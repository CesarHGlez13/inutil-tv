import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Persistencia local: favoritos, listas del usuario y ajustes.
class Storage {
  static const _kFavChannels = 'fav_channels';
  static const _kFavMovies = 'fav_movies';
  static const _kPlaylists = 'playlists';
  static const _kNsfw = 'show_nsfw';

  static Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  // ---- favoritos ----
  static Future<Set<String>> favChannels() async {
    final sp = await _sp();
    return (jsonDecode(sp.getString(_kFavChannels) ?? '[]') as List)
        .cast<String>()
        .toSet();
  }

  static Future<void> toggleFavChannel(String id) async {
    final favs = await favChannels();
    favs.contains(id) ? favs.remove(id) : favs.add(id);
    final sp = await _sp();
    await sp.setString(_kFavChannels, jsonEncode(favs.toList()));
  }

  static Future<Set<String>> favMovies() async {
    final sp = await _sp();
    return (jsonDecode(sp.getString(_kFavMovies) ?? '[]') as List)
        .cast<String>()
        .toSet();
  }

  static Future<void> toggleFavMovie(String id) async {
    final favs = await favMovies();
    favs.contains(id) ? favs.remove(id) : favs.add(id);
    final sp = await _sp();
    await sp.setString(_kFavMovies, jsonEncode(favs.toList()));
  }

  // ---- playlists ----
  static Future<List<UserPlaylist>> playlists() async {
    final sp = await _sp();
    final raw = jsonDecode(sp.getString(_kPlaylists) ?? '[]') as List;
    return raw
        .map((e) => UserPlaylist.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> savePlaylists(List<UserPlaylist> list) async {
    final sp = await _sp();
    await sp.setString(
        _kPlaylists, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  // ---- ajustes ----
  static Future<bool> showNsfw() async =>
      (await _sp()).getBool(_kNsfw) ?? false;

  static Future<void> setShowNsfw(bool v) async =>
      (await _sp()).setBool(_kNsfw, v);
}
