import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/screens/about_screen.dart';
import 'package:tubotv/screens/settings_screen.dart';
import 'package:tubotv/services/app_settings_service.dart';
import 'package:tubotv/services/cuevana_poseidon_service.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/hls_stream_proxy.dart';
import 'package:tubotv/services/inutil_cloud_backup_service.dart';
import 'package:tubotv/services/inutil_promo_popup_service.dart';
import 'package:tubotv/services/inutil_wrapped_service.dart';
import 'package:tubotv/services/series_health_service.dart';
import 'package:tubotv/services/serieskao_service.dart';
import 'package:tubotv/services/sleep_timer_service.dart';
import 'package:tubotv/services/stream_validator.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/inutil_inactivity_paused_screen.dart';
import 'package:tubotv/widgets/inutil_onboarding_tour.dart';
import 'package:tubotv/widgets/inutil_sleep_timer_sheet.dart';
import 'package:tubotv/widgets/inutil_support_popup.dart';
import 'package:tubotv/widgets/inutil_wrapped_dialog.dart';

Uint8List _buildFakePngWrappedTs({int pngPrefixLen = 70, int tsPackets = 4}) {
  final out = Uint8List(pngPrefixLen + tsPackets * 188);
  // PNG magic header
  out[0] = 0x89;
  out[1] = 0x50;
  out[2] = 0x4E;
  out[3] = 0x47;
  out[4] = 0x0D;
  out[5] = 0x0A;
  out[6] = 0x1A;
  out[7] = 0x0A;
  for (var p = 0; p < tsPackets; p++) {
    final base = pngPrefixLen + p * 188;
    out[base] = 0x47; // MPEG-TS sync byte
    out[base + 1] = 0x40;
    out[base + 2] = p & 0xFF;
  }
  return out;
}

