import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/network_config_service.dart';

/// Verificación REAL (con sockets de verdad, sin burlas) del motor de red de
/// InútilTV v3.2.5: DNS seguro, proxy de empresa y redes que inspeccionan el
/// tráfico.
///
/// Se corre sólo cuando se pide explícitamente:
///   INUTILTV_REAL_NET=1 flutter test test/v3_2_5_corporate_network_live_test.dart
///
/// Los servidores locales (bucle interno) siempre se usan en ese modo. El
/// grupo contra internet se salta solo si el equipo donde corre el test no
/// tiene salida real, para que el test siga sirviendo en máquinas sin red.
void main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final live = Platform.environment.containsKey('INUTILTV_REAL_NET');
  final net = NetworkConfigService.instance;

  /// El ejecutor de pruebas de Flutter suele estar aislado de internet y,
  /// ademas, Flutter sustituye HttpClient por uno de burla dentro de las
  /// pruebas. Por eso la puerta de los grupos remotos se mide con sockets
  /// directos, sin pasar por HttpClient.
  final reachable = live
      ? await Future.wait(const [
          'api.github.com',
          'cloudflare-dns.com',
          'dns.google',
          'firestore.googleapis.com',
          'www.themoviedb.org',
          'jkanime.net',
          'github.com',
        ].map(_tlsReachable))
      : const <bool>[];
  final internetViva = live && reachable.first;
  final dohVivo = live && reachable[1] && reachable[2];
  final diagnosticoVivo = live && reachable.every((ok) => ok);
  // ignore: avoid_print
  print('live=$live alcanzables=${reachable.asMap().entries
      .where((e) => e.value)
      .map((e) => const [
            'api.github.com',
            'cloudflare-dns.com',
            'dns.google',
            'firestore.googleapis.com',
            'www.themoviedb.org',
            'jkanime.net',
            'github.com',
          ][e.key])
      .join(' ')}');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Con INUTILTV_REAL_NET=1 esto instala además el HttpOverrides.global que
    // usa la app, así las peticiones de abajo salen como salen en el móvil.
    await net.load(force: true);
    net.resetForTest();
    await net.setProxy('');
    await net.setSecureDnsEnabled(true);
    await net.setTlsFallbackEnabled(true);
  });

  tearDown(() async {
    net.resetForTest();
    await net.setProxy('');
  });

  group('motor de red con servidores locales', () {
    test('el modo live no es hermético', () {
      expect(NetworkConfigService.hermeticTestEnvironment, isFalse);
    }, skip: live ? false : 'requiere INUTILTV_REAL_NET=1');

    test(
      'DNS seguro: consulta, analiza, cachea y no repite consultas',
      () async {
        final stub = await _DohStub.start();
        try {
          net.dohEndpointsForTest = ['http://127.0.0.1:${stub.port}/dns-query'];

          final ip = await net.resolve('peliculas.inutiltv.tv');
          expect(ip, '203.0.113.7', reason: 'Debe venir la IP del servidor');
          expect(
            stub.queries.where((q) => q == 'peliculas.inutiltv.tv').length,
            1,
          );

          // Segunda vez: sale de la caché, sin molestar a la red.
          expect(await net.resolve('peliculas.inutiltv.tv'), ip);
          expect(
            stub.queries.where((q) => q == 'peliculas.inutiltv.tv').length,
            1,
          );

          // Dos peticiones a la vez del mismo nombre = una sola consulta.
          final dobles = await Future.wait([
            net.resolve('lento.inutiltv.tv'),
            net.resolve('lento.inutiltv.tv'),
          ]);
          expect(dobles, ['203.0.113.9', '203.0.113.9']);
          expect(
            stub.queries.where((q) => q == 'lento.inutiltv.tv').length,
            1,
            reason: 'las consultas simultaneas se agrupan',
          );

          // Dominio muerto: responde "no existe", pero el DNS seguro sigue vivo.
          expect(await net.resolve('muerto.inutiltv.tv'), isNull);
          expect(
            net.secureDnsWorking,
            isTrue,
            reason: 'un dominio muerto no debe apagar el DNS seguro',
          );
        } finally {
          await stub.close();
        }
      },
      skip: live ? false : 'requiere INUTILTV_REAL_NET=1',
    );

    test(
      'DNS seguro: si ningún entorno responde se deja de intentar',
      () async {
        net.dohEndpointsForTest = [
          'http://127.0.0.1:1/dns-query',
          'http://127.0.0.1:2/dns-query',
        ];

        final sw = Stopwatch()..start();
        expect(await net.resolve('peliculas.inutiltv.tv'), isNull);
        sw.stop();
        expect(net.secureDnsWorking, isFalse);
        expect(
          sw.elapsedMilliseconds,
          lessThan(1500),
          reason: 'un DNS caido no debe hacer esperar al usuario',
        );

        // Ya descartado: la siguiente respuesta es inmediata.
        final sw2 = Stopwatch()..start();
        expect(await net.resolve('otro.inutiltv.tv'), isNull);
        sw2.stop();
        expect(sw2.elapsedMilliseconds, lessThan(200));
      },
      skip: live ? false : 'requiere INUTILTV_REAL_NET=1',
    );

    test(
      'proxy de la red: CONNECT y bytes reales a traves del tunel',
      () async {
        final origin = await _SelfSignedServer.start();
        final proxy = await _ConnectProxy.start();
        try {
          expect(await net.setProxy('127.0.0.1:${proxy.port}'), isNull);
          expect(net.mpvProxyUrl, 'http://127.0.0.1:${proxy.port}');
          // Con proxy, el nombre lo resuelve el proxy: el DNS seguro no estorba.
          expect(await net.resolve('peliculas.inutiltv.tv'), isNull);

          // Cliente como el del video: tolera el certificado del firewall.
          final client = HttpClient();
          net.apply(client, tolerateBadCertificates: true);
          try {
            final req = await client
                .getUrl(Uri.parse('https://localhost:${origin.port}/'));
            final res = await req.close().timeout(const Duration(seconds: 12));
            final body = await utf8.decoder.bind(res).join();
            expect(res.statusCode, 200);
            expect(body, contains('ok'));
          } finally {
            client.close(force: true);
          }

          // El trafico salio por el proxy y el certificado se valido contra el
          // servidor de destino, no contra el proxy.
          expect(proxy.tunnels, contains('localhost:${origin.port}'));
        } finally {
          await proxy.close();
          await origin.close();
          await net.setProxy('');
        }
      },
      skip: live ? false : 'requiere INUTILTV_REAL_NET=1',
    );

    test(
      'proxy caido: falla rapido y el consejo apunta al proxy',
      () async {
        expect(await net.setProxy('127.0.0.1:1'), isNull);

        final sw = Stopwatch()..start();
        final client = HttpClient();
        Object? fallo;
        try {
          final req = await client.getUrl(Uri.parse('https://localhost:9/'));
          await req.close().timeout(const Duration(seconds: 12));
        } catch (e) {
          fallo = e;
        } finally {
          client.close(force: true);
        }
        sw.stop();

        expect(fallo, isNotNull, reason: 'un proxy muerto debe fallar');
        expect(
          sw.elapsedMilliseconds,
          lessThan(4000),
          reason: 'no debe esperarse el timeout completo',
        );
        expect(net.lastIssue, NetworkIssue.proxyUnreachable);
        expect(net.playbackHint, contains('proxy'));
      },
      skip: live ? false : 'requiere INUTILTV_REAL_NET=1',
    );

    test(
      'red que revisa el trafico: detecta, reintenta y apagada la opcion falla',
      () async {
        final firewall = await _SelfSignedServer.start();
        try {
          // Sin DNS seguro para que la prueba vaya directa al servidor local.
          await net.setSecureDnsEnabled(false);

          final client = HttpClient();
          try {
            final req = await client
                .getUrl(Uri.parse('https://localhost:${firewall.port}/'));
            final res = await req.close().timeout(const Duration(seconds: 12));
            final body = await utf8.decoder.bind(res).join();
            expect(res.statusCode, 200,
                reason: 'el reintento debe dejar pasar el video');
            expect(body, contains('ok'));
          } finally {
            client.close(force: true);
          }
          expect(net.lastIssue, NetworkIssue.tlsInspected);
          expect(net.tlsFallbackEnabled, isTrue);

          // Con la opcion apagada, la misma red vuelve a estar cortada.
          await net.setTlsFallbackEnabled(false);
          final estricto = HttpClient();
          Object? fallo;
          try {
            final req = await estricto
                .getUrl(Uri.parse('https://localhost:${firewall.port}/'));
            await req.close().timeout(const Duration(seconds: 12));
          } catch (e) {
            fallo = e;
          } finally {
            estricto.close(force: true);
          }
          expect(fallo, isA<HandshakeException>());
          expect(net.playbackHint, contains('Redes que revisan el tráfico'));
        } finally {
          await firewall.close();
          await net.setSecureDnsEnabled(true);
          await net.setTlsFallbackEnabled(true);
        }
      },
      skip: live ? false : 'requiere INUTILTV_REAL_NET=1',
    );
  });

  group('motor de red contra internet real', () {
    test(
      'DNS seguro resuelve de verdad un dominio real',
      () async {
        final ip = await net.resolve('api.github.com');
        expect(
          ip,
          matches(r'^\d{1,3}(\.\d{1,3}){3}$'),
          reason: 'Debe devolver la IP publica real',
        );
        expect(await net.resolve('api.github.com'), ip);
        expect(net.secureDnsWorking, isTrue);
      },
      skip: dohVivo ? false : 'sin acceso a los servidores de DNS seguro',
    );

    test(
      'HTTPS real funciona con el motor de red instalado',
      () async {
        final client = HttpClient();
        try {
          final req =
              await client.getUrl(Uri.parse('https://api.github.com/zen'));
          final res = await req.close().timeout(const Duration(seconds: 15));
          final body = await utf8.decoder.bind(res).join();
          expect(res.statusCode, 200);
          expect(body.trim().isNotEmpty, isTrue);
          expect(net.lastIssue, NetworkIssue.none);
        } finally {
          client.close(force: true);
        }
      },
      skip: internetViva ? false : 'sin salida real a internet en este entorno',
    );

    test(
      'proxy real: CONNECT contra un host de internet',
      () async {
        final proxy = await _ConnectProxy.start();
        try {
          expect(await net.setProxy('127.0.0.1:${proxy.port}'), isNull);
          final client = HttpClient();
          try {
            final req =
                await client.getUrl(Uri.parse('https://api.github.com/zen'));
            final res = await req.close().timeout(const Duration(seconds: 20));
            final body = await utf8.decoder.bind(res).join();
            expect(res.statusCode, 200);
            expect(body.trim().isNotEmpty, isTrue);
          } finally {
            client.close(force: true);
          }
          expect(proxy.tunnels, contains('api.github.com:443'));
        } finally {
          await proxy.close();
          await net.setProxy('');
        }
      },
      skip: internetViva ? false : 'sin salida real a internet en este entorno',
    );

    test(
      'Comprobacion de conexion mide los cuatro frentes',
      () async {
        final report = await net.runDiagnostics();
        for (final c in report.checks) {
          // ignore: avoid_print
          print('${c.ok ? 'OK ' : 'MAL'} ${c.label} ${c.millis}ms ${c.detail}');
        }
        expect(
          report.checks.map((c) => c.label).toList(),
          ['Cuenta', 'Catálogo', 'Video', 'Actualizaciones'],
        );
        expect(report.viaSecureDns, isTrue);
        expect(report.viaProxy, isFalse);
        expect(
          report.allOk,
          isTrue,
          reason: 'esta red debe dejar pasar la app completa',
        );
      },
      skip: diagnosticoVivo
          ? false
          : 'sin acceso a todos los frentes de la app',
    );
  });
}

