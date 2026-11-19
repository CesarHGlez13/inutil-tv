import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Iconografía geométrica exclusiva de la familia Inútil (Inútil Music & InútilTV).
///
/// Cada glifo se dibuja sobre un lienzo preciso 24×24 con dos pesos ópticos:
/// - `filled == false`: trazo limpio `1.85 px` con terminaciones redondeadas.
/// - `filled == true`: silueta sólida / duotono para estados activos.
enum InutilGlyph {
  home,
  liveTv,
  movies,
  series,
  anime,
  search,
  settings,
  profile,
  palette,
  sparkles,
  update,
  info,
  heart,
  code,
  refresh,
  trash,
  bookmark,
  play,
  lock,
  shield,
  sleepTimer,
  cloud,
  guide,
  download,
}

class InutilIcon extends StatelessWidget {
  const InutilIcon(
    this.glyph, {
    this.size = 24,
    this.color,
    this.filled = false,
    this.strokeWidth = 1.85,
    super.key,
  });

  final InutilGlyph glyph;
  final double size;
  final Color? color;
  final bool filled;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _InutilGlyphPainter(
            glyph: glyph,
            color: resolvedColor,
            filled: filled,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _InutilGlyphPainter extends CustomPainter {
  const _InutilGlyphPainter({
    required this.glyph,
    required this.color,
    required this.filled,
    required this.strokeWidth,
  });

  final InutilGlyph glyph;
  final Color color;
  final bool filled;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 24.0;
    canvas.save();
    canvas.translate(
      (size.width - 24.0 * scale) / 2,
      (size.height - 24.0 * scale) / 2,
    );
    canvas.scale(scale, scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final softFill = Paint()
      ..color = color.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    switch (glyph) {
      case InutilGlyph.home:
        _paintHome(canvas, stroke, fill);
      case InutilGlyph.liveTv:
        _paintLiveTv(canvas, stroke, fill, softFill);
      case InutilGlyph.movies:
        _paintMovies(canvas, stroke, fill, softFill);
      case InutilGlyph.series:
        _paintSeries(canvas, stroke, fill, softFill);
      case InutilGlyph.anime:
        _paintAnime(canvas, stroke, fill, softFill);
      case InutilGlyph.search:
        _paintSearch(canvas, stroke, fill, softFill);
      case InutilGlyph.settings:
        _paintSettings(canvas, stroke, fill, softFill);
      case InutilGlyph.profile:
        _paintProfile(canvas, stroke, fill, softFill);
      case InutilGlyph.palette:
        _paintPalette(canvas, stroke, fill, softFill);
      case InutilGlyph.sparkles:
        _paintSparkles(canvas, stroke, fill, softFill);
      case InutilGlyph.update:
        _paintUpdate(canvas, stroke, softFill);
      case InutilGlyph.info:
        _paintInfo(canvas, stroke, fill, softFill);
      case InutilGlyph.heart:
        _paintHeart(canvas, stroke, fill, softFill);
      case InutilGlyph.code:
        _paintCode(canvas, stroke);
      case InutilGlyph.refresh:
        _paintRefresh(canvas, stroke);
      case InutilGlyph.trash:
        _paintTrash(canvas, stroke, softFill);
      case InutilGlyph.bookmark:
        _paintBookmark(canvas, stroke, fill);
      case InutilGlyph.play:
        _paintPlay(canvas, stroke, fill);
      case InutilGlyph.lock:
        _paintLock(canvas, stroke, softFill);
      case InutilGlyph.shield:
        _paintShield(canvas, stroke, softFill);
      case InutilGlyph.sleepTimer:
        _paintSleepTimer(canvas, stroke, fill, softFill);
      case InutilGlyph.cloud:
        _paintCloud(canvas, stroke, softFill);
      case InutilGlyph.guide:
        _paintGuide(canvas, stroke, fill, softFill);
      case InutilGlyph.download:
        _paintDownload(canvas, stroke, softFill);
    }

    canvas.restore();
  }

  void _paintHome(Canvas canvas, Paint stroke, Paint fill) {
    final house = Path()
      ..moveTo(3.5, 10.6)
      ..quadraticBezierTo(3.5, 9.4, 4.4, 8.7)
      ..lineTo(10.8, 3.8)
      ..quadraticBezierTo(12.0, 2.9, 13.2, 3.8)
      ..lineTo(19.6, 8.7)
      ..quadraticBezierTo(20.5, 9.4, 20.5, 10.6)
      ..lineTo(20.5, 18.2)
      ..quadraticBezierTo(20.5, 20.4, 18.3, 20.4)
      ..lineTo(5.7, 20.4)
      ..quadraticBezierTo(3.5, 20.4, 3.5, 18.2)
      ..close();

    if (filled) {
      final cutout = Path()
        ..addRRect(RRect.fromRectAndRadius(
          const Rect.fromLTWH(9.4, 14.3, 5.2, 2.2),
          const Radius.circular(1.1),
        ));
      canvas.drawPath(
        Path.combine(PathOperation.difference, house, cutout),
        fill,
      );
    } else {
      canvas.drawPath(house, stroke);
      canvas.drawLine(const Offset(9.5, 16.0), const Offset(14.5, 16.0), stroke);
    }
  }

  void _paintLiveTv(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    final screen = RRect.fromRectAndRadius(
      const Rect.fromLTWH(3.0, 6.2, 18.0, 12.6),
      const Radius.circular(3.0),
    );
    if (filled) {
      canvas.drawRRect(screen, softFill);
      canvas.drawRRect(screen, stroke);
      // Señal central (triángulo play)
      final play = Path()
        ..moveTo(10.2, 9.8)
        ..lineTo(15.2, 12.5)
        ..lineTo(10.2, 15.2)
        ..close();
      canvas.drawPath(play, fill);
    } else {
      canvas.drawRRect(screen, stroke);
      canvas.drawCircle(const Offset(12.0, 12.5), 1.8, fill);
      // Ondas de señal
      canvas.drawArc(
        Rect.fromCircle(center: const Offset(12.0, 12.5), radius: 4.3),
        -0.75,
        1.5,
        false,
        stroke,
      );
      canvas.drawArc(
        Rect.fromCircle(center: const Offset(12.0, 12.5), radius: 4.3),
        math.pi - 0.75,
        1.5,
        false,
        stroke,
      );
    }
    // Base minimalista
    canvas.drawLine(const Offset(8.5, 21.0), const Offset(15.5, 21.0), stroke);
  }

  void _paintMovies(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    final frame = RRect.fromRectAndRadius(
      const Rect.fromLTWH(3.2, 4.4, 17.6, 15.2),
      const Radius.circular(3.0),
    );
    if (filled) {
      canvas.drawRRect(frame, softFill);
      canvas.drawRRect(frame, stroke);
      final tri = Path()
        ..moveTo(10.2, 9.4)
        ..lineTo(15.4, 12.0)
        ..lineTo(10.2, 14.6)
        ..close();
      canvas.drawPath(tri, fill);
    } else {
      canvas.drawRRect(frame, stroke);
      // Perforaciones cinematográficas laterales
      canvas.drawLine(const Offset(7.2, 4.6), const Offset(7.2, 19.4), stroke);
      canvas.drawLine(const Offset(16.8, 4.6), const Offset(16.8, 19.4), stroke);
      canvas.drawLine(const Offset(3.4, 9.5), const Offset(7.0, 9.5), stroke);
      canvas.drawLine(const Offset(3.4, 14.5), const Offset(7.0, 14.5), stroke);
      canvas.drawLine(const Offset(17.0, 9.5), const Offset(20.6, 9.5), stroke);
      canvas.drawLine(const Offset(17.0, 14.5), const Offset(20.6, 14.5), stroke);
    }
  }

  void _paintSeries(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    final mainCard = RRect.fromRectAndRadius(
      const Rect.fromLTWH(3.2, 7.6, 17.6, 12.4),
      const Radius.circular(3.0),
    );
    // Capas superiores (episodios apilados)
    canvas.drawLine(const Offset(6.2, 4.6), const Offset(17.8, 4.6), stroke);
    if (filled) {
      canvas.drawRRect(mainCard, softFill);
      canvas.drawRRect(mainCard, stroke);
      canvas.drawLine(const Offset(7.2, 12.2), const Offset(16.8, 12.2), stroke);
      canvas.drawLine(const Offset(7.2, 15.8), const Offset(13.2, 15.8), stroke);
    } else {
      canvas.drawRRect(mainCard, stroke);
      canvas.drawLine(const Offset(7.5, 12.4), const Offset(16.5, 12.4), stroke);
      canvas.drawLine(const Offset(7.5, 15.8), const Offset(13.0, 15.8), stroke);
    }
  }

  void _paintAnime(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    // Estrella de 4 puntas estilizada (estética limpia editorial en vez de rayo chillón)
    final star = Path()
      ..moveTo(12.0, 3.0)
      ..quadraticBezierTo(12.6, 10.2, 20.6, 12.0)
      ..quadraticBezierTo(12.6, 13.8, 12.0, 21.0)
      ..quadraticBezierTo(11.4, 13.8, 3.4, 12.0)
      ..quadraticBezierTo(11.4, 10.2, 12.0, 3.0)
      ..close();
    if (filled) {
      canvas.drawPath(star, fill);
    } else {
      canvas.drawPath(star, softFill);
      canvas.drawPath(star, stroke);
    }
  }

  void _paintSearch(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    const center = Offset(10.8, 10.8);
    if (filled) {
      canvas.drawCircle(center, 6.8, softFill);
      canvas.drawCircle(center, 6.8, stroke..strokeWidth = 2.2);
      canvas.drawCircle(center, 2.0, fill);
      canvas.drawLine(
        const Offset(16.0, 16.0),
        const Offset(20.4, 20.4),
        stroke..strokeWidth = 2.4,
      );
    } else {
      canvas.drawCircle(center, 6.8, stroke);
      canvas.drawLine(
        const Offset(15.9, 15.9),
        const Offset(20.3, 20.3),
        stroke,
      );
    }
  }

  void _paintSettings(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    // Tres deslizadores minimalistas horizontales (estilo Inútil Music)
    canvas.drawLine(const Offset(4.0, 6.8), const Offset(20.0, 6.8), stroke);
    canvas.drawLine(const Offset(4.0, 12.0), const Offset(20.0, 12.0), stroke);
    canvas.drawLine(const Offset(4.0, 17.2), const Offset(20.0, 17.2), stroke);

    final knobPaint = filled ? fill : stroke;
    final bgClear = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    for (final pt in const [
      Offset(9.0, 6.8),
      Offset(15.5, 12.0),
      Offset(10.5, 17.2),
    ]) {
      if (!filled) canvas.drawCircle(pt, 2.3, bgClear);
      canvas.drawCircle(pt, 2.3, knobPaint);
    }
  }

  void _paintProfile(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    if (filled) {
      canvas.drawCircle(const Offset(12.0, 8.2), 3.7, fill);
    } else {
      canvas.drawCircle(const Offset(12.0, 8.2), 3.7, stroke);
    }
    final body = Path()
      ..moveTo(4.6, 20.0)
      ..quadraticBezierTo(5.2, 14.6, 12.0, 14.6)
      ..quadraticBezierTo(18.8, 14.6, 19.4, 20.0);
    if (filled) {
      body.close();
      canvas.drawPath(body, softFill);
    }
    canvas.drawPath(body, stroke);
  }

  void _paintPalette(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    canvas.drawCircle(const Offset(12, 12), 8.5, softFill);
    canvas.drawCircle(const Offset(12, 12), 8.5, stroke);
    canvas.drawCircle(const Offset(9.0, 9.5), 1.3, fill);
    canvas.drawCircle(const Offset(13.8, 8.6), 1.3, fill);
    canvas.drawCircle(const Offset(15.8, 12.5), 1.3, fill);
    canvas.drawCircle(const Offset(11.0, 15.2), 1.6, fill);
  }

  void _paintSparkles(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    _paintAnime(canvas, stroke, fill, softFill);
    canvas.drawCircle(const Offset(18.5, 5.5), 1.2, fill);
  }

  void _paintUpdate(Canvas canvas, Paint stroke, Paint softFill) {
    canvas.drawCircle(const Offset(12, 12), 8.6, softFill);
    canvas.drawCircle(const Offset(12, 12), 8.6, stroke);
    canvas.drawLine(const Offset(12, 8.0), const Offset(12, 15.6), stroke);
    final arrow = Path()
      ..moveTo(8.8, 12.6)
      ..lineTo(12.0, 15.8)
      ..lineTo(15.2, 12.6);
    canvas.drawPath(arrow, stroke);
  }

  void _paintInfo(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    canvas.drawCircle(const Offset(12, 12), 8.6, softFill);
    canvas.drawCircle(const Offset(12, 12), 8.6, stroke);
    canvas.drawCircle(const Offset(12, 8.4), 1.1, fill);
    canvas.drawLine(const Offset(12, 11.4), const Offset(12, 16.4), stroke);
  }

  void _paintHeart(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    final p = Path()
      ..moveTo(12, 19.6)
      ..cubicTo(6.2, 15.4, 3.6, 12.2, 3.6, 8.8)
      ..cubicTo(3.6, 6.0, 5.8, 4.2, 8.3, 4.2)
      ..cubicTo(10.0, 4.2, 11.3, 5.1, 12.0, 6.4)
      ..cubicTo(12.7, 5.1, 14.0, 4.2, 15.7, 4.2)
      ..cubicTo(18.2, 4.2, 20.4, 6.0, 20.4, 8.8)
      ..cubicTo(20.4, 12.2, 17.8, 15.4, 12, 19.6)
      ..close();
    canvas.drawPath(p, filled ? fill : softFill);
    canvas.drawPath(p, stroke);
  }

  void _paintCode(Canvas canvas, Paint stroke) {
    final left = Path()
      ..moveTo(8.5, 8.0)
      ..lineTo(4.0, 12.0)
      ..lineTo(8.5, 16.0);
    final right = Path()
      ..moveTo(15.5, 8.0)
      ..lineTo(20.0, 12.0)
      ..lineTo(15.5, 16.0);
    canvas.drawPath(left, stroke);
    canvas.drawPath(right, stroke);
    canvas.drawLine(const Offset(13.4, 6.5), const Offset(10.6, 17.5), stroke);
  }

  void _paintRefresh(Canvas canvas, Paint stroke) {
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(12, 12), radius: 7.4),
      0.4,
      4.9,
      false,
      stroke,
    );
    final head = Path()
      ..moveTo(16.2, 5.2)
      ..lineTo(18.6, 8.6)
      ..lineTo(14.5, 8.8);
    canvas.drawPath(head, stroke);
  }

