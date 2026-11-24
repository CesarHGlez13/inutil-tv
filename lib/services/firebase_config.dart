library;

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Configuración cliente de Firebase compartida por la familia INÚTIL
/// (Inútil Music e InútilTV).
///
/// Solo contiene identificadores públicos (`projectId`, `apiKey`, `appId`...).
/// Ninguno de estos valores es secreto: la seguridad real la imponen las
/// reglas de Firestore y el propio Firebase Auth. No hay contraseñas ni claves
/// de Service Account en el cliente.
class FirebaseConfig {
  const FirebaseConfig._();

  // Proyecto oficial compartido de la familia Inútil (`inutil-music-app`).
  static const String projectId = String.fromEnvironment(
    'FB_PROJECT_ID',
    defaultValue: 'inutil-music-app',
  );
  static const String apiKey = String.fromEnvironment(
    'FB_API_KEY',
    defaultValue: 'AIzaSyBLg1eN_N7Djc8X1Kri5MQFS-bnS2vVv-c',
  );
  static const String messagingSenderId = '129744480084';
  static const String appId = '1:129744480084:android:3f38029aa9917db411cac1';

  /// Client ID OAuth Web del proyecto `inutil-music-app` (client_type 3) para
  /// solicitar el `idToken` de Google Sign-In y canjearlo en Firebase Auth.
  static const String googleWebClientId = String.fromEnvironment(
    'FB_GOOGLE_WEB_CLIENT_ID',
    defaultValue:
        '129744480084-l2df9mg9o2i7218vt8mq3899nkta43pe.apps.googleusercontent.com',
  );

  static String get authDomain => '$projectId.firebaseapp.com';

  /// `true` cuando se apunta a la suite de emuladores local
  /// (`firebase emulators:start --only auth,firestore`) en lugar de la nube
  /// real. Permite validar el flujo completo sin tocar producción:
  ///   `flutter run --dart-define=FB_EMULATOR=true`
  static const bool useEmulator = bool.fromEnvironment(
    'FB_EMULATOR',
    defaultValue: false,
  );
  static const String emulatorHost = String.fromEnvironment(
    'FB_EMULATOR_HOST',
    defaultValue: '127.0.0.1',
  );
  static const String emulatorAuthPort = String.fromEnvironment(
    'FB_EMULATOR_AUTH_PORT',
    defaultValue: '9099',
  );
  static const String emulatorFirestorePort = String.fromEnvironment(
    'FB_EMULATOR_FIRESTORE_PORT',
    defaultValue: '8080',
  );

  static String get storageBucket => const String.fromEnvironment(
        'FB_STORAGE_BUCKET',
        defaultValue: '$projectId.firebasestorage.app',
      );

  /// Host del relay propio (el S7 Edge, `relay.py`). Vacío = Firebase real.
  /// Solo redirige FIRESTORE; el Auth sigue en Firebase real (decisión del
  /// plan: auth en Firebase, lecturas/datos en el servidor propio).
  static const String relayHost =
      String.fromEnvironment('FB_RELAY_HOST', defaultValue: '');
  static const String relayPort =
      String.fromEnvironment('FB_RELAY_PORT', defaultValue: '8080');
  static const String cloudRelayHost =
      String.fromEnvironment('FB_CLOUD_RELAY_HOST', defaultValue: '');
  static const String backupRelayHost =
      String.fromEnvironment('FB_BACKUP_RELAY_HOST', defaultValue: '');

  static DateTime? _cloudRelayFailedAt;
  static const Duration _cloudRelayCooldown = Duration(seconds: 90);

