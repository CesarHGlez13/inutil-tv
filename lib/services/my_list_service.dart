import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import 'inutil_cloud_backup_service.dart';
import 'tv_taste_profile_service.dart';

/// "Mi Lista" persistente para Películas, Series y Anime de InútilTV.
class MyListService extends ChangeNotifier {
  MyListService._();
  static final MyListService instance = MyListService._();

  static const _key = 'inutiltv_my_list_v1';
  static const _maxItems = 80;

  List<VodItem> _items = [];
  bool _loaded = false;

  List<VodItem> get items => List.unmodifiable(_items);

  bool contains(String id) => _items.any((it) => it.id == id);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List;
        _items = decoded
            .whereType<Map>()
            .map((e) => VodItem.fromJson(e.cast<String, dynamic>()))
            .where((v) => v.id.isNotEmpty && v.title.isNotEmpty)
            .toList();
      } else {
        _items = [];
      }
    } catch (_) {
      _items = [];
    }
    _loaded = true;
    notifyListeners();
  }

  /// Alterna un título en Mi Lista y devuelve `true` si quedó guardado.
  Future<bool> toggle(VodItem item) async {
    await load();
    final idx = _items.indexWhere((it) => it.id == item.id);
    bool added;
    if (idx >= 0) {
      _items.removeAt(idx);
      added = false;
    } else {
      // Guardar versión ligera (sin lista gigante de episodios embebida)
      final compact = VodItem(
        id: item.id,
        title: item.title,
        poster: item.poster,
        backdrop: item.backdrop,
        overview: item.overview,
        year: item.year,
        genre: item.genre,
        rating: item.rating,
        duration: item.duration,
        isSeries: item.isSeries,
        isAnime: item.isAnime,
        slug: item.slug,
        provider: item.provider,
        quality: item.quality,
        sources: item.sources.take(3).toList(),
      );
      _items.insert(0, compact);
      if (_items.length > _maxItems) {
        _items = _items.take(_maxItems).toList();
      }
      added = true;
    }
    notifyListeners();
    await _persist();
    unawaited(
      TvTasteProfileService.instance.recordMyListSignal(item, added: added),
    );
    return added;
  }

  Future<void> remove(String id) async {
    await load();
    final removed = _items.where((it) => it.id == id).toList();
    _items.removeWhere((it) => it.id == id);
    notifyListeners();
    await _persist();
    if (removed.isNotEmpty) {
      unawaited(
        TvTasteProfileService.instance
            .recordMyListSignal(removed.first, added: false),
      );
    }
  }

  Future<void> clear() async {
    _items = [];
    notifyListeners();
    await _persist();
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
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
      InutilTvCloudBackupService.instance.schedulePush();
    } catch (_) {}
  }
}
