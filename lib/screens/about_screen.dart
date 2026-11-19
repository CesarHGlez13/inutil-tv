import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_info.dart';
import '../services/firebase_auth_service.dart';
import '../services/inutil_update_service.dart';
import '../services/inutil_wrapped_service.dart';
import '../services/my_list_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import '../widgets/inutil_onboarding_tour.dart';
import '../widgets/inutil_update_gate.dart';
import '../widgets/inutil_wrapped_dialog.dart';

/// Pantalla «Acerca de la aplicación» de InútilTV v3.0 — estilo Inútil Music:
/// versión, actualizaciones OTA, novedades, creador, donaciones y contacto.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _openExternalUrl(
    BuildContext context,
    String rawUrl, {
    required String fallbackError,
  }) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      _showSnack(context, fallbackError);
      return;
    }
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        _showSnack(context, fallbackError);
      }
    } catch (_) {
      if (context.mounted) {
        _showSnack(context, fallbackError);
      }
    }
  }

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnack(context, '$label copiado al portapapeles.');
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showWhatsNewDialog(BuildContext context) async {
    final accent = AppColors.accentFor(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            InutilIcon(InutilGlyph.sparkles, size: 20, color: accent),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Novedades de v${AppInfo.appVersion}',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < AppInfo.whatsNewHighlights.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom:
                          i == AppInfo.whatsNewHighlights.length - 1 ? 0 : 12,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.check_circle_outline_rounded,
                            size: 17,
                            color: accent,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            AppInfo.whatsNewHighlights[i],
                            style: const TextStyle(fontSize: 13, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSupportDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            InutilIcon(InutilGlyph.heart, size: 20, color: Colors.pinkAccent, filled: true),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Apoyar el Desarrollo',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'InútilTV e Inútil Music son proyectos independientes desarrollados y mantenidos por César. Si deseas apoyar con una donación voluntaria para servidores y nuevas funciones, escríbenos directamente:',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.elevatedSurfaceFor(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.cardBorderFor(context)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.email_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      AppInfo.supportEmail,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copiar correo',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy_rounded, size: 17),
                    onPressed: () => _copyToClipboard(
                      context,
                      AppInfo.supportEmail,
                      'Correo de apoyo',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _openExternalUrl(
                context,
                AppInfo.supportDevelopmentUrl,
                fallbackError:
                    'No se encontró app de correo. Usa ${AppInfo.supportEmail}.',
              );
            },
            icon: const Icon(Icons.mail_rounded, size: 17),
            label: const Text('Enviar Correo'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppColors.accentFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          'Acerca de la aplicación',
          style: appTabTitleStyle(context).copyWith(fontSize: 20),
        ),
        backgroundColor: theme.scaffoldBackgroundColor,
      ),
      body: ListView(
        padding: const EdgeInsets.all(appPagePaddingHorizontal),
        children: [
          // Tarjeta Hero de identidad
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: AppColors.cardSurfaceFor(context),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppColors.cardBorderFor(context),
                width: 0.9,
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Inútil',
                      style: appTabTitleStyle(context).copyWith(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'TV',
                        style: TextStyle(
                          color: AppColors.onAccentFor(context),
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  AppInfo.familyEcosystemLabel,
                  style: TextStyle(
                    color: subColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Creado por ${AppInfo.creatorName}',
                    style: TextStyle(
                      color: headingColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          _entryCard(
            context,
            key: const ValueKey('about-version'),
            glyph: InutilGlyph.info,
            title: 'Versión',
            subtitle: 'v${AppInfo.appVersion} · Build Oficial de Producción',
            onTap: () => _copyToClipboard(
              context,
              '${AppInfo.appName} v${AppInfo.appVersion}',
              'Versión',
            ),
          ),
          const SizedBox(height: 10),

          _entryCard(
            context,
            key: const ValueKey('about-ota'),
            glyph: InutilGlyph.update,
            title: 'Buscar actualizaciones (OTA)',
            subtitle: 'Descarga e instala nuevas versiones sin salir de InútilTV',
            onTap: () async {
              final release =
                  await InutilUpdateService.instance.checkForUpdate();
              if (context.mounted) {
                await showInutilUpdateDialog(context, release: release);
              }
            },
          ),
          const SizedBox(height: 10),

          _entryCard(
            context,
            key: const ValueKey('about-whats-new'),
            glyph: InutilGlyph.sparkles,
            title: 'Novedades de ${AppInfo.appVersion}',
            subtitle:
                'Series multi-proveedor, Precarga instantánea, Respaldo en la nube y Wrapped',
            onTap: () => _showWhatsNewDialog(context),
          ),
          const SizedBox(height: 10),

          _entryCard(
            context,
            key: const ValueKey('about-wrapped'),
            glyph: InutilGlyph.sparkles,
            iconColorOverride: const Color(0xFF34D399),
            title: 'Tu Resumen del Año (InútilTV Wrapped)',
            subtitle:
                'Revive tus horas vistas, tu título #1 y tu personalidad de pantalla',
            onTap: () async {
              final summary =
                  await InutilTvWrappedService.instance.buildSummary();
              final user = InutilAuthService.instance.currentUser;
              final name = user?.displayName.isNotEmpty == true
                  ? user!.displayName
                  : (user?.email.split('@').first ?? 'Cinéfilo');
              if (!context.mounted) return;
              await InutilTvWrappedDialog.show(
                context,
                summary: summary,
                userName: name,
                myListCount: MyListService.instance.items.length,
              );
            },
          ),
          const SizedBox(height: 10),

          _entryCard(
            context,
            key: const ValueKey('about-onboarding'),
            glyph: InutilGlyph.guide,
            title: 'Recorrido guiado interactivo',
            subtitle:
                'Vuelve a explorar las funciones clave y gestos de InútilTV',
            onTap: () => InutilOnboardingTour.show(
              context,
              inactivityDays: InutilAuthService.instance.inactivityPolicyDays,
            ),
          ),
          const SizedBox(height: 10),

          _entryCard(
            context,
            key: const ValueKey('about-support'),
            glyph: InutilGlyph.heart,
            iconColorOverride: Colors.pinkAccent,
            title: 'Apoyar el desarrollo / Donaciones',
            subtitle:
                'Ayuda a mantener InútilTV e Inútil Music y seguir agregando funciones',
            onTap: () => _showSupportDialog(context),
          ),
          const SizedBox(height: 10),

          _entryCard(
            context,
            key: const ValueKey('about-creator'),
            glyph: InutilGlyph.profile,
            title: 'Contacto y Soporte (${AppInfo.creatorName})',
            subtitle: AppInfo.supportEmail,
            onTap: () => _openExternalUrl(
              context,
              AppInfo.contactCreatorUrl,
              fallbackError:
                  'Escríbenos a ${AppInfo.supportEmail} (toca largo para copiar).',
            ),
            onLongPress: () => _copyToClipboard(
              context,
              AppInfo.supportEmail,
              'Correo de contacto',
            ),
          ),
          const SizedBox(height: 10),

          _entryCard(
            context,
            key: const ValueKey('about-github'),
            glyph: InutilGlyph.code,
            title: 'Proyectos en GitHub (Familia Inútil)',
            subtitle: AppInfo.githubProfileUrl,
            onTap: () => _openExternalUrl(
              context,
              AppInfo.githubProfileUrl,
              fallbackError: 'No se pudo abrir el navegador.',
            ),
          ),

          const SizedBox(height: 26),

          Center(
            child: Text(
              '${AppInfo.appName} v${AppInfo.appVersion} · '
              'Creado por ${AppInfo.creatorName} · '
              '${AppInfo.supportEmail}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: subColor.withValues(alpha: 0.6),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _entryCard(
    BuildContext context, {
    Key? key,
    required InutilGlyph glyph,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    Color? iconColorOverride,
  }) {
    final accent = iconColorOverride ?? AppColors.accentFor(context);
    final subColor = AppColors.contentSubtitleFor(context);

    return Material(
      key: key,
      color: AppColors.cardSurfaceFor(context),
      borderRadius: BorderRadius.circular(appCardRadius),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(appCardRadius),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(appCardRadius),
            border: Border.all(
              color: AppColors.cardBorderFor(context),
              width: 0.85,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: appListCardIconSize,
                height: appListCardIconSize,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(appListCardIconRadius),
                ),
                child: Center(child: InutilIcon(glyph, size: 21, color: accent)),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: appListCardTitleStyle(context)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: appListCardSubtitleStyle(context)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: subColor.withValues(alpha: 0.5),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
