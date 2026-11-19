import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Métricas editoriales y tipografía compartidas con Inútil Music.
const double appPagePaddingHorizontal = 16.0;
const double appSectionGap = 20.0;
const double appSectionTitleGap = 10.0;
const double appCardRadius = 16.0;
const double appArtworkRadius = 12.0;
const double appNavPillRadius = 28.0;
const double appListCardIconSize = 44.0;
const double appListCardIconRadius = 14.0;

TextStyle appTabTitleStyle(BuildContext context) {
  return Theme.of(context).textTheme.headlineSmall!.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.65,
        color: AppColors.contentHeadingFor(context),
      );
}

TextStyle appSectionTitleStyle(BuildContext context) {
  return Theme.of(context).textTheme.titleMedium!.copyWith(
        fontSize: 17.5,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.35,
        color: AppColors.contentHeadingFor(context),
      );
}

TextStyle appListCardTitleStyle(BuildContext context) {
  return Theme.of(context).textTheme.titleSmall!.copyWith(
        fontSize: 14.5,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.15,
        color: AppColors.contentHeadingFor(context),
      );
}

TextStyle appListCardSubtitleStyle(BuildContext context) {
  return Theme.of(context).textTheme.bodySmall!.copyWith(
        fontSize: 12,
        color: AppColors.contentSubtitleFor(context),
        height: 1.3,
      );
}
