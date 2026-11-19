import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/artwork_cache_service.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/fast_artwork.dart';
import 'package:tubotv/widgets/glass_surface.dart';
import 'package:tubotv/widgets/hero_carousel.dart';
import 'package:tubotv/widgets/poster_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArtworkCacheService — URL Optimization, RAM/Disk LRU & Dedup', () {
    late Directory tempDir;

    setUp(() async {
      HttpOverrides.global = null;
      tempDir = await Directory.systemTemp.createTemp('inutil_artwork_test_');
      await ArtworkCacheService.instance.resetForTesting(dir: tempDir);
    });

    tearDown(() async {
      await ArtworkCacheService.instance.resetForTesting();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('optimizeUrl reescribe TMDB al tamaño exacto por tier y rechaza 404x', () {
      const orig = 'https://image.tmdb.org/t/p/original/abc123.jpg';
      const w500 = 'https://image.tmdb.org/t/p/w500/abc123.jpg';

      expect(
        ArtworkCacheService.optimizeUrl(orig, tier: ArtworkTier.poster),
        'https://image.tmdb.org/t/p/w342/abc123.jpg',
      );
      expect(
        ArtworkCacheService.optimizeUrl(w500, tier: ArtworkTier.poster),
        'https://image.tmdb.org/t/p/w342/abc123.jpg',
      );
      expect(
        ArtworkCacheService.optimizeUrl(orig, tier: ArtworkTier.backdrop),
        'https://image.tmdb.org/t/p/w780/abc123.jpg',
      );
      expect(
        ArtworkCacheService.optimizeUrl(w500, tier: ArtworkTier.thumbnail),
        'https://image.tmdb.org/t/p/w185/abc123.jpg',
      );
      expect(
        ArtworkCacheService.optimizeUrl('https://cdn.site/404x.jpg'),
        '',
      );
      expect(ArtworkCacheService.optimizeUrl(''), '');
    });

    test('deduplicación in-flight + escritura atómica + L2 disco + L1 RAM + caché negativa 404', () async {
      final hits = <String, int>{};
      final fakeJpg = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0,
        ...List<int>.generate(2048, (i) => i & 0xFF),
      ]);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final p = req.uri.path;
        hits[p] = (hits[p] ?? 0) + 1;
        if (p == '/missing.jpg') {
          req.response.statusCode = 404;
        } else {
          req.response.headers.contentType = ContentType('image', 'jpeg');
          req.response.add(fakeJpg);
        }
        await req.response.close();
      });

      final cache = ArtworkCacheService.instance;
      final url = 'http://127.0.0.1:${server.port}/poster1.jpg';

      // 1. 6 solicitudes simultáneas a la misma URL -> SOLO 1 petición HTTP real
      final results = await Future.wait(
        List.generate(6, (_) => cache.getBytes(url)),
      );
      for (final r in results) {
        expect(r, equals(fakeJpg));
      }
      expect(hits['/poster1.jpg'], 1);
      expect(cache.networkFetches, 1);

      // Esperar escritura atómica en disco y verificar cero .tmp huérfanos
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final files = tempDir.listSync().map((e) => e.path).toList();
      expect(files.where((p) => p.endsWith('.tmp')), isEmpty);
      expect(files.where((p) => p.endsWith('.img')).length, 1);

      // 2. Hit de L1 RAM (0 red)
      final fromRam = await cache.getBytes(url);
      expect(fromRam, equals(fakeJpg));
      expect(cache.ramHits, 1);
      expect(hits['/poster1.jpg'], 1);

      // 3. Limpiar solo RAM -> hit de L2 Disco (0 red!)
      await cache.clear(includeDisk: false);
      final fromDisk = await cache.getBytes(url);
      expect(fromDisk, equals(fakeJpg));
      expect(cache.diskHits, 1);
      expect(hits['/poster1.jpg'], 1);

      // 4. Caché negativa 404 -> no martilla el servidor al re-scrollear
      final badUrl = 'http://127.0.0.1:${server.port}/missing.jpg';
      expect(await cache.getBytes(badUrl), isNull);
      expect(await cache.getBytes(badUrl), isNull);
      expect(hits['/missing.jpg'], 1);

      // 5. Prefetch paralelo en lote (8 URLs)
      final batch = List.generate(
        8,
        (i) => 'http://127.0.0.1:${server.port}/batch_$i.jpg',
      );
      await cache.prefetchUrls(batch, maxConcurrent: 4);
      for (final u in batch) {
        expect(cache.peekRam(u), equals(fakeJpg));
      }
    });
  });

  group('UI Fluidez & RepaintBoundary v3.2.1', () {
    Widget wrapTheme(Widget child) => MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: Scaffold(body: child),
        );

    testWidgets('PosterCard usa FastArtwork + RepaintBoundary y cero overflow en grid 360px',
        (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final items = List.generate(
        6,
        (i) => VodItem(
          id: 'p_$i',
          title: 'Película Rápida $i',
          year: '2026',
          genre: 'Acción',
          rating: '8.4',
        ),
      );

      await tester.pumpWidget(
        wrapTheme(
          GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.56,
              crossAxisSpacing: 10,
              mainAxisSpacing: 14,
            ),
            itemCount: items.length,
            itemBuilder: (_, i) => PosterCard(
              item: items[i],
              expandInGrid: true,
              onTap: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(FastArtwork), findsNWidgets(6));
      expect(find.byType(RepaintBoundary), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('HeroCarousel soporta pausa por pestaña inactiva y dispose sin fugas de Timer',
        (tester) async {
      final featured = [
        const VodItem(id: 'h1', title: 'Hero Uno', year: '2026'),
        const VodItem(id: 'h2', title: 'Hero Dos', year: '2026'),
      ];

      await tester.pumpWidget(
        wrapTheme(
          HeroCarousel(
            featured: featured,
            active: true,
            onPlay: (_) {},
            onDetails: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Cambiar a pestaña inactiva -> pausa animaciones y timers
      await tester.pumpWidget(
        wrapTheme(
          HeroCarousel(
            featured: featured,
            active: false,
            onPlay: (_) {},
            onDetails: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Desmontar sin dejar timers pendientes
      await tester.pumpWidget(wrapTheme(const SizedBox.shrink()));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('GlassSurface aísla BackdropFilter en RepaintBoundary',
        (tester) async {
      await tester.pumpWidget(
        wrapTheme(
          const GlassSurface(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('Liquid Glass'),
            ),
          ),
        ),
      );
      expect(find.byType(RepaintBoundary), findsWidgets);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  });
}
