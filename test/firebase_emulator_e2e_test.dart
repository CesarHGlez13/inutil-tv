import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/firebase_config.dart';
import 'package:tubotv/services/firebase_firestore_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'E2E real contra Emulador Firebase Auth + Firestore Rules',
    () async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      InutilAuthService.testSkipOnlineValidation = false;

      final auth = InutilAuthService.instance;
      await auth.initialize();

      // 1. Registro de usuario normal -> queda en estado pending sin acceso
      final cliente = await auth.register(
        email: 'cliente@inutiltv.test',
        password: 'password123',
        displayName: 'Cliente Prueba',
      );
      expect(cliente.role, 'user');
      expect(cliente.status, 'pending');
      expect(cliente.isActive, isFalse);
      expect(auth.isAccessAllowed, isFalse);
      final clienteUid = cliente.uid;

      // 2. El usuario normal NO puede auto-ascenderse ni darse vigencia
      final selfEscalate = await InutilFirestoreService.instance.setDocument(
        'users/$clienteUid',
        {'role': 'admin', 'status': 'active', 'isActive': true},
        merge: true,
      );
      expect(selfEscalate, isFalse);
      await auth.signOut();

      // 3. Registro del admin fundador -> rol admin automático validado por rules
      final admin = await auth.register(
        email: InutilAuthService.bootstrapAdminEmail,
        password: 'AdminPassword2026!',
        displayName: 'César Admin',
      );
      expect(admin.isAdmin, isTrue);
      expect(admin.isActive, isTrue);
      expect(auth.isAccessAllowed, isTrue);

      // 4. El admin lista todos los usuarios desde Firestore
      var all = await auth.getAllUsers();
      expect(all.length, greaterThanOrEqualTo(2));
      expect(all.any((u) => u.uid == clienteUid && u.status == 'pending'), isTrue);

      // 5. El admin crea un nuevo usuario SIN perder su propia sesión admin
      final creado = await auth.adminCreateUser(
        email: 'vip@inutiltv.test',
        password: 'vippassword123',
        displayName: 'Usuario VIP',
        initialDays: 90,
      );
      expect(auth.currentUser?.email, InutilAuthService.bootstrapAdminEmail);
      expect(auth.currentUser?.isAdmin, isTrue);
      expect(creado.isActive, isTrue);

      // 6. El admin otorga 30 días al usuario pendiente (updateMask debe preservar email y displayName)
      await auth.adminGrantVigencia(uid: clienteUid, additionalDays: 30);
      final clienteDoc =
          await InutilFirestoreService.instance.getUserProfile(clienteUid);
      expect(clienteDoc, isNotNull);
      expect(clienteDoc!['email'], 'cliente@inutiltv.test');
      expect(clienteDoc['displayName'], 'Cliente Prueba');
      expect(clienteDoc['status'], 'active');
      expect(clienteDoc['isActive'], isTrue);

      // 7. Suspender y reactivar preservando datos
      await auth.adminToggleUserActive(uid: clienteUid, isActive: false);
      var docSuspended =
          await InutilFirestoreService.instance.getUserProfile(clienteUid);
      expect(docSuspended!['isActive'], isFalse);
      expect(docSuspended['status'], 'blocked');
      expect(docSuspended['email'], 'cliente@inutiltv.test');

      await auth.adminToggleUserActive(uid: clienteUid, isActive: true);
      await auth.adminRevokeDevice(clienteUid);
      await auth.adminDeleteUser(creado.uid);

      all = await auth.getAllUsers();
      expect(all.any((u) => u.uid == creado.uid), isFalse);

      // 8. El cliente vuelve a iniciar sesión y ahora tiene acceso completo + TV device claim
      await auth.signOut();
      final clienteActive = await auth.signIn(
        email: 'cliente@inutiltv.test',
        password: 'password123',
      );
      expect(clienteActive.licenseValid, isTrue);
      expect(auth.isAccessAllowed, isTrue);
      expect(auth.canPlay, isTrue);
      expect(clienteActive.currentTvDeviceId, auth.deviceId);

      await auth.signOut();
    },
    skip: !FirebaseConfig.useEmulator,
  );
}
