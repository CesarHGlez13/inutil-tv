import 'package:flutter/material.dart';

/// Modos de tema compartidos con la familia Inútil (Inútil Music & InútilTV).
enum AppThemeMode {
  system,
  light,
  dark;

  String get code => name;

  String get labelEs => switch (this) {
        AppThemeMode.system => 'Sistema',
        AppThemeMode.light => 'Claro',
        AppThemeMode.dark => 'Oscuro',
      };

  ThemeMode get materialMode => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };

  static AppThemeMode fromCode(String? code) => switch (code) {
        'light' => AppThemeMode.light,
        'system' => AppThemeMode.system,
        _ => AppThemeMode.dark,
      };
}

/// Tratamiento de superficies compartidas por encabezados y barra de navegación
/// (idéntico al sistema visual de Inútil Music).
enum SurfaceBackgroundMode {
  accent,
  transparent,
  liquidGlass;

  String get code => name;

  String get labelEs => switch (this) {
        SurfaceBackgroundMode.accent => 'Acento',
        SurfaceBackgroundMode.transparent => 'Transparente',
        SurfaceBackgroundMode.liquidGlass => 'Liquid Glass',
      };

  bool get usesBackdrop => this != SurfaceBackgroundMode.accent;

  bool get isLiquidGlass => this == SurfaceBackgroundMode.liquidGlass;

  static SurfaceBackgroundMode fromCode(String? code) => switch (code) {
        'accent' => SurfaceBackgroundMode.accent,
        'transparent' => SurfaceBackgroundMode.transparent,
        'liquidGlass' => SurfaceBackgroundMode.liquidGlass,
        _ => SurfaceBackgroundMode.liquidGlass,
      };
}

/// Paleta curada de 18 acentos idéntica a Inútil Music.
/// Por defecto usa blanco monocromático puro (`#F5F7F5`) para una estética
/// editorial sobria, elegante y libre de neón chillón.
enum AppAccent {
  white,
  green,
  blue,
  purple,
  orange,
  red,
  yellow,
  pink,
  teal,
  cyan,
  indigo,
  lime,
  mint,
  magenta,
  coral,
  brown,
  lavender,
  ocean;

  String get code => name;

  String get labelEs => switch (this) {
        AppAccent.white => 'Blanco Puro',
        AppAccent.green => 'Verde',
        AppAccent.blue => 'Azul',
        AppAccent.purple => 'Morado',
        AppAccent.orange => 'Naranja',
        AppAccent.red => 'Rojo',
        AppAccent.yellow => 'Amarillo',
        AppAccent.pink => 'Rosa',
        AppAccent.teal => 'Turquesa',
        AppAccent.cyan => 'Cian',
        AppAccent.indigo => 'Índigo',
        AppAccent.lime => 'Lima',
        AppAccent.mint => 'Menta',
        AppAccent.magenta => 'Magenta',
        AppAccent.coral => 'Coral',
        AppAccent.brown => 'Ámbar',
        AppAccent.lavender => 'Lavanda',
        AppAccent.ocean => 'Océano',
      };

  Color get seedColor => switch (this) {
        AppAccent.white => const Color(0xFFF5F7F5),
        AppAccent.green => const Color(0xFF18C75A),
        AppAccent.blue => const Color(0xFF3D8BFF),
        AppAccent.purple => const Color(0xFFA66CFF),
        AppAccent.orange => const Color(0xFFFFA047),
        AppAccent.red => const Color(0xFFFF3B3F),
        AppAccent.yellow => const Color(0xFFFFD54F),
        AppAccent.pink => const Color(0xFFFF5C93),
        AppAccent.teal => const Color(0xFF2DD4BF),
        AppAccent.cyan => const Color(0xFF22D3EE),
        AppAccent.indigo => const Color(0xFF818CF8),
        AppAccent.lime => const Color(0xFFA3E635),
        AppAccent.mint => const Color(0xFF6EE7B7),
        AppAccent.magenta => const Color(0xFFD946EF),
        AppAccent.coral => const Color(0xFFFF6F61),
        AppAccent.brown => const Color(0xFF8D6E63),
        AppAccent.lavender => const Color(0xFFC4B5FD),
        AppAccent.ocean => const Color(0xFF38BDF8),
      };

