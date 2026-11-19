import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Puente nativo ligero hacia MainActivity (`inutil_tv/device`) para controlar
/// brillo de pantalla y WakeLock durante la reproducción de video.
class DeviceControlService {
  DeviceControlService._();
  static const MethodChannel _channel = MethodChannel('inutil_tv/device');

  static Future<void> setKeepScreenOn(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<bool>('setKeepScreenOn', {'enabled': enabled});
    } catch (_) {}
  }

  static Future<double> getBrightness() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return 0.5;
    try {
      final val = await _channel.invokeMethod<num>('getBrightness');
      return (val?.toDouble() ?? 0.5).clamp(0.02, 1.0);
    } catch (_) {
      return 0.5;
    }
  }

  static Future<void> setBrightness(double value) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<bool>('setBrightness', {
        'value': value.clamp(0.02, 1.0),
      });
    } catch (_) {}
  }

  static Future<void> resetBrightness() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<bool>('resetBrightness');
    } catch (_) {}
  }

  /// Detecta desde el sistema Android si corre en Android TV / Google TV / TV Box
  /// (UiMode TELEVISION, feature Leanback o dispositivo sin pantalla táctil).
  static Future<bool> isAndroidTv() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return (await _channel.invokeMethod<bool>('isAndroidTv')) ?? false;
    } catch (_) {
      return false;
    }
  }
}
