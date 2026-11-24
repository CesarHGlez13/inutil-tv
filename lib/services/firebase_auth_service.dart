import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../constants/app_info.dart';
import 'firebase_config.dart';
import 'firebase_firestore_service.dart';
import 'tv_mode_service.dart';

/// Modelo de usuario unificado de la familia INÚTIL (Inútil Music + InútilTV).
///
/// Las credenciales (`idToken` / `refreshToken`) provienen exclusivamente de
/// Firebase Auth; la vigencia, rol y estado viven en Firestore `users/{uid}`
/// bajo control exclusivo del administrador.
@immutable
class InutilUser {
  const InutilUser({
    required this.uid,
    required this.email,
    this.displayName = '',
    this.idToken = '',
    this.refreshToken = '',
    this.accountExpiresAt,
    this.isActive = true,
    this.role = 'user',
    this.accountDurationDays = 30,
    this.createdAt,
    this.lastLoginAt,
    this.status = 'pending',
    this.currentPhoneDeviceId = '',
    this.currentTvDeviceId = '',
    this.currentSmartTvDeviceId = '',
    this.phoneSwitchCount = 0,
    this.phoneSwitchMonth = '',
  });

  final String uid;
  final String email;
  final String displayName;
  final String idToken;
  final String refreshToken;
  final DateTime? accountExpiresAt;
  final bool isActive;
  final String role;
  final int accountDurationDays;
  final DateTime? createdAt;
  final DateTime? lastLoginAt;

  /// Estado de licencia gestionado por el administrador:
  /// `pending` (registrado, sin vigencia) | `active` | `blocked`.
  final String status;

  /// Teléfono registrado en Inútil Music (`currentPhoneDeviceId`).
  final String currentPhoneDeviceId;

  /// Celular activo registrado en InútilTV (`currentTvDeviceId`).
  /// Se mantiene separado de `currentPhoneDeviceId` (Inútil Music) y de
  /// `currentSmartTvDeviceId` (Smart TV / TV Box) para permitir 1 celular y
  /// 1 Smart TV activos al mismo tiempo en la cuenta gratuita.
  final String currentTvDeviceId;

  /// Smart TV / Android TV / TV Box activa vinculada a esta cuenta.
  final String currentSmartTvDeviceId;

  /// Cambios de teléfono realizados en el mes en curso (Inútil Music).
  final int phoneSwitchCount;
  final String phoneSwitchMonth;

  /// Administrador solo por rol (Firebase Auth/Firestore). Ya no se decide
  /// por UID ni por correo hardcodeados: conocer el correo no es un secreto.
  bool get isAdmin => role == 'admin';

  /// Licencia Premium Permanente (año 2090 en adelante o rol admin).
  bool get isPermanent =>
      isAdmin || (accountExpiresAt != null && accountExpiresAt!.year >= 2090);

  /// Estado de expiración: administradores y permanentes nunca expiran.
  bool get isExpired {
    if (isAdmin || isPermanent) return false;
    if (accountExpiresAt == null) return true;
    return DateTime.now().isAfter(accountExpiresAt!);
  }

  /// Días restantes de vigencia.
  int get daysRemaining {
    if (isAdmin || isPermanent) return 9999;
    if (accountExpiresAt == null) return 0;
    final diff = accountExpiresAt!.difference(DateTime.now()).inDays;
    return diff > 0 ? diff : 0;
  }

  /// Indica si la licencia es válida para reproducir contenido.
  bool get licenseValid {
    if (isAdmin) return true;
    return isActive && status == 'active' && !isExpired;
  }

  bool get hasAnyBoundDevice =>
      currentPhoneDeviceId.isNotEmpty ||
      currentTvDeviceId.isNotEmpty ||
      currentSmartTvDeviceId.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'email': email,
        'displayName': displayName,
        'idToken': idToken,
        'refreshToken': refreshToken,
        'accountExpiresAt': accountExpiresAt?.toIso8601String(),
        'isActive': isActive,
        'role': role,
        'accountDurationDays': accountDurationDays,
        'createdAt': createdAt?.toIso8601String(),
        'lastLoginAt': lastLoginAt?.toIso8601String(),
        'status': status,
        'currentPhoneDeviceId': currentPhoneDeviceId,
        'currentTvDeviceId': currentTvDeviceId,
        'currentSmartTvDeviceId': currentSmartTvDeviceId,
        'phoneSwitchCount': phoneSwitchCount,
        'phoneSwitchMonth': phoneSwitchMonth,
      };

  factory InutilUser.fromJson(Map<String, dynamic> json) {
    return InutilUser(
      uid: json['uid'] as String? ?? '',
      email: json['email'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      idToken: json['idToken'] as String? ?? '',
      refreshToken: json['refreshToken'] as String? ?? '',
      accountExpiresAt: json['accountExpiresAt'] != null
          ? DateTime.tryParse(json['accountExpiresAt'].toString())
          : null,
      isActive: json['isActive'] as bool? ?? true,
      role: json['role'] as String? ?? 'user',
      accountDurationDays: (json['accountDurationDays'] as num?)?.toInt() ?? 30,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString())
          : null,
      lastLoginAt: json['lastLoginAt'] != null
          ? DateTime.tryParse(json['lastLoginAt'].toString())
          : null,
      status: json['status'] as String? ?? 'pending',
      currentPhoneDeviceId: json['currentPhoneDeviceId'] as String? ?? '',
      currentTvDeviceId: json['currentTvDeviceId'] as String? ?? '',
      currentSmartTvDeviceId: json['currentSmartTvDeviceId'] as String? ?? '',
      phoneSwitchCount: (json['phoneSwitchCount'] as num?)?.toInt() ?? 0,
      phoneSwitchMonth: json['phoneSwitchMonth'] as String? ?? '',
    );
  }

  InutilUser copyWith({
    String? displayName,
    String? idToken,
    String? refreshToken,
    DateTime? accountExpiresAt,
    bool? isActive,
    String? role,
    int? accountDurationDays,
    DateTime? createdAt,
    DateTime? lastLoginAt,
    String? status,
    String? currentPhoneDeviceId,
    String? currentTvDeviceId,
    String? currentSmartTvDeviceId,
    int? phoneSwitchCount,
    String? phoneSwitchMonth,
  }) {
    return InutilUser(
      uid: uid,
      email: email,
      displayName: displayName ?? this.displayName,
      idToken: idToken ?? this.idToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accountExpiresAt: accountExpiresAt ?? this.accountExpiresAt,
      isActive: isActive ?? this.isActive,
      role: role ?? this.role,
      accountDurationDays: accountDurationDays ?? this.accountDurationDays,
      createdAt: createdAt ?? this.createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      status: status ?? this.status,
      currentPhoneDeviceId: currentPhoneDeviceId ?? this.currentPhoneDeviceId,
      currentTvDeviceId: currentTvDeviceId ?? this.currentTvDeviceId,
      currentSmartTvDeviceId:
          currentSmartTvDeviceId ?? this.currentSmartTvDeviceId,
      phoneSwitchCount: phoneSwitchCount ?? this.phoneSwitchCount,
      phoneSwitchMonth: phoneSwitchMonth ?? this.phoneSwitchMonth,
    );
  }
}

