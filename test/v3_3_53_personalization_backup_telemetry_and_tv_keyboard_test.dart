import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/app_settings_service.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/firebase_config.dart';
import 'package:tubotv/services/firebase_firestore_service.dart';
import 'package:tubotv/services/inutil_cloud_backup_service.dart';
import 'package:tubotv/services/inutil_wrapped_service.dart';
import 'package:tubotv/services/my_list_service.dart';
import 'package:tubotv/services/tv_daily_usage_service.dart';
import 'package:tubotv/services/tv_mode_service.dart';
import 'package:tubotv/services/tv_taste_profile_service.dart';
import 'package:tubotv/services/watch_history.dart';
import 'package:tubotv/services/xuper_service.dart';
import 'package:tubotv/theme/app_theme.dart';
import 'package:tubotv/widgets/inutil_tv_keyboard.dart';
import 'package:tubotv/widgets/tv_focusable.dart';

const String _uid = 'uid_personalization_v3_3_53';

Future<void> _seedAuth() async {
  final prefs = await SharedPreferences.getInstance();
  final expires = DateTime.now().add(const Duration(days: 30));
  await prefs.setString(
    'inutil_tv_auth_user_v3',
    jsonEncode({
      'uid': _uid,
      'email': 'cesar@inutix.com',
      'displayName': 'Cesar',
      'role': 'user',
      'status': 'active',
      'isActive': true,
      'accountExpiresAt': expires.toIso8601String(),
      'currentTvDeviceId': '',
      'currentPhoneDeviceId': '',
    }),
  );
  await prefs.setString(
    'inutil_tv_auth_session_v3',
    jsonEncode({
      'uid': _uid,
      'email': 'cesar@inutix.com',
      'idToken': 'token-v3353',
      'refreshToken': 'refresh-v3353',
    }),
  );
  await prefs.setString(
    'inutil_tv_last_validated_v3',
    DateTime.now().toIso8601String(),
  );
  await InutilAuthService.instance.initialize();
}

