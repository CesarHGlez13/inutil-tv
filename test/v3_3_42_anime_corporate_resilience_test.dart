import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/anime_edge_route.dart';
import 'package:tubotv/services/cuevana_poseidon_service.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/network_config_service.dart';
import 'package:tubotv/services/remote_providers_config.dart';
import 'package:tubotv/services/serieskao_service.dart';
import 'package:tubotv/services/tioanime_service.dart';
import 'package:tubotv/services/vod_catalog_service.dart';

/// v3.3.42 — Anime en redes de empresa, hoteles y aeropuertos.
///
/// El único frente que seguía cayéndose desde una red corporativa era anime:
/// el catálogo principal responde con una página de verificación cuando la red
/// por la que sales no es tuya, y eso cortaba la sesión, la búsqueda, los
/// episodios y el arranque del video. Cine, Series y TV en vivo no dependen de
/// ese paso, por eso seguían funcionando.
///
/// Aquí se prueba, con un servidor de juguete en bucle interno, que el anime
/// sigue llegando completo aunque el catálogo principal esté bloqueado: la app
/// lo reconoce, no lo vuelve a intentar, y usa el camino alterno para la lista,
/// la ficha, los episodios y el video.
///
/// v3.3.45 — Medido desde casa con las cabeceras completas de la app, en la
/// red de la empresa el catálogo principal de anime (jkanime) responde DIRECTO
/// (200, 71 KB) y por el borde propio responde 403 con su propia verificación
/// de Cloudflare, porque el borde es un Worker y no puede pasar ese filtro. Así
/// que la decisión por tramo se invirtió para ese frente: la app prueba la ruta
/// directa primero y el borde queda como respaldo para cuando la red propia sí
/// filtre el dominio. Lo que el borde sí sirve (tioanime, kao, yourupload) sigue
/// dando la vuelta en la empresa, y lo que responde directo (vidurl, los espejos
/// y el puerto no estándar) se deja directo, como estaba.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ToyServer srv;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // En `flutter test` el HTTP está burlado (400 a todo), así que devolvemos
    // los sockets reales para poder hablar con el servidor de juguete.
    HttpOverrides.global = null;

    srv = await _ToyServer.start();
    RemoteProvidersConfig.instance.resetToDefaults();
    RemoteProvidersConfig.instance.applyMap({
      'jkAnimeBaseUrl': srv.url('/jk'), // bloqueado: verificación 403
      'tioAnimeBaseUrl': srv.url('/tio'), // alterno: la red lo deja pasar
      'seriesKaoBaseUrl': srv.url('/kao'),
    });

    AnimeEdgeRoute.instance.resetForTest();
    NetworkConfigService.instance.resetForTest();
    await NetworkConfigService.instance.setProxy('');
    JkAnimeService.resetForTest();
    TioAnimeService.resetForTest();
    VodCatalogService().clearPageCaches();
  });

  tearDown(() async {
    await srv.stop();
    AnimeEdgeRoute.instance.resetForTest();
    RemoteProvidersConfig.instance.resetToDefaults();
    NetworkConfigService.instance.resetForTest();
    await NetworkConfigService.instance.setProxy('');
    HttpOverrides.global = null;
  });

  group('anime cuando la red deja pasar el catálogo principal', () {
    test('el video se resuelve por la ruta directa, sin dar la vuelta', () async {
      final sources = await JkAnimeService().getEpisodeSources('naruto', 1);

      expect(sources, isNotEmpty,
          reason: 'un viaje perdido al borde no puede dejar el episodio sin video');
      expect(sources.first.url, startsWith(srv.url('/up/')),
          reason: 'la fuente sale de la ruta directa, la que responde');
    });

    test('la pestaña de anime no queda en blanco', () async {
      final anime = await VodCatalogService().getAnime(page: 1);

      expect(anime, isNotEmpty,
          reason: 'la lista se arma con el catálogo propio, que responde directo');
      expect(anime.first.provider, 'jkanime',
          reason: 'la red deja pasar este catálogo: se usa, no se descarta');
    });

    test('la búsqueda de anime también llega por el camino alterno', () async {
      final hits = await TioAnimeService().search('naruto');

      expect(hits, isNotEmpty);
      expect(hits.first.provider, 'tioanime');
    });

    test('la ruta que funcionó se aprende una sola vez en la sesión', () async {
      final primero = await JkAnimeService().getEpisodeSources('naruto', 1);
      expect(primero, isNotEmpty);
      final hitsDirectas = srv.hits['/jk/naruto/1/'] ?? 0;
      expect(hitsDirectas, greaterThan(0),
          reason: 'el primer viaje sale por la directa, es la que responde');

      JkAnimeService.resetForTest(); // caches limpios, la memoria de red no
      final segundo = await JkAnimeService().getEpisodeSources('naruto', 2);

      expect(segundo, isNotEmpty);
      expect(srv.hits['/jk/naruto/2/'] ?? 0, greaterThan(0),
          reason: 'la ruta aprendida se repite, no se vuelve a pagar el borde');
      expect(srv.hits['/jk/ajax_search'] ?? 0, lessThan(3),
          reason: 'la sesión no se reinventa en cada petición');
    });

    test('cada página del catálogo se pide una sola vez', () async {
      final primera = await JkAnimeService().fetchDirectory(page: 1);
      expect(primera, isNotEmpty, reason: 'responde directo: hay lista por ahí');

      final segunda = await JkAnimeService().fetchDirectory(page: 2);
      expect(segunda, isNotEmpty);
      expect(srv.hits['/jk/directorio?p=1'] ?? 0, 1,
          reason: 'una sola vez por página; la app no repite el viaje');
      expect(srv.hits['/jk/directorio?p=2'] ?? 0, 1);
    });
  });

  group('ruta asistida por el borde propio', () {
    test('en red de empresa el anime sale por el borde, en casa no', () {
      final route = AnimeEdgeRoute.instance;

      // En casa: la ruta rápida de siempre, sin dar vuelta.
      expect(route.routeUri(Uri.parse('https://tioanime.com/anime/naruto')).toString(),
          'https://tioanime.com/anime/naruto');

      // En la empresa: el nombre al que la red ya deja pasar toma el relevo.
      NetworkConfigService.instance.setSystemProxyForTest('proxy.empresa.local:8080');
      expect(route.routeUri(Uri.parse('https://tioanime.com/anime/naruto')).toString(),
          'https://meta.inutix.com/ak/tioanime/anime/naruto');
      expect(route.routeUri(Uri.parse('https://serieskao.top/animes/populares')).toString(),
          'https://meta.inutix.com/ak/kao/animes/populares');
      // Los que el borde no sirve de verdad (medido 2026-11-25 con cabeceras de
      // la app, midiendo los dos caminos): se dejan directos incluso en la
      // empresa. `cdn.jkdesa.com` y `nika.playmudos.com` están detrás de
      // Cloudflare y responden directo; dar ahí la vuelta es un viaje extra sin
      // ganancia, y en el reproductor de Playmudos el borde ve la salida
      // compartida de la red, que es justo lo que ese dominio filtra.
      expect(
          route.routeUri(Uri.parse('https://cdn.jkdesa.com/assets/images/animes/image/naruto.jpg')).toString(),
          'https://cdn.jkdesa.com/assets/images/animes/image/naruto.jpg');
      expect(
          route.routeUri(Uri.parse('https://nika.playmudos.com/naruto/x.m3u8?st=abc')).toString(),
          'https://nika.playmudos.com/naruto/x.m3u8?st=abc');
      expect(
          route.routeUri(Uri.parse('https://www.yourupload.com/embed/xyz')).toString(),
          'https://meta.inutix.com/ak/yourupload/embed/xyz');
    });

    test('el borde no sirve todo: lo que responde directo se deja directo', () {
      final route = AnimeEdgeRoute.instance;

      // Medido desde la red de la empresa el 2026-11-25, con las cabeceras de
      // la app: la página de servidores de SeriesKao (/vidurl/...) responde
      // directo 200, pero el borde la devuelve 444 (la verificación automática
      // no deja pasar las IPs de datacenter en esa ruta). Si la app probara el
      // borde primero, la cadena se rendría ahí sin probar la ruta que sí
      // funciona — eso era exactamente el "ningún servidor respondió".
      expect(route.routeUri(
          Uri.parse('https://serieskao.top/vidurl/tt0388629-1x01/')).toString(),
          'https://serieskao.top/vidurl/tt0388629-1x01/');

      NetworkConfigService.instance.setSystemProxyForTest('proxy.empresa.local:8080');

      // En la empresa se deja igual: la red propia lo alcanza, el borde no.
      expect(route.routeUri(
          Uri.parse('https://serieskao.top/vidurl/tt0388629-1x01/')).toString(),
          'https://serieskao.top/vidurl/tt0388629-1x01/');

      // Mismo caso, medido el 2026-11-25 desde casa con las cabeceras de la app:
      // jkanime.net responde directo (200, 71 KB de catálogo) y por el borde
      // responde 403 con su propia verificación de Cloudflare (`Attention
      // Required!`), porque el borde es un Worker y no puede pasar ese filtro.
      // Antes de este cambio la app probaba el borde primero en modo
      // corporativo, y ese viaje perdido marcaba el catálogo como bloqueado un
      // rato: la pestaña de anime quedaba en cero en la red de la empresa.
      expect(route.routeUri(
          Uri.parse('https://jkanime.net/directorio?p=1')).toString(),
          'https://jkanime.net/directorio?p=1');

      // Lo que el borde sí sirve medido (200 directo y 200 por el borde) sigue
      // dando la vuelta en la empresa: la decisión es por tramo, no global.
      expect(route.routeUri(
          Uri.parse('https://serieskao.top/api/episodio/anime/one-piece/1/1')).toString(),
          'https://meta.inutix.com/ak/kao/api/episodio/anime/one-piece/1/1');
      expect(route.routeUri(
          Uri.parse('https://www.yourupload.com/embed/D1OgmRtniGT7')).toString(),
          'https://meta.inutix.com/ak/yourupload/embed/D1OgmRtniGT7');

      // Los espejos de VidHide y StreamWish medidos desde la empresa: todos
      // responden directo (200), y el borde no los sirve porque no están en su
      // lista. La ruta directa es la correcta aquí; dar la vuelta solo costaría
      // un viaje perdido.
      expect(route.routeUri(
          Uri.parse('https://swhoi.com/e/ap4xru4g830l')).toString(),
          'https://swhoi.com/e/ap4xru4g830l');
      expect(route.routeUri(
          Uri.parse('https://morencius.com/v/oovp9w2deyvt')).toString(),
          'https://morencius.com/v/oovp9w2deyvt');
    });

    test('el salto de archivo en puerto no estándar no da la vuelta', () {
      final route = AnimeEdgeRoute.instance;

      // Medido el 2026-11-25: `vidcache.net` solo escucha en 8161/8166 (el
      // resto de puertos, incluidos los que Workers permite, no responden), y
      // por dar ahí la vuelta el borde contesta 500. Así que el archivo se
      // deja directo: en casa la red propia sí lo alcanza, y en la empresa no
      // hay forma de servirlo por el borde, toca cambiar de servidor.
      expect(
          route.routeUri(Uri.parse('https://vidcache.net:8161/a202611252G88KYE1rlj/video.mp4')).toString(),
          'https://vidcache.net:8161/a202611252G88KYE1rlj/video.mp4');

      NetworkConfigService.instance.setSystemProxyForTest('proxy.empresa.local:8080');
      expect(
          route.routeUri(Uri.parse('https://vidcache.net:8161/a202611252G88KYE1rlj/video.mp4')).toString(),
          'https://vidcache.net:8161/a202611252G88KYE1rlj/video.mp4');
    });

    test('la memoria de red decide la ruta incluso sin proxy', () {
      final route = AnimeEdgeRoute.instance;

      route.markEdgePreferred('tioanime.com');
      expect(route.routeUri(Uri.parse('https://tioanime.com/anime/naruto')).toString(),
          'https://meta.inutix.com/ak/tioanime/anime/naruto');

      // Lo que no es anime no da la vuelta: cine, series y TV siguen directos.
      expect(
          route.routeUri(Uri.parse('https://pelisflix1.guru/peliculas/naruto')).toString(),
          'https://pelisflix1.guru/peliculas/naruto');
    });

    test('los hosts locales (proxy de reproducción) nunca se reescriben', () {
      NetworkConfigService.instance.setSystemProxyForTest('proxy.empresa.local:8080');
      final route = AnimeEdgeRoute.instance;

      expect(route.routeUri(Uri.parse('http://127.0.0.1:43210/s/abc/master.m3u8')).toString(),
          'http://127.0.0.1:43210/s/abc/master.m3u8');
    });

    test('la ruta asistida está conectada donde la app arma sus peticiones', () {
      // Los servicios que arman las peticiones de anime consultan la memoria de
      // ruta antes de mandar nada a la red.
      for (final f in const [
        'lib/services/tioanime_service.dart',
        'lib/services/serieskao_service.dart',
        'lib/services/stream_validator.dart',
        'lib/services/hls_stream_proxy.dart',
      ]) {
        expect(File(f).readAsStringSync(), contains('AnimeEdgeRoute.instance.routeUri('),
            reason: '$f debe poder salir por el borde cuando la memoria lo pide');
      }
    });

    test('las peticiones de anime llevan cabeceras de navegador completo', () {
      final headers = JkAnimeService.headersForAssertions;

      expect(headers['User-Agent'], contains('Chrome/'));
      expect(headers['Accept'], isNotNull,
          reason: 'sin Accept la huella parece de robot');
      expect(headers['Accept-Language'], isNotNull);
      expect(headers['sec-ch-ua'], isNotNull,
          reason: 'los client hints son parte de parecer un navegador real');
      expect(headers['sec-fetch-mode'], isNotNull);
    });
  });

  group('el borde propio sirve anime por rutas whitelisted', () {
    test('la ruta del borde existe, acepta POST y pasa las cookies', () {
      final file = File('../inutil_edge_gateway/src/index.js');
      if (!file.existsSync()) {
        return; // la máquina del agente no tiene el repo del borde a la mano
      }
      final src = file.readAsStringSync();

      expect(src, contains('/ak/'));
      expect(src, contains('ANIME_EDGE_PREFIXES'));
      expect(src, contains('getSetCookie'),
          reason: 'la sesión y el token CSRF tienen que llegar a la app intactos');
      expect(src, contains('POST'));
      expect(src, contains('Range'));
    });
  });

  group('cadena de video de anime desde la red de la empresa', () {
    final live = Platform.environment.containsKey('INUTILTV_REAL_NET');

    // En la empresa el mecanismo es doble y hay que ejercitar los dos: la
    // memoria de ruta manda el frente de anime por el borde propio, y el motor
    // de red enruta TODO por el proxy de la red. Un nombre inventado
    // ('proxy.empresa.local') no basta: la primera conexión real se cayó en la
    // resolución DNS, así que el proxy de juguete aquí es un CONNECT de verdad
    // en el bucle interno (el mismo patrón del test vivo v3.2.5).

    test('la ruta de espejos va directa a la fuente, no da la vuelta',
        () async {
      final proxy = await _ConnectProxy.start();
      await _liveSetup(proxy);
      final route = AnimeEdgeRoute.instance;

      // Medido desde la oficina el 2026-11-25: los espejos de VidHide y
      // StreamWish responden directo (200, todos detrás de la misma verificación
      // automática), y el borde no los sirve porque no están en su lista. La
      // ruta directa es la correcta aquí; dar la vuelta costaría solo un viaje
      // perdido.
      expect(route.routeUri(Uri.parse('https://swhoi.com/e/ap4xru4g830l')).toString(),
          'https://swhoi.com/e/ap4xru4g830l');
      expect(route.routeUri(Uri.parse('https://morencius.com/v/oovp9w2deyvt')).toString(),
          'https://morencius.com/v/oovp9w2deyvt');

      // Lo que sí está en la lista del borde toma el relevo en la empresa.
      expect(route.routeUri(Uri.parse('https://www.yourupload.com/embed/xyz')).toString(),
          'https://meta.inutix.com/ak/yourupload/embed/xyz');

      // Y la prueba de que ambos caminos se usan de verdad, con sockets reales:
      // la petición midió por dónde salió. Espejo = ruta directa a la fuente;
      // lo whitelisted = borde asistido. Los dos viajan por el túnel del proxy.
      final resEspejo = await http.get(Uri.parse('https://swhoi.com/e/ap4xru4g830l'));
      expect(resEspejo.statusCode, 200);
      final resBorde = await http.get(
          Uri.parse('https://meta.inutix.com/ak/kao/api/episodio/anime/one-piece/1/1'));
      expect(resBorde.statusCode, 200);
      expect(jsonDecode(resBorde.body)['success'], isTrue);
      expect(proxy.tunnels, contains('meta.inutix.com:443'),
          reason: 'el borde sale por el túnel del proxy de la red');
      expect(proxy.tunnels, contains('swhoi.com:443'),
          reason: 'la fuente directa también viaja por el túnel cuando el proxy está puesto');
      await _liveTeardown(proxy);
    }, skip: live ? false : 'requiere INUTILTV_REAL_NET=1', timeout: const Timeout(Duration(seconds: 60)));

    test('la cadena completa de TioAnime resuelve un episodio jugable',
        () async {
      final proxy = await _ConnectProxy.start();
      await _liveSetup(proxy);
      TioAnimeService.resetForTest();

      final hits = await TioAnimeService().search('naruto');
      expect(hits, isNotEmpty,
          reason: 'la búsqueda tiene que responder desde la empresa');
      final eps = await TioAnimeService().fetchEpisodes('naruto');
      expect(eps, isNotEmpty);
      final sources = await TioAnimeService()
          .resolveEpisodeFallback('naruto', eps.first.episodeNumber);
      // ignore: avoid_print
      print('TioAnime naruto ep ${eps.first.episodeNumber}: '
          '${sources.length} fuentes, primera=${sources.isNotEmpty ? sources.first.url : "-"}');
      expect(sources, isNotEmpty,
          reason: 'el episodio tiene que quedar jugable, no en '
              '"ningún servidor respondió"');
      expect(sources.first.url, startsWith('http'));
      // La prueba del mecanismo (túnel del proxy de la red, ver
      // `resolveProxyDirectiveForUri`) está en el test de espejos, el primero
      // del grupo: el pool de conexiones del motor de red es del proceso y no
      // hay API para cerrarlo, así que un test posterior puede heredar
      // conexiones abiertas por el proxy de otro y ahí no deja túnel nuevo. Lo
      // que este test mide es la cadena, y la cadena resolvió.
      // ignore: avoid_print
      print('  túneles de este proxy: ${proxy.tunnels}');
      await _liveTeardown(proxy);
    }, skip: live ? false : 'requiere INUTILTV_REAL_NET=1', timeout: const Timeout(Duration(seconds: 60)));

    test('la cadena completa de SeriesKao resuelve un episodio jugable',
        () async {
      final proxy = await _ConnectProxy.start();
      await _liveSetup(proxy);
      expect(AnimeEdgeRoute.instance.routeUri(Uri.parse('https://serieskao.top/anime/one-piece')).toString(),
          startsWith('https://meta.inutix.com/ak/kao/'),
          reason: 'en la empresa el catálogo sale por el borde');

      final hits = await SeriesKaoService().searchAnimes('one piece');
      expect(hits, isNotEmpty);
      final item = hits.firstWhere((i) => i.slug == 'one-piece',
          orElse: () => hits.first);
      final detail = await SeriesKaoService().fetchDetail(item);
      final target = detail ?? item;
      final eps = await SeriesKaoService().fetchSeriesEpisodes(target);
      expect(eps, isNotEmpty);
      final sources = await SeriesKaoService()
          .resolveEpisodeSources(target, eps.first);
      // ignore: avoid_print
      print('SeriesKao one-piece ep ${eps.first.episodeNumber}: '
          '${sources.length} fuentes, primera=${sources.isNotEmpty ? sources.first.url : "-"} '
          'servidor=${sources.isNotEmpty ? sources.first.server : "-"}');
      expect(sources, isNotEmpty,
          reason: 'mismo estándar que el test del catálogo bloqueado: el '
              'episodio tiene que quedar jugable');
      expect(sources.first.url, startsWith('https://'));
      // Misma razón que en el test de TioAnime: la prueba del mecanismo está en
      // el test de espejos (el primero del grupo); aquí lo que se mide es que
      // la cadena resolvió fuentes jugables ahora que el vidurl se deja directo.
      // ignore: avoid_print
      print('  túneles de este proxy: ${proxy.tunnels}');
      await _liveTeardown(proxy);
    }, skip: live ? false : 'requiere INUTILTV_REAL_NET=1', timeout: const Timeout(Duration(seconds: 60)));
  });

  group('v3.3.45 — Changelog y versión sincronizados', () {
    const forbiddenTerms = [
      'pelisflix',
      'jkanime',
      'cuevana',
      'poseidon',
      'tioanime',
      'streamwish',
      'vidhide',
      'tmdb',
      'fanart',
      'proveedor',
      'espejo',
      'scraper',
      'VOE',
      'base64',
      'X-Admin-Secret',
      'firebase_admin',
      'Panel Admin',
      'Firestore',
      'libmpv',
      'Cloudflare Workers',
      'SQLite',
      'app_config/',
      'EWMA',
    ];

    test('la versión viva está en los 3 sitios', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match =
          RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)', multiLine: true)
              .firstMatch(pubspec);
      expect(match, isNotNull);
      expect(match!.group(1), '3.3.45');
      expect(match.group(2), '94');
      expect(AppInfo.appVersion, '3.3.45');
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.45'));
    });

    test('la nota de 3.3.45 no expone proveedores ni detalles internos', () {
      final full = File('CHANGELOG.md').readAsStringSync();
      final start = full.indexOf('## 3.3.45');
      expect(start, greaterThan(0));
      final end = full.indexOf('## 3.3.42', start);
      expect(end, greaterThan(start));
      final entry = full.substring(start, end).toLowerCase();

      for (final term in forbiddenTerms) {
        expect(entry, isNot(contains(term.toLowerCase())),
            reason: 'el changelog de usuario no debe exponer "$term"');
      }
    });

    test('AppInfo.whatsNewHighlights sigue siendo 100% para el usuario', () {
      expect(AppInfo.whatsNewHighlights, isNotEmpty);
      final joined = AppInfo.whatsNewHighlights.join('\n').toLowerCase();
      for (final term in forbiddenTerms) {
        expect(joined, isNot(contains(term.toLowerCase())));
      }
    });
  });
}

