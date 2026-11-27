import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/firebase_auth_service.dart';
import 'package:tubotv/services/inutix_license_ticket_service.dart';

const String _prodPubKeyK1 =
    '047f4f1c87530b4f31ef9939e62acf44a8753fdafac405e0d8a543a524646d1b72'
    'f22b17dfe84e29d4ddd4dc4020185163eff2778e41e8615f7f9f999f8814e1d1';

const String _tvPackageName = 'dev.cesar.tubotv';
const String _tvCertSha256 =
    '00e7d8692c82722ff208f01100eae0fab868cf42372b53f6b69b506cf60765b0';

({pc.ECPrivateKey priv, String pubHex}) _generateTestEcKeyPair() {
  final rnd = pc.FortunaRandom();
  final seed = Uint8List(32);
  final rng = Random(424242);
  for (var i = 0; i < seed.length; i++) {
    seed[i] = rng.nextInt(256);
  }
  rnd.seed(pc.KeyParameter(seed));

  final gen = pc.ECKeyGenerator()
    ..init(
      pc.ParametersWithRandom(
        pc.ECKeyGeneratorParameters(pc.ECCurve_secp256r1()),
        rnd,
      ),
    );
  final pair = gen.generateKeyPair();
  final priv = pair.privateKey;
  final pub = pair.publicKey;
  final pubBytes = pub.Q!.getEncoded(false);
  final pubHex =
      pubBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return (priv: priv, pubHex: pubHex);
}

