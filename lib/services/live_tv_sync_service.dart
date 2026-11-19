import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'stream_validator.dart';

/// Sincronizador autónomo multi-fuente para TV en Vivo.
///
/// Combina el catálogo maestro verificado (`assets/channels_master.json`) con
/// actualizaciones en segundo plano desde listas públicas abiertas y sostenibles
/// (`TDTChannels`, `iptv-org` México/Deportes/Cine y `Free-TV/IPTV`).
/// - Si una señal se cae en el futuro, las fuentes de respaldo adicionales se
///   fusionan automáticamente en `sources[]` sin esperar actualización de APK.
/// - Mantiene caché local de 12 horas en `SharedPreferences`.
class LiveTvSyncService {
  LiveTvSyncService._();
  static final LiveTvSyncService instance = LiveTvSyncService._();

  static const _kCacheKey = 'inutiltv_live_sync_cache_v3';
  static const _kTimestampKey = 'inutiltv_live_sync_ts_v3';
  static const _cacheTtl = Duration(hours: 12);

  static const List<({String url, String group, String country})> _m3uFeeds = [
    (
      url: 'https://iptv-org.github.io/iptv/countries/mx.m3u',
      group: 'México',
      country: 'MX',
    ),
    (
      url: 'https://iptv-org.github.io/iptv/categories/sports.m3u',
      group: 'Deportes',
      country: '',
    ),
    (
      url: 'https://iptv-org.github.io/iptv/categories/movies.m3u',
      group: 'Cine y Series',
      country: '',
    ),
    (
      url: 'https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8',
      group: 'Internacional',
      country: '',
    ),
  ];

  static const String _tdtChannelsUrl =
      'https://www.tdtchannels.com/lists/tv.json';

  /// Fusiona fuentes frescas (de caché o red) sobre la lista base [baseChannels].
  /// Devuelve la lista enriquecida sin duplicados de nombre ni URL.
  Future<List<Channel>> syncAndMerge(
    List<Channel> baseChannels, {
    bool forceRefresh = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastTs = prefs.getInt(_kTimestampKey) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - lastTs;

      List<Channel> extra = [];
      if (!forceRefresh && age < _cacheTtl.inMilliseconds) {
        final raw = prefs.getString(_kCacheKey);
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw) as List;
          extra = decoded
              .map((e) => Channel.fromJson((e as Map).cast<String, dynamic>()))
              .toList();
        }
      }

      if (extra.isEmpty || forceRefresh) {
        extra = await _fetchRemoteBackups();
        if (extra.isNotEmpty) {
          // Guardamos hasta 350 canales/respaldos frescos para no inflar SharedPreferences
          final toSave = extra.take(350).map((c) => c.toJson()).toList();
          await prefs.setString(_kCacheKey, jsonEncode(toSave));
          await prefs.setInt(
            _kTimestampKey,
            DateTime.now().millisecondsSinceEpoch,
          );
        }
      }

