import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';

import 'tv_mode_service.dart';

/// Runtime Android APK integrity snapshot returned by [InutixAppIntegrityPlugin].
@immutable
class InutixAppIntegrityInfo {
  const InutixAppIntegrityInfo({
    required this.packageName,
    required this.apkCertSha256,
  });

  static const empty = InutixAppIntegrityInfo(
    packageName: '',
    apkCertSha256: '',
  );

  final String packageName;
  final String apkCertSha256;

  bool get hasCertificate => apkCertSha256.length == 64;
}

/// Verified Level 2 server-signed license payload (ES256 / ECDSA P-256).
@immutable
class InutixLicenseTicketPayload {
  const InutixLicenseTicketPayload({
    required this.version,
    required this.keyId,
    required this.uid,
    required this.role,
    required this.status,
    required this.deviceId,
    required this.platform,
    required this.apkCertSha256,
    required this.iatMs,
    required this.expMs,
    required this.offlineExpMs,
    required this.allowStreaming,
    required this.allowDownloads,
    required this.profileVersions,
  });

  final int version;
  final String keyId;
  final String uid;
  final String role;
  final String status;
  final String deviceId;
  final String platform;
  final String apkCertSha256;
  final int iatMs;
  final int expMs;
  final int offlineExpMs;
  final bool allowStreaming;
  final bool allowDownloads;
  final Map<String, String> profileVersions;

  bool get isAdmin => role == 'admin';
  bool get isActiveStatus => isAdmin || status == 'active';

  static InutixLicenseTicketPayload? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final uid = (raw['uid'] as String?)?.trim() ?? '';
    final keyId = (raw['kid'] as String?)?.trim() ?? 'k1';
    final role = (raw['role'] as String?)?.trim() ?? 'user';
    final status = (raw['status'] as String?)?.trim() ?? 'pending';
    final deviceId = (raw['deviceId'] as String?)?.trim() ?? '';
    final platform = (raw['platform'] as String?)?.trim() ?? '';
    final apkCert = ((raw['apkCertSha256'] as String?) ?? '')
        .trim()
        .toLowerCase();
    final iatMs = raw['iatMs'] is num ? (raw['iatMs'] as num).toInt() : 0;
    final expMs = raw['expMs'] is num ? (raw['expMs'] as num).toInt() : 0;
    final offlineExpMs = raw['offlineExpMs'] is num
        ? (raw['offlineExpMs'] as num).toInt()
        : expMs;
    if (uid.isEmpty || expMs <= 0) return null;

    final rawProfiles = raw['profileVersions'];
    final profileVersions = <String, String>{};
    if (rawProfiles is Map) {
      for (final entry in rawProfiles.entries) {
        final k = entry.key.toString().trim();
        final v = entry.value?.toString().trim() ?? '';
        if (k.isNotEmpty && v.isNotEmpty) {
          profileVersions[k] = v;
        }
      }
    }

    return InutixLicenseTicketPayload(
      version: raw['v'] is num ? (raw['v'] as num).toInt() : 1,
      keyId: keyId,
      uid: uid,
      role: role,
      status: status,
      deviceId: deviceId,
      platform: platform,
      apkCertSha256: apkCert,
      iatMs: iatMs,
      expMs: expMs,
      offlineExpMs: offlineExpMs,
      allowStreaming: raw['allowStreaming'] != false,
      allowDownloads: raw['allowDownloads'] != false,
      profileVersions: Map<String, String>.unmodifiable(profileVersions),
    );
  }
}

/// Outcome of requesting a fresh signed license ticket from `api.inutix.com`.
enum LicenseTicketRefreshStatus {
  ok,
  rejectedByServer,
  endpointUnavailable,
  networkError,
  unauthenticated,
}

@immutable
class LicenseTicketRefreshResult {
  const LicenseTicketRefreshResult({
    required this.status,
    this.rejectionCode = '',
    this.rejectionMessage = '',
    this.payload,
  });

