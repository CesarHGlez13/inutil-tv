import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/screens/about_screen.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/firebase_config.dart';
import 'package:tubotv/services/firebase_firestore_service.dart';
import 'package:tubotv/widgets/inutil_admin_panel.dart';
import 'package:tubotv/widgets/inutil_auth_gate.dart';

Future<void> seedSession({
  required String uid,
  required String email,
  String role = 'user',
  String status = 'active',
  bool isActive = true,
  String? expiresAt,
  String currentTvDeviceId = '',
  String currentPhoneDeviceId = '',
}) async {
  final prefs = await SharedPreferences.getInstance();
  final user = <String, dynamic>{
    'uid': uid,
    'email': email,
    'displayName': email.split('@').first,
    'role': role,
    'status': status,
    'isActive': isActive,
    'accountExpiresAt': expiresAt,
    'currentTvDeviceId': currentTvDeviceId,
    'currentPhoneDeviceId': currentPhoneDeviceId,
  };
  await prefs.setString('inutil_tv_auth_user_v3', jsonEncode(user));
  await prefs.setString(
    'inutil_tv_auth_session_v3',
    jsonEncode({
      'uid': uid,
      'email': email,
      'idToken': 'test-token',
      'refreshToken': 'test-refresh',
    }),
  );
  await prefs.setString(
    'inutil_tv_last_validated_v3',
    DateTime.now().toIso8601String(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    InutilAuthService.testSkipOnlineValidation = true;
    await InutilAuthService.instance.initialize();
  });

  tearDown(() async {
    await InutilAuthService.instance.signOut();
    InutilAuthService.testSkipOnlineValidation = false;
  });

  group('FirebaseConfig & Firestore UpdateMask', () {
    test('Apunta al mismo proyecto Firebase que Inútil Music y tiene Web Client ID', () {
      expect(FirebaseConfig.projectId, 'inutil-music-app');
      expect(FirebaseConfig.messagingSenderId, '129744480084');
      expect(
        FirebaseConfig.googleWebClientId,
        contains('.apps.googleusercontent.com'),
      );
      expect(
        InutilAuthService.isBootstrapAdminEmail('humbertoglez96@gmail.com'),
        isTrue,
      );
      expect(
        InutilAuthService.isBootstrapAdminEmail('cesar@inutilmusic.com'),
        isTrue,
      );
    });

    test('buildPatchUri agrega updateMask.fieldPaths en merge=true', () {
      final uri = InutilFirestoreService.buildPatchUri(
        'users/abc',
        ['isActive', 'status'],
        merge: true,
      );
      expect(uri.queryParametersAll['updateMask.fieldPaths'], ['isActive', 'status']);
    });

    test('buildPatchUri omite updateMask en merge=false (creación completa)', () {
      final uri = InutilFirestoreService.buildPatchUri(
        'users/abc',
        ['uid', 'email'],
        merge: false,
      );
      expect(uri.queryParametersAll['updateMask.fieldPaths'], isNull);
    });
  });

  group('InutilUser Model & Permissions', () {
    test('Solo el rol admin define al Administrador', () {
      const admin = InutilUser(
        uid: 'u1',
        email: 'admin@inutil.com',
        role: 'admin',
      );
      expect(admin.isAdmin, isTrue);
      expect(admin.isPermanent, isTrue);
      expect(admin.isExpired, isFalse);
      expect(admin.licenseValid, isTrue);
      expect(admin.daysRemaining, 9999);
    });

    test('El correo fundador NO concede admin sin rol en Firestore', () {
      const user = InutilUser(
        uid: 'u2',
        email: 'cesar@inutilmusic.com',
        role: 'user',
        status: 'pending',
        isActive: false,
      );
      expect(user.isAdmin, isFalse);
      expect(user.licenseValid, isFalse);
    });

    test('Usuario con vigencia futura tiene licencia válida', () {
      final user = InutilUser(
        uid: 'u3',
        email: 'cliente@ejemplo.com',
        role: 'user',
        status: 'active',
        isActive: true,
        accountExpiresAt: DateTime.now().add(const Duration(days: 20)),
      );
      expect(user.isExpired, isFalse);
      expect(user.licenseValid, isTrue);
      expect(user.daysRemaining, greaterThanOrEqualTo(19));
    });

    test('Usuario expirado no puede reproducir', () {
      final user = InutilUser(
        uid: 'u4',
        email: 'expirado@ejemplo.com',
        role: 'user',
        status: 'active',
        isActive: true,
        accountExpiresAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(user.isExpired, isTrue);
      expect(user.licenseValid, isFalse);
    });

    test('Licencia permanente (>= 2090) nunca expira', () {
      final user = InutilUser(
        uid: 'u5',
        email: 'vip@ejemplo.com',
        role: 'user',
        status: 'active',
        isActive: true,
        accountExpiresAt: DateTime(2099, 12, 31),
      );
      expect(user.isPermanent, isTrue);
      expect(user.isExpired, isFalse);
      expect(user.licenseValid, isTrue);
    });
  });

  group('InutilAuthService Lifecycle & Device Isolation', () {
    test('Un teléfono de Inútil Music NO bloquea InútilTV', () async {
      final future = DateTime.now().add(const Duration(days: 15));
      await seedSession(
        uid: 'uid_both_apps',
        email: 'ambas@inutil.com',
        status: 'active',
        isActive: true,
        expiresAt: future.toIso8601String(),
        currentPhoneDeviceId: 'inutil_music_phone_uuid',
        currentTvDeviceId: InutilAuthService.instance.deviceId,
      );
      await InutilAuthService.instance.initialize();

      final auth = InutilAuthService.instance;
      expect(auth.isAccessAllowed, isTrue);
      expect(auth.canPlay, isTrue);
      expect(auth.blockedReason, isEmpty);
    });

    test('Otro equipo TV bloquea la reproducción', () async {
      final future = DateTime.now().add(const Duration(days: 15));
      await seedSession(
        uid: 'uid_other_tv',
        email: 'otro_tv@inutil.com',
        status: 'active',
        isActive: true,
        expiresAt: future.toIso8601String(),
        currentTvDeviceId: 'otro_tv_box_distinto',
      );
      await InutilAuthService.instance.initialize();

      final auth = InutilAuthService.instance;
      expect(auth.canPlay, isFalse);
      expect(auth.blockedReason, contains('Otro dispositivo'));
    });

    test('Ventana de gracia offline de 72 horas', () async {
      final future = DateTime.now().add(const Duration(days: 15));
      await seedSession(
        uid: 'uid_stale',
        email: 'offline@inutil.com',
        status: 'active',
        isActive: true,
        expiresAt: future.toIso8601String(),
      );
      await InutilAuthService.instance.initialize();
      InutilAuthService.instance.testSeedLicenseValidation(
        DateTime.now().subtract(const Duration(hours: 73)),
      );

      expect(InutilAuthService.instance.canPlay, isFalse);
      expect(InutilAuthService.instance.blockedReason, contains('72 horas'));
    });

    test('Purga claves legadas locales al inicializar', () async {
      SharedPreferences.setMockInitialValues({
        'inutiltv_auth_session': '{"role":"admin"}',
        'inutiltv_custom_licenses': ['FAKE-KEY'],
      });
      await InutilAuthService.instance.initialize();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('inutiltv_auth_session'), isFalse);
      expect(prefs.containsKey('inutiltv_custom_licenses'), isFalse);
      expect(InutilAuthService.instance.isAuthenticated, isFalse);
    });
  });

  group('InutilAuthGate & InutilAdminPanel Widget Tests', () {
    testWidgets('Sin sesión muestra InutilAuthScreen (login/registro)',
        (tester) async {
      await InutilAuthService.instance.signOut();

      await tester.pumpWidget(
        const MaterialApp(
          home: InutilAuthGate(
            child: Scaffold(body: Text('APP_INTERIOR')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(InutilAuthScreen), findsOneWidget);
      expect(find.text('INUTIX TV'), findsOneWidget);
      expect(find.text('Iniciar Sesión'), findsOneWidget);
      expect(find.text('Crear Cuenta'), findsOneWidget);
      expect(find.text('Continuar con Google'), findsOneWidget);
      expect(find.text('APP_INTERIOR'), findsNothing);
    });

    testWidgets('Usuario pendiente muestra pantalla CUENTA PENDIENTE',
        (tester) async {
      await seedSession(
        uid: 'uid_pend',
        email: 'pendiente@inutil.com',
        status: 'pending',
        isActive: false,
      );
      await InutilAuthService.instance.initialize();

      await tester.pumpWidget(
        const MaterialApp(
          home: InutilAuthGate(
            child: Scaffold(body: Text('APP_INTERIOR')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(InutilLicenseBlockedScreen), findsOneWidget);
      expect(find.text('CUENTA PENDIENTE'), findsOneWidget);
      expect(find.text('Comprobar Estado en Firebase'), findsOneWidget);
      expect(find.text('APP_INTERIOR'), findsNothing);
    });

    testWidgets('Usuario vencido muestra pantalla LICENCIA VENCIDA',
        (tester) async {
      await seedSession(
        uid: 'uid_exp',
        email: 'vencido@inutil.com',
        status: 'active',
        isActive: true,
        expiresAt: DateTime.now().subtract(const Duration(days: 3)).toIso8601String(),
      );
      await InutilAuthService.instance.initialize();

      await tester.pumpWidget(
        const MaterialApp(
          home: InutilAuthGate(
            child: Scaffold(body: Text('APP_INTERIOR')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(InutilLicenseBlockedScreen), findsOneWidget);
      expect(find.text('LICENCIA VENCIDA'), findsOneWidget);
      expect(find.text('APP_INTERIOR'), findsNothing);
    });

    testWidgets('Admin accede al interior de la app', (tester) async {
      await seedSession(
        uid: 'uid_admin',
        email: 'cesar@inutilmusic.com',
        role: 'admin',
        status: 'active',
        isActive: true,
        expiresAt: DateTime(2099, 12, 31).toIso8601String(),
      );
      await InutilAuthService.instance.initialize();

      await tester.pumpWidget(
        const MaterialApp(
          home: InutilAuthGate(
            child: Scaffold(body: Text('APP_INTERIOR')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('APP_INTERIOR'), findsOneWidget);
      expect(find.byType(InutilAuthScreen), findsNothing);
      expect(find.byType(InutilLicenseBlockedScreen), findsNothing);
    });

    testWidgets('InutilAdminPanel renderiza controles y usuarios sin overflow',
        (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'inutil_tv_users_cache_v3',
        jsonEncode([
          {
            'uid': 'uid_admin',
            'email': 'cesar@inutilmusic.com',
            'displayName': 'César',
            'role': 'admin',
            'status': 'active',
            'isActive': true,
            'accountExpiresAt': DateTime(2099, 12, 31).toIso8601String(),
          },
          {
            'uid': 'uid_pending_1',
            'email': 'nuevo@cliente.com',
            'displayName': 'Juan',
            'role': 'user',
            'status': 'pending',
            'isActive': false,
          },
        ]),
      );
      await seedSession(
        uid: 'uid_admin',
        email: 'cesar@inutilmusic.com',
        role: 'admin',
        status: 'active',
        isActive: true,
        expiresAt: DateTime(2099, 12, 31).toIso8601String(),
      );
      await InutilAuthService.instance.initialize();

      // Probar en tamaño de teléfono angosto (390x844) para descartar overflows.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: InutilAdminPanel()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Panel de Control César'), findsOneWidget);
      expect(find.text('Nuevo Usuario'), findsOneWidget);
      expect(find.text('cesar@inutilmusic.com'), findsOneWidget);
      expect(find.text('nuevo@cliente.com'), findsOneWidget);
      expect(find.text('⏳ PENDIENTE'), findsOneWidget);
      expect(find.text('👑 ADMIN'), findsOneWidget);
    });

    testWidgets('AboutScreen muestra creador, versión, novedades y donaciones',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(home: AboutScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Acerca de la aplicación'), findsOneWidget);
      expect(find.text('Creado por ${AppInfo.creatorName}'), findsOneWidget);
      expect(find.text('Buscar actualizaciones (OTA)'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Apoyar el desarrollo / Donaciones'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Apoyar el desarrollo / Donaciones'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(AppInfo.supportEmail),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(AppInfo.supportEmail), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('about-whats-new')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      // Abrir diálogo de Novedades
      await tester.tap(find.byKey(const ValueKey('about-whats-new')));
      await tester.pumpAndSettle();
      expect(find.text('Novedades de v${AppInfo.appVersion}'), findsOneWidget);
      await tester.tap(find.text('Entendido'));
      await tester.pumpAndSettle();

      // Abrir diálogo de Donaciones / Apoyar el Desarrollo
      await tester.tap(find.byKey(const ValueKey('about-support')));
      await tester.pumpAndSettle();
      expect(find.text('Apoyar el Desarrollo'), findsOneWidget);
      expect(find.text('Enviar Correo'), findsOneWidget);
    });
  });
}
