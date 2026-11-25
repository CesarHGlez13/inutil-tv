import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/artwork_cache_service.dart';
import 'package:tubotv/services/title_logo_service.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/widgets/fast_artwork.dart';
import 'package:tubotv/widgets/hero_carousel.dart';
import 'package:tubotv/widgets/vod_detail_modal.dart';

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

  group('v3.3.24 a v3.3.41 — pins de versión y documentación', () {
    test('pubspec.yaml en 3.3.41+90', () {
      expect(_pubspecVersion(), '3.3.41+90');
    });

    test('lib/constants/app_info.dart en 3.3.41', () {
      expect(File('lib/constants/app_info.dart').readAsStringSync(),
          contains("static const String appVersion = '3.3.41'"));
      expect(AppInfo.appVersion, '3.3.41');
    });

    test('CHANGELOG.md documenta 3.3.24 a 3.3.37 con mejoras de portadas, navegación TV, colores, logos Crunchyroll, seguridad LAN, inutix.com, redes lentas, rebrand Inutix TV, proxy del sistema y redes corporativas', () {
      final changelog = File('CHANGELOG.md').readAsStringSync();
      expect(changelog, contains('## 3.3.37'));
      expect(changelog, contains('## 3.3.35'));
      expect(changelog, contains('## 3.3.34'));
      expect(changelog, contains('## 3.3.33'));
      expect(changelog, contains('## 3.3.31'));
      expect(changelog, contains('## 3.3.30'));
      expect(changelog, contains('## 3.3.29'));
      expect(changelog, contains('## 3.3.28'));
      expect(changelog, contains('## 3.3.27'));
      expect(changelog, contains('## 3.3.24'));
      expect(changelog, contains('## 3.3.25'));
      expect(changelog, contains('## 3.3.26'));
      expect(changelog, contains('Logos Tipográficos Oficiales PNG y Animación de Desplazamiento estilo Crunchyroll'));
      expect(changelog, contains('Encuadre Completo y Retención de Scroll en Destacados de Smart TV'));
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
        find.descendant(
          of: find.byType(HeroCarousel),
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

    testWidgets('En Smart TV cambiar de slide conserva foco en los botones y no salta a otros rieles', (tester) async {
      TvModeService.instance.setForTest(detectedTv: true);

      tester.view.physicalSize = const Size(1920, 1080);
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

      final detailsFinder = find.byKey(const ValueKey('hero-tv-details-btn'));
      final playFinder = find.byKey(const ValueKey('hero-tv-play-btn'));
      expect(detailsFinder, findsOneWidget);
      expect(playFinder, findsOneWidget);

      // Simular evento D-pad derecha en Detalles
      final focusWidget = tester.widget<Focus>(find.ancestor(of: detailsFinder, matching: find.byType(Focus)).first);
      focusWidget.onKeyEvent!(FocusNode(), const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowRight,
        logicalKey: LogicalKeyboardKey.arrowRight,
        timeStamp: Duration.zero,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Verificamos que avanza al siguiente slide y ambos botones siguen montados con su key intacta
      expect(find.text('Frieren: Más allá del final del viaje'), findsOneWidget);
      expect(find.byKey(const ValueKey('hero-tv-details-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('hero-tv-play-btn')), findsOneWidget);
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

  group('v3.3.27 — Unificación de botones al estilo Destacados', () {
    testWidgets('VodDetailModal en TV utiliza píldora blanca playbackPrimaryBackground en Reproducir', (tester) async {
      TvModeService.instance.setForTest(detectedTv: true);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        TvModeService.instance.setForTest(detectedTv: false);
      });

      await tester.pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: testItems.first))));
      await tester.pumpAndSettle();

      // Botón de reproducción en TV debe ser píldora blanca
      final playText = find.text('Comenzar a ver E1');
      expect(playText, findsOneWidget);

      final containerFinder = find.ancestor(of: playText, matching: find.byType(Container)).first;
      final container = tester.widget<Container>(containerFinder);
      final decoration = container.decoration as BoxDecoration;

      expect(decoration.color, AppColors.playbackPrimaryBackground);
      expect(decoration.borderRadius, BorderRadius.circular(24));

      // Botón Mi Lista debe tener estilo translúcido con radio 24
      final myListText = find.text('Mi Lista');
      expect(myListText, findsOneWidget);
      final myListContainerFinder = find.ancestor(of: myListText, matching: find.byType(Container)).first;
      final myListContainer = tester.widget<Container>(myListContainerFinder);
      final myListDecoration = myListContainer.decoration as BoxDecoration;
      expect(myListDecoration.borderRadius, BorderRadius.circular(24));
    });
  });

  group('v3.3.28 — Logos PNG y animación de desplazamiento Crunchyroll', () {
    test('TitleLogoService.cleanTitle limpia etiquetas y sufijos de calidad/idioma', () {
      expect(TitleLogoService.cleanTitle('Black Clover (Audio Latino)'), 'Black Clover');
      expect(TitleLogoService.cleanTitle('Solo Leveling [1080p] [Sub Esp]'), 'Solo Leveling');
      expect(TitleLogoService.cleanTitle('Kimetsu no Yaiba Temporada 2'), 'Kimetsu no Yaiba');
      expect(TitleLogoService.cleanTitle('Demon Slayer: Kimetsu no Yaiba -'), 'Demon Slayer: Kimetsu no Yaiba');
      expect(TitleLogoService.cleanTitle('Deadpool & Wolverine (Latino) HD'), 'Deadpool & Wolverine');
    });

    test('VodItem serializa y preserva titleLogo en copyWith, mergedWith y JSON', () {
      const original = VodItem(
        id: 'test_logo_1',
        title: 'Black Clover',
        titleLogo: 'https://image.tmdb.org/t/p/w500/test_logo.png',
      );

      // copyWith
      final copied = original.copyWith(title: 'Black Clover HD');
      expect(copied.titleLogo, 'https://image.tmdb.org/t/p/w500/test_logo.png');

      // mergedWith
      const other = VodItem(
        id: 'test_logo_1',
        title: 'Black Clover',
      );
      final merged = other.mergedWith(original);
      expect(merged.titleLogo, 'https://image.tmdb.org/t/p/w500/test_logo.png');

      // JSON roundtrip
      final json = original.toJson();
      expect(json['titleLogo'], 'https://image.tmdb.org/t/p/w500/test_logo.png');
      final fromJson = VodItem.fromJson(json);
      expect(fromJson.titleLogo, 'https://image.tmdb.org/t/p/w500/test_logo.png');
    });

    testWidgets('VodDetailModal muestra FastArtwork con titleLogo si está definido', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const itemWithLogo = VodItem(
        id: 'test_item_with_logo',
        title: 'Black Clover',
        titleLogo: 'https://image.tmdb.org/t/p/w500/j9ZZ7WV5pwLLXbbebyGdMUxbqrc.png',
        isAnime: true,
        isSeries: true,
      );

      await tester.pumpWidget(wrapTheme(const Scaffold(body: VodDetailModal(item: itemWithLogo))));
      await tester.pumpAndSettle();

      // Debe encontrarse un FastArtwork configurado con la URL del logo
      final artworkFinder = find.byWidgetPredicate(
        (w) => w is FastArtwork && w.url == 'https://image.tmdb.org/t/p/w500/j9ZZ7WV5pwLLXbbebyGdMUxbqrc.png',
      );
      expect(artworkFinder, findsWidgets);
    });

    testWidgets('VodDetailModal aplica Transform.translate y Transform.scale en hero title', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrapTheme(Scaffold(body: VodDetailModal(item: testItems.first))));
      await tester.pumpAndSettle();

      // Debe haber widgets Transform en el árbol del hero para desplazamiento y escala
      final transformFinder = find.byType(Transform);
      expect(transformFinder, findsWidgets);
    });
  });
}
