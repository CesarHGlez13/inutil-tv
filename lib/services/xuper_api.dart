/// Cliente limpio del portal Xuper/Koocan (APK `com.msandroid.mobile` 6.5.7).
///
/// Contrato verificado por ingeniería inversa del smali (no copiado):
///   * `bb/b.g()`  -> cabeceras fijas: `Content-type`, `apk`, `apkVer`, `spkgVer`.
///   * `bb/a.*`    -> `apk`  = `Context.getPackageName()`
///                    `apkVer`= `PackageInfo.versionCode`
///                    `spkgVer`=`Build.VERSION.RELEASE`
///   * `bb/c.l()`  -> `CommonParams` (12 campos, nombres exactos)
///   * `bb/c.d()`  -> `CombinedParams(commonParams, specificParams)` -> Gson
///   * `db/b2.i`   -> el JSON plano se entrega cifrado al motor nativo `q8/p0`
///   * `db/y1.X2`  -> `POST api/portalCore/v3/snToken` con `SnTokenBean`
///   * respuesta   -> `{returnCode, errorMessage, data}`
///
/// Wire: cuerpo = JSON -> 3DES-CBC (IV 0, PKCS5/7) -> base64 -> hex, enviado
/// como `{"data":"<hex>"}`; la respuesta se descifra con hex->base64->3DES.
///
/// Hallazgo F0 (2026-11-15, medido): el gateway del portal contesta
/// `portal200001 / 版本已停止使用` a *cualquier* `apk`/`apkVer`/`spkgVer` y a
/// cualquier forma de cuerpo, tanto en los seeds de `strings.xml` como en el
/// dominio visto en runtime (`gzhgvk.41tranuy.com`). La versión 6.5.7 está
/// retirada del lado servidor: tras `pm clear`, la APK real tampoco sincroniza
/// (`config.xml` queda vacío) y la UI que se ve son cachés viejos.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

/// Cifrado del portal: TripleDES 24 bytes, CBC, IV cero, relleno PKCS5(=PKCS7).
class XuperCrypto {
  static final Uint8List _key =
      _hexToBytes('e7af1ed7de1ffddd7bd3fe37ebdffde9ef3fe1ae39edfeb8');

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _bytesToHex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _pad(List<int> b) {
    final n = 8 - (b.length % 8);
    return [...b, ...List.filled(n, n)];
  }

  static List<int> _unpad(List<int> b) =>
      b.isEmpty ? b : b.sublist(0, b.length - b.last);

  static Uint8List _crypt(bool forEncryption, Uint8List data) {
    final cipher = CBCBlockCipher(DESedeEngine())
      ..init(
          forEncryption, ParametersWithIV(KeyParameter(_key), Uint8List(8)));
    final out = Uint8List(data.length);
    for (var off = 0; off < data.length; off += 8) {
      cipher.processBlock(data, off, out, off);
    }
    return out;
  }

  /// Texto plano UTF-8 -> hex(base64(3DES-CBC)).
  static String encryptString(String plain) {
    final ct = _crypt(true, Uint8List.fromList(_pad(utf8.encode(plain))));
    return _bytesToHex(base64.encode(ct).codeUnits);
  }

  /// hex(base64(3DES-CBC)) -> texto plano UTF-8.
  static String decryptString(String hexStr) {
    final s = hexStr.trim();
    final bytes = <int>[];
    for (var i = 0; i + 1 < s.length; i += 2) {
      bytes.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    final raw = base64.decode(latin1.decode(bytes));
    return utf8.decode(_unpad(_crypt(false, Uint8List.fromList(raw))));
  }

  /// JSON -> hex(base64(3DES-CBC)). Gson serializa en el orden de declaración
  /// del bean, que es el orden en que se construyen estos mapas.
  static String encryptJson(Map<String, dynamic> obj) =>
      encryptString(jsonEncode(obj));

  /// hex(base64(3DES)) -> Map; si el portal contesta JSON plano, lo devuelve.
  static Map<String, dynamic> decryptText(String hexStr) {
    final s = hexStr.trim();
    try {
      return jsonDecode(decryptString(s)) as Map<String, dynamic>;
    } catch (_) {
      return jsonDecode(s) as Map<String, dynamic>;
    }
  }
}

/// Error del portal (`returnCode` inesperado) o de transporte.
class XuperException implements Exception {
  final String message;
  final String? code;

