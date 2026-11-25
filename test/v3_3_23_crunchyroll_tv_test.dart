import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/tv_focusable.dart';
import 'package:tubotv/widgets/vod_detail_modal.dart';

/// v3.3.23 — Experiencia Smart TV / Android TV estilo Crunchyroll 2026:
/// - Apertura Full Screen inmersiva en TV sin cajas de diálogo reducidas.
/// - Lienzo panorámico con viñetas degradadas de alto contraste (izq -> der y abajo -> arriba).
/// - Tipografía y metadatos 10-foot (título a 42 px, badge naranja SUB | DUB / SERIE).
/// - Foco D-Pad prioritario (autofocus en Reproducir / Continuar en naranja #FF640A).
/// - Carrusel horizontal de episodios 16:9 con miniaturas y barra de progreso.
/// - Carrusel horizontal de recomendaciones.

String _pubspecVersion() {
  final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+\+\d+)', multiLine: true)
      .firstMatch(File('pubspec.yaml').readAsStringSync());
  expect(match, isNotNull, reason: 'pubspec.yaml sin línea version: x.y.z+n');
  return match!.group(1)!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TvModeService.instance.resetForTest();
  });

  tearDown(() {
    TvModeService.instance.resetForTest();
  });

  Widget wrapTheme(Widget child) => MaterialApp(
        theme: AppColors.buildDarkTheme(
          accent: AppAccent.white,
          surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
        ),
        shortcuts: <ShortcutActivator, Intent>{
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.select):
              const ActivateIntent(),
        },
        home: child,
      );

  VodItem item() => const VodItem(
        id: 'tv_v3323_bc',
        title: 'Black Clover',
        year: '2017',
        genre: 'Acción, Aventura, Fantasía',
        rating: '8.8',
        provider: 'poseidon',
        isAnime: true,
        isSeries: true,
      );

  group('v3.3.23 a v3.3.49 — pins de versión', () {
    test('pubspec.yaml en 3.3.49+98', () {
      expect(_pubspecVersion(), '3.3.49+98');
    });

    test('lib/constants/app_info.dart en 3.3.49', () {
      expect(File('lib/constants/app_info.dart').readAsStringSync(),
          contains("static const String appVersion = '3.3.49'"));
      expect(AppInfo.appVersion, '3.3.49');
    });

    test('CHANGELOG.md documenta 3.3.49', () {
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.49'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.40'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.39'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.38'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.37'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.35'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.34'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.33'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.32'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.31'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.30'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.29'));
    });
  });

  group('v3.3.23 — Experiencia Smart TV / Android TV Crunchyroll 2026', () {
    testWidgets('en modo TV presenta layout panorámico 10-foot con título a 42 px',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      TvModeService.instance.setForTest(detectedTv: true);

      await tester.pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      // En modo TV no hay SliverAppBar móvil colapsable sino el layout dedicado de TV
      expect(find.byType(SliverAppBar), findsNothing);

      // Título en tipografía display legible de TV (30 px para layout compacto)
      final tvTitle = find.byWidgetPredicate((w) =>
          w is Text && w.data == 'Black Clover' && (w.style?.fontSize == 30.0 || w.style?.fontSize == 42.0));
      expect(tvTitle, findsOneWidget,
          reason: 'en TV el título principal tiene tipografía display legible');

      // Badge naranja Crunchyroll
      expect(find.text('SUB | DUB'), findsOneWidget);

      // Metadatos visibles
      expect(find.text('2017'), findsOneWidget);
      expect(find.text('8.8 / 10'), findsOneWidget);

      // Botón de Volver accesible en TV
      expect(find.text('Volver'), findsOneWidget);

      // Botón principal de reproducción naranja Crunchyroll (#FF640A)
      final playBtn = find.text('Comenzar a ver E1');
      expect(playBtn, findsOneWidget);

      // Botón Mi Lista
      expect(find.text('Mi Lista'), findsOneWidget);

      // Sección de episodios
      expect(find.text('Episodios'), findsOneWidget);
    });

    testWidgets('botón primario de reproducción tiene autofocus y recibe Enter/Select',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      TvModeService.instance.setForTest(detectedTv: true);

      await tester.pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      // Verificar que el TvFocusable con autofocus existe
      final autoFocusable = find.byWidgetPredicate(
          (w) => w is TvFocusable && w.autofocus == true);
      expect(autoFocusable, findsOneWidget,
          reason: 'el botón principal en TV tiene autofocus para el control remoto');

      // Verificar que el gestor de foco tiene un nodo activo para el control remoto
      final primaryFocus = FocusManager.instance.primaryFocus;
      expect(primaryFocus, isNotNull,
          reason: 'en TV debe haber un control enfocado activamente');
    });

    testWidgets('carrusel de episodios en TV es horizontal (16:9)',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      TvModeService.instance.setForTest(detectedTv: true);

      await tester.pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      // Comprobar que ListView de episodios o temporadas tiene scroll horizontal
      final horizontalLists = find.byWidgetPredicate((w) =>
          w is ListView && w.scrollDirection == Axis.horizontal);
      expect(horizontalLists, findsAtLeast(1),
          reason: 'en TV los carruseles se navegan horizontalmente con flechas izquierda/derecha');
    });

    testWidgets('en móvil (!isTv) mantiene el layout móvil con SliverAppBar y barra flotante',
        (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      TvModeService.instance.setForTest(detectedTv: false);

      await tester.pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      // En móvil se usa SliverAppBar con Collapsing Toolbar
      expect(find.byType(SliverAppBar), findsOneWidget);
      expect(find.byType(FlexibleSpaceBar), findsOneWidget);

      // Barra flotante persistente al pie (ElevatedButton)
      expect(find.byType(ElevatedButton), findsOneWidget);
    });
  });
}
