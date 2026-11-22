import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_ui.dart';

/// Canvas dinámico cinematográfico de InútilTV (v3.3.16 T3).
///
/// Cumple dos funciones:
/// 1. Como portada generada (carga y fallback cuando falta artwork): reemplaza
///    los recuadros grises planos con un canvas procedural determinista por
///    título (paleta curada + halos radiales + curva de luz + monograma +
///    brillo diagonal de estudio + tipografía limpia).
/// 2. Expone [accentForTitle] y [PosterCanvasGlassOverlay] para dar a TODAS
///    las portadas del catálogo un marco luminoso de vidrio dinámico (borde
///    especular + halo ambiental + destello en foco/pulsación) manteniendo
///    60–120 FPS sin `AnimationController` por tarjeta.
class DynamicPosterCanvas extends StatelessWidget {
  final String title;

  /// Subtítulo opcional (año/género) pintado bajo el título.
  final String subtitle;

  /// `false` => solo el arte generado (para contenedores que ya muestran el
  /// título en otro lado, como el héroe del carrusel).
  final bool showText;

  const DynamicPosterCanvas({
    super.key,
    required this.title,
    this.subtitle = '',
    this.showText = true,
  });

  /// Color de acento determinista por título para ambientar halos y bordes.
  static Color accentForTitle(String title) => _paletteFor(_fnv1a(title));

