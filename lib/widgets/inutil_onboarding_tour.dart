import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/inutil_icons.dart';

/// Recorrido guiado interactivo de bienvenida de InútilTV v3.1
/// (portado desde Inútil Music v2.4, repetible desde Ajustes → Acerca de).
class InutilOnboardingTour extends StatefulWidget {
  const InutilOnboardingTour({this.inactivityDays = 15, super.key});

  final int inactivityDays;

  static const String prefsKey = 'inutiltv_onboarding_completed_v1';

  static Future<bool> shouldShow() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) != true;
  }

  static Future<void> markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, true);
  }

  static Future<void> show(
    BuildContext context, {
    int inactivityDays = 15,
  }) async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 520),
        reverseTransitionDuration: const Duration(milliseconds: 360),
        pageBuilder: (_, __, ___) =>
            InutilOnboardingTour(inactivityDays: inactivityDays),
        transitionsBuilder: (_, animation, __, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 1.03, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    await markCompleted();
  }

  @override
  State<InutilOnboardingTour> createState() => _InutilOnboardingTourState();
}

class _TourStep {
  const _TourStep({
    required this.accent,
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.demo,
  });

  final Color accent;
  final String eyebrow;
  final String title;
  final String body;
  final WidgetBuilder demo;
}

class _InutilOnboardingTourState extends State<InutilOnboardingTour> {
  final PageController _pages = PageController();
  int _index = 0;

  late final List<_TourStep> _steps = <_TourStep>[
    _TourStep(
      accent: const Color(0xFFF5F7F5),
      eyebrow: 'BIENVENIDO',
      title: 'Hola, esto es\nInútilTV',
      body:
          'TV en vivo, cine, series y anime en un solo lugar con la misma '
          'estética minimalista de Inútil Music. Explora las demos interactivas.',
      demo: (_) => const _WelcomeTvDemo(),
    ),
    _TourStep(
      accent: const Color(0xFF34D399),
      eyebrow: 'TV EN VIVO VERIFICADA',
      title: '+1,180 canales\nsin señales caídas',
      body:
          'Deportes organizados por Liga MX, Champions, ESPN, F1 y más. '
          'Gira tu teléfono para pantalla completa real sin reproducción doble.',
      demo: (_) => const _LiveTvDemo(accent: Color(0xFF34D399)),
    ),
    _TourStep(
      accent: const Color(0xFF38BDF8),
      eyebrow: 'PRECARGA INSTANTÁNEA',
      title: 'Salta de capítulo\nsin esperar nada',
      body:
          'Mientras ves una serie o anime, InútilTV precarga en fondo los '
          'primeros minutos del siguiente capítulo para que el salto sea instantáneo.',
      demo: (_) => const _InstantPreloadDemo(accent: Color(0xFF38BDF8)),
    ),
    _TourStep(
      accent: const Color(0xFFC084FC),
      eyebrow: 'REPRODUCTOR PRO',
      title: 'Gestos, Omitir Intro\ny Temporizador',
      body:
          'Doble toque ±10s, desliza brillo o volumen, omite la intro con un '
          'toque o activa el Temporizador de sueño para dormir tranquilo.',
      demo: (_) => const _PlayerGesturesDemo(accent: Color(0xFFC084FC)),
    ),
    _TourStep(
      accent: const Color(0xFFF472B6),
      eyebrow: 'RESPALDO EN LA NUBE',
      title: 'Tu Lista e historial\nsiempre contigo',
      body:
          'Guarda películas, series y canales favoritos. Todo se respalda en tu '
          'cuenta Firebase de la Familia Inútil para que nunca lo pierdas.',
      demo: (_) => const _BookmarkDemo(accent: Color(0xFFF472B6)),
    ),
    _TourStep(
      accent: const Color(0xFFFBBF24),
      eyebrow: 'HAZLA TUYA',
      title: '18 colores y\nLiquid Glass',
      body:
          'Personaliza el color de acento, el estilo Liquid Glass y consulta tu '
          'Resumen del Año cuando quieras desde Ajustes.',
      demo: (_) => const _AccentPickerDemo(),
    ),
    _TourStep(
      accent: const Color(0xFF8B9CFF),
      eyebrow: 'MANTÉN TU CUENTA ACTIVA',
      title: 'Tu acceso gratuito\nse cuida solo',
      body:
          'Los cupos gratuitos son limitados: si no abres la app durante '
          '${widget.inactivityDays} días, tu acceso se pausa automáticamente. '
          'Tu lista e historial siempre quedan a salvo en la nube.',
      demo: (_) => _InactivityInfoDemo(
        accent: const Color(0xFF8B9CFF),
        days: widget.inactivityDays,
      ),
    ),
  ];

