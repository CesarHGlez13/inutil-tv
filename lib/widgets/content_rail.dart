import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/tv_mode_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import 'poster_card.dart';

/// Riel horizontal editorial estilo Inútil Music:
/// - Título limpio (`appSectionTitleStyle`), sin barras neón ni badges saturados.
/// - Tarjetas 2:3 con proporciones precisas y cero recortes.
class ContentRail extends StatelessWidget {
  final String title;
  final List<VodItem> items;
  final void Function(VodItem item) onTap;
  final VoidCallback? onMore;
  final String moreLabel;
  final String? subtitle;
  final bool loading;

  const ContentRail({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.onMore,
    this.moreLabel = 'Ver todo',
    this.subtitle,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!loading && items.isEmpty) return const SizedBox.shrink();
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: appSectionTitleStyle(context),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: TextStyle(color: subColor, fontSize: 11.5),
                      ),
                  ],
                ),
              ),
              if (onMore != null)
                TextButton(
                  onPressed: onMore,
                  style: TextButton.styleFrom(
                    foregroundColor: subColor,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        moreLabel,
                        style: TextStyle(
                          color: subColor,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right_rounded, size: 17, color: subColor),
                    ],
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 252,
          child: loading
              ? _buildSkeletonRail(context)
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  cacheExtent: TvModeService.instance.isTv ? 360 : 640,
                  addAutomaticKeepAlives: false,
                  padding: const EdgeInsets.symmetric(
                    horizontal: appPagePaddingHorizontal,
                    vertical: 8,
                  ),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 14),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return PosterCard(
                      key: ValueKey(item.id),
                      item: item,
                      width: 128,
                      height: 188,
                      onTap: () => onTap(item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSkeletonRail(BuildContext context) {
    final surface = AppColors.elevatedSurfaceFor(context);
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: appPagePaddingHorizontal),
      itemCount: 5,
      separatorBuilder: (_, __) => const SizedBox(width: 12),
      itemBuilder: (_, __) => Container(
        width: 128,
        height: 188,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(appArtworkRadius),
        ),
      ),
    );
  }
}
