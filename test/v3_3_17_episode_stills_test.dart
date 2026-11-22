import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/cuevana_poseidon_service.dart';
import 'package:tubotv/services/serieskao_service.dart';

/// v3.3.17 — Miniaturas reales de episodios en Series/Anime.
///
/// SeriesKao (y TioAnime) no publican imagen por capítulo: su HTML sólo trae
/// número, título y un SVG de reproducción (medido en vivo en
/// `serieskao.top/serie/rick-and-morty`, 94 anclas `<a data-episode>` sin `<img>`).
/// El relleno se hace con los stills TMDB reales del espejo PoseidonHD2, así que
/// estas pruebas cubren las dos piezas deterministas del pipeline:
///   1. que el parse de SeriesKao deja `thumbnail` vacía (motivo del relleno), y
///   2. que el emparejamiento de títulos elige la obra correcta.
///
/// La parte de red se verificó por separado contra los servicios reales
/// (PoseidonHD2 `search` + ficha `__NEXT_DATA__` → `w300` HTTP 200, ~14.5 KB).
void main() {
  final poseidon = CuevanaPoseidonService();

  group('T1 — parse de SeriesKao: episodios sin miniatura propia', () {
    test('los anclas reales del HTML producen título pero thumbnail vacía', () {
      const html = '''
<a href="/serie/rick-and-morty#s1-e1" class="episode-item" data-episode-link data-season="1" data-episode="1">
  <span class="episode-item__number">1</span>
  <span class="episode-item__title">Piloto</span>
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" class="episode-item__icon"><path d="M8 5v14l11-7z"/></svg>
</a>
<a href="/serie/rick-and-morty#s1-e2" class="episode-item" data-episode-link data-season="1" data-episode="2">
  <span class="episode-item__number">2</span>
  <span class="episode-item__title">El cortador de césped perruno</span>
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" class="episode-item__icon"><path d="M8 5v14l11-7z"/></svg>
</a>
''';
      final eps = SeriesKaoService.parseEpisodesFromHtml(
        html,
        slug: 'rick-and-morty',
      );
      expect(eps, hasLength(2));
      expect(eps.first.title, 'Piloto');
      expect(eps.last.title, 'El cortador de césped perruno');
      // Sin relleno cruzado esto es literalmente el recuadro negro de la ficha.
      expect(eps.every((e) => e.thumbnail.isEmpty), isTrue);
      // Y ya no se inventa una duración.
      expect(eps.every((e) => e.duration.isEmpty), isTrue);
    });
  });

  group('T2 — emparejamiento de títulos para el relleno de stills', () {
    VodItem hit(String title, {bool isSeries = true}) =>
        VodItem(id: 'cp_s_$title', title: title, isSeries: isSeries);

    test('prefiere la obra exacta sobre una parecida con palabras extra', () {
      final hits = [
        hit('Rick y Morty: El Anime'),
        hit('Rick y Morty'),
        hit('Rick and Morty: Summer Meets God (Rick Meets Evil)',
            isSeries: false),
      ];
      expect(
        poseidon.pickStillsMatch(hits, 'Rick y Morty', isSeries: true)?.title,
        'Rick y Morty',
      );
    });

    test('equivale conectores bilingües (and ↔ y) sin cambiar de obra', () {
      final hits = [
        hit('Rick y Morty: El Anime'),
        hit('Rick y Morty'),
      ];
      expect(
        poseidon.pickStillsMatch(hits, 'Rick and Morty', isSeries: true)?.title,
        'Rick y Morty',
      );
    });

    test('rechaza candidatos no relacionados en vez de adivinar', () {
      final hits = [
        hit('Fullmetal Alchemist'),
        hit('Death Note'),
      ];
      expect(
        poseidon.pickStillsMatch(hits, 'Rick y Morty', isSeries: true),
        isNull,
      );
    });

    test('respeta el tipo de medio pedido (serie vs película)', () {
      final hits = [
        hit('Rick y Morty', isSeries: false),
        hit('Rick y Morty'),
      ];
      expect(
        poseidon
            .pickStillsMatch(hits, 'Rick y Morty', isSeries: true)
            ?.isSeries,
        isTrue,
      );
    });
  });
}
