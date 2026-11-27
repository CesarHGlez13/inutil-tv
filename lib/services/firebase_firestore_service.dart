import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'firebase_auth_service.dart';
import 'firebase_config.dart';

/// Fallo al leer un documento de Firestore distinto de «no existe» (404).
class FirestoreOperationException implements Exception {
  const FirestoreOperationException(this.path, this.statusCode, this.body);

  final String path;
  final int statusCode;
  final String body;

  @override
  String toString() =>
      'FirestoreOperationException($statusCode en $path): '
      '${InutilFirestoreService.briefErrorBody(body)}';
}

/// Servicio de Cloud Firestore multiplataforma mediante REST API oficial v1.
/// Comparte la colección `users/{uid}` con Inútil Music en `inutil-music-app`.
class InutilFirestoreService {
  InutilFirestoreService._();
  static final InutilFirestoreService instance = InutilFirestoreService._();

  String? get _idToken => InutilAuthService.instance.currentUser?.idToken;

  /// Cliente propio, sólo para `postDailyMetrics`. Los demás métodos siguen con
  /// las funciones top-level de `package:http` para no cambiar su comportamiento.
  http.Client? _httpClient;
  http.Client get _client => _httpClient ??= http.Client();

  /// Permite inyectar un cliente HTTP en pruebas (mismo patrón que
  /// `TitleLogoService.testClient`), sin tocar la red real.
  @visibleForTesting
  set testClient(http.Client? client) => _httpClient = client;

