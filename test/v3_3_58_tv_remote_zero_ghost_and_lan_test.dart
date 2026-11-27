import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/services/tv_remote_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TvModeService.instance.resetForTest();
    TvRemoteService.instance.disableLanDiscoveryForTest = true;
    TvRemoteService.instance.resetCommandDedupeForTest();
    TvRemoteService.instance.registerActivePlayerHandler(null);
    TvRemoteService.instance.registerSystemNavigationHandler(null);
  });

  tearDown(() {
    TvRemoteService.instance.resetCommandDedupeForTest();
    TvRemoteService.instance.registerActivePlayerHandler(null);
    TvRemoteService.instance.registerSystemNavigationHandler(null);
    TvModeService.instance.resetForTest();
  });

  group('v3.3.58 — Cero movimientos fantasma en Control Remoto TV', () {
    test(
        'un comando cloud ya ejecutado JAMÁS se re-ejecuta tras recibir comandos por LAN',
        () {
      final svc = TvRemoteService.instance;
      final now = DateTime.now();
      svc.resetCommandDedupeForTest(
        startedAt: now.subtract(const Duration(minutes: 1)),
      );

      final cloudRight = TvRemoteCommand(
        commandId: '66ae1f20-8398-4ea3-bdb0-01623a07aed1',
        action: 'dpad_right',
        payload: const {},
        createdAt: now,
      );

      // 1. Primera vez que llega desde Firestore -> se ejecuta una vez
      expect(svc.tryAcceptCommand(cloudRight, fromCloud: true), isTrue);
      // 2. Polling inmediato del mismo documento -> ignorado
      expect(svc.tryAcceptCommand(cloudRight, fromCloud: true), isFalse);

      // 3. Usuario mueve el control por LAN (antes sobrescribía _lastHandledCommandId!)
      for (final (id, act) in [
        ('lan-1', 'dpad_down'),
        ('lan-2', 'dpad_left'),
        ('lan-3', 'dpad_up'),
        ('lan-4', 'dpad_left'),
      ]) {
        final lanCmd = TvRemoteCommand(
          commandId: id,
          action: act,
          payload: const {},
          createdAt: DateTime.now(),
        );
        expect(svc.tryAcceptCommand(lanCmd, fromCloud: false), isTrue);
        // 4. Polling cloud lee otra vez el documento viejo dpad_right -> JAMÁS debe re-ejecutarse!
        expect(svc.tryAcceptCommand(cloudRight, fromCloud: true), isFalse);
      }
    });

    test('ignora comandos cloud viejos anteriores al arranque de la TV o >45s',
        () {
      final svc = TvRemoteService.instance;
      final bootTime = DateTime.now();
      svc.resetCommandDedupeForTest(startedAt: bootTime);

      final beforeBoot = TvRemoteCommand(
        commandId: 'old-before-boot',
        action: 'dpad_right',
        payload: const {},
        createdAt: bootTime.subtract(const Duration(seconds: 20)),
      );
      expect(svc.tryAcceptCommand(beforeBoot, fromCloud: true), isFalse);

      final expired = TvRemoteCommand(
        commandId: 'old-expired',
        action: 'dpad_right',
        payload: const {},
        createdAt: bootTime.subtract(const Duration(seconds: 60)),
      );
      expect(expired.isFresh, isFalse);
      expect(svc.tryAcceptCommand(expired, fromCloud: true), isFalse);
    });

    test(
        'con reproductor activo, dpad y back van SOLO al reproductor (sin doble disparo al menú)',
        () {
      final svc = TvRemoteService.instance;
      final playerEvents = <String>[];
      final navEvents = <String>[];

      svc.registerActivePlayerHandler(
        (c) => playerEvents.add(c.action),
        exclusiveDpad: true,
      );
      svc.registerSystemNavigationHandler((c) => navEvents.add(c.action));

      for (final act in [
        'dpad_up',
        'dpad_down',
        'dpad_left',
        'dpad_right',
        'dpad_center',
        'back',
      ]) {
        svc.dispatchCommandLocally(
          TvRemoteCommand(
            commandId: 'id_$act',
            action: act,
            payload: const {},
            createdAt: DateTime.now(),
          ),
        );
      }

      expect(playerEvents, [
        'dpad_up',
        'dpad_down',
        'dpad_left',
        'dpad_right',
        'dpad_center',
        'back',
      ]);
      expect(navEvents, isEmpty);

      // Comandos globales como home/open_search sí siguen yendo a navegación
      svc.dispatchCommandLocally(
        TvRemoteCommand(
          commandId: 'id_home',
          action: 'home',
          payload: const {},
          createdAt: DateTime.now(),
        ),
      );
      expect(navEvents, ['home']);
    });
  });

  group('v3.3.58 — Detección inteligente de IP LAN universal', () {
    test('prioriza wlan0/eth0 RFC1918 e ignora VPN, datos móviles y loopback',
        () {
      expect(
        TvRemoteService.pickBestLanIpv4([
          (name: 'lo', address: '127.0.0.1'),
          (name: 'tun0', address: '10.8.0.2'),
          (name: 'rmnet0', address: '10.145.22.9'),
          (name: 'p2p0', address: '192.168.49.1'),
          (name: 'wlan0', address: '192.168.1.147'),
        ]),
        '192.168.1.147',
      );

      expect(
        TvRemoteService.pickBestLanIpv4([
          (name: 'dummy0', address: '192.168.55.1'),
          (name: 'eth0', address: '10.0.0.88'),
        ]),
        '10.0.0.88',
      );

      expect(
        TvRemoteService.pickBestLanIpv4([
          (name: 'tun0', address: '10.8.0.2'),
          (name: 'wlan0', address: '169.254.12.34'),
        ]),
        isNull,
      );
    });
  });
}
