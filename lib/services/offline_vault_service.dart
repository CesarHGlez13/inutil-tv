import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'hls_stream_proxy.dart';
import 'network_config_service.dart';
import 'stream_validator.dart';
import 'vault_crypto.dart';
import 'vod_catalog_service.dart';

enum DownloadStatus {
  queued,
  resolving,
  downloading,
  paused,
  completed,
  failed,
}

enum DownloadQuality {
  high('high', 'Máxima HD'),
  balanced('balanced', 'Equilibrada (Ahorro)');

  const DownloadQuality(this.code, this.label);
  final String code;
  final String label;

  static DownloadQuality fromCode(String? raw) =>
      raw == 'balanced' ? DownloadQuality.balanced : DownloadQuality.high;
}

@immutable
class VaultSubtitleMeta {
  final String label;
  final String language;
  final int index;

  const VaultSubtitleMeta({
    required this.label,
    required this.language,
    required this.index,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'language': language,
        'index': index,
      };

  factory VaultSubtitleMeta.fromJson(Map<String, dynamic> j) =>
      VaultSubtitleMeta(
        label: (j['label'] ?? 'Español').toString(),
        language: (j['language'] ?? 'es').toString(),
        index: (j['index'] as num?)?.toInt() ?? 0,
      );
}

@immutable
class OfflineDownloadItem {
  final String id;
  final String itemId;
  final String title;
  final String overview;
  final String year;
  final String genre;
  final bool isSeries;
  final bool isAnime;
  final String provider;
  final String slug;
  final String remotePosterUrl;
  final String localPosterPath;
  final int seasonNumber;
  final int episodeNumber;
  final String episodeTitle;
  final String mediaKind; // 'hls' | 'mp4'
  final String vaultDirName;
  final DownloadStatus status;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final int segmentsDone;
  final int segmentsTotal;
  final double speedBytesPerSec;
  final String resolvedStreamUrl;
  final Map<String, String> resolvedHeaders;
  final List<VaultSubtitleMeta> localSubtitles;
  final String qualityLabel;
  final String errorMessage;
  final int createdAtMs;
  final int completedAtMs;

  const OfflineDownloadItem({
    required this.id,
    required this.itemId,
    required this.title,
    this.overview = '',
    this.year = '',
    this.genre = '',
    this.isSeries = false,
    this.isAnime = false,
    this.provider = '',
    this.slug = '',
    this.remotePosterUrl = '',
    this.localPosterPath = '',
    this.seasonNumber = 1,
    this.episodeNumber = 1,
    this.episodeTitle = '',
    this.mediaKind = 'hls',
    required this.vaultDirName,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.segmentsDone = 0,
    this.segmentsTotal = 0,
    this.speedBytesPerSec = 0,
    this.resolvedStreamUrl = '',
    this.resolvedHeaders = const {},
    this.localSubtitles = const [],
    this.qualityLabel = 'HD',
    this.errorMessage = '',
    this.createdAtMs = 0,
    this.completedAtMs = 0,
  });

  bool get isCompleted => status == DownloadStatus.completed;
  bool get isActive =>
      status == DownloadStatus.downloading ||
      status == DownloadStatus.resolving ||
      status == DownloadStatus.queued;

  String get displaySubtitle {
    if (isSeries) {
      final epPart = isAnime
          ? 'Ep. $episodeNumber'
          : 'T$seasonNumber · Ep. $episodeNumber';
      return episodeTitle.isNotEmpty ? '$epPart — $episodeTitle' : epPart;
    }
    return [if (year.isNotEmpty) year, if (genre.isNotEmpty) genre].join(' · ');
  }

  VodItem toVodItem() => VodItem(
        id: itemId,
        title: title,
        poster: remotePosterUrl,
        backdrop: remotePosterUrl,
        overview: overview,
        year: year,
        genre: genre,
        isSeries: isSeries,
        isAnime: isAnime,
        slug: slug,
        provider: provider,
        quality: qualityLabel,
      );

  VodEpisode toVodEpisode() => VodEpisode(
        id: id,
        title: episodeTitle.isNotEmpty ? episodeTitle : 'Episodio $episodeNumber',
        episodeNumber: episodeNumber,
        seasonNumber: seasonNumber,
        provider: provider,
        slug: slug,
      );