/// Servicio integral de autenticación y administración Firebase para InútilTV.
///
/// Comparte cuentas, roles y licencias en tiempo real con Inútil Music sobre
/// el mismo proyecto Firebase (`inutil-music-app`):
///   * Autenticación REAL contra Firebase Auth (Identity Toolkit REST v1).
///   * Tokens guardados en `flutter_secure_storage` (fallback seguro a prefs).
///   * Licencias y roles gobernados por Firestore `users/{uid}` y sus reglas.
class InutilAuthService extends ChangeNotifier {
  InutilAuthService._();
  static final InutilAuthService instance = InutilAuthService._();

  static const _storageUserKey = 'inutil_tv_auth_user_v3';
  static const _storageDeviceIdKey = 'inutil_tv_device_id_v3';
  static const _storageSessionKey = 'inutil_tv_auth_session_v3';
  static const _storageUsersCacheKey = 'inutil_tv_users_cache_v3';
  static const _storageLastValidatedKey = 'inutil_tv_last_validated_v3';

  // Claves legadas de la autenticación local antigua (se purgan al migrar).
  static const _legacySessionKey = 'inutiltv_auth_session';
  static const _legacyLicensesKey = 'inutiltv_custom_licenses';

  /// Correos del administrador fundador (misma identidad verificada por las
  /// reglas de Firestore de la familia Inútil). No son credenciales: Firebase
  /// Auth o Google Sign-In siguen exigiendo la autenticación real.
  static const String bootstrapAdminEmail = 'cesar@inutilmusic.com';
  static const Set<String> bootstrapAdminEmails = {
    'cesar@inutilmusic.com',
    'humbertoglez96@gmail.com',
    'cesarmaster133@gmail.com',
  };

  static bool isBootstrapAdminEmail(String email) =>
      bootstrapAdminEmails.contains(email.trim().toLowerCase());

  /// Ventana de gracia sin validación en línea (72 h).
  static const Duration offlineGrace = Duration(hours: 72);

  /// Política de inactividad compartida con Inútil Music (`app_config/inactivity_policy`).
  static const int defaultInactivityDays = 15;
  static const int _minInactivityDays = 2;
  static const int _maxInactivityDays = 365;
  static const Duration _heartbeatThrottle = Duration(hours: 1);

  /// Decide si una cuenta gratuita debe quedar en pausa por inactividad.
  static int? inactivityPauseDays({
    required DateTime? lastActiveAt,
    required bool exempt,
    required bool enabled,
    required int thresholdDays,
    required DateTime now,
  }) {
    if (!enabled || exempt || lastActiveAt == null) return null;
    final days = now.difference(lastActiveAt).inDays;
    return days >= thresholdDays ? days : null;
  }

  /// Cambios mensuales de teléfono permitidos (compartido con Inútil Music).
  static const int maxMonthlyPhoneSwitches = 3;

  static const Duration _validateInterval = Duration(minutes: 15);
  static const Duration _secureTimeout = Duration(seconds: 3);

  @visibleForTesting
  static bool testSkipOnlineValidation = false;

  bool get isOnlineValidationDisabled => testSkipOnlineValidation;

