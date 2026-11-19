import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/xuper_api.dart';

/// Vectores generados con el cliente Python de referencia
/// (`research/xuper_api.py`, verificado contra el portal real):
/// hex(base64(3DES-CBC(IV=0, PKCS7))) de la cadena exacta que se manda.
const _vectores = <String, String>{
  '{"a":1}': '44357475557643476c67383d',
  '{"commonParams":{"apkVersion":"60507","appId":"com.msandroid.mobile","sysVersion":"14","sn":"7c5cd33b779e95d468c0f335fe4bc0d0"},"specificParams":{"verId":""}}':
      '3778414a33646b6a792b6a4b50596e757a6667745a4d4c7637714f53665743572b347666534c7974576648684f5353667a64664163576130797962796679374d2f2b7141456a50364c44782f5556472b4c4b4f474e5958777141444d69665058336b582f77696e4d684e377a2f516c726841533830327a64584153315a3642496468737667776e77306269614a31434c5368546c4b3868432f434970377273786f674864677a376f30706f447453332f58576d43444c4a71754c497556615534626258644d673054513236516d37785a7235384e56673d3d',
  '{"msg":"versión 已停止","n":42}':
      '5857345039303779347447733633413059413248706839426d4756654b66585073536d4c455a457553713646396d554a7454642b32413d3d',
};

void main() {
  group('cifrado del portal (3DES-CBC IV=0 -> base64 -> hex)', () {
    for (final e in _vectores.entries) {
      test('vector ${e.key.length} chars', () {
        expect(XuperCrypto.encryptString(e.key), e.value);
        expect(XuperCrypto.decryptString(e.value), e.key);
      });
    }

    test('ida y vuelta sobre un sobre real', () {
      final body = {
        'commonParams': {'apkVersion': '60507', 'appId': 'com.msandroid.mobile'},
        'specificParams': {'androidId': 'b7d37a2c41df8dac'},
      };
      final hex = XuperCrypto.encryptJson(body);
      expect(XuperCrypto.decryptText(hex), body);
    });

    test('acepta JSON plano (el portal lo usa en errores)', () {
      const plano = '{"returnCode":"portal200001","errorMessage":"版本已停止使用"}';
      final out = XuperCrypto.decryptText(plano);
      expect(out['returnCode'], 'portal200001');
      expect(out['errorMessage'], '版本已停止使用');
    });
  });

  group('contrato verificado de la APK 6.5.7', () {
    final api = XuperApi(device: DeviceInfo.random());

    test('cabeceras exactas de bb/b.g()', () {
      expect(api.headers.keys.toList(), [
        'Content-type',
        'User-Agent',
        'apk',
        'apkVer',
        'spkgVer',
      ]);
      expect(api.headers['apk'], 'com.msandroid.mobile');
      expect(api.headers['apkVer'], '60507');
      expect(api.headers['Content-type'], 'application/json;charset=utf-8');
      expect(api.headers['User-Agent'], 'okhttp/3.12.12');
    });

    test('CommonParams tiene los 12 nombres de bb/c.l()', () {
      expect(api.commonParams().keys.toList(), [
        'apkVersion',
        'appId',
        'appLanguage',
        'cpu',
        'deviceToken',
        'hardwareInfo',
        'loginType',
        'model',
        'product',
        'reserve1',
        'sn',
        'sysVersion',
      ]);
    });

    test('SnTokenBean tiene los 21 campos del bean', () {
      expect(api.snTokenBean().keys.toList(), [
        'androidId', 'board', 'brand', 'cpuAbi', 'cpuId', 'device', 'diskInfo',
        'display', 'etheMac', 'fingerprint', 'gatewayMac', 'hardware', 'host',
        'manufacturer', 'ramSize', 'romSize', 'se', 'serialNumber', 'tags',
        'verId', 'wifiMac',
      ]);
    });

    test('los hosts vienen del strings.xml real', () {
      expect(XuperApi.defaultHosts.take(2),
          ['dtgrd.txhnojlbu.com', 'c2tgd.izvhrdcjb.com']);
    });

    test('el sobre del cuerpo es {data: hex}', () {
      final api2 = XuperApi(hosts: const ['127.0.0.1'], device: DeviceInfo.random());
      final hex = XuperCrypto.encryptJson({
        'commonParams': api2.commonParams(),
        'specificParams': api2.snTokenBean(),
      });
      final body = jsonEncode({'data': hex});
      expect((jsonDecode(body) as Map).keys, ['data']);
      expect(XuperCrypto.decryptText((jsonDecode(body) as Map)['data'] as String)
          ['commonParams']['appId'], 'com.msandroid.mobile');
    });
  });
}
