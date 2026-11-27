import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import 'inutil_cloud_backup_service.dart';

/// Registro de reproducción local ("Seguir viendo"), al estilo Netflix.
/// Guarda progreso exacto por título (y episodio activo en Series/Anime)
/// para reanudar exactamente donde te quedaste aunque se cierre la app.
class WatchProgress {
  final String id;
  final String title;
  final String poster;
  final String backdrop;
  final String year;
  final String genre;
  final String slug;
  final String provider;
  final bool isSeries;
  final bool isAnime;
  final double positionSec;
  final double durationSec;
  final int seasonNumber;
  final int episodeNumber;
  final String episodeTitle;
  final int updatedAt;

  const WatchProgress({
    required this.id,
    required this.title,
    this.poster = '',
    this.backdrop = '',
    this.year = '',
    this.genre = '',
    this.slug = '',
    this.provider = '',
    this.isSeries = false,
    this.isAnime = false,
    this.positionSec = 0,
    this.durationSec = 0,
    this.seasonNumber = 1,
    this.episodeNumber = 1,
    this.episodeTitle = '',
    this.updatedAt = 0,
  });

  /// Fracción vista 0.0 – 1.0 (mínimo visible 0.03 para que la barra se note).
  double get fraction {
    if (durationSec <= 0) return 0.05;
    return (positionSec / durationSec).clamp(0.03, 0.99).toDouble();
  }

  bool get finished => durationSec > 0 && positionSec / durationSec > 0.93;

  String get label {
    final epPrefix = isSeries ? 'T$seasonNumber·E$episodeNumber · ' : '';
    if (durationSec <= 0) return '${epPrefix}Viendo';
    final left = ((durationSec - positionSec) / 60).round();
    if (left <= 0) return '${epPrefix}Casi terminada';
    return '${epPrefix}Quedan $left min';
  }

  /// Reconstruye el item para volver a abrir su detalle/reproductor.
  VodItem toVodItem() => VodItem(
        id: id,
        title: title,
        poster: poster,
        backdrop: backdrop,
        year: year,
        genre: genre,
        slug: slug,
        provider: provider,
        isSeries: isSeries,
        isAnime: isAnime,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'poster': poster,
        'backdrop': backdrop,
        'year': year,
        'genre': genre,
        'slug': slug,
        'provider': provider,
        'isSeries': isSeries,
        'isAnime': isAnime,
        'positionSec': positionSec,
        'durationSec': durationSec,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'episodeTitle': episodeTitle,
        'updatedAt': updatedAt,
      };

