import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Caché en disco de los catálogos JSON descargados.
///
/// iptv-org mueve ~26 MB entre streams/channels/logos: sin caché cada arranque
/// vuelve a bajarlos todos (y en un móvil o un emulador eso tarda minutos).
/// Se guardan en el directorio de caché de la app con una caducidad corta.
class JsonCache {
  static const ttl = Duration(hours: 12);
  static const _prefix = 'tubotv_cache_';

  static String keyFor(String url) =>
      '$_prefix${url.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}';

  static Future<File> _file(String key) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/$key.json');
  }

  /// Devuelve el contenido cacheado si sigue vigente, o null.
  static Future<String?> read(String key) async {
    try {
      final f = await _file(key);
      if (!await f.exists()) return null;
      final mtime = await f.lastModified();
      if (DateTime.now().difference(mtime) > ttl) return null;
      return await f.readAsString();
    } catch (_) {
      return null; // caché best-effort: si falla, se descarga igual
    }
  }

  static Future<void> write(String key, String data) async {
    try {
      final f = await _file(key);
      await f.writeAsString(data, flush: true);
    } catch (_) {}
  }
}
