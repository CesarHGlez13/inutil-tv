import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/tv_mode_service.dart';

import '../models/models.dart';
import '../services/artwork_cache_service.dart';
import '../services/play_target.dart';
import '../services/tv_remote_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import 'dynamic_poster_canvas.dart';
import 'fast_artwork.dart';
import 'live_canvas_preview.dart';
import 'tv_focusable.dart';

/// Carrusel Hero editorial de InútilTV v3.2.1 — optimizado para 120 FPS:
/// - Imagen HD TMDB con [FastArtwork] (RAM/Disco LRU + `w780`) + prefetch de
///   la siguiente diapositiva.
/// - Pausa automática de `_kenBurns` y del temporizador al cambiar de pestaña
///   (`active: false`) y cancelación segura de timers al hacer swipe.
class HeroCarousel extends StatefulWidget {
  final List<VodItem> featured;
  final void Function(VodItem item) onPlay;
  final void Function(VodItem item) onDetails;
  final bool active;

  const HeroCarousel({
    super.key,
    required this.featured,
    required this.onPlay,
    required this.onDetails,
    this.active = true,
  });

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<HeroCarousel>
    with SingleTickerProviderStateMixin {
  static const _autoMs = 8000;

  late final PageController _pageController;
  late final AnimationController _kenBurns;
  int _currentIndex = 0;
  Timer? _autoTimer;
  Timer? _resumeTimer;
  bool _interacting = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _kenBurns = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _autoMs),
    );
    _prefetchSlides();
    if (widget.active) _startTimer();
  }

  void _prefetchSlides() {
    if (widget.featured.isEmpty) return;
    final urls = widget.featured
        .map((v) => v.backdrop.isNotEmpty ? v.backdrop : v.poster)
        .where((u) => u.isNotEmpty);
    unawaited(
      ArtworkCacheService.instance.prefetchUrls(
        urls,
        tier: ArtworkTier.backdrop,
        maxConcurrent: 3,
        limit: 6,
      ),
    );
  }

  void _startTimer() {
    _autoTimer?.cancel();
    if (!widget.active || widget.featured.length <= 1) return;
    _kenBurns.forward(from: 0);
    _autoTimer = Timer.periodic(const Duration(milliseconds: _autoMs), (_) {
      if (!mounted || _interacting || !widget.active) return;
      final next = (_currentIndex + 1) % widget.featured.length;
      final isTv = TvModeService.instance.isTv;
      if (isTv) {
        setState(() {
          _currentIndex = next;
          _kenBurns.forward(from: 0);
        });
      } else {
        if (!_pageController.hasClients) return;
        _pageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 650),
          curve: Curves.fastOutSlowIn,
        );
      }
    });
  }

  void _pause() {
    _autoTimer?.cancel();
    _resumeTimer?.cancel();
    _kenBurns.stop();
    _interacting = true;
  }

  void _resume() {
    if (!mounted || !widget.active) return;
    _interacting = false;
    _startTimer();
  }

  void _prevSlide({bool fromTv = false}) {
    _autoTimer?.cancel();
    _resumeTimer?.cancel();
    if (widget.featured.isEmpty) return;
    final prev = (_currentIndex - 1 + widget.featured.length) % widget.featured.length;
    setState(() {
      _currentIndex = prev;
      if (widget.active) _kenBurns.forward(from: 0);
    });
    if (_pageController.hasClients) {
      if (fromTv) {
        _pageController.jumpToPage(prev);
      } else {
        _pageController.animateToPage(
          prev,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  void _nextSlide({bool fromTv = false}) {
    _autoTimer?.cancel();
    _resumeTimer?.cancel();
    if (widget.featured.isEmpty) return;
    final next = (_currentIndex + 1) % widget.featured.length;
    setState(() {
      _currentIndex = next;
      if (widget.active) _kenBurns.forward(from: 0);
    });
    if (_pageController.hasClients) {
      if (fromTv) {
        _pageController.jumpToPage(next);
      } else {
        _pageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  void didUpdateWidget(covariant HeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.featured.length != widget.featured.length) {
      _currentIndex = 0;
      _prefetchSlides();
      if (widget.active) _startTimer();
    }
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        _interacting = false;
        _startTimer();
      } else {
        _pause();
      }
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _resumeTimer?.cancel();
    _kenBurns.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.featured.isEmpty) return const SizedBox.shrink();
    final accent = AppColors.accentFor(context);
    final isTv = TvModeService.of(context);
    final carouselHeight = isTv ? 370.0 : 310.0;

    return Column(
      children: [
        SizedBox(
          height: carouselHeight,
          child: isTv
              ? _buildTvHero(context, accent, carouselHeight)
              : _buildMobileHero(context, accent, carouselHeight),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.featured.length, (i) {
            final active = i == _currentIndex;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: active ? (isTv ? 28 : 24) : 6,
              height: isTv ? 5 : 4,
              decoration: BoxDecoration(
                color: active
                    ? accent
                    : AppColors.contentSubtitleFor(context)
                        .withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ],
    );
  }

  /// Experiencia Smart TV: botones CTA anclados que NUNCA se desmontan ni pierden
  /// el foco al cambiar de diapositiva. El arte y los metadatos hacen cross-fade
  /// suave con [AnimatedSwitcher] sin provocar saltos hacia el riel inferior.
  Widget _buildTvHero(
    BuildContext context,
    Color accent,
    double carouselHeight,
  ) {
    final item = widget.featured[_currentIndex % widget.featured.length];
    final image = item.backdrop.isNotEmpty ? item.backdrop : item.poster;

    return Stack(
      children: [
        // 1. Tarjeta visual del slide con AnimatedSwitcher
        Container(
          margin: const EdgeInsets.symmetric(
            horizontal: appPagePaddingHorizontal,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: AppColors.carbonElevated,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.48),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Cross-fade cinemático del fondo y metadatos
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 340),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    fit: StackFit.expand,
                    children: [
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  ),
                  transitionBuilder: (child, animation) =>
                      FadeTransition(opacity: animation, child: child),
                  child: KeyedSubtree(
                    key: ValueKey('tv-hero-${item.id}'),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (image.isNotEmpty)
                          AnimatedBuilder(
                            animation: _kenBurns,
                            builder: (context, child) {
                              final t = widget.active ? _kenBurns.value : 0.02;
                              return Transform.scale(
                                scale: 1.0 + 0.06 * t,
                                alignment: Alignment.center,
                                child: child,
                              );
                            },
                            child: FastArtwork(
                              url: image,
                              tier: ArtworkTier.backdrop,
                              cacheWidth: 1280,
                              fit: BoxFit.cover,
                              placeholder: _buildDegradado(title: item.title),
                              errorWidget: _buildFallback(
                                portada: item.poster == image ? '' : item.poster,
                                title: item.title,
                              ),
                            ),
                          )
                        else
                          _buildFallback(portada: item.poster, title: item.title),

                        // Degradado cinematográfico de alto contraste
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.18),
                                Colors.black.withValues(alpha: 0.22),
                                Colors.black.withValues(alpha: 0.78),
                                const Color(0xFF070709).withValues(alpha: 0.96),
                              ],
                              stops: const [0.0, 0.35, 0.72, 1.0],
                            ),
                          ),
                        ),

                        // Metadatos y título display
                        Positioned(
                          left: 24,
                          right: 24,
                          bottom: 74,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.2),
                                        width: 0.6,
                                      ),
                                    ),
                                    child: Text(
                                      item.isSeries
                                          ? (item.isAnime ? 'ANIME' : 'SERIE')
                                          : 'DESTACADO',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ),
                                  if (item.rating.isNotEmpty &&
                                      item.rating != '0.0') ...[
                                    const SizedBox(width: 8),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.star_rounded,
                                          size: 14,
                                          color: AppColors.ratingGold,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          item.rating,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  if (item.year.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      item.year,
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.75),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                  if (item.duration.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      item.duration,
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.7),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.5,
                                  height: 1.12,
                                ),
                              ),
                              if (item.overview.isNotEmpty) ...[
                                const SizedBox(height: 5),
                                Text(
                                  item.overview,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.72),
                                    fontSize: 12.5,
                                    height: 1.32,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 2. Botones de acción anclados fijos (NUNCA se desmontan)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 18,
                  child: Row(
                    children: [
                      // Botón Reproducir fijo
                      Focus(
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                            _prevSlide(fromTv: true);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TvFocusable(
                          key: const ValueKey('hero-tv-play-btn'),
                          onTap: () => widget.onPlay(
                            widget.featured[_currentIndex % widget.featured.length],
                          ),
                          borderRadius: BorderRadius.circular(24),
                          focusColor: accent,
                          focusScale: 1.05,
                          child: ListenableBuilder(
                            listenable: TvRemoteService.instance,
                            builder: (context, _) {
                              final toTv = PlayTarget.isTvDestination(context);
                              return Container(
                                decoration: BoxDecoration(
                                  color: AppColors.playbackPrimaryBackground,
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 10,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      toTv
                                          ? Icons.cast_rounded
                                          : Icons.play_arrow_rounded,
                                      color:
                                          AppColors.playbackPrimaryForeground,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      toTv ? 'Reproducir en TV' : 'Reproducir',
                                      style: const TextStyle(
                                        color:
                                            AppColors.playbackPrimaryForeground,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Botón Detalles fijo
                      Focus(
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.arrowRight) {
                            _nextSlide(fromTv: true);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TvFocusable(
                          key: const ValueKey('hero-tv-details-btn'),
                          onTap: () => widget.onDetails(
                            widget.featured[_currentIndex % widget.featured.length],
                          ),
                          borderRadius: BorderRadius.circular(24),
                          focusColor: accent,
                          focusScale: 1.05,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.2),
                                width: 0.8,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.info_outline_rounded,
                                  color: Colors.white,
                                  size: 16,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'Detalles',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Progreso visual Ken Burns al pie
                if (widget.featured.length > 1)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 2,
                    child: ColoredBox(
                      color: Colors.white.withValues(alpha: 0.08),
                      child: AnimatedBuilder(
                        animation: _kenBurns,
                        builder: (context, _) => Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: widget.active ? _kenBurns.value : 0.0,
                            child: ColoredBox(
                              color: accent.withValues(alpha: 0.85),
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

        // 3. Flechas de navegación fija lateral para Smart TV
        if (widget.featured.length > 1) ...[
          Positioned(
            left: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: TvFocusable(
                key: const ValueKey('hero-tv-prev-arrow'),
                onTap: () => _prevSlide(fromTv: true),
                borderRadius: BorderRadius.circular(20),
                focusColor: accent,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
                  child: const Icon(
                    Icons.chevron_left_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: TvFocusable(
                key: const ValueKey('hero-tv-next-arrow'),
                onTap: () => _nextSlide(fromTv: true),
                borderRadius: BorderRadius.circular(20),
                focusColor: accent,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
                  child: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Experiencia Móvil / Tablet: carrusel con gestos táctiles fluidos mediante PageView.
  Widget _buildMobileHero(
    BuildContext context,
    Color accent,
    double carouselHeight,
  ) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification) {
          _pause();
        } else if (n is ScrollEndNotification) {
          _resumeTimer?.cancel();
          _resumeTimer = Timer(const Duration(milliseconds: 2500), _resume);
        }
        return false;
      },
      child: PageView.builder(
        controller: _pageController,
        itemCount: widget.featured.length,
        onPageChanged: (i) => setState(() {
          _currentIndex = i;
          if (widget.active) _kenBurns.forward(from: 0);
        }),
        itemBuilder: (context, index) =>
            _buildHeroSlide(context, widget.featured[index], index),
      ),
    );
  }

  Widget _buildHeroSlide(BuildContext context, VodItem item, int index) {
    final image = item.backdrop.isNotEmpty ? item.backdrop : item.poster;
    final isActive = index == _currentIndex;
    final accent = AppColors.accentFor(context);

    return RepaintBoundary(
      child: GestureDetector(
        onTap: () => widget.onDetails(item),
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(
            horizontal: appPagePaddingHorizontal,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: AppColors.carbonElevated,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isActive ? 0.48 : 0.25),
                blurRadius: isActive ? 18 : 10,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (item.highlightStills.length >= 2)
                  LiveCanvasPreview(
                    title: item.title,
                    posterUrl: item.poster,
                    backdropUrl: image,
                    stills: item.highlightStills,
                    active: false,
                    radius: 20,
                  )
                else if (image.isNotEmpty)
                  AnimatedBuilder(
                    animation: _kenBurns,
                    builder: (context, child) {
                      final t =
                          (isActive && widget.active) ? _kenBurns.value : 0.02;
                      return Transform.scale(
                        scale: 1.0 + 0.07 * t,
                        alignment: Alignment.center,
                        child: child,
                      );
                    },
                    child: FastArtwork(
                      url: image,
                      tier: ArtworkTier.backdrop,
                      cacheWidth: 860,
                      fit: BoxFit.cover,
                      placeholder: _buildDegradado(title: item.title),
                      errorWidget: _buildFallback(
                        portada: item.poster == image ? '' : item.poster,
                        title: item.title,
                      ),
                    ),
                  )
                else
                  _buildFallback(portada: item.poster, title: item.title),

                // Gradiente editorial suave hacia negro carbón
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.22),
                        Colors.black.withValues(alpha: 0.78),
                        const Color(0xFF070709).withValues(alpha: 0.96),
                      ],
                      stops: const [0.0, 0.35, 0.72, 1.0],
                    ),
                  ),
                ),

                // Contenido superpuesto
                Positioned(
                  left: 18,
                  right: 18,
                  bottom: 18,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.2),
                                width: 0.6,
                              ),
                            ),
                            child: Text(
                              item.isSeries
                                  ? (item.isAnime ? 'ANIME' : 'SERIE')
                                  : 'DESTACADO',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                          if (item.rating.isNotEmpty &&
                              item.rating != '0.0' &&
                              !(item.provider == 'jkanime' &&
                                  item.rating == '8.8')) ...[
                            const SizedBox(width: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.star_rounded,
                                  size: 13,
                                  color: AppColors.ratingGold,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  item.rating,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (item.year.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              item.year,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.75),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (item.duration.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              item.duration,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          height: 1.12,
                        ),
                      ),
                      if (item.overview.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          item.overview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.72),
                            fontSize: 12,
                            height: 1.32,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () => widget.onPlay(item),
                            child: ListenableBuilder(
                              listenable: TvRemoteService.instance,
                              builder: (context, _) {
                                final toTv =
                                    PlayTarget.isTvDestination(context);
                                return Container(
                                  decoration: BoxDecoration(
                                    color: AppColors.playbackPrimaryBackground,
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        toTv
                                            ? Icons.cast_rounded
                                            : Icons.play_arrow_rounded,
                                        color: AppColors
                                            .playbackPrimaryForeground,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        toTv
                                            ? 'Reproducir en TV'
                                            : 'Reproducir',
                                        style: const TextStyle(
                                          color: AppColors
                                              .playbackPrimaryForeground,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          GestureDetector(
                            onTap: () => widget.onDetails(item),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  width: 0.8,
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'Detalles',
                                    style: TextStyle(
                                      color: Colors.white,
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

                if (widget.featured.length > 1)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 2,
                    child: ColoredBox(
                      color: Colors.white.withValues(alpha: 0.08),
                      child: AnimatedBuilder(
                        animation: _kenBurns,
                        builder: (context, _) => Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: isActive ? _kenBurns.value : 0.0,
                            child: ColoredBox(
                              color: accent.withValues(alpha: 0.85),
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
      ),
    );
  }

  /// Fondo del héroe cuando la imagen no llegó: primero prueba la portada
  /// (vive en otro servidor y suele estar ya guardada en el teléfono) y si
  /// tampoco hay portada muestra un canvas dinámico en vez de un recuadro gris.
  Widget _buildFallback({String portada = '', String title = ''}) {
    if (portada.isNotEmpty) {
      return FastArtwork(
        url: portada,
        tier: ArtworkTier.poster,
        cacheWidth: 520,
        fit: BoxFit.cover,
        errorWidget: _buildDegradado(title: title),
      );
    }
    return _buildDegradado(title: title);
  }

  Widget _buildDegradado({String title = ''}) {
    if (title.isNotEmpty) {
      // T3 (v3.3.16): canvas determinista; el título ya va en el overlay.
      return DynamicPosterCanvas(title: title, showText: false);
    }
    final accent = AppColors.accentFor(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.30),
            AppColors.carbonElevated,
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.movie_outlined, size: 44, color: Colors.white24),
      ),
    );
  }
}
