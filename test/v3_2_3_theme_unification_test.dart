import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/screens/player_screen.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/inutil_update_service.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/inutil_auth_gate.dart';
import 'package:tubotv/widgets/inutil_inactivity_paused_screen.dart';
import 'package:tubotv/widgets/inutil_update_gate.dart';

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

  group('Unificación visual v3.2.3 (cero temas heredados)', () {
    test('0 colores hex heredados (azul marino / cian neón) en todo lib/', () {
      final legacyPattern = RegExp(
        r'0xFF(0D1426|070B14|0A0F1E|0D1424|04060E|050811|00E5FF|0072FF|12142A|1E293B)',
        caseSensitive: false,
      );
      final libDir = Directory('lib');
      final offenders = <String>[];

      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final content = entity.readAsStringSync();
        for (final match in legacyPattern.allMatches(content)) {
          offenders.add('${entity.path}: ${match.group(0)}');
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Se encontraron colores heredados fuera del tema Inútil Music: $offenders',
      );
    });

    testWidgets(
      'InutilUpdateDialogContent usa superficie Carbon Black y acento dinámico del usuario',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final release = InutilTvReleaseInfo(
          currentVersion: '3.2.2',
          latestVersion: '3.2.3',
          mandatory: false,
          apkDownloadUrl: 'https://example.com/inutiltv-3.2.3.apk',
          releaseNotes: const [
            'Unificación visual total al estilo Inútil Music en todos los diálogos y pantallas.',
            'Caja elevada con scroll limpio para novedades largas sin cortar texto.',
            'Adaptación completa a tema oscuro, tema claro y los 18 colores de acento.',
            'Otra línea larga adicional para verificar scroll interno sin overflow en teléfonos compactos.',
          ],
          publishedAt: DateTime.utc(2026, 11, 18),
        );

        final darkTheme = AppColors.buildDarkTheme(
          accent: AppAccent.green,
          surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: darkTheme,
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: InutilUpdateDialogContent(
                    release: release,
                    onClose: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Inutix TV v3.2.3'), findsOneWidget);
        expect(find.text('NOVEDADES'), findsOneWidget);
        expect(find.text('Actualizar ahora'), findsOneWidget);
        expect(find.text('Más tarde'), findsOneWidget);

        final card = tester.widget<Material>(
          find.byKey(const ValueKey('inutil-update-dialog-card')),
        );
        final ctx = tester.element(
          find.byKey(const ValueKey('inutil-update-dialog-card')),
        );
        expect(card.color, AppColors.cardSurfaceFor(ctx));
        expect(AppColors.accentFor(ctx), AppAccent.green.seedColor);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'InutilUpdateDialogContent y InutilForceUpdateScreen funcionan en tema Claro sin overflow',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final blockingRelease = InutilTvReleaseInfo(
          currentVersion: '3.1.0',
          latestVersion: '3.2.3',
          minSupportedVersion: '3.2.1',
          mandatory: true,
          apkDownloadUrl: 'https://example.com/inutiltv-3.2.3.apk',
          releaseNotes: const ['Actualización obligatoria verificada'],
          publishedAt: DateTime.utc(2026, 11, 18),
        );

        final lightTheme = AppColors.buildLightTheme(
          accent: AppAccent.ocean,
          surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: lightTheme,
            home: InutilForceUpdateScreen(
              release: blockingRelease,
              onRetry: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
        expect(scaffold.backgroundColor, AppColors.lightScaffold);
        expect(find.text('ACTUALIZACIÓN OBLIGATORIA'), findsOneWidget);
        expect(find.text('Comprobar de nuevo'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'InutilAuthScreen, InutilLicenseBlockedScreen e InutilInactivityPausedScreen respetan tema y acento',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final lightTheme = AppColors.buildLightTheme(
          accent: AppAccent.purple,
          surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
        );
        final darkTheme = AppColors.buildDarkTheme(
          accent: AppAccent.orange,
          surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
        );

        // 1. Login en tema claro
        await tester.pumpWidget(
          MaterialApp(theme: lightTheme, home: const InutilAuthScreen()),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
          AppColors.lightScaffold,
        );
        expect(find.text('INUTIX TV'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 2. Cuenta Pendiente en tema oscuro
        const pendingUser = InutilUser(
          uid: 'uid_pending_theme',
          email: 'usuario@familia.inutil',
          displayName: 'César',
          role: 'user',
          status: 'pending',
          isActive: false,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: darkTheme,
            home: const InutilLicenseBlockedScreen(user: pendingUser),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
          AppColors.carbonScaffold,
        );
        expect(find.text('CUENTA PENDIENTE'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 3. Pausa por inactividad en tema claro
        await tester.pumpWidget(
          MaterialApp(
            theme: lightTheme,
            home: const InutilInactivityPausedScreen(
              user: pendingUser,
              inactiveDays: 18,
              policyDays: 15,
            ),
          ),
        );
        // Avanzar más allá de kThemeAnimationDuration (200ms) para completar AnimatedTheme.
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
          AppColors.lightScaffold,
        );
        expect(find.byKey(const ValueKey('inutil-inactivity-paused-screen')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    test('PlayerScreen oculta nombres internos de fuentes y detalles técnicos', () {
      expect(
        PlayerScreen.publicServerLabel(0, 'VidHide HLS · Latino'),
        'Servidor 1 · Latino',
      );
      expect(
        PlayerScreen.publicServerLabel(1, 'StreamWish HLS · Subtitulado'),
        'Servidor 2 · Subtitulado',
      );
      expect(
        PlayerScreen.publicServerLabel(2, 'Doodstream MP4 · Español 1080p'),
        'Servidor 3 · Español · 1080p',
      );
      expect(
        PlayerScreen.publicServerLabel(0, 'JKPlayer #1 HD'),
        'Servidor 1 · HD',
      );
      expect(
        PlayerScreen.publicServerLabel(0, 'Sin conexión · AES-256'),
        'Sin conexión',
      );

      expect(
        PlayerScreen.sanitizeStatusMessage('Verificando VidHide HD (Latino)...'),
        'Conectando al servidor...',
      );
      expect(
        PlayerScreen.sanitizeStatusMessage('Buscando servidores de JKAnime...'),
        'Conectando al servidor...',
      );
      expect(
        PlayerScreen.sanitizeStatusMessage('Buscando servidores disponibles...'),
        'Buscando servidores disponibles...',
      );
    });
  });
}
