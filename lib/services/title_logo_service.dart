import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'remote_providers_config.dart';

/// Servicio de resolución y caché de logos tipográficos transparentes (PNG)
/// para carátulas y cabeceras de títulos estilo Crunchyroll 2026.
///
/// Resuelve 100% a través del Edge Gateway propio (`https://meta.inutix.com/logo`),
/// donde las credenciales de TMDB y Fanart.tv residen exclusivamente como secretos
/// cifrados en Cloudflare Workers (cero llaves de terceros en la app o el repo):
/// 1. Caché Edge global de 7 días en Cloudflare (`meta.inutix.com/logo`).
/// 2. Caché local multinivel: L1 RAM instantánea (0 ms) + L2 disco persistente
///    (`SharedPreferences`) + deduplicación de peticiones en vuelo (`in-flight`).
class TitleLogoService {
  TitleLogoService._();
  static final TitleLogoService instance = TitleLogoService._();

  static const String _prefPrefix = 'title_logo_v1_';

  final Map<String, String> _memoryCache = {};
  final Map<String, Future<String?>> _inFlight = {};

  http.Client? _httpClient;
  http.Client get _client => _httpClient ??= http.Client();

  @visibleForTesting
  set testClient(http.Client? client) => _httpClient = client;

  @visibleForTesting
  void clearMemoryCache() {
    _memoryCache.clear();
    _inFlight.clear();
  }

  /// Limpia títulos removiendo información accesoria (idiomas, calidad, temporadas)
  /// para mejorar la precisión de búsqueda en el Edge Gateway (`meta.inutix.com`).
  static String cleanTitle(String raw) {
    var s = raw.trim();
    // 1. Quitar contenido entre paréntesis o corchetes: (Latino), [1080p], etc.
    s = s.replaceAll(RegExp(r'\[.*?\]|\(.*?\)', caseSensitive: false), ' ');
    // 2. Quitar etiquetas y sufijos comunes de release
    s = s.replaceAll(
      RegExp(
        r'\b(audio latino|latino|castellano|sub español|subtitulado|sub esp|sub|dub|temporada \d+|season \d+|t\d+|1080p|720p|hd|4k)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    // 3. Quitar guiones o dos puntos residuales al final
    s = s.replaceAll(RegExp(r'\s+[-:]\s*$'), ' ');
    // 4. Normalizar espacios
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.isNotEmpty ? s : raw.trim();
  }

  /// Clave única de caché para un [VodItem].
  static String cacheKeyFor(VodItem item) {
    if (item.id.isNotEmpty) {
      return item.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    }
    return cleanTitle(item.title)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
  }

  /// Obtiene de forma síncrona el logo si ya reside en la memoria RAM (0 ms).
  String? getCachedLogo(VodItem item) {
    if (item.titleLogo.isNotEmpty) return item.titleLogo;
    final key = cacheKeyFor(item);
    final cached = _memoryCache[key];
    if (cached != null) {
      return cached.isNotEmpty ? cached : null;
    }
    return null;
  }

  /// Resuelve la URL del logo transparente PNG para un [VodItem].
  /// Devuelve `null` si no existe logo disponible o si falla la red.
  Future<String?> getLogoUrl(VodItem item) async {
    if (item.titleLogo.isNotEmpty) return item.titleLogo;

    final key = cacheKeyFor(item);

    // 1. Revisar memoria RAM
    if (_memoryCache.containsKey(key)) {
      final cached = _memoryCache[key]!;
      return cached.isNotEmpty ? cached : null;
    }

    // 2. Deduplicar peticiones simultáneas
    if (_inFlight.containsKey(key)) {
      return _inFlight[key];
    }

    final future = _resolve(item, key);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<String?> _resolve(VodItem item, String key) async {
    // 3. Revisar SharedPreferences (disco)
    try {
      final sp = await SharedPreferences.getInstance();
      final diskVal = sp.getString('$_prefPrefix$key');
      if (diskVal != null) {
        _memoryCache[key] = diskVal;
        return diskVal.isNotEmpty ? diskVal : null;
      }
    } catch (_) {}

    // 4. Consultar Edge Gateway propio (`meta.inutix.com/logo`, caché global 7 d)
    final (localId, localType) = _extractLocalTmdbIdentity(item);
    final edgeResult = await _fetchEdgeLogo(
      item: item,
      tmdbId: localId,
      mediaType: localType,
    );

    // Solo persistir caché negativa si el Edge respondió explícitamente (ok: true);
    // si hubo fallo transitorio de red, no envenenar el disco para reintentar luego.
    if (!edgeResult.handled) {
      return null;
    }

    final resolved = edgeResult.logoUrl ?? '';
    _memoryCache[key] = resolved;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('$_prefPrefix$key', resolved);
    } catch (_) {}

    return resolved.isNotEmpty ? resolved : null;
  }

  /// Extrae ID numérico de TMDB localmente (0 ms, sin red) si está presente en
  /// `item.id` o `item.slug`.
  (int?, String) _extractLocalTmdbIdentity(VodItem item) {
    final isSeries = item.isSeries || item.isAnime;
    final defaultType = isSeries ? 'tv' : 'movie';

    final idMatch = RegExp(r'^cp_[sm]_(\d+)$').firstMatch(item.id);
    if (idMatch != null) {
      final id = int.tryParse(idMatch.group(1)!);
      if (id != null) {
        final type = item.id.startsWith('cp_s_') ? 'tv' : 'movie';
        return (id, type);
      }
    }

    final slugMatch =
        RegExp(r'(?:series|serie|movies|movie)/(\d+)').firstMatch(item.slug);
    if (slugMatch != null) {
      final id = int.tryParse(slugMatch.group(1)!);
      if (id != null) {
        final type = item.slug.startsWith('movie') ? 'movie' : 'tv';
        return (id, type);
      }
    }

    return (null, defaultType);
  }

  /// Consulta `https://meta.inutix.com/logo?type=...&id=...` (o `&q=...`).
  Future<({bool handled, String? logoUrl})> _fetchEdgeLogo({
    required VodItem item,
    required int? tmdbId,
    required String mediaType,
  }) async {
    final base = RemoteProvidersConfig.instance.metaBaseUrl;
    if (base.isEmpty) return (handled: false, logoUrl: null);

    final params = <String, String>{'type': mediaType};
    if (tmdbId != null && tmdbId > 0) {
      params['id'] = '$tmdbId';
    } else {
      final query = cleanTitle(item.title);
      if (query.isEmpty) return (handled: true, logoUrl: null);
      params['q'] = query;
    }

    try {
      final uri = Uri.parse('$base/logo').replace(queryParameters: params);
      final resp = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return (handled: false, logoUrl: null);

      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
        return (handled: false, logoUrl: null);
      }
      final logo = decoded['logo']?.toString().trim() ?? '';
      if (logo.startsWith('http://') || logo.startsWith('https://')) {
        return (handled: true, logoUrl: logo);
      }
      if (decoded['source'] == 'none') {
        return (handled: true, logoUrl: null);
      }
      return (handled: false, logoUrl: null);
    } catch (_) {
      return (handled: false, logoUrl: null);
    }
  }
}
