import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/vod_detail_modal.dart';

/// v3.3.19 — Cabecera cinematográfica del modal de detalle (diseño pedido por
/// Cesar con 4 capturas de referencia de Black Clover).
///
/// Cubre lo que se puede medir sin red: la escala pura de estrellas, el alto
/// responsivo del lienzo, el reveal desde negro (con y sin "reducir
/// animaciones"), la composición centrada y los pins de versión exactos de la
/// versión viva.
String _pubspecSemver() {
  final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+', multiLine: true)
      .firstMatch(File('pubspec.yaml').readAsStringSync());
  expect(match, isNotNull, reason: 'pubspec.yaml sin línea version: x.y.z+n');
  return match!.group(1)!;
}

/// El reveal es el único `ScaleTransition` por debajo del arte (el arte es su
/// hijo directo). Los `FadeTransition` de Material son ancestros del modal
/// (route), nunca ancestros del arte, así que el ancestro del arte es el nuestro.
Finder revealScale() => find.descendant(
    of: heroArt(), matching: find.byType(ScaleTransition));

/// El FadeTransition cuyo `opacity` está gobernado por el controller del reveal
/// (los FadeTransitions de Material cuelgan de `kAlways*Animation`).
Finder revealFade() => find.byWidgetPredicate(
    (w) =>
        w is FadeTransition &&
        w.opacity is CurvedAnimation &&
        (w.opacity as CurvedAnimation).parent is AnimationController);

