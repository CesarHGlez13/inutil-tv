import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/inutil_promo_popup_service.dart';
import '../theme/app_colors.dart';
import '../theme/inutil_icons.dart';

/// Pop-up elegante de apoyo al creador y avisos remotos (portado de Inútil Music v2.4).
class InutilSupportPopupDialog extends StatelessWidget {
  const InutilSupportPopupDialog({
    required this.campaign,
    this.onOpenUrl,
    super.key,
  });

  final InutilPopupCampaign campaign;
  final Future<void> Function(Uri uri)? onOpenUrl;

  static Future<void> show(
    BuildContext context,
    InutilPopupCampaign campaign, {
    Future<void> Function(Uri uri)? onOpenUrl,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar',
      barrierColor: Colors.black.withValues(alpha: 0.65),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, __, ___) => InutilSupportPopupDialog(
        campaign: campaign,
        onOpenUrl: onOpenUrl,
      ),
      transitionBuilder: (_, animation, __, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _handlePrimary(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final uri = Uri.tryParse(campaign.actionUrl);
    Navigator.of(context).pop();
    if (uri == null) return;
    if (onOpenUrl != null) {
      await onOpenUrl!(uri);
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final isAd = campaign.kind == InutilPopupKind.ad;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Material(
            key: const ValueKey('inutil-support-popup-card'),
            color: surface,
            elevation: 18,
            shadowColor: Colors.black.withValues(alpha: 0.45),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
              side: BorderSide(
                color: accent.withValues(alpha: 0.34),
                width: 1.1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned(
                  top: -48,
                  left: 0,
                  right: 0,
                  height: 150,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0, -0.4),
                          radius: 0.95,
                          colors: [
                            accent.withValues(alpha: 0.22),
                            accent.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: IconButton(
                    key: const ValueKey('inutil-support-popup-close'),
                    tooltip: 'Cerrar',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: subColor,
                  ),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 74,
                        height: 74,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accent.withValues(alpha: 0.14),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.38),
                            width: 1.3,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          campaign.emoji,
                          style: const TextStyle(fontSize: 34),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          campaign.badge,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        campaign.headline,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: headingColor,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                          letterSpacing: -0.35,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        campaign.body,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: subColor,
                          height: 1.42,
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const ValueKey('inutil-support-popup-primary'),
                          onPressed: () => _handlePrimary(context),
                          style: FilledButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: onAccent,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                          icon: InutilIcon(
                            isAd ? InutilGlyph.sparkles : InutilGlyph.heart,
                            size: 18,
                            color: onAccent,
                            filled: true,
                          ),
                          label: Text(
                            campaign.primaryCta,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          key: const ValueKey('inutil-support-popup-secondary'),
                          onPressed: () => Navigator.of(context).pop(),
                          style: TextButton.styleFrom(
                            foregroundColor: subColor,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                          child: Text(
                            campaign.secondaryCta,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      if (campaign.footnote.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          campaign.footnote,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: subColor.withValues(alpha: 0.72),
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
