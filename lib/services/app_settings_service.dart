import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// Preferencias reales y persistentes del motor de video y apariencia de InútilTV.
/// Incluye personalización visual compartida con Inútil Music:
/// - `accent` (18 colores, por defecto Blanco Puro `#F5F7F5`)
/// - `surfaceMode` (`liquidGlass` / `transparent` / `accent`)
/// - `themeMode` (`dark` / `light` / `system`)
class AppSettingsService extends ChangeNotifier {
  AppSettingsService._();
  static final AppSettingsService instance = AppSettingsService._();

  static const _kHwAccel = 'inutiltv_hw_acceleration_v1';
  static const _kUltraBuffer = 'inutiltv_ultra_buffer_v1';
  static const _kAutoNext = 'inutiltv_auto_next_episode_v1';
  static const _kPreloadNext = 'inutiltv_preload_next_ep_v1';
  static const _kSkipIntroSec = 'inutiltv_skip_intro_sec_v1';
  static const _kAccent = 'inutiltv_appearance_accent_v3';
  static const _kSurfaceMode = 'inutiltv_appearance_surface_v3';
  static const _kThemeMode = 'inutiltv_appearance_theme_v3';

  bool _loaded = false;
  bool _hwAcceleration = true;
  bool _ultraBuffer = true;
  bool _autoNextEpisode = true;
  bool _preloadNextEpisode = true;
  int _skipIntroSeconds = 85;

  AppAccent _accent = AppAccent.white;
  SurfaceBackgroundMode _surfaceMode = SurfaceBackgroundMode.liquidGlass;
  AppThemeMode _themeMode = AppThemeMode.dark;

  /// Notificador global para que `MainScaffold` oculte encabezado y barra
  /// flotante cuando TV en Vivo gira a horizontal en pantalla completa real.
  final ValueNotifier<bool> immersiveLandscape = ValueNotifier<bool>(false);

  bool get hwAcceleration => _hwAcceleration;
  bool get ultraBuffer => _ultraBuffer;
  bool get autoNextEpisode => _autoNextEpisode;
  bool get preloadNextEpisode => _preloadNextEpisode;
  int get skipIntroSeconds => _skipIntroSeconds;

  AppAccent get accent => _accent;
  SurfaceBackgroundMode get surfaceMode => _surfaceMode;
  AppThemeMode get themeMode => _themeMode;

  /// Tamaño real del buffer para `PlayerConfiguration(bufferSize: ...)`.
  int get bufferSizeBytes => _ultraBuffer ? 64 * 1024 * 1024 : 16 * 1024 * 1024;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final sp = await SharedPreferences.getInstance();
      _hwAcceleration = sp.getBool(_kHwAccel) ?? true;
      _ultraBuffer = sp.getBool(_kUltraBuffer) ?? true;
      _autoNextEpisode = sp.getBool(_kAutoNext) ?? true;
      _preloadNextEpisode = sp.getBool(_kPreloadNext) ?? true;
      _skipIntroSeconds = (sp.getInt(_kSkipIntroSec) ?? 85).clamp(30, 150);
      _accent = AppAccent.fromCode(sp.getString(_kAccent));
      _surfaceMode = SurfaceBackgroundMode.fromCode(sp.getString(_kSurfaceMode));
      _themeMode = AppThemeMode.fromCode(sp.getString(_kThemeMode));
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  Future<void> setPreloadNextEpisode(bool value) async {
    _preloadNextEpisode = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kPreloadNext, value);
    } catch (_) {}
  }

  Future<void> setAccent(AppAccent value) async {
    if (_accent == value) return;
    _accent = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kAccent, value.code);
    } catch (_) {}
  }

  Future<void> setSurfaceMode(SurfaceBackgroundMode value) async {
    if (_surfaceMode == value) return;
    _surfaceMode = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kSurfaceMode, value.code);
    } catch (_) {}
  }

  Future<void> setThemeMode(AppThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kThemeMode, value.code);
    } catch (_) {}
  }

  Future<void> setHwAcceleration(bool value) async {
    _hwAcceleration = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kHwAccel, value);
    } catch (_) {}
  }

  Future<void> setUltraBuffer(bool value) async {
    _ultraBuffer = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kUltraBuffer, value);
    } catch (_) {}
  }

  Future<void> setAutoNextEpisode(bool value) async {
    _autoNextEpisode = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kAutoNext, value);
    } catch (_) {}
  }

  Future<void> setSkipIntroSeconds(int seconds) async {
    _skipIntroSeconds = seconds.clamp(30, 150);
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_kSkipIntroSec, _skipIntroSeconds);
    } catch (_) {}
  }
}
