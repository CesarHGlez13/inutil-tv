import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide Playable;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/app_settings_service.dart';
import '../services/artwork_cache_service.dart';
import '../services/device_control_service.dart';
import '../services/fullscreen_playback_coordinator.dart';
import '../services/inutil_cloud_backup_service.dart';
import '../services/network_config_service.dart';
import '../services/sleep_timer_service.dart';
import '../services/tv_mode_service.dart';
import '../services/tv_remote_service.dart';
import '../services/xuper_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import '../widgets/fast_artwork.dart';
import '../widgets/inutil_sleep_timer_sheet.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/tv_remote_sheet.dart';
import 'player_screen.dart';

/// Pantalla "TV en Vivo" de InútilTV v3.2.1 — estilo Inútil Music:
/// - 1,183 canales verificados por bytes reales + auto-sincronización de respaldos.
/// - CERO reproducción doble al pasar a pantalla completa o al cambiar de pestaña
///   dentro de `IndexedStack` (pausa y silencia automáticamente cuando `isTabActive`
///   es `false` o la app pasa a segundo plano).
class TvScreen extends StatefulWidget {
  final Channel? initialChannel;
  final bool isTabActive;

  const TvScreen({
    super.key,
    this.initialChannel,
    this.isTabActive = true,
  });