  final LicenseTicketRefreshStatus status;
  final String rejectionCode;
  final String rejectionMessage;
  final InutixLicenseTicketPayload? payload;
}

/// Pure-Dart ES256 (ECDSA P-256 + SHA-256) verifier backed by `pointycastle`.
///
/// The server signs ASCII bytes of `payloadB64` with ECDSA P-256 and encodes
/// the raw IEEE P1363 64-byte `(r || s)` signature as base64url without padding.
/// Public keys are uncompressed 65-byte SEC1 points (`0x04 || x(32B) || y(32B)`)
/// represented as 130 lowercase hex characters.
abstract final class InutixEs256Verifier {
  static final pc.ECDomainParameters _curve = pc.ECCurve_secp256r1();

  static bool verifyTicket({
    required String ticket,
    required Map<String, String> pinnedPublicKeysHex,
    void Function(InutixLicenseTicketPayload payload)? onVerified,
  }) {
    final parts = ticket.split('.');
    if (parts.length != 2) return false;
    final payloadB64 = parts[0];
    final sigB64 = parts[1];
    if (payloadB64.isEmpty || sigB64.isEmpty) return false;

    final payloadBytes = _decodeBase64Url(payloadB64);
    final sigBytes = _decodeBase64Url(sigB64);
    if (payloadBytes == null || sigBytes == null || sigBytes.length != 64) {
      return false;
    }

    InutixLicenseTicketPayload? payload;
    try {
      final decoded = jsonDecode(utf8.decode(payloadBytes));
      payload = InutixLicenseTicketPayload.fromJson(decoded);
    } catch (_) {
      return false;
    }
    if (payload == null) return false;

    final pubKeyHex = pinnedPublicKeysHex[payload.keyId]?.trim().toLowerCase();
    if (pubKeyHex == null || pubKeyHex.isEmpty) {
      return false;
    }

    final ok = verifyRawEs256(
      message: Uint8List.fromList(ascii.encode(payloadB64)),
      rawSignature64: sigBytes,
      uncompressedPublicKeyHex: pubKeyHex,
    );
    if (!ok) return false;
    onVerified?.call(payload);
    return true;
  }

  static bool verifyRawEs256({
    required Uint8List message,
    required Uint8List rawSignature64,
    required String uncompressedPublicKeyHex,
  }) {
    if (rawSignature64.length != 64) return false;
    final pubBytes = _hexToBytes(uncompressedPublicKeyHex);
    if (pubBytes == null || pubBytes.length != 65 || pubBytes[0] != 0x04) {
      return false;
    }
    try {
      final point = _curve.curve.decodePoint(pubBytes);
      if (point == null || point.isInfinity) return false;
      final pubKey = pc.ECPublicKey(point, _curve);
      final r = _bytesToBigInt(rawSignature64.sublist(0, 32));
      final s = _bytesToBigInt(rawSignature64.sublist(32, 64));
      if (r <= BigInt.zero || s <= BigInt.zero) return false;

      final signer = pc.ECDSASigner(pc.SHA256Digest());
      signer.init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pubKey));
      return signer.verifySignature(message, pc.ECSignature(r, s));
    } catch (_) {
      return false;
    }
  }

  static Uint8List? _decodeBase64Url(String input) {
    try {
      final normalized = base64Url.normalize(input);
      return Uint8List.fromList(base64Url.decode(normalized));
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _hexToBytes(String hex) {
    final clean = hex.trim();
    if (clean.length.isOdd || clean.isEmpty) return null;
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final parsed = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
      if (parsed == null) return null;
      out[i] = parsed;
    }
    return out;
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }
}

