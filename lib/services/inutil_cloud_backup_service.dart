import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_firestore_service.dart';
import 'inutil_wrapped_service.dart';
import 'my_list_service.dart';
import 'tv_daily_usage_service.dart';
import 'tv_taste_profile_service.dart';
import 'watch_history.dart';
import 'xuper_service.dart';

/// Respaldo total en la nube de InútilTV (esquema v2, retrocompatible con v1).
///
/// Guarda y restaura en `users/{uid}/data/tv_backup` (aislado de Inutix Music):
/// - Posición exacta en segundos de cada película/capítulo («Seguir viendo» +
///   historial completo hasta 120 títulos, resuelto por `updatedAt` más reciente)
/// - Episodios vistos por serie (fusión por unión de conjuntos)
/// - «Mi Lista» completa
/// - Perfil de gustos / afinidad (`TvTasteProfileService`: géneros, búsquedas,
///   ratio, audio preferido, finalizaciones/abandonos, horarios)
/// - Canales Favoritos (`inutiltv_favorite_channels`) y recientes
/// - Preferencias de reproductor, idioma de audio y apariencia (`AppSettingsService`)
///
/// Protección anti-sobrescritura tras reinstalar: jamás sube un estado vacío
/// antes de completar la restauración inicial.
class InutilTvCloudBackupService extends ChangeNotifier {
  InutilTvCloudBackupService._();
  static final InutilTvCloudBackupService instance =
      InutilTvCloudBackupService._();

  static const int schemaVersion = 2;
  static const Duration _pushDebounce = Duration(seconds: 20);
  static const Duration _autoPushInterval = Duration(minutes: 30);

  static const String _myListKey = 'inutiltv_my_list_v1';
  static const String _historyKey = 'inutiltv_watch_history_v1';
  static const String _watchedEpsKey = 'inutiltv_watched_episodes_v1';
  static const String _favChannelsKey = 'inutiltv_favorite_channels';
  static const String _recentChannelsKey = 'inutiltv_recent_channels_v1';
  static const String _tasteKey = TvTasteProfileService.prefsKey;

  static const Set<String> _backedSettingKeys = {
    'inutiltv_hw_acceleration_v1',
    'inutiltv_ultra_buffer_v1',
    'inutiltv_auto_next_episode_v1',
    'inutiltv_preload_next_ep_v1',
    'inutiltv_skip_intro_sec_v1',
    'inutiltv_appearance_accent_v3',
    'inutiltv_appearance_surface_v3',
    'inutiltv_appearance_theme_v3',
    'inutiltv_preferred_audio_lang_v1',
  };

  final _auth = InutilAuthService.instance;
  Timer? _debounce;
  Timer? _interval;
  bool _pushing = false;
  bool _pulling = false;
  bool _initialPullCompleted = false;
  DateTime? _lastPushAt;
  DateTime? _lastRestoreAt;
  String _lastError = '';

  DateTime? get lastPushAt => _lastPushAt;
  DateTime? get lastRestoreAt => _lastRestoreAt;
  String get lastError => _lastError;
  bool get isBusy => _pushing || _pulling;

  bool get canSync =>
      _auth.currentUser?.idToken.isNotEmpty == true && _auth.isAccessAllowed;

  void schedulePush() {
    if (!canSync) return;
    _debounce?.cancel();
    _debounce = Timer(_pushDebounce, () => unawaited(pushNow()));
  }

  void startAutoSync() {
    _interval?.cancel();
    _interval = Timer.periodic(_autoPushInterval, (_) {
      if (canSync) unawaited(pushNow());
    });
  }

  void stopAutoSync() {
    _interval?.cancel();
    _interval = null;
    _debounce?.cancel();
    _debounce = null;
  }

