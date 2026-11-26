import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'firebase_auth_service.dart';
import 'network_config_service.dart';
import 'stream_validator.dart';

/// Resultado de una sonda real a través del túnel VPN cifrado.
class TunnelProbeResult {
  const TunnelProbeResult({
    required this.ok,
    required this.millis,
    this.detail = '',
  });

  final bool ok;
  final int millis;
  final String detail;
}

/// Túnel VPN integrado de Inutix TV (v3.3.51).
///
/// Funciona exactamente como una VPN dedicada a la app, sin requerir apps
/// externas, sin permisos `VpnService` del sistema y compatible con teléfonos
/// Android, Android TV y escritorio:
///
/// 1. Levanta un proxy HTTP/HTTPS `CONNECT` local en `127.0.0.1:<puerto>`.
/// 2. Todo el tráfico externo de la app (catálogos, imágenes, `HlsStreamProxy`
///    y `libmpv`) entra a ese proxy local.
/// 3. Cada conexión TCP saliente se empaqueta dentro de un WebSocket cifrado
///    `wss://api.inutix.com/v1/tun` autenticado con el `idToken` de la cuenta.
/// 4. El destino (`host:puerto`) viaja dentro del primer frame binario cifrado
///    (nunca en URL ni cabeceras HTTP), y el servidor propio (`s7-edge`) abre
///    el socket TCP real hacia Internet desde IP residencial.
///
/// Para el firewall de oficina/escuela/hotel, todo el tráfico es una sola
/// conexión TLS 1.3 a `api.inutix.com:443`: cero fugas DNS, cero SNI
/// bloqueables y cero inspección MITM sobre los proveedores ni el video.
class InutilVpnTunnel extends ChangeNotifier {
  InutilVpnTunnel._();
  static final InutilVpnTunnel instance = InutilVpnTunnel._();

  static const String defaultTunnelEndpoint = 'wss://api.inutix.com/v1/tun';
  static const Duration _handshakeTimeout = Duration(seconds: 12);
  static const Duration _pingInterval = Duration(seconds: 25);
  static const int _maxHeaderBytes = 16384;

  ServerSocket? _server;
  int _port = 0;
  Future<bool>? _starting;
  Future<bool>? _refreshingToken;

  int _activeStreams = 0;
  int _totalStreams = 0;
  int _bytesUp = 0;
  int _bytesDown = 0;
  String? _lastError;
  DateTime? _lastSuccessAt;

  String? _endpointOverrideForTest;
  Future<String?> Function({bool forceRefresh})? _tokenProviderForTest;

  // ------------------------------------------------------------------ estado

  bool get isRunning => _server != null && _port > 0;
  int get localPort => _port;
  String get localProxyHostPort => isRunning ? '127.0.0.1:$_port' : '';
  String get endpoint => _endpointOverrideForTest ?? defaultTunnelEndpoint;

  int get activeStreams => _activeStreams;
  int get totalStreams => _totalStreams;
  int get bytesUp => _bytesUp;
  int get bytesDown => _bytesDown;
  String? get lastError => _lastError;
  DateTime? get lastSuccessAt => _lastSuccessAt;

  @visibleForTesting
  void configureForTest({
    String? endpoint,
    Future<String?> Function({bool forceRefresh})? tokenProvider,
  }) {
    _endpointOverrideForTest = endpoint;
    _tokenProviderForTest = tokenProvider;
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    await stop();
    _endpointOverrideForTest = null;
    _tokenProviderForTest = null;
    _activeStreams = 0;
    _totalStreams = 0;
    _bytesUp = 0;
    _bytesDown = 0;
    _lastError = null;
    _lastSuccessAt = null;
  }

  // ----------------------------------------------------------- ciclo de vida

  /// Arranca el proxy local `127.0.0.1:<puerto>`. Idempotente.
  Future<bool> ensureStarted() async {
    if (isRunning) return true;
    if (_starting != null) return _starting!;
    _starting = _startInternal();
    try {
      return await _starting!;
    } finally {
      _starting = null;
    }
  }

