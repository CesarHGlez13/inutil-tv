import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'stream_validator.dart';

/// Puntaje de salud por serie/título (inspirado en arquitectura Source Health Scoring).
///
/// Registra éxitos y fallos reales al resolver episodios para:
/// - Priorizar series verificadas y confiables arriba del catálogo.
/// - Filtrar o relegar automáticamente títulos caídos (0 éxitos y >= 2 fallos)
///   para evitar que el usuario pierda tiempo tocando series rotas.
class SeriesHealthService {
  SeriesHealthService._();
  static final SeriesHealthService instance = SeriesHealthService._();

  static const _prefsKey = 'inutiltv_series_health_v1';
  static const _maxTrackedEntries = 180;

  final Map<String, _HealthRecord> _records = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((k, v) {
          if (v is Map) {
            _records[k] = _HealthRecord.fromJson(v.cast<String, dynamic>());
          }
        });
      }
    } catch (_) {}
    _loaded = true;
  }

  String _keyOf(String titleOrId) {
    final norm = StreamValidator.normalizeTitle(titleOrId);
    return norm.isNotEmpty ? norm : titleOrId.trim().toLowerCase();
  }

  Future<void> recordSuccess(String titleOrId, {int latencyMs = 800}) async {
    await load();
    final key = _keyOf(titleOrId);
    final prev = _records[key];
    _records[key] = _HealthRecord(
      successes: (prev?.successes ?? 0) + 1,
      failures: prev?.failures ?? 0,
      lastLatencyMs: latencyMs,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _persist();
  }

  Future<void> recordFailure(String titleOrId) async {
    await load();
    final key = _keyOf(titleOrId);
    final prev = _records[key];
    _records[key] = _HealthRecord(
      successes: prev?.successes ?? 0,
      failures: (prev?.failures ?? 0) + 1,
      lastLatencyMs: prev?.lastLatencyMs ?? 0,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _persist();
  }

  /// Devuelve `true` si la serie tiene historial reciente de fallos repetidos
  /// sin ningún episodio reproducido con éxito en las últimas 48h.
  bool isKnownBroken(String titleOrId) {
    final rec = _records[_keyOf(titleOrId)];
    if (rec == null) return false;
    final ageHours =
        (DateTime.now().millisecondsSinceEpoch - rec.updatedAtMs) / 3600000.0;
    if (ageHours > 48) return false;
    return rec.successes == 0 && rec.failures >= 2;
  }

  /// Calcula un puntaje 0.0–1.0 para priorizar series sanas y probadas.
  double healthScore(VodItem item) {
    final rec = _records[_keyOf(item.title)];
    final providerBase = switch (item.provider) {
      'serieskao' => 0.88,
      'poseidon' => 0.80,
      'jkanime' => 0.90,
      _ => 0.65,
    };
    if (rec == null) return providerBase;
    final total = rec.successes + rec.failures;
    if (total == 0) return providerBase;
    final empirical = rec.successes / total;
    final latencyBonus =
        rec.lastLatencyMs > 0 && rec.lastLatencyMs < 1500 ? 0.08 : 0.0;
    return (providerBase * 0.4 + empirical * 0.6 + latencyBonus).clamp(0.0, 1.0);
  }

  /// Filtra series rotas conocidas y mantiene el catálogo limpio y confiable.
  List<VodItem> filterAndRankSeries(List<VodItem> items) {
    if (items.isEmpty) return items;
    final clean = items.where((it) => !isKnownBroken(it.title)).toList();
    final pool = clean.isNotEmpty ? clean : List<VodItem>.of(items);
    // Orden estable: solo promovemos/relegamos si hay historial real registrado
    pool.sort((a, b) => healthScore(b).compareTo(healthScore(a)));
    return pool;
  }

  Future<void> _persist() async {
    try {
      if (_records.length > _maxTrackedEntries) {
        final entries = _records.entries.toList()
          ..sort((a, b) => b.value.updatedAtMs.compareTo(a.value.updatedAtMs));
        _records
          ..clear()
          ..addEntries(entries.take(_maxTrackedEntries));
      }
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _prefsKey,
        jsonEncode(_records.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (_) {}
  }
}

class _HealthRecord {
  final int successes;
  final int failures;
  final int lastLatencyMs;
  final int updatedAtMs;

  const _HealthRecord({
    required this.successes,
    required this.failures,
    required this.lastLatencyMs,
    required this.updatedAtMs,
  });

  Map<String, dynamic> toJson() => {
        's': successes,
        'f': failures,
        'l': lastLatencyMs,
        'u': updatedAtMs,
      };

  factory _HealthRecord.fromJson(Map<String, dynamic> j) => _HealthRecord(
        successes: (j['s'] as num?)?.toInt() ?? 0,
        failures: (j['f'] as num?)?.toInt() ?? 0,
        lastLatencyMs: (j['l'] as num?)?.toInt() ?? 0,
        updatedAtMs: (j['u'] as num?)?.toInt() ?? 0,
      );
}
