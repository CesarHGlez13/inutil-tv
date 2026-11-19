import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'net.dart';

/// Fuente iptv-org: 18 000+ canales IPTV públicos y gratuitos.
/// Une streams.json + channels.json + feeds.json para elegir la mejor calidad.
class IptvOrgService {
  static const base = 'https://iptv-org.github.io/api';

  /// `--dart-define=VERBOSE=true` imprime cuánto tarda cada catálogo.
  static const _verbose = bool.fromEnvironment('VERBOSE');

  /// Carga y fusiona los catálogos. [showNsfw] incluye contenido para adultos.
  /// [onProgress] informa de archivos descargados (0..total) para la pantalla
  /// de carga.
  ///
  /// La descarga (I/O) va en el isolate de UI; el parseo y el fusionado de los
  /// ~26 MB de JSON (130 000 registros) van en un isolate de trabajo con
  /// [compute]: en el isolate de UI eso congela la pantalla de carga varios
  /// segundos (y más si el equipo va justo de memoria).
  Future<List<Channel>> loadChannels({
    bool showNsfw = false,
    void Function(int done, int total)? onProgress,
  }) async {
    const names = ['streams', 'channels', 'feeds', 'categories', 'countries'];
    var done = 0;
    Future<String> get(String name) async {
      final t0 = DateTime.now();
      final body = await Net.getTextCached(Uri.parse('$base/$name.json'));
      if (_verbose) {
        final ms = DateTime.now().difference(t0).inMilliseconds;
        debugPrint('[iptv-org] $name.json: ${(body.length / 1024).round()} KB, '
            '$ms ms');
      }
      done++;
      onProgress?.call(done, names.length + 1);
      return body;
    }

    // Los logos ya NO vienen en channels.json: viven en logos.json. Se pide en
    // paralelo pero a parte, y de forma tolerante: si ese download falla la
    // lista de canales sigue cargando (sin miniaturas).
    final logosFuture = get('logos').catchError((_) {
      done++;
      onProgress?.call(done, names.length + 1);
      return '';
    });
    final bodies = await Future.wait(names.map(get));
    final logosBody = await logosFuture;

    final t0 = DateTime.now();
    final out = await compute(
      _mergeAll,
      MergeInput(bodies: bodies, logos: logosBody, showNsfw: showNsfw),
    );
    if (_verbose) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      debugPrint('[iptv-org] merge (isolate): ${out.length} canales, $ms ms');
    }
    return out;
  }

  /// Playlists M3U públicas globales (descarga directa del .m3u).
  static const indexUrl = 'https://iptv-org.github.io/iptv/index.m3u';
  static const byCountryUrl = 'https://iptv-org.github.io/iptv/index.country.m3u';
}

/// Datos en bruto que se envían al isolate de trabajo para fusionar.
class MergeInput {
  const MergeInput({
    required this.bodies,
    required this.logos,
    required this.showNsfw,
  });

  /// streams, channels, feeds, categories y countries.json (en ese orden).
  final List<String> bodies;
  final String logos;
  final bool showNsfw;
}