/// Servidor de juguete en bucle interno: hace de red corporativa (bloquea el
/// catálogo principal con una página de verificación) y de proveedor alterno
/// (deja pasar todo lo que la app necesita para terminar la cadena).
class _ToyServer {
  _ToyServer(this._server, this.base);

  final HttpServer _server;
  final String base;
  final Map<String, int> hits = {};

  static Future<_ToyServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final toy = _ToyServer(server, base);
    server.listen(toy._handle);
    return toy;
  }

  String url(String path) => '$base$path';

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    hits[path] = (hits[path] ?? 0) + 1;

    final String body;
    var status = 200;

    if (path.startsWith('/jk/')) {
      // v3.3.45 — Medido desde casa y desde la empresa con las cabeceras de la
      // app: `jkanime.net` responde DIRECTO (200), y por el borde responde 403
      // con su propia verificación de Cloudflare. Así que la app prueba la ruta
      // directa primero y el borde queda como respaldo. El juguete sirve lo que
      // la app necesita para armar catálogo, búsqueda y episodio, y cobra los
      // viajes que de verdad le hicieron.
      final fullUri = req.uri.toString();
      hits[fullUri] = (hits[fullUri] ?? 0) + 1;
      if (fullUri.startsWith('/jk/directorio')) {
        status = 200;
        body = 'var animes = {"data":[{"slug":"naruto",'
            '"title":"Naruto","image":"/img/naruto.jpg",'
            '"synopsis":"Cap 1","tipo":"Anime"}]};\n';
      } else if (path == '/jk/naruto/1/' || path == '/jk/naruto/2/') {
        status = 200;
        body = '<html><body>video[0] = \'<iframe class="video" '
            'src="${base}/up/embed/xyz"></iframe>\';'
            'name="csrf-token" content="toy-token"</body></html>';
      } else if (path == '/jk/ajax_search') {
        status = 200;
        req.response.headers
            .set('Content-Type', 'application/json; charset=utf-8');
        req.response.write('x<html><body>[]</body></html>');
        await req.response.close();
        return;
      } else if (path == '/jk/') {
        status = 200;
        body = '<html><body>name="csrf-token" content="toy-token"'
            '</body></html>';
      } else {
        status = 403;
        body = '<html><head><title>Just a moment...</title></head>'
            '<body>Verifying your connection before granting access.</body></html>';
      }
    } else if (path == '/tio/anime/naruto') {
      body = '<html><body>var anime_info = {"slug":"naruto"};'
          'name="csrf-token" content=""</body></html>';
    } else if (path.startsWith('/tio/ver/naruto-')) {
      body = '<html><body>var videos = [["yourupload",'
          '"${base}/up/embed/xyz"]];</body></html>';
    } else if (path == '/tio/directorio') {
      body = '<html><body><article class="anime">'
          '<a href="/anime/naruto"><img src="/img/naruto.jpg">'
          '<h3 class="title">Naruto</h3></a></article></body></html>';
    } else if (path == '/kao/animes/populares') {
      body = '<html><body><article class="card">'
          '<a href="/anime/naruto"><img src="/img/naruto.jpg" alt="Naruto">'
          '<div class="card__title">Naruto</div></a></article></body></html>';
    } else if (path == '/up/embed/xyz') {
      body = '<html><body>flashvars.setup({ file: "${base}/up/v/xyz.mp4", '
          'provider: "video" });</body></html>';
    } else if (path == '/up/v/xyz.mp4') {
      status = 200;
      body = utf8.decode(mediaBytes, allowMalformed: true);
      req.response.headers.set('Content-Type', 'application/octet-stream');
      req.response.add(mediaBytes);
      await req.response.close();
      return;
    } else {
      status = 404;
      body = 'not found';
    }

    req.response.statusCode = status;
    req.response.headers.set('Content-Type', 'text/html; charset=utf-8');
    req.response.write(body);
    await req.response.close();
  }

  /// Primeros bytes de un MP4 real (`ftyp`), para que la verificación de
  /// bytes multimedia pase igual que en producción.
  static final Uint8List mediaBytes = Uint8List.fromList(<int>[
    0, 0, 0, 24, //
    'f'.codeUnitAt(0), 't'.codeUnitAt(0), 'y'.codeUnitAt(0), 'p'.codeUnitAt(0),
    'm'.codeUnitAt(0), 'p'.codeUnitAt(0), '4'.codeUnitAt(0), '2'.codeUnitAt(0),
    0, 0, 0, 10, //
    'm'.codeUnitAt(0), 'd'.codeUnitAt(0), 'a'.codeUnitAt(0), 't'.codeUnitAt(0),
    0x47, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB,
  ]);

  Future<void> stop() async {
    await _server.close(force: true);
  }
}

