import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/artwork_cache_service.dart';
import '../theme/app_ui.dart';
import 'dynamic_poster_canvas.dart';
import 'fast_artwork.dart';

/// Canvas en vivo estilo Spotify (v3.3.18).
///
/// Spotify no pinta la carátula quieta: al enfocarla empieza a reproducir
/// fragmentos del tema. Aquí igual — la tarjeta muestra el póster y, cuando se
/// [active] (foco del mando en Smart TV / Android TV, long-press en el teléfono,
/// o autoplay en el carrusel héroe), rota por los [stills] reales de la obra
/// (los stills TMDB que el relleno cruzado de v3.3.17 ya resuelve por episodio)
/// con crossfade lento y deriva Ken Burns, rematada por el velo de vidrio de
/// [PosterCanvasGlassOverlay].
///
/// Costo controlado a propósito:
/// - **Un solo** `AnimationController` por instancia, y sólo mientras hay algo
///   que animar (se crea perezosamente al activarse y se detiene al salir de
///   foco). En grillas esto significa ~1 tarjeta animando a la vez, porque el
///   foco del mando es exclusivo; en el teléfono sólo arranca con long-press.
/// - Las imágenes pasan por [FastArtwork] (RAM LRU → disco LRU), así que los
///   stills que la ficha ya mostró en la lista de episodios no se vuelven a
///   descargar.
/// - Sin stills => arte generado [DynamicPosterCanvas] (nunca un recuadro negro).
class LiveCanvasPreview extends StatefulWidget {
  /// Título de la obra: semilla del arte generado y del acento del velo.
  final String title;

  final String posterUrl;
  final String backdropUrl;

  /// Stills reales (TMDB) a modo de «momentos destacados». Menos de 2 => sin
  /// rotación: se queda en el póster/arte generado con el velo luminoso.
  final List<String> stills;

  /// `true` mientras la tarjeta debe animar (foco, long-press o héroe).
  final bool active;

  /// Máximo de stills en rotación (los reparte `VodItem.selectHighlightStills`).
  final int maxStills;

  /// Segundos por plano antes del siguiente crossfade.
  final double secondsPerSlide;

  /// Segundos del crossfade entre planos.
  final double crossfadeSeconds;

  /// `false` cuando la pantalla que incrusta el canvas ya pinta su propio velo
  /// de vidrio encima (la tarjeta de póster): evita duplicar el brillo.
  final bool showOverlay;

  /// Radio de recorte del lienzo: el de las tarjetas por defecto.
  final double radius;

  const LiveCanvasPreview({
    super.key,
    required this.title,
    this.posterUrl = '',
    this.backdropUrl = '',
    this.stills = const [],
    this.active = false,
    this.maxStills = 4,
    this.secondsPerSlide = 2.6,
    this.crossfadeSeconds = 0.65,
    this.showOverlay = true,
    this.radius = appArtworkRadius,
  });

  @override
  State<LiveCanvasPreview> createState() => _LiveCanvasPreviewState();
}

class _LiveCanvasPreviewState extends State<LiveCanvasPreview>
    with SingleTickerProviderStateMixin {
  AnimationController? _t;

  /// Los that actually cycle (recortados a [LiveCanvasPreview.maxStills]).
  List<String> get _slides {
    final src = widget.stills.where((u) => u.isNotEmpty).toList();
    if (src.length <= widget.maxStills) return src;
    return VodItem.selectHighlightStills(
      // Mismo selector determinista que usa el catálogo: así la rotación es
      // estable entre sesiones y no depende del orden en que llegó la red.
      [
        for (var i = 0; i < src.length; i++)
          VodEpisode(
            id: '$i',
            title: '',
            episodeNumber: i + 1,
            thumbnail: src[i],
          ),
      ],
      max: widget.maxStills,
    );
  }

  Duration get _cycleDuration =>
      Duration(milliseconds: (_secondsPerCycle() * 1000).round());

  double _secondsPerCycle() {
    final n = _slides.length;
    if (n < 2) return widget.secondsPerSlide;
    return n * widget.secondsPerSlide;
  }

  void _syncController() {
    final shouldRun = widget.active && _slides.length >= 2;
    if (shouldRun && _t == null) {
      _t = AnimationController(vsync: this, duration: _cycleDuration);
      _t!.repeat();
    } else if (shouldRun && _t != null) {
      if (_t!.duration != _cycleDuration) {
        _t!.duration = _cycleDuration;
      }
      if (!_t!.isAnimating) _t!.repeat();
    } else if (!shouldRun && _t != null) {
      _t!.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _syncController();
  }

  @override
  void didUpdateWidget(covariant LiveCanvasPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController();
  }

  @override
  void dispose() {
    _t?.dispose();
    super.dispose();
  }

  /// Póster/arte estático (el lienzo base debajo de la rotación).
  Widget _base(BuildContext context) {
    final url =
        widget.backdropUrl.isNotEmpty ? widget.backdropUrl : widget.posterUrl;
    final generated = DynamicPosterCanvas(
      title: widget.title,
      showText: false,
    );
    if (url.isEmpty) return generated;
    return FastArtwork(
      url: url,
      tier: ArtworkTier.backdrop,
      fit: BoxFit.cover,
      placeholder: generated,
      errorWidget: generated,
    );
  }

  Widget _slide(BuildContext context, String url, double opacity, double scale,
      Alignment alignment) {
    return Opacity(
      // 1.0 exacto deja el layer en opacidad total y evita un blend innecesario.
      opacity: opacity >= 0.999 ? 1.0 : opacity,
      child: Transform.scale(
        scale: scale,
        alignment: alignment,
        child: FastArtwork(
          url: url,
          tier: ArtworkTier.thumbnail,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final slides = _slides;
    final accent = DynamicPosterCanvas.accentForTitle(widget.title);
    final controller = _t;

    Widget core;
    if (controller == null || slides.length < 2) {
      core = _base(context);
    } else {
      core = AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final n = slides.length;
          // Avance dentro del ciclo completo [0,1) => plano actual + progreso.
          final pos = controller.value * n;
          final current = pos.floor() % n;
          final next = (current + 1) % n;
          final local = pos - pos.floor();

          // Crossfade: sólo en la última fracción del plano.
          final fadeWindow = widget.crossfadeSeconds / widget.secondsPerSlide;
          final mix = fadeWindow <= 0
              ? 0.0
              : ((local - (1 - fadeWindow)) / fadeWindow).clamp(0.0, 1.0);
          final eased = Curves.easeOutCubic.transform(mix);

          // Deriva Ken Burns lenta sobre el plano que manda.
          final drift = Curves.easeInOutSine.transform(local);
          final scale = 1.0 + 0.055 * drift;

          return Stack(
            fit: StackFit.expand,
            children: [
              _slide(context, slides[current], 1.0, scale, Alignment.center),
              if (eased > 0)
                _slide(
                  context,
                  slides[next],
                  eased,
                  1.0 + 0.055 * (drift - 1).abs(),
                  const Alignment(0.2, -0.2),
                ),
            ],
          );
        },
      );
    }

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            core,
            if (widget.showOverlay)
              Positioned.fill(
                child: PosterCanvasGlassOverlay(
                  accent: accent,
                  highlighted: widget.active,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Utilidad para las pantallas: stills ya conocidos de una ficha, sin red.
/// (El relleno cruzado de v3.3.17 los deja en `episode.thumbnail`.)
List<String> highlightStillsFor(VodItem item) =>
    VodItem.selectHighlightStills(item.episodes);