  /// Sube el respaldo completo de InútilTV a `users/{uid}/data/tv_backup`.
  Future<String> pushNow({bool force = false}) async {
    if (_pushing) return 'Respaldo en curso…';
    if (!canSync) return 'Inicia sesión para respaldar en la nube.';
    _pushing = true;
    notifyListeners();
    try {
      final uid = _auth.currentUser!.uid;

      // Garantizar que el perfil de gustos esté volcado a disco antes de leer
      await TvTasteProfileService.instance.persistNow(triggerBackup: false);

      final sp = await SharedPreferences.getInstance();

      final myListRaw = sp.getString(_myListKey) ?? '[]';
      final histRaw = sp.getString(_historyKey) ?? '[]';
      final epsRaw = sp.getString(_watchedEpsKey) ?? '{}';
      final tasteRaw = sp.getString(_tasteKey) ?? '';
      final favChannels = sp.getStringList(_favChannelsKey) ?? const <String>[];
      final recentChannels =
          sp.getStringList(_recentChannelsKey) ?? const <String>[];

      final myList = _safeDecodeList(myListRaw);
      final history = _safeDecodeList(histRaw);
      final hasTaste = TvTasteProfileService.instance.events.isNotEmpty;
      final hasLocalData = myList.isNotEmpty ||
          history.isNotEmpty ||
          favChannels.isNotEmpty ||
          hasTaste;

      // Protección anti-borrado tras reinstalar (igual que Inútil Music):
      if (!force && !_initialPullCompleted && !hasLocalData) {
        await InutilTvWrappedService.instance.persistNow();
        await InutilTvWrappedService.instance.syncCurrentYearToCloud();
        return 'Esperando restauración inicial antes de respaldar.';
      }

      final settings = <String, dynamic>{};
      for (final k in _backedSettingKeys) {
        final v = sp.get(k);
        if (v != null) settings[k] = v;
      }

      final payload = <String, dynamic>{
        'schemaVersion': schemaVersion,
        'myListJson': myListRaw,
        'watchHistoryJson': histRaw,
        'watchedEpisodesJson': epsRaw,
        'tasteProfileJson': tasteRaw,
        'favoriteChannels': favChannels,
        'recentChannels': recentChannels,
        'settings': settings,
        'updatedAt': DateTime.now().toIso8601String(),
        'platform': Platform.operatingSystem,
      };

      final ok = await InutilFirestoreService.instance.setDocument(
        'users/$uid/data/tv_backup',
        payload,
      );

      await InutilTvWrappedService.instance.persistNow();
      await InutilTvWrappedService.instance.syncCurrentYearToCloud();
      unawaited(TvDailyUsageService.instance.flushRichAnalytics());

      _lastPushAt = DateTime.now();
      _lastError = ok ? '' : 'No se pudo completar el respaldo en Firestore.';
      return ok
          ? 'Respaldo guardado: ${myList.length} en Mi Lista, ${favChannels.length} canales fav, ${history.length} en historial.'
          : _lastError;
    } catch (e) {
      _lastError = 'Error al respaldar: $e';
      debugPrint('[TvCloudBackup] Push err: $e');
      return 'No se pudo respaldar (¿sin conexión?).';
    } finally {
      _pushing = false;
      notifyListeners();
    }
  }

