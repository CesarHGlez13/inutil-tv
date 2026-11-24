import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_info.dart';
import 'firebase_auth_service.dart';
import 'firebase_config.dart';
import 'firebase_firestore_service.dart';
import 'ota_download_manager.dart';

/// Información de lanzamiento OTA y Kill Switch (OTA forzosa) de InútilTV.
/// Compatible 100% con el mismo modelo de Inútil Music, guardado en
/// Firestore `app_config/tv_release` (independiente de `app_config/release`).
@immutable
class InutilTvReleaseInfo {
  const InutilTvReleaseInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    this.apkDownloadUrl = '',
    this.mandatory = false,
    required this.publishedAt,
    this.androidDownloads = const <String, String>{},
    this.minSupportedVersion = '',
  });

  final String currentVersion;
  final String latestVersion;
  final List<String> releaseNotes;
  final String apkDownloadUrl;
  final bool mandatory;
  final DateTime publishedAt;
  final Map<String, String> androidDownloads;
  final String minSupportedVersion;

  bool get belowMinSupported {
    final min = minSupportedVersion.trim();
    if (min.isEmpty) return false;
    final baseline = currentVersion.trim().isEmpty
        ? AppInfo.appVersion
        : currentVersion.trim();
    return compareSemver(baseline, min) < 0;
  }

  bool get updateAvailable {
    final baseline = currentVersion.trim().isEmpty
        ? AppInfo.appVersion
        : currentVersion.trim();
    return compareSemver(latestVersion, baseline) > 0 || belowMinSupported;
  }

  bool get effectiveMandatory => mandatory || belowMinSupported;

  bool get isBlockingUpdate =>
      belowMinSupported || (updateAvailable && effectiveMandatory);

  static String normalizeAbiKey(String abi) => abi
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-]+'), '_')
      .replaceAll(RegExp(r'[^a-z0-9_]'), '');

  String apkUrlForAbi(String abi) {
    final norm = normalizeAbiKey(abi);
    for (final key in <String>[norm, 'universal', 'split_universal']) {
      if (key.isEmpty) continue;
      final url = androidDownloads[key]?.trim() ?? '';
      if (url.isNotEmpty) return url;
    }
    return apkDownloadUrl.trim();
  }

  Map<String, dynamic> toJson() => {
        'currentVersion': currentVersion,
        'latestVersion': latestVersion,
        'releaseNotes': releaseNotes,
        'apkDownloadUrl': apkDownloadUrl,
        'mandatory': mandatory,
        'minSupportedVersion': minSupportedVersion,
        'publishedAt': publishedAt.toUtc().toIso8601String(),
        'androidDownloads': androidDownloads,
      };

  factory InutilTvReleaseInfo.fromJson(
    Map<String, dynamic> json, {
    String? currentVersionOverride,
  }) {
    final rawNotes = json['releaseNotes'];
    final notes = <String>[];
    if (rawNotes is List) {
      for (final item in rawNotes) {
        final t = item?.toString().trim() ?? '';
        if (t.isNotEmpty) notes.add(t);
      }
    }

    final rawDownloads = json['androidDownloads'];
    final downloads = <String, String>{};
    if (rawDownloads is Map) {
      for (final e in rawDownloads.entries) {
        final k = normalizeAbiKey(e.key.toString());
        final v = e.value is Map
            ? ((e.value as Map)['url'] ?? '').toString().trim()
            : (e.value?.toString().trim() ?? '');
        if (k.isNotEmpty && v.isNotEmpty) downloads[k] = v;
      }
    }

    return InutilTvReleaseInfo(
      currentVersion: currentVersionOverride ??
          (json['currentVersion'] as String?) ??
          AppInfo.appVersion,
      latestVersion:
          (json['latestVersion'] as String?)?.trim().isNotEmpty == true
              ? (json['latestVersion'] as String).trim()
              : AppInfo.appVersion,
      releaseNotes: notes,
      apkDownloadUrl: (json['apkDownloadUrl'] as String?)?.trim() ?? '',
      mandatory: json['mandatory'] as bool? ?? false,
      minSupportedVersion:
          (json['minSupportedVersion'] as String?)?.trim() ?? '',
      publishedAt:
          DateTime.tryParse(json['publishedAt']?.toString() ?? '') ??
              DateTime.now().toUtc(),
      androidDownloads: Map<String, String>.unmodifiable(downloads),
    );
  }

  static int compareSemver(String a, String b) {
    final pa = _parts(a);
    final pb = _parts(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }

  static List<int> _parts(String v) {
    final clean = v.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final mainPart = clean.split(RegExp(r'[\+\-]')).first;
    return mainPart
        .split('.')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .toList(growable: false);
  }
}

