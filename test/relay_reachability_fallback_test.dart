import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tubotv/services/firebase_config.dart';
import 'package:tubotv/services/firebase_firestore_service.dart';

void main() {
  group('relayAwareUrl (decisión pura de endpoint)', () {
    const google =
        'https://firestore.googleapis.com/v1/projects/p/databases/(default)/documents';
    const emulator =
        'http://127.0.0.1:8080/v1/projects/p/databases/(default)/documents';

    String decide({
      required String host,
      required bool? reachable,
      bool emulatorOn = false,
    }) =>
        FirebaseConfig.relayAwareUrl(
          configuredHost: host,
          configuredPort: '8080',
          emulator: emulatorOn,
          reachable: reachable,
          emulatorUrl: emulator,
          googleUrl: google,
        );

    test('sin relay horneado usa Google en los tres estados de la sonda', () {
      for (final reachable in [null, true, false]) {
        expect(
          decide(host: '', reachable: reachable),
          google,
          reason: 'reachable=$reachable no debe redirigir sin host',
        );
        expect(
          decide(host: '   ', reachable: reachable),
          google,
          reason: 'un host en blanco cuenta como no configurado',
        );
      }
    });

    test('host horneado pero todavía sin medir usa Google', () {
      expect(decide(host: '192.168.100.27', reachable: null), google);
    });

    test(
      'relay declarado caído usa Google: es el caso del usuario off-LAN',
      () {
        expect(decide(host: '192.168.100.27', reachable: false), google);
      },
    );

    test(
      'relay declarado vivo redirige conservando la ruta exacta de Google',
      () {
        final url = decide(host: '192.168.100.27', reachable: true);
        expect(
          url,
          'http://192.168.100.27:8080/v1/projects/p/databases/(default)/documents',
        );
        expect(Uri.parse(url).path, Uri.parse(google).path);
        expect(Uri.parse(url).host, '192.168.100.27');
        expect(Uri.parse(url).port, 8080);
      },
    );

    test(
      'emuladores ganan sobre el relay: nunca se le manda tráfico al S7',
      () {
        expect(
          decide(host: '192.168.100.27', reachable: true, emulatorOn: true),
          emulator,
        );
      },
    );
  });

  group('sonda de TCP', () {
    setUp(() => FirebaseConfig.resetRelayReachability());
    tearDown(() => FirebaseConfig.resetRelayReachability());

    test(
      'un puerto que sí escucha se declara alcanzable',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final probe = await FirebaseConfig.probeRelayReachability(
          timeout: const Duration(milliseconds: 400),
          ports: [server.port],
          host: server.address.address,
        );
        expect(probe, isTrue, reason: 'un listener local siempre handshake-a');
        expect(FirebaseConfig.relayReachabilityState, isTrue);
      },
    );

    test(
      'un host que no responde regresa false rápido y deja los endpoints en Google',
      () async {
        final sw = Stopwatch()..start();
        final probe = await FirebaseConfig.probeRelayReachability(
          timeout: const Duration(milliseconds: 300),
          ports: [40001, 40002],
          host: '192.168.100.253',
        );
        sw.stop();
        expect(probe, isFalse);
        expect(FirebaseConfig.relayReachabilityState, isFalse);
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason: 'dos puertos x 300 ms = máximo ~600 ms de arranque',
        );
        expect(
          FirebaseConfig.firestoreBaseUrl,
          contains('firestore.googleapis'),
        );
      },
    );

    test(
      'markRelayUnreachable marca caído y activa recuperación si estaba vivo',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        await FirebaseConfig.probeRelayReachability(
          timeout: const Duration(milliseconds: 400),
          ports: [server.port],
          host: server.address.address,
        );
        expect(FirebaseConfig.relayReachabilityState, isTrue);
        expect(FirebaseConfig.relayRecoveryWorthy, isFalse);

        FirebaseConfig.markRelayUnreachable();
        expect(FirebaseConfig.relayReachabilityState, isFalse);
        expect(FirebaseConfig.relayRecoveryWorthy, isTrue);
      },
    );
  });

  group('clasificación de errores que activan el reintento', () {
    test('los errores de conexión sí, los códigos HTTP no', () {
      expect(
        InutilFirestoreService.isConnectionFailure(
          TimeoutException('sin respuesta'),
        ),
        isTrue,
      );
      expect(
        InutilFirestoreService.isConnectionFailure(
          const SocketException('Connection refused'),
        ),
        isTrue,
      );
      expect(
        InutilFirestoreService.isConnectionFailure(
          http.ClientException('Socket error'),
        ),
        isTrue,
      );
      expect(
        InutilFirestoreService.isConnectionFailure(
          const FirestoreOperationException('p', 429, 'RESOURCE_EXHAUSTED'),
        ),
        isFalse,
      );
      expect(
        InutilFirestoreService.isConnectionFailure(
          const FormatException('json roto'),
        ),
        isFalse,
      );
    });
  });

  group('el reintento en InutilFirestoreService', () {
    test(
      'sin relay horneado manda una sola vez y propaga el error tal cual',
      () async {
        var calls = 0;
        await expectLater(
          InutilFirestoreService.instance.sendWithRelayFallbackForTest(
            label: 'users/x',
            urlBuilder: () => Uri.parse(
              'https://firestore.googleapis.com/v1/projects/p/databases/'
              '(default)/documents/users/x',
            ),
            send: (url) async {
              calls++;
              throw const SocketException('Connection refused');
            },
          ),
          throwsA(isA<SocketException>()),
        );
        expect(calls, 1);
      },
    );

    test('una respuesta HTTP normal se entrega sin reintentos', () async {
      var calls = 0;
      final response = await InutilFirestoreService.instance
          .sendWithRelayFallbackForTest(
            label: 'users/x',
            urlBuilder: () => Uri.parse('https://firestore.googleapis.com/x'),
            send: (url) async {
              calls++;
              return http.Response('{"fields":{}}', 200);
            },
          );
      expect(calls, 1);
      expect(response.statusCode, 200);
    });
  });
}
