import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_config.dart';
import 'firebase_firestore_service.dart';
import 'inutil_wrapped_service.dart';
import 'my_list_service.dart';
import 'tv_taste_profile_service.dart';
import 'watch_history.dart';

/// Reporte diario de telemetría de Inutix TV al relay
/// (`POST {BASE}/metrics/<uid>/daily`) + resumen agregado de uso y gustos
/// (`users/{uid}/data/tv_analytics`, máx. 1 escritura/día en S7 autoritativo).
///
/// Contrato del endpoint `/metrics/<uid>/daily`:
/// - El cuerpo trae únicamente las claves de esta app (`tvMinutes`, `tvSessions`,
///   `tvOpens`, `source: "tv"`, `day: "YYYYMMDD"`) como TOTAL ACUMULADO del día
///   calendario UTC (idempotente, merge por columna en `daily_usage`).
/// - Máximo UNA escritura por día por app.
///
/// Telemetría rica (`flushRichAnalytics`):
/// - Publica en `users/{uid}/data/tv_analytics` (sólo contra relay, máx. 1/día)
///   métricas agregadas limpias para `inutix_console`: tiempo visto por día,
///   top géneros, proporción películas/series/anime/TV, top títulos, tasa de
///   finalización vs abandono, audio preferido y horarios habituales.
class TvDailyUsageService {
  TvDailyUsageService._();
  static final TvDailyUsageService instance = TvDailyUsageService._();

  /// Días (por uid) de los que ya se logró una escritura en `/metrics/<uid>/daily`.
  static const _sentKey = 'inutiltv_daily_report_sent_v1';

  /// Días (por uid) de los que ya se publicó `users/{uid}/data/tv_analytics`.
  static const _richSentKey = 'inutiltv_rich_analytics_sent_v1';

  final Map<String, Set<String>> _sentDays = {};
  final Map<String, Set<String>> _richSentDays = {};
  bool _loadingSent = false;
  bool _loadingRichSent = false;
  bool _flushing = false;
  bool _flushingRich = false;

  /// Último reporte que se armó (día + cuerpo exacto), para poder reenviarlo tal
  /// cual. El relay hace merge por columna, así que reenviar el mismo total deja
  /// exactamente el mismo renglón: es lo que hace idempotente al pipeline.
  String? _lastDay;
  Map<String, dynamic>? _lastBody;
  Map<String, dynamic>? _lastRichSnapshot;

  /// Reenvía el último reporte sin respetar la marca de «ya enviado», que es lo que
  /// haría un reintento tras un cierre incierto. Expuesto sólo para pruebas.
  @visibleForTesting
  Future<bool> resendLastForTest() async {
    final user = InutilAuthService.instance.currentUser;
    if (user == null || _lastBody == null || _lastDay == null) return false;
    if (!FirebaseConfig.dailyReportEndpointIsRelay) return false;
    final resp = await InutilFirestoreService.instance.postDailyMetrics(
      uid: user.uid,
      body: _lastBody!,
    );
    return resp.statusCode >= 200 && resp.statusCode < 300;
  }

  @visibleForTesting
  Map<String, dynamic>? get lastRichSnapshotForTest => _lastRichSnapshot;

  /// Refuerza la contabilidad diaria: la lleva el store, aquí sólo se delega para
  /// que el gate de sesión tenga un punto único de entrada.
  void noteAppOpen() => InutilTvWrappedService.instance.noteAppOpen();

  /// Cierra el día: manda el acumulado del día más viejo pendiente, uno solo por
  /// cierre. Devuelve `true` sólo si el relay aceptó la escritura.
  Future<bool> flush() async {
    if (_flushing) return false;
    final user = InutilAuthService.instance.currentUser;
    if (user == null || user.idToken.isEmpty) return false;
    if (!InutilAuthService.instance.isAccessAllowed) return false;

    // Sin relay no hay endpoint: contra Google la ruta `metrics/<uid>/daily` no
    // existe, así que aquí no se inventa una escritura nueva.
    if (!FirebaseConfig.dailyReportEndpointIsRelay) return false;

    _flushing = true;
    try {
      final uid = user.uid;
      final totals = await InutilTvWrappedService.instance.dailyTotalsUtc();
      final sent = await _loadSentDays(uid);
      final pending = _pendingDays(totals, sent);
      if (pending.isEmpty) return false;

      final day = pending.first;
      final totalsDay = totals[day]!;
      if (totalsDay.isEmpty) return false;

      final body = <String, dynamic>{
        'tvMinutes': totalsDay.minutes,
        'tvSessions': totalsDay.sessions,
        'tvOpens': totalsDay.opens,
        'source': 'tv',
        'day': day,
      };
      _lastDay = day;
      _lastBody = body;

      final resp = await InutilFirestoreService.instance.postDailyMetrics(
        uid: uid,
        body: body,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint(
          '[TvDailyUsage] Reporte no aceptado (${resp.statusCode}): '
          '${InutilFirestoreService.briefErrorBody(resp.body)}',
        );
        return false;
      }

      sent.add(day);
      _sentDays[uid] = sent;
      await _persistSentDays(uid);
      debugPrint('[TvDailyUsage] Reporte aceptado: $day $body');
      return true;
    } catch (e) {
      debugPrint('[TvDailyUsage] Reporte err: $e');
      return false;
    } finally {
      _flushing = false;
    }
  }

