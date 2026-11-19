import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/screens/settings_screen.dart';
import 'package:tubotv/services/app_settings_service.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/live_tv_sync_service.dart';
import 'package:tubotv/services/pelisflix_service.dart';
import 'package:tubotv/services/stream_validator.dart';
import 'package:tubotv/theme/app_colors.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/poster_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InútilTV v3.0 — Validador anti-DMCA, Limpieza y Multi-Fuente', () {
    test('StreamValidator rechaza HTML de DMCA y acepta bytes MPEG-TS / MP4 / MKV', () {
      final dmcaHtml = utf8.encode(
        '<html><body><h1>File deleted by DMCA request</h1></body></html>',
      );
      expect(StreamValidator.isPlayableMediaBytes(dmcaHtml), isFalse);

      final jsonErr = utf8.encode('{"error": "forbidden", "code": 403}');
      expect(StreamValidator.isPlayableMediaBytes(jsonErr), isFalse);

      // MPEG-TS sync packet (0x47 ...)
      final tsBytes = List<int>.filled(188, 0x11)..[0] = 0x47;
      expect(StreamValidator.isPlayableMediaBytes(tsBytes), isTrue);

      // MP4 ftyp header
      final mp4Bytes = [
        0x00, 0x00, 0x00, 0x18,
        0x66, 0x74, 0x79, 0x70, // 'ftyp'
        0x69, 0x73, 0x6F, 0x6D, // 'isom'
        0x00, 0x00, 0x02, 0x00,
      ];
      expect(StreamValidator.isPlayableMediaBytes(mp4Bytes), isTrue);

      // Matroska EBML header
      final mkvBytes = List<int>.filled(32, 0x00)
        ..[0] = 0x1A
        ..[1] = 0x45
        ..[2] = 0xDF
        ..[3] = 0xA3;
      expect(StreamValidator.isPlayableMediaBytes(mkvBytes), isTrue);
    });

    test('PelisflixService descarta portadas 404x.jpg y elimina títulos duplicados', () {
      const sampleHtml = '''
      <ul>
        <li>
          <a href="https://pelisflix1.guru/pelicula/talento-para-matar-3/">
            <span class="Title">Talento para matar</span>
            <img src="https://imgs.repelisplus.hair/404x.jpg" />
          </a>
        </li>
        <li>
          <a href="https://pelisflix1.guru/pelicula/talento-para-matar-2/">
            <span class="Title">Talento para matar</span>
            <img src="https://image.tmdb.org/t/p/w500/real1.jpg" />
          </a>
        </li>
        <li>
          <a href="https://pelisflix1.guru/pelicula/talento-para-matar/">
            <span class="Title">Talento para matar</span>
            <img src="https://image.tmdb.org/t/p/w500/real2.jpg" />
          </a>
        </li>
      </ul>
      ''';
      final items = PelisflixService().parseItemsFromHtml(sampleHtml);
      expect(items.length, 1);
      expect(items.first.poster, contains('real1.jpg'));
      expect(items.first.rating, isEmpty);
    });

    test('JkAnimeService convierte miniaturas borrosas 60px a portadas HD y normaliza tildes', () {
      final hd = JkAnimeService.upgradePosterUrl(
        'https://cdn.jkdesa.com/assets/images/animes/image/thumbnail/dragon-ball-z.jpg',
        'dragon-ball-z',
      );
      expect(hd, 'https://cdn.jkdesa.com/assets/images/animes/image/dragon-ball-z.jpg');
      expect(StreamValidator.stripAccents('Dragón Ball Z'), 'Dragon Ball Z');
    });

    test('LiveTvSyncService fusiona respaldos multi-señal sin duplicar canales ni URLs', () {
      final base = [
        const Channel(
          id: 'espn',
          name: 'ESPN HD',
          group: 'Deportes',
          sources: [StreamSource(url: 'https://srv1.test/espn.m3u8')],
        ),
      ];
      final remote = [
        const Channel(
          id: 'espn_alt',
          name: 'ESPN (1080p)',
          group: 'Deportes',
          sources: [
            StreamSource(url: 'https://srv1.test/espn.m3u8'),
            StreamSource(url: 'https://srv2.test/espn_backup.m3u8'),
          ],
        ),
      ];
      final merged = LiveTvSyncService.mergeChannels(base, remote);
      expect(merged.length, 1);
      expect(merged.first.sources.length, 2);
      expect(merged.first.sources[1].url, 'https://srv2.test/espn_backup.m3u8');
    });

    test('assets/channels_master.json contiene +1,000 canales verificados sin duplicados ni fuentes vacías', () {
      final raw = File('assets/channels_master.json').readAsStringSync();
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      expect(list.length, greaterThan(1000));
      final seenIds = <String>{};
      var multiSource = 0;
      for (final ch in list) {
        final id = ch['id'] as String;
        expect(seenIds.add(id), isTrue, reason: 'ID duplicado: $id');
        final sources = ch['sources'] as List;
        expect(sources, isNotEmpty);
        if (sources.length > 1) multiSource++;
      }
      expect(multiSource, greaterThan(50));
    });
  });

  group('InútilTV v3.0 — Paridad Visual Inútil Music y App 100% Usuario', () {
    testWidgets('PosterCard(expandInGrid: true) en grid móvil 360px 3-col tiene CERO overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final items = List.generate(
        9,
        (i) => VodItem(
          id: 'm_$i',
          title: 'Película de Prueba Muy Larga Número $i',
          year: '2026',
          genre: 'Acción · Drama',
          rating: '7.8',
          provider: 'poseidon',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppColors.buildDarkTheme(
            accent: AppAccent.white,
            surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
          ),
          home: Scaffold(
            body: GridView.builder(
              padding: const EdgeInsets.all(16),
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
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(PosterCard), findsNWidgets(9));
    });

    testWidgets('SettingsScreen muestra Apariencia Inútil Music y CERO botón de Admin interno', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await AppSettingsService.instance.load();

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

      expect(find.text('Apariencia'), findsOneWidget);
      expect(find.text('Liquid Glass'), findsOneWidget);
      expect(find.text('Color de acento'), findsOneWidget);

      // Verificación estricta: administración solo en Firebase Web, NUNCA en la app
      expect(find.textContaining('Panel de Control César'), findsNothing);
      expect(find.byIcon(Icons.admin_panel_settings_rounded), findsNothing);
      expect(AppInfo.appVersion, matches(RegExp(r'^3\.\d+\.\d+$')));
    });

    test('AppSettingsService persiste AppAccent, SurfaceBackgroundMode y AppThemeMode', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppSettingsService.instance;
      await s.setAccent(AppAccent.green);
      await s.setSurfaceMode(SurfaceBackgroundMode.transparent);
      await s.setThemeMode(AppThemeMode.light);

      expect(s.accent, AppAccent.green);
      expect(s.surfaceMode, SurfaceBackgroundMode.transparent);
      expect(s.themeMode, AppThemeMode.light);

      // Restaurar defaults monocromáticos
      await s.setAccent(AppAccent.white);
      await s.setSurfaceMode(SurfaceBackgroundMode.liquidGlass);
      await s.setThemeMode(AppThemeMode.dark);
    });
  });
}
