import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/firebase_config.dart';
import 'package:tubotv/services/firebase_firestore_service.dart';
import 'package:tubotv/services/inutil_wrapped_service.dart';
import 'package:tubotv/services/tv_daily_usage_service.dart';

const String _testUid = 'uid_daily_report';

/// Mismo seed que `firebase_auth_and_admin_test.dart`: licencia vigente con
/// `idToken`, sin tocar la red real.
Future<void> seedSession() async {
  final prefs = await SharedPreferences.getInstance();
  final expires = DateTime.now().add(const Duration(days: 30));
  final user = <String, dynamic>{
    'uid': _testUid,
    'email': 'daily@inutil.com',
    'displayName': 'daily',
    'role': 'user',
    'status': 'active',
    'isActive': true,
    'accountExpiresAt': expires.toIso8601String(),
    'currentTvDeviceId': '',
    'currentPhoneDeviceId': '',
  };
  await prefs.setString('inutil_tv_auth_user_v3', jsonEncode(user));
  await prefs.setString(
    'inutil_tv_auth_session_v3',
    jsonEncode({
      'uid': _testUid,
      'email': 'daily@inutil.com',
      'idToken': 'test-token',
      'refreshToken': 'test-refresh',
    }),
  );
  await prefs.setString(
    'inutil_tv_last_validated_v3',
    DateTime.now().toIso8601String(),
  );
  await InutilAuthService.instance.initialize();
}

