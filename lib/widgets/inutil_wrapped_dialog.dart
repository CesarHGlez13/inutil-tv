import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/inutil_promo_popup_service.dart';
import '../services/inutil_wrapped_service.dart';
import '../theme/inutil_icons.dart';
import 'inutil_support_popup.dart';

/// Pop-up animado tipo Stories «Tu Año en InútilTV» (portado desde Inútil Music v2.4).
class InutilTvWrappedDialog extends StatefulWidget {
  const InutilTvWrappedDialog({
    required this.summary,
    required this.userName,
    this.myListCount = 0,
    super.key,
  });

  final InutilTvWrappedSummary summary;
  final String userName;
  final int myListCount;

  static Future<void> show(
    BuildContext context, {
    required InutilTvWrappedSummary summary,
    required String userName,
    int myListCount = 0,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar resumen',
      barrierColor: Colors.black.withValues(alpha: 0.86),
      transitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (_, __, ___) => InutilTvWrappedDialog(
        summary: summary,
        userName: userName,
        myListCount: myListCount,
      ),
      transitionBuilder: (_, animation, __, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<InutilTvWrappedDialog> createState() => _InutilTvWrappedDialogState();
}

class _InutilTvWrappedDialogState extends State<InutilTvWrappedDialog>
    with SingleTickerProviderStateMixin {
  static const int _slideCount = 5;
  static const Duration _slideDuration = Duration(milliseconds: 7000);

  late final AnimationController _progress;
  int _index = 0;

  static const _palettes = <List<Color>>[
    [Color(0xFF0A1412), Color(0xFF102A23), Color(0xFF070709)],
    [Color(0xFF130D1C), Color(0xFF28173F), Color(0xFF070709)],
    [Color(0xFF0A111A), Color(0xFF13283B), Color(0xFF070709)],
    [Color(0xFF1A100A), Color(0xFF3D1F11), Color(0xFF070709)],
    [Color(0xFF0C0C10), Color(0xFF181920), Color(0xFF070709)],
  ];

  static const _accents = <Color>[
    Color(0xFF34D399),
    Color(0xFFC084FC),
    Color(0xFF38BDF8),
    Color(0xFFFB923C),
    Color(0xFFF5F7F5),
  ];

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this, duration: _slideDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && _index < _slideCount - 1) {
          _goTo(_index + 1);
        }
      });
    _progress.forward();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _goTo(int next) {
    final clamped = next.clamp(0, _slideCount - 1);
    HapticFeedback.selectionClick();
    setState(() => _index = clamped);
    _progress
      ..reset()
      ..forward();
  }

  void _onTapUp(TapUpDetails d, double width) {
    if (d.localPosition.dx < width * 0.34) {
      if (_index > 0) {
        _goTo(_index - 1);
      } else {
        _progress
          ..reset()
          ..forward();
      }
    } else if (_index < _slideCount - 1) {
      _goTo(_index + 1);
    }
  }

  Future<void> _openSupport() async {
    final campaign =
        await InutilPromoPopupService.instance.nextRotatingCampaign();
    if (!mounted) return;
    await InutilSupportPopupDialog.show(context, campaign);
  }

