import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import 'tv_focusable.dart';

enum InutilTvKeyboardMode { search, email, text, password }

/// Teclado en pantalla D-Pad nativo de Inutix TV (v3.3.53).
///
/// Resuelve de raíz el problema de Smart TVs / Android TV Boxes donde el
/// teclado virtual del sistema (`InputMethodManager`) aparece en pantalla pero
/// no recibe el foco de las flechas del control remoto, dejando el foco
/// desplazándose por la interfaz trasera.
///
/// Todas las teclas son widgets de Flutter dentro del árbol de foco de la app
/// con navegación D-Pad determinista por coordenadas `(fila, columna)`.
class InutilTvKeyboard extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmit;
  final VoidCallback? onMoveDownToResults;
  final InutilTvKeyboardMode mode;
  final bool autofocusFirstKey;
  final List<String> quickSuggestions;
  final String submitLabel;

  const InutilTvKeyboard({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSubmit,
    this.onMoveDownToResults,
    this.mode = InutilTvKeyboardMode.search,
    this.autofocusFirstKey = true,
    this.quickSuggestions = const [
      'Dragon Ball',
      'One Piece',
      'Naruto',
      'Acción',
      'Terror',
      'Ciencia Ficción',
    ],
    this.submitLabel = 'Resultados',
  });

  /// Abre un panel modal con el teclado D-Pad para editar cualquier [controller]
  /// (login de correo/contraseña, proxy, etc.) con el control remoto de la TV.
  static Future<void> showModal(
    BuildContext context, {
    required TextEditingController controller,
    required String title,
    String hintText = '',
    InutilTvKeyboardMode mode = InutilTvKeyboardMode.text,
    bool obscureText = false,
    ValueChanged<String>? onChanged,
    VoidCallback? onSubmitted,
  }) async {
    // Asegurar que el teclado fantasma del sistema Android TV se oculte.
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.78),
      builder: (ctx) => _InutilTvKeyboardDialog(
        controller: controller,
        title: title,
        hintText: hintText,
        mode: mode,
        initialObscure: obscureText,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      ),
    );
  }

  @override
  State<InutilTvKeyboard> createState() => _InutilTvKeyboardState();
}

class _TvKeySpec {
  final String id;
  final String label;
  final String? insert;
  final IconData? icon;
  final int flex;
  final bool isAction;
  final bool isAccent;

  const _TvKeySpec({
    required this.id,
    required this.label,
    this.insert,
    this.icon,
    this.flex = 1,
    this.isAction = false,
    this.isAccent = false,
  });
}

class _InutilTvKeyboardState extends State<InutilTvKeyboard> {
  bool _uppercase = false;
  late List<List<_TvKeySpec>> _rows;
  final Map<String, FocusNode> _nodes = {};

  @override
  void initState() {
    super.initState();
    // Ocultar el IME del sistema para que no tape la interfaz en Smart TV.
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    _uppercase = widget.mode != InutilTvKeyboardMode.email;
    _rebuildRows();
  }

