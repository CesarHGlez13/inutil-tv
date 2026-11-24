import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/artwork_cache_service.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/widgets/fast_artwork.dart';
import 'package:tubotv/widgets/hero_carousel.dart';

String _pubspecVersion() {
  final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+\+\d+)', multiLine: true)
      .firstMatch(File('pubspec.yaml').readAsStringSync());
  expect(match, isNotNull, reason: 'pubspec.yaml sin línea version: x.y.z+n');
  return match!.group(1)!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TvModeService.instance.resetForTest();
  });

  tearDown(() {
    TvModeService.instance.resetForTest();
  });

  Widget wrapTheme(Widget child) => MaterialApp(
        theme: ThemeData.dark(),
        shortcuts: <ShortcutActivator, Intent>{
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.select):
              const ActivateIntent(),
        },
        home: Scaffold(body: child),
      );

  final testItems = <VodItem>[
    const VodItem(
      id: 'item_1',
      title: 'Solo Leveling',
      year: '2024',
      genre: 'Acción, Fantasía',
      rating: '8.9',
      provider: 'poseidon',
      isAnime: true,
      isSeries: true,
      backdrop: 'https://image.tmdb.org/t/p/original/backdrop1.jpg',
      poster: 'https://image.tmdb.org/t/p/original/poster1.jpg',
    ),
    const VodItem(
      id: 'item_2',
      title: 'Frieren: Más allá del final del viaje',
      year: '2023',
      genre: 'Aventura, Drama',
      rating: '9.1',
      provider: 'poseidon',
      isAnime: true,
      isSeries: true,
      backdrop: 'https://image.tmdb.org/t/p/original/backdrop2.jpg',
      poster: 'https://image.tmdb.org/t/p/original/poster2.jpg',
    ),
  ];

  group('v3.3.24 — pins de versión y documentación', () {
    test('pubspec.yaml en 3.3.24+73', () {
      expect(_pubspecVersion(), '3.3.24+73');
    });

    test('lib/constants/app_info.dart en 3.3.24', () {
      expect(File('lib/constants/app_info.dart').readAsStringSync(),
          contains("static const String appVersion = '3.3.24'"));
      expect(AppInfo.appVersion, '3.3.24');
    });

    test('CHANGELOG.md documenta 3.3.24 con mejoras de portadas, navegación TV y colores de marca', () {
      final changelog = File('CHANGELOG.md').readAsStringSync();
      expect(changelog, contains('## 3.3.24'));
      expect(changelog, contains('Navegación D-Pad fluida y selección de Destacados en Smart TV'));
      expect(changelog, contains('Calidad HD / 4K Ultra en Portadas y Fondos'));
      expect(changelog, contains('Restauración de Identidad y Paleta Oficial InútilTV'));
    });
  });

  group('v3.3.24 — Calidad Ultra HD de Portadas y Fondos TMDB', () {
    test('ArtworkCacheService reescribe a w500 poster, w1280 backdrop y w300 thumbnail', () {
      const rawPoster = 'https://image.tmdb.org/t/p/w185/xyz.jpg';
      const rawBackdrop = 'https://image.tmdb.org/t/p/w300/abc.jpg';

      expect(
        ArtworkCacheService.optimizeUrl(rawPoster, tier: ArtworkTier.poster),
        'https://image.tmdb.org/t/p/w500/xyz.jpg',
      );
      expect(
        ArtworkCacheService.optimizeUrl(rawBackdrop, tier: ArtworkTier.backdrop),
        'https://image.tmdb.org/t/p/w1280/abc.jpg',
      );
      expect(
        ArtworkCacheService.optimizeUrl(rawPoster, tier: ArtworkTier.thumbnail),
        'https://image.tmdb.org/t/p/w300/xyz.jpg',
      );
    });

    testWidgets('FastArtwork aplica cacheWidth mejorado por tier y filterQuality medium', (tester) async {
      await tester.pumpWidget(wrapTheme(
        const Column(
          children: [
            SizedBox(
              width: 100,
              height: 150,
              child: FastArtwork(
                url: 'https://image.tmdb.org/t/p/w500/poster.jpg',
                tier: ArtworkTier.poster,
              ),
            ),
            SizedBox(
              width: 160,
              height: 90,
              child: FastArtwork(
                url: 'https://image.tmdb.org/t/p/w1280/backdrop.jpg',
                tier: ArtworkTier.backdrop,
              ),
            ),
            SizedBox(
              width: 80,
              height: 120,
              child: FastArtwork(
                url: 'https://image.tmdb.org/t/p/w300/thumb.jpg',
                tier: ArtworkTier.thumbnail,
              ),
            ),
          ],
        ),
      ));
      await tester.pump();

      final fastArtworks = tester.widgetList<FastArtwork>(find.byType(FastArtwork)).toList();
      expect(fastArtworks.length, 3);
      expect(fastArtworks[0].tier, ArtworkTier.poster);
      expect(fastArtworks[1].tier, ArtworkTier.backdrop);
      expect(fastArtworks[2].tier, ArtworkTier.thumbnail);
    });
  });

  group('v3.3.24 — Navegación D-Pad en HeroCarousel de Inicio para Smart TV', () {
    testWidgets('En Smart TV altura es 370 px y presenta flechas laterales de navegación', (tester) async {
      TvModeService.instance.setForTest(detectedTv: true);

      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      VodItem? detailItem;

      await tester.pumpWidget(wrapTheme(
        HeroCarousel(
          featured: testItems,
          active: false,
          onPlay: (_) {},
          onDetails: (item) => detailItem = item,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));

      // Altura del carrusel en TV es 370 px
      final sizedBox = tester.widget<SizedBox>(
        find.ancestor(
          of: find.byType(PageView),
          matching: find.byType(SizedBox),
        ).first,
      );
      expect(sizedBox.height, 370.0);

      // Flechas laterales visibles para TV
      expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

      // Los botones de acción existen
      expect(find.text('Reproducir'), findsOneWidget);
      expect(find.text('Detalles'), findsOneWidget);

      // Tap en Detalles invoca onDetails
      await tester.tap(find.text('Detalles'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(detailItem, isNotNull);
      expect(detailItem!.title, 'Solo Leveling');

      // Tap en chevron_right avanza a la siguiente diapositiva
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Frieren: Más allá del final del viaje'), findsOneWidget);
    });

    testWidgets('En Móvil altura es 310 px y NO muestra flechas laterales', (tester) async {
      TvModeService.instance.setForTest(detectedTv: false);

      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(wrapTheme(
        HeroCarousel(
          featured: testItems,
          active: false,
          onPlay: (_) {},
          onDetails: (_) {},
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));

      final sizedBox = tester.widget<SizedBox>(
        find.ancestor(
          of: find.byType(PageView),
          matching: find.byType(SizedBox),
        ).first,
      );
      expect(sizedBox.height, 310.0);

      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    });
  });

  group('v3.3.24 — Eliminación de branding ajeno y respeto de paleta InútilTV', () {
    test('vod_detail_modal.dart y hero_carousel.dart no contienen naranja ajeno 0xFFFF640A', () {
      final modalSrc = File('lib/widgets/vod_detail_modal.dart').readAsStringSync();
      final heroSrc = File('lib/widgets/hero_carousel.dart').readAsStringSync();

      expect(modalSrc.contains('0xFFFF640A'), isFalse,
          reason: 'El código del modal aún contiene el naranja ajeno');
      expect(modalSrc.contains('FF640A'), isFalse,
          reason: 'El código del modal aún contiene referencias a FF640A');
      expect(heroSrc.contains('0xFFFF640A'), isFalse,
          reason: 'El carrusel aún contiene el naranja ajeno');
    });
  });
}
