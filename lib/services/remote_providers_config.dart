import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_config.dart';
import 'firebase_firestore_service.dart';

/// Configuración remota dinámica de espejos VOD y gateways Cloudflare Edge
/// (`meta.inutix.com`, `ota.inutix.com`), leída desde `app_config/providers`
/// en `api.inutix.com` (SQLite autoritativo, 0 cuota Firestore) con failover
/// automático `LAN → api.inutix.com → backup.inutix.com`.
///
/// Permite rotar dominios caídos de Poseidon/Cuevana, VidHide, StreamWish,
/// SeriesKao, JKAnime o TioAnime en segundos sin recompilar ni lanzar OTA.
class RemoteProvidersConfig {
  RemoteProvidersConfig._();
  static final RemoteProvidersConfig instance = RemoteProvidersConfig._();

  static const String _prefsKey = 'inutil_tv_remote_providers_v1';
  static const Duration _refreshTtl = Duration(hours: 6);

  // Defaults verificados en producción (usados al instante antes de cualquier red).
  static const String defaultMetaBaseUrl = 'https://meta.inutix.com';
  static const String defaultOtaBaseUrl = 'https://ota.inutix.com';
  static const String defaultSeriesKaoBaseUrl = 'https://serieskao.top';
  static const String defaultJkAnimeBaseUrl = 'https://jkanime.net';
  static const String defaultTioAnimeBaseUrl = 'https://tioanime.com';

  static const List<String> defaultPoseidonMirrors = [
    'https://www.poseidonhd2.co',
    'https://wv3.cuevana3.eu',
  ];

  static const List<String> defaultVidHideMirrors = [
    'callistanise.com',
    'peytonepre.com',
    'smoothpre.com',
    'vidhidevip.com',
    'vidhideplus.com',
    'bingezove.com',
    'niikaplayerr.com',
  ];

  static const List<String> defaultStreamWishMirrors = [
    'swhoi.com',
    'jodwish.com',
    'embedwish.com',
    'swishsrv.com',
    'uqloads.xyz',
    'iplayerhls.com',
    'cdnwish.com',
  ];

  String _metaBaseUrl = defaultMetaBaseUrl;
  String _otaBaseUrl = defaultOtaBaseUrl;
  String _seriesKaoBaseUrl = defaultSeriesKaoBaseUrl;
  String _jkAnimeBaseUrl = defaultJkAnimeBaseUrl;
  String _tioAnimeBaseUrl = defaultTioAnimeBaseUrl;
  List<String> _poseidonMirrors = defaultPoseidonMirrors;
  List<String> _vidHideMirrors = defaultVidHideMirrors;
  List<String> _streamWishMirrors = defaultStreamWishMirrors;
  String _updatedAt = '';
  bool _loadedFromPrefs = false;
  Future<void>? _inFlightRefresh;

  String get metaBaseUrl => _metaBaseUrl;
  String get otaBaseUrl => _otaBaseUrl;
  String get seriesKaoBaseUrl => _seriesKaoBaseUrl;
  String get jkAnimeBaseUrl => _jkAnimeBaseUrl;
  String get tioAnimeBaseUrl => _tioAnimeBaseUrl;
  List<String> get poseidonMirrors => _poseidonMirrors;
  List<String> get vidHideMirrors => _vidHideMirrors;
  List<String> get streamWishMirrors => _streamWishMirrors;
  String get updatedAt => _updatedAt;

