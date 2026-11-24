import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/inutil_update_service.dart';
import 'package:tubotv/services/jkanime_service.dart';
import 'package:tubotv/services/remote_providers_config.dart';
import 'package:tubotv/services/serieskao_service.dart';
import 'package:tubotv/services/tioanime_service.dart';
import 'package:tubotv/services/title_logo_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RemoteProvidersConfig.instance.resetToDefaults();
    TitleLogoService.instance.clearMemoryCache();
    TitleLogoService.instance.testClient = null;
  });

  tearDown(() {
    RemoteProvidersConfig.instance.resetToDefaults();
    TitleLogoService.instance.clearMemoryCache();
    TitleLogoService.instance.testClient = null;
  });

  group('v3.3.33 — RemoteProvidersConfig (app_config/providers en api.inutix.com)', () {
    test('arranca con defaults verificados de meta.inutix.com, ota.inutix.com y mirrors VOD', () {
      final cfg = RemoteProvidersConfig.instance;
      expect(cfg.metaBaseUrl, 'https://meta.inutix.com');
      expect(cfg.otaBaseUrl, 'https://ota.inutix.com');
      expect(cfg.poseidonMirrors, contains('https://www.poseidonhd2.co'));
      expect(cfg.vidHideMirrors.first, 'callistanise.com');
      expect(cfg.streamWishMirrors.first, 'swhoi.com');
      expect(SeriesKaoService.baseUrl, 'https://serieskao.top');
      expect(JkAnimeService.baseUrl, 'https://jkanime.net');
      expect(TioAnimeService.baseUrl, 'https://tioanime.com');
    });

    test('decodifica documento REST Firestore, persiste en SharedPreferences y actualiza servicios', () async {
      var networkCalls = 0;
      final mockClient = MockClient((req) async {
        networkCalls++;
        expect(req.url.path, endsWith('/app_config/providers'));
        return http.Response(
          jsonEncode({
            'fields': {
              'metaBaseUrl': {'stringValue': 'https://meta-v2.inutix.com/'},
              'otaBaseUrl': {'stringValue': 'https://ota-v2.inutix.com/'},
              'seriesKaoBaseUrl': {'stringValue': 'https://serieskao.lat/'},
              'jkAnimeBaseUrl': {'stringValue': 'https://jkanime.org/'},
              'tioAnimeBaseUrl': {'stringValue': 'https://tioanime.net/'},
              'poseidonMirrors': {
                'arrayValue': {
                  'values': [
                    {'stringValue': 'https://poseidon-new.co/'},
                    {'stringValue': 'https://cuevana-new.eu'},
                  ],
                },
              },
              'vidHideMirrors': {
                'arrayValue': {
                  'values': [
                    {'stringValue': 'https://newvidhide.com/v/123'},
                    {'stringValue': 'callistanise.com'},
                  ],
                },
              },
              'streamWishMirrors': {
                'arrayValue': {
                  'values': [
                    {'stringValue': 'newstreamwish.com'},
                  ],
                },
              },
              'updatedAt': {'stringValue': '2026-11-24T19:33:41+00:00'},
            },
          }),
          200,
        );
      });

      await RemoteProvidersConfig.instance.loadAndRefresh(
        force: true,
        client: mockClient,
      );

      final cfg = RemoteProvidersConfig.instance;
      expect(networkCalls, 1);
      expect(cfg.metaBaseUrl, 'https://meta-v2.inutix.com');
      expect(cfg.otaBaseUrl, 'https://ota-v2.inutix.com');
      expect(SeriesKaoService.baseUrl, 'https://serieskao.lat');
      expect(JkAnimeService.baseUrl, 'https://jkanime.org');
      expect(TioAnimeService.baseUrl, 'https://tioanime.net');
      expect(cfg.poseidonMirrors, [
        'https://poseidon-new.co',
        'https://cuevana-new.eu',
      ]);
      expect(cfg.vidHideMirrors, ['newvidhide.com', 'callistanise.com']);
      expect(cfg.streamWishMirrors, ['newstreamwish.com']);

      // Reiniciar en memoria y recargar desde caché persistente (0 llamadas de red dentro del TTL)
      cfg.resetToDefaults();
      expect(cfg.metaBaseUrl, 'https://meta.inutix.com');
      await cfg.loadAndRefresh(client: mockClient);
      expect(networkCalls, 1); // Sin nueva petición HTTP
      expect(cfg.metaBaseUrl, 'https://meta-v2.inutix.com');
      expect(SeriesKaoService.baseUrl, 'https://serieskao.lat');
    });

    test('ignora valores corruptos o vacíos y conserva defaults seguros', () {
      final cfg = RemoteProvidersConfig.instance;
      cfg.applyMap({
        'metaBaseUrl': 'not-a-url',
        'otaBaseUrl': '',
        'poseidonMirrors': <String>[],
        'vidHideMirrors': ['invalid host with spaces'],
      });
      expect(cfg.metaBaseUrl, 'https://meta.inutix.com');
      expect(cfg.otaBaseUrl, 'https://ota.inutix.com');
      expect(cfg.poseidonMirrors, RemoteProvidersConfig.defaultPoseidonMirrors);
      expect(cfg.vidHideMirrors, RemoteProvidersConfig.defaultVidHideMirrors);
    });
  });

  group('v3.3.33 — TitleLogoService con meta.inutix.com + fallback TMDB', () {
    test('resuelve logo vía meta.inutix.com/logo en 1 sola llamada sin tocar TMDB', () async {
      final requestedUrls = <Uri>[];
      TitleLogoService.instance.testClient = MockClient((req) async {
        requestedUrls.add(req.url);
        if (req.url.host == 'meta.inutix.com' && req.url.path == '/logo') {
          expect(req.url.queryParameters['type'], 'tv');
          expect(req.url.queryParameters['id'], '73223');
          return http.Response(
            jsonEncode({
              'ok': true,
              'logo': 'https://image.tmdb.org/t/p/w500/edge_logo.png',
              'source': 'tmdb',
            }),
            200,
          );
        }
        fail('No debería llamar a ${req.url} cuando meta.inutix.com responde 200');
      });

      const item = VodItem(
        id: 'cp_s_73223',
        title: 'Black Clover',
        isSeries: true,
        isAnime: true,
      );

      final logo = await TitleLogoService.instance.getLogoUrl(item);
      expect(logo, 'https://image.tmdb.org/t/p/w500/edge_logo.png');
      expect(requestedUrls.length, 1);
      expect(requestedUrls.first.host, 'meta.inutix.com');
    });

    test('respeta caché negativa del Edge (source: none) sin cascadear llamadas a TMDB/Fanart', () async {
      var calls = 0;
      TitleLogoService.instance.testClient = MockClient((req) async {
        calls++;
        expect(req.url.host, 'meta.inutix.com');
        expect(req.url.queryParameters['q'], 'Pelicula Indie Sin Logo');
        return http.Response(
          jsonEncode({'ok': true, 'logo': '', 'source': 'none'}),
          200,
        );
      });

      const item = VodItem(
        id: 'custom_indie_1',
        title: 'Pelicula Indie Sin Logo (Latino)',
        isSeries: false,
      );

      final logo = await TitleLogoService.instance.getLogoUrl(item);
      expect(logo, isNull);
      expect(calls, 1);
    });
  });

  group('v3.3.33 — InutilUpdateService OTA Edge Mirror (ota.inutix.com)', () {
    test('reescribe URLs de GitHub Releases APK al proxy ota.inutix.com/download/...', () {
      const ghArm64 =
          'https://github.com/CesarHGlez13/inutil-tv/releases/download/v3.3.33/app-arm64-v8a-release.apk';
      const ghArmv7 =
          'https://github.com/CesarHGlez13/inutil-tv/releases/download/v3.3.33/app-armeabi-v7a-release.apk';

      expect(
        InutilUpdateService.otaFallbackUrlFor(ghArm64),
        'https://ota.inutix.com/download/v3.3.33/app-arm64-v8a-release.apk',
      );
      expect(
        InutilUpdateService.otaFallbackUrlFor(ghArmv7),
        'https://ota.inutix.com/download/v3.3.33/app-armeabi-v7a-release.apk',
      );
    });

    test('respeta otaBaseUrl dinámico y descarta URLs ajenas a GitHub Releases', () {
      RemoteProvidersConfig.instance.applyMap({
        'otaBaseUrl': 'https://ota-alt.inutix.com/',
      });
      expect(
        InutilUpdateService.otaFallbackUrlFor(
          'https://github.com/CesarHGlez13/inutil-tv/releases/download/v3.3.33/app-universal-release.apk',
        ),
        'https://ota-alt.inutix.com/download/v3.3.33/app-universal-release.apk',
      );
      expect(
        InutilUpdateService.otaFallbackUrlFor(
          'https://ota.inutix.com/download/v3.3.33/app-arm64-v8a-release.apk',
        ),
        isEmpty,
      );
      expect(
        InutilUpdateService.otaFallbackUrlFor('https://example.com/file.apk'),
        isEmpty,
      );
    });
  });
}
