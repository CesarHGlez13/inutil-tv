import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/vod_detail_modal.dart';

/// v3.3.20 — Canvas con calidad fija + Collapsing Toolbar en el modal de detalle
/// (lo que Cesar pidió con las capturas de Black Clover: el arte se desvanece,
/// el rótulo sube y se ancla en la barra superior con los iconos fijos).
///
/// Los widgets de test no tienen red, así que aquí se mide lo que se puede medir
/// sin ella: los pins de versión, las guardas de fuente de los tres call sites
/// del canvas y el comportamiento real del colapso (arriba anclado, abajo se
/// va) con drags de tamaño controlado.
String _pubspecVersion() {
  final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+\+\d+)', multiLine: true)
      .firstMatch(File('pubspec.yaml').readAsStringSync());
  expect(match, isNotNull, reason: 'pubspec.yaml sin línea version: x.y.z+n');
  return match!.group(1)!;
}

/// Los dos rótulos se distinguen por tamaño de fuente: 18 px el que se ancla
/// (móvil) y 31 px el grande del lienzo.
Finder titleAt(double fontSize) => find.byWidgetPredicate((w) =>
    w is Text && w.data == 'Black Clover' && w.style?.fontSize == fontSize);

Finder pinnedTitleOpacity() =>
    find.ancestor(of: titleAt(18.0), matching: find.byType(Opacity));

/// El rótulo grande no lleva `Opacity` propio (se desvanece con el velo del
/// lienzo, que va por debajo de él en el Stack), así que este finder debe estar
/// vacío: sirve para documentar dónde está el fade de cada capa.
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

/// Velo dinámico del lienzo: el único `ColoredBox` cuyo color es el fondo de la
/// hoja con alfa al máximo de la curva (0.92).
Finder fullVeil() => find.byWidgetPredicate(
    (w) => w is ColoredBox && (w.color.a - 0.92).abs() < 1e-6);

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
        id: 'ui_v3320_bc',
        title: 'Black Clover',
        year: '2017',
        genre: 'Acción, Aventura',
        rating: '8.8',
        provider: 'poseidon',
        isAnime: true,
        isSeries: true,
      );

  group('v3.3.20 — pins exactos de la versión viva', () {
    test('pubspec.yaml en 3.3.20+69', () {
      expect(_pubspecVersion(), '3.3.20+69');
    });

    test('lib/constants/app_info.dart en 3.3.20', () {
      expect(File('lib/constants/app_info.dart').readAsStringSync(),
          contains("static const String appVersion = '3.3.20'"));
      expect(AppInfo.appVersion, '3.3.20');
    });

    test('CHANGELOG.md documenta 3.3.20', () {
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.20'));
    });
  });

  group('v3.3.20 — canvas con calidad fija (guardas de fuente)', () {
    // Los stills del proveedor llegan a w300 de TMDB: en un lienzo grande se
    // ven borrosos, así que los tres call sites quedan en arte fijo de tier
    // alta. El motor de rotación sigue vivo (lo prueba v3_3_18), pero en la app
    // ya no se alimenta con basura.
    test('los tres call sites del canvas quedan en active: false', () {
      for (final file in [
        'lib/widgets/vod_detail_modal.dart',
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

  group('v3.3.20 — Collapsing Toolbar del modal de detalle', () {
    test('el detalle es un CustomScrollView con SliverAppBar pinned', () {
      final src = File('lib/widgets/vod_detail_modal.dart').readAsStringSync();
      expect(src, contains('CustomScrollView('));
      expect(src, contains('SliverAppBar('));
      expect(src, contains('pinned: true'));
      expect(src, contains('expandedHeight: heroH'));
      expect(src, contains('collapsedHeight: kToolbarHeight'));
      expect(src, contains('CollapseMode.parallax'));
      expect(src, contains('SliverList('));
      // Los iconos fijos van en actions: de la barra anclada, no dentro del lienzo.
      expect(src, contains('actions: ['));
    });

    testWidgets('arriba se ancla, abajo se desvanece', (tester) async {
      // Ventana alta y angosta: el lienzo llega al techo del clamp (640) y el
      // contenido (sin episodios en test) es corto, así que el scroll máximo
      // deja la barra colapsada a ~40%: suficiente para medir, no al 100%.
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

      // El modal no trae controller en test (lo inyecta el sheet), así que el
      // Scrollable crea su PrimaryScrollController y la posición es del estado.
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(position.pixels, 0.0);
      expect(position.maxScrollExtent, greaterThan(100.0),
          reason: 'sin rango de scroll no se puede probar el colapso');

      const sheet = AppColors.carbonSurface;
      const delta = 640.0 - 56.0;

      // ── Reposo: barra sin rótulo anclado, píldora visible, velo del lienzo a 0.
      expect(tester.widget<Opacity>(pinnedTitleOpacity()).opacity, 0.0);
      expect(tester.widget<Opacity>(pillOpacity()).opacity, 1.0);
      expect(
          find.byWidgetPredicate((w) =>
              w is ColoredBox && w.color == sheet.withValues(alpha: 0.0)),
          findsOneWidget,
          reason: 'el velo del lienzo nace transparente');

      final pinnedTopRest = tester.getTopLeft(titleAt(18.0)).dy;
      final bigTopRest = tester.getTopLeft(titleAt(31.0)).dy;
      expect(bigTopRest, greaterThan(pinnedTopRest),
          reason: 'en reposo el rótulo grande está por debajo del anclado');

      // ── Scroll a fondo: la barra se encoge y se queda anclada arriba.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();

      final k = (position.pixels / delta).clamp(0.0, 1.0);
      expect(k, greaterThan(0.30),
          reason: 'debe colapsar lo bastante para medir');

      // Lo pedido, literal: el rótulo se queda ANCLADO arriba mientras el
      // contenido sube y el lienzo se desvanece.
      expect(tester.getTopLeft(titleAt(18.0)).dy, closeTo(pinnedTopRest, 1.0),
          reason: 'el rótulo anclado no se mueve: es pinned');
      expect(tester.getTopLeft(titleAt(31.0)).dy, lessThan(bigTopRest - 40),
          reason:
              'el rótulo del lienzo sube con el contenido (menos el parallax)');

      // Crossfade: el anclado gana opacidad con la fracción de colapso, el
      // grande y la píldora la pierden, y el velo del lienzo sube.
      expect(
          tester.widget<Opacity>(pinnedTitleOpacity()).opacity,
          closeTo(Curves.easeIn.transform(((k - 0.45) / 0.55).clamp(0.0, 1.0)),
              1e-9),
          reason: 'el rótulo anclado sigue la fracción de colapso real');
      expect(bigTitleOpacity(), findsNothing,
          reason: 'el rótulo grande no se apaga solo: lo oscurece el velo');
      expect(tester.widget<Opacity>(pillOpacity()).opacity,
          closeTo((1.0 - k * 3.2).clamp(0.0, 1.0), 1e-9));
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
      expect(closeAfter.dx, greaterThan(closeRest.dx - 1),
          reason: 'sigue a la derecha');
    });
  });
}
