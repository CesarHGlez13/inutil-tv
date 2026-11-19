import 'dart:convert';

import '../models/models.dart';
import 'net.dart';

/// Cliente Xtream Codes (player_api.php): credenciales usuario/contraseña.
class XtreamService {
  /// Devuelve los canales en vivo de una cuenta Xtream.
  static Future<List<Channel>> liveChannels(
      String host, String user, String pass) async {
    final base = _normalize(host);
    final api = '$base/player_api.php?username=$user&password=$pass';

    final catsBody = await Net.getText(Uri.parse('$api&action=get_live_categories'));
    final streamsBody =
        await Net.getText(Uri.parse('$api&action=get_live_streams'));

    final cats = (jsonDecode(catsBody) as List).cast<Map<String, dynamic>>();
    final streams =
        (jsonDecode(streamsBody) as List).cast<Map<String, dynamic>>();

    final catNames = <String, String>{
      for (final c in cats) c['category_id'].toString(): c['category_name'].toString(),
    };

    return streams.map((s) {
      final numId = s['stream_id'].toString();
      return Channel(
        id: 'xtream-$numId',
        name: s['name']?.toString() ?? 'Canal $numId',
        logo: s['stream_icon']?.toString() ?? '',
        group: catNames[s['category_id']?.toString()] ?? 'En vivo',
        sources: [
          StreamSource(url: '$base/live/$user/$pass/$numId.m3u8'),
          StreamSource(url: '$base/live/$user/$pass/$numId.ts'),
        ],
      );
    }).toList();
  }

  /// Verifica credenciales; lanza si son inválidas.
  static Future<void> authCheck(String host, String user, String pass) async {
    final base = _normalize(host);
    final body = await Net.getText(
        Uri.parse('$base/player_api.php?username=$user&password=$pass'));
    final j = jsonDecode(body) as Map<String, dynamic>;
    if (j['user_info']?['auth'] != 1) {
      throw Exception('Credenciales Xtream inválidas');
    }
  }

  static String _normalize(String host) {
    var h = host.trim();
    if (!h.startsWith('http')) h = 'http://$h';
    while (h.endsWith('/')) {
      h = h.substring(0, h.length - 1);
    }
    // quita /c o /player_api.php si el usuario pegó la URL completa
    h = h.replaceAll(RegExp(r'/(c|player_api\.php)/?$'), '');
    return h;
  }
}