  static bool get cloudRelayUsable {
    if (useEmulator || cloudRelayHost.trim().isEmpty) return false;
    final failedAt = _cloudRelayFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _cloudRelayCooldown) {
      return false;
    }
    _cloudRelayFailedAt = null;
    return true;
  }

  static bool get backupRelayUsable =>
      !useEmulator && backupRelayHost.trim().isNotEmpty;

  static void markCloudRelayUnreachable() {
    _cloudRelayFailedAt = DateTime.now();
  }

  // ---------------------------------------------------------------------------
  // Fallback de alcance del relay (compatible con Inútil Music)
  // ---------------------------------------------------------------------------

  /// Estado de alcance del relay: `null` = todavía sin medir, `true` = vivo,
  /// `false` = no respondió a la sonda.
  static bool? _relayReachable;

  /// "Este equipo debería estar usando el relay y ahora mismo no lo está".
  static bool _relayRecoveryDesired = false;

  /// `true` sólo cuando hay relay horneado, no estamos en emuladores y la sonda
  /// lo declaró vivo. Es la única puerta de los endpoints redirigidos.
  static bool get relayUsable =>
      relayHost.trim().isNotEmpty && !useEmulator && _relayReachable == true;

  /// Decisión pura de endpoint, expuesta para pruebas: el relay se usa sólo si
  /// está configurado, fuera de emuladores y alcanzable; de lo contrario se
  /// devuelve tal cual el endpoint de Google (o del emulador) que le pase el
  /// llamante.
  @visibleForTesting
  static String relayAwareUrl({
    required String configuredHost,
    required String configuredPort,
    required bool emulator,
    required bool? reachable,
    required String emulatorUrl,
    required String googleUrl,
  }) {
    if (configuredHost.trim().isEmpty) return googleUrl;
    if (emulator) return emulatorUrl;
    if (reachable != true) return googleUrl;
    return 'http://$configuredHost:$configuredPort'
        '${Uri.parse(googleUrl).path}';
  }

  /// Cache en SharedPreferences del último estado medido.
  static const String relayReachabilityCacheKey =
      'inutil_tv_relay_reachable_v1';

  /// Sonda de TCP al relay. Devuelve el estado medido y lo deja en el estado
  /// de clase para que los getters lo respeten de inmediato.
  ///
  /// Prueba los puertos `relayPort` y `5555` en paralelo (el segundo es el
  /// puerto TCP del ADB shell del S7, por si el `relay.py` quedó levantado
  /// sobre otro número) y abandona al primer handshake.
  static Future<bool> probeRelayReachability({
    Duration timeout = const Duration(milliseconds: 1200),
    List<int>? ports,
    String? host,
  }) async {
    final target = (host ?? relayHost).trim();
    if (useEmulator || target.isEmpty) {
      _relayReachable = false;
      return false;
    }
    final candidates = <int>{
      int.tryParse(relayPort.trim()) ?? 8080,
      5555,
    }.toList(growable: false);
    for (final port in ports ?? candidates) {
      if (await _canOpen(target, port, timeout)) {
        _relayReachable = true;
        _relayRecoveryDesired = false;
        return true;
      }
    }
    _relayReachable = false;
    return false;
  }

  static Future<bool> _canOpen(
    String host,
    int port,
    Duration timeout,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  /// Marca el relay como caído y a partir de la siguiente petición los
  /// endpoints vuelven a Google, sin reiniciar la app.
  static void markRelayUnreachable() {
    if (_relayReachable == true) _relayRecoveryDesired = true;
    _relayReachable = false;
  }

  /// Pide que se re-sondee el relay aunque ahora esté marcado caído.
  static void noteRelayRecoveryWanted() {
    if (useEmulator) return;
    _relayRecoveryDesired = true;
  }

  /// `true` sólo cuando la sonda declaró el relay caído y este equipo tiene
  /// relación con él.
  static bool get relayRecoveryWorthy =>
      !useEmulator && _relayReachable == false && _relayRecoveryDesired;

  /// Restablece la medición (pruebas y re-sondas programadas).
  @visibleForTesting
  static void resetRelayReachability() {
    _relayReachable = null;
    _relayRecoveryDesired = false;
  }

  /// Estado actual conocido, para telemetría y pruebas.
  @visibleForTesting
  static bool? get relayReachabilityState => _relayReachable;

  // Endpoints REST oficiales de Google Cloud / Firebase
  static String get authBaseUrl => useEmulator
      ? 'http://$emulatorHost:$emulatorAuthPort/identitytoolkit.googleapis.com/v1'
      : 'https://identitytoolkit.googleapis.com/v1';

  /// Intercambio de `refreshToken` por `idToken` (Secure Token Manager).
  static String get secureTokenUrl => useEmulator
      ? 'http://$emulatorHost:$emulatorAuthPort/securetoken.googleapis.com/v1/token'
      : 'https://securetoken.googleapis.com/v1/token';

  static String get firestoreBaseUrl {
    if (relayUsable) {
      return 'http://$relayHost:$relayPort/v1/projects/$projectId/databases/(default)/documents';
    }
    if (cloudRelayUsable) {
      return 'https://${cloudRelayHost.trim()}/v1/projects/$projectId/databases/(default)/documents';
    }
    if (backupRelayUsable) {
      return 'https://${backupRelayHost.trim()}/v1/projects/$projectId/databases/(default)/documents';
    }
    return useEmulator
        ? 'http://$emulatorHost:$emulatorFirestorePort/v1/projects/$projectId/databases/(default)/documents'
        : 'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents';
  }

  /// El emulador de Auth ignora la clave, pero el endpoint exige el parámetro.
  static String get keyParam => useEmulator ? 'key=emulator' : 'key=$apiKey';
}
