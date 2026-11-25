import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/services/anime_edge_route.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/network_config_service.dart';
import 'package:tubotv/services/remote_providers_config.dart';
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

  group('anime cuando la red bloquea el catálogo principal', () {
    test('el video sigue resolviéndose por el camino alterno', () async {
      final sources = await JkAnimeService().getEpisodeSources('naruto', 1);

      expect(sources, isNotEmpty,
          reason: 'un bloqueo en la red no puede dejar el episodio sin video');
      expect(sources.first.url, startsWith(srv.url('/up/')),
          reason: 'la fuente debe venir del proveedor alterno, no del bloqueado');
    });

    test('la pestaña de anime no queda en blanco', () async {
      final anime = await VodCatalogService().getAnime(page: 1);

      expect(anime, isNotEmpty,
          reason: 'la lista debe armarse con lo que la red sí deja pasar');
      expect(anime.first.provider, isNot('jkanime'),
          reason: 'lo que se muestra tiene que ser jugable, no un espejo muerto');
    });

    test('la búsqueda de anime también llega por el camino alterno', () async {
      final hits = await TioAnimeService().search('naruto');

      expect(hits, isNotEmpty);
      expect(hits.first.provider, 'tioanime');
    });

    test('no se vuelve a tocar la puerta bloqueada en el resto de la sesión',
        () async {
      final primero = await JkAnimeService().getEpisodeSources('naruto', 1);
      expect(primero, isNotEmpty);
      final hitsBloqueadas = srv.hits['/jk/naruto/1/'] ?? 0;
      expect(hitsBloqueadas, greaterThan(0),
          reason: 'el primer intento sí sale, es cómo se descubre el bloqueo');

      JkAnimeService.resetForTest(); // caches limpios, la memoria de red no
      final segundo = await JkAnimeService().getEpisodeSources('naruto', 2);

      expect(segundo, isNotEmpty);
      expect(srv.hits['/jk/naruto/2/'] ?? 0, 0,
          reason: 'ya se sabe que está bloqueado: no se le vuelve a preguntar');
      expect(srv.hits['/jk/ajax_search'] ?? 0, lessThan(3),
          reason: 'la sesión se corta, no se reinventa en cada petición');
    });

    test('el catálogo principal se deja de consultar mientras esté bloqueado',
        () async {
      final primera = await JkAnimeService().fetchDirectory(page: 1);
      expect(primera, isEmpty, reason: 'bloqueado: no hay lista por ahí');

      final segunda = await JkAnimeService().fetchDirectory(page: 2);
      expect(segunda, isEmpty);
      expect(srv.hits['/jk/directorio'] ?? 0, 1,
          reason: 'una sola vez; después la app ya sabe la respuesta');
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
      expect(
          route.routeUri(Uri.parse('https://cdn.jkdesa.com/assets/images/animes/image/naruto.jpg')).toString(),
          'https://meta.inutix.com/ak/cdn/assets/images/animes/image/naruto.jpg');
      expect(
          route.routeUri(Uri.parse('https://nika.playmudos.com/naruto/x.m3u8?st=abc')).toString(),
          'https://meta.inutix.com/ak/player/naruto/x.m3u8?st=abc');
      expect(
          route.routeUri(Uri.parse('https://www.yourupload.com/embed/xyz')).toString(),
          'https://meta.inutix.com/ak/yourupload/embed/xyz');
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

  group('v3.3.42 — Changelog y versión sincronizados', () {
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
      expect(match!.group(1), '3.3.42');
      expect(match.group(2), '91');
      expect(AppInfo.appVersion, '3.3.42');
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.42'));
    });

    test('la nota de 3.3.42 no expone proveedores ni detalles internos', () {
      final full = File('CHANGELOG.md').readAsStringSync();
      final start = full.indexOf('## 3.3.42');
      expect(start, greaterThan(0));
      final end = full.indexOf('## 3.3.41', start);
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
      // La red no deja pasar: respuesta de verificación, sin sesión ni token.
      status = 403;
      body = '<html><head><title>Just a moment...</title></head>'
          '<body>Verifying your connection before granting access.</body></html>';
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
