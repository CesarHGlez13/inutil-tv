import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../constants/app_info.dart';
import '../services/inutil_update_service.dart';
import '../services/ota_download_manager.dart';
import '../theme/app_colors.dart';
import '../theme/inutil_icons.dart';

/// Puerta de OTA y Kill Switch (OTA Forzosa) para InútilTV.
///
/// - Si `app_config/tv_release` marca `mandatory: true` o `minSupportedVersion`
///   superior a la versión instalada, reemplaza toda la interfaz por
///   [InutilForceUpdateScreen] (no descartable, atrapa el botón atrás).
/// - Si hay una actualización opcional disponible, ofrece un diálogo elegante
///   una vez por sesión para actualizar sin salir de la app.
class InutilUpdateGate extends StatefulWidget {
  const InutilUpdateGate({super.key, required this.child});

  final Widget child;

  @override
  State<InutilUpdateGate> createState() => _InutilUpdateGateState();
}

class _InutilUpdateGateState extends State<InutilUpdateGate>
    with WidgetsBindingObserver {
  static const Duration _resumeCooldown = Duration(minutes: 5);

  InutilTvReleaseInfo? _blocker;
  bool _checking = false;
  DateTime? _lastCheck;
  String _promptedOptionalVersion = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final last = _lastCheck;
    if (last != null && DateTime.now().difference(last) < _resumeCooldown) {
      return;
    }
    unawaited(_check());
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    InutilTvReleaseInfo? release;
    try {
      release = await InutilUpdateService.instance.checkForUpdate();
    } catch (e) {
      debugPrint('[InutilUpdateGate] Error verificando OTA: $e');
    } finally {
      _checking = false;
      _lastCheck = DateTime.now();
    }
    if (!mounted || release == null) return;

    if (release.isBlockingUpdate) {
      setState(() => _blocker = release);
      return;
    }

    if (_blocker != null) {
      setState(() => _blocker = null);
    }

    // Actualización opcional: avisar una vez por versión nueva detectada
    if (release.updateAvailable &&
        _promptedOptionalVersion != release.latestVersion) {
      _promptedOptionalVersion = release.latestVersion;
      final r = release;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showInutilUpdateDialog(context, release: r);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocker = _blocker;
    if (blocker == null) return widget.child;

    return PopScope(
      canPop: false,
      child: InutilForceUpdateScreen(release: blocker, onRetry: _check),
    );
  }
}

/// Pantalla completa no descartable para OTA forzosa (Kill Switch).
class InutilForceUpdateScreen extends StatelessWidget {
  const InutilForceUpdateScreen({
    super.key,
    required this.release,
    this.onRetry,
  });

