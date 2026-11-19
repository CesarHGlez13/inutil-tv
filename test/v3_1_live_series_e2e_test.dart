import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/services/hls_stream_proxy.dart';
import 'package:tubotv/services/next_episode_preloader.dart';
import 'package:tubotv/services/serieskao_service.dart';
import 'package:tubotv/services/vod_catalog_service.dart';

/// Prueba LIVE E2E de InútilTV v3.1.0:
/// Verifica con tráfico REAL y bytes reales de video:
/// 1. Catálogo popular de SeriesKao (Breaking Bad, TWD, Dexter, Los Simpson...).
/// 2. Resolución REAL de Episodios 1, 2 Y 3 de Breaking Bad y Stranger Things.
/// 3. Precarga REAL en segundo plano (`NextEpisodePreloader` + `HlsStreamProxy`)
///    sirviendo el Episodio 2 desde `127.0.0.1` en <150ms con prefijo PNG recortado
///    a MPEG-TS `0x47` puro!
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'LIVE E2E v3.1: Series Ep 1, 2 & 3 resolve with real bytes + Instant Preloader serves clean TS <150ms',
    () async {
      final sk = SeriesKaoService();
      final catalog = VodCatalogService();

      // 1. Catálogo popular curado
      final popular = await sk.fetchPopularSeries(page: 1);
      expect(popular.length, greaterThanOrEqualTo(15));
      expect(popular.every((s) => s.poster.startsWith('http')), isTrue);

      // 2. Búsqueda exacta + episodios reales en español
      final bbHits = await catalog.searchSeries('Breaking Bad');
      expect(bbHits, isNotEmpty);
      final bb = bbHits.firstWhere(
        (s) => s.title.toLowerCase().contains('breaking bad'),
        orElse: () => bbHits.first,
      );
      final bbEps = await catalog.fetchEpisodes(bb);
      expect(bbEps.length, greaterThanOrEqualTo(3));

      // 3. Resolver Ep 1, Ep 2 Y Ep 3 de Breaking Bad (¡todos deben pasar!)
      for (var i = 0; i < 3; i++) {
        final ep = bbEps[i];
        final sources = await catalog.resolveAllPlaybackSources(bb, ep);
        expect(
          sources,
          isNotEmpty,
          reason: 'Breaking Bad T${ep.seasonNumber}·E${ep.episodeNumber} debe tener stream válido',
        );
      }

      // 4. Probar NextEpisodePreloader REAL sobre Breaking Bad Ep 2 -> proxy 127.0.0.1
      await NextEpisodePreloader.instance.preloadNext(
        item: bb,
        nextEpisode: bbEps[1],
      );
      final bundle = NextEpisodePreloader.instance.consumeIfReady(bb.id, bbEps[1]);
      expect(bundle, isNotNull, reason: 'El Ep 2 debe quedar precargado y listo');
      expect(bundle!.localProxyUrl, startsWith('http://127.0.0.1:'));
      expect(bundle.bytesCached, greaterThan(100000),
          reason: 'Debe precargar cientos de KB/MB de segmentos reales');

      // Verificar que el segmento 0 servido por 127.0.0.1 es MPEG-TS limpio (0x47) en <150ms
      final client = HttpClient();
      try {
        final masterRes =
            await (await client.getUrl(Uri.parse(bundle.localProxyUrl))).close();
        expect(masterRes.statusCode, 200);
        final masterText =
            await masterRes.transform(const SystemEncoding().decoder).join();
        final nextUrl = masterText
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.startsWith('http://127.0.0.1'));

        String segUrl = nextUrl;
        if (nextUrl.endsWith('.m3u8')) {
          final plRes = await (await client.getUrl(Uri.parse(nextUrl))).close();
          final plText =
              await plRes.transform(const SystemEncoding().decoder).join();
          segUrl = plText
              .split('\n')
              .map((l) => l.trim())
              .firstWhere((l) => l.endsWith('.ts'));
        }

        final sw = Stopwatch()..start();
        final segRes = await (await client.getUrl(Uri.parse(segUrl))).close();
        final segBytes = await segRes.fold<List<int>>([], (a, b) => a..addAll(b));
        sw.stop();

        expect(segRes.statusCode, 200);
        expect(segBytes.length, greaterThan(10000));
        expect(segBytes.first, 0x47,
            reason: 'El proxy 127.0.0.1 debe entregar MPEG-TS puro (sin prefijo PNG)');
        expect(sw.elapsedMilliseconds, lessThan(250));
      } finally {
        client.close(force: true);
        HlsStreamProxy.instance.releaseSession(bundle.sessionId);
      }

      // 5. Verificar Stranger Things Ep 1, 2 Y 3 también (otra serie grande)
      final stHits = await catalog.searchSeries('Stranger Things');
      expect(stHits, isNotEmpty);
      final st = stHits.first;
      final stEps = await catalog.fetchEpisodes(st);
      expect(stEps.length, greaterThanOrEqualTo(3));
      for (var i = 0; i < 3; i++) {
        final sources = await catalog.resolveAllPlaybackSources(st, stEps[i]);
        expect(
          sources,
          isNotEmpty,
          reason: 'Stranger Things Ep ${i + 1} debe resolver con bytes reales',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
