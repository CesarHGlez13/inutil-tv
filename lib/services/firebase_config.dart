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

  // Endpoints REST oficiales de Google Cloud / Firebase
  static String get authBaseUrl => useEmulator
      ? 'http://$emulatorHost:$emulatorAuthPort/identitytoolkit.googleapis.com/v1'
      : 'https://identitytoolkit.googleapis.com/v1';

  /// Intercambio de `refreshToken` por `idToken` (Secure Token Manager).
  static String get secureTokenUrl => useEmulator
      ? 'http://$emulatorHost:$emulatorAuthPort/securetoken.googleapis.com/v1/token'
      : 'https://securetoken.googleapis.com/v1/token';

  static String get firestoreBaseUrl => useEmulator
      ? 'http://$emulatorHost:$emulatorFirestorePort/v1/projects/$projectId/databases/(default)/documents'
      : 'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents';

  /// El emulador de Auth ignora la clave, pero el endpoint exige el parámetro.
  static String get keyParam => useEmulator ? 'key=emulator' : 'key=$apiKey';
}
