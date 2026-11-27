import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/artwork_cache_service.dart';
import '../services/watch_history.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import 'fast_artwork.dart';
import 'tv_focusable.dart';

/// Riel "Seguir viendo" sobrio estilo Inútil Music con botón Play blanco puro
/// y barra de progreso minimalista.
class ContinueWatchingRail extends StatelessWidget {
  final List<WatchProgress> history;
  final void Function(WatchProgress entry) onResume;
  final void Function(WatchProgress entry) onRemove;
  final VoidCallback onClear;
  final FocusNode? upFocusNode;

  const ContinueWatchingRail({
    super.key,
    required this.history,
    required this.onResume,
    required this.onRemove,
    required this.onClear,
    this.upFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) return const SizedBox.shrink();
    final subColor = AppColors.contentSubtitleFor(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            appPagePaddingHorizontal,
            10,
            10,
            appSectionTitleGap,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Seguir viendo',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: appSectionTitleStyle(context),
                ),
              ),
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                  foregroundColor: subColor,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Limpiar',
                  style: TextStyle(
                    color: subColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 158,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            cacheExtent: 500,
            addAutomaticKeepAlives: false,
            padding: const EdgeInsets.symmetric(
              horizontal: appPagePaddingHorizontal,
              vertical: 8,
            ),
            itemCount: history.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) => _buildCard(context, history[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildCard(BuildContext context, WatchProgress entry) {
    final img = entry.backdrop.isNotEmpty ? entry.backdrop : entry.poster;
    final accent = AppColors.accentFor(context);

    return RepaintBoundary(
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.arrowUp &&
              upFocusNode != null) {
            upFocusNode!.requestFocus();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TvFocusable(
          onTap: () => onResume(entry),
          onLongPress: () => _confirmRemove(context, entry),
          borderRadius: BorderRadius.circular(14),
          focusScale: 1.04,
          child: Container(
        width: 222,
        decoration: BoxDecoration(
          color: AppColors.elevatedSurfaceFor(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.cardBorderFor(context),
            width: 0.8,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FastArtwork(
              url: img,
              tier: ArtworkTier.backdrop,
              cacheWidth: 480,
              fit: BoxFit.cover,
              errorWidget: const ColoredBox(color: AppColors.carbonElevated),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.14),
                    Colors.black.withValues(alpha: 0.56),
                    const Color(0xFF070709).withValues(alpha: 0.94),
                  ],
                  stops: const [0.18, 0.68, 1.0],
                ),
              ),
            ),
            Center(
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.playbackPrimaryBackground.withValues(
                    alpha: 0.94,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: AppColors.playbackPrimaryForeground,
                  size: 24,
                ),
              ),
            ),
            Positioned(
              left: 11,
              right: 11,
              bottom: 24,
              child: Text(
                entry.label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Positioned(
              left: 11,
              right: 11,
              bottom: 8,
              child: Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 3,
              child: LinearProgressIndicator(
                value: entry.fraction,
                minHeight: 3,
                backgroundColor: Colors.white.withValues(alpha: 0.16),
                valueColor: AlwaysStoppedAnimation(accent),
              ),
            ),
          ],
        ),
      ),
      ),
      ),
    );
  }

  void _confirmRemove(BuildContext context, WatchProgress entry) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '¿Quitar de "Seguir viendo"?',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: Text(entry.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onRemove(entry);
            },
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
  }
}
