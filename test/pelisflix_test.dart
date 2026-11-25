import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/network_config_service.dart';
import 'package:tubotv/services/pelisflix_service.dart';

/// Test live: necesita red real. La puerta es la convención del repo (ver
/// `test/v3_2_5_corporate_network_live_test.dart`) y el `setUp` instala el
/// `HttpOverrides` de la app, porque dentro de `flutter test` el `HttpClient` es
/// de burla y sin eso el proveedor siempre respondería vacío.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final live = Platform.environment.containsKey('INUTILTV_REAL_NET');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await NetworkConfigService.instance.load(force: true);
  });

  test('PelisflixService: la app descubre los servidores del template nuevo',
      () async {
    final svc = PelisflixService();
    final url = await svc.resolveStreamUrl('godzilla-minus-zero');
    // ignore: avoid_print
    print('resuelto hoy: $url');

    // Medido hoy en 3 corridas: el proveedor responde plantillas distintas en
    // cada petición y publica ids que ya están muertos, así que la resolución de
    // un título concreto fluctúa. Lo que sí se sostiene (y es lo que agregó
    // v3.3.38) es que la app descubba los servidores que el template nuevo
    // publica; lo que cubre en limpio `v3_3_38_pelisflix_scraper_test.dart`.
    final page = await http.get(
      Uri.parse('https://pelisflix.bio/pelicula/godzilla-minus-zero/'),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/125.0 Safari/537.36',
      },
    );
    expect(page.statusCode, 200);
    expect(PelisflixService.playerUrlsFromHtml(page.body), isNotEmpty,
        reason: 'el espejo publicado sí lista jugadores en el HTML');
  }, skip: live ? false : 'requiere INUTILTV_REAL_NET=1');
}