/// Manages Level 2 cryptographically signed server license tickets (ES256),
/// Android APK certificate integrity reporting, and anti-clock-rollback checks
/// for Inutix TV (aligned with `api.inutix.com` and Inutix Music).
class InutixLicenseTicketService extends ChangeNotifier {
  InutixLicenseTicketService({
    http.Client? httpClient,
    Future<InutixAppIntegrityInfo> Function()? integrityLoader,
    DateTime Function()? clock,
    Map<String, String>? pinnedPublicKeysHex,
    String? endpointUrl,
  })  : _http = httpClient ?? http.Client(),
        _integrityLoader = integrityLoader ?? _readPlatformIntegrityInfo,
        _clock = clock ?? DateTime.now,
        _pinnedPublicKeysHex = Map<String, String>.unmodifiable(
          pinnedPublicKeysHex ?? _defaultPinnedPublicKeys(),
        ),
        _endpointUrl = endpointUrl ?? defaultEndpointUrl;

  static final InutixLicenseTicketService instance =
      InutixLicenseTicketService();

  static const String defaultEndpointUrl = String.fromEnvironment(
    'INUTIX_LICENSE_TICKET_URL',
    defaultValue: 'https://api.inutix.com/v1/music/license-ticket',
  );

  static const String backupEndpointUrl =
      'https://backup.inutix.com/v1/music/license-ticket';

  static const String _storageTicketKey = 'inutix_tv_l2_signed_ticket_v1';
  static const String _storageLastServerNowKey =
      'inutix_tv_l2_last_server_now_v1';
  static const Duration _clockRollbackTolerance = Duration(minutes: 10);
  static const Duration _refreshInterval = Duration(hours: 6);

  /// Compile-time pinned server public key (`k1`, 130-hex uncompressed SEC1
  /// P-256 point) active on `https://api.inutix.com`. Can be overridden at
  /// build time via `--dart-define=INUTIX_LICENSE_PUBKEY_K1=...` for rotation.
  static const String compiledPublicKeyK1Hex = String.fromEnvironment(
    'INUTIX_LICENSE_PUBKEY_K1',
    defaultValue:
        '047f4f1c87530b4f31ef9939e62acf44a8753fdafac405e0d8a543a524646d1b72'
        'f22b17dfe84e29d4ddd4dc4020185163eff2778e41e8615f7f9f999f8814e1d1',
  );

  static Map<String, String> _defaultPinnedPublicKeys() {
    final map = <String, String>{};
    final k1 = compiledPublicKeyK1Hex.trim().toLowerCase();
    if (k1.length == 130 && k1.startsWith('04')) {
      map['k1'] = k1;
    }
    return map;
  }

