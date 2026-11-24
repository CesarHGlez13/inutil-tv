import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/artwork_cache_service.dart';
import '../theme/app_colors.dart';

/// `ImageProvider` de alto rendimiento respaldado por [ArtworkCacheService]
/// (RAM LRU -> Disco persistente LRU -> Pool HTTP Keep-Alive + deduplicación).
///
/// Compatible de forma nativa con [ResizeImage.resizeIfNeeded] para decodificar
/// exactamente al ancho visible del widget y minimizar el consumo de GPU/RAM.
@immutable
class FastNetworkImageProvider extends ImageProvider<FastNetworkImageProvider> {
  final String url;
  final ArtworkTier tier;
  final double scale;
  final Map<String, String>? headers;

  const FastNetworkImageProvider(
    this.url, {
    this.tier = ArtworkTier.poster,
    this.scale = 1.0,
    this.headers,
  });

  String get _resolvedUrl => ArtworkCacheService.optimizeUrl(url, tier: tier);

  @override
  Future<FastNetworkImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<FastNetworkImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    FastNetworkImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: key._resolvedUrl,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('Resolved URL', key._resolvedUrl),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    FastNetworkImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final targetUrl = key._resolvedUrl;
    if (targetUrl.isEmpty) {
      throw StateError('URL de carátula inválida o vacía');
    }
    final bytes = await ArtworkCacheService.instance.getBytes(
      targetUrl,
      tier: key.tier,
      headers: key.headers,
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError('No se pudo cargar la carátula: $targetUrl');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FastNetworkImageProvider &&
        other._resolvedUrl == _resolvedUrl &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(_resolvedUrl, scale);
}

/// Widget unificado de carátulas ultrarrápidas para toda la app InútilTV v3.2.1.
///
/// - Usa [FastNetworkImageProvider] + [ResizeImage.resizeIfNeeded] (decodificación
///   acotada al tamaño real en pantalla, cero desperdicio de RAM/GPU).
/// - Soporta archivos locales offline (`.art` de la Bóveda Cifrada).
/// - Cero `AnimationController` por tarjeta: pintado síncrono instantáneo (0 ms)
///   en hits de caché y aparición suave (140 ms) en cargas frías.
class FastArtwork extends StatelessWidget {
  final String url;
  final String? localFilePath;
  final ArtworkTier tier;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final int? cacheWidth;
  final int? cacheHeight;
  final FilterQuality filterQuality;
  final Widget? placeholder;
  final Widget? errorWidget;

  const FastArtwork({
    super.key,
    required this.url,
    this.localFilePath,
    this.tier = ArtworkTier.poster,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.cacheHeight,
    this.filterQuality = FilterQuality.medium,
    this.placeholder,
    this.errorWidget,
  });

  int? get _defaultCacheWidth => switch (tier) {
        ArtworkTier.thumbnail => 300,
        ArtworkTier.poster => 500,
        ArtworkTier.backdrop => 1280,
      };

  @override
  Widget build(BuildContext context) {
    final effectiveWidth = cacheWidth ?? _defaultCacheWidth;

    // 1. Archivo local offline (Bóveda Cifrada en Modo Avión)
    final local = localFilePath;
    if (local != null && local.isNotEmpty) {
      final f = File(local);
      if (f.existsSync()) {
        return Image(
          image: ResizeImage.resizeIfNeeded(
            effectiveWidth,
            cacheHeight,
            FileImage(f),
          ),
          fit: fit,
          alignment: alignment,
          filterQuality: filterQuality,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _buildError(context),
        );
      }
    }

    // 2. URL de red optimizada + caché RAM/Disco
    final optimized = ArtworkCacheService.optimizeUrl(url, tier: tier);
    if (optimized.isEmpty) {
      return _buildError(context);
    }

    final provider = ResizeImage.resizeIfNeeded(
      effectiveWidth,
      cacheHeight,
      FastNetworkImageProvider(optimized, tier: tier),
    );

    return Image(
      image: provider,
      fit: fit,
      alignment: alignment,
      filterQuality: filterQuality,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => _buildError(context),
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        final loaded = frame != null;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (!loaded) placeholder ?? _defaultPlaceholder(context),
            AnimatedOpacity(
              opacity: loaded ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: child,
            ),
          ],
        );
      },
    );
  }

  Widget _defaultPlaceholder(BuildContext context) {
    return ColoredBox(color: AppColors.elevatedSurfaceFor(context));
  }

  Widget _buildError(BuildContext context) {
    return errorWidget ?? _defaultPlaceholder(context);
  }
}