  /// true cuando el gateway respondió que la versión del cliente ya no se usa
  /// (`portal200001`): no se arregla cambiando cabeceras ni cuerpo.
  final bool versionRetired;

  XuperException(this.message, [this.code, this.versionRetired = false]);
  @override
  String toString() => 'XuperException($code): $message';
}

/// Cliente del portal Xuper.
class XuperApi {
  XuperApi({
    List<String>? hosts,
    http.Client? client,
    Duration? timeout,
    String? sysVersion,
    DeviceInfo? device,
  })  : hosts = (hosts == null || hosts.isEmpty) ? defaultHosts : hosts,
        client = client ?? http.Client(),
        timeout = timeout ?? const Duration(seconds: 14),
        sysVersion = sysVersion ?? defaultSysVersion,
        device = device ?? DeviceInfo.random();

  /// Hosts reales leídos de `res/values/strings.xml` (`portal_main`,
  /// `portal_backup`, `h5_main`) más el host observado en TLS durante la
  /// ejecución del SDK. Al final quedan hosts históricos como último recurso.
  static const List<String> defaultHosts = [
    'dtgrd.txhnojlbu.com', // portal_main   (strings.xml)
    'c2tgd.izvhrdcjb.com', // portal_backup (strings.xml)
    'gzhgvk.41tranuy.com', // SNI observado en runtime
    'bg4gr.msfxethyc.com', // h5_main       (mismo gateway)
    'mptec.dhkrxuzcy.com', // históricos documentados por el puerto webOS
    'dio3ka.lpsyujwj.xyz',
    'ftmrmy.jdfey0cd.com',
    'fuxok.nguvmqhpk.com',
    'eajmnp.hcgv1dt8.com',
  ];

  /// Semilla con la que el portal deriva `sn`; la APK no la manda en el cuerpo,
  /// solo se usa como respaldo local si el portal no devuelve `sn`.
  static const String snTokenSalt = 'ntFT65w6itH!lHCPw7D=@qnsFC5adD28';
  static const String portalCode = 'masnew';

  /// Identidad del cliente real: paquete + versionCode de la APK 6.5.7.
  static const String appId = 'com.msandroid.mobile';
  static const String apkVerHeader = '60507';
  static const String defaultSysVersion = '14';
  static const String userAgent = 'okhttp/3.12.12';

  /// Código del gateway cuando la versión del cliente fue retirada.
  static const String codeVersionRetired = 'portal200001';

  final List<String> hosts;
  final http.Client client;
  final Duration timeout;
  final String sysVersion;
  final DeviceInfo device;

  String? workingHost;
  String sn = '';
  String snToken = '';
  String userId = '';
  String userToken = '';

  bool get ready => userToken.isNotEmpty;

  /// Cabeceras exactas que arma `bb/b.g()` de la APK.
  Map<String, String> get headers => {
        'Content-type': 'application/json;charset=utf-8',
        'User-Agent': userAgent,
        'apk': appId,
        'apkVer': apkVerHeader,
        'spkgVer': sysVersion,
      };

  /// `CommonParams` (bb/c.l): 12 campos, nombres y orden verificados.
  Map<String, dynamic> commonParams() => {
        'apkVersion': apkVerHeader,
        'appId': appId,
        'appLanguage': device.language,
        'cpu': device.cpu,
        'deviceToken': device.deviceToken,
        'hardwareInfo': device.hardware,
        'loginType': device.loginType,
        'model': device.model,
        'product': device.product,
        'reserve1': device.reserve1,
        'sn': sn,
        'sysVersion': sysVersion,
      };

  /// POST cifrado con rotación de host: sobre `commonParams`/`specificParams`
  /// cifrado y enviado como `{"data":"<hex>"}`.
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> specific,
      {bool onlyCommon = false}) async {
    final envelope = onlyCommon
        ? {'commonParams': commonParams()}
        : {'commonParams': commonParams(), 'specificParams': specific};
    final payload = jsonEncode({'data': XuperCrypto.encryptJson(envelope)});
    final order = <String>[
      if (workingHost != null) workingHost!,
      ...hosts.where((h) => h != workingHost),
    ];
    String? lastErr;
    for (final h in order) {
      try {
        final r = await client
            .post(Uri.parse('https://$h/api/portalCore/$path'),
                headers: headers, body: payload)
            .timeout(timeout);
        if (r.statusCode != 200) {
          lastErr = '$h HTTP ${r.statusCode}';
          continue;
        }
        workingHost = h;
        final out = XuperCrypto.decryptText(r.body);
        final code = '${out['returnCode'] ?? out['portalCode'] ?? ''}';
        final msg = '${out['errorMessage'] ?? out['message'] ?? ''}';
        if (code.isNotEmpty && code != '0' && code != 'portal000000') {
          if (code == codeVersionRetired) {
            throw XuperException(
              '$path: versión de cliente retirada por el proveedor ($msg)',
              code,
              true,
            );
          }
          if (code.startsWith('aaa100')) {
            userId = '';
            userToken = '';
          }
          throw XuperException('$path: $msg', code);
        }
        return out;
      } on XuperException {
        rethrow;
      } catch (e) {
        lastErr = '$h: $e';
      }
    }
    throw XuperException('sin host disponible ($lastErr)');
  }

