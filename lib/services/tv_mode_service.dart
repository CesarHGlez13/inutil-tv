import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_control_service.dart';

/// Detección y estado del modo Smart TV / Android TV / TV Box (Onn, Google TV,
/// Fire TV, Xiaomi Box, etc.).
///
/// Combina la detección nativa de Android (`UI_MODE_TYPE_TELEVISION`, feature
/// `leanback` o dispositivo sin pantalla táctil) con un ajuste opcional manual
/// para TV Boxes que reportan falsamente pantalla táctil.
class TvModeService extends ChangeNotifier {
  TvModeService._();
  static final TvModeService instance = TvModeService._();

  static const _kOverrideKey = 'inutiltv_smart_tv_mode_v1';

  bool _initialized = false;
  bool _detectedTv = false;
  bool? _manualOverride;

  /// Verdadero cuando se debe presentar la interfaz de Smart TV (menú lateral,
  /// navegación D-pad prioritaria, En Vivo dividido, reproductor con mando).
  bool get isTv => _manualOverride ?? _detectedTv;

  /// Verdadero si el hardware/SO fue detectado como Android TV / TV Box.
  bool get detectedHardwareTv => _detectedTv;

  /// Override manual del usuario (`null` = automático, `true` = siempre TV,
  /// `false` = siempre móvil).
  bool? get manualOverride => _manualOverride;

  /// Atajo de lectura en árboles de widgets.
  static bool of(BuildContext context) => instance.isTv;

  Future<void> initialize({bool force = false}) async {
    if (_initialized && !force) return;
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.containsKey(_kOverrideKey)) {
        _manualOverride = sp.getBool(_kOverrideKey);
      } else {
        _manualOverride = null;
      }
    } catch (_) {}

    try {
      _detectedTv = await DeviceControlService.isAndroidTv();
    } catch (_) {
      _detectedTv = false;
    }

    _initialized = true;
    if (isTv) {
      await _applyTvOrientation();
    }
    notifyListeners();
  }

  Future<void> setManualOverride(bool? value) async {
    if (_manualOverride == value) return;
    _manualOverride = value;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      if (value == null) {
        await sp.remove(_kOverrideKey);
      } else {
        await sp.setBool(_kOverrideKey, value);
      }
    } catch (_) {}
    if (isTv) {
      await _applyTvOrientation();
    } else {
      try {
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      } catch (_) {}
    }
  }

  Future<void> _applyTvOrientation() async {
    try {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } catch (_) {}
  }

  @visibleForTesting
  void setForTest({bool? detectedTv, bool? manualOverride}) {
    if (detectedTv != null) _detectedTv = detectedTv;
    _manualOverride = manualOverride;
    _initialized = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _initialized = false;
    _detectedTv = false;
    _manualOverride = null;
    notifyListeners();
  }
}
