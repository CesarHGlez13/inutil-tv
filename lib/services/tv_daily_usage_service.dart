import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_service.dart';
import 'firebase_config.dart';
import 'firebase_firestore_service.dart';
import 'inutil_wrapped_service.dart';

/// Reporte diario de telemetría de Inutix TV al relay
/// (`POST {BASE}/metrics/<uid>/daily`).
///
/// Contrato ya verificado en el relay (`inutil_relay` 8eddb17): el cuerpo trae
/// únicamente las claves de esta app (`tvMinutes`, `tvSessions`, `tvOpens`) y
/// `source: "tv"`, todas opcionales, y es el TOTAL ACUMULADO del día calendario
/// UTC, no un delta, porque el relay hace merge por columna (el último valor del
/// día gana) y reenviar el mismo total es idempotente. `day` (`YYYYMMDD`) se manda
/// explícito para que un cierre tarde no se le atribuya al día equivocado.
///
/// Máximo UNA escritura por día por app: se dispara en los momentos de cierre que
/// ya existían (pause / background del reproductor / stop del último playback) y no
/// se le agregaron timers ni polls. La contabilidad vive en el store
/// (`InutilTvWrappedService`), persistida, así que si la escritura falla el reporte
/// queda pendiente y se reintenta en el siguiente cierre: es el mismo patrón de
/// cola/offline que la app ya traía, no una cola nueva.
///
/// El endpoint sólo existe en el relay. Cuando el prefijo REST resuelve contra
/// Google directo no hay ruta y la telemetría NO se escribe: se deja pendiente para
/// el cierre en que el relay vuelva a estar vivo.
class TvDailyUsageService {
  TvDailyUsageService._();
  static final TvDailyUsageService instance = TvDailyUsageService._();

  /// Días (por uid) de los que ya se logró una escritura. Es la marca que hace
  /// cumplir la regla de una escritura por día; se persiste para sobrevivir a los
  /// cierres brusos de Android TV.
  static const _sentKey = 'inutiltv_daily_report_sent_v1';

  final Map<String, Set<String>> _sentDays = {};
  bool _loadingSent = false;
  bool _flushing = false;

  /// Último reporte que se armó (día + cuerpo exacto), para poder reenviarlo tal
  /// cual. El relay hace merge por columna, así que reenviar el mismo total deja
  /// exactamente el mismo renglón: es lo que hace idempotente al pipeline.
  String? _lastDay;
  Map<String, dynamic>? _lastBody;

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
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_sentKey);
      final all = <String, dynamic>{};
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            all[k.toString()] = v;
          });
        }
      }
      for (final entry in _sentDays.entries) {
        all[entry.key] = entry.value.toList();
      }
      await sp.setString(_sentKey, jsonEncode(all));
    } catch (e) {
      debugPrint('[TvDailyUsage] Persist sent err: $e');
    }
  }

  /// Reinicia el estado en memoria (pruebas). El marker de enviado se deja en el
  /// disco que controla la prueba y el cliente HTTP se inyecta directamente en
  /// `InutilFirestoreService.instance.testClient`.
  @visibleForTesting
  void resetForTest() {
    _sentDays.clear();
    _flushing = false;
    _loadingSent = false;
    _lastDay = null;
    _lastBody = null;
  }
}
