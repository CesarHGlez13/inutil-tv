import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/services/tv_remote_service.dart';
import 'package:tubotv/widgets/tv_remote_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TvModeService.instance.resetForTest();
    TvRemoteService.instance.disableLanDiscoveryForTest = true;
  });

  tearDown(() {
    TvModeService.instance.resetForTest();
  });

  group('TvPlaybackState — 2026 Companion features', () {
    test('serializes and deserializes speed, episodeIndex and episodeCount', () {
      final state = TvPlaybackState(
        updatedAt: DateTime.now(),
        isPlaying: true,
        title: 'Batman: The Dark Knight',
        positionSec: 120,
        durationSec: 7200,
        volume: 85,
        isLive: false,
        episodeIndex: 3,
        episodeCount: 10,
        speed: 1.25,
      );

      final map = state.toFirestore();
      expect(map['episodeIndex'], 3);
      expect(map['episodeCount'], 10);
      expect(map['speed'], 1.25);

      final restored = TvPlaybackState.fromFirestore(map);
      expect(restored.episodeIndex, 3);
      expect(restored.episodeCount, 10);
      expect(restored.speed, 1.25);
      expect(restored.positionSec, 120);
      expect(restored.durationSec, 7200);
      expect(restored.volume, 85);
    });
  });

  group('TvRemoteSheet — UI and controls render', () {
    testWidgets('renders trackpad mode toggle and allows switching between Táctil and D-Pad',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      TvRemoteService.instance.setTvStateForTest(
        TvPlaybackState(
          online: true,
          title: 'Batman',
          isPlaying: true,
          positionSec: 100,
          durationSec: 1000,
          updatedAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TvRemoteSheet(),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      // Header is visible
      expect(find.text('Mi Smart TV'), findsOneWidget);

      // By default trackpadMode is false -> D-pad is visible
      expect(find.text('OK'), findsOneWidget);
      expect(find.text('D-Pad'), findsOneWidget);
      expect(find.text('Táctil'), findsOneWidget);

      // Tap on Táctil button to activate Trackpad mode
      await tester.tap(find.text('Táctil'));
      await tester.pump(const Duration(milliseconds: 100));

      // Now Trackpad hint is visible
      expect(find.text('Desliza para navegar\nToca para seleccionar'), findsOneWidget);

      // Toggle back to D-Pad
      await tester.tap(find.text('D-Pad'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('OK'), findsOneWidget);
    });

    testWidgets('toggles Keyboard Bridge text field when Buscar icon is tapped',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      TvRemoteService.instance.setTvStateForTest(
        TvPlaybackState(
          online: true,
          title: 'Batman',
          isPlaying: true,
          positionSec: 100,
          durationSec: 1000,
          updatedAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TvRemoteSheet(),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      // Keyboard input is hidden initially
      expect(find.byType(TextField), findsNothing);

      // Tap Buscar button
      await tester.tap(find.text('Buscar'));
      await tester.pump(const Duration(milliseconds: 350));

      // Keyboard Bridge is now visible
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Escribe aquí → aparece en la TV'), findsOneWidget);
    });
  });

  group('TvRemoteService — Ultra-Fast LAN Direct Bridge', () {
    test('lanHost serialization and copyWith', () {
      const state = TvPlaybackState(
        online: true,
        tvDeviceId: 'tv-living-room',
        tvName: 'Living Room TV',
        lanHost: '192.168.100.17',
        speed: 1.5,
      );

      final map = state.toFirestore();
      expect(map['lanHost'], '192.168.100.17');

      final deserialized = TvPlaybackState.fromFirestore(map);
      expect(deserialized.lanHost, '192.168.100.17');

      final copied = state.copyWith(lanHost: '192.168.100.25', speed: 2.0);
      expect(copied.lanHost, '192.168.100.25');
      expect(copied.speed, 2.0);
      expect(copied.tvName, 'Living Room TV');
    });

    test('dispatchCommandLocally dispatches LAN received commands immediately', () {
      TvRemoteCommand? receivedPlayerCmd;
      TvRemoteCommand? receivedNavCmd;

      TvRemoteService.instance.registerActivePlayerHandler((cmd) {
        receivedPlayerCmd = cmd;
      });
      TvRemoteService.instance.registerSystemNavigationHandler((cmd) {
        receivedNavCmd = cmd;
      });

      // 1. Player action
      final playerCmd = TvRemoteCommand(
        commandId: 'cmd-lan-1',
        action: 'seek_absolute',
        payload: {'positionSec': 450},
        createdAt: DateTime.now(),
      );
      TvRemoteService.instance.dispatchCommandLocally(playerCmd);
      expect(receivedPlayerCmd, isNotNull);
      expect(receivedPlayerCmd!.action, 'seek_absolute');
      expect(receivedPlayerCmd!.payload['positionSec'], 450);

      // 2. Navigation action
      final navCmd = TvRemoteCommand(
        commandId: 'cmd-lan-2',
        action: 'dpad_down',
        payload: {},
        createdAt: DateTime.now(),
      );
      TvRemoteService.instance.dispatchCommandLocally(navCmd);
      expect(receivedNavCmd, isNotNull);
      expect(receivedNavCmd!.action, 'dpad_down');

      // Cleanup
      TvRemoteService.instance.registerActivePlayerHandler(null);
      TvRemoteService.instance.registerSystemNavigationHandler(null);
    });

    test('sets and retains targetTvLanHost', () {
      TvRemoteService.instance.setTargetTvLanHost('192.168.100.17');
      expect(TvRemoteService.instance.targetTvLanHost, '192.168.100.17');
      TvRemoteService.instance.setTargetTvLanHost(null);
      expect(TvRemoteService.instance.targetTvLanHost, isNull);
    });

    test('playOnTv persistent destination toggle and state', () async {
      // 1. Initially offline TV -> playOnTv is false
      expect(TvRemoteService.instance.playOnTv, isFalse);

      // 2. Mark TV online
      TvRemoteService.instance.setTvStateForTest(
        TvPlaybackState(
          online: true,
          updatedAt: DateTime.now(),
        ),
      );

      // 3. Set playOnTv true
      await TvRemoteService.instance.setPlayOnTv(true);
      expect(TvRemoteService.instance.playOnTv, isTrue);

      // 4. Toggle playOnTv
      await TvRemoteService.instance.togglePlayOnTv();
      expect(TvRemoteService.instance.playOnTv, isFalse);

      // 5. When set true again, verify persistence via reload
      await TvRemoteService.instance.setPlayOnTv(true);
      expect(TvRemoteService.instance.playOnTv, isTrue);
      await TvRemoteService.instance.loadPreferences();
      expect(TvRemoteService.instance.playOnTv, isTrue);

      // 6. If TV goes offline, playOnTv safely returns false
      TvRemoteService.instance.setTvStateForTest(
        const TvPlaybackState(online: false),
      );
      expect(TvRemoteService.instance.playOnTv, isFalse);
    });

    test('sendPause, sendPlay y sendStop gestionan el estado y envían comando', () async {
      TvRemoteCommand? lastDispatched;
      TvRemoteService.instance.registerActivePlayerHandler((cmd) {
        lastDispatched = cmd;
      });

      // Simular TV reproduciendo
      TvRemoteService.instance.setTvStateForTest(
        TvPlaybackState(
          online: true,
          isPlaying: true,
          title: 'Dragon Ball Super',
          positionSec: 120,
          updatedAt: DateTime.now(),
        ),
      );
      expect(TvRemoteService.instance.tvState.isPlaying, isTrue);

      // Despacho local de pause
      TvRemoteService.instance.dispatchCommandLocally(
        TvRemoteCommand(
          commandId: 'cmd-pause-1',
          action: 'pause',
          payload: const {},
          createdAt: DateTime.now(),
        ),
      );
      expect(lastDispatched?.action, 'pause');

      // sendStop actualiza isPlaying localmente a false
      await TvRemoteService.instance.sendStop();
      expect(TvRemoteService.instance.tvState.isPlaying, isFalse);

      TvRemoteService.instance.registerActivePlayerHandler(null);
    });
  });
}
