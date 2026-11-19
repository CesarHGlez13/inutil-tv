import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';

/// Estado vacío honesto de las pestañas de catálogo (Cine, Series y Anime).
///
/// Cuando los servidores no dejaron traer títulos no sirve de nada decir
/// «prueba con otro término»: se explica lo que pasó y se ofrece reintentar,
/// que es lo que el usuario puede hacer desde su teléfono.
class CatalogEmptyState extends StatelessWidget {
  const CatalogEmptyState({
    super.key,
    required this.fallaRed,
    required this.onRetry,
    required this.tituloSinResultados,
    this.icono = InutilGlyph.movies,
  });

  /// true cuando el intento terminó con problemas de red (a diferencia de una
  /// búsqueda normal que simplemente no trajo nada).
  final bool fallaRed;
  final VoidCallback onRetry;
  final String tituloSinResultados;
  final InutilGlyph icono;

  @override
  Widget build(BuildContext context) {
    final subColor = AppColors.contentSubtitleFor(context);
    final accent = AppColors.accentFor(context);

    final titulo = fallaRed ? 'No llegó el catálogo' : tituloSinResultados;
    final detalle = fallaRed
        ? 'Tu red no deja entrar a los servidores del catálogo o están '
            'saturados. Reintenta en un momento o revisa tu conexión en '
            'Ajustes.'
        : 'Prueba con otro término o género.';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InutilIcon(icono, size: 44, color: subColor),
            const SizedBox(height: 12),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: appListCardTitleStyle(context),
            ),
            const SizedBox(height: 6),
            Text(
              detalle,
              textAlign: TextAlign.center,
              style: appListCardSubtitleStyle(context),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: AppColors.onAccentFor(context),
              ),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}
