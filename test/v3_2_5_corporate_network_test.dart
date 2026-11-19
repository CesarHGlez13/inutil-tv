import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/screens/player_screen.dart';
import 'package:tubotv/services/network_config_service.dart';

/// Red en entornos restringidos (v3.2.5): WiFi de empresa, hoteles y
/// aeropuertos donde el DNS filtra, hay proxy obligatorio o se inspecciona TLS.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await NetworkConfigService.instance.load(force: true);
    await NetworkConfigService.instance.setProxy('');
  });

  group('NetworkConfigService', () {
    test('arranca con DNS seguro y tolerancia TLS activados', () {
      final net = NetworkConfigService.instance;
      expect(net.secureDnsEnabled, isTrue);
      expect(net.tlsFallbackEnabled, isTrue);
      expect(net.proxyEnabled, isFalse);
      expect(net.mpvProxyUrl, isNull);
      expect(
        net.restrictionsActive,
        isTrue,
        reason: 'DNS seguro viene activado de fábrica',
      );
    });

    test('en flutter test no se toca la red real ni se instalan overrides', () {
      expect(NetworkConfigService.hermeticTestEnvironment, isTrue);
      // No debe lanzar ni romper el entorno de pruebas.
      NetworkConfigService.instance.installGlobalOverride();
    });

    test('proxy: normaliza, alimenta a libmpv y se puede borrar', () async {
      final net = NetworkConfigService.instance;

      expect(await net.setProxy('192.168.1.10:3128'), isNull);
      expect(net.proxyHostPort, '192.168.1.10:3128');
      expect(net.mpvProxyUrl, 'http://192.168.1.10:3128');
      expect(net.restrictionsActive, isTrue);

      expect(await net.setProxy('http://proxy.oficina.com:8080/'), isNull);
      expect(net.proxyHostPort, 'proxy.oficina.com:8080');

      // Sin puerto -> asume el estándar 3128.
      expect(await net.setProxy('proxy.oficina.com'), isNull);
      expect(net.proxyHostPort, 'proxy.oficina.com:3128');

      expect(await net.setProxy(''), isNull);
      expect(net.proxyEnabled, isFalse);
      expect(net.mpvProxyUrl, isNull);
    });

    test('proxy: texto inválido no borra el valor anterior', () async {
      final net = NetworkConfigService.instance;
      await net.setProxy('192.168.1.10:3128');

      expect(await net.setProxy('con espacios:3128'), isNotNull);
      expect(net.proxyHostPort, '192.168.1.10:3128');

      expect(await net.setProxy('proxy.oficina.com:99999'), isNotNull);
      expect(net.proxyHostPort, '192.168.1.10:3128');
    });

    test('proxy e interruptores sobreviven a un reinicio de la app', () async {
      final net = NetworkConfigService.instance;
      await net.setProxy('10.0.0.5:8080');
      await net.setSecureDnsEnabled(false);
      await net.setTlsFallbackEnabled(false);

      await net.load(force: true);
      expect(net.proxyHostPort, '10.0.0.5:8080');
      expect(net.secureDnsEnabled, isFalse);
      expect(net.tlsFallbackEnabled, isFalse);
      expect(net.restrictionsActive, isTrue);
    });

    test('el consejo del reproductor se expresa sin tecnicismos', () async {
      final net = NetworkConfigService.instance;

      net.lastIssueForTest = NetworkIssue.none;
      expect(net.playbackHint, isNull);

      // DNS filtrado y el usuario con "DNS seguro" apagado.
      await net.setSecureDnsEnabled(false);
      net.lastIssueForTest = NetworkIssue.dnsBlocked;
      final hintSinDoh = net.playbackHint!;
      expect(hintSinDoh, contains('Búsqueda segura'));
      expect(hintSinDoh, isNot(contains('DoH')));
      expect(hintSinDoh, isNot(contains('DNS-over-HTTPS')));

      // Con DNS seguro activo y sin proxy, la sugerencia correcta es el proxy.
      await net.setSecureDnsEnabled(true);
      await net.setProxy('');
      net.lastIssueForTest = NetworkIssue.dnsBlocked;
      expect(net.playbackHint, contains('proxy'));

      // Proxy mal escrito o caído.
      net.lastIssueForTest = NetworkIssue.proxyUnreachable;
      expect(net.playbackHint, contains('proxy'));

      // Red que cifra el tráfico, con la opción desactivada.
      await net.setTlsFallbackEnabled(false);
      net.lastIssueForTest = NetworkIssue.tlsInspected;
      expect(net.playbackHint, contains('Redes que revisan el tráfico'));
    });

    test('el informe de conexión cuenta los frentes fallidos', () {
      const ok = NetworkCheck(label: 'Video', ok: true, millis: 120);
      const slow = NetworkCheck(label: 'Catálogo', ok: true, millis: 900);
      const dead = NetworkCheck(
        label: 'Cuenta',
        ok: false,
        millis: 6000,
        detail: 'bloqueado',
      );
      final report = const NetworkReport([ok, slow, dead], false, true);
      expect(report.allOk, isFalse);
      expect(report.failures, 1);
      expect(report.viaSecureDns, isTrue);
      expect(report.viaProxy, isFalse);
      expect(const NetworkReport([ok, slow], true, false).allOk, isTrue);
    });
  });

  group('Proxy local de reproducción', () {
    test('conserva la extensión real para que libmpv elija el demuxer', () {
      expect(
        PlayerScreen.directFileExtension(
          'https://cdn.example.com/a/video.mkv?t=1',
        ),
        'mkv',
      );
      expect(
        PlayerScreen.directFileExtension('https://cdn.example.com/a/clip.webm'),
        'webm',
      );
      // Sin extensión o URL rara: se asume mp4 (comportamiento anterior).
      expect(
        PlayerScreen.directFileExtension('https://cdn.example.com/a/clip'),
        'mp4',
      );
      expect(PlayerScreen.directFileExtension('no-es-una-url'), 'mp4');
    });
  });
}