  Future<bool> _startInternal() async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _port = server.port;
      _lastError = null;
      server.listen(
        (socket) => unawaited(_handleClient(socket)),
        onError: (Object e) {
          debugPrint('[InutilVpnTunnel] Server error: $e');
        },
      );
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = 'No se pudo abrir el túnel local: $e';
      debugPrint('[InutilVpnTunnel] $_lastError');
      notifyListeners();
      return false;
    }
  }

  /// Detiene el proxy local del túnel VPN.
  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = 0;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Sondeo real a través de `wss://api.inutix.com/v1/tun` abriendo un stream
  /// TCP hacia [probeHost]:[probePort] y verificando el ACK `0x00` del nodo.
  Future<TunnelProbeResult> probeTunnel({
    String probeHost = 'jkanime.net',
    int probePort = 443,
  }) async {
    final sw = Stopwatch()..start();
    WebSocket? ws;
    try {
      final res = await _openUpstream(probeHost, probePort);
      ws = res.ws;
      await ws.close();
      _lastError = null;
      _lastSuccessAt = DateTime.now();
      notifyListeners();
      return TunnelProbeResult(ok: true, millis: sw.elapsedMilliseconds);
    } catch (e) {
      final msg = _humanError(e);
      _lastError = msg;
      notifyListeners();
      return TunnelProbeResult(
        ok: false,
        millis: sw.elapsedMilliseconds,
        detail: msg,
      );
    } finally {
      try {
        await ws?.close();
      } catch (_) {}
    }
  }

  // ----------------------------------------------------------- proxy local

  Future<void> _handleClient(Socket client) async {
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    final headerBuf = BytesBuilder(copy: false);
    final headerDone = Completer<_ParsedProxyRequest?>();
    StreamSubscription<Uint8List>? sub;

    // Cola para bytes que lleguen antes de terminar la apertura WSS.
    final pendingUp = <Uint8List>[];
    var piping = false;
    WebSocket? ws;
    var closed = false;

    void closeBoth() {
      if (closed) return;
      closed = true;
      try {
        sub?.cancel();
      } catch (_) {}
      try {
        client.destroy();
      } catch (_) {}
      try {
        ws?.close();
      } catch (_) {}
    }

    sub = client.listen(
      (Uint8List chunk) {
        if (!headerDone.isCompleted) {
          headerBuf.add(chunk);
          final bytes = headerBuf.toBytes();
          final endIdx = _findHeaderEnd(bytes);
          if (endIdx != -1) {
            final headBytes = Uint8List.sublistView(bytes, 0, endIdx);
            final extra = endIdx + 4 < bytes.length
                ? Uint8List.sublistView(bytes, endIdx + 4)
                : Uint8List(0);
            headerDone.complete(_parseProxyRequest(headBytes, extra));
            // Pausamos brevemente mientras abre el WSS para no acumular RAM.
            sub?.pause();
          } else if (bytes.length > _maxHeaderBytes) {
            headerDone.complete(null);
            closeBoth();
          }
          return;
        }
        if (piping && ws != null && ws.readyState == WebSocket.open) {
          try {
            ws.add(chunk);
            _bytesUp += chunk.length;
          } catch (_) {
            closeBoth();
          }
        } else {
          pendingUp.add(chunk);
        }
      },
      onError: (_) {
        if (!headerDone.isCompleted) headerDone.complete(null);
        closeBoth();
      },
      onDone: () {
        if (!headerDone.isCompleted) headerDone.complete(null);
        closeBoth();
      },
      cancelOnError: true,
    );

    final parsed = await headerDone.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
    if (parsed == null || closed) {
      if (!closed) {
        _tryWrite(client, 'HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
      }
      closeBoth();
      return;
    }

    _activeStreams++;
    _totalStreams++;
    StreamSubscription<dynamic>? wsSub;
    try {
      final opened = await _openUpstream(parsed.host, parsed.port);
      if (closed) {
        await opened.ws.close();
        return;
      }
      ws = opened.ws;
      _lastError = null;
      _lastSuccessAt = DateTime.now();

      if (parsed.isConnect) {
        client.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        if (parsed.initialPayload.isNotEmpty) {
          ws.add(parsed.initialPayload);
          _bytesUp += parsed.initialPayload.length;
        }
      } else {
        ws.add(parsed.initialPayload);
        _bytesUp += parsed.initialPayload.length;
      }

      // Entregar cualquier dato que hubiera llegado junto con el ACK del servidor.
      for (final pre in opened.earlyDown) {
        if (pre.isNotEmpty) {
          client.add(pre);
          _bytesDown += pre.length;
        }
      }

      final wsDone = Completer<void>();
      wsSub = opened.stream.listen(
        (dynamic msg) {
          if (closed) return;
          if (msg is List<int> && msg.isNotEmpty) {
            try {
              client.add(msg);
              _bytesDown += msg.length;
            } catch (_) {
              closeBoth();
            }
          }
        },
        onError: (_) {
          if (!wsDone.isCompleted) wsDone.complete();
          closeBoth();
        },
        onDone: () {
          if (!wsDone.isCompleted) wsDone.complete();
          try {
            client.flush().whenComplete(() => closeBoth());
          } catch (_) {
            closeBoth();
          }
        },
        cancelOnError: true,
      );

      // Vaciar pendientes y reanudar lectura del cliente local.
      for (final p in pendingUp) {
        if (p.isNotEmpty && !closed && ws.readyState == WebSocket.open) {
          ws.add(p);
          _bytesUp += p.length;
        }
      }
      pendingUp.clear();
      piping = true;
      sub.resume();

      await wsDone.future;
    } catch (e) {
      _lastError = _humanError(e);
      if (!closed) {
        _tryWrite(
          client,
          'HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n',
        );
      }
      closeBoth();
    } finally {
      _activeStreams = _activeStreams > 0 ? _activeStreams - 1 : 0;
      try {
        await wsSub?.cancel();
      } catch (_) {}
      closeBoth();
    }
  }

  // ------------------------------------------------------- conexión WSS real

  Future<({WebSocket ws, Stream<dynamic> stream, List<Uint8List> earlyDown})>
      _openUpstream(String host, int port) async {
    var token = await _resolveToken(forceRefresh: false);
    WebSocket ws;
    try {
      ws = await _connectWebSocket(token);
    } on WebSocketException {
      // Dart lanza `WebSocketException("Connection ... was not upgraded to
      // websocket")` sin el código 401 en el mensaje: si falló el upgrade,
      // refrescamos el JWT una sola vez y reintentamos antes de rendirnos.
      final fresh = await _resolveToken(forceRefresh: true);
      if (fresh != null && fresh.isNotEmpty && fresh != token) {
        ws = await _connectWebSocket(fresh);
      } else {
        rethrow;
      }
    }

    ws.pingInterval = _pingInterval;

    // Frame 1 binario: `[0x01][port:u16][host_len:u8][host_utf8]`
    final hostBytes = utf8.encode(host);
    if (hostBytes.isEmpty || hostBytes.length > 255) {
      await ws.close();
      throw const FormatException('Host demasiado largo para el túnel');
    }
    final openFrame = Uint8List(4 + hostBytes.length);
    openFrame[0] = 0x01;
    openFrame[1] = (port >> 8) & 0xFF;
    openFrame[2] = port & 0xFF;
    openFrame[3] = hostBytes.length;
    openFrame.setRange(4, openFrame.length, hostBytes);
    ws.add(openFrame);

    // Leer ACK del servidor (`0x00` = conectado, `0x01<err>` = rechazado)
    // preservando cualquier frame siguiente en un broadcast/controller limpio.
    final ackCompleter = Completer<Uint8List>();
    final outCtrl = StreamController<dynamic>();
    final earlyDown = <Uint8List>[];

    ws.listen(
      (dynamic msg) {
        if (!ackCompleter.isCompleted) {
          if (msg is List<int>) {
            ackCompleter.complete(Uint8List.fromList(msg));
          } else {
            ackCompleter.complete(Uint8List(0));
          }
          return;
        }
        if (!outCtrl.hasListener) {
          if (msg is List<int> && msg.isNotEmpty) {
            earlyDown.add(Uint8List.fromList(msg));
          }
        } else if (!outCtrl.isClosed) {
          outCtrl.add(msg);
        }
      },
      onError: (Object e, StackTrace st) {
        if (!ackCompleter.isCompleted) {
          ackCompleter.completeError(e, st);
        } else if (!outCtrl.isClosed) {
          outCtrl.addError(e, st);
        }
      },
      onDone: () {
        if (!ackCompleter.isCompleted) {
          ackCompleter.completeError(const SocketException('Túnel cerrado antes de ACK'));
        }
        if (!outCtrl.isClosed) {
          outCtrl.close();
        }
      },
      cancelOnError: false,
    );

    final ack = await ackCompleter.future.timeout(
      _handshakeTimeout,
      onTimeout: () {
        ws.close();
        throw TimeoutException('El servidor VPN no respondió a tiempo');
      },
    );
    if (ack.isEmpty || ack[0] != 0x00) {
      await ws.close();
      final reason = ack.length > 1
          ? utf8.decode(ack.sublist(1), allowMalformed: true)
          : 'rechazado';
      throw SocketException('Túnel rechazó $host:$port ($reason)');
    }
    return (ws: ws, stream: outCtrl.stream, earlyDown: earlyDown);
  }

  Future<WebSocket> _connectWebSocket(String? token) async {
    final headers = <String, dynamic>{
      'User-Agent': StreamValidator.defaultUserAgent,
    };
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final client = _createOuterHttpClient();
    try {
      return await WebSocket.connect(
        endpoint,
        headers: headers,
        customClient: client,
      ).timeout(_handshakeTimeout);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  /// `HttpClient` exclusivo para la conexión externa `wss://api.inutix.com/v1/tun`:
  /// usa el cliente nativo de `dart:io` (sin el `connectionFactory` global, que
  /// interfiere con el upgrade `WebSocket`/`detachSocket`) y nunca pasa por el
  /// propio túnel local (cero recursión), pero sí respeta el proxy externo de
  /// empresa (manual o Wi-Fi) y la tolerancia TLS si la red inspecciona.
  HttpClient _createOuterHttpClient() {
    final client = HttpOverrides.runWithHttpOverrides(
      () => HttpClient(),
      _NativeOuterHttpOverrides(),
    )..connectionTimeout = _handshakeTimeout;
    final net = NetworkConfigService.instance;
    final extProxy = net.externalProxyHostPort;
    client.findProxy = (uri) {
      if (extProxy.isNotEmpty) return 'PROXY $extProxy';
      return 'DIRECT';
    };
    client.badCertificateCallback = (cert, host, port) {
      return net.tlsFallbackEnabled;
    };
    return client;
  }

  Future<String?> _resolveToken({required bool forceRefresh}) async {
    final testProvider = _tokenProviderForTest;
    if (testProvider != null) {
      return testProvider(forceRefresh: forceRefresh);
    }
    final auth = InutilAuthService.instance;
    final current = auth.currentUser?.idToken ?? '';
    if (!forceRefresh && current.isNotEmpty && !_isJwtExpired(current)) {
      return current;
    }
    // Deduplicar refrescos concurrentes si varias peticiones abren al tiempo.
    _refreshingToken ??= auth.ensureFreshIdToken(force: forceRefresh).whenComplete(
      () => _refreshingToken = null,
    );
    await _refreshingToken;
    return auth.currentUser?.idToken;
  }

  static bool _isJwtExpired(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return true;
      final normalized = base64Url.normalize(parts[1]);
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(normalized))) as Map<String, dynamic>;
      final exp = (payload['exp'] as num?)?.toInt() ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return exp <= now + 45;
    } catch (_) {
      return true;
    }
  }

  // ------------------------------------------------------- parsing HTTP proxy

  static int _findHeaderEnd(Uint8List bytes) {
    for (var i = 0; i <= bytes.length - 4; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static _ParsedProxyRequest? _parseProxyRequest(
    Uint8List headBytes,
    Uint8List extraBody,
  ) {
    final text = latin1.decode(headBytes);
    final lines = text.split('\r\n');
    if (lines.isEmpty) return null;
    final first = lines.first.trim().split(' ');
    if (first.length < 2) return null;

    final method = first[0].toUpperCase();
    final rawTarget = first[1].trim();
    final version = first.length >= 3 ? first[2] : 'HTTP/1.1';

    if (method == 'CONNECT') {
      final hp = _splitHostPort(rawTarget, defaultPort: 443);
      if (hp == null) return null;
      return _ParsedProxyRequest(
        isConnect: true,
        host: hp.host,
        port: hp.port,
        initialPayload: extraBody,
      );
    }

    // Petición HTTP plana (`GET http://host:port/path HTTP/1.1` — p. ej. IPTV)
    final uri = Uri.tryParse(rawTarget);
    if (uri == null || uri.host.isEmpty) return null;
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final originPath =
        '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';

    final out = StringBuffer('$method $originPath $version\r\n');
    var hasHost = false;
    var hasConnection = false;
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();
      if (lower.startsWith('proxy-connection:') ||
          lower.startsWith('proxy-authorization:')) {
        continue;
      }
      if (lower.startsWith('host:')) hasHost = true;
      if (lower.startsWith('connection:')) {
        hasConnection = true;
        out.write('Connection: close\r\n');
        continue;
      }
      out.write('$line\r\n');
    }
    if (!hasHost) {
      out.write('Host: $host${port == 80 ? '' : ':$port'}\r\n');
    }
    if (!hasConnection) {
      out.write('Connection: close\r\n');
    }
    out.write('\r\n');

    final headerOut = latin1.encode(out.toString());
    if (extraBody.isEmpty) {
      return _ParsedProxyRequest(
        isConnect: false,
        host: host,
        port: port,
        initialPayload: Uint8List.fromList(headerOut),
      );
    }
    final combined = Uint8List(headerOut.length + extraBody.length);
    combined.setRange(0, headerOut.length, headerOut);
    combined.setRange(headerOut.length, combined.length, extraBody);
    return _ParsedProxyRequest(
      isConnect: false,
      host: host,
      port: port,
      initialPayload: combined,
    );
  }

  static ({String host, int port})? _splitHostPort(
    String target, {
    required int defaultPort,
  }) {
    if (target.startsWith('[')) {
      final close = target.indexOf(']');
      if (close <= 1) return null;
      final host = target.substring(1, close);
      var port = defaultPort;
      if (close + 1 < target.length && target[close + 1] == ':') {
        final p = int.tryParse(target.substring(close + 2));
        if (p == null || p < 1 || p > 65535) return null;
        port = p;
      }
      return (host: host, port: port);
    }
    final cut = target.lastIndexOf(':');
    if (cut == -1) return (host: target, port: defaultPort);
    final host = target.substring(0, cut).trim();
    final port = int.tryParse(target.substring(cut + 1).trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    return (host: host, port: port);
  }

  static void _tryWrite(Socket socket, String text) {
    try {
      socket.add(ascii.encode(text));
    } catch (_) {}
  }

  static String _humanError(Object e) {
    final s = e.toString();
    if (s.contains('401')) return 'Sesión vencida para el túnel';
    if (s.contains('503')) return 'Servidor VPN ocupado';
    if (e is TimeoutException) return 'El servidor VPN tardó demasiado';
    return 'Sin respuesta del servidor VPN';
  }
}

class _NativeOuterHttpOverrides extends HttpOverrides {
  _NativeOuterHttpOverrides();
}

class _ParsedProxyRequest {
  const _ParsedProxyRequest({
    required this.isConnect,
    required this.host,
    required this.port,
    required this.initialPayload,
  });

  final bool isConnect;
  final String host;
  final int port;
  final Uint8List initialPayload;
}