  /// Construye un snapshot limpio y agregado de uso y gustos compatible con
  /// `inutil_relay` / `inutix_console`.
  Future<Map<String, dynamic>> buildRichAnalyticsSnapshot({
    DateTime? nowUtc,
  }) async {
    await Future.wait([
      TvTasteProfileService.instance.load(),
      WatchHistory().load(),
      MyListService.instance.load(),
    ]);

    final utc = (nowUtc ?? DateTime.now().toUtc());
    final todayKey = _utcDayKey(utc);
    final dailyTotals = await InutilTvWrappedService.instance.dailyTotalsUtc();
    final today = dailyTotals[todayKey] ??
        const TvDailyTotals(minutes: 0, sessions: 0, opens: 0);
    final wrapped = await InutilTvWrappedService.instance.buildSummary();
    final taste = TvTasteProfileService.instance.computeSummary();

    // Calcular proporción real combinando tiempo visto (Wrapped) + perfil de gustos
    final catSec = wrapped.categorySeconds;
    final totalCatSec = catSec.values.fold<int>(0, (a, b) => a + b);
    Map<String, double> formatRatio;
    if (totalCatSec > 0) {
      double pct(String key) => double.parse(
            ((catSec[key] ?? 0) / totalCatSec).toStringAsFixed(3),
          );
      formatRatio = {
        'movies': pct('Películas'),
        'series': pct('Series'),
        'anime': pct('Anime'),
        'liveTv': pct('TV en Vivo'),
      };
    } else {
      formatRatio = {
        'movies': taste.formatRatio['movie'] ?? 0.34,
        'series': taste.formatRatio['series'] ?? 0.33,
        'anime': taste.formatRatio['anime'] ?? 0.33,
        'liveTv': 0.0,
      };
    }

    final topGenres = [
      for (final entry in taste.topGenres(8))
        <String, dynamic>{
          'id': entry.key,
          'label': TvTasteProfileService.labelForGenre(entry.key),
          'weight': entry.value,
        },
    ];

    final topTitles = [
      for (final t in wrapped.topTitles.take(10))
        <String, dynamic>{
          'id': t.id,
          'title': t.title,
          'category': t.category,
          'plays': t.plays,
          'seconds': t.seconds,
        },
    ];

    final dailyHistory = [
      for (final e in dailyTotals.entries)
        <String, dynamic>{
          'day': e.key,
          'minutes': e.value.minutes,
          'sessions': e.value.sessions,
          'opens': e.value.opens,
        },
    ];

    final configuredAudio = AppSettingsService.instance.preferredAudioLang;
    final preferredAudio = configuredAudio != 'auto'
        ? configuredAudio
        : taste.preferredAudio;

    return <String, dynamic>{
      'schemaVersion': 1,
      'source': 'tv',
      'day': todayKey,
      'updatedAt': utc.toIso8601String(),
      'today': <String, dynamic>{
        'minutes': today.minutes,
        'sessions': today.sessions,
        'opens': today.opens,
      },
      'dailyHistory7d': dailyHistory,
      'totalMinutesYear': wrapped.totalMinutes,
      'totalSessionsYear': wrapped.totalSessions,
      'activeDaysYear': wrapped.activeDaysCount,
      'topGenres': topGenres,
      'formatRatio': formatRatio,
      'topTitles': topTitles,
      'completionRate': taste.completionRate,
      'abandonedRate': taste.abandonedRate,
      'startedSessions': taste.startedSessions,
      'completedSessions': taste.completedSessions,
      'abandonedSessions': taste.abandonedSessions,
      'preferredAudio': preferredAudio,
      'peakHour': taste.hasSignals ? taste.peakHour : wrapped.peakHour,
      'timeBuckets': taste.timeBuckets,
      'library': <String, dynamic>{
        'myListCount': MyListService.instance.items.length,
        'watchHistoryCount': WatchHistory().items.length,
      },
    };
  }