  void _paintTrash(Canvas canvas, Paint stroke, Paint softFill) {
    canvas.drawLine(const Offset(4.5, 6.8), const Offset(19.5, 6.8), stroke);
    canvas.drawLine(const Offset(9.5, 4.2), const Offset(14.5, 4.2), stroke);
    final bin = RRect.fromRectAndRadius(
      const Rect.fromLTWH(6.5, 6.8, 11.0, 13.0),
      const Radius.circular(2.4),
    );
    canvas.drawRRect(bin, softFill);
    canvas.drawRRect(bin, stroke);
  }

  void _paintBookmark(Canvas canvas, Paint stroke, Paint fill) {
    final p = Path()
      ..moveTo(6.2, 4.2)
      ..lineTo(17.8, 4.2)
      ..lineTo(17.8, 20.0)
      ..lineTo(12.0, 15.8)
      ..lineTo(6.2, 20.0)
      ..close();
    if (filled) {
      canvas.drawPath(p, fill);
    } else {
      canvas.drawPath(p, stroke);
    }
  }

  void _paintPlay(Canvas canvas, Paint stroke, Paint fill) {
    final p = Path()
      ..moveTo(7.5, 5.2)
      ..lineTo(19.0, 12.0)
      ..lineTo(7.5, 18.8)
      ..close();
    canvas.drawPath(p, filled ? fill : stroke);
  }

