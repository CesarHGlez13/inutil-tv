import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/title_logo_service.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/services/tv_remote_service.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/vod_detail_modal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TvModeService.instance.resetForTest();
    TvRemoteService.instance.disableLanDiscoveryForTest = true;
    TvRemoteService.instance.uidOverrideForTest = null;
    TvRemoteService.instance.setTargetTvLanHost(null);
    TitleLogoService.instance.clearMemoryCache();
    TitleLogoService.instance.testClient = null;
  });

  tearDown(() async {
    await TvRemoteService.instance.stopLanHttpServerForTest();
    TvRemoteService.instance.uidOverrideForTest = null;
    TvRemoteService.instance.registerActivePlayerHandler(null);
    TvRemoteService.instance.registerSystemNavigationHandler(null);
    TvModeService.instance.resetForTest();
    TitleLogoService.instance.clearMemoryCache();
    TitleLogoService.instance.testClient = null;
  });

  group('v3.3.30 — Seguridad LAN por cuenta en TvRemoteService', () {
    test('el código fuente ya no tiene IP fija 192.168.100.17 hardcodeada', () {
      final src = File('lib/services/tv_remote_service.dart').readAsStringSync();
      expect(src, isNot(contains('192.168.100.17')));
      expect(src, isNot(contains('192.168.100.255')));
    });

    test('UDP discovery responde solo al token de la misma cuenta', () {
      TvRemoteService.instance.uidOverrideForTest = 'uid_cuenta_tv_A';
      final tokenA = TvRemoteService.accountTokenForUid('uid_cuenta_tv_A');
      final tokenB = TvRemoteService.accountTokenForUid('uid_cuenta_movil_B');

      // Paquete legado sin token → ignorado
      expect(
        TvRemoteService.instance.buildUdpDiscoveryReplyForMessage('INUTIL_TV_DISCOVER'),
        isNull,
      );
      // Paquete de otra cuenta → ignorado
      expect(
        TvRemoteService.instance.buildUdpDiscoveryReplyForMessage('INUTIL_TV_DISCOVER|$tokenB'),
        isNull,
      );
      // Paquete de la misma cuenta → respondido con el token
      final reply = TvRemoteService.instance
          .buildUdpDiscoveryReplyForMessage('INUTIL_TV_DISCOVER|$tokenA');
      expect(reply, isNotNull);
      expect(reply, startsWith('INUTIL_TV_ONLINE|'));
      expect(reply, endsWith('|$tokenA'));
    });

    test('servidor HTTP LAN rechaza con 403 a otra cuenta y acepta la misma cuenta',
        () async {
      TvRemoteService.instance.uidOverrideForTest = 'uid_cuenta_tv_A';
      TvRemoteService.instance.setTvStateForTest(
        TvPlaybackState(
          online: true,
          tvDeviceId: 'tv-onn-4k',
          tvName: 'Smart TV Sala',
          title: 'Black Clover',
          isPlaying: true,
          updatedAt: DateTime.now(),
        ),
      );

      final executed = <String>[];
      TvRemoteService.instance.registerActivePlayerHandler((cmd) {
        executed.add(cmd.action);
      });

      final port = await TvRemoteService.instance.startLanHttpServerForTest();
      final tokenA = TvRemoteService.accountTokenForUid('uid_cuenta_tv_A');
      final tokenB = TvRemoteService.accountTokenForUid('uid_cuenta_movil_B');

      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final client = HttpClient();
      try {
        // 1. Sin header → 403 en ping, state y command
        for (final path in ['/api/tv/ping', '/api/tv/state']) {
          final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
          final resp = await req.close();
          expect(resp.statusCode, HttpStatus.forbidden, reason: '$path sin token');
          await resp.drain<void>();
        }

        // 2. Cuenta distinta (Xiaomi con cuenta B) → 403 en ping, state y command
        final pingB = await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/tv/ping'));
        pingB.headers.set(TvRemoteService.lanAccountHeader, tokenB);
        final pingBResp = await pingB.close();
        expect(pingBResp.statusCode, HttpStatus.forbidden);
        await pingBResp.drain<void>();

        final stateB = await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/tv/state'));
        stateB.headers.set(TvRemoteService.lanAccountHeader, tokenB);
        final stateBResp = await stateB.close();
        expect(stateBResp.statusCode, HttpStatus.forbidden);
        await stateBResp.drain<void>();

        final cmdB = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/tv/command'));
        cmdB.headers.contentType = ContentType.json;
        cmdB.headers.set(TvRemoteService.lanAccountHeader, tokenB);
        cmdB.write(jsonEncode({'action': 'pause', 'payload': {}, 'accountToken': tokenB}));
        final cmdBResp = await cmdB.close();
        expect(cmdBResp.statusCode, HttpStatus.forbidden);
        await cmdBResp.drain<void>();
        expect(executed, isEmpty, reason: 'una cuenta distinta jamás debe ejecutar comandos');

        // 3. Misma cuenta (A) → 200 OK en ping, state y command
        final pingA = await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/tv/ping'));
        pingA.headers.set(TvRemoteService.lanAccountHeader, tokenA);
        final pingAResp = await pingA.close();
        expect(pingAResp.statusCode, HttpStatus.ok);
        final pingBody = jsonDecode(await utf8.decoder.bind(pingAResp).join()) as Map;
        expect(pingBody['ok'], isTrue);
        expect(pingBody['accountToken'], tokenA);

        final cmdA = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/tv/command'));
        cmdA.headers.contentType = ContentType.json;
        cmdA.headers.set(TvRemoteService.lanAccountHeader, tokenA);
        cmdA.write(jsonEncode({'action': 'pause', 'payload': {}, 'accountToken': tokenA}));
        final cmdAResp = await cmdA.close();
        expect(cmdAResp.statusCode, HttpStatus.ok);
        await cmdAResp.drain<void>();
        expect(executed, ['pause']);
      } finally {
        client.close(force: true);
        HttpOverrides.global = prevOverrides;
      }
    });
  });

  group('v3.3.30–v3.3.34 — Resolución segura de logos en TitleLogoService vía meta.inutix.com', () {
    test('resuelve logo PNG vía meta.inutix.com/logo sin exponer llaves TMDB/Fanart en el cliente', () async {
      final capturedUrls = <Uri>[];
      TitleLogoService.instance.testClient = MockClient((req) async {
        capturedUrls.add(req.url);
        expect(req.url.host, 'meta.inutix.com');
        expect(req.url.path, '/logo');
        expect(req.headers.containsKey('Authorization'), isFalse);
        return http.Response(
          jsonEncode({
            'ok': true,
            'logo': 'https://image.tmdb.org/t/p/w500/black_clover_logo.png',
            'source': 'tmdb',
          }),
          200,
        );
      });

      const item = VodItem(
        id: 'cp_s_73223',
        title: 'Black Clover',
        isAnime: true,
        isSeries: true,
      );

      final url = await TitleLogoService.instance.getLogoUrl(item);
      expect(url, 'https://image.tmdb.org/t/p/w500/black_clover_logo.png');
      expect(capturedUrls, hasLength(1));
      expect(capturedUrls.first.queryParameters['id'], '73223');
      expect(capturedUrls.first.queryParameters['type'], 'tv');
    });
  });

  group('v3.3.30 — Logo sobre la portada con desplazamiento solidario 1:1 en móvil', () {
    testWidgets('el logo vive sobre la portada (FlexibleSpaceBar pin) y sube 1:1 con la hoja negra',
        (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const item = VodItem(
        id: 'mobile_logo_pin_test',
        title: 'Black Clover',
        year: '2017',
        genre: 'Acción',
        rating: '8.8',
        isAnime: true,
        isSeries: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: const Scaffold(body: VodDetailModal(item: item)),
        ),
      );
      await tester.pumpAndSettle();

      // FlexibleSpaceBar usa CollapseMode.pin
      final flex = tester.widget<FlexibleSpaceBar>(find.byType(FlexibleSpaceBar));
      expect(flex.collapseMode, CollapseMode.pin);

      // El rótulo grande vive DENTRO de FlexibleSpaceBar (sobre la portada, no en el bloque negro)
      final bigTitleFinder = find.descendant(
        of: find.byType(FlexibleSpaceBar),
        matching: find.byWidgetPredicate(
          (w) => w is Text && w.data == 'Black Clover' && w.style?.fontSize == 31.0,
        ),
      );
      expect(bigTitleFinder, findsOneWidget);

      // En reposo el logo está por encima del borde superior de la hoja negra (metadata '14+')
      final badgeFinder = find.text('14+');
      expect(badgeFinder, findsOneWidget);
      final logoBottomBefore = tester.getBottomLeft(bigTitleFinder).dy;
      final badgeTopBefore = tester.getTopLeft(badgeFinder).dy;
      expect(logoBottomBefore, lessThan(badgeTopBefore),
          reason: 'el logo debe estar sobre la portada, encima de la zona negra de metadatos');

      // Al scrollear 80px hacia arriba, logo y barra negra se desplazan solidariamente (misma distancia)
      final logoTopBefore = tester.getTopLeft(bigTitleFinder).dy;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -80));
      await tester.pumpAndSettle();

      final logoDelta = logoTopBefore - tester.getTopLeft(bigTitleFinder).dy;
      final badgeDelta = badgeTopBefore - tester.getTopLeft(badgeFinder).dy;
      expect(logoDelta, greaterThan(40));
      expect((logoDelta - badgeDelta).abs(), lessThan(4.0),
          reason: 'el logo debe desplazarse 1:1 con la barra negra sin quedar cubierto por ella');
    });
  });
}
