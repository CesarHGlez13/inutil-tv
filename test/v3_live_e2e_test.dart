import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/cuevana_poseidon_service.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/vod_catalog_service.dart';

void main() {
  test('LIVE E2E: PoseidonHD2/Cuevana3 Movies + Series + Real Verified Streams + JKAnime HD Search', () async {
    final cp = CuevanaPoseidonService();

    // 1. Películas recientes con metadatos TMDB reales (sin 404x, con sinopsis ES)
    final movies = await cp.fetchMovies(page: 1);
    expect(movies.length, greaterThanOrEqualTo(10));
    for (final m in movies.take(5)) {
      expect(m.poster, contains('image.tmdb.org'));
      expect(m.poster, isNot(contains('404x.jpg')));
      expect(m.overview.length, greaterThan(20));
    }

    // 2. Resolver stream REAL (Vidara HLS o Doodstream MP4 validado por bytes!)
    final movieSources = await VodCatalogService().resolveAllPlaybackSources(movies.first);
    expect(movieSources, isNotEmpty, reason: 'Película principal debe resolver stream real validado');

    // 3. Series + episodios en 1 petición + stream real del episodio 1
    final series = await cp.fetchSeries(page: 1);
    expect(series.length, greaterThanOrEqualTo(10));
    final firstSeries = series.first;
    expect(firstSeries.overview.length, greaterThan(20));
    final eps = await VodCatalogService().fetchEpisodes(firstSeries);
    expect(eps, isNotEmpty);
    final epSources = await VodCatalogService().resolveAllPlaybackSources(firstSeries, eps.first);
    expect(epSources, isNotEmpty, reason: 'Episodio 1 de serie debe resolver stream real validado');

    // 4. Búsqueda Anime tolerante a acentos ("dragón ball") + portadas HD
    final dbResults = await JkAnimeService().search('dragón ball');
    expect(dbResults.length, greaterThanOrEqualTo(5));
    for (final a in dbResults.take(5)) {
      expect(a.poster, isNot(contains('/thumbnail/')));
    }
    final dbSources = await JkAnimeService().getEpisodeSources(dbResults.first.slug, 1);
    expect(dbSources, isNotEmpty, reason: 'Anime debe resolver HLS real');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
