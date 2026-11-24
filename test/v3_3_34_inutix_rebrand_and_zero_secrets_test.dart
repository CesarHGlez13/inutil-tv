import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/title_logo_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TitleLogoService.instance.clearMemoryCache();
    TitleLogoService.instance.testClient = null;
  });

  tearDown(() {
    TitleLogoService.instance.clearMemoryCache();
    TitleLogoService.instance.testClient = null;
  });

  group('v3.3.34 — Cero llaves de terceros en el cliente y rebrand Inutix TV', () {
    test('TitleLogoService ya no contiene llaves de TMDB ni Fanart.tv en código fuente', () {
      final src =
          File('lib/services/title_logo_service.dart').readAsStringSync();
      expect(src, isNot(contains('tmdbApiKey')));
      expect(src, isNot(contains('tmdbReadAccessToken')));
      expect(src, isNot(contains('fanartApiKey')));
      expect(src, isNot(contains('62a51d0e8a768b445ff8e3fda7c3721e')));
      expect(src, isNot(contains('06c9206b4acb54a9a33158bc7ff4db7c')));
      expect(src, isNot(contains('api.themoviedb.org')));
      expect(src, isNot(contains('webservice.fanart.tv')));
    });

    test('fallo transitorio de meta.inutix.com no envenena caché negativa en disco', () async {
      var calls = 0;
      TitleLogoService.instance.testClient = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response('edge_down', 503);
        }
        return http.Response(
          jsonEncode({
            'ok': true,
            'logo': 'https://image.tmdb.org/t/p/w500/recovered_logo.png',
            'source': 'tmdb',
          }),
          200,
        );
      });

      const item = VodItem(
        id: 'cp_s_99999',
        title: 'Test Recovery',
        isSeries: true,
      );

      expect(await TitleLogoService.instance.getLogoUrl(item), isNull);
      expect(
        await TitleLogoService.instance.getLogoUrl(item),
        'https://image.tmdb.org/t/p/w500/recovered_logo.png',
      );
      expect(calls, 2);
    });

    test('identidad oficial actualizada a Inutix TV en AppInfo, Manifest y assets', () {
      expect(AppInfo.appName, 'Inutix TV');
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:label="Inutix TV"'));
      expect(File('assets/logo.png').lengthSync(), greaterThan(5000));
      expect(
        File('android/app/src/main/res/drawable-xhdpi/tv_banner.png')
            .lengthSync(),
        greaterThan(5000),
      );
      expect(
        File('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png')
            .lengthSync(),
        greaterThan(2000),
      );
    });

    test('tool/firebase_admin.py ya no hardcodea /home/cesar ni IP local 192.168.100.23', () {
      final adminSrc = File('tool/firebase_admin.py').readAsStringSync();
      expect(adminSrc, isNot(contains('/home/cesar/')));
      expect(adminSrc, isNot(contains('192.168.100.23')));
    });
  });
}