/// El arte de cabecera es el único SizedBox de ancho infinito del modal.
Finder heroArt() => find.byWidgetPredicate(
    (w) => w is SizedBox && w.width == double.infinity && w.height != null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrapTheme(Widget child) => MaterialApp(
        theme: AppColors.buildDarkTheme(
          accent: AppAccent.white,
          surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
        ),
        home: child,
      );

  /// Sin poster ni backdrop ⇒ cero red: el lienzo cae en `ColoredBox`.
  VodItem item({String rating = '', String provider = 'poseidon'}) => VodItem(
        id: 'ui_v3319_${rating.isEmpty ? 'nr' : rating}_$provider',
        title: 'Black Clover',
        year: '2017',
        genre: 'Acción, Aventura',
        rating: rating,
        provider: provider,
        isAnime: true,
        isSeries: true,
      );

  group('v3.3.19 — escala pura de estrellas', () {
    test('pasa el rating del proveedor (0-10) a estrellas sobre 5', () {
      expect(starsFromRating('8.8'), closeTo(4.4, 1e-9));
      expect(starsFromRating('9,5'), closeTo(4.75, 1e-9),
          reason: 'coma europea');
      expect(starsFromRating('10'), closeTo(5.0, 1e-9));
      expect(starsFromRating('7.4'), closeTo(3.7, 1e-9));
    });

    test('vacío y basura dan 0, y los extremos se recortan a 0..10', () {
      expect(starsFromRating(''), 0.0);
      expect(starsFromRating('abc'), 0.0);
      expect(starsFromRating('-4'), 0.0);
      expect(starsFromRating('13'), closeTo(5.0, 1e-9));
    });
  });

  group('v3.3.19 — versión sincronizada (pins exactos de la versión viva)', () {
    // v3.3.20: los pines exactos de la versión viva viven en
    // test/v3_3_20_collapsing_header_test.dart; aquí se comprueba la
    // SINCRONÍA (pubspec ↔ app_info ↔ CHANGELOG), que es lo que no debe romperse
    // al subir versión.
    test('pubspec, app_info y CHANGELOG van sincronizados con la versión viva',
        () {
      final v = _pubspecSemver();
      expect(v, isNotEmpty);
      expect(File('lib/constants/app_info.dart').readAsStringSync(),
          contains("static const String appVersion = '$v'"));
      expect(AppInfo.appVersion, v);
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## $v'));
      // La entrada de esta versión sigue documentada (fija, no dinámica).
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.19'));
    });

    test('inutil_music NO se tocó: sigue en 835ad61', () {
      final musicDir = File('pubspec.yaml').parent.parent;
      final pub = File('${musicDir.path}/inutil_music/pubspec.yaml');
      if (!pub.existsSync()) return; // CI sin el repo hermano
      expect(
          Process.runSync('git', ['rev-parse', '--short', 'HEAD'],
                  workingDirectory: musicDir.path)
              .stdout
              .toString()
              .trim(),
          '835ad61',
          reason: 'inutil_music debía quedar intacto en su commit');
      // Nota verificada a mano: su árbol tiene UN fichero de test modificado
      // (remote_collection_detail_page_test.dart) que ya estaba así antes de
      // esta versión. No se tocó en v3.3.19; no se commitea ni se revierte.
    });
  });

  group('v3.3.19 — lienzo responsivo y reveal desde negro', () {
    testWidgets('el alto del lienzo es 46% del alto de pantalla, con suelo',
        (tester) async {
      final sizes = {
        const Size(1080, 2400): 640.0, // techo: 46% se recorta a 640
        const Size(1080, 1391): 639.86, // justo por debajo del techo
        const Size(1080, 1300): 598.0, // zona responsiva: 46%
        const Size(1080, 700): 322.0, // móvil: sigue 46%
        const Size(1080, 600): 300.0, // por debajo del suelo ⇒ 300
      };
      for (final entry in sizes.entries) {
        tester.view.physicalSize = entry.key;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
            wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
        await tester.pumpAndSettle();

        final hero = heroArt().evaluate().single;
        expect(tester.getSize(find.byWidget(hero.widget)).height,
            closeTo(entry.value, 1.0),
            reason: 'tamaño ${entry.key}');
      }
    });

    testWidgets('con animaciones del sistema activas hay reveal y termina en 1',
        (tester) async {
      expect(tester.platformDispatcher.accessibilityFeatures.disableAnimations,
          isFalse,
          reason: 'el binding de test debe reportar animaciones activas');

      await tester.pumpWidget(
          wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pump(const Duration(milliseconds: 200));

      expect(revealFade(), findsOneWidget, reason: 'el arte debe entrar con fade');
      expect(revealScale(), findsOneWidget, reason: 'debe haber deriva de escala');
      expect(tester.widget<FadeTransition>(revealFade()).opacity.value,
          lessThan(1.0),
          reason: 'a mitad de animación todavía no es opaco del todo');
      expect(tester.widget<ScaleTransition>(revealScale()).scale.value,
          greaterThan(1.0),
          reason: 'la deriva todavía no ha bajado a 1.0');

      await tester.pumpAndSettle();
      expect(tester.widget<FadeTransition>(revealFade()).opacity.value, 1.0);
      expect(tester.widget<ScaleTransition>(revealScale()).scale.value, 1.0);
    });

    testWidgets('con "reducir animaciones" el lienzo queda estático',
        (tester) async {
      const reduced = FakeAccessibilityFeatures(disableAnimations: true);
      tester.platformDispatcher.accessibilityFeaturesTestValue = reduced;
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

      await tester.pumpWidget(
          wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      expect(revealScale(), findsNothing,
          reason: 'reducir animaciones ⇒ sin fade ni escala sobre el arte');
      expect(revealFade(), findsNothing);
      expect(heroArt().evaluate().length, 1);
    });
  });

  group('v3.3.19 — guardas de fuente del reveal', () {
    // Convención del repo (grupo 'widget y cableado' de v3.3.18): si alguien
    // mueve el timing o quita el respeto a "reducir animaciones", esto avisa.
    test('el controller del reveal mide 760 ms y sólo se crea si procede', () {
      final src = File('lib/widgets/vod_detail_modal.dart').readAsStringSync();
      expect(src, contains('Duration(milliseconds: 760)'));
      expect(src, contains('if (!_reduceMotion) {'));
      expect(src, contains('disableAnimations'));
      expect(src, contains('_reveal?.dispose()'));
    });

    test('el rótulo va dentro del lienzo y la viñeta superior está en 0.10', () {
      final src = File('lib/widgets/vod_detail_modal.dart').readAsStringSync();
      expect(src, contains('Colors.black.withValues(alpha: 0.10)'));
      expect(src, contains('stops: const [0.0, 0.42, 0.74, 1.0]'));
      expect(src, contains('bottom: 78'));
    });
  });

  group('v3.3.19 — composición centrada de la ficha', () {
    testWidgets('fila de estrellas: 5 estrellas + Media: X.X/10 sin votos',
        (tester) async {
      await tester.pumpWidget(wrapTheme(
          Scaffold(body: VodDetailModal(item: item(rating: '8.8')))));
      await tester.pumpAndSettle();

      expect(find.text('Media: 8.8/10'), findsOneWidget);
      expect(
        find.byIcon(Icons.star_rounded).evaluate().length +
            find.byIcon(Icons.star_half_rounded).evaluate().length +
            find.byIcon(Icons.star_outline_rounded).evaluate().length,
        5,
      );
      // El (393K) de la referencia es un recuento de votos que los proveedores
      // no publican: aquí no se inventa.
      expect(find.textContaining('(393K)'), findsNothing);
    });

    testWidgets('el rótulo vive dentro del lienzo y no se duplica abajo',
        (tester) async {
      await tester.pumpWidget(
          wrapTheme(Scaffold(body: VodDetailModal(item: item()))));
      await tester.pumpAndSettle();

      // v3.3.20: ahora hay DOS rótulos con el título, y es a propósito: el
      // grande sobre el lienzo (el de siempre) y el que se ancla en la barra
      // superior al colapsar (Collapsing Toolbar). Ninguno vive en el cuerpo
      // del detalle, así que siguen siendo exactamente dos.
      expect(find.text('Black Clover'), findsExactly(2));
    });

    testWidgets('sin rating real no hay fila de estrellas', (tester) async {
      // El default del modelo es '8.0', así que "sin rating real" se prueba
      // con el centinela '0.0' (el que el modal usa para no pintar estrellas).
      await tester.pumpWidget(wrapTheme(
          Scaffold(body: VodDetailModal(item: item(rating: '0.0')))));
      await tester.pumpAndSettle();

      expect(find.textContaining('Media:'), findsNothing);
    });
  });
}
