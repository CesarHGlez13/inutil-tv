import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tubotv/constants/app_info.dart';
import 'package:tubotv/services/network_config_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NetworkConfigService.instance.resetForTest();
    await NetworkConfigService.instance.setProxy('');
  });

  tearDown(() async {
    NetworkConfigService.instance.resetForTest();
    await NetworkConfigService.instance.setProxy('');
  });

  group('v3.3.36 — Changelog orientado a usuario (cero contenido admin/infra)', () {
    const forbiddenTerms = [
      'X-Admin-Secret',
      'firebase_admin',
      'Panel Admin',
      'Firestore',
      'SQLite',
      'Cloudflare Workers',
      'app_config/',
      'mipmap-',
      'libmpv',
      'EWMA',
    ];

    test('las notas recientes (3.3.30–3.3.36) en CHANGELOG.md no exponen detalles administrativos ni internos', () {
      final full = File('CHANGELOG.md').readAsStringSync();
      final cutoff = full.indexOf('## 3.3.29');
      expect(cutoff, greaterThan(0));
      final recent = full.substring(0, cutoff);

      for (final term in forbiddenTerms) {
        expect(
          recent.toLowerCase(),
          isNot(contains(term.toLowerCase())),
          reason: 'El changelog de usuario no debe mencionar "$term"',
        );
      }
    });

    test('AppInfo.whatsNewHighlights es 100% amigable para usuario final', () {
      expect(AppInfo.whatsNewHighlights, isNotEmpty);
      final joined = AppInfo.whatsNewHighlights.join('\n').toLowerCase();
      for (final term in forbiddenTerms) {
        expect(joined, isNot(contains(term.toLowerCase())));
      }
    });
  });

  group('v3.3.36 — Compatibilidad con proxy HTTP configurado del sistema Android', () {
    test('detecta y aplica proxy del sistema en solicitudes externas pero mantiene 127.0.0.1 DIRECT', () async {
      final net = NetworkConfigService.instance;
      net.setSystemProxyForTest('proxy.empresa.local:8080');

      expect(net.systemProxyDetected, isTrue);
      expect(net.effectiveProxyHostPort, 'proxy.empresa.local:8080');
      expect(net.mpvProxyUrl, 'http://proxy.empresa.local:8080');
      expect(
        net.resolveProxyDirectiveForUri(Uri.parse('https://api.inutix.com/healthz')),
        'PROXY proxy.empresa.local:8080',
      );
      expect(
        net.resolveProxyDirectiveForUri(Uri.parse('http://127.0.0.1:45123/master.m3u8')),
        'DIRECT',
      );
      expect(
        net.resolveProxyDirectiveForUri(Uri.parse('http://localhost:45123/seg0.ts')),
        'DIRECT',
      );

      // Si el usuario configura un proxy manual, tiene prioridad sobre el del sistema
      await net.setProxy('10.10.0.5:3128');
      expect(net.systemProxyDetected, isFalse);
      expect(net.effectiveProxyHostPort, '10.10.0.5:3128');
      expect(
        net.resolveProxyDirectiveForUri(Uri.parse('https://meta.inutix.com/logo')),
        'PROXY 10.10.0.5:3128',
      );
      expect(
        net.resolveProxyDirectiveForUri(Uri.parse('http://127.0.0.1:45123/master.m3u8')),
        'DIRECT',
      );
    });
  });
}