  bool get _isLast => _index == _steps.length - 1;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    HapticFeedback.selectionClick();
    _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeOutCubic,
    );
  }

  void _next() {
    if (_isLast) {
      _finish();
    } else {
      _goTo(_index + 1);
    }
  }

  void _finish() {
    HapticFeedback.mediumImpact();
    unawaited(InutilOnboardingTour.markCompleted());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_index];
    final compact = MediaQuery.of(context).size.height < 700;

    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index > 0) _goTo(_index - 1);
      },
      child: Scaffold(
        key: const ValueKey('onboarding-tour'),
        backgroundColor: const Color(0xFF070709),
        body: AnimatedContainer(
          duration: const Duration(milliseconds: 650),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.75),
              radius: 1.25,
              colors: [
                Color.alphaBlend(
                  step.accent.withValues(alpha: 0.12),
                  const Color(0xFF070709),
                ),
                const Color(0xFF070709),
              ],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 10, 10, 0),
                  child: Row(
                    children: [
                      Text(
                        '${_index + 1} de ${_steps.length}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 220),
                        opacity: _isLast ? 0 : 1,
                        child: TextButton(
                          key: const ValueKey('onboarding-skip'),
                          onPressed: _isLast ? null : _finish,
                          child: Text(
                            'Saltar',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.78),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: _steps.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) => _TourPage(
                      key: ValueKey('onboarding-page-$i'),
                      step: _steps[i],
                      compact: compact,
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _steps.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: i == _index ? 22 : 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: i == _index
                              ? step.accent
                              : Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                  child: Row(
                    children: [
                      if (_index > 0)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: IconButton.outlined(
                            key: const ValueKey('onboarding-back'),
                            onPressed: () => _goTo(_index - 1),
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              color: Colors.white,
                            ),
                            style: IconButton.styleFrom(
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.2),
                              ),
                              minimumSize: const Size(54, 54),
                            ),
                          ),
                        ),
                      Expanded(
                        child: SizedBox(
                          height: 54,
                          child: FilledButton(
                            key: ValueKey(
                              _isLast ? 'onboarding-finish' : 'onboarding-next',
                            ),
                            onPressed: _next,
                            style: FilledButton.styleFrom(
                              backgroundColor: step.accent,
                              foregroundColor: const Color(0xFF070709),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            child: Text(
                              _isLast ? '¡Empezar a ver!' : 'Siguiente',
                            ),
                          ),
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
    );
  }
}

class _TourPage extends StatelessWidget {
  const _TourPage({required this.step, required this.compact, super.key});

  final _TourStep step;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final demoMinHeight = math.min(
          constraints.maxHeight * (compact ? 0.34 : 0.4),
          240.0,
        );
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 26),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(minHeight: demoMinHeight),
                  child: Center(child: step.demo(context)),
                ),
                SizedBox(height: compact ? 18 : 26),
                Text(
                  step.eyebrow,
                  style: TextStyle(
                    color: step.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  step.title,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 26 : 30,
                    height: 1.12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  step.body,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DemoCard extends StatelessWidget {
  const _DemoCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 370),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: child,
    );
  }
}

class _WelcomeTvDemo extends StatefulWidget {
  const _WelcomeTvDemo();

  @override
  State<_WelcomeTvDemo> createState() => _WelcomeTvDemoState();
}