  @visibleForTesting
  void testSeedLicenseValidation(DateTime validatedAt) {
    _lastValidatedAt = validatedAt;
  }

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true, migrateOnAlgorithmChange: true),
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );

  InutilUser? _currentUser;
  String? _deviceId;
  String? _deviceName;
  String? _devicePlatform;
  DateTime? _lastValidatedAt;
  Timer? _validateTimer;
  bool _validating = false;
  bool _initialized = false;
  String _kickedOutReason = '';
  bool _inactivityPolicyEnabled = true;
  int _inactivityPolicyDays = defaultInactivityDays;
  bool _inactivityPaused = false;
  int _inactiveDays = 0;
  DateTime? _lastHeartbeatAt;

  InutilUser? get currentUser => _currentUser;
  bool get isInitialized => _initialized;
  bool get isAuthenticated => _currentUser != null;
  bool get isKickedOut => _kickedOutReason.isNotEmpty;
  String get kickedOutReason => _kickedOutReason;
  DateTime? get lastValidatedAt => _lastValidatedAt;
  bool get isInactivityPaused => _inactivityPaused;
  int get inactiveDays => _inactiveDays;
  int get inactivityPolicyDays => _inactivityPolicyDays;

  String get deviceId => _deviceId ?? 'unknown_device';
  String get deviceName => _deviceName ?? 'Inutix TV Client';
  String get devicePlatform => _devicePlatform ?? 'generic';

  /// Control estricto de acceso (Gatekeeper):
  /// sesión válida + sin expulsión + sin pausa de inactividad + (admin O licencia vigente).
  bool get isAccessAllowed =>
      _currentUser != null &&
      _kickedOutReason.isEmpty &&
      !_inactivityPaused &&
      (_currentUser!.isAdmin || _currentUser!.licenseValid);

  /// `true` si además la validación remota está dentro de la ventana de 72 h.
  bool get canPlay => _currentUser != null && _licenseFresh();

  /// Explicación legible del estado de bloqueo.
  String get blockedReason {
    final user = _currentUser;
    if (user == null) return 'Inicia sesión para ver Inutix TV.';
    if (_kickedOutReason.isNotEmpty) return _kickedOutReason;
    if (!user.isAdmin && user.status == 'pending') {
      return 'Tu cuenta está registrada pero pendiente de aprobación. '
          'El administrador debe activar tu vigencia.';
    }
    if (!user.isAdmin && (!user.isActive || user.status == 'blocked')) {
      return 'Tu cuenta fue suspendida por el administrador.';
    }
    if (user.isExpired) {
      return 'Tu vigencia terminó. Solicita al administrador una renovación.';
    }
    if (!_tvSessionOk(user)) {
      return _isSmartTvSlot
          ? 'Otro dispositivo (Smart TV) tomó el control de esta cuenta en Inutix TV. '
              'Tu cuenta incluye 1 celular y 1 Smart TV a la vez.'
          : 'Otro dispositivo (celular) tomó el control de esta cuenta en Inutix TV. '
              'Tu cuenta incluye 1 celular y 1 Smart TV a la vez.';
    }
    if (!_licenseFresh()) {
      return 'Necesitas conexión a internet para validar tu licencia '
          '(última validación hace más de 72 horas).';
    }
    return '';
  }

  /// Cada cuenta gratuita permite **1 celular** (`currentTvDeviceId`) y
  /// **1 Smart TV / TV Box** (`currentSmartTvDeviceId`) activos a la vez.
  bool get _isSmartTvSlot => TvModeService.instance.isTv;

  bool _tvSessionOk(InutilUser user) {
    if (user.isAdmin) return true;
    final bound = _isSmartTvSlot
        ? user.currentSmartTvDeviceId
        : user.currentTvDeviceId;
    return bound.isEmpty || bound == _deviceId;
  }

  bool _licenseFresh() {
    final user = _currentUser;
    if (user == null) return false;
    if (!user.licenseValid) return false;
    if (_inactivityPaused) return false;
    if (!_tvSessionOk(user)) return false;
    if (user.isAdmin) return true;
    final validated = _lastValidatedAt;
    if (validated == null) return false;
    return DateTime.now().difference(validated) <= offlineGrace;
  }

  // ---------------------------------------------------------------------------
  // 1. ARRANQUE Y PERSISTENCIA DE SESIÓN
  // ---------------------------------------------------------------------------
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();

    // Purga de claves locales antiguas (antes de Firebase)
    await _migrateLegacy(prefs);

    // 1. Identificación única de dispositivo
    _deviceId = prefs.getString(_storageDeviceIdKey);
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = const Uuid().v4();
      await prefs.setString(_storageDeviceIdKey, _deviceId!);
    }

    if (Platform.isAndroid) {
      _devicePlatform = 'android';
      _deviceName = 'Android / TV';
    } else if (Platform.isLinux) {
      _devicePlatform = 'linux';
      _deviceName = 'PC Linux';
    } else if (Platform.isWindows) {
      _devicePlatform = 'windows';
      _deviceName = 'PC Windows';
    } else {
      _devicePlatform = 'desktop';
      _deviceName = 'Desktop';
    }

    final savedValidated = prefs.getString(_storageLastValidatedKey);
    if (savedValidated != null) {
      _lastValidatedAt = DateTime.tryParse(savedValidated);
    }

    // 2. Restaurar sesión desde almacenamiento seguro (o fallback prefs)
    final sessionJson = await _readSecure(prefs, _storageSessionKey);
    if (sessionJson != null) {
      try {
        final map = jsonDecode(sessionJson) as Map<String, dynamic>;
        final snap = prefs.getString(_storageUserKey);
        var user = snap != null
            ? InutilUser.fromJson(jsonDecode(snap) as Map<String, dynamic>)
            : InutilUser.fromJson({
                'uid': map['uid'] ?? '',
                'email': map['email'] ?? '',
              });
        user = user.copyWith(
          idToken: map['idToken'] as String? ?? user.idToken,
          refreshToken: map['refreshToken'] as String? ?? user.refreshToken,
        );
        if (isBootstrapAdminEmail(user.email)) {
          user = user.copyWith(
            role: 'admin',
            status: 'active',
            isActive: true,
            accountExpiresAt: user.accountExpiresAt ?? DateTime(2099, 12, 31),
          );
        }
        _currentUser = user;
      } catch (e) {
        debugPrint('[InutilAuth] Error decodificando sesión guardada: $e');
        await _clearSession(prefs);
      }
    }

    _initialized = true;
    notifyListeners();

    if (_currentUser == null) return;

    // 3. Refrescar idToken y validar licencia contra Firestore
    await _ensureFreshIdToken();
    unawaited(_validateSession(reason: 'arranque'));
    if (!testSkipOnlineValidation) _startValidationTimer();
  }

  void _startValidationTimer() {
    _validateTimer?.cancel();
    _validateTimer = Timer.periodic(_validateInterval, (_) {
      unawaited(_validateSession(reason: 'temporizador'));
    });
  }

  /// Revalida la licencia al volver a primer plano.
  Future<void> onAppResumed() async {
    if (_currentUser == null) return;
    await _ensureFreshIdToken();
    await _validateSession(reason: 'reanudada');
  }

  Future<void> _migrateLegacy(SharedPreferences prefs) async {
    if (prefs.containsKey(_legacySessionKey)) {
      await prefs.remove(_legacySessionKey);
    }
    if (prefs.containsKey(_legacyLicensesKey)) {
      await prefs.remove(_legacyLicensesKey);
    }
  }

  Future<String?> _readSecure(SharedPreferences prefs, String key) async {
    try {
      final v = await _secure.read(key: key).timeout(_secureTimeout);
      if (v != null && v.isNotEmpty) return v;
    } catch (e) {
      debugPrint('[InutilAuth] SecureStorage no disponible ($e); usando prefs');
    }
    return prefs.getString(key);
  }

  Future<void> _writeSecure(
    SharedPreferences prefs,
    String key,
    String value,
  ) async {
    try {
      await _secure.write(key: key, value: value).timeout(_secureTimeout);
      await prefs.remove(key);
    } catch (e) {
      debugPrint('[InutilAuth] SecureStorage falló ($e); espejando en prefs');
      await prefs.setString(key, value);
    }
  }

  Future<void> _deleteSecure(SharedPreferences prefs, String key) async {
    try {
      await _secure.delete(key: key).timeout(_secureTimeout);
    } catch (_) {}
    await prefs.remove(key);
  }

  Future<void> _clearSession(SharedPreferences prefs) async {
    await _deleteSecure(prefs, _storageSessionKey);
    await prefs.remove(_storageUserKey);
    await prefs.remove(_storageLastValidatedKey);
    _currentUser = null;
    _lastValidatedAt = null;
    notifyListeners();
  }

  Future<void> _saveSession() async {
    final user = _currentUser;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    await _writeSecure(
      prefs,
      _storageSessionKey,
      jsonEncode({
        'uid': user.uid,
        'email': user.email,
        'idToken': user.idToken,
        'refreshToken': user.refreshToken,
        'savedAt': DateTime.now().toIso8601String(),
      }),
    );
    await prefs.setString(_storageUserKey, jsonEncode(user.toJson()));
    if (_lastValidatedAt != null) {
      await prefs.setString(
        _storageLastValidatedKey,
        _lastValidatedAt!.toIso8601String(),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 2. FIREBASE AUTH REST (Identity Toolkit v1)
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> _authPost(
    String path,
    Map<String, dynamic> body,
  ) async {
    final url =
        Uri.parse('${FirebaseConfig.authBaseUrl}/$path?${FirebaseConfig.keyParam}');
    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    final decoded = _tryDecode(response.body);
    final message =
        decoded['error']?['message']?.toString() ?? 'Error de autenticación';
    throw Exception(_mapAuthError(message));
  }

  static Map<String, dynamic> _tryDecode(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Intercambio público de `refreshToken` por un `idToken` nuevo (útil tras 401).
  Future<bool> ensureFreshIdToken({bool force = false}) =>
      _ensureFreshIdToken(force: force);

  /// Intercambio de `refreshToken` por un `idToken` nuevo.
  Future<bool> _ensureFreshIdToken({bool force = false}) async {
    final user = _currentUser;
    if (user == null || user.refreshToken.isEmpty) return false;
    if (testSkipOnlineValidation) return _idTokenValid(user.idToken);
    if (!force && _idTokenValid(user.idToken)) return true;
    try {
      final url = Uri.parse(
        '${FirebaseConfig.secureTokenUrl}?${FirebaseConfig.keyParam}',
      );
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'grant_type': 'refresh_token',
              'refresh_token': user.refreshToken,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return false;
      final data = _tryDecode(response.body);
      final idToken = data['id_token'] as String? ?? '';
      if (idToken.isEmpty) return false;
      _currentUser = user.copyWith(
        idToken: idToken,
        refreshToken: (data['refresh_token'] as String?) ?? user.refreshToken,
      );
      await _saveSession();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[InutilAuth] Fallo refrescando idToken: $e');
      return false;
    }
  }

  static bool _idTokenValid(String idToken) {
    if (idToken.isEmpty) return false;
    try {
      final parts = idToken.split('.');
      if (parts.length < 2) return false;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final exp = (payload['exp'] as num?)?.toInt() ?? 0;
      return exp - DateTime.now().millisecondsSinceEpoch ~/ 1000 > 60;
    } catch (_) {
      return false;
    }
  }

  /// Registro de usuario con Correo y Contraseña (Firebase Auth real).
  /// El alta queda en `status: 'pending'` hasta que el Administrador la active.
  Future<InutilUser> register({
    required String email,
    required String password,
    String? displayName,
  }) async {
    final trimmedEmail = email.trim().toLowerCase();
    if (trimmedEmail.isEmpty || password.length < 6) {
      throw Exception(
        'El correo y la contraseña (mínimo 6 caracteres) son obligatorios.',
      );
    }

    final data = await _authPost('accounts:signUp', {
      'email': trimmedEmail,
      'password': password,
      'returnSecureToken': true,
    });

    final user = InutilUser(
      uid: data['localId'] as String,
      email: trimmedEmail,
      displayName: displayName?.trim().isNotEmpty == true
          ? displayName!.trim()
          : trimmedEmail.split('@').first,
      idToken: data['idToken'] as String? ?? '',
      refreshToken: data['refreshToken'] as String? ?? '',
      accountExpiresAt: null,
      isActive: false,
      status: 'pending',
      accountDurationDays: 0,
      createdAt: DateTime.now(),
      lastLoginAt: DateTime.now(),
    );

    _currentUser = user;
    _kickedOutReason = '';
    await _saveSession();
    await _bootstrapSession(createIfMissing: true);
    if (!testSkipOnlineValidation) _startValidationTimer();
    notifyListeners();
    return _currentUser!;
  }

  /// Inicio de sesión con Correo y Contraseña (Firebase Auth real).
  Future<InutilUser> signIn({
    required String email,
    required String password,
  }) async {
    final trimmedEmail = email.trim().toLowerCase();

    final data = await _authPost('accounts:signInWithPassword', {
      'email': trimmedEmail,
      'password': password,
      'returnSecureToken': true,
    });

    final user = InutilUser(
      uid: data['localId'] as String,
      email: trimmedEmail,
      displayName:
          (data['displayName'] as String?)?.isNotEmpty == true
              ? data['displayName'] as String
              : trimmedEmail.split('@').first,
      idToken: data['idToken'] as String? ?? '',
      refreshToken: data['refreshToken'] as String? ?? '',
      createdAt: DateTime.now(),
      lastLoginAt: DateTime.now(),
    );

    _currentUser = user;
    _kickedOutReason = '';
    await _saveSession();
    await _bootstrapSession(createIfMissing: true);
    if (!testSkipOnlineValidation) _startValidationTimer();
    notifyListeners();
    return _currentUser!;
  }

  /// Inicio de sesión o registro con cuenta de Google (Google Sign-In nativo
  /// + intercambio `accounts:signInWithIdp` contra Firebase Auth REST).
  ///
  /// Los usuarios nuevos con Google entran igualmente al flujo de control de
  /// vigencia (`status: 'pending'`) hasta que el administrador les conceda
  /// acceso, salvo los correos fundadores en [bootstrapAdminEmails].
  Future<InutilUser?> signInWithGoogle() async {
    final googleSignIn = GoogleSignIn(
      scopes: const ['email', 'profile'],
      serverClientId: FirebaseConfig.googleWebClientId,
    );

    GoogleSignInAccount? account;
    try {
      account = await googleSignIn.signIn();
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('ApiException: 10')) {
        throw Exception(
          'Configuración OAuth de Google (código 10). Verifica que estés usando el APK oficial firmado.',
        );
      }
      if (msg.contains('ApiException: 7') || msg.contains('network')) {
        throw Exception('Sin conexión a internet para iniciar sesión con Google.');
      }
      if (msg.contains('MissingPluginException') ||
          msg.contains('not available')) {
        throw Exception(
          'Este equipo no tiene Google Play Services. Inicia sesión con correo y contraseña.',
        );
      }
      throw Exception('No se pudo conectar con Google: $msg');
    }

    // Usuario canceló el selector de cuenta de Google.
    if (account == null) return null;

    final googleAuth = await account.authentication;
    final googleIdToken = googleAuth.idToken;
    final googleAccessToken = googleAuth.accessToken;
    if ((googleIdToken == null || googleIdToken.isEmpty) &&
        (googleAccessToken == null || googleAccessToken.isEmpty)) {
      throw Exception(
        'Google no devolvió un token válido. Intenta de nuevo o usa correo y contraseña.',
      );
    }

    final postBody = (googleIdToken != null && googleIdToken.isNotEmpty)
        ? 'id_token=$googleIdToken&providerId=google.com'
        : 'access_token=$googleAccessToken&providerId=google.com';

    final data = await _authPost('accounts:signInWithIdp', {
      'postBody': postBody,
      'requestUri': 'http://localhost',
      'returnIdpCredential': true,
      'returnSecureToken': true,
    });

    final email =
        (data['email'] as String? ?? account.email).trim().toLowerCase();
    final displayName = (data['displayName'] as String?)?.isNotEmpty == true
        ? data['displayName'] as String
        : ((account.displayName?.isNotEmpty == true)
            ? account.displayName!
            : email.split('@').first);

    final user = InutilUser(
      uid: data['localId'] as String,
      email: email,
      displayName: displayName,
      idToken: data['idToken'] as String? ?? '',
      refreshToken: data['refreshToken'] as String? ?? '',
      createdAt: DateTime.now(),
      lastLoginAt: DateTime.now(),
    );

    _currentUser = user;
    _kickedOutReason = '';
    await _saveSession();
    await _bootstrapSession(createIfMissing: true);
    if (!testSkipOnlineValidation) _startValidationTimer();
    notifyListeners();
    return _currentUser!;
  }

  /// Cambio de contraseña de la cuenta en sesión (`accounts:update`).
  Future<void> changePassword(String newPassword) async {
    final user = _currentUser;
    if (user == null || user.idToken.isEmpty) {
      throw Exception('Inicia sesión antes de cambiar la contraseña.');
    }
    if (newPassword.length < 6) {
      throw Exception('La nueva contraseña debe tener al menos 6 caracteres.');
    }
    await _ensureFreshIdToken();
    final data = await _authPost('accounts:update', {
      'idToken': _currentUser!.idToken,
      'password': newPassword,
      'returnSecureToken': true,
    });
    _currentUser = _currentUser!.copyWith(
      idToken: data['idToken'] as String? ?? _currentUser!.idToken,
      refreshToken:
          data['refreshToken'] as String? ?? _currentUser!.refreshToken,
    );
    await _saveSession();
    notifyListeners();
  }

  /// Cierre de sesión seguro: libera `currentTvDeviceId` en Firestore.
  Future<void> signOut() async {
    final user = _currentUser;
    final prefs = await SharedPreferences.getInstance();
    if (user != null &&
        !testSkipOnlineValidation &&
        user.idToken.isNotEmpty &&
        !user.isAdmin) {
      try {
        await InutilFirestoreService.instance.setDocument(
          'users/${user.uid}',
          {'currentTvDeviceId': ''},
          merge: true,
        );
      } catch (_) {}
    }
    _validateTimer?.cancel();
    _validateTimer = null;
    _kickedOutReason = '';
    _inactivityPaused = false;
    _inactiveDays = 0;
    if (!testSkipOnlineValidation) {
      try {
        await GoogleSignIn().signOut();
      } catch (_) {}
    }
    await _clearSession(prefs);
  }

  /// Recuperación de contraseña por correo.
  Future<void> sendPasswordReset(String email) async {
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty) return;
    try {
      await _authPost('accounts:sendOobCode', {
        'requestType': 'PASSWORD_RESET',
        'email': trimmedEmail,
      });
    } catch (_) {
      // Respuesta neutra por seguridad: no revela si el correo existe.
    }
  }

  @override
  // ignore: must_call_super
  void dispose() {
    // Singleton persistente durante la vida de la app.
  }

  // ---------------------------------------------------------------------------
  // 3. LICENCIA EN FIRESTORE: arranque de sesión, validez y control de equipo
  // ---------------------------------------------------------------------------
  Future<void> _bootstrapSession({required bool createIfMissing}) async {
    final user = _currentUser;
    if (user == null || user.uid.isEmpty || user.idToken.isEmpty) return;
    try {
      final remote =
          await InutilFirestoreService.instance.getUserProfile(user.uid);
      if (remote == null || remote.isEmpty) {
        if (!createIfMissing) return;
        final isAdminSeed = isBootstrapAdminEmail(user.email);
        final seeded = <String, dynamic>{
          'uid': user.uid,
          'email': user.email,
          'displayName': user.displayName,
          'role': isAdminSeed ? 'admin' : 'user',
          'status': isAdminSeed ? 'active' : 'pending',
          'isActive': isAdminSeed,
          'accountExpiresAt': isAdminSeed ? DateTime(2099, 12, 31) : null,
          'accountDurationDays': isAdminSeed ? 9999 : 0,
          'currentPhoneDeviceId': '',
          'currentTvDeviceId': _isSmartTvSlot ? '' : deviceId,
          'currentSmartTvDeviceId': _isSmartTvSlot ? deviceId : '',
          'phoneSwitchCount': 0,
          'phoneSwitchMonth': '',
          'createdAt': DateTime.now(),
          'lastLoginAt': DateTime.now(),
          'lastValidatedAt': DateTime.now(),
          'schemaVersion': 3,
        };
        final ok = await InutilFirestoreService.instance.setDocument(
          'users/${user.uid}',
          seeded,
          merge: false,
        );
        if (ok) {
          _lastValidatedAt = DateTime.now();
          _currentUser = user.copyWith(
            role: isAdminSeed ? 'admin' : 'user',
            status: isAdminSeed ? 'active' : 'pending',
            isActive: isAdminSeed,
            accountExpiresAt: isAdminSeed ? DateTime(2099, 12, 31) : null,
            currentTvDeviceId: _isSmartTvSlot ? '' : deviceId,
            currentSmartTvDeviceId: _isSmartTvSlot ? deviceId : '',
          );
          await _saveSession();
        }
        return;
      }

      await _applyRemoteDoc(remote);

      // Si alguno de los correos fundadores ya tenía documento sin rol admin,
      // lo eleva (las reglas de Firestore solo permiten esto para dichos correos).
      final me = _currentUser;
      if (me != null && isBootstrapAdminEmail(me.email) && !me.isAdmin) {
        final upgraded = await InutilFirestoreService.instance.setDocument(
          'users/${me.uid}',
          {
            'role': 'admin',
            'status': 'active',
            'isActive': true,
            'accountExpiresAt': DateTime(2099, 12, 31),
          },
          merge: true,
        );
        if (upgraded) {
          _currentUser = me.copyWith(
            role: 'admin',
            status: 'active',
            isActive: true,
            accountExpiresAt: DateTime(2099, 12, 31),
          );
          await _saveSession();
        }
      }

      await _claimTvDevice();
      if (_currentUser?.licenseValid == true) {
        await _enforceInactivityPolicy(remote);
      }
    } catch (e) {
      debugPrint('[InutilAuth] Bootstrap de sesión sin respuesta remota: $e');
    }
  }

  Future<void> _applyRemoteDoc(Map<String, dynamic> remote) async {
    final user = _currentUser;
    if (user == null) return;
    final rawExpiry = remote['accountExpiresAt'];
    final expiresAt = rawExpiry is DateTime
        ? rawExpiry
        : (rawExpiry != null ? DateTime.tryParse(rawExpiry.toString()) : null);
    final role = remote['role'] as String? ?? user.role;
    final status = remote['status'] as String? ??
        ((remote['isActive'] as bool?) == false ? 'blocked' : user.status);
    final isActive = (remote['isActive'] as bool?) ?? user.isActive;

    _currentUser = user.copyWith(
      accountExpiresAt: expiresAt,
      isActive: isActive,
      role: role,
      status: status,
      displayName: (remote['displayName'] as String?)?.isNotEmpty == true
          ? remote['displayName'] as String
          : user.displayName,
      currentPhoneDeviceId:
          remote['currentPhoneDeviceId'] as String? ?? user.currentPhoneDeviceId,
      currentTvDeviceId:
          remote['currentTvDeviceId'] as String? ?? user.currentTvDeviceId,
      currentSmartTvDeviceId: remote['currentSmartTvDeviceId'] as String? ??
          user.currentSmartTvDeviceId,
      phoneSwitchCount:
          (remote['phoneSwitchCount'] as num?)?.toInt() ?? user.phoneSwitchCount,
      phoneSwitchMonth:
          remote['phoneSwitchMonth'] as String? ?? user.phoneSwitchMonth,
    );
    _lastValidatedAt = DateTime.now();

    // Si la licencia pasó a válida y el equipo coincide, limpiamos expulsión previa.
    if (_currentUser!.isAdmin ||
        (_currentUser!.licenseValid && _tvSessionOk(_currentUser!))) {
      _kickedOutReason = '';
    }

    await _saveSession();
    notifyListeners();
  }

  /// Reclama la ranura correspondiente (celular -> `currentTvDeviceId`,
  /// Smart TV -> `currentSmartTvDeviceId`) sin tocar `currentPhoneDeviceId`
  /// de Inútil Music ni la otra ranura (permite 1 celular + 1 Smart TV).
  Future<void> _claimTvDevice() async {
    final user = _currentUser;
    if (user == null || !user.licenseValid) return;

    final isTvSlot = _isSmartTvSlot;
    final fieldName =
        isTvSlot ? 'currentSmartTvDeviceId' : 'currentTvDeviceId';
    final alreadyMine = isTvSlot
        ? user.currentSmartTvDeviceId == deviceId
        : user.currentTvDeviceId == deviceId;
    if (alreadyMine) return;

    final ok = await InutilFirestoreService.instance.setDocument(
      'users/${user.uid}',
      {
        fieldName: deviceId,
        'lastLoginAt': DateTime.now(),
        'lastValidatedAt': DateTime.now(),
      },
      merge: true,
    );
    if (ok) {
      _currentUser = isTvSlot
          ? user.copyWith(currentSmartTvDeviceId: deviceId)
          : user.copyWith(currentTvDeviceId: deviceId);
      _kickedOutReason = '';
      await _saveSession();
      notifyListeners();
    }
  }

  /// Inicia sesión automáticamente en la Smart TV usando un `refreshToken`
  /// recibido mediante el flujo de vinculación QR cifrado desde el celular.
  ///
  /// Devuelve `null` si todo salió bien, o un mensaje legible si falló.
  Future<String?> signInWithPairedRefreshToken(
    String refreshToken, {
    String emailHint = '',
    String displayNameHint = '',
  }) async {
    final token = refreshToken.trim();
    if (token.isEmpty) return 'La sesión enviada desde el celular está vacía.';
    try {
      final tokenUrl = Uri.parse(
        '${FirebaseConfig.secureTokenUrl}?${FirebaseConfig.keyParam}',
      );
      final tokenRes = await http
          .post(
            tokenUrl,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'grant_type': 'refresh_token',
              'refresh_token': token,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (tokenRes.statusCode != 200) {
        return 'El celular debe tener sesión activa vigente para vincular la TV.';
      }
      final data = _tryDecode(tokenRes.body);
      final idToken = data['id_token'] as String? ?? '';
      final uid = data['user_id'] as String? ?? '';
      final newRefresh = (data['refresh_token'] as String?) ?? token;
      if (idToken.isEmpty || uid.isEmpty) {
        return 'No se pudo validar la sesión recibida.';
      }

      // Recuperar correo y nombre reales desde Firebase Identity Toolkit.
      var email = emailHint.trim();
      var displayName = displayNameHint.trim();
      try {
        final lookupUrl = Uri.parse(
          '${FirebaseConfig.authBaseUrl}/accounts:lookup?${FirebaseConfig.keyParam}',
        );
        final lookupRes = await http
            .post(
              lookupUrl,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'idToken': idToken}),
            )
            .timeout(const Duration(seconds: 8));
        if (lookupRes.statusCode == 200) {
          final lData = _tryDecode(lookupRes.body);
          final users = lData['users'] as List?;
          if (users != null && users.isNotEmpty && users.first is Map) {
            final u = users.first as Map;
            final e = (u['email'] ?? '').toString().trim();
            final d = (u['displayName'] ?? '').toString().trim();
            if (e.isNotEmpty) email = e;
            if (d.isNotEmpty) displayName = d;
          }
        }
      } catch (_) {}

      final isAdmin = isBootstrapAdminEmail(email);
      final baseUser = InutilUser(
        uid: uid,
        email: email,
        displayName: displayName.isNotEmpty
            ? displayName
            : (email.contains('@') ? email.split('@').first : 'Usuario'),
        idToken: idToken,
        refreshToken: newRefresh,
        role: isAdmin ? 'admin' : 'user',
        status: isAdmin ? 'active' : 'pending',
        isActive: isAdmin,
        accountExpiresAt: isAdmin ? DateTime(2099, 12, 31) : null,
      );
      _currentUser = baseUser;
      _kickedOutReason = '';
      _inactivityPaused = false;
      await _saveSession();
      await _bootstrapSession(createIfMissing: true);
      if (!testSkipOnlineValidation) _startValidationTimer();
      notifyListeners();
      return null;
    } catch (e) {
      debugPrint('[InutilAuth] Error vinculando TV por QR: $e');
      return 'Sin conexión para completar la vinculación. Intenta de nuevo.';
    }
  }

  /// Revalida la licencia y el dispositivo contra Firestore.
  Future<void> _validateSession({required String reason}) async {
    final user = _currentUser;
    if (user == null || user.uid.isEmpty) return;
    if (testSkipOnlineValidation) return;
    if (_validating) return;
    _validating = true;
    try {
      await _ensureFreshIdToken();
      final remote =
          await InutilFirestoreService.instance.getUserProfile(user.uid);
      if (remote == null) {
        _kickedOutReason =
            'Tu cuenta fue eliminada. Contacta al administrador.';
        notifyListeners();
        return;
      }
      await _applyRemoteDoc(remote);

      final updated = _currentUser!;
      if (!updated.isAdmin && !_tvSessionOk(updated)) {
        _kickedOutReason =
            'Otro dispositivo inició sesión con esta cuenta en Inutix TV. '
            'Esta sesión quedó bloqueada.';
        notifyListeners();
        return;
      }
      if (!updated.licenseValid) {
        _kickedOutReason = blockedReason;
        notifyListeners();
      } else {
        await _enforceInactivityPolicy(remote);
      }
    } catch (e) {
      debugPrint('[InutilAuth] Validación ($reason) sin conexión: $e');
    } finally {
      _validating = false;
    }
  }

  /// Fuerza la lectura del perfil actual desde Firestore (botón "Comprobar Estado").
  Future<void> refreshCurrentUserProfile() async {
    if (_currentUser == null) return;
    if (testSkipOnlineValidation) return;
    try {
      await _ensureFreshIdToken();
      final remoteDoc = await InutilFirestoreService.instance
          .getUserProfile(_currentUser!.uid);
      if (remoteDoc != null && remoteDoc.isNotEmpty) {
        await _applyRemoteDoc(remoteDoc);
        if (_currentUser!.licenseValid && !_tvSessionOk(_currentUser!)) {
          // Si estaba pendiente y el admin acaba de aprobarla, reclamamos el equipo.
          final emptySlot = _isSmartTvSlot
              ? _currentUser!.currentSmartTvDeviceId.isEmpty
              : _currentUser!.currentTvDeviceId.isEmpty;
          if (emptySlot) {
            await _claimTvDevice();
          }
        }
        if (_currentUser?.licenseValid == true) {
          await _enforceInactivityPolicy(remoteDoc);
        }
      }
    } catch (e) {
      debugPrint('[InutilAuth] Error refrescando perfil: $e');
      if (_currentUser != null && isBootstrapAdminEmail(_currentUser!.email)) {
        _currentUser = _currentUser!.copyWith(
          role: 'admin',
          status: 'active',
          isActive: true,
          accountExpiresAt:
              _currentUser!.accountExpiresAt ?? DateTime(2099, 12, 31),
        );
        _kickedOutReason = '';
        await _saveSession();
        notifyListeners();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 3b. USO REAL Y PAUSA AUTOMÁTICA POR INACTIVIDAD (compartida con Inútil Music)
  // ---------------------------------------------------------------------------

  static DateTime? _parseRemoteDate(Object? raw) {
    if (raw is DateTime) return raw;
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString());
  }

  Future<void> _loadInactivityPolicy() async {
    try {
      final doc = await InutilFirestoreService.instance
          .getDocument('app_config/inactivity_policy');
      if (doc == null) return;
      final enabled = doc['enabled'];
      if (enabled is bool) _inactivityPolicyEnabled = enabled;
      final days = (doc['days'] as num?)?.toInt() ??
          int.tryParse(doc['days']?.toString() ?? '');
      if (days != null) {
        _inactivityPolicyDays =
            days.clamp(_minInactivityDays, _maxInactivityDays);
      }
    } catch (e) {
      debugPrint('[InutilAuth] Política de inactividad no disponible: $e');
    }
  }

  Future<void> _enforceInactivityPolicy(Map<String, dynamic> remote) async {
    final user = _currentUser;
    if (user == null) return;
    await _loadInactivityPolicy();
    final lastActiveAt = _parseRemoteDate(remote['lastActiveAt']);
    final exempt = user.isAdmin ||
        user.isPermanent ||
        remote['inactivityExempt'] == true;
    final days = inactivityPauseDays(
      lastActiveAt: lastActiveAt,
      exempt: exempt,
      enabled: _inactivityPolicyEnabled,
      thresholdDays: _inactivityPolicyDays,
      now: DateTime.now(),
    );
    if (days != null) {
      final changed = !_inactivityPaused || _inactiveDays != days;
      _inactivityPaused = true;
      _inactiveDays = days;
      if (changed) notifyListeners();
      return;
    }
    final wasPaused = _inactivityPaused;
    _inactivityPaused = false;
    _inactiveDays = 0;
    await _writeActivityHeartbeat(force: lastActiveAt == null || wasPaused);
    if (wasPaused) notifyListeners();
  }

  Future<void> _writeActivityHeartbeat({bool force = false}) async {
    final user = _currentUser;
    if (user == null || user.uid.isEmpty || _inactivityPaused) return;
    final now = DateTime.now();
    final last = _lastHeartbeatAt;
    if (!force && last != null && now.difference(last) < _heartbeatThrottle) {
      return;
    }
    final ok = await InutilFirestoreService.instance.setDocument(
      'users/${user.uid}',
      {
        'lastActiveAt': now,
        'lastActivePlatform': devicePlatform,
        'lastActiveTvVersion': AppInfo.appVersion,
      },
    );
    if (ok) _lastHeartbeatAt = now;
  }

  /// El usuario en pausa solicita reactivación (visible en el portal web admin).
  Future<bool> requestReactivation() async {
    final user = _currentUser;
    if (user == null || user.uid.isEmpty) return false;
    try {
      await _ensureFreshIdToken();
      return await InutilFirestoreService.instance.setDocument(
        'users/${user.uid}',
        {'reactivationRequestedAt': DateTime.now()},
      );
    } catch (e) {
      debugPrint('[InutilAuth] No se pudo solicitar reactivación: $e');
      return false;
    }
  }

  @visibleForTesting
  void testSetInactivityPaused({required bool paused, int days = 0}) {
    _inactivityPaused = paused;
    _inactiveDays = days;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 4. MÓDULO DE ADMINISTRACIÓN (EXCLUSIVO PARA ADMINS)
  // ---------------------------------------------------------------------------

  /// Obtiene todos los usuarios registrados en la familia Inútil (Firestore).
  Future<List<InutilUser>> getAllUsers() async {
    final usersMap = <String, InutilUser>{};
    final prefs = await SharedPreferences.getInstance();
    try {
      if (!testSkipOnlineValidation) {
        await _ensureFreshIdToken();
      }
      final remoteUsers = testSkipOnlineValidation
          ? const <Map<String, dynamic>>[]
          : await InutilFirestoreService.instance.getAllUsers();
      if (remoteUsers.isEmpty) {
        final cache = prefs.getString(_storageUsersCacheKey);
        if (cache != null) {
          for (final entry in (jsonDecode(cache) as List? ?? [])) {
            if (entry is Map<String, dynamic>) {
              final u = InutilUser.fromJson(entry);
              usersMap[u.uid] = u;
            }
          }
        }
        return _sortedUsers(usersMap.values.toList());
      }

      final encoded = <Map<String, dynamic>>[];
      for (final doc in remoteUsers) {
        final uid = doc['uid'] as String? ?? '';
        if (uid.isEmpty) continue;
        final rawExp = doc['accountExpiresAt'];
        final rawLogin = doc['lastLoginAt'];
        final rawCreated = doc['createdAt'];
        final u = InutilUser(
          uid: uid,
          email: doc['email'] as String? ?? '',
          displayName: doc['displayName'] as String? ?? '',
          role: doc['role'] as String? ?? 'user',
          isActive: doc['isActive'] as bool? ?? true,
          status: doc['status'] as String? ??
              ((doc['isActive'] as bool?) == false ? 'blocked' : 'active'),
          accountExpiresAt: rawExp is DateTime
              ? rawExp
              : (rawExp != null ? DateTime.tryParse(rawExp.toString()) : null),
          accountDurationDays:
              (doc['accountDurationDays'] as num?)?.toInt() ?? 30,
          createdAt: rawCreated is DateTime
              ? rawCreated
              : (rawCreated != null
                  ? DateTime.tryParse(rawCreated.toString())
                  : null),
          lastLoginAt: rawLogin is DateTime
              ? rawLogin
              : (rawLogin != null
                  ? DateTime.tryParse(rawLogin.toString())
                  : null),
          currentPhoneDeviceId: doc['currentPhoneDeviceId'] as String? ?? '',
          currentTvDeviceId: doc['currentTvDeviceId'] as String? ?? '',
          phoneSwitchCount: (doc['phoneSwitchCount'] as num?)?.toInt() ?? 0,
          phoneSwitchMonth: doc['phoneSwitchMonth'] as String? ?? '',
        );
        usersMap[uid] = u;
        encoded.add(u.toJson());
      }
      await prefs.setString(_storageUsersCacheKey, jsonEncode(encoded));
    } catch (e) {
      debugPrint('[InutilAuth] Error obteniendo usuarios de Firestore: $e');
    }
    return _sortedUsers(usersMap.values.toList());
  }

  List<InutilUser> _sortedUsers(List<InutilUser> list) {
    list.sort((a, b) {
      if (a.isAdmin && !b.isAdmin) return -1;
      if (!a.isAdmin && b.isAdmin) return 1;
      if (a.status == 'pending' && b.status != 'pending') return -1;
      if (a.status != 'pending' && b.status == 'pending') return 1;
      if (a.isActive && !b.isActive) return -1;
      if (!a.isActive && b.isActive) return 1;
      return a.email.compareTo(b.email);
    });
    return list;
  }

  /// Administrador: crea un nuevo usuario en Firebase Auth + Firestore **sin
  /// cerrar ni sobrescribir la sesión actual del administrador**.
  Future<InutilUser> adminCreateUser({
    required String email,
    required String password,
    String? displayName,
    int initialDays = 30,
    bool isPermanent = false,
  }) async {
    final admin = _currentUser;
    if (admin == null || !admin.isAdmin) {
      throw Exception('Solo un administrador puede crear usuarios.');
    }
    final trimmedEmail = email.trim().toLowerCase();
    if (trimmedEmail.isEmpty || password.length < 6) {
      throw Exception(
        'El correo y la contraseña (mínimo 6 caracteres) son obligatorios.',
      );
    }

    await _ensureFreshIdToken();

    // 1. Crea la cuenta en Firebase Auth sin tocar `_currentUser`.
    final data = await _authPost('accounts:signUp', {
      'email': trimmedEmail,
      'password': password,
      'returnSecureToken': true,
    });
    final newUid = data['localId'] as String;
    final cleanName = displayName?.trim().isNotEmpty == true
        ? displayName!.trim()
        : trimmedEmail.split('@').first;
    final expiresAt = isPermanent
        ? DateTime(2099, 12, 31)
        : DateTime.now().add(Duration(days: initialDays));
    final durationDays = isPermanent ? 9999 : initialDays;

    // 2. Escribe el documento completo en Firestore usando el token del ADMIN.
    final ok = await InutilFirestoreService.instance.setDocument(
      'users/$newUid',
      {
        'uid': newUid,
        'email': trimmedEmail,
        'displayName': cleanName,
        'role': 'user',
        'status': 'active',
        'isActive': true,
        'accountExpiresAt': expiresAt,
        'accountDurationDays': durationDays,
        'currentPhoneDeviceId': '',
        'currentTvDeviceId': '',
        'phoneSwitchCount': 0,
        'phoneSwitchMonth': '',
        'createdAt': DateTime.now(),
        'lastLoginAt': DateTime.now(),
        'lastValidatedAt': DateTime.now(),
        'schemaVersion': 3,
      },
      merge: false,
    );
    if (!ok) {
      throw Exception(
        'La cuenta se creó en Auth, pero falló al guardar su licencia en Firestore.',
      );
    }

    notifyListeners();
    return InutilUser(
      uid: newUid,
      email: trimmedEmail,
      displayName: cleanName,
      role: 'user',
      status: 'active',
      isActive: true,
      accountExpiresAt: expiresAt,
      accountDurationDays: durationDays,
      createdAt: DateTime.now(),
      lastLoginAt: DateTime.now(),
    );
  }

  /// Administrador: conceder vigencia en días o Licencia Premium Permanente.
  Future<void> adminGrantVigencia({
    required String uid,
    required int additionalDays,
    bool isPermanent = false,
  }) async {
    await _ensureFreshIdToken();
    DateTime newExpiresAt;
    int days = additionalDays;
    if (isPermanent) {
      newExpiresAt = DateTime(2099, 12, 31);
      days = 9999;
    } else {
      DateTime? currentExpiry;
      try {
        final doc = await InutilFirestoreService.instance.getUserProfile(uid);
        final raw = doc?['accountExpiresAt'];
        currentExpiry = raw is DateTime
            ? raw
            : (raw != null ? DateTime.tryParse(raw.toString()) : null);
      } catch (_) {}
      if (currentExpiry != null &&
          currentExpiry.isAfter(DateTime.now()) &&
          currentExpiry.year < 2090) {
        newExpiresAt = currentExpiry.add(Duration(days: additionalDays));
      } else {
        newExpiresAt = DateTime.now().add(Duration(days: additionalDays));
      }
    }

    final ok = await InutilFirestoreService.instance.adminUpdateUser(uid, {
      'accountExpiresAt': newExpiresAt,
      'isActive': true,
      'status': 'active',
      'accountDurationDays': days,
    });
    if (!ok) {
      throw Exception(
        'No se pudo guardar la vigencia en la nube. Revisa tu conexión o permisos.',
      );
    }

    if (_currentUser?.uid == uid) {
      _currentUser = _currentUser!.copyWith(
        accountExpiresAt: newExpiresAt,
        isActive: true,
        status: 'active',
      );
      await _saveSession();
    }
    notifyListeners();
  }

  /// Administrador: establecer fecha exacta de vencimiento.
  Future<void> adminSetExactExpiration({
    required String uid,
    required DateTime newExpiry,
  }) async {
    await _ensureFreshIdToken();
    final ok = await InutilFirestoreService.instance.adminUpdateUser(uid, {
      'accountExpiresAt': newExpiry,
      'isActive': true,
      'status': 'active',
    });
    if (!ok) {
      throw Exception('No se pudo guardar la fecha en la nube.');
    }

    if (_currentUser?.uid == uid) {
      _currentUser = _currentUser!.copyWith(
        accountExpiresAt: newExpiry,
        isActive: true,
        status: 'active',
      );
      await _saveSession();
    }
    notifyListeners();
  }

  /// Administrador: activar o suspender cuenta.
  Future<void> adminToggleUserActive({
    required String uid,
    required bool isActive,
  }) async {
    await _ensureFreshIdToken();
    final ok = await InutilFirestoreService.instance.adminUpdateUser(uid, {
      'isActive': isActive,
      'status': isActive ? 'active' : 'blocked',
    });
    if (!ok) {
      throw Exception('No se pudo actualizar la cuenta en la nube.');
    }

    if (_currentUser?.uid == uid) {
      _currentUser = _currentUser!.copyWith(
        isActive: isActive,
        status: isActive ? 'active' : 'blocked',
      );
      await _saveSession();
    }
    notifyListeners();
  }

  /// Administrador: asignar o revocar rol de Administrador.
  Future<void> adminToggleUserRole({
    required String uid,
    required String role,
  }) async {
    await _ensureFreshIdToken();
    final ok = await InutilFirestoreService.instance.adminUpdateUser(uid, {
      'role': role,
    });
    if (!ok) {
      throw Exception('No se pudo actualizar el rol en la nube.');
    }

    if (_currentUser?.uid == uid) {
      _currentUser = _currentUser!.copyWith(role: role);
      await _saveSession();
    }
    notifyListeners();
  }

  /// Administrador: liberar dispositivos vinculados (Inútil Music e InútilTV).
  Future<void> adminRevokeDevice(String uid) async {
    await _ensureFreshIdToken();
    final ok = await InutilFirestoreService.instance.adminUpdateUser(uid, {
      'currentPhoneDeviceId': '',
      'currentTvDeviceId': '',
      'phoneSwitchCount': 0,
      'phoneSwitchMonth': '',
    });
    if (!ok) {
      throw Exception('No se pudo liberar el dispositivo en la nube.');
    }

    if (_currentUser?.uid == uid) {
      _currentUser = _currentUser!.copyWith(
        currentPhoneDeviceId: '',
        currentTvDeviceId: '',
      );
      await _saveSession();
    }
    notifyListeners();
  }

  /// Administrador: eliminar usuario de Firestore.
  Future<void> adminDeleteUser(String uid) async {
    await _ensureFreshIdToken();
    if (_currentUser?.uid == uid) {
      await signOut();
      return;
    }
    final ok = await InutilFirestoreService.instance.deleteDocument('users/$uid');
    if (!ok) {
      throw Exception('No se pudo eliminar la cuenta en la nube.');
    }
    notifyListeners();
  }

  String _mapAuthError(String error) {
    if (error.contains('EMAIL_EXISTS')) {
      return 'Este correo ya está registrado.';
    }
    if (error.contains('EMAIL_NOT_FOUND')) {
      return 'No existe ninguna cuenta con este correo.';
    }
    if (error.contains('INVALID_PASSWORD') ||
        error.contains('INVALID_LOGIN_CREDENTIALS')) {
      return 'Correo o contraseña incorrectos.';
    }
    if (error.contains('INVALID_EMAIL')) {
      return 'El formato del correo electrónico no es válido.';
    }
    if (error.contains('WEAK_PASSWORD')) {
      return 'La contraseña debe tener al menos 6 caracteres.';
    }
    if (error.contains('USER_DISABLED')) {
      return 'Esta cuenta ha sido desactivada por el administrador.';
    }
    if (error.contains('TOO_MANY_ATTEMPTS_TRY_LATER')) {
      return 'Demasiados intentos fallidos. Inténtalo más tarde.';
    }
    if (error.contains('CONFIGURATION_NOT_FOUND') ||
        error.contains('OPERATION_NOT_ALLOWED')) {
      return 'Firebase Auth (Correo/Contraseña) aún no está activado en la consola del proyecto.';
    }
    if (error.contains('NETWORK_ERROR') || error.contains('SocketException')) {
      return 'Sin conexión con el servidor de cuentas. Revisa tu internet.';
    }
    return 'Error de autenticación: $error';
  }
}
