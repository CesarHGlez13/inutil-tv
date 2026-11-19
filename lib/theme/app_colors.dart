import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Paleta y constructores de tema 100% alineados con Inútil Music.
///
/// Negro carbón puro (`#070709` / `#0C0C0F` / `#14141A`), acento blanco
/// monocromático por defecto (`#F5F7F5`) personalizable con los 18 acentos,
/// superficies sobrias con bordes ultrafinos y controles primarios en blanco
/// puro con texto carbón (`#07110A`).
abstract final class AppColors {
  static const carbonScaffold = Color(0xFF070709);
  static const carbonSurface = Color(0xFF0C0C0F);
  static const carbonElevated = Color(0xFF14141A);
  static const lightScaffold = Color(0xFFF5F8F6);

  static const playbackPrimaryBackground = Colors.white;
  static const playbackPrimaryForeground = Color(0xFF07110A);
  static const liveRed = Color(0xFFE53935);
  static const ratingGold = Color(0xFFE8B949);

  static Color accentFor(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppAccentTheme>();
    if (theme.brightness == Brightness.dark) {
      return ext?.seed ?? theme.colorScheme.primary;
    }
    return ext?.dark ?? theme.colorScheme.primary;
  }

  static Color accentSeedFor(BuildContext context) {
    return Theme.of(context).extension<AppAccentTheme>()?.seed ??
        Theme.of(context).colorScheme.primary;
  }

  static Color accentDarkFor(BuildContext context) {
    return Theme.of(context).extension<AppAccentTheme>()?.dark ??
        Theme.of(context).colorScheme.primaryContainer;
  }

  static Color onAccentFor(BuildContext context) {
    final accent = accentFor(context);
    return ThemeData.estimateBrightnessForColor(accent) == Brightness.light
        ? playbackPrimaryForeground
        : Colors.white;
  }

  static SurfaceBackgroundMode surfaceBackgroundModeFor(BuildContext context) {
    return Theme.of(context).extension<AppSurfaceTheme>()?.backgroundMode ??
        SurfaceBackgroundMode.liquidGlass;
  }

  static Color cardSurfaceFor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = accentSeedFor(context);
    final isDark = theme.brightness == Brightness.dark;
    if (isDark) {
      return Color.alphaBlend(
        accent.withValues(alpha: 0.045),
        carbonSurface,
      );
    }
    return Color.alphaBlend(
      accent.withValues(alpha: 0.04),
      colors.surface,
    );
  }

  static Color elevatedSurfaceFor(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentSeedFor(context);
    if (theme.brightness == Brightness.dark) {
      return Color.alphaBlend(
        accent.withValues(alpha: 0.055),
        carbonElevated,
      );
    }
    return theme.colorScheme.surfaceContainerHighest;
  }

  static Color cardBorderFor(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = accentFor(context);
    if (isDark) {
      return Color.alphaBlend(
        accent.withValues(alpha: 0.14),
        Colors.white.withValues(alpha: 0.09),
      );
    }
    return Color.alphaBlend(
      accent.withValues(alpha: 0.14),
      Colors.black.withValues(alpha: 0.09),
    );
  }

  static Color inputSurfaceFor(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentSeedFor(context);
    if (theme.brightness == Brightness.dark) {
      return Color.alphaBlend(
        accent.withValues(alpha: 0.04),
        const Color(0xFF131318),
      );
    }
    return Color.alphaBlend(
      accent.withValues(alpha: 0.04),
      const Color(0xFFE9ECEA),
    );
  }

  static Color contentHeadingFor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? const Color(0xFFF6F7F8)
        : const Color(0xFF111315);
  }

  static Color contentSubtitleFor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.dark
        ? const Color(0xFF8F96A3)
        : const Color(0xFF5A6270);
  }

  static Color dividerFor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.08);
  }

  /// Construye el tema oscuro oficial de la familia Inútil (Carbon Black).
  static ThemeData buildDarkTheme({
    required AppAccent accent,
    required SurfaceBackgroundMode surfaceBackgroundMode,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent.seedColor,
      brightness: Brightness.dark,
    ).copyWith(
      surface: carbonSurface,
      surfaceContainerHighest: carbonElevated,
      primary: accent.seedColor,
      onPrimary: ThemeData.estimateBrightnessForColor(accent.seedColor) ==
              Brightness.light
          ? playbackPrimaryForeground
          : Colors.white,
      primaryContainer: accent.darkColor,
      secondary: accent.darkColor,
      tertiary: accent.seedColor,
      onSurface: const Color(0xFFF5F7F5),
      onSurfaceVariant: const Color(0xFF949BA8),
      outlineVariant: const Color(0xFF23252D),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      extensions: [
        AppAccentTheme.fromAccent(accent),
        AppSurfaceTheme(backgroundMode: surfaceBackgroundMode),
      ],
      scaffoldBackgroundColor: carbonScaffold,
      appBarTheme: const AppBarTheme(
        backgroundColor: carbonScaffold,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Color(0xFFF5F7F5),
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: Color.alphaBlend(
          accent.seedColor.withValues(alpha: 0.045),
          carbonSurface,
        ),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Color.alphaBlend(
          accent.seedColor.withValues(alpha: 0.05),
          const Color(0xFF0E0E13),
        ),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF0C0C10),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF17181E),
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF131318),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Color(0xFF38BDF8), width: 3.0);
            }
            return BorderSide.none;
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const Color(0xFF38BDF8).withValues(alpha: 0.24);
            }
            return null;
          }),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Color(0xFF38BDF8), width: 3.0);
            }
            return null;
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const Color(0xFF38BDF8).withValues(alpha: 0.20);
            }
            return null;
          }),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Color(0xFF38BDF8), width: 2.0);
            }
            return BorderSide.none;
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const Color(0xFF38BDF8).withValues(alpha: 0.18);
            }
            return null;
          }),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Color(0xFF38BDF8), width: 2.2);
            }
            return BorderSide.none;
          }),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.white.withValues(alpha: 0.07),
        thickness: 0.8,
      ),
    );
  }

  /// Construye el tema claro oficial de la familia Inútil.
  static ThemeData buildLightTheme({
    required AppAccent accent,
    required SurfaceBackgroundMode surfaceBackgroundMode,
  }) {
    final lightPrimary = accent == AppAccent.white
        ? const Color(0xFF181A1F)
        : accent.darkColor;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent.seedColor,
      brightness: Brightness.light,
    ).copyWith(
      surface: Colors.white,
      surfaceContainerHighest: const Color(0xFFEBEFF0),
      primary: lightPrimary,
      onPrimary: Colors.white,
      primaryContainer: accent.seedColor.withValues(alpha: 0.18),
      secondary: lightPrimary,
      tertiary: accent.seedColor,
      onSurface: const Color(0xFF111315),
      onSurfaceVariant: const Color(0xFF5A6270),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      extensions: [
        AppAccentTheme.fromAccent(accent),
        AppSurfaceTheme(backgroundMode: surfaceBackgroundMode),
      ],
      scaffoldBackgroundColor: lightScaffold,
      appBarTheme: const AppBarTheme(
        backgroundColor: lightScaffold,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Color(0xFF111315),
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF181A1F),
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