/// Comprueba, sin usar HttpClient, si este entorno puede abrir TLS contra un
/// host: el ejecutor de pruebas de Flutter simula el trafico y el entorno de
/// desarrollo puede tener la red filtrada.
Future<bool> _tlsReachable(String host) async {
  Socket? raw;
  try {
    raw = await Socket.connect(host, 443, timeout: const Duration(seconds: 6));
    final secure = await SecureSocket.secure(raw, host: host)
        .timeout(const Duration(seconds: 6));
    secure.destroy();
    return true;
  } catch (_) {
    raw?.destroy();
    return false;
  }
}

/// Servidor DNS sobre HTTPS de juguete: responde como Cloudflare y Google.
class _DohStub {
  _DohStub._(this._server, this.queries);

  final HttpServer _server;
  final List<String> queries;

  int get port => _server.port;

  static Future<_DohStub> start() async {
    final queries = <String>[];
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    server.listen((req) async {
      final name = req.uri.queryParameters['name'] ?? '';
      final type = req.uri.queryParameters['type'] ?? 'A';
      queries.add(name);

      Map<String, Object?> body;
      if (name.startsWith('muerto')) {
        body = {'Status': 3, 'name': name, 'Comment': 'no existe'};
      } else if (name.startsWith('lento')) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        body = _answer(name, type, '203.0.113.9');
      } else {
        body = _answer(name, type, '203.0.113.7');
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await req.response.close();
    });
    return _DohStub._(server, queries);
  }

