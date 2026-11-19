import 'package:flutter/widgets.dart';

// Métricas compartidas de la barra de navegación flotante ("Liquid Glass")
// de la pantalla móvil.
//
// Viven separadas de `main.dart` porque el FAB del control remoto y la propia
// barra deben usar EXACTAMENTE los mismos números: si uno de los dos cambia
// por su cuenta, el FAB vuelve a quedar empalmado sobre el botón circular de
// Búsqueda (reportado en 3.3.12).

/// Altura visible de la barra de navegación flotante (cápsula de 5 secciones
/// + botón circular de Búsqueda de 56 dp). Medido sobre captura real en
/// Xiaomi (1080x2400 @420dpi): 142 px físicos ≈ 54 dp → 58 dp con holgura.
const double kLiquidNavHeight = 58;

/// Separación vertical entre el borde superior de la barra y el FAB del
/// control remoto, para que nunca queden "empalmados".
const double kFabNavGap = 14;

/// Márgenes laterales de la barra flotante (`SafeArea(minimum:)`).
const double kLiquidNavSideMargin = 14;

/// Mínimo inferior cuando el sistema reporta un inset de navegación mayor que
/// cero (barra de gestos / 3 botones). Es un *mínimo*: el `SafeArea` aplica
/// `max(mínimo, inset)`.
const double kLiquidNavMinBottomInsetWithSystemBar = 6;

/// Mínimo inferior cuando el sistema no reporta ningún inset (navegación
/// inmersiva a pantalla completa).
const double kLiquidNavMinBottomInsetImmersive = 12;

/// Margen inferior real que ocupa la barra flotante para un `bottom` de
/// `MediaQuery.padding` dado. Réplica exacta del `SafeArea(minimum:)` que usa
/// la barra flotante de `main.dart`.
double liquidNavBottomInsetFor(double bottomPadding) {
  final minimum = bottomPadding > 0
      ? kLiquidNavMinBottomInsetWithSystemBar
      : kLiquidNavMinBottomInsetImmersive;
  return bottomPadding > minimum ? bottomPadding : minimum;
}

/// Distancia desde el borde inferior de la pantalla hasta el borde SUPERIOR de
/// la barra flotante, más la holgura `kFabNavGap`.
///
/// Es el valor correcto para anclar el FAB del control remoto: así queda
/// SIEMPRE por encima de la barra, pase lo que pase con la barra de gestos del
/// sistema, y nunca tapa el botón circular de Búsqueda.
double liquidNavTopOffsetFor(double bottomPadding) =>
    liquidNavBottomInsetFor(bottomPadding) + kLiquidNavHeight + kFabNavGap;

/// Versión con `BuildContext` de [liquidNavBottomInsetFor].
double liquidNavBottomInset(BuildContext context) =>
    liquidNavBottomInsetFor(MediaQuery.paddingOf(context).bottom);

/// Versión con `BuildContext` de [liquidNavTopOffsetFor].
double liquidNavTopOffset(BuildContext context) =>
    liquidNavTopOffsetFor(MediaQuery.paddingOf(context).bottom);