/// Clave del día calendario UTC (`YYYYMMDD`), la misma convención del relay.
String utcToday() {
  final t = DateTime.now().toUtc();
  return '${t.year}${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final captured = <http.Request>[];
  int nextStatus = 200;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    InutilAuthService.testSkipOnlineValidation = true;
    FirebaseConfig.resetRelayReachability();
    captured.clear();
    nextStatus = 200;

    // El endpoint `metrics/<uid>/daily` sólo existe en el relay: se hornea el mismo
    // host que ya usa el pipeline de release para que la ruta resuelva por ahí.
    FirebaseConfig.cloudRelayHostOverrideForTest = 'api.inutix.com';

    // Fake del layer HTTP (sin red real, sin producción).
    InutilFirestoreService.instance.testClient = MockClient((req) async {
      captured.add(req);
      return http.Response(jsonEncode({'ok': true, 'uid': _testUid}), nextStatus);
    });

    await seedSession();
    InutilTvWrappedService.instance.resetDailyCountersForTest();
    TvDailyUsageService.instance.resetForTest();
  });

  tearDown(() async {
    InutilFirestoreService.instance.testClient = null;
    FirebaseConfig.resetRelayReachability();
    // `signOut` primero, con la bandera todavía en `true`: así no intenta tocar la
    // red (ni Google Sign-In) al limpiar el singleton.
    await InutilAuthService.instance.signOut();
    InutilAuthService.testSkipOnlineValidation = false;
    InutilTvWrappedService.instance.resetDailyCountersForTest();
    TvDailyUsageService.instance.resetForTest();
  });

  /// Alimenta la contabilidad por la API real del store: 120 + 60 + 30 s en dos
  /// títulos distintos y una apertura. Total: 210 s = 3.5 min, 2 sesiones, 1 apertura.
  Future<void> feedCounters() async {
    InutilTvWrappedService.instance.recordWatchDelta(
      id: 'p1',
      title: 'P1',
      category: 'Películas',
      deltaSeconds: 120,
    );
    InutilTvWrappedService.instance.recordWatchDelta(
      id: 'p2',
      title: 'P2',
      category: 'Series',
      deltaSeconds: 60,
    );
    InutilTvWrappedService.instance.recordWatchDelta(
      id: 'p1',
      title: 'P1',
      category: 'Películas',
      deltaSeconds: 30,
    );
    InutilTvWrappedService.instance.noteAppOpen();
    // La contabilidad se persiste sola (fire-and-forget); se da tiempo a la cadena
    // de `SharedPreferences` para que el cierre brusco del test vea el disco real.
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }

  group('v3.3.41 — Forma exacta del cuerpo y ruta del relay', () {
    test('el cuerpo trae únicamente las claves de TV y POSTea metrics/<uid>/daily',
        () async {
      await feedCounters();

      final ok = await TvDailyUsageService.instance.flush();
      expect(ok, isTrue);
      expect(captured, hasLength(1));

      final req = captured.first;
      expect(req.method, 'POST');
      // Mismo prefijo REST que la app ya usa, ahora resuelto por el relay.
      expect(req.url.host, 'api.inutix.com');
      expect(
        req.url.path,
        '/v1/projects/inutil-music-app/databases/(default)/documents'
            '/metrics/$_testUid/daily',
      );

      // Mismo token Bearer que toda escritura de Firestore de la app.
      expect(req.headers['Authorization'], 'Bearer test-token');
      expect(req.headers['Content-Type'], 'application/json');

      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'tvMinutes', 'tvSessions', 'tvOpens', 'source', 'day'});
      expect(body['source'], 'tv');
      expect(body['day'], utcToday());
      expect(body['tvMinutes'], 3.5);
      expect(body['tvSessions'], 2);
      expect(body['tvOpens'], 1);
      // No deben aparecer claves de la otra app.
      expect(body.containsKey('musicMinutes'), isFalse);
      expect(body.containsKey('musicPlays'), isFalse);
    });
  });

  group('v3.3.41 — Máximo una escritura por día', () {
    test('el segundo cierre del mismo día no escribe nada', () async {
      await feedCounters();
      expect(await TvDailyUsageService.instance.flush(), isTrue);
      expect(captured, hasLength(1));

      // Cierres extra (los hay: pause, stop del playback, background de En Vivo).
      expect(await TvDailyUsageService.instance.flush(), isFalse);
      expect(await TvDailyUsageService.instance.flush(), isFalse);
      expect(captured, hasLength(1));
    });

    test('reenviar el mismo total es idempotente: cuerpo byte a byte idéntico',
        () async {
      await feedCounters();
      expect(await TvDailyUsageService.instance.flush(), isTrue);
      expect(captured, hasLength(1));
      final first = captured.first;

      expect(await TvDailyUsageService.instance.resendLastForTest(), isTrue);
      expect(captured, hasLength(2));
      expect(captured[1].body, first.body);
      expect(captured[1].url.path, first.url.path);
      expect(captured[1].method, 'POST');
    });

    test('un reporte rechazado queda pendiente y se reintegra en el siguiente cierre',
        () async {
      await feedCounters();
      nextStatus = 500;
      expect(await TvDailyUsageService.instance.flush(), isFalse);
      expect(captured, hasLength(1));

      // La contabilidad quedó persistida en el store: el siguiente cierre (el que
      // sea, sin timers ni polls) reintentará el mismo total acumulado.
      nextStatus = 200;
      expect(await TvDailyUsageService.instance.flush(), isTrue);
      expect(captured, hasLength(2));
      expect(jsonDecode(captured[1].body), jsonDecode(captured[0].body));
    });
  });

  group('v3.3.41 — Totales diarios calculados desde los contadores', () {
    test('el store reporta el acumulado del día en minutos, no en deltas', () async {
      await feedCounters();

      final totals = await InutilTvWrappedService.instance.dailyTotalsUtc();
      expect(totals.keys, [utcToday()]);
      expect(totals[utcToday()]!.minutes, 3.5);
      expect(totals[utcToday()]!.sessions, 2);
      expect(totals[utcToday()]!.opens, 1);
    });

    test('la contabilidad sobrevive a un cierre brusco de Android TV', () async {
      await feedCounters();

      // Reinicio: se borra la memoria, queda sólo lo que el store dejó en disco.
      InutilTvWrappedService.instance.resetDailyCountersForTest();
      TvDailyUsageService.instance.resetForTest();

      final totals = await InutilTvWrappedService.instance.dailyTotalsUtc();
      expect(totals[utcToday()]!.minutes, 3.5);
      expect(totals[utcToday()]!.sessions, 2);
      expect(totals[utcToday()]!.opens, 1);

      // Y el reporte sale intacto por esa contabilidad recuperada.
      expect(await TvDailyUsageService.instance.flush(), isTrue);
      expect(captured, hasLength(1));
      expect(captured.first.method, 'POST');
      expect(captured.first.url.path, contains('/metrics/$_testUid/daily'));
      final body = jsonDecode(captured.first.body) as Map<String, dynamic>;
      expect(body['tvMinutes'], 3.5);
      expect(body['tvSessions'], 2);
      expect(body['tvOpens'], 1);
      expect(body['source'], 'tv');
    });

    test('la regla de un solo envío por día se aplica día por día', () async {
      final totals = <String, TvDailyTotals>{
        '20261122': const TvDailyTotals(minutes: 10, sessions: 3, opens: 2),
        '20261123': const TvDailyTotals(minutes: 20, sessions: 4, opens: 1),
        '20261124': const TvDailyTotals(minutes: 5, sessions: 1, opens: 1),
      };
      final sent = {'20261122', '20261123'};
      expect(TvDailyUsageService.pendingDaysForTest(totals, sent), ['20261124']);

      // Un día vacío no se manda (no hay nada que reportar).
      final withEmpty = <String, TvDailyTotals>{
        '20261122': const TvDailyTotals(minutes: 0, sessions: 0, opens: 0),
        '20261123': const TvDailyTotals(minutes: 7.5, sessions: 2, opens: 1),
      };
      expect(TvDailyUsageService.pendingDaysForTest(withEmpty, {}), ['20261123']);
    });
  });

  group('v3.3.41 — Sin relay no hay endpoint y no se escribe en Google', () {
    test('cuando el prefijo resuelve directo a Google el reporte se deja pendiente',
        () async {
      await feedCounters();

      // `FB_RELAY_HOST` vacío y `cloudRelayHost` vacío: los builds que corren
      // fuera de la LAN resuelven contra Google, donde la ruta no existe.
      FirebaseConfig.cloudRelayHostOverrideForTest = '';

      expect(FirebaseConfig.dailyReportEndpointIsRelay, isFalse);
      expect(await TvDailyUsageService.instance.flush(), isFalse);
      expect(captured, isEmpty);

      // Y no se pierde: en el cierre en que el relay vuelva a estar vivo sale.
      FirebaseConfig.cloudRelayHostOverrideForTest = 'api.inutix.com';
      expect(await TvDailyUsageService.instance.flush(), isTrue);
      expect(captured, hasLength(1));
      expect(captured.first.url.host, 'api.inutix.com');
      expect(captured.first.url.path, contains('/metrics/$_testUid/daily'));
    });
  });
}