/// Parsea los 6 catálogos y construye la lista final de canales. Corre en un
/// isolate aparte ([compute]), así que la interfaz sigue animando.
List<Channel> _mergeAll(MergeInput input) {
  final streams = _list(input.bodies[0]);
  final channelsRaw = _list(input.bodies[1]);
  final feedsRaw = _list(input.bodies[2]);
  final catsRaw = _list(input.bodies[3]);
  final countriesRaw = _list(input.bodies[4]);
  final logosRaw = _list(input.logos);

  final catNames = <String, String>{
    for (final c in catsRaw)
      c['id'].toString(): c['name'].toString(),
  };
  final countryNames = <String, String>{
    for (final c in countriesRaw) c['code'].toString(): c['name'].toString(),
  };
  final channelInfo = <String, Map<String, dynamic>>{
    for (final c in channelsRaw) c['id'].toString(): c as Map<String, dynamic>,
  };
  // feed "es-419"-style keys: canal::feedId -> {isMain, quality}
  final feedQuality = <String, int>{};
  for (final f in feedsRaw) {
    final key = '${f['channel']}:${f['id']}';
    feedQuality[key] = parseQuality((f['quality'] ?? f['format'])?.toString());
  }

  // canal -> mejor logo. Un canal puede tener varios logos (distintos
  // formatos/tamaños): se descarta SVG (Flutter no lo decodifica) y se
  // prefiere el marcado in_use y el de mayor resolución.
  final logoScore = <String, int>{};
  final logoUrl = <String, String>{};
  for (final l in logosRaw) {
    final id = l['channel']?.toString();
    final url = l['url']?.toString();
    if (id == null || url == null || url.isEmpty) continue;
    final fmt = (l['format']?.toString() ?? '').toUpperCase();
    if (fmt == 'SVG' || fmt == 'AVIF') continue;
    final w = int.tryParse('${l['width']}') ?? 0;
    final h = int.tryParse('${l['height']}') ?? 0;
    int score = (w * h).clamp(0, 1 << 30);
    if (l['in_use'] == true) score += 1 << 31;
    if (logoScore[id] != null && logoScore[id]! >= score) continue;
    logoScore[id] = score;
    logoUrl[id] = url;
  }

  // Agrupa streams por canal, elige la mejor calidad primero.
  final byChannel = <String, List<StreamSource>>{};
  for (final s in streams) {
    final chId = s['channel']?.toString();
    if (chId == null || chId.isEmpty) continue; // sin id de canal: fuera
    final url = s['url']?.toString() ?? '';
    if (!url.startsWith('http')) continue;
    final q = s['quality']?.toString() ??
        feedQuality['$chId:${s['feed']}']?.toString() ??
        '';
    // iptv-org indica por stream el User-Agent / Referer que el CDN exige.
    final headers = <String, String>{};
    final ua = s['user_agent']?.toString();
    final ref = s['referrer']?.toString();
    if (ua != null && ua.isNotEmpty) headers['user-agent'] = ua;
    if (ref != null && ref.isNotEmpty) headers['referer'] = ref;
    byChannel
        .putIfAbsent(chId, () => [])
        .add(StreamSource(url: url, quality: q, headers: headers));
  }

  final out = <Channel>[];
  byChannel.forEach((chId, srcs) {
    final info = channelInfo[chId];
    if (info == null) return;
    final nsfw = info['is_nsfw'] == true;
    if (nsfw && !input.showNsfw) return;
    srcs.sort((a, b) => parseQuality(b.quality).compareTo(parseQuality(a.quality)));
    final cats = (info['categories'] as List?)?.cast<String>() ?? const [];
    final country = info['country']?.toString() ?? '';
    out.add(Channel(
      id: chId,
      name: info['name']?.toString() ?? chId,
      logo: logoUrl[chId] ?? info['logo']?.toString() ?? '',
      group: catNames[cats.isEmpty ? '' : cats.first] ?? (cats.isEmpty ? '' : cats.first),
      country: countryNames[country] ?? country,
      nsfw: nsfw,
      sources: srcs,
    ));
  });
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// JSON tolerante: un catálogo vacío o ilegible no debe tumbar la lista.
List<dynamic> _list(String body) {
  if (body.isEmpty) return const [];
  try {
    final v = jsonDecode(body);
    return v is List ? v : const [];
  } catch (_) {
    return const [];
  }
}

int parseQuality(String? q) {
  if (q == null) return 0;
  final m = RegExp(r'(\d{3,4})[pP]').firstMatch(q);
  if (m != null) return int.tryParse(m.group(1)!) ?? 0;
  const formats = {'4K': 2160, '1080i': 1080, '1080p': 1080, '720p': 720};
  return formats[q] ?? 0;
}
