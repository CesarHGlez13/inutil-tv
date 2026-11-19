import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/pelisflix_service.dart';

void main() {
  test('Live v2 verification: JKAnime One Piece 1000+ eps & PelisFlix search noise filter', () async {
    final jk = JkAnimeService();
    final onePieceEps = await jk.fetchEpisodes('one-piece');
    expect(onePieceEps.length, greaterThan(1000));

    final pf = PelisflixService();
    // Breaking Bad ya no debe devolver "Padre de Familia"
    final bb = await pf.search('breaking bad');
    for (final it in bb) {
      expect(it.title.toLowerCase().contains('padre de familia'), isFalse);
    }

    // Multi-servidor de película real en PelisFlix
    final movies = await pf.fetchMovies(page: 1);
    expect(movies, isNotEmpty);
    final statuses = <String>[];
    final sources = await pf.resolveAllStreamSources(
      movies.first.slug,
      onStatus: statuses.add,
    );
    expect(statuses, isNotEmpty);
    expect(sources, isNotEmpty);
  });
}