/// Servicio centralizado de actualizaciones OTA e OTA Forzosa para InútilTV.
class InutilUpdateService {
  InutilUpdateService._();
  static final InutilUpdateService instance = InutilUpdateService._();

  static const MethodChannel _channel = MethodChannel('inutil_tv/app_update');
  static const String _prefsCacheKey = 'inutil_tv_cached_release_v1';
  static const String _manifestUrlPrefKey = 'inutil_tv_manifest_url_v1';

  /// Repositorio público de Releases de GitHub (artefactos OTA sin código fuente),
  /// idéntico a `CesarHGlez13/inutil-music`.
  static const String releaseRepo = String.fromEnvironment(
    'RELEASE_REPO',
    defaultValue: 'CesarHGlez13/inutil-tv',
  );

  String get _githubManifestUrl =>
      'https://github.com/$releaseRepo/releases/latest/download/release.json';

  final OtaDownloadManager downloadManager = OtaDownloadManager();

  String get _releaseDocumentUrl =>
      '${FirebaseConfig.firestoreBaseUrl}/app_config/tv_release';

  @visibleForTesting
  static InutilTvReleaseInfo? testReleaseOverride;

  Map<String, String> _headers() {
    final idToken = InutilAuthService.instance.currentUser?.idToken;
    return {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': FirebaseConfig.apiKey,
      if (idToken != null && idToken.isNotEmpty)
        'Authorization': 'Bearer $idToken',
    };
  }

