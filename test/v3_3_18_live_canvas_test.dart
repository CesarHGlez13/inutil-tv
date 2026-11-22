import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/widgets/live_canvas_preview.dart';

/// v3.3.18 — Canvas en vivo estilo Spotify.
///
/// El selector de stills destacados tiene que ser puro y determinista (misma
/// obra ⇒ mismos planos, sin red), y las pantallas que lo consumen están
/// cubiertas por guardas de fuente: si alguien quita el cableado del widget,
/// esta suite lo avisa.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  VodEpisode ep(int season, int num, String thumb) => VodEpisode(
        id: '${season}x$num',
        title: 'E$num',
        seasonNumber: season,
        episodeNumber: num,
        thumbnail: thumb,
      );

  group('v3.3.18 — selector determinista de stills destacados', () {
    test('ordena por temporada/episodio antes de repartir los picks', () {
      final desordenadas = [
        ep(2, 3, 'u://t2x3'),
        ep(1, 2, 'u://t1x2'),
        ep(1, 1, 'u://t1x1'),
        ep(2, 1, 'u://t2x1'),
      ];
      final ordenadas = [
        ep(1, 1, 'u://t1x1'),
        ep(1, 2, 'u://t1x2'),
        ep(2, 1, 'u://t2x1'),
        ep(2, 3, 'u://t2x3'),
      ];
      expect(
        VodItem.selectHighlightStills(desordenadas),
        VodItem.selectHighlightStills(ordenadas),
      );
    });

    test('es estable ante el orden de llegada (determinista)', () {
      final base = [for (var i = 1; i <= 12; i++) ep(1, i, 'u://e$i')];
      final esperado = VodItem.selectHighlightStills(base);
      expect(esperado.length, 4);
      expect(VodItem.selectHighlightStills(base.reversed.toList()), esperado);
      expect(
        VodItem.selectHighlightStills(<VodEpisode>[
          base[5],
          base[0],
          base[11],
          base[3],
          base[7],
          base[1],
          base[9],
          base[2],
          base[10],
          base[4],
          base[8],
          base[6],
        ]),
        esperado,
      );
    });

    test('quita URLs repetidas y nunca devuelve entradas vacías', () {
      final conDups = [
        ep(1, 1, 'u://a'),
        ep(1, 2, 'u://a'),
        ep(1, 3, ''),
        ep(1, 4, 'u://b'),
        ep(1, 5, 'u://b'),
        ep(1, 6, 'u://c'),
      ];
      final picks = VodItem.selectHighlightStills(conDups);
      expect(picks, containsAll(<String>['u://a', 'u://b', 'u://c']));
      expect(picks.toSet().length, picks.length, reason: 'sin duplicados');
      expect(picks, isNot(contains('')));
    });

    test('reparte a lo largo de la obra, no sólo toma el arranque', () {
      final cien = [for (var i = 1; i <= 100; i++) ep(1, i, 'u://e$i')];
      final picks = VodItem.selectHighlightStills(cien);
      expect(picks.length, 4);
      // Reparto 1º / ~⅓ / ~⅔ / último sobre las 100 únicas.
      expect(picks, <String>['u://e1', 'u://e34', 'u://e67', 'u://e100']);
    });

    test('max: 1 deja sólo el primero y sin episodios devuelve vacío', () {
      final tres = [ep(1, 1, 'u://a'), ep(1, 2, 'u://b'), ep(1, 3, 'u://c')];
      expect(VodItem.selectHighlightStills(tres, max: 1), <String>['u://a']);
      expect(VodItem.selectHighlightStills(const []), isEmpty);
      expect(
          VodItem.selectHighlightStills(tres),
          <String>[
            'u://a',
            'u://b',
            'u://c',
          ],
          reason: 'menos que max => todos');
    });
  });

  group('v3.3.18 — modelo y persistencia del campo', () {
    test('toJson/fromJson conservan highlightStills y omiten el campo vacío',
        () {
      const conStills = VodItem(
        id: 'x1',
        title: 'Black Clover',
        highlightStills: ['u://a', 'u://b'],
      );
      final json = conStills.toJson();
      expect((json['highlightStills'] as List).cast<String>(), <String>[
        'u://a',
        'u://b',
      ]);
      expect(
          VodItem.fromJson(json).highlightStills, <String>['u://a', 'u://b']);

      const sinStills = VodItem(id: 'x2', title: 'Sin stills');
      expect(sinStills.toJson().containsKey('highlightStills'), isFalse);
      expect(VodItem.fromJson(sinStills.toJson()).highlightStills, isEmpty);
    });

    test('los merges priorizan el campo explícito y si no, lo derivan', () {
      final base = VodItem(
        id: 'x3',
        title: 'El Internado',
        episodes: [ep(1, 1, 'u://p1'), ep(1, 2, 'u://p2')],
      );
      const enriquecidoConCampo = VodItem(
        id: 'x3',
        title: 'El Internado',
        episodes: [],
        highlightStills: ['u://q1', 'u://q2'],
      );
      // El item enriquecido manda cuando trae el campo explícito.
      expect(
        base.mergedWith(enriquecidoConCampo).highlightStills,
        <String>['u://q1', 'u://q2'],
      );

      // Si nadie lo trae explícito, se rellena desde los episodios (los stills
      // que el relleno cruzado de v3.3.17 ya puso en `episode.thumbnail`).
      const enriquecidoSinCampo = VodItem(id: 'x3', title: 'El Internado');
      final merged = base.mergedWith(enriquecidoSinCampo);
      expect(merged.highlightStills, isNotEmpty);
      expect(
        merged.highlightStills,
        VodItem.selectHighlightStills(merged.episodes),
      );
    });
  });

  group('v3.3.18 — widget y cableado', () {
    testWidgets('sin stills cae en el arte generado (nunca recuadro negro)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          home: const Scaffold(
            body: SizedBox(
              height: 220,
              width: 160,
              child: LiveCanvasPreview(title: 'Sin stills', active: true),
            ),
          ),
        ),
      );
      expect(find.byType(LiveCanvasPreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('poster_card usa LiveCanvasPreview en foco/long-press', () {
      expect(
        File('lib/widgets/poster_card.dart').readAsStringSync(),
        contains('LiveCanvasPreview'),
      );
    });

    test('hero_carousel rota los destacados con LiveCanvasPreview', () {
      expect(
        File('lib/widgets/hero_carousel.dart').readAsStringSync(),
        contains('LiveCanvasPreview'),
      );
    });

    test('el modal de detalle lleva cabecera con LiveCanvasPreview', () {
      expect(
        File('lib/widgets/vod_detail_modal.dart').readAsStringSync(),
        contains('LiveCanvasPreview'),
      );
    });
  });

  group('v3.3.18 — versión sincronizada en los 3 sitios', () {
    test('pubspec.yaml en 3.3.18+67', () {
      expect(
          File('pubspec.yaml').readAsStringSync(),
          contains(
            'version: 3.3.18+67',
          ));
    });

    test('lib/constants/app_info.dart en 3.3.18', () {
      expect(
          File('lib/constants/app_info.dart').readAsStringSync(),
          contains(
            "static const String appVersion = '3.3.18'",
          ));
    });

    test('CHANGELOG.md documenta 3.3.18', () {
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.18'));
    });
  });
}
