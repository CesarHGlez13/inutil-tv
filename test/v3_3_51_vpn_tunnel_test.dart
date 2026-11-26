import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/anime_edge_route.dart';
import 'package:tubotv/services/inutil_vpn_tunnel.dart';
import 'package:tubotv/services/network_config_service.dart';

/// Servidor WebSocket falso que implementa el protocolo binario `/v1/tun` del
/// relay S7 (`[0x01][port:u16][len:u8][host]` -> `[0x00]` + TCP bidireccional).
class _FakeRelayTunnelServer {
  HttpServer? _server;
  final List<String> openedTargets = [];
  final List<String> seenAuthHeaders = [];
  String? requiredToken;

  int get port => _server!.port;
  String get wsUrl => 'ws://127.0.0.1:$port/v1/tun';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    seenAuthHeaders.add(auth);
    if (requiredToken != null && auth != 'Bearer $requiredToken') {
      req.response.statusCode = 401;
      await req.response.close();
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = 426;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    Socket? remote;
    var opened = false;

    ws.listen(
      (dynamic msg) async {
        if (msg is! List<int>) return;
        final data = Uint8List.fromList(msg);
        if (!opened) {
          opened = true;
          if (data.length < 5 || data[0] != 0x01) {
            ws.add(Uint8List.fromList([0x01, ...utf8.encode('bad_header')]));
            await ws.close();
            return;
          }
          final targetPort = (data[1] << 8) | data[2];
          final hostLen = data[3];
          final host = utf8.decode(data.sublist(4, 4 + hostLen));
          openedTargets.add('$host:$targetPort');
          try {
            remote = await Socket.connect(host, targetPort,
                timeout: const Duration(seconds: 5));
            ws.add(Uint8List.fromList([0x00]));
            remote!.listen(
              (chunk) {
                if (ws.readyState == WebSocket.open) {
                  ws.add(chunk);
                }
              },
              onDone: () => ws.close(),
              onError: (_) => ws.close(),
            );
          } catch (e) {
            ws.add(Uint8List.fromList([0x01, ...utf8.encode('$e')]));
            await ws.close();
          }
          return;
        }
        remote?.add(data);
      },
      onDone: () => remote?.destroy(),
      onError: (_) => remote?.destroy(),
    );
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides? prevOverrides;

  setUp(() async {
    prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    NetworkConfigService.instance.resetForTest();
    AnimeEdgeRoute.instance.resetForTest();
    await InutilVpnTunnel.instance.resetForTest();
  });

  tearDown(() async {
    await InutilVpnTunnel.instance.resetForTest();
    NetworkConfigService.instance.resetForTest();
    AnimeEdgeRoute.instance.resetForTest();
    HttpOverrides.global = prevOverrides;
  });

  test('proxy CONNECT y HTTP plano viajan cifrados por el túnel WSS', () async {
    // 1. Origen HTTP real local (simula un servidor de catálogo o stream)
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) async {
      req.response.statusCode = 200;
      req.response.headers.set('content-type', 'text/plain; charset=utf-8');
      req.response.write('CATALOGO_OK:${req.uri.path}?${req.uri.query}');
      await req.response.close();
    });

    // 2. Origen TCP raw para probar túnel CONNECT bidireccional (simula TLS)
    final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    echo.listen((s) {
      s.listen(
        (d) => s.add(Uint8List.fromList([...utf8.encode('ECHO:'), ...d])),
        onDone: () => s.destroy(),
      );
    });

    // 3. Servidor túnel WSS falso
    final relay = _FakeRelayTunnelServer()..requiredToken = 'jwt-valido-123';
    await relay.start();

    try {
      var refreshCalled = false;
      InutilVpnTunnel.instance.configureForTest(
        endpoint: relay.wsUrl,
        tokenProvider: ({bool forceRefresh = false}) async {
          if (forceRefresh) {
            refreshCalled = true;
            return 'jwt-valido-123';
          }
          // Primera llamada devuelve token vencido para probar auto-refresh en 401
          return refreshCalled ? 'jwt-valido-123' : 'jwt-expirado';
        },
      );

      final started = await InutilVpnTunnel.instance.ensureStarted();
      expect(started, isTrue);
      expect(InutilVpnTunnel.instance.localPort, greaterThan(0));

      // A) Petición HTTP plana usando HttpClient apuntando al proxy local VPN
      final client = HttpClient();
      client.findProxy = (_) =>
          'PROXY ${InutilVpnTunnel.instance.localProxyHostPort}';
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${origin.port}/directorio?q=naruto'),
      );
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      client.close(force: true);

      expect(res.statusCode, 200);
      expect(body, 'CATALOGO_OK:/directorio?q=naruto');
      expect(refreshCalled, isTrue,
          reason: 'Ante 401 del servidor VPN debe refrescar el JWT automáticamente');
      expect(relay.openedTargets, contains('127.0.0.1:${origin.port}'));

      // B) Túnel CONNECT raw (idéntico al que usa HTTPS y libmpv)
      final sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        InutilVpnTunnel.instance.localPort,
      );
      final received = BytesBuilder();
      final done = Completer<String>();
      sock.listen(
        (chunk) {
          received.add(chunk);
          final text = latin1.decode(received.toBytes());
          if (text.contains('ECHO:HOLA_TLS')) {
            if (!done.isCompleted) done.complete(text);
          }
        },
      );
      sock.add(ascii.encode(
          'CONNECT 127.0.0.1:${echo.port} HTTP/1.1\r\nHost: 127.0.0.1:${echo.port}\r\n\r\n'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      sock.add(utf8.encode('HOLA_TLS'));
      final text = await done.future.timeout(const Duration(seconds: 5));
      sock.destroy();

      expect(text, startsWith('HTTP/1.1 200 Connection Established\r\n\r\n'));
      expect(text, contains('ECHO:HOLA_TLS'));
      expect(relay.openedTargets, contains('127.0.0.1:${echo.port}'));

      // C) Sonda real del túnel (`probeTunnel`)
      final probe = await InutilVpnTunnel.instance.probeTunnel(
        probeHost: '127.0.0.1',
        probePort: echo.port,
      );
      expect(probe.ok, isTrue);
      expect(probe.millis, greaterThanOrEqualTo(0));
    } finally {
      await origin.close(force: true);
      await echo.close();
      await relay.close();
    }
  });

  test('NetworkConfigService enruta tráfico externo por VPN y excluye bucles',
      () async {
    final ok = await NetworkConfigService.instance.setVpnTunnelEnabled(true);
    expect(ok, isTrue);
    expect(NetworkConfigService.instance.vpnTunnelActive, isTrue);

    final localProxy = InutilVpnTunnel.instance.localProxyHostPort;
    final net = NetworkConfigService.instance;

    // Proveedores y CDNs externos -> SIEMPRE entran al túnel VPN
    expect(
      net.resolveProxyDirectiveForUri(Uri.parse('https://jkanime.net/directorio')),
      'PROXY $localProxy',
    );
    expect(
      net.resolveProxyDirectiveForUri(Uri.parse('https://tioanime.com/directorio')),
      'PROXY $localProxy',
    );
    expect(
      net.resolveProxyDirectiveForUri(Uri.parse('https://serieskao.top/animes')),
      'PROXY $localProxy',
    );
    expect(
      net.resolveProxyDirectiveForUri(Uri.parse('http://vidcache.net:8161/stream.mp4')),
      'PROXY $localProxy',
    );

    // Exenciones obligatorias (evitar bucles y permitir Auth/LAN)
    expect(
      net.resolveProxyDirectiveForUri(Uri.parse('https://api.inutix.com/v1/tun')),
      'DIRECT',
    );
    expect(
      net.resolveProxyDirectiveForUri(Uri.parse('https://backup.inutix.com/healthz')),
      'DIRECT',
    );
    expect(
      net.resolveProxyDirectiveForUri(Uri.parse('http://127.0.0.1:45678/seg/0.ts')),
      'DIRECT',
    );
    expect(
      net.resolveProxyDirectiveForUri(Uri.parse('http://192.168.100.27:8080/healthz')),
      'DIRECT',
    );
    expect(
      net.resolveProxyDirectiveForUri(
        Uri.parse('https://securetoken.googleapis.com/v1/token'),
      ),
      'DIRECT',
    );

    // libmpv también recibe el túnel para streams remotos, pero DIRECT para proxy HLS local
    expect(net.mpvProxyUrl, 'http://$localProxy');
    expect(
      NetworkConfigService.mpvProxyForUrl('https://cdn.jkdesa.com/video.m3u8'),
      'http://$localProxy',
    );
    expect(
      NetworkConfigService.mpvProxyForUrl('http://127.0.0.1:41234/master.m3u8'),
      isNull,
    );

    // AnimeEdgeRoute NO desvía al Worker de Cloudflare cuando el Modo VPN está activo
    expect(AnimeEdgeRoute.instance.shouldUseEdge('tioAnime'), isFalse);
    expect(AnimeEdgeRoute.instance.shouldUseEdge('seriesKao'), isFalse);
    expect(AnimeEdgeRoute.instance.shouldUseEdge('jkAnime'), isFalse);

    // Al apagar el Modo VPN, se detiene el proxy local y vuelve a DIRECT
    await net.setVpnTunnelEnabled(false);
    expect(net.vpnTunnelActive, isFalse);
    expect(InutilVpnTunnel.instance.isRunning, isFalse);
    expect(
      net.resolveProxyDirectiveForUri(Uri.parse('https://jkanime.net/directorio')),
      'DIRECT',
    );
    expect(net.mpvProxyUrl, isNull);
  });
}
