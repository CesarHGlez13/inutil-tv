import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_service.dart';
import 'firebase_firestore_service.dart';
import 'watch_history.dart';

@immutable
class TvWrappedTitleStat {
  const TvWrappedTitleStat({
    required this.id,
    required this.title,
    required this.category,
    this.posterUrl,
    required this.plays,
    required this.seconds,
  });

  final String id;
  final String title;
  final String category; // 'Películas' | 'Series' | 'Anime' | 'TV en Vivo'
  final String? posterUrl;
  final int plays;
  final int seconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'category': category,
        if (posterUrl != null && posterUrl!.isNotEmpty) 'posterUrl': posterUrl,
        'plays': plays,
        'seconds': seconds,
      };

  factory TvWrappedTitleStat.fromJson(Map<String, dynamic> j) =>
      TvWrappedTitleStat(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? 'Título').toString(),
        category: (j['category'] ?? 'Series').toString(),
        posterUrl: j['posterUrl']?.toString(),
        plays: (j['plays'] as num?)?.toInt() ?? 0,
        seconds: (j['seconds'] as num?)?.toInt() ?? 0,
      );
}

@immutable
class InutilTvWrappedSummary {
  const InutilTvWrappedSummary({
    required this.year,
    required this.totalSeconds,
    required this.totalSessions,
    required this.topTitles,
    required this.categorySeconds,
    required this.activeDaysCount,
    required this.peakHour,
    this.fromHistoryFallback = false,
  });

  final int year;
  final int totalSeconds;
  final int totalSessions;
  final List<TvWrappedTitleStat> topTitles;
  final Map<String, int> categorySeconds;
  final int activeDaysCount;
  final int peakHour;
  final bool fromHistoryFallback;

  int get totalMinutes => (totalSeconds / 60).round();
  double get totalHours => totalSeconds / 3600.0;
  int get equivalentMovies => (totalMinutes / 110).ceil().clamp(1, 9999);
  TvWrappedTitleStat? get topTitle =>
      topTitles.isNotEmpty ? topTitles.first : null;

  String get topCategory {
    if (categorySeconds.isEmpty) return 'Series';
    final sorted = categorySeconds.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  bool get hasViewingData => totalSessions > 0 || topTitles.isNotEmpty;

  ({String emoji, String title, String subtitle}) get viewingScheduleVibe {
    if (peakHour >= 22 || peakHour < 5) {
      return (
        emoji: '🌙',
        title: 'Maratón Nocturno',
        subtitle: 'Tus mejores funciones empiezan cuando la ciudad duerme.',
      );
    }
    if (peakHour >= 5 && peakHour < 12) {
      return (
        emoji: '☀️',
        title: 'Cine Matutino',
        subtitle: 'Arrancas el día con un buen capítulo o las noticias en vivo.',
      );
    }
    if (peakHour >= 12 && peakHour < 18) {
      return (
        emoji: '⚡',
        title: 'Función de Tarde',
        subtitle: 'Las tardes son tu momento favorito para desconectar frente a la pantalla.',
      );
    }
    return (
      emoji: '🍿',
      title: 'Prime Time',
      subtitle: 'Siempre listo para el horario estelar con palomitas en mano.',
    );
  }

  ({String emoji, String title, String description}) get viewerArchetype {
    if (topCategory == 'Anime') {
      return (
        emoji: '⚡',
        title: 'Leyenda del Anime',
        description:
            'Nunca te saltas un arco épico y siempre tienes un episodio más listo.',
      );
    }
    if (topCategory == 'TV en Vivo') {
      return (
        emoji: '📺',
        title: 'Rey del Zapping en Vivo',
        description:
            'Deportes, noticias y canales en vivo 24/7: nunca te pierdes el momento exacto.',
      );
    }
    if (topCategory == 'Películas') {
      return (
        emoji: '🎬',
        title: 'Cinéfilo de Corazón',
        description:
            'Disfrutas el séptimo arte en pantalla completa, de estrenos a clásicos eternos.',
      );
    }
    return (
      emoji: '🍿',
      title: 'Maestro del Maratón',
      description:
          '"Solo un capítulo más" es tu frase favorita — y con precarga instantánea, ni parpadeas.',
    );
  }
}

/// Motor de estadísticas anuales («Tu Año en InútilTV») portado desde Inútil Music,
/// con respaldo automático en Firestore (`users/{uid}/data/tv_wrapped_<year>`).
class InutilTvWrappedService {
  InutilTvWrappedService._();
  static final InutilTvWrappedService instance = InutilTvWrappedService._();