  /// Restaura exactamente el estado del usuario desde `users/{uid}/data/tv_backup`
  /// fusionando por recencia (`updatedAt`) y unión de conjuntos sin borrar progreso.
  Future<String> pullAndRestoreIfEmpty({bool mergeOverwrite = false}) async {
    if (_pulling) return 'Restauración en curso…';
    if (!canSync) return 'Inicia sesión para restaurar tu respaldo.';
    _pulling = true;
    notifyListeners();
    try {
      final uid = _auth.currentUser!.uid;
      final sp = await SharedPreferences.getInstance();

      await InutilTvWrappedService.instance.pullYearFromCloud();

      final doc = await InutilFirestoreService.instance.getDocument(
        'users/$uid/data/tv_backup',
      );
      _initialPullCompleted = true;

      if (doc == null || doc.isEmpty) {
        return 'Aún no hay respaldo de Inutix TV en la nube para esta cuenta.';
      }

      var restoredCount = 0;
      final localHistBefore = _safeDecodeList(sp.getString(_historyKey) ?? '[]');
      final localMyListBefore = _safeDecodeList(sp.getString(_myListKey) ?? '[]');
      final localFavsBefore =
          sp.getStringList(_favChannelsKey) ?? const <String>[];
      final isFreshInstall = localHistBefore.isEmpty &&
          localMyListBefore.isEmpty &&
          localFavsBefore.isEmpty;

      // 1. Mi Lista (fusión por ID sin perder elementos locales ni remotos)
      final remoteMyList =
          _safeDecodeList((doc['myListJson'] ?? '').toString());
      if (remoteMyList.isNotEmpty) {
        final merged = _mergeById(localMyListBefore, remoteMyList);
        if (merged.length != localMyListBefore.length ||
            mergeOverwrite ||
            localMyListBefore.isEmpty) {
          await sp.setString(_myListKey, jsonEncode(merged));
          restoredCount += remoteMyList.length;
        }
      }

      // 2. Historial exacto "Seguir viendo" (gana el `updatedAt` más reciente)
      final remoteHist =
          _safeDecodeList((doc['watchHistoryJson'] ?? '').toString());
      if (remoteHist.isNotEmpty) {
        final merged = _mergeByIdNewest(
          localHistBefore,
          remoteHist,
          preferRemoteOnTie: mergeOverwrite || isFreshInstall,
        );
        await sp.setString(_historyKey, jsonEncode(merged));
        restoredCount += remoteHist.length;
      }

      // 3. Episodios vistos (unión exacta por `seriesId`, jamás borra capítulos)
      final remoteEpsRaw = (doc['watchedEpisodesJson'] ?? '').toString();
      if (remoteEpsRaw.length > 2) {
        final mergedEps = _mergeWatchedEpisodes(
          sp.getString(_watchedEpsKey) ?? '{}',
          remoteEpsRaw,
        );
        if (mergedEps.isNotEmpty) {
          await sp.setString(_watchedEpsKey, jsonEncode(mergedEps));
          restoredCount += 1;
        }
      }

      // 4. Perfil de gustos / afinidad (`TvTasteProfileService`)
      final remoteTasteRaw = (doc['tasteProfileJson'] ?? '').toString();
      if (remoteTasteRaw.isNotEmpty) {
        final mergedTaste = await TvTasteProfileService.instance
            .mergeFromJsonString(remoteTasteRaw, overwrite: mergeOverwrite);
        if (mergedTaste) restoredCount += 1;
      }

      // 5. Canales favoritos y recientes (unión ordenada sin duplicados)
      final remoteFavs = (doc['favoriteChannels'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const <String>[];
      if (remoteFavs.isNotEmpty) {
        final mergedFavs = {...localFavsBefore, ...remoteFavs}.toList();
        await sp.setStringList(_favChannelsKey, mergedFavs);
        if (mergedFavs.length > localFavsBefore.length || isFreshInstall) {
          restoredCount += remoteFavs.length;
        }
      }

      final remoteRecs = (doc['recentChannels'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const <String>[];
      final localRecs =
          sp.getStringList(_recentChannelsKey) ?? const <String>[];
      if (remoteRecs.isNotEmpty) {
        final mergedRecs = <String>[
          ...localRecs,
          for (final r in remoteRecs)
            if (!localRecs.contains(r)) r,
        ].take(10).toList();
        await sp.setStringList(_recentChannelsKey, mergedRecs);
      }

      // 6. Preferencias de reproductor, idioma y apariencia
      final settings = doc['settings'];
      if (settings is Map) {
        for (final entry in settings.entries) {
          final k = entry.key.toString();
          if (!_backedSettingKeys.contains(k)) continue;
          if (!mergeOverwrite && !isFreshInstall && sp.containsKey(k)) continue;
          final v = entry.value;
          if (v is String) {
            await sp.setString(k, v);
          } else if (v is bool) {
            await sp.setBool(k, v);
          } else if (v is int) {
            await sp.setInt(k, v);
          } else if (v is num) {
            await sp.setInt(k, v.toInt());
          }
        }
      }

      // Recargar todos los singletons en memoria y recalcular Home al instante
      await Future.wait([
        AppSettingsService.instance.load(force: true),
        MyListService.instance.reloadFromDisk(),
        WatchHistory().reloadFromDisk(),
        TvTasteProfileService.instance.reloadFromDisk(),
      ]);
      XuperService().rebuildRecommendations();

      _lastRestoreAt = DateTime.now();
      _lastError = '';
      return restoredCount > 0
          ? 'Respaldo restaurado ($restoredCount elementos recuperados).'
          : 'Tu biblioteca ya estaba al día con la nube.';
    } catch (e) {
      _lastError = 'Restauración no completada: $e';
      debugPrint('[TvCloudBackup] Pull err: $e');
      return 'No se pudo restaurar desde la nube. Intenta más tarde.';
    } finally {
      _pulling = false;
      notifyListeners();
    }
  }

  /// Helper puro y testeable para fusionar listas de mapas por `id` sin perder datos.
  @visibleForTesting
  static List<Map<String, dynamic>> mergeByIdForTest(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote,
  ) =>
      _mergeById(local, remote);

  /// Helper puro para fusionar historial por `id` eligiendo el `updatedAt` más nuevo.
  @visibleForTesting
  static List<Map<String, dynamic>> mergeByIdNewestForTest(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote, {
    bool preferRemoteOnTie = false,
  }) =>
      _mergeByIdNewest(
        local,
        remote,
        preferRemoteOnTie: preferRemoteOnTie,
      );

  /// Helper puro para fusionar episodios vistos por unión de conjuntos.
  @visibleForTesting
  static Map<String, List<String>> mergeWatchedEpisodesForTest(
    String localRaw,
    String remoteRaw,
  ) =>
      _mergeWatchedEpisodes(localRaw, remoteRaw);

  @visibleForTesting
  void resetForTest() {
    stopAutoSync();
    _pushing = false;
    _pulling = false;
    _initialPullCompleted = false;
    _lastPushAt = null;
    _lastRestoreAt = null;
    _lastError = '';
  }

  static List<Map<String, dynamic>> _safeDecodeList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      }
    } catch (_) {}
    return [];
  }

  static List<Map<String, dynamic>> _mergeById(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote,
  ) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final m in [...local, ...remote]) {
      final id = (m['id'] ?? '').toString();
      if (id.isEmpty || seen.add(id)) {
        out.add(m);
      }
    }
    return out;
  }

  /// Fusiona historial de reproducción eligiendo por cada `id` la entrada con
  /// `updatedAt` más reciente (o mayor progreso si empatan) y ordena descendente.
  static List<Map<String, dynamic>> _mergeByIdNewest(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote, {
    bool preferRemoteOnTie = false,
  }) {
    final byId = <String, Map<String, dynamic>>{};
    int tsOf(Map<String, dynamic> m) => (m['updatedAt'] as num?)?.toInt() ?? 0;
    double posOf(Map<String, dynamic> m) =>
        (m['positionSec'] as num?)?.toDouble() ?? 0.0;

    for (final m in local) {
      final id = (m['id'] ?? '').toString();
      if (id.isNotEmpty) byId[id] = m;
    }
    for (final m in remote) {
      final id = (m['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final cur = byId[id];
      if (cur == null) {
        byId[id] = m;
        continue;
      }
      final rTs = tsOf(m);
      final lTs = tsOf(cur);
      if (rTs > lTs ||
          (rTs == lTs &&
              (preferRemoteOnTie || posOf(m) > posOf(cur)))) {
        byId[id] = m;
      }
    }

    final merged = byId.values.toList()
      ..sort((a, b) => tsOf(b).compareTo(tsOf(a)));
    return merged.take(120).toList();
  }

  static Map<String, List<String>> _mergeWatchedEpisodes(
    String localRaw,
    String remoteRaw,
  ) {
    final merged = <String, Set<String>>{};
    void absorb(String raw) {
      if (raw.trim().length <= 2) return;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return;
        decoded.forEach((k, v) {
          final seriesId = k.toString();
          if (seriesId.isEmpty || v is! List) return;
          final set = merged.putIfAbsent(seriesId, () => <String>{});
          for (final ep in v) {
            final epStr = ep.toString();
            if (epStr.isNotEmpty) set.add(epStr);
          }
        });
      } catch (_) {}
    }

    absorb(localRaw);
    absorb(remoteRaw);
    return merged.map((k, v) {
      final list = v.toList()..sort();
      return MapEntry(k, list);
    });
  }
}
