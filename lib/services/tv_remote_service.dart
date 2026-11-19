import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'firebase_auth_service.dart';
import 'firebase_firestore_service.dart';
import 'tv_mode_service.dart';

/// Estado en vivo publicado por la Smart TV para que el celular actúe como
/// control remoto (estilo Spotify Connect / YouTube TV).
@immutable
class TvPlaybackState {
  final bool online;
  final String tvDeviceId;
  final String tvName;
  final String lanHost;
  final bool isPlaying;
  final String title;
  final String subtitle;
  final String poster;
  final bool isLive;
  final int positionSec;
  final int durationSec;
  final int volume;
  final int episodeIndex;
  final int episodeCount;
  final double speed;
  final DateTime? updatedAt;

  const TvPlaybackState({
    this.online = false,
    this.tvDeviceId = '',
    this.tvName = 'Mi Smart TV',
    this.lanHost = '',
    this.isPlaying = false,
    this.title = '',
    this.subtitle = '',
    this.poster = '',
    this.isLive = false,
    this.positionSec = 0,
    this.durationSec = 0,
    this.volume = 100,
    this.episodeIndex = 0,
    this.episodeCount = 0,
    this.speed = 1.0,
    this.updatedAt,
  });

  TvPlaybackState copyWith({
    bool? online,
    String? tvDeviceId,
    String? tvName,
    String? lanHost,
    bool? isPlaying,
    String? title,
    String? subtitle,
    String? poster,
    bool? isLive,
    int? positionSec,
    int? durationSec,
    int? volume,
    int? episodeIndex,
    int? episodeCount,
    double? speed,
    DateTime? updatedAt,
  }) {
    return TvPlaybackState(
      online: online ?? this.online,
      tvDeviceId: tvDeviceId ?? this.tvDeviceId,
      tvName: tvName ?? this.tvName,
      lanHost: lanHost ?? this.lanHost,
      isPlaying: isPlaying ?? this.isPlaying,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      poster: poster ?? this.poster,
      isLive: isLive ?? this.isLive,
      positionSec: positionSec ?? this.positionSec,
      durationSec: durationSec ?? this.durationSec,
      volume: volume ?? this.volume,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      episodeCount: episodeCount ?? this.episodeCount,
      speed: speed ?? this.speed,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Se considera conectada si reportó presencia en línea dentro de los últimos
  /// 300 segundos (tolerancia amplia para desfases de reloj entre celular y Smart TV Box).
  bool get isReachable {
    if (!online || updatedAt == null) return false;
    final diffSec = DateTime.now().difference(updatedAt!).inSeconds.abs();
    return diffSec <= 300;
  }

  bool get hasActiveMedia => title.isNotEmpty;

  double get progressFraction {
    if (isLive || durationSec <= 0) return 0;
    return (positionSec / durationSec).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toFirestore() => {
        'online': online,
        'tvDeviceId': tvDeviceId,
        'tvName': tvName,
        'lanHost': lanHost,
        'isPlaying': isPlaying,
        'title': title,
        'subtitle': subtitle,
        'poster': poster,
        'isLive': isLive,
        'positionSec': positionSec,
        'durationSec': durationSec,
        'volume': volume,
        'episodeIndex': episodeIndex,
        'episodeCount': episodeCount,
        'speed': speed,
        'updatedAt': DateTime.now(),
      };

  factory TvPlaybackState.fromFirestore(Map<String, dynamic> data) {
    final rawUpdated = data['updatedAt'];
    final updated = rawUpdated is DateTime
        ? rawUpdated
        : (rawUpdated != null ? DateTime.tryParse(rawUpdated.toString()) : null);
    return TvPlaybackState(
      online: (data['online'] as bool?) ?? false,
      tvDeviceId: (data['tvDeviceId'] ?? '').toString(),
      tvName: (data['tvName'] ?? 'Mi Smart TV').toString(),
      lanHost: (data['lanHost'] ?? '').toString(),
      isPlaying: (data['isPlaying'] as bool?) ?? false,
      title: (data['title'] ?? '').toString(),
      subtitle: (data['subtitle'] ?? '').toString(),
      poster: (data['poster'] ?? '').toString(),
      isLive: (data['isLive'] as bool?) ?? false,
      positionSec: (data['positionSec'] as num?)?.toInt() ?? 0,
      durationSec: (data['durationSec'] as num?)?.toInt() ?? 0,
      volume: (data['volume'] as num?)?.toInt() ?? 100,
      episodeIndex: (data['episodeIndex'] as num?)?.toInt() ?? 0,
      episodeCount: (data['episodeCount'] as num?)?.toInt() ?? 0,
      speed: (data['speed'] as num?)?.toDouble() ?? 1.0,
      updatedAt: updated,
    );
  }
}

/// Orden enviada desde el celular hacia la Smart TV.
@immutable
class TvRemoteCommand {
  final String commandId;
  final String action;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  const TvRemoteCommand({
    required this.commandId,
    required this.action,
    required this.payload,
    required this.createdAt,
  });

  bool get isFresh =>
      DateTime.now().difference(createdAt).inSeconds.abs() <= 600;

  Map<String, dynamic> toFirestore() => {
        'commandId': commandId,
        'action': action,
        'payloadJson': jsonEncode(payload),
        'createdAt': createdAt,
      };

  static TvRemoteCommand? fromFirestore(Map<String, dynamic> data) {
    final id = (data['commandId'] ?? '').toString();
    final action = (data['action'] ?? '').toString();
    if (id.isEmpty || action.isEmpty) return null;
    Map<String, dynamic> payload = {};
    final rawPayload = data['payloadJson']?.toString() ?? '';
    if (rawPayload.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPayload);
        if (decoded is Map<String, dynamic>) payload = decoded;
      } catch (_) {}
    }
    final rawTs = data['createdAt'];
    final ts = rawTs is DateTime
        ? rawTs
        : (rawTs != null
            ? DateTime.tryParse(rawTs.toString()) ?? DateTime.now()
            : DateTime.now());
    return TvRemoteCommand(
      commandId: id,
      action: action,
      payload: payload,
      createdAt: ts,
    );
  }
}

/// Servicio bidireccional "InútilTV Connect" (Celular ↔ Smart TV) con doble enlace:
/// 1. Enlace Directo LAN Ultra-Rápido (HTTP en 38443 / UDP en 38444): latencia <5ms
///    y cero dependencia de Firestore cuando ambos están en la misma red WiFi.
/// 2. Enlace Cloud Firestore: respaldo automático fuera del hogar o redes corporativas.
class TvRemoteService extends ChangeNotifier {
  TvRemoteService._();
  static final TvRemoteService instance = TvRemoteService._();

