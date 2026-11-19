import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_info.dart';
import '../services/firebase_auth_service.dart';
import '../theme/app_colors.dart';
import '../theme/inutil_icons.dart';

/// Pantalla amigable cuando una cuenta gratuita de la Familia Inútil queda en
/// pausa automática por inactividad (portada 1:1 desde Inútil Music v2.4).
class InutilInactivityPausedScreen extends StatefulWidget {
  const InutilInactivityPausedScreen({
    required this.user,
    required this.inactiveDays,
    required this.policyDays,
    this.onRequestReactivation,
    this.onCheckStatus,
    this.onSignOut,
    super.key,
  });

  final InutilUser user;
  final int inactiveDays;
  final int policyDays;

  final Future<bool> Function()? onRequestReactivation;
  final Future<void> Function()? onCheckStatus;
  final Future<void> Function()? onSignOut;

  @override
  State<InutilInactivityPausedScreen> createState() =>
      _InutilInactivityPausedScreenState();
}

class _InutilInactivityPausedScreenState
    extends State<InutilInactivityPausedScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  bool _requesting = false;
  bool _requested = false;
  bool _checking = false;
  String? _feedback;

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  Future<void> _requestReactivation() async {
    setState(() {
      _requesting = true;
      _feedback = null;
    });
    final ok = await (widget.onRequestReactivation ??
        InutilAuthService.instance.requestReactivation)();
    if (!mounted) return;
    setState(() {
      _requesting = false;
      _requested = ok;
      _feedback = ok
          ? 'Solicitud enviada. Te avisaremos en cuanto el creador la apruebe.'
          : 'No pudimos enviar la solicitud. Revisa tu conexión e inténtalo de nuevo.';
    });
  }

  Future<void> _checkStatus() async {
    setState(() {
      _checking = true;
      _feedback = null;
    });
    await (widget.onCheckStatus ??
        InutilAuthService.instance.refreshCurrentUserProfile)();
    if (!mounted) return;
    setState(() {
      _checking = false;
      if (InutilAuthService.instance.isInactivityPaused) {
        _feedback = 'Tu acceso sigue en pausa por ahora.';
      }
    });
  }

  Future<void> _support() async {
    try {
      await launchUrl(
        Uri.parse(AppInfo.supportDevelopmentUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final heading = AppColors.contentHeadingFor(context);
    final sub = AppColors.contentSubtitleFor(context);
    final safeGreen =
        isDark ? const Color(0xFF34D399) : const Color(0xFF15803D);
    final supportAmber =
        isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);

    final name = widget.user.displayName.trim().isNotEmpty
        ? widget.user.displayName.trim().split(' ').first
        : widget.user.email.split('@').first;

    return Scaffold(
      key: const ValueKey('inutil-inactivity-paused-screen'),
      backgroundColor: scaffoldBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -120,
            left: 0,
            right: 0,
            height: 300,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.2),
                    radius: 0.95,
                    colors: [
                      accent.withValues(alpha: isDark ? 0.14 : 0.08),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: AnimatedBuilder(
                          animation: _breath,
                          builder: (_, child) {
                            final t = Curves.easeInOut.transform(_breath.value);
                            return Container(
                              width: 92,
                              height: 92,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: accent.withValues(alpha: 0.12),
                                border: Border.all(
                                  color: accent.withValues(alpha: 0.36),
                                  width: 1.4,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: accent.withValues(
                                      alpha: (isDark ? 0.14 : 0.08) + 0.12 * t,
                                    ),
                                    blurRadius: 20 + 14 * t,
                                    spreadRadius: 1 + 3 * t,
                                  ),
                                ],
                              ),
                              child: child,
                            );
                          },
                          child: Center(
                            child: InutilIcon(
                              InutilGlyph.sleepTimer,
                              size: 40,
                              color: accent,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Tu acceso gratuito\nestá en pausa, $name',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: heading,
                          fontSize: 25,
                          height: 1.18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.6,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No detectamos actividad durante ${widget.inactiveDays} '
                        'días (el límite es ${widget.policyDays}). Para mantener '
                        'los cupos gratuitos disponibles para quienes ven InútilTV '
                        'a diario, tu acceso se pausó automáticamente.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: sub,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TU BIBLIOTECA SIGUE A SALVO',
                              style: TextStyle(
                                color: safeGreen,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 12),
                            _SafeRow(
                              glyph: InutilGlyph.bookmark,
                              text:
                                  'Mi Lista y canales favoritos respaldados en la nube',
                              iconColor: safeGreen,
                            ),
                            const SizedBox(height: 10),
                            _SafeRow(
                              glyph: InutilGlyph.sparkles,
                              text:
                                  'Tu historial, episodios vistos y Resumen del Año intactos',
                              iconColor: safeGreen,
                            ),
                            const SizedBox(height: 10),
                            _SafeRow(
                              glyph: InutilGlyph.settings,
                              text:
                                  'Tu apariencia y ajustes te esperan tal como los dejaste',
                              iconColor: safeGreen,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        key: const ValueKey('inactivity-request-reactivation'),
                        onPressed: _requesting || _requested
                            ? null
                            : _requestReactivation,
                        icon: _requesting
                            ? SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: onAccent,
                                ),
                              )
                            : Icon(
                                _requested
                                    ? Icons.check_circle_rounded
                                    : Icons.waving_hand_rounded,
                                size: 18,
                              ),
                        label: Text(
                          _requested
                              ? 'Solicitud enviada'
                              : 'Solicitar reactivación',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: onAccent,
                          disabledBackgroundColor:
                              accent.withValues(alpha: 0.25),
                          disabledForegroundColor:
                              heading.withValues(alpha: 0.65),
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          textStyle: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        key: const ValueKey('inactivity-check-status'),
                        onPressed: _checking ? null : _checkStatus,
                        icon: _checking
                            ? SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: accent,
                                ),
                              )
                            : InutilIcon(
                                InutilGlyph.refresh,
                                size: 17,
                                color: heading,
                              ),
                        label: const Text('Comprobar estado'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: heading,
                          side: BorderSide(color: border),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        key: const ValueKey('inactivity-support-creator'),
                        onPressed: _support,
                        icon: const Text('💛', style: TextStyle(fontSize: 16)),
                        label: const Text(
                          'Apoya al creador y obtén acceso permanente',
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: supportAmber,
                        ),
                      ),
                      if (_feedback != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _feedback!,
                          key: const ValueKey('inactivity-feedback'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: sub,
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      TextButton(
                        onPressed: () async {
                          await (widget.onSignOut ??
                              InutilAuthService.instance.signOut)();
                        },
                        child: Text(
                          'Cerrar sesión',
                          style: TextStyle(
                            color: sub,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SafeRow extends StatelessWidget {
  const _SafeRow({
    required this.glyph,
    required this.text,
    required this.iconColor,
  });

  final InutilGlyph glyph;
  final String text;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        InutilIcon(glyph, size: 18, color: iconColor),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.contentHeadingFor(context),
              fontSize: 13.5,
              height: 1.32,
            ),
          ),
        ),
      ],
    );
  }
}
