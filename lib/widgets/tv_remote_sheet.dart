import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/tv_qr_scanner_screen.dart';
import '../services/artwork_cache_service.dart';
import '../services/tv_remote_service.dart';
import '../theme/app_colors.dart';
import '../theme/inutil_icons.dart';
import 'fast_artwork.dart';

// ─────────────────────────────────────────────────────────────────────────────
/// Hoja de Control Remoto Móvil "InútilTV Connect" — Sprint 1 (2026):
///
/// • Toggle Trackpad gestual ↔ D-Pad clásico.
/// • Keyboard Bridge: TextField en celular escribe en el buscador de la TV.
/// • Volumen + / − con botones UI (y hardware volume keys interceptadas).
/// • Scrubbar arrastrable a posición exacta en segundos.
/// • Control de velocidad: 0.75× · 1× · 1.25× · 1.5× · 2×.
/// • Botón ⏮ episodio anterior + ⏭ siguiente episodio.
/// • Indicador de conexión pulsante (AnimatedOpacity).
// ─────────────────────────────────────────────────────────────────────────────
class TvRemoteSheet extends StatefulWidget {
  const TvRemoteSheet({super.key});

  static bool _isOpen = false;
  static bool get isOpen => _isOpen;
  static BuildContext? _activeContext;

  static Future<void> show(BuildContext context) async {
    if (_isOpen && _activeContext != null && _activeContext!.mounted) {
      Navigator.of(_activeContext!).pop();
      return;
    }
    _isOpen = true;
    TvRemoteService.instance.refreshTvStateNow();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? AppColors.carbonSurface
            : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (modalCtx) {
          _activeContext = modalCtx;
          return const TvRemoteSheet();
        },
      );
    } finally {
      _isOpen = false;
      _activeContext = null;
    }
  }

  static void close() {
    if (_isOpen && _activeContext != null && _activeContext!.mounted) {
      Navigator.of(_activeContext!).pop();
    }
  }

  @override
  State<TvRemoteSheet> createState() => _TvRemoteSheetState();
}

