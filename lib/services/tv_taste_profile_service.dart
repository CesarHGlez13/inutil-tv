import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'inutil_cloud_backup_service.dart';
import 'my_list_service.dart';
import 'watch_history.dart';

/// Evento ponderado de comportamiento del usuario (equivalente en TV a los
/// `playback_events` de Inutix Music).
@immutable
class TvTasteEvent {
  const TvTasteEvent({
    required this.type,
    required this.itemId,
    required this.title,
    required this.format,
    required this.genres,
    required this.timestampMs,
    this.audioLang = '',
    this.completionRatio = 0.0,
    this.watchedSec = 0,
    this.hour = 21,
  });

  /// `play_completed` | `play_partial` | `play_abandoned` |
  /// `my_list_add` | `my_list_remove` | `search` | `detail_view`
  final String type;
  final String itemId;
  final String title;

  /// `movie` | `series` | `anime` | `search`
  final String format;
  final List<String> genres;

  /// `latino` | `sub` | `espanol` | ''
  final String audioLang;
  final double completionRatio;
  final int watchedSec;
  final int hour;
  final int timestampMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': type,
        'id': itemId,
        'ti': title,
        'f': format,
        if (genres.isNotEmpty) 'g': genres,
        if (audioLang.isNotEmpty) 'a': audioLang,
        if (completionRatio > 0)
          'r': double.parse(completionRatio.clamp(0.0, 1.0).toStringAsFixed(2)),
        if (watchedSec > 0) 's': watchedSec,
        'h': hour,
        'ts': timestampMs,
      };

  factory TvTasteEvent.fromJson(Map<String, dynamic> j) => TvTasteEvent(
        type: (j['t'] ?? j['type'] ?? '').toString(),
        itemId: (j['id'] ?? j['itemId'] ?? '').toString(),
        title: (j['ti'] ?? j['title'] ?? '').toString(),
        format: (j['f'] ?? j['format'] ?? 'movie').toString(),
        genres: ((j['g'] ?? j['genres']) as List? ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(),
        audioLang: (j['a'] ?? j['audioLang'] ?? '').toString(),
        completionRatio:
            ((j['r'] ?? j['completionRatio']) as num?)?.toDouble() ?? 0.0,
        watchedSec: ((j['s'] ?? j['watchedSec']) as num?)?.toInt() ?? 0,
        hour: ((j['h'] ?? j['hour']) as num?)?.toInt().clamp(0, 23) ?? 21,
        timestampMs: ((j['ts'] ?? j['timestampMs']) as num?)?.toInt() ?? 0,
      );
}

/// Fotografía agregada del perfil de gustos del usuario.
@immutable
class TvTasteSummary {
  const TvTasteSummary({
    required this.genreWeights,
    required this.formatRatio,
    required this.preferredAudio,
    required this.audioCounts,
    required this.completionRate,
    required this.abandonedRate,
    required this.startedSessions,
    required this.completedSessions,
    required this.abandonedSessions,
    required this.timeBuckets,
    required this.peakHour,
    required this.eventCount,
  });

  /// Género canónico -> peso normalizado (0.0 a 1.0).
  final Map<String, double> genreWeights;

  /// Proporción `movie`, `series`, `anime` (suma 1.0).
  final Map<String, double> formatRatio;

  /// `latino` | `sub` | `espanol` | `auto`
  final String preferredAudio;
  final Map<String, int> audioCounts;

  final double completionRate;
  final double abandonedRate;
  final int startedSessions;
  final int completedSessions;
  final int abandonedSessions;

  /// `madrugada` | `manana` | `tarde` | `noche` -> proporción 0..1.
  final Map<String, double> timeBuckets;
  final int peakHour;
  final int eventCount;

  bool get hasSignals => eventCount > 0 || genreWeights.isNotEmpty;

  List<MapEntry<String, double>> topGenres([int limit = 6]) {
    final entries = genreWeights.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).toList();
  }

  /// Formato dominante (`movie`, `series`, `anime`).
  String get dominantFormat {
    if (formatRatio.isEmpty) return 'movie';
    final sorted = formatRatio.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }
}

/// Motor de Perfil de Gustos Local + Nube para Inutix TV.
///
/// Aprende continuamente de:
/// - Géneros reales consumidos (normalizados y libres de ruido de proveedor)
/// - Proporción películas vs series vs anime
/// - Audio/idioma preferido (latino / subtitulado / español)
/// - Tasa de finalización vs abandono rápido (<12% y <5 min)
/// - Búsquedas, «Mi Lista» y horarios habituales
/// - Historial de impresiones para rotación anti-repetición en Home/Hero
class TvTasteProfileService extends ChangeNotifier {
  TvTasteProfileService._();
  static final TvTasteProfileService instance = TvTasteProfileService._();

  static const String prefsKey = 'inutiltv_taste_profile_v1';
  static const int _schemaVersion = 1;
  static const int _maxEvents = 180;
  static const int _maxCompleted = 250;
  static const int _maxAbandoned = 120;
  static const int _maxSearches = 30;
  static const int _maxEnrichedGenres = 220;
  static const int _maxImpressions = 160;
  static const double _halfLifeDays = 30.0;
  static const int _abandonCooldownDays = 14;