Uint8List _bigIntTo32Bytes(BigInt value) {
  final out = Uint8List(32);
  var v = value;
  for (var i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

String _signTicketEs256(Map<String, Object?> payload, pc.ECPrivateKey priv) {
  final payloadB64 =
      base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  final signer = pc.ECDSASigner(pc.SHA256Digest(), pc.HMac(pc.SHA256Digest(), 64));
  signer.init(true, pc.PrivateKeyParameter<pc.ECPrivateKey>(priv));
  final sig = signer.generateSignature(
    Uint8List.fromList(ascii.encode(payloadB64)),
  ) as pc.ECSignature;
  final raw64 = Uint8List(64)
    ..setRange(0, 32, _bigIntTo32Bytes(sig.r))
    ..setRange(32, 64, _bigIntTo32Bytes(sig.s));
  final sigB64 = base64Url.encode(raw64).replaceAll('=', '');
  return '$payloadB64.$sigB64';
}

Future<void> _seedAuthSession({
  required String uid,
  required String email,
  String role = 'user',
  String status = 'active',
  bool isActive = true,
  DateTime? expiresAt,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    'inutil_tv_auth_user_v3',
    jsonEncode({
      'uid': uid,
      'email': email,
      'displayName': 'Cliente',
      'role': role,
      'status': status,
      'isActive': isActive,
      'accountExpiresAt': expiresAt?.toIso8601String(),
      'currentTvDeviceId': '',
      'currentSmartTvDeviceId': '',
    }),
  );
  await prefs.setString(
    'inutil_tv_auth_session_v3',
    jsonEncode({
      'uid': uid,
      'email': email,
      'idToken': 'id-token-l2',
      'refreshToken': 'refresh-token-l2',
    }),
  );
  await prefs.setString(
    'inutil_tv_last_validated_v3',
    DateTime.now().toIso8601String(),
  );
  await InutilAuthService.instance.initialize();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    InutilAuthService.testSkipOnlineValidation = true;
    await InutixLicenseTicketService.instance.resetForTest();
  });

  tearDown(() async {
    await InutilAuthService.instance.signOut();
    await InutixLicenseTicketService.instance.resetForTest();
    InutilAuthService.testSkipOnlineValidation = false;
  });

  group('Nivel 1 — Endurecimiento de InutilUser y firebase_auth_service', () {
    test('copyWith(clearAccountExpiresAt: true) borra accountExpiresAt explícitamente',
        () {
      final active = InutilUser(
        uid: 'u1',
        email: 'user@ejemplo.com',
        status: 'active',
        isActive: true,
        accountExpiresAt: DateTime(2030, 1, 1),
      );
      final pending = active.copyWith(
        status: 'pending',
        isActive: false,
        clearAccountExpiresAt: true,
      );
      expect(pending.status, 'pending');
      expect(pending.isActive, isFalse);
      expect(pending.accountExpiresAt, isNull);
      expect(pending.licenseValid, isFalse);
    });

    test(
        '_applyRemoteDoc nunca deja isActive=true ni accountExpiresAt!=null cuando status != active y role != admin',
        () async {
      await _seedAuthSession(
        uid: 'u_downgrade',
        email: 'cliente@ejemplo.com',
        status: 'active',
        isActive: true,
        expiresAt: DateTime.now().add(const Duration(days: 30)),
      );
      expect(InutilAuthService.instance.currentUser!.licenseValid, isTrue);

      // Incluso si llega un doc inconsistente con isActive:true o fecha futura
      // pero status:'pending', Nivel 1 fuerza isActive=false y accountExpiresAt=null.
      await InutilAuthService.instance.applyRemoteDocForTest({
        'role': 'user',
        'status': 'pending',
        'isActive': true,
        'accountExpiresAt': DateTime.now().add(const Duration(days: 60)),
      });

      final updated = InutilAuthService.instance.currentUser!;
      expect(updated.status, 'pending');
      expect(updated.isActive, isFalse);
      expect(updated.accountExpiresAt, isNull);
      expect(updated.licenseValid, isFalse);
      expect(InutilAuthService.instance.isAccessAllowed, isFalse);
    });
  });

  group('Nivel 2 — Llave k1, verificador ES256 y contrato de ticket', () {
    test('llave pública k1 de producción coincide exactamente y activa modo estricto',
        () {
      expect(InutixLicenseTicketService.compiledPublicKeyK1Hex, _prodPubKeyK1);
      expect(
        InutixLicenseTicketService.compiledPublicKeyK1Hex.length,
        130,
      );
      expect(
        InutixLicenseTicketService.instance.isStrictEnforcementActive,
        isTrue,
      );
    });

    test('verifica firma ES256 real, rechaza manipulación y valida bindings + anti-rollback',
        () async {
      final kp = _generateTestEcKeyPair();
      var now = DateTime.utc(2026, 11, 27, 6, 0, 0);
      final serverNowMs = now.millisecondsSinceEpoch;

      final payload = <String, Object?>{
        'v': 1,
        'kid': 'k1',
        'uid': 'uid_tv_1',
        'role': 'user',
        'status': 'active',
        'deviceId': 'dev_tv_1',
        'platform': 'android',
        'apkCertSha256': _tvCertSha256,
        'iatMs': serverNowMs,
        'expMs': serverNowMs + const Duration(hours: 24).inMilliseconds,
        'offlineExpMs': serverNowMs + const Duration(hours: 72).inMilliseconds,
        'allowStreaming': true,
        'allowDownloads': true,
      };
      final validTicket = _signTicketEs256(payload, kp.priv);

      Map<String, dynamic>? capturedBody;
      String? capturedAuth;

      final service = InutixLicenseTicketService(
        httpClient: MockClient((req) async {
          capturedAuth = req.headers['Authorization'];
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'ok': true,
              'keyId': 'k1',
              'serverNowMs': serverNowMs,
              'ticket': validTicket,
            }),
            200,
          );
        }),
        integrityLoader: () async => const InutixAppIntegrityInfo(
          packageName: _tvPackageName,
          apkCertSha256: _tvCertSha256,
        ),
        clock: () => now,
        pinnedPublicKeysHex: {'k1': kp.pubHex},
      );

      final res = await service.refreshFromServer(
        idToken: 'tok_real',
        uid: 'uid_tv_1',
        deviceId: 'dev_tv_1',
        appVersion: '3.3.53',
      );
      expect(res.status, LicenseTicketRefreshStatus.ok);
      expect(capturedAuth, 'Bearer tok_real');
      expect(capturedBody?['packageName'], _tvPackageName);
      expect(capturedBody?['apkCertSha256'], _tvCertSha256);
      expect(capturedBody?['app'], 'tv');

      expect(
        service.isOnlineStreamingAuthorized(
          uid: 'uid_tv_1',
          deviceId: 'dev_tv_1',
        ),
        isTrue,
      );
      // Binding mismatch rechazado
      expect(
        service.isOnlineStreamingAuthorized(
          uid: 'otro_uid',
          deviceId: 'dev_tv_1',
        ),
        isFalse,
      );
      expect(
        service.isOnlineStreamingAuthorized(
          uid: 'uid_tv_1',
          deviceId: 'otro_device',
        ),
        isFalse,
      );
      expect(
        service.isOnlineStreamingAuthorized(
          uid: 'uid_tv_1',
          deviceId: 'dev_tv_1',
          apkCertSha256Override: 'f' * 64,
        ),
        isFalse,
      );

      // Ticket manipulado (alterar status o expMs sin re-firmar) falla ES256
      final tamperedPayload = Map<String, Object?>.from(payload)
        ..['expMs'] = serverNowMs + const Duration(days: 365).inMilliseconds;
      final tamperedB64 = base64Url
          .encode(utf8.encode(jsonEncode(tamperedPayload)))
          .replaceAll('=', '');
      final originalSig = validTicket.split('.')[1];
      expect(
        InutixEs256Verifier.verifyTicket(
          ticket: '$tamperedB64.$originalSig',
          pinnedPublicKeysHex: {'k1': kp.pubHex},
        ),
        isFalse,
      );

      // Tras +25 h expira streaming online, pero sigue dentro de ventana offline 72 h
      now = now.add(const Duration(hours: 25));
      expect(
        service.isOnlineStreamingAuthorized(
          uid: 'uid_tv_1',
          deviceId: 'dev_tv_1',
        ),
        isFalse,
      );
      expect(
        service.isOfflinePlaybackAuthorized(
          uid: 'uid_tv_1',
          deviceId: 'dev_tv_1',
        ),
        isTrue,
      );

      // Anti-clock-rollback: atrasar el reloj del dispositivo 30 min respecto a serverNowMs bloquea
      now = DateTime.fromMillisecondsSinceEpoch(serverNowMs, isUtc: true)
          .subtract(const Duration(minutes: 30));
      expect(
        service.isOnlineStreamingAuthorized(
          uid: 'uid_tv_1',
          deviceId: 'dev_tv_1',
        ),
        isFalse,
      );
      expect(
        service.isOfflinePlaybackAuthorized(
          uid: 'uid_tv_1',
          deviceId: 'dev_tv_1',
        ),
        isFalse,
      );
    });

    test('maneja rechazos 403 del servidor (PENDING, EXPIRED, BLOCKED, INVALID_APP_SIGNATURE, DEVICE_CONFLICT)',
        () async {
      final codes = [
        ('LICENSE_PENDING', 'Cuenta pendiente.'),
        ('LICENSE_EXPIRED', 'Licencia expirada.'),
        ('LICENSE_BLOCKED', 'Cuenta bloqueada.'),
        ('INVALID_APP_SIGNATURE', 'Versión no oficial de la aplicación.'),
        ('DEVICE_CONFLICT', 'Otro dispositivo activo en esta cuenta.'),
      ];

      for (final (code, msg) in codes) {
        final service = InutixLicenseTicketService(
          httpClient: MockClient((_) async => http.Response(
                jsonEncode({'ok': false, 'code': code, 'message': msg}),
                403,
              )),
          integrityLoader: () async => const InutixAppIntegrityInfo(
            packageName: _tvPackageName,
            apkCertSha256: _tvCertSha256,
          ),
        );

        final res = await service.refreshFromServer(
          idToken: 'tok',
          uid: 'u_reject',
          deviceId: 'd_1',
          appVersion: '3.3.53',
          force: true,
        );
        expect(res.status, LicenseTicketRefreshStatus.rejectedByServer);
        expect(res.rejectionCode, code);
        expect(service.hasServerRejection, isTrue);
        expect(
          service.isOnlineStreamingAuthorized(uid: 'u_reject', deviceId: 'd_1'),
          isFalse,
        );

        // Verificar transición de estado en InutilAuthService
        await _seedAuthSession(
          uid: 'u_reject',
          email: 'cliente@ejemplo.com',
          status: 'active',
          isActive: true,
          expiresAt: DateTime.now().add(const Duration(days: 15)),
        );
        await InutilAuthService.instance.applyTicketRefreshResultForTest(res);
        final auth = InutilAuthService.instance;
        if (code == 'LICENSE_PENDING') {
          expect(auth.currentUser!.status, 'pending');
          expect(auth.currentUser!.isActive, isFalse);
          expect(auth.currentUser!.accountExpiresAt, isNull);
          expect(auth.isAccessAllowed, isFalse);
        } else if (code == 'LICENSE_EXPIRED') {
          expect(auth.currentUser!.isExpired, isTrue);
          expect(auth.currentUser!.isActive, isFalse);
          expect(auth.isAccessAllowed, isFalse);
        } else {
          expect(auth.isKickedOut, isTrue);
          expect(auth.kickedOutReason, msg);
          expect(auth.isAccessAllowed, isFalse);
        }
        await auth.signOut();
      }
    });

    test('sin testSkipOnlineValidation exige pase ES256 válido para canPlay / canStreamOnline',
        () async {
      await _seedAuthSession(
        uid: 'u_strict',
        email: 'strict@ejemplo.com',
        status: 'active',
        isActive: true,
        expiresAt: DateTime.now().add(const Duration(days: 15)),
      );
      // Con bypass de tests activo -> permitido
      expect(InutilAuthService.instance.canPlay, isTrue);
      expect(InutilAuthService.instance.canStreamOnline, isTrue);

      // En modo producción (testSkipOnlineValidation = false) sin ticket ES256 -> bloqueado
      InutilAuthService.testSkipOnlineValidation = false;
      expect(InutilAuthService.instance.canPlay, isFalse);
      expect(InutilAuthService.instance.canStreamOnline, isFalse);
      expect(
        InutilAuthService.instance.blockedReason,
        contains('licencia oficial'),
      );
      InutilAuthService.testSkipOnlineValidation = true;
    });
  });
}
