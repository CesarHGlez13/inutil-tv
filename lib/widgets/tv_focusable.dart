import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/tv_mode_service.dart';
import '../theme/app_colors.dart';
import 'inutil_tv_keyboard.dart';

/// Envoltorio universal táctil + control remoto (D-pad de Smart TV / Android TV).
///
/// - En celular/tablet responde con toque natural (`onTap`, `onLongPress`) y
///   micro-escala al presionar.
/// - En Smart TV / TV Box recibe foco con las flechas del mando, activa la
///   acción con **OK (`select`) / Enter / Space / botón A**, dibuja un anillo
///   de foco limpio con el color de acento y hace auto-scroll suave para
///   mantener siempre visible el elemento seleccionado.
class TvFocusable extends StatefulWidget {
  final Widget? child;
  final Widget Function(BuildContext context, bool focused, bool pressed)?
      builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius borderRadius;
  final double focusScale;
  final double pressScale;
  final bool showFocusBorder;
  final double focusBorderWidth;
  final Color? focusColor;
  final bool autofocus;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final bool ensureVisible;
  final EdgeInsetsGeometry? margin;
  final bool enabled;
  final bool descendantsAreFocusable;
  final bool descendantsAreTraversable;

  const TvFocusable({
    super.key,
    this.child,
    this.builder,
    this.onTap,
    this.onLongPress,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.focusScale = 1.03,
    this.pressScale = 0.96,
    this.showFocusBorder = true,
    this.focusBorderWidth = 2.4,
    this.focusColor,
    this.autofocus = false,
    this.focusNode,
    this.onFocusChange,
    this.ensureVisible = true,
    this.margin,
    this.enabled = true,
    this.descendantsAreFocusable = true,
    this.descendantsAreTraversable = true,
  }) : assert(child != null || builder != null, 'Provide child or builder');

  static const Map<ShortcutActivator, Intent> remoteActivateShortcuts = {
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };

  /// Crea un [FocusNode] para `TextField` de una línea en Smart TV / Android TV:
  /// - Por defecto abre el teclado nativo del sistema (Gboard TV / dictado por
  ///   voz en Google TV) al pulsar **OK (`select`)** o **Enter**.
  /// - Si [useCustomTvKeyboard] es `true`, abre el teclado D-Pad opcional de
  ///   la app ([InutilTvKeyboard]) para TVs cuyo IME del sistema no responda.
  /// - Al pulsar **Flecha Abajo / Arriba** (y **Flecha Izquierda** si el campo
  ///   está vacío), mueve el foco al control vecino en lugar de quedar atrapado.
  static FocusNode createTextFieldFocusNode({
    VoidCallback? onDoneKey,
    TextEditingController? controller,
    bool useCustomTvKeyboard = false,
    String tvKeyboardTitle = 'Escribir con el control remoto',
    String tvKeyboardHint = '',
    InutilTvKeyboardMode tvKeyboardMode = InutilTvKeyboardMode.search,
    bool obscureText = false,
    ValueChanged<String>? onChanged,
  }) {
    late final FocusNode created;
    created = FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        final isRemoteOk = key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.gameButtonA;
        final isEnter = key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter;

        if (isRemoteOk || isEnter) {
          final isTv = TvModeService.instance.isTv || isRemoteOk;
          if (useCustomTvKeyboard && isTv) {
            if (onDoneKey != null) {
              SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
              onDoneKey();
              return KeyEventResult.handled;
            }
            final ctx = node.context;
            if (controller != null && ctx != null) {
              SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
              InutilTvKeyboard.showModal(
                ctx,
                controller: controller,
                title: tvKeyboardTitle,
                hintText: tvKeyboardHint,
                mode: tvKeyboardMode,
                obscureText: obscureText,
                onChanged: onChanged,
              );
              return KeyEventResult.handled;
            }
          }
          SystemChannels.textInput.invokeMethod<void>('TextInput.show');
          onDoneKey?.call();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          node.focusInDirection(TraversalDirection.down);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          node.focusInDirection(TraversalDirection.up);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft &&
            (controller == null || controller.text.isEmpty)) {
          node.focusInDirection(TraversalDirection.left);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    );
    if (useCustomTvKeyboard) {
      created.addListener(() {
        if (created.hasFocus && TvModeService.instance.isTv) {
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        }
      });
    }
    return created;
  }

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;
  bool _pressed = false;

  void _handleFocusChange(bool hasFocus) {
    if (_focused == hasFocus) return;
    setState(() => _focused = hasFocus);
    widget.onFocusChange?.call(hasFocus);
    if (hasFocus && widget.ensureVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          Scrollable.ensureVisible(
            context,
            alignment: 0.35,
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOutCubic,
            alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
          );
        } catch (_) {}
      });
    }
  }

  void _triggerTap() {
    if (!widget.enabled) return;
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.focusColor ?? AppColors.accentFor(context);
    final inner = widget.builder != null
        ? widget.builder!(context, _focused, _pressed)
        : widget.child!;

    final scale = _pressed
        ? widget.pressScale
        : (_focused ? widget.focusScale : 1.0);

    // Usamos DecoratedBox explícito (sin null tweens de AnimatedContainer)
    // para que en Android TV / Impeller Vulkan nunca queden bordes fantasma
    // al desplazarse rápido por listas largas con el D-pad.
    Widget content = AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      child: widget.showFocusBorder
          ? DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: _focused
                  ? BoxDecoration(
                      borderRadius: widget.borderRadius,
                      border: Border.all(
                        color: accent,
                        width: widget.focusBorderWidth,
                      ),
                    )
                  : BoxDecoration(
                      borderRadius: widget.borderRadius,
                      border: Border.all(
                        color: Colors.transparent,
                        width: 0,
                      ),
                    ),
              child: DecoratedBox(
                decoration: _focused
                    ? BoxDecoration(
                        borderRadius: widget.borderRadius,
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.30),
                            blurRadius: 12,
                            spreadRadius: 0,
                            blurStyle: BlurStyle.outer,
                          ),
                        ],
                      )
                    : const BoxDecoration(),
                child: inner,
              ),
            )
          : inner,
    );

    if (widget.margin != null) {
      content = Padding(padding: widget.margin!, child: content);
    }

    return FocusableActionDetector(
      enabled: widget.enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      descendantsAreFocusable: widget.descendantsAreFocusable,
      descendantsAreTraversable: widget.descendantsAreTraversable,
      onFocusChange: _handleFocusChange,
      shortcuts: TvFocusable.remoteActivateShortcuts,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _triggerTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        onLongPress: widget.enabled ? widget.onLongPress : null,
        onTapDown: widget.enabled
            ? (_) {
                if (!_pressed) setState(() => _pressed = true);
              }
            : null,
        onTapUp: (_) {
          if (_pressed) setState(() => _pressed = false);
        },
        onTapCancel: () {
          if (_pressed) setState(() => _pressed = false);
        },
        child: content,
      ),
    );
  }
}
