import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/tv_qr_pairing_service.dart';
import '../theme/app_colors.dart';
import '../theme/inutil_icons.dart';

/// Escáner móvil para vincular una Smart TV / TV Box escaneando el código QR
/// (o escribiendo el código de 8 caracteres que muestra la tele).
class TvQrScannerScreen extends StatefulWidget {
  const TvQrScannerScreen({super.key});

  @override
  State<TvQrScannerScreen> createState() => _TvQrScannerScreenState();
}

class _TvQrScannerScreenState extends State<TvQrScannerScreen> {
  final MobileScannerController _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _processing = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _handleCode(String raw) async {
    if (_processing || _done) return;
    if (TvQrPairingService.parseQrUri(raw) == null) return;

    setState(() {
      _processing = true;
      _error = null;
    });

    final err = await TvQrPairingService.instance.approveFromMobile(raw);
    if (!mounted) return;
    if (err == null) {
      setState(() {
        _processing = false;
        _done = true;
      });
      await Future.delayed(const Duration(milliseconds: 1400));
      if (mounted) Navigator.of(context).pop(true);
    } else {
      setState(() {
        _processing = false;
        _error = err;
      });
    }
  }

  Future<void> _showManualCodeDialog() async {
    final ctl = TextEditingController();
    final submitted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Código de tu Smart TV',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Escribe los 8 caracteres que aparecen debajo del código QR en tu televisor:',
              style: TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                hintText: 'Ej. 33JL-YR6D',
                prefixIcon: Icon(Icons.tv_rounded),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctl.text),
            child: const Text('Vincular'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (submitted == null || submitted.trim().isEmpty || !mounted) return;

    setState(() {
      _processing = true;
      _error = null;
    });
    final err =
        await TvQrPairingService.instance.approveFromMobileWithCode(submitted);
    if (!mounted) return;
    if (err == null) {
      setState(() {
        _processing = false;
        _done = true;
      });
      await Future.delayed(const Duration(milliseconds: 1400));
      if (mounted) Navigator.of(context).pop(true);
    } else {
      setState(() {
        _processing = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Vincular Smart TV',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          TextButton(
            onPressed: _processing ? null : _showManualCodeDialog,
            child: Text(
              'Usar código',
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Linterna',
            icon: const Icon(Icons.flash_on_rounded),
            onPressed: () => _scanner.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _scanner,
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
                final val = barcode.rawValue;
                if (val != null && val.isNotEmpty) {
                  _handleCode(val);
                  break;
                }
              }
            },
            errorBuilder: (context, error) {
              final detail = error.errorDetails?.message;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 170),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.videocam_off_rounded,
                        color: Colors.white.withValues(alpha: 0.6),
                        size: 46,
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'No se pudo abrir la cámara',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        detail != null && detail.isNotEmpty
                            ? detail
                            : 'Puedes reintentar o vincular escribiendo el código de 8 letras que aparece en tu TV.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _scanner.start(),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.35),
                              ),
                            ),
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Reintentar'),
                          ),
                          FilledButton.icon(
                            onPressed: _showManualCodeDialog,
                            style: FilledButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: onAccent,
                            ),
                            icon: const Icon(Icons.keyboard_rounded, size: 18),
                            label: const Text('Escribir código'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          // Marco visor centrado
          IgnorePointer(
            child: Center(
              child: Container(
                width: 248,
                height: 248,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _done ? const Color(0xFF18C75A) : accent,
                    width: 3,
                  ),
                ),
              ),
            ),
          ),

          // Instrucciones y estado abajo
          Positioned(
            left: 20,
            right: 20,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0E0E13).withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_done) ...[
                    const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF18C75A),
                      size: 36,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '¡Smart TV vinculada!',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tu televisor iniciará sesión automáticamente en unos segundos.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.72),
                        fontSize: 12.5,
                      ),
                    ),
                  ] else if (_processing) ...[
                    CircularProgressIndicator(color: accent, strokeWidth: 2.5),
                    const SizedBox(height: 10),
                    const Text(
                      'Vinculando tu cuenta con la Smart TV...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: InutilIcon(
                              InutilGlyph.liveTv,
                              size: 20,
                              color: accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Apunta al código QR de tu TV',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                'O toca «Usar código» arriba para escribir las 8 letras.',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.68),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.redAccent.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: () => setState(() => _error = null),
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: onAccent,
                        ),
                        child: const Text('Intentar de nuevo'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
