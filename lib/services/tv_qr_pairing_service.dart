import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'firebase_auth_service.dart';
import 'firebase_firestore_service.dart';

/// Sesión activa de vinculación QR en la Smart TV.
class TvQrPairingSession {
  final String code;
  final Uint8List secretKey;
  final String qrUri;
  final DateTime expiresAt;

  const TvQrPairingSession({
    required this.code,
    required this.secretKey,
    required this.qrUri,
    required this.expiresAt,
  });

  /// Código formateado para mostrar en pantalla (`XXXX-XXXX`).
  String get displayCode => code.length == 8
      ? '${code.substring(0, 4)}-${code.substring(4)}'
      : code;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Datos extraídos de un código QR válido escaneado desde el celular.
class ParsedTvQr {
  final String code;
  final Uint8List secretKey;

  const ParsedTvQr({required this.code, required this.secretKey});
}

/// Servicio de inicio de sesión por código QR cifrado extremo a extremo
/// (App Móvil → Smart TV / TV Box) sobre Firestore `tv_pairing/{code}`.
///
/// Seguridad:
/// - La TV genera una clave aleatoria efímera de 256 bits que **jamás** se
///   envía a Firestore: solo existe en la memoria de la TV y dentro de la
///   imagen QR escaneada por la cámara del celular.
/// - El celular cifra el `refreshToken` de Firebase Auth con AES-256-CBC +
///   HMAC-SHA256 (Encrypt-then-MAC) usando esa clave efímera.
/// - Al completarse, la TV descifra en memoria, canjea una sesión real de
///   Firebase Auth, reclama la ranura `currentSmartTvDeviceId` (1 celular +
///   1 TV por cuenta) y borra inmediatamente el documento temporal.
class TvQrPairingService {
  TvQrPairingService._();
  static final TvQrPairingService instance = TvQrPairingService._();

  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const Duration sessionTtl = Duration(minutes: 5);

  // ---------------------------------------------------------------------------
  // 1. CRIPTOGRAFÍA E2E (AES-256-CBC + PKCS7 + HMAC-SHA256)
  // ---------------------------------------------------------------------------
  static Uint8List _deriveKey(Uint8List master, String purpose) {
    final digest = crypto.sha256.convert([...master, ...utf8.encode(purpose)]);
    return Uint8List.fromList(digest.bytes);
  }

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  static String generateCode() {
    final rng = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buf.write(_alphabet[rng.nextInt(_alphabet.length)]);
    }
    return buf.toString();
  }

  static Uint8List generateSecretKey() => _randomBytes(32);

  /// Clave derivada de un código manual `XXXX-XXXX` cuando el usuario prefiere
  /// escribir el código de la TV en vez de escanear el QR con la cámara.
  static Uint8List deriveManualCodeKey(String code) {
    final norm = code.replaceAll('-', '').trim().toUpperCase();
    final digest = crypto.sha256.convert(
      utf8.encode('inutiltv-manual-pair-v1:$norm'),
    );
    return Uint8List.fromList(digest.bytes);
  }

  static String buildQrUri(String code, Uint8List secretKey) {
    final k = base64Url.encode(secretKey).replaceAll('=', '');
    return 'inutiltv://pair?c=$code&k=$k';
  }

