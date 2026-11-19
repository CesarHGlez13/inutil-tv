import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/sleep_timer_service.dart';
import '../theme/app_colors.dart';
import '../theme/inutil_icons.dart';

/// Hoja inferior elegante de Temporizador de Sueño para InútilTV
/// (portada desde Inútil Music v2.4, con opción adicional "Al terminar este episodio").
class InutilSleepTimerSheet extends StatelessWidget {
  const InutilSleepTimerSheet({
    this.showEndOfEpisode = false,
    super.key,
  });

  final bool showEndOfEpisode;

  static const _presets = <({String label, Duration duration})>[
    (label: '15 minutos', duration: Duration(minutes: 15)),
    (label: '30 minutos', duration: Duration(minutes: 30)),
    (label: '45 minutos', duration: Duration(minutes: 45)),
    (label: '1 hora', duration: Duration(hours: 1)),
    (label: '1 hora y 30 min', duration: Duration(minutes: 90)),
  ];

  static Future<void> show(
    BuildContext context, {
    bool showEndOfEpisode = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => InutilSleepTimerSheet(showEndOfEpisode: showEndOfEpisode),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timer = SleepTimerService.instance;
    final theme = Theme.of(context);
    final accent = AppColors.accentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) {
        return Container(
          key: const ValueKey('inutil-sleep-timer-sheet'),
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: EdgeInsets.fromLTRB(20, 14, 20, bottomInset + 18),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: border, width: 0.9),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: subColor.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: accent.withValues(alpha: 0.14),
                      ),
                      child: Center(
                        child: InutilIcon(
                          InutilGlyph.sleepTimer,
                          size: 22,
                          color: accent,
                          filled: timer.isActive,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Temporizador de sueño',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: headingColor,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            timer.isActive
                                ? (timer.stopAtEndOfEpisode
                                    ? 'Se pausará al terminar este episodio'
                                    : 'Se detendrá en ${timer.shortLabel}')
                                : 'Pausa la reproducción automáticamente',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: timer.isActive ? accent : subColor,
                              fontWeight: timer.isActive
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 20),
                      color: subColor,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (showEndOfEpisode) ...[
                  _optionTile(
                    context,
                    label: 'Al terminar este episodio',
                    selected: timer.stopAtEndOfEpisode,
                    accent: accent,
                    headingColor: headingColor,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      timer.startEndOfEpisode();
                      Navigator.of(context).pop();
                    },
                  ),
                  const SizedBox(height: 6),
                ],
                for (final preset in _presets) ...[
                  _optionTile(
                    context,
                    label: preset.label,
                    selected: timer.isActive &&
                        !timer.stopAtEndOfEpisode &&
                        timer.selectedDuration == preset.duration,
                    accent: accent,
                    headingColor: headingColor,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      timer.start(preset.duration);
                      Navigator.of(context).pop();
                    },
                  ),
                  const SizedBox(height: 6),
                ],
                if (timer.isActive) ...[
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    key: const ValueKey('sleep-timer-cancel'),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      timer.cancel();
                      Navigator.of(context).pop();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: BorderSide(
                        color: Colors.redAccent.withValues(alpha: 0.45),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.timer_off_outlined, size: 19),
                    label: const Text(
                      'Desactivar temporizador',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _optionTile(
    BuildContext context, {
    required String label,
    required bool selected,
    required Color accent,
    required Color headingColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected
          ? accent.withValues(alpha: 0.14)
          : AppColors.elevatedSurfaceFor(context),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? accent : headingColor,
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, size: 20, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}