  static const _prefsPrefix = 'inutiltv_wrapped_stats_v1_';
  static const _maxStoredTitles = 100;

  final Map<int, _TvYearBucket> _buckets = {};
  Timer? _persistTimer;
  Timer? _cloudTimer;
  String? _lastCountedSessionKey;

  bool get _canSyncCloud =>
      InutilAuthService.instance.currentUser?.idToken.isNotEmpty == true &&
      InutilAuthService.instance.isAccessAllowed;

  /// Registra segundos reales de visualización desde `PlayerScreen` o `TvScreen`.
  void recordWatchDelta({
    required String id,
    required String title,
    required String category,
    String? posterUrl,
    required int deltaSeconds,
  }) {
    final cleanId = id.trim();
    if (cleanId.isEmpty || deltaSeconds <= 0 || deltaSeconds > 120) return;

    final now = DateTime.now();
    final bucket = _buckets.putIfAbsent(now.year, () => _TvYearBucket(now.year));
    bucket.totalSeconds += deltaSeconds;
    bucket.hourBuckets[now.hour] =
        (bucket.hourBuckets[now.hour] ?? 0) + deltaSeconds;
    bucket.categorySeconds[category] =
        (bucket.categorySeconds[category] ?? 0) + deltaSeconds;
    final dayKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    bucket.activeDays.add(dayKey);

    var addPlay = 0;
    final sessionKey = '${dayKey}_$cleanId';
    if (_lastCountedSessionKey != sessionKey) {
      _lastCountedSessionKey = sessionKey;
      addPlay = 1;
      bucket.totalSessions += 1;
    }

    final prev = bucket.titles[cleanId];
    bucket.titles[cleanId] = TvWrappedTitleStat(
      id: cleanId,
      title: title.trim().isNotEmpty ? title.trim() : 'Título',
      category: category,
      posterUrl: (posterUrl?.isNotEmpty == true) ? posterUrl : prev?.posterUrl,
      plays: (prev?.plays ?? 0) + addPlay,
      seconds: (prev?.seconds ?? 0) + deltaSeconds,
    );

    _schedulePersist();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(seconds: 12),
      () => unawaited(persistNow()),
    );
    _cloudTimer?.cancel();
    _cloudTimer = Timer(
      const Duration(seconds: 45),
      () => unawaited(syncCurrentYearToCloud()),
    );
  }

  Future<void> persistNow({int? year}) async {
    final targetYear = year ?? DateTime.now().year;
    final bucket = _buckets[targetYear];
    if (bucket == null) return;
    try {
      final sp = await SharedPreferences.getInstance();
      if (!bucket.hydratedFromDisk) {
        final raw = sp.getString('$_prefsPrefix$targetYear');
        if (raw != null && raw.isNotEmpty) {
          bucket.mergeFrom(_TvYearBucket.fromJsonString(targetYear, raw));
        }
        bucket.hydratedFromDisk = true;
      }
      bucket.prune(_maxStoredTitles);
      await sp.setString('$_prefsPrefix$targetYear', bucket.toJsonString());
    } catch (e) {
      debugPrint('[TvWrapped] Local persist err: $e');
    }
  }

  Future<_TvYearBucket> _loadBucket(int year) async {
    final bucket = _buckets.putIfAbsent(year, () => _TvYearBucket(year));
    if (!bucket.hydratedFromDisk) {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('$_prefsPrefix$year');
      if (raw != null && raw.isNotEmpty) {
        bucket.mergeFrom(_TvYearBucket.fromJsonString(year, raw));
      }
      bucket.hydratedFromDisk = true;
    }
    return bucket;
  }

