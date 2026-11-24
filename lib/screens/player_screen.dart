import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide Playable;
import 'package:media_kit_video/media_kit_video.dart';

import '../models/models.dart';
import '../services/app_settings_service.dart';
import '../services/artwork_cache_service.dart';
import '../services/device_control_service.dart';
import '../services/fullscreen_playback_coordinator.dart';
import '../services/hls_stream_proxy.dart';
import '../services/inutil_wrapped_service.dart';
import '../services/next_episode_preloader.dart';
import '../services/network_config_service.dart';
import '../services/offline_vault_service.dart';
import '../services/sleep_timer_service.dart';
import '../services/stream_validator.dart';
import '../services/tv_mode_service.dart';
import '../services/tv_remote_service.dart';
import '../services/vod_catalog_service.dart';
import '../services/watch_history.dart';
import '../theme/app_colors.dart';
import '../theme/inutil_icons.dart';
import '../widgets/fast_artwork.dart';
import '../widgets/inutil_sleep_timer_sheet.dart';
import '../widgets/tv_focusable.dart';

class Playable {
  final String label;
  final String url;
  final Map<String, String> headers;
  final List<SubtitleSource> subtitles;

  const Playable(
    this.label,
    this.url, {
    this.headers = const {},
    this.subtitles = const [],
  });
}

