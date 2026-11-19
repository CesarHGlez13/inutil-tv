import '../models/models.dart';

/// Parser de listas M3U / M3U8 extendidas (formato Xuper/IPTV estándar).
class M3uParser {
  static List<Channel> parse(String content) {
    final lines = content.split(RegExp(r'\r?\n'));
    final out = <Channel>[];
    _Pending? pending;
    var idx = 0;

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        pending = _Pending(
          name: _extractName(line),
          logo: _attr(line, 'tvg-logo'),
          group: _attr(line, 'group-title'),
          ua: _attr(line, 'user-agent'),
          id: _attr(line, 'tvg-id'),
        );
      } else if (line.startsWith('#EXTVLCOPT') || line.startsWith('#EXTM3U')) {
        // #EXTVLCOPT:http-user-agent=... / http-referrer=... : el CDN pide
        // esas cabeceras o devuelve 403.
        final opt =
            RegExp(r'^#EXTVLCOPT:http-([a-zA-Z-]+)=(.+)$').firstMatch(line);
        if (opt != null && pending != null) {
          final key = opt.group(1)!.toLowerCase();
          final value = opt.group(2)!.trim();
          if (key == 'user-agent' || key == 'useragent') {
            pending.headers['user-agent'] = value;
          } else if (key == 'referrer' || key == 'referer') {
            pending.headers['referer'] = value;
          }
        }
      } else if (line.startsWith('#')) {
        continue; // otros comentarios (#EXTGRP, #KODIPROP...)
      } else if (line.startsWith('http') || line.startsWith('rtmp')) {
        final p = pending;
        final headers = <String, String>{};
        if (p != null) {
          if (p.ua.isNotEmpty) headers['user-agent'] = p.ua;
          headers.addAll(p.headers);
        }
        out.add(Channel(
          id: (p != null && p.id.isNotEmpty) ? p.id : 'm3u-$idx',
          name: (p != null && p.name.isNotEmpty) ? p.name : 'Canal ${idx + 1}',
          logo: p?.logo ?? '',
          group: p?.group ?? '',
          sources: [StreamSource(url: line, headers: headers)],
        ));
        idx++;
        pending = null;
      }
    }
    return out;
  }

  /// Nombre visible: texto tras la coma del EXTINF (estándar) o tvg-name.
  static String _extractName(String line) {
    final noTag = line.replaceFirst(RegExp(r'^#EXTINF:[^,]*,'), '');
    final name = _attr(line, 'tvg-name');
    if (noTag.trim().isNotEmpty && !noTag.startsWith('#')) return noTag.trim();
    if (name.isNotEmpty) return name;
    final ci = line.indexOf(',');
    return ci >= 0 ? line.substring(ci + 1).trim() : '';
  }

  static String _attr(String line, String key) {
    final m = RegExp('$key="([^"]*)"').firstMatch(line);
    return m?.group(1)?.trim() ?? '';
  }
}

class _Pending {
  final String name;
  final String logo;
  final String group;
  final String ua;
  final String id;

  /// Cabeceras tomadas de #EXTVLCOPT:http-* aplicadas al stream siguiente.
  final Map<String, String> headers = {};
  _Pending({
    required this.name,
    required this.logo,
    required this.group,
    required this.ua,
    required this.id,
  });
}
