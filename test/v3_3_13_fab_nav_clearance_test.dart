import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/liquid_nav_metrics.dart';

/// Regresión del bug reportado en 3.3.12: el FAB del control remoto quedaba
/// POR DEBAJO de la barra flotante de navegación (Inicio / En vivo / Buscar)
/// y empalmado sobre el botón circular de Búsqueda.
///
/// Causa: el FAB se anclaba con una fórmula fija (`(inset>0?6:12) + 70`) que
/// ignoraba que en MIUI/HyperOS la barra de gestos reporta un inset real de
/// ~46-49 dp, así que la barra flotante terminaba mucho más arriba de lo que
/// suponía el anclaje del FAB.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Insets medidos en el Xiaomi 25082RN14A (Android 16 / HyperOS,
  // 1080x2400 @420dpi): 120 px y 128 px físicos ≈ 45.7 dp y 48.8 dp.
  const measuredInsets = <double>[45.7, 48.8];
  const otherInsets = <double>[0, 6, 12, 16, 24, 32, 64];

  group('Métricas de la barra flotante (3.3.13)', () {
    test('la barra flotante mide lo que dice la constante', () {
      // El botón circular de Búsqueda (56 dp) es el elemento más alto de la
      // barra; la constante debe cubrirlo o el cálculo de holgura se queda
      // corto.
      expect(kLiquidNavHeight, greaterThanOrEqualTo(56));
      expect(kFabNavGap, greaterThanOrEqualTo(12));
    });

    test('margen inferior = max(mínimo, inset) del SafeArea', () {
      // Sin inset del sistema: mínimo de 12 dp (pantalla completa).
      expect(liquidNavBottomInsetFor(0), kLiquidNavMinBottomInsetImmersive);
      // Con inset pequeño: se respeta el mínimo de 6 dp, no el inset.
      expect(liquidNavBottomInsetFor(1), kLiquidNavMinBottomInsetWithSystemBar);
      expect(liquidNavBottomInsetFor(6), kLiquidNavMinBottomInsetWithSystemBar);
      // Con inset grande (barra de gestos de HyperOS): manda el inset real.
      for (final inset in measuredInsets) {
        expect(liquidNavBottomInsetFor(inset), inset,
            reason: 'inset medido de $inset dp debe respetarse tal cual');
      }
    });

    test('el FAB queda SIEMPRE por encima de la barra, con holgura', () {
      for (final inset in [...measuredInsets, ...otherInsets]) {
        final barBottom = liquidNavBottomInsetFor(inset);
        final barTop = barBottom + kLiquidNavHeight;
        final fabBottom = liquidNavTopOffsetFor(inset);

        expect(fabBottom - barTop, closeTo(kFabNavGap, 0.001),
            reason: 'inset=$inset: el FAB debe separarse kFabNavGap del techo '
                'de la barra');
        expect(fabBottom, greaterThan(barTop),
            reason: 'inset=$inset: el borde inferior del FAB debe quedar por '
                'encima del borde superior de la barra');
      }
    });

    test('regresión: la fórmula vieja sí provocaba el solapamiento', () {
      // Fórmula de 3.3.12: bottom = (inset>0 ? 6 : 12) + 70.
      double oldFabBottom(double inset) => (inset > 0 ? 6.0 : 12.0) + 70.0;

      for (final inset in measuredInsets) {
        final barTop = liquidNavBottomInsetFor(inset) + kLiquidNavHeight;
        expect(oldFabBottom(inset), lessThan(barTop),
            reason: 'la fórmula antigua ponía el FAB (bottom=${oldFabBottom(inset)} dp) '
                'por debajo del techo de la barra ($barTop dp) con inset=$inset');
        expect(liquidNavTopOffsetFor(inset), greaterThan(barTop),
            reason: 'la fórmula nueva debe corregir ese solapamiento');
      }
    });

    test('main.dart usa las métricas compartidas, no números hardcodeados', () {
      final mainFile = File('lib/main.dart');
      expect(mainFile.existsSync(), isTrue);
      final src = mainFile.readAsStringSync();

      expect(src.contains("import 'services/liquid_nav_metrics.dart';"), isTrue,
          reason: 'main.dart debe importar las métricas compartidas');
      expect(src.contains('bottom: liquidNavTopOffset(context)'), isTrue,
          reason: 'el FAB debe anclarse con liquidNavTopOffset(context)');
      expect(src.contains('liquidNavBottomInset(context)'), isTrue,
          reason: 'el SafeArea de la barra debe usar la misma fórmula');
      expect(
          src.contains('EdgeInsets.fromLTRB(14, 0, 14, bottomInset > 0 ? 6 : 12)'),
          isFalse,
          reason:
              'no puede volver a existir un margen hardcodeado en la barra');
    });
  });
}
