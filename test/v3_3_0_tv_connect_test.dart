import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/services/tv_qr_pairing_service.dart';
import 'package:tubotv/services/tv_remote_service.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/tv_remote_sheet.dart';

ThemeData _darkTheme() => AppColors.buildDarkTheme(
      accent: AppAccent.white,
      surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TvModeService.instance.resetForTest();
    InutilAuthService.testSkipOnlineValidation = true;
  });

  tearDown(() {
    TvModeService.instance.resetForTest();
    InutilAuthService.testSkipOnlineValidation = false;
  });

  group('TvQrPairingService — cifrado E2E AES-256 + HMAC', () {
    test('genera QR válido, cifra/descifra refreshToken y detecta manipulación',
        () {
      final code = TvQrPairingService.generateCode();
      final key = TvQrPairingService.generateSecretKey();
      expect(code.length, 8);
      expect(key.length, 32);

      final uri = TvQrPairingService.buildQrUri(code, key);
      final parsed = TvQrPairingService.parseQrUri(uri);
      expect(parsed, isNotNull);
      expect(parsed!.code, code);
      expect(parsed.secretKey, orderedEquals(key));

      final encrypted = TvQrPairingService.encryptPayload(
        {
          'refreshToken': 'rt_super_secreto_12345',
          'email': 'cesar@inutilmusic.com',
          'uid': 'uid_abc',
        },
        parsed.secretKey,
      );
      expect(encrypted, isNot(contains('rt_super_secreto_12345')));

      final decrypted = TvQrPairingService.decryptPayload(encrypted, key);
      expect(decrypted, isNotNull);
      expect(decrypted!['refreshToken'], 'rt_super_secreto_12345');
      expect(decrypted['email'], 'cesar@inutilmusic.com');

      // Clave distinta -> debe fallar HMAC
      final wrongKey = Uint8List.fromList(List.filled(32, 7));
      expect(TvQrPairingService.decryptPayload(encrypted, wrongKey), isNull);

      // Ciphertext alterado -> debe fallar HMAC
      final tampered =
          '${encrypted.substring(0, encrypted.length - 4)}AAAA';
      expect(TvQrPairingService.decryptPayload(tampered, key), isNull);

      // QR ajenos -> null
      expect(TvQrPairingService.parseQrUri('https://example.com'), isNull);
      expect(TvQrPairingService.parseQrUri(''), isNull);

      // Código manual XXXX-XXXX deriva clave determinista de 32 bytes y descifra
      final manualKey = TvQrPairingService.deriveManualCodeKey('33JL-YR6D');
      final manualKey2 = TvQrPairingService.deriveManualCodeKey('33jlyr6d');
      expect(manualKey.length, 32);
      expect(manualKey, orderedEquals(manualKey2));
      final encManual = TvQrPairingService.encryptPayload(
        {'refreshToken': 'rt_manual_ok'},
        manualKey,
      );
      expect(
        TvQrPairingService.decryptPayload(encManual, manualKey2)?['refreshToken'],
        'rt_manual_ok',
      );
    });
  });

  group('1 Celular + 1 Smart TV — ranuras independientes en InutilUser', () {
    test('conserva currentTvDeviceId (celular) y currentSmartTvDeviceId (TV)',
        () {
      const user = InutilUser(
        uid: 'u1',
        email: 'user@test.com',
        status: 'active',
        isActive: true,
        currentTvDeviceId: 'mobile_dev_1',
        currentSmartTvDeviceId: 'onn_tv_1',
      );
      final json = user.toJson();
      final roundTrip = InutilUser.fromJson(json);

      expect(roundTrip.currentTvDeviceId, 'mobile_dev_1');
      expect(roundTrip.currentSmartTvDeviceId, 'onn_tv_1');
      expect(roundTrip.hasAnyBoundDevice, isTrue);

      final updated = roundTrip.copyWith(currentSmartTvDeviceId: 'onn_tv_2');
      expect(updated.currentTvDeviceId, 'mobile_dev_1');
      expect(updated.currentSmartTvDeviceId, 'onn_tv_2');
    });
  });

  group('TvRemoteService — presencia, comandos y control remoto móvil', () {
    test('despacha play_vod/play_channel al launcher y controles al player', () {
      String? launchedAction;
      String? playerAction;
      TvRemoteService.instance.registerTvLaunchHandler((c) {
        launchedAction = c.action;
      });
      TvRemoteService.instance.registerActivePlayerHandler((c) {
        playerAction = c.action;
      });

      final vodCmd = TvRemoteCommand(
        commandId: 'c1',
        action: 'play_vod',
        payload: const {'positionSec': 120},
        createdAt: DateTime.now(),
      );
      final roundTrip = TvRemoteCommand.fromFirestore(vodCmd.toFirestore());
      expect(roundTrip, isNotNull);
      expect(roundTrip!.payload['positionSec'], 120);

      TvRemoteService.instance.dispatchCommandLocally(roundTrip);
      expect(launchedAction, 'play_vod');

      TvRemoteService.instance.dispatchCommandLocally(
        TvRemoteCommand(
          commandId: 'c2',
          action: 'toggle_play',
          payload: const {},
          createdAt: DateTime.now(),
        ),
      );
      expect(playerAction, 'toggle_play');

      TvRemoteService.instance.registerTvLaunchHandler(null);
      TvRemoteService.instance.registerActivePlayerHandler(null);
    });

    test('despacha comandos D-Pad y navegación al handler de sistema', () {
      String? navAction;
      Map<String, dynamic>? navPayload;
      TvRemoteService.instance.registerSystemNavigationHandler((c) {
        navAction = c.action;
        navPayload = c.payload;
      });

      TvRemoteService.instance.dispatchCommandLocally(
        TvRemoteCommand(
          commandId: 'c_dpad',
          action: 'dpad_up',
          payload: const {},
          createdAt: DateTime.now(),
        ),
      );
      expect(navAction, 'dpad_up');

      TvRemoteService.instance.dispatchCommandLocally(
        TvRemoteCommand(
          commandId: 'c_tab',
          action: 'nav_tab',
          payload: const {'index': 2},
          createdAt: DateTime.now(),
        ),
      );
      expect(navAction, 'nav_tab');
      expect(navPayload?['index'], 2);

      TvRemoteService.instance.registerSystemNavigationHandler(null);
    });

    test('TvPlaybackState detecta TV conectada vs desconectada (ventana 300s con skew)', () {
      final online = TvPlaybackState(
        online: true,
        title: 'Los Croods',
        isPlaying: true,
        positionSec: 300,
        durationSec: 1200,
        updatedAt: DateTime.now(),
      );
      expect(online.isReachable, isTrue);
      expect(online.progressFraction, closeTo(0.25, 0.001));

      // Desfase de reloj tolerable (+30 s o -180 s)
      final skewAhead = TvPlaybackState(
        online: true,
        updatedAt: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(skewAhead.isReachable, isTrue);

      final skewBehind = TvPlaybackState(
        online: true,
        updatedAt: DateTime.now().subtract(const Duration(seconds: 180)),
      );
      expect(skewBehind.isReachable, isTrue);

      final stale = TvPlaybackState(
        online: true,
        updatedAt: DateTime.now().subtract(const Duration(seconds: 350)),
      );
      expect(stale.isReachable, isFalse);
    });

    testWidgets('TvRemoteSheet muestra estado conectado, D-Pad y botones de mando',
        (tester) async {
      TvRemoteService.instance.setTvStateForTest(
        TvPlaybackState(
          online: true,
          title: 'Dragon Ball Super',
          subtitle: 'Episodio 2',
          isPlaying: true,
          positionSec: 120,
          durationSec: 1400,
          updatedAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: _darkTheme(),
          home: const Scaffold(body: TvRemoteSheet()),
        ),
      );
      await tester.pump();

      expect(find.text('Mi Smart TV'), findsOneWidget);
      expect(find.text('Dragon Ball Super'), findsOneWidget);
      expect(find.text('-10s'), findsOneWidget);
      expect(find.text('+10s'), findsOneWidget);
      expect(find.text('Cerrar'), findsOneWidget);
      expect(find.text('Control Remoto'), findsOneWidget);
      expect(find.text('OK'), findsOneWidget);
      expect(find.text('Atrás'), findsOneWidget);
      expect(find.text('Inicio'), findsOneWidget);
      expect(find.text('Buscar'), findsOneWidget);
      expect(find.text('📺 En Vivo'), findsOneWidget);
      expect(find.text('🎬 Cine'), findsOneWidget);
    });
  });
}