  static Map<String, Object?> _answer(String name, String type, String ip) {
    if (type == 'AAAA') return {'Status': 0, 'name': name};
    return {
      'Status': 0,
      'name': name,
      'Answer': [
        {'name': name, 'type': 1, 'TTL': 60, 'data': ip},
      ],
    };
  }

  Future<void> close() => _server.close(force: true);
}

/// Proxy HTTP minimo: hace CONNECT (como los de una oficina) y anota a donde.
class _ConnectProxy {
  _ConnectProxy._(this._server, this.tunnels);

  final ServerSocket _server;
  final List<String> tunnels;

  int get port => _server.port;

  static Future<_ConnectProxy> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final tunnels = <String>[];
    server.listen((client) {
      final head = <int>[];
      var tunnelReady = false;
      Socket? upstream;
      late StreamSubscription<List<int>> sub;
      sub = client.listen((chunk) {
        if (tunnelReady) {
          upstream?.add(chunk);
          return;
        }
        sub.pause();
        head.addAll(chunk);
        final text = latin1.decode(head, allowInvalid: true);
        final cut = text.indexOf('\r\n\r\n');
        if (cut < 0) {
          sub.resume();
          return;
        }
        final match = RegExp(
          r'^CONNECT\s+(\S+)\s+HTTP/1\.[01]',
          caseSensitive: false,
        ).firstMatch(text.substring(0, cut));
        if (match == null) {
          client.write('HTTP/1.1 405 Method Not Allowed\r\n\r\n');
          client.close();
          return;
        }
        final target = match.group(1)!;
        tunnels.add(target);
        final parts = target.split(':');
        Socket.connect(
          parts[0],
          int.parse(parts[1]),
          timeout: const Duration(seconds: 8),
        ).then((up) {
          upstream = up;
          _forward(up, client);
          client.write('HTTP/1.1 200 Connection established\r\n\r\n');
          client.flush();
          tunnelReady = true;
          // Lo que ya hubiera del saludo TLS, se entrega ahora.
          final resto = text.substring(cut + 4);
          if (resto.isNotEmpty) up.add(latin1.encode(resto));
          sub.resume();
        }).catchError((_) {
          client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
          client.close();
        });
      }, onDone: () => upstream?.destroy(), onError: (_) => upstream?.destroy());
    });
    return _ConnectProxy._(server, tunnels);
  }

  Future<void> close() => _server.close();
}