  Future<String> primaryAbi() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return '';
    try {
      return (await _channel.invokeMethod<String>('primaryAbi')) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<bool> canRequestPackageInstalls() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return (await _channel.invokeMethod<bool>('canRequestPackageInstalls')) ??
          true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> openInstallUnknownAppsSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return (await _channel
              .invokeMethod<bool>('openInstallUnknownAppsSettings')) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> installApk(String path) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return (await _channel.invokeMethod<bool>(
            'installPackage',
            {'path': path},
          )) ??
          false;
    } catch (e) {
      debugPrint('[InutilUpdateService] Error lanzando instalador: $e');
      return false;
    }
  }

  /// Consulta la versión publicada combinando:
  /// 1. Manifiesto personalizado (si existe).
  /// 2. Firestore `app_config/tv_release` (cambios en vivo desde el Panel Admin)
  ///    y GitHub Releases `releases/latest/download/release.json` en paralelo,
  ///    eligiendo siempre la versión más reciente (o la que active Kill Switch).
  /// 3. Caché local si no hay red.
  Future<InutilTvReleaseInfo> checkForUpdate({String? currentVersion}) async {
    final effectiveCurrent = currentVersion ?? AppInfo.appVersion;
    final pinned = testReleaseOverride;
    if (pinned != null) return pinned;

    // 1. Manifiesto JSON opcional configurado manualmente
    final customUrl = await manifestUrlSetting();
    if (customUrl.isNotEmpty) {
      final fromCustom = await _fetchFromManifestUrl(
        customUrl,
        currentVersion: effectiveCurrent,
      );
      if (fromCustom != null) {
        await _saveCachedRelease(fromCustom);
        return fromCustom;
      }
    }

    // 2. Consultar Firestore `app_config/tv_release` y GitHub Releases en paralelo
    final results = await Future.wait<InutilTvReleaseInfo?>([
      _fetchFirestoreRelease(currentVersion: effectiveCurrent),
      if (!FirebaseConfig.useEmulator)
        _fetchFromManifestUrl(
          _githubManifestUrl,
          currentVersion: effectiveCurrent,
        )
      else
        Future.value(null),
    ]);

    final fromFirestore = results[0];
    final fromGithub = results[1];
    final chosen = _pickBestRelease(fromFirestore, fromGithub);
    if (chosen != null) {
      await _saveCachedRelease(chosen);
      return chosen;
    }

    // 3. Caché local si no hubo respuesta de red
    final cached = await _loadCachedRelease(currentVersion: effectiveCurrent);
    if (cached != null) return cached;

    return InutilTvReleaseInfo(
      currentVersion: effectiveCurrent,
      latestVersion: effectiveCurrent,
      releaseNotes: const [],
      mandatory: false,
      publishedAt: DateTime.now().toUtc(),
    );
  }

  Future<InutilTvReleaseInfo?> _fetchFirestoreRelease({
    required String currentVersion,
  }) async {
    try {
      final res = await InutilFirestoreService.instance.sendWithRelayFallback(
        label: 'GET app_config/tv_release',
        urlBuilder: () =>
            Uri.parse('$_releaseDocumentUrl?${FirebaseConfig.keyParam}'),
        send: (url) => http
            .get(url, headers: _headers())
            .timeout(const Duration(seconds: 8)),
      );
      if (res.statusCode == 200) {
        final decoded =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        return _decodeFirestoreRelease(
          decoded,
          currentVersion: currentVersion,
        );
      }
    } catch (e) {
      debugPrint('[InutilUpdateService] Firestore check error: $e');
    }
    return null;
  }

  InutilTvReleaseInfo? _pickBestRelease(
    InutilTvReleaseInfo? firestore,
    InutilTvReleaseInfo? github,
  ) {
    if (firestore == null) return github;
    if (github == null) return firestore;

    final cmp = InutilTvReleaseInfo.compareSemver(
      firestore.latestVersion,
      github.latestVersion,
    );
    if (cmp > 0) return firestore;
    if (cmp < 0) return github;
    // Misma versión: priorizar el que tenga Kill Switch / mandatory o enlaces ABI
    if (firestore.isBlockingUpdate && !github.isBlockingUpdate) {
      return firestore;
    }
    if (github.isBlockingUpdate && !firestore.isBlockingUpdate) {
      return github;
    }
    if (firestore.publishedAt.isAfter(github.publishedAt) &&
        firestore.apkDownloadUrl.isNotEmpty) {
      return firestore;
    }
    return github.androidDownloads.isNotEmpty ? github : firestore;
  }

  Future<InutilTvReleaseInfo?> _fetchFromManifestUrl(
    String url, {
    required String currentVersion,
  }) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['fields'] is Map<String, dynamic>) {
        return _decodeFirestoreRelease(decoded, currentVersion: currentVersion);
      }
      return InutilTvReleaseInfo.fromJson(
        decoded,
        currentVersionOverride: currentVersion,
      );
    } catch (_) {
      return null;
    }
  }

  /// Publica (o actualiza) el manifiesto OTA / Forzar OTA en Firestore
  /// (`app_config/tv_release`). Solo permitido por `firestore.rules` para Admins.
  Future<bool> publishRelease({
    required String version,
    required List<String> notes,
    String apkUrl = '',
    String armv7ApkUrl = '',
    bool mandatory = false,
    String minSupportedVersion = '',
  }) async {
    final cleanVersion =
        version.trim().isEmpty ? AppInfo.appVersion : version.trim();
    final cleanMin = minSupportedVersion.trim();
    final cleanNotes = notes
        .map((n) => n.trim())
        .where((n) => n.isNotEmpty)
        .toList(growable: false);
    final publishedAt = DateTime.now().toUtc();

    final downloadsMap = <String, String>{};
    if (apkUrl.trim().isNotEmpty) {
      downloadsMap['arm64_v8a'] = apkUrl.trim();
      downloadsMap['universal'] = apkUrl.trim();
    }
    if (armv7ApkUrl.trim().isNotEmpty) {
      downloadsMap['armeabi_v7a'] = armv7ApkUrl.trim();
    }

    final releaseInfo = InutilTvReleaseInfo(
      currentVersion: AppInfo.appVersion,
      latestVersion: cleanVersion,
      releaseNotes: cleanNotes.isEmpty ? AppInfo.whatsNewHighlights : cleanNotes,
      apkDownloadUrl: apkUrl.trim(),
      mandatory: mandatory,
      minSupportedVersion: cleanMin,
      publishedAt: publishedAt,
      androidDownloads: downloadsMap,
    );

    final firestoreFields = <String, dynamic>{
      'latestVersion': {'stringValue': releaseInfo.latestVersion},
      'apkDownloadUrl': {'stringValue': releaseInfo.apkDownloadUrl},
      'mandatory': {'booleanValue': releaseInfo.mandatory},
      'minSupportedVersion': {'stringValue': cleanMin},
      'publishedAt': {'timestampValue': publishedAt.toIso8601String()},
      'releaseNotes': {
        'arrayValue': {
          'values': [
            for (final n in releaseInfo.releaseNotes) {'stringValue': n},
          ],
        },
      },
      'androidDownloads': {
        'mapValue': {
          'fields': {
            for (final e in downloadsMap.entries)
              e.key: {'stringValue': e.value},
          },
        },
      },
    };

    try {
      final body = jsonEncode({'fields': firestoreFields});
      final res = await InutilFirestoreService.instance.sendWithRelayFallback(
        label: 'PATCH app_config/tv_release',
        urlBuilder: () =>
            Uri.parse('$_releaseDocumentUrl?${FirebaseConfig.keyParam}'),
        send: (url) => http
            .patch(url, headers: _headers(), body: body)
            .timeout(const Duration(seconds: 10)),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        await _saveCachedRelease(releaseInfo);
        return true;
      }
      debugPrint(
        '[InutilUpdateService] publishRelease HTTP ${res.statusCode}: ${res.body}',
      );
      return false;
    } catch (e) {
      debugPrint('[InutilUpdateService] publishRelease error: $e');
      return false;
    }
  }

  /// Descarga el APK correspondiente a la ABI del equipo (con reanudación)
  /// y lanza el instalador de paquetes de Android vía FileProvider.
  Future<String> downloadAndInstall(
    InutilTvReleaseInfo release, {
    required void Function(OtaDownloadProgress progress) onProgress,
  }) async {
    final abi = await primaryAbi();
    final url = release.apkUrlForAbi(abi);
    if (url.isEmpty) {
      throw const OtaDownloadException(
        'No hay enlace de descarga APK configurado para esta versión.',
      );
    }

    final safeVer = release.latestVersion.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final fileName = 'inutil_tv_v$safeVer.apk';

    final localPath = await downloadManager.download(
      url: url,
      fileName: fileName,
      onProgress: onProgress,
    );

    if (Platform.isAndroid) {
      final installed = await installApk(localPath);
      if (!installed) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } else {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }

    return localPath;
  }

  InutilTvReleaseInfo _decodeFirestoreRelease(
    Map<String, dynamic> doc, {
    required String currentVersion,
  }) {
    final fields = doc['fields'] as Map<String, dynamic>? ?? const {};
    String str(String key) =>
        (fields[key] as Map<String, dynamic>?)?['stringValue']?.toString().trim() ??
        '';
    bool boolVal(String key) =>
        (fields[key] as Map<String, dynamic>?)?['booleanValue'] as bool? ?? false;

    final notes = <String>[];
    final rawArr =
        ((fields['releaseNotes'] as Map<String, dynamic>?)?['arrayValue']
            as Map<String, dynamic>?)?['values'];
    if (rawArr is List) {
      for (final item in rawArr) {
        if (item is Map && item['stringValue'] != null) {
          final txt = item['stringValue'].toString().trim();
          if (txt.isNotEmpty) notes.add(txt);
        }
      }
    }

    final downloads = <String, String>{};
    final rawMap =
        ((fields['androidDownloads'] as Map<String, dynamic>?)?['mapValue']
            as Map<String, dynamic>?)?['fields'];
    if (rawMap is Map) {
      for (final e in rawMap.entries) {
        final k = InutilTvReleaseInfo.normalizeAbiKey(e.key.toString());
        final v = e.value is Map
            ? (e.value['stringValue']?.toString().trim() ?? '')
            : '';
        if (k.isNotEmpty && v.isNotEmpty) downloads[k] = v;
      }
    }

    final ts =
        (fields['publishedAt'] as Map<String, dynamic>?)?['timestampValue']
                ?.toString() ??
            '';

    return InutilTvReleaseInfo(
      currentVersion: currentVersion,
      latestVersion:
          str('latestVersion').isNotEmpty ? str('latestVersion') : currentVersion,
      releaseNotes: notes,
      apkDownloadUrl: str('apkDownloadUrl'),
      mandatory: boolVal('mandatory'),
      minSupportedVersion: str('minSupportedVersion'),
      publishedAt: DateTime.tryParse(ts) ?? DateTime.now().toUtc(),
      androidDownloads: Map<String, String>.unmodifiable(downloads),
    );
  }

  Future<String> manifestUrlSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getString(_manifestUrlPrefKey) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> setManifestUrlSetting(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final clean = url.trim();
      if (clean.isEmpty) {
        await prefs.remove(_manifestUrlPrefKey);
      } else {
        await prefs.setString(_manifestUrlPrefKey, clean);
      }
    } catch (_) {}
  }

  Future<void> _saveCachedRelease(InutilTvReleaseInfo info) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsCacheKey, jsonEncode(info.toJson()));
    } catch (_) {}
  }

  Future<InutilTvReleaseInfo?> _loadCachedRelease({
    required String currentVersion,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsCacheKey);
      if (raw == null || raw.isEmpty) return null;
      return InutilTvReleaseInfo.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
        currentVersionOverride: currentVersion,
      );
    } catch (_) {
      return null;
    }
  }
}