  Color get darkColor => switch (this) {
        AppAccent.white => const Color(0xFF8E9891),
        AppAccent.green => const Color(0xFF0B8F43),
        AppAccent.blue => const Color(0xFF1F58B5),
        AppAccent.purple => const Color(0xFF6C2FC7),
        AppAccent.orange => const Color(0xFFC86A16),
        AppAccent.red => const Color(0xFFC62828),
        AppAccent.yellow => const Color(0xFFC49A00),
        AppAccent.pink => const Color(0xFFC52D65),
        AppAccent.teal => const Color(0xFF0F8F80),
        AppAccent.cyan => const Color(0xFF0E7490),
        AppAccent.indigo => const Color(0xFF4338CA),
        AppAccent.lime => const Color(0xFF4D7C0F),
        AppAccent.mint => const Color(0xFF047857),
        AppAccent.magenta => const Color(0xFF86198F),
        AppAccent.coral => const Color(0xFFB8322A),
        AppAccent.brown => const Color(0xFF4E342E),
        AppAccent.lavender => const Color(0xFF6D28D9),
        AppAccent.ocean => const Color(0xFF0369A1),
      };

  static AppAccent fromCode(String? code) => switch (code) {
        'white' => AppAccent.white,
        'green' => AppAccent.green,
        'blue' => AppAccent.blue,
        'purple' => AppAccent.purple,
        'orange' => AppAccent.orange,
        'red' => AppAccent.red,
        'yellow' => AppAccent.yellow,
        'pink' => AppAccent.pink,
        'teal' => AppAccent.teal,
        'cyan' => AppAccent.cyan,
        'indigo' => AppAccent.indigo,
        'lime' => AppAccent.lime,
        'mint' => AppAccent.mint,
        'magenta' => AppAccent.magenta,
        'coral' => AppAccent.coral,
        'brown' || 'amber' => AppAccent.brown,
        'lavender' => AppAccent.lavender,
        'ocean' => AppAccent.ocean,
        _ => AppAccent.white,
      };
}

@immutable
class AppAccentTheme extends ThemeExtension<AppAccentTheme> {
  const AppAccentTheme({required this.accent});

  final AppAccent accent;

  Color get seed => accent.seedColor;
  Color get dark => accent.darkColor;

  static AppAccentTheme fromAccent(AppAccent accent) =>
      AppAccentTheme(accent: accent);

  @override
  AppAccentTheme copyWith({AppAccent? accent}) =>
      AppAccentTheme(accent: accent ?? this.accent);

  @override
  AppAccentTheme lerp(ThemeExtension<AppAccentTheme>? other, double t) {
    if (other is! AppAccentTheme) return this;
    return t < 0.5 ? this : other;
  }
}

@immutable
class AppSurfaceTheme extends ThemeExtension<AppSurfaceTheme> {
  const AppSurfaceTheme({required this.backgroundMode});

  final SurfaceBackgroundMode backgroundMode;

  bool get isTransparent => backgroundMode == SurfaceBackgroundMode.transparent;
  bool get usesBackdrop => backgroundMode.usesBackdrop;
  bool get isLiquidGlass => backgroundMode.isLiquidGlass;

  @override
  AppSurfaceTheme copyWith({SurfaceBackgroundMode? backgroundMode}) =>
      AppSurfaceTheme(backgroundMode: backgroundMode ?? this.backgroundMode);

  @override
  AppSurfaceTheme lerp(ThemeExtension<AppSurfaceTheme>? other, double t) {
    if (other is! AppSurfaceTheme) return this;
    return t < 0.5 ? this : other;
  }
}
