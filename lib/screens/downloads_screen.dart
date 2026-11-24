import 'package:flutter/material.dart';

import '../services/artwork_cache_service.dart';
import '../services/offline_vault_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import '../widgets/fast_artwork.dart';
import '../widgets/tv_focusable.dart';
import 'player_screen.dart';

/// Hub de Descargas Sin Conexión (Bóveda Cifrada AES-256) de InútilTV v3.2.
///
/// - Estética Carbon Black + Liquid Glass alineada con Inútil Music.
/// - Muestra almacenamiento usado, calidad de descarga, auto-borrado inteligente,
///   cola activa con pausa/reanudación en vivo y biblioteca offline agrupada
///   por Series/Anime y Películas (100 % funcional en Modo Avión).
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final _vault = OfflineVaultService.instance;
  final Set<String> _expandedSeries = {};

  @override
  void initState() {
    super.initState();
    _vault.initialize();
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '¿Eliminar todas las descargas?',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        content: Text(
          'Se eliminarán las ${_vault.items.length} descargas guardadas (${OfflineVaultService.formatBytes(_vault.totalVaultBytes)}) de este dispositivo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Eliminar todo'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _vault.deleteAllDownloads();
    }
  }

  void _playOfflineMovie(OfflineDownloadItem entry) {
    final poster = entry.localPosterPath.isNotEmpty
        ? entry.localPosterPath
        : entry.remotePosterUrl;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: entry.title,
          subtitle: entry.displaySubtitle.isNotEmpty
              ? '${entry.displaySubtitle} · Sin conexión'
              : 'Sin conexión',
          posterUrl: poster,
          isVod: true,
          isAnime: entry.isAnime,
          animeId: entry.isAnime ? entry.itemId : null,
          vodItem: entry.toVodItem(),
        ),
      ),
    );
  }

  void _playOfflineSeriesEpisode(
    List<OfflineDownloadItem> seriesEpisodes,
    int index,
  ) {
    if (seriesEpisodes.isEmpty) return;
    final safeIdx = index.clamp(0, seriesEpisodes.length - 1);
    final selected = seriesEpisodes[safeIdx];
    final poster = selected.localPosterPath.isNotEmpty
        ? selected.localPosterPath
        : selected.remotePosterUrl;
    final vodEpisodes = seriesEpisodes.map((e) => e.toVodEpisode()).toList();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: selected.title,
          subtitle:
              'T${selected.seasonNumber} · Ep. ${selected.episodeNumber} — ${selected.episodeTitle.isNotEmpty ? selected.episodeTitle : "Episodio ${selected.episodeNumber}"}',
          posterUrl: poster,
          isVod: true,
          isAnime: selected.isAnime,
          animeId: selected.isAnime ? selected.itemId : null,
          vodItem: selected.toVodItem(),
          episodeList: vodEpisodes,
          initialEpisodeIndex: safeIdx,
        ),
      ),
    );
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return '';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _statusLabel(OfflineDownloadItem item) {
    switch (item.status) {
      case DownloadStatus.queued:
        return 'En cola';
      case DownloadStatus.resolving:
        return 'Preparando flujo...';
      case DownloadStatus.downloading:
        final spd = _formatSpeed(item.speedBytesPerSec);
        return spd.isNotEmpty ? 'Descargando · $spd' : 'Descargando...';
      case DownloadStatus.paused:
        return 'Pausado · toca para reanudar';
      case DownloadStatus.completed:
        return 'Listo sin conexión';
      case DownloadStatus.failed:
        return item.errorMessage.isNotEmpty
            ? item.errorMessage
            : 'Error de red · toca para reintentar';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppColors.accentFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);

    return ListenableBuilder(
      listenable: _vault,
      builder: (context, _) {
        final activeItems = _vault.activeOrQueuedItems;
        final groupedSeries = _vault.groupedCompletedSeries();
        final completedMovies =
            _vault.completedItems.where((i) => !i.isSeries).toList();
        final hasAnything = activeItems.isNotEmpty ||
            groupedSeries.isNotEmpty ||
            completedMovies.isNotEmpty;

        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          appBar: AppBar(
            backgroundColor: theme.scaffoldBackgroundColor,
            title: Text(
              'Descargas',
              style: appTabTitleStyle(context).copyWith(fontSize: 21),
            ),
            actions: [
              if (_vault.items.isNotEmpty)
                IconButton(
                  tooltip: 'Eliminar descargas',
                  onPressed: _confirmClearAll,
                  icon: InutilIcon(
                    InutilGlyph.trash,
                    size: 20,
                    color: subColor,
                  ),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              appPagePaddingHorizontal,
              8,
              appPagePaddingHorizontal,
              36,
            ),
            children: [
              // 1. Tarjeta de Bóveda Cifrada + controles rápidos
              _buildVaultSummaryCard(context, accent, headingColor, subColor),

              const SizedBox(height: 20),

              if (!hasAnything)
                _buildEmptyState(context, accent, headingColor, subColor)
              else ...[
                // 2. Descargas en curso / pausadas / en cola
                if (activeItems.isNotEmpty) ...[
                  Text(
                    'En curso y en cola (${activeItems.length})',
                    style: appSectionTitleStyle(context),
                  ),
                  const SizedBox(height: 10),
                  for (final item in activeItems)
                    _buildActiveDownloadCard(
                      context,
                      item,
                      accent,
                      headingColor,
                      subColor,
                    ),
                  const SizedBox(height: 16),
                ],

                // 3. Series y Anime agrupados
                if (groupedSeries.isNotEmpty) ...[
                  Text(
                    'Series y Anime sin conexión',
                    style: appSectionTitleStyle(context),
                  ),
                  const SizedBox(height: 10),
                  for (final entry in groupedSeries.entries)
                    _buildSeriesGroupCard(
                      context,
                      entry.key,
                      entry.value,
                      accent,
                      headingColor,
                      subColor,
                    ),
                  const SizedBox(height: 16),
                ],

                // 4. Películas sin conexión
                if (completedMovies.isNotEmpty) ...[
                  Text(
                    'Películas sin conexión (${completedMovies.length})',
                    style: appSectionTitleStyle(context),
                  ),
                  const SizedBox(height: 10),
                  for (final movie in completedMovies)
                    _buildCompletedMovieCard(
                      context,
                      movie,
                      accent,
                      headingColor,
                      subColor,
                    ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildVaultSummaryCard(
    BuildContext context,
    Color accent,
    Color headingColor,
    Color subColor,
  ) {
    final cardSurface = AppColors.cardSurfaceFor(context);
    final cardBorder = AppColors.cardBorderFor(context);
    final elevated = AppColors.elevatedSurfaceFor(context);

    return Material(
      color: cardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(appCardRadius),
        side: BorderSide(color: cardBorder, width: 0.85),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
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
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Center(
                    child: InutilIcon(
                      InutilGlyph.download,
                      size: 21,
                      color: accent,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Descargas sin conexión',
                        style: appListCardTitleStyle(context),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Tus películas, series y anime disponibles sin internet.',
                        style: appListCardSubtitleStyle(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statPill(
                  context,
                  elevated,
                  cardBorder,
                  'Espacio: ${OfflineVaultService.formatBytes(_vault.totalVaultBytes)}',
                  headingColor,
                ),
                _statPill(
                  context,
                  elevated,
                  cardBorder,
                  '${_vault.completedCount} sin conexión',
                  const Color(0xFF18C75A),
                ),
                if (_vault.activeCount > 0)
                  _statPill(
                    context,
                    accent.withValues(alpha: 0.15),
                    accent.withValues(alpha: 0.5),
                    '${_vault.activeCount} descargando',
                    accent,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Divider(color: AppColors.dividerFor(context), height: 1),
            const SizedBox(height: 12),
            Text(
              'Calidad de descarga',
              style: TextStyle(
                color: subColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final q in DownloadQuality.values)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: q == DownloadQuality.values.last ? 0 : 8,
                      ),
                      child: TvFocusable(
                        onTap: () => _vault.setQuality(q),
                        borderRadius: BorderRadius.circular(11),
                        focusScale: 1.02,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _vault.quality == q ? accent : elevated,
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color:
                                  _vault.quality == q ? accent : cardBorder,
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            q.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _vault.quality == q
                                  ? AppColors.onAccentFor(context)
                                  : subColor,
                              fontSize: 12,
                              fontWeight: _vault.quality == q
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _vault.autoDeleteWatched,
              onChanged: _vault.setAutoDeleteWatched,
              activeThumbColor: accent,
              title: Text(
                'Auto-borrar al terminar de ver',
                style: appListCardTitleStyle(context).copyWith(fontSize: 13.5),
              ),
              subtitle: Text(
                'Libera espacio automáticamente cuando terminas un título o episodio.',
                style: appListCardSubtitleStyle(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statPill(
    BuildContext context,
    Color bg,
    Color border,
    String text,
    Color fg,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border, width: 0.7),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildActiveDownloadCard(
    BuildContext context,
    OfflineDownloadItem item,
    Color accent,
    Color headingColor,
    Color subColor,
  ) {
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final pct = (item.progress * 100).clamp(0, 100).round();
    final isFailed = item.status == DownloadStatus.failed;
    final isPaused = item.status == DownloadStatus.paused;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: isFailed
              ? Colors.redAccent.withValues(alpha: 0.45)
              : border,
          width: 0.85,
        ),
      ),
      child: Row(
        children: [
          _posterThumb(item, width: 54, height: 74),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: headingColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (item.displaySubtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.displaySubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: subColor, fontSize: 11.5),
                  ),
                ],
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: item.status == DownloadStatus.resolving
                        ? null
                        : item.progress.clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation(
                      isFailed
                          ? Colors.redAccent
                          : (isPaused ? subColor : accent),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _statusLabel(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isFailed ? Colors.redAccent : subColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      item.downloadedBytes > 0
                          ? '$pct% · ${OfflineVaultService.formatBytes(item.downloadedBytes)}'
                          : '$pct%',
                      style: TextStyle(
                        color: headingColor.withValues(alpha: 0.8),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: item.isActive ? 'Pausar' : 'Reanudar',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  if (item.isActive) {
                    _vault.pauseDownload(item.id);
                  } else {
                    _vault.resumeDownload(item.id);
                  }
                },
                icon: Icon(
                  item.isActive
                      ? Icons.pause_circle_filled_rounded
                      : (isFailed
                          ? Icons.refresh_rounded
                          : Icons.play_circle_fill_rounded),
                  color: accent,
                  size: 26,
                ),
              ),
              IconButton(
                tooltip: 'Cancelar y borrar',
                visualDensity: VisualDensity.compact,
                onPressed: () => _vault.deleteDownload(item.id),
                icon: Icon(
                  Icons.close_rounded,
                  color: subColor.withValues(alpha: 0.75),
                  size: 19,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSeriesGroupCard(
    BuildContext context,
    String itemId,
    List<OfflineDownloadItem> episodes,
    Color accent,
    Color headingColor,
    Color subColor,
  ) {
    final first = episodes.first;
    final totalBytes =
        episodes.fold<int>(0, (sum, e) => sum + e.downloadedBytes);
    final expanded = _expandedSeries.contains(itemId) || episodes.length <= 3;
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border, width: 0.85),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () {
              setState(() {
                if (_expandedSeries.contains(itemId)) {
                  _expandedSeries.remove(itemId);
                } else {
                  _expandedSeries.add(itemId);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _posterThumb(first, width: 56, height: 78),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                first.isAnime ? 'ANIME' : 'SERIE',
                                style: TextStyle(
                                  color: accent,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.lock_rounded,
                              size: 12,
                              color: Color(0xFF18C75A),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          first.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: headingColor,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${episodes.length} ${episodes.length == 1 ? "episodio" : "episodios"} · ${OfflineVaultService.formatBytes(totalBytes)}',
                          style: TextStyle(color: subColor, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => _playOfflineSeriesEpisode(episodes, 0),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.playbackPrimaryBackground,
                      foregroundColor: AppColors.playbackPrimaryForeground,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: Size.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text(
                      'Ver',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(color: AppColors.dividerFor(context), height: 1),
            for (var i = 0; i < episodes.length; i++)
              _buildSeriesEpisodeRow(
                context,
                episodes,
                i,
                headingColor,
                subColor,
                accent,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildSeriesEpisodeRow(
    BuildContext context,
    List<OfflineDownloadItem> episodes,
    int index,
    Color headingColor,
    Color subColor,
    Color accent,
  ) {
    final ep = episodes[index];
    return InkWell(
      onTap: () => _playOfflineSeriesEpisode(episodes, index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.play_circle_fill_rounded,
              color: accent,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ep.displaySubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: headingColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${OfflineVaultService.formatBytes(ep.downloadedBytes)} · ${ep.qualityLabel}',
                    style: TextStyle(color: subColor, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Eliminar episodio',
              visualDensity: VisualDensity.compact,
              onPressed: () => _vault.deleteDownload(ep.id),
              icon: Icon(
                Icons.delete_outline_rounded,
                color: subColor.withValues(alpha: 0.75),
                size: 19,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletedMovieCard(
    BuildContext context,
    OfflineDownloadItem movie,
    Color accent,
    Color headingColor,
    Color subColor,
  ) {
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: border, width: 0.85),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: () => _playOfflineMovie(movie),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _posterThumb(movie, width: 56, height: 78),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      movie.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: headingColor,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (movie.displaySubtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        movie.displaySubtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: subColor, fontSize: 11.5),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(
                          Icons.lock_rounded,
                          size: 12,
                          color: Color(0xFF18C75A),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${OfflineVaultService.formatBytes(movie.downloadedBytes)} · ${movie.qualityLabel} · Sin conexión',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF18C75A),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Reproducir sin conexión',
                onPressed: () => _playOfflineMovie(movie),
                icon: Icon(
                  Icons.play_circle_fill_rounded,
                  color: accent,
                  size: 30,
                ),
              ),
              IconButton(
                tooltip: 'Eliminar descarga',
                visualDensity: VisualDensity.compact,
                onPressed: () => _vault.deleteDownload(movie.id),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: subColor.withValues(alpha: 0.75),
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _posterThumb(
    OfflineDownloadItem item, {
    required double width,
    required double height,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: FastArtwork(
        url: item.remotePosterUrl,
        localFilePath: item.localPosterPath,
        tier: ArtworkTier.poster,
        cacheWidth: 220,
        fit: BoxFit.cover,
        errorWidget: _posterFallback(),
      ),
    );
  }

  Widget _posterFallback() => Container(
        color: const Color(0xFF181920),
        child: const Center(
          child: Icon(
            Icons.movie_outlined,
            color: Colors.white30,
            size: 24,
          ),
        ),
      );

  Widget _buildEmptyState(
    BuildContext context,
    Color accent,
    Color headingColor,
    Color subColor,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 34),
      child: Column(
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: InutilIcon(
                InutilGlyph.download,
                size: 30,
                color: accent,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Aún no tienes descargas',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: headingColor,
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Abre cualquier película, serie o anime y toca "Descargar" para verlo cuando no tengas internet.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: subColor,
              fontSize: 13,
              height: 1.48,
            ),
          ),
        ],
      ),
    );
  }
}
