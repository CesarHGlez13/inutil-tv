import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/app_settings_service.dart';
import 'package:tubotv/services/inutil_update_service.dart';
import 'package:tubotv/services/my_list_service.dart';
import 'package:tubotv/services/watch_history.dart';
import 'package:tubotv/widgets/inutil_update_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    InutilUpdateService.testReleaseOverride = null;
  });

  tearDown(() {
    InutilUpdateService.testReleaseOverride = null;
  });

  group('OTA & Force OTA (Kill Switch)', () {
    test('AppInfo.appVersion está estrictamente sincronizada con pubspec.yaml', () {
      final pubspecFile = File('pubspec.yaml');
      expect(pubspecFile.existsSync(), isTrue);
      final pubspecContent = pubspecFile.readAsStringSync();
      final match = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true).firstMatch(pubspecContent);
      expect(match, isNotNull, reason: 'pubspec.yaml debe definir version: X.Y.Z');
      final pubspecVersion = match!.group(1);
      expect(AppInfo.appVersion, pubspecVersion,
          reason: 'Si AppInfo.appVersion no coincide con pubspec.yaml, la app mostrará un falso diálogo de actualización a los usuarios.');
    });

    test('detecta actualización disponible, ABI y kill switch correctamente', () {
      final info = InutilTvReleaseInfo(
        currentVersion: '2.0.0',
        latestVersion: '2.1.0',
        minSupportedVersion: '2.0.5',
        mandatory: false,
        apkDownloadUrl: 'https://example.com/universal.apk',
        androidDownloads: const {
          'arm64_v8a': 'https://example.com/arm64.apk',
          'armeabi_v7a': 'https://example.com/armv7.apk',
        },
        releaseNotes: const ['Nueva mejora'],
        publishedAt: DateTime.utc(2026, 11, 18),
      );

      expect(info.updateAvailable, isTrue);
      expect(info.belowMinSupported, isTrue);
      expect(info.effectiveMandatory, isTrue);
      expect(info.isBlockingUpdate, isTrue);
      expect(info.apkUrlForAbi('arm64-v8a'), 'https://example.com/arm64.apk');
      expect(info.apkUrlForAbi('armeabi-v7a'), 'https://example.com/armv7.apk');
      expect(info.apkUrlForAbi('x86_64'), 'https://example.com/universal.apk');
      expect(InutilUpdateService.releaseRepo, 'CesarHGlez13/inutil-tv');
    });

    test('versión al día jamás bloquea la app', () {
      final info = InutilTvReleaseInfo(
        currentVersion: '2.0.0',
        latestVersion: '2.0.0',
        minSupportedVersion: '2.0.0',
        mandatory: true,
        releaseNotes: const [],
        publishedAt: DateTime.utc(2026, 11, 18),
      );

      expect(info.updateAvailable, isFalse);
      expect(info.belowMinSupported, isFalse);
      expect(info.isBlockingUpdate, isFalse);
    });

    testWidgets('InutilUpdateGate bloquea toda la UI cuando OTA forzosa está activa',
        (tester) async {
      InutilUpdateService.testReleaseOverride = InutilTvReleaseInfo(
        currentVersion: '2.0.0',
        latestVersion: '2.5.0',
        minSupportedVersion: '2.2.0',
        mandatory: true,
        apkDownloadUrl: 'https://example.com/inutiltv-2.5.0.apk',
        releaseNotes: const ['Actualización obligatoria de seguridad'],
        publishedAt: DateTime.utc(2026, 11, 18),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: InutilUpdateGate(
            child: Scaffold(body: Center(child: Text('APP_NORMAL'))),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ACTUALIZACIÓN OBLIGATORIA'), findsOneWidget);
      expect(find.text('Inutix TV v2.5.0'), findsOneWidget);
      expect(find.text('Actualizar ahora'), findsOneWidget);
      expect(find.text('APP_NORMAL'), findsNothing);
    });

    testWidgets('InutilUpdateGate muestra la app normal cuando está al día',
        (tester) async {
      InutilUpdateService.testReleaseOverride = InutilTvReleaseInfo(
        currentVersion: '2.0.0',
        latestVersion: '2.0.0',
        mandatory: false,
        releaseNotes: const [],
        publishedAt: DateTime.utc(2026, 11, 18),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: InutilUpdateGate(
            child: Scaffold(body: Center(child: Text('APP_NORMAL'))),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('APP_NORMAL'), findsOneWidget);
      expect(find.text('ACTUALIZACIÓN OBLIGATORIA'), findsNothing);
    });
  });

  group('WatchHistory, Mi Lista y Ajustes Reales', () {
    test('WatchHistory guarda episodio, progreso y marca capítulo visto >= 85%',
        () async {
      final history = WatchHistory();
      await history.clear();

      const serie = VodItem(
        id: 'pf_serie_demo',
        title: 'Serie Demo',
        slug: 'serie-demo',
        isSeries: true,
        provider: 'pelisflix',
      );

      await history.record(
        serie,
        positionSec: 2300,
        durationSec: 2600,
        seasonNumber: 2,
        episodeNumber: 4,
        episodeTitle: 'Episodio 4',
      );

      final saved = history.progressFor('pf_serie_demo');
      expect(saved, isNotNull);
      expect(saved!.seasonNumber, 2);
      expect(saved.episodeNumber, 4);
      expect(saved.positionSec, 2300);
      expect(saved.label.contains('Viéndonos'), isFalse);
      expect(history.isEpisodeWatched('pf_serie_demo', 2, 4), isTrue);
      expect(history.isEpisodeWatched('pf_serie_demo', 2, 5), isFalse);
    });

    test('MyListService agrega y quita títulos correctamente', () async {
      final list = MyListService.instance;
      await list.clear();

      const movie = VodItem(id: 'm1', title: 'Película Test');
      expect(await list.toggle(movie), isTrue);
      expect(list.contains('m1'), isTrue);
      expect(await list.toggle(movie), isFalse);
      expect(list.contains('m1'), isFalse);
    });

    test('AppSettingsService guarda preferencias y cambia buffer real', () async {
      final settings = AppSettingsService.instance;
      await settings.setUltraBuffer(false);
      expect(settings.bufferSizeBytes, 16 * 1024 * 1024);
      await settings.setUltraBuffer(true);
      expect(settings.bufferSizeBytes, 64 * 1024 * 1024);

      await settings.setSkipIntroSeconds(90);
      expect(settings.skipIntroSeconds, 90);
    });
  });

  group('Catálogo TV depurado (channels_master.json)', () {
    test('0 URLs duplicadas, ESPN en Deportes y HBO en Cine y Series', () {
      final raw = File('assets/channels_master.json').readAsStringSync();
      final list = jsonDecode(raw) as List;
      final urls = <String>{};
      var espnInSports = false;
      var hboInCine = false;

      for (final item in list) {
        final m = item as Map<String, dynamic>;
        final srcs = (m['sources'] as List?) ?? [];
        for (final s in srcs) {
          final url = (s as Map)['url'] as String;
          expect(urls.add(url), isTrue, reason: 'URL duplicada: $url');
        }

        final name = (m['name'] as String).toLowerCase();
        final group = m['group'] as String;
        if (name.contains('espn') && group == 'Deportes') {
          espnInSports = true;
        }
        if (name.contains('hbo') && group == 'Cine y Series') {
          hboInCine = true;
        }
      }

      expect(espnInSports, isTrue);
      expect(hboInCine, isTrue);
    });
  });
}