VodItem _vod(
  String id,
  String title, {
  String genre = 'Acción',
  String overview = '',
  String year = '2025',
  String rating = '7.8',
  bool isSeries = false,
  bool isAnime = false,
  String quality = 'HD · Latino',
}) =>
    VodItem(
      id: id,
      title: title,
      poster: 'https://img.example.com/$id.jpg',
      backdrop: 'https://img.example.com/${id}_bg.jpg',
      overview: overview,
      year: year,
      genre: genre,
      rating: rating,
      isSeries: isSeries,
      isAnime: isAnime,
      provider: isAnime ? 'jkanime' : (isSeries ? 'serieskao' : 'poseidon'),
      quality: quality,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    InutilAuthService.testSkipOnlineValidation = true;
    FirebaseConfig.resetRelayReachability();
    FirebaseConfig.cloudRelayHostOverrideForTest = 'api.inutix.com';
    TvTasteProfileService.instance.resetForTest();
    InutilTvCloudBackupService.instance.resetForTest();
    InutilTvWrappedService.instance.resetDailyCountersForTest();
    TvDailyUsageService.instance.resetForTest();
    await WatchHistory().clear();
    await MyListService.instance.clear();
  });

  tearDown(() async {
    InutilFirestoreService.instance.testClient = null;
    FirebaseConfig.resetRelayReachability();
    await InutilAuthService.instance.signOut();
    InutilAuthService.testSkipOnlineValidation = false;
    TvTasteProfileService.instance.resetForTest();
    InutilTvCloudBackupService.instance.resetForTest();
    InutilTvWrappedService.instance.resetDailyCountersForTest();
    TvDailyUsageService.instance.resetForTest();
  });

  group('Pilar 1 — Motor de Perfil de Gustos (TvTasteProfileService)', () {
    test('normaliza géneros filtrando ruido de proveedor e infiere de sinopsis',
        () {
      expect(
        TvTasteProfileService.extractCanonicalGenres(
          genre: 'Serie · Latino / Sub',
          overview: 'Un viaje espacial futurista contra robots en la galaxia.',
          title: 'Odisea',
        ),
        contains('ciencia_ficcion'),
      );
      expect(
        TvTasteProfileService.extractCanonicalGenres(
          genre: 'Terror · Suspenso · HD',
        ),
        containsAll(['terror', 'suspenso']),
      );
      expect(
        TvTasteProfileService.extractCanonicalGenres(
          genre: 'Serie · Sub Español',
          isAnime: true,
        ),
        contains('anime'),
      );
    });

    test(
        'pondera completados > parciales, penaliza abandonos rápidos, aprende audio, búsquedas y horarios',
        () async {
      final taste = TvTasteProfileService.instance;
      final now = DateTime(2026, 11, 26, 22, 30);

      final scifiDone = _vod(
        'm_scifi_1',
        'Dune Parte Dos',
        genre: 'Ciencia Ficción · Aventura',
        quality: 'HD · Latino',
      );
      final horrorAbandoned = _vod(
        'm_horror_1',
        'Casa Maldita',
        genre: 'Terror',
        quality: 'HD · Subtitulado',
      );
      final scifiSeries = _vod(
        's_scifi_1',
        'Silo',
        genre: 'Ciencia Ficción · Misterio',
        isSeries: true,
        quality: 'HD · Latino',
      );

      await taste.recordPlaybackSession(
        item: scifiDone,
        watchedSec: 7000,
        durationSec: 7200,
        audioLang: 'Servidor 1 · Latino HD',
        now: now,
      );
      await taste.recordPlaybackSession(
        item: scifiSeries,
        watchedSec: 2500,
        durationSec: 3000,
        audioLang: 'Servidor 1 · Latino',
        now: now,
      );
      // Abandono rápido: vio 120 s (2 min) de una peli de 90 min (<12% y <5 min)
      await taste.recordPlaybackSession(
        item: horrorAbandoned,
        watchedSec: 120,
        durationSec: 5400,
        audioLang: 'Subtitulado',
        now: now,
      );
      await taste.recordSearch('interstellar ciencia ficcion', now: now);

      final summary = taste.computeSummary(now: now);
      expect(summary.topGenres(3).first.key, 'ciencia_ficcion');
      expect(summary.preferredAudio, 'latino');
      expect(summary.startedSessions, 3);
      expect(summary.completedSessions, 2);
      expect(summary.abandonedSessions, 1);
      expect(summary.completionRate, closeTo(0.667, 0.01));
      expect(summary.peakHour, 22);
      expect(summary.timeBuckets['noche'], greaterThan(0.5));

      expect(taste.isCompleted(scifiDone), isTrue);
      expect(taste.isRecentlyAbandoned(horrorAbandoned, now: now), isTrue);
      expect(taste.shouldExcludeFromDiscovery(scifiDone), isTrue);
      expect(
        taste.shouldExcludeFromDiscovery(horrorAbandoned, now: now),
        isTrue,
      );

      final candidateScifi = _vod(
        'm_scifi_new',
        'Interstellar 2',
        genre: 'Ciencia Ficción',
        quality: 'HD · Latino',
      );
      final candidateHorror = _vod(
        'm_horror_new',
        'Otro Terror',
        genre: 'Terror',
        quality: 'HD · Subtitulado',
      );
      expect(
        taste.scoreItem(candidateScifi, now: now),
        greaterThan(taste.scoreItem(candidateHorror, now: now)),
      );
    });
  });

  group('Pilar 2 — Novedades, Hero y Home 100% dinámicos', () {
    test(
        're-rankea Novedades y Hero según perfil, excluye terminados/abandonados, adapta orden de rieles y rota sin repetir',
        () async {
      final taste = TvTasteProfileService.instance;
      final now = DateTime.now();

      final finishedMovie = _vod('m_done', 'Peli Ya Vista', genre: 'Comedia');
      final abandonedSeries = _vod(
        's_bad',
        'Serie Abandonada',
        genre: 'Terror',
        isSeries: true,
      );
      final watchedScifiSeries = _vod(
        's_anchor',
        'Dark',
        genre: 'Ciencia Ficción · Misterio',
        isSeries: true,
      );

      // Perfil fuerte: fan de Series de Ciencia Ficción
      await taste.recordPlaybackSession(
        item: watchedScifiSeries,
        watchedSec: 2800,
        durationSec: 3000,
        audioLang: 'Latino',
        now: now,
      );
      await taste.recordPlaybackSession(
        item: _vod('s_scifi_prev', 'Severance',
            genre: 'Ciencia Ficción · Suspenso', isSeries: true),
        watchedSec: 2900,
        durationSec: 3000,
        audioLang: 'Latino',
        now: now,
      );
      await taste.recordPlaybackSession(
        item: finishedMovie,
        watchedSec: 6000,
        durationSec: 6100,
        audioLang: 'Latino',
        now: now,
      );
      await taste.recordPlaybackSession(
        item: abandonedSeries,
        watchedSec: 90,
        durationSec: 3600,
        audioLang: 'Sub',
        now: now,
      );
      await WatchHistory().record(
        watchedScifiSeries,
        positionSec: 1200,
        durationSec: 3000,
        seasonNumber: 1,
        episodeNumber: 3,
      );

      final movies = [
        finishedMovie,
        _vod('m_com_1', 'Comedia Genérica', genre: 'Comedia'),
        _vod('m_scifi_new', 'Arrival', genre: 'Ciencia Ficción · Misterio'),
        _vod('m_act_1', 'Acción X', genre: 'Acción'),
        _vod('m_rom_1', 'Romance Y', genre: 'Romance'),
      ];
      final series = [
        abandonedSeries,
        _vod('s_scifi_1', 'Foundation',
            genre: 'Ciencia Ficción', isSeries: true),
        _vod('s_scifi_2', '3 Body Problem',
            genre: 'Ciencia Ficción · Misterio', isSeries: true),
        _vod('s_scifi_3', 'Westworld',
            genre: 'Ciencia Ficción · Suspenso', isSeries: true),
        _vod('s_scifi_4', 'For All Mankind',
            genre: 'Ciencia Ficción · Drama', isSeries: true),
        _vod('s_com_1', 'Sitcom Cualquiera', genre: 'Comedia', isSeries: true),
      ];
      final anime = [
        _vod('a_1', 'Steins Gate',
            genre: 'Ciencia Ficción', isSeries: true, isAnime: true),
        _vod('a_2', 'Naruto',
            genre: 'Acción · Fantasía', isSeries: true, isAnime: true),
      ];

      final xuper = XuperService();
      xuper.setCatalogForTest(
        trendingMovies: movies,
        liveMovies: movies,
        liveSeries: series,
        liveAnime: anime,
      );

      final rails = xuper.getVodCategories();
      expect(rails.containsKey('Novedades para ti'), isTrue);
      expect(rails.containsKey('Especialmente para ti'), isTrue);
      expect(rails.keys.any((k) => k.startsWith('Porque viste Dark')), isTrue);

      // En Novedades para ti NO aparecen la peli terminada ni la serie abandonada
      final novedadesIds = rails['Novedades para ti']!.map((e) => e.id).toSet();
      expect(novedadesIds.contains('m_done'), isFalse);
      expect(novedadesIds.contains('s_bad'), isFalse);

      // Como es usuario fan de Series, "Series Destacadas" sube antes de "Estrenos de Cine"
      final keys = rails.keys.toList();
      expect(
        keys.indexOf('Series Destacadas'),
        lessThan(keys.indexOf('Estrenos de Cine')),
      );

      // El Hero también excluye terminados/abandonados y prioriza Series Sci-Fi
      final hero1 = xuper.getFeaturedVod();
      expect(hero1, isNotEmpty);
      expect(hero1.map((e) => e.id), isNot(contains('m_done')));
      expect(hero1.map((e) => e.id), isNot(contains('s_bad')));
      expect(hero1.first.isSeries, isTrue);

      // Al registrar impresiones y avanzar sesión, la rotación anti-repetición cambia el orden
      taste.recordImpressions(hero1.take(3).map((e) => e.id));
      taste.bumpSession(persist: false);
      final hero2 = xuper.getFeaturedVod(seed: 777);
      expect(
        hero2.map((e) => e.id).toList(),
        isNot(equals(hero1.map((e) => e.id).toList())),
      );
    });
  });

  group('Pilar 3 — Respaldo total en la nube y restauración exacta al reinstalar',
      () {
    test(
        'sube backup v2 y tras borrar todo (reinstalación) restaura posición exacta en segundos, episodios, Mi Lista, gustos, ajustes y canales',
        () async {
      final cloudDocs = <String, Map<String, dynamic>>{};

      // Mock del relay Firestore REST (decode/encode real simplificado)
      InutilFirestoreService.instance.testClient = MockClient((req) async {
        final pathIdx = req.url.path.indexOf('/documents/');
        final docPath =
            pathIdx >= 0 ? req.url.path.substring(pathIdx + 11) : req.url.path;

        if (req.method == 'PATCH' || req.method == 'POST') {
          if (docPath.startsWith('metrics/')) {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          cloudDocs[docPath] = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(req.body, 200);
        }
        if (req.method == 'GET') {
          final stored = cloudDocs[docPath];
          if (stored == null) return http.Response('{}', 404);
          return http.Response(jsonEncode(stored), 200);
        }
        return http.Response('{}', 200);
      });

      await _seedAuth();

      // 1. Poblar estado completo del usuario ANTES de desinstalar
      final breakingBad = _vod(
        'sk_bb',
        'Breaking Bad',
        genre: 'Crimen · Drama',
        isSeries: true,
      );
      await WatchHistory().record(
        breakingBad,
        positionSec: 1427.0, // posición exacta al segundo
        durationSec: 2880.0,
        seasonNumber: 3,
        episodeNumber: 7,
        episodeTitle: 'Un minuto',
      );
      await WatchHistory().markEpisodeWatched('sk_bb', 3, 6);
      await MyListService.instance.toggle(
        _vod('cp_interstellar', 'Interstellar', genre: 'Ciencia Ficción'),
      );
      await TvTasteProfileService.instance.recordPlaybackSession(
        item: breakingBad,
        watchedSec: 2700,
        durationSec: 2880,
        audioLang: 'Latino',
      );
      await TvTasteProfileService.instance.recordSearch('better call saul');
      await AppSettingsService.instance.setPreferredAudioLang('latino');
      final nonDefaultAccent = AppAccent.values.last;
      await AppSettingsService.instance.setAccent(nonDefaultAccent);
      await AppSettingsService.instance.setSkipIntroSeconds(90);

      final sp = await SharedPreferences.getInstance();
      await sp.setStringList('inutiltv_favorite_channels', ['espn_mx', 'tudn']);
      await sp.setStringList('inutiltv_recent_channels_v1', ['espn_mx']);

      // 2. Respaldar a la nube
      final pushMsg =
          await InutilTvCloudBackupService.instance.pushNow(force: true);
      expect(pushMsg, contains('Respaldo guardado'));
      expect(cloudDocs.containsKey('users/$_uid/data/tv_backup'), isTrue);

      // 3. SIMULAR DESINSTALACIÓN Y REINSTALACIÓN LIMPIA (SharedPreferences vacío)
      SharedPreferences.setMockInitialValues({});
      TvTasteProfileService.instance.resetForTest();
      InutilTvCloudBackupService.instance.resetForTest();
      await WatchHistory().reloadFromDisk();
      await MyListService.instance.reloadFromDisk();
      await AppSettingsService.instance.load(force: true);
      await _seedAuth();

      expect(WatchHistory().items, isEmpty);
      expect(MyListService.instance.items, isEmpty);
      expect(AppSettingsService.instance.preferredAudioLang, 'auto');

      // 4. Iniciar sesión -> pullAndRestoreIfEmpty()
      final pullMsg =
          await InutilTvCloudBackupService.instance.pullAndRestoreIfEmpty();
      expect(pullMsg, contains('Respaldo restaurado'));

      // 5. Verificar restauración EXACTA punto por punto
      final restoredProgress = WatchHistory().progressFor('sk_bb');
      expect(restoredProgress, isNotNull);
      expect(restoredProgress!.positionSec, 1427.0);
      expect(restoredProgress.seasonNumber, 3);
      expect(restoredProgress.episodeNumber, 7);
      expect(restoredProgress.episodeTitle, 'Un minuto');
      expect(WatchHistory().isEpisodeWatched('sk_bb', 3, 6), isTrue);

      expect(MyListService.instance.contains('cp_interstellar'), isTrue);

      final restoredTaste = TvTasteProfileService.instance.computeSummary();
      expect(restoredTaste.preferredAudio, 'latino');
      expect(restoredTaste.genreWeights.keys, contains('crimen'));
      expect(
        TvTasteProfileService.instance.recentSearches,
        contains('better call saul'),
      );

      expect(AppSettingsService.instance.preferredAudioLang, 'latino');
      expect(AppSettingsService.instance.accent, nonDefaultAccent);
      expect(AppSettingsService.instance.skipIntroSeconds, 90);

      final spAfter = await SharedPreferences.getInstance();
      expect(
        spAfter.getStringList('inutiltv_favorite_channels'),
        containsAll(['espn_mx', 'tudn']),
      );
      expect(
        spAfter.getStringList('inutiltv_recent_channels_v1'),
        contains('espn_mx'),
      );
    });

    test('merge de historial elige siempre updatedAt más reciente y episodios hace unión',
        () {
      final merged = InutilTvCloudBackupService.mergeByIdNewestForTest(
        [
          {'id': 's1', 'positionSec': 100.0, 'updatedAt': 1000},
        ],
        [
          {'id': 's1', 'positionSec': 950.0, 'updatedAt': 2000},
          {'id': 's2', 'positionSec': 400.0, 'updatedAt': 1500},
        ],
      );
      expect(merged, hasLength(2));
      expect(merged.first['id'], 's1');
      expect(merged.first['positionSec'], 950.0);

      final mergedEps = InutilTvCloudBackupService.mergeWatchedEpisodesForTest(
        jsonEncode({'s1': ['1x1', '1x2']}),
        jsonEncode({'s1': ['1x2', '1x3'], 's2': ['1x1']}),
      );
      expect(mergedEps['s1'], ['1x1', '1x2', '1x3']);
      expect(mergedEps['s2'], ['1x1']);
    });
  });

  group('Pilar 4 — Telemetría rica diaria para relay / inutix_console', () {
    test(
        'buildRichAnalyticsSnapshot agrega géneros, ratio, top títulos, finalización y flushRichAnalytics respeta máx. 1/día',
        () async {
      final requests = <http.Request>[];
      InutilFirestoreService.instance.testClient = MockClient((req) async {
        requests.add(req);
        return http.Response(jsonEncode({'ok': true}), 200);
      });
      await _seedAuth();

      InutilTvWrappedService.instance.recordWatchDelta(
        id: 'sk_bb',
        title: 'Breaking Bad',
        category: 'Series',
        deltaSeconds: 120,
      );
      InutilTvWrappedService.instance.recordWatchDelta(
        id: 'cp_m1',
        title: 'Inception',
        category: 'Películas',
        deltaSeconds: 60,
      );
      await TvTasteProfileService.instance.recordPlaybackSession(
        item: _vod('cp_m1', 'Inception', genre: 'Ciencia Ficción · Suspenso'),
        watchedSec: 8000,
        durationSec: 8800,
        audioLang: 'Latino',
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final snap = await TvDailyUsageService.instance.buildRichAnalyticsSnapshot();
      expect(snap['source'], 'tv');
      expect((snap['topGenres'] as List), isNotEmpty);
      expect((snap['topTitles'] as List), isNotEmpty);
      expect(snap['completionRate'], 1.0);
      expect(snap['preferredAudio'], 'latino');
      final ratio = snap['formatRatio'] as Map<String, dynamic>;
      expect((ratio['series'] as num), greaterThan(ratio['movies'] as num));

      // Primera escritura diaria aceptada hacia `users/<uid>/data/tv_analytics`
      expect(await TvDailyUsageService.instance.flushRichAnalytics(), isTrue);
      expect(requests, hasLength(1));
      expect(requests.first.url.path, contains('users/$_uid/data/tv_analytics'));

      // Segunda escritura el mismo día -> no-op (cuota protegida)
      expect(await TvDailyUsageService.instance.flushRichAnalytics(), isFalse);
      expect(requests, hasLength(1));
    });
  });

  group('Teclado D-Pad de Smart TV (InutilTvKeyboard)', () {
    testWidgets('permite navegar con flechas D-Pad y escribir texto sin teclado IME roto',
        (tester) async {
      final controller = TextEditingController();
      var submitted = '';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: InutilTvKeyboard(
                controller: controller,
                mode: InutilTvKeyboardMode.search,
                autofocusFirstKey: true,
                submitLabel: 'Buscar',
                onSubmit: () => submitted = controller.text,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // En fila 0, col 0 está 'A' (en modo búsqueda arranca en mayúsculas); Select escribe 'A'
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(controller.text, 'A');

      // Derecha -> 'B', Select escribe 'B'
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(controller.text, 'AB');

      // Botón Buscar también funciona con tap directo
      await tester.tap(find.text('BUSCAR'));
      await tester.pump();
      expect(submitted, 'AB');
    });

    testWidgets(
        'en modo Google TV, pulsar OK sobre un TextField abre el modal InutilTvKeyboard y escribe con D-Pad',
        (tester) async {
      TvModeService.instance.setForTest(detectedTv: true);
      addTearDown(TvModeService.instance.resetForTest);

      final controller = TextEditingController();
      final focusNode = TvFocusable.createTextFieldFocusNode(
        controller: controller,
        tvKeyboardTitle: 'Buscar en Google TV',
        tvKeyboardMode: InutilTvKeyboardMode.search,
      );
      addTearDown(() {
        focusNode.dispose();
        controller.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                readOnly: TvModeService.instance.isTv,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Pulsar OK del control remoto de Google TV abre el teclado D-Pad propio
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('Buscar en Google TV'), findsOneWidget);

      // Escribir 'A' y luego moverse a 'B' y pulsar Select
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();

      expect(controller.text, 'AB');
    });
  });
}