  /// Etiquetas legibles de cada género canónico.
  static const Map<String, String> canonicalGenreLabels = {
    'accion': 'Acción',
    'ciencia_ficcion': 'Ciencia Ficción',
    'terror': 'Terror',
    'comedia': 'Comedia',
    'drama': 'Drama',
    'suspenso': 'Suspenso',
    'animacion': 'Animación',
    'fantasia': 'Fantasía',
    'crimen': 'Crimen',
    'aventura': 'Aventura',
    'romance': 'Romance',
    'familia': 'Familia',
    'documental': 'Documental',
    'misterio': 'Misterio',
    'belica': 'Bélica',
    'dorama': 'Dorama',
    'anime': 'Anime',
  };

  final List<TvTasteEvent> _events = [];
  final Map<String, int> _completedIds = {};
  final Map<String, int> _abandonedIds = {};
  final List<String> _recentSearches = [];
  final Map<String, List<String>> _enrichedGenres = {};
  final Map<String, int> _recentImpressions = {};
  int _sessionCounter = 1;
  bool _loaded = false;
  TvTasteSummary? _cachedSummary;

  bool get isLoaded => _loaded;
  int get sessionCounter => _sessionCounter;
  List<TvTasteEvent> get events => List.unmodifiable(_events);
  List<String> get recentSearches => List.unmodifiable(_recentSearches);
  Set<String> get completedIds => Set.unmodifiable(_completedIds.keys);