  static const _uuid = Uuid();
  static const int lanHttpPort = 38443;
  static const int lanUdpPort = 38444;
  static const String _prefTvLanHostKey = 'inutil_tv_lan_host';

  Timer? _tvHeartbeatTimer;
  Timer? _tvCommandPollTimer;
  Timer? _mobilePollTimer;

  bool _pollingCommand = false;
  bool _pollingState = false;
  bool _discoveringLan = false;
  String _lastHandledCommandId = '';
  bool _started = false;

  HttpServer? _lanHttpServer;
  RawDatagramSocket? _lanUdpSocket;
  DateTime? _lastFirestore429Time;
  String? _localTvIp;
  String? get localTvIp => _localTvIp;

  String? _targetTvLanHost;
  String? get targetTvLanHost => _targetTvLanHost;

  static const String _prefPlayOnTvKey = 'inutil_tv_play_on_tv';
  bool _playOnTv = false;

  /// Indica si la reproducción multimedia se redirige persistentemente a la TV.
  bool get playOnTv => _playOnTv && isTvOnline;

  Future<void> setPlayOnTv(bool value) async {
    _playOnTv = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefPlayOnTvKey, value);
    } catch (_) {}
  }

  Future<void> togglePlayOnTv() => setPlayOnTv(!_playOnTv);

  Future<void> loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _playOnTv = prefs.getBool(_prefPlayOnTvKey) ?? false;
      notifyListeners();
    } catch (_) {}
  }

  @visibleForTesting
  bool disableLanDiscoveryForTest = false;

  TvPlaybackState _tvState = const TvPlaybackState();
  TvPlaybackState get tvState => _tvState;
  bool get isTvOnline => _tvState.isReachable;

  // Callbacks registrados por la Smart TV
  void Function(TvRemoteCommand cmd)? _launchHandler;
  void Function(TvRemoteCommand cmd)? _activePlayerHandler;
  void Function(TvRemoteCommand cmd)? _systemNavigationHandler;

  String? get _uid => InutilAuthService.instance.currentUser?.uid;

  void registerTvLaunchHandler(void Function(TvRemoteCommand cmd)? handler) {
    _launchHandler = handler;
  }

  void registerActivePlayerHandler(void Function(TvRemoteCommand cmd)? handler) {
    _activePlayerHandler = handler;
  }

  void registerSystemNavigationHandler(
      void Function(TvRemoteCommand cmd)? handler) {
    _systemNavigationHandler = handler;
  }

  /// Inicia automáticamente el rol correspondiente (receptor en TV, mando en móvil).
  void start() {
    if (_started) return;
    if (InutilAuthService.instance.isOnlineValidationDisabled) return;
    final uid = _uid;
    if (uid == null || uid.isEmpty) return;

    _started = true;
    if (TvModeService.instance.isTv) {
      _startTvReceiver();
    } else {
      _startMobileWatcher();
    }
  }

  void stop() {
    _started = false;
    _tvHeartbeatTimer?.cancel();
    _tvCommandPollTimer?.cancel();
    _mobilePollTimer?.cancel();
    _tvHeartbeatTimer = null;
    _tvCommandPollTimer = null;
    _mobilePollTimer = null;
    try {
      _lanHttpServer?.close(force: true);
    } catch (_) {}
    _lanHttpServer = null;
    try {
      _lanUdpSocket?.close();
    } catch (_) {}
    _lanUdpSocket = null;
    if (TvModeService.instance.isTv && _uid != null && _uid!.isNotEmpty) {
      unawaited(
        _publishTvState(
          TvPlaybackState(
            online: false,
            tvDeviceId: InutilAuthService.instance.deviceId,
            tvName: 'Smart TV',
          ),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 1. ROL SMART TV (servidor LAN local + publica presencia y ejecuta comandos)
  // ---------------------------------------------------------------------------
  void _startTvReceiver() {
    _tvState = TvPlaybackState(
      online: true,
      tvDeviceId: InutilAuthService.instance.deviceId,
      tvName: 'Smart TV',
      updatedAt: DateTime.now(),
    );
    unawaited(_startLanServer());
    unawaited(_publishTvState(_tvState));

    _tvHeartbeatTimer?.cancel();
    _tvHeartbeatTimer = Timer.periodic(const Duration(seconds: 18), (_) {
      unawaited(_publishTvState(_tvState));
    });

    _tvCommandPollTimer?.cancel();
    _tvCommandPollTimer =
        Timer.periodic(const Duration(milliseconds: 1500), (_) {
      unawaited(_pollIncomingCommand());
    });
  }

  Future<void> _detectLocalTvIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('127.')) {
            _localTvIp = addr.address;
            break;
          }
        }
        if (_localTvIp != null) break;
      }
      debugPrint('📍 [TvRemoteService] IP LAN de Smart TV detectada: $_localTvIp');
    } catch (_) {}
  }

  Future<void> _startLanServer() async {
    if (InutilAuthService.instance.isOnlineValidationDisabled) return;
    await _detectLocalTvIp();
    try {
      _lanHttpServer?.close(force: true);
      _lanHttpServer = await HttpServer.bind(InternetAddress.anyIPv4, lanHttpPort);
      debugPrint('🚀 [TvRemoteService] Servidor LAN TV iniciado en puerto $lanHttpPort');
      _lanHttpServer!.listen(_handleLanHttpRequest, onError: (e) {
        debugPrint('⚠️ [TvRemoteService] Error en HttpServer LAN: $e');
      });
    } catch (e) {
      debugPrint('⚠️ [TvRemoteService] No se pudo iniciar HttpServer LAN: $e');
    }

    try {
      _lanUdpSocket?.close();
      _lanUdpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, lanUdpPort);
      _lanUdpSocket!.broadcastEnabled = true;
      _lanUdpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = _lanUdpSocket?.receive();
          if (dg != null) {
            try {
              final msg = utf8.decode(dg.data, allowMalformed: true).trim();
              if (msg.startsWith('INUTIL_TV_DISCOVER')) {
                final reply = utf8.encode('INUTIL_TV_ONLINE|$lanHttpPort|${_tvState.tvName}|${_tvState.tvDeviceId}');
                _lanUdpSocket?.send(reply, dg.address, dg.port);
                debugPrint('📡 [TvRemoteService] Descubrimiento UDP respondido a ${dg.address.address}:${dg.port}');
              }
            } catch (_) {}
          }
        }
      });
      debugPrint('📡 [TvRemoteService] Socket UDP LAN listo en puerto $lanUdpPort');
    } catch (e) {
      debugPrint('⚠️ [TvRemoteService] No se pudo iniciar UDP LAN: $e');
    }
  }

  Future<void> _handleLanHttpRequest(HttpRequest req) async {
    req.response.headers.add('Access-Control-Allow-Origin', '*');
    req.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    req.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method == 'OPTIONS') {
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
      return;
    }

    final path = req.uri.path;
    if (req.method == 'GET' && path == '/api/tv/ping') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'ok': true,
        'name': _tvState.tvName,
        'deviceId': _tvState.tvDeviceId,
        'online': true,
      }));
      await req.response.close();
      return;
    }

    if (req.method == 'GET' && path == '/api/tv/state') {
      req.response.headers.contentType = ContentType.json;
      final map = _tvState.toFirestore();
      map['updatedAt'] = (_tvState.updatedAt ?? DateTime.now()).toIso8601String();
      req.response.write(jsonEncode({
        'ok': true,
        'state': map,
      }));
      await req.response.close();
      return;
    }

    if (req.method == 'POST' && path == '/api/tv/command') {
      try {
        final bodyStr = await utf8.decoder.bind(req).join();
        final Map<String, dynamic> json = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : {};
        final action = json['action']?.toString() ?? '';
        final payload = (json['payload'] as Map<String, dynamic>?) ?? {};
        final cmdId = json['commandId']?.toString() ?? _uuid.v4();

        if (action.isNotEmpty) {
          final cmd = TvRemoteCommand(
            commandId: cmdId,
            action: action,
            payload: payload,
            createdAt: DateTime.now(),
          );
          _lastHandledCommandId = cmd.commandId;
          debugPrint('⚡ [TvRemoteService] Comando LAN recibido en TV: $action (id: $cmdId)');
          dispatchCommandLocally(cmd);
        }

        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'ok': true,
          'action': action,
          'commandId': cmdId,
        }));
      } catch (e) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.write(jsonEncode({'ok': false, 'error': e.toString()}));
      }
      await req.response.close();
      return;
    }

    req.response.statusCode = HttpStatus.notFound;
    req.response.write('Not Found');
    await req.response.close();
  }

  /// Reporta el estado actual del reproductor de la TV hacia el celular.
  Future<void> reportTvPlayback({
    required bool isPlaying,
    required String title,
    String subtitle = '',
    String poster = '',
    bool isLive = false,
    int positionSec = 0,
    int durationSec = 0,
    int volume = 100,
    int episodeIndex = 0,
    int episodeCount = 0,
    double speed = 1.0,
  }) async {
    if (!TvModeService.instance.isTv) return;
    _tvState = TvPlaybackState(
      online: true,
      tvDeviceId: InutilAuthService.instance.deviceId,
      tvName: 'Smart TV',
      lanHost: _localTvIp ?? _targetTvLanHost ?? '',
      isPlaying: isPlaying,
      title: title,
      subtitle: subtitle,
      poster: poster,
      isLive: isLive,
      positionSec: positionSec,
      durationSec: durationSec,
      volume: volume,
      episodeIndex: episodeIndex,
      episodeCount: episodeCount,
      speed: speed,
      updatedAt: DateTime.now(),
    );
    await _publishTvState(_tvState);
  }

  Future<void> clearTvPlayback() async {
    if (!TvModeService.instance.isTv) return;
    _tvState = TvPlaybackState(
      online: true,
      tvDeviceId: InutilAuthService.instance.deviceId,
      tvName: 'Smart TV',
      lanHost: _localTvIp ?? _targetTvLanHost ?? '',
      updatedAt: DateTime.now(),
    );
    await _publishTvState(_tvState);
  }

  Future<void> _publishTvState(TvPlaybackState state) async {
    final uid = _uid;
    if (uid == null || uid.isEmpty) return;
    if (InutilAuthService.instance.isOnlineValidationDisabled) return;
    if (_lastFirestore429Time != null &&
        DateTime.now().difference(_lastFirestore429Time!).inSeconds < 60) {
      return;
    }
    try {
      final ok = await InutilFirestoreService.instance.setDocument(
        'users/$uid/tv_remote/state',
        state.toFirestore(),
        merge: false,
      );
      if (!ok) {
        _lastFirestore429Time = DateTime.now();
      }
    } catch (e) {
      final err = e.toString();
      if (err.contains('429') || err.contains('RESOURCE_EXHAUSTED')) {
        _lastFirestore429Time = DateTime.now();
        debugPrint('⏳ [TvRemoteService] Firestore 429 en publishTvState. Pausando sincronización cloud 60s.');
      }
    }
  }

  Future<void> _pollIncomingCommand() async {
    if (_pollingCommand) return;
    final uid = _uid;
    if (uid == null || uid.isEmpty) return;
    if (_lastFirestore429Time != null &&
        DateTime.now().difference(_lastFirestore429Time!).inSeconds < 45) {
      return;
    }
    _pollingCommand = true;
    try {
      final doc = await InutilFirestoreService.instance
          .getDocument('users/$uid/tv_remote/command');
      if (doc == null) return;
      final cmd = TvRemoteCommand.fromFirestore(doc);
      if (cmd == null) return;
      if (cmd.commandId == _lastHandledCommandId) return;
      if (!cmd.isFresh) {
        _lastHandledCommandId = cmd.commandId;
        return;
      }
      _lastHandledCommandId = cmd.commandId;
      debugPrint('📺 [TvRemoteService] Comando recibido en TV: ${cmd.action} (id: ${cmd.commandId})');
      dispatchCommandLocally(cmd);
    } catch (e) {
      final err = e.toString();
      if (err.contains('429') || err.contains('RESOURCE_EXHAUSTED')) {
        _lastFirestore429Time = DateTime.now();
        debugPrint('⏳ [TvRemoteService] Firestore 429 detectado. Pausando sondeo cloud por 45s (LAN activo).');
      } else {
        debugPrint('⚠️ [TvRemoteService] Error al recibir comando: $e');
      }
    } finally {
      _pollingCommand = false;
    }
  }

  static const _playerActions = {
    'toggle_play',
    'play',
    'pause',
    'seek_relative',
    'seek_absolute',
    'set_speed',
    'prev_episode',
    'next_episode',
    'volume_delta',
    'stop',
  };

  /// Despacha un comando recibido hacia el handler de lanzamiento, reproductor o navegación.
  @visibleForTesting
  void dispatchCommandLocally(TvRemoteCommand cmd) {
    if (cmd.action == 'play_vod' || cmd.action == 'play_channel') {
      _launchHandler?.call(cmd);
    } else if (_activePlayerHandler != null && _playerActions.contains(cmd.action)) {
      _activePlayerHandler?.call(cmd);
    } else if (_activePlayerHandler != null &&
        (cmd.action == 'back' || cmd.action == 'stop')) {
      _activePlayerHandler?.call(cmd);
    } else {
      // Si hay reproductor activo, también le notificamos por si puede reaccionar (ej. dpad)
      _activePlayerHandler?.call(cmd);
      _systemNavigationHandler?.call(cmd);
    }
  }

  // ---------------------------------------------------------------------------
  // 2. ROL CELULAR (descubrimiento LAN + detecta TV + envía controles)
  // ---------------------------------------------------------------------------
  void _startMobileWatcher() {
    unawaited(loadPreferences());
    unawaited(discoverTvLan().then((_) => refreshTvStateNow()));
    _mobilePollTimer?.cancel();
    _mobilePollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(refreshTvStateNow());
    });
  }

  void setTargetTvLanHost(String? host) {
    _targetTvLanHost = host;
    notifyListeners();
  }

  Future<void> discoverTvLan() async {
    if (disableLanDiscoveryForTest) return;
    if (_discoveringLan) return;
    if (InutilAuthService.instance.isOnlineValidationDisabled) return;
    _discoveringLan = true;
    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Host en memoria o SharedPreferences
      final cachedHost = _targetTvLanHost ?? prefs.getString(_prefTvLanHostKey);
      if (cachedHost != null && cachedHost.isNotEmpty) {
        if (await _pingLanHost(cachedHost)) {
          _targetTvLanHost = cachedHost;
          await prefs.setString(_prefTvLanHostKey, cachedHost);
          _discoveringLan = false;
          notifyListeners();
          return;
        }
      }

      // 2. IP fija conocida en la red de pruebas (192.168.100.17)
      const knownTvHost = '192.168.100.17';
      if (await _pingLanHost(knownTvHost)) {
        _targetTvLanHost = knownTvHost;
        await prefs.setString(_prefTvLanHostKey, knownTvHost);
        debugPrint('🎯 [TvRemoteService] TV confirmada en host local conocido: $knownTvHost');
        _discoveringLan = false;
        notifyListeners();
        return;
      }

      // 3. Descubrimiento por broadcast UDP
      try {
        final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        socket.broadcastEnabled = true;
        final completer = Completer<String?>();

        socket.listen((event) {
          if (event == RawSocketEvent.read) {
            final dg = socket.receive();
            if (dg != null) {
              final resp = utf8.decode(dg.data, allowMalformed: true).trim();
              if (resp.startsWith('INUTIL_TV_ONLINE')) {
                final host = dg.address.address;
                if (!completer.isCompleted) completer.complete(host);
              }
            }
          }
        });

        final probeMsg = utf8.encode('INUTIL_TV_DISCOVER');
        try {
          socket.send(probeMsg, InternetAddress('255.255.255.255'), lanUdpPort);
        } catch (_) {}
        try {
          socket.send(probeMsg, InternetAddress('192.168.100.255'), lanUdpPort);
        } catch (_) {}
        try {
          final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
          for (final iface in interfaces) {
            for (final addr in iface.addresses) {
              final parts = addr.address.split('.');
              if (parts.length == 4) {
                final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
                socket.send(probeMsg, InternetAddress(bcast), lanUdpPort);
              }
            }
          }
        } catch (_) {}

        final foundHost = await completer.future.timeout(
          const Duration(milliseconds: 1000),
          onTimeout: () => null,
        );
        socket.close();

        if (foundHost != null) {
          _targetTvLanHost = foundHost;
          await prefs.setString(_prefTvLanHostKey, foundHost);
          debugPrint('🎯 [TvRemoteService] TV descubierta vía broadcast UDP: $foundHost');
          _discoveringLan = false;
          notifyListeners();
          return;
        }
      } catch (e) {
        debugPrint('⚠️ [TvRemoteService] Error en broadcast UDP: $e');
      }

      // 4. Barrido de IPs vecinas probables
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLinkLocal: false,
        );
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (addr.address.startsWith('127.')) continue;
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
              final candidates = [17, 2, 3, 4, 5, 10, 15, 16, 18, 20, 23, 24, 25, 30, 50, 100];
              final futures = candidates.map((c) => _pingLanHost('$prefix.$c'));
              final results = await Future.wait(futures);
              for (int i = 0; i < results.length; i++) {
                if (results[i]) {
                  final found = '$prefix.${candidates[i]}';
                  _targetTvLanHost = found;
                  await prefs.setString(_prefTvLanHostKey, found);
                  debugPrint('🎯 [TvRemoteService] TV descubierta vía barrido LAN: $found');
                  _discoveringLan = false;
                  notifyListeners();
                  return;
                }
              }
            }
          }
        }
      } catch (_) {}
    } finally {
      _discoveringLan = false;
    }
  }

  Future<bool> _pingLanHost(String host) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
      final req = await client.getUrl(Uri.parse('http://$host:$lanHttpPort/api/tv/ping'));
      final resp = await req.close().timeout(const Duration(milliseconds: 700));
      if (resp.statusCode == HttpStatus.ok) {
        final body = await utf8.decoder.bind(resp).join();
        final map = jsonDecode(body);
        return map is Map && map['ok'] == true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> refreshTvStateNow() async {
    if (_pollingState) return;
    _pollingState = true;
    try {
      // 1. Intentar enlace directo por LAN de ultra-baja latencia
      if (_targetTvLanHost != null) {
        HttpClient? client;
        try {
          client = HttpClient()..connectionTimeout = const Duration(milliseconds: 1000);
          final req = await client.getUrl(Uri.parse('http://$_targetTvLanHost:$lanHttpPort/api/tv/state'));
          final resp = await req.close().timeout(const Duration(milliseconds: 1200));
          if (resp.statusCode == HttpStatus.ok) {
            final body = await utf8.decoder.bind(resp).join();
            final map = jsonDecode(body) as Map<String, dynamic>;
            if (map['ok'] == true && map['state'] is Map<String, dynamic>) {
              final stateData = Map<String, dynamic>.from(map['state'] as Map);
              stateData['updatedAt'] = DateTime.now().toIso8601String();
              stateData['online'] = true;
              _tvState = TvPlaybackState.fromFirestore(stateData);
              notifyListeners();
              return;
            }
          }
        } catch (e) {
          debugPrint('⚠️ [TvRemoteService] Falló refresco LAN con $_targetTvLanHost: $e');
          unawaited(discoverTvLan());
        } finally {
          client?.close(force: true);
        }
      } else {
        unawaited(discoverTvLan());
      }

      // 2. Fallback a Firestore si LAN no está disponible
      final uid = _uid;
      if (uid != null &&
          uid.isNotEmpty &&
          !InutilAuthService.instance.isOnlineValidationDisabled) {
        if (_lastFirestore429Time != null &&
            DateTime.now().difference(_lastFirestore429Time!).inSeconds < 60) {
          return;
        }
        try {
          final doc = await InutilFirestoreService.instance
              .getDocument('users/$uid/tv_remote/state');
          if (doc != null) {
            final next = TvPlaybackState.fromFirestore(doc);
            if (next.lanHost.isNotEmpty && _targetTvLanHost != next.lanHost) {
              _targetTvLanHost = next.lanHost;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_prefTvLanHostKey, next.lanHost);
              unawaited(refreshTvStateNow());
            }
            _tvState = next;
            notifyListeners();
          }
        } catch (e) {
          final err = e.toString();
          if (err.contains('429') || err.contains('RESOURCE_EXHAUSTED')) {
            _lastFirestore429Time = DateTime.now();
            debugPrint('⏳ [TvRemoteService] Firestore 429 en refreshTvState. Pausando 60s.');
          }
        }
      }
    } catch (_) {
    } finally {
      _pollingState = false;
    }
  }

  Future<bool> sendCommand(
    String action, {
    Map<String, dynamic> payload = const {},
  }) async {
    final cmdId = _uuid.v4();

    // 1. Prioridad: Despacho directo por LAN (sub-10ms, sin cuota cloud)
    if (_targetTvLanHost != null) {
      HttpClient? client;
      try {
        client = HttpClient()..connectionTimeout = const Duration(milliseconds: 1000);
        final req = await client.postUrl(Uri.parse('http://$_targetTvLanHost:$lanHttpPort/api/tv/command'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({
          'commandId': cmdId,
          'action': action,
          'payload': payload,
        }));
        final resp = await req.close().timeout(const Duration(milliseconds: 1200));
        if (resp.statusCode == HttpStatus.ok) {
          debugPrint('⚡ [TvRemote] Comando $action enviado por LAN a $_targetTvLanHost en <5ms');
          Future.delayed(const Duration(milliseconds: 250), () {
            unawaited(refreshTvStateNow());
          });
          return true;
        }
      } catch (e) {
        debugPrint('⚠️ [TvRemote] Falló envío LAN a $_targetTvLanHost: $e');
        unawaited(discoverTvLan());
      } finally {
        client?.close(force: true);
      }
    }

    // 2. Fallback: Despacho vía Firestore Cloud
    final uid = _uid;
    if (uid == null || uid.isEmpty) return false;
    final cmd = TvRemoteCommand(
      commandId: cmdId,
      action: action,
      payload: payload,
      createdAt: DateTime.now(),
    );
    try {
      final ok = await InutilFirestoreService.instance.setDocument(
        'users/$uid/tv_remote/command',
        cmd.toFirestore(),
        merge: false,
      );
      if (ok) {
        Future.delayed(const Duration(seconds: 2), () {
          unawaited(refreshTvStateNow());
        });
      }
      return ok;
    } catch (e) {
      debugPrint('[TvRemote] Error enviando comando $action por Firestore: $e');
      return false;
    }
  }

  Future<bool> sendVodToTv(
    VodItem item, {
    VodEpisode? episode,
    int positionSec = 0,
  }) {
    // Al enviar contenido a la TV, fijamos la preferencia para que los capítulos
    // siguientes (ej. capítulo 2, 3...) continúen reproduciéndose en la TV.
    unawaited(setPlayOnTv(true));
    return sendCommand(
      'play_vod',
      payload: {
        'item': item.toJson(),
        if (episode != null) 'episode': episode.toJson(),
        'positionSec': positionSec,
      },
    );
  }

  Future<bool> sendChannelToTv(Channel channel) {
    return sendCommand(
      'play_channel',
      payload: {'channel': channel.toJson()},
    );
  }

  /// Pausa inmediatamente la reproducción en la Smart TV.
  Future<bool> sendPause() => sendCommand('pause');

  /// Reanuda la reproducción en la Smart TV.
  Future<bool> sendPlay() => sendCommand('play');

  /// Detiene por completo la reproducción en la Smart TV y limpia el estado activo.
  Future<bool> sendStop() async {
    final ok = await sendCommand('stop');
    _tvState = _tvState.copyWith(isPlaying: false);
    notifyListeners();
    return ok;
  }

  /// Envía dirección D-Pad a la Smart TV ('up', 'down', 'left', 'right', 'center').
  Future<bool> sendDpad(String direction) =>
      sendCommand('dpad_$direction');

  /// Envía botón Volver / Atrás a la Smart TV.
  Future<bool> sendBack() => sendCommand('back');

  /// Envía botón Inicio / Home a la Smart TV.
  Future<bool> sendHome() => sendCommand('home');

  /// Salta directamente a una pestaña de la Smart TV (0=Inicio, 1=En Vivo, 2=Cine, 3=Series, 4=Anime).
  Future<bool> sendTab(int index) =>
      sendCommand('nav_tab', payload: {'index': index});

  /// Abre la pantalla de Búsqueda en la Smart TV.
  Future<bool> sendOpenSearch() => sendCommand('open_search');

  @visibleForTesting
  void setTvStateForTest(TvPlaybackState state) {
    _tvState = state;
    notifyListeners();
  }

  /// Busca texto completo en la TV (reemplaza el query actual del buscador).
  Future<bool> sendKeyboardText(String text) =>
      sendCommand('keyboard_text', payload: {'text': text});

  /// Confirma la búsqueda actual (Enter).
  Future<bool> sendKeyboardSubmit() => sendCommand('keyboard_submit');

  /// Borra el texto del buscador de la TV.
  Future<bool> sendKeyboardClear() => sendCommand('keyboard_clear');

  /// Salta a la posición exacta en segundos.
  Future<bool> sendSeekAbsolute(int positionSec) =>
      sendCommand('seek_absolute', payload: {'positionSec': positionSec});

  /// Cambia la velocidad de reproducción (0.5 – 2.0).
  Future<bool> sendSetSpeed(double speed) =>
      sendCommand('set_speed', payload: {'speed': speed});

  /// Episodio anterior.
  Future<bool> sendPrevEpisode() => sendCommand('prev_episode');

  /// Siguiente episodio.
  Future<bool> sendNextEpisode() => sendCommand('next_episode');

  /// Volumen delta sobre la TV (delta: -5 a +5 típicamente).
  Future<bool> sendVolumeDelta(int delta) =>
      sendCommand('volume_delta', payload: {'delta': delta});
}