/// Reproductor Cinematográfico Minimalista de InútilTV v3.0 — estética Inútil Music:
/// - Paleta obsidiana pura (`#070709`), botones translúcidos en vidrio oscuro y
///   botón principal Play/Pausa en blanco puro (`#FFFFFF` / ícono carbón `#07110A`).
/// - CERO colisión de controles sobre errores o pantalla de carga.
/// - CERO pantalla negra en 0:00: solo oculta el HUD de carga cuando llegan
///   fotogramas reales (`videoParams.w > 0`) o avance real (`position > 600ms`),
///   con cambio automático al siguiente servidor validado tras 9s de estancamiento.
/// - Doble toque izq/der ±10s, gestos brillo/volumen, bloqueo táctil real,
///   Omitir Intro, Siguiente episodio en 5s y cajón lateral de zapping para TV en Vivo.
class PlayerScreen extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<Playable> playables;
  final String posterUrl;
  final bool isVod;
  final bool isAnime;
  final String? animeId;
  final VodItem? vodItem;
  final List<VodEpisode>? episodeList;
  final int initialEpisodeIndex;
  final Duration? initialPosition;
  final List<Channel>? channelList;
  final int initialChannelIndex;

  const PlayerScreen({
    super.key,
    required this.title,
    this.subtitle = '',
    this.playables = const [],
    this.posterUrl = '',
    this.isVod = false,
    this.isAnime = false,
    this.animeId,
    this.vodItem,
    this.episodeList,
    this.initialEpisodeIndex = 0,
    this.initialPosition,
    this.channelList,
    this.initialChannelIndex = 0,
  });

  /// Terminación real de un archivo directo, para que `libmpv` elija el
  /// demuxer correcto aunque reproduzca desde `127.0.0.1` (por defecto `mp4`).
  static String directFileExtension(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final match = RegExp(
      r'\.(mp4|mkv|webm|m4v|mov|avi|ts|m2ts|flv)$',
    ).firstMatch(path);
    return match?.group(1) ?? 'mp4';
  }

  /// Convierte cualquier etiqueta interna de fuente en un nombre limpio para el
  /// usuario final (sin revelar proveedores, hosts externos ni formatos técnicos).
  static String publicServerLabel(int index, String rawLabel) {
    final lower = rawLabel.toLowerCase();
    if (lower.contains('sin conexión') ||
        lower.contains('sin conexion') ||
        lower.contains('offline')) {
      return 'Sin conexión';
    }

    String? lang;
    if (lower.contains('latino')) {
      lang = 'Latino';
    } else if (lower.contains('subtitul') ||
        RegExp(r'\bsub\b').hasMatch(lower)) {
      lang = 'Subtitulado';
    } else if (lower.contains('español') || lower.contains('espanol')) {
      lang = 'Español';
    }

    String? quality;
    if (lower.contains('4k') || lower.contains('2160')) {
      quality = '4K';
    } else if (lower.contains('1080')) {
      quality = '1080p';
    } else if (lower.contains('720')) {
      quality = '720p';
    } else if (lower.contains('hd')) {
      quality = 'HD';
    }

    final parts = <String>['Servidor ${index + 1}'];
    if (lang != null) parts.add(lang);
    if (quality != null && (lang == null || quality != 'HD')) {
      parts.add(quality);
    }
    return parts.join(' · ');
  }

  /// Estado de carga sobrio: sin servidores ni proveedores, solo el
  /// idioma cuando ayuda ('Conectando · Latino...').
  static String _neutralLoadingStatus(String publicLabel) {
    final extra = publicLabel
        .split(' · ')
        .where((p) => !p.startsWith('Servidor') && p != 'Sin conexión')
        .join(' · ');
    return extra.isEmpty ? 'Conectando...' : 'Conectando · $extra...';
  }

  static final RegExp _privateSourcePattern = RegExp(
    r'\b(vidhide|streamwish|filemoon|doodstream|dood|vidara|voe|nupload|mixdrop|jkanime|jkplayer|tioanime|yourupload|serieskao|poseidon\w*|cuevana\w*|pelisflix|embed69|tdtchannels|iptv-org|free-tv|hls|mp4|aes-256|bóveda|boveda|http\s*\d{3})\b',
    caseSensitive: false,
  );

  /// Filtra mensajes de estado antes de mostrarlos en pantalla para evitar
  /// filtrar nombres de fuentes o detalles técnicos al usuario final.
  static String sanitizeStatusMessage(String rawStatus) {
    final trimmed = rawStatus.trim();
    if (trimmed.isEmpty) return 'Preparando reproducción...';
    if (_privateSourcePattern.hasMatch(trimmed)) {
      return 'Conectando al servidor...';
    }
    return trimmed;
  }

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  late final Player _player;
  late final VideoController _controller;
  final _focusNode = FocusNode();
  final _playPauseFocusNode = FocusNode();
  final _scrubberFocusNode = FocusNode();
  final List<StreamSubscription<dynamic>> _subs = [];

  int _current = 0;
  int _episodeIndex = 0;
  int _channelIndex = 0;
  String _activeTitle = '';
  String _activeSubtitle = '';
  List<Playable> _activePlayables = [];
  final Set<int> _tried = {};

  bool _resolving = false;
  bool _buffering = true;
  bool _hasVideo = false;
  bool _isPlaying = false;
  bool _isLocked = false;
  bool _showControls = true;
  bool _tvSeekBarVisible = false;
  bool _tvLiveBannerVisible = false;
  bool _tvChannelDrawerOpen = false;
  bool _scrubberFocused = false;
  bool _isLandscape = true;
  bool _initialSeekDone = false;
  BoxFit _fit = BoxFit.contain;

  String _statusMessage = 'Preparando reproducción...';
  String? _error;
  String _detectedQuality = '';

  String? _hudToast;
  Timer? _hudToastTimer;
  Timer? _hideTimer;
  Timer? _tvSeekBarTimer;
  Timer? _tvLiveBannerTimer;
  Timer? _stallTimer;
  Timer? _progressSaveTimer;

  // Ripple doble toque ±10s
  int _seekRippleDir = 0;
  int _seekRippleAccum = 0;
  Timer? _seekRippleTimer;

  // Gestos brillo / volumen + arrastre suave de barra de progreso
  bool _draggingBrightness = false;
  bool _draggingVolume = false;
  double _brightnessVal = 0.6;
  double _volumeVal = 1.0;
  double? _scrubbingMs;

  // Maratón Series / Anime + Proxy local 127.0.0.1 + Precarga instantánea
  bool _introSkipped = false;
  bool _nextOverlayVisible = false;
  bool _nextOverlayDismissed = false;
  int _nextCountdown = 5;
  Timer? _nextCountdownTimer;
  Timer? _preloadTriggerTimer;
  String? _activeProxySessionId;
  bool _preloadScheduledForCurrent = false;

  bool get _hasEpisodes =>
      widget.episodeList != null && widget.episodeList!.isNotEmpty;

  bool get _hasNextEpisode =>
      _hasEpisodes && _episodeIndex < widget.episodeList!.length - 1;

  bool get _hasChannels =>
      widget.channelList != null && widget.channelList!.isNotEmpty;

  bool get _isLiveChannelMode =>
      _hasChannels && !widget.isVod && widget.vodItem == null && !_hasEpisodes;

  bool get _isVodMode =>
      !_isLiveChannelMode &&
      (widget.isVod ||
          widget.vodItem != null ||
          _hasEpisodes ||
          _player.state.duration > Duration.zero);

  /// Solo mostramos controles centrales cuando el video realmente está activo
  /// y NO hay error ni resolución en curso (cero colisión de overlays).
  bool get _canShowCenterPlaybackControls =>
      _error == null && !_resolving && _hasVideo;

  @override
  void initState() {
    super.initState();
    _activeTitle = widget.title;
    _activeSubtitle = widget.subtitle;
    _activePlayables = List.of(widget.playables);
    _episodeIndex = widget.initialEpisodeIndex;
    // AVISA a TV en Vivo para que destruya su reproductor: en las TV Box de
    // 2 GB sólo hay un decodificador MediaCodec libre y si el de TV lo retiene
    // la película cae a decodificación por software (se ve trabada).
    FullscreenPlaybackCoordinator.instance.begin();
    _channelIndex = widget.initialChannelIndex;

    final settings = AppSettingsService.instance;
    final isTv = TvModeService.instance.isTv;
    final useZeroCopyTv = isTv && settings.hwAcceleration;
    _player = Player(
      configuration: PlayerConfiguration(
        logLevel: MPVLogLevel.warn,
        // En TV Box de 2 GB RAM (ej. Onn 4K) mantiene memoria estable sin swap.
        bufferSize: isTv ? 16 * 1024 * 1024 : settings.bufferSizeBytes,
        protocolWhitelist: const [
          'file',
          'tcp',
          'tls',
          'http',
          'https',
          'crypto',
          'data',
          'hls',
          'applehttp',
        ],
      ),
    );
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        // En Smart TV / TV Box usa decodificación y renderizado directo en
        // hardware (`vo=mediacodec_embed` + `hwdec=mediacodec`, zero-copy)
        // para eliminar el cuello de botella de CPU de `mediacodec-copy`.
        // En celular mantiene `vo=gpu` + `hwdec=auto-safe`.
        vo: useZeroCopyTv ? 'mediacodec_embed' : 'gpu',
        hwdec: useZeroCopyTv
            ? 'mediacodec'
            : (settings.hwAcceleration ? 'auto-safe' : 'no'),
        enableHardwareAcceleration: settings.hwAcceleration,
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );
    _configureSmoothMpv(settings);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    DeviceControlService.setKeepScreenOn(true);
    DeviceControlService.getBrightness().then((b) {
      if (mounted) _brightnessVal = b;
    });

    _bindPlayerStreams();

    if (TvModeService.instance.isTv) {
      // En Smart TV arrancamos en pantalla completa limpia (sin iconos encima)
      _showControls = false;
      TvRemoteService.instance
          .registerActivePlayerHandler(_handleRemoteCommand);
      unawaited(_syncRemoteTvState());
    } else {
      // En celular: si la TV estaba reproduciendo, la detenemos de inmediato para evitar sonido duplicado
      if (TvRemoteService.instance.isTvOnline) {
        unawaited(TvRemoteService.instance.sendStop());
      }
    }

    _subs.add(SleepTimerService.instance.onExpired.listen((reason) {
      if (!mounted) return;
      _cancelNextEpisodeCountdown();
      _player.pause();
      _showHudToast(reason);
    }));

    _progressSaveTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) {
        _saveCurrentProgress();
        if (TvModeService.instance.isTv) {
          unawaited(_syncRemoteTvState());
        }
        if (_isPlaying && _hasVideo) {
          final item = widget.vodItem;
          final cat = item != null
              ? (item.isAnime
                  ? 'Anime'
                  : (item.isSeries ? 'Series' : 'Películas'))
              : 'TV en Vivo';
          InutilTvWrappedService.instance.recordWatchDelta(
            id: item?.id ??
                (_hasChannels
                    ? widget.channelList![_channelIndex].id
                    : _activeTitle),
            title: _activeTitle,
            category: cat,
            posterUrl: widget.posterUrl,
            deltaSeconds: 15,
          );
        }
      },
    );

    if (_hasEpisodes && _activePlayables.isEmpty) {
      _playEpisode(_episodeIndex, applyInitialSeek: true);
    } else if (_hasEpisodes && widget.vodItem != null) {
      _startEpisodeCheckingVaultFirst();
    } else if (widget.vodItem != null) {
      _startMovieCheckingVaultFirst();
    } else if (_activePlayables.isNotEmpty) {
      _play(0);
    } else if (_hasChannels) {
      _playChannelAt(_channelIndex);
    } else {
      _error = 'No hay enlaces disponibles para este título.';
      _buffering = false;
    }

    _resetHideTimer();
  }

  /// Configura libmpv para reproducción fluida sin tirones en red y offline.
  void _configureSmoothMpv(AppSettingsService settings) {
    if (_player.platform is! NativePlayer) return;
    final np = _player.platform as NativePlayer;
    final isVod = widget.isVod || widget.vodItem != null || _hasEpisodes;
    final isTv = TvModeService.instance.isTv;
    final props = <String, String>{
      'cache': 'yes',
      'cache-pause': 'yes',
      'cache-pause-initial': 'yes',
      'cache-pause-wait': isVod ? '2.0' : '1.0',
      'demuxer-max-bytes': isTv
          ? (isVod ? '16MiB' : '10MiB')
          : (settings.ultraBuffer ? '64MiB' : '32MiB'),
      'demuxer-max-back-bytes': isTv ? '6MiB' : '16MiB',
      'demuxer-readahead-secs':
          isTv ? (isVod ? '24' : '8') : (isVod ? '60' : '12'),
      'network-timeout': '30',
      'stream-lavf-o':
          'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=8,multiple_requests=1',
      'framedrop': 'vo',
      'video-sync': 'audio',
      'hwdec-codecs': 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1',
      'vd-lavc-fast': 'yes',
      'vd-lavc-threads': '0',
      'interpolation': 'no',
      'deband': 'no',
      'dither-depth': 'no',
      'scale': 'bilinear',
      'cscale': 'bilinear',
      'dscale': 'bilinear',
      'sws-scaler': 'fast_bilinear',
      'audio-buffer': '0.4',
      'hr-seek': isTv ? 'no' : 'yes',
    };
    // Redes con proxy obligatorio (empresas, hoteles, aeropuertos): libmpv no
    // usa el proxy del sistema, hay que decírselo explícitamente.
    final proxyUrl = NetworkConfigService.instance.mpvProxyUrl;
    if (proxyUrl != null) {
      props['proxy-url'] = proxyUrl;
      _mpvProxyApplied = proxyUrl;
    }
    for (final e in props.entries) {
      try {
        np.setProperty(e.key, e.value);
      } catch (_) {
        try {
          np.command(['set_option', e.key, e.value]);
        } catch (_) {}
      }
    }
  }

  /// Último `proxy-url` enviado a libmpv, para no reescribirlo en cada apertura.
  String? _mpvProxyApplied;

  /// Proxy para libmpv según la URL que se va a abrir.
  ///
  /// `proxy-url` se aplica a TODAS las peticiones de libmpv, incluidas las de
  /// `127.0.0.1`. Si el video pasa por nuestro proxy local y la red tiene proxy
  /// obligatorio, libmpv le mandaría la URL de loopback al proxy corporativo,
  /// que no puede ver el teléfono, y la reproducción se caería. Por eso cada
  /// apertura fija el valor que le toca a esa URL concreta.
  Future<void> _applyMpvProxyForUrl(String url) async {
    if (_player.platform is! NativePlayer) return;
    final np = _player.platform as NativePlayer;
    final desired = NetworkConfigService.mpvProxyForUrl(url) ?? '';
    if (desired == _mpvProxyApplied) return;
    _mpvProxyApplied = desired;
    try {
      np.setProperty('proxy-url', desired);
    } catch (_) {
      try {
        np.command(['set_option', 'proxy-url', desired]);
      } catch (_) {}
    }
  }

  void _bindPlayerStreams() {
    _subs.add(_player.stream.buffering.listen((b) {
      if (!mounted || _buffering == b) return;
      setState(() => _buffering = b);
    }));

    _subs.add(_player.stream.playing.listen((p) {
      if (!mounted || _isPlaying == p) return;
      setState(() => _isPlaying = p);
      // IMPORTANTE: JAMÁS marcamos _hasVideo = true con un timer ciego.
      // Esperamos fotogramas reales (videoParams) o avance real (position > 600ms).
    }));

    _subs.add(_player.stream.videoParams.listen((vp) {
      if (!mounted) return;
      final w = vp.w ?? 0;
      final h = vp.h ?? 0;
      if (w > 0 && h > 0) {
        final firstFrame = !_hasVideo;
        final label = h >= 2000
            ? '4K'
            : h >= 1000
                ? '1080p'
                : h >= 680
                    ? '720p'
                    : h >= 440
                        ? '480p'
                        : '${h}p';
        setState(() {
          _hasVideo = true;
          _buffering = false;
          _error = null;
          _detectedQuality = label;
          if (firstFrame && TvModeService.instance.isTv) {
            _showControls = false;
          }
        });
        _stallTimer?.cancel();
        if (firstFrame) {
          _onVideoReady();
        }
        _tryInitialSeek();
        _scheduleNextEpisodePreload();
      }
    }));

    _subs.add(_player.stream.position.listen((pos) {
      if (!mounted) return;
      if (pos > const Duration(milliseconds: 600) && !_hasVideo) {
        setState(() {
          _hasVideo = true;
          _buffering = false;
          _error = null;
          if (TvModeService.instance.isTv) {
            _showControls = false;
          }
        });
        _stallTimer?.cancel();
        _onVideoReady();
        _tryInitialSeek();
        _scheduleNextEpisodePreload();
      }

      if (_hasNextEpisode &&
          !_nextOverlayVisible &&
          !_nextOverlayDismissed &&
          AppSettingsService.instance.autoNextEpisode) {
        final dur = _player.state.duration;
        if (dur > const Duration(minutes: 2)) {
          final remaining = dur - pos;
          if (remaining <= const Duration(seconds: 25) &&
              remaining > const Duration(seconds: 2)) {
            _startNextEpisodeCountdown(seconds: 10);
          }
        }
      }
    }));

    _subs.add(_player.stream.completed.listen((done) {
      if (!mounted || !done) return;
      _saveCurrentProgress(forceCompleted: true);
      final item = widget.vodItem;
      if (item != null) {
        final ep = _hasEpisodes ? widget.episodeList![_episodeIndex] : null;
        unawaited(
          OfflineVaultService.instance.onPlaybackCompleted(
            itemId: item.id,
            isSeries: _hasEpisodes,
            seasonNumber: ep?.seasonNumber ?? 1,
            episodeNumber: ep?.episodeNumber ?? 1,
          ),
        );
      }
      if (SleepTimerService.instance.consumeEndOfEpisodeIfArmed()) {
        _player.pause();
        return;
      }
      if (_hasNextEpisode && AppSettingsService.instance.autoNextEpisode) {
        _startNextEpisodeCountdown(seconds: 5);
      }
    }));

    _subs.add(_player.stream.error.listen((msg) {
      if (!mounted || _resolving) return;
      if (_benignError(msg)) return;
      _failoverOrShowError('Error de transmisión');
    }));
  }

  void _failoverOrShowError(String reason) {
    _stallTimer?.cancel();
    final next = _nextUntried();
    if (next != null) {
      _tried.add(next);
      _showHudToast('Cambiando a ${_activePlayables[next].label}...');
      _play(next);
    } else {
      setState(() {
        _error =
            'No fue posible reproducir este título en este momento.\nIntenta reintentar o prueba otro episodio.';
        _buffering = false;
        _hasVideo = false;
      });
    }
  }

  void _tryInitialSeek() {
    if (_initialSeekDone) return;
    final target = widget.initialPosition;
    if (target != null && target > const Duration(seconds: 8)) {
      _initialSeekDone = true;
      Future.delayed(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        final dur = _player.state.duration;
        if (dur == Duration.zero ||
            target < dur - const Duration(seconds: 10)) {
          _player.seek(target);
          _showHudToast('Reanudando en ${_fmt(target)}');
        }
      });
    } else {
      _initialSeekDone = true;
    }
  }

  bool _benignError(String msg) {
    final l = msg.toLowerCase();
    return l.contains('unsupported') ||
        l.contains('deprecated') ||
        l.contains('unknown') ||
        l.contains('subtitle') ||
        l.contains('metadata');
  }

  int? _nextUntried() {
    for (var i = 0; i < _activePlayables.length; i++) {
      if (!_tried.contains(i)) return i;
    }
    return null;
  }

  /// Programa la precarga silenciosa de los primeros ~2-3 min del siguiente
  /// episodio (Series y Anime) tras 6s de reproducción estable.
  void _scheduleNextEpisodePreload() {
    if (_preloadScheduledForCurrent) return;
    if (!_hasNextEpisode || widget.vodItem == null) return;
    if (!AppSettingsService.instance.preloadNextEpisode) return;

    _preloadScheduledForCurrent = true;
    _preloadTriggerTimer?.cancel();
    final nextEp = widget.episodeList![_episodeIndex + 1];
    final item = widget.vodItem!;
    // Si el siguiente episodio ya está en la bóveda offline, ya es instantáneo (0 MB de red)
    if (OfflineVaultService.instance.findCompletedEpisode(
          item.id,
          nextEp.seasonNumber,
          nextEp.episodeNumber,
        ) !=
        null) {
      return;
    }
    _preloadTriggerTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || _error != null) return;
      unawaited(
        NextEpisodePreloader.instance.preloadNext(
          item: item,
          nextEpisode: nextEp,
        ),
      );
    });
  }

  Future<void> _startMovieCheckingVaultFirst() async {
    final item = widget.vodItem!;
    if (await _tryOpenOfflineMovie(item, applyInitialSeek: true)) return;
    if (!mounted) return;
    if (_activePlayables.isNotEmpty) {
      await _play(0);
    } else {
      await _resolveAndPlayVodItem(item, applyInitialSeek: true);
    }
  }

  Future<void> _startEpisodeCheckingVaultFirst() async {
    final item = widget.vodItem!;
    final ep = widget.episodeList![_episodeIndex];
    if (await _tryOpenOfflineEpisode(
      item,
      ep,
      _episodeIndex,
      applyInitialSeek: true,
    )) {
      return;
    }
    if (!mounted) return;
    if (_activePlayables.isNotEmpty) {
      await _play(0);
    } else {
      await _playEpisode(_episodeIndex, applyInitialSeek: true);
    }
  }

  Future<bool> _tryOpenOfflineMovie(
    VodItem item, {
    bool applyInitialSeek = false,
  }) async {
    await OfflineVaultService.instance.initialize();
    final entry = OfflineVaultService.instance.findCompletedMovie(item.id);
    if (entry == null) return false;
    final handle = await OfflineVaultService.instance.openVaultPlayback(entry);
    if (!mounted || handle == null) return false;

    _activePlayables = [
      Playable(
        'Sin conexión',
        handle.localUrl,
        subtitles: handle.subtitles,
      ),
    ];
    if (!applyInitialSeek) _initialSeekDone = true;
    _showHudToast('Reproduciendo sin conexión');
    await _play(
      0,
      preloadedSessionId: handle.sessionId,
      preloadedLocalUrl: handle.localUrl,
    );
    return true;
  }

  Future<bool> _tryOpenOfflineEpisode(
    VodItem item,
    VodEpisode ep,
    int index, {
    bool applyInitialSeek = false,
  }) async {
    await OfflineVaultService.instance.initialize();
    final entry = OfflineVaultService.instance.findCompletedEpisode(
      item.id,
      ep.seasonNumber,
      ep.episodeNumber,
    );
    if (entry == null) return false;
    final handle = await OfflineVaultService.instance.openVaultPlayback(entry);
    if (!mounted || handle == null) return false;

    setState(() {
      _episodeIndex = index;
      _activeSubtitle =
          'T${ep.seasonNumber} · Ep. ${ep.episodeNumber} — ${ep.title}';
      _introSkipped = false;
      _nextOverlayDismissed = false;
      _tried.clear();
    });
    _activePlayables = [
      Playable(
        'Sin conexión',
        handle.localUrl,
        subtitles: handle.subtitles,
      ),
    ];
    if (!applyInitialSeek) _initialSeekDone = true;
    _showHudToast('Ep. ${ep.episodeNumber} sin conexión');
    await _play(
      0,
      preloadedSessionId: handle.sessionId,
      preloadedLocalUrl: handle.localUrl,
    );
    return true;
  }

  Future<void> _play(
    int index, {
    String? preloadedSessionId,
    String? preloadedLocalUrl,
  }) async {
    if (index < 0 || index >= _activePlayables.length) return;
    _stallTimer?.cancel();
    _tried.add(index);

    final playable = _activePlayables[index];
    final publicLabel = PlayerScreen.publicServerLabel(index, playable.label);
    setState(() {
      _current = index;
      _resolving = false;
      _buffering = true;
      _hasVideo = false;
      _error = null;
      _detectedQuality = '';
      _statusMessage = preloadedLocalUrl != null
          ? (publicLabel == 'Sin conexión'
              ? 'Cargando descarga sin conexión...'
              : 'Iniciando reproducción...')
          : PlayerScreen._neutralLoadingStatus(publicLabel);
    });

    try {
      String urlToOpen = playable.url;
      Map<String, String>? headersToOpen =
          playable.headers.isEmpty ? null : playable.headers;

      // Liberar sesión de proxy anterior si es diferente a la nueva
      if (_activeProxySessionId != null &&
          _activeProxySessionId != preloadedSessionId) {
        HlsStreamProxy.instance.releaseSession(_activeProxySessionId);
        _activeProxySessionId = null;
      }

      if (preloadedLocalUrl != null && preloadedSessionId != null) {
        // ¡Cambio instantáneo! El siguiente episodio ya está pre-bufferizado en 127.0.0.1
        _activeProxySessionId = preloadedSessionId;
        urlToOpen = preloadedLocalUrl;
        headersToOpen = null;
      } else if (_isVodMode &&
          (StreamValidator.needsLocalHlsProxy(playable.url) ||
              NetworkConfigService.instance.restrictionsActive)) {
        // En VOD todo pasa por nuestro proxy local 127.0.0.1:
        // - HLS: normaliza segmentos .image/.png -> .ts y recorta cabeceras
        //   PNG falsas antes de entregarlos a libmpv.
        // - Archivos directos: sólo cuando la red tiene proxy o DNS seguro,
        //   para que libmpv nunca dependa del DNS de la red (127.0.0.1 no
        //   requiere resolver nada).
        final isHls = StreamValidator.needsLocalHlsProxy(playable.url);
        final reg = isHls
            ? await HlsStreamProxy.instance.registerHlsSession(
                upstreamUrl: playable.url,
                headers: playable.headers,
                tag: _activeTitle,
              )
            : await HlsStreamProxy.instance.registerMp4Session(
                upstreamUrl: playable.url,
                headers: playable.headers,
                tag: _activeTitle,
                extension: PlayerScreen.directFileExtension(playable.url),
              );
        if (!mounted) {
          HlsStreamProxy.instance.releaseSession(reg.sessionId);
          return;
        }
        _activeProxySessionId = reg.sessionId;
        urlToOpen = reg.localUrl;
        headersToOpen = null;
      }

      await _applyMpvProxyForUrl(urlToOpen);

      await _player.open(
        Media(urlToOpen, httpHeaders: headersToOpen),
        play: true,
      );

      if (playable.subtitles.isNotEmpty) {
        final firstSub = playable.subtitles.first;
        Future.delayed(const Duration(milliseconds: 900), () {
          if (!mounted) return;
          try {
            _player.setSubtitleTrack(
              SubtitleTrack.uri(
                firstSub.url,
                title: firstSub.label.isNotEmpty ? firstSub.label : 'Español',
                language: firstSub.language,
              ),
            );
          } catch (_) {}
        });
      }

      // Guardián anti-pantalla-negra: en VOD damos 22s para tolerar redes lentas
      // (3G/4G débil) sin abortar mientras se descarga el primer segmento; en TV en Vivo 12s.
      _stallTimer = Timer(Duration(seconds: _isVodMode ? 22 : 12), () {
        if (!mounted || _hasVideo || _error != null || _resolving) return;
        _failoverOrShowError('Tiempo de espera agotado');
      });
    } catch (_) {
      _failoverOrShowError('Error al abrir flujo');
    }
  }

  Future<void> _resolveAndPlayVodItem(
    VodItem item, {
    bool applyInitialSeek = false,
  }) async {
    _stallTimer?.cancel();
    // 0. ¿Ya está descargada en la bóveda offline? 0 ms, 0 MB de datos móviles.
    if (await _tryOpenOfflineMovie(item, applyInitialSeek: applyInitialSeek)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _resolving = true;
      _buffering = true;
      _hasVideo = false;
      _error = null;
      _tried.clear();
      _statusMessage = 'Buscando servidores disponibles...';
    });

    final sources = await VodCatalogService().resolveAllPlaybackSources(
      item,
      null,
      (status) {
        if (mounted) {
          setState(
            () => _statusMessage = PlayerScreen.sanitizeStatusMessage(status),
          );
        }
      },
    );

    if (!mounted) return;
    if (sources.isEmpty) {
      setState(() {
        _resolving = false;
        _buffering = false;
        _error =
            'Ningún servidor respondió con video válido para "${item.title}".';
      });
      return;
    }

    _activePlayables = [
      for (final s in sources)
        Playable(
          s.quality.isEmpty ? 'Servidor HD' : s.quality,
          s.url,
          headers: s.headers,
          subtitles: s.subtitles,
        ),
    ];
    if (!applyInitialSeek) _initialSeekDone = true;
    await _play(0);
  }

  Future<void> _playEpisode(int index, {bool applyInitialSeek = false}) async {
    if (!_hasEpisodes || index < 0 || index >= widget.episodeList!.length) {
      return;
    }
    _cancelNextEpisodeCountdown();
    _stallTimer?.cancel();
    _preloadTriggerTimer?.cancel();
    _preloadScheduledForCurrent = false;

    final ep = widget.episodeList![index];
    final item = widget.vodItem;

    // 0. ¿Ya está descargado en la bóveda offline? 0 ms, 0 MB, Modo Avión 100 %.
    if (item != null) {
      if (await _tryOpenOfflineEpisode(
        item,
        ep,
        index,
        applyInitialSeek: applyInitialSeek,
      )) {
        return;
      }
      if (!mounted) return;
    }

    // 1. ¿Ya está PRECARGADO en segundo plano? ¡Salto instantáneo <300 ms!
    if (item != null) {
      final preloaded =
          NextEpisodePreloader.instance.consumeIfReady(item.id, ep);
      if (preloaded != null && preloaded.sources.isNotEmpty) {
        setState(() {
          _episodeIndex = index;
          _activeSubtitle =
              'T${ep.seasonNumber} · Ep. ${ep.episodeNumber} — ${ep.title}';
          _introSkipped = false;
          _nextOverlayDismissed = false;
          _tried.clear();
        });
        _activePlayables = [
          for (final s in preloaded.sources)
            Playable(
              s.quality.isEmpty ? 'Servidor HD' : s.quality,
              s.url,
              headers: s.headers,
              subtitles: s.subtitles,
            ),
        ];
        if (!applyInitialSeek) _initialSeekDone = true;
        final mb = (preloaded.bytesCached / (1024 * 1024));
        _showHudToast(
          mb >= 0.5
              ? '⚡ Ep. ${ep.episodeNumber} precargado (${mb.toStringAsFixed(1)} MB) · al instante'
              : '⚡ Ep. ${ep.episodeNumber} listo al instante',
        );
        await _play(
          0,
          preloadedSessionId: preloaded.sessionId,
          preloadedLocalUrl: preloaded.localProxyUrl,
        );
        return;
      }
    }

    setState(() {
      _episodeIndex = index;
      _activeSubtitle =
          'T${ep.seasonNumber} · Ep. ${ep.episodeNumber} — ${ep.title}';
      _resolving = true;
      _buffering = true;
      _hasVideo = false;
      _error = null;
      _introSkipped = false;
      _nextOverlayDismissed = false;
      _tried.clear();
      _statusMessage = 'Resolviendo Episodio ${ep.episodeNumber}...';
    });

    if (ep.sources.isNotEmpty) {
      _activePlayables = [
        for (final s in ep.sources)
          Playable(
            s.quality.isEmpty ? 'Servidor HD' : s.quality,
            s.url,
            headers: s.headers,
            subtitles: s.subtitles,
          ),
      ];
      if (!applyInitialSeek) _initialSeekDone = true;
      await _play(0);
      return;
    }

    if (item == null) {
      setState(() {
        _resolving = false;
        _buffering = false;
        _error = 'No se encontraron fuentes para este episodio.';
      });
      return;
    }

    final sources = await VodCatalogService().resolveAllPlaybackSources(
      item,
      ep,
      (status) {
        if (mounted) {
          setState(
            () => _statusMessage = PlayerScreen.sanitizeStatusMessage(status),
          );
        }
      },
    );

    if (!mounted) return;
    if (sources.isEmpty) {
      setState(() {
        _resolving = false;
        _buffering = false;
        _error =
            'Ningún servidor respondió para T${ep.seasonNumber}·E${ep.episodeNumber}.\nPrueba el siguiente episodio o reintenta.';
      });
      return;
    }

    _activePlayables = [
      for (final s in sources)
        Playable(
          s.quality.isEmpty ? 'Servidor HD' : s.quality,
          s.url,
          headers: s.headers,
          subtitles: s.subtitles,
        ),
    ];
    if (!applyInitialSeek) _initialSeekDone = true;
    await _play(0);
  }

  Future<void> _playChannelAt(int index) async {
    if (!_hasChannels) return;
    final safeIdx =
        ((index % widget.channelList!.length) + widget.channelList!.length) %
            widget.channelList!.length;
    final ch = widget.channelList![safeIdx];
    _channelIndex = safeIdx;
    _activeTitle = ch.name;
    _activeSubtitle = ch.group;
    _tried.clear();
    _activePlayables = [
      for (final s in ch.sources)
        Playable(
          s.quality.isEmpty ? 'Señal En Vivo' : s.quality,
          s.url,
          headers: s.headers,
        ),
    ];
    if (_activePlayables.isEmpty) {
      setState(() {
        _error = 'Este canal no tiene señales disponibles.';
        _buffering = false;
      });
      return;
    }
    await _play(0);
  }

  void _startNextEpisodeCountdown({int seconds = 5}) {
    _nextCountdownTimer?.cancel();
    setState(() {
      _nextOverlayVisible = true;
      _nextCountdown = seconds;
    });
    _nextCountdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_nextCountdown <= 1) {
        t.cancel();
        _playEpisode(_episodeIndex + 1);
      } else {
        setState(() => _nextCountdown--);
      }
    });
  }

  void _cancelNextEpisodeCountdown({bool dismiss = false}) {
    _nextCountdownTimer?.cancel();
    if (mounted) {
      setState(() {
        _nextOverlayVisible = false;
        if (dismiss) _nextOverlayDismissed = true;
      });
    }
  }

  Future<void> _saveCurrentProgress({bool forceCompleted = false}) async {
    final item = widget.vodItem;
    if (item == null) return;
    final pos = _player.state.position.inSeconds.toDouble();
    final dur = _player.state.duration.inSeconds.toDouble();
    if (!forceCompleted && pos < 5) return;

    final ep = _hasEpisodes ? widget.episodeList![_episodeIndex] : null;
    await WatchHistory().record(
      item,
      seasonNumber: ep?.seasonNumber ?? 1,
      episodeNumber: ep?.episodeNumber ?? 1,
      episodeTitle: ep?.title ?? '',
      positionSec: forceCompleted && dur > 0 ? dur : pos,
      durationSec: dur > 0 ? dur : (pos + 60),
    );
  }

  void _onVideoReady() {
    if (!mounted) return;
    if (TvModeService.instance.isTv) {
      if (_isLiveChannelMode) {
        _showTvLiveBanner();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_showControls && !_tvChannelDrawerOpen) {
          _focusNode.requestFocus();
        }
      });
    } else if (_showControls) {
      _resetHideTimer();
    }
  }

  void _setShowControls(bool show) {
    if (!mounted) return;
    setState(() {
      _showControls = show;
      if (show) {
        _tvSeekBarVisible = false;
        _tvLiveBannerVisible = false;
      }
    });
    if (show) {
      _resetHideTimer();
      if (TvModeService.instance.isTv) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _showControls) {
            if (_canShowCenterPlaybackControls) {
              _playPauseFocusNode.requestFocus();
            } else {
              _focusNode.requestFocus();
            }
          }
        });
      }
    } else {
      _hideTimer?.cancel();
      if (TvModeService.instance.isTv) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_showControls && !_tvChannelDrawerOpen) {
            _focusNode.requestFocus();
          }
        });
      }
    }
  }

  void _showTvSeekBar() {
    _tvSeekBarTimer?.cancel();
    if (!mounted) return;
    if (!_tvSeekBarVisible) {
      setState(() => _tvSeekBarVisible = true);
    }
    _tvSeekBarTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _tvSeekBarVisible = false);
    });
  }

  void _showTvLiveBanner() {
    _tvLiveBannerTimer?.cancel();
    if (!mounted) return;
    setState(() => _tvLiveBannerVisible = true);
    _tvLiveBannerTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _tvLiveBannerVisible = false);
    });
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    if (_isLocked) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying && _hasVideo && _error == null) {
        _setShowControls(false);
      }
    });
  }

  void _toggleControls() {
    if (_isLocked) {
      setState(() => _showControls = !_showControls);
      return;
    }
    _setShowControls(!_showControls);
  }

  void _showHudToast(String text) {
    _hudToastTimer?.cancel();
    setState(() => _hudToast = text);
    _hudToastTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _hudToast = null);
    });
  }

  Future<void> _syncRemoteTvState() async {
    await TvRemoteService.instance.reportTvPlayback(
      isPlaying: _player.state.playing,
      title: _activeTitle,
      subtitle: widget.subtitle,
      poster: widget.posterUrl,
      isLive: !_isVodMode,
      positionSec: _player.state.position.inSeconds,
      durationSec: _player.state.duration.inSeconds,
      volume: _player.state.volume.round().clamp(0, 100),
      episodeIndex: _hasEpisodes ? _episodeIndex : 0,
      episodeCount: _hasEpisodes ? widget.episodeList!.length : 0,
      speed: _player.state.rate,
    );
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  void _handleRemoteCommand(TvRemoteCommand cmd) {
    if (!mounted) return;
    switch (cmd.action) {
      case 'toggle_play':
        _player.playOrPause();
        _showHudToast(_player.state.playing ? 'Pausa' : 'Reproduciendo');
        unawaited(_syncRemoteTvState());
        break;
      case 'pause':
        _player.pause();
        _showHudToast('Pausado desde tu celular');
        unawaited(_syncRemoteTvState());
        break;
      case 'play':
        _player.play();
        _showHudToast('Reproduciendo');
        unawaited(_syncRemoteTvState());
        break;
      case 'seek_relative':
        final sec = (cmd.payload['seconds'] as num?)?.toInt() ?? 10;
        _seekRelative(sec);
        unawaited(_syncRemoteTvState());
        break;
      case 'volume_delta':
        final delta = (cmd.payload['delta'] as num?)?.toDouble() ?? 10;
        final nextVol = (_player.state.volume + delta).clamp(0.0, 100.0);
        _player.setVolume(nextVol);
        _showHudToast('Volumen: ${nextVol.round()}%');
        unawaited(_syncRemoteTvState());
        break;
      case 'next_channel':
        if (_hasChannels) {
          _playChannelAt((_channelIndex + 1) % widget.channelList!.length);
        }
        break;
      case 'prev_channel':
        if (_hasChannels) {
          final len = widget.channelList!.length;
          _playChannelAt((_channelIndex - 1 + len) % len);
        }
        break;
      case 'next_episode':
        if (_hasEpisodes && _episodeIndex + 1 < widget.episodeList!.length) {
          _playEpisode(_episodeIndex + 1);
        }
        break;
      case 'dpad_left':
        _seekRelative(-10);
        unawaited(_syncRemoteTvState());
        break;
      case 'dpad_right':
        _seekRelative(10);
        unawaited(_syncRemoteTvState());
        break;
      case 'dpad_center':
      case 'select':
        _player.playOrPause();
        _showHudToast(_player.state.playing ? 'Pausa' : 'Reproduciendo');
        unawaited(_syncRemoteTvState());
        break;
      case 'dpad_up':
      case 'dpad_down':
        _toggleControls();
        break;
      case 'seek_absolute':
        final posSec = (cmd.payload['positionSec'] as num?)?.toInt() ?? 0;
        final target = Duration(
            seconds: posSec.clamp(0, _player.state.duration.inSeconds));
        _player.seek(target);
        _showHudToast('${_fmtDuration(target)} ⏩');
        unawaited(_syncRemoteTvState());
        break;
      case 'set_speed':
        final spd = (cmd.payload['speed'] as num?)?.toDouble() ?? 1.0;
        final clamped = spd.clamp(0.25, 3.0);
        _player.setRate(clamped);
        _showHudToast(
            '${clamped == clamped.truncateToDouble() ? clamped.toInt() : clamped}x ⏩');
        unawaited(_syncRemoteTvState());
        break;
      case 'prev_episode':
        if (_hasEpisodes && _episodeIndex > 0) {
          _playEpisode(_episodeIndex - 1);
        }
        break;
      case 'back':
      case 'stop':
        Navigator.of(context).maybePop();
        break;
    }
  }

  void _seekRelative(int seconds, {bool showMinimalTvBar = false}) {
    if (!_isVodMode) return;
    final cur = _player.state.position;
    final dur = _player.state.duration;
    var next = cur + Duration(seconds: seconds);
    if (next < Duration.zero) next = Duration.zero;
    if (dur > Duration.zero && next > dur) next = dur;
    _player.seek(next);

    final newDir = seconds >= 0 ? 1 : -1;
    setState(() {
      _seekRippleAccum =
          (_seekRippleDir == newDir ? _seekRippleAccum : 0) + seconds.abs();
      _seekRippleDir = newDir;
    });
    _seekRippleTimer?.cancel();
    _seekRippleTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() {
          _seekRippleDir = 0;
          _seekRippleAccum = 0;
        });
      }
    });
    if (showMinimalTvBar && !_showControls) {
      _showTvSeekBar();
    } else if (_showControls) {
      _resetHideTimer();
    }
  }

  void _skipIntro() {
    final sec = AppSettingsService.instance.skipIntroSeconds;
    _seekRelative(sec);
    setState(() => _introSkipped = true);
    _showHudToast('Intro omitida (+${sec}s)');
  }

  void _toggleOrientation() {
    if (TvModeService.instance.isTv) return;
    setState(() => _isLandscape = !_isLandscape);
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
    _resetHideTimer();
  }

  void _cycleAspectFit() {
    setState(() {
      if (_fit == BoxFit.contain) {
        _fit = BoxFit.cover;
        _showHudToast('Ajuste: Pantalla llena');
      } else if (_fit == BoxFit.cover) {
        _fit = BoxFit.fill;
        _showHudToast('Ajuste: Expandido');
      } else {
        _fit = BoxFit.contain;
        _showHudToast('Ajuste: Original');
      }
    });
    _resetHideTimer();
  }

  void _retryCurrent() {
    _tried.clear();
    if (_activePlayables.isNotEmpty) {
      _play(0);
    } else if (_hasEpisodes) {
      _playEpisode(_episodeIndex);
    } else if (widget.vodItem != null) {
      _resolveAndPlayVodItem(widget.vodItem!);
    } else if (_hasChannels) {
      _playChannelAt(_channelIndex);
    }
  }

  String _fmt(Duration d) {
    if (d <= Duration.zero) return '0:00';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  @override
  void dispose() {
    _saveCurrentProgress();
    _hideTimer?.cancel();
    _tvSeekBarTimer?.cancel();
    _tvLiveBannerTimer?.cancel();
    _stallTimer?.cancel();
    _hudToastTimer?.cancel();
    _seekRippleTimer?.cancel();
    _nextCountdownTimer?.cancel();
    _preloadTriggerTimer?.cancel();
    _progressSaveTimer?.cancel();
    NextEpisodePreloader.instance.cancel();
    if (_activeProxySessionId != null) {
      HlsStreamProxy.instance.releaseSession(_activeProxySessionId);
      _activeProxySessionId = null;
    }
    for (final s in _subs) {
      s.cancel();
    }
    _focusNode.dispose();
    _playPauseFocusNode.dispose();
    _scrubberFocusNode.dispose();
    if (TvModeService.instance.isTv) {
      // Solo desregistra si el handler sigue siendo el suyo: cuando el celular
      // lanza contenido, este dispose llega después del initState del
      // reproductor nuevo y le robaba el control remoto (stop/pausa/volumen).
      TvRemoteService.instance.unregisterActivePlayerHandler(
        _handleRemoteCommand,
      );
      unawaited(TvRemoteService.instance.clearTvPlayback());
    }
    DeviceControlService.setKeepScreenOn(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!TvModeService.instance.isTv) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    final p = _player;
    Future.microtask(() async {
      try {
        await p.stop();
        await p.dispose();
      } catch (_) {}
      // Ya liberó el decodificador: TV en Vivo puede crear el suyo.
      FullscreenPlaybackCoordinator.instance.end();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(context);
    final isTv = TvModeService.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (isTv && _tvChannelDrawerOpen) {
          setState(() => _tvChannelDrawerOpen = false);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focusNode.requestFocus();
          });
          return;
        }
        if (isTv && _showControls && _error == null && !_resolving) {
          _setShowControls(false);
          return;
        }
        Navigator.of(context).pop(
          _hasChannels ? widget.channelList![_channelIndex] : null,
        );
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (node, ev) {
            final isDown = ev is KeyDownEvent;
            final isRepeat = ev is KeyRepeatEvent;
            if (!isDown && !isRepeat) return KeyEventResult.ignored;
            final key = ev.logicalKey;

            // Mini-guía de canales abierta en TV
            if (_tvChannelDrawerOpen) {
              if (isDown &&
                  (key == LogicalKeyboardKey.arrowRight ||
                      key == LogicalKeyboardKey.escape ||
                      key == LogicalKeyboardKey.goBack)) {
                setState(() => _tvChannelDrawerOpen = false);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _focusNode.requestFocus();
                });
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            }

            // Teclas multimedia dedicadas de controles Android TV / Onn
            if (isDown &&
                (key == LogicalKeyboardKey.mediaPlayPause ||
                    key == LogicalKeyboardKey.space)) {
              _player.playOrPause();
              if (!_showControls) {
                if (_isVodMode) {
                  _setShowControls(true);
                } else {
                  _showHudToast(
                    _player.state.playing ? 'Pausa' : 'Reproduciendo',
                  );
                }
              } else {
                _resetHideTimer();
              }
              return KeyEventResult.handled;
            }
            if (isDown && key == LogicalKeyboardKey.mediaPlay) {
              _player.play();
              _resetHideTimer();
              return KeyEventResult.handled;
            }
            if (isDown && key == LogicalKeyboardKey.mediaPause) {
              _player.pause();
              if (!_showControls && _isVodMode) _setShowControls(true);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.mediaFastForward) {
              _seekRelative(10, showMinimalTvBar: isTv);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.mediaRewind) {
              _seekRelative(-10, showMinimalTvBar: isTv);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.channelUp && _hasChannels) {
              final next = (_channelIndex + 1) % widget.channelList!.length;
              _playChannelAt(next);
              if (isTv) _showTvLiveBanner();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.channelDown && _hasChannels) {
              final len = widget.channelList!.length;
              final prev = (_channelIndex - 1 + len) % len;
              _playChannelAt(prev);
              if (isTv) _showTvLiveBanner();
              return KeyEventResult.handled;
            }

            // Con controles completos visibles: navegar botones con D-pad
            if (_showControls) {
              if (isDown &&
                  (key == LogicalKeyboardKey.escape ||
                      key == LogicalKeyboardKey.goBack)) {
                _setShowControls(false);
                return KeyEventResult.handled;
              }
              _resetHideTimer();
              return KeyEventResult.ignored;
            }

            // Con controles ocultos (pantalla completa pura sin iconos):
            if (_isLiveChannelMode) {
              if (key == LogicalKeyboardKey.arrowDown) {
                final next = (_channelIndex + 1) % widget.channelList!.length;
                _playChannelAt(next);
                _showTvLiveBanner();
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowUp) {
                final len = widget.channelList!.length;
                final prev = (_channelIndex - 1 + len) % len;
                _playChannelAt(prev);
                _showTvLiveBanner();
                return KeyEventResult.handled;
              }
              if (isRepeat) return KeyEventResult.handled;
              if (key == LogicalKeyboardKey.select ||
                  key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.numpadEnter ||
                  key == LogicalKeyboardKey.arrowLeft) {
                setState(() {
                  _tvChannelDrawerOpen = true;
                  _tvLiveBannerVisible = false;
                });
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowRight) {
                _cycleAspectFit();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            }

            // VOD (Películas / Series / Anime) en pantalla completa pura:
            // ◀ / ▶ (pulsación simple o mantenida) adelanta/atrasa ±10s con barra limpia
            if (key == LogicalKeyboardKey.arrowRight) {
              _seekRelative(10, showMinimalTvBar: isTv);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowLeft) {
              _seekRelative(-10, showMinimalTvBar: isTv);
              return KeyEventResult.handled;
            }
            if (isRepeat) return KeyEventResult.handled;

            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter) {
              if (_canShowCenterPlaybackControls) {
                _player.playOrPause();
              }
              _setShowControls(true);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowUp ||
                key == LogicalKeyboardKey.arrowDown) {
              _setShowControls(true);
              return KeyEventResult.handled;
            }

            return KeyEventResult.ignored;
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Lienzo de video real aislado en RepaintBoundary
              RepaintBoundary(
                child: Center(
                  child: Video(
                    controller: _controller,
                    fit: _fit,
                    controls: NoVideoControls,
                    subtitleViewConfiguration: const SubtitleViewConfiguration(
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        shadows: [
                          Shadow(
                            color: Colors.black,
                            blurRadius: 8,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      padding: EdgeInsets.fromLTRB(24, 0, 24, 34),
                    ),
                  ),
                ),
              ),

              // 2. Capa táctil de gestos (tap / doble tap ±10s / brillo & volumen)
              if (_error == null) _buildGestureLayer(),

              // 3. Ripple doble toque ±10s
              if (_seekRippleDir != 0) _buildSeekRippleOverlay(),

              // 4. Indicador vertical brillo / volumen
              if (_draggingBrightness || _draggingVolume)
                _buildVerticalGaugeOverlay(accent),

              // 5. Pantalla de carga cinematográfica limpia (póster difuminado + estado real)
              if (_error == null && (_resolving || !_hasVideo))
                _buildLoadingOverlay(accent),

              // 6. Spinner sutil de re-buffering mientras ya hay video
              if (_error == null && _hasVideo && _buffering && !_resolving)
                const Center(
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.6,
                    ),
                  ),
                ),

              // 7. Tarjeta de error limpia (NUNCA cubierta por botones de Play)
              if (_error != null) _buildErrorOverlay(accent),

              // 8. Controles flotantes minimalistas estilo Inútil Music
              if (_showControls)
                _isLocked
                    ? _buildLockedOverlay()
                    : _buildCinemaControls(accent),

              // 8b. Barra minimalista de adelanto/retroceso en Smart TV (sin iconos)
              if (isTv &&
                  !_showControls &&
                  _tvSeekBarVisible &&
                  _isVodMode &&
                  _error == null)
                _buildMinimalTvSeekBar(accent),

              // 8c. Banner minimalista de cambio de canal en Smart TV (sin iconos)
              if (isTv &&
                  !_showControls &&
                  !_tvChannelDrawerOpen &&
                  _tvLiveBannerVisible &&
                  _isLiveChannelMode &&
                  _error == null)
                _buildMinimalTvLiveBanner(),

              // 8d. Mini-guía lateral de canales para Smart TV en PlayerScreen
              if (isTv && _tvChannelDrawerOpen && _hasChannels)
                _buildTvChannelsDrawer(),

              // 9. Botón flotante "Omitir Intro"
              if (_hasEpisodes &&
                  _hasVideo &&
                  !_introSkipped &&
                  !_isLocked &&
                  _error == null &&
                  _player.state.position > const Duration(seconds: 5) &&
                  _player.state.position < const Duration(minutes: 3))
                Positioned(
                  right: 22,
                  bottom: _showControls ? 96 : 28,
                  child: _glassPillButton(
                    icon: Icons.fast_forward_rounded,
                    label: 'Omitir intro',
                    onTap: _skipIntro,
                  ),
                ),

              // 10. Tarjeta "Siguiente episodio" en vidrio oscuro (cuenta regresiva 5s)
              if (_nextOverlayVisible && _hasNextEpisode && _error == null)
                Positioned(
                  right: 22,
                  bottom: _showControls ? 96 : 26,
                  child: _buildNextEpisodeCard(),
                ),

              // 11. Toast flotante superior minimalista
              if (_hudToast != null)
                Positioned(
                  top: 66,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF121318).withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            _hudToast!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGestureLayer() {
    return LayoutBuilder(
      builder: (context, box) {
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _toggleControls,
          onDoubleTapDown: (details) {
            if (_isLocked || !_hasVideo || !_isVodMode) return;
            final dx = details.localPosition.dx;
            if (dx < box.maxWidth * 0.42) {
              _seekRelative(-10);
            } else if (dx > box.maxWidth * 0.58) {
              _seekRelative(10);
            } else {
              _player.playOrPause();
            }
          },
          onVerticalDragStart: (d) {
            if (_isLocked || !_hasVideo) return;
            if (d.localPosition.dx < box.maxWidth / 2) {
              _draggingBrightness = true;
            } else {
              _draggingVolume = true;
            }
          },
          onVerticalDragUpdate: (d) {
            if (_isLocked || !_hasVideo) return;
            final delta = -d.delta.dy / 220.0;
            if (_draggingBrightness) {
              setState(() {
                _brightnessVal = (_brightnessVal + delta).clamp(0.05, 1.0);
              });
              DeviceControlService.setBrightness(_brightnessVal);
            } else if (_draggingVolume) {
              setState(() {
                _volumeVal = (_volumeVal + delta).clamp(0.0, 1.0);
              });
              _player.setVolume(_volumeVal * 100);
            }
          },
          onVerticalDragEnd: (_) {
            if (_draggingBrightness || _draggingVolume) {
              setState(() {
                _draggingBrightness = false;
                _draggingVolume = false;
              });
            }
          },
          child: const SizedBox.expand(),
        );
      },
    );
  }

  Widget _buildSeekRippleOverlay() {
    final isRight = _seekRippleDir > 0;
    return Align(
      alignment: isRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 56),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.16),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isRight
                    ? Icons.fast_forward_rounded
                    : Icons.fast_rewind_rounded,
                color: Colors.white,
                size: 24,
              ),
              const SizedBox(width: 6),
              Text(
                '${isRight ? "+" : "-"}${_seekRippleAccum}s',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerticalGaugeOverlay(Color accent) {
    final isB = _draggingBrightness;
    final val = isB ? _brightnessVal : _volumeVal;
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: 152,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF101116).withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.14),
                width: 0.8,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isB
                      ? Icons.brightness_6_rounded
                      : (val <= 0.01
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded),
                  color: Colors.white,
                  size: 24,
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: val,
                    minHeight: 4,
                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                    valueColor: AlwaysStoppedAnimation(accent),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${(val * 100).round()}%',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pantalla de carga minimalista y elegante (póster difuminado + progreso honesto)
  Widget _buildLoadingOverlay(Color accent) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.posterUrl.isNotEmpty)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Opacity(
              opacity: 0.28,
              child: FastArtwork(
                url:
                    widget.posterUrl.startsWith('http') ? widget.posterUrl : '',
                localFilePath: widget.posterUrl.startsWith('http')
                    ? null
                    : widget.posterUrl,
                tier: ArtworkTier.backdrop,
                cacheWidth: 540,
                fit: BoxFit.cover,
                errorWidget: const SizedBox.shrink(),
              ),
            ),
          ),
        Container(color: const Color(0xFF070709).withValues(alpha: 0.72)),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  color: accent,
                  strokeWidth: 2.6,
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _activeTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Tarjeta de error sobria en vidrio obsidiana — NUNCA tapada por botones Play
  Widget _buildErrorOverlay(Color accent) {
    return Container(
      color: const Color(0xFF070709).withValues(alpha: 0.94),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF101116),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 0.9,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.wifi_off_rounded,
                  color: Colors.white70,
                  size: 24,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'No se pudo reproducir el video',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.25,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? '',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
              if (NetworkConfigService.instance.playbackHint != null) ...[
                const SizedBox(height: 10),
                Text(
                  NetworkConfigService.instance.playbackHint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF34D399),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TvFocusable(
                    autofocus: TvModeService.of(context),
                    focusColor: const Color(0xFF38BDF8),
                    borderRadius: BorderRadius.circular(24),
                    descendantsAreFocusable: false,
                    descendantsAreTraversable: false,
                    onTap: _retryCurrent,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.playbackPrimaryBackground,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.refresh_rounded,
                            color: AppColors.playbackPrimaryForeground,
                            size: 18,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Reintentar',
                            style: TextStyle(
                              color: AppColors.playbackPrimaryForeground,
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  TvFocusable(
                    focusColor: const Color(0xFF38BDF8),
                    borderRadius: BorderRadius.circular(22),
                    descendantsAreFocusable: false,
                    descendantsAreTraversable: false,
                    onTap: () => Navigator.of(context).pop(
                      _hasChannels ? widget.channelList![_channelIndex] : null,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.24),
                        ),
                      ),
                      child: const Text(
                        'Volver',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLockedOverlay() {
    return SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _glassPillButton(
            icon: Icons.lock_open_rounded,
            label: 'Desbloquear',
            onTap: () {
              setState(() {
                _isLocked = false;
                _showControls = true;
              });
              _resetHideTimer();
            },
          ),
        ),
      ),
    );
  }

  /// Barra inferior minimalista solo para adelantar/atrasar con ◀/▶ en Smart TV
  /// (cero iconos ni botones tapando la película; se oculta sola en 2.2s).
  Widget _buildMinimalTvSeekBar(Color accent) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(36, 28, 36, 24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: 0.85),
                Colors.transparent,
              ],
            ),
          ),
          child: StreamBuilder<Duration>(
            stream: _player.stream.position,
            initialData: _player.state.position,
            builder: (context, snap) {
              final pos = snap.data ?? Duration.zero;
              final dur = _player.state.duration;
              final ratio = dur.inMilliseconds > 0
                  ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                  : 0.0;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _activeTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        '${_fmt(pos)}  /  ${dur > Duration.zero ? _fmt(dur) : '--:--'}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 5,
                      backgroundColor: Colors.white.withValues(alpha: 0.22),
                      valueColor: const AlwaysStoppedAnimation(
                        Color(0xFF38BDF8),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Banner minimalista de cambio de canal en Smart TV (sin iconos; se oculta solo).
  Widget _buildMinimalTvLiveBanner() {
    final chNum = '${_channelIndex + 1}'.padLeft(3, '0');
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(32, 30, 32, 24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: 0.86),
                Colors.transparent,
              ],
            ),
          ),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.55),
                  ),
                ),
                child: Text(
                  '#$chNum',
                  style: const TextStyle(
                    color: Color(0xFF38BDF8),
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _activeTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.liveRed,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: const Text(
                            'EN VIVO',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (_detectedQuality.isNotEmpty) ...[
                          const SizedBox(width: 7),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              _detectedQuality,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_activeSubtitle  ·  ▲▼ Cambiar canal  ·  OK Guía  ·  ▶ Ajuste  ·  Atrás Salir',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.68),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Mini-guía lateral translúcida de canales en PlayerScreen para Smart TV.
  Widget _buildTvChannelsDrawer() {
    final chs = widget.channelList!;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: 340,
        height: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFF0A0B0F).withValues(alpha: 0.92),
          border: Border(
            right: BorderSide(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Canales en Vivo',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    '${chs.length} canales',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: ListView.builder(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                itemCount: chs.length,
                itemBuilder: (_, i) {
                  final ch = chs[i];
                  final active = i == _channelIndex;
                  return TvFocusable(
                    autofocus: active,
                    descendantsAreFocusable: false,
                    descendantsAreTraversable: false,
                    focusColor: const Color(0xFF38BDF8),
                    focusScale: 1.015,
                    borderRadius: BorderRadius.circular(12),
                    margin: const EdgeInsets.only(bottom: 6),
                    onTap: () {
                      setState(() => _tvChannelDrawerOpen = false);
                      if (!active) _playChannelAt(i);
                      _showTvLiveBanner();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _focusNode.requestFocus();
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.16)
                            : Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: active
                              ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.08),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 32,
                            child: Text(
                              '${i + 1}'.padLeft(3, '0'),
                              style: TextStyle(
                                color: active
                                    ? const Color(0xFF38BDF8)
                                    : Colors.white54,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              ch.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: active ? Colors.white : Colors.white70,
                                fontSize: 13.5,
                                fontWeight:
                                    active ? FontWeight.w800 : FontWeight.w600,
                              ),
                            ),
                          ),
                          if (active)
                            const Icon(
                              Icons.equalizer_rounded,
                              color: Color(0xFF38BDF8),
                              size: 18,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Controles flotantes cinematográficos (estética sobria Inútil Music)
  Widget _buildCinemaControls(Color accent) {
    final isTv = TvModeService.of(context);
    return Stack(
      children: [
        // Viñetas sutiles arriba y abajo
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.72),
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.84),
                  ],
                  stops: const [0.0, 0.24, 0.68, 1.0],
                ),
              ),
            ),
          ),
        ),

        // Barra superior
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 14, 0),
            child: Row(
              children: [
                _iconCircle(
                  icon: Icons.arrow_back_rounded,
                  onTap: () => Navigator.of(context).pop(
                    _hasChannels ? widget.channelList![_channelIndex] : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _activeTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          if (_detectedQuality.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                _detectedQuality,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (_activeSubtitle.isNotEmpty)
                        Text(
                          _activeSubtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_hasChannels)
                  _iconCircle(
                    icon: Icons.list_rounded,
                    tooltip: 'Canales',
                    onTap: _openChannelsSheet,
                  ),
                if (_activePlayables.length > 1)
                  _iconCircle(
                    icon: Icons.dns_outlined,
                    tooltip: 'Servidores',
                    onTap: _openServersSheet,
                  ),
                if (_isVodMode) ...[
                  _iconCircle(
                    icon: Icons.speed_rounded,
                    tooltip: 'Velocidad',
                    onTap: _openSpeedSheet,
                  ),
                  _iconCircle(
                    icon: Icons.subtitles_outlined,
                    tooltip: 'Audio y subtítulos',
                    onTap: _openTracksSheet,
                  ),
                ],
                ListenableBuilder(
                  listenable: SleepTimerService.instance,
                  builder: (context, _) {
                    final timer = SleepTimerService.instance;
                    return Tooltip(
                      message: timer.isActive
                          ? 'Sueño: ${timer.shortLabel}'
                          : 'Temporizador de sueño',
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: TvFocusable(
                          focusColor: const Color(0xFF38BDF8),
                          borderRadius: BorderRadius.circular(19),
                          descendantsAreFocusable: false,
                          descendantsAreTraversable: false,
                          onTap: () {
                            InutilSleepTimerSheet.show(
                              context,
                              showEndOfEpisode: _hasEpisodes,
                            );
                            _resetHideTimer();
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: timer.isActive
                                  ? accent.withValues(alpha: 0.24)
                                  : Colors.black.withValues(alpha: 0.38),
                              borderRadius: BorderRadius.circular(19),
                              border: Border.all(
                                color: timer.isActive
                                    ? accent.withValues(alpha: 0.7)
                                    : Colors.white.withValues(alpha: 0.14),
                                width: 0.7,
                              ),
                            ),
                            padding: EdgeInsets.symmetric(
                              horizontal: timer.isActive ? 10 : 9,
                              vertical: 9,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                InutilIcon(
                                  InutilGlyph.sleepTimer,
                                  size: 18,
                                  color: timer.isActive ? accent : Colors.white,
                                  filled: timer.isActive,
                                ),
                                if (timer.isActive) ...[
                                  const SizedBox(width: 5),
                                  Text(
                                    timer.shortLabel,
                                    style: TextStyle(
                                      color: accent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (!isTv) ...[
                  _iconCircle(
                    icon: Icons.lock_outline_rounded,
                    tooltip: 'Bloquear pantalla',
                    onTap: () => setState(() => _isLocked = true),
                  ),
                  _iconCircle(
                    icon: Icons.screen_rotation_rounded,
                    tooltip: 'Rotar',
                    onTap: _toggleOrientation,
                  ),
                ],
              ],
            ),
          ),
        ),

        // Controles centrales: SOLO si el video está reproduciéndose sin errores ni carga!
        if (_canShowCenterPlaybackControls)
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isVodMode) ...[
                  _centerSecondaryBtn(
                    icon: Icons.replay_10_rounded,
                    onTap: () => _seekRelative(-10),
                  ),
                  const SizedBox(width: 28),
                ] else if (_hasChannels) ...[
                  _centerSecondaryBtn(
                    icon: Icons.skip_previous_rounded,
                    onTap: () => _playChannelAt(_channelIndex - 1),
                  ),
                  const SizedBox(width: 28),
                ],
                // Botón Play/Pausa blanco puro minimalista (100% enfocable con D-pad en TV)
                TvFocusable(
                  focusNode: _playPauseFocusNode,
                  focusColor: const Color(0xFF38BDF8),
                  focusBorderWidth: 3.2,
                  focusScale: 1.08,
                  borderRadius: BorderRadius.circular(36),
                  descendantsAreFocusable: false,
                  descendantsAreTraversable: false,
                  onTap: () {
                    _player.playOrPause();
                    _resetHideTimer();
                  },
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.playbackPrimaryBackground,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.48),
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Icon(
                      _isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: AppColors.playbackPrimaryForeground,
                      size: 36,
                    ),
                  ),
                ),
                if (_isVodMode) ...[
                  const SizedBox(width: 28),
                  _centerSecondaryBtn(
                    icon: Icons.forward_10_rounded,
                    onTap: () => _seekRelative(10),
                  ),
                ] else if (_hasChannels) ...[
                  const SizedBox(width: 28),
                  _centerSecondaryBtn(
                    icon: Icons.skip_next_rounded,
                    onTap: () => _playChannelAt(_channelIndex + 1),
                  ),
                ],
              ],
            ),
          ),

        // Barra inferior (scrubber + episodios + ajuste)
        if (_error == null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isVodMode) _buildProgressBar(accent),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _glassPillButton(
                          icon: Icons.aspect_ratio_rounded,
                          label: _fit == BoxFit.contain
                              ? 'Original'
                              : (_fit == BoxFit.cover ? 'Lleno' : 'Expandido'),
                          onTap: _cycleAspectFit,
                        ),
                        const Spacer(),
                        if (_hasEpisodes) ...[
                          if (_episodeIndex > 0)
                            _iconCircle(
                              icon: Icons.skip_previous_rounded,
                              onTap: () => _playEpisode(_episodeIndex - 1),
                            ),
                          const SizedBox(width: 6),
                          _glassPillButton(
                            icon: Icons.video_library_outlined,
                            label:
                                'Ep. ${widget.episodeList![_episodeIndex].episodeNumber}',
                            onTap: _openEpisodesSheet,
                          ),
                          if (_hasNextEpisode) ...[
                            const SizedBox(width: 6),
                            ValueListenableBuilder<NextEpisodePreloadState>(
                              valueListenable:
                                  NextEpisodePreloader.instance.state,
                              builder: (_, ps, __) {
                                final nextEp =
                                    widget.episodeList![_episodeIndex + 1];
                                final isNextReady = widget.vodItem != null &&
                                    ps.matches(widget.vodItem!.id, nextEp) &&
                                    ps.isReady;
                                return Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    _iconCircle(
                                      icon: Icons.skip_next_rounded,
                                      tooltip: isNextReady
                                          ? 'Siguiente precargado (instantáneo)'
                                          : 'Siguiente episodio',
                                      onTap: () =>
                                          _playEpisode(_episodeIndex + 1),
                                    ),
                                    if (isNextReady)
                                      Positioned(
                                        right: -1,
                                        top: -1,
                                        child: Container(
                                          width: 10,
                                          height: 10,
                                          decoration: const BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Color(0xFF34D399),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ],
                          const Spacer(),
                        ],
                        if (!_isVodMode)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.liveRed.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: AppColors.liveRed.withValues(alpha: 0.5),
                                width: 0.7,
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 3,
                                  backgroundColor: AppColors.liveRed,
                                ),
                                SizedBox(width: 5),
                                Text(
                                  'EN VIVO',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(width: 8),
                        _iconCircle(
                          icon: _volumeVal <= 0.01
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          onTap: () {
                            setState(() {
                              _volumeVal = _volumeVal > 0.01 ? 0.0 : 1.0;
                            });
                            _player.setVolume(_volumeVal * 100);
                            _resetHideTimer();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildProgressBar(Color accent) {
    final isTv = TvModeService.of(context);
    return StreamBuilder<Duration>(
      stream: _player.stream.position,
      initialData: _player.state.position,
      builder: (context, posSnap) {
        final pos = _scrubbingMs != null
            ? Duration(milliseconds: _scrubbingMs!.round())
            : (posSnap.data ?? Duration.zero);
        final dur = _player.state.duration;
        final maxSec =
            dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
        final val = pos.inMilliseconds.clamp(0, maxSec.toInt()).toDouble();

        final sliderWidget = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: _scrubberFocused ? 5.0 : 3.2,
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: _scrubberFocused ? 8.5 : 6.5,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor:
                _scrubberFocused ? const Color(0xFF38BDF8) : accent,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
            thumbColor:
                _scrubberFocused ? const Color(0xFF38BDF8) : Colors.white,
            overlayColor: Colors.white.withValues(alpha: 0.14),
          ),
          child: Slider(
            value: val,
            min: 0,
            max: maxSec,
            onChangeStart: (v) {
              _hideTimer?.cancel();
              setState(() => _scrubbingMs = v);
            },
            onChanged: (v) {
              setState(() => _scrubbingMs = v);
            },
            onChangeEnd: (v) {
              setState(() => _scrubbingMs = null);
              _player.seek(Duration(milliseconds: v.round()));
              _resetHideTimer();
            },
          ),
        );

        return Column(
          children: [
            if (isTv)
              Focus(
                focusNode: _scrubberFocusNode,
                descendantsAreFocusable: false,
                descendantsAreTraversable: false,
                onFocusChange: (f) {
                  if (_scrubberFocused != f) {
                    setState(() => _scrubberFocused = f);
                  }
                },
                onKeyEvent: (node, ev) {
                  if (ev is! KeyDownEvent && ev is! KeyRepeatEvent) {
                    return KeyEventResult.ignored;
                  }
                  if (ev.logicalKey == LogicalKeyboardKey.arrowRight) {
                    _seekRelative(10);
                    return KeyEventResult.handled;
                  }
                  if (ev.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _seekRelative(-10);
                    return KeyEventResult.handled;
                  }
                  if (ev is KeyDownEvent &&
                      (ev.logicalKey == LogicalKeyboardKey.select ||
                          ev.logicalKey == LogicalKeyboardKey.enter)) {
                    _player.playOrPause();
                    _resetHideTimer();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: _scrubberFocused
                      ? BoxDecoration(
                          color:
                              const Color(0xFF38BDF8).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFF38BDF8),
                            width: 1.6,
                          ),
                        )
                      : null,
                  child: sliderWidget,
                ),
              )
            else
              sliderWidget,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _fmt(pos),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (isTv && _scrubberFocused)
                    const Text(
                      '◀ -10s  ·  ▶ +10s',
                      style: TextStyle(
                        color: Color(0xFF38BDF8),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  Text(
                    dur > Duration.zero ? _fmt(dur) : '--:--',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNextEpisodeCard() {
    final nextEp = widget.episodeList![_episodeIndex + 1];
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: 278,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF101116).withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 0.9,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<NextEpisodePreloadState>(
                valueListenable: NextEpisodePreloader.instance.state,
                builder: (_, ps, __) {
                  final ready = widget.vodItem != null &&
                      ps.matches(widget.vodItem!.id, nextEp) &&
                      ps.isReady;
                  return Row(
                    children: [
                      Text(
                        'Siguiente en ${_nextCountdown}s',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (ready) ...[
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF34D399).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            '⚡ Instantáneo',
                            style: TextStyle(
                              color: Color(0xFF34D399),
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 4),
              Text(
                'T${nextEp.seasonNumber} · Ep. ${nextEp.episodeNumber} — ${nextEp.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Material(
                      color: AppColors.playbackPrimaryBackground,
                      borderRadius: BorderRadius.circular(24),
                      child: InkWell(
                        onTap: () => _playEpisode(_episodeIndex + 1),
                        borderRadius: BorderRadius.circular(24),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Center(
                            child: Text(
                              'Reproducir ahora',
                              style: TextStyle(
                                color: AppColors.playbackPrimaryForeground,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => _cancelNextEpisodeCountdown(dismiss: true),
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.white70),
                    child: const Text('Cancelar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconCircle({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final btn = Padding(
      padding: const EdgeInsets.only(left: 4),
      child: TvFocusable(
        focusColor: const Color(0xFF38BDF8),
        focusScale: 1.08,
        borderRadius: BorderRadius.circular(20),
        descendantsAreFocusable: false,
        descendantsAreTraversable: false,
        onTap: () {
          onTap();
          _resetHideTimer();
        },
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.44),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.16),
              width: 0.8,
            ),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: btn) : btn;
  }

  Widget _centerSecondaryBtn({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return TvFocusable(
      focusColor: const Color(0xFF38BDF8),
      focusScale: 1.08,
      borderRadius: BorderRadius.circular(26),
      descendantsAreFocusable: false,
      descendantsAreTraversable: false,
      onTap: onTap,
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.48),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 0.9,
          ),
        ),
        child: Icon(icon, color: Colors.white, size: 28),
      ),
    );
  }

  Widget _glassPillButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return TvFocusable(
      focusColor: const Color(0xFF38BDF8),
      focusScale: 1.05,
      borderRadius: BorderRadius.circular(20),
      descendantsAreFocusable: false,
      descendantsAreTraversable: false,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF14151C).withValues(alpha: 0.84),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.16),
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Hojas de opciones sobrias (Servidores, Episodios, Velocidad, Pistas, Canales) ─

  Widget _sheetRow({
    required Widget title,
    Widget? leading,
    Widget? trailing,
    Widget? subtitle,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return TvFocusable(
      autofocus: active && TvModeService.instance.isTv,
      focusColor: const Color(0xFF38BDF8),
      focusScale: 1.01,
      borderRadius: BorderRadius.circular(12),
      descendantsAreFocusable: false,
      descendantsAreTraversable: false,
      margin: const EdgeInsets.only(bottom: 4),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: active
              ? Colors.white.withValues(alpha: 0.09)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  title,
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    subtitle
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  void _openServersSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.carbonSurface,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Servidores disponibles',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < _activePlayables.length; i++)
              _sheetRow(
                active: i == _current,
                leading: Icon(
                  i == _current
                      ? Icons.check_circle_rounded
                      : Icons.dns_outlined,
                  color: i == _current ? Colors.white : Colors.white54,
                ),
                title: Text(
                  PlayerScreen.publicServerLabel(i, _activePlayables[i].label),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _play(i);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openSpeedSheet() {
    const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
    final currentRate = _player.state.rate;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.carbonSurface,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Velocidad de reproducción',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            for (final s in speeds)
              _sheetRow(
                active: (currentRate - s).abs() < 0.05,
                leading: Icon(
                  (currentRate - s).abs() < 0.05
                      ? Icons.check_circle_rounded
                      : Icons.speed_rounded,
                  color: (currentRate - s).abs() < 0.05
                      ? Colors.white
                      : Colors.white54,
                ),
                title: Text(
                  s == 1.0 ? 'Normal (1.0x)' : '${s}x',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _player.setRate(s);
                  _showHudToast('Velocidad ${s}x');
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openTracksSheet() {
    final audios = _player.state.tracks.audio;
    final subs = _player.state.tracks.subtitle;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.carbonSurface,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Audio y Subtítulos',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (audios.length > 1) ...[
              const SizedBox(height: 12),
              const Text(
                'Pistas de Audio',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              for (final a in audios)
                if (a.id != 'no')
                  _sheetRow(
                    active: _player.state.track.audio.id == a.id,
                    title: Text(
                      a.title ?? a.language ?? 'Pista ${a.id}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    trailing: _player.state.track.audio.id == a.id
                        ? const Icon(Icons.check_rounded, color: Colors.white)
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _player.setAudioTrack(a);
                    },
                  ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Subtítulos',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            _sheetRow(
              active: _player.state.track.subtitle.id == 'no',
              title: const Text(
                'Desactivados',
                style: TextStyle(color: Colors.white),
              ),
              trailing: _player.state.track.subtitle.id == 'no'
                  ? const Icon(Icons.check_rounded, color: Colors.white)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _player.setSubtitleTrack(SubtitleTrack.no());
              },
            ),
            for (final s in subs)
              if (s.id != 'no' && s.id != 'auto')
                _sheetRow(
                  active: _player.state.track.subtitle.id == s.id,
                  title: Text(
                    s.title ?? s.language ?? 'Subtítulo ${s.id}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: _player.state.track.subtitle.id == s.id
                      ? const Icon(Icons.check_rounded, color: Colors.white)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    _player.setSubtitleTrack(s);
                  },
                ),
          ],
        ),
      ),
    );
  }

  void _openEpisodesSheet() {
    if (!_hasEpisodes) return;
    final eps = widget.episodeList!;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.carbonSurface,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: eps.length,
          itemBuilder: (_, i) {
            final ep = eps[i];
            final active = i == _episodeIndex;
            return _sheetRow(
              active: active,
              leading: Icon(
                active ? Icons.play_arrow_rounded : Icons.video_file_outlined,
                color: active ? Colors.white : Colors.white54,
              ),
              title: Text(
                'T${ep.seasonNumber} · Ep. ${ep.episodeNumber} — ${ep.title}',
                style: TextStyle(
                  color: active ? Colors.white : Colors.white70,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _playEpisode(i);
              },
            );
          },
        ),
      ),
    );
  }

  void _openChannelsSheet() {
    if (!_hasChannels) return;
    if (TvModeService.instance.isTv) {
      setState(() {
        _showControls = false;
        _tvChannelDrawerOpen = true;
      });
      return;
    }
    final chs = widget.channelList!;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.carbonSurface,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: chs.length,
          itemBuilder: (_, i) {
            final ch = chs[i];
            final active = i == _channelIndex;
            return _sheetRow(
              active: active,
              leading: Icon(
                active ? Icons.play_arrow_rounded : Icons.live_tv_rounded,
                color: active ? Colors.white : Colors.white54,
              ),
              title: Text(
                ch.name,
                style: TextStyle(
                  color: active ? Colors.white : Colors.white70,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
              subtitle: Text(
                ch.group,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _playChannelAt(i);
              },
            );
          },
        ),
      ),
    );
  }
}