  /// Carga el perfil desde disco y, si el usuario ya tenía historial/Mi Lista
  /// antes de esta actualización, realiza un bootstrap suave sin perder nada.
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        _applyFromMap(jsonDecode(raw) as Map<String, dynamic>, overwrite: true);
      } else if (force) {
        _clearInMemory();
      }
      _sessionCounter += 1;
    } catch (e) {
      debugPrint('[TvTasteProfile] Load err: $e');
    }
    _loaded = true;
    _cachedSummary = null;

    // Bootstrap automático para usuarios existentes que actualizan por OTA
    if (_events.isEmpty) {
      await _seedFromExistingHistoryAndList();
    }
    notifyListeners();
  }

  Future<void> reloadFromDisk() => load(force: true);

  /// Avanza el contador de sesión para forzar rotación fresca en Hero/Novedades.
  void bumpSession({bool persist = true}) {
    _sessionCounter += 1;
    _cachedSummary = null;
    if (persist) _schedulePersist(triggerBackup: false);
    notifyListeners();
  }

  /// Registra el resultado de una sesión de reproducción (completada, parcial o
  /// abandono rápido). Es la señal principal del motor.
  Future<void> recordPlaybackSession({
    required VodItem item,
    required double watchedSec,
    required double durationSec,
    String audioLang = '',
    bool completed = false,
    DateTime? now,
  }) async {
    await load();
    if (item.id.isEmpty || item.title.isEmpty) return;

    final ts = (now ?? DateTime.now());
    final ratio = durationSec > 0
        ? (watchedSec / durationSec).clamp(0.0, 1.0)
        : (completed ? 1.0 : 0.0);

    // Determinar tipo de evento según tasa de finalización vs abandono rápido
    final bool isCompleted =
        completed || (durationSec > 60 && ratio >= 0.80);
    final bool isQuickAbandon = !isCompleted &&
        durationSec >= 600 && // al menos 10 min de duración real
        watchedSec >= 20 &&
        watchedSec <= 300 && // menos de 5 min vistos
        ratio < 0.12;

    // Ignorar aperturas accidentales de menos de 20 s sin finalización
    if (!isCompleted && !isQuickAbandon && watchedSec < 20) return;

    final String eventType = isCompleted
        ? 'play_completed'
        : (isQuickAbandon ? 'play_abandoned' : 'play_partial');

    final genres = resolveGenresForItem(item);
    if (genres.isNotEmpty) {
      _rememberEnrichedGenres(item.id, genres);
    }

    final normAudio = normalizeAudioLang(audioLang.isNotEmpty
        ? audioLang
        : '${item.genre} ${item.quality}');

    final event = TvTasteEvent(
      type: eventType,
      itemId: item.id,
      title: item.title,
      format: formatOf(item),
      genres: genres,
      audioLang: normAudio,
      completionRatio: ratio,
      watchedSec: watchedSec.round(),
      hour: ts.hour,
      timestampMs: ts.millisecondsSinceEpoch,
    );

    _appendEvent(event);

    if (isCompleted) {
      // Para películas, marcar como terminada; para series se respeta si está en
      // WatchHistory como finished o si fue un capítulo completado.
      if (!item.isSeries) {
        _completedIds[item.id] = ts.millisecondsSinceEpoch;
        _pruneTimestampMap(_completedIds, _maxCompleted);
      }
      _abandonedIds.remove(item.id);
    } else if (isQuickAbandon) {
      _abandonedIds[item.id] = ts.millisecondsSinceEpoch;
      _pruneTimestampMap(_abandonedIds, _maxAbandoned);
    } else if (ratio >= 0.25 || watchedSec >= 420) {
      // Si volvió y vio bastante, limpiar marca de abandono
      _abandonedIds.remove(item.id);
    }

    _cachedSummary = null;
    notifyListeners();
    _schedulePersist(triggerBackup: true);
  }

  /// Registra una preferencia explícita de idioma/audio al cambiar servidor.
  Future<void> recordAudioChoice(String label, {VodItem? item, DateTime? now}) async {
    await load();
    final norm = normalizeAudioLang(label);
    if (norm.isEmpty) return;
    final ts = now ?? DateTime.now();
    _appendEvent(TvTasteEvent(
      type: 'play_partial',
      itemId: item?.id ?? 'audio_pref',
      title: item?.title ?? 'Preferencia de audio',
      format: item != null ? formatOf(item) : 'movie',
      genres: item != null ? resolveGenresForItem(item) : const [],
      audioLang: norm,
      watchedSec: 60,
      hour: ts.hour,
      timestampMs: ts.millisecondsSinceEpoch,
    ));
    _cachedSummary = null;
    notifyListeners();
    _schedulePersist(triggerBackup: true);
  }

  /// Registra cambios en «Mi Lista» como señal fuerte de intención.
  Future<void> recordMyListSignal(
    VodItem item, {
    required bool added,
    DateTime? now,
  }) async {
    await load();
    if (item.id.isEmpty) return;
    final ts = now ?? DateTime.now();
    final genres = resolveGenresForItem(item);
    if (genres.isNotEmpty) _rememberEnrichedGenres(item.id, genres);

    _appendEvent(TvTasteEvent(
      type: added ? 'my_list_add' : 'my_list_remove',
      itemId: item.id,
      title: item.title,
      format: formatOf(item),
      genres: genres,
      audioLang: normalizeAudioLang('${item.genre} ${item.quality}'),
      hour: ts.hour,
      timestampMs: ts.millisecondsSinceEpoch,
    ));
    if (added) {
      _abandonedIds.remove(item.id);
    }
    _cachedSummary = null;
    notifyListeners();
    _schedulePersist(triggerBackup: true);
  }

  /// Registra una búsqueda realizada por el usuario (con los géneros de los
  /// primeros resultados si existen).
  Future<void> recordSearch(
    String query, {
    List<VodItem> topResults = const [],
    DateTime? now,
  }) async {
    await load();
    final clean = _normalizeToken(query);
    if (clean.length < 2) return;

    _recentSearches.remove(clean);
    _recentSearches.insert(0, clean);
    if (_recentSearches.length > _maxSearches) {
      _recentSearches.removeRange(_maxSearches, _recentSearches.length);
    }

    final inferredGenres = <String>{
      ...extractCanonicalGenres(genre: query, title: query),
    };
    var format = 'search';
    if (topResults.isNotEmpty) {
      for (final r in topResults.take(3)) {
        inferredGenres.addAll(resolveGenresForItem(r));
      }
      format = formatOf(topResults.first);
    }

    final ts = now ?? DateTime.now();
    _appendEvent(TvTasteEvent(
      type: 'search',
      itemId: 'q:$clean',
      title: query.trim(),
      format: format,
      genres: inferredGenres.take(4).toList(),
      hour: ts.hour,
      timestampMs: ts.millisecondsSinceEpoch,
    ));

    _cachedSummary = null;
    notifyListeners();
    _schedulePersist(triggerBackup: true);
  }

  /// Registra metadatos enriquecidos al abrir la ficha de un título para que el
  /// catálogo en grid (que suele venir sin género) herede sus géneros reales.
  void registerEnrichedItem(VodItem item) {
    if (item.id.isEmpty) return;
    final genres = extractCanonicalGenres(
      genre: item.genre,
      overview: item.overview,
      title: item.title,
      isAnime: item.isAnime,
    );
    if (genres.isEmpty) return;
    final prev = _enrichedGenres[item.id];
    if (prev != null && listEquals(prev, genres)) return;
    _rememberEnrichedGenres(item.id, genres);
    unawaited(persistNow(triggerBackup: false));
  }

  /// Registra que ciertos títulos se mostraron en el Hero / Novedades para
  /// rotarlos y evitar pantallas estáticas.
  void recordImpressions(Iterable<String> itemIds) {
    var changed = false;
    for (final id in itemIds) {
      if (id.isEmpty) continue;
      if (_recentImpressions[id] != _sessionCounter) {
        _recentImpressions[id] = _sessionCounter;
        changed = true;
      }
    }
    if (changed) {
      if (_recentImpressions.length > _maxImpressions) {
        final sorted = _recentImpressions.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        _recentImpressions
          ..clear()
          ..addEntries(sorted.take(_maxImpressions));
      }
      unawaited(persistNow(triggerBackup: false));
    }
  }

  /// Calcula o devuelve el resumen agregado actual del perfil de gustos.
  TvTasteSummary computeSummary({DateTime? now}) {
    if (_cachedSummary != null && now == null) return _cachedSummary!;
    final refMs = (now ?? DateTime.now()).millisecondsSinceEpoch;

    final genreRaw = <String, double>{};
    final formatRaw = <String, double>{'movie': 0, 'series': 0, 'anime': 0};
    final audioCounts = <String, int>{};
    final hourWeights = <int, double>{};
    final bucketWeights = <String, double>{
      'madrugada': 0,
      'manana': 0,
      'tarde': 0,
      'noche': 0,
    };

    var started = 0;
    var completed = 0;
    var abandoned = 0;

    for (final e in _events) {
      final ageDays = e.timestampMs > 0
          ? math.max(0.0, (refMs - e.timestampMs) / 86400000.0)
          : 0.0;
      final decay = _recencyDecay(ageDays);

      double baseWeight;
      switch (e.type) {
        case 'play_completed':
          baseWeight = 3.2;
          started += 1;
          completed += 1;
          break;
        case 'play_partial':
          baseWeight = e.completionRatio >= 0.45 ? 2.0 : 1.4;
          started += 1;
          break;
        case 'play_abandoned':
          baseWeight = -1.6;
          started += 1;
          abandoned += 1;
          break;
        case 'my_list_add':
          baseWeight = 2.2;
          break;
        case 'my_list_remove':
          baseWeight = -0.6;
          break;
        case 'search':
          baseWeight = 0.9;
          break;
        default:
          baseWeight = 0.5;
      }

      final weighted = baseWeight * decay;
      for (final g in e.genres) {
        genreRaw[g] = (genreRaw[g] ?? 0) + weighted;
      }

      if (weighted > 0 && formatRaw.containsKey(e.format)) {
        formatRaw[e.format] = (formatRaw[e.format] ?? 0) + weighted;
      }

      if (e.audioLang.isNotEmpty && baseWeight > 0) {
        audioCounts[e.audioLang] = (audioCounts[e.audioLang] ?? 0) + 1;
      }

      if (baseWeight > 0 &&
          (e.type == 'play_completed' || e.type == 'play_partial')) {
        hourWeights[e.hour] = (hourWeights[e.hour] ?? 0) + decay;
        final b = timeBucketForHour(e.hour);
        bucketWeights[b] = (bucketWeights[b] ?? 0) + decay;
      }
    }

    // Normalizar pesos positivos de género a 0..1
    final positiveGenres = <String, double>{};
    var maxG = 0.0;
    genreRaw.forEach((k, v) {
      if (v > 0.05) {
        positiveGenres[k] = v;
        if (v > maxG) maxG = v;
      }
    });
    final normalizedGenres = <String, double>{};
    if (maxG > 0) {
      positiveGenres.forEach((k, v) {
        normalizedGenres[k] = double.parse((v / maxG).toStringAsFixed(3));
      });
    }

    // Normalizar ratio de formatos (default equilibrado si no hay señales)
    final formatSum = formatRaw.values.fold<double>(0, (a, b) => a + b);
    final formatRatio = formatSum > 0
        ? {
            for (final entry in formatRaw.entries)
              entry.key:
                  double.parse((entry.value / formatSum).toStringAsFixed(3)),
          }
        : const {'movie': 0.34, 'series': 0.33, 'anime': 0.33};

    // Audio preferido
    var preferredAudio = 'auto';
    var bestAudioCount = 0;
    audioCounts.forEach((k, v) {
      if (v > bestAudioCount) {
        bestAudioCount = v;
        preferredAudio = k;
      }
    });

    // Horario habitual
    var peakHour = 21;
    var bestHourW = -1.0;
    hourWeights.forEach((h, w) {
      if (w > bestHourW) {
        bestHourW = w;
        peakHour = h;
      }
    });
    final bucketSum = bucketWeights.values.fold<double>(0, (a, b) => a + b);
    final normalizedBuckets = bucketSum > 0
        ? {
            for (final entry in bucketWeights.entries)
              entry.key:
                  double.parse((entry.value / bucketSum).toStringAsFixed(3)),
          }
        : const {
            'madrugada': 0.1,
            'manana': 0.15,
            'tarde': 0.3,
            'noche': 0.45,
          };

    final summary = TvTasteSummary(
      genreWeights: normalizedGenres,
      formatRatio: formatRatio,
      preferredAudio: preferredAudio,
      audioCounts: Map<String, int>.unmodifiable(audioCounts),
      completionRate: started > 0
          ? double.parse((completed / started).toStringAsFixed(3))
          : 0.0,
      abandonedRate: started > 0
          ? double.parse((abandoned / started).toStringAsFixed(3))
          : 0.0,
      startedSessions: started,
      completedSessions: completed,
      abandonedSessions: abandoned,
      timeBuckets: normalizedBuckets,
      peakHour: peakHour,
      eventCount: _events.length,
    );

    if (now == null) _cachedSummary = summary;
    return summary;
  }

  /// Indica si un título ya fue completado por el usuario (película terminada o
  /// marcado en `_completedIds`).
  bool isCompleted(VodItem item, {Iterable<WatchProgress>? history}) {
    if (_completedIds.containsKey(item.id)) return true;
    final hist = history ?? WatchHistory().items;
    for (final h in hist) {
      if (h.id == item.id && !h.isSeries && h.finished) return true;
    }
    return false;
  }

  /// Indica si un título fue abandonado rápido recientemente (ventana de 14 días).
  bool isRecentlyAbandoned(VodItem item, {DateTime? now}) {
    final ts = _abandonedIds[item.id];
    if (ts == null) return false;
    final refMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final ageDays = (refMs - ts) / 86400000.0;
    return ageDays <= _abandonCooldownDays;
  }

  /// Verdadero cuando conviene excluir el título de Novedades / Hero /
  /// Recomendaciones frescas (ya terminado o abandonado rápido).
  bool shouldExcludeFromDiscovery(
    VodItem item, {
    Iterable<WatchProgress>? history,
    DateTime? now,
  }) {
    return isCompleted(item, history: history) ||
        isRecentlyAbandoned(item, now: now);
  }

  /// Puntaje de afinidad personalizado para re-rankear cualquier catálogo
  /// (Hero, Novedades, Estrenos, Series, Anime).
  double scoreItem(
    VodItem item, {
    TvTasteSummary? summary,
    Iterable<WatchProgress>? history,
    bool applyImpressionPenalty = true,
    DateTime? now,
  }) {
    final s = summary ?? computeSummary(now: now);
    double score = 0.0;

    // 1. Afinidad por géneros canónicos
    final genres = resolveGenresForItem(item);
    if (genres.isNotEmpty && s.genreWeights.isNotEmpty) {
      var genreScore = 0.0;
      var matches = 0;
      for (final g in genres) {
        final w = s.genreWeights[g];
        if (w != null && w > 0) {
          genreScore += w * 3.0;
          matches += 1;
        }
      }
      // Bonus por coincidencia múltiple
      if (matches >= 2) genreScore += 0.9;
      score += math.min(genreScore, 7.5);
    }

    // 2. Proporción Película vs Serie vs Anime
    final fmt = formatOf(item);
    score += (s.formatRatio[fmt] ?? 0.33) * 2.6;

    // 3. Afinidad con idioma/audio preferido
    if (s.preferredAudio != 'auto') {
      final itemAudio = normalizeAudioLang('${item.genre} ${item.quality}');
      if (itemAudio == s.preferredAudio) {
        score += 0.9;
      }
    }

    // 4. Afinidad con búsquedas recientes
    if (_recentSearches.isNotEmpty) {
      final haystack = _normalizeToken('${item.title} ${item.overview}');
      for (var i = 0; i < _recentSearches.length && i < 12; i++) {
        final q = _recentSearches[i];
        if (q.length >= 3 && haystack.contains(q)) {
          score += 2.4 * math.max(0.4, 1.0 - i * 0.06);
          break;
        }
      }
    }

    // 5. Calidad visual / ficha rica
    if (item.backdrop.isNotEmpty) score += 0.45;
    final rating = double.tryParse(item.rating.replaceAll(',', '.')) ?? 0.0;
    if (rating >= 7.0) {
      score += ((rating - 6.5) * 0.35).clamp(0.0, 1.2);
    }

    // 6. Frescura por año reciente
    final yearNum = int.tryParse(item.year.trim()) ?? 0;
    final curYear = (now ?? DateTime.now()).year;
    if (yearNum >= curYear - 1) {
      score += 0.55;
    } else if (yearNum >= curYear - 3) {
      score += 0.25;
    }

    // 7. Penalizaciones: ya terminado / abandonado rápido / anti-repetición
    if (isCompleted(item, history: history)) {
      score -= 10.0;
    }
    if (isRecentlyAbandoned(item, now: now)) {
      score -= 7.5;
    }
    if (applyImpressionPenalty) {
      final lastShown = _recentImpressions[item.id];
      if (lastShown != null) {
        final gap = _sessionCounter - lastShown;
        if (gap <= 0) {
          score -= 3.2;
        } else if (gap == 1) {
          score -= 2.2;
        } else if (gap == 2) {
          score -= 1.1;
        }
      }
    }

    return score;
  }

  /// Devuelve los géneros canónicos de un `VodItem`, combinando caché
  /// enriquecida + texto del ítem.
  List<String> resolveGenresForItem(VodItem item) {
    final cached = _enrichedGenres[item.id];
    final extracted = extractCanonicalGenres(
      genre: item.genre,
      overview: item.overview,
      title: item.title,
      isAnime: item.isAnime,
    );
    if (cached == null || cached.isEmpty) return extracted;
    if (extracted.isEmpty) return cached;
    return {...cached, ...extracted}.toList();
  }

  /// Exporta todo el perfil de gustos como JSON compacto para respaldo en nube.
  String exportJsonString() => jsonEncode(toMap());

  Map<String, dynamic> toMap() => <String, dynamic>{
        'v': _schemaVersion,
        'sessionCounter': _sessionCounter,
        'events': _events.map((e) => e.toJson()).toList(),
        'completedIds': _completedIds,
        'abandonedIds': _abandonedIds,
        'recentSearches': _recentSearches,
        'enrichedGenres': _enrichedGenres,
        'recentImpressions': _recentImpressions,
      };

  /// Fusiona un perfil descargado de la nube sin perder señales locales
  /// (deduplicación por evento + max timestamp + unión de géneros).
  Future<bool> mergeFromJsonString(
    String raw, {
    bool overwrite = false,
  }) async {
    if (raw.trim().isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      await load();
      _applyFromMap(decoded.cast<String, dynamic>(), overwrite: overwrite);
      _cachedSummary = null;
      await persistNow(triggerBackup: false);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[TvTasteProfile] Merge err: $e');
      return false;
    }
  }

  Future<void> persistNow({bool triggerBackup = false}) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(prefsKey, exportJsonString());
      if (triggerBackup) {
        InutilTvCloudBackupService.instance.schedulePush();
      }
    } catch (e) {
      debugPrint('[TvTasteProfile] Persist err: $e');
    }
  }

  Future<void> clear() async {
    _clearInMemory();
    _cachedSummary = null;
    notifyListeners();
    await persistNow(triggerBackup: true);
  }

  @visibleForTesting
  void resetForTest() {
    _clearInMemory();
    _loaded = false;
    _cachedSummary = null;
  }

  // ── Helpers de normalización y mapeo de proveedores ───────────────────────

  static String formatOf(VodItem item) {
    if (item.isAnime) return 'anime';
    if (item.isSeries) return 'series';
    return 'movie';
  }

  static String timeBucketForHour(int hour) {
    final h = hour % 24;
    if (h >= 0 && h < 6) return 'madrugada';
    if (h >= 6 && h < 12) return 'manana';
    if (h >= 12 && h < 19) return 'tarde';
    return 'noche';
  }

  static String normalizeAudioLang(String raw) {
    final l = _normalizeToken(raw);
    if (l.isEmpty) return '';
    if (l.contains('latino') || l.contains('lat ')) return 'latino';
    if (l.contains('subtitul') ||
        l.contains('sub espanol') ||
        RegExp(r'\bsub\b').hasMatch(l) ||
        l.contains('vose') ||
        l.contains('ingles')) {
      return 'sub';
    }
    if (l.contains('castellano') || l.contains('espana')) {
      return 'espanol';
    }
    return '';
  }

  /// Extrae géneros canónicos filtrando ruido de proveedores (`Serie`,
  /// `Latino`, `Sub Español`, `HD`). Si el campo `genre` viene genérico,
  /// aplica inferencia ligera sobre sinopsis y título.
  static List<String> extractCanonicalGenres({
    required String genre,
    String overview = '',
    String title = '',
    bool isAnime = false,
  }) {
    final out = <String>{};
    if (isAnime) out.add('anime');

    final normGenre = _normalizeToken(genre);
    _matchGenreKeywords(normGenre, out, strict: false);

    // Si los géneros explícitos no aportaron más allá de 'anime', inferir de
    // sinopsis/título con reglas más estrictas para evitar falsos positivos.
    final nonAnimeCount = out.where((g) => g != 'anime').length;
    if (nonAnimeCount == 0 && (overview.isNotEmpty || title.isNotEmpty)) {
      final combined = _normalizeToken('$title $overview');
      _matchGenreKeywords(combined, out, strict: true);
    }

    return out.toList();
  }

  static void _matchGenreKeywords(
    String text,
    Set<String> out, {
    required bool strict,
  }) {
    if (text.isEmpty) return;

    void check(String canonical, List<String> strong, [List<String> soft = const []]) {
      for (final kw in strong) {
        if (text.contains(kw)) {
          out.add(canonical);
          return;
        }
      }
      if (!strict) {
        for (final kw in soft) {
          if (text.contains(kw)) {
            out.add(canonical);
            return;
          }
        }
      }
    }

    check('accion', ['accion', 'action', 'superhero', 'artes marciales', 'combate', 'mercenari'], ['pelea']);
    check('ciencia_ficcion', ['ciencia ficcion', 'sci-fi', 'scifi', 'science fiction', 'espacial', 'extraterrestre', 'futurista', 'distopi', 'cyberpunk', 'robot', 'galaxia']);
    check('terror', ['terror', 'horror', 'zombi', 'vampiro', 'demonio', 'exorcism', 'sobrenatural', 'asesino serial', 'maldicion', 'fantasma']);
    check('comedia', ['comedia', 'comedy', 'sitcom', 'humor', 'divertid', 'parodia']);
    check('drama', ['drama', 'melodrama', 'tragedia']);
    check('suspenso', ['suspenso', 'suspense', 'thriller', 'psicologic', 'secuestro', 'conspiracion']);
    check('animacion', ['animacion', 'animation', 'animada', 'caricatura', 'pixar', 'dreamworks']);
    check('fantasia', ['fantasia', 'fantasy', 'magia', 'hechic', 'dragon', 'reino', 'isekai', 'shonen', 'mitologi']);
    check('crimen', ['crimen', 'crime', 'policial', 'narco', 'mafia', 'detective', 'cartel', 'robo', 'heist', 'asesinato']);
    check('aventura', ['aventura', 'adventure', 'expedicion', 'tesoro', 'viaje epico', 'supervivencia']);
    check('romance', ['romance', 'romantic', 'historia de amor', 'enamora']);
    check('familia', ['familia', 'family', 'infantil', 'ninos', 'familiar']);
    check('documental', ['documental', 'documentary', 'biografic']);
    check('misterio', ['misterio', 'mystery', 'enigma', 'desaparicion', 'investigacion']);
    check('belica', ['belica', 'guerra', 'war', 'militar', 'soldado', 'ejercito']);
    check('dorama', ['dorama', 'k-drama', 'kdrama', 'corean']);
  }

  /// Slug de género para `VodCatalogService.getMovies(genre:)`.
  static String? toMovieGenreSlug(String canonical) {
    return switch (canonical) {
      'accion' => 'accion',
      'ciencia_ficcion' => 'ciencia-ficcion',
      'terror' => 'terror',
      'comedia' => 'comedia',
      'drama' => 'drama',
      'suspenso' => 'suspenso',
      'animacion' => 'animacion',
      'fantasia' => 'fantasia',
      'crimen' => 'crimen',
      'aventura' => 'aventura',
      'romance' => 'romance',
      'familia' => 'familia',
      'documental' => 'documental',
      'misterio' => 'misterio',
      _ => null,
    };
  }

  /// Categoría de género para `VodCatalogService.getSeries(category:)`.
  static String? toSeriesCategorySlug(String canonical) {
    return switch (canonical) {
      'accion' => 'gen:accion',
      'comedia' => 'gen:comedia',
      'crimen' => 'gen:crimen',
      'animacion' => 'gen:animacion',
      'drama' => 'gen:drama',
      'fantasia' => 'gen:fantasia',
      'aventura' => 'gen:aventura',
      'ciencia_ficcion' => 'gen:ciencia-ficcion',
      'dorama' => 'gen:dorama',
      'familia' => 'gen:familia',
      'documental' => 'gen:documental',
      'belica' => 'gen:belica',
      _ => null,
    };
  }

  /// Slug de género para `VodCatalogService.getAnime(genre:)`.
  static String? toAnimeGenreSlug(String canonical) {
    return switch (canonical) {
      'accion' => 'accion',
      'aventura' => 'aventura',
      'comedia' => 'comedia',
      'drama' => 'drama',
      'fantasia' => 'fantasia',
      'misterio' => 'misterio',
      'romance' => 'romance',
      'ciencia_ficcion' => 'sci-fi',
      'terror' => 'terror',
      'suspenso' => 'suspenso',
      _ => null,
    };
  }

  static String labelForGenre(String canonical) =>
      canonicalGenreLabels[canonical] ?? canonical;

  // ── Internos ──────────────────────────────────────────────────────────────

  static double _recencyDecay(double ageDays) {
    if (ageDays <= 0) return 1.0;
    final raw = math.exp(-ageDays * math.ln2 / _halfLifeDays);
    return raw.clamp(0.15, 1.0).toDouble();
  }

  static String _normalizeToken(String input) {
    var s = input.toLowerCase().trim();
    const reps = {
      'á': 'a',
      'é': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'ü': 'u',
      'ñ': 'n',
    };
    reps.forEach((k, v) => s = s.replaceAll(k, v));
    return s.replaceAll(RegExp(r'\s+'), ' ');
  }

  void _appendEvent(TvTasteEvent event) {
    _events.add(event);
    if (_events.length > _maxEvents) {
      _events.removeRange(0, _events.length - _maxEvents);
    }
  }

  void _rememberEnrichedGenres(String id, List<String> genres) {
    _enrichedGenres[id] = genres;
    if (_enrichedGenres.length > _maxEnrichedGenres) {
      final firstKey = _enrichedGenres.keys.first;
      _enrichedGenres.remove(firstKey);
    }
  }

  static void _pruneTimestampMap(Map<String, int> map, int maxEntries) {
    if (map.length <= maxEntries) return;
    final sorted = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    map
      ..clear()
      ..addEntries(sorted.take(maxEntries));
  }

  void _schedulePersist({required bool triggerBackup}) {
    unawaited(persistNow(triggerBackup: triggerBackup));
  }

  void _clearInMemory() {
    _events.clear();
    _completedIds.clear();
    _abandonedIds.clear();
    _recentSearches.clear();
    _enrichedGenres.clear();
    _recentImpressions.clear();
    _sessionCounter = 1;
  }

  void _applyFromMap(Map<String, dynamic> map, {required bool overwrite}) {
    if (overwrite) _clearInMemory();

    final remoteCounter = (map['sessionCounter'] as num?)?.toInt() ?? 1;
    if (remoteCounter > _sessionCounter) _sessionCounter = remoteCounter;

    // 1. Eventos deduplicados por (tipo, id, minuto)
    final seen = <String>{
      for (final e in _events) '${e.type}|${e.itemId}|${e.timestampMs ~/ 60000}',
    };
    final rawEvents = map['events'];
    if (rawEvents is List) {
      for (final raw in rawEvents) {
        if (raw is! Map) continue;
        final ev = TvTasteEvent.fromJson(raw.cast<String, dynamic>());
        if (ev.type.isEmpty) continue;
        final key = '${ev.type}|${ev.itemId}|${ev.timestampMs ~/ 60000}';
        if (seen.add(key)) {
          _events.add(ev);
        }
      }
      _events.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
      if (_events.length > _maxEvents) {
        _events.removeRange(0, _events.length - _maxEvents);
      }
    }

    // 2. Completados y abandonados (gana timestamp más reciente)
    void mergeTsMap(Map<String, int> target, dynamic raw, int cap) {
      if (raw is! Map) return;
      raw.forEach((k, v) {
        final key = k.toString();
        final ts = (v as num?)?.toInt() ?? 0;
        if (key.isEmpty) return;
        final cur = target[key] ?? 0;
        if (ts > cur) target[key] = ts;
      });
      _pruneTimestampMap(target, cap);
    }

    mergeTsMap(_completedIds, map['completedIds'], _maxCompleted);
    mergeTsMap(_abandonedIds, map['abandonedIds'], _maxAbandoned);

    // 3. Búsquedas recientes
    final rawSearches = map['recentSearches'];
    if (rawSearches is List) {
      for (final s in rawSearches.reversed) {
        final clean = _normalizeToken(s.toString());
        if (clean.length < 2) continue;
        if (!_recentSearches.contains(clean)) {
          _recentSearches.add(clean);
        }
      }
      if (_recentSearches.length > _maxSearches) {
        _recentSearches.removeRange(_maxSearches, _recentSearches.length);
      }
    }

    // 4. Géneros enriquecidos (unión)
    final rawEnriched = map['enrichedGenres'];
    if (rawEnriched is Map) {
      rawEnriched.forEach((k, v) {
        if (v is List) {
          final id = k.toString();
          final list = v.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
          if (id.isNotEmpty && list.isNotEmpty) {
            final existing = _enrichedGenres[id] ?? const <String>[];
            _enrichedGenres[id] = {...existing, ...list}.toList();
          }
        }
      });
    }

    // 5. Impresiones recientes
    final rawImp = map['recentImpressions'];
    if (rawImp is Map) {
      rawImp.forEach((k, v) {
        final id = k.toString();
        final s = (v as num?)?.toInt() ?? 0;
        if (id.isNotEmpty && s > (_recentImpressions[id] ?? 0)) {
          _recentImpressions[id] = s;
        }
      });
    }
  }

  Future<void> _seedFromExistingHistoryAndList() async {
    try {
      await Future.wait([
        WatchHistory().load(),
        MyListService.instance.load(),
      ]);
      final hist = WatchHistory().items;
      final myList = MyListService.instance.items;
      if (hist.isEmpty && myList.isEmpty) return;

      for (final h in hist) {
        final genres = extractCanonicalGenres(
          genre: h.genre,
          title: h.title,
          isAnime: h.isAnime,
        );
        final ratio = h.durationSec > 0
            ? (h.positionSec / h.durationSec).clamp(0.0, 1.0)
            : 0.35;
        final isCompleted = !h.isSeries && h.finished;
        final ts = h.updatedAt > 0
            ? h.updatedAt
            : DateTime.now().millisecondsSinceEpoch;
        _appendEvent(TvTasteEvent(
          type: isCompleted ? 'play_completed' : 'play_partial',
          itemId: h.id,
          title: h.title,
          format: h.isAnime ? 'anime' : (h.isSeries ? 'series' : 'movie'),
          genres: genres,
          audioLang: normalizeAudioLang(h.genre),
          completionRatio: ratio,
          watchedSec: h.positionSec.round(),
          hour: DateTime.fromMillisecondsSinceEpoch(ts).hour,
          timestampMs: ts,
        ));
        if (isCompleted) _completedIds[h.id] = ts;
      }

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final m in myList) {
        final genres = extractCanonicalGenres(
          genre: m.genre,
          overview: m.overview,
          title: m.title,
          isAnime: m.isAnime,
        );
        _appendEvent(TvTasteEvent(
          type: 'my_list_add',
          itemId: m.id,
          title: m.title,
          format: formatOf(m),
          genres: genres,
          audioLang: normalizeAudioLang('${m.genre} ${m.quality}'),
          hour: DateTime.now().hour,
          timestampMs: nowMs,
        ));
      }
      _cachedSummary = null;
      _schedulePersist(triggerBackup: false);
    } catch (e) {
      debugPrint('[TvTasteProfile] Seed err: $e');
    }
  }
}