  static ParsedTvQr? parseQrUri(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final uri = Uri.parse(trimmed);
      if (uri.scheme != 'inutiltv' || uri.host != 'pair') return null;
      final code = (uri.queryParameters['c'] ?? '').replaceAll('-', '').trim();
      final keyStr = (uri.queryParameters['k'] ?? '').trim();
      if (code.length < 6 || keyStr.isEmpty) return null;
      final key = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(keyStr)),
      );
      if (key.length != 32) return null;
      return ParsedTvQr(code: code.toUpperCase(), secretKey: key);
    } catch (_) {
      return null;
    }
  }

  static String encryptPayload(Map<String, dynamic> payload, Uint8List masterKey) {
    final encKey = _deriveKey(masterKey, 'inutiltv-qr-enc-v1');
    final macKey = _deriveKey(masterKey, 'inutiltv-qr-mac-v1');
    final iv = _randomBytes(16);
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));

    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
        true,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV<KeyParameter>(KeyParameter(encKey), iv),
          null,
        ),
      );

    final encrypted = cipher.process(plain);
    final macInput = Uint8List(iv.length + encrypted.length)
      ..setRange(0, iv.length, iv)
      ..setRange(iv.length, iv.length + encrypted.length, encrypted);
    final mac = crypto.Hmac(crypto.sha256, macKey).convert(macInput).bytes;

    final out = Uint8List(iv.length + mac.length + encrypted.length)
      ..setRange(0, iv.length, iv)
      ..setRange(iv.length, iv.length + mac.length, mac)
      ..setRange(iv.length + mac.length, iv.length + mac.length + encrypted.length,
          encrypted);
    return base64Url.encode(out);
  }

  static Map<String, dynamic>? decryptPayload(
    String token,
    Uint8List masterKey,
  ) {
    try {
      final raw = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(token.trim())),
      );
      if (raw.length <= 16 + 32) return null;
      final iv = raw.sublist(0, 16);
      final mac = raw.sublist(16, 48);
      final encrypted = raw.sublist(48);

      final encKey = _deriveKey(masterKey, 'inutiltv-qr-enc-v1');
      final macKey = _deriveKey(masterKey, 'inutiltv-qr-mac-v1');

      final macInput = Uint8List(iv.length + encrypted.length)
        ..setRange(0, iv.length, iv)
        ..setRange(iv.length, iv.length + encrypted.length, encrypted);
      final expected =
          crypto.Hmac(crypto.sha256, macKey).convert(macInput).bytes;
      if (!_constantTimeEquals(mac, expected)) return null;

      final cipher = PaddedBlockCipherImpl(
        PKCS7Padding(),
        CBCBlockCipher(AESEngine()),
      )..init(
          false,
          PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
            ParametersWithIV<KeyParameter>(KeyParameter(encKey), iv),
            null,
          ),
        );

      final plain = cipher.process(encrypted);
      final decoded = jsonDecode(utf8.decode(plain));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ---------------------------------------------------------------------------
  // 2. FLUJO EN SMART TV (crear sesión QR + esperar aprobación)
  // ---------------------------------------------------------------------------
  Future<TvQrPairingSession?> createTvSession() async {
    final code = generateCode();
    final key = generateSecretKey();
    final now = DateTime.now();
    final expiresAt = now.add(sessionTtl);

    try {
      final ok = await InutilFirestoreService.instance.setDocument(
        'tv_pairing/$code',
        {
          'status': 'pending',
          'deviceId': InutilAuthService.instance.deviceId,
          'deviceName': InutilAuthService.instance.deviceName,
          'createdAt': now,
          'expiresAt': expiresAt,
        },
        merge: false,
        overrideToken: '',
      );
      if (!ok) return null;
      return TvQrPairingSession(
        code: code,
        secretKey: key,
        qrUri: buildQrUri(code, key),
        expiresAt: expiresAt,
      );
    } catch (e) {
      debugPrint('[TvQrPairing] No se pudo crear sesión QR: $e');
      return null;
    }
  }

  /// Consulta una vez si el celular ya aprobó el código QR.
  /// Devuelve:
  /// - `null` si sigue esperando (`pending`)
  /// - `'OK'` si completó el inicio de sesión en la TV
  /// - otro texto si ocurrió un error para mostrar en pantalla.
  Future<String?> pollAndCompleteTvSession(TvQrPairingSession session) async {
    if (session.isExpired) return 'EXPIRED';
    try {
      final doc = await InutilFirestoreService.instance.getDocument(
        'tv_pairing/${session.code}',
        overrideToken: '',
      );
      if (doc == null) return null;
      final status = (doc['status'] ?? '').toString();
      if (status != 'approved') return null;

      final encrypted = (doc['payload'] ?? '').toString();
      if (encrypted.isEmpty) return null;

      final mode = (doc['mode'] ?? 'qr').toString();
      final decryptKey = mode == 'code'
          ? deriveManualCodeKey(session.code)
          : session.secretKey;
      final payload = decryptPayload(encrypted, decryptKey);
      // Limpiar inmediatamente el sobre temporal tras leerlo
      unawaited(cleanupTvSession(session.code));

      if (payload == null) {
        return 'No se pudo validar el código de vinculación. Genera uno nuevo.';
      }

      final refreshToken = (payload['refreshToken'] ?? '').toString();
      final uid = (payload['uid'] ?? '').toString();
      final email = (payload['email'] ?? '').toString();
      final displayName = (payload['displayName'] ?? '').toString();
      final err = await InutilAuthService.instance.signInWithPairedRefreshToken(
        refreshToken,
        uidHint: uid,
        emailHint: email,
        displayNameHint: displayName,
      );
      return err ?? 'OK';
    } catch (e) {
      debugPrint('[TvQrPairing] Error consultando sesión QR: $e');
      return null;
    }
  }

  Future<void> cleanupTvSession(String code) async {
    try {
      await InutilFirestoreService.instance.deleteDocument(
        'tv_pairing/$code',
        overrideToken: '',
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // 3. FLUJO EN CELULAR (escanear QR y enviar sesión cifrada)
  // ---------------------------------------------------------------------------
  /// Aprueba una vinculación de Smart TV desde el celular autenticado.
  /// Devuelve `null` si fue exitoso, o mensaje legible de error.
  Future<String?> approveFromMobile(String rawQr) async {
    final parsed = parseQrUri(rawQr);
    if (parsed == null) {
      return 'Este código QR no corresponde a Inutix TV.';
    }

    final auth = InutilAuthService.instance;
    final initialUser = auth.currentUser;
    if (initialUser == null || initialUser.refreshToken.isEmpty) {
      return 'Necesitas tener sesión iniciada en tu celular para vincular la TV.';
    }
    if (!auth.isAccessAllowed) {
      return 'Tu cuenta debe estar activa para vincular una Smart TV.';
    }
    if (!InutilAuthService.isInutixToken(initialUser.refreshToken)) {
      await auth.ensureFreshIdToken();
    }
    final user = auth.currentUser ?? initialUser;

    try {
      final existing = await InutilFirestoreService.instance.getDocument(
        'tv_pairing/${parsed.code}',
      );
      if (existing == null) {
        return 'El código expiró o ya fue usado. Genera uno nuevo en tu TV.';
      }
      if (existing['status'] != 'pending') {
        return 'Este código ya fue utilizado. Genera uno nuevo en tu TV.';
      }

      final encrypted = encryptPayload(
        {
          'refreshToken': user.refreshToken,
          'email': user.email,
          'displayName': user.displayName,
          'uid': user.uid,
        },
        parsed.secretKey,
      );

      final ok = await InutilFirestoreService.instance.setDocument(
        'tv_pairing/${parsed.code}',
        {
          'status': 'approved',
          'mode': 'qr',
          'payload': encrypted,
          'approvedByUid': user.uid,
          'approvedAt': DateTime.now(),
        },
        merge: true,
      );
      if (!ok) {
        return 'No se pudo autorizar la TV. Verifica tu conexión e intenta de nuevo.';
      }
      return null;
    } catch (e) {
      debugPrint('[TvQrPairing] Error aprobando TV: $e');
      return 'Error de conexión al vincular la TV. Intenta de nuevo.';
    }
  }

  /// Alternativa sin cámara: vincula la Smart TV escribiendo el código de 8
  /// caracteres (`XXXX-XXXX`) que aparece debajo del QR en el televisor.
  Future<String?> approveFromMobileWithCode(String rawCode) async {
    final code = rawCode.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (code.length != 8) {
      return 'Escribe los 8 caracteres que muestra tu Smart TV (ej. 33JL-YR6D).';
    }

    final auth = InutilAuthService.instance;
    final initialUser = auth.currentUser;
    if (initialUser == null || initialUser.refreshToken.isEmpty) {
      return 'Necesitas tener sesión iniciada en tu celular para vincular la TV.';
    }
    if (!auth.isAccessAllowed) {
      return 'Tu cuenta debe estar activa para vincular una Smart TV.';
    }
    if (!InutilAuthService.isInutixToken(initialUser.refreshToken)) {
      await auth.ensureFreshIdToken();
    }
    final user = auth.currentUser ?? initialUser;

    try {
      final existing = await InutilFirestoreService.instance.getDocument(
        'tv_pairing/$code',
      );
      if (existing == null) {
        return 'No se encontró ese código en tu TV o ya expiró. Genera uno nuevo en la tele.';
      }
      if (existing['status'] != 'pending') {
        return 'Este código ya fue usado. Genera uno nuevo en tu TV.';
      }

      final encrypted = encryptPayload(
        {
          'refreshToken': user.refreshToken,
          'email': user.email,
          'displayName': user.displayName,
          'uid': user.uid,
        },
        deriveManualCodeKey(code),
      );

      final ok = await InutilFirestoreService.instance.setDocument(
        'tv_pairing/$code',
        {
          'status': 'approved',
          'mode': 'code',
          'payload': encrypted,
          'approvedByUid': user.uid,
          'approvedAt': DateTime.now(),
        },
        merge: true,
      );
      if (!ok) {
        return 'No se pudo autorizar la TV. Verifica tu conexión e intenta de nuevo.';
      }
      return null;
    } catch (e) {
      debugPrint('[TvQrPairing] Error aprobando TV por código: $e');
      return 'Error de conexión al vincular la TV. Intenta de nuevo.';
    }
  }
}
