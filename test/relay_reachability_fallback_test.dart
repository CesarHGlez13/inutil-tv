import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/firebase_config.dart';
import 'package:tubotv/services/firebase_firestore_service.dart';
import 'package:tubotv/services/tv_remote_service.dart';

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

  group('re-sonda de recuperación del relay (medido 2026-11-20)', () {
    setUp(() => FirebaseConfig.resetRelayReachability());
    tearDown(() => FirebaseConfig.resetRelayReachability());

    test('tras caerse MIENTRAS se usaba quiere re-sondear, y se recupera sola '
        'cuando el relay vuelve', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      Future<bool> ver() => FirebaseConfig.probeRelayReachability(
            timeout: const Duration(milliseconds: 400),
            ports: [server.port],
            host: server.address.address,
          );
      expect(await ver(), isTrue);
      expect(
        FirebaseConfig.relayRecoveryWorthy,
        isFalse,
        reason: 'con el relay vivo no hay nada que re-sondear',
      );
      // El caso real: `relay.py` se reinicia en el S7 y los servicios reciben
      // Connection refused. Sin esta marca la app latcheaba Google para toda la
      // sesión (medido: 0 peticiones al relay en 3 min) y sus heartbeats
      // volvían a pagar cuota escritos directo en Google.
      FirebaseConfig.markRelayUnreachable();
      expect(
        FirebaseConfig.relayRecoveryWorthy,
        isTrue,
        reason: 'se cayó estando en uso: hay que recuperarlo sin cerrar la app',
      );
      // `zz-relay.sh` lo levanta en ~10 s: la re-sonda lo encuentra y la puerta
      // se apaga sola, no se sigue sondeando.
      expect(await ver(), isTrue);
      expect(FirebaseConfig.relayReachabilityState, isTrue);
      expect(
        FirebaseConfig.relayRecoveryWorthy,
        isFalse,
        reason: 'recuperado: no gastar handshakes de más',
      );
    });

    test('un equipo que nunca usó el relay no pide re-sonda: el usuario '
        'off-LAN no paga timeouts cada 45 s', () async {
      final probe = await FirebaseConfig.probeRelayReachability(
        timeout: const Duration(milliseconds: 300),
        ports: [40001, 40002],
        host: '192.168.100.253',
      );
      expect(probe, isFalse);
      expect(
        FirebaseConfig.relayRecoveryWorthy,
        isFalse,
        reason: 'nunca lo vio vivo: no hay relación que recuperar',
      );
      // Un error de red contra Google (estando `null`) tampoco la enciende:
      // `markRelayUnreachable` sólo deja marca si estaba EN USO.
      FirebaseConfig.markRelayUnreachable();
      expect(FirebaseConfig.relayRecoveryWorthy, isFalse);
    });

    test('noteRelayRecoveryWanted es el caso del S7 levantándose con la app '
        'ya abierta (cache true + sonda de arranque fallida)', () {
      FirebaseConfig.markRelayUnreachable();
      expect(
        FirebaseConfig.relayRecoveryWorthy,
        isFalse,
        reason: 'sin relación previa no se sondea',
      );
      FirebaseConfig.noteRelayRecoveryWanted();
      expect(FirebaseConfig.relayRecoveryWorthy, isTrue);
      FirebaseConfig.resetRelayReachability();
      expect(
        FirebaseConfig.relayRecoveryWorthy,
        isFalse,
        reason: 'el reset limpia la marca, para que las pruebas arranquen limpias',
      );
    });

    test('la sonda de arranque con cache decide la recuperación y persiste lo '
        'que midió', () async {
      SharedPreferences.setMockInitialValues(
          {FirebaseConfig.relayReachabilityCacheKey: true});
      FirebaseConfig.relayHostOverrideForTest = '192.168.100.253';
      FirebaseConfig.relayPortOverrideForTest = 40001;
      await FirebaseConfig.probeRelayReachabilityAndCache();
      expect(FirebaseConfig.relayReachabilityState, isFalse);
      expect(
        FirebaseConfig.relayRecoveryWorthy,
        isTrue,
        reason: 'el cache decía vivo: este equipo SÍ vive en la LAN del relay',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(FirebaseConfig.relayReachabilityCacheKey),
        isFalse,
        reason: 'el cache es telemetría: guarda lo medido en este arranque',
      );
    });

    test('un build sin host horneado no sondea ni decide nada', () async {
      SharedPreferences.setMockInitialValues(
          {FirebaseConfig.relayReachabilityCacheKey: true});
      await FirebaseConfig.probeRelayReachabilityAndCache();
      expect(
        FirebaseConfig.relayReachabilityState,
        isNull,
        reason: 'sin relay horneado la función sale antes de tocar la red',
      );
    });

    test('la re-sonda del tick encuentra el relay levantado y apaga la puerta '
        'sola', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      FirebaseConfig.relayHostOverrideForTest = server.address.address;
      FirebaseConfig.relayPortOverrideForTest = server.port;
      FirebaseConfig.setRelayReachableForTest(false);
      FirebaseConfig.noteRelayRecoveryWanted();
      expect(FirebaseConfig.relayRecoveryWorthy, isTrue);

      final svc = TvRemoteService.instance;
      svc.resetReprobeStateForTest();
      svc.reprobeRelayForTest();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(FirebaseConfig.relayReachabilityState, isTrue,
          reason: 'la re-sonda colgada del tick encontró el relay');
      expect(FirebaseConfig.relayRecoveryWorthy, isFalse,
          reason: 'recuperado: la puerta se apaga sola');
    });

    test('la re-sonda respeta su intervalo: dentro de la ventana no se gasta '
        'otro handshake', () {
      final now = DateTime.now();
      expect(
        TvRemoteService.reprobeDue(
            last: DateTime.fromMillisecondsSinceEpoch(0), now: now),
        isTrue,
      );
      expect(TvRemoteService.reprobeDue(last: now, now: now), isFalse);
      expect(
        TvRemoteService.reprobeDue(
            last: now.subtract(const Duration(seconds: 44)), now: now),
        isFalse,
        reason: '44 s: todavía dentro de la ventana de 45 s',
      );
      expect(
        TvRemoteService.reprobeDue(
            last: now.subtract(const Duration(seconds: 45)), now: now),
        isTrue,
      );
    });
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
