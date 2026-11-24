import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/vod_detail_modal.dart';

/// v3.3.21 — Canvas dinámico eliminado; portada fija HD + crossfade completo
/// del Collapsing Toolbar (título grande se desvanece, título pinned aparece,
/// botones se apagan al colapsar).

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

/// v3.3.21: el rótulo grande AHORA lleva su propio Opacity (crossfade).
Finder bigTitleOpacity() =>
    find.ancestor(of: titleAt(31.0), matching: find.byType(Opacity));

Finder pillOpacity() => find.ancestor(
    of: find.byWidgetPredicate((w) =>
        w is Container &&
        w.margin == const EdgeInsets.only(top: 10) &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).color ==
            Colors.white.withValues(alpha: 0.4)),
    matching: find.byType(Opacity));

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

  group('v3.3.21 — pins de versión', () {
    test('pubspec.yaml en 3.3.21+70', () {
      expect(_pubspecVersion(), '3.3.21+70');
    });

    test('lib/constants/app_info.dart en 3.3.21', () {
      expect(File('lib/constants/app_info.dart').readAsStringSync(),
          contains("static const String appVersion = '3.3.21'"));
      expect(AppInfo.appVersion, '3.3.21');
    });

    test('CHANGELOG.md documenta 3.3.21', () {
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.21'));
    });
  });

  group('v3.3.21 — sin canvas dinámico en el modal', () {
    test('vod_detail_modal.dart no importa LiveCanvasPreview', () {
      final src = File('lib/widgets/vod_detail_modal.dart').readAsStringSync();
      expect(src, isNot(contains('LiveCanvasPreview')),
          reason: 'el canvas dinámico fue eliminado del detalle');
      expect(src, isNot(contains('live_canvas_preview')),
          reason: 'el import fue eliminado');
      // Siempre usa FastArtwork:
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

  group('v3.3.21 — Collapsing Toolbar crossfade completo', () {
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
          reason: 'rótulo anclado en la barra');
      expect(titleAt(31.0), findsOneWidget, reason: 'rótulo grande del lienzo');

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(position.pixels, 0.0);
      expect(position.maxScrollExtent, greaterThan(100.0),
          reason: 'sin rango de scroll no se puede probar el colapso');

      const sheet = AppColors.carbonSurface;
      const delta = 640.0 - 56.0;

      // ── Reposo: barra sin rótulo anclado, píldora visible, velo a 0.
      expect(tester.widget<Opacity>(pinnedTitleOpacity()).opacity, 0.0);
      expect(tester.widget<Opacity>(pillOpacity()).opacity, 1.0);

      // v3.3.21: el rótulo grande tiene Opacity propio, arranca en 1.0.
      expect(bigTitleOpacity(), findsAtLeast(1),
          reason: 'el rótulo grande tiene su propio Opacity ahora');
      // El Opacity más cercano al título grande debe ser 1.0 en reposo:
      final bigOpacityWidgets =
          tester.widgetList<Opacity>(bigTitleOpacity()).toList();
      // Al menos uno de los Opacity ancestros tiene la opacidad explícita del crossfade
      expect(bigOpacityWidgets.any((o) => (o.opacity - 1.0).abs() < 1e-6), true,
          reason: 'rótulo grande opaco en reposo');

      final pinnedTopRest = tester.getTopLeft(titleAt(18.0)).dy;
      final bigTopRest = tester.getTopLeft(titleAt(31.0)).dy;
      expect(bigTopRest, greaterThan(pinnedTopRest));

      // ── Scroll a fondo.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();

      final k = (position.pixels / delta).clamp(0.0, 1.0);
      expect(k, greaterThan(0.30));

      // El rótulo anclado no se mueve: pinned.
      expect(tester.getTopLeft(titleAt(18.0)).dy, closeTo(pinnedTopRest, 1.0));

      // El rótulo del lienzo sube con el contenido.
      expect(tester.getTopLeft(titleAt(31.0)).dy, lessThan(bigTopRest - 40));

      // Crossfade: el anclado gana opacidad.
      expect(
          tester.widget<Opacity>(pinnedTitleOpacity()).opacity,
          closeTo(Curves.easeIn.transform(((k - 0.45) / 0.55).clamp(0.0, 1.0)),
              1e-9));

      // El grande pierde opacidad: (1 - k*2.5) clamped.
      final expectedBigOpacity = (1.0 - k * 2.5).clamp(0.0, 1.0);
      final bigOpacitiesAfter =
          tester.widgetList<Opacity>(bigTitleOpacity()).toList();
      expect(
          bigOpacitiesAfter.any(
              (o) => (o.opacity - expectedBigOpacity).abs() < 1e-6),
          true,
          reason: 'rótulo grande se desvanece');

      // La píldora se apaga.
      expect(tester.widget<Opacity>(pillOpacity()).opacity,
          closeTo((1.0 - k * 3.2).clamp(0.0, 1.0), 1e-9));

      // El velo sube.
      expect(
          find.byWidgetPredicate((w) =>
              w is ColoredBox &&
              w.color ==
                  sheet.withValues(alpha: 0.92 * Curves.easeIn.transform(k))),
          findsOneWidget,
          reason: 'el lienzo se desvanece hacia el color de la hoja');
    });

    testWidgets('la barra anclada conserva el botón de cerrar', (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester
          .pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      final closeRest = tester.getTopLeft(find.byIcon(Icons.close_rounded));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pumpAndSettle();

      final closeAfter = tester.getTopLeft(find.byIcon(Icons.close_rounded));
      expect((closeAfter.dy - closeRest.dy).abs(), lessThan(1.0),
          reason: 'la X vive en la barra anclada: no se va al scrollear');
    });

    testWidgets('los botones se desvanecen y dejan de interceptar taps',
        (tester) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester
          .pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      // En reposo los botones están visibles.
      expect(find.text('Reproducir'), findsOneWidget);

      // Scroll a fondo.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();

      // IgnorePointer activo cuando k > 0.4.
      final ignorePointers = tester
          .widgetList<IgnorePointer>(find.byType(IgnorePointer))
          .where((ip) => ip.ignoring)
          .toList();
      expect(ignorePointers, isNotEmpty,
          reason: 'IgnorePointer activo al colapsar');
    });
  });
}
