import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/vod_detail_modal.dart';

/// v3.3.21 — Experiencia Completa Crunchyroll 2026:
/// - Portada fija HD con reveal cinemático y sin canvas dinámico.
/// - Collapsing Toolbar: SliverAppBar pinned, parallax, fade-out del arte.
/// - Título de cabecera alineado a la izquierda junto a la "X".
/// - Iconos fijos de barra superior (X a la izquierda, Cast y 3-puntos a la derecha).
/// - Barra inferior flotante persistente (CTA comenzar/reproducir + Mi Lista).
/// - Fila de acciones secundarias (+ Mi Lista, Transmitir, Compartir).

String _pubspecVersion() {
  final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+\+\d+)', multiLine: true)
      .firstMatch(File('pubspec.yaml').readAsStringSync());
  expect(match, isNotNull, reason: 'pubspec.yaml sin línea version: x.y.z+n');
  return match!.group(1)!;
}

Finder titleAt(double fontSize) => find.byWidgetPredicate((w) =>
    w is Text && w.data == 'Black Clover' && w.style?.fontSize == fontSize);

Finder pinnedTitleOpacity() =>
    find.ancestor(of: titleAt(18.0), matching: find.byType(Opacity));

Finder bigTitleOpacity() =>
    find.ancestor(of: titleAt(31.0), matching: find.byType(Opacity));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrapTheme(Widget child) => MaterialApp(
        theme: AppColors.buildDarkTheme(
          accent: AppAccent.white,
          surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
        ),
        home: child,
      );

  VodItem item() => const VodItem(
        id: 'ui_v3321_bc',
        title: 'Black Clover',
        year: '2017',
        genre: 'Acción, Aventura',
        rating: '8.8',
        provider: 'poseidon',
        isAnime: true,
        isSeries: true,
      );

  group('v3.3.22/v3.3.23/v3.3.24/v3.3.25/v3.3.26/v3.3.27 — pins de versión', () {
    test('pubspec.yaml en 3.3.27+76', () {
      expect(_pubspecVersion(), '3.3.27+76');
    });

    test('lib/constants/app_info.dart en 3.3.27', () {
      expect(File('lib/constants/app_info.dart').readAsStringSync(),
          contains("static const String appVersion = '3.3.27'"));
      expect(AppInfo.appVersion, '3.3.27');
    });

    test('CHANGELOG.md documenta versiones recientes', () {
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.22'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.23'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.24'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.25'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.26'));
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.27'));
    });
  });

  group('v3.3.21 — sin canvas dinámico en el modal', () {
    test('vod_detail_modal.dart no importa LiveCanvasPreview', () {
      final src = File('lib/widgets/vod_detail_modal.dart').readAsStringSync();
      expect(src, isNot(contains('LiveCanvasPreview')),
          reason: 'el canvas dinámico fue eliminado del detalle');
      expect(src, isNot(contains('live_canvas_preview')),
          reason: 'el import fue eliminado');
      expect(src, contains('FastArtwork('));
      expect(src, contains("tier: ArtworkTier.backdrop"));
    });

    test('hero_carousel y poster_card siguen con active: false', () {
      for (final file in [
        'lib/widgets/hero_carousel.dart',
        'lib/widgets/poster_card.dart',
      ]) {
        final src = File(file).readAsStringSync();
        expect(src, contains('LiveCanvasPreview'), reason: file);
        expect(src, contains('active: false'), reason: file);
        expect(src, isNot(contains('active: true')),
            reason: '$file sigue rotando');
      }
    });
  });

  group('v3.3.21 — Collapsing Toolbar y Barra Pinned estilo Crunchyroll', () {
    testWidgets('arriba se ancla, abajo se desvanece — crossfade total',
        (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester
          .pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      expect(find.byType(SliverAppBar), findsOneWidget);
      expect(find.byType(FlexibleSpaceBar), findsOneWidget);
      expect(titleAt(18.0), findsOneWidget,
          reason: 'rótulo anclado en la barra superior');
      expect(titleAt(31.0), findsOneWidget, reason: 'rótulo grande del lienzo');

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(position.pixels, 0.0);
      expect(position.maxScrollExtent, greaterThan(100.0),
          reason: 'sin rango de scroll no se puede probar el colapso');

      const delta = 640.0 - 56.0;

      // En reposo: rótulo anclado transparente
      expect(tester.widget<Opacity>(pinnedTitleOpacity()).opacity, 0.0);

      // Rótulo grande visible
      expect(bigTitleOpacity(), findsAtLeast(1));
      final bigOpacityWidgets =
          tester.widgetList<Opacity>(bigTitleOpacity()).toList();
      expect(bigOpacityWidgets.any((o) => (o.opacity - 1.0).abs() < 1e-6), true,
          reason: 'rótulo grande opaco en reposo');

      final pinnedTopRest = tester.getTopLeft(titleAt(18.0)).dy;
      final bigTopRest = tester.getTopLeft(titleAt(31.0)).dy;
      expect(bigTopRest, greaterThan(pinnedTopRest));

      // Scroll a fondo
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();

      final k = (position.pixels / delta).clamp(0.0, 1.0);
      expect(k, greaterThan(0.30));

      // El rótulo anclado se queda en la barra superior (pinned)
      expect(tester.getTopLeft(titleAt(18.0)).dy, closeTo(pinnedTopRest, 1.0));

      // El rótulo grande del lienzo sube con el scroll
      expect(tester.getTopLeft(titleAt(31.0)).dy, lessThan(bigTopRest - 40));

      // Crossfade: anclado gana opacidad
      expect(
          tester.widget<Opacity>(pinnedTitleOpacity()).opacity,
          closeTo(Curves.easeIn.transform(((k - 0.45) / 0.55).clamp(0.0, 1.0)),
              1e-9));

      // Rótulo grande pierde opacidad
      final expectedBigOpacity = (1.0 - k * 2.5).clamp(0.0, 1.0);
      final bigOpacitiesAfter =
          tester.widgetList<Opacity>(bigTitleOpacity()).toList();
      expect(
          bigOpacitiesAfter.any(
              (o) => (o.opacity - expectedBigOpacity).abs() < 1e-6),
          true,
          reason: 'rótulo grande se desvanece al colapsar');
    });

    testWidgets('iconos fijos en cabecera: X, Cast y 3-puntos',
        (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester
          .pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);

      final closeRest = tester.getTopLeft(find.byIcon(Icons.close_rounded));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pumpAndSettle();

      final closeAfter = tester.getTopLeft(find.byIcon(Icons.close_rounded));
      expect((closeAfter.dy - closeRest.dy).abs(), lessThan(1.0),
          reason: 'la X vive en la barra anclada: no se mueve al scrollear');
    });

    testWidgets('barra flotante persistente al pie (Crunchyroll CTA)',
        (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester
          .pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      // Botón principal de reproducción al pie
      expect(find.byType(ElevatedButton), findsOneWidget);

      // Al scrollear, la barra sigue visible y anclada al pie
      final btnRest = tester.getBottomLeft(find.byType(ElevatedButton));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
      await tester.pumpAndSettle();

      final btnAfter = tester.getBottomLeft(find.byType(ElevatedButton));
      expect((btnAfter.dy - btnRest.dy).abs(), lessThan(1.0),
          reason: 'el botón CTA flota persistentemente al pie');
    });

    testWidgets('fila de acciones secundarias estilo Crunchyroll presente',
        (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester
          .pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      expect(find.text('Mi Lista'), findsAtLeast(1));
      expect(find.text('Transmitir'), findsOneWidget);
      expect(find.text('Compartir'), findsOneWidget);
    });
  });
}
