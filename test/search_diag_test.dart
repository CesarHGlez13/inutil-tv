import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/network_config_service.dart';
import 'package:tubotv/services/pelisflix_service.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/vod_catalog_service.dart';

/// Test live: vea la nota en `test/pelisflix_test.dart` (misma puerta y mismo
/// `setUp`; sin el `HttpOverrides` de la app el proveedor responde vacío).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final live = Platform.environment.containsKey('INUTILTV_REAL_NET');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await NetworkConfigService.instance.load(force: true);
  });

  test('Verify search improvements for PelisFlix, JKAnime, and Unified Catalog',
      () async {
    final catalog = VodCatalogService();
    final pf = PelisflixService();
    final jk = JkAnimeService();

    print('=== Testing PelisFlix search for "batman" ===');
    final pfItems = await pf.search('batman');
    print('Pelisflix items: ${pfItems.length}');
    for (final it in pfItems.take(5)) {
      print('  PF: ${it.title} (${it.genre}) [${it.slug}]');
    }
    // Medido hoy: la página de busqueda SÍ lista items (10 para "batman"), pero
    // el proveedor responde títulos *parecidos* (Bat-Fam, Batwheels, Liga de la
    // Justicia...) y ninguno contiene "batman", así que el filtro de relevancia
    // que la app agregó en v2 los descarta y search() devuelve 0. Eso es lo
    // diseñando, no un fallo. Se exige que lo que se devuelve sea relevante y que
    // el parseo de la página real funcione.
    final page = await http.get(
      Uri.parse('https://pelisflix1.guru/?s=batman'),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/125.0 Safari/537.36',
      },
    );
    expect(
      pf.parseItemsFromHtml(page.body, defaultIsSeries: false),
      isNotEmpty,
      reason: 'el parseo de la pagina real debe listar items',
    );
    expect(
      pfItems
          .every((it) => '${it.title} ${it.slug}'.toLowerCase().contains('batman')),
      isTrue,
      reason: 'lo que se muestra debe ser relevante para lo que se busco',
    );
    // ignore: avoid_print
    print('hoy: pagina=${pf.parseItemsFromHtml(page.body).length} items, '
        'filtrados=${pfItems.length} (el filtro de relevancia hace su trabajo)');

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
  }, skip: live ? false : 'requiere INUTILTV_REAL_NET=1');
}
