import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'network_config_service.dart';
import 'remote_providers_config.dart';

/// Resultado de una petición enviada por la ruta que tocaba usar.
class AnimeRouteResult {
  const AnimeRouteResult({
    this.response,
    this.viaEdge = false,
    this.failedAll = false,
  });

  /// Respuesta de la última ruta intentada (`null` si ninguna respondió).
  final http.Response? response;

  /// true cuando la respuesta viene por el borde propio, no directo.
  final bool viaEdge;

  /// true cuando todas las rutas disponibles fallaron (bloqueo de la red).
  final bool failedAll;

  /// true si hay respuesta usable (200 y ningún signo de verificación).
  bool get ok => response != null && !failedAll && response!.statusCode == 200;
}

/// v3.3.43 — Ruta asistida para el frente de anime.
///
/// Anime es el único frente de la app cuyo catálogo vive detrás de una
/// verificación automática: cuando sales de una red que no es la tuya (empresa,
/// hotel, aeropuerto), te saluda con una página de comprobación en vez de la
/// lista, y eso cortaba la sesión, la búsqueda, los episodios y el arranque del
/// video. Las otras pestañas no dependen de ese paso, por eso seguían andando.
///
/// Esta clase hace dos cosas y nada más:
/// 1. Sabe qué hosts pueden salir por el borde propio (`meta.inutix.com`, el
///    nombre que la red ya deja pasar) y cuál les corresponde.
/// 2. Lleva la memoria de red: la primera vez que un proveedor no responde se
///    intenta por el borde; la ruta que funcionó se recuerda, y el proveedor
///    que resulta bloqueado en las dos rutas se deja de consultar un rato para
///    no robarle tiempo al usuario en cada pantalla.
///
/// En una red doméstica normal no cambia nada: la primera petición sale directo
/// como siempre y la memoria queda vacía.
class AnimeEdgeRoute {
  AnimeEdgeRoute._();
  static final AnimeEdgeRoute instance = AnimeEdgeRoute._();

  /// Prefijos del borde (`/ak/<prefijo>/...`) por proveedor.
  static const Map<String, String> prefixByRouteKey = <String, String>{
    'jkAnime': 'jkanime',
    'jkCdn': 'cdn',
    'tioAnime': 'tioanime',
    'seriesKao': 'kao',
    'playmudos': 'player',
    'yourUpload': 'yourupload',
  };

  /// Los mismos proveedores, indexados por nombre de host, para las URLs que se
  /// construyen sueltas (imágenes, reproductores, playlists HLS). El valor es la
  /// clave canónica de `prefixByRouteKey`.
  static const Map<String, String> prefixByHost = <String, String>{
    'jkanime.net': 'jkAnime',
    'cdn.jkdesa.com': 'jkCdn',
    'tioanime.com': 'tioAnime',
    'serieskao.top': 'seriesKao',
    'nika.playmudos.com': 'playmudos',
    'www.yourupload.com': 'yourUpload',
  };

  /// Rutas que NUNCA dan la vuelta por el borde, incluso en modo corporativo.
  /// Son las que responden bien por la red propia y el borde no las sirve
  /// (medido desde la red de la empresa el 2026-11-25, con cabeceras de la app):
  /// dar ahí la vuelta costaba solo un viaje perdido, y en el vidurl de
  /// SeriesKao ese viaje devolvía 444 y la cadena se rendía sin probar la ruta
  /// directa. La decisión quedó escrita en el test
  /// `el borde no sirve todo: lo que responde directo se deja directo`.
  /// Las claves son el primer segmento del path, que es lo que compara
  /// [_isNoDetourPath].
  ///
  /// `jkAnime` entró aquí el 2026-11-25 por el mismo motivo, medido desde casa
  /// con las cabeceras completas de la app: directo a `jkanime.net` responde 200
  /// (71 KB de catálogo), y por el borde responde 403 con la verificación propia
  /// de Cloudflare (`Attention Required!`) — el borde es un Worker y no puede
  /// pasar ese filtro, así que dar ahí la vuelta era un viaje perdido que además
  /// hacía que la app marcara el catálogo como bloqueado un rato y dejara la
  /// pestaña de anime en cero. El borde se queda como respaldo para cuando la red
  /// propia sí filtre el dominio (en la empresa se probó por los dos caminos y
  /// ninguno respondió; con VPN de la misma empresa sí entra). Como todas las
  /// rutas que la app arma para ese proveedor (catálogo, búsqueda, episodes
  /// AJAX, ficha y página del episodio) entran por el mismo camino, la decisión
  /// es por proveedor completo y está en [_noDetourFirstKeys].
  static const Map<String, Set<String>> _noDetourFirstPaths = <String, Set<String>>{
    'seriesKao': {'vidurl'},
  };