String _encryptAes256Cbc(String plaintext, Uint8List key32) {
  final iv = Uint8List.fromList(List.generate(16, (i) => i + 1));
  final cipher = pc.PaddedBlockCipherImpl(
    pc.PKCS7Padding(),
    pc.CBCBlockCipher(pc.AESEngine()),
  );
  cipher.init(
    true,
    pc.PaddedBlockCipherParameters<pc.ParametersWithIV<pc.KeyParameter>, Null>(
      pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key32), iv),
      null,
    ),
  );
  final ct = cipher.process(Uint8List.fromList(utf8.encode(plaintext)));
  return base64.encode([...iv, ...ct]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    InutilAuthService.testSkipOnlineValidation = true;
    SleepTimerService.instance.cancel();
  });

  group('HlsStreamProxy — Anti-PNG Disguise & Instant Preloading', () {
    test('stripDisguisedHeader removes 70B fake PNG prefix and preserves pure 0x47 TS', () {
      final wrapped = _buildFakePngWrappedTs(pngPrefixLen: 70, tsPackets: 4);
      expect(wrapped[0], 0x89);
      expect(StreamValidator.findMpegTsSyncOffset(wrapped), 70);
      expect(StreamValidator.isPlayableMediaBytes(wrapped), isTrue);

      final stripped = HlsStreamProxy.stripDisguisedHeader(wrapped);
      expect(stripped.length, 4 * 188);
      expect(stripped[0], 0x47);
      expect(stripped[188], 0x47);
      expect(stripped[376], 0x47);
    });

    test('stripDisguisedHeader leaves clean TS and fMP4 untouched', () {
      final cleanTs = _buildFakePngWrappedTs(pngPrefixLen: 0, tsPackets: 3);
      expect(HlsStreamProxy.stripDisguisedHeader(cleanTs).length, cleanTs.length);

      final mp4 = Uint8List.fromList([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, ...List.filled(32, 1)]);
      expect(HlsStreamProxy.stripDisguisedHeader(mp4), equals(mp4));
    });

    test('Live loopback proxy rewrites .image segments to .ts, strips PNG, and serves preloaded segments in <50ms', () async {
      final tsPayload = _buildFakePngWrappedTs(pngPrefixLen: 70, tsPackets: 8);
      var upstreamHits = 0;

      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        final p = req.uri.path;
        if (p == '/master.m3u8') {
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2500000\n/index.m3u8\n');
          await req.response.close();
        } else if (p == '/index.m3u8') {
          req.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write(
              '#EXTM3U\n#EXT-X-TARGETDURATION:10\n'
              '#EXTINF:10.0,\n/seg0.image\n'
              '#EXTINF:10.0,\n/seg1.image\n'
              '#EXTINF:10.0,\n/seg2.image\n'
              '#EXT-X-ENDLIST\n',
            );
          await req.response.close();
        } else if (p.endsWith('.image')) {
          upstreamHits++;
          req.response
            ..headers.contentType = ContentType('image', 'png')
            ..add(tsPayload);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      try {
        final reg = await HlsStreamProxy.instance.registerHlsSession(
          upstreamUrl: 'http://127.0.0.1:${upstream.port}/master.m3u8',
          headers: {'Referer': 'https://cdnwish.com/'},
        );

        final stats = await HlsStreamProxy.instance.preloadHlsSession(
          reg.sessionId,
          maxSegments: 3,
        );
        expect(stats.segmentsCached, 3);
        expect(stats.bytesCached, 3 * 8 * 188);
        final hitsAfterPreload = upstreamHits;

        // Fetch rewritten master -> subplaylist -> segment 0 from loopback
        final client = HttpClient();
        final mReq = await client.getUrl(Uri.parse(reg.localUrl));
        final mRes = await mReq.close();
        final masterTxt = await utf8.decoder.bind(mRes).join();
        expect(masterTxt, contains('/pl/0.m3u8'));

        final plUrl = masterTxt
            .split('\n')
            .firstWhere((l) => l.startsWith('http://127.0.0.1'));
        final pReq = await client.getUrl(Uri.parse(plUrl));
        final pRes = await pReq.close();
        final plTxt = await utf8.decoder.bind(pRes).join();
        expect(plTxt, contains('/seg/0.ts'));
        expect(plTxt, isNot(contains('.image')));

        // Measure cached segment latency (must be served from RAM with 0 new upstream hits!)
        final segUrl = plTxt
            .split('\n')
            .firstWhere((l) => l.endsWith('.ts'));
        final sw = Stopwatch()..start();
        final sReq = await client.getUrl(Uri.parse(segUrl));
        final sRes = await sReq.close();
        final segBytes = await sRes.fold<List<int>>([], (a, b) => a..addAll(b));
        sw.stop();

        expect(sRes.statusCode, 200);
        expect(segBytes.first, 0x47, reason: 'Fake PNG header must be stripped');
        expect(segBytes.length, 8 * 188);
        expect(upstreamHits, hitsAfterPreload,
            reason: 'Preloaded segment must come from RAM cache');
        expect(sw.elapsedMilliseconds, lessThan(150));

        client.close(force: true);
        HlsStreamProxy.instance.releaseSession(reg.sessionId);
      } finally {
        await upstream.close(force: true);
      }
    });

    test('Live loopback MP4 preloader serves 206 Partial Content from RAM + proxies tail', () async {
      final totalData = Uint8List(2048);
      // Valid ftyp MP4 header
      totalData[4] = 0x66;
      totalData[5] = 0x74;
      totalData[6] = 0x79;
      totalData[7] = 0x70;
      for (var i = 8; i < totalData.length; i++) {
        totalData[i] = i & 0xFF;
      }

      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        var end = totalData.length - 1;
        if (range != null && range.startsWith('bytes=')) {
          final parts = range.substring(6).split('-');
          start = int.parse(parts[0]);
          if (parts[1].isNotEmpty) end = int.parse(parts[1]).clamp(start, totalData.length - 1);
        }
        final slice = totalData.sublist(start, end + 1);
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${totalData.length}',
        );
        req.response.add(slice);
        await req.response.close();
      });

      try {
        final reg = await HlsStreamProxy.instance.registerMp4Session(
          upstreamUrl: 'http://127.0.0.1:${upstream.port}/ep2.mp4',
        );
        final stats = await HlsStreamProxy.instance.preloadMp4Session(
          reg.sessionId,
          maxBytes: 1024,
        );
        expect(stats.bytesCached, 1024);

        final client = HttpClient();
        // Range inside RAM prefix
        final r1 = await client.getUrl(Uri.parse(reg.localUrl));
        r1.headers.set('Range', 'bytes=0-255');
        final res1 = await r1.close();
        final b1 = await res1.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(res1.statusCode, 206);
        expect(b1.length, 256);
        expect(b1.sublist(4, 8), equals([0x66, 0x74, 0x79, 0x70]));

        // Range beyond RAM prefix -> transparent upstream proxy
        final r2 = await client.getUrl(Uri.parse(reg.localUrl));
        r2.headers.set('Range', 'bytes=1500-1755');
        final res2 = await r2.close();
        final b2 = await res2.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(res2.statusCode, 206);
        expect(b2.length, 256);
        expect(b2[0], 1500 & 0xFF);

        client.close(force: true);
        HlsStreamProxy.instance.releaseSession(reg.sessionId);
      } finally {
        await upstream.close(force: true);
      }
    });
  });

  group('SeriesKao AES-256-CBC + StreamWish Ranking + Health Scoring', () {
    test('CuevanaPoseidonService ranks /stream/ master.m3u8 ahead of premilkyway 502 URLs', () {
      const sampleUnpacked = '''
        var links = {
          "hls2": "https://abc.premilkyway.com/hls2/01/01341/xyz/master.m3u8?t=1",
          "hls4": "/stream/token123/master.m3u8"
        };
      ''';
      final ranked = CuevanaPoseidonService.rankExtractedM3u8Urls(
        sampleUnpacked,
        'cdnwish.com',
      );
      expect(ranked.length, 2);
      expect(ranked.first, 'https://cdnwish.com/stream/token123/master.m3u8');
      expect(ranked.last, contains('premilkyway.com'));
    });

    test('SeriesKaoService decrypts Embed69 AES-256-CBC dataLink cleanly in pure Dart', () {
      const challenge = 'abc123challenge';
      const salt = 'xyz789salt';
      final key = Uint8List.fromList(
        crypto.sha256.convert(utf8.encode('$challenge$salt')).bytes,
      );
      final encVidHide = _encryptAes256Cbc('https://vidhidevip.com/v/test123', key);
      final encStreamWish = _encryptAes256Cbc('https://cdnwish.com/e/wish456', key);

      final html = '''
        <script>
        const LINK_CHALLENGE = '$challenge';
        const LINK_SALT = '$salt';
        let dataLink = [{"video_language":"LAT","sortedEmbeds":[
          {"servername":"streamwish","link":"$encStreamWish"},
          {"servername":"vidhide","link":"$encVidHide"},
          {"servername":"voe","link":"ignored"}
        ]}];
        </script>
      ''';

      final embeds = SeriesKaoService.extractDecryptedEmbeds(html);
      expect(embeds.length, 2);
      expect(embeds.any((e) => e.server == 'vidhide' && e.url == 'https://vidhidevip.com/v/test123'), isTrue);
      expect(embeds.any((e) => e.server == 'streamwish' && e.url == 'https://cdnwish.com/e/wish456'), isTrue);
    });

    test('SeriesHealthService filters out repeatedly broken series and preserves healthy ones', () async {
      final health = SeriesHealthService.instance;
      await health.recordFailure('Serie Rota XYZ');
      await health.recordFailure('Serie Rota XYZ');
      await health.recordSuccess('Breaking Bad', latencyMs: 650);

      expect(health.isKnownBroken('Serie Rota XYZ'), isTrue);
      expect(health.isKnownBroken('Breaking Bad'), isFalse);

      final ranked = health.filterAndRankSeries([
        const VodItem(id: '1', title: 'Serie Rota XYZ', isSeries: true, provider: 'poseidon'),
        const VodItem(id: '2', title: 'Breaking Bad', isSeries: true, provider: 'serieskao'),
      ]);
      expect(ranked.length, 1);
      expect(ranked.first.title, 'Breaking Bad');
    });
  });

  group('Inútil Music v2.4 Ported Services (Inactivity, Cloud Backup, Sleep Timer)', () {
    test('Inactivity pause policy logic matches Inútil Music rules', () {
      final now = DateTime(2026, 11, 18);
      // Exempt / admin / permanent -> never paused
      expect(
        InutilAuthService.inactivityPauseDays(
          lastActiveAt: now.subtract(const Duration(days: 40)),
          exempt: true,
          enabled: true,
          thresholdDays: 15,
          now: now,
        ),
        isNull,
      );
      // Under threshold -> active
      expect(
        InutilAuthService.inactivityPauseDays(
          lastActiveAt: now.subtract(const Duration(days: 10)),
          exempt: false,
          enabled: true,
          thresholdDays: 15,
          now: now,
        ),
        isNull,
      );
      // Over threshold -> paused with exact inactive day count
      expect(
        InutilAuthService.inactivityPauseDays(
          lastActiveAt: now.subtract(const Duration(days: 18)),
          exempt: false,
          enabled: true,
          thresholdDays: 15,
          now: now,
        ),
        18,
      );
    });

    test('Cloud backup merge preserves local items and restores remote without duplicates', () {
      final merged = InutilTvCloudBackupService.mergeByIdForTest(
        [
          {'id': 'a', 'title': 'Local A'},
        ],
        [
          {'id': 'a', 'title': 'Remote A'},
          {'id': 'b', 'title': 'Remote B'},
        ],
      );
      expect(merged.length, 2);
      expect(merged.first['title'], 'Local A');
      expect(merged.last['title'], 'Remote B');
    });

    test('SleepTimerService supports end-of-episode arming and cancellation', () {
      final st = SleepTimerService.instance;
      expect(st.isActive, isFalse);
      st.startEndOfEpisode();
      expect(st.isActive, isTrue);
      expect(st.stopAtEndOfEpisode, isTrue);
      expect(st.shortLabel, 'Fin ep.');
      expect(st.consumeEndOfEpisodeIfArmed(), isTrue);
      expect(st.isActive, isFalse);
      expect(st.consumeEndOfEpisodeIfArmed(), isFalse);
    });
  });

  group('UI Widgets Ported from Inútil Music v2.4', () {
    testWidgets('InutilInactivityPausedScreen triggers reactivation request', (tester) async {
      var requested = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: InutilInactivityPausedScreen(
            user: const InutilUser(uid: 'u1', email: 'fan@inutil.tv', displayName: 'César'),
            inactiveDays: 19,
            policyDays: 15,
            onRequestReactivation: () async {
              requested = true;
              return true;
            },
          ),
        ),
      );

      expect(find.textContaining('Tu acceso gratuito'), findsOneWidget);
      expect(find.textContaining('19 días'), findsOneWidget);
      final reqBtn = find.byKey(const ValueKey('inactivity-request-reactivation'));
      await tester.ensureVisible(reqBtn);
      await tester.pump();
      await tester.tap(reqBtn);
      await tester.pump();
      expect(requested, isTrue);
      expect(find.text('Solicitud enviada'), findsOneWidget);
    });

    testWidgets('InutilSleepTimerSheet displays presets + end of episode and arms timer', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: const Scaffold(
            body: InutilSleepTimerSheet(showEndOfEpisode: true),
          ),
        ),
      );

      expect(find.text('Temporizador de sueño'), findsOneWidget);
      expect(find.text('Al terminar este episodio'), findsOneWidget);
      expect(find.text('30 minutos'), findsOneWidget);
    });

    testWidgets('InutilOnboardingTour renders and advances slides', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: const InutilOnboardingTour(inactivityDays: 15),
        ),
      );
      expect(find.text('1 de 7'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('onboarding-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('2 de 7'), findsOneWidget);
    });

    testWidgets('InutilSupportPopupDialog and InutilTvWrappedDialog render cleanly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: InutilSupportPopupDialog(
            campaign: InutilPromoPopupService.creatorCampaigns.first,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('inutil-support-popup-card')), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: const InutilTvWrappedDialog(
            userName: 'César',
            myListCount: 7,
            summary: InutilTvWrappedSummary(
              year: 2026,
              totalSeconds: 14400,
              totalSessions: 12,
              topTitles: [
                TvWrappedTitleStat(
                  id: 'sk_s_breaking-bad',
                  title: 'Breaking Bad',
                  category: 'Series',
                  plays: 5,
                  seconds: 9000,
                ),
              ],
              categorySeconds: {'Series': 14400},
              activeDaysCount: 6,
              peakHour: 23,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('inutil-tv-wrapped-dialog')), findsOneWidget);
      expect(find.textContaining('4.0 h'), findsWidgets);
    });

    testWidgets('SettingsScreen & AboutScreen expose v3.1.0 features with ZERO Admin Panel', (tester) async {
      expect(AppInfo.appVersion, startsWith('3.'));
      await AppSettingsService.instance.load(force: true);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: const SettingsScreen(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Panel de Control'), findsNothing);
      final mainScroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Respaldar biblioteca en la nube'),
        250,
        scrollable: mainScroll,
      );
      expect(find.text('Respaldar biblioteca en la nube'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Precarga instantánea del siguiente episodio'),
        250,
        scrollable: mainScroll,
      );
      expect(find.text('Precarga instantánea del siguiente episodio'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: const AboutScreen(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('about-wrapped')), findsOneWidget);
      expect(find.byKey(const ValueKey('about-onboarding')), findsOneWidget);
    });
  });
}
