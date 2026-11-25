import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/services/pelisflix_service.dart';

/// Cobertura determinista (sin red) del scraper de PelisFlix de v3.3.38. Los
/// fixtures son markup copiado del proveedor vivo: `data-url` en base64 (el
/// template viejo), `<option value="http...">` (el de ahora) y el envoltorio
/// `?url=` codificado con el que el proveedor mete un servidor dentro de otro.
/// La vida contra el proveedor está en los tests live `pelisflix_test.dart` y
/// `pelisflix_multi_test.dart`, que sólo corren con `INUTILTV_REAL_NET=1`.
void main() {
  const fixture = '''
    <select id="player-language">
      <option value="https://nupload.my/iframe/?url=https%3A%2F%2Fvoe.sx%2Fe%2Fydkms3ntcq5k" data-language="0">Opción 2</option>
    </select>
    <li data-url="aHR0cHM6Ly9udXBsb2FkLm15L3dhdGNoL09MRElEMTIz">
      <a href="https://pelisflix1.team/pelicula/x/"><div class="Title">X</div></a>
    </li>
  ''';

  test('saca los servidores del template nuevo y del viejo', () {
    final urls = PelisflixService.playerUrlsFromHtml(fixture);
    expect(urls, contains('https://nupload.my/watch/OLDID123'),
        reason: 'el template viejo seguía publicando data-url en base64');
    expect(
      urls,
      contains(
        'https://nupload.my/iframe/?url=https%3A%2F%2Fvoe.sx%2Fe%2Fydkms3ntcq5k',
      ),
    );
    expect(urls, contains('https://voe.sx/e/ydkms3ntcq5k'),
        reason: 'el servidor real es el que va adentro del envoltorio');
    expect(urls.length, 3);
  });

  test('una página sin jugadores no inventa servidores', () {
    expect(
      PelisflixService.playerUrlsFromHtml('<html><body><p>hueco</p></body></html>'),
      isEmpty,
    );
  });

  test('sigue el salto que VOE manda dar al navegador', () {
    const voePage = '''
      <script>
        if (typeof localStorage !== 'undefined') {
          const permanentToken = localStorage.getItem('permanentToken');
          if (permanentToken) { window.location.href = currentUrl.toString(); }
        } else {
          window.location.href = 'https://caseyseemavoid.com/e/ydkms3ntcq5k';
        }
      </script>
    ''';
    expect(PelisflixService.voeHopUrl(voePage),
        'https://caseyseemavoid.com/e/ydkms3ntcq5k');
    expect(PelisflixService.voeHopUrl('<html><body>sin salto</body></html>'), isNull);
  });

  test('la nota de 3.3.38 y whatsNewHighlights no revelan proveedores ni detalles internos', () {
    const forbiddenTerms = [
      'pelisflix',
      'jkanime',
      'cuevana',
      'poseidon',
      'animeflv',
      'tioanime',
      'streamwish',
      'filemoon',
      'doodstream',
      'vidhide',
      'tmdb',
      'fanart',
      'proveedor',
      'espejo',
      'scraper',
      'VOE',
      'Nupload',
      'base64',
      'JS',
      'X-Admin-Secret',
      'firebase_admin',
      'Panel Admin',
      'Firestore',
      'libmpv',
    ];
    final full = File('CHANGELOG.md').readAsStringSync();
    final start = full.indexOf('## 3.3.38');
    expect(start, greaterThan(0));
    final end = full.indexOf('## 3.3.37', start);
    expect(end, greaterThan(start));
    final entry = full.substring(start, end);
    final highlights = AppInfo.whatsNewHighlights.join('\n');
    for (final term in forbiddenTerms) {
      expect(entry.toLowerCase(), isNot(contains(term.toLowerCase())),
          reason: 'CHANGELOG 3.3.38 no debe exponer $term');
      expect(highlights.toLowerCase(), isNot(contains(term.toLowerCase())),
          reason: 'AppInfo.whatsNewHighlights no debe exponer $term');
    }
  });
}