class _TvRemoteSheetState extends State<TvRemoteSheet>
    with SingleTickerProviderStateMixin {
  // ── Timers / polling ──────────────────────────────────────────────────────
  String? _toast;
  Timer? _toastTimer;
  Timer? _sheetPollTimer;
  Timer? _fastPollTimer;
  bool _connecting = false;

  // ── Modo: trackpad vs D-Pad ───────────────────────────────────────────────
  bool _trackpadMode = false;
  static const _prefKey = 'tv_remote_trackpad_mode';

  // ── Trackpad gestual ──────────────────────────────────────────────────────
  Offset? _panStart;
  static const double _swipeThreshold = 22.0;

  // ── Keyboard Bridge ───────────────────────────────────────────────────────
  bool _keyboardMode = false;
  final _kbController = TextEditingController();
  final _kbFocus = FocusNode();
  Timer? _kbTimer;

  // ── Volume overlay ────────────────────────────────────────────────────────
  Timer? _volOverlayTimer;
  int? _volOverlay; // valor 0–100 para mostrar overlay

  // ── Velocidades de reproducción ───────────────────────────────────────────
  static const _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
  double _selectedSpeed = 1.0;

  // ── Scrubbar: posición drag ───────────────────────────────────────────────
  double? _scrubValue; // null = usando el valor del estado

  // ── Pulsating indicator ───────────────────────────────────────────────────
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    // Pulsating connection dot
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 0.25).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Iniciar descubrimiento LAN inmediato y refresco
    unawaited(TvRemoteService.instance.discoverTvLan().then((_) {
      if (mounted) TvRemoteService.instance.refreshTvStateNow();
    }));

    // Polling periódico mientras la hoja está abierta
    _sheetPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) TvRemoteService.instance.refreshTvStateNow();
    });

    // Cargar preferencia de modo
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(() => _trackpadMode = p.getBool(_prefKey) ?? false);
      }
    });

    // Sincronizar velocidad con estado actual de la TV
    final speed = TvRemoteService.instance.tvState.speed;
    if (_speeds.contains(speed)) _selectedSpeed = speed;
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _sheetPollTimer?.cancel();
    _fastPollTimer?.cancel();
    _volOverlayTimer?.cancel();
    _kbTimer?.cancel();
    _pulseCtrl.dispose();
    _kbController.dispose();
    _kbFocus.dispose();
    super.dispose();
  }

  // ─── helpers ─────────────────────────────────────────────────────────────

  void _showFeedback(String msg) {
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() => _toast = msg);
    _toastTimer = Timer(const Duration(milliseconds: 2000), () {
      if (mounted && _toast == msg) setState(() => _toast = null);
    });
  }

  Future<void> _send(
    String action, {
    Map<String, dynamic> payload = const {},
    String? feedback,
  }) async {
    HapticFeedback.lightImpact();
    final ok =
        await TvRemoteService.instance.sendCommand(action, payload: payload);
    if (!mounted) return;
    _showFeedback(
        ok ? (feedback ?? 'Enviado ✓') : 'Sin conexión. Revisa tu red.');
  }

  Future<void> _sendDpad(String direction) async {
    HapticFeedback.selectionClick();
    await TvRemoteService.instance.sendDpad(direction);
  }

  void _showVolOverlay(int val) {
    setState(() => _volOverlay = val);
    _volOverlayTimer?.cancel();
    _volOverlayTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _volOverlay = null);
    });
  }

  Future<void> _volumeDelta(int delta) async {
    HapticFeedback.selectionClick();
    final current = TvRemoteService.instance.tvState.volume;
    final next = (current + delta).clamp(0, 100);
    _showVolOverlay(next);
    await TvRemoteService.instance
        .sendCommand('volume_delta', payload: {'delta': delta});
  }

  Future<void> _openQrScanner() async {
    final linked = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const TvQrScannerScreen()));
    if (linked == true && mounted) {
      setState(() {
        _connecting = true;
        _toast = 'Smart TV vinculada. Espera unos segundos...';
      });
      _startFastPoll();
    }
  }

  void _startFastPoll() {
    _fastPollTimer?.cancel();
    var attempts = 0;
    _fastPollTimer =
        Timer.periodic(const Duration(milliseconds: 1200), (t) async {
      attempts++;
      await TvRemoteService.instance.refreshTvStateNow();
      if (!mounted) {
        t.cancel();
        return;
      }
      if (TvRemoteService.instance.isTvOnline) {
        t.cancel();
        setState(() => _connecting = false);
        _showFeedback('¡Smart TV conectada!');
      } else if (attempts >= 15) {
        t.cancel();
        setState(() => _connecting = false);
        _showFeedback('Abre Inutix TV en tu TV para comenzar');
      }
    });
  }

  void _toggleMode(bool trackpad) {
    setState(() => _trackpadMode = trackpad);
    SharedPreferences.getInstance()
        .then((p) => p.setBool(_prefKey, trackpad));
  }

  // ── Keyboard Bridge ───────────────────────────────────────────────────────

  void _activateKeyboard() {
    // Primero abre búsqueda en la TV
    TvRemoteService.instance.sendOpenSearch();
    setState(() {
      _keyboardMode = true;
      _kbController.clear();
    });
    _kbTimer?.cancel();
    _kbTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _kbFocus.requestFocus();
    });
  }

  void _onKbChanged(String text) {
    TvRemoteService.instance.sendKeyboardText(text);
  }

  void _kbSubmit() {
    HapticFeedback.mediumImpact();
    TvRemoteService.instance.sendKeyboardSubmit();
    _showFeedback('Búsqueda enviada ✓');
  }

  void _kbClear() {
    _kbController.clear();
    TvRemoteService.instance.sendKeyboardClear();
  }

  // ── Trackpad gestures ─────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails d) => _panStart = d.globalPosition;

  void _onPanEnd(DragEndDetails _) => _panStart = null;

  void _onPanUpdate(DragUpdateDetails d) {
    if (_panStart == null) return;
    final delta = d.globalPosition - _panStart!;
    if (delta.distance < _swipeThreshold) return;
    _panStart = d.globalPosition;
    final dx = delta.dx.abs();
    final dy = delta.dy.abs();
    if (dx > dy) {
      _sendDpad(delta.dx > 0 ? 'right' : 'left');
    } else {
      _sendDpad(delta.dy > 0 ? 'down' : 'up');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final heading = AppColors.contentHeadingFor(context);
    final sub = AppColors.contentSubtitleFor(context);
    final elevated = AppColors.elevatedSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        child: SingleChildScrollView(
          physics: _trackpadMode
              ? const NeverScrollableScrollPhysics()
              : const ClampingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: ListenableBuilder(
            listenable: TvRemoteService.instance,
            builder: (context, _) {
              final state = TvRemoteService.instance.tvState;
              final online = state.isReachable;

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ─── Handle ──────────────────────────────────────────────
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: sub.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ─── Header conexión ──────────────────────────────────────
                  _buildConnectionHeader(
                      state, online, heading, sub, elevated, border, accent),

                  const SizedBox(height: 16),

                  if (online) ...[
                    // ─── Now Playing card ─────────────────────────────────
                    if (state.hasActiveMedia) ...[
                      _buildNowPlayingCard(
                          state, elevated, border, heading, sub, accent, onAccent),
                      const SizedBox(height: 16),
                    ],

                    // ─── Keyboard Bridge ──────────────────────────────────
                    if (_keyboardMode)
                      _buildKeyboardBridge(elevated, border, heading, sub, accent, onAccent)
                    else ...[
                      // ─── Mode toggle ──────────────────────────────────
                      _buildModeToggle(elevated, border, heading, sub, accent),
                      const SizedBox(height: 14),

                      // ─── Trackpad o D-Pad ─────────────────────────────
                      _trackpadMode
                          ? _buildTrackpad(elevated, border, heading, accent, onAccent)
                          : _buildDpad(context, elevated, border, heading, accent, onAccent),

                      const SizedBox(height: 16),

                      // ─── Fila: Atrás · Inicio · Buscar · Volumen ─────
                      _buildSystemRow(elevated, border, heading, accent, onAccent),
                    ],

                    const SizedBox(height: 14),

                    // ─── Secciones rápidas ────────────────────────────────
                    Text(
                      'Secciones Rápidas',
                      style: TextStyle(
                          color: sub,
                          fontSize: 12,
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    _buildSectionsRow(),
                  ] else ...[
                    // ─── Desconectado ─────────────────────────────────────
                    _buildDisconnectedCard(elevated, border, heading, sub, accent),
                  ],

                  // ─── Toast ────────────────────────────────────────────────
                  if (_toast != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _toast!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: accent,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700),
                    ),
                  ],

                  // ─── Volume overlay ───────────────────────────────────────
                  if (_volOverlay != null) ...[
                    const SizedBox(height: 8),
                    _buildVolumeOverlay(_volOverlay!, accent, sub),
                  ],

                  const SizedBox(height: 16),

                  // ─── Vincular QR ─────────────────────────────────────────
                  _buildQrButton(online, elevated, border, heading, accent, onAccent),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // WIDGETS INTERNOS
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildConnectionHeader(
    TvPlaybackState state,
    bool online,
    Color heading,
    Color sub,
    Color elevated,
    Color border,
    Color accent,
  ) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: online
                ? const Color(0xFF18C75A).withValues(alpha: 0.16)
                : elevated,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: online
                  ? const Color(0xFF18C75A).withValues(alpha: 0.6)
                  : border,
            ),
          ),
          child: Center(
            child: InutilIcon(
              InutilGlyph.liveTv,
              size: 22,
              color: online ? const Color(0xFF18C75A) : sub,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      state.tvName.isNotEmpty ? state.tvName : 'Mi Smart TV',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: heading,
                          fontSize: 16.5,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (online) ...[
                    const SizedBox(width: 8),
                    // 💚 PULSATING DOT
                    AnimatedBuilder(
                      animation: _pulseAnim,
                      builder: (_, __) => Opacity(
                        opacity: _pulseAnim.value,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFF18C75A),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                _connecting
                    ? 'Sincronizando con tu Smart TV...'
                    : (online
                        ? (TvRemoteService.instance.targetTvLanHost != null
                            ? 'Conectada · Red Local Ultra-Rápida (<5ms)'
                            : 'Conectada · Lista para recibir contenido')
                        : 'Desconectada · Abre Inutix TV en tu TV'),
                style: TextStyle(
                  color: online ? const Color(0xFF18C75A) : sub,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (online) ...[
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => TvRemoteService.instance.togglePlayOnTv(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: TvRemoteService.instance.playOnTv
                    ? const Color(0xFF18C75A).withValues(alpha: 0.16)
                    : elevated,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: TvRemoteService.instance.playOnTv
                      ? const Color(0xFF18C75A).withValues(alpha: 0.6)
                      : border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    TvRemoteService.instance.playOnTv
                        ? Icons.cast_connected_rounded
                        : Icons.smartphone_rounded,
                    size: 14,
                    color: TvRemoteService.instance.playOnTv
                        ? const Color(0xFF18C75A)
                        : sub,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    TvRemoteService.instance.playOnTv
                        ? 'Destino: TV'
                        : 'Destino: Móvil',
                    style: TextStyle(
                      color: TvRemoteService.instance.playOnTv
                          ? const Color(0xFF18C75A)
                          : sub,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
        IconButton(
          tooltip: 'Actualizar estado',
          icon: Icon(Icons.refresh_rounded, color: sub, size: 20),
          onPressed: () => TvRemoteService.instance.refreshTvStateNow(),
        ),
      ],
    );
  }

  // ─── Now Playing card ─────────────────────────────────────────────────────
  Widget _buildNowPlayingCard(
    TvPlaybackState state,
    Color elevated,
    Color border,
    Color heading,
    Color sub,
    Color accent,
    Color onAccent,
  ) {
    final hasEpisodes = state.episodeCount > 1;
    final hasPrev = hasEpisodes && state.episodeIndex > 0;
    final hasNext = hasEpisodes && state.episodeIndex < state.episodeCount - 1;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: elevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          // Poster + título
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 52,
                  height: 68,
                  child: state.poster.isNotEmpty
                      ? FastArtwork(
                          url: state.poster,
                          tier: ArtworkTier.thumbnail,
                          cacheWidth: 160,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          color: Colors.black38,
                          child: Center(
                            child: InutilIcon(InutilGlyph.liveTv,
                                size: 22, color: sub),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: heading,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      state.subtitle.isNotEmpty
                          ? state.subtitle
                          : (state.isLive
                              ? 'TV en Vivo'
                              : (state.isPlaying ? 'Reproduciendo' : 'En pausa')),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: sub, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // ── Scrubbar arrastrable ───────────────────────────────────────
          if (!state.isLive && state.durationSec > 0) ...[
            const SizedBox(height: 10),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: accent,
                inactiveTrackColor: sub.withValues(alpha: 0.2),
                thumbColor: accent,
                overlayColor: accent.withValues(alpha: 0.2),
              ),
              child: Slider(
                value: (_scrubValue ??
                        state.positionSec.toDouble())
                    .clamp(0.0, state.durationSec.toDouble()),
                min: 0,
                max: state.durationSec.toDouble(),
                onChanged: (v) => setState(() => _scrubValue = v),
                onChangeEnd: (v) {
                  final posSec = v.toInt();
                  TvRemoteService.instance.sendSeekAbsolute(posSec);
                  Future.delayed(const Duration(seconds: 2),
                      () => setState(() => _scrubValue = null));
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmtSec((_scrubValue?.toInt() ?? state.positionSec)),
                      style: TextStyle(color: sub, fontSize: 10.5)),
                  Text(_fmtSec(state.durationSec),
                      style: TextStyle(color: sub, fontSize: 10.5)),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],

          const SizedBox(height: 10),

          // ── Controles de reproducción ─────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // ⏮ Episodio anterior
              if (hasEpisodes)
                _mediaBtn(
                  icon: Icons.skip_previous_rounded,
                  label: 'Anterior',
                  onTap: hasPrev
                      ? () => _send('prev_episode', feedback: 'Episodio anterior')
                      : null,
                ),
              _mediaBtn(
                icon: Icons.replay_10_rounded,
                label: '-10s',
                onTap: () =>
                    _send('seek_relative', payload: {'seconds': -10}, feedback: '-10 s'),
              ),
              // ▶ / ⏸ Play/Pausa
              FilledButton(
                onPressed: () => _send('toggle_play',
                    feedback: state.isPlaying ? 'Pausa' : 'Play'),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: onAccent,
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(12),
                ),
                child: Icon(
                  state.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 24,
                ),
              ),
              _mediaBtn(
                icon: Icons.forward_10_rounded,
                label: '+10s',
                onTap: () =>
                    _send('seek_relative', payload: {'seconds': 10}, feedback: '+10 s'),
              ),
              // ⏭ Episodio siguiente o Detener
              if (hasEpisodes && hasNext)
                _mediaBtn(
                  icon: Icons.skip_next_rounded,
                  label: 'Siguiente',
                  onTap: () => _send('next_episode', feedback: 'Episodio siguiente'),
                ),
              _mediaBtn(
                icon: Icons.stop_rounded,
                label: 'Cerrar',
                onTap: () => _send('stop', feedback: 'Detenido en TV'),
              ),
            ],
          ),

          // ── Chips de velocidad (sólo VOD) ─────────────────────────────
          if (!state.isLive) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Velocidad  ',
                    style: TextStyle(
                        color: sub, fontSize: 11, fontWeight: FontWeight.w600)),
                ..._speeds.map((spd) {
                  final selected = _selectedSpeed == spd;
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedSpeed = spd);
                        TvRemoteService.instance.sendSetSpeed(spd);
                        _showFeedback('${_spdLabel(spd)} ▶');
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: selected
                              ? accent.withValues(alpha: 0.18)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: selected
                                ? accent
                                : sub.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          _spdLabel(spd),
                          style: TextStyle(
                            color: selected ? accent : sub,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _spdLabel(double s) =>
      s == s.truncateToDouble() ? '${s.toInt()}×' : '${s}×';

  // ─── Mode toggle ──────────────────────────────────────────────────────────
  Widget _buildModeToggle(
    Color elevated,
    Color border,
    Color heading,
    Color sub,
    Color accent,
  ) {
    return Row(
      children: [
        Text('Control Remoto',
            style: TextStyle(
                color: heading, fontSize: 15, fontWeight: FontWeight.w800)),
        const Spacer(),
        // Toggle D-Pad ↔ Trackpad
        Container(
          decoration: BoxDecoration(
            color: elevated,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _modeChip(
                  label: 'D-Pad',
                  icon: Icons.gamepad_rounded,
                  selected: !_trackpadMode,
                  onTap: () => _toggleMode(false),
                  accent: accent,
                  sub: sub),
              _modeChip(
                  label: 'Táctil',
                  icon: Icons.swipe_rounded,
                  selected: _trackpadMode,
                  onTap: () => _toggleMode(true),
                  accent: accent,
                  sub: sub),
            ],
          ),
        ),
      ],
    );
  }

  Widget _modeChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
    required Color accent,
    required Color sub,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? accent : sub),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: selected ? accent : sub,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  // ─── Trackpad gestual ─────────────────────────────────────────────────────
  Widget _buildTrackpad(
    Color elevated,
    Color border,
    Color heading,
    Color accent,
    Color onAccent,
  ) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          height: 190,
          decoration: BoxDecoration(
            color: elevated,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: border, width: 1.5),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            onTap: () => _sendDpad('center'),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.swipe_rounded, size: 36, color: heading.withValues(alpha: 0.3)),
                  const SizedBox(height: 8),
                  Text(
                    'Desliza para navegar\nToca para seleccionar',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: heading.withValues(alpha: 0.4),
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─── D-Pad clásico ────────────────────────────────────────────────────────
  Widget _buildDpad(
    BuildContext context,
    Color elevated,
    Color border,
    Color heading,
    Color accent,
    Color onAccent,
  ) {
    return Center(
      child: Container(
        width: 204,
        height: 204,
        decoration: BoxDecoration(
          color: elevated,
          shape: BoxShape.circle,
          border: Border.all(color: border, width: 1.5),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
                top: 6,
                child: _dpadBtn(
                    Icons.keyboard_arrow_up_rounded, () => _sendDpad('up'), heading)),
            Positioned(
                bottom: 6,
                child: _dpadBtn(Icons.keyboard_arrow_down_rounded,
                    () => _sendDpad('down'), heading)),
            Positioned(
                left: 6,
                child: _dpadBtn(Icons.keyboard_arrow_left_rounded,
                    () => _sendDpad('left'), heading)),
            Positioned(
                right: 6,
                child: _dpadBtn(Icons.keyboard_arrow_right_rounded,
                    () => _sendDpad('right'), heading)),
            Material(
              color: accent,
              shape: const CircleBorder(),
              elevation: 2,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _sendDpad('center'),
                child: SizedBox(
                  width: 58,
                  height: 58,
                  child: Center(
                    child: Text('OK',
                        style: TextStyle(
                            color: onAccent,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dpadBtn(IconData icon, VoidCallback onTap, Color color) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child:
            SizedBox(width: 52, height: 52, child: Icon(icon, color: color, size: 34)),
      ),
    );
  }

  // ─── Fila sistema: Atrás · Inicio · Buscar · Vol− · Vol+ ─────────────────
  Widget _buildSystemRow(
    Color elevated,
    Color border,
    Color heading,
    Color accent,
    Color onAccent,
  ) {
    return Row(
      children: [
        Expanded(
          child: _actionTile(
              icon: Icons.arrow_back_rounded,
              label: 'Atrás',
              onTap: () => _send('back', feedback: 'Atrás'),
              elevated: elevated,
              border: border,
              heading: heading),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _actionTile(
              icon: Icons.home_rounded,
              label: 'Inicio',
              onTap: () => _send('home', feedback: 'Inicio'),
              elevated: elevated,
              border: border,
              heading: heading),
        ),
        const SizedBox(width: 6),
        // Buscar: abre teclado en celular Y buscador en TV
        Expanded(
          child: _actionTile(
              icon: Icons.search_rounded,
              label: 'Buscar',
              onTap: _activateKeyboard,
              elevated: elevated,
              border: border,
              heading: heading),
        ),
        const SizedBox(width: 6),
        // Volumen −
        Expanded(
          child: _actionTile(
              icon: Icons.volume_down_rounded,
              label: 'Vol −',
              onTap: () => _volumeDelta(-5),
              elevated: elevated,
              border: border,
              heading: heading),
        ),
        const SizedBox(width: 6),
        // Volumen +
        Expanded(
          child: _actionTile(
              icon: Icons.volume_up_rounded,
              label: 'Vol +',
              onTap: () => _volumeDelta(5),
              elevated: elevated,
              border: border,
              heading: heading),
        ),
      ],
    );
  }

  // ─── Keyboard Bridge ──────────────────────────────────────────────────────
  Widget _buildKeyboardBridge(
    Color elevated,
    Color border,
    Color heading,
    Color sub,
    Color accent,
    Color onAccent,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.keyboard_rounded, color: accent, size: 20),
            const SizedBox(width: 8),
            Text('Buscador en TV',
                style: TextStyle(
                    color: heading, fontSize: 15, fontWeight: FontWeight.w800)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => setState(() {
                _keyboardMode = false;
                _kbController.clear();
              }),
              icon: const Icon(Icons.close_rounded, size: 16),
              label: const Text('Cerrar'),
              style:
                  TextButton.styleFrom(foregroundColor: sub, padding: EdgeInsets.zero),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: elevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: border),
          ),
          child: TextField(
            controller: _kbController,
            focusNode: _kbFocus,
            onChanged: _onKbChanged,
            onSubmitted: (_) => _kbSubmit(),
            textInputAction: TextInputAction.search,
            style: TextStyle(color: heading, fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Escribe aquí → aparece en la TV',
              hintStyle:
                  TextStyle(color: sub.withValues(alpha: 0.5), fontSize: 14),
              prefixIcon: Icon(Icons.search_rounded, color: sub),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_kbController.text.isNotEmpty)
                    IconButton(
                      icon: Icon(Icons.clear_rounded, color: sub, size: 20),
                      onPressed: _kbClear,
                    ),
                  IconButton(
                    icon: Icon(Icons.send_rounded, color: accent, size: 20),
                    onPressed: _kbSubmit,
                  ),
                ],
              ),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Lo que escribas aquí aparece automáticamente en el buscador de tu TV.',
          style: TextStyle(color: sub, fontSize: 11.5),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // ─── Secciones rápidas ────────────────────────────────────────────────────
  Widget _buildSectionsRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _sectionPill('📺 En Vivo',
              () => _send('nav_tab', payload: {'index': 1}, feedback: 'TV en Vivo')),
          const SizedBox(width: 8),
          _sectionPill('🎬 Cine',
              () => _send('nav_tab', payload: {'index': 2}, feedback: 'Películas')),
          const SizedBox(width: 8),
          _sectionPill('🍿 Series',
              () => _send('nav_tab', payload: {'index': 3}, feedback: 'Series')),
          const SizedBox(width: 8),
          _sectionPill('⚡ Anime',
              () => _send('nav_tab', payload: {'index': 4}, feedback: 'Anime')),
        ],
      ),
    );
  }

  // ─── Desconectado ─────────────────────────────────────────────────────────
  Widget _buildDisconnectedCard(
    Color elevated,
    Color border,
    Color heading,
    Color sub,
    Color accent,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: elevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: _connecting
          ? Row(
              children: [
                SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: accent)),
                const SizedBox(width: 14),
                Expanded(
                    child: Text(
                        'Conectando con tu Smart TV... Espera unos segundos.',
                        style: TextStyle(
                            color: heading,
                            fontSize: 13,
                            fontWeight: FontWeight.w600))),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Asegúrate de que tu Smart TV esté encendida con Inutix TV abierta en la misma red WiFi.\n\nTu cuenta gratuita incluye 1 celular + 1 Smart TV al mismo tiempo.',
                  style: TextStyle(color: sub, fontSize: 12.5, height: 1.4),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accent,
                    side: BorderSide(color: accent.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    setState(() => _connecting = true);
                    unawaited(TvRemoteService.instance.discoverTvLan().then((_) {
                      return TvRemoteService.instance.refreshTvStateNow();
                    }).whenComplete(() {
                      if (mounted) setState(() => _connecting = false);
                    }));
                  },
                  icon: const Icon(Icons.wifi_find_rounded, size: 18),
                  label: const Text('Buscar Smart TV en red local'),
                ),
              ],
            ),
    );
  }

  // ─── Volume overlay ───────────────────────────────────────────────────────
  Widget _buildVolumeOverlay(int vol, Color accent, Color sub) {
    return Row(
      children: [
        Icon(vol == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            color: accent, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: vol / 100,
              minHeight: 4,
              backgroundColor: sub.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation(accent),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('$vol%',
            style: TextStyle(
                color: accent, fontSize: 11.5, fontWeight: FontWeight.w700)),
      ],
    );
  }

  // ─── QR Button ────────────────────────────────────────────────────────────
  Widget _buildQrButton(
    bool online,
    Color elevated,
    Color border,
    Color heading,
    Color accent,
    Color onAccent,
  ) {
    return FilledButton.icon(
      onPressed: _openQrScanner,
      style: FilledButton.styleFrom(
        backgroundColor: online ? elevated : accent,
        foregroundColor: online ? heading : onAccent,
        padding: const EdgeInsets.symmetric(vertical: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: online ? BorderSide(color: border) : BorderSide.none,
        ),
      ),
      icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
      label: Text(
        online ? 'Vincular otra Smart TV por QR' : 'Vincular Smart TV con código QR',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }

  // ─── Shared micro-widgets ─────────────────────────────────────────────────

  Widget _actionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color elevated,
    required Color border,
    required Color heading,
  }) {
    return Material(
      color: elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: heading, size: 20),
              const SizedBox(height: 3),
              Text(label,
                  style: TextStyle(
                      color: heading,
                      fontSize: 10,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mediaBtn({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    final heading = AppColors.contentHeadingFor(context);
    final sub = AppColors.contentSubtitleFor(context);
    final disabled = onTap == null;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: disabled
                    ? sub.withValues(alpha: 0.3)
                    : heading,
                size: 22),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: disabled
                        ? sub.withValues(alpha: 0.3)
                        : sub,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _sectionPill(String title, VoidCallback onTap) {
    final elevated = AppColors.elevatedSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final heading = AppColors.contentHeadingFor(context);
    return Material(
      color: elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(title,
              style: TextStyle(
                  color: heading, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  String _fmtSec(int sec) {
    if (sec <= 0) return '0:00';
    final m = sec ~/ 60;
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
