import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/artwork_cache_service.dart';
import 'fast_artwork.dart';

/// Tarjeta de canal reutilizada por "En vivo" y "Mis listas".
class ChannelTile extends StatelessWidget {
  final Channel channel;
  final bool fav;
  final VoidCallback? onTap;
  final VoidCallback? onFav;

  const ChannelTile({
    super.key,
    required this.channel,
    required this.fav,
    required this.onTap,
    this.onFav,
  });

  /// Sin logo (o si el CDN del logo falla): iniciales sobre un color fijo
  /// derivado del nombre, para que la rejilla no se vea vacía.
  Widget _fallback(BuildContext context) {
    const palette = [
      Color(0xFF00695C), Color(0xFF6A1B9A), Color(0xFF283593),
      Color(0xFFAD1457), Color(0xFFEF6C00), Color(0xFF4527A0),
      Color(0xFF1565C0), Color(0xFF2E7D32), Color(0xFF8E24AA),
    ];
    var h = 0;
    for (final c in channel.name.codeUnits) {
      h = (h * 31 + c) & 0x3FFFFFFF;
    }
    final words = channel.name
        .split(RegExp(r'[\s\-|,.]+'))
        .where((w) => w.trim().isNotEmpty)
        .toList();
    final initials = words.isEmpty
        ? '?'
        : words.take(2).map((w) => w[0].toUpperCase()).join();
    return Container(
      decoration: BoxDecoration(
        color: palette[h % palette.length],
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: MediaQuery.sizeOf(context).width < 500 ? 22 : 28,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: channel.logo.isNotEmpty
                          ? FastArtwork(
                              url: channel.logo,
                              tier: ArtworkTier.thumbnail,
                              cacheWidth: 160,
                              fit: BoxFit.contain,
                              errorWidget: _fallback(context),
                            )
                          : _fallback(context),
                    ),
                    if (onFav != null)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 16,
                          icon: Icon(
                              fav ? Icons.favorite : Icons.favorite_border,
                              color: fav ? Colors.pinkAccent : Colors.white38),
                          onPressed: onFav,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (channel.group.isNotEmpty)
                Text(
                  channel.group,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
