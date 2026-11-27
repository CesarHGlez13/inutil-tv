import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/firebase_auth_service.dart';
import '../services/inutil_cloud_backup_service.dart';
import '../services/tv_daily_usage_service.dart';
import '../services/tv_mode_service.dart';
import '../services/tv_qr_pairing_service.dart';
import '../theme/app_colors.dart';
import '../theme/inutil_icons.dart';
import 'inutil_inactivity_paused_screen.dart';
import 'inutil_tv_keyboard.dart';
import 'tv_focusable.dart';

/// Barrera de autenticación y licencias Firebase para InútilTV.
/// Comparte cuentas, vigencia y roles en tiempo real con Inútil Music.
class InutilAuthGate extends StatefulWidget {
  const InutilAuthGate({super.key, required this.child});

  final Widget child;

  @override
  State<InutilAuthGate> createState() => _InutilAuthGateState();
}

class _InutilAuthGateState extends State<InutilAuthGate>
    with WidgetsBindingObserver {
  final _auth = InutilAuthService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!_auth.isInitialized) {
      _auth.initialize();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _auth.onAppResumed();
      // Apertura de app (arranque en primer plano o `resumed`): único hook de
      // lifecycle que ya existía, la contabilidad la lleva el store.
      TvDailyUsageService.instance.noteAppOpen();
    } else if (state == AppLifecycleState.paused) {
      unawaited(InutilTvCloudBackupService.instance.pushNow());
      unawaited(TvDailyUsageService.instance.flush());
      unawaited(TvDailyUsageService.instance.flushRichAnalytics());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _auth,
      builder: (context, _) {
        if (!_auth.isInitialized) {
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            body: Center(
              child: CircularProgressIndicator(
                color: AppColors.accentFor(context),
                strokeWidth: 2.6,
              ),
            ),
          );
        }

        final user = _auth.currentUser;

        // 1. Sin sesión iniciada -> Pantalla de acceso / registro Firebase
        if (user == null) {
          return const InutilAuthScreen();
        }

        // 2. Sesión expulsada (otro dispositivo, cuenta eliminada o bloqueada)
        if (_auth.isKickedOut) {
          return InutilLicenseBlockedScreen(
            user: user,
            reason: _auth.kickedOutReason,
          );
        }

        // 2b. Cuenta gratuita en pausa automática por inactividad
        if (_auth.isInactivityPaused) {
          return InutilInactivityPausedScreen(
            user: user,
            inactiveDays: _auth.inactiveDays,
            policyDays: _auth.inactivityPolicyDays,
          );
        }

        // 3. Cuenta registrada pero pendiente, suspendida o vencida (no admin)
        if (!user.isAdmin &&
            (!user.isActive || user.status == 'pending' || user.isExpired)) {
          return InutilLicenseBlockedScreen(user: user);
        }

        // 4. Acceso autorizado: Admin o usuario con licencia activa vigente
        return widget.child;
      },
    );
  }
}

/// Pantalla cinemática de Inicio de Sesión y Registro Firebase de InútilTV.
class InutilAuthScreen extends StatefulWidget {
  const InutilAuthScreen({super.key});

  @override
  State<InutilAuthScreen> createState() => _InutilAuthScreenState();
}

