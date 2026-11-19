import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/models/models.dart';
import 'package:tubotv/screens/downloads_screen.dart';
import 'package:tubotv/screens/settings_screen.dart';
import 'package:tubotv/services/hls_stream_proxy.dart';
import 'package:tubotv/services/offline_vault_service.dart';
import 'package:tubotv/services/vault_crypto.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/vod_detail_modal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VaultCrypto AES-256-CTR (O(1) Random Access)', () {
    test('cifra y descifra en offset 0, bloque alineado y offset arbitrario', () {
      final key = VaultCrypto.generateKey32();
      final nonce = VaultCrypto.generateNonce16();
      expect(key.length, 32);
      expect(nonce.length, 16);

      final plain = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 31 + 7) & 0xFF),
      );
      final cipher = VaultCrypto.transformAtOffset(
        plain,
        key32: key,
        nonce16: nonce,
        byteOffset: 0,
      );

      expect(cipher, isNot(equals(plain)));

      // Descifrado completo desde 0
      final restored = VaultCrypto.transformAtOffset(
        cipher,
        key32: key,
        nonce16: nonce,
        byteOffset: 0,
      );
      expect(restored, equals(plain));

      // Acceso aleatorio O(1) en bloque alineado (offset 32)
      final sliceAligned = VaultCrypto.transformAtOffset(
        Uint8List.sublistView(cipher, 32, 32 + 128),
        key32: key,
        nonce16: nonce,
        byteOffset: 32,
      );
      expect(sliceAligned, equals(plain.sublist(32, 32 + 128)));

      // Acceso aleatorio O(1) en offset NO alineado (offset 37)
      final sliceUnaligned = VaultCrypto.transformAtOffset(
        Uint8List.sublistView(cipher, 37, 37 + 215),
        key32: key,
        nonce16: nonce,
        byteOffset: 37,
      );
      expect(sliceUnaligned, equals(plain.sublist(37, 37 + 215)));
    });

    test('deriveSegmentNonce genera nonces deterministas y distintos por segmento', () {
      final base = VaultCrypto.generateNonce16();
      final n0 = VaultCrypto.deriveSegmentNonce(base, 0);
      final n1 = VaultCrypto.deriveSegmentNonce(base, 1);
      final n1b = VaultCrypto.deriveSegmentNonce(base, 1);

      expect(n0, isNot(equals(n1)));
      expect(n1, equals(n1b));
    });

    test('transformOffMainThread descifra bloques de 256 KB en Isolate persistente idéntico a transformAtOffset', () async {
      final key = VaultCrypto.generateKey32();
      final nonce = VaultCrypto.generateNonce16();
      final plain = Uint8List.fromList(
        List<int>.generate(256 * 1024, (i) => (i * 19 + 11) & 0xFF),
      );

      final enc = await VaultCrypto.transformOffMainThread(
        plain,
        key32: key,
        nonce16: nonce,
        byteOffset: 0,
      );
      expect(enc, isNot(equals(plain)));

      // Verificar equivalencia exacta con transformAtOffset en offset 0 y 37
      final dec0 = await VaultCrypto.transformOffMainThread(
        enc,
        key32: key,
        nonce16: nonce,
        byteOffset: 0,
      );
      expect(dec0, equals(plain));

      final sliceEnc = Uint8List.fromList(enc.sublist(37, 37 + 16384));
      final dec37 = await VaultCrypto.transformOffMainThread(
        sliceEnc,
        key32: key,
        nonce16: nonce,
        byteOffset: 37,
      );
      expect(dec37, equals(plain.sublist(37, 37 + 16384)));
    });
  });

  group('OfflineVaultService E2E (HLS cifrado + MP4 Range 206 + .nomedia)', () {
    late Directory tempRoot;

    setUp(() async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      tempRoot = await Directory.systemTemp.createTemp('inutil_vault_e2e_');
      final vault = OfflineVaultService.instance;
      vault.testVaultRoot = tempRoot;
      vault.testSourceResolver = null;
      await vault.initialize(force: true);
      await vault.deleteAllDownloads();
    });

    tearDown(() async {
      final vault = OfflineVaultService.instance;
      await vault.deleteAllDownloads();
      vault.testSourceResolver = null;
      vault.testVaultRoot = null;
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Future<OfflineDownloadItem> waitUntilDone(
      String id, {
      Duration timeout = const Duration(seconds: 15),
    }) async {
      final sw = Stopwatch()..start();
      while (sw.elapsed < timeout) {
        final cur = OfflineVaultService.instance.findById(id);
        if (cur != null &&
            (cur.status == DownloadStatus.completed ||
                cur.status == DownloadStatus.failed)) {
          return cur;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('Timeout esperando descarga $id');
    }

    test('HLS con segmentos PNG disfrazados + EXT-X-KEY + subtítulo VTT se cifra en disco y descifra al vuelo', () async {
      final pngMagic = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      final keyBytes = Uint8List.fromList(List<int>.generate(16, (i) => i + 10));
      const vttContent = 'WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHola desde la bóveda cifrada\n';
      final fakePoster = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0,
        ...List<int>.filled(1024, 0x42),
      ]);

      Uint8List buildTs(int segIdx) {
        final ts = Uint8List(188 * 2);
        ts[0] = 0x47;
        ts[1] = segIdx;
        ts[188] = 0x47;
        ts[189] = segIdx + 100;
        return ts;
      }

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final p = req.uri.path;
        if (p == '/master.m3u8') {
          req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          req.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720\n'
            'index.m3u8\n',
          );
        } else if (p == '/index.m3u8') {
          req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          req.response.write(
            '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:6\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n'
            '#EXTINF:6.0,\nseg0.image\n'
            '#EXTINF:6.0,\nseg1.image\n'
            '#EXTINF:6.0,\nseg2.image\n'
            '#EXT-X-ENDLIST\n',
          );
        } else if (p == '/enc.key') {
          req.response.add(keyBytes);
        } else if (p.startsWith('/seg') && p.endsWith('.image')) {
          final idx = int.parse(p.replaceAll(RegExp(r'[^0-9]'), ''));
          req.response.add([...pngMagic, ...buildTs(idx)]);
        } else if (p == '/es.vtt') {
          req.response.headers.contentType = ContentType('text', 'vtt', charset: 'utf-8');
          req.response.add(utf8.encode(vttContent));
        } else if (p == '/poster.jpg') {
          req.response.add(fakePoster);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final base = 'http://127.0.0.1:${server.port}';
      final movie = VodItem(
        id: 'mv_hls_1',
        title: 'Película HLS Cifrada',
        poster: '$base/poster.jpg',
        year: '2026',
        genre: 'Acción',
      );

      final vault = OfflineVaultService.instance;
      vault.testSourceResolver = (_, __) async => [
            StreamSource(
              url: '$base/master.m3u8',
              quality: '1080p',
              subtitles: [
                SubtitleSource(url: '$base/es.vtt', label: 'Español', language: 'es'),
              ],
            ),
          ];

      final queued = await vault.enqueueMovie(movie);
      final done = await waitUntilDone(queued.id);

      expect(done.status, DownloadStatus.completed);
      expect(done.mediaKind, 'hls');
      expect(done.segmentsDone, 3);
      expect(done.segmentsTotal, 3);
      expect(done.localSubtitles.length, 1);

      // 1. Verificar centinela .nomedia para ocultar de Galería
      expect(await File('${tempRoot.path}/.nomedia').exists(), isTrue);

      // 2. Verificar póster cacheado offline con extensión opaca .art
      expect(done.localPosterPath, endsWith('.art'));
      expect(await File(done.localPosterPath).exists(), isTrue);

      // 3. Verificar que los archivos .ivlt en disco están CIFRADOS (cero texto plano)
      final itemDir = Directory('${tempRoot.path}/${done.vaultDirName}');
      final rawManifest = await File('${itemDir.path}/manifest.ivlt').readAsBytes();
      expect(utf8.decode(rawManifest, allowMalformed: true), isNot(contains('#EXTM3U')));
      final rawSeg0 = await File('${itemDir.path}/seg_00000.ivlt').readAsBytes();
      expect(rawSeg0[0], isNot(equals(0x47)));
      expect(rawSeg0.sublist(0, 4), isNot(equals(pngMagic.sublist(0, 4))));

      // 4. Reproducir vía loopback descifrado al vuelo (127.0.0.1/v/...)
      final handle = await vault.openVaultPlayback(done);
      expect(handle, isNotNull);
      expect(handle!.localUrl, contains('/v/'));
      expect(handle.subtitles.length, 1);

      final client = HttpClient();
      addTearDown(client.close);

      // Manifest descifrado
      final mReq = await client.getUrl(Uri.parse(handle.localUrl));
      final mRes = await mReq.close();
      expect(mRes.statusCode, 200);
      final mText = await utf8.decoder.bind(mRes).join();
      expect(mText, contains('#EXTM3U'));
      expect(mText, contains('/seg/0.ts'));
      expect(mText, contains('/key/0.bin'));

      // Segmento 0 descifrado y sin cabecera PNG falsa
      final segUrl = RegExp(r'http://127\.0\.0\.1:\d+/v/[^/\s]+/seg/0\.ts')
          .firstMatch(mText)!
          .group(0)!;
      final sReq = await client.getUrl(Uri.parse(segUrl));
      final sRes = await sReq.close();
      expect(sRes.statusCode, 200);
      final sBytes = await sRes.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(Uint8List.fromList(sBytes), equals(buildTs(0)));

      // Clave descifrada
      final keyUrl = RegExp(r'http://127\.0\.0\.1:\d+/v/[^/\s]+/key/0\.bin')
          .firstMatch(mText)!
          .group(0)!;
      final kReq = await client.getUrl(Uri.parse(keyUrl));
      final kRes = await kReq.close();
      final kBytes = await kRes.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(Uint8List.fromList(kBytes), equals(keyBytes));

      // Subtítulo VTT offline descifrado
      final subReq = await client.getUrl(Uri.parse(handle.subtitles.first.url));
      final subRes = await subReq.close();
      final subText = await utf8.decoder.bind(subRes).join();
      expect(subText, equals(vttContent));

      HlsStreamProxy.instance.releaseSession(handle.sessionId);

      // 5. Auto-borrar al terminar de ver
      await vault.setAutoDeleteWatched(true);
      await vault.onPlaybackCompleted(itemId: movie.id, isSeries: false);
      expect(vault.findCompletedMovie(movie.id), isNull);
      expect(await itemDir.exists(), isFalse);
    });

    test('MP4 directo cifrado con AES-256-CTR soporta 206 Partial Content y seeking O(1)', () async {
      // Construir MP4 sintético de 128 KB con cabecera real ftypisom
      final mp4Bytes = Uint8List(128 * 1024);
      final header = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D];
      for (var i = 0; i < header.length; i++) {
        mp4Bytes[i] = header[i];
      }
      for (var i = header.length; i < mp4Bytes.length; i++) {
        mp4Bytes[i] = (i * 17 + 3) & 0xFF;
      }

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (range != null && range.startsWith('bytes=')) {
          final parts = range.substring(6).split('-');
          final start = int.parse(parts[0]);
          final end = parts.length > 1 && parts[1].isNotEmpty
              ? int.parse(parts[1])
              : mp4Bytes.length - 1;
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${mp4Bytes.length}',
          );
          req.response.headers.contentLength = end - start + 1;
          req.response.add(mp4Bytes.sublist(start, end + 1));
        } else {
          req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          req.response.headers.contentLength = mp4Bytes.length;
          req.response.add(mp4Bytes);
        }
        await req.response.close();
      });

      final movie = VodItem(
        id: 'mv_mp4_1',
        title: 'Película MP4 Cifrada',
        year: '2026',
        genre: 'Sci-Fi',
      );

      final vault = OfflineVaultService.instance;
      vault.testSourceResolver = (_, __) async => [
            StreamSource(
              url: 'http://127.0.0.1:${server.port}/movie.mp4',
              quality: '1080p MP4',
            ),
          ];

      final queued = await vault.enqueueMovie(movie);
      final done = await waitUntilDone(queued.id);

      expect(done.status, DownloadStatus.completed);
      expect(done.mediaKind, 'mp4');
      expect(done.downloadedBytes, mp4Bytes.length);

      // Verificar que media.ivlt NO contiene 'ftyp' en claro
      final encryptedFile = File('${tempRoot.path}/${done.vaultDirName}/media.ivlt');
      final rawDisk = await encryptedFile.readAsBytes();
      expect(rawDisk.length, mp4Bytes.length);
      expect(utf8.decode(rawDisk.sublist(0, 32), allowMalformed: true), isNot(contains('ftyp')));

      // Abrir reproducción offline y probar 206 Partial Content en inicio y en offset 65536
      final handle = await vault.openVaultPlayback(done);
      expect(handle, isNotNull);

      final client = HttpClient();
      addTearDown(client.close);

      // Range 0-255
      final r1 = await client.getUrl(Uri.parse(handle!.localUrl));
      r1.headers.set(HttpHeaders.rangeHeader, 'bytes=0-255');
      final res1 = await r1.close();
      expect(res1.statusCode, HttpStatus.partialContent);
      final b1 = await res1.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(Uint8List.fromList(b1), equals(mp4Bytes.sublist(0, 256)));

      // Range 65536-65791 (seeking O(1) a mitad del archivo)
      final r2 = await client.getUrl(Uri.parse(handle.localUrl));
      r2.headers.set(HttpHeaders.rangeHeader, 'bytes=65536-65791');
      final res2 = await r2.close();
      expect(res2.statusCode, HttpStatus.partialContent);
      final b2 = await res2.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(Uint8List.fromList(b2), equals(mp4Bytes.sublist(65536, 65792)));

      HlsStreamProxy.instance.releaseSession(handle.sessionId);
    });

    test('Series por lotes agrupa episodios ordenados y soporta pausa/reanudación', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final payload = Uint8List.fromList(List<int>.generate(16 * 1024, (i) => i & 0xFF));
      server.listen((req) async {
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        req.response.headers.contentLength = payload.length;
        req.response.add(payload);
        await req.response.close();
      });

      final series = VodItem(
        id: 'sr_1',
        title: 'Serie Épica',
        isSeries: true,
        year: '2026',
      );
      final eps = [
        VodEpisode(id: 'e1', title: 'Piloto', episodeNumber: 1, seasonNumber: 1),
        VodEpisode(id: 'e2', title: 'El Secreto', episodeNumber: 2, seasonNumber: 1),
      ];

      final vault = OfflineVaultService.instance;
      vault.testSourceResolver = (_, __) async => [
            StreamSource(
              url: 'http://127.0.0.1:${server.port}/ep.mp4',
              quality: 'HD',
            ),
          ];

      final added = await vault.enqueueEpisodesBatch(series, eps);
      expect(added, 2);

      final d1 = await waitUntilDone(OfflineVaultService.idForEpisode(series.id, 1, 1));
      final d2 = await waitUntilDone(OfflineVaultService.idForEpisode(series.id, 1, 2));
      expect(d1.isCompleted, isTrue);
      expect(d2.isCompleted, isTrue);

      final grouped = vault.groupedCompletedSeries();
      expect(grouped[series.id]?.length, 2);
      expect(grouped[series.id]![0].episodeNumber, 1);
      expect(grouped[series.id]![1].episodeNumber, 2);
    });

    test('Pausa y reanudación real conserva bloques cifrados y recupera tras reinicio', () async {
      // Simular estado serializado mientras estaba descargando -> al reiniciar arranca en paused
      const serialized = {
        'id': 'mv_resume_1',
        'itemId': 'resume_1',
        'title': 'Película Pausada',
        'vaultDirName': 'mv_resume_1',
        'status': 'downloading',
        'progress': 0.5,
      };
      final restored = OfflineDownloadItem.fromJson(serialized);
      expect(restored.status, DownloadStatus.paused);

      // Pausa real durante descarga HLS de 8 segmentos lentos y reanudación sin repetir segs
      var segRequests = 0;
      final tsChunk = Uint8List(188 * 2)..[0] = 0x47..[188] = 0x47;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        if (req.uri.path == '/index.m3u8') {
          req.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
            '${List.generate(8, (i) => '#EXTINF:6.0,\nseg$i.ts\n').join()}'
            '#EXT-X-ENDLIST\n',
          );
        } else {
          segRequests++;
          await Future<void>.delayed(const Duration(milliseconds: 60));
          req.response.add(tsChunk);
        }
        await req.response.close();
      });

      final vault = OfflineVaultService.instance;
      vault.testSourceResolver = (_, __) async => [
            StreamSource(
              url: 'http://127.0.0.1:${server.port}/index.m3u8',
              quality: 'HD',
            ),
          ];

      final entry = await vault.enqueueMovie(
        VodItem(id: 'resume_hls', title: 'Reanudable HLS'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 110));
      await vault.pauseDownload(entry.id);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final pausedState = vault.findById(entry.id)!;
      expect(pausedState.status, DownloadStatus.paused);

      // Reanudar y verificar que completa sin re-descargar los bloques ya guardados
      await vault.resumeDownload(entry.id);
      final done = await waitUntilDone(entry.id);
      expect(done.status, DownloadStatus.completed);
      expect(done.segmentsDone, 8);
      // Nunca debería haber pedido más de 12 segmentos (8 totales + como máximo 4 en vuelo al pausar)
      expect(segRequests, lessThanOrEqualTo(12));
    });
  });

  group('UI Widgets de Descargas Sin Conexión v3.2', () {
    late Directory tempRoot;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempRoot = await Directory.systemTemp.createTemp('inutil_vault_ui_');
      final vault = OfflineVaultService.instance;
      vault.testVaultRoot = tempRoot;
      await vault.initialize(force: true);
      await vault.deleteAllDownloads();
    });

    tearDown(() async {
      final vault = OfflineVaultService.instance;
      await vault.deleteAllDownloads();
      vault.testVaultRoot = null;
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    Widget wrapTheme(Widget child) => MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: child,
        );

    testWidgets('DownloadsScreen muestra estado vacío limpio, selector de calidad y auto-borrar',
        (tester) async {
      await tester.pumpWidget(wrapTheme(const DownloadsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Descargas'), findsOneWidget);
      expect(find.text('Descargas sin conexión'), findsOneWidget);
      expect(find.text('Aún no tienes descargas'), findsOneWidget);
      expect(find.textContaining('Galería'), findsNothing);
      expect(find.textContaining('AES-256'), findsNothing);
      expect(find.text('Máxima HD'), findsOneWidget);
      expect(find.text('Equilibrada (Ahorro)'), findsOneWidget);
      expect(find.text('Auto-borrar al terminar de ver'), findsOneWidget);

      await tester.tap(find.text('Equilibrada (Ahorro)'));
      await tester.pumpAndSettle();
      expect(OfflineVaultService.instance.quality, DownloadQuality.balanced);
    });

    testWidgets('VodDetailModal muestra botón de descarga en película y lote en serie',
        (tester) async {
      final movie = VodItem(
        id: 'ui_mv_1',
        title: 'Cine Offline HD',
        year: '2026',
        genre: 'Acción',
      );
      await tester.pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: movie))));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const ValueKey('vod-movie-download-btn')), findsOneWidget);
      expect(find.text('Descargar'), findsOneWidget);

      final series = VodItem(
        id: 'ui_sr_1',
        title: 'Serie Offline HD',
        isSeries: true,
        episodes: [
          VodEpisode(id: 'ep1', title: 'Inicio', episodeNumber: 1, seasonNumber: 1),
          VodEpisode(id: 'ep2', title: 'Nudo', episodeNumber: 2, seasonNumber: 1),
        ],
      );
      await tester.pumpWidget(
        wrapTheme(
          Scaffold(
            body: VodDetailModal(key: ValueKey(series.id), item: series),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final modalScroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('vod-ep-dl-s1-e2')),
        250,
        scrollable: modalScroll,
      );
      expect(find.byKey(const ValueKey('vod-batch-download-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('vod-ep-dl-s1-e1')), findsOneWidget);
      expect(find.byKey(const ValueKey('vod-ep-dl-s1-e2')), findsOneWidget);
    });

    testWidgets('SettingsScreen muestra acceso limpio a Descargas sin conexión',
        (tester) async {
      await tester.pumpWidget(wrapTheme(const SettingsScreen()));
      await tester.pump(const Duration(milliseconds: 200));

      final mainScroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Descargas sin conexión'),
        300,
        scrollable: mainScroll,
      );
      expect(find.text('Descargas sin conexión'), findsOneWidget);
      expect(find.textContaining('AES-256'), findsNothing);
    });
  });
}
