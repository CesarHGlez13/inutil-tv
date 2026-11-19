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
import 'watch_history.dart';

/// Respaldo en la nube de InútilTV (portado de Inútil Music v2.4).
///
/// Guarda y restaura en `users/{uid}/data/tv_backup` (completamente aislado de
/// `backup_meta` / `backup_tracks_*` de Inútil Music para que jamás colisionen):
/// - Mi Lista (`inutiltv_my_list_v1`)
/// - Historial "Seguir viendo" (`inutiltv_watch_history_v1`) y episodios vistos
/// - Canales Favoritos (`inutiltv_favorite_channels`) y recientes
/// - Apariencia y motor de video (`AppSettingsService`)
///
/// Incluye protección anti-sobrescritura tras reinstalar (igual que Inútil Music):
/// nunca sube un estado vacío antes de completar la restauración inicial.
class InutilTvCloudBackupService extends ChangeNotifier {
  InutilTvCloudBackupService._();
  static final InutilTvCloudBackupService instance =
      InutilTvCloudBackupService._();

  static const Duration _pushDebounce = Duration(seconds: 20);
  static const Duration _autoPushInterval = Duration(minutes: 30);

  static const String _myListKey = 'inutiltv_my_list_v1';
  static const String _historyKey = 'inutiltv_watch_history_v1';
  static const String _watchedEpsKey = 'inutiltv_watched_episodes_v1';
  static const String _favChannelsKey = 'inutiltv_favorite_channels';
  static const String _recentChannelsKey = 'inutiltv_recent_channels_v1';

  static const Set<String> _backedSettingKeys = {
    'inutiltv_hw_acceleration_v1',
    'inutiltv_ultra_buffer_v1',
    'inutiltv_auto_next_episode_v1',
    'inutiltv_preload_next_ep_v1',
    'inutiltv_skip_intro_sec_v1',
    'inutiltv_appearance_accent_v3',
    'inutiltv_appearance_surface_v3',
    'inutiltv_appearance_theme_v3',
  };

  final _auth = InutilAuthService.instance;
  Timer? _debounce;
  Timer? _interval;
  bool _pushing = false;
  bool _pulling = false;
  bool _initialPullCompleted = false;
  DateTime? _lastPushAt;
  String _lastError = '';

  DateTime? get lastPushAt => _lastPushAt;
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

  /// Sube el respaldo de InútilTV a `users/{uid}/data/tv_backup`.
  Future<String> pushNow({bool force = false}) async {
    if (_pushing) return 'Respaldo en curso…';
    if (!canSync) return 'Inicia sesión para respaldar en la nube.';
    _pushing = true;
    notifyListeners();
    try {
      final uid = _auth.currentUser!.uid;
      final sp = await SharedPreferences.getInstance();

      final myListRaw = sp.getString(_myListKey) ?? '[]';
      final histRaw = sp.getString(_historyKey) ?? '[]';
      final epsRaw = sp.getString(_watchedEpsKey) ?? '{}';
      final favChannels = sp.getStringList(_favChannelsKey) ?? const <String>[];
      final recentChannels =
          sp.getStringList(_recentChannelsKey) ?? const <String>[];

      final myList = _safeDecodeList(myListRaw);
      final history = _safeDecodeList(histRaw);
      final hasLocalData =
          myList.isNotEmpty || history.isNotEmpty || favChannels.isNotEmpty;

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
        'myListJson': myListRaw,
        'watchHistoryJson': histRaw,
        'watchedEpisodesJson': epsRaw,
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

  /// Restaura desde `users/{uid}/data/tv_backup` fusionando sin borrar datos locales.
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
        return 'Aún no hay respaldo de InútilTV en la nube para esta cuenta.';
      }

      var restoredCount = 0;

      // 1. Mi Lista (fusiona si local está vacío o si se pidió restauración manual)
      final remoteMyListRaw = (doc['myListJson'] ?? '').toString();
      final localMyList = _safeDecodeList(sp.getString(_myListKey) ?? '[]');
      final remoteMyList = _safeDecodeList(remoteMyListRaw);
      if (remoteMyList.isNotEmpty && (localMyList.isEmpty || mergeOverwrite)) {
        final merged = _mergeById(localMyList, remoteMyList);
        await sp.setString(_myListKey, jsonEncode(merged));
        restoredCount += remoteMyList.length;
      }

      // 2. Historial de reproducción
      final remoteHistRaw = (doc['watchHistoryJson'] ?? '').toString();
      final localHist = _safeDecodeList(sp.getString(_historyKey) ?? '[]');
      final remoteHist = _safeDecodeList(remoteHistRaw);
      if (remoteHist.isNotEmpty && (localHist.isEmpty || mergeOverwrite)) {
        final merged = _mergeById(localHist, remoteHist);
        await sp.setString(_historyKey, jsonEncode(merged));
        restoredCount += remoteHist.length;
      }

      // 3. Episodios vistos
      final remoteEpsRaw = (doc['watchedEpisodesJson'] ?? '').toString();
      if (remoteEpsRaw.length > 2 &&
          ((sp.getString(_watchedEpsKey) ?? '').length <= 2 || mergeOverwrite)) {
        await sp.setString(_watchedEpsKey, remoteEpsRaw);
      }

      // 4. Canales favoritos y recientes
      final remoteFavs = (doc['favoriteChannels'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      final localFavs = sp.getStringList(_favChannelsKey) ?? const <String>[];
      if (remoteFavs.isNotEmpty && (localFavs.isEmpty || mergeOverwrite)) {
        final mergedFavs = {...localFavs, ...remoteFavs}.toList();
        await sp.setStringList(_favChannelsKey, mergedFavs);
        restoredCount += remoteFavs.length;
      }

      final remoteRecs = (doc['recentChannels'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      final localRecs =
          sp.getStringList(_recentChannelsKey) ?? const <String>[];
      if (remoteRecs.isNotEmpty && localRecs.isEmpty) {
        await sp.setStringList(_recentChannelsKey, remoteRecs);
      }

      // 5. Ajustes de apariencia y motor (solo claves que aún no existan)
      final settings = doc['settings'];
      if (settings is Map) {
        for (final entry in settings.entries) {
          final k = entry.key.toString();
          if (!_backedSettingKeys.contains(k)) continue;
          if (!mergeOverwrite && sp.containsKey(k)) continue;
          final v = entry.value;
          if (v is String) {
            await sp.setString(k, v);
          } else if (v is bool) {
            await sp.setBool(k, v);
          } else if (v is int) {
            await sp.setInt(k, v);
          }
        }
      }

      // Recargar singletons en memoria
      await Future.wait([
        AppSettingsService.instance.load(force: true),
        MyListService.instance.reloadFromDisk(),
        WatchHistory().reloadFromDisk(),
      ]);

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
}