class _InutilAuthScreenState extends State<InutilAuthScreen>
    with SingleTickerProviderStateMixin {
  bool _isRegister = false;
  bool _isLoading = false;
  bool _isGoogleLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _displayNameController = TextEditingController();

  late final FocusNode _displayNameFocus =
      TvFocusable.createTextFieldFocusNode(
    controller: _displayNameController,
    tvKeyboardTitle: 'Tu Nombre o Alias',
    tvKeyboardMode: InutilTvKeyboardMode.text,
  );
  late final FocusNode _emailFocus = TvFocusable.createTextFieldFocusNode(
    controller: _emailController,
    tvKeyboardTitle: 'Correo Electrónico',
    tvKeyboardHint: 'ejemplo@gmail.com',
    tvKeyboardMode: InutilTvKeyboardMode.email,
  );
  late final FocusNode _passwordFocus = TvFocusable.createTextFieldFocusNode(
    controller: _passwordController,
    tvKeyboardTitle: 'Contraseña',
    tvKeyboardMode: InutilTvKeyboardMode.password,
    obscureText: true,
  );
  final FocusNode _eyeSkipFocus = FocusNode(skipTraversal: true);
  final FocusNode _copyIdSkipFocus = FocusNode(skipTraversal: true);

  TvQrPairingSession? _qrSession;
  bool _qrLoading = false;
  String? _qrStatusMessage;
  Timer? _qrPollTimer;
  bool _qrPolling = false;

  late final AnimationController _glowAnim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    if (TvModeService.instance.isTv) {
      unawaited(_startQrPairing());
    }
  }

  Future<void> _startQrPairing() async {
    _qrPollTimer?.cancel();
    final oldCode = _qrSession?.code;
    if (oldCode != null) {
      unawaited(TvQrPairingService.instance.cleanupTvSession(oldCode));
    }
    if (!mounted) return;
    setState(() {
      _qrLoading = true;
      _qrStatusMessage = null;
      _qrSession = null;
    });
    final session = await TvQrPairingService.instance.createTvSession();
    if (!mounted) return;
    if (session == null) {
      setState(() {
        _qrLoading = false;
        _qrStatusMessage = 'No se pudo generar el QR. Revisa tu conexión.';
      });
      return;
    }
    setState(() {
      _qrLoading = false;
      _qrSession = session;
      _qrStatusMessage = null;
    });
    _qrPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_qrPolling || !mounted || _qrSession == null) return;
      _qrPolling = true;
      try {
        final res = await TvQrPairingService.instance
            .pollAndCompleteTvSession(_qrSession!);
        if (!mounted || res == null) return;
        if (res == 'OK') {
          _qrPollTimer?.cancel();
        } else if (res == 'EXPIRED') {
          _qrPollTimer?.cancel();
          setState(() {
            _qrStatusMessage = 'El código expiró. Pulsa para generar uno nuevo.';
          });
        } else {
          _qrPollTimer?.cancel();
          setState(() => _qrStatusMessage = res);
        }
      } finally {
        _qrPolling = false;
      }
    });
  }

  @override
  void dispose() {
    _qrPollTimer?.cancel();
    final pendingCode = _qrSession?.code;
    if (pendingCode != null && !InutilAuthService.instance.isAuthenticated) {
      unawaited(TvQrPairingService.instance.cleanupTvSession(pendingCode));
    }
    _emailController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    _displayNameFocus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _eyeSkipFocus.dispose();
    _copyIdSkipFocus.dispose();
    _glowAnim.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(
        () => _errorMessage = 'Por favor ingresa tu correo y contraseña.',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final auth = InutilAuthService.instance;
      if (_isRegister) {
        await auth.register(
          email: email,
          password: password,
          displayName: _displayNameController.text.trim(),
        );
      } else {
        await auth.signIn(email: email, password: password);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _submitGoogle() async {
    setState(() {
      _isGoogleLoading = true;
      _errorMessage = null;
    });
    try {
      await InutilAuthService.instance.signInWithGoogle();
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _isGoogleLoading = false);
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final resetCtl = TextEditingController(text: _emailController.text.trim());
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final accent = AppColors.accentFor(ctx);
        final onAccent = AppColors.onAccentFor(ctx);
        final surface = AppColors.cardSurfaceFor(ctx);
        final inputBg = AppColors.inputSurfaceFor(ctx);
        final border = AppColors.cardBorderFor(ctx);
        final heading = AppColors.contentHeadingFor(ctx);
        final sub = AppColors.contentSubtitleFor(ctx);

        return AlertDialog(
          backgroundColor: surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: border, width: 1.0),
          ),
          title: Row(
            children: [
              InutilIcon(InutilGlyph.lock, size: 20, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Recuperar Contraseña',
                  style: TextStyle(
                    color: heading,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ingresa tu correo registrado de la familia Inutix para recibir un enlace de restablecimiento:',
                style: TextStyle(color: sub, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: resetCtl,
                style: TextStyle(color: heading, fontSize: 14),
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Correo Electrónico',
                  labelStyle: TextStyle(color: sub),
                  prefixIcon: Icon(Icons.email_outlined, color: accent),
                  filled: true,
                  fillColor: inputBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: accent, width: 1.4),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Cancelar', style: TextStyle(color: sub)),
            ),
            FilledButton(
              onPressed: () async {
                final email = resetCtl.text.trim();
                if (email.isNotEmpty) {
                  await InutilAuthService.instance.sendPasswordReset(email);
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Si $email está registrado, recibirás un correo para restablecer tu contraseña.',
                        ),
                      ),
                    );
                  }
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: onAccent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: const Text(
                'Enviar',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        );
      },
    );
    resetCtl.dispose();
  }

  InputDecoration _fieldDecoration(
    BuildContext context, {
    required String label,
    required IconData icon,
    Widget? suffix,
  }) {
    final accent = AppColors.accentFor(context);
    final inputBg = AppColors.inputSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final sub = AppColors.contentSubtitleFor(context);

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: sub, fontSize: 13),
      prefixIcon: Icon(icon, color: accent, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: inputBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: accent, width: 1.4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final isTv = TvModeService.of(context) ||
        (screenSize.width >= 800 && screenSize.height <= 620);
    final isDesktop = screenSize.width > 700;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final surfaceCard = AppColors.cardSurfaceFor(context);
    final elevated = AppColors.elevatedSurfaceFor(context);
    final inputBg = AppColors.inputSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final heading = AppColors.contentHeadingFor(context);
    final sub = AppColors.contentSubtitleFor(context);
    final divider = AppColors.dividerFor(context);
    final deviceId = InutilAuthService.instance.deviceId;
    final shortDevId =
        deviceId.length > 12 ? deviceId.substring(0, 12).toUpperCase() : deviceId;

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -120,
            right: -110,
            child: IgnorePointer(
              child: Container(
                width: 340,
                height: 340,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      accent.withValues(alpha: isDark ? 0.14 : 0.08),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -130,
            left: -120,
            child: IgnorePointer(
              child: Container(
                width: 340,
                height: 340,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      accent.withValues(alpha: isDark ? 0.08 : 0.05),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Builder(
              builder: (context) {
                final brandColumn = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedBuilder(
                      animation: _glowAnim,
                      builder: (context, child) => Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: accent.withValues(
                                alpha: (isDark ? 0.14 : 0.08) +
                                    (_glowAnim.value * 0.14),
                              ),
                              blurRadius: 24 + (_glowAnim.value * 12),
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: child,
                      ),
                      child: Image.asset(
                        'assets/logo.png',
                        height: isTv ? 56 : 82,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => InutilIcon(
                          InutilGlyph.liveTv,
                          size: isTv ? 46 : 60,
                          color: accent,
                        ),
                      ),
                    ),
                    SizedBox(height: isTv ? 8 : 14),
                    Text(
                      'INUTIX TV',
                      style: TextStyle(
                        fontSize: isTv ? 22 : 25,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.0,
                        color: heading,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (!isTv) ...[
                      Text(
                        'Cuenta Unificada · Ecosistema inutix.com',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: sub,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: elevated,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.fingerprint_rounded,
                            color: accent,
                            size: 15,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'TV-$shortDevId',
                            style: TextStyle(
                              color: heading,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            focusNode: _copyIdSkipFocus,
                            onTap: () {
                              Clipboard.setData(
                                ClipboardData(text: deviceId),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('ID de dispositivo copiado'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            },
                            child: Icon(
                              Icons.copy_rounded,
                              color: sub,
                              size: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isTv) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: surfaceCard,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: border),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_qrLoading)
                              const SizedBox(
                                width: 148,
                                height: 148,
                                child: Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                ),
                              )
                            else if (_qrSession != null &&
                                !_qrSession!.isExpired)
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: QrImageView(
                                  data: _qrSession!.qrUri,
                                  version: QrVersions.auto,
                                  size: 144,
                                  eyeStyle: const QrEyeStyle(
                                    eyeShape: QrEyeShape.square,
                                    color: Color(0xFF070709),
                                  ),
                                  dataModuleStyle: const QrDataModuleStyle(
                                    dataModuleShape: QrDataModuleShape.square,
                                    color: Color(0xFF070709),
                                  ),
                                ),
                              )
                            else
                              SizedBox(
                                width: 156,
                                height: 120,
                                child: Center(
                                  child: OutlinedButton.icon(
                                    onPressed: _startQrPairing,
                                    icon: const Icon(
                                      Icons.refresh_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('Generar QR'),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 10),
                            Text(
                              _qrStatusMessage ??
                                  'Escanea desde Inutix TV en tu celular',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _qrStatusMessage != null
                                    ? Colors.amberAccent
                                    : heading,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _qrSession != null
                                  ? 'Código ${_qrSession!.displayCode} · 1 celular + 1 TV'
                                  : 'Ajustes → Vincular Smart TV',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: sub,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                );

                final authCard = Container(
                  padding: EdgeInsets.all(isTv ? 18 : 22),
                  decoration: BoxDecoration(
                    color: surfaceCard,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: border, width: 1.0),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.45 : 0.08,
                        ),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                            Container(
                              height: 44,
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: inputBg,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: border),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TvFocusable(
                                      autofocus: isTv,
                                      onTap: () => setState(() {
                                        _isRegister = false;
                                        _errorMessage = null;
                                      }),
                                      borderRadius: BorderRadius.circular(10),
                                      focusScale: 1.02,
                                      child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 200),
                                        decoration: BoxDecoration(
                                          color: !_isRegister
                                              ? accent
                                              : Colors.transparent,
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        alignment: Alignment.center,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          child: Text(
                                            'Iniciar Sesión',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w800,
                                              color: !_isRegister
                                                  ? onAccent
                                                  : sub,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: TvFocusable(
                                      onTap: () => setState(() {
                                        _isRegister = true;
                                        _errorMessage = null;
                                      }),
                                      borderRadius: BorderRadius.circular(10),
                                      focusScale: 1.02,
                                      child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 200),
                                        decoration: BoxDecoration(
                                          color: _isRegister
                                              ? accent
                                              : Colors.transparent,
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        alignment: Alignment.center,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          child: Text(
                                            'Crear Cuenta',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w800,
                                              color: _isRegister
                                                  ? onAccent
                                                  : sub,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),

                            if (_errorMessage != null) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      Colors.redAccent.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.redAccent
                                        .withValues(alpha: 0.35),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.error_outline_rounded,
                                      color: Colors.redAccent,
                                      size: 19,
                                    ),
                                    const SizedBox(width: 9),
                                    Expanded(
                                      child: Text(
                                        _errorMessage!,
                                        style: const TextStyle(
                                          color: Colors.redAccent,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            if (_isRegister) ...[
                              TextField(
                                controller: _displayNameController,
                                focusNode: _displayNameFocus,
                                readOnly: TvModeService.of(context),
                                showCursor: true,
                                onTap: TvModeService.of(context)
                                    ? () => InutilTvKeyboard.showModal(
                                          context,
                                          controller: _displayNameController,
                                          title: 'Tu Nombre o Alias',
                                          mode: InutilTvKeyboardMode.text,
                                        )
                                    : null,
                                style: TextStyle(
                                  color: heading,
                                  fontSize: 14,
                                ),
                                textInputAction: TextInputAction.next,
                                onSubmitted: (_) {
                                  _emailFocus.requestFocus();
                                  if (!TvModeService.of(context)) {
                                    SystemChannels.textInput
                                        .invokeMethod<void>('TextInput.show');
                                  }
                                },
                                decoration: _fieldDecoration(
                                  context,
                                  label: 'Tu Nombre o Alias',
                                  icon: Icons.person_outline_rounded,
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],

                            TextField(
                              controller: _emailController,
                              focusNode: _emailFocus,
                              readOnly: TvModeService.of(context),
                              showCursor: true,
                              onTap: TvModeService.of(context)
                                  ? () => InutilTvKeyboard.showModal(
                                        context,
                                        controller: _emailController,
                                        title: 'Correo Electrónico',
                                        mode: InutilTvKeyboardMode.email,
                                      )
                                  : null,
                              style: TextStyle(
                                color: heading,
                                fontSize: 14,
                              ),
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              onSubmitted: (_) {
                                _passwordFocus.requestFocus();
                                if (!TvModeService.of(context)) {
                                  SystemChannels.textInput
                                      .invokeMethod<void>('TextInput.show');
                                }
                              },
                              decoration: _fieldDecoration(
                                context,
                                label: 'Correo Electrónico',
                                icon: Icons.email_outlined,
                              ),
                            ),
                            const SizedBox(height: 12),

                            TextField(
                              controller: _passwordController,
                              focusNode: _passwordFocus,
                              readOnly: TvModeService.of(context),
                              showCursor: true,
                              onTap: TvModeService.of(context)
                                  ? () => InutilTvKeyboard.showModal(
                                        context,
                                        controller: _passwordController,
                                        title: 'Contraseña',
                                        mode: InutilTvKeyboardMode.password,
                                        obscureText: _obscurePassword,
                                      )
                                  : null,
                              style: TextStyle(
                                color: heading,
                                fontSize: 14,
                              ),
                              obscureText: _obscurePassword,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _submit(),
                              decoration: _fieldDecoration(
                                context,
                                label: 'Contraseña',
                                icon: Icons.lock_outline_rounded,
                                suffix: IconButton(
                                  focusNode: _eyeSkipFocus,
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    color: sub,
                                    size: 20,
                                  ),
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),

                            if (!_isRegister)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: _showForgotPasswordDialog,
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: Text(
                                    '¿Olvidaste tu contraseña?',
                                    style: TextStyle(
                                      color: accent,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),

                            const SizedBox(height: 18),

                            SizedBox(
                              height: 48,
                              child: FilledButton(
                                onPressed:
                                    (_isLoading || _isGoogleLoading)
                                        ? null
                                        : _submit,
                                style: FilledButton.styleFrom(
                                  backgroundColor: accent,
                                  foregroundColor: onAccent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                child: _isLoading
                                    ? SizedBox.square(
                                        dimension: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: onAccent,
                                        ),
                                      )
                                    : Text(
                                        _isRegister
                                            ? 'Crear Cuenta en Familia Inutix'
                                            : 'Acceder a Inutix TV',
                                        style: const TextStyle(
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                              ),
                            ),

                            const SizedBox(height: 16),

                            Row(
                              children: [
                                Expanded(child: Divider(color: divider)),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Text(
                                    'o continúa con',
                                    style: TextStyle(
                                      color: sub,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                Expanded(child: Divider(color: divider)),
                              ],
                            ),

                            const SizedBox(height: 14),

                            SizedBox(
                              height: 48,
                              child: OutlinedButton(
                                onPressed: (_isLoading || _isGoogleLoading)
                                    ? null
                                    : _submitGoogle,
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: const Color(0xFF1F1F1F),
                                  side: BorderSide(color: border),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                child: _isGoogleLoading
                                    ? const SizedBox.square(
                                        dimension: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.4,
                                          color: Color(0xFF4285F4),
                                        ),
                                      )
                                    : Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Container(
                                            width: 22,
                                            height: 22,
                                            alignment: Alignment.center,
                                            decoration: const BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: Color(0xFFF1F3F4),
                                            ),
                                            child: const Text(
                                              'G',
                                              style: TextStyle(
                                                color: Color(0xFF4285F4),
                                                fontSize: 15,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          const Flexible(
                                            child: Text(
                                              'Continuar con Google',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.2,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                          ],
                        ),
                      );

                final footerInfo = Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: elevated,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: border),
                  ),
                  child: Row(
                    children: [
                      InutilIcon(
                        InutilGlyph.shield,
                        size: 18,
                        color: sub,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Usa la misma cuenta de Inutix Music. Se requiere licencia activa otorgada por el Administrador (César).',
                          style: TextStyle(
                            color: sub,
                            fontSize: 11.5,
                            height: 1.38,
                          ),
                        ),
                      ),
                    ],
                  ),
                );

                if (isTv) {
                  return Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 36,
                        vertical: 16,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 880),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(flex: 4, child: brandColumn),
                            const SizedBox(width: 32),
                            Expanded(flex: 6, child: authCard),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 28,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: isDesktop ? 460 : 420,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          brandColumn,
                          const SizedBox(height: 22),
                          authCard,
                          const SizedBox(height: 20),
                          footerInfo,
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Pantalla mostrada cuando la cuenta está pendiente, suspendida, expirada
/// o fue desplazada por otro dispositivo.
class InutilLicenseBlockedScreen extends StatefulWidget {
  const InutilLicenseBlockedScreen({
    super.key,
    required this.user,
    this.reason,
  });

  final InutilUser user;
  final String? reason;

  @override
  State<InutilLicenseBlockedScreen> createState() =>
      _InutilLicenseBlockedScreenState();
}

class _InutilLicenseBlockedScreenState
    extends State<InutilLicenseBlockedScreen> {
  bool _isChecking = false;

  Future<void> _checkStatus() async {
    setState(() => _isChecking = true);
    await InutilAuthService.instance.refreshCurrentUserProfile();
    if (mounted) setState(() => _isChecking = false);
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return 'Sin fecha asignada';
    if (dt.year >= 2090) return 'Licencia Permanente';
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final y = dt.year;
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$d/$m/$y $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final isPending = user.status == 'pending' && !user.isAdmin;
    final isSuspended = !user.isActive && !isPending;
    final reason = widget.reason;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final userAccent = AppColors.accentFor(context);
    final onUserAccent = AppColors.onAccentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final elevated = AppColors.elevatedSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final heading = AppColors.contentHeadingFor(context);
    final sub = AppColors.contentSubtitleFor(context);
    final divider = AppColors.dividerFor(context);

    final String title;
    final String message;
    final Color statusAccent;
    final IconData icon;

    if (reason != null && reason.isNotEmpty) {
      title = 'SESIÓN BLOQUEADA';
      message = reason;
      statusAccent = Colors.redAccent;
      icon = Icons.phonelink_lock_rounded;
    } else if (isPending) {
      title = 'CUENTA PENDIENTE';
      message =
          'Tu cuenta ya está registrada en Firebase, pero el Administrador aún no te ha concedido vigencia. En cuanto César la active podrás entrar a Inutix TV e Inutix Music.';
      statusAccent = userAccent;
      icon = Icons.hourglass_top_rounded;
    } else if (isSuspended) {
      title = 'CUENTA SUSPENDIDA';
      message =
          'Tu cuenta ha sido desactivada temporalmente por el Administrador.';
      statusAccent =
          isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706);
      icon = Icons.block_rounded;
    } else {
      title = 'LICENCIA VENCIDA';
      message =
          'Tu periodo de vigencia en la familia Inutix ha caducado. Solicita al Administrador una renovación para seguir disfrutando de Inutix TV.';
      statusAccent = Colors.redAccent;
      icon = Icons.lock_clock_rounded;
    }

    return Scaffold(
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
                      statusAccent.withValues(alpha: isDark ? 0.14 : 0.08),
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
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: statusAccent.withValues(alpha: 0.13),
                          border: Border.all(
                            color: statusAccent.withValues(alpha: 0.36),
                            width: 1.4,
                          ),
                        ),
                        child: Icon(icon, size: 40, color: statusAccent),
                      ),
                      const SizedBox(height: 20),

                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                          color: heading,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: sub,
                          height: 1.48,
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
                          children: [
                            _infoRow(
                              context,
                              'Usuario',
                              user.displayName.isNotEmpty
                                  ? user.displayName
                                  : user.email.split('@').first,
                            ),
                            Divider(color: divider, height: 18),
                            _infoRow(context, 'Correo', user.email),
                            Divider(color: divider, height: 18),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'UID Cuenta',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: sub,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: InkWell(
                                    onTap: () {
                                      Clipboard.setData(
                                        ClipboardData(text: user.uid),
                                      );
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text('UID copiado'),
                                          duration: Duration(seconds: 1),
                                        ),
                                      );
                                    },
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            user.uid,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              color: userAccent,
                                              fontWeight: FontWeight.w700,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 5),
                                        Icon(
                                          Icons.copy_rounded,
                                          size: 13,
                                          color: sub,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Divider(color: divider, height: 18),
                            _infoRow(
                              context,
                              'Vencimiento',
                              _formatDate(user.accountExpiresAt),
                            ),
                            Divider(color: divider, height: 18),
                            _infoRow(
                              context,
                              'Estado',
                              reason != null && reason.isNotEmpty
                                  ? 'Sesión bloqueada'
                                  : isPending
                                      ? 'Pendiente de aprobación'
                                      : isSuspended
                                          ? 'Suspendida'
                                          : 'Expirada',
                              color: statusAccent,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),

                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: _isChecking ? null : _checkStatus,
                          icon: _isChecking
                              ? SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: onUserAccent,
                                  ),
                                )
                              : InutilIcon(
                                  InutilGlyph.refresh,
                                  size: 18,
                                  color: onUserAccent,
                                ),
                          label: const Text(
                            'Comprobar Estado en Firebase',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: userAccent,
                            foregroundColor: onUserAccent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: OutlinedButton.icon(
                          onPressed: () => InutilAuthService.instance.signOut(),
                          icon: Icon(
                            Icons.logout_rounded,
                            size: 17,
                            color: heading,
                          ),
                          label: Text(
                            'Cerrar Sesión e Ingresar con otra Cuenta',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: heading,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: border),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),

                      Container(
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: elevated,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: border),
                        ),
                        child: Row(
                          children: [
                            InutilIcon(
                              InutilGlyph.info,
                              size: 18,
                              color: userAccent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Ponte en contacto con César (Administrador) indicando tu correo o UID para activar tu licencia de acceso.',
                                style: TextStyle(
                                  color: sub,
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
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

  Widget _infoRow(
    BuildContext context,
    String label,
    String value, {
    Color? color,
  }) {
    final heading = AppColors.contentHeadingFor(context);
    final sub = AppColors.contentSubtitleFor(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12.5, color: sub),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: color ?? heading,
            ),
          ),
        ),
      ],
    );
  }
}