/// Copia todos los bytes de from hacia to (tunel transparente).
void _forward(Stream<List<int>> from, Socket to) {
  from.listen(
    (data) => to.add(data),
    onDone: () {
      try {
        to.destroy();
      } catch (_) {}
    },
    onError: (_) {
      try {
        to.destroy();
      } catch (_) {}
    },
    cancelOnError: true,
  );
}

/// Servidor HTTPS con certificado auto-firmado: simula el firewall de una
/// empresa que cifra lo que navegas con su propia autoridad.
class _SelfSignedServer {
  _SelfSignedServer._(this._server, this._dir);

  final HttpServer _server;
  final Directory _dir;

  int get port => _server.port;

  static Future<_SelfSignedServer> start() async {
    final dir = await Directory.systemTemp.createTemp('inutiltv_tls_fixture');
    final key = '${dir.path}/key.pem';
    final crt = '${dir.path}/cert.pem';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-keyout',
      key,
      '-out',
      crt,
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=DNS:localhost,IP:127.0.0.1',
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'openssl no pudo generar el certificado: ${result.stderr}',
      );
    }
    final ctx = SecurityContext()
      ..useCertificateChain(crt)
      ..usePrivateKey(key);
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      ctx,
    );
    server.listen((req) async {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.text
        ..write('ok');
      await req.response.close();
    });
    return _SelfSignedServer._(server, dir);
  }

  Future<void> close() async {
    await _server.close(force: true);
    try {
      await _dir.delete(recursive: true);
    } catch (_) {}
  }
}