class _WelcomeTvDemoState extends State<_WelcomeTvDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _spin,
      builder: (_, __) {
        final pulse = (math.sin(_spin.value * math.pi * 4) + 1) / 2;
        return SizedBox(
          width: 196,
          height: 196,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.rotate(
                angle: _spin.value * math.pi * 2,
                child: Container(
                  width: 186,
                  height: 186,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: 0.55),
                        const Color(0xFF38BDF8).withValues(alpha: 0.45),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                width: 166,
                height: 166,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF070709),
                ),
              ),
              Container(
                width: 112 + 8 * pulse,
                height: 112 + 8 * pulse,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.22 + 0.14 * pulse),
                      blurRadius: 34,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Center(
                  child: InutilIcon(
                    InutilGlyph.liveTv,
                    size: 50,
                    color: Color(0xFF070709),
                    filled: true,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LiveTvDemo extends StatelessWidget {
  const _LiveTvDemo({required this.accent});
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return _DemoCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE53935).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '● EN VIVO',
                  style: TextStyle(
                    color: Color(0xFFFF6B6B),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Deportes · 1080p verificado',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in const [
                'Liga MX',
                'Champions',
                'ESPN · Fox',
                'NFL · NBA',
                'F1 · Motor',
              ])
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: accent.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      color: accent,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InstantPreloadDemo extends StatefulWidget {
  const _InstantPreloadDemo({required this.accent});
  final Color accent;

  @override
  State<_InstantPreloadDemo> createState() => _InstantPreloadDemoState();
}

class _InstantPreloadDemoState extends State<_InstantPreloadDemo> {
  int _ep = 1;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    return _DemoCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.bolt_rounded, color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Reproduciendo Ep. $_ep',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Ep. ${_ep + 1} precargado',
                  style: TextStyle(
                    color: accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                HapticFeedback.lightImpact();
                setState(() => _ep = _ep >= 12 ? 1 : _ep + 1);
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF070709),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.skip_next_rounded, size: 18),
              label: Text(
                'Saltar al Ep. ${_ep + 1} (instantáneo)',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerGesturesDemo extends StatefulWidget {
  const _PlayerGesturesDemo({required this.accent});
  final Color accent;

  @override
  State<_PlayerGesturesDemo> createState() => _PlayerGesturesDemoState();
}

class _PlayerGesturesDemoState extends State<_PlayerGesturesDemo> {
  bool _sleepOn = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    return _DemoCard(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _pill(Icons.replay_10_rounded, '-10s', Colors.white70),
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _sleepOn = !_sleepOn);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _sleepOn
                    ? accent.withValues(alpha: 0.24)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _sleepOn ? accent : Colors.white24,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InutilIcon(
                    InutilGlyph.sleepTimer,
                    size: 22,
                    color: _sleepOn ? accent : Colors.white,
                    filled: _sleepOn,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _sleepOn ? '30m activo' : 'Toca aquí',
                    style: TextStyle(
                      color: _sleepOn ? accent : Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _pill(Icons.fast_forward_rounded, 'Intro', Colors.white70),
        ],
      ),
    );
  }

  Widget _pill(IconData icon, String label, Color color) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      );
}

class _BookmarkDemo extends StatefulWidget {
  const _BookmarkDemo({required this.accent});
  final Color accent;

  @override
  State<_BookmarkDemo> createState() => _BookmarkDemoState();
}

class _BookmarkDemoState extends State<_BookmarkDemo> {
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    return _DemoCard(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: accent.withValues(alpha: 0.16),
            ),
            child: Center(
              child: InutilIcon(InutilGlyph.cloud, size: 24, color: accent),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Respaldo automático',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _saved ? 'Guardado en Mi Lista y nube' : 'Toca el marcador →',
                  style: TextStyle(
                    color: _saved ? accent : Colors.white60,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              setState(() => _saved = !_saved);
            },
            icon: Icon(
              _saved ? Icons.bookmark_added_rounded : Icons.bookmark_add_outlined,
              color: _saved ? accent : Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _AccentPickerDemo extends StatefulWidget {
  const _AccentPickerDemo();

  @override
  State<_AccentPickerDemo> createState() => _AccentPickerDemoState();
}

class _AccentPickerDemoState extends State<_AccentPickerDemo> {
  static const _swatches = [
    Color(0xFFF5F7F5),
    Color(0xFF1DB954),
    Color(0xFF38BDF8),
    Color(0xFFA78BFA),
    Color(0xFFF472B6),
    Color(0xFFFBBF24),
  ];
  int _sel = 0;

  @override
  Widget build(BuildContext context) {
    return _DemoCard(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < _swatches.length; i++)
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _sel = i);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: _sel == i ? 36 : 30,
                height: _sel == i ? 36 : 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _swatches[i],
                  border: Border.all(
                    color: _sel == i ? Colors.white : Colors.white24,
                    width: _sel == i ? 2.6 : 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InactivityInfoDemo extends StatelessWidget {
  const _InactivityInfoDemo({required this.accent, required this.days});
  final Color accent;
  final int days;

  @override
  Widget build(BuildContext context) {
    return _DemoCard(
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.16),
              border: Border.all(color: accent.withValues(alpha: 0.45)),
            ),
            child: Center(
              child: InutilIcon(InutilGlyph.shield, size: 24, color: accent),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Usa InútilTV al menos una vez cada $days días para mantener '
              'tu cupo gratuito activo de forma automática.',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
