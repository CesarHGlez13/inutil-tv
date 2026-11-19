import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/artwork_cache_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import 'fast_artwork.dart';
import 'tv_focusable.dart';

/// Tarjeta editorial de póster vertical (relación estricta 2:3) de InútilTV v3.2.1.
///
/// Optimizada para 60–120 FPS en cuadrículas y rieles:
/// - Aislada en [RepaintBoundary] y sin `AnimationController` por tarjeta.
/// - Usa [FastArtwork] (RAM LRU + Disco persistente LRU + TMDB `w342` +
///   decodificación acotada a 320px).
/// - Evita `LayoutBuilder` cuando `expandInGrid` o `height` están definidos.
/// - CERO empalmes ni desbordamientos en cuadrícula.
class PosterCard extends StatefulWidget {
  final VodItem item;
  final VoidCallback onTap;

  /// Ancho fijo cuando se usa dentro de un riel horizontal (`ContentRail`).
  /// Si es `null` o [expandInGrid] es `true`, ocupa el 100% de la celda del grid.
  final double? width;

  /// Alto fijo del póster (solo cuando se usa fuera de un GridView).
  final double? height;

  /// En `GridView` se adapta automáticamente a la altura de la celda (cero empalmes).
  final bool expandInGrid;

  /// Progreso de reproducción 0.0 – 1.0 (opcional).
  final double progress;

  /// Subtítulo alternativo opcional.
  final String? subtitleOverride;

  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width,
    this.height,
    this.expandInGrid = false,
    this.progress = 0,
    this.subtitleOverride,
  });

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  static final _emojiPrefixRe = RegExp(r'^[🎬📺⚡🔥🎞️✨🧸]+\s*');
  bool _pressed = false;

  bool get _hasGenuineRating {
    final r = widget.item.rating.trim();
    if (r.isEmpty || r == '0.0' || r == '0') return false;
    if (widget.item.provider == 'pelisflix' && r == '8.5') return false;
    if (widget.item.provider == 'jkanime' && r == '8.8') return false;
    final val = double.tryParse(r);
    return val != null && val > 0 && val <= 10;
  }

  String _cleanSubtitle() {
    if (widget.subtitleOverride != null &&
        widget.subtitleOverride!.isNotEmpty) {
      return widget.subtitleOverride!;
    }
    final item = widget.item;
    final cleanGenre = item.genre
        .replaceAll(_emojiPrefixRe, '')
        .split('·')
        .first
        .trim();
    if (item.year.isNotEmpty && cleanGenre.isNotEmpty) {
      return '${item.year} · $cleanGenre';
    }
    if (item.year.isNotEmpty) return item.year;
    return cleanGenre;
  }

  Widget _buildColumn(
    BuildContext context,
    Color accent,
    Color titleColor,
    Color subColor,
    String sub, {
    required bool useExpanded,
  }) {
    final posterBox = _buildPosterArtwork(context, accent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: useExpanded ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (useExpanded)
          Expanded(child: posterBox)
        else if (widget.height != null)
          SizedBox(
            height: widget.height,
            width: double.infinity,
            child: posterBox,
          )
        else
          AspectRatio(aspectRatio: 2 / 3, child: posterBox),
        const SizedBox(height: 7),
        Text(
          widget.item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: _pressed ? accent : titleColor,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.15,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          sub.isNotEmpty
              ? sub
              : (widget.item.isSeries ? 'Serie' : 'Película'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: subColor,
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            height: 1.15,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(context);
    final titleColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final sub = _cleanSubtitle();

    // Ruta rápida sin LayoutBuilder para el 99% de los casos (GridView y ContentRail)
    Widget body;
    if (widget.expandInGrid) {
      body = _buildColumn(
        context,
        accent,
        titleColor,
        subColor,
        sub,
        useExpanded: true,
      );
    } else if (widget.height != null) {
      body = _buildColumn(
        context,
        accent,
        titleColor,
        subColor,
        sub,
        useExpanded: false,
      );
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final hasBoundedHeight =
              constraints.hasBoundedHeight && constraints.maxHeight.isFinite;
          return _buildColumn(
            context,
            accent,
            titleColor,
            subColor,
            sub,
            useExpanded: hasBoundedHeight,
          );
        },
      );
    }

    return RepaintBoundary(
      child: TvFocusable(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(appArtworkRadius),
        focusScale: 1.045,
        pressScale: 0.96,
        onFocusChange: (hasFocus) {
          if (_pressed != hasFocus) {
            setState(() => _pressed = hasFocus);
          }
        },
        child: widget.width != null
            ? SizedBox(width: widget.width, child: body)
            : body,
      ),
    );
  }

  Widget _buildPosterArtwork(BuildContext context, Color accent) {
    final item = widget.item;
    final cardSurface = AppColors.elevatedSurfaceFor(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(appArtworkRadius),
        color: cardSurface,
        border: Border.all(
          color: _pressed
              ? accent.withValues(alpha: 0.65)
              : AppColors.cardBorderFor(context),
          width: _pressed ? 1.1 : 0.75,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(appArtworkRadius - 0.5),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FastArtwork(
              url: item.poster,
              tier: ArtworkTier.poster,
              cacheWidth: 320,
              fit: BoxFit.cover,
              errorWidget: _buildPlaceholder(context),
            ),

            // Sutil degradado superior/inferior para legibilidad sin opacar la carátula
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x38000000),
                      Color(0x00000000),
                      Color(0x00000000),
                      Color(0x8C000000),
                    ],
                    stops: [0.0, 0.22, 0.72, 1.0],
                  ),
                ),
              ),
            ),

            // Rating real en vidrio sobrio (solo si proviene de TMDB/fuente real)
            if (_hasGenuineRating)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xAD000000),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: const Color(0x24FFFFFF),
                      width: 0.6,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        size: 10.5,
                        color: AppColors.ratingGold,
                      ),
                      const SizedBox(width: 2.5),
                      Text(
                        item.rating,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Etiqueta minimalista de tipo para Anime en resultados mixtos
            if (item.isAnime)
              Positioned(
                bottom: 7,
                left: 7,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xB8000000),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0x29FFFFFF),
                      width: 0.6,
                    ),
                  ),
                  child: const Text(
                    'ANIME',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),

            // Indicador de reproducción al presionar
            if (_pressed)
              Container(
                color: const Color(0x52000000),
                alignment: Alignment.center,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.playbackPrimaryBackground,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: AppColors.playbackPrimaryForeground,
                    size: 24,
                  ),
                ),
              ),

            // Barra de progreso "Seguir viendo"
            if (widget.progress > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 3,
                child: ColoredBox(
                  color: Colors.black54,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: widget.progress.clamp(0.0, 1.0),
                      child: ColoredBox(color: accent),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    final surface = AppColors.elevatedSurfaceFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    return Container(
      color: surface,
      padding: const EdgeInsets.all(10),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.movie_outlined,
              color: subColor.withValues(alpha: 0.45),
              size: 28,
            ),
            const SizedBox(height: 6),
            Text(
              widget.item.title,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: subColor.withValues(alpha: 0.8),
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
