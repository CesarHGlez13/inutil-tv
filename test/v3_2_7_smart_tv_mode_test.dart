import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/main.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/poster_card.dart';
import 'package:tubotv/widgets/tv_focusable.dart';

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

  group('TvModeService — detección y override Smart TV', () {
    test('detecta modo TV, persiste override manual y vuelve a automático',
        () async {
      final svc = TvModeService.instance;
      svc.setForTest(detectedTv: false);
      expect(svc.isTv, isFalse);

      await svc.setManualOverride(true);
      expect(svc.isTv, isTrue);
      expect(svc.manualOverride, isTrue);

      // Re-cargar desde SharedPreferences conserva el override
      await svc.initialize(force: true);
      expect(svc.isTv, isTrue);

      await svc.setManualOverride(null);
      expect(svc.manualOverride, isNull);
      expect(svc.isTv, isFalse);

      svc.setForTest(detectedTv: true);
      expect(svc.isTv, isTrue);
    });
  });

  group('TvFocusable & PosterCard — control remoto D-pad', () {
    testWidgets('TvFocusable activa onTap con botón OK (select) y Enter',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: _darkTheme(),
          home: Scaffold(
            body: Center(
              child: TvFocusable(
                autofocus: true,
                onTap: () => taps++,
                child: const SizedBox(
                  width: 120,
                  height: 60,
                  child: Text('Abrir'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 2);
    });

    testWidgets('PosterCard recibe foco y abre detalle al pulsar OK (select)',
        (tester) async {
      var opened = false;
      final item = VodItem(
        id: 'm_tv_1',
        title: 'Película en Smart TV',
        poster: '',
        overview: 'Prueba de control remoto',
        year: '2026',
        genre: 'Acción',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: _darkTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 140,
                height: 220,
                child: PosterCard(
                  item: item,
                  expandInGrid: true,
                  onTap: () => opened = true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Enfocar con Tab (simula entrada D-pad) y pulsar OK (select)
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();

      expect(opened, isTrue);
    });
  });

  group('MainScaffold — interfaz adaptativa Smart TV vs Celular', () {
    testWidgets('en modo Smart TV muestra barra lateral y oculta barra móvil',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      TvModeService.instance.setForTest(detectedTv: true);

      await tester.pumpWidget(
        MaterialApp(
          theme: _darkTheme(),
          shortcuts: <ShortcutActivator, Intent>{
            ...WidgetsApp.defaultShortcuts,
            const SingleActivator(LogicalKeyboardKey.select):
                const ActivateIntent(),
          },
          home: const MainScaffold(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 200));

      // En modo TV el rail lateral tiene foco inicial (autofocus en Inicio) y se expande
      expect(find.text('Buscar'), findsWidgets);
      expect(find.text('Inicio'), findsWidgets);
      expect(find.text('Cine'), findsWidgets);
      expect(find.text('Series'), findsWidgets);
      expect(find.text('Anime'), findsWidgets);
      expect(find.text('Ajustes'), findsWidgets);

      // Cambiar a Cine con D-pad (En Vivo -> Cine -> OK) y salir con Flecha Derecha
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final railFocusBefore = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      expect(FocusManager.instance.primaryFocus, isNot(equals(railFocusBefore)));
      // Al salir del rail, éste se compacta (ya no muestra la etiqueta 'Ajustes')
      expect(find.text('Ajustes'), findsNothing);
    });

    testWidgets('manifiesto Android declara Leanback y banner de Android TV',
        (tester) async {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android.intent.category.LEANBACK_LAUNCHER'));
      expect(manifest, contains('android.software.leanback'));
      expect(manifest, contains('android.hardware.touchscreen'));
      expect(manifest, contains('android:banner="@drawable/tv_banner"'));
      expect(
        File('android/app/src/main/res/drawable/tv_banner.png').existsSync(),
        isTrue,
      );
      expect(
        File('android/app/src/main/res/drawable-xhdpi/tv_banner.png')
            .existsSync(),
        isTrue,
      );
    });

    testWidgets(
        'TvFocusable con descendantsAreFocusable=false baja 1 a 1 sin rebotar ni dejar foco doble',
        (tester) async {
      final focused = <int>{};
      await tester.pumpWidget(
        MaterialApp(
          theme: _darkTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 420,
              child: ListView.builder(
                itemCount: 15,
                itemBuilder: (_, i) => TvFocusable(
                  autofocus: i == 0,
                  descendantsAreFocusable: false,
                  descendantsAreTraversable: false,
                  onFocusChange: (f) {
                    if (f) {
                      focused.add(i);
                    } else {
                      focused.remove(i);
                    }
                  },
                  onTap: () {},
                  child: SizedBox(
                    height: 60,
                    child: Row(
                      children: [
                        Expanded(child: Text('Canal $i')),
                        const Icon(Icons.star_border_rounded),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(focused, equals({0}));

      for (var expected = 1; expected <= 8; expected++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 160));
        expect(focused, equals({expected}));
      }
    });
  });
}
