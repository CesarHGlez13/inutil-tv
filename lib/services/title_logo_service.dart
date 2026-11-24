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
/// Utiliza:
/// 1. TMDB API (gratuita, CDN global ilimitada y sin cuotas por usuario) como proveedor primario.
/// 2. Fanart.tv API como respaldo enriquecido para animes y películas de culto.
/// 3. Caché multinivel: L1 RAM instantánea (0 ms) + L2 disco persistente (SharedPreferences)
///    + Deduplicación de peticiones en vuelo (in-flight) para cero sobrecarga de red.
class TitleLogoService {
  TitleLogoService._();
  static final TitleLogoService instance = TitleLogoService._();

  static const String tmdbApiKey = '62a51d0e8a768b445ff8e3fda7c3721e';
  static const String tmdbReadAccessToken =
      'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiI2MmE1MWQwZThhNzY4YjQ0NWZmOGUzZmRhN2MzNzIxZSIsIm5iZiI6MTc5NTM2OTA4MS4yOTIsInN1YiI6IjZiMDMyODc5MGQwNDhiZWQ4ZDljMjNlYyIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.FKx8f4qYS795RC0RDffALs2Y0-AJlKMNkU2N5qnMkzs';
  static const String fanartApiKey = '06c9206b4acb54a9a33158bc7ff4db7c';
  static const String _prefPrefix = 'title_logo_v1_';

  static const Map<String, String> _tmdbHeaders = {
    'Authorization': 'Bearer $tmdbReadAccessToken',
    'accept': 'application/json',
  };

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
  /// para mejorar la precisión de búsqueda en TMDB / Fanart.tv.
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
    return cleanTitle(item.title).toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
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

    // 4. Intentar primero el Edge Gateway propio (`meta.inutix.com/logo`, caché
    //    global de 7 días en Cloudflare Edge sin depender de acceso directo a TMDB).
    final (localId, localType) = _extractLocalTmdbIdentity(item);
    final edgeResult = await _fetchEdgeLogo(
      item: item,
      tmdbId: localId,
      mediaType: localType,
    );

    String? logoUrl;
    if (edgeResult.handled) {
      logoUrl = edgeResult.logoUrl;
    } else {
      // 5. Fallback directo a TMDB Bearer Auth + Fanart.tv si el Edge no respondió
      final (tmdbId, mediaType) = localId != null && localId > 0
          ? (localId, localType)
          : await _findTmdbIdentity(item);

      if (tmdbId != null && tmdbId > 0) {
        logoUrl = await _fetchTmdbLogo(tmdbId, mediaType);
        if (logoUrl == null || logoUrl.isEmpty) {
          logoUrl = await _fetchFanartLogo(tmdbId, mediaType);
        }
      }
    }