  final InutilTvReleaseInfo release;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;

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
                      Colors.redAccent.withValues(alpha: 0.14),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(minHeight: constraints.maxHeight - 40),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.redAccent.withValues(alpha: 0.42),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.system_update_rounded,
                                color: Colors.redAccent,
                                size: 15,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  release.belowMinSupported
                                      ? 'ACTUALIZACIÓN OBLIGATORIA'
                                      : 'ACTUALIZACIÓN REQUERIDA',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 11,
                                    letterSpacing: 0.9,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        InutilUpdateDialogContent(release: release),
                        if (onRetry != null) ...[
                          const SizedBox(height: 14),
                          TextButton.icon(
                            onPressed: onRetry,
                            style: TextButton.styleFrom(
                              foregroundColor: accent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            icon: InutilIcon(
                              InutilGlyph.refresh,
                              size: 16,
                              color: subColor,
                            ),
                            label: Text(
                              'Comprobar de nuevo',
                              style: TextStyle(
                                color: subColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
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

/// Abre el diálogo OTA desde Ajustes, Acerca de, o notificación opcional.
Future<void> showInutilUpdateDialog(
  BuildContext context, {
  required InutilTvReleaseInfo release,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: !release.isBlockingUpdate,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) => PopScope(
      canPop: !release.isBlockingUpdate,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
        child: InutilUpdateDialogContent(
          release: release,
          onClose: release.isBlockingUpdate ? null : () => Navigator.pop(ctx),
        ),
      ),
    ),
  );
}

/// Tarjeta interactiva de descarga e instalación OTA con progreso real,
/// velocidad, permiso de fuentes desconocidas y reanudación.
class InutilUpdateDialogContent extends StatefulWidget {
  const InutilUpdateDialogContent({
    super.key,
    required this.release,
    this.onClose,
  });

  final InutilTvReleaseInfo release;
  final VoidCallback? onClose;

  @override
  State<InutilUpdateDialogContent> createState() =>
      _InutilUpdateDialogContentState();
}

class _InutilUpdateDialogContentState extends State<InutilUpdateDialogContent> {
  bool _downloading = false;
  bool _installed = false;
  bool _needsInstallPermission = false;
  OtaDownloadProgress? _progress;
  String? _error;
  String? _downloadedPath;

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var idx = 0;
    while (value >= 1024 && idx < units.length - 1) {
      value /= 1024;
      idx++;
    }
    return '${value.toStringAsFixed(idx == 0 ? 0 : 1)} ${units[idx]}';
  }

  Future<void> _startDownload() async {
    final service = InutilUpdateService.instance;
    if (Platform.isAndroid) {
      final allowed = await service.canRequestPackageInstalls();
      if (!allowed) {
        if (mounted) {
          setState(() {
            _needsInstallPermission = true;
            _error =
                'Activa "Instalar aplicaciones desconocidas" para Inutix TV y vuelve a pulsar Actualizar.';
          });
        }
        await service.openInstallUnknownAppsSettings();
        return;
      }
    }

    setState(() {
      _downloading = true;
      _installed = false;
      _needsInstallPermission = false;
      _error = null;
      _progress = null;
    });

    try {
      final path = await service.downloadAndInstall(
        widget.release,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) {
        setState(() {
          _downloading = false;
          _installed = true;
          _downloadedPath = path;
        });
      }
    } on OtaDownloadCancelled {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = 'Descarga pausada. Puedes reanudarla cuando quieras.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
  }

  Future<void> _cancelDownload() async {
    await InutilUpdateService.instance.downloadManager.cancelActiveDownload();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final hasUpdate = r.updateAvailable;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userAccent = AppColors.accentFor(context);
    final onUserAccent = AppColors.onAccentFor(context);
    final accent = r.isBlockingUpdate ? Colors.redAccent : userAccent;
    final onAccent = r.isBlockingUpdate ? Colors.white : onUserAccent;
    final surface = AppColors.cardSurfaceFor(context);
    final elevated = AppColors.elevatedSurfaceFor(context);
    final cardBorder = r.isBlockingUpdate
        ? Colors.redAccent.withValues(alpha: 0.42)
        : AppColors.cardBorderFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final dividerColor = AppColors.dividerFor(context);
    final successColor =
        isDark ? const Color(0xFF34D399) : const Color(0xFF15803D);
    final warningColor =
        isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Material(
        key: const ValueKey('inutil-update-dialog-card'),
        color: surface,
        elevation: 18,
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.55 : 0.2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(color: cardBorder, width: 1.0),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              top: -54,
              left: 0,
              right: 0,
              height: 150,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.35),
                      radius: 0.95,
                      colors: [
                        accent.withValues(alpha: isDark ? 0.14 : 0.10),
                        accent.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.30),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: hasUpdate
                            ? InutilIcon(
                                InutilGlyph.update,
                                size: 22,
                                color: accent,
                              )
                            : Icon(
                                Icons.verified_rounded,
                                color: accent,
                                size: 22,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hasUpdate
                                  ? 'Inutix TV v${r.latestVersion}'
                                  : '¡Inutix TV está al día!',
                              style: TextStyle(
                                color: headingColor,
                                fontSize: 17.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hasUpdate
                                  ? 'Instalada: v${r.currentVersion} → Nueva: v${r.latestVersion}'
                                  : 'Versión actual: v${r.currentVersion}',
                              style: TextStyle(
                                color: subColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.onClose != null && !_downloading)
                        IconButton(
                          tooltip: 'Cerrar',
                          onPressed: widget.onClose,
                          icon: Icon(
                            Icons.close_rounded,
                            color: subColor,
                            size: 20,
                          ),
                        ),
                    ],
                  ),

                  if (r.isBlockingUpdate) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.30),
                        ),
                      ),
                      child: Text(
                        'Esta versión quedó obsoleta por decisión del administrador. '
                        'Actualiza desde aquí para continuar usando Inutix TV.',
                        style: TextStyle(
                          color: headingColor,
                          fontSize: 12.2,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],

                  if (r.releaseNotes.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      'NOVEDADES',
                      style: TextStyle(
                        color: subColor,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      decoration: BoxDecoration(
                        color: elevated,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppColors.cardBorderFor(context),
                        ),
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 165),
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < r.releaseNotes.length; i++)
                                Padding(
                                  padding: EdgeInsets.only(
                                    bottom:
                                        i == r.releaseNotes.length - 1 ? 0 : 8,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        margin: const EdgeInsets.only(top: 6),
                                        width: 5,
                                        height: 5,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: accent.withValues(alpha: 0.85),
                                        ),
                                      ),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: Text(
                                          r.releaseNotes[i],
                                          style: TextStyle(
                                            color: headingColor.withValues(
                                              alpha: 0.86,
                                            ),
                                            fontSize: 12.2,
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
                  ],

                  if (_downloading) ...[
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: _progress?.fraction,
                        minHeight: 6,
                        backgroundColor: dividerColor,
                        valueColor: AlwaysStoppedAnimation<Color>(accent),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _progress == null
                              ? 'Conectando con el servidor...'
                              : _progress!.hasTotal
                                  ? '${_formatBytes(_progress!.receivedBytes)} / ${_formatBytes(_progress!.totalBytes)}'
                                  : '${_formatBytes(_progress!.receivedBytes)} descargados',
                          style: TextStyle(
                            color: subColor,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (_progress != null && _progress!.bytesPerSecond > 0)
                          Text(
                            '${_formatBytes(_progress!.bytesPerSecond)}/s',
                            style: TextStyle(
                              color: headingColor,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ],

                  if (_installed) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: successColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: successColor.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_rounded,
                            color: successColor,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'APK descargado. Acepta el instalador de Android para completar la actualización.',
                              style: TextStyle(
                                color: headingColor.withValues(alpha: 0.9),
                                fontSize: 11.8,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: warningColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: warningColor.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: warningColor,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_downloading)
                          OutlinedButton(
                            onPressed: _cancelDownload,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: headingColor,
                              side: BorderSide(
                                color: AppColors.cardBorderFor(context),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 11,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            child: const Text(
                              'Pausar / Cancelar',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          )
                        else ...[
                          if (widget.onClose != null && !r.isBlockingUpdate)
                            TextButton(
                              onPressed: widget.onClose,
                              style: TextButton.styleFrom(
                                foregroundColor: subColor,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 11,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                              child: Text(
                                hasUpdate ? 'Más tarde' : 'Cerrar',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (hasUpdate)
                            FilledButton.icon(
                              onPressed: _downloadedPath != null
                                  ? () => InutilUpdateService.instance
                                      .installApk(_downloadedPath!)
                                  : _startDownload,
                              icon: Icon(
                                _needsInstallPermission
                                    ? Icons.security_rounded
                                    : _downloadedPath != null
                                        ? Icons.install_mobile_rounded
                                        : Icons.download_rounded,
                                size: 18,
                              ),
                              label: Text(
                                _needsInstallPermission
                                    ? 'Dar permiso y reintentar'
                                    : _downloadedPath != null
                                        ? 'Abrir instalador'
                                        : 'Actualizar ahora',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: onAccent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Diálogo exclusivo del SuperAdmin César para publicar una actualización OTA
/// o activar el Kill Switch (OTA forzosa) en `app_config/tv_release`.
Future<void> showInutilAdminPublishUpdateDialog(BuildContext context) async {
  final current = await InutilUpdateService.instance.checkForUpdate();
  if (!context.mounted) return;

  final versionCtl = TextEditingController(text: current.latestVersion);
  final minVerCtl = TextEditingController(text: current.minSupportedVersion);
  final apkUrlCtl = TextEditingController(text: current.apkDownloadUrl);
  final armv7UrlCtl = TextEditingController(
    text: current.androidDownloads['armeabi_v7a'] ?? '',
  );
  final notesCtl = TextEditingController(
    text: (current.releaseNotes.isNotEmpty
            ? current.releaseNotes
            : AppInfo.whatsNewHighlights)
        .join('\n'),
  );
  var mandatory = current.mandatory;
  var saving = false;
  String? error;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlgState) {
        final accent = AppColors.accentFor(ctx);
        final onAccent = AppColors.onAccentFor(ctx);
        final surface = AppColors.cardSurfaceFor(ctx);
        final border = AppColors.cardBorderFor(ctx);
        final heading = AppColors.contentHeadingFor(ctx);
        final sub = AppColors.contentSubtitleFor(ctx);

        return AlertDialog(
          backgroundColor: surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: border, width: 1.0),
          ),
          title: Row(
            children: [
              InutilIcon(InutilGlyph.update, size: 20, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Publicar / Forzar OTA (Inutix TV)',
                  style: TextStyle(
                    color: heading,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Se guarda en Firebase (app_config/tv_release) sin afectar a Inutix Music.',
                    style: TextStyle(color: sub, fontSize: 11.5),
                  ),
                  const SizedBox(height: 12),
                  if (error != null) ...[
                    Text(
                      error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextField(
                    controller: versionCtl,
                    style: TextStyle(color: heading, fontSize: 13.5),
                    decoration: InputDecoration(
                      labelText: 'Última versión publicada (ej. 3.2.3)',
                      labelStyle: TextStyle(color: sub, fontSize: 12.5),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: minVerCtl,
                    style: TextStyle(color: heading, fontSize: 13.5),
                    decoration: InputDecoration(
                      labelText:
                          'Versión mínima soportada / Kill Switch (opcional)',
                      labelStyle: TextStyle(color: sub, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: mandatory,
                    activeThumbColor: Colors.redAccent,
                    onChanged: (v) => setDlgState(() => mandatory = v),
                    title: Text(
                      'Forzar actualización OTA obligatoria',
                      style: TextStyle(
                        color: heading,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      'Bloquea versiones anteriores hasta que actualicen.',
                      style: TextStyle(color: sub, fontSize: 11),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: apkUrlCtl,
                    style: TextStyle(color: heading, fontSize: 12.5),
                    decoration: InputDecoration(
                      labelText: 'URL APK principal (arm64 / universal)',
                      hintText: 'https://github.com/.../inutiltv-arm64.apk',
                      labelStyle: TextStyle(color: sub, fontSize: 12),
                      hintStyle: TextStyle(
                        color: sub.withValues(alpha: 0.5),
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: armv7UrlCtl,
                    style: TextStyle(color: heading, fontSize: 12.5),
                    decoration: InputDecoration(
                      labelText: 'URL APK 32-bit armeabi-v7a (opcional)',
                      labelStyle: TextStyle(color: sub, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: notesCtl,
                    maxLines: 4,
                    style: TextStyle(color: heading, fontSize: 12),
                    decoration: InputDecoration(
                      labelText: 'Novedades (una por línea)',
                      labelStyle: TextStyle(color: sub, fontSize: 12),
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: Text('Cancelar', style: TextStyle(color: sub)),
            ),
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      final ver = versionCtl.text.trim();
                      if (ver.isEmpty) {
                        setDlgState(
                          () => error = 'Ingresa el número de versión.',
                        );
                        return;
                      }
                      setDlgState(() {
                        saving = true;
                        error = null;
                      });
                      final ok =
                          await InutilUpdateService.instance.publishRelease(
                        version: ver,
                        notes: notesCtl.text.split('\n'),
                        apkUrl: apkUrlCtl.text.trim(),
                        armv7ApkUrl: armv7UrlCtl.text.trim(),
                        mandatory: mandatory,
                        minSupportedVersion: minVerCtl.text.trim(),
                      );
                      if (!ctx.mounted) return;
                      if (ok) {
                        Navigator.pop(ctx);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                mandatory
                                    ? 'OTA Forzosa v$ver publicada en Firebase.'
                                    : 'OTA v$ver publicada en Firebase.',
                              ),
                              backgroundColor: mandatory
                                  ? Colors.redAccent
                                  : const Color(0xFF18C75A),
                            ),
                          );
                        }
                      } else {
                        setDlgState(() {
                          saving = false;
                          error =
                              'No se pudo publicar en Firestore. Verifica tu sesión Admin.';
                        });
                      }
                    },
              icon: saving
                  ? SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: mandatory ? Colors.white : onAccent,
                      ),
                    )
                  : const Icon(Icons.publish_rounded, size: 17),
              label: Text(
                mandatory ? 'Publicar OTA Forzosa' : 'Publicar OTA',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: mandatory ? Colors.redAccent : accent,
                foregroundColor: mandatory ? Colors.white : onAccent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  versionCtl.dispose();
  minVerCtl.dispose();
  apkUrlCtl.dispose();
  armv7UrlCtl.dispose();
  notesCtl.dispose();
}
