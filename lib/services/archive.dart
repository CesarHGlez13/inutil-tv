import 'dart:convert';

import '../models/models.dart';
import 'net.dart';

/// Catálogo de películas gratuitas y legales de Internet Archive
/// (dominio público + licencias abiertas). ~40 000 títulos.
class ArchiveService {
  static const _search = 'https://archive.org/advancedsearch.php';
  static const _meta = 'https://archive.org/metadata/';

  /// Búsqueda paginada. [query] vacío = más descargadas de cine gratuito.
  Future<List<ArchiveMovie>> search(String query, int page, int rows) async {
    final q = query.trim().isEmpty
        ? '(collection:feature_films OR collection:prelinger) AND mediatype:movies'
        : '(${query.trim()}) AND mediatype:movies AND (collection:feature_films OR collection:prelinger)';
    final uri = Uri.parse(_search).replace(queryParameters: {
      'q': q,
      'fl[]': ['identifier', 'title', 'downloads', 'year'],
      'sort[]': 'downloads desc',
      'rows': '$rows',
      'page': '${page + 1}',
      'output': 'json',
    });
    final body = await Net.getText(uri);
    final docs = (jsonDecode(body)['response']['docs'] as List)
        .cast<Map<String, dynamic>>();
    return docs
        .map((d) => ArchiveMovie(
              identifier: d['identifier'].toString(),
              title: _cleanTitle(d['title']?.toString()),
              downloads: int.tryParse('${d['downloads'] ?? 0}') ?? 0,
              year: _yearOf(d),
            ))
        .toList();
  }

  /// Obtiene las variantes reproducibles (MP4/HLS) de una película.
  Future<List<MovieVariant>> variants(ArchiveMovie movie) async {
    final meta = await Net.getJson(Uri.parse('$_meta${movie.identifier}'));
    final server = meta['server']?.toString() ?? 'archive.org';
    final dir = meta['dir']?.toString() ?? '';
    final files =
        (meta['files'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final vids = files.where((f) {
      final n = f['name']?.toString() ?? '';
      return n.endsWith('.mp4') || n.endsWith('.m3u8') || n.endsWith('.mkv');
    }).toList();

    final out = <MovieVariant>[];
    for (final f in vids) {
      final name = f['name'].toString();
      final size = int.tryParse('${f['size'] ?? 0}') ?? 0;
      final url = 'https://$server$dir/$name';
      out.add(MovieVariant(
        name: name,
        url: url,
        label: _labelFor(name),
        sizeBytes: size,
      ));
    }
    // Orden: HLS primero (arranque instantáneo), luego 512kb, luego resto.
    int order(MovieVariant v) {
      if (v.name.endsWith('.m3u8')) return 0;
      if (v.name.contains('512kb')) return 1;
      if (v.name.endsWith('.mp4')) return 2;
      if (v.name.endsWith('.mkv')) return 3;
      return 4;
    }

    out.sort((a, b) {
      final c = order(a).compareTo(order(b));
      return c != 0 ? c : a.sizeBytes.compareTo(b.sizeBytes);
    });
    return out;
  }

  /// URL del afiche. Internet Archive sirve un JPEG para CUALQUIER ítem en
  /// `https://archive.org/services/img/<id>` (resuelve internamente al
  /// `metadata/<id>_thumb.jpg` y devuelve un placeholder si el ítem no tiene
  /// miniatura propia).
  ///
  /// No se sondea el archivo: la antigua comprobación de
  /// `metadata/<id>.<ext>` respondía `{"error":"Couldn't get part ..."}` con
  /// HTTP 200 para casi todos los ítems, así que `asrc` nunca era válido y la
  /// rejilla de películas quedaba **sin ninguna miniatura**.
  Future<String> posterFor(ArchiveMovie movie) async =>
      'https://archive.org/services/img/${movie.identifier}';

  static String _labelFor(String name) {
    if (name.endsWith('.m3u8')) return 'HLS (rápido)';
    if (name.contains('1080')) return '1080p';
    if (name.contains('720')) return '720p';
    if (name.contains('512kb')) return '480p ligero';
    if (name.endsWith('.mkv')) return 'original MKV';
    return 'original';
  }

  static String _cleanTitle(String? t) {
    if (t == null) return '(sin título)';
    var s = t.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
    if (s.length > 90) s = '${s.substring(0, 87)}...';
    return s.isEmpty ? t.trim() : s;
  }

  static String _yearOf(Map<String, dynamic> d) {
    final y = d['year'];
    if (y is List && y.isNotEmpty) return y.first.toString();
    return y?.toString() ?? '';
  }
}