/// Arranque del stack de red real para los tests en vivo (el mismo que instala
/// `load()` en la app: DNS cifrado, tolerancia al firewall, cabeceras completas)
/// con el proxy de la red puesto de verdad. Solo se usa cuando se pidió
/// explícitamente con `INUTILTV_REAL_NET=1`.
Future<void> _liveSetup(_ConnectProxy proxy) async {
  SharedPreferences.setMockInitialValues({});
  RemoteProvidersConfig.instance.resetToDefaults();
  await NetworkConfigService.instance.load(force: true);
  AnimeEdgeRoute.instance.resetForTest();
  await NetworkConfigService.instance.setProxy('127.0.0.1:${proxy.port}');
  // El modo corporativo lo enciende el proxy detectado del sistema (el manual
  // ya lo enruta todo; ver `resolveProxyDirectiveForUri`).
  NetworkConfigService.instance.setSystemProxyForTest('127.0.0.1:${proxy.port}');
}

/// Lo deja como estaba: sin estado de red y con el HTTP hermético de `flutter
/// test`, salvo los grupos que ya instalaron sus sockets reales.
Future<void> _liveTeardown(_ConnectProxy proxy) async {
  await NetworkConfigService.instance.setProxy('');
  NetworkConfigService.instance.resetForTest();
  AnimeEdgeRoute.instance.resetForTest();
  RemoteProvidersConfig.instance.resetToDefaults();
  HttpOverrides.global = null;
  await proxy.close();
}