  /// Reduce el cuerpo de un error de Google a una sola línea legible.
  static String briefErrorBody(String body) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return 'sin respuesta';
    return flat.length <= 180 ? flat : '${flat.substring(0, 180)}…';
  }

  Map<String, String> _headers({String? overrideToken}) {
    final token = overrideToken ?? _idToken;
    return {
      'Content-Type': 'application/json',
      if (!FirebaseConfig.useEmulator) 'X-Goog-Api-Key': FirebaseConfig.apiKey,
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// ¿El error es de conexión (el destino nunca respondió) o es una respuesta
  /// HTTP con código? Sólo los de conexión activan el reintento contra Google:
  /// un 403/429/500 sí llegó a un servidor y reintentarlo contra otro sería
  /// ciego (y en el caso del 429 de cuota, contraproducente).
  @visibleForTesting
  static bool isConnectionFailure(Object error) {
    if (error is TimeoutException) return true;
    if (error is SocketException) return true;
    if (error is http.ClientException) return true;
    final text = error.toString().toLowerCase();
    return text.contains('connection refused') ||
        text.contains('connection reset') ||
        text.contains('failed host lookup') ||
        text.contains('network is unreachable') ||
        text.contains('broken pipe') ||
        text.contains('network unreachable');
  }

  /// Códigos HTTP de túnel/proxy caído (Cloudflare Tunnel / Nginx / gateway)
  /// que deben activar el failover inmediato hacia `backup.inutix.com`.
  @visibleForTesting
  static bool isTunnelUnavailableStatus(int statusCode) =>
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 521 ||
      statusCode == 522 ||
      statusCode == 524 ||
      statusCode == 530;

  /// Manda una petición de datos con failover automático en cadena:
  /// `LAN S7 (192.168.100.27) → api.inutix.com → backup.inutix.com`.
  ///
  /// - Si el relay LAN muere por fallo de conexión, llama a
  ///   `markRelayUnreachable()` y reintenta contra `api.inutix.com`.
  /// - Si `api.inutix.com` muere por fallo de conexión o responde
  ///   `502/503/521/522/524/530`, llama a `markCloudRelayUnreachable()` y
  ///   reintenta automáticamente contra `backup.inutix.com`.
  Future<http.Response> sendWithRelayFallback({
    required String label,
    required Uri Function() urlBuilder,
    required Future<http.Response> Function(Uri url) send,
  }) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final lanWasUsable = FirebaseConfig.relayUsable;
      final cloudWasUsable = !lanWasUsable && FirebaseConfig.cloudRelayUsable;
      try {
        final resp = await send(urlBuilder());
        if (cloudWasUsable &&
            FirebaseConfig.backupRelayUsable &&
            isTunnelUnavailableStatus(resp.statusCode)) {
          FirebaseConfig.markCloudRelayUnreachable();
          debugPrint(
            'Nodo principal inutix.com respondió HTTP ${resp.statusCode} en '
            '$label: conmutando a respaldo ${FirebaseConfig.backupRelayHost}.',
          );
          continue;
        }
        return resp;
      } catch (error) {
        if (!isConnectionFailure(error)) rethrow;
        if (lanWasUsable) {
          FirebaseConfig.markRelayUnreachable();
          debugPrint(
            'Relay LAN del S7 sin respuesta en $label: '
            'reintentando en siguiente capa (${FirebaseConfig.firestoreBaseUrl}).',
          );
          continue;
        }
        if (cloudWasUsable && FirebaseConfig.backupRelayUsable) {
          FirebaseConfig.markCloudRelayUnreachable();
          debugPrint(
            'Nodo principal inutix.com sin respuesta en $label: '
            'conmutando a respaldo ${FirebaseConfig.backupRelayHost}.',
          );
          continue;
        }
        rethrow;
      }
    }
    return await send(urlBuilder());
  }

  Future<http.Response> _sendWithRelayFallback({
    required String label,
    required Uri Function() urlBuilder,
    required Future<http.Response> Function(Uri url) send,
  }) =>
      sendWithRelayFallback(
        label: label,
        urlBuilder: urlBuilder,
        send: send,
      );

  /// Misma ayuda, expuesta para pruebas.
  @visibleForTesting
  Future<http.Response> sendWithRelayFallbackForTest({
    required String label,
    required Uri Function() urlBuilder,
    required Future<http.Response> Function(Uri url) send,
  }) =>
      _sendWithRelayFallback(
        label: label,
        urlBuilder: urlBuilder,
        send: send,
      );

  // ---------------------------------------------------------------------------
  // 1. SERIALIZACIÓN FIRESTORE REST (Dart Map <-> Firestore Value Formats)
  // ---------------------------------------------------------------------------
  Map<String, dynamic> _encodeFields(Map<String, dynamic> data) {
    final fields = <String, dynamic>{};
    for (final entry in data.entries) {
      fields[entry.key] = _encodeValue(entry.value);
    }
    return {'fields': fields};
  }

  Map<String, dynamic> _encodeValue(dynamic value) {
    if (value == null) {
      return {'nullValue': null};
    } else if (value is bool) {
      return {'booleanValue': value};
    } else if (value is int) {
      return {'integerValue': value.toString()};
    } else if (value is double) {
      return {'doubleValue': value};
    } else if (value is String) {
      return {'stringValue': value};
    } else if (value is DateTime) {
      return {'timestampValue': value.toUtc().toIso8601String()};
    } else if (value is List) {
      return {
        'arrayValue': {
          'values': value.map(_encodeValue).toList(),
        },
      };
    } else if (value is Map<String, dynamic>) {
      final mapFields = <String, dynamic>{};
      for (final e in value.entries) {
        mapFields[e.key] = _encodeValue(e.value);
      }
      return {
        'mapValue': {'fields': mapFields},
      };
    }
    return {'stringValue': value.toString()};
  }

  Map<String, dynamic> _decodeDocument(Map<String, dynamic> doc) {
    final fields = doc['fields'] as Map<String, dynamic>?;
    if (fields == null) return {};
    final result = <String, dynamic>{};
    for (final entry in fields.entries) {
      result[entry.key] = _decodeValue(entry.value as Map<String, dynamic>);
    }
    return result;
  }

  dynamic _decodeValue(Map<String, dynamic> val) {
    if (val.containsKey('stringValue')) return val['stringValue'];
    if (val.containsKey('integerValue')) {
      return int.tryParse(val['integerValue'].toString()) ?? 0;
    }
    if (val.containsKey('doubleValue')) {
      return (val['doubleValue'] as num).toDouble();
    }
    if (val.containsKey('booleanValue')) return val['booleanValue'];
    if (val.containsKey('timestampValue')) {
      return DateTime.tryParse(val['timestampValue'].toString());
    }
    if (val.containsKey('nullValue')) return null;
    if (val.containsKey('arrayValue')) {
      final values = val['arrayValue']['values'] as List?;
      if (values == null) return [];
      return values
          .map((e) => _decodeValue(e as Map<String, dynamic>))
          .toList();
    }
    if (val.containsKey('mapValue')) {
      final fields = val['mapValue']['fields'] as Map<String, dynamic>?;
      if (fields == null) return {};
      final res = <String, dynamic>{};
      for (final e in fields.entries) {
        res[e.key] = _decodeValue(e.value as Map<String, dynamic>);
      }
      return res;
    }
    return null;
  }

  /// Construye la URI de PATCH con `updateMask.fieldPaths` para actualizaciones
  /// parciales seguras (sin borrar campos existentes como `email`, `role`, etc.).
  @visibleForTesting
  static Uri buildPatchUri(String path, Iterable<String> fieldPaths, {bool merge = true}) {
    final base = Uri.parse('${FirebaseConfig.firestoreBaseUrl}/$path');
    if (!merge || fieldPaths.isEmpty) return base;
    return base.replace(
      queryParameters: {
        'updateMask.fieldPaths': fieldPaths.toList(growable: false),
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 2. DOCUMENTOS Y COLECCIONES
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>?> getDocument(
    String path, {
    String? overrideToken,
  }) async {
    var response = await _sendWithRelayFallback(
      label: 'GET $path',
      urlBuilder: () => Uri.parse('${FirebaseConfig.firestoreBaseUrl}/$path'),
      send: (url) => (_httpClient != null
              ? _httpClient!.get(
                  url,
                  headers: _headers(overrideToken: overrideToken),
                )
              : http.get(
                  url,
                  headers: _headers(overrideToken: overrideToken),
                ))
          .timeout(const Duration(seconds: 10)),
    );
    if (response.statusCode == 401 && overrideToken == null) {
      final refreshed =
          await InutilAuthService.instance.ensureFreshIdToken(force: true);
      if (refreshed) {
        response = await _sendWithRelayFallback(
          label: 'GET $path (reauth)',
          urlBuilder: () =>
              Uri.parse('${FirebaseConfig.firestoreBaseUrl}/$path'),
          send: (url) => (_httpClient != null
                  ? _httpClient!.get(
                      url,
                      headers: _headers(overrideToken: overrideToken),
                    )
                  : http.get(
                      url,
                      headers: _headers(overrideToken: overrideToken),
                    ))
              .timeout(const Duration(seconds: 10)),
        );
      }
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw FirestoreOperationException(
        path,
        response.statusCode,
        response.body,
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return _decodeDocument(json);
  }

  /// Lee un documento directamente contra Google Firestore sin pasar por
  /// relays/respaldo. Se usa como doble verificación antes de aceptar un 404
  /// de cuenta eliminada.
  Future<Map<String, dynamic>?> getDocumentDirect(
    String path, {
    String? overrideToken,
  }) async {
    final url = Uri.parse('${FirebaseConfig.directFirestoreBaseUrl}/$path');
    final response = await http
        .get(url, headers: _headers(overrideToken: overrideToken))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw FirestoreOperationException(
        path,
        response.statusCode,
        response.body,
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return _decodeDocument(json);
  }

  /// Escribe o actualiza campos en un documento de Firestore.
  /// Cuando [merge] es `true` (por defecto), solo se actualizan las claves de
  /// [data] mediante `updateMask.fieldPaths` para preservar el resto del
  /// documento (compatible con Inútil Music e InútilTV).
  Future<bool> setDocument(
    String path,
    Map<String, dynamic> data, {
    bool merge = true,
    String? overrideToken,
  }) async {
    final body = jsonEncode(_encodeFields(data));
    var response = await _sendWithRelayFallback(
      label: 'PATCH $path',
      urlBuilder: () => buildPatchUri(path, data.keys, merge: merge),
      send: (url) => (_httpClient != null
              ? _httpClient!.patch(
                  url,
                  headers: _headers(overrideToken: overrideToken),
                  body: body,
                )
              : http.patch(
                  url,
                  headers: _headers(overrideToken: overrideToken),
                  body: body,
                ))
          .timeout(const Duration(seconds: 10)),
    );
    if (response.statusCode == 401 && overrideToken == null) {
      final refreshed =
          await InutilAuthService.instance.ensureFreshIdToken(force: true);
      if (refreshed) {
        response = await _sendWithRelayFallback(
          label: 'PATCH $path (reauth)',
          urlBuilder: () => buildPatchUri(path, data.keys, merge: merge),
          send: (url) => (_httpClient != null
                  ? _httpClient!.patch(
                      url,
                      headers: _headers(overrideToken: overrideToken),
                      body: body,
                    )
                  : http.patch(
                      url,
                      headers: _headers(overrideToken: overrideToken),
                      body: body,
                    ))
              .timeout(const Duration(seconds: 10)),
        );
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return true;
    }
    debugPrint(
      '[Firestore] PATCH error ($path, ${response.statusCode}): '
      '${briefErrorBody(response.body)}',
    );
    return false;
  }

  Future<bool> deleteDocument(String path, {String? overrideToken}) async {
    final response = await _sendWithRelayFallback(
      label: 'DELETE $path',
      urlBuilder: () => Uri.parse('${FirebaseConfig.firestoreBaseUrl}/$path'),
      send: (url) => http
          .delete(url, headers: _headers(overrideToken: overrideToken))
          .timeout(const Duration(seconds: 10)),
    );
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  /// Reporte diario de telemetría: `POST {BASE}/metrics/<uid>/daily`.
  ///
  /// A diferencia de las escrituras de Firestore, el cuerpo es JSON PLANO (no el
  /// envoltorio `fields`), porque el endpoint es del relay, no de Google. El
  /// cuerpo es el TOTAL ACUMULADO del día calendario UTC, no un delta, y el relay
  /// hace merge por columna (el último valor del día gana), así que reenviar el
  /// mismo total es idempotente. Mismo token Bearer que toda escritura.
  ///
  /// Devuelve la respuesta cruda para que la capa de arriba decida; no hace el
  /// `ensureFreshIdToken` de los métodos de documento porque el llamante reintenta
  /// en el siguiente cierre de sesión y ahí el token ya estará fresco.
  Future<http.Response> postDailyMetrics({
    required String uid,
    required Map<String, dynamic> body,
    String? overrideToken,
  }) async {
    final path = 'metrics/$uid/daily';
    final encoded = jsonEncode(body);
    return _sendWithRelayFallback(
      label: 'POST $path',
      urlBuilder: () => Uri.parse('${FirebaseConfig.firestoreBaseUrl}/$path'),
      send: (url) => _client
          .post(
            url,
            headers: _headers(overrideToken: overrideToken),
            body: encoded,
          )
          .timeout(const Duration(seconds: 10)),
    );
  }

  // ---------------------------------------------------------------------------
  // 3. GESTIÓN DE PERFILES Y LICENCIAS (`users/{uid}`)
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>?> getUserProfile(
    String uid, {
    String? overrideToken,
  }) async {
    return getDocument('users/$uid', overrideToken: overrideToken);
  }

  Future<Map<String, dynamic>?> getUserProfileDirect(
    String uid, {
    String? overrideToken,
  }) async {
    return getDocumentDirect('users/$uid', overrideToken: overrideToken);
  }

  Future<bool> adminUpdateUser(String uid, Map<String, dynamic> updates) async {
    return setDocument('users/$uid', updates, merge: true);
  }

  Future<List<Map<String, dynamic>>> getAllUsers() async {
    try {
      final result = <Map<String, dynamic>>[];
      String? pageToken;

      do {
        final response = await _sendWithRelayFallback(
          label: 'LIST users',
          urlBuilder: () =>
              Uri.parse('${FirebaseConfig.firestoreBaseUrl}/users').replace(
            queryParameters: {
              'pageSize': '200',
              if (pageToken != null && pageToken.isNotEmpty)
                'pageToken': pageToken,
            },
          ),
          send: (url) => http
              .get(url, headers: _headers())
              .timeout(const Duration(seconds: 8)),
        );
        if (response.statusCode != 200) {
          debugPrint(
            '[Firestore] getAllUsers (${response.statusCode}): '
            '${briefErrorBody(response.body)}',
          );
          break;
        }
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final docs = json['documents'] as List?;
        if (docs != null) {
          for (final doc in docs) {
            if (doc is Map<String, dynamic>) {
              final fields = _decodeDocument(doc);
              final name = doc['name'] as String? ?? '';
              final docUid = name.split('/').last;
              if (!fields.containsKey('uid') ||
                  (fields['uid']?.toString().isEmpty ?? true)) {
                fields['uid'] = docUid;
              }
              result.add(fields);
            }
          }
        }
        pageToken = json['nextPageToken'] as String?;
      } while (pageToken != null && pageToken.isNotEmpty);

      return result;
    } catch (e) {
      debugPrint('[Firestore] getAllUsers offline / fallback: $e');
      return [];
    }
  }
}