  OfflineDownloadItem copyWith({
    String? localPosterPath,
    String? mediaKind,
    DownloadStatus? status,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    int? segmentsDone,
    int? segmentsTotal,
    double? speedBytesPerSec,
    String? resolvedStreamUrl,
    Map<String, String>? resolvedHeaders,
    List<VaultSubtitleMeta>? localSubtitles,
    String? qualityLabel,
    String? errorMessage,
    int? completedAtMs,
  }) {
    return OfflineDownloadItem(
      id: id,
      itemId: itemId,
      title: title,
      overview: overview,
      year: year,
      genre: genre,
      isSeries: isSeries,
      isAnime: isAnime,
      provider: provider,
      slug: slug,
      remotePosterUrl: remotePosterUrl,
      localPosterPath: localPosterPath ?? this.localPosterPath,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeTitle: episodeTitle,
      mediaKind: mediaKind ?? this.mediaKind,
      vaultDirName: vaultDirName,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      segmentsDone: segmentsDone ?? this.segmentsDone,
      segmentsTotal: segmentsTotal ?? this.segmentsTotal,
      speedBytesPerSec: speedBytesPerSec ?? this.speedBytesPerSec,
      resolvedStreamUrl: resolvedStreamUrl ?? this.resolvedStreamUrl,
      resolvedHeaders: resolvedHeaders ?? this.resolvedHeaders,
      localSubtitles: localSubtitles ?? this.localSubtitles,
      qualityLabel: qualityLabel ?? this.qualityLabel,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAtMs: createdAtMs,
      completedAtMs: completedAtMs ?? this.completedAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'itemId': itemId,
        'title': title,
        'overview': overview,
        'year': year,
        'genre': genre,
        'isSeries': isSeries,
        'isAnime': isAnime,
        'provider': provider,
        'slug': slug,
        'remotePosterUrl': remotePosterUrl,
        'localPosterPath': localPosterPath,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'episodeTitle': episodeTitle,
        'mediaKind': mediaKind,
        'vaultDirName': vaultDirName,
        'status': status.name,
        'progress': progress,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'segmentsDone': segmentsDone,
        'segmentsTotal': segmentsTotal,
        'resolvedStreamUrl': resolvedStreamUrl,
        'resolvedHeaders': resolvedHeaders,
        'localSubtitles': localSubtitles.map((s) => s.toJson()).toList(),
        'qualityLabel': qualityLabel,
        'errorMessage': errorMessage,
        'createdAtMs': createdAtMs,
        'completedAtMs': completedAtMs,
      };

  factory OfflineDownloadItem.fromJson(Map<String, dynamic> j) {
    final rawStatus = (j['status'] ?? 'paused').toString();
    var parsedStatus = DownloadStatus.values.firstWhere(
      (s) => s.name == rawStatus,
      orElse: () => DownloadStatus.paused,
    );
    // Si la app se cerró mientras descargaba, arranca pausado listo para reanudar
    if (parsedStatus == DownloadStatus.downloading ||
        parsedStatus == DownloadStatus.resolving ||
        parsedStatus == DownloadStatus.queued) {
      parsedStatus = DownloadStatus.paused;
    }

    final rawHeaders = j['resolvedHeaders'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v.toString());
    }

    final rawSubs = j['localSubtitles'];
    final subs = <VaultSubtitleMeta>[];
    if (rawSubs is List) {
      for (final s in rawSubs) {
        if (s is Map) {
          subs.add(VaultSubtitleMeta.fromJson(s.cast<String, dynamic>()));
        }
      }
    }

    return OfflineDownloadItem(
      id: (j['id'] ?? '').toString(),
      itemId: (j['itemId'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      overview: (j['overview'] ?? '').toString(),
      year: (j['year'] ?? '').toString(),
      genre: (j['genre'] ?? '').toString(),
      isSeries: j['isSeries'] == true,
      isAnime: j['isAnime'] == true,
      provider: (j['provider'] ?? '').toString(),
      slug: (j['slug'] ?? '').toString(),
      remotePosterUrl: (j['remotePosterUrl'] ?? '').toString(),
      localPosterPath: (j['localPosterPath'] ?? '').toString(),
      seasonNumber: (j['seasonNumber'] as num?)?.toInt() ?? 1,
      episodeNumber: (j['episodeNumber'] as num?)?.toInt() ?? 1,
      episodeTitle: (j['episodeTitle'] ?? '').toString(),
      mediaKind: (j['mediaKind'] ?? 'hls').toString(),
      vaultDirName: (j['vaultDirName'] ?? '').toString(),
      status: parsedStatus,
      progress: (j['progress'] as num?)?.toDouble() ?? 0.0,
      downloadedBytes: (j['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (j['totalBytes'] as num?)?.toInt() ?? 0,
      segmentsDone: (j['segmentsDone'] as num?)?.toInt() ?? 0,
      segmentsTotal: (j['segmentsTotal'] as num?)?.toInt() ?? 0,
      resolvedStreamUrl: (j['resolvedStreamUrl'] ?? '').toString(),
      resolvedHeaders: headers,
      localSubtitles: subs,
      qualityLabel: (j['qualityLabel'] ?? 'HD').toString(),
      errorMessage: (j['errorMessage'] ?? '').toString(),
      createdAtMs: (j['createdAtMs'] as num?)?.toInt() ?? 0,
      completedAtMs: (j['completedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class VaultPlaybackHandle {
  final String sessionId;
  final String localUrl;
  final List<SubtitleSource> subtitles;
  final OfflineDownloadItem item;

  const VaultPlaybackHandle({
    required this.sessionId,
    required this.localUrl,
    required this.subtitles,
    required this.item,
  });
}

/// Bóveda Offline Cifrada de InútilTV v3.2.
///
/// - **100 % privada e invisible para la Galería:** vive dentro del sandbox
///   interno (`ApplicationSupportDirectory/inutil_vault/`), incluye centinela
///   `.nomedia`, usa extensión opaca `.ivlt` y cifra cada película/episodio con
///   **AES-256-CTR** con clave única por título.
/// - **Soporte universal HLS + MP4:** descarga segmentos HLS en lotes paralelos
///   de 4 (recortando cabeceras PNG falsas antes de cifrar) y MP4 por rangos
///   con pausa/reanudación real sin perder progreso.
/// - **Reproducción instantánea sin internet:** descifra al vuelo en RAM a través
///   de [HlsStreamProxy] (`127.0.0.1`) con soporte total de scrubbing (`206`),
///   subtítulos offline y portadas cacheadas.
class OfflineVaultService extends ChangeNotifier {
  OfflineVaultService._();
  static final OfflineVaultService instance = OfflineVaultService._();

  static const _metaKey = 'inutiltv_offline_vault_items_v1';
  static const _keysFallbackPrefix = 'inutiltv_vault_k_v1_';
  static const _qualityKey = 'inutiltv_offline_quality_v1';
  static const _autoDeleteKey = 'inutiltv_offline_auto_delete_v1';
  static const Duration _secureTimeout = Duration(seconds: 2);

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true, migrateOnAlgorithmChange: true),
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );

  @visibleForTesting
  Directory? testVaultRoot;

  @visibleForTesting
  Future<List<StreamSource>> Function(VodItem item, VodEpisode? ep)?
      testSourceResolver;

  bool _loaded = false;
  Directory? _vaultRoot;
  final List<OfflineDownloadItem> _items = [];
  final Set<String> _pausedOrCancelledIds = {};
  bool _processingQueue = false;
  DownloadQuality _quality = DownloadQuality.high;
  bool _autoDeleteWatched = false;

  List<OfflineDownloadItem> get items => List.unmodifiable(_items);
  List<OfflineDownloadItem> get completedItems =>
      _items.where((i) => i.isCompleted).toList(growable: false);
  List<OfflineDownloadItem> get activeOrQueuedItems => _items
      .where((i) =>
          i.status == DownloadStatus.downloading ||
          i.status == DownloadStatus.resolving ||
          i.status == DownloadStatus.queued ||
          i.status == DownloadStatus.paused ||
          i.status == DownloadStatus.failed)
      .toList(growable: false);

  int get activeCount => _items.where((i) => i.isActive).length;
  int get completedCount => _items.where((i) => i.isCompleted).length;
  DownloadQuality get quality => _quality;
  bool get autoDeleteWatched => _autoDeleteWatched;

  int get totalVaultBytes =>
      _items.fold<int>(0, (sum, i) => sum + i.downloadedBytes);

  static String idForMovie(String itemId) => 'mv_$itemId';

  static String idForEpisode(String itemId, int season, int episode) =>
      'ep_${itemId}_s${season}_e$episode';

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> initialize({bool force = false}) async {
    if (_loaded && !force) return;
    await _ensureVaultRoot();
    try {
      final sp = await SharedPreferences.getInstance();
      _quality = DownloadQuality.fromCode(sp.getString(_qualityKey));
      _autoDeleteWatched = sp.getBool(_autoDeleteKey) ?? false;

      final raw = sp.getString(_metaKey);
      _items.clear();
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        for (final entry in list) {
          if (entry is Map) {
            final item =
                OfflineDownloadItem.fromJson(entry.cast<String, dynamic>());
            if (item.id.isNotEmpty) _items.add(item);
          }
        }
      }
    } catch (e) {
      debugPrint('[OfflineVault] Load err: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setQuality(DownloadQuality value) async {
    if (_quality == value) return;
    _quality = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_qualityKey, value.code);
    } catch (_) {}
  }

  Future<void> setAutoDeleteWatched(bool value) async {
    if (_autoDeleteWatched == value) return;
    _autoDeleteWatched = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_autoDeleteKey, value);
    } catch (_) {}
  }

  OfflineDownloadItem? findById(String downloadId) {
    for (final it in _items) {
      if (it.id == downloadId) return it;
    }
    return null;
  }

  OfflineDownloadItem? findForMovie(String itemId) =>
      findById(idForMovie(itemId));

  OfflineDownloadItem? findForEpisode(
    String itemId,
    int seasonNumber,
    int episodeNumber,
  ) =>
      findById(idForEpisode(itemId, seasonNumber, episodeNumber));

  OfflineDownloadItem? findCompletedMovie(String itemId) {
    final hit = findForMovie(itemId);
    return (hit != null && hit.isCompleted) ? hit : null;
  }

  OfflineDownloadItem? findCompletedEpisode(
    String itemId,
    int seasonNumber,
    int episodeNumber,
  ) {
    final hit = findForEpisode(itemId, seasonNumber, episodeNumber);
    return (hit != null && hit.isCompleted) ? hit : null;
  }

  /// Devuelve episodios descargados de una serie ordenados por temporada y episodio.
  List<OfflineDownloadItem> completedEpisodesForSeries(String itemId) {
    final list = _items
        .where((i) => i.isSeries && i.itemId == itemId && i.isCompleted)
        .toList();
    list.sort((a, b) {
      if (a.seasonNumber != b.seasonNumber) {
        return a.seasonNumber.compareTo(b.seasonNumber);
      }
      return a.episodeNumber.compareTo(b.episodeNumber);
    });
    return list;
  }

  /// Agrupa series/animes descargados por `itemId` para la vista de Descargas.
  Map<String, List<OfflineDownloadItem>> groupedCompletedSeries() {
    final map = <String, List<OfflineDownloadItem>>{};
    for (final it in completedItems.where((e) => e.isSeries)) {
      map.putIfAbsent(it.itemId, () => []).add(it);
    }
    for (final eps in map.values) {
      eps.sort((a, b) {
        if (a.seasonNumber != b.seasonNumber) {
          return a.seasonNumber.compareTo(b.seasonNumber);
        }
        return a.episodeNumber.compareTo(b.episodeNumber);
      });
    }
    return map;
  }

  /// Encola la descarga cifrada de una película.
  Future<OfflineDownloadItem> enqueueMovie(VodItem item) async {
    await initialize();
    final id = idForMovie(item.id);
    final existing = findById(id);
    if (existing != null) {
      if (existing.isCompleted || existing.isActive) return existing;
      return resumeDownload(id);
    }

    final dirName = _safeDirName(id);
    final entry = OfflineDownloadItem(
      id: id,
      itemId: item.id,
      title: item.title,
      overview: item.overview,
      year: item.year,
      genre: item.genre,
      isSeries: false,
      isAnime: item.isAnime,
      provider: item.provider,
      slug: item.slug,
      remotePosterUrl: item.poster.isNotEmpty ? item.poster : item.backdrop,
      vaultDirName: dirName,
      status: DownloadStatus.queued,
      qualityLabel: _quality == DownloadQuality.high ? 'HD' : 'Ahorro',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    _items.insert(0, entry);
    _pausedOrCancelledIds.remove(id);
    await _persistMeta();
    notifyListeners();
    unawaited(_processQueue());
    return entry;
  }

  /// Encola la descarga cifrada de un episodio de Serie o Anime.
  Future<OfflineDownloadItem> enqueueEpisode(
    VodItem item,
    VodEpisode episode,
  ) async {
    await initialize();
    final id =
        idForEpisode(item.id, episode.seasonNumber, episode.episodeNumber);
    final existing = findById(id);
    if (existing != null) {
      if (existing.isCompleted || existing.isActive) return existing;
      return resumeDownload(id);
    }

    final dirName = _safeDirName(id);
    final entry = OfflineDownloadItem(
      id: id,
      itemId: item.id,
      title: item.title,
      overview: item.overview,
      year: item.year,
      genre: item.genre,
      isSeries: true,
      isAnime: item.isAnime,
      provider: item.provider,
      slug: item.slug,
      remotePosterUrl: item.poster.isNotEmpty ? item.poster : item.backdrop,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      episodeTitle: episode.title,
      vaultDirName: dirName,
      status: DownloadStatus.queued,
      qualityLabel: _quality == DownloadQuality.high ? 'HD' : 'Ahorro',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    _items.insert(0, entry);
    _pausedOrCancelledIds.remove(id);
    await _persistMeta();
    notifyListeners();
    unawaited(_processQueue());
    return entry;
  }

  /// Descarga por lotes (p. ej. "Descargar temporada" o "Próximos 3 episodios").
  Future<int> enqueueEpisodesBatch(
    VodItem item,
    List<VodEpisode> episodes,
  ) async {
    await initialize();
    var added = 0;
    for (final ep in episodes) {
      final id = idForEpisode(item.id, ep.seasonNumber, ep.episodeNumber);
      final existing = findById(id);
      if (existing != null && (existing.isCompleted || existing.isActive)) {
        continue;
      }
      await enqueueEpisode(item, ep);
      added++;
    }
    return added;
  }

  /// Pausa una descarga en curso conservando todos los bloques cifrados en disco.
  Future<void> pauseDownload(String downloadId) async {
    _pausedOrCancelledIds.add(downloadId);
    final idx = _items.indexWhere((i) => i.id == downloadId);
    if (idx >= 0 && !_items[idx].isCompleted) {
      _items[idx] = _items[idx].copyWith(
        status: DownloadStatus.paused,
        speedBytesPerSec: 0,
      );
      await _persistMeta();
      notifyListeners();
    }
  }

  /// Reanuda una descarga pausada o fallida exactamente donde se quedó.
  Future<OfflineDownloadItem> resumeDownload(String downloadId) async {
    await initialize();
    _pausedOrCancelledIds.remove(downloadId);
    final idx = _items.indexWhere((i) => i.id == downloadId);
    if (idx < 0) {
      throw StateError('Descarga no encontrada: $downloadId');
    }
    if (!_items[idx].isCompleted) {
      _items[idx] = _items[idx].copyWith(
        status: DownloadStatus.queued,
        errorMessage: '',
      );
      await _persistMeta();
      notifyListeners();
      unawaited(_processQueue());
    }
    return _items[idx];
  }

  /// Elimina completamente una descarga (archivos cifrados `.ivlt`, clave y metadatos).
  Future<void> deleteDownload(String downloadId) async {
    await initialize();
    _pausedOrCancelledIds.add(downloadId);
    final idx = _items.indexWhere((i) => i.id == downloadId);
    if (idx < 0) return;
    final target = _items.removeAt(idx);
    await _persistMeta();
    notifyListeners();

    try {
      final dir = await _dirFor(target.vaultDirName);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await _deleteKeyMaterial(target.id);
    } catch (e) {
      debugPrint('[OfflineVault] Delete dir err: $e');
    }
  }

  /// Vacía toda la bóveda offline.
  Future<void> deleteAllDownloads() async {
    await initialize();
    final ids = _items.map((e) => e.id).toList();
    for (final id in ids) {
      await deleteDownload(id);
    }
  }

  /// Si `autoDeleteWatched` está activo, libera el archivo al terminar de verlo.
  Future<void> onPlaybackCompleted({
    required String itemId,
    bool isSeries = false,
    int seasonNumber = 1,
    int episodeNumber = 1,
  }) async {
    if (!_autoDeleteWatched) return;
    final id = isSeries
        ? idForEpisode(itemId, seasonNumber, episodeNumber)
        : idForMovie(itemId);
    final found = findById(id);
    if (found != null && found.isCompleted) {
      await deleteDownload(id);
    }
  }

  /// Abre una sesión segura de reproducción OFFLINE sobre `127.0.0.1`
  /// descifrando al vuelo desde la bóveda AES-256-CTR (0 bytes en claro en disco).
  Future<VaultPlaybackHandle?> openVaultPlayback(
    OfflineDownloadItem entry,
  ) async {
    await initialize();
    if (!entry.isCompleted) return null;
    final keys = await _loadKeyMaterial(entry.id);
    if (keys == null) return null;

    final dir = await _dirFor(entry.vaultDirName);
    if (!await dir.exists()) return null;

    final reg = await HlsStreamProxy.instance.registerVaultSession(
      vaultDir: dir,
      key32: keys.key32,
      nonce16: keys.nonce16,
      isMp4: entry.mediaKind == 'mp4',
      subtitleCount: entry.localSubtitles.length,
    );

    final subs = <SubtitleSource>[];
    for (var i = 0; i < entry.localSubtitles.length; i++) {
      final meta = entry.localSubtitles[i];
      if (i < reg.subtitleUrls.length) {
        subs.add(SubtitleSource(
          url: reg.subtitleUrls[i],
          label: meta.label,
          language: meta.language,
        ));
      }
    }

    return VaultPlaybackHandle(
      sessionId: reg.sessionId,
      localUrl: reg.localUrl,
      subtitles: subs,
      item: entry,
    );
  }

  // ── Motor de cola y descarga cifrada ───────────────────────────────────────

  Future<void> _processQueue() async {
    if (_processingQueue) return;
    _processingQueue = true;
    try {
      while (true) {
        final nextIdx =
            _items.indexWhere((i) => i.status == DownloadStatus.queued);
        if (nextIdx < 0) break;
        final id = _items[nextIdx].id;
        await _executeDownload(id);
      }
    } finally {
      _processingQueue = false;
    }
  }

  Future<void> _executeDownload(String downloadId) async {
    bool stopped() =>
        _pausedOrCancelledIds.contains(downloadId) ||
        !_items.any((i) => i.id == downloadId);

    void update(OfflineDownloadItem Function(OfflineDownloadItem cur) fn) {
      final i = _items.indexWhere((e) => e.id == downloadId);
      if (i < 0) return;
      _items[i] = fn(_items[i]);
      notifyListeners();
    }

    OfflineDownloadItem? current() => findById(downloadId);

    try {
      var item = current();
      if (item == null || stopped()) return;

      final dir = await _dirFor(item.vaultDirName);
      if (!await dir.exists()) await dir.create(recursive: true);

      // Generar o recuperar clave única AES-256-CTR + nonce de 128 bits
      final keys = await _getOrCreateKeyMaterial(downloadId);

      // Cachear póster en la bóveda privada (.nomedia) para 100% modo avión
      if (item.localPosterPath.isEmpty && item.remotePosterUrl.startsWith('http')) {
        final localPoster = await _cachePosterLocally(dir, item.remotePosterUrl);
        if (localPoster != null) {
          update((c) => c.copyWith(localPosterPath: localPoster));
          await _persistMeta();
        }
      }

      // 1. Resolver fuente verificada (o reutilizar la ya resuelta al reanudar)
      item = current();
      if (item == null || stopped()) return;

      StreamSource? chosen;
      if (item.resolvedStreamUrl.startsWith('http')) {
        chosen = StreamSource(
          url: item.resolvedStreamUrl,
          quality: item.qualityLabel,
          headers: item.resolvedHeaders,
        );
      } else {
        update((c) => c.copyWith(
              status: DownloadStatus.resolving,
              errorMessage: '',
            ));
        final vodItem = item.toVodItem();
        final ep = item.isSeries ? item.toVodEpisode() : null;
        final sources = testSourceResolver != null
            ? await testSourceResolver!(vodItem, ep)
            : await VodCatalogService().resolveAllPlaybackSources(vodItem, ep);

        if (stopped()) return;
        if (sources.isEmpty) {
          update((c) => c.copyWith(
                status: DownloadStatus.failed,
                errorMessage: 'Sin servidores disponibles para descargar ahora.',
                speedBytesPerSec: 0,
              ));
          await _persistMeta();
          return;
        }
        chosen = sources.first;
      }

      if (stopped()) return;

      // Descargar y cifrar subtítulos externos si existen
      final savedSubs = <VaultSubtitleMeta>[];
      if (chosen.subtitles.isNotEmpty) {
        for (var si = 0; si < chosen.subtitles.length && si < 3; si++) {
          final sub = chosen.subtitles[si];
          final ok = await _downloadAndEncryptFile(
            url: sub.url,
            headers: chosen.headers,
            outFile: File('${dir.path}/sub_$si.ivlt'),
            key32: keys.key32,
            nonce16: VaultCrypto.deriveSegmentNonce(
              keys.nonce16,
              HlsStreamProxy.vaultSubNonceBase + si,
            ),
          );
          if (ok) {
            savedSubs.add(VaultSubtitleMeta(
              label: sub.label.isNotEmpty ? sub.label : 'Español',
              language: sub.language.isNotEmpty ? sub.language : 'es',
              index: si,
            ));
          }
        }
      }

      final lowerUrl = chosen.url.toLowerCase();
      final isHls = lowerUrl.contains('.m3u8') ||
          lowerUrl.contains('/hls/') ||
          lowerUrl.contains('master.txt') ||
          StreamValidator.needsLocalHlsProxy(chosen.url);
      update((c) => c.copyWith(
            status: DownloadStatus.downloading,
            mediaKind: isHls ? 'hls' : 'mp4',
            resolvedStreamUrl: chosen!.url,
            resolvedHeaders: chosen.headers,
            localSubtitles: savedSubs.isNotEmpty ? savedSubs : c.localSubtitles,
          ));
      await _persistMeta();

      final ok = isHls
          ? await _downloadHlsToVault(
              downloadId: downloadId,
              dir: dir,
              streamUrl: chosen.url,
              headers: chosen.headers,
              key32: keys.key32,
              nonce16: keys.nonce16,
              stopped: stopped,
              update: update,
            )
          : await _downloadMp4ToVault(
              downloadId: downloadId,
              dir: dir,
              streamUrl: chosen.url,
              headers: chosen.headers,
              key32: keys.key32,
              nonce16: keys.nonce16,
              stopped: stopped,
              update: update,
            );

      if (stopped()) {
        await _persistMeta();
        return;
      }

      if (ok) {
        update((c) => c.copyWith(
              status: DownloadStatus.completed,
              progress: 1.0,
              speedBytesPerSec: 0,
              completedAtMs: DateTime.now().millisecondsSinceEpoch,
              errorMessage: '',
            ));
      } else {
        update((c) => c.copyWith(
              status: DownloadStatus.failed,
              speedBytesPerSec: 0,
              errorMessage: c.errorMessage.isNotEmpty
                  ? c.errorMessage
                  : 'Descarga interrumpida. Toca para reanudar.',
            ));
      }
      await _persistMeta();
    } catch (e) {
      debugPrint('[OfflineVault] Download err ($downloadId): $e');
      if (!stopped()) {
        update((c) => c.copyWith(
              status: DownloadStatus.failed,
              speedBytesPerSec: 0,
              errorMessage: 'Error de red durante la descarga. Reintenta.',
            ));
        await _persistMeta();
      }
    }
  }

  /// Descarga un flujo HLS completo en lotes paralelos de 4 segmentos,
  /// recortando cabeceras PNG falsas y cifrando cada segmento con AES-256-CTR.
  /// Soporta pausa y reanudación exacta saltando segmentos ya guardados.
  Future<bool> _downloadHlsToVault({
    required String downloadId,
    required Directory dir,
    required String streamUrl,
    required Map<String, String> headers,
    required Uint8List key32,
    required Uint8List nonce16,
    required bool Function() stopped,
    required void Function(OfflineDownloadItem Function(OfflineDownloadItem))
        update,
  }) async {
    // 1. Obtener playlist master o media
    final firstRes = await _fetchBytes(streamUrl, headers);
    if (firstRes == null || stopped()) return false;

    var mediaText = utf8.decode(firstRes.bytes, allowMalformed: true);
    var mediaBaseUri = firstRes.finalUri;
    if (!mediaText.contains('#EXTM3U')) return false;

    // Si es master con variantes, elegir la calidad según preferencia del usuario
    if (mediaText.contains('#EXT-X-STREAM-INF')) {
      final variants = _parseMasterVariants(mediaText, mediaBaseUri);
      if (variants.isEmpty) return false;
      variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
      final chosenVariant = _quality == DownloadQuality.balanced &&
              variants.length > 1
          ? variants[variants.length ~/ 2]
          : variants.first;

      final varRes = await _fetchBytes(chosenVariant.url, headers);
      if (varRes == null || stopped()) return false;
      mediaText = utf8.decode(varRes.bytes, allowMalformed: true);
      mediaBaseUri = varRes.finalUri;
    }

    // 2. Parsear segmentos + claves AES-128 del playlist y construir manifiesto local
    final lines = mediaText.split(RegExp(r'\r?\n'));
    final segmentUrls = <String>[];
    final keyUrls = <String>[];
    final manifestBuf = StringBuffer();

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-KEY') || line.startsWith('#EXT-X-MAP')) {
          final rewritten = line.replaceAllMapped(
            RegExp(r'URI="([^"]+)"'),
            (m) {
              final abs = mediaBaseUri.resolve(m.group(1)!).toString();
              var kIdx = keyUrls.indexOf(abs);
              if (kIdx < 0) {
                kIdx = keyUrls.length;
                keyUrls.add(abs);
              }
              return 'URI="{{BASE}}/key/$kIdx.bin"';
            },
          );
          manifestBuf.writeln(rewritten);
        } else {
          manifestBuf.writeln(line);
        }
        continue;
      }
      final segIdx = segmentUrls.length;
      segmentUrls.add(mediaBaseUri.resolve(line).toString());
      manifestBuf.writeln('{{BASE}}/seg/$segIdx.ts');
    }

    if (segmentUrls.isEmpty) return false;
    if (!mediaText.contains('#EXT-X-ENDLIST')) {
      manifestBuf.writeln('#EXT-X-ENDLIST');
    }

    // 3. Descargar y cifrar claves #EXT-X-KEY si existen
    for (var ki = 0; ki < keyUrls.length; ki++) {
      if (stopped()) return false;
      final keyFile = File('${dir.path}/key_$ki.ivlt');
      if (await keyFile.exists()) continue;
      final ok = await _downloadAndEncryptFile(
        url: keyUrls[ki],
        headers: headers,
        outFile: keyFile,
        key32: key32,
        nonce16: VaultCrypto.deriveSegmentNonce(
          nonce16,
          HlsStreamProxy.vaultKeyNonceBase + ki,
        ),
      );
      if (!ok) return false;
    }

    // 4. Guardar manifiesto cifrado
    final encManifest = VaultCrypto.transformAtOffset(
      Uint8List.fromList(utf8.encode(manifestBuf.toString())),
      key32: key32,
      nonce16: VaultCrypto.deriveSegmentNonce(
        nonce16,
        HlsStreamProxy.vaultManifestNonceIndex,
      ),
    );
    await File('${dir.path}/manifest.ivlt').writeAsBytes(encManifest, flush: true);

    // 5. Descargar segmentos en lotes paralelos de 4 (saltando los ya existentes)
    final totalSegs = segmentUrls.length;
    var doneSegs = 0;
    var totalBytes = 0;

    // Contabilizar segmentos ya descargados (reanudación real!)
    final pendingIndices = <int>[];
    for (var i = 0; i < totalSegs; i++) {
      final f = File('${dir.path}/seg_${i.toString().padLeft(5, '0')}.ivlt');
      if (await f.exists() && await f.length() > 0) {
        doneSegs++;
        totalBytes += await f.length();
      } else {
        pendingIndices.add(i);
      }
    }

    update((c) => c.copyWith(
          segmentsDone: doneSegs,
          segmentsTotal: totalSegs,
          downloadedBytes: totalBytes,
          progress: totalSegs > 0 ? doneSegs / totalSegs : 0,
        ));

    var windowStart = DateTime.now();
    var windowBytes = 0;
    var failedSegs = 0;
    const batchSize = 4;

    for (var offset = 0; offset < pendingIndices.length; offset += batchSize) {
      if (stopped()) return false;
      final end = (offset + batchSize < pendingIndices.length)
          ? offset + batchSize
          : pendingIndices.length;
      final batch = pendingIndices.sublist(offset, end);

      final batchBytes = await Future.wait(batch.map((segIdx) async {
        if (stopped()) return -1;
        final segRes = await _fetchBytesWithRetry(segmentUrls[segIdx], headers);
        if (segRes == null || segRes.isEmpty) return -1;

        // Recortar cabecera PNG/JPEG falsa antes de cifrar fuera del hilo UI
        final clean = HlsStreamProxy.stripDisguisedHeader(segRes);
        final encrypted = await VaultCrypto.transformOffMainThread(
          clean,
          key32: key32,
          nonce16: VaultCrypto.deriveSegmentNonce(nonce16, segIdx),
        );
        final outFile = File(
          '${dir.path}/seg_${segIdx.toString().padLeft(5, '0')}.ivlt',
        );
        await outFile.writeAsBytes(encrypted, flush: false);
        return encrypted.length;
      }));

      for (final sz in batchBytes) {
        if (sz > 0) {
          doneSegs++;
          totalBytes += sz;
          windowBytes += sz;
        } else if (!stopped()) {
          failedSegs++;
        }
      }

      if (failedSegs > 8 && failedSegs > totalSegs * 0.15) {
        return false;
      }

      final elapsedSec =
          DateTime.now().difference(windowStart).inMilliseconds / 1000.0;
      double speed = 0;
      if (elapsedSec >= 0.4) {
        speed = windowBytes / elapsedSec;
        if (elapsedSec >= 2.0) {
          windowStart = DateTime.now();
          windowBytes = 0;
        }
      }

      final estTotal = doneSegs > 0 ? (totalBytes * totalSegs) ~/ doneSegs : 0;
      update((c) => c.copyWith(
            segmentsDone: doneSegs,
            segmentsTotal: totalSegs,
            downloadedBytes: totalBytes,
            totalBytes: estTotal,
            progress: (doneSegs / totalSegs).clamp(0.0, 0.999),
            speedBytesPerSec: speed > 0 ? speed : c.speedBytesPerSec,
          ));

      // Guardar progreso en prefs periódicamente cada 12 segmentos
      if (doneSegs % 12 == 0) {
        await _persistMeta();
      }
    }

    return !stopped() && doneSegs >= (totalSegs * 0.95).floor();
  }

  /// Descarga un MP4 directo en streaming cifrando cada bloque con AES-256-CTR
  /// en su `byteOffset` exacto, con pausa y reanudación HTTP `Range`.
  Future<bool> _downloadMp4ToVault({
    required String downloadId,
    required Directory dir,
    required String streamUrl,
    required Map<String, String> headers,
    required Uint8List key32,
    required Uint8List nonce16,
    required bool Function() stopped,
    required void Function(OfflineDownloadItem Function(OfflineDownloadItem))
        update,
  }) async {
    final outFile = File('${dir.path}/media.ivlt');
    var existingLen = await outFile.exists() ? await outFile.length() : 0;

    final client = _newHttpClient();
    IOSink? sink;
    try {
      final req =
          await client.getUrl(Uri.parse(streamUrl)).timeout(const Duration(seconds: 15));
      _applyHeaders(req, headers);
      if (existingLen > 0) {
        req.headers.set('Range', 'bytes=$existingLen-');
      }

      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          existingLen > 0) {
        return true; // Ya estaba completo
      }
      if (res.statusCode < 200 || res.statusCode >= 300) return false;

      // Si el servidor ignoró Range y devolvió 200 completo, reiniciamos archivo
      if (res.statusCode == HttpStatus.ok && existingLen > 0) {
        existingLen = 0;
      }

      var totalLen = existingLen + (res.contentLength > 0 ? res.contentLength : 0);
      final cr = res.headers.value(HttpHeaders.contentRangeHeader);
      if (cr != null) {
        final m = RegExp(r'/(\d+)$').firstMatch(cr);
        if (m != null) totalLen = int.tryParse(m.group(1)!) ?? totalLen;
      }

      sink = outFile.openWrite(
        mode: existingLen > 0 ? FileMode.append : FileMode.writeOnly,
      );

      var offset = existingLen;
      var lastEmit = DateTime.now();
      var windowStart = DateTime.now();
      var windowBytes = 0;

      await for (final chunk in res) {
        if (stopped()) {
          await sink.flush();
          return false;
        }
        final raw = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        final encrypted = await VaultCrypto.transformOffMainThread(
          raw,
          key32: key32,
          nonce16: nonce16,
          byteOffset: offset,
        );
        sink.add(encrypted);
        offset += raw.length;
        windowBytes += raw.length;

        final now = DateTime.now();
        if (now.difference(lastEmit).inMilliseconds >= 350) {
          lastEmit = now;
          final sec = now.difference(windowStart).inMilliseconds / 1000.0;
          final speed = sec > 0.1 ? windowBytes / sec : 0.0;
          if (sec >= 2.0) {
            windowStart = now;
            windowBytes = 0;
          }
          update((c) => c.copyWith(
                downloadedBytes: offset,
                totalBytes: totalLen > 0 ? totalLen : offset,
                progress: totalLen > 0 ? (offset / totalLen).clamp(0.0, 0.999) : 0.5,
                speedBytesPerSec: speed,
              ));
        }
      }

      await sink.flush();
      update((c) => c.copyWith(
            downloadedBytes: offset,
            totalBytes: offset,
            progress: 1.0,
          ));
      return offset > 0;
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  // ── Helpers privados de red, almacenamiento y claves ───────────────────────

  Future<Directory> _ensureVaultRoot() async {
    if (testVaultRoot != null) {
      if (!await testVaultRoot!.exists()) {
        await testVaultRoot!.create(recursive: true);
      }
      await _ensureNoMedia(testVaultRoot!);
      _vaultRoot = testVaultRoot;
      return _vaultRoot!;
    }
    if (_vaultRoot != null) return _vaultRoot!;
    final supportDir = await getApplicationSupportDirectory();
    final root = Directory('${supportDir.path}/inutil_vault');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    await _ensureNoMedia(root);
    _vaultRoot = root;
    return root;
  }

  Future<void> _ensureNoMedia(Directory dir) async {
    try {
      final nomedia = File('${dir.path}/.nomedia');
      if (!await nomedia.exists()) {
        await nomedia.writeAsBytes(const <int>[]);
      }
    } catch (_) {}
  }

  Future<Directory> _dirFor(String dirName) async {
    final root = await _ensureVaultRoot();
    return Directory('${root.path}/$dirName');
  }

  static String _safeDirName(String id) {
    final hash = crypto.sha1.convert(utf8.encode(id)).toString();
    return 'v_${hash.substring(0, 16)}';
  }

  Future<({Uint8List key32, Uint8List nonce16})> _getOrCreateKeyMaterial(
    String downloadId,
  ) async {
    final existing = await _loadKeyMaterial(downloadId);
    if (existing != null) return existing;

    final key32 = VaultCrypto.generateKey32();
    final nonce16 = VaultCrypto.generateNonce16();
    final encoded = jsonEncode({
      'k': base64.encode(key32),
      'n': base64.encode(nonce16),
    });

    final keyName = '$_keysFallbackPrefix$downloadId';
    try {
      await _secure.write(key: keyName, value: encoded).timeout(_secureTimeout);
    } catch (_) {}
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(keyName, encoded);
    } catch (_) {}

    return (key32: key32, nonce16: nonce16);
  }

  Future<({Uint8List key32, Uint8List nonce16})?> _loadKeyMaterial(
    String downloadId,
  ) async {
    final keyName = '$_keysFallbackPrefix$downloadId';
    String? raw;
    try {
      raw = await _secure.read(key: keyName).timeout(_secureTimeout);
    } catch (_) {}
    if (raw == null || raw.isEmpty) {
      try {
        final sp = await SharedPreferences.getInstance();
        raw = sp.getString(keyName);
      } catch (_) {}
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final k = base64.decode(m['k'] as String);
      final n = base64.decode(m['n'] as String);
      if (k.length == 32 && n.length == 16) {
        return (key32: k, nonce16: n);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _deleteKeyMaterial(String downloadId) async {
    final keyName = '$_keysFallbackPrefix$downloadId';
    try {
      await _secure.delete(key: keyName).timeout(_secureTimeout);
    } catch (_) {}
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(keyName);
    } catch (_) {}
  }

  Future<String?> _cachePosterLocally(Directory dir, String url) async {
    try {
      final res = await _fetchBytes(url, const {});
      if (res == null || res.bytes.length < 512) return null;
      // Guardamos con extensión opaca `.art` dentro de `.nomedia`
      final file = File('${dir.path}/poster.art');
      await file.writeAsBytes(res.bytes, flush: false);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _downloadAndEncryptFile({
    required String url,
    required Map<String, String> headers,
    required File outFile,
    required Uint8List key32,
    required Uint8List nonce16,
  }) async {
    final res = await _fetchBytes(url, headers);
    if (res == null || res.bytes.isEmpty) return false;
    final enc = VaultCrypto.transformAtOffset(
      res.bytes,
      key32: key32,
      nonce16: nonce16,
    );
    await outFile.writeAsBytes(enc, flush: true);
    return true;
  }

  Future<Uint8List?> _fetchBytesWithRetry(
    String url,
    Map<String, String> headers,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final r = await _fetchBytes(url, headers);
      if (r != null && r.bytes.isNotEmpty) return r.bytes;
    }
    return null;
  }

  Future<({Uint8List bytes, Uri finalUri})?> _fetchBytes(
    String url,
    Map<String, String> headers,
  ) async {
    final client = _newHttpClient();
    try {
      final uri = Uri.parse(url);
      final req =
          await client.getUrl(uri).timeout(const Duration(seconds: 14));
      _applyHeaders(req, headers);
      final res = await req.close().timeout(const Duration(seconds: 14));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;

      var resolved = uri;
      for (final r in res.redirects) {
        resolved = resolved.resolveUri(r.location);
      }

      final builder = BytesBuilder(copy: false);
      await for (final c in res) {
        builder.add(c);
      }
      return (bytes: builder.takeBytes(), finalUri: resolved);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  List<({String url, int bandwidth})> _parseMasterVariants(
    String masterText,
    Uri baseUri,
  ) {
    final lines = masterText.split(RegExp(r'\r?\n'));
    final out = <({String url, int bandwidth})>[];
    int? pendingBw;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        final m = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
        pendingBw = int.tryParse(m?.group(1) ?? '') ?? 0;
      } else if (!line.startsWith('#') && pendingBw != null) {
        out.add((url: baseUri.resolve(line).toString(), bandwidth: pendingBw));
        pendingBw = null;
      }
    }
    return out;
  }

  HttpClient _newHttpClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 14)
      ..badCertificateCallback = (_, __, ___) => true;
    // Las descargas también usan el proxy / DNS seguro si el usuario los activó.
    NetworkConfigService.instance.apply(client, tolerateBadCertificates: true);
    return client;
  }

  void _applyHeaders(HttpClientRequest req, Map<String, String> headers) {
    req.headers.set(
      'User-Agent',
      headers['User-Agent'] ?? StreamValidator.defaultUserAgent,
    );
    headers.forEach((k, v) {
      if (k.toLowerCase() != 'user-agent') {
        req.headers.set(k, v);
      }
    });
  }

  Future<void> _persistMeta() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _metaKey,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[OfflineVault] Persist err: $e');
    }
  }
}