  void _paintLock(Canvas canvas, Paint stroke, Paint softFill) {
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(5.2, 10.6, 13.6, 9.6),
      const Radius.circular(3.0),
    );
    canvas.drawRRect(body, softFill);
    canvas.drawRRect(body, stroke);
    canvas.drawArc(
      const Rect.fromLTWH(8.2, 4.2, 7.6, 8.0),
      math.pi,
      math.pi,
      false,
      stroke,
    );
  }

  void _paintShield(Canvas canvas, Paint stroke, Paint softFill) {
    final p = Path()
      ..moveTo(12.0, 3.2)
      ..lineTo(19.2, 6.0)
      ..lineTo(19.2, 11.8)
      ..quadraticBezierTo(19.2, 17.6, 12.0, 20.8)
      ..quadraticBezierTo(4.8, 17.6, 4.8, 11.8)
      ..lineTo(4.8, 6.0)
      ..close();
    canvas.drawPath(p, softFill);
    canvas.drawPath(p, stroke);
  }

  void _paintSleepTimer(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    // Luna creciente geométrica + destello
    final moon = Path()
      ..moveTo(14.5, 4.2)
      ..cubicTo(9.2, 4.6, 5.2, 8.8, 5.4, 14.0)
      ..cubicTo(5.6, 18.6, 9.8, 21.0, 14.6, 20.0)
      ..cubicTo(17.0, 19.5, 18.8, 18.0, 19.8, 16.0)
      ..cubicTo(16.2, 16.8, 12.6, 14.8, 11.8, 11.2)
      ..cubicTo(11.2, 8.4, 12.4, 5.8, 14.5, 4.2)
      ..close();
    canvas.drawPath(moon, filled ? fill : softFill);
    canvas.drawPath(moon, stroke);
    canvas.drawCircle(const Offset(18.2, 7.2), 1.3, fill);
  }

  void _paintCloud(Canvas canvas, Paint stroke, Paint softFill) {
    final p = Path()
      ..moveTo(7.2, 18.4)
      ..lineTo(17.0, 18.4)
      ..cubicTo(19.6, 18.4, 21.2, 16.6, 21.0, 14.2)
      ..cubicTo(20.9, 12.1, 19.3, 10.6, 17.2, 10.4)
      ..cubicTo(16.6, 7.2, 13.8, 5.2, 10.6, 5.8)
      ..cubicTo(8.0, 6.2, 6.2, 8.4, 6.0, 11.0)
      ..cubicTo(4.0, 11.4, 2.8, 13.2, 3.0, 15.2)
      ..cubicTo(3.2, 17.1, 5.0, 18.4, 7.2, 18.4)
      ..close();
    canvas.drawPath(p, softFill);
    canvas.drawPath(p, stroke);
  }

  void _paintGuide(Canvas canvas, Paint stroke, Paint fill, Paint softFill) {
    canvas.drawCircle(const Offset(12, 12), 8.6, softFill);
    canvas.drawCircle(const Offset(12, 12), 8.6, stroke);
    final needle = Path()
      ..moveTo(15.6, 8.4)
      ..lineTo(13.2, 13.2)
      ..lineTo(8.4, 15.6)
      ..lineTo(10.8, 10.8)
      ..close();
    canvas.drawPath(needle, filled ? fill : stroke);
  }

  void _paintDownload(Canvas canvas, Paint stroke, Paint softFill) {
    final tray = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4.2, 14.8, 15.6, 4.8),
      const Radius.circular(2.0),
    );
    canvas.drawRRect(tray, softFill);
    // Bandeja inferior abierta por arriba
    final trayPath = Path()
      ..moveTo(4.4, 15.2)
      ..lineTo(4.4, 17.6)
      ..quadraticBezierTo(4.4, 19.6, 6.4, 19.6)
      ..lineTo(17.6, 19.6)
      ..quadraticBezierTo(19.6, 19.6, 19.6, 17.6)
      ..lineTo(19.6, 15.2);
    canvas.drawPath(trayPath, stroke);
    // Flecha descendente
    canvas.drawLine(const Offset(12, 4.4), const Offset(12, 14.2), stroke);
    final head = Path()
      ..moveTo(8.2, 10.6)
      ..lineTo(12.0, 14.4)
      ..lineTo(15.8, 10.6);
    canvas.drawPath(head, stroke);
  }

  @override
  bool shouldRepaint(covariant _InutilGlyphPainter oldDelegate) {
    return oldDelegate.glyph != glyph ||
        oldDelegate.color != color ||
        oldDelegate.filled != filled ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