    // 6. Guardar en memoria y disco (incluso cadena vacía para caché negativa)
    final resolved = logoUrl ?? '';
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
      if (query.isEmpty) return (handled: false, logoUrl: null);
      params['q'] = query;
    }

    try {
      final uri = Uri.parse('$base/logo').replace(queryParameters: params);
      final resp = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 4));
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

  /// Determina el id numérico de TMDB y el tipo de medio ('tv' o 'movie').
  Future<(int?, String)> _findTmdbIdentity(VodItem item) async {
    final isSeries = item.isSeries || item.isAnime;
    final defaultType = isSeries ? 'tv' : 'movie';

    // A. Extraer de id si es de Poseidon: cp_m_12345 o cp_s_12345
    final idMatch = RegExp(r'^cp_[sm]_(\d+)$').firstMatch(item.id);
    if (idMatch != null) {
      final id = int.tryParse(idMatch.group(1)!);
      if (id != null) {
        final type = item.id.startsWith('cp_s_') ? 'tv' : 'movie';
        return (id, type);
      }
    }

    // B. Extraer de slug si tiene formato series/12345/... o movies/12345/...
    final slugMatch = RegExp(r'(?:series|serie|movies|movie)/(\d+)').firstMatch(item.slug);
    if (slugMatch != null) {
      final id = int.tryParse(slugMatch.group(1)!);
      if (id != null) {
        final type = item.slug.startsWith('movie') ? 'movie' : 'tv';
        return (id, type);
      }
    }

    // C. Búsqueda por título en TMDB
    final query = cleanTitle(item.title);
    if (query.isEmpty) return (null, defaultType);

    try {
      // Intento 1: Endpoint específico según tipo
      final uri = Uri.parse(
        'https://api.themoviedb.org/3/search/$defaultType?query=${Uri.encodeComponent(query)}',
      );
      final resp = await _client
          .get(uri, headers: _tmdbHeaders)
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final first = results.first as Map<String, dynamic>;
          final id = (first['id'] as num?)?.toInt();
          if (id != null) return (id, defaultType);
        }
      }

      // Intento 2: Multi-search
      final multiUri = Uri.parse(
        'https://api.themoviedb.org/3/search/multi?query=${Uri.encodeComponent(query)}',
      );
      final multiResp = await _client
          .get(multiUri, headers: _tmdbHeaders)
          .timeout(const Duration(seconds: 4));
      if (multiResp.statusCode == 200) {
        final data = jsonDecode(multiResp.body) as Map<String, dynamic>;
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          for (final res in results) {
            if (res is Map<String, dynamic>) {
              final type = res['media_type']?.toString();
              if (type == 'tv' || type == 'movie') {
                final id = (res['id'] as num?)?.toInt();
                if (id != null) return (id, type!);
              }
            }
          }
        }
      }
    } catch (_) {}

    return (null, defaultType);
  }

  /// Consulta logos PNG transparentes en TMDB.
  Future<String?> _fetchTmdbLogo(int tmdbId, String mediaType) async {
    try {
      final uri = Uri.parse(
        'https://api.themoviedb.org/3/$mediaType/$tmdbId/images?include_image_language=es,en,ja,null',
      );
      final resp = await _client
          .get(uri, headers: _tmdbHeaders)
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return null;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final rawLogos = (data['logos'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      if (rawLogos.isEmpty) return null;

      // Filtrar sólo archivos PNG (descartar SVG que requieren plugins extra)
      final pngLogos = rawLogos.where((l) {
        final path = (l['file_path'] ?? '').toString().toLowerCase();
        return path.endsWith('.png');
      }).toList();

      if (pngLogos.isEmpty) return null;

      // Puntuar logos para elegir el más nítido, horizontal y en idioma preferido
      pngLogos.sort((a, b) => _scoreTmdbLogo(b).compareTo(_scoreTmdbLogo(a)));

      final best = pngLogos.first;
      final filePath = best['file_path']?.toString();
      if (filePath == null || filePath.isEmpty) return null;

      return 'https://image.tmdb.org/t/p/w500$filePath';
    } catch (_) {
      return null;
    }
  }

  int _scoreTmdbLogo(Map<String, dynamic> logo) {
    var score = 0;
    final lang = (logo['iso_639_1'] ?? '').toString();

    // Preferencia de idioma: español o inglés son los más estilizados y limpios
    if (lang == 'es') {
      score += 40;
    } else if (lang == 'en') {
      score += 35;
    } else if (lang == 'ja') {
      score += 20;
    } else {
      score += 10;
    }

    // Aspect ratio: logotipos horizontales (banner de título) se integran mejor
    final aspect = (logo['aspect_ratio'] as num?)?.toDouble() ?? 1.0;
    if (aspect >= 2.0) {
      score += 25;
    } else if (aspect >= 1.3) {
      score += 15;
    }

    // Votos de la comunidad TMDB
    final votes = (logo['vote_count'] as num?)?.toInt() ?? 0;
    score += votes.clamp(0, 15);

    return score;
  }

  /// Consulta logos PNG transparentes en Fanart.tv como respaldo.
  Future<String?> _fetchFanartLogo(int tmdbId, String mediaType) async {
    try {
      final isSeries = mediaType == 'tv';
      final uri = Uri.parse(
        isSeries
            ? 'http://webservice.fanart.tv/v3/tv/$tmdbId?api_key=$fanartApiKey'
            : 'http://webservice.fanart.tv/v3/movies/$tmdbId?api_key=$fanartApiKey',
      );
      final resp = await _client.get(uri).timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return null;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final logoList = (data[isSeries ? 'hdtvlogo' : 'hdmovielogo'] as List?) ??
          (data[isSeries ? 'clearlogo' : 'movielogo'] as List?);

      if (logoList == null || logoList.isEmpty) return null;

      // Buscar versión 'es' o 'en'
      for (final item in logoList) {
        if (item is Map) {
          final lang = item['lang']?.toString();
          if (lang == 'es' || lang == 'en') {
            final u = item['url']?.toString();
            if (u != null && u.isNotEmpty) return u;
          }
        }
      }

      // Fallback al primer logo disponible
      final first = logoList.first;
      if (first is Map) {
        final u = first['url']?.toString();
        if (u != null && u.isNotEmpty) return u;
      }
    } catch (_) {}

    return null;
  }
}