  static const MethodChannel _integrityChannel = MethodChannel(
    'inutil_tv/app_integrity',
  );

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true, migrateOnAlgorithmChange: true),
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );

  final http.Client _http;
  final Future<InutixAppIntegrityInfo> Function() _integrityLoader;
  final DateTime Function() _clock;
  final Map<String, String> _pinnedPublicKeysHex;
  final String _endpointUrl;

  InutixAppIntegrityInfo? _cachedIntegrity;
  String? _rawTicket;
  InutixLicenseTicketPayload? _verifiedPayload;
  int _lastSeenServerNowMs = 0;
  DateTime? _lastRefreshAttempt;
  String _lastServerRejectionCode = '';
  String _lastServerRejectionMessage = '';

  /// True once a real server public key is pinned in the build.
  bool get isStrictEnforcementActive => _pinnedPublicKeysHex.isNotEmpty;

  InutixLicenseTicketPayload? get verifiedPayload => _verifiedPayload;
  String get lastServerRejectionCode => _lastServerRejectionCode;
  String get lastServerRejectionMessage => _lastServerRejectionMessage;
  bool get hasServerRejection => _lastServerRejectionCode.isNotEmpty;

  Map<String, String> get dynamicProfileVersions =>
      _verifiedPayload?.profileVersions ?? const <String, String>{};

  Future<InutixAppIntegrityInfo> getIntegrityInfo() async {
    if (_cachedIntegrity != null) return _cachedIntegrity!;
    final info = await _integrityLoader();
    _cachedIntegrity = info;
    return info;
  }

  static Future<InutixAppIntegrityInfo> _readPlatformIntegrityInfo() async {
    if (kIsWeb || !Platform.isAndroid) {
      return InutixAppIntegrityInfo.empty;
    }
    try {
      final raw = await _integrityChannel.invokeMapMethod<String, dynamic>(
        'getIntegrityInfo',
      );
      if (raw == null) return InutixAppIntegrityInfo.empty;
      return InutixAppIntegrityInfo(
        packageName: (raw['packageName'] as String?)?.trim() ?? '',
        apkCertSha256:
            ((raw['apkCertSha256'] as String?) ?? '').trim().toLowerCase(),
      );
    } catch (e) {
      debugPrint('[InutixLicenseTicket] InutixAppIntegrityPlugin unavailable: $e');
      return InutixAppIntegrityInfo.empty;
    }
  }

  /// Loads any persisted ticket and verifies its ECDSA P-256 signature.
  Future<void> initialize() async {
    final storedTicket = await _readSecure(_storageTicketKey);
    final storedServerNow = await _readSecure(_storageLastServerNowKey);
    _lastSeenServerNowMs = int.tryParse(storedServerNow ?? '') ?? 0;

    if (storedTicket != null && storedTicket.isNotEmpty) {
      _tryAcceptTicket(storedTicket);
    }
  }

  /// Requests a fresh signed license ticket from `api.inutix.com`.
  Future<LicenseTicketRefreshResult> refreshFromServer({
    required String idToken,
    required String uid,
    required String deviceId,
    required String appVersion,
    bool force = false,
  }) async {
    if (idToken.trim().isEmpty || uid.trim().isEmpty) {
      return const LicenseTicketRefreshResult(
        status: LicenseTicketRefreshStatus.unauthenticated,
      );
    }
    final now = _clock();
    if (!force &&
        _verifiedPayload != null &&
        _lastRefreshAttempt != null &&
        now.difference(_lastRefreshAttempt!) < _refreshInterval &&
        isOnlineStreamingAuthorized(uid: uid, deviceId: deviceId)) {
      return LicenseTicketRefreshResult(
        status: LicenseTicketRefreshStatus.ok,
        payload: _verifiedPayload,
      );
    }
    _lastRefreshAttempt = now;

    final integrity = await getIntegrityInfo();
    final platformName = kIsWeb
        ? 'web'
        : (Platform.isAndroid
            ? 'android'
            : (Platform.isIOS
                ? 'ios'
                : (Platform.isWindows
                    ? 'windows'
                    : (Platform.isMacOS ? 'macos' : 'linux'))));

    final headers = <String, String>{
      'Authorization': 'Bearer $idToken',
      'Content-Type': 'application/json',
    };
    final reqBody = jsonEncode(<String, Object?>{
      'app': 'tv',
      'slot': TvModeService.instance.isTv ? 'smart_tv' : 'mobile',
      'deviceId': deviceId,
      'platform': platformName,
      'appVersion': appVersion,
      'packageName': integrity.packageName,
      'apkCertSha256': integrity.apkCertSha256,
    });

    try {
      http.Response res;
      try {
        res = await _http
            .post(Uri.parse(_endpointUrl), headers: headers, body: reqBody)
            .timeout(const Duration(seconds: 10));
        if (_endpointUrl == defaultEndpointUrl &&
            (res.statusCode == 502 ||
                res.statusCode == 503 ||
                res.statusCode == 521 ||
                res.statusCode == 522 ||
                res.statusCode == 524 ||
                res.statusCode == 530)) {
          res = await _http
              .post(
                Uri.parse(backupEndpointUrl),
                headers: headers,
                body: reqBody,
              )
              .timeout(const Duration(seconds: 10));
        }
      } catch (_) {
        if (_endpointUrl != defaultEndpointUrl) rethrow;
        res = await _http
            .post(
              Uri.parse(backupEndpointUrl),
              headers: headers,
              body: reqBody,
            )
            .timeout(const Duration(seconds: 10));
      }

      Map<String, dynamic> body = const <String, dynamic>{};
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {}

      if (res.statusCode == 404 || res.statusCode == 501) {
        return const LicenseTicketRefreshResult(
          status: LicenseTicketRefreshStatus.endpointUnavailable,
        );
      }

      if (res.statusCode == 401 || res.statusCode == 403) {
        final code = (body['code'] as String?)?.trim() ?? 'LICENSE_REQUIRED';
        final message = (body['message'] as String?)?.trim() ??
            'Tu licencia no está autorizada por el servidor.';
        debugPrint(
          '[InutixLicenseTicket] server rejected (${res.statusCode}) '
          'code=$code pkg=${integrity.packageName}',
        );
        await _revokeLocalTicket(code: code, message: message);
        return LicenseTicketRefreshResult(
          status: LicenseTicketRefreshStatus.rejectedByServer,
          rejectionCode: code,
          rejectionMessage: message,
        );
      }

      if (res.statusCode != 200 || body['ok'] != true) {
        return const LicenseTicketRefreshResult(
          status: LicenseTicketRefreshStatus.networkError,
        );
      }

      final serverNowMs =
          body['serverNowMs'] is num ? (body['serverNowMs'] as num).toInt() : 0;
      if (serverNowMs > _lastSeenServerNowMs) {
        _lastSeenServerNowMs = serverNowMs;
        await _writeSecure(
          _storageLastServerNowKey,
          _lastSeenServerNowMs.toString(),
        );
      }

      final ticket = (body['ticket'] as String?)?.trim() ?? '';
      if (ticket.isEmpty || !_tryAcceptTicket(ticket)) {
        await _revokeLocalTicket(
          code: 'INVALID_TICKET_SIGNATURE',
          message:
              'No se pudo verificar la firma criptográfica de tu licencia.',
        );
        return const LicenseTicketRefreshResult(
          status: LicenseTicketRefreshStatus.rejectedByServer,
          rejectionCode: 'INVALID_TICKET_SIGNATURE',
          rejectionMessage:
              'No se pudo verificar la firma criptográfica de tu licencia.',
        );
      }

      // Confirm ticket binds to the exact authenticated user & device.
      final verified = _verifiedPayload!;
      if (verified.uid != uid ||
          (verified.deviceId.isNotEmpty && verified.deviceId != deviceId)) {
        await _revokeLocalTicket(
          code: 'TICKET_BINDING_MISMATCH',
          message: 'El pase de licencia no corresponde a este dispositivo.',
        );
        return const LicenseTicketRefreshResult(
          status: LicenseTicketRefreshStatus.rejectedByServer,
          rejectionCode: 'TICKET_BINDING_MISMATCH',
          rejectionMessage:
              'El pase de licencia no corresponde a este dispositivo.',
        );
      }

      _rawTicket = ticket;
      _lastServerRejectionCode = '';
      _lastServerRejectionMessage = '';
      await _writeSecure(_storageTicketKey, ticket);
      debugPrint(
        '[InutixLicenseTicket] ES256 verified kid=${verified.keyId} '
        'status=${verified.status} role=${verified.role}',
      );
      notifyListeners();
      return LicenseTicketRefreshResult(
        status: LicenseTicketRefreshStatus.ok,
        payload: verified,
      );
    } catch (e) {
      debugPrint('[InutixLicenseTicket] refresh error: $e');
      return const LicenseTicketRefreshResult(
        status: LicenseTicketRefreshStatus.networkError,
      );
    }
  }

  /// Validates whether online streaming is authorized for [uid] on [deviceId].
  bool isOnlineStreamingAuthorized({
    required String uid,
    required String deviceId,
    String? apkCertSha256Override,
  }) {
    if (hasServerRejection) return false;
    if (!isStrictEnforcementActive) return true;
    final payload = _verifiedPayload;
    if (payload == null) return false;
    if (!_matchesBindings(
      payload,
      uid: uid,
      deviceId: deviceId,
      apkCertSha256Override: apkCertSha256Override,
    )) {
      return false;
    }
    if (!payload.allowStreaming || !payload.isActiveStatus) return false;
    return _isWithinWindow(payload.expMs);
  }

  /// Validates whether offline playback of downloaded VOD is authorized.
  bool isOfflinePlaybackAuthorized({
    required String uid,
    required String deviceId,
    String? apkCertSha256Override,
  }) {
    if (hasServerRejection) return false;
    if (!isStrictEnforcementActive) return true;
    final payload = _verifiedPayload;
    if (payload == null) return false;
    if (!_matchesBindings(
      payload,
      uid: uid,
      deviceId: deviceId,
      apkCertSha256Override: apkCertSha256Override,
    )) {
      return false;
    }
    if (!payload.allowDownloads || !payload.isActiveStatus) return false;
    return _isWithinWindow(payload.offlineExpMs);
  }

  bool _matchesBindings(
    InutixLicenseTicketPayload payload, {
    required String uid,
    required String deviceId,
    String? apkCertSha256Override,
  }) {
    if (payload.uid != uid) return false;
    if (payload.deviceId.isNotEmpty &&
        deviceId.isNotEmpty &&
        payload.deviceId != deviceId) {
      return false;
    }
    final runtimeCert =
        (apkCertSha256Override ?? _cachedIntegrity?.apkCertSha256 ?? '')
            .trim()
            .toLowerCase();
    if (payload.platform == 'android' &&
        payload.apkCertSha256.isNotEmpty &&
        runtimeCert.isNotEmpty &&
        payload.apkCertSha256 != runtimeCert) {
      return false;
    }
    return true;
  }

  bool _isWithinWindow(int expiryMs) {
    final nowMs = _clock().toUtc().millisecondsSinceEpoch;
    // Anti-clock-rollback: reject if device clock was wound back past server time.
    if (_lastSeenServerNowMs > 0 &&
        nowMs + _clockRollbackTolerance.inMilliseconds < _lastSeenServerNowMs) {
      return false;
    }
    return nowMs <= expiryMs;
  }

  bool _tryAcceptTicket(String ticket) {
    if (!isStrictEnforcementActive) {
      final parts = ticket.split('.');
      if (parts.length != 2) return false;
      final bytes = InutixEs256Verifier._decodeBase64Url(parts[0]);
      if (bytes == null) return false;
      try {
        final parsed = InutixLicenseTicketPayload.fromJson(
          jsonDecode(utf8.decode(bytes)),
        );
        if (parsed == null) return false;
        _verifiedPayload = parsed;
        return true;
      } catch (_) {
        return false;
      }
    }

    InutixLicenseTicketPayload? verified;
    final ok = InutixEs256Verifier.verifyTicket(
      ticket: ticket,
      pinnedPublicKeysHex: _pinnedPublicKeysHex,
      onVerified: (p) => verified = p,
    );
    if (!ok || verified == null) return false;
    _verifiedPayload = verified;
    return true;
  }

  Future<void> _revokeLocalTicket({
    required String code,
    required String message,
  }) async {
    _rawTicket = null;
    _verifiedPayload = null;
    _lastServerRejectionCode = code;
    _lastServerRejectionMessage = message;
    await _deleteSecure(_storageTicketKey);
    notifyListeners();
  }

  /// Clears ticket and rejection state (called on signOut).
  Future<void> clear() async {
    _rawTicket = null;
    _verifiedPayload = null;
    _lastRefreshAttempt = null;
    _lastServerRejectionCode = '';
    _lastServerRejectionMessage = '';
    await _deleteSecure(_storageTicketKey);
    notifyListeners();
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    _cachedIntegrity = null;
    _lastSeenServerNowMs = 0;
    await clear();
    await _deleteSecure(_storageLastServerNowKey);
  }

  String? get rawTicket => _rawTicket;

  Future<String?> _readSecure(String key) async {
    try {
      final val = await _secureStorage.read(key: key);
      if (val != null) return val;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSecure(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
  }

  Future<void> _deleteSecure(String key) async {
    try {
      await _secureStorage.delete(key: key);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }
}