  /// Carga caché local inmediata y refresca desde `app_config/providers` si
  /// pasaron más de 6 horas (o si [force] es true).
  Future<void> loadAndRefresh({
    bool force = false,
    http.Client? client,
  }) async {
    int fetchedAtMs = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          applyMap(decoded);
          fetchedAtMs = (decoded['_fetchedAtMs'] as num?)?.toInt() ?? 0;
        }
      }
      _loadedFromPrefs = true;
    } catch (e) {
      debugPrint('[RemoteProvidersConfig] Error leyendo caché local: $e');
    }

    final ageMs = DateTime.now().millisecondsSinceEpoch - fetchedAtMs;
    if (!force &&
        fetchedAtMs > 0 &&
        ageMs >= 0 &&
        ageMs < _refreshTtl.inMilliseconds) {
      return;
    }

    if (_inFlightRefresh != null && !force) {
      return _inFlightRefresh;
    }

    final future = _fetchRemote(client: client);
    _inFlightRefresh = future;
    try {
      await future;
    } finally {
      if (identical(_inFlightRefresh, future)) {
        _inFlightRefresh = null;
      }
    }
  }

  Future<void> _fetchRemote({http.Client? client}) async {
    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final res = await InutilFirestoreService.instance.sendWithRelayFallback(
        label: 'GET app_config/providers',
        urlBuilder: () => Uri.parse(
          '${FirebaseConfig.firestoreBaseUrl}/app_config/providers?${FirebaseConfig.keyParam}',
        ),
        send: (url) => httpClient.get(
          url,
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'InutilTV/3.3 (RemoteProvidersConfig)',
          },
        ).timeout(const Duration(seconds: 8)),
      );

      if (res.statusCode != 200) return;

      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map<String, dynamic>) return;

      final parsed = decodeDocument(decoded);
      if (parsed.isEmpty) return;

      applyMap(parsed);
      parsed['_fetchedAtMs'] = DateTime.now().millisecondsSinceEpoch;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsKey, jsonEncode(parsed));
      } catch (_) {}
    } catch (e) {
      debugPrint('[RemoteProvidersConfig] Refresh remoto omitido: $e');
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  /// Decodifica tanto un documento REST de Firestore (`{"fields": {...}}`)
  /// como un mapa JSON plano.
  @visibleForTesting
  static Map<String, dynamic> decodeDocument(Map<String, dynamic> doc) {
    final rawFields = doc['fields'];
    if (rawFields is! Map<String, dynamic>) {
      return Map<String, dynamic>.from(doc);
    }

    String? strVal(String key) {
      final f = rawFields[key];
      if (f is Map && f['stringValue'] != null) {
        final s = f['stringValue'].toString().trim();
        return s.isNotEmpty ? s : null;
      }
      return null;
    }

    List<String>? listVal(String key) {
      final f = rawFields[key];
      if (f is! Map) return null;
      final arr = f['arrayValue'];
      if (arr is! Map) return null;
      final vals = arr['values'];
      if (vals is! List) return null;
      final out = <String>[];
      for (final item in vals) {
        if (item is Map && item['stringValue'] != null) {
          final s = item['stringValue'].toString().trim();
          if (s.isNotEmpty) out.add(s);
        }
      }
      return out.isNotEmpty ? out : null;
    }

    final result = <String, dynamic>{};
    for (final k in const [
      'metaBaseUrl',
      'otaBaseUrl',
      'seriesKaoBaseUrl',
      'jkAnimeBaseUrl',
      'tioAnimeBaseUrl',
      'updatedAt',
    ]) {
      final v = strVal(k);
      if (v != null) result[k] = v;
    }
    for (final k in const [
      'poseidonMirrors',
      'vidHideMirrors',
      'streamWishMirrors',
    ]) {
      final v = listVal(k);
      if (v != null) result[k] = v;
    }
    return result;
  }

  /// Aplica un mapa de configuración validando URLs y listas no vacías.
  void applyMap(Map<String, dynamic> map) {
    final meta = _cleanHttpBase(map['metaBaseUrl']);
    if (meta != null) _metaBaseUrl = meta;

    final ota = _cleanHttpBase(map['otaBaseUrl']);
    if (ota != null) _otaBaseUrl = ota;

    final sk = _cleanHttpBase(map['seriesKaoBaseUrl']);
    if (sk != null) _seriesKaoBaseUrl = sk;

    final jk = _cleanHttpBase(map['jkAnimeBaseUrl']);
    if (jk != null) _jkAnimeBaseUrl = jk;

    final tio = _cleanHttpBase(map['tioAnimeBaseUrl']);
    if (tio != null) _tioAnimeBaseUrl = tio;

    final poseidon = _cleanUrlList(map['poseidonMirrors']);
    if (poseidon != null) _poseidonMirrors = List<String>.unmodifiable(poseidon);

    final vidHide = _cleanHostList(map['vidHideMirrors']);
    if (vidHide != null) _vidHideMirrors = List<String>.unmodifiable(vidHide);

    final streamWish = _cleanHostList(map['streamWishMirrors']);
    if (streamWish != null) {
      _streamWishMirrors = List<String>.unmodifiable(streamWish);
    }

    final upd = map['updatedAt']?.toString().trim() ?? '';
    if (upd.isNotEmpty) _updatedAt = upd;
  }

  static String? _cleanHttpBase(Object? raw) {
    final s = raw?.toString().trim() ?? '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) return null;
    final trimmed = s.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return null;
    return trimmed;
  }

  static List<String>? _cleanUrlList(Object? raw) {
    if (raw is! List) return null;
    final out = <String>[];
    final seen = <String>{};
    for (final item in raw) {
      final clean = _cleanHttpBase(item);
      if (clean != null && seen.add(clean)) out.add(clean);
    }
    return out.isNotEmpty ? out : null;
  }

  static List<String>? _cleanHostList(Object? raw) {
    if (raw is! List) return null;
    final out = <String>[];
    final seen = <String>{};
    for (final item in raw) {
      var h = item?.toString().trim().toLowerCase() ?? '';
      if (h.startsWith('https://')) h = h.substring(8);
      if (h.startsWith('http://')) h = h.substring(7);
      final slash = h.indexOf('/');
      if (slash >= 0) h = h.substring(0, slash);
      if (h.isNotEmpty && h.contains('.') && !h.contains(' ') && seen.add(h)) {
        out.add(h);
      }
    }
    return out.isNotEmpty ? out : null;
  }

  @visibleForTesting
  bool get loadedFromPrefs => _loadedFromPrefs;

  @visibleForTesting
  void resetToDefaults() {
    _metaBaseUrl = defaultMetaBaseUrl;
    _otaBaseUrl = defaultOtaBaseUrl;
    _seriesKaoBaseUrl = defaultSeriesKaoBaseUrl;
    _jkAnimeBaseUrl = defaultJkAnimeBaseUrl;
    _tioAnimeBaseUrl = defaultTioAnimeBaseUrl;
    _poseidonMirrors = defaultPoseidonMirrors;
    _vidHideMirrors = defaultVidHideMirrors;
    _streamWishMirrors = defaultStreamWishMirrors;
    _updatedAt = '';
    _loadedFromPrefs = false;
    _inFlightRefresh = null;
  }
}