  @override
  void didUpdateWidget(covariant InutilTvKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode ||
        oldWidget.submitLabel != widget.submitLabel) {
      _rebuildRows();
    }
  }

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _nodes.clear();
    super.dispose();
  }

  FocusNode _nodeFor(int r, int c) {
    final key = '$r:$c';
    return _nodes.putIfAbsent(key, () => FocusNode(debugLabel: 'tvKey_$key'));
  }

  String _cased(String ch) => _uppercase ? ch.toUpperCase() : ch.toLowerCase();

  void _rebuildRows() {
    final isEmail = widget.mode == InutilTvKeyboardMode.email;
    final isPassOrText = widget.mode == InutilTvKeyboardMode.password ||
        widget.mode == InutilTvKeyboardMode.text;

    final row0Letters = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'];
    final row1Letters = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'ñ'];
    final row2Letters = ['z', 'x', 'c', 'v', 'b', 'n', 'm', '1', '2', '3'];
    final row3Nums = ['4', '5', '6', '7', '8', '9', '0'];

    _rows = [
      [
        for (final ch in row0Letters)
          _TvKeySpec(id: 'k_$ch', label: _cased(ch), insert: _cased(ch)),
      ],
      [
        for (final ch in row1Letters)
          _TvKeySpec(id: 'k_$ch', label: _cased(ch), insert: _cased(ch)),
      ],
      [
        for (final ch in row2Letters)
          _TvKeySpec(
            id: 'k_$ch',
            label: ch.length == 1 && RegExp(r'[a-z]').hasMatch(ch)
                ? _cased(ch)
                : ch,
            insert: ch.length == 1 && RegExp(r'[a-z]').hasMatch(ch)
                ? _cased(ch)
                : ch,
          ),
      ],
      [
        for (final ch in row3Nums)
          _TvKeySpec(id: 'k_$ch', label: ch, insert: ch),
        if (isEmail) ...[
          const _TvKeySpec(id: 'k_at', label: '@', insert: '@'),
          const _TvKeySpec(id: 'k_dot', label: '.', insert: '.'),
          const _TvKeySpec(id: 'k_und', label: '_', insert: '_'),
        ] else if (isPassOrText) ...[
          const _TvKeySpec(id: 'k_dot', label: '.', insert: '.'),
          const _TvKeySpec(id: 'k_col', label: ':', insert: ':'),
          const _TvKeySpec(id: 'k_dsh', label: '-', insert: '-'),
        ] else ...[
          const _TvKeySpec(
            id: 'act_space',
            label: 'ESPACIO',
            insert: ' ',
            flex: 3,
            isAction: true,
          ),
        ],
      ],
      [
        if (isEmail || isPassOrText)
          _TvKeySpec(
            id: 'act_case',
            label: _uppercase ? 'ABC → abc' : 'abc → ABC',
            flex: 2,
            isAction: true,
          ),
        if (isEmail) ...[
          const _TvKeySpec(
            id: 'k_gmail',
            label: '@gmail.com',
            insert: '@gmail.com',
            flex: 2,
            isAction: true,
          ),
          const _TvKeySpec(
            id: 'k_com',
            label: '.com',
            insert: '.com',
            flex: 1,
            isAction: true,
          ),
        ] else if (isPassOrText) ...[
          const _TvKeySpec(
            id: 'k_at',
            label: '@',
            insert: '@',
            flex: 1,
          ),
          const _TvKeySpec(
            id: 'act_space',
            label: 'ESPACIO',
            insert: ' ',
            flex: 2,
            isAction: true,
          ),
        ],
        const _TvKeySpec(
          id: 'act_backspace',
          label: 'BORRAR',
          icon: Icons.backspace_outlined,
          flex: 2,
          isAction: true,
        ),
        const _TvKeySpec(
          id: 'act_clear',
          label: 'LIMPIAR',
          icon: Icons.clear_rounded,
          flex: 2,
          isAction: true,
        ),
        _TvKeySpec(
          id: 'act_done',
          label: widget.submitLabel.toUpperCase(),
          icon: Icons.check_rounded,
          flex: 3,
          isAction: true,
          isAccent: true,
        ),
      ],
    ];
  }

  void _applyText(String next) {
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    widget.onChanged?.call(next);
  }

  void _onKeyTap(_TvKeySpec spec) {
    final current = widget.controller.text;
    if (spec.insert != null) {
      _applyText('$current${spec.insert!}');
      return;
    }
    switch (spec.id) {
      case 'act_case':
        setState(() {
          _uppercase = !_uppercase;
          _rebuildRows();
        });
        break;
      case 'act_backspace':
        if (current.isNotEmpty) {
          final chars = current.characters;
          _applyText(chars.skipLast(1).toString());
        }
        break;
      case 'act_clear':
        if (current.isNotEmpty) {
          _applyText('');
        }
        break;
      case 'act_done':
        if (widget.onSubmit != null) {
          widget.onSubmit!();
        } else if (widget.onMoveDownToResults != null) {
          widget.onMoveDownToResults!();
        }
        break;
    }
  }

  KeyEventResult _handleGridNavigation(int r, int c, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowRight) {
      final row = _rows[r];
      if (c + 1 < row.length) {
        _nodeFor(r, c + 1).requestFocus();
      } else {
        _nodeFor(r, 0).requestFocus();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (c - 1 >= 0) {
        _nodeFor(r, c - 1).requestFocus();
      } else {
        // En modo búsqueda permitimos salir al menú lateral izquierdo si está en col 0
        if (widget.mode == InutilTvKeyboardMode.search) {
          return KeyEventResult.ignored;
        }
        _nodeFor(r, _rows[r].length - 1).requestFocus();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      if (r - 1 >= 0) {
        final prevRow = _rows[r - 1];
        final targetCol =
            ((c / _rows[r].length) * prevRow.length).floor().clamp(0, prevRow.length - 1);
        _nodeFor(r - 1, targetCol).requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      if (r + 1 < _rows.length) {
        final nextRow = _rows[r + 1];
        final targetCol =
            ((c / _rows[r].length) * nextRow.length).floor().clamp(0, nextRow.length - 1);
        _nodeFor(r + 1, targetCol).requestFocus();
        return KeyEventResult.handled;
      }
      if (widget.onMoveDownToResults != null) {
        widget.onMoveDownToResults!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Atajo con botón de retroceso de controles remotos multimedia
    if (key == LogicalKeyboardKey.backspace) {
      final current = widget.controller.text;
      if (current.isNotEmpty) {
        _applyText(current.characters.skipLast(1).toString());
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final elevated = AppColors.elevatedSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final heading = AppColors.contentHeadingFor(context);
    final sub = AppColors.contentSubtitleFor(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border, width: 0.9),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.mode == InutilTvKeyboardMode.search &&
              widget.quickSuggestions.isNotEmpty) ...[
            SizedBox(
              height: 30,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.quickSuggestions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, idx) {
                  final term = widget.quickSuggestions[idx];
                  return TvFocusable(
                    onTap: () => _applyText(term),
                    borderRadius: BorderRadius.circular(14),
                    ensureVisible: false,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: elevated,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: border, width: 0.7),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.bolt_rounded, size: 13, color: accent),
                          const SizedBox(width: 4),
                          Text(
                            term,
                            style: TextStyle(
                              color: sub,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (var r = 0; r < _rows.length; r++) ...[
            if (r > 0) const SizedBox(height: 5),
            Row(
              children: [
                for (var c = 0; c < _rows[r].length; c++) ...[
                  if (c > 0) const SizedBox(width: 5),
                  Expanded(
                    flex: _rows[r][c].flex,
                    child: _buildKey(
                      context,
                      r: r,
                      c: c,
                      spec: _rows[r][c],
                      accent: accent,
                      onAccent: onAccent,
                      elevated: elevated,
                      border: border,
                      heading: heading,
                      sub: sub,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildKey(
    BuildContext context, {
    required int r,
    required int c,
    required _TvKeySpec spec,
    required Color accent,
    required Color onAccent,
    required Color elevated,
    required Color border,
    required Color heading,
    required Color sub,
  }) {
    final node = _nodeFor(r, c);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _handleGridNavigation(r, c, event),
      child: TvFocusable(
        key: ValueKey('tv_key_${spec.id}'),
        focusNode: node,
        autofocus: widget.autofocusFirstKey && r == 0 && c == 0,
        ensureVisible: false,
        focusScale: 1.05,
        borderRadius: BorderRadius.circular(10),
        onTap: () => _onKeyTap(spec),
        builder: (context, focused, pressed) {
          final bg = focused
              ? accent
              : (spec.isAccent
                  ? accent.withValues(alpha: 0.22)
                  : (spec.isAction
                      ? elevated.withValues(alpha: 0.95)
                      : elevated.withValues(alpha: 0.65)));
          final fg = focused
              ? onAccent
              : (spec.isAccent
                  ? accent
                  : (spec.isAction ? sub : heading));

          return Container(
            height: 36,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: focused
                    ? accent
                    : (spec.isAccent
                        ? accent.withValues(alpha: 0.55)
                        : border),
                width: focused ? 1.6 : 0.7,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (spec.icon != null) ...[
                  Icon(spec.icon, size: 14, color: fg),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    spec.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: spec.isAction ? 11 : 13,
                      fontWeight:
                          focused || spec.isAccent ? FontWeight.w900 : FontWeight.w700,
                      letterSpacing: spec.isAction ? 0.2 : 0,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _InutilTvKeyboardDialog extends StatefulWidget {
  final TextEditingController controller;
  final String title;
  final String hintText;
  final InutilTvKeyboardMode mode;
  final bool initialObscure;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;

  const _InutilTvKeyboardDialog({
    required this.controller,
    required this.title,
    required this.hintText,
    required this.mode,
    required this.initialObscure,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  State<_InutilTvKeyboardDialog> createState() =>
      _InutilTvKeyboardDialogState();
}

class _InutilTvKeyboardDialogState extends State<_InutilTvKeyboardDialog> {
  late bool _obscure = widget.initialObscure;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(context);
    final surface = AppColors.elevatedSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final heading = AppColors.contentHeadingFor(context);
    final sub = AppColors.contentSubtitleFor(context);

    return Dialog(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: border, width: 1),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.keyboard_alt_outlined, color: accent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        color: heading,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (widget.mode == InutilTvKeyboardMode.password)
                    TvFocusable(
                      onTap: () => setState(() => _obscure = !_obscure),
                      borderRadius: BorderRadius.circular(10),
                      ensureVisible: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 16,
                              color: sub,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _obscure ? 'Mostrar' : 'Ocultar',
                              style: TextStyle(
                                color: sub,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.controller,
                builder: (context, value, _) {
                  final raw = value.text;
                  final display = raw.isEmpty
                      ? (widget.hintText.isNotEmpty
                          ? widget.hintText
                          : 'Usa las flechas del control y pulsa OK en cada letra...')
                      : (_obscure ? '•' * raw.length : raw);
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.inputSurfaceFor(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.55),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            display,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: raw.isEmpty ? sub : heading,
                              fontSize: 15,
                              fontWeight:
                                  raw.isEmpty ? FontWeight.w500 : FontWeight.w700,
                            ),
                          ),
                        ),
                        Container(
                          width: 2,
                          height: 18,
                          color: accent,
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              InutilTvKeyboard(
                controller: widget.controller,
                mode: widget.mode,
                autofocusFirstKey: true,
                quickSuggestions: const [],
                submitLabel: 'Listo',
                onChanged: widget.onChanged,
                onSubmit: () {
                  Navigator.of(context).pop();
                  widget.onSubmitted?.call();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
