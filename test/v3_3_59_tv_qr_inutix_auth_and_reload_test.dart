import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/services/tv_qr_pairing_service.dart';
import 'package:tubotv/widgets/inutil_auth_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    InutilAuthService.testSkipOnlineValidation = true;
    InutilAuthService.inutixRefreshOverrideForTest = null;
    await InutilAuthService.instance.signOut();
  });

  tearDown(() async {
    InutilAuthService.inutixRefreshOverrideForTest = null;
    InutilAuthService.testSkipOnlineValidation = false;
    await InutilAuthService.instance.signOut();
  });

  group('v3.3.59 — Vinculación QR TV con sesiones nativas Inutix y botón Recargar QR',
      () {
    test('signInWithPairedRefreshToken canjea inutix_ref_* vía /auth/refresh',
        () async {
      var receivedRefresh = '';
      InutilAuthService.inutixRefreshOverrideForTest = (rt) async {
        receivedRefresh = rt;
        return {
          'ok': true,
          'idToken': 'inutix_ses_nueva_sesion_tv_123',
          'refreshToken': rt,
          'expiresIn': '2592000',
        };
      };

      final err = await InutilAuthService.instance.signInWithPairedRefreshToken(
        'inutix_ref_celular_activo_abc',
        uidHint: 'K8Rz2FDAvfeZqqmmzsEBYy2TK8g1',
        emailHint: 'usuario@example.com',
        displayNameHint: 'Usuario TV',
      );

      expect(err, isNull);
      expect(receivedRefresh, 'inutix_ref_celular_activo_abc');
      final u = InutilAuthService.instance.currentUser;
      expect(u, isNotNull);
      expect(u!.uid, 'K8Rz2FDAvfeZqqmmzsEBYy2TK8g1');
      expect(u.email, 'usuario@example.com');
      expect(u.idToken, 'inutix_ses_nueva_sesion_tv_123');
      expect(u.refreshToken, 'inutix_ref_celular_activo_abc');
    });

    test('signInWithPairedRefreshToken rechaza inutix_ref_* inválido con mensaje claro',
        () async {
      InutilAuthService.inutixRefreshOverrideForTest = (_) async => null;

      final err = await InutilAuthService.instance.signInWithPairedRefreshToken(
        'inutix_ref_revocado',
        uidHint: 'uid_test',
      );

      expect(err, isNotNull);
      expect(err, contains('sesión activa vigente'));
      expect(InutilAuthService.instance.currentUser, isNull);
    });

    test('ensureFreshIdToken soporta inutix_ses_* y refresca inutix_ref_* con force',
        () async {
      var refreshCalls = 0;
      InutilAuthService.inutixRefreshOverrideForTest = (rt) async {
        refreshCalls++;
        return {
          'ok': true,
          'idToken': 'inutix_ses_refrescado_$refreshCalls',
          'refreshToken': rt,
        };
      };

      await InutilAuthService.instance.signInWithPairedRefreshToken(
        'inutix_ref_demo_1',
        uidHint: 'uid_demo_1',
        emailHint: 'demo@example.com',
      );
      expect(refreshCalls, 1);

      // Ahora con validación online activa: sin force, inutix_ses_* es válido sin red
      InutilAuthService.testSkipOnlineValidation = false;
      final okNoForce = await InutilAuthService.instance.ensureFreshIdToken();
      expect(okNoForce, isTrue);
      expect(refreshCalls, 1);

      // Con force: true, sí refresca vía /auth/refresh (no Google securetoken)
      final okForce =
          await InutilAuthService.instance.ensureFreshIdToken(force: true);
      expect(okForce, isTrue);
      expect(refreshCalls, 2);
      expect(
        InutilAuthService.instance.currentUser?.idToken,
        'inutix_ses_refrescado_2',
      );
    });

    test('TvQrPairingService extiende vigencia del QR a 5 minutos', () {
      expect(TvQrPairingService.sessionTtl, const Duration(minutes: 5));
    });

    testWidgets('InutilAuthScreen en modo TV ofrece botón visible para regenerar QR',
        (tester) async {
      TvModeService.instance.setForTest(detectedTv: true);
      addTearDown(TvModeService.instance.resetForTest);

      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: InutilAuthScreen(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final hasReloadBtn = find.text('Recargar código QR').evaluate().isNotEmpty ||
          find.text('Generar nuevo QR').evaluate().isNotEmpty;
      expect(hasReloadBtn, isTrue);
    });
  });
}
