import 'dart:ui';
import 'package:flutter/material.dart';

import '../services/tv_mode_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Superficie translúcida / Liquid Glass compartida con el lenguaje visual
/// de Inútil Music para la barra de navegación flotante, encabezados y HUD
/// del reproductor. Respeta `SurfaceBackgroundMode` (`liquidGlass`, `transparent`,
/// `accent`) de forma fluida en todos los dispositivos Android y escritorio.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blurSigma;
  final Color? colorOverride;
  final Color? borderOverride;
  final bool forceGlass;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.padding,
    this.blurSigma = 14,
    this.colorOverride,
    this.borderOverride,
    this.forceGlass = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final mode = AppColors.surfaceBackgroundModeFor(context);
    final accent = AppColors.accentSeedFor(context);
    final useBlur = forceGlass || mode.usesBackdrop;

    final Color bgColor;
    final Color borderColor;
    if (colorOverride != null) {
      bgColor = colorOverride!;
    } else if (forceGlass || mode.isLiquidGlass) {
      bgColor = (isDark ? const Color(0xFF101116) : Colors.white)
          .withValues(alpha: isDark ? 0.68 : 0.76);
    } else if (mode == SurfaceBackgroundMode.transparent) {
      bgColor = Color.alphaBlend(
        accent.withValues(alpha: 0.06),
        (isDark ? const Color(0xFF0E0F14) : Colors.white)
            .withValues(alpha: isDark ? 0.56 : 0.68),
      );
    } else {
      bgColor = Color.alphaBlend(
        accent.withValues(alpha: 0.09),
        isDark ? const Color(0xFF0E0F14) : Colors.white,
      );
    }

    if (borderOverride != null) {
      borderColor = borderOverride!;
    } else if (forceGlass || mode.isLiquidGlass) {
      borderColor = (isDark ? Colors.white : Colors.black)
          .withValues(alpha: isDark ? 0.16 : 0.10);
    } else {
      borderColor = AppColors.cardBorderFor(context);
    }

    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor, width: 0.9),
        gradient: (forceGlass || mode.isLiquidGlass)
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  (isDark ? Colors.white : Colors.white)
                      .withValues(alpha: isDark ? 0.08 : 0.35),
                  Colors.transparent,
                  Colors.black.withValues(alpha: isDark ? 0.14 : 0.03),
                ],
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.10),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );

    if (!useBlur) {
      return RepaintBoundary(
        child: ClipRRect(borderRadius: borderRadius, child: box),
      );
    }

    // En Smart TV / TV Box conservamos el vidrio esmerilado pero con sigma
    // compacto (6–8) y TileMode.clamp: ~70 % menos píxeles muestreados en GPU.
    final effectiveSigma = TvModeService.instance.isTv
        ? (blurSigma * 0.45).clamp(5.0, 8.0)
        : blurSigma;

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: effectiveSigma,
            sigmaY: effectiveSigma,
            tileMode: TileMode.clamp,
          ),
          child: box,
        ),
      ),
    );
  }
}
