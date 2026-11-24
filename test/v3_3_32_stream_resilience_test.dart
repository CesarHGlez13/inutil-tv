import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/cuevana_poseidon_service.dart';
import 'package:tubotv/services/hls_stream_proxy.dart';
import 'package:tubotv/services/stream_validator.dart';

void main() {
  group('v3.3.32 — Resiliencia de streaming y optimización para redes lentas', () {
    test('raceFirstNonNull retorna en cuanto gana el primer espejo sin esperar colgados',
        () async {
      final sw = Stopwatch()..start();
      final result = await CuevanaPoseidonService.raceFirstNonNull<String>([
        Future.delayed(const Duration(seconds: 5), () => 'slow'),
        Future.delayed(const Duration(milliseconds: 40), () => null),
        Future.delayed(const Duration(milliseconds: 80), () => 'fast_winner'),
      ]);
      sw.stop();

      expect(result, 'fast_winner');
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('collectBatchWithFastWin no espera a servidores lentos tras ventana de gracia',
        () async {
      final sw = Stopwatch()..start();
      const fastSrc = StreamSource(
        url: 'https://cdn.example/fast/master.m3u8',
        quality: 'HD · Latino',
        server: 'vidhide',
      );
      final results = await CuevanaPoseidonService.collectBatchWithFastWin(
        [
          Future.delayed(
            const Duration(milliseconds: 30),
            () => (fastSrc, StreamValidationStatus.valid),
          ),
          Future.delayed(
            const Duration(seconds: 5),
            () => (null as StreamSource?, StreamValidationStatus.timeout),
          ),
        ],
        graceWindow: const Duration(milliseconds: 120),
      );
      sw.stop();

      expect(results.length, 1);
      expect(results.first.$1?.url, fastSrc.url);
      expect(results.first.$2, StreamValidationStatus.valid);
      expect(sw.elapsedMilliseconds, lessThan(600));
    });

    test('rankExtractedM3u8Urls incluye respaldos master.txt (hls3) y descarta .txt no-HLS',
        () {
      const js = '''
        var notes = "https://example.com/readme.txt";
        var links = {
          "hls2": "https://cdn.premilkyway.com/hls2/01/abc/master.m3u8?t=1",
          "hls3": "https://mirror.store/hls3/01/abc/master.txt",
          "hls4": "/stream/abc/master.m3u8"
        };
      ''';
      final ranked =
          CuevanaPoseidonService.rankExtractedM3u8Urls(js, 'callistanise.com');

      expect(ranked, hasLength(3));
      expect(ranked[0], 'https://callistanise.com/stream/abc/master.m3u8');
      expect(ranked[1], 'https://mirror.store/hls3/01/abc/master.txt');
      expect(ranked[2], 'https://cdn.premilkyway.com/hls2/01/abc/master.m3u8?t=1');
      expect(ranked.any((u) => u.contains('readme.txt')), isFalse);
    });

    test('HlsStreamProxy.adaptiveLookaheadForThroughput reduce lookahead en redes lentas',
        () {
      expect(HlsStreamProxy.adaptiveLookaheadForThroughput(0), 3);
      expect(HlsStreamProxy.adaptiveLookaheadForThroughput(80 * 1024), 1);
      expect(HlsStreamProxy.adaptiveLookaheadForThroughput(199 * 1024), 1);
      expect(HlsStreamProxy.adaptiveLookaheadForThroughput(350 * 1024), 2);
      expect(HlsStreamProxy.adaptiveLookaheadForThroughput(900 * 1024), 4);
    });

    test('StreamValidator.validateUrlDetailed distingue valid, invalid (404/DMCA) y timeout',
        () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path == '/master.m3u8') {
          req.response
            ..statusCode = 200
            ..write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000\nindex.m3u8\n');
          await req.response.close();
        } else if (req.uri.path == '/index.m3u8') {
          req.response
            ..statusCode = 200
            ..write('#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n');
          await req.response.close();
        } else if (req.uri.path == '/seg0.ts') {
          final ts = List<int>.filled(376, 0);
          ts[0] = 0x47;
          ts[188] = 0x47;
          req.response
            ..statusCode = 206
            ..add(ts);
          await req.response.close();
        } else if (req.uri.path == '/dmca.ts') {
          req.response
            ..statusCode = 200
            ..write('<html><body>File deleted by DMCA request</body></html>');
          await req.response.close();
        } else if (req.uri.path == '/slow.m3u8') {
          await Future<void>.delayed(const Duration(seconds: 2));
          try {
            req.response.statusCode = 200;
            await req.response.close();
          } catch (_) {}
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });

      try {
        final base = 'http://127.0.0.1:${server.port}';
        expect(
          await StreamValidator.validateUrlDetailed('$base/master.m3u8'),
          StreamValidationStatus.valid,
        );
        expect(
          await StreamValidator.validateUrlDetailed('$base/dmca.ts'),
          StreamValidationStatus.invalid,
        );
        expect(
          await StreamValidator.validateUrlDetailed('$base/missing.m3u8'),
          StreamValidationStatus.invalid,
        );
        expect(
          await StreamValidator.validateUrlDetailed(
            '$base/slow.m3u8',
            timeout: const Duration(milliseconds: 250),
          ),
          StreamValidationStatus.timeout,
        );
      } finally {
        await server.close(force: true);
        HttpOverrides.global = prevOverrides;
      }
    });
  });
}