      if (extra.isEmpty) return baseChannels;
      return mergeChannels(baseChannels, extra);
    } catch (e) {
      debugPrint('[LiveTvSyncService] Sync error: $e');
      return baseChannels;
    }
  }

  /// Fusiona [remoteChannels] sobre [baseChannels]:
  /// - Si el canal ya existe (mismo nombre normalizado), agrega sus URLs nuevas
  ///   como fuentes de respaldo (`sources[]`, hasta 4 por canal) sin duplicar.
  /// - Conserva el orden curado de los canales verificados en `baseChannels`.
  static List<Channel> mergeChannels(
    List<Channel> baseChannels,
    List<Channel> remoteChannels,
  ) {
    final byKey = <String, _MutableChannel>{};
    final order = <String>[];

    for (final ch in baseChannels) {
      final k = _channelKey(ch.name);
      if (k.isEmpty) continue;
      if (!byKey.containsKey(k)) {
        byKey[k] = _MutableChannel.from(ch);
        order.add(k);
      } else {
        byKey[k]!.mergeFrom(ch);
      }
    }

    // Agregamos URLs de respaldo a canales existentes (y nuevos de México/España/Deportes)
    for (final r in remoteChannels) {
      final k = _channelKey(r.name);
      if (k.isEmpty) continue;
      final existing = byKey[k];
      if (existing != null) {
        existing.mergeFrom(r);
      }
    }

    return [for (final k in order) byKey[k]!.toChannel()];
  }

  Future<List<Channel>> _fetchRemoteBackups() async {
    final results = await Future.wait<List<Channel>>([
      _fetchTdtChannels(),
      for (final f in _m3uFeeds) _fetchM3uFeed(f.url, f.group, f.country),
    ]);
    return [for (final list in results) ...list];
  }

  Future<List<Channel>> _fetchTdtChannels() async {
    try {
      final res = await http
          .get(
            Uri.parse(_tdtChannelsUrl),
            headers: const {'User-Agent': StreamValidator.defaultUserAgent},
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final countries = (j['countries'] as List?) ?? const [];
      final out = <Channel>[];

      for (final cObj in countries) {
        if (cObj is! Map) continue;
        final cName = (cObj['name'] ?? '').toString();
        final cc = cName.contains('Spain') || cName.contains('España')
            ? 'ES'
            : (cName.contains('Mexico') || cName.contains('México') ? 'MX' : '');
        for (final amb in (cObj['ambits'] as List?) ?? const []) {
          if (amb is! Map) continue;
          for (final ch in (amb['channels'] as List?) ?? const []) {
            if (ch is! Map) continue;
            final name = _cleanName((ch['name'] ?? '').toString());
            final logo = (ch['logo'] ?? '').toString();
            final sources = <StreamSource>[];
            for (final opt in (ch['options'] as List?) ?? const []) {
              if (opt is! Map) continue;
              final u = (opt['url'] ?? '').toString().trim();
              final fmt = (opt['format'] ?? '').toString().toLowerCase();
              if (u.startsWith('http') &&
                  (fmt.contains('m3u8') || u.contains('.m3u8'))) {
                sources.add(StreamSource(
                  url: u,
                  quality: 'Señal Alterna',
                  server: 'tdtchannels',
                ));
              }
            }
            if (name.isNotEmpty && sources.isNotEmpty) {
              out.add(Channel(
                id: 'tdt_${_channelKey(name)}',
                name: name,
                logo: logo,
                group: cc == 'ES' ? 'España' : (cc == 'MX' ? 'México' : 'Internacional'),
                country: cc,
                sources: sources,
              ));
            }
          }
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<List<Channel>> _fetchM3uFeed(
    String url,
    String defaultGroup,
    String country,
  ) async {
    try {
      final res = await http
          .get(
            Uri.parse(url),
            headers: const {'User-Agent': StreamValidator.defaultUserAgent},
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];

      final out = <Channel>[];
      final lines = res.body.split('\n');
      String? pendingName;
      String pendingLogo = '';

      for (final raw in lines) {
        final line = raw.trim();
        if (line.startsWith('#EXTINF:')) {
          if (line.contains('[Geo-blocked]') || line.contains('[Not 24/7]')) {
            pendingName = null;
            continue;
          }
          final logoM = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line);
          pendingLogo = logoM?.group(1) ?? '';
          final comma = line.lastIndexOf(',');
          pendingName = comma >= 0 ? _cleanName(line.substring(comma + 1)) : null;
        } else if (line.startsWith('http') &&
            pendingName != null &&
            pendingName.isNotEmpty) {
          out.add(Channel(
            id: 'sync_${_channelKey(pendingName)}',
            name: pendingName,
            logo: pendingLogo,
            group: defaultGroup,
            country: country,
            sources: [
              StreamSource(
                url: line,
                quality: 'Señal Alterna',
                server: 'iptv-sync',
              ),
            ],
          ));
          pendingName = null;
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static String _cleanName(String s) {
    return s
        .replaceAll(RegExp(r'\s*\[(?:Geo-blocked|Not 24/7|Offline)\]\s*', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s*\((?:1080p|720p|576p|480p|360p)\)\s*', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _channelKey(String name) {
    return StreamValidator.stripAccents(name)
        .toLowerCase()
        .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
        .replaceAll(RegExp(r'\b\d+\.\d+\b'), ' ')
        .replaceAll(
          RegExp(r'\b(hd|fhd|uhd|4k|sd|1080p|720p|480p|360p|live|tv|mexico|espana|spain)\b'),
          ' ',
        )
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }
}

class _MutableChannel {
  final String id;
  final String name;
  String logo;
  final String group;
  final String country;
  final List<StreamSource> sources;
  final Set<String> seenUrls;

  _MutableChannel({
    required this.id,
    required this.name,
    required this.logo,
    required this.group,
    required this.country,
    required this.sources,
    required this.seenUrls,
  });

  factory _MutableChannel.from(Channel ch) => _MutableChannel(
        id: ch.id,
        name: ch.name,
        logo: ch.logo,
        group: ch.group,
        country: ch.country,
        sources: List.of(ch.sources),
        seenUrls: ch.sources.map((s) => s.url).toSet(),
      );

  void mergeFrom(Channel other) {
    if (logo.isEmpty && other.logo.isNotEmpty) {
      logo = other.logo;
    }
    for (final s in other.sources) {
      if (sources.length >= 4) break;
      if (s.url.startsWith('http') && seenUrls.add(s.url)) {
        sources.add(StreamSource(
          url: s.url,
          quality: 'HD · Señal ${sources.length + 1}',
          headers: s.headers,
          server: s.server,
        ));
      }
    }
  }

  Channel toChannel() => Channel(
        id: id,
        name: name,
        logo: logo,
        group: group,
        country: country,
        sources: sources,
      );
}
