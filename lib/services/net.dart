import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cache.dart';

/// Cliente HTTP con User-Agent de navegador y reintentos cortos.
class Net {
  static const ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36 InutilTV/1.4';

  static Future<String> getText(Uri uri,
      {int attempts = 3, Duration timeout = const Duration(seconds: 25)}) async {
    Object? lastError;
    for (var i = 0; i < attempts; i++) {
      try {
        final res = await http
            .get(uri, headers: {'User-Agent': ua, 'Accept-Language': 'es'})
            .timeout(timeout);
        if (res.statusCode == 200) {
          return utf8.decode(res.bodyBytes, allowMalformed: true);
        }
        lastError = 'HTTP ${res.statusCode}';
      } catch (e) {
        lastError = e;
      }
      await Future.delayed(Duration(milliseconds: 400 * (i + 1)));
    }
    throw Exception('Fallo de red: $lastError ($uri)');
  }

  static Future<Map<String, dynamic>> getJson(Uri uri,
      {int attempts = 3}) async {
    final body = await getText(uri, attempts: attempts);
    return jsonDecode(body) as Map<String, dynamic>;
  }

  static Future<List<dynamic>> getJsonList(Uri uri, {int attempts = 3}) async {
    final body = await getText(uri, attempts: attempts);
    return jsonDecode(body) as List<dynamic>;
  }

  /// Descarga [uri] con caché en disco y devuelve el cuerpo en crudo (texto).
  /// El llamador decide cuándo parsear: así el JSON de 26 MB se puede procesar
  /// en un isolate aparte y no bloquear la interfaz.
  static Future<String> getTextCached(Uri uri, {int attempts = 3}) async {
    final key = JsonCache.keyFor(uri.toString());
    final hit = await JsonCache.read(key);
    if (hit != null && hit.isNotEmpty) return hit;
    final body = await getText(uri, attempts: attempts);
    unawaited(JsonCache.write(key, body));
    return body;
  }

  /// Igual que [getJsonList] pero guardando la respuesta en disco: los
  /// catálogos de iptv-org pesan ~26 MB y no hace falta bajarlos en cada
  /// arranque (ver JsonCache).
  static Future<List<dynamic>> getJsonListCached(Uri uri,
      {int attempts = 3}) async {
    final key = JsonCache.keyFor(uri.toString());
    final hit = await JsonCache.read(key);
    if (hit != null) {
      try {
        return jsonDecode(hit) as List<dynamic>;
      } catch (_) {
        // caché corrupto: se vuelve a descargar
      }
    }
    final body = await getText(uri, attempts: attempts);
    unawaited(JsonCache.write(key, body));
    return jsonDecode(body) as List<dynamic>;
  }
}
