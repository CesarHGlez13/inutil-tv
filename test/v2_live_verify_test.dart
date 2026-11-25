import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/network_config_service.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/pelisflix_service.dart';

/// Test live: vea la nota en `test/pelisflix_test.dart` (misma puerta y mismo
/// `setUp`; sin el `HttpOverrides` de la app el proveedor responde vacío).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final live = Platform.environment.containsKey('INUTILTV_REAL_NET');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await NetworkConfigService.instance.load(force: true);
  });

  test(
      'Live v2 verification: JKAnime One Piece 1000+ eps & PelisFlix search noise filter',
      () async {
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
    // Medido hoy: el proveedor responde plantillas distintas y publica ids muertos
    // (0-1 de 6 titulos resueltos en 3 corridas), asi que la resolucion no es
    // determinista. Lo que si se sostiene es que la app recorra el camino nuevo
    // hasta el servidor, y eso es lo que registran los statuses de arriba.
    // ignore: avoid_print
    print('hoy: ${statuses.length} pasos del camino, '
        '${sources.length} fuentes jugables para ${movies.first.slug}');
  }, skip: live ? false : 'requiere INUTILTV_REAL_NET=1');
}