  Future<void> syncCurrentYearToCloud({int? year}) async {
    if (!_canSyncCloud) return;
    final targetYear = year ?? DateTime.now().year;
    try {
      final bucket = await _loadBucket(targetYear);
      if (bucket.totalSeconds == 0 && bucket.totalSessions == 0) return;
      final uid = InutilAuthService.instance.currentUser!.uid;
      bucket.prune(_maxStoredTitles);
      await InutilFirestoreService.instance.setDocument(
        'users/$uid/data/tv_wrapped_$targetYear',
        bucket.toMap(),
      );
    } catch (e) {
      debugPrint('[TvWrapped] Cloud push err: $e');
    }
  }

  Future<void> pullYearFromCloud({int? year}) async {
    if (!_canSyncCloud) return;
    final targetYear = year ?? DateTime.now().year;
    try {
      final uid = InutilAuthService.instance.currentUser!.uid;
      final remote = await InutilFirestoreService.instance.getDocument(
        'users/$uid/data/tv_wrapped_$targetYear',
      );
      if (remote == null) return;
      final remoteBucket = _TvYearBucket.fromMap(targetYear, remote);
      final local = await _loadBucket(targetYear);
      local.mergeTakingMax(remoteBucket);
      local.prune(_maxStoredTitles);
      final sp = await SharedPreferences.getInstance();
      await sp.setString('$_prefsPrefix$targetYear', local.toJsonString());
    } catch (e) {
      debugPrint('[TvWrapped] Cloud pull err: $e');
    }
  }

  /// Construye el resumen del año (complementando con `WatchHistory` si aún no
  /// hay suficientes segundos registrados en el motor nuevo).
  Future<InutilTvWrappedSummary> buildSummary({int? year}) async {
    final targetYear = year ?? DateTime.now().year;
    final bucket = await _loadBucket(targetYear);

    if (bucket.totalSeconds >= 60 && bucket.titles.isNotEmpty) {
      final top = bucket.titles.values.toList()
        ..sort((a, b) => b.seconds.compareTo(a.seconds));
      var peakHour = 21;
      var peakSec = -1;
      bucket.hourBuckets.forEach((h, s) {
        if (s > peakSec) {
          peakSec = s;
          peakHour = h;
        }
      });
      return InutilTvWrappedSummary(
        year: targetYear,
        totalSeconds: bucket.totalSeconds,
        totalSessions: bucket.totalSessions,
        topTitles: top.take(5).toList(),
        categorySeconds: Map<String, int>.from(bucket.categorySeconds),
        activeDaysCount: bucket.activeDays.length.clamp(1, 366),
        peakHour: peakHour,
      );
    }

    // Fallback amigable desde el historial real de WatchHistory
    await WatchHistory().load();
    final hist = WatchHistory().items;
    if (hist.isEmpty) {
      return InutilTvWrappedSummary(
        year: targetYear,
        totalSeconds: 0,
        totalSessions: 0,
        topTitles: const [],
        categorySeconds: const {},
        activeDaysCount: 0,
        peakHour: 21,
        fromHistoryFallback: true,
      );
    }

    var totalSec = 0;
    final catSec = <String, int>{};
    final stats = <TvWrappedTitleStat>[];
    for (final h in hist) {
      final sec = h.positionSec > 30 ? h.positionSec.round() : 1200;
      totalSec += sec;
      final cat = h.isAnime
          ? 'Anime'
          : (h.isSeries ? 'Series' : 'Películas');
      catSec[cat] = (catSec[cat] ?? 0) + sec;
      stats.add(TvWrappedTitleStat(
        id: h.id,
        title: h.title,
        category: cat,
        posterUrl: h.poster,
        plays: 1,
        seconds: sec,
      ));
    }
    stats.sort((a, b) => b.seconds.compareTo(a.seconds));

    return InutilTvWrappedSummary(
      year: targetYear,
      totalSeconds: totalSec,
      totalSessions: hist.length,
      topTitles: stats.take(5).toList(),
      categorySeconds: catSec,
      activeDaysCount: hist.length.clamp(1, 30),
      peakHour: 21,
      fromHistoryFallback: true,
    );
  }
}

class _TvYearBucket {
  _TvYearBucket(this.year);

