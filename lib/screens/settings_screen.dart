import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_info.dart';
import '../services/app_settings_service.dart';
import '../services/firebase_auth_service.dart';
import '../services/inutil_cloud_backup_service.dart';
import '../services/inutil_update_service.dart';
import '../services/network_config_service.dart';
import '../services/offline_vault_service.dart';
import '../services/sleep_timer_service.dart';
import '../services/watch_history.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import '../widgets/inutil_admin_panel.dart';
import '../widgets/inutil_sleep_timer_sheet.dart';
import '../services/tv_mode_service.dart';
import '../services/tv_remote_service.dart';
import '../widgets/inutil_update_gate.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/tv_remote_sheet.dart';
import 'about_screen.dart';
import 'downloads_screen.dart';
import 'tv_qr_scanner_screen.dart';

/// Ajustes y Perfil de Usuario de InútilTV v3.0 — paridad visual con Inútil Music:
/// - App 100% para usuario final (administración exclusivamente desde Firebase Web).
/// - Personalización de Apariencia idéntica a Inútil Music:
///   Tema (Oscuro / Claro / Sistema), Superficies (Liquid Glass / Transparente / Acento)
///   y los 18 colores de acento (por defecto Blanco Puro `#F5F7F5`).
/// - Cuenta Firebase unificada, Motor de Video, Actualizaciones OTA y Acerca de.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _auth = InutilAuthService.instance;
  final _settings = AppSettingsService.instance;
  final _backup = InutilTvCloudBackupService.instance;
  final _network = NetworkConfigService.instance;
  bool _syncing = false;
  bool _checkingOta = false;
  bool _checkingNetwork = false;
  NetworkReport? _networkReport;
  int _historyCount = 0;

  @override
  void initState() {
    super.initState();
    _settings.load();
    _network.load();
    OfflineVaultService.instance.initialize();
    _loadHistory();
  }

  Future<void> _checkOtaNow() async {
    setState(() => _checkingOta = true);
    final release = await InutilUpdateService.instance.checkForUpdate();
    if (!mounted) return;
    setState(() => _checkingOta = false);
    await showInutilUpdateDialog(context, release: release);
  }

  /// Pide el proxy de la red (empresas, hoteles, aeropuertos) y lo guarda.
  Future<void> _editProxySetting() async {
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final controller = TextEditingController(text: _network.proxyHostPort);

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.elevatedSurfaceFor(dialogContext),
        title: const Text('Proxy de tu red'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Algunas redes sólo dejan salir a internet por un proxy. '
              'Escribe su dirección y puerto, por ejemplo 192.168.1.10:3128. '
              'Déjalo vacío para conectarte directo.',
              style: appListCardSubtitleStyle(dialogContext),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                hintText: '192.168.1.10:3128',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: onAccent,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (saved != true || !mounted) return;
    final error = await _network.setProxy(controller.text);
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error), duration: const Duration(seconds: 3)),
    );
  }

  /// Mide si la red actual deja abrir cada parte de la app.
  Future<void> _runNetworkCheck() async {
    setState(() => _checkingNetwork = true);
    final report = await _network.runDiagnostics();
    if (!mounted) return;
    setState(() {
      _checkingNetwork = false;
      _networkReport = report;
    });

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.elevatedSurfaceFor(dialogContext),
        title: Text(
          report.allOk
              ? 'Tu red deja ver Inutix TV'
              : (report.checks.any(
                    (c) => !c.ok && c.detail.startsWith('HTTP 5'),
                  )
                  ? 'El video no responde en esta red'
                  : 'Tu red está bloqueando algo'),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final check in report.checks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Icon(
                      check.ok
                          ? Icons.check_circle_rounded
                          : Icons.error_rounded,
                      size: 18,
                      color: check.ok
                          ? Colors.greenAccent
                          : const Color(0xFFFF6B6B),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        check.ok
                            ? '${check.label} · ${check.millis} ms'
                            : '${check.label} · ${check.detail.isEmpty ? 'sin respuesta' : check.detail}',
                        style: appListCardTitleStyle(dialogContext),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              _networkAdvice(report),
              style: appListCardSubtitleStyle(dialogContext),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  /// Consejo legible según lo que respondió la comprobación.
  String _networkAdvice(NetworkReport report) {
    if (report.allOk) {
      return 'Todo en orden. Si aun así un título no abre, reintenta: suele '
          'ser ese servidor, no tu red.';
    }
    final saturado = report.checks.any(
      (c) => !c.ok && c.detail.startsWith('HTTP 5'),
    );
    if (saturado) {
      return 'El video respondió con un error (servidor saturado o '
          'filtro de tu red). Vuelve a comprobar la conexión en un '
          'momento; si sigue igual en esta red, escríbele el punto de '
          'salida de tu empresa en «Salida por proxy».';
    }
    if (report.viaProxy) {
      return 'El proxy configurado no está dejando pasar todo. Revisa la '
          'dirección con tu empresa o vuelve a dejarlo vacío.';
    }
    if (!report.viaSecureDns) {
      return 'Activa «Búsqueda segura de servidores»: tu red está '
          'bloqueando algunos sitios. Si tu empresa usa un punto de '
          'salida, escríbelo en «Salida por proxy».';
    }
    return 'Tu red bloquea incluso la conexión cifrada. Pide a tu empresa que '
        'permita los dominios de video, o usa datos móviles.';
  }

  Future<void> _loadHistory() async {
    await WatchHistory().load();
    if (mounted) {
      setState(() => _historyCount = WatchHistory().items.length);
    }
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return 'Sin fecha';
    if (dt.year >= 2090) return 'Licencia Permanente';
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    return '$d/$m/${dt.year}';
  }

  Future<void> _pushCloudBackup() async {
    final msg = await _backup.pushNow(force: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _restoreCloudBackup() async {
    final msg = await _backup.pullAndRestoreIfEmpty(mergeOverwrite: true);
    await _loadHistory();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _syncLicenseNow() async {
    setState(() => _syncing = true);
    await _auth.refreshCurrentUserProfile();
    if (mounted) {
      setState(() => _syncing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Estado de licencia sincronizado con Firebase.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _changePasswordDialog() async {
    final passCtl = TextEditingController();
    final confirmCtl = TextEditingController();
    String? error;
    bool saving = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text(
            'Cambiar Contraseña',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error != null) ...[
                Text(
                  error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: passCtl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Nueva contraseña (mín. 6 caracteres)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirmCtl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirmar contraseña',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final p1 = passCtl.text;
                      final p2 = confirmCtl.text;
                      if (p1.length < 6) {
                        setDialogState(() => error = 'Mínimo 6 caracteres.');
                        return;
                      }
                      if (p1 != p2) {
                        setDialogState(
                          () => error = 'Las contraseñas no coinciden.',
                        );
                        return;
                      }
                      setDialogState(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        await _auth.changePassword(p1);
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content:
                                  Text('Contraseña actualizada en Firebase.'),
                            ),
                          );
                        }
                      } catch (e) {
                        setDialogState(() {
                          saving = false;
                          error = e.toString().replaceAll('Exception: ', '');
                        });
                      }
                    },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    passCtl.dispose();
    confirmCtl.dispose();
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '¿Borrar el historial?',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Se eliminará el progreso de $_historyCount títulos. Tu cuenta y licencia Firebase no se ven afectadas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await WatchHistory().clear();
    if (mounted) setState(() => _historyCount = 0);
  }

  Future<void> _confirmLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Cerrar Sesión',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        content: const Text(
          'Se desvinculará este equipo de tu cuenta Firebase. Podrás volver a iniciar sesión en cualquier momento.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cerrar Sesión'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _auth.signOut();
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppColors.accentFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);

    return ListenableBuilder(
      listenable: Listenable.merge([
        _auth,
        _settings,
        _backup,
        _network,
        SleepTimerService.instance,
        OfflineVaultService.instance,
      ]),
      builder: (context, _) {
        final user = _auth.currentUser;
        final isPermanent = user?.isPermanent ?? false;
        final days = user?.daysRemaining ?? 0;
        final deviceId = _auth.deviceId;
        final shortDev =
            deviceId.length > 14 ? '${deviceId.substring(0, 14)}…' : deviceId;

        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          appBar: AppBar(
            backgroundColor: theme.scaffoldBackgroundColor,
            title: Text(
              'Ajustes',
              style: appTabTitleStyle(context).copyWith(fontSize: 21),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              appPagePaddingHorizontal,
              8,
              appPagePaddingHorizontal,
              32,
            ),
            children: [
              // 1. Tarjeta de Perfil Firebase (sobria, sin botones de admin en la app)
              _cardContainer(
                context,
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Center(
                            child: InutilIcon(
                              InutilGlyph.profile,
                              size: 24,
                              color: accent,
                              filled: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user?.displayName.isNotEmpty == true
                                    ? user!.displayName
                                    : (user?.email.split('@').first ??
                                        'Usuario Inútil'),
                                style: TextStyle(
                                  color: headingColor,
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              if (user != null)
                                Text(
                                  user.email,
                                  style: TextStyle(
                                    color: subColor,
                                    fontSize: 12,
                                  ),
                                ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text(
                                  isPermanent
                                      ? 'LICENCIA PERMANENTE'
                                      : 'ACTIVA · $days días restantes',
                                  style: TextStyle(
                                    color: accent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    const SizedBox(height: 12),
                    _metaRow(
                      context,
                      'Ecosistema',
                      'Familia Inútil (TV + Music)',
                    ),
                    const SizedBox(height: 6),
                    _metaRow(
                      context,
                      'Vigencia',
                      isPermanent
                          ? 'Sin vencimiento'
                          : _formatDate(user?.accountExpiresAt),
                    ),
                    const SizedBox(height: 6),
                    _copyRow(context, 'ID Equipo', shortDev, deviceId),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              // ─── 1.5 Administración VIP (Solo para cuentas con rol admin) ───
              if (user?.isAdmin == true) ...[
                Text('Administración Firebase VIP',
                    style: appSectionTitleStyle(context)),
                const SizedBox(height: 10),
                _cardContainer(
                  context,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8B949)
                                  .withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFFE8B949)
                                    .withValues(alpha: 0.4),
                              ),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.admin_panel_settings_rounded,
                                color: Color(0xFFE8B949),
                                size: 24,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Panel de Licencias y Cuentas',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Gestión profesional de usuarios, roles, días y equipos en Firebase',
                                  style: TextStyle(
                                    color: subColor,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFE8B949),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 0,
                          ),
                          onPressed: () => InutilAdminPanel.show(context),
                          icon: const Icon(Icons.manage_accounts_rounded,
                              size: 19),
                          label: const Text(
                            'Abrir Panel de Control VIP',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
              ],

              // 2. Apariencia (exactamente igual que Inútil Music!)
              Text('Apariencia', style: appSectionTitleStyle(context)),
              const SizedBox(height: 10),
              _cardContainer(
                context,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _squircleIcon(context, InutilGlyph.palette),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Color de acento',
                                style: appListCardTitleStyle(context),
                              ),
                              Text(
                                _settings.accent.labelEs,
                                style: appListCardSubtitleStyle(context),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 36,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: AppAccent.values.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (_, idx) {
                          final a = AppAccent.values[idx];
                          final selected = a == _settings.accent;
                          return Tooltip(
                            message: a.labelEs,
                            child: TvFocusable(
                              onTap: () => _settings.setAccent(a),
                              borderRadius: BorderRadius.circular(20),
                              focusScale: 1.12,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: a.seedColor,
                                  border: Border.all(
                                    color: selected
                                        ? headingColor
                                        : Colors.white.withValues(alpha: 0.25),
                                    width: selected ? 2.5 : 1,
                                  ),
                                ),
                                child: selected
                                    ? Icon(
                                        Icons.check_rounded,
                                        size: 16,
                                        color: ThemeData.estimateBrightnessForColor(
                                                  a.seedColor,
                                                ) ==
                                                Brightness.light
                                            ? AppColors.playbackPrimaryForeground
                                            : Colors.white,
                                      )
                                    : null,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    const SizedBox(height: 14),
                    Text('Superficies y barra flotante',
                        style: appListCardTitleStyle(context)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final mode in SurfaceBackgroundMode.values)
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(
                                right: mode == SurfaceBackgroundMode.values.last
                                    ? 0
                                    : 8,
                              ),
                              child: _choicePill(
                                context,
                                label: mode.labelEs,
                                selected: _settings.surfaceMode == mode,
                                onTap: () => _settings.setSurfaceMode(mode),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text('Tema', style: appListCardTitleStyle(context)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final mode in AppThemeMode.values)
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(
                                right:
                                    mode == AppThemeMode.values.last ? 0 : 8,
                              ),
                                child: _choicePill(
                                  context,
                                  label: mode.labelEs,
                                  selected: _settings.themeMode == mode,
                                  onTap: () => _settings.setThemeMode(mode),
                                ),
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 14),
                    Text('Diseño de pantalla',
                        style: appListCardTitleStyle(context)),
                    const SizedBox(height: 4),
                    Text(
                      'Se adapta solo si estás en Smart TV o TV Box, o puedes elegirlo aquí.',
                      style: TextStyle(color: subColor, fontSize: 11.5),
                    ),
                    const SizedBox(height: 8),
                    ListenableBuilder(
                      listenable: TvModeService.instance,
                      builder: (context, _) {
                        final override = TvModeService.instance.manualOverride;
                        return Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: _choicePill(
                                  context,
                                  label: 'Automático',
                                  selected: override == null,
                                  onTap: () => TvModeService.instance
                                      .setManualOverride(null),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: _choicePill(
                                  context,
                                  label: 'Smart TV',
                                  selected: override == true,
                                  onTap: () => TvModeService.instance
                                      .setManualOverride(true),
                                ),
                              ),
                            ),
                            Expanded(
                              child: _choicePill(
                                context,
                                label: 'Celular',
                                selected: override == false,
                                onTap: () => TvModeService.instance
                                    .setManualOverride(false),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              // 3. Cuenta Firebase
              Text('Cuenta y Seguridad', style: appSectionTitleStyle(context)),
              const SizedBox(height: 10),
              _cardContainer(
                context,
                child: Column(
                  children: [
                    _actionRow(
                      context,
                      glyph: InutilGlyph.refresh,
                      title: 'Sincronizar licencia',
                      subtitle: 'Actualiza tu vigencia desde Cloud Firestore',
                      trailing: _syncing
                          ? SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            )
                          : null,
                      onTap: _syncing ? null : _syncLicenseNow,
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    _actionRow(
                      context,
                      glyph: InutilGlyph.cloud,
                      title: 'Respaldar biblioteca en la nube',
                      subtitle: _backup.lastPushAt != null
                          ? 'Mi Lista, historial, canales favoritos y ajustes guardados'
                          : 'Guarda Mi Lista, historial, favoritos y ajustes en Firebase',
                      trailing: _backup.isBusy
                          ? SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            )
                          : null,
                      onTap: _backup.isBusy ? null : _pushCloudBackup,
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    _actionRow(
                      context,
                      glyph: InutilGlyph.refresh,
                      title: 'Restaurar respaldo desde la nube',
                      subtitle: 'Recupera tu biblioteca al cambiar de equipo o reinstalar',
                      onTap: _backup.isBusy ? null : _restoreCloudBackup,
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    _actionRow(
                      context,
                      glyph: InutilGlyph.lock,
                      title: 'Cambiar contraseña',
                      subtitle: 'Aplica a Inutix TV e Inútil Music',
                      onTap: _changePasswordDialog,
                    ),
                    if (!TvModeService.of(context)) ...[
                      Divider(color: AppColors.dividerFor(context), height: 1),
                      _actionRow(
                        context,
                        glyph: InutilGlyph.liveTv,
                        title: 'Vincular Smart TV con código QR',
                        subtitle:
                            'Escanea el QR de tu tele para entrar sin escribir contraseña (1 celular + 1 TV)',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const TvQrScannerScreen(),
                          ),
                        ),
                      ),
                      Divider(color: AppColors.dividerFor(context), height: 1),
                      ListenableBuilder(
                        listenable: TvRemoteService.instance,
                        builder: (context, _) {
                          final online = TvRemoteService.instance.isTvOnline;
                          return _actionRow(
                            context,
                            glyph: InutilGlyph.play,
                            title: 'Control remoto de mi Smart TV',
                            subtitle: online
                                ? 'Smart TV conectada · Pausa, adelanta o envía contenido'
                                : 'Controla tu tele y envía películas desde tu celular',
                            onTap: () => TvRemoteSheet.show(context),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 22),

              // 4. Motor de Video
              Text('Reproducción', style: appSectionTitleStyle(context)),
              const SizedBox(height: 10),
              _cardContainer(
                context,
                child: Column(
                  children: [
                    SwitchListTile(
                      value: _settings.hwAcceleration,
                      onChanged: _settings.setHwAcceleration,
                      activeThumbColor: accent,
                      title: Text(
                        'Reproducción fluida',
                        style: appListCardTitleStyle(context),
                      ),
                      subtitle: Text(
                        'Usa la fuerza del dispositivo para evitar tirones',
                        style: appListCardSubtitleStyle(context),
                      ),
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    SwitchListTile(
                      value: _settings.ultraBuffer,
                      onChanged: _settings.setUltraBuffer,
                      activeThumbColor: accent,
                      title: Text(
                        'Carga anticipada amplia',
                        style: appListCardTitleStyle(context),
                      ),
                      subtitle: Text(
                        'Guarda 64 MB por adelantado para evitar cortes',
                        style: appListCardSubtitleStyle(context),
                      ),
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    SwitchListTile(
                      value: _settings.preloadNextEpisode,
                      onChanged: _settings.setPreloadNextEpisode,
                      activeThumbColor: accent,
                      title: Text(
                        'Precarga instantánea del siguiente episodio',
                        style: appListCardTitleStyle(context),
                      ),
                      subtitle: Text(
                        'Pre-carga en fondo 2–3 min del próximo capítulo (Series y Anime)',
                        style: appListCardSubtitleStyle(context),
                      ),
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    _actionRow(
                      context,
                      glyph: InutilGlyph.sleepTimer,
                      title: 'Temporizador de sueño',
                      subtitle: SleepTimerService.instance.isActive
                          ? 'Activo · ${SleepTimerService.instance.shortLabel}'
                          : 'Pausa la reproducción automáticamente al dormir',
                      onTap: () => InutilSleepTimerSheet.show(context),
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    SwitchListTile(
                      value: _settings.autoNextEpisode,
                      onChanged: _settings.setAutoNextEpisode,
                      activeThumbColor: accent,
                      title: Text(
                        'Auto-siguiente episodio',
                        style: appListCardTitleStyle(context),
                      ),
                      subtitle: Text(
                        'Cuenta regresiva automática al terminar un capítulo',
                        style: appListCardSubtitleStyle(context),
                      ),
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      title: Text(
                        'Salto de "Omitir intro"',
                        style: appListCardTitleStyle(context),
                      ),
                      subtitle: Text(
                        'Adelanta +${_settings.skipIntroSeconds}s en Series y Anime',
                        style: appListCardSubtitleStyle(context),
                      ),
                      trailing: DropdownButton<int>(
                        value: _settings.skipIntroSeconds,
                        dropdownColor: AppColors.elevatedSurfaceFor(context),
                        underline: const SizedBox.shrink(),
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                        items: const [
                          DropdownMenuItem(value: 60, child: Text('60s')),
                          DropdownMenuItem(value: 85, child: Text('85s')),
                          DropdownMenuItem(value: 90, child: Text('90s')),
                          DropdownMenuItem(value: 120, child: Text('120s')),
                        ],
                        onChanged: (v) {
                          if (v != null) _settings.setSkipIntroSeconds(v);
                        },
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              // 5. Red y conexión
              Text('Red y conexión', style: appSectionTitleStyle(context)),
              const SizedBox(height: 10),
              _cardContainer(
                context,
                child: Column(
                  children: [
                    SwitchListTile(
                      value: _network.secureDnsEnabled,
                      onChanged: _network.setSecureDnsEnabled,
                      activeThumbColor: accent,
                      title: Text(
                        'Búsqueda segura de servidores',
                        style: appListCardTitleStyle(context),
                      ),
                      subtitle: Text(
                        'Si tu red bloquea el video, Inutix TV busca los '
                        'servidores por un camino cifrado',
                        style: appListCardSubtitleStyle(context),
                      ),
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    SwitchListTile(
                      value: _network.tlsFallbackEnabled,
                      onChanged: _network.setTlsFallbackEnabled,
                      activeThumbColor: accent,
                      title: Text(
                        'Redes que revisan el tráfico',
                        style: appListCardTitleStyle(context),
                      ),
                      subtitle: Text(
                        'Reintenta solo si tu empresa u hotel cifra lo que '
                        'navegas',
                        style: appListCardSubtitleStyle(context),
                      ),
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    _actionRow(
                      context,
                      glyph: InutilGlyph.shield,
                      title: 'Salida por proxy',
                      subtitle: _network.proxyEnabled
                          ? '${_network.proxyHostPort} · el video sale por ahí'
                          : 'Directo (lo normal en casa)',
                      onTap: _editProxySetting,
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    _actionRow(
                      context,
                      glyph: InutilGlyph.cloud,
                      title: 'Comprobar conexión',
                      subtitle: _networkReport == null
                          ? 'Mide si tu red deja abrir catálogo, video y cuentas'
                          : _networkReport!.allOk
                              ? 'Tu red permite todo · toca para repetir'
                              : '${_networkReport!.failures} de '
                                  '${_networkReport!.checks.length} sin respuesta · toca para repetir',
                      trailing: _checkingNetwork
                          ? SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            )
                          : null,
                      onTap: _checkingNetwork ? null : _runNetworkCheck,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              // 6. Aplicación y Actualizaciones
              Text('Aplicación', style: appSectionTitleStyle(context)),
              const SizedBox(height: 10),
              _cardContainer(
                context,
                child: Column(
                  children: [
                    _actionRow(
                      context,
                      glyph: InutilGlyph.download,
                      title: 'Descargas sin conexión',
                      subtitle: OfflineVaultService.instance.items.isEmpty
                          ? 'Sin descargas guardadas'
                          : '${OfflineVaultService.instance.completedCount} disponibles · ${OfflineVaultService.formatBytes(OfflineVaultService.instance.totalVaultBytes)}',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DownloadsScreen(),
                          ),
                        );
                      },
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    _actionRow(
                      context,
                      glyph: InutilGlyph.update,
                      title: 'Buscar actualizaciones (OTA)',
                      subtitle: 'Versión actual v${AppInfo.appVersion}',
                      trailing: _checkingOta
                          ? SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            )
                          : null,
                      onTap: _checkingOta ? null : _checkOtaNow,
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    _actionRow(
                      context,
                      glyph: InutilGlyph.info,
                      title: 'Acerca de Inutix TV',
                      subtitle: 'Creador, novedades, donaciones y contacto',
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AboutScreen(),
                          ),
                        );
                      },
                    ),
                    Divider(color: AppColors.dividerFor(context), height: 1),
                    _actionRow(
                      context,
                      glyph: InutilGlyph.trash,
                      title: 'Borrar historial de reproducción',
                      subtitle: _historyCount == 0
                          ? 'Sin títulos guardados'
                          : '$_historyCount títulos en "Seguir viendo"',
                      onTap: _historyCount > 0 ? _clearHistory : null,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // 6. Cerrar sesión
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _confirmLogout,
                  icon: const Icon(
                    Icons.logout_rounded,
                    color: Colors.redAccent,
                    size: 19,
                  ),
                  label: const Text(
                    'Cerrar sesión',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: Colors.redAccent.withValues(alpha: 0.4),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 18),
              Center(
                child: Text(
                  '${AppInfo.appName} v${AppInfo.appVersion} · Creado por ${AppInfo.creatorName}',
                  style: TextStyle(
                    color: subColor.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _cardContainer(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry? padding,
  }) {
    final inner = padding != null ? Padding(padding: padding, child: child) : child;
    return Material(
      color: AppColors.cardSurfaceFor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(appCardRadius),
        side: BorderSide(
          color: AppColors.cardBorderFor(context),
          width: 0.85,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: inner,
    );
  }

  Widget _squircleIcon(BuildContext context, InutilGlyph glyph) {
    final accent = AppColors.accentFor(context);
    return Container(
      width: appListCardIconSize,
      height: appListCardIconSize,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(appListCardIconRadius),
      ),
      child: Center(child: InutilIcon(glyph, size: 21, color: accent)),
    );
  }

  Widget _actionRow(
    BuildContext context, {
    required InutilGlyph glyph,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final subColor = AppColors.contentSubtitleFor(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            _squircleIcon(context, glyph),
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
            trailing ??
                Icon(
                  Icons.chevron_right_rounded,
                  color: subColor.withValues(alpha: 0.5),
                  size: 20,
                ),
          ],
        ),
      ),
    );
  }

  Widget _choicePill(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final surface = AppColors.elevatedSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final subColor = AppColors.contentSubtitleFor(context);

    return TvFocusable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      focusScale: 1.02,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? accent : surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? accent : border,
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? onAccent : subColor,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _metaRow(BuildContext context, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppColors.contentSubtitleFor(context),
            fontSize: 12,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: AppColors.contentHeadingFor(context),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _copyRow(
    BuildContext context,
    String label,
    String display,
    String fullValue,
  ) {
    final subColor = AppColors.contentSubtitleFor(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: subColor, fontSize: 12)),
        TvFocusable(
          borderRadius: BorderRadius.circular(8),
          focusScale: 1.02,
          onTap: () {
            Clipboard.setData(ClipboardData(text: fullValue));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('$label copiado.'),
                duration: const Duration(seconds: 1),
              ),
            );
          },
          child: Row(
            children: [
              Text(
                display,
                style: TextStyle(
                  color: AppColors.contentHeadingFor(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 5),
              Icon(Icons.copy_rounded, size: 13, color: subColor),
            ],
          ),
        ),
      ],
    );
  }
}
