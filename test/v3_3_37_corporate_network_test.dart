import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/services/network_config_service.dart';

/// v3.3.37 — Redes corporativas (empresas, hoteles, aeropuertos) donde el
/// Wi-Fi filtra el video: DNS envenenado, proxy obligatorio o tráfico cifrado
/// por el propio firewall. La app se arregla sola, sin pedirle VPN al usuario.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NetworkConfigService.instance.resetForTest();
    await NetworkConfigService.instance.setProxy('');
  });

  tearDown(() async {
    NetworkConfigService.instance.resetForTest();
    await NetworkConfigService.instance.setProxy('');
  });

  group('Modo corporativo detectado solo', () {
    test('una red con proxy del sistema se reconoce como corporativa', () {
      final net = NetworkConfigService.instance;
      expect(net.corporateModeActive, isFalse,
          reason: 'en casa no debe activarse nada distinto');

      net.setSystemProxyForTest('proxy.empresa.local:8080');
      expect(net.systemProxyDetected, isTrue);
      expect(net.corporateModeActive, isTrue);
      expect(net.effectiveProxyHostPort, 'proxy.empresa.local:8080');
    });

    test(
        'en red corporativa el DNS cifrado usa primero las IPs de los '
        'resolutores, porque el DNS de la empresa no deja resolver su nombre',
        () async {
      final net = NetworkConfigService.instance;

      net.setSystemProxyForTest('proxy.empresa.local:8080');
      final corporate = net.dohEndpointsForAssertions;
      expect(corporate.first, startsWith('https://1.1.1.1/'));
      expect(corporate[1], startsWith('https://1.0.0.1/'));
      expect(corporate, contains('https://8.8.8.8/resolve'));
      expect(corporate, contains('https://dns.google/resolve'),
          reason: 'los entornos de nombre siguen disponibles como respaldo');

      net.resetForTest();
      await net.setProxy('');
      final normal = net.dohEndpointsForAssertions;
      expect(normal.first, 'https://cloudflare-dns.com/dns-query',
          reason: 'en red doméstica se mantiene la ruta rápida de siempre');
    });

    test('el proxy de la red aplica incluso al propio DNS cifrado', () {
      final net = NetworkConfigService.instance;
      net.setSystemProxyForTest('proxy.empresa.local:8080');

      expect(net.resolveProxyDirectiveForUri(Uri.parse('https://1.1.1.1/')),
          'PROXY proxy.empresa.local:8080');
      expect(
          net.resolveProxyDirectiveForUri(
              Uri.parse('https://cloudflare-dns.com/dns-query')),
          'PROXY proxy.empresa.local:8080');
    });

    test('el proxy local de reproducción nunca sale por el proxy de la red',
        () {
      final net = NetworkConfigService.instance;
      net.setSystemProxyForTest('proxy.empresa.local:8080');

      expect(
          net.resolveProxyDirectiveForUri(
              Uri.parse('http://127.0.0.1:43210/s/abc/master.m3u8')),
          'DIRECT');
      expect(
          net.resolveProxyDirectiveForUri(
              Uri.parse('http://localhost:43210/v/xyz/video.mp4')),
          'DIRECT');
      expect(
          net.resolveProxyDirectiveForUri(
              Uri.parse('http://[::1]:43210/s/abc/master.m3u8')),
          'DIRECT');
    });

    test('libmpv recibe proxy sólo para lo que sale de la máquina', () {
      final net = NetworkConfigService.instance;
      net.setSystemProxyForTest('proxy.empresa.local:8080');

      // Lo que reproduce libmpv desde nuestro proxy local: directo, si no el
      // proxy corporativo intentaría descargar desde el teléfono.
      expect(
          NetworkConfigService.mpvProxyForUrl(
              'http://127.0.0.1:43210/s/abc/master.m3u8'),
          isNull);
      // Lo que sí sale a la red: el proxy de la empresa.
      expect(
          NetworkConfigService.mpvProxyForUrl(
              'https://cdn.epicsports.com/a/video.mkv'),
          'http://proxy.empresa.local:8080');
      expect(
          NetworkConfigService.mpvProxyForUrl('https://jkanime.net/video.mp4'),
          'http://proxy.empresa.local:8080');

      // En casa, sin proxy, todo sigue igual que antes.
      net.resetForTest();
      expect(NetworkConfigService.mpvProxyForUrl('https://jkanime.net/x.mp4'),
          isNull);
    });

    test(
        'el DNS cifrado acepta el certificado de la red sólo si la red '
        'muestra señales de inspeccionar', () async {
      final net = NetworkConfigService.instance;
      expect(net.dohToleratesCertificates, isFalse,
          reason: 'en una red normal se mantiene la validación estricta');

      net.setSystemProxyForTest('proxy.empresa.local:8080');
      expect(net.dohToleratesCertificates, isTrue);

      await net.setTlsFallbackEnabled(false);
      expect(net.dohToleratesCertificates, isFalse,
          reason: 'el usuario pidió validación estricta');
    });

    test('la comprobación de conexión incluye el frente del DNS cifrado', () {
      final src =
          File('lib/services/network_config_service.dart').readAsStringSync();
      expect(src, contains("'DNS cifrado'"));
      expect(src, contains('https://1.1.1.1/dns-query'));
      expect(src, contains('https://8.8.8.8/resolve'));
    });
  });

  group('v3.3.37 — Changelog y versión sincronizados', () {
    const forbiddenTerms = [
      'X-Admin-Secret',
      'firebase_admin',
      'Panel Admin',
      'Firestore',
      'SQLite',
      'Cloudflare Workers',
      'app_config/',
      'mipmap-',
      'libmpv',
      'EWMA',
    ];

    test('la versión viva está en los 3 sitios', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match =
          RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)', multiLine: true)
              .firstMatch(pubspec);
      expect(match, isNotNull);
      final viva = match!;
      expect(viva.group(1), '3.3.42');
      expect(viva.group(2), '91');
      expect(AppInfo.appVersion, '3.3.42');
      expect(File('CHANGELOG.md').readAsStringSync(), contains('## 3.3.42'));
    });

    test('la nota de 3.3.37 no expone detalles administrativos ni internos',
        () {
      final full = File('CHANGELOG.md').readAsStringSync();
      final start = full.indexOf('## 3.3.37');
      expect(start, greaterThan(0));
      final end = full.indexOf('## 3.3.36', start);
      expect(end, greaterThan(start));
      final entry = full.substring(start, end).toLowerCase();

      for (final term in forbiddenTerms) {
        expect(entry, isNot(contains(term.toLowerCase())),
            reason: 'El changelog de usuario no debe mencionar "$term"');
      }
    });

    test('AppInfo.whatsNewHighlights sigue siendo 100% para el usuario', () {
      expect(AppInfo.whatsNewHighlights, isNotEmpty);
      final joined = AppInfo.whatsNewHighlights.join('\n').toLowerCase();
      for (final term in forbiddenTerms) {
        expect(joined, isNot(contains(term.toLowerCase())));
      }
    });
  });
}