  /// Proveedores completos que siempre se dejan directos, por cualquier ruta.
  static const Set<String> _noDetourFirstKeys = <String>{'jkAnime'};

  /// Cabeceras de navegador real. Los filtros de las redes de empresa puntúan
  /// la petición antes de dejarla pasar, y con una huella pelada de robot toca
  /// verificación. Se envían completas y coherentes entre sí.
  static const Map<String, String> browserHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, '
            'like Gecko) Chrome/125.0.0.0 Safari/537.36',
    'Accept': 'application/json,text/html;q=0.9,*/*;q=0.8',
    'Accept-Language': 'es-MX,es;q=0.9,en;q=0.8',
    'sec-ch-ua':
        '"Chromium";v="125", "Not-A.Brand";v="24", "Google Chrome";v="125"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    'sec-fetch-dest': 'empty',
    'sec-fetch-mode': 'cors',
    'sec-fetch-site': 'same-origin',
  };

  /// Cuánto se deja de consultar un proveedor que no respondió por ningún camino.
  static const Duration _blockedTtl = Duration(minutes: 10);

  final Map<String, DateTime> _blockedUntil = <String, DateTime>{};
  final Set<String> _edgePreferred = <String>{};

  /// Clave canónica de un proveedor (`routeKey` o el host que se conoce).
  /// `null` si el host no es del frente de anime: eso se deja siempre directo.
  @visibleForTesting
  static String? keyFor(Uri uri, {String? routeKey}) {
    final direct = routeKey?.trim() ?? '';
    if (direct.isNotEmpty && prefixByRouteKey.containsKey(direct)) return direct;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return null;
    return prefixByHost[host];
  }

  /// true si [routeKey] está marcado como bloqueado (no respondió por ningún
  /// camino hace menos de [_blockedTtl]): los servicios lo saltan y usan el
  /// respaldo, sin gastar una petición que se va a caer.
  bool isBlocked(String routeKey) {
    final until = _blockedUntil[routeKey];
    return until != null && DateTime.now().isBefore(until);
  }

  /// Recuerda que este proveedor no respondió por ningún camino.
  void markBlocked(String routeKey) {
    if (!prefixByRouteKey.containsKey(routeKey)) return;
    _blockedUntil[routeKey] = DateTime.now().add(_blockedTtl);
  }

  /// Recuerda que este proveedor sale por el borde (el camino directo no
  /// funcionó), así las siguientes peticiones no vuelvan a tropezar. Acepta tanto
  /// la clave del proveedor como su nombre de host.
  void markEdgePreferred(String keyOrHost) {
    final k = keyOrHost.trim();
    final canonical =
        prefixByRouteKey.containsKey(k) ? k : prefixByHost[k.toLowerCase()];
    if (canonical != null) _edgePreferred.add(canonical);
  }

  /// true cuando la ruta asistida es la que toca usar ahora mismo. [uriPath]
  /// permite afinar por ruta: hay caminos que el borde no sirve y que la red
  /// propia sí (ver `_noDetourFirstPaths`), y esos se dejan directos.
  bool shouldUseEdge(String routeKey, {String? uriPath}) {
    if (!prefixByRouteKey.containsKey(routeKey)) return false;
    if (_isNoDetourPath(routeKey, uriPath)) return false;
    if (_edgePreferred.contains(routeKey)) return true;
    return NetworkConfigService.instance.corporateModeActive;
  }

  /// true si la ruta pertenece a las que no dan la vuelta (primer segmento del
  /// path, p. ej. `/vidurl/...`), o si el proveedor está marcado completo
  /// ([_noDetourFirstKeys]).
  bool _isNoDetourPath(String? key, String? uriPath) {
    if (key == null) return false;
    if (_noDetourFirstKeys.contains(key)) return true;
    final segs = _noDetourFirstPaths[key];
    if (segs == null || segs.isEmpty) return false;
    if (uriPath == null) return false;
    final firstSegs = uriPath.split('/').where((s) => s.isNotEmpty).take(1).toList();
    return firstSegs.isNotEmpty && segs.contains(firstSegs.first);
  }

  /// URL a usar para [uri]: la propia si toca directo, la del borde si la
  /// memoria de red o el modo corporativo lo piden. Los hosts locales (el proxy
  /// de reproducción de la app) y el propio borde nunca se reescriben.
  Uri routeUri(Uri uri, {String? routeKey}) {
    final key = keyFor(uri, routeKey: routeKey);
    if (key == null) return uri;
    final host = uri.host.toLowerCase();
    final edgeHost = RemoteProvidersConfig.instance.metaBaseUrl
        .replaceFirst(RegExp(r'^https?://'), '')
        .toLowerCase();
    if (host == 'localhost' || host == '::1' || host == '127.0.0.1' || host == edgeHost) {
      return uri;
    }
    if (!shouldUseEdge(key, uriPath: uri.path)) return uri;
    return _edgeUrl(uri, prefixByRouteKey[key]!);
  }

  Uri _edgeUrl(Uri uri, String prefix) {
    final base = RemoteProvidersConfig.instance.metaBaseUrl;
    final tail = uri.path.replaceFirst(RegExp(r'^/+'), '');
    final q = uri.queryParameters.isEmpty
        ? ''
        : '?${uri.queryParameters.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
    return Uri.parse('$base/ak/$prefix/$tail$q');
  }

  /// Manda [method] a [uri] por la ruta que toque: primero la que la memoria
  /// aprendió (o el borde en modo corporativo), y si no la directa. En cuanto
  /// una responde bien se recuerda cuál fue. Si ninguna responde, el proveedor
  /// queda marcado como bloqueado un rato.
  ///
  /// [headers] se envían tal cual; al borde se le copian las que el borde
  /// reenvía al proveedor (Cookie, CSRF, Referer, Range, Content-Type).
  Future<AnimeRouteResult> send(
    String method,
    Uri uri,
    Map<String, String> headers, {
    Object? body,
    required Duration timeout,
    String? routeKey,
  }) async {
    final key = keyFor(uri, routeKey: routeKey);
    final edge = key == null ? null : _edgeUrl(uri, prefixByRouteKey[key]!);

    final order = <Uri>[uri];
    if (edge != null && shouldUseEdge(key!, uriPath: uri.path)) {
      order.insert(0, edge);
      order.removeLast();
    } else if (edge != null) {
      order.add(edge);
    }

    http.Response? last;
    var viaEdge = false;

    for (final target in order) {
      final isEdge = target != uri;
      final h = Map<String, String>.from(headers);
      if (isEdge) {
        for (final k in const [
          'Cookie',
          'X-CSRF-TOKEN',
          'X-Requested-With',
          'Referer',
          'Content-Type',
          'Range',
        ]) {
          final v = headers[k];
          if (v != null) h[k] = v;
        }
      }
      try {
        final res = method == 'POST'
            ? await http
                .post(target, headers: h, body: body)
                .timeout(timeout)
            : await http.get(target, headers: h).timeout(timeout);
        last = res;
        viaEdge = isEdge;
        if (!_looksBlocked(res)) {
          if (isEdge && key != null) markEdgePreferred(key);
          return AnimeRouteResult(response: res, viaEdge: isEdge);
        }
      } catch (_) {
        // ni respondió: se prueba la otra ruta antes de rendirse
      }
    }

    if (key != null) markBlocked(key);
    return AnimeRouteResult(
      response: last,
      viaEdge: viaEdge,
      failedAll: last == null || _looksBlocked(last),
    );
  }

  /// Señales de que la respuesta no es el contenido sino una verificación de la
  /// red: status de filtro o HTML de comprobación.
  static bool _looksBlocked(http.Response res) {
    if (const [403, 429, 503].contains(res.statusCode)) return true;
    if (res.statusCode != 200) return false;
    final head = res.body.length < 400 ? res.body : res.body.substring(0, 400);
    final lower = head.toLowerCase();
    return lower.contains('just a moment') ||
        lower.contains('verifying your connection') ||
        lower.contains('cf-browser-verification') ||
        lower.contains('enable javascript and cookies');
  }

  @visibleForTesting
  void resetForTest() {
    _blockedUntil.clear();
    _edgePreferred.clear();
  }
}
