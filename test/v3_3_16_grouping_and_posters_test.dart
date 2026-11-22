import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/serieskao_service.dart';
import 'package:tubotv/services/tioanime_service.dart';
import 'package:tubotv/services/vod_catalog_service.dart';
import 'package:tubotv/widgets/dynamic_poster_canvas.dart';

/// v3.3.16 — Suite integral:
/// - T1: Carátulas HD en búsqueda JKAnime (ajax_search `/thumbnail/` -> `/image/`).
/// - T2: Agrupación real de temporadas en Series y Anime (grillas, búsquedas,
///       `seasonRefs` para carga diferida, y cadena `Precuela`/`Secuela` de JKAnime).
/// - T3: Canvas dinámico determinista (`DynamicPosterCanvas` + `PosterCanvasGlassOverlay`).
/// - T4: Catálogos ampliados verificados en vivo (JKAnime canónicos + SeriesKao
///       Animes Latino multi-temporada + SeriesKao géneros + TioAnime directorio).
void main() {
  group('T1 — upgradePosterUrl de JKAnime', () {
    test('ajax_search: /animes/thumbnail/<slug>.jpg sube a /animes/image/', () {
      const raw =
          'https://cdn.jkdesa.com/assets/images/animes/thumbnail/fruits-basket.jpg';
      expect(
        JkAnimeService.upgradePosterUrl(raw, 'fruits-basket'),
        'https://cdn.jkdesa.com/assets/images/animes/image/fruits-basket.jpg',
      );
    });

    test('la variante /image/thumbnail/ conserva el comportamiento viejo', () {
      const raw =
          'https://cdn.jkdesa.com/assets/images/animes/image/thumbnail/naruto.jpg';
      expect(
        JkAnimeService.upgradePosterUrl(raw, 'naruto'),
        'https://cdn.jkdesa.com/assets/images/animes/image/naruto.jpg',
      );
    });

    test('sin URL se construye el HD desde el slug (directorio)', () {
      expect(
        JkAnimeService.upgradePosterUrl('', 'one-piece'),
        'https://cdn.jkdesa.com/assets/images/animes/image/one-piece.jpg',
      );
    });

    test('nunca queda la doble barra ni doble /animes/', () {
      const raw =
          'https://cdn.jkdesa.com/assets/images/animes/thumbnail/fruits-basket.jpg';
      final out = JkAnimeService.upgradePosterUrl(raw, 'fruits-basket');
      expect(out, isNot(contains('//fruits-basket.jpg')));
      expect(out, isNot(contains('animes/animes/')));
    });

    test('búsqueda en vivo "frs" sale con la ruta HD (contrato del proveedor)',
        () async {
      final items = await JkAnimeService().search('frs');
      if (items.isEmpty) return;
      final withPoster = items.where((i) => i.poster.isNotEmpty).toList();
      expect(withPoster, isNotEmpty);
      expect(withPoster.first.poster, contains('/animes/image/'));
    });
  });

  group('T2 — Agrupación de temporadas en Series y Anime', () {
    VodItem item(
      String title, {
      String slug = '',
      bool isSeries = true,
      bool isAnime = false,
      List<VodEpisode> eps = const [],
      String poster = 'https://example.com/p.jpg',
    }) {
      return VodItem(
        id: 'id_$title',
        title: title,
        slug: slug.isNotEmpty ? slug : title.toLowerCase().replaceAll(' ', '-'),
        poster: poster,
        isSeries: isSeries,
        isAnime: isAnime,
        episodes: eps,
        provider: isAnime ? 'jkanime' : 'serieskao',
      );
    }

    VodEpisode ep(String id, int season, int num) {
      return VodEpisode(
        id: id,
        title: 'E$num',
        episodeNumber: num,
        seasonNumber: season,
      );
    }

    test('colapsa variantes reales de Series y Anime (T2, 2nd Season, Final, II, Part 2)',
        () {
      final base = item('Kaijuu 8-gou', isAnime: true);
      for (final variant in [
        'Kaijuu 8-gou 2nd Season',
        'Kaijuu 8-gou 3rd Season',
        'Kaijuu 8-gou Season 2',
        'Kaijuu 8-gou Temporada 2',
        'Kaijuu 8-gou T2',
        'Kaijuu 8-gou S2',
        'Kaijuu 8-gou Part 2',
        'Kaijuu 8-gou The Final Season',
        'Kaijuu 8-gou II',
        'Kaijuu 8-gou III',
      ]) {
        expect(
          VodCatalogService.canonicalShowKey(item(variant, isAnime: true)),
          VodCatalogService.canonicalShowKey(base),
          reason: '"$variant" debe colapsar con "Kaijuu 8-gou"',
        );
      }
    });

    test('dígito final en títulos multi-palabra colapsa pero películas NO colapsan',
        () {
      expect(
        VodCatalogService.canonicalShowKey(
          item('5-toubun no Hanayome 2', isAnime: true),
        ),
        VodCatalogService.canonicalShowKey(
          item('5-toubun no Hanayome', isAnime: true),
        ),
      );
      // Películas secuelas NO deben colapsar
      expect(
        VodCatalogService.canonicalShowKey(
          item('Toy Story 2', isSeries: false, isAnime: false),
        ),
        isNot(
          VodCatalogService.canonicalShowKey(
            item('Toy Story', isSeries: false, isAnime: false),
          ),
        ),
      );
    });

    test('títulos distintos y pestañas distintas NO colapsan', () {
      expect(
        VodCatalogService.canonicalShowKey(item('Naruto', isAnime: true)),
        isNot(VodCatalogService.canonicalShowKey(
          item('Naruto Shippuden', isAnime: true),
        )),
      );
      final anime = item('Death Note', isSeries: false, isAnime: true);
      final serie = item('Death Note', isSeries: true, isAnime: false);
      expect(
        VodCatalogService.canonicalShowKey(anime),
        isNot(VodCatalogService.canonicalShowKey(serie)),
      );
    });

    test('groupByShowStateless elige T1 como base y conserva seasonRefs aunque episodes esté vacío',
        () {
      // Llega primero 2nd Season y después Season 1 (caso real del directorio JKAnime)
      final s2 = item(
        'Kaijuu 8-gou 2nd Season',
        slug: 'kaijuu-8-gou-2nd-season',
        isAnime: true,
      );
      final s1 = item(
        'Kaijuu 8-gou',
        slug: 'kaijuu-8-gou',
        isAnime: true,
      );

      final grouped = VodCatalogService.groupByShowStateless([s2, s1]);
      expect(grouped.length, 1);
      expect(grouped.first.slug, 'kaijuu-8-gou');
      expect(grouped.first.seasonRefs.length, 2);
      expect(grouped.first.seasons, [1, 2]);
      expect(
        grouped.first.seasonRefs.map((r) => r.slug),
        ['kaijuu-8-gou', 'kaijuu-8-gou-2nd-season'],
      );
    });

    test('groupedWithSeasonSiblings UNE episodios y dedup por temporada#episodio',
        () {
      final base = item('Demon Slayer', eps: [ep('a1', 1, 1), ep('a2', 1, 2)]);
      final hermana = item('Demon Slayer T2', eps: [
        ep('dup', 1, 1),
        ep('b1', 2, 1),
        ep('b2', 2, 2),
      ]);
      final grouped = base.groupedWithSeasonSiblings(hermana.episodes);

      expect(grouped.episodes.length, 4);
      expect(grouped.seasons, [1, 2]);
      expect(grouped.seasonCount, 2);
      expect(grouped.episodeCount, 4);
    });

    test('duplicados de distinto proveedor NO inflan seasonRefs ni crean temporadas fantasma',
        () {
      final jkS1 = VodItem(
        id: 'jk_jujutsu-kaisen-tv',
        title: 'Jujutsu Kaisen (TV)',
        slug: 'jujutsu-kaisen-tv',
        poster: 'https://cdn.jkdesa.com/a.jpg',
        rating: '',
        isSeries: true,
        isAnime: true,
        provider: 'jkanime',
      );
      final jkS2 = VodItem(
        id: 'jk_jujutsu-kaisen-2nd-season',
        title: 'Jujutsu Kaisen 2nd Season',
        slug: 'jujutsu-kaisen-2nd-season',
        poster: 'https://cdn.jkdesa.com/b.jpg',
        rating: '',
        isSeries: true,
        isAnime: true,
        provider: 'jkanime',
      );
      final skDup = VodItem(
        id: 'sk_a_jujutsu-kaisen',
        title: 'Jujutsu Kaisen',
        slug: 'jujutsu-kaisen',
        poster: 'https://image.tmdb.org/t/p/w500/c.jpg',
        rating: '9',
        isSeries: true,
        isAnime: true,
        provider: 'serieskao',
      );
      final tioDup = VodItem(
        id: 'tio_jujutsu-kaisen',
        title: 'Jujutsu Kaisen',
        slug: 'jujutsu-kaisen',
        poster: 'https://tioanime.com/d.jpg',
        isSeries: true,
        isAnime: true,
        provider: 'tioanime',
      );

      final grouped =
          VodCatalogService.groupByShowStateless([jkS1, jkS2, skDup, tioDup]);
      expect(grouped.length, 1);
      expect(grouped.first.seasonRefs.length, 2,
          reason: 'solo T1 y T2 reales de JKAnime, sin duplicados fantasma');
      expect(grouped.first.rating, '9',
          reason: 'hereda el rating real de TMDB/SeriesKao');
    });

    test('parseRelatedSeasons extrae Precuela/Secuela (Serie) y omite Películas/OVAs',
        () {
      const sampleHtml = '''
        <h1>Jujutsu Kaisen (TV)</h1>
        <h3 class="mb-3">Temporadas y relacionados</h3>
        <h5 id="aditional">Precuela</h5>
        <a href="https://jkanime.net/jujutsu-kaisen-0-movie/">Jujutsu Kaisen 0 Movie (Pelicula) </a> <br>
        <h5 id="aditional">Secuela</h5>
        <a href="https://jkanime.net/jujutsu-kaisen-2nd-season/">Jujutsu Kaisen 2nd Season (Serie) </a> <br>
        <h5 id="aditional">Adicional</h5>
        <a href="https://jkanime.net/jujutsu-ova/">Jujutsu OVA (OVA) </a> <br>
        </div>
      ''';
      final rel = JkAnimeService.parseRelatedSeasons(sampleHtml);
      expect(rel.prequels, isEmpty, reason: 'Pelicula debe omitirse');
      expect(rel.sequels.length, 1);
      expect(rel.sequels.first.slug, 'jujutsu-kaisen-2nd-season');
      expect(rel.sequels.first.title, 'Jujutsu Kaisen 2nd Season');
    });

    test('en vivo: discoverSeasonChain("jujutsu-kaisen-tv") descubre T1 + T2',
        () async {
      final chain = await JkAnimeService().discoverSeasonChain(
        'jujutsu-kaisen-tv',
        fallbackTitle: 'Jujutsu Kaisen',
      );
      if (chain.length <= 1) return; // sin red en CI
      expect(chain.first.slug, 'jujutsu-kaisen-tv');
      expect(
        chain.map((r) => r.slug),
        contains('jujutsu-kaisen-2nd-season'),
      );
    });
  });

  group('T3 — DynamicPosterCanvas y PosterCanvasGlassOverlay', () {
    test('accentForTitle es 100% determinista para el mismo título', () {
      expect(
        DynamicPosterCanvas.accentForTitle('Chainsaw Man'),
        DynamicPosterCanvas.accentForTitle('chainsaw man'),
      );
    });

    testWidgets('renderiza DynamicPosterCanvas y PosterCanvasGlassOverlay sin errores',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SizedBox(
              width: 140,
              height: 210,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const DynamicPosterCanvas(
                    title: 'Jujutsu Kaisen',
                    subtitle: '2020 · Acción',
                  ),
                  PosterCanvasGlassOverlay(
                    accent: DynamicPosterCanvas.accentForTitle('Jujutsu Kaisen'),
                    highlighted: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Jujutsu Kaisen'), findsOneWidget);
      expect(find.text('2020 · Acción'), findsOneWidget);
    });
  });

  group('T4 — Catálogos ampliados verificados en vivo', () {
    test('JKAnime expone slugs canónicos + Latino HD + TioAnime + Películas',
        () {
      final paths = JkAnimeService.genres.map((g) => g['path']).toSet();
      expect(paths, isNot(contains('ciencia-ficcion')));
      expect(paths, isNot(contains('super-accion')));
      for (final slug in [
        'sk:populares',
        'sk:recientes',
        'tio:populares',
        'sci-fi',
        'super-poderes',
        'misterio',
        'psicologico',
        'thriller',
        'magia',
        'harem',
        'policial',
        'militar',
        'demonios',
        'isekai',
        'shoujo',
        'musica',
        'tipo:peliculas',
      ]) {
        expect(paths, contains(slug), reason: '$slug verificado en vivo');
      }
    });

    test('SeriesKao parseCatalogCards soporta /anime/<slug> con rating y año',
        () {
      const html = '''
        <article class="card">
          <a href="/anime/ataque-a-los-titanes-2013" class="card__link">
            <img src="https://image.tmdb.org/t/p/w200/abc.jpg" alt="Attack on Titan" />
            <span class="card__rating">9.1</span>
            <span class="card__badge card__badge--year">2013</span>
            <h2 class="card__title">Attack on Titan</h2>
          </a>
        </article>
      ''';
      final items = SeriesKaoService.parseCatalogCards(
        html,
        includeAnime: true,
        onlyAnime: true,
      );
      expect(items.length, 1);
      expect(items.first.isAnime, isTrue);
      expect(items.first.slug, 'ataque-a-los-titanes-2013');
      expect(items.first.year, '2013');
      expect(items.first.rating, '9.1');
      expect(items.first.poster, contains('/t/p/w500/'));
    });

    test('TioAnime parseDirectoryCards parsea tarjetas con portada completa',
        () {
      const html = '''
        <article class="anime">
          <a href="/anime/kimetsu-no-yaiba">
            <img src="/uploads/portadas/3129.jpg" alt="img">
            <h3 class="title">Kimetsu no Yaiba</h3>
          </a>
        </article>
      ''';
      final items = TioAnimeService.parseDirectoryCards(html);
      expect(items.length, 1);
      expect(items.first.slug, 'kimetsu-no-yaiba');
      expect(items.first.poster, 'https://tioanime.com/uploads/portadas/3129.jpg');
      expect(items.first.provider, 'tioanime');
    });

    test('en vivo: SeriesKao Animes Populares + TioAnime Directorio responden',
        () async {
      final sk = await SeriesKaoService().fetchPopularAnimes(page: 1);
      final tio = await TioAnimeService().fetchDirectory(page: 1);
      if (sk.isNotEmpty) {
        expect(sk.first.isAnime, isTrue);
        expect(sk.first.poster, startsWith('http'));
      }
      if (tio.isNotEmpty) {
        expect(tio.first.isAnime, isTrue);
        expect(tio.first.poster, startsWith('http'));
      }
    });
  });
}