  factory WatchProgress.fromJson(Map<String, dynamic> j) => WatchProgress(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        poster: j['poster'] as String? ?? '',
        backdrop: j['backdrop'] as String? ?? '',
        year: j['year'] as String? ?? '',
        genre: j['genre'] as String? ?? '',
        slug: j['slug'] as String? ?? '',
        provider: j['provider'] as String? ?? '',
        isSeries: j['isSeries'] as bool? ?? false,
        isAnime: j['isAnime'] as bool? ?? false,
        positionSec: (j['positionSec'] as num?)?.toDouble() ?? 0,
        durationSec: (j['durationSec'] as num?)?.toDouble() ?? 0,
        seasonNumber: (j['seasonNumber'] as num?)?.toInt() ?? 1,
        episodeNumber: (j['episodeNumber'] as num?)?.toInt() ?? 1,
        episodeTitle: j['episodeTitle'] as String? ?? '',
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

class WatchHistory extends ChangeNotifier {
  static final WatchHistory _instance = WatchHistory._internal();
  factory WatchHistory() => _instance;
  WatchHistory._internal();

  static const _key = 'inutiltv_watch_history_v1';
  static const _watchedEpsKey = 'inutiltv_watched_episodes_v1';
  static const _maxEntries = 120;

  List<WatchProgress> _cache = [];
  Map<String, Set<String>> _watchedEpisodes = {};
  bool _loaded = false;

  /// Historial ordenado del más reciente al más antiguo.
  List<WatchProgress> get items => List.unmodifiable(_cache);

  /// Copia de solo lectura de episodios marcados como vistos por `seriesId`.
  Map<String, Set<String>> get watchedEpisodesSnapshot => {
        for (final e in _watchedEpisodes.entries)
          e.key: Set<String>.unmodifiable(e.value),
      };

  Future<void> load() async {
    if (_loaded) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List)
            .map((e) => WatchProgress.fromJson(e as Map<String, dynamic>))
            .where((p) => p.id.isNotEmpty && p.title.isNotEmpty)
            .toList();
        list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        _cache = list.take(_maxEntries).toList();
      } else {
        _cache = [];
      }
      final rawEps = sp.getString(_watchedEpsKey);
      if (rawEps != null && rawEps.isNotEmpty) {
        final map = jsonDecode(rawEps) as Map<String, dynamic>;
        _watchedEpisodes = map.map(
          (k, v) => MapEntry(k, (v as List).map((e) => e.toString()).toSet()),
        );
      } else {
        _watchedEpisodes = {};
      }
    } catch (_) {
      _cache = [];
      _watchedEpisodes = {};
    }
    _loaded = true;
    notifyListeners();
  }

  /// Devuelve el progreso guardado de un título (o null si no existe).
  WatchProgress? progressFor(String id) {
    for (final p in _cache) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Comprueba si un episodio específico ya fue marcado como visto.
  bool isEpisodeWatched(String seriesId, int season, int episode) {
    final set = _watchedEpisodes[seriesId];
    if (set == null) return false;
    return set.contains('${season}x$episode');
  }

  /// Marca un episodio como visto (se dispara automáticamente al superar 85%).
  Future<void> markEpisodeWatched(String seriesId, int season, int episode) async {
    await load();
    if (seriesId.isEmpty) return;
    final set = _watchedEpisodes.putIfAbsent(seriesId, () => <String>{});
    if (set.add('${season}x$episode')) {
      notifyListeners();
      await _persistWatchedEpisodes();
    }
  }

  /// Registra/actualiza el progreso exacto de un título VOD.
  Future<void> record(
    VodItem item, {
    double positionSec = 0,
    double durationSec = 0,
    int seasonNumber = 1,
    int episodeNumber = 1,
    String episodeTitle = '',
  }) async {
    await load();
    if (item.id.isEmpty || item.title.isEmpty) return;

    // Ignora aperturas menores a 5 segundos si ya existía progreso mayor
    if (positionSec < 5 && durationSec > 0 && positionSec < durationSec * 0.02) {
      final existing = progressFor(item.id);
      if (existing != null && existing.positionSec >= 5) return;
    }

    if (item.isSeries && durationSec > 0 && (positionSec / durationSec) >= 0.85) {
      final set = _watchedEpisodes.putIfAbsent(item.id, () => <String>{});
      set.add('${seasonNumber}x$episodeNumber');
      await _persistWatchedEpisodes();
    }

    final entry = WatchProgress(
      id: item.id,
      title: item.title,
      poster: item.poster,
      backdrop: item.backdrop.isNotEmpty ? item.backdrop : item.poster,
      year: item.year,
      genre: item.genre,
      slug: item.slug,
      provider: item.provider,
      isSeries: item.isSeries,
      isAnime: item.isAnime,
      positionSec: positionSec,
      durationSec: durationSec,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeTitle: episodeTitle,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    _cache.removeWhere((p) => p.id == item.id);
    _cache.insert(0, entry);
    if (_cache.length > _maxEntries) _cache = _cache.take(_maxEntries).toList();
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    await load();
    _cache.removeWhere((p) => p.id == id);
    notifyListeners();
    await _persist();
  }

  Future<void> clear() async {
    _cache = [];
    _watchedEpisodes = {};
    notifyListeners();
    await _persist();
    await _persistWatchedEpisodes();
  }

  Future<void> reloadFromDisk() async {
    _loaded = false;
    await load();
  }

  Future<void> _persist() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _key,
        jsonEncode(_cache.map((p) => p.toJson()).toList()),
      );
      InutilTvCloudBackupService.instance.schedulePush();
    } catch (_) {}
  }

  Future<void> _persistWatchedEpisodes() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final encoded = _watchedEpisodes.map((k, v) => MapEntry(k, v.toList()));
      await sp.setString(_watchedEpsKey, jsonEncode(encoded));
      InutilTvCloudBackupService.instance.schedulePush();
    } catch (_) {}
  }
}
