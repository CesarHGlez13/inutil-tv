library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  @visibleForTesting
  static String? relayHostOverrideForTest;
  @visibleForTesting
  static int? relayPortOverrideForTest;
  @visibleForTesting
  static String? cloudRelayHostOverrideForTest;
  @visibleForTesting
  static String? backupRelayHostOverrideForTest;

  static String Function()? activeSessionTokenProvider;

  static bool get _hasInutixSession {
    try {
      final tok = activeSessionTokenProvider?.call() ?? '';
      return tok.startsWith('inutix_');
    } catch (_) {
      return false;
    }
  }

  static String get _activeRelayHost =>
      (relayHostOverrideForTest ?? relayHost).trim();
  static String get _activeCloudRelayHost {
    final host = (cloudRelayHostOverrideForTest ?? cloudRelayHost).trim();
    if (host.isNotEmpty) return host;
    if (_hasInutixSession) return 'api.inutix.com';
    return '';
  }
  static String get _activeBackupRelayHost {
    final host = (backupRelayHostOverrideForTest ?? backupRelayHost).trim();
    if (host.isNotEmpty) return host;
    if (_hasInutixSession) return 'backup.inutix.com';
    return '';
  }

  static bool get cloudRelayUsable {
    if (useEmulator || _activeCloudRelayHost.isEmpty) return false;
    final failedAt = _cloudRelayFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _cloudRelayCooldown) {
      return false;
    }
    _cloudRelayFailedAt = null;
    return true;
  }

  static bool get backupRelayUsable =>
      !useEmulator && _activeBackupRelayHost.isNotEmpty;

  /// `true` sólo cuando el prefijo REST de escritura (`firestoreBaseUrl`) apunta a
  /// un relay propio (LAN del S7, `api.inutix.com` o `backup.inutix.com`) y NO a
  /// Google directo.
  ///
  /// Replica la misma cadena de decisión de `firestoreBaseUrl`, pero sin los
  /// efectos secundarios de `cloudRelayUsable` (que limpia su cooldown al
  /// consultarse), porque aquí sólo se quiere responder si el endpoint existe:
  /// `POST metrics/<uid>/daily` vive únicamente en el relay, contra Google no hay
  /// ruta, así que la telemetría diaria no se escribe cuando se resuelve directo.
  static bool get dailyReportEndpointIsRelay =>
      !useEmulator &&
      ((_activeRelayHost.isNotEmpty && _relayReachable == true) ||
       (_activeCloudRelayHost.isNotEmpty &&
        (_cloudRelayFailedAt == null ||
         DateTime.now().difference(_cloudRelayFailedAt!) >=
             _cloudRelayCooldown)) ||
       _activeBackupRelayHost.isNotEmpty);

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
      _activeRelayHost.isNotEmpty && !useEmulator && _relayReachable == true;

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
    final target = (host ?? _activeRelayHost).trim();
    if (useEmulator || target.isEmpty) {
      _relayReachable = false;
      return false;
    }
    final candidates = <int>{
      relayPortOverrideForTest ?? int.tryParse(relayPort.trim()) ?? 8080,
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

  /// Sonda de arranque con cache, la que llama `main.dart`.
  ///
  /// El cache (`relayReachabilityCacheKey`) es sólo telemetría: cada arranque
  /// vuelve a sondear, así que llevar la TV/box a otra red se autodetecta sin
  /// reinstalar nada. Lo que sí se aprovecha del cache es la decisión de
  /// recuperación: si en un arranque anterior este equipo SÍ vivió en la LAN
  /// del relay y ahora no responde, se pide la re-sonda
  /// ([noteRelayRecoveryWanted]). Es el caso medido en casa: `relay.py` o el S7
  /// se reinician con la app ya abierta, y sin esta marca las lecturas se
  /// quedan en Google todo el resto de la sesión pagando la cuota que el relay
  /// ahorra (medido el 2026-11-20: 0 peticiones al relay en 3 minutos, los
  /// heartbeats escritos directo en Google).
  ///
  /// Un build sin `FB_RELAY_HOST` horneado sale antes de tocar nada: no hay
  /// relay que sondear y el comportamiento queda igual que antes. Se lee el
  /// host con el override de pruebas (`_activeRelayHost`) para que la decisión
  /// se pueda ejercitar entera; en producción el override está vacío y la
  /// lectura es la misma constante de siempre.
  static Future<void> probeRelayReachabilityAndCache() async {
    if (_activeRelayHost.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getBool(relayReachabilityCacheKey);
      final reachable = await probeRelayReachability();
      if (reachable) {
        debugPrint(
          'Relay del S7 alcanzable: lecturas por él '
          '(cacheaba ${cached == null ? "nada" : "$cached"}).',
        );
      } else {
        debugPrint(
          'Relay del S7 sin respuesta: lecturas directo a Google '
          '(cacheaba ${cached == null ? "nada" : "$cached"}).',
        );
        if (cached == true) noteRelayRecoveryWanted();
      }
      if (cached != reachable) {
        await prefs.setBool(relayReachabilityCacheKey, reachable);
      }
    } catch (error) {
      debugPrint('Sonda de relay falló (se asume Google): $error');
      markRelayUnreachable();
    }
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

  /// Pide que se re-sondee el relay aunque ahora esté marcado caído. Lo llama
  /// [probeRelayReachabilityAndCache] cuando la sonda de arranque falló PERO
  /// este dispositivo lo declaró vivo en un arranque anterior: es el caso del
  /// S7 levantándose del reboot con la app ya abierta. Quien llama ya descartó
  /// el build sin relay (sale antes si `relayHost` está vacío), así que aquí no
  /// se vuelve a comprobar el host.
  static void noteRelayRecoveryWanted() {
    if (useEmulator) return;
    _relayRecoveryDesired = true;
  }

  /// `true` sólo cuando la sonda declaró el relay caído y este equipo tiene
  /// relación con él. Es la única puerta de la re-sonda de recuperación que
  /// `TvRemoteService` cuelga de su tick de 1.5 s. Nunca se sondea por sondear.
  static bool get relayRecoveryWorthy =>
      !useEmulator && _relayReachable == false && _relayRecoveryDesired;

  /// Restablece la medición (pruebas y re-sondas programadas).
  @visibleForTesting
  static void resetRelayReachability() {
    _relayReachable = null;
    _relayRecoveryDesired = false;
    _cloudRelayFailedAt = null;
    relayHostOverrideForTest = null;
    relayPortOverrideForTest = null;
    cloudRelayHostOverrideForTest = null;
    backupRelayHostOverrideForTest = null;
  }

  /// Permite fijar el estado LAN en pruebas unitarias de failover.
  @visibleForTesting
  static void setRelayReachableForTest(bool? reachable) {
    _relayReachable = reachable;
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
      return 'http://$_activeRelayHost:$relayPort/v1/projects/$projectId/databases/(default)/documents';
    }
    if (cloudRelayUsable) {
      return 'https://$_activeCloudRelayHost/v1/projects/$projectId/databases/(default)/documents';
    }
    if (backupRelayUsable) {
      return 'https://$_activeBackupRelayHost/v1/projects/$projectId/databases/(default)/documents';
    }
    return useEmulator
        ? 'http://$emulatorHost:$emulatorFirestorePort/v1/projects/$projectId/databases/(default)/documents'
        : 'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents';
  }

  /// URL directa de Google Firestore sin pasar por relays/respaldo.
  static String get directFirestoreBaseUrl => useEmulator
      ? 'http://$emulatorHost:$emulatorFirestorePort/v1/projects/$projectId/databases/(default)/documents'
      : 'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents';

  /// El emulador de Auth ignora la clave, pero el endpoint exige el parámetro.
  static String get keyParam => useEmulator ? 'key=emulator' : 'key=$apiKey';
}