  @override
  Widget build(BuildContext context) {
    final seed = _fnv1a(title);
    final palette = _paletteFor(seed);
    final secondary = _secondaryFor(seed);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trimmed = title.trim();
    final monogram = trimmed.isNotEmpty ? trimmed[0].toUpperCase() : 'I';

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(appArtworkRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette.withValues(alpha: isDark ? 0.62 : 0.38),
            secondary.withValues(alpha: isDark ? 0.34 : 0.20),
            AppColors.elevatedSurfaceFor(context),
          ],
          stops: const [0.0, 0.48, 1.0],
        ),
      ),
      child: CustomPaint(
        painter: _CanvasPosterPainter(
          seed: seed,
          accent: palette,
          secondary: secondary,
          isDark: isDark,
          monogram: monogram,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          child: !showText
              ? const SizedBox.expand()
              : Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.contentHeadingFor(context),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.15,
                        height: 1.18,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.contentSubtitleFor(context),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// Capa ligera de acabado dinámico en `CustomPaint` sobre cualquier póster real:
/// añade un bisel luminoso superior, sutil tinte ambiental derivado del título
/// y un destello diagonal de estudio al enfocar o presionar la tarjeta.
class PosterCanvasGlassOverlay extends StatelessWidget {
  final Color accent;
  final bool highlighted;

  const PosterCanvasGlassOverlay({
    super.key,
    required this.accent,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _PosterGlassOverlayPainter(
          accent: accent,
          highlighted: highlighted,
        ),
      ),
    );
  }
}

/// Hash FNV-1a determinista (estable entre procesos y plataformas).
int _fnv1a(String s) {
  var hash = 0x811c9dc5;
  for (final unit in s.toLowerCase().codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// Paleta cinematográfica curada: tonos profundos y atractivos, nunca chillones.
Color _paletteFor(int seed) {
  const palette = [
    Color(0xFF6D5DFB), // índigo eléctrico
    Color(0xFF1EA896), // esmeralda cine
    Color(0xFFD15B47), // carmesí cálido
    Color(0xFF3A7BD5), // azul cobalto
    Color(0xFF9C4DCC), // amatista
    Color(0xFF2E8B57), // verde bosque
    Color(0xFFD49A3A), // ámbar dorado
    Color(0xFF4B6CB7), // zafiro nocturno
  ];
  return palette[seed % palette.length];
}

Color _secondaryFor(int seed) {
  const secondary = [
    Color(0xFF1F2B6C),
    Color(0xFF103F47),
    Color(0xFF4C1D24),
    Color(0xFF162C4E),
    Color(0xFF38194E),
    Color(0xFF133A26),
    Color(0xFF4A3112),
    Color(0xFF1E293B),
  ];
  return secondary[(seed >> 3) % secondary.length];
}

class _CanvasPosterPainter extends CustomPainter {
  final int seed;
  final Color accent;
  final Color secondary;
  final bool isDark;
  final String monogram;

  _CanvasPosterPainter({
    required this.seed,
    required this.accent,
    required this.secondary,
    required this.isDark,
    required this.monogram,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.clipRect(rect);

    // 1. Halo radial luminoso superior (aura de estudio)
    final cx1 = size.width * (0.18 + ((seed >> 5) % 58) / 100);
    final cy1 = size.height * (0.08 + ((seed >> 11) % 34) / 100);
    final r1 = size.shortestSide * (0.68 + ((seed >> 17) % 24) / 100);
    final haloPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          accent.withValues(alpha: isDark ? 0.36 : 0.24),
          accent.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx1, cy1), radius: r1));
    canvas.drawCircle(Offset(cx1, cy1), r1, haloPaint);

    // 2. Segundo punto de luz complementario en el tercio medio
    final cx2 = size.width * (0.55 + ((seed >> 7) % 38) / 100);
    final cy2 = size.height * (0.48 + ((seed >> 13) % 28) / 100);
    final r2 = size.shortestSide * (0.45 + ((seed >> 19) % 18) / 100);
    final halo2 = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: isDark ? 0.10 : 0.08),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx2, cy2), radius: r2));
    canvas.drawCircle(Offset(cx2, cy2), r2, halo2);

    // 3. Curva orgánica de luz (cinta cinematográfica)
    final ribbon = Path()
      ..moveTo(-size.width * 0.1, size.height * (0.62 + ((seed >> 3) % 16) / 100))
      ..cubicTo(
        size.width * 0.32,
        size.height * (0.28 + ((seed >> 9) % 18) / 100),
        size.width * 0.68,
        size.height * (0.76 - ((seed >> 6) % 18) / 100),
        size.width * 1.12,
        size.height * (0.36 + ((seed >> 15) % 20) / 100),
      );
    canvas.drawPath(
      ribbon,
      Paint()
        ..color = accent.withValues(alpha: isDark ? 0.42 : 0.28)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke,
    );

    // 4. Monograma tipográfico sutil de marca de agua en el tercio superior
    final tp = TextPainter(
      text: TextSpan(
        text: monogram,
        style: TextStyle(
          fontSize: math.min(size.width * 0.62, size.height * 0.42),
          fontWeight: FontWeight.w900,
          color: Colors.white.withValues(alpha: isDark ? 0.075 : 0.09),
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(
        (size.width - tp.width) * 0.5,
        size.height * 0.14,
      ),
    );

    // 5. Brillo diagonal de cristal en esquina superior izquierda
    final sheen = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.white.withValues(alpha: isDark ? 0.13 : 0.18),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.45));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height * 0.45), sheen);

    // 6. Viñeta inferior para contraste tipográfico
    final vignette = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          (isDark ? const Color(0xFF06070A) : Colors.white)
              .withValues(alpha: 0.72),
        ],
        stops: const [0.35, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, vignette);
  }

  @override
  bool shouldRepaint(covariant _CanvasPosterPainter oldDelegate) =>
      oldDelegate.seed != seed ||
      oldDelegate.isDark != isDark ||
      oldDelegate.monogram != monogram;
}

class _PosterGlassOverlayPainter extends CustomPainter {
  final Color accent;
  final bool highlighted;

  _PosterGlassOverlayPainter({
    required this.accent,
    required this.highlighted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Bisel superior luminoso (da profundidad de canvas sobre vidrio)
    final topRim = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: highlighted ? 0.24 : 0.11),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, 18));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 18), topRim);

    // Sutil resplandor cromático inferior vinculado al título
    final bottomAura = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [
          accent.withValues(alpha: highlighted ? 0.26 : 0.10),
          Colors.transparent,
        ],
        stops: const [0.0, 0.45],
      ).createShader(rect);
    canvas.drawRect(rect, bottomAura);

    // Destello especular diagonal cuando la tarjeta recibe foco (TV) o toque
    if (highlighted) {
      final sheenPath = Path()
        ..moveTo(0, size.height * 0.28)
        ..lineTo(size.width * 0.55, 0)
        ..lineTo(size.width * 0.85, 0)
        ..lineTo(0, size.height * 0.52)
        ..close();
      canvas.drawPath(
        sheenPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.20),
              Colors.white.withValues(alpha: 0.02),
            ],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PosterGlassOverlayPainter oldDelegate) =>
      oldDelegate.accent != accent || oldDelegate.highlighted != highlighted;
}
