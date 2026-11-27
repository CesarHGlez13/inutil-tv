import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/hls_stream_proxy.dart';
import 'package:tubotv/services/stream_validator.dart';
import 'package:tubotv/services/vod_playback_warmup_service.dart';

Uint8List _fakeTsSegment(int sizeBytes) {
  final out = Uint8List(sizeBytes);
  for (var i = 0; i < sizeBytes; i += 188) {
    out[i] = 0x47;
  }
  return out;
}

void main() {
  setUp(() {
    HttpOverrides.global = null;
    StreamHostHealth.instance.resetForTest();
    VodPlaybackWarmupService.instance.cancel();
    VodPlaybackWarmupService.instance.enabled = true;
  });

  tearDown(() {
    StreamHostHealth.instance.resetForTest();
    VodPlaybackWarmupService.instance.cancel();
  });

  group('v3.3.55 — StreamHostHealth y sonda de velocidad real', () {
    test('degrada hosts trabados o con throttling sp=500 y prioriza servidores rápidos',
        () {
      final health = StreamHostHealth.instance;
      const slowVidhideUrl =
          'https://h85abc.acek-cdn.com/hls2/01/test/master.m3u8?sp=500';
      const fastStreamwishUrl =
          'https://embedwish.com/stream/abc/master.m3u8';

      // Sin telemetría previa, la heurística ya evita nodos throttled frente a StreamWish
      final baseSlow = health.scoreFor(
        url: slowVidhideUrl,
        server: 'vidhide',
        probeBytesPerSec: 120 * 1024,
        latencyMs: 900,
      );
      final baseFast = health.scoreFor(
        url: fastStreamwishUrl,
        server: 'streamwish',
        probeBytesPerSec: 1400 * 1024,
        latencyMs: 180,
      );
      expect(baseFast, greaterThan(baseSlow));

      // Al registrar un corte/stall en VidHide, queda penalizado y baja en hostOrderPenalty
      health.recordStallOrTimeout(slowVidhideUrl, server: 'vidhide');
      expect(
        health.isHostPenalized(
          'https://z99other.acek-cdn.com/hls2/02/other/master.m3u8',
          server: 'vidhide',
        ),
        isTrue,
      );
      expect(health.hostOrderPenalty('vidhide'), greaterThan(0));
      expect(health.hostOrderPenalty('streamwish'), 0);
    });

    test('StreamValidator.probeUrl valida HLS y mide bytes/s reales en local',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seg = _fakeTsSegment(64 * 1024);
      server.listen((req) async {
        if (req.uri.path == '/master.m3u8') {
          req.response
            ..statusCode = 200
            ..write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2500000\n/pl.m3u8\n');
          await req.response.close();
        } else if (req.uri.path == '/pl.m3u8') {
          req.response
            ..statusCode = 200
            ..write('#EXTM3U\n#EXTINF:6.0,\n/seg0.ts\n');
          await req.response.close();
        } else if (req.uri.path == '/seg0.ts') {
          req.response
            ..statusCode = 200
            ..add(seg);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      try {
        final res = await StreamValidator.probeUrl(
          'http://127.0.0.1:${server.port}/master.m3u8',
          server: 'streamwish',
        );
        expect(res.isValid, isTrue);
        expect(res.bytesRead, greaterThanOrEqualTo(49152));
        expect(res.bytesPerSec, greaterThan(0));
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('v3.3.55 — HlsStreamProxy eagerWarmup y VodPlaybackWarmupService', () {
    test('eagerWarmup pre-descarga master, sub-playlist y primeros segmentos antes de que libmpv conecte',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seg = _fakeTsSegment(32 * 1024);
      final requested = <String>[];
      server.listen((req) async {
        requested.add(req.uri.path);
        if (req.uri.path == '/master.m3u8') {
          req.response
            ..statusCode = 200
            ..write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2500000\n/pl.m3u8\n');
          await req.response.close();
        } else if (req.uri.path == '/pl.m3u8') {
          req.response
            ..statusCode = 200
            ..write('#EXTM3U\n#EXTINF:6.0,\n/seg0.ts\n#EXTINF:6.0,\n/seg1.ts\n');
          await req.response.close();
        } else if (req.uri.path.startsWith('/seg')) {
          req.response
            ..statusCode = 200
            ..add(seg);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      try {
        final reg = await HlsStreamProxy.instance.registerHlsSession(
          upstreamUrl: 'http://127.0.0.1:${server.port}/master.m3u8',
          tag: 'eager_test',
          eagerWarmup: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(requested, contains('/master.m3u8'));
        expect(requested, contains('/pl.m3u8'));
        expect(requested, contains('/seg0.ts'));

        final client = HttpClient();
        final sw = Stopwatch()..start();
        final req = await client.getUrl(Uri.parse(reg.localUrl));
        final res = await req.close();
        final body = await res.transform(const SystemEncoding().decoder).join();
        sw.stop();
        client.close(force: true);

        expect(res.statusCode, 200);
        expect(body, contains('/pl/0.m3u8'));
        expect(sw.elapsedMilliseconds, lessThan(200));

        HlsStreamProxy.instance.releaseSession(reg.sessionId);
      } finally {
        await server.close(force: true);
      }
    });

    test('VodPlaybackWarmupService precalienta película y entrega sesión lista en <100ms',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seg = _fakeTsSegment(32 * 1024);
      server.listen((req) async {
        if (req.uri.path == '/master.m3u8') {
          req.response
            ..statusCode = 200
            ..write('#EXTM3U\n#EXTINF:6.0,\n/seg0.ts\n#EXTINF:6.0,\n/seg1.ts\n');
          await req.response.close();
        } else if (req.uri.path.startsWith('/seg')) {
          req.response
            ..statusCode = 200
            ..add(seg);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      try {
        final movie = VodItem(
          id: 'warm_dbz_test',
          title: 'Dragon Ball Z: El Poder Invencible',
          sources: [
            StreamSource(
              url: 'http://127.0.0.1:${server.port}/master.m3u8',
              quality: 'HD · Latino',
              server: 'streamwish',
            ),
          ],
        );

        VodPlaybackWarmupService.instance.warmUp(item: movie);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final sw = Stopwatch()..start();
        final bundle = await VodPlaybackWarmupService.instance
            .consumeOrAttach(movie.id);
        sw.stop();

        expect(bundle, isNotNull);
        expect(bundle!.sources.first.url, contains('/master.m3u8'));
        expect(bundle.bytesCached, greaterThan(0));
        expect(sw.elapsedMilliseconds, lessThan(100));

        final second = await VodPlaybackWarmupService.instance
            .consumeOrAttach(movie.id);
        expect(second, isNull);

        HlsStreamProxy.instance.releaseSession(bundle.sessionId);
      } finally {
        await server.close(force: true);
      }
    });
  });
}
