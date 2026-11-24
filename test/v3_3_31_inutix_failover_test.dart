import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tubotv/services/firebase_config.dart';
import 'package:tubotv/services/firebase_firestore_service.dart';

void main() {
  setUp(() {
    FirebaseConfig.resetRelayReachability();
  });

  tearDown(() {
    FirebaseConfig.resetRelayReachability();
  });

  group('v3.3.31 — Cero URLs hardcodeadas a firestore.googleapis.com', () {
    test('inutil_promo_popup_service y network_config_service usan FirebaseConfig.firestoreBaseUrl', () {
      final promoSrc =
          File('lib/services/inutil_promo_popup_service.dart').readAsStringSync();
      final netSrc =
          File('lib/services/network_config_service.dart').readAsStringSync();

      expect(promoSrc, isNot(contains('firestore.googleapis.com')));
      expect(promoSrc, contains('FirebaseConfig.firestoreBaseUrl'));
      expect(netSrc, isNot(contains('firestore.googleapis.com')));
      expect(netSrc, contains('FirebaseConfig.firestoreBaseUrl'));
    });

    test('publish_release.sh sincroniza api.inutix.com e invalida backup.inutix.com', () {
      final script = File('tool/publish_release.sh').readAsStringSync();
      expect(script, contains('https://api.inutix.com'));
      expect(script, contains('https://backup.inutix.com'));
      expect(script, contains('X-Admin-Secret'));
      expect(script, contains('/admin/invalidate'));
    });
  });

  group('v3.3.31 — Failover automático LAN → api.inutix.com → backup.inutix.com', () {
    test('clasifica 502/503/521/522/524/530 como túnel caído y otros códigos no', () {
      for (final code in [502, 503, 521, 522, 524, 530]) {
        expect(InutilFirestoreService.isTunnelUnavailableStatus(code), isTrue,
            reason: 'HTTP $code debe activar failover');
      }
      for (final code in [200, 400, 401, 403, 404, 429, 500]) {
        expect(InutilFirestoreService.isTunnelUnavailableStatus(code), isFalse,
            reason: 'HTTP $code no debe activar failover');
      }
    });

    test('LAN SocketException → api.inutix.com HTTP 530 → backup.inutix.com HTTP 200',
        () async {
      FirebaseConfig.relayHostOverrideForTest = '192.168.100.27';
      FirebaseConfig.cloudRelayHostOverrideForTest = 'api.inutix.com';
      FirebaseConfig.backupRelayHostOverrideForTest = 'backup.inutix.com';
      FirebaseConfig.setRelayReachableForTest(true);

      final visitedHosts = <String>[];
      final resp = await InutilFirestoreService.instance.sendWithRelayFallback(
        label: 'GET app_config/tv_release',
        urlBuilder: () =>
            Uri.parse('${FirebaseConfig.firestoreBaseUrl}/app_config/tv_release'),
        send: (url) async {
          visitedHosts.add(url.host);
          if (url.host == '192.168.100.27') {
            throw const SocketException('Connection refused');
          }
          if (url.host == 'api.inutix.com') {
            return http.Response('Cloudflare Tunnel error', 530);
          }
          return http.Response('{"fields":{}}', 200);
        },
      );

      expect(resp.statusCode, 200);
      expect(visitedHosts, ['192.168.100.27', 'api.inutix.com', 'backup.inutix.com']);
      expect(FirebaseConfig.relayUsable, isFalse);
      expect(FirebaseConfig.cloudRelayUsable, isFalse);
      expect(FirebaseConfig.firestoreBaseUrl, contains('https://backup.inutix.com/'));
    });

    test('api.inutix.com TimeoutException → backup.inutix.com HTTP 200', () async {
      FirebaseConfig.cloudRelayHostOverrideForTest = 'api.inutix.com';
      FirebaseConfig.backupRelayHostOverrideForTest = 'backup.inutix.com';
      FirebaseConfig.setRelayReachableForTest(false);

      final visitedHosts = <String>[];
      final resp = await InutilFirestoreService.instance.sendWithRelayFallback(
        label: 'GET users/abc',
        urlBuilder: () =>
            Uri.parse('${FirebaseConfig.firestoreBaseUrl}/users/abc'),
        send: (url) async {
          visitedHosts.add(url.host);
          if (url.host == 'api.inutix.com') {
            throw TimeoutException('timeout');
          }
          return http.Response('{"fields":{}}', 200);
        },
      );

      expect(resp.statusCode, 200);
      expect(visitedHosts, ['api.inutix.com', 'backup.inutix.com']);
      expect(FirebaseConfig.cloudRelayUsable, isFalse);
    });

    test('api.inutix.com HTTP 403/404 NO marca cloudRelay como caído ni reintenta',
        () async {
      FirebaseConfig.cloudRelayHostOverrideForTest = 'api.inutix.com';
      FirebaseConfig.backupRelayHostOverrideForTest = 'backup.inutix.com';
      FirebaseConfig.setRelayReachableForTest(false);

      final visitedHosts = <String>[];
      final resp = await InutilFirestoreService.instance.sendWithRelayFallback(
        label: 'GET users/forbidden',
        urlBuilder: () =>
            Uri.parse('${FirebaseConfig.firestoreBaseUrl}/users/forbidden'),
        send: (url) async {
          visitedHosts.add(url.host);
          return http.Response('Forbidden', 403);
        },
      );

      expect(resp.statusCode, 403);
      expect(visitedHosts, ['api.inutix.com']);
      expect(FirebaseConfig.cloudRelayUsable, isTrue);
    });
  });
}