  @override
  Widget build(BuildContext context) {
    final palette = _palettes[_index % _palettes.length];
    final accent = _accents[_index % _accents.length];
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Material(
      key: const ValueKey('inutil-tv-wrapped-dialog'),
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _onTapUp(d, constraints.maxWidth),
            onLongPressStart: (_) => _progress.stop(),
            onLongPressEnd: (_) => _progress.forward(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 520),
              curve: Curves.easeInOutCubic,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: palette,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      24,
                      topInset + 64,
                      24,
                      bottomInset + 24,
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 380),
                      child: KeyedSubtree(
                        key: ValueKey('tv-wrapped-slide-$_index'),
                        child: _buildSlide(_index, accent),
                      ),
                    ),
                  ),
                  Positioned(
                    top: topInset + 10,
                    left: 16,
                    right: 12,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: _progress,
                          builder: (_, __) => Row(
                            children: [
                              for (var i = 0; i < _slideCount; i++) ...[
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(99),
                                    child: LinearProgressIndicator(
                                      minHeight: 3,
                                      value: i < _index
                                          ? 1.0
                                          : i == _index
                                              ? _progress.value
                                              : 0.0,
                                      backgroundColor:
                                          Colors.white.withValues(alpha: 0.22),
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                        Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                                if (i < _slideCount - 1)
                                  const SizedBox(width: 5),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'INUTIX TV WRAPPED ${widget.summary.year}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              key: const ValueKey('tv-wrapped-close'),
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(
                                Icons.close_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSlide(int idx, Color accent) {
    final s = widget.summary;
    final name = widget.userName.trim().isNotEmpty
        ? widget.userName.trim().split(' ').first
        : 'Cinéfilo';

    switch (idx) {
      case 0:
        final timeLabel = s.totalHours >= 1
            ? '${s.totalHours.toStringAsFixed(1)} h'
            : '${math.max(1, s.totalMinutes)} min';
        return _slideFrame(
          accent: accent,
          eyebrow: 'TU AÑO EN PANTALLA',
          headline: s.hasViewingData
              ? '$name, pasaste\n$timeLabel viendo Inutix TV'
              : 'Hola $name,\ntu historia apenas comienza',
          body: s.hasViewingData
              ? 'Equivale a unas ${s.equivalentMovies} películas completas en '
                  '${s.activeDaysCount} días activos este ${s.year}.'
              : 'Empieza a ver películas, series, anime o TV en vivo y aquí '
                  'verás tus estadísticas anuales en tiempo real.',
          highlight: s.hasViewingData ? timeLabel : '🍿',
        );
      case 1:
        final top = s.topTitle;
        return _slideFrame(
          accent: accent,
          eyebrow: 'TU TÍTULO #1',
          headline: top != null ? top.title : 'Aún por coronar',
          body: top != null
              ? 'Tu obsesión en ${top.category}. Nadie te quitó el control cuando '
                  'tocaba reproducirlo.'
              : 'El título que más horas veas en Inutix TV aparecerá aquí como tu favorito.',
          highlight: top != null ? '#1' : '🎬',
        );
      case 2:
        final vibe = s.viewingScheduleVibe;
        return _slideFrame(
          accent: accent,
          eyebrow: 'TU HORARIO FAVORITO',
          headline: '${vibe.emoji} ${vibe.title}',
          body: vibe.subtitle,
          highlight: '${s.peakHour.toString().padLeft(2, '0')}:00',
        );
      case 3:
        final arch = s.viewerArchetype;
        return _slideFrame(
          accent: accent,
          eyebrow: 'TU PERSONALIDAD DE PANTALLA',
          headline: '${arch.emoji} ${arch.title}',
          body: arch.description,
          highlight: s.topCategory,
        );
      default:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'RESUMEN ${s.year}',
              style: TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Gracias por ser parte\nde la Familia Inutix',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w900,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Column(
                children: [
                  _statRow('Categoría favorita', s.topCategory),
                  const SizedBox(height: 10),
                  _statRow('Sesiones registradas', '${s.totalSessions}'),
                  const SizedBox(height: 10),
                  _statRow('Guardados en Mi Lista', '${widget.myListCount}'),
                ],
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _openSupport,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF070709),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const InutilIcon(
                InutilGlyph.heart,
                size: 18,
                color: Color(0xFF070709),
                filled: true,
              ),
              label: const Text(
                'Apoyar a la Familia Inutix',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
              ),
            ),
          ],
        );
    }
  }

  Widget _slideFrame({
    required Color accent,
    required String eyebrow,
    required String headline,
    required String body,
    required String highlight,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Text(
            highlight,
            style: TextStyle(
              color: accent,
              fontSize: 32,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.8,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          eyebrow,
          style: TextStyle(
            color: accent,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          headline,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 30,
            height: 1.12,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          body,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.78),
            fontSize: 15.5,
            height: 1.45,
          ),
        ),
      ],
    );
  }

  Widget _statRow(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 13.5,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      );
}