  /// Datos del dispositivo para `SnTokenBean` (21 campos del bean real).
  Map<String, dynamic> snTokenBean() => device.snTokenBean();

  /// 1) `v3/snToken` 2) `v8/active` -> `sn`, `snToken`, `userId`, `userToken`.
  Future<void> session() async {
    final t = await post('v3/snToken', snTokenBean());
    final data = (t['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    snToken = '${data['snToken'] ?? ''}';
    if (snToken.isEmpty) throw XuperException('respuesta sin snToken');
    final s = '${data['sn'] ?? ''}';
    sn = s.isNotEmpty
        ? s
        : crypto.md5.convert(utf8.encode('$snToken$snTokenSalt')).toString();
    userId = '${data['userId'] ?? ''}';
    final a = await post('v8/active', {
      'snToken': snToken,
      'authVersion': '',
      'authCode': '',
      'portalCode': portalCode,
      'loginType': device.loginType,
    });
    final ad = (a['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    userId = '${ad['userId'] ?? userId}';
    userToken = '${ad['userToken'] ?? ''}';
  }

  Future<void> ensureSession() async {
    if (ready) return;
    await session();
  }

  /// Categorías raíz (Live/VOD): el portal las entrega en `getHome`.
  Future<List<Map<String, dynamic>>> catalogRoots() async {
    final r = await post('getHome', {'columnId': 0});
    return _maps(r['data'], ['columnList', 'childColumnList', 'list']);
  }

  /// Canales en vivo: `v7/getLiveData` (la APK no tiene `startPlayLive`).
  Future<List<Map<String, dynamic>>> liveChannels(
      {int columnId = 77040}) async {
    await ensureSession();
    final r = await post('v7/getLiveData', {
      'columnId': columnId,
      'page': 1,
      'pageSize': 200,
      'programCount': 3,
    });
    return _maps(r['data'], ['liveList', 'channelList', 'list']);
  }

  /// EPG de un canal: `v3/getProgram`.
  Future<List<Map<String, dynamic>>> program(String channelId) async {
    await ensureSession();
    final r = await post('v3/getProgram', {'channelId': channelId});
    return _maps(r['data'], ['programList', 'list']);
  }

  /// Contenido de una columna (VOD/Series/Películas): `v3/getColumnContents`.
  Future<List<Map<String, dynamic>>> columnContents(int columnId,
      {int page = 1, int pageSize = 40}) async {
    await ensureSession();
    final r = await post('v3/getColumnContents', {
      'columnId': columnId,
      'page': page,
      'pageSize': pageSize,
    });
    return _maps(r['data'], ['contentList', 'list', 'items']);
  }

  /// Portadas de la home: `v3/getShelveData`.
  Future<List<Map<String, dynamic>>> shelf(int columnId) async {
    await ensureSession();
    final r = await post('v3/getShelveData', {'columnId': columnId});
    return _maps(r['data'], ['shelveList', 'list']);
  }

  /// Búsqueda: `v3/searchByName`.
  Future<List<Map<String, dynamic>>> search(String value,
      {int page = 1, int pageSize = 40}) async {
    await ensureSession();
    final r = await post('v3/searchByName',
        {'keyword': value, 'page': page, 'pageSize': pageSize});
    return _maps(r['data'], ['contentList', 'list']);
  }

  /// Detalle de un título: `v4/getItemData`.
  Future<Map<String, dynamic>> itemData(String contentId) async {
    await ensureSession();
    final r = await post('v4/getItemData', {'contentId': contentId});
    return ((r['data'] as Map?)?.cast<String, dynamic>()) ?? const {};
  }

  /// URLs reales de un VOD: `v10/startPlayVOD`.
  Future<List<String>> playVod(String contentId) async {
    await ensureSession();
    final r = await post('v10/startPlayVOD', {
      'contentId': contentId,
      'definition': 0,
      'playType': 0,
    });
    return _extractUrls(r['data']);
  }

  /// Lista de CDNs/servidores de balanceo: `v15/getSlbInfo`.
  Future<List<String>> slbInfo() async {
    await ensureSession();
    final r = await post('v15/getSlbInfo', {'type': 1});
    return _extractUrls(r['data']);
  }

  /// Latido para mantener la sesión: `v5/heartbeat`.
  Future<void> heartbeat() async {
    await post('v5/heartbeat', {'type': 1});
  }

  static List<Map<String, dynamic>> _maps(dynamic node, List<String> keys) {
    if (node is List) {
      return node
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    if (node is Map) {
      for (final k in keys) {
        final v = node[k];
        if (v is List) {
          return v
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
        }
      }
      for (final v in node.values) {
        final got = _maps(v, keys);
        if (got.isNotEmpty) return got;
      }
    }
    return const [];
  }

  /// Recoge URLs de cualquier forma (lista, mapa anidado o string separado por
  /// comas), porque el portal las mete en campos distintos según el CDN.
  List<String> _extractUrls(dynamic node, [List<String>? acc]) {
    final out = acc ?? <String>[];
    if (node is String) {
      for (final p in node.split(RegExp(r'[,;\s]+'))) {
        if (p.startsWith('http')) out.add(p);
      }
    } else if (node is List) {
      for (final e in node) {
        _extractUrls(e, out);
      }
    } else if (node is Map) {
      for (final e in node.values) {
        _extractUrls(e, out);
      }
    }
    return out;
  }
}

/// Huella de dispositivo: rellena `SnTokenBean` y `CommonParams` con valores
/// plausibles (el gateway solo mira identidad de cliente, no hardware).
class DeviceInfo {
  DeviceInfo({
    required this.androidId,
    required this.serialNumber,
    required this.etheMac,
    required this.wifiMac,
    required this.gatewayMac,
    required this.cpuId,
    this.board = 'goldfish_x86_64',
    this.brand = 'google',
    this.cpu = 'x86_64',
    this.device = 'emu64xa',
    this.diskInfo = '11811160064',
    this.display = 'UE1A.230829.036.A4',
    this.fingerprint =
        'google/sdk_gphone64_x86_64/emu64xa:14/UE1A.230829.036.A4/12096271:user/release-keys',
    this.hardware = 'ranchu',
    this.host = 'buildbox',
    this.manufacturer = 'Google',
    this.model = 'sdk_gphone64_x86_64',
    this.product = 'sdk_gphone64_x86_64',
    this.ramSize = '4294967296',
    this.romSize = '11811160064',
    this.tags = 'release-keys',
    this.language = 'es',
    this.loginType = '3',
    this.reserve1 = '',
  });

  /// Huella aleatoria pero autoconsistente (una por instalación).
  factory DeviceInfo.random() {
    final r = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    String mac() => List.generate(6, (_) => hex(2)).join(':');
    return DeviceInfo(
      androidId: hex(16),
      serialNumber: hex(16),
      etheMac: mac(),
      wifiMac: mac(),
      gatewayMac: mac(),
      cpuId: hex(16),
    );
  }

  final String androidId, serialNumber, etheMac, wifiMac, gatewayMac, cpuId;
  final String board, brand, cpu, device, diskInfo, display, fingerprint;
  final String hardware, host, manufacturer, model, product, ramSize, romSize;
  final String tags, language, loginType, reserve1;

  String get deviceToken => androidId;

  /// `mobile.com.requestframe.utils.bean.SnTokenBean` (21 campos exactos).
  Map<String, dynamic> snTokenBean() => {
        'androidId': androidId,
        'board': board,
        'brand': brand,
        'cpuAbi': cpu,
        'cpuId': cpuId,
        'device': device,
        'diskInfo': diskInfo,
        'display': display,
        'etheMac': etheMac,
        'fingerprint': fingerprint,
        'gatewayMac': gatewayMac,
        'hardware': hardware,
        'host': host,
        'manufacturer': manufacturer,
        'ramSize': ramSize,
        'romSize': romSize,
        'se': '',
        'serialNumber': serialNumber,
        'tags': tags,
        'verId': '',
        'wifiMac': wifiMac,
      };
}