  final int year;
  int totalSeconds = 0;
  int totalSessions = 0;
  final Map<String, TvWrappedTitleStat> titles = {};
  final Map<String, int> categorySeconds = {};
  final Map<int, int> hourBuckets = {};
  final Set<String> activeDays = {};
  bool hydratedFromDisk = false;

  void mergeFrom(_TvYearBucket other) {
    totalSeconds += other.totalSeconds;
    totalSessions += other.totalSessions;
    activeDays.addAll(other.activeDays);
    other.categorySeconds.forEach((k, v) {
      categorySeconds[k] = (categorySeconds[k] ?? 0) + v;
    });
    other.hourBuckets.forEach((k, v) {
      hourBuckets[k] = (hourBuckets[k] ?? 0) + v;
    });
    other.titles.forEach((k, v) {
      final cur = titles[k];
      if (cur == null) {
        titles[k] = v;
      } else {
        titles[k] = TvWrappedTitleStat(
          id: cur.id,
          title: cur.title,
          category: cur.category,
          posterUrl: cur.posterUrl ?? v.posterUrl,
          plays: cur.plays + v.plays,
          seconds: cur.seconds + v.seconds,
        );
      }
    });
  }

  void mergeTakingMax(_TvYearBucket remote) {
    if (remote.totalSeconds > totalSeconds) totalSeconds = remote.totalSeconds;
    if (remote.totalSessions > totalSessions) {
      totalSessions = remote.totalSessions;
    }
    activeDays.addAll(remote.activeDays);
    remote.categorySeconds.forEach((k, v) {
      final cur = categorySeconds[k] ?? 0;
      if (v > cur) categorySeconds[k] = v;
    });
    remote.hourBuckets.forEach((k, v) {
      final cur = hourBuckets[k] ?? 0;
      if (v > cur) hourBuckets[k] = v;
    });
    remote.titles.forEach((k, v) {
      final cur = titles[k];
      if (cur == null || v.seconds > cur.seconds) {
        titles[k] = v;
      }
    });
  }

  void prune(int maxTitles) {
    if (titles.length <= maxTitles) return;
    final sorted = titles.entries.toList()
      ..sort((a, b) => b.value.seconds.compareTo(a.value.seconds));
    titles
      ..clear()
      ..addEntries(sorted.take(maxTitles));
  }

  Map<String, dynamic> toMap() => {
        'year': year,
        'totalSeconds': totalSeconds,
        'totalSessions': totalSessions,
        'titles': titles.values.map((e) => e.toJson()).toList(),
        'categorySeconds': categorySeconds,
        'hourBuckets': hourBuckets.map((k, v) => MapEntry(k.toString(), v)),
        'activeDays': activeDays.toList(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

  String toJsonString() => jsonEncode(toMap());

  factory _TvYearBucket.fromJsonString(int year, String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return _TvYearBucket.fromMap(year, m);
    } catch (_) {
      return _TvYearBucket(year);
    }
  }

  factory _TvYearBucket.fromMap(int year, Map<String, dynamic> m) {
    final b = _TvYearBucket(year)
      ..totalSeconds = (m['totalSeconds'] as num?)?.toInt() ?? 0
      ..totalSessions = (m['totalSessions'] as num?)?.toInt() ?? 0;
    final rawTitles = m['titles'];
    if (rawTitles is List) {
      for (final t in rawTitles) {
        if (t is Map) {
          final st = TvWrappedTitleStat.fromJson(t.cast<String, dynamic>());
          if (st.id.isNotEmpty) b.titles[st.id] = st;
        }
      }
    }
    final rawCats = m['categorySeconds'];
    if (rawCats is Map) {
      rawCats.forEach((k, v) {
        b.categorySeconds[k.toString()] = (v as num?)?.toInt() ?? 0;
      });
    }
    final rawHours = m['hourBuckets'];
    if (rawHours is Map) {
      rawHours.forEach((k, v) {
        final h = int.tryParse(k.toString());
        if (h != null) b.hourBuckets[h] = (v as num?)?.toInt() ?? 0;
      });
    }
    final rawDays = m['activeDays'];
    if (rawDays is List) {
      b.activeDays.addAll(rawDays.map((e) => e.toString()));
    }
    return b;
  }
}