  /// Publica el resumen agregado de uso y gustos en `users/{uid}/data/tv_analytics`
  /// (máximo 1 escritura por día UTC, sólo cuando el destino es el relay S7).
  Future<bool> flushRichAnalytics({bool force = false}) async {
    if (_flushingRich) return false;
    final user = InutilAuthService.instance.currentUser;
    if (user == null || user.idToken.isEmpty) return false;
    if (!InutilAuthService.instance.isAccessAllowed) return false;
    if (!FirebaseConfig.dailyReportEndpointIsRelay) return false;

    _flushingRich = true;
    try {
      final uid = user.uid;
      final todayKey = _utcDayKey(DateTime.now().toUtc());
      final sent = await _loadRichSentDays(uid);
      if (!force && sent.contains(todayKey)) return false;

      final snapshot = await buildRichAnalyticsSnapshot();
      final todayMap = snapshot['today'] as Map<String, dynamic>;
      final hasToday = ((todayMap['minutes'] as num?)?.toDouble() ?? 0) > 0 ||
          ((todayMap['sessions'] as num?)?.toInt() ?? 0) > 0;
      final hasTaste = (snapshot['topGenres'] as List).isNotEmpty ||
          (snapshot['topTitles'] as List).isNotEmpty;
      if (!force && !hasToday && !hasTaste) return false;

      _lastRichSnapshot = snapshot;
      final ok = await InutilFirestoreService.instance.setDocument(
        'users/$uid/data/tv_analytics',
        snapshot,
      );
      if (!ok) return false;

      sent.add(todayKey);
      _richSentDays[uid] = sent;
      await _persistRichSentDays(uid);
      return true;
    } catch (e) {
      debugPrint('[TvDailyUsage] Rich analytics err: $e');
      return false;
    } finally {
      _flushingRich = false;
    }
  }

  /// Días con contabilidad que aún no se han mandado, del más viejo al más nuevo.
  /// Es la regla de una escritura por día: un día ya enviado no vuelve a escribirse.
  static List<String> _pendingDays(
    Map<String, TvDailyTotals> totals,
    Set<String> sentDays,
  ) {
    final keys = totals.keys.toList()..sort();
    return keys
        .where((d) => !sentDays.contains(d) && !totals[d]!.isEmpty)
        .toList();
  }

  static String _utcDayKey(DateTime utc) {
    final t = utc.isUtc ? utc : utc.toUtc();
    return '${t.year}${t.month.toString().padLeft(2, '0')}'
        '${t.day.toString().padLeft(2, '0')}';
  }

  /// Misma ayuda, expuesta para pruebas.
  @visibleForTesting
  static List<String> pendingDaysForTest(
    Map<String, TvDailyTotals> totals,
    Set<String> sentDays,
  ) =>
      _pendingDays(totals, sentDays);

  Future<Set<String>> _loadSentDays(String uid) async {
    if (_loadingSent) return _sentDays[uid] ?? {};
    _loadingSent = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_sentKey);
      if (raw == null || raw.isEmpty) return _sentDays[uid] ?? {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return _sentDays[uid] ?? {};
      final stored = decoded[uid];
      if (stored is! List) return _sentDays[uid] ?? {};
      return _sentDays[uid] = stored.map((e) => e.toString()).toSet();
    } catch (e) {
      debugPrint('[TvDailyUsage] Load sent err: $e');
      return _sentDays[uid] ?? {};
    } finally {
      _loadingSent = false;
    }
  }

  Future<void> _persistSentDays(String uid) async {
    await _persistDayMap(_sentKey, _sentDays);
  }

  Future<Set<String>> _loadRichSentDays(String uid) async {
    if (_loadingRichSent) return _richSentDays[uid] ?? {};
    _loadingRichSent = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_richSentKey);
      if (raw == null || raw.isEmpty) return _richSentDays[uid] ?? {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return _richSentDays[uid] ?? {};
      final stored = decoded[uid];
      if (stored is! List) return _richSentDays[uid] ?? {};
      return _richSentDays[uid] = stored.map((e) => e.toString()).toSet();
    } catch (e) {
      debugPrint('[TvDailyUsage] Load rich sent err: $e');
      return _richSentDays[uid] ?? {};
    } finally {
      _loadingRichSent = false;
    }
  }

  Future<void> _persistRichSentDays(String uid) async {
    await _persistDayMap(_richSentKey, _richSentDays);
  }

  static Future<void> _persistDayMap(
    String key,
    Map<String, Set<String>> source,
  ) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(key);
      final all = <String, dynamic>{};
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            all[k.toString()] = v;
          });
        }
      }
      for (final entry in source.entries) {
        all[entry.key] = entry.value.toList();
      }
      await sp.setString(key, jsonEncode(all));
    } catch (e) {
      debugPrint('[TvDailyUsage] Persist err: $e');
    }
  }

  /// Reinicia el estado en memoria (pruebas). El marker de enviado se deja en el
  /// disco que controla la prueba y el cliente HTTP se inyecta directamente en
  /// `InutilFirestoreService.instance.testClient`.
  @visibleForTesting
  void resetForTest() {
    _sentDays.clear();
    _richSentDays.clear();
    _flushing = false;
    _flushingRich = false;
    _loadingSent = false;
    _loadingRichSent = false;
    _lastDay = null;
    _lastBody = null;
    _lastRichSnapshot = null;
  }
}