  @override
  State<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends State<TvScreen> with WidgetsBindingObserver {
  static const _recentKey = 'inutiltv_recent_channels_v1';

  static const List<String> _sportsSubTabs = [
    'Destacados',
    'Liga MX',
    'Champions',
    'ESPN · Fox · Claro',
    'Sudamérica',
    'NFL · NBA · MLB',
    'Box · UFC',
    'F1 · Motor',
    'Todos',
  ];

  final _service = XuperService();
  final _searchCtl = TextEditingController();
  late final FocusNode _searchFocus =
      TvFocusable.createTextFieldFocusNode(controller: _searchCtl);
  final List<StreamSubscription<dynamic>> _subs = [];

  // El reproductor de TV en Vivo es *destruible*: se libera por completo
  // (no sólo se detiene) mientras hay una película a pantalla completa,
  // porque las TV Box de 2 GB (Onn 4K) apenas dejan un decodificador
  // MediaCodec libre. Si el de TV queda vivo, la película cae a
  // decodificación por software y se ve trabada.
  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription<dynamic>> _playerSubs = [];

  // Cada VideoController necesita su propia vista nativa: al crear un
  // reproductor nuevo cambiamos esta época para que Flutter re-monte <Video>.
  int _videoEpoch = 0;
  // El canal quedó sin señal porque el reproductor se destruyó (película a
  // pantalla completa / pestaña de fondo): hay que volver a sintonizarlo.
  bool _needsRetune = false;

  List<Channel> _all = [];
  List<Channel> _shown = [];
  List<String> _categories = [];
  String _selectedCategory = 'Todos';
  String _selectedSportsSub = 'Destacados';
  Set<String> _favorites = {};
  List<String> _recentIds = [];
  Channel? _currentChannel;
  int _sourceIndex = 0;
  bool _playerLoading = true;
  bool _hasVideo = false;
  String _detectedQuality = '';
  BoxFit _fit = BoxFit.contain;
  bool _showLandscapeControls = true;
  bool _isInFullscreenRoute = false;
  Timer? _landscapeHideTimer;

  // Modo pantalla completa instantánea (0 ms, sin iconos) para Smart TV / TV Box
  bool _tvFullscreen = false;
  bool _tvMiniGuideOpen = false;
  bool _tvZapBannerVisible = false;
  String? _tvFsToast;
  Timer? _tvZapBannerTimer;
  Timer? _tvFsToastTimer;
  final FocusNode _tvFullscreenFocus = FocusNode();
  final FocusNode _tvFullscreenBtnFocus = FocusNode();
  final ScrollController _channelListScroll = ScrollController();

  bool get _isSportsCategory =>
      _selectedCategory.toLowerCase().contains('deport');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _createPlayer();

    DeviceControlService.setKeepScreenOn(true);

    _subs.add(SleepTimerService.instance.onExpired.listen((reason) {
      if (!mounted) return;
      _player?.pause();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(reason), duration: const Duration(seconds: 3)),
      );
    }));

    // TV en Vivo libera TODO su reproductor mientras haya una película a
    // pantalla completa (los decodificadores MediaCodec son limitados).
    FullscreenPlaybackCoordinator.instance.isActive
        .addListener(_onFullscreenActiveChanged);

    _bootstrap();
  }

  /// Crea el reproductor de TV en Vivo con su salida de vídeo nativa.
  void _createPlayer() {
    final settings = AppSettingsService.instance;
    final isTv = TvModeService.instance.isTv;
    final useZeroCopyTv = isTv && settings.hwAcceleration;
    final player = Player(
      configuration: PlayerConfiguration(
        logLevel: MPVLogLevel.warn,
        // En TV Box de 2 GB RAM (ej. Onn 4K) evita disparar zram/swap.
        bufferSize: isTv ? 10 * 1024 * 1024 : settings.bufferSizeBytes,
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
    _player = player;
    _videoController = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        // En Smart TV / TV Box (Amlogic/ARMv7), `vo=mediacodec_embed` +
        // `hwdec=mediacodec` renderiza directo en hardware (zero-copy) evitando
        // el cuello de botella de `mediacodec-copy` (~94% CPU en un núcleo).
        vo: useZeroCopyTv ? 'mediacodec_embed' : 'gpu',
        hwdec: useZeroCopyTv
            ? 'mediacodec'
            : (settings.hwAcceleration ? 'auto-safe' : 'no'),
        enableHardwareAcceleration: settings.hwAcceleration,
        // Sin esto, tras destruir y recrear el reproductor la superficie
        // queda enganchada a la vista anterior y deja de llegar vídeo nuevo:
        // la imagen se congela aunque el audio siga avanzando.
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );
    // Reproductor nuevo -> vista nativa nueva.
    _videoEpoch++;

    _playerSubs.add(player.stream.error.listen((e) {
      if (!mounted || _isInFullscreenRoute) return;
      if (_currentChannel != null &&
          _sourceIndex + 1 < _currentChannel!.sources.length) {
        _switchChannel(_currentChannel!, sourceIndex: _sourceIndex + 1);
      }
    }));

    _playerSubs.add(player.stream.videoParams.listen((params) {
      if (!mounted) return;
      final w = params.w ?? 0;
      final h = params.h ?? 0;
      if (w > 0 && h > 0) {
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
          _playerLoading = false;
          _detectedQuality = label;
        });
      }
    }));

    _playerSubs.add(player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      setState(() => _playerLoading = buffering);
    }));

    _playerSubs.add(player.stream.position.listen((pos) {
      if (!mounted) return;
      if (pos > const Duration(milliseconds: 500) && !_hasVideo) {
        setState(() {
          _hasVideo = true;
          _playerLoading = false;
        });
      }
    }));
  }

  /// Destruye por completo el reproductor de TV en Vivo: libera el
  /// decodificador MediaCodec, la superficie nativa y los hilos de mpv.
  Future<void> _releasePlayer() async {
    final player = _player;
    final controller = _videoController;
    if (player == null && controller == null) return;
    _needsRetune = _currentChannel != null;
    _player = null;
    _videoController = null;
    _hasVideo = false;
    _playerLoading = true;
    final subs = List.of(_playerSubs);
    _playerSubs.clear();
    for (final s in subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    try {
      await player?.stop();
    } catch (_) {}
    try {
      await player?.dispose();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  /// Vuelve a crear el reproductor de TV en Vivo si ya no hay ninguna
  /// reproducción a pantalla completa que necesite el decodificador.
  void _maybeRecreatePlayer() {
    if (!mounted || _player != null) return;
    if (FullscreenPlaybackCoordinator.instance.isActive.value) return;
    _createPlayer();
    setState(() {});
  }

  void _onFullscreenActiveChanged() {
    if (!mounted) return;
    if (FullscreenPlaybackCoordinator.instance.isActive.value) {
      _releasePlayer();
      return;
    }
    _maybeRecreatePlayer();
    // Cerraron la película: reanuda el canal que estaba sintonizado.
    if (_needsRetune &&
        _player != null &&
        widget.isTabActive &&
        !_isInFullscreenRoute &&
        _currentChannel != null) {
      _switchChannel(_currentChannel!, sourceIndex: _sourceIndex);
    }
  }

  /// El <Video> de media_kit, sólo mientras existe el reproductor.
  ///
  /// [tag] identifica el sitio de la interfaz y `_videoEpoch` cambia cada vez
  /// que se crea un reproductor: la clave nueva obliga a Flutter a desmontar la
  /// vista nativa vieja, porque el `Video` de media_kit no reacciona al cambio
  /// de controlador en `didUpdateWidget`.
  Widget _buildVideo({BoxFit fit = BoxFit.contain, required String tag}) {
    final vc = _videoController;
    if (vc == null) return const SizedBox.shrink();
    return Video(
      key: ValueKey('tv_video_${tag}_$_videoEpoch'),
      controller: vc,
      fit: fit,
      controls: NoVideoControls,
    );
  }

  @override
  void didUpdateWidget(covariant TvScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isTabActive != widget.isTabActive) {
      if (!widget.isTabActive) {
        if (_tvFullscreen) {
          _tvFullscreen = false;
          _tvMiniGuideOpen = false;
          AppSettingsService.instance.immersiveLandscape.value = false;
          TvRemoteService.instance.registerActivePlayerHandler(null);
        }
        _pauseEmbeddedForBackground();
      } else if (!_isInFullscreenRoute) {
        _resumeEmbeddedIfVisible();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _pauseEmbeddedForBackground();
    } else if (state == AppLifecycleState.resumed &&
        widget.isTabActive &&
        !_isInFullscreenRoute) {
      _resumeEmbeddedIfVisible();
    }
  }

  void _pauseEmbeddedForBackground() {
    _landscapeHideTimer?.cancel();
    DeviceControlService.setKeepScreenOn(false);
    // Liberar el decodificador hardware (MediaCodec) al salir de En Vivo
    // evita que Android tenga que reclamar el VPU al abrir una película.
    // Con `stop()` no basta: en las cajas de 2 GB el hilo de la salida
    // `mediacodec_embed` sigue girando al 100 % de un núcleo y la siguiente
    // reproducción se ve trabada, así que destruimos el reproductor.
    if (FullscreenPlaybackCoordinator.instance.isActive.value) return;
    _releasePlayer();
  }

  void _resumeEmbeddedIfVisible() {
    if (!mounted || !widget.isTabActive || _isInFullscreenRoute) return;
    DeviceControlService.setKeepScreenOn(true);
    _maybeRecreatePlayer();
    if (_player == null) return;
    // Siempre re-sintoniza: el reproductor pudo haberse destruido en el fondo.
    _needsRetune = false;
    try {
      if (_currentChannel != null) {
        _switchChannel(_currentChannel!, sourceIndex: _sourceIndex);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchCtl.dispose();
    _searchFocus.dispose();
    _tvFullscreenFocus.dispose();
    _tvFullscreenBtnFocus.dispose();
    _channelListScroll.dispose();
    _landscapeHideTimer?.cancel();
    _tvZapBannerTimer?.cancel();
    _tvFsToastTimer?.cancel();
    if (_tvFullscreen) {
      TvRemoteService.instance.registerActivePlayerHandler(null);
    }
    for (final s in _subs) {
      s.cancel();
    }
    AppSettingsService.instance.immersiveLandscape.value = false;
    DeviceControlService.setKeepScreenOn(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!TvModeService.instance.isTv) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    FullscreenPlaybackCoordinator.instance.isActive
        .removeListener(_onFullscreenActiveChanged);
    for (final s in _playerSubs) {
      s.cancel();
    }
    _playerSubs.clear();
    final p = _player;
    _player = null;
    _videoController = null;
    Future.microtask(() async {
      try {
        await p?.stop();
        await p?.dispose();
      } catch (_) {}
    });
    super.dispose();
  }

  Future<void> _bootstrap() async {
    _categories = _service.getLiveCategories();
    final channels = await _service.getLiveChannels();
    final prefs = await SharedPreferences.getInstance();
    final favs = prefs.getStringList('inutiltv_favorite_channels') ?? [];
    final recents = prefs.getStringList(_recentKey) ?? [];

    if (!mounted) return;
    setState(() {
      _all = channels;
      _favorites = favs.toSet();
      _recentIds = recents;
      if (!_categories.contains(_selectedCategory) && _categories.isNotEmpty) {
        _selectedCategory = _categories.first;
      }
      _applyFilters();
    });

    if (channels.isNotEmpty) {
      final startCh = widget.initialChannel ??
          _findChannelById(recents.isNotEmpty ? recents.first : '') ??
          channels.first;
      _switchChannel(startCh);
    }
  }

  Channel? _findChannelById(String id) {
    if (id.isEmpty) return null;
    for (final c in _all) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _recordRecent(Channel ch) async {
    _recentIds.remove(ch.id);
    _recentIds.insert(0, ch.id);
    if (_recentIds.length > 10) {
      _recentIds = _recentIds.take(10).toList();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentKey, _recentIds);
    } catch (_) {}
  }

  Future<void> _toggleFavorite(Channel ch) async {
    setState(() {
      if (_favorites.contains(ch.id)) {
        _favorites.remove(ch.id);
      } else {
        _favorites.add(ch.id);
      }
      if (_selectedCategory == 'Favoritos') _applyFilters();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('inutiltv_favorite_channels', _favorites.toList());
    InutilTvCloudBackupService.instance.schedulePush();
  }

  bool _matchesSportsSub(Channel ch, String sub) {
    final n = ch.name.toLowerCase();
    switch (sub) {
      case 'Liga MX':
        return n.contains('tudn') ||
            n.contains('claro') ||
            n.contains('mexico') ||
            n.contains('mx') ||
            n.contains('tnt sport') ||
            n.contains('azteca') ||
            n.contains('caliente') ||
            n.contains('fox sports') ||
            n.contains('espn');
      case 'Champions':
        return n.contains('dazn') ||
            n.contains('laliga') ||
            n.contains('movistar') ||
            n.contains('eurosport') ||
            n.contains('bein') ||
            n.contains('sky sport') ||
            n.contains('tnt sport') ||
            n.contains('champions') ||
            n.contains('real madrid') ||
            n.contains('barca') ||
            n.contains('espn');
      case 'ESPN · Fox · Claro':
        return n.contains('espn') ||
            n.contains('fox sport') ||
            n.contains('claro sport') ||
            n.contains('tudn');
      case 'Sudamérica':
        return n.contains('tyc') ||
            n.contains('dsport') ||
            n.contains('directv') ||
            n.contains('win sport') ||
            n.contains('gol ') ||
            n.contains('goltv') ||
            n.contains('tigo') ||
            n.contains('colombia') ||
            n.contains('argentina');
      case 'NFL · NBA · MLB':
        return n.contains('nba') ||
            n.contains('nfl') ||
            n.contains('mlb') ||
            n.contains('nhl') ||
            n.contains('espn') ||
            n.contains('fox sports 1');
      case 'Box · UFC':
        return n.contains('ufc') ||
            n.contains('box') ||
            n.contains('wwe') ||
            n.contains('fight') ||
            n.contains('mma') ||
            n.contains('combat');
      case 'F1 · Motor':
        return n.contains('f1') ||
            n.contains('formula') ||
            n.contains('motor') ||
            n.contains('racing') ||
            n.contains('auto') ||
            n.contains('fox sports');
      case 'Destacados':
        return n.contains('espn') ||
            n.contains('fox sport') ||
            n.contains('tudn') ||
            n.contains('claro sport') ||
            n.contains('tnt sport') ||
            n.contains('tyc') ||
            n.contains('dsport') ||
            n.contains('directv') ||
            n.contains('win sport') ||
            n.contains('gol') ||
            n.contains('tigo') ||
            n.contains('dazn') ||
            n.contains('laliga') ||
            n.contains('bein') ||
            n.contains('eurosport') ||
            n.contains('sky sport') ||
            n.contains('nba') ||
            n.contains('nfl') ||
            n.contains('ufc') ||
            n.contains('f1');
      default:
        return true;
    }
  }

  void _applyFilters() {
    final q = _searchCtl.text.trim().toLowerCase();
    var list = _all;

    if (_selectedCategory == 'Favoritos') {
      list = list.where((c) => _favorites.contains(c.id)).toList();
    } else if (_selectedCategory != 'Todos') {
      list = list.where((c) => c.group == _selectedCategory).toList();
      if (_isSportsCategory && q.isEmpty) {
        final filtered = list
            .where((c) => _matchesSportsSub(c, _selectedSportsSub))
            .toList();
        if (filtered.isNotEmpty) list = filtered;
      }
    }

    if (q.isNotEmpty) {
      list = list
          .where((c) =>
              c.name.toLowerCase().contains(q) ||
              c.group.toLowerCase().contains(q) ||
              c.country.toLowerCase().contains(q))
          .toList();
    }

    _shown = list;
  }

  void _switchChannel(Channel ch, {int sourceIndex = 0}) {
    if (ch.sources.isEmpty) return;
    _needsRetune = false;
    final idx = sourceIndex.clamp(0, ch.sources.length - 1);
    final src = ch.sources[idx];

    setState(() {
      _currentChannel = ch;
      _sourceIndex = idx;
      _playerLoading = true;
      _hasVideo = false;
      _detectedQuality = '';
    });

    if (TvModeService.instance.isTv) {
      unawaited(
        TvRemoteService.instance.reportTvPlayback(
          isPlaying: true,
          title: ch.name,
          subtitle: ch.group.isNotEmpty ? ch.group : 'TV en Vivo',
          poster: ch.logo,
          isLive: true,
        ),
      );
    }

    unawaited(_recordRecent(ch));

    final np = _player?.platform;
    if (np is NativePlayer) {
      final isTv = TvModeService.instance.isTv;
      final props = <String, String>{
        'cache': 'yes',
        'cache-pause': 'yes',
        'cache-pause-wait': '1.0',
        'demuxer-max-bytes': isTv
            ? '10MiB'
            : (AppSettingsService.instance.ultraBuffer ? '64MiB' : '24MiB'),
        'demuxer-max-back-bytes': isTv ? '2MiB' : '8MiB',
        'demuxer-readahead-secs': isTv ? '8' : '12',
        'network-timeout': '15',
        'stream-lavf-o':
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,multiple_requests=1',
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
      };
      // Canales en redes con proxy obligatorio (empresas, hoteles): libmpv no
      // hereda el proxy del sistema.
      final proxyUrl = NetworkConfigService.instance.mpvProxyUrl;
      if (proxyUrl != null) {
        props['proxy-url'] = proxyUrl;
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

    _player?.setVolume(100.0);
    _player?.open(
      Media(src.url, httpHeaders: src.headers.isEmpty ? null : src.headers),
      play: true,
    );
  }

  void _nextChannel() {
    if (_shown.isEmpty) return;
    final curIdx = _shown.indexWhere((c) => c.id == _currentChannel?.id);
    final nextIdx = curIdx < 0 ? 0 : (curIdx + 1) % _shown.length;
    _switchChannel(_shown[nextIdx]);
    if (_tvFullscreen) {
      _showTvZapBanner();
    } else {
      _resetLandscapeHideTimer();
    }
  }

  void _previousChannel() {
    if (_shown.isEmpty) return;
    final curIdx = _shown.indexWhere((c) => c.id == _currentChannel?.id);
    final prevIdx = curIdx <= 0 ? _shown.length - 1 : curIdx - 1;
    _switchChannel(_shown[prevIdx]);
    if (_tvFullscreen) {
      _showTvZapBanner();
    } else {
      _resetLandscapeHideTimer();
    }
  }

  void _showTvZapBanner() {
    _tvZapBannerTimer?.cancel();
    if (!mounted) return;
    setState(() => _tvZapBannerVisible = true);
    _tvZapBannerTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _tvZapBannerVisible = false);
    });
  }

  void _showTvFsToast(String message) {
    _tvFsToastTimer?.cancel();
    if (!mounted) return;
    setState(() => _tvFsToast = message);
    _tvFsToastTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _tvFsToast = null);
    });
  }

  void _handleTvRemoteCommand(TvRemoteCommand cmd) {
    if (!mounted) return;
    switch (cmd.action) {
      case 'toggle_play':
        _player?.playOrPause();
        _showTvFsToast(
            (_player?.state.playing ?? false) ? 'Pausa' : 'Reproduciendo');
        break;
      case 'pause':
        _player?.pause();
        _showTvFsToast('Pausado desde tu celular');
        break;
      case 'play':
        _player?.play();
        _showTvFsToast('Reproduciendo');
        break;
      case 'volume_delta':
        final delta = (cmd.payload['delta'] as num?)?.toDouble() ?? 10;
        final nextVol = ((_player?.state.volume ?? 100.0) + delta).clamp(0.0, 100.0);
        _player?.setVolume(nextVol);
        _showTvFsToast('Volumen: ${nextVol.round()}%');
        break;
      case 'next_channel':
        _nextChannel();
        break;
      case 'prev_channel':
        _previousChannel();
        break;
      case 'stop':
        if (_tvFullscreen) _exitTvFullscreen();
        break;
    }
  }

  void _enterTvFullscreen() {
    if (_currentChannel == null) return;
    setState(() {
      _tvFullscreen = true;
      _tvMiniGuideOpen = false;
      _tvZapBannerVisible = true;
    });
    AppSettingsService.instance.immersiveLandscape.value = true;
    TvRemoteService.instance.registerActivePlayerHandler(_handleTvRemoteCommand);
    _showTvZapBanner();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _tvFullscreen) {
        _tvFullscreenFocus.requestFocus();
      }
    });
  }

  void _exitTvFullscreen() {
    _tvZapBannerTimer?.cancel();
    _tvFsToastTimer?.cancel();
    TvRemoteService.instance.registerActivePlayerHandler(null);
    setState(() {
      _tvFullscreen = false;
      _tvMiniGuideOpen = false;
      _tvZapBannerVisible = false;
      _tvFsToast = null;
    });
    AppSettingsService.instance.immersiveLandscape.value = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_channelListScroll.hasClients && _currentChannel != null) {
        final idx = _shown.indexWhere((c) => c.id == _currentChannel!.id);
        if (idx >= 0) {
          final target = (idx * 72.0 - 120.0)
              .clamp(0.0, _channelListScroll.position.maxScrollExtent);
          _channelListScroll.jumpTo(target);
        }
      }
      _tvFullscreenBtnFocus.requestFocus();
    });
  }

  void _cycleTvAspect() {
    _cycleLandscapeAspect();
    final label = _fit == BoxFit.contain
        ? 'Original'
        : (_fit == BoxFit.cover ? 'Pantalla llena' : 'Expandido');
    _showTvFsToast('Ajuste: $label');
  }

  void _resetLandscapeHideTimer() {
    _landscapeHideTimer?.cancel();
    if (!mounted) return;
    setState(() => _showLandscapeControls = true);
    _landscapeHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showLandscapeControls = false);
    });
  }

  void _cycleLandscapeAspect() {
    setState(() {
      if (_fit == BoxFit.contain) {
        _fit = BoxFit.cover;
      } else if (_fit == BoxFit.cover) {
        _fit = BoxFit.fill;
      } else {
        _fit = BoxFit.contain;
      }
    });
  }

  /// Abre PlayerScreen pausando y silenciando el reproductor embebido PRIMERO
  /// para eliminar por completo la reproducción doble.
  Future<void> _openFullScreen() async {
    if (_currentChannel == null || _currentChannel!.sources.isEmpty) return;
    _isInFullscreenRoute = true;
    try {
      await _player?.pause();
      await _player?.setVolume(0.0);
    } catch (_) {}

    final list = _shown.isNotEmpty ? _shown : _all;
    final idx = list.indexWhere((c) => c.id == _currentChannel!.id);

    if (!mounted) return;
    final returnedChannel = await Navigator.of(context).push<Channel>(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: _currentChannel!.name,
          subtitle: _currentChannel!.group,
          playables: [
            for (final s in _currentChannel!.sources)
              Playable(
                s.quality.isEmpty ? 'Señal En Vivo' : s.quality,
                s.url,
                headers: s.headers,
              ),
          ],
          channelList: list,
          initialChannelIndex: idx >= 0 ? idx : 0,
        ),
      ),
    );

    _isInFullscreenRoute = false;
    if (!mounted) return;

    // El reproductor de En Vivo se destruyó mientras PlayerScreen tenía el
    // decodificador: hay que crearlo y volver a sintonizar el canal.
    _maybeRecreatePlayer();

    if (returnedChannel != null && returnedChannel.id != _currentChannel?.id) {
      _switchChannel(returnedChannel);
    } else if (_needsRetune) {
      _needsRetune = false;
      if (_currentChannel != null && _player != null) {
        _switchChannel(_currentChannel!, sourceIndex: _sourceIndex);
      }
    } else {
      try {
        await _player?.setVolume(100.0);
        await _player?.play();
      } catch (_) {}
    }
  }

  void _returnToPortraitTemporarily() {
    if (TvModeService.instance.isTv) return;
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted && !TvModeService.instance.isTv) {
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      }
    });
  }

  void _showLandscapeChannelDrawer() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.carbonSurface,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 320,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _selectedCategory,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${_shown.length} canales',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white10),
              Expanded(
                child: ListView.builder(
                  itemCount: _shown.length,
                  itemBuilder: (ctx, idx) {
                    final ch = _shown[idx];
                    final active = ch.id == _currentChannel?.id;
                    return ListTile(
                      dense: true,
                      tileColor: active
                          ? Colors.white.withValues(alpha: 0.08)
                          : null,
                      leading: Text(
                        '${idx + 1}'.padLeft(3, '0'),
                        style: TextStyle(
                          color: active ? Colors.white : Colors.white38,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      title: Text(
                        ch.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active ? Colors.white : Colors.white70,
                          fontWeight:
                              active ? FontWeight.w800 : FontWeight.w500,
                        ),
                      ),
                      trailing: active
                          ? const Icon(Icons.equalizer_rounded,
                              color: Colors.white)
                          : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        _switchChannel(ch);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenLandscapePlayer() {
    final ch = _currentChannel;
    return GestureDetector(
      onTap: () {
        if (_showLandscapeControls) {
          setState(() => _showLandscapeControls = false);
        } else {
          _resetLandscapeHideTimer();
        }
      },
      onDoubleTap: () {
        _cycleLandscapeAspect();
        _resetLandscapeHideTimer();
      },
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.black),
          Center(child: _buildVideo(fit: _fit, tag: 'landscape')),
          if (_playerLoading && !_hasVideo)
            const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.5,
              ),
            ),
          AnimatedOpacity(
            opacity: _showLandscapeControls ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 220),
            child: IgnorePointer(
              ignoring: !_showLandscapeControls,
              child: Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.85),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: SafeArea(
                        bottom: false,
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    ch?.name ?? 'TV en Vivo',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  Text(
                                    '${ch?.group ?? ""}${_detectedQuality.isNotEmpty ? " · $_detectedQuality" : ""}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Material(
                              color: AppColors.playbackPrimaryBackground,
                              borderRadius: BorderRadius.circular(18),
                              child: InkWell(
                                onTap: _showLandscapeChannelDrawer,
                                borderRadius: BorderRadius.circular(18),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.list_rounded,
                                        color: AppColors
                                            .playbackPrimaryForeground,
                                        size: 16,
                                      ),
                                      SizedBox(width: 5),
                                      Text(
                                        'Canales',
                                        style: TextStyle(
                                          color: AppColors
                                              .playbackPrimaryForeground,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Temporizador de sueño',
                              icon: const InutilIcon(
                                InutilGlyph.sleepTimer,
                                color: Colors.white,
                                size: 20,
                              ),
                              onPressed: () {
                                InutilSleepTimerSheet.show(context);
                                _resetLandscapeHideTimer();
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.aspect_ratio_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                              onPressed: () {
                                _cycleLandscapeAspect();
                                _resetLandscapeHideTimer();
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.stay_current_portrait_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                              tooltip: 'Volver a Vertical',
                              onPressed: _returnToPortraitTemporarily,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          CircleAvatar(
                            backgroundColor:
                                Colors.black.withValues(alpha: 0.56),
                            radius: 24,
                            child: IconButton(
                              icon: const Icon(
                                Icons.skip_previous_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                              onPressed: _previousChannel,
                            ),
                          ),
                          CircleAvatar(
                            backgroundColor:
                                Colors.black.withValues(alpha: 0.56),
                            radius: 24,
                            child: IconButton(
                              icon: const Icon(
                                Icons.skip_next_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                              onPressed: _nextChannel,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pantalla completa pura e instantánea (0 ms, misma señal activa, 0 iconos)
  /// diseñada para Smart TV / Android TV / TV Box:
  /// - Video a pantalla completa sin iconos ni botones encima.
  /// - `▲` / `▼` o `CH+` / `CH-`: zapping inmediato de canal con banner sutil
  ///   de 2.4 s que desaparece por completo.
  /// - `OK` o `◀`: abre/cierra la mini-guía lateral de canales para cambiar sin
  ///   salir de pantalla completa.
  /// - `▶`: cambia el ajuste de aspecto (`Original` / `Pantalla llena` / `Expandido`).
  /// - `Atrás`: cierra mini-guía o sale de pantalla completa.
  Widget _buildTvPureFullscreenPlayer() {
    final ch = _currentChannel;
    final curIdx = _shown.indexWhere((c) => c.id == ch?.id);
    final chNum = curIdx >= 0 ? '${curIdx + 1}'.padLeft(3, '0') : '---';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tvMiniGuideOpen) {
          setState(() => _tvMiniGuideOpen = false);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _tvFullscreen) _tvFullscreenFocus.requestFocus();
          });
        } else {
          _exitTvFullscreen();
        }
      },
      child: Focus(
        focusNode: _tvFullscreenFocus,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;

          // Mini-guía abierta: dejar que ▲/▼/OK naveguen los canales y cerrar con ▶ o Esc
          if (_tvMiniGuideOpen) {
            if (event is KeyDownEvent &&
                (key == LogicalKeyboardKey.arrowRight ||
                    key == LogicalKeyboardKey.escape ||
                    key == LogicalKeyboardKey.goBack)) {
              setState(() => _tvMiniGuideOpen = false);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _tvFullscreen) _tvFullscreenFocus.requestFocus();
              });
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          }

          // Pantalla completa pura: zapping inmediato con ▲/▼ o CH+/CH-
          if (key == LogicalKeyboardKey.arrowDown ||
              key == LogicalKeyboardKey.channelUp) {
            _nextChannel();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowUp ||
              key == LogicalKeyboardKey.channelDown) {
            _previousChannel();
            return KeyEventResult.handled;
          }
          if (event is KeyRepeatEvent) {
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.arrowLeft) {
            setState(() {
              _tvMiniGuideOpen = true;
              _tvZapBannerVisible = false;
            });
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowRight) {
            _cycleTvAspect();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.mediaPlayPause ||
              key == LogicalKeyboardKey.space) {
            _player?.playOrPause();
            _showTvFsToast(
                (_player?.state.playing ?? false) ? 'Pausa' : 'Reproduciendo');
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.escape ||
              key == LogicalKeyboardKey.goBack) {
            _exitTvFullscreen();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Video puro 100% pantalla completa sin ningún icono
              Center(child: _buildVideo(fit: _fit, tag: 'tv_fs')),

              // 2. Spinner limpio solo mientras cambia/sintoniza canal
              if (_playerLoading && !_hasVideo)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 34,
                        height: 34,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.6,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Sintonizando ${ch?.name ?? "canal"}...',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),

              // 3. Banner informativo minimalista (sin iconos ni botones; se oculta solo en 2.4s)
              if (!_tvMiniGuideOpen)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _tvZapBannerVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 240),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(32, 34, 32, 24),
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
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF38BDF8)
                                    .withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF38BDF8)
                                      .withValues(alpha: 0.55),
                                  width: 1,
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
                                          ch?.name ?? 'TV en Vivo',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
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
                                          borderRadius:
                                              BorderRadius.circular(5),
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
                                            color: Colors.white
                                                .withValues(alpha: 0.16),
                                            borderRadius:
                                                BorderRadius.circular(5),
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
                                    '${ch?.group ?? ""}  ·  ▲▼ Cambiar canal  ·  OK Guía  ·  ▶ Ajuste  ·  Atrás Salir',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.68),
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
                  ),
                ),

              // 4. Toast breve de ajuste de aspecto / pausa
              if (_tvFsToast != null)
                Positioned(
                  top: 28,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E1016).withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.18),
                          width: 0.9,
                        ),
                      ),
                      child: Text(
                        _tvFsToast!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),

              // 5. Mini-guía lateral translúcida (solo al pulsar OK o ◀)
              if (_tvMiniGuideOpen)
                Align(
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
                              Expanded(
                                child: Text(
                                  _selectedCategory,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Text(
                                '${_shown.length} canales',
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            itemCount: _shown.length,
                            itemBuilder: (ctx, idx) {
                              final item = _shown[idx];
                              final active = item.id == _currentChannel?.id;
                              return TvFocusable(
                                autofocus: active || (curIdx < 0 && idx == 0),
                                descendantsAreFocusable: false,
                                descendantsAreTraversable: false,
                                focusColor: const Color(0xFF38BDF8),
                                focusScale: 1.015,
                                borderRadius: BorderRadius.circular(12),
                                margin: const EdgeInsets.only(bottom: 6),
                                onTap: () {
                                  if (!active) {
                                    _switchChannel(item);
                                  }
                                  setState(() => _tvMiniGuideOpen = false);
                                  _showTvZapBanner();
                                  WidgetsBinding.instance
                                      .addPostFrameCallback((_) {
                                    if (mounted && _tvFullscreen) {
                                      _tvFullscreenFocus.requestFocus();
                                    }
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: active
                                        ? const Color(0xFF38BDF8)
                                            .withValues(alpha: 0.16)
                                        : Colors.white.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: active
                                          ? const Color(0xFF38BDF8)
                                              .withValues(alpha: 0.6)
                                          : Colors.white
                                              .withValues(alpha: 0.08),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 32,
                                        child: Text(
                                          '${idx + 1}'.padLeft(3, '0'),
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
                                          item.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: active
                                                ? Colors.white
                                                : Colors.white70,
                                            fontSize: 13.5,
                                            fontWeight: active
                                                ? FontWeight.w800
                                                : FontWeight.w600,
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
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = TvModeService.of(context);
    final isLandscape =
        !isTv && MediaQuery.of(context).orientation == Orientation.landscape;
    final wantImmersive = isLandscape || (isTv && _tvFullscreen);

    if (AppSettingsService.instance.immersiveLandscape.value != wantImmersive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          AppSettingsService.instance.immersiveLandscape.value = wantImmersive;
        }
      });
    }

    if (isTv && _tvFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      return _buildTvPureFullscreenPlayer();
    }

    if (isLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      return _buildFullscreenLandscapePlayer();
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }

    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final headingColor = AppColors.contentHeadingFor(context);

    final recentChannels = _recentIds
        .map(_findChannelById)
        .whereType<Channel>()
        .take(6)
        .toList();

    final listColumn = Column(
      children: [
        if (!isTv)
          // 1. Reproductor embebido 16:9
          _buildEmbeddedPlayer(context),

        if (isTv)
          const SizedBox(height: 14)
        else
          // 2. Buscador de canales sobrio (en Smart TV se usa el botón Buscar del menú lateral)
          Padding(
          padding: const EdgeInsets.fromLTRB(
            appPagePaddingHorizontal,
            10,
            appPagePaddingHorizontal,
            8,
          ),
          child: Container(
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.inputSurfaceFor(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: border, width: 0.8),
            ),
            child: TextField(
              controller: _searchCtl,
              focusNode: _searchFocus,
              onChanged: (_) => setState(_applyFilters),
              style: TextStyle(color: headingColor, fontSize: 13),
              decoration: InputDecoration(
                filled: false,
                hintText: 'Buscar entre ${_all.length} canales verificados...',
                hintStyle: TextStyle(color: subColor, fontSize: 12.5),
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(11),
                  child: InutilIcon(
                    InutilGlyph.search,
                    size: 17,
                    color: subColor,
                  ),
                ),
                suffixIcon: _searchCtl.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.close_rounded,
                            color: subColor, size: 18),
                        onPressed: () {
                          _searchCtl.clear();
                          setState(_applyFilters);
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ),

        // 3. Píldoras de Categorías limpias
        SizedBox(
          height: 36,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: appPagePaddingHorizontal),
            itemCount: _categories.length,
            itemBuilder: (context, index) {
              final cat = _categories[index];
              final selected = cat == _selectedCategory;
              return TvFocusable(
                onTap: () {
                  setState(() {
                    _selectedCategory = cat;
                    _applyFilters();
                  });
                },
                focusColor: isTv ? const Color(0xFF38BDF8) : null,
                descendantsAreFocusable: false,
                descendantsAreTraversable: false,
                borderRadius: BorderRadius.circular(18),
                margin: const EdgeInsets.only(right: 8),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? accent : surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: selected ? accent : border,
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    cat,
                    style: TextStyle(
                      color: selected ? onAccent : subColor,
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // 4. Sub-categorías inteligentes en Deportes
        if (_isSportsCategory) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: appPagePaddingHorizontal,
              ),
              itemCount: _sportsSubTabs.length,
              itemBuilder: (context, idx) {
                final sub = _sportsSubTabs[idx];
                final active = sub == _selectedSportsSub;
                return TvFocusable(
                  onTap: () {
                    setState(() {
                      _selectedSportsSub = sub;
                      _applyFilters();
                    });
                  },
                  focusColor: isTv ? const Color(0xFF38BDF8) : null,
                  descendantsAreFocusable: false,
                  descendantsAreTraversable: false,
                  borderRadius: BorderRadius.circular(14),
                  margin: const EdgeInsets.only(right: 7),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? accent.withValues(alpha: 0.16)
                          : AppColors.elevatedSurfaceFor(context),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: active ? accent.withValues(alpha: 0.65) : border,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      sub,
                      style: TextStyle(
                        color: active ? accent : subColor,
                        fontSize: 11,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],

        // 5. Canales recientes
        if (_selectedCategory == 'Todos' &&
            _searchCtl.text.isEmpty &&
            recentChannels.isNotEmpty) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 30,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: appPagePaddingHorizontal,
              ),
              itemCount: recentChannels.length,
              itemBuilder: (context, idx) {
                final rc = recentChannels[idx];
                final active = rc.id == _currentChannel?.id;
                return TvFocusable(
                  onTap: () {
                    if (isTv && active) {
                      _enterTvFullscreen();
                    } else {
                      _switchChannel(rc);
                    }
                  },
                  focusColor: isTv ? const Color(0xFF38BDF8) : null,
                  descendantsAreFocusable: false,
                  descendantsAreTraversable: false,
                  borderRadius: BorderRadius.circular(12),
                  margin: const EdgeInsets.only(right: 7),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active ? accent.withValues(alpha: 0.14) : surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: active ? accent.withValues(alpha: 0.5) : border,
                        width: 0.7,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.history_rounded,
                          size: 12,
                          color: active ? accent : subColor,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          rc.name,
                          style: TextStyle(
                            color: active ? headingColor : subColor,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],

        // Conteo
        Padding(
          padding: const EdgeInsets.fromLTRB(
            appPagePaddingHorizontal,
            8,
            appPagePaddingHorizontal,
            4,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  _isSportsCategory
                      ? '$_selectedCategory · $_selectedSportsSub'
                      : _selectedCategory,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: subColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${_shown.length} canales',
                style: TextStyle(
                  color: headingColor,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),

        // 6. Lista de canales con espacio inferior para la cápsula flotante
        Expanded(
          child: _shown.isEmpty
              ? Center(
                  child: Text(
                    'No hay canales en este filtro.',
                    style: appListCardSubtitleStyle(context),
                  ),
                )
              : ListView.builder(
                  controller: _channelListScroll,
                  padding: EdgeInsets.fromLTRB(
                    appPagePaddingHorizontal,
                    4,
                    appPagePaddingHorizontal,
                    isTv ? 24 : 112,
                  ),
                  itemCount: _shown.length,
                  itemBuilder: (context, index) =>
                      _buildChannelTile(context, _shown[index], index),
                ),
        ),
      ],
    );

    if (!isTv) return listColumn;

    final ch = _currentChannel;
    final isCurrentFav = ch != null && _favorites.contains(ch.id);
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: listColumn,
        ),
        VerticalDivider(
          width: 1,
          thickness: 0.9,
          color: AppColors.dividerFor(context),
        ),
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExcludeFocus(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: _buildEmbeddedPlayer(context),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  ch?.name ?? 'Selecciona un canal',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: appTabTitleStyle(context).copyWith(fontSize: 20),
                ),
                if (ch != null)
                  Text(
                    '${ch.group}${_detectedQuality.isNotEmpty ? ' · $_detectedQuality' : ''} · Pulsa OK de nuevo en el canal para pantalla completa',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    TvFocusable(
                      focusNode: _tvFullscreenBtnFocus,
                      focusColor: const Color(0xFF38BDF8),
                      focusBorderWidth: 3.0,
                      borderRadius: BorderRadius.circular(24),
                      descendantsAreFocusable: false,
                      descendantsAreTraversable: false,
                      onTap: ch == null ? null : _enterTvFullscreen,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.fullscreen_rounded,
                              size: 20,
                              color: Colors.black,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Pantalla completa',
                              style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    TvFocusable(
                      focusColor: const Color(0xFF38BDF8),
                      borderRadius: BorderRadius.circular(24),
                      descendantsAreFocusable: false,
                      descendantsAreTraversable: false,
                      onTap: _shown.length > 1 ? _previousChannel : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: border, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.skip_previous_rounded,
                              size: 19,
                              color: headingColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Anterior',
                              style: TextStyle(
                                color: headingColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    TvFocusable(
                      focusColor: const Color(0xFF38BDF8),
                      borderRadius: BorderRadius.circular(24),
                      descendantsAreFocusable: false,
                      descendantsAreTraversable: false,
                      onTap: _shown.length > 1 ? _nextChannel : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: border, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.skip_next_rounded,
                              size: 19,
                              color: headingColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Siguiente',
                              style: TextStyle(
                                color: headingColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (ch != null)
                      TvFocusable(
                        focusColor: const Color(0xFF38BDF8),
                        borderRadius: BorderRadius.circular(24),
                        descendantsAreFocusable: false,
                        descendantsAreTraversable: false,
                        onTap: () => _toggleFavorite(ch),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 15,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: border, width: 1),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isCurrentFav
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                size: 19,
                                color: isCurrentFav
                                    ? AppColors.ratingGold
                                    : headingColor,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                isCurrentFav ? 'En favoritos' : 'Favorito',
                                style: TextStyle(
                                  color: headingColor,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmbeddedPlayer(BuildContext context) {
    final ch = _currentChannel;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildVideo(tag: 'embedded'),
            if (_playerLoading && !_hasVideo)
              Container(
                color: Colors.black.withValues(alpha: 0.68),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sintonizando ${ch?.name ?? "señal"}...',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 20, 8, 6),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.88),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
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
                          fontSize: 8.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ch?.name ?? 'Selecciona un canal',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (_detectedQuality.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
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
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    if (!TvModeService.of(context) && ch != null)
                      ListenableBuilder(
                        listenable: TvRemoteService.instance,
                        builder: (context, _) {
                          if (!TvRemoteService.instance.isTvOnline) {
                            return const SizedBox.shrink();
                          }
                          return IconButton(
                            icon: const Icon(
                              Icons.cast_connected_rounded,
                              color: Color(0xFF18C75A),
                              size: 21,
                            ),
                            tooltip: 'Ver este canal en mi Smart TV',
                            onPressed: () async {
                              final ok = await TvRemoteService.instance
                                  .sendChannelToTv(ch);
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    ok
                                        ? '${ch.name} enviado a tu Smart TV'
                                        : 'No se pudo enviar el canal',
                                  ),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                              if (ok) TvRemoteSheet.show(context);
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                          );
                        },
                      ),
                    if (!TvModeService.of(context))
                      IconButton(
                        icon: const Icon(
                          Icons.fullscreen_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                        tooltip: 'Pantalla completa',
                        onPressed: _openFullScreen,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelTile(BuildContext context, Channel ch, int index) {
    final isTv = TvModeService.of(context);
    final isCurrent = _currentChannel?.id == ch.id;
    final isFav = _favorites.contains(ch.id);
    final accent = AppColors.accentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);

    return TvFocusable(
      key: ValueKey('ch_${ch.id}'),
      onTap: () {
        if (isTv && isCurrent) {
          _enterTvFullscreen();
        } else {
          _switchChannel(ch);
        }
      },
      onLongPress: isTv ? () => _toggleFavorite(ch) : null,
      borderRadius: BorderRadius.circular(14),
      focusColor: isTv ? const Color(0xFF38BDF8) : null,
      focusScale: 1.015,
      descendantsAreFocusable: !isTv,
      descendantsAreTraversable: !isTv,
      margin: const EdgeInsets.only(bottom: 7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: isCurrent ? accent.withValues(alpha: 0.12) : surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isCurrent ? accent.withValues(alpha: 0.65) : border,
            width: isCurrent ? 1.1 : 0.75,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '${index + 1}'.padLeft(2, '0'),
                style: TextStyle(
                  color: isCurrent ? accent : subColor.withValues(alpha: 0.6),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Container(
              width: 38,
              height: 38,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(9),
              ),
              child: ch.logo.isNotEmpty
                  ? FastArtwork(
                      url: ch.logo,
                      tier: ArtworkTier.thumbnail,
                      cacheWidth: 120,
                      fit: BoxFit.contain,
                      errorWidget: Icon(
                        Icons.live_tv_rounded,
                        color: subColor,
                        size: 19,
                      ),
                    )
                  : Icon(Icons.live_tv_rounded, color: subColor, size: 19),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ch.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? accent : headingColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ch.sources.length > 1
                        ? '${ch.group} · ${ch.sources.length} señales'
                        : ch.group,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: subColor, fontSize: 10.5),
                  ),
                ],
              ),
            ),
            if (isCurrent)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.equalizer_rounded, color: accent, size: 19),
              ),
            if (isTv)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  isFav ? Icons.star_rounded : Icons.star_border_rounded,
                  color: isFav
                      ? AppColors.ratingGold
                      : subColor.withValues(alpha: 0.45),
                  size: 19,
                ),
              )
            else
              IconButton(
                icon: Icon(
                  isFav ? Icons.star_rounded : Icons.star_border_rounded,
                  color: isFav
                      ? AppColors.ratingGold
                      : subColor.withValues(alpha: 0.6),
                  size: 20,
                ),
                onPressed: () => _toggleFavorite(ch),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              ),
          ],
        ),
      ),
    );
  }
}