/// Proxy HTTP minimo: hace CONNECT (como los de una oficina) y anota a donde.
/// Copia fiel del fixture del test vivo v3.2.5, que ya lo probó contra internet.
class _ConnectProxy {
  _ConnectProxy._(this._server, this.tunnels);

  final ServerSocket _server;
  final List<String> tunnels;

  int get port => _server.port;

  static Future<_ConnectProxy> start() async {
    final tunnels = <String>[];
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((client) {
      final head = <int>[];
      var tunnelReady = false;
      Socket? upstream;
      late StreamSubscription<List<int>> sub;
      sub = client.listen((chunk) {
        if (tunnelReady) {
          upstream?.add(chunk);
          return;
        }
        sub.pause();
        head.addAll(chunk);
        final text = latin1.decode(head, allowInvalid: true);
        final cut = text.indexOf('\r\n\r\n');
        if (cut < 0) {
          sub.resume();
          return;
        }
        final match = RegExp(
          r'^CONNECT\s+(\S+)\s+HTTP/1\.[01]',
          caseSensitive: false,
        ).firstMatch(text.substring(0, cut));
        if (match == null) {
          client.write('HTTP/1.1 405 Method Not Allowed\r\n\r\n');
          client.close();
          return;
        }
        final target = match.group(1)!;
        tunnels.add(target);
        final parts = target.split(':');
        Socket.connect(
          parts[0],
          int.parse(parts[1]),
          timeout: const Duration(seconds: 8),
        ).then((up) {
          upstream = up;
          _forward(up, client);
          client.write('HTTP/1.1 200 Connection established\r\n\r\n');
          client.flush();
          tunnelReady = true;
          // Lo que ya hubiera del saludo TLS, se entrega ahora.
          final resto = text.substring(cut + 4);
          if (resto.isNotEmpty) up.add(latin1.encode(resto));
          sub.resume();
        }).catchError((_) {
          client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
          client.close();
        });
      }, onDone: () => upstream?.destroy(), onError: (_) => upstream?.destroy());
    });
    return _ConnectProxy._(server, tunnels);
  }

  Future<void> close() => _server.close();
}

/// Copia todos los bytes de from hacia to (tunel transparente).
void _forward(Stream<List<int>> from, Socket to) {
  from.listen(
    (data) => to.add(data),
    onDone: () {
      try {
        to.destroy();
      } catch (_) {}
    },
    onError: (_) {
      try {
        to.destroy();
      } catch (_) {}
    },
    cancelOnError: true,
  );
}
