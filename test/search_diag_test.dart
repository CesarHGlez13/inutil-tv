import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/pelisflix_service.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/vod_catalog_service.dart';

void main() {
  test('Verify search improvements for PelisFlix, JKAnime, and Unified Catalog', () async {
    final catalog = VodCatalogService();
    final pf = PelisflixService();
    final jk = JkAnimeService();

    print('=== Testing PelisFlix search for "batman" ===');
    final pfItems = await pf.search('batman');
    print('Pelisflix items: ${pfItems.length}');
    for (final it in pfItems.take(5)) {
      print('  PF: ${it.title} (${it.genre}) [${it.slug}]');
    }
    expect(pfItems.isNotEmpty, isTrue, reason: 'Pelisflix must return items for batman');

    print('=== Testing JKAnime search for "naruto" ===');
    final jkItems = await jk.search('naruto');
    print('JKAnime items: ${jkItems.length}');
    for (final it in jkItems.take(5)) {
      print('  JK: ${it.title} [${it.slug}]');
    }
    expect(jkItems.isNotEmpty, isTrue, reason: 'JKAnime must return items for naruto');

    print('=== Testing Unified Catalog search for "dragon ball" ===');
    final dbItems = await catalog.search('dragon ball');
    print('Dragon Ball items: ${dbItems.length}');
    for (final it in dbItems.take(5)) {
      print('  CAT: ${it.title} [${it.provider}] (${it.genre})');
    }
    expect(dbItems.isNotEmpty, isTrue, reason: 'Unified catalog must return items for dragon ball');

    print('=== Testing Specialized searchMovies for "avatar" ===');
    final movies = await catalog.searchMovies('avatar');
    print('Avatar movies: ${movies.length}');
    for (final it in movies.take(3)) {
      print('  Movie: ${it.title} (${it.genre})');
    }

    print('=== Testing Specialized searchAnime for "one piece" ===');
    final animes = await catalog.searchAnime('one piece');
    print('One Piece animes: ${animes.length}');
    for (final it in animes.take(3)) {
      print('  Anime: ${it.title}');
    }
    expect(animes.isNotEmpty, isTrue, reason: 'Must find One Piece');
  });
}
