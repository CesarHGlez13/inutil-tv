import 'dart:async';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../screens/downloads_screen.dart';
import '../screens/player_screen.dart';
import '../services/artwork_cache_service.dart';
import '../services/my_list_service.dart';
import '../services/offline_vault_service.dart';
import '../services/tv_mode_service.dart';
import '../services/tv_remote_service.dart';
import '../services/vod_catalog_service.dart';
import '../services/watch_history.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import 'fast_artwork.dart';
import 'poster_card.dart';
import 'tv_focusable.dart';
import 'tv_remote_sheet.dart';

/// Escala pura de estrellas (0..5) a partir del rating del proveedor (0-10).
/// Tolerante con comas europeas, vacío y basura ⇒ 0. Pública y sin contexto
/// para poder probarla sin widget (test/v3_3_19_cinematic_header_test.dart).
double starsFromRating(String rating) {
  final score =
      (double.tryParse(rating.replaceAll(',', '.')) ?? 0).clamp(0.0, 10.0);
  return score / 2;
}

/// Modal editorial de ficha VOD de InútilTV v3.0 — alineado con Inútil Music:
/// - Enriquece automáticamente sinopsis reales en español + portadas HD.
/// - Botón primario blanco puro (`#FFFFFF` / texto carbón `#07110A`) + botón Mi Lista.
/// - Temporadas completas y selector de rangos (`Ep. 1–50`, `51–100`, ...).
class VodDetailModal extends StatefulWidget {
  final VodItem item;
  final List<VodItem> recommendations;
  final void Function(VodItem)? onSelectSimilar;
  final ScrollController? scrollController;

  const VodDetailModal({
    super.key,
    required this.item,
    this.recommendations = const [],
    this.onSelectSimilar,
    this.scrollController,
  });

  static void show(
    BuildContext context,
    VodItem item, {
    List<VodItem> recommendations = const [],
    void Function(VodItem)? onSelectSimilar,
  }) {
    final bg = Theme.of(context).brightness == Brightness.dark
        ? AppColors.carbonSurface
        : Colors.white;
    if (TvModeService.of(context)) {
      showDialog<void>(
        context: context,
        builder: (ctx) {
          final size = MediaQuery.sizeOf(ctx);
          return Dialog(
            backgroundColor: bg,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 40,
              vertical: 24,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(color: AppColors.cardBorderFor(ctx)),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 880,
                maxHeight: size.height * 0.88,
              ),
              child: VodDetailModal(
                item: item,
                recommendations: recommendations,
                onSelectSimilar: onSelectSimilar,
              ),
            ),
          );
        },
      );
      return;
    }
    // Móvil: Pantalla completa estilo Crunchyroll con animación slide-up desde abajo
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        fullscreenDialog: true,
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black.withValues(alpha: 0.8),
        pageBuilder: (context, animation, secondaryAnimation) => VodDetailModal(
          item: item,
          recommendations: recommendations,
          onSelectSimilar: onSelectSimilar,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          const curve = Curves.easeOutCubic;
          final tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    );
  }

  @override
  State<VodDetailModal> createState() => _VodDetailModalState();
}

class _VodDetailModalState extends State<VodDetailModal>
    with SingleTickerProviderStateMixin {
  static const _pageChunk = 50;

  /// Revealed del lienzo de cabecera (v3.3.19): el arte entra desde negro con
  /// un fade lento y una deriva de escala mínima. Medido sobre la referencia
  /// (4 fotogramas del mismo modal): la banda superior pasa de brillo 14 → 34
  /// → 63 → 88, o sea un fade-in desde negro, no un salto. Se crea perezosamente
  /// y sólo si el sistema no pide reducir animaciones.
  AnimationController? _reveal;

  bool get _reduceMotion => WidgetsBinding
      .instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  /// Alto del lienzo: la referencia deja el arte en ~55% de la pantalla con el
  /// rótulo dentro. Aquí 46% del alto, recortado a 640 px para que en paneles
  /// grandes el arte no se estire más de lo que resuelve el CDN.
  double _heroHeight(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return (h * 0.46).clamp(300.0, 640.0);
  }

  /// v3.3.20 — Fracción de colapso de la cabecera (0 = lienzo expandido,
  /// 1 = barra anclada). `FlexibleSpaceBarSettings` es el InheritedWidget que el
  /// delegate de `SliverAppBar` publica en cada frame de scroll, así que basta
  /// con depender de él para animar el fade del arte y el crossfade del rótulo
  /// sin un controller propio. Sin `SliverAppBar` alrededor devuelve 0.
  double _collapseFraction(BuildContext context) {
    final settings =
        context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    if (settings == null) return 0.0;
    final delta = settings.maxExtent - settings.minExtent;
    if (delta <= 0) return 0.0;
    return ((settings.maxExtent - settings.currentExtent) / delta)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  /// Envuelve el arte con el fade-in desde negro + deriva de escala.
  Widget _revealed(BuildContext context, Widget child) {
    final t = _reveal;
    if (t == null) return child;
    return FadeTransition(
      opacity: CurvedAnimation(parent: t, curve: Curves.easeOutCubic),
      child: ScaleTransition(
        alignment: Alignment.center,
        scale: Tween<double>(begin: 1.055, end: 1.0).animate(
          CurvedAnimation(parent: t, curve: Curves.easeOutQuart),
        ),
        child: child,
      ),
    );
  }

  final _catalog = VodCatalogService();
  final _history = WatchHistory();
  final _myList = MyListService.instance;
  final _vault = OfflineVaultService.instance;

  late VodItem _item;
  int _selectedSeason = 1;
  int _episodeChunkIndex = 0;
  List<VodEpisode> _episodes = [];

  bool _loadingEpisodes = false;
  int _requestToken = 0;

  @override
  void initState() {
    super.initState();
    _item = widget.item;
    _history.load();
    _myList.load();
    _vault.initialize();
    _initForCurrentItem();
    if (!_reduceMotion) {
      _reveal = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 760),
      )..forward();
    }
  }

  @override
  void dispose() {
    _reveal?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VodDetailModal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _item = widget.item;
      _episodes = [];
      _selectedSeason = 1;
      _episodeChunkIndex = 0;
      _loadingEpisodes = false;
      _initForCurrentItem();
    }
  }

  void _initForCurrentItem() {
    final token = ++_requestToken;
    _hydrateMetadata(token);
    if (_item.isSeries) {
      if (_item.episodes.isNotEmpty) {
        _episodes = _item.episodes;
        _selectedSeason = _item.seasons.first;
      } else {
        _loadEpisodes(token);
      }
    }
  }

  Future<void> _hydrateMetadata(int token) async {
    final enriched = await _catalog.enrichDetail(_item);
    if (!mounted || token != _requestToken) return;
    setState(() {
      _item = enriched;
      if (_episodes.isEmpty && enriched.episodes.isNotEmpty) {
        _episodes = enriched.episodes;
        _selectedSeason = enriched.seasons.first;
      }
    });
  }

  Future<void> _loadEpisodes(int token) async {
    setState(() => _loadingEpisodes = true);
    final eps = await _catalog.fetchEpisodes(_item);
    if (!mounted || token != _requestToken) return;
    final saved = _history.progressFor(_item.id);
    setState(() {
      _episodes = eps;
      _loadingEpisodes = false;
      if (eps.isNotEmpty) {
        final seasons = eps.map((e) => e.seasonNumber).toSet().toList()..sort();
        if (saved != null && seasons.contains(saved.seasonNumber)) {
          _selectedSeason = saved.seasonNumber;
          _episodeChunkIndex =
              ((saved.episodeNumber - 1) ~/ _pageChunk).clamp(0, 999);
        } else {
          _selectedSeason = seasons.first;
        }
      }
    });
  }

  List<int> get _seasons {
    if (_episodes.isEmpty) {
      // Agrupación por show: el modelo ya conoce las temporadas declaradas
      // (seasonCount/entradas hermanas unidas) aunque los episodios se
      // carguen de forma diferida. Sin esto el selector no aparece.
      final s = _item.seasons;
      return s.isEmpty ? const [1] : s;
    }
    final s = _episodes.map((e) => e.seasonNumber).toSet().toList()..sort();
    return s.isEmpty ? const [1] : s;
  }

  List<VodEpisode> get _episodesForCurrentSeason =>
      _episodes.where((e) => e.seasonNumber == _selectedSeason).toList();

  void _openPlayer({
    VodEpisode? episode,
    List<VodEpisode>? episodeList,
    int initialEpisodeIndex = 0,
    Duration? resumePosition,
  }) {
    // Si la Smart TV estaba reproduciendo contenido, la detenemos para que
    // no se reproduzca simultáneamente en la TV y en el móvil (cero duplicidad).
    if (!TvModeService.of(context) && TvRemoteService.instance.isTvOnline) {
      unawaited(TvRemoteService.instance.sendStop());
    }

    final item = _item;
    final directPlayables = <Playable>[];
    if (episode != null && episode.sources.isNotEmpty) {
      for (final s in episode.sources) {
        directPlayables.add(
          Playable(
            s.quality.isEmpty ? 'Servidor Directo' : s.quality,
            s.url,
            headers: s.headers,
            subtitles: s.subtitles,
          ),
        );
      }
    } else if (episode == null && item.sources.isNotEmpty) {
      for (final s in item.sources) {
        directPlayables.add(
          Playable(
            s.quality.isEmpty ? 'Servidor Directo' : s.quality,
            s.url,
            headers: s.headers,
            subtitles: s.subtitles,
          ),
        );
      }
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: item.title,
          subtitle: episode != null
              ? 'T${episode.seasonNumber} · Ep. ${episode.episodeNumber} — ${episode.title}'
              : '${item.year.isNotEmpty ? "${item.year} · " : ""}${item.genre}',
          posterUrl: item.backdrop.isNotEmpty ? item.backdrop : item.poster,
          playables: directPlayables,
          isVod: true,
          isAnime: item.isAnime,
          animeId: item.isAnime ? item.id : null,
          vodItem: item,
          episodeList: episodeList,
          initialEpisodeIndex: initialEpisodeIndex,
          initialPosition: resumePosition,
        ),
      ),
    );
  }

  Future<void> _sendMovieToTv(Duration? resumePos) async {
    final posSec = resumePos?.inSeconds ?? 0;
    final ok = await TvRemoteService.instance.sendVodToTv(
      _item,
      positionSec: posSec,
    );
    if (!mounted) return;
    if (ok) {
      unawaited(TvRemoteService.instance.refreshTvStateNow());
      TvRemoteSheet.show(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo conectar con la Smart TV'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _sendEpisodeToTv(VodEpisode ep, int globalIndex) async {
    final saved = _history.progressFor(_item.id);
    final isCurrentEpisode = saved != null &&
        saved.seasonNumber == ep.seasonNumber &&
        saved.episodeNumber == ep.episodeNumber;
    final posSec =
        (isCurrentEpisode && saved.positionSec > 10 && !saved.finished)
            ? saved.positionSec.round()
            : 0;

    final ok = await TvRemoteService.instance.sendVodToTv(
      _item,
      episode: ep,
      positionSec: posSec,
    );
    if (!mounted) return;
    if (ok) {
      unawaited(TvRemoteService.instance.refreshTvStateNow());
      TvRemoteSheet.show(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo conectar con la Smart TV'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _playMainAction() {
    final saved = _history.progressFor(_item.id);
    final tvState = TvRemoteService.instance.tvState;
    // Si la TV estaba reproduciendo este contenido, transferimos su segundo exacto al celular
    final isSameContentOnTv = tvState.isPlaying &&
        (tvState.title.toLowerCase().contains(_item.title.toLowerCase()) ||
            _item.title.toLowerCase().contains(tvState.title.toLowerCase()));

    final resumePos = (isSameContentOnTv && tvState.positionSec > 5)
        ? Duration(seconds: tvState.positionSec)
        : ((saved != null && saved.positionSec > 10 && !saved.finished)
            ? Duration(seconds: saved.positionSec.round())
            : null);

    if (!TvModeService.of(context) && TvRemoteService.instance.playOnTv) {
      if (_item.isSeries) {
        final allEps = _episodes;
        var idx = 0;
        if (saved != null && allEps.isNotEmpty) {
          final found = allEps.indexWhere(
            (e) =>
                e.seasonNumber == saved.seasonNumber &&
                e.episodeNumber == saved.episodeNumber,
          );
          if (found >= 0) idx = found;
        }
        final targetEp = allEps.isNotEmpty
            ? allEps[idx]
            : VodEpisode(
                id: _item.isAnime
                    ? 'https://jkanime.net/${_item.slug}/1/'
                    : 'ep_1_${_item.slug}',
                title: 'Episodio 1',
                episodeNumber: 1,
                seasonNumber: 1,
                provider: _item.provider,
              );
        _sendEpisodeToTv(targetEp, idx);
        return;
      } else {
        _sendMovieToTv(resumePos);
        return;
      }
    }

    // Si se reproduce en móvil y la TV estaba online, detenemos la TV de inmediato
    if (!TvModeService.of(context) && TvRemoteService.instance.isTvOnline) {
      unawaited(TvRemoteService.instance.sendStop());
    }

    if (_item.isSeries) {
      final allEps = _episodes;
      if (allEps.isNotEmpty) {
        var idx = 0;
        if (saved != null) {
          final found = allEps.indexWhere(
            (e) =>
                e.seasonNumber == saved.seasonNumber &&
                e.episodeNumber == saved.episodeNumber,
          );
          if (found >= 0) idx = found;
        }
        _openPlayer(
          episode: allEps[idx],
          episodeList: allEps,
          initialEpisodeIndex: idx,
          resumePosition: resumePos,
        );
        return;
      }
      final ep1 = VodEpisode(
        id: _item.isAnime
            ? 'https://jkanime.net/${_item.slug}/1/'
            : 'ep_1_${_item.slug}',
        title: 'Episodio 1',
        episodeNumber: 1,
        seasonNumber: 1,
        provider: _item.provider,
      );
      _openPlayer(
        episode: ep1,
        episodeList: [ep1],
        initialEpisodeIndex: 0,
        resumePosition: resumePos,
      );
      return;
    }

    _openPlayer(resumePosition: resumePos);
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final image = item.backdrop.isNotEmpty ? item.backdrop : item.poster;
    final heroH = _heroHeight(context);
    final seasons = _seasons;
    final seasonEpisodes = _episodesForCurrentSeason;

    final totalChunks = (seasonEpisodes.length / _pageChunk).ceil();
    final safeChunk =
        totalChunks > 0 ? _episodeChunkIndex.clamp(0, totalChunks - 1) : 0;
    final visibleEpisodes = seasonEpisodes.length > _pageChunk
        ? seasonEpisodes.skip(safeChunk * _pageChunk).take(_pageChunk).toList()
        : seasonEpisodes;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark ? AppColors.carbonSurface : Colors.white;
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final surface = AppColors.elevatedSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);

    final hasRealRating = item.rating.isNotEmpty &&
        item.rating != '0.0' &&
        !(item.provider == 'jkanime' && item.rating == '8.8') &&
        !(item.provider == 'pelisflix' && item.rating == '8.5');

    return ListenableBuilder(
      listenable: Listenable.merge([_myList, _history, _vault]),
      builder: (context, _) {
        final inMyList = _myList.contains(item.id);
        final saved = _history.progressFor(item.id);
        final canResume =
            saved != null && saved.positionSec > 10 && !saved.finished;
        final movieDl = !item.isSeries ? _vault.findForMovie(item.id) : null;

        final isTv = TvModeService.of(context);

        return Scaffold(
          backgroundColor: sheetBg,
          body: Stack(
            children: [
              CustomScrollView(
                controller: widget.scrollController,
                slivers: [
                  // ── Cabecera (SliverAppBar Collapsing Toolbar estilo Crunchyroll 2026):
                  // El póster hace parallax y fade-out al subir; el título sube y se ancla
                  // a la izquierda junto a la "X" mientras los iconos (Cast y Más opciones)
                  // permanecen fijos a la derecha.
                  SliverAppBar(
                    pinned: true,
                    primary: !isTv,
                    expandedHeight: heroH,
                    collapsedHeight: kToolbarHeight,
                    centerTitle: false,
                    titleSpacing: 0,
                    backgroundColor: sheetBg,
                    elevation: 0,
                    leading: IconButton(
                      tooltip: 'Cerrar',
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    title: Builder(
                      builder: (context) {
                        final k = _collapseFraction(context);
                        return Opacity(
                          opacity: Curves.easeIn
                              .transform(((k - 0.45) / 0.55).clamp(0.0, 1.0)),
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: appTabTitleStyle(context).copyWith(
                              fontSize: isTv ? 26.0 : 18.0,
                              fontWeight: FontWeight.w900,
                              color: headingColor,
                            ),
                          ),
                        );
                      },
                    ),
                    actions: [
                      IconButton(
                        tooltip: 'Transmitir / Smart TV',
                        icon: Icon(
                          TvRemoteService.instance.isTvOnline
                              ? Icons.cast_connected_rounded
                              : Icons.cast_rounded,
                          color: TvRemoteService.instance.isTvOnline
                              ? const Color(0xFF18C75A)
                              : Colors.white,
                          size: 23,
                        ),
                        onPressed: () => TvRemoteSheet.show(context),
                      ),
                      IconButton(
                        tooltip: 'Más opciones',
                        icon: const Icon(
                          Icons.more_vert_rounded,
                          color: Colors.white,
                          size: 23,
                        ),
                        onPressed: () => _showMoreOptions(context),
                      ),
                      const SizedBox(width: 4),
                    ],
                flexibleSpace: FlexibleSpaceBar(
                  // Parallax nativo: el arte sube más despacio que el scroll y
                  // se recorta al encogerse el contenedor.
                  collapseMode: CollapseMode.parallax,
                  background: Stack(
                    children: [
                      SizedBox(
                        height: heroH,
                        width: double.infinity,
                        child: _revealed(
                          context,
                          image.isNotEmpty
                              ? FastArtwork(
                                  url: image,
                                  tier: ArtworkTier.backdrop,
                                  cacheWidth: 900,
                                  fit: BoxFit.cover,
                                  errorWidget: ColoredBox(color: surface),
                                )
                              : ColoredBox(color: surface),
                        ),
                      ),
                      // 2. Viñeta superior oscura: legibilidad de iconos de cabecera
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 120,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.72),
                                Colors.black.withValues(alpha: 0.30),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.55, 1.0],
                            ),
                          ),
                        ),
                      ),
                      // 3. Viñeta inferior: fundido cinematográfico hacia el fondo
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: 190,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.45),
                                sheetBg.withValues(alpha: 0.85),
                                sheetBg,
                              ],
                              stops: const [0.0, 0.45, 0.8, 1.0],
                            ),
                          ),
                        ),
                      ),
                      // 4. Velo dinámico al colapsar
                      Positioned.fill(
                        child: Builder(
                          builder: (context) => ColoredBox(
                            color: sheetBg.withValues(
                              alpha: 0.95 *
                                  Curves.easeIn
                                      .transform(_collapseFraction(context)),
                            ),
                          ),
                        ),
                      ),
                      // Rótulo dentro del lienzo (v3.3.19): tipografía display
                      // sobre el arte. Se desvanece al colapsar (crossfade con
                      // el título anclado en la barra pinned).
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 24,
                        child: Builder(
                          builder: (context) {
                            final k = _collapseFraction(context);
                            return Opacity(
                              opacity: (1.0 - k * 2.5).clamp(0.0, 1.0),
                              child: Center(
                                child: Text(
                                  item.title,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: appTabTitleStyle(context).copyWith(
                                    fontSize:
                                        TvModeService.of(context) ? 46 : 31,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing:
                                        TvModeService.of(context)
                                            ? -1.0
                                            : -0.65,
                                    color: Colors.white,
                                    shadows: const [
                                      Shadow(
                                        blurRadius: 28,
                                        color: Colors.black87,
                                        offset: Offset(0, 3),
                                      ),
                                      Shadow(
                                        blurRadius: 10,
                                        color: Colors.black54,
                                      ),
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
                ),
              ),

              SliverList(
                delegate: SliverChildListDelegate([
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Fila de estrellas de la referencia (v3.3.19), centrada.
                        if (hasRealRating) _starsRow(context, item.rating),
                        const SizedBox(height: 16),
                        _buildCrunchyrollActionRow(
                          context,
                          item,
                          movieDl,
                          accent,
                        ),
                        const SizedBox(height: 16),
                        if (isTv) ...[
                          TvFocusable(
                            autofocus: true,
                            onTap: _playMainAction,
                            borderRadius: BorderRadius.circular(24),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF640A),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.play_arrow_rounded,
                                      color: Colors.white, size: 24),
                                  const SizedBox(width: 8),
                                  Text(
                                    canResume
                                        ? 'Continuar reproducción'
                                        : 'Reproducir ahora',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          alignment: WrapAlignment.center,
                          children: [
                            if (item.year.isNotEmpty)
                              _metaChip(context, item.year),
                            if (item.duration.isNotEmpty)
                              _metaChip(context, item.duration),
                            if (item.isSeries)
                              _metaChip(
                                context,
                                item.isAnime ? 'Anime' : 'Serie',
                              ),
                            if (item.isSeries && _episodes.isNotEmpty)
                              _metaChip(
                                  context, '${_episodes.length} episodios'),
                          ],
                        ),
                        if (item.genre.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            item.genre.replaceAll(
                                RegExp(r'^[🎬📺⚡🔥🎞️✨🧸]+\s*'), ''),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: subColor,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          'Sinopsis',
                          textAlign: TextAlign.center,
                          style: appListCardTitleStyle(context),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.overview.isNotEmpty
                              ? item.overview
                              : 'Título disponible en alta definición con cambio automático de servidor en InútilTV.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: headingColor.withValues(alpha: 0.8),
                            fontSize: 13.5,
                            height: 1.48,
                          ),
                        ),
                        if (item.isSeries) ...[
                          const SizedBox(height: 22),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'Episodios',
                                    style: appSectionTitleStyle(context),
                                  ),
                                  if (_loadingEpisodes) ...[
                                    const SizedBox(width: 10),
                                    SizedBox(
                                      width: 15,
                                      height: 15,
                                      child: CircularProgressIndicator(
                                        color: accent,
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (seasonEpisodes.isNotEmpty)
                                    TextButton.icon(
                                      key: const ValueKey(
                                          'vod-batch-download-btn'),
                                      onPressed: () => _showBatchDownloadSheet(
                                        context,
                                        seasonEpisodes,
                                      ),
                                      style: TextButton.styleFrom(
                                        foregroundColor: accent,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      icon: InutilIcon(
                                        InutilGlyph.download,
                                        size: 16,
                                        color: accent,
                                      ),
                                      label: const Text(
                                        'Descargar',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  if (seasons.length > 1) ...[
                                    const SizedBox(width: 4),
                                    DropdownButton<int>(
                                      value: seasons.contains(_selectedSeason)
                                          ? _selectedSeason
                                          : seasons.first,
                                      dropdownColor: surface,
                                      underline: const SizedBox.shrink(),
                                      icon: Icon(
                                        Icons.keyboard_arrow_down_rounded,
                                        color: accent,
                                      ),
                                      style: TextStyle(
                                        color: accent,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13,
                                      ),
                                      items: [
                                        for (final s in seasons)
                                          DropdownMenuItem(
                                            value: s,
                                            child: Text('Temporada $s'),
                                          ),
                                      ],
                                      onChanged: (val) {
                                        if (val != null) {
                                          setState(() {
                                            _selectedSeason = val;
                                            _episodeChunkIndex = 0;
                                          });
                                        }
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                          // Píldoras horizontales de Temporada (acceso inmediato en móvil y TV)
                          if (seasons.length > 1) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 34,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: seasons.length,
                                itemBuilder: (_, idx) {
                                  final s = seasons[idx];
                                  final active = s == _selectedSeason;
                                  return TvFocusable(
                                    onTap: () => setState(() {
                                      _selectedSeason = s;
                                      _episodeChunkIndex = 0;
                                    }),
                                    borderRadius: BorderRadius.circular(14),
                                    margin: const EdgeInsets.only(right: 8),
                                    child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 160),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 13,
                                      ),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: active ? accent : surface,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: active ? accent : border,
                                          width: 0.85,
                                        ),
                                      ),
                                      child: Text(
                                        'T$s',
                                        style: TextStyle(
                                          color: active ? onAccent : subColor,
                                          fontSize: 12,
                                          fontWeight: active
                                              ? FontWeight.w800
                                              : FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            if (_item.seasonLabelFor(_selectedSeason) != null &&
                                _item.seasonLabelFor(_selectedSeason) !=
                                    _item.title) ...[
                              const SizedBox(height: 6),
                              Text(
                                _item.seasonLabelFor(_selectedSeason)!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: subColor,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                          if (totalChunks > 1) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 32,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: totalChunks,
                                itemBuilder: (_, idx) {
                                  final start = idx * _pageChunk + 1;
                                  final end = ((idx + 1) * _pageChunk)
                                      .clamp(1, seasonEpisodes.length);
                                  final active = idx == safeChunk;
                                  return TvFocusable(
                                    onTap: () => setState(
                                        () => _episodeChunkIndex = idx),
                                    borderRadius: BorderRadius.circular(14),
                                    margin: const EdgeInsets.only(right: 8),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: active ? accent : surface,
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: active ? accent : border,
                                          width: 0.8,
                                        ),
                                      ),
                                      child: Text(
                                        'Ep. $start–$end',
                                        style: TextStyle(
                                          color: active ? onAccent : subColor,
                                          fontSize: 11.5,
                                          fontWeight: active
                                              ? FontWeight.w800
                                              : FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          if (visibleEpisodes.isEmpty && !_loadingEpisodes)
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: border),
                              ),
                              child: Text(
                                'Pulsa Reproducir arriba para iniciar desde el Episodio 1.',
                                style: appListCardSubtitleStyle(context),
                              ),
                            )
                          else
                            Column(
                              children: [
                                for (final ep in visibleEpisodes)
                                  _buildEpisodeTile(
                                    context,
                                    ep,
                                    _episodes.indexOf(ep),
                                  ),
                              ],
                            ),
                        ],
                        if (widget.recommendations.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          Text(
                            'Títulos Similares',
                            style: appSectionTitleStyle(context),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 224,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: widget.recommendations.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 12),
                              itemBuilder: (_, idx) {
                                final sim = widget.recommendations[idx];
                                return PosterCard(
                                  item: sim,
                                  width: 118,
                                  height: 174,
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    widget.onSelectSimilar?.call(sim);
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                        SizedBox(height: isTv ? 24 : 110),
                      ],
                    ),
                  ),
                ]),
              ),
            ],
          ),
          if (!isTv)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildCrunchyrollFloatingBar(
                context,
                item,
                canResume,
                saved,
                movieDl,
                sheetBg,
                inMyList,
              ),
            ),
        ],
      ),
    );
      },
    );
  }


  Widget _buildCrunchyrollFloatingBar(
    BuildContext context,
    VodItem item,
    bool canResume,
    WatchProgress? saved,
    OfflineDownloadItem? movieDl,
    Color bg,
    bool inMyList,
  ) {
    final playOnTv = TvRemoteService.instance.playOnTv;

    String mainLabel;
    if (playOnTv) {
      mainLabel = canResume
          ? (item.isSeries
              ? 'Ver T${saved!.seasonNumber}·E${saved.episodeNumber} en TV'
              : 'Continuar en TV')
          : 'Reproducir en TV';
    } else {
      mainLabel = canResume
          ? (item.isSeries
              ? 'Continuar T${saved!.seasonNumber}·E${saved.episodeNumber}'
              : 'Continuar')
          : (movieDl?.isCompleted == true
              ? 'Ver sin conexión'
              : (item.isSeries ? 'Comenzar a ver E1' : 'Reproducir'));
    }

    const orangeCta = Color(0xFFFF640A);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomInset),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            bg,
            bg.withValues(alpha: 0.96),
            bg.withValues(alpha: 0.85),
            bg.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 0.75, 1.0],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _playMainAction,
              icon: Icon(
                playOnTv
                    ? Icons.cast_connected_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 24,
              ),
              label: Text(
                mainLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                  letterSpacing: 0.2,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: playOnTv
                    ? const Color(0xFF18C75A)
                    : orangeCta,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                elevation: 6,
                shadowColor: (playOnTv
                        ? const Color(0xFF18C75A)
                        : orangeCta)
                    .withValues(alpha: 0.4),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: inMyList
                    ? orangeCta
                    : Colors.white.withValues(alpha: 0.25),
                width: 1.5,
              ),
              color: inMyList
                  ? orangeCta.withValues(alpha: 0.2)
                  : Colors.black.withValues(alpha: 0.45),
            ),
            child: IconButton(
              onPressed: () async {
                final added = await _myList.toggle(item);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        added
                            ? 'Agregado a Mi Lista'
                            : 'Quitado de Mi Lista',
                      ),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                }
              },
              icon: Icon(
                inMyList
                    ? Icons.bookmark_added_rounded
                    : Icons.bookmark_add_outlined,
                color: inMyList ? orangeCta : Colors.white,
                size: 22,
              ),
              tooltip: inMyList ? 'En Mi Lista' : 'Guardar en Mi Lista',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCrunchyrollActionRow(
    BuildContext context,
    VodItem item,
    OfflineDownloadItem? movieDl,
    Color accent,
  ) {
    const orangeCta = Color(0xFFFF640A);
    final inMyList = _myList.contains(item.id);
    final isSeries = item.isSeries;
    final seasonEpisodes = _episodesForCurrentSeason;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _crunchyrollActionItem(
            icon: inMyList
                ? Icons.bookmark_added_rounded
                : Icons.add_rounded,
            label: inMyList ? 'En Mi Lista' : 'Mi Lista',
            color: inMyList ? orangeCta : Colors.white,
            onTap: () async {
              final added = await _myList.toggle(item);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      added
                          ? 'Agregado a Mi Lista'
                          : 'Quitado de Mi Lista',
                    ),
                    duration: const Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
          _crunchyrollActionItem(
            icon: TvRemoteService.instance.playOnTv
                ? Icons.cast_connected_rounded
                : Icons.cast_rounded,
            label: TvRemoteService.instance.playOnTv
                ? 'En TV'
                : 'Transmitir',
            color: TvRemoteService.instance.playOnTv
                ? const Color(0xFF18C75A)
                : Colors.white,
            onTap: () => TvRemoteSheet.show(context),
          ),
          if (isSeries)
            _crunchyrollActionItem(
              icon: Icons.download_rounded,
              label: 'Descargar',
              color: Colors.white,
              onTap: seasonEpisodes.isNotEmpty
                  ? () => _showBatchDownloadSheet(context, seasonEpisodes)
                  : () {},
            )
          else
            _crunchyrollActionItem(
              icon: movieDl?.isCompleted == true
                  ? Icons.offline_pin_rounded
                  : (movieDl?.isActive == true
                      ? Icons.downloading_rounded
                      : Icons.download_rounded),
              label: movieDl?.isCompleted == true
                  ? 'Descargada'
                  : (movieDl?.isActive == true ? 'Descargando' : 'Descargar'),
              color: movieDl?.isCompleted == true
                  ? const Color(0xFF18C75A)
                  : Colors.white,
              onTap: () async {
                if (movieDl == null) {
                  await _vault.enqueueMovie(item);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Descargando película para ver sin conexión...',
                        ),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                } else if (movieDl.isCompleted) {
                  await _showCompletedDownloadActions(
                    context,
                    movieDl,
                    () => _playMainAction(),
                  );
                } else if (movieDl.isActive) {
                  await _vault.pauseDownload(movieDl.id);
                } else {
                  await _vault.resumeDownload(movieDl.id);
                }
              },
            ),
          _crunchyrollActionItem(
            icon: Icons.share_rounded,
            label: 'Compartir',
            color: Colors.white,
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Compartir "${item.title}"'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _crunchyrollActionItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color.withValues(alpha: 0.9),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMoreOptions(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF141922) : Colors.white;
    final heading = isDark ? Colors.white : Colors.black87;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.share_rounded, color: Colors.white),
                title: Text('Compartir título',
                    style: TextStyle(color: heading, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Compartiendo "${_item.title}"'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  _myList.contains(_item.id)
                      ? Icons.bookmark_remove_rounded
                      : Icons.bookmark_add_rounded,
                  color: _myList.contains(_item.id)
                      ? const Color(0xFFFF640A)
                      : Colors.white,
                ),
                title: Text(
                  _myList.contains(_item.id)
                      ? 'Quitar de Mi Lista'
                      : 'Agregar a Mi Lista',
                  style: TextStyle(color: heading, fontWeight: FontWeight.w600),
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await _myList.toggle(_item);
                },
              ),
              if (!TvModeService.of(context) &&
                  TvRemoteService.instance.isTvOnline)
                ListTile(
                  leading: const Icon(Icons.settings_remote_rounded,
                      color: Color(0xFF18C75A)),
                  title: Text('Control remoto Smart TV',
                      style: TextStyle(color: heading, fontWeight: FontWeight.w600)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    TvRemoteSheet.show(context);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeTile(
    BuildContext context,
    VodEpisode ep,
    int globalIndex,
  ) {
    final watched = _history.isEpisodeWatched(
      _item.id,
      ep.seasonNumber,
      ep.episodeNumber,
    );
    final epDl = _vault.findForEpisode(
      _item.id,
      ep.seasonNumber,
      ep.episodeNumber,
    );
    final surface = AppColors.elevatedSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final accent = AppColors.accentFor(context);

    return TvFocusable(
      onTap: () {
        if (!TvModeService.of(context) && TvRemoteService.instance.playOnTv) {
          _sendEpisodeToTv(ep, globalIndex);
        } else {
          if (!TvModeService.of(context) &&
              TvRemoteService.instance.isTvOnline) {
            unawaited(TvRemoteService.instance.sendStop());
          }
          _openPlayer(
            episode: ep,
            episodeList: _episodes,
            initialEpisodeIndex: globalIndex >= 0 ? globalIndex : 0,
          );
        }
      },
      borderRadius: BorderRadius.circular(14),
      focusScale: 1.015,
      margin: const EdgeInsets.only(bottom: 9),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: epDl?.isCompleted == true
                ? const Color(0xFF18C75A).withValues(alpha: 0.45)
                : (watched
                    ? const Color(0xFF18C75A).withValues(alpha: 0.35)
                    : border),
            width: 0.8,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 84,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(9),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (ep.thumbnail.isNotEmpty)
                    FastArtwork(
                      url: ep.thumbnail,
                      tier: ArtworkTier.thumbnail,
                      cacheWidth: 240,
                      fit: BoxFit.cover,
                      errorWidget: const SizedBox.shrink(),
                    )
                  // Sin still del capítulo: nunca un recuadro negro, se muestra
                  // el arte del show (backdrop -> poster) bajo el velo.
                  else if (_item.backdrop.isNotEmpty || _item.poster.isNotEmpty)
                    FastArtwork(
                      url: _item.backdrop.isNotEmpty
                          ? _item.backdrop
                          : _item.poster,
                      tier: ArtworkTier.thumbnail,
                      cacheWidth: 240,
                      fit: BoxFit.cover,
                      errorWidget: const SizedBox.shrink(),
                    ),
                  Container(color: Colors.black.withValues(alpha: 0.34)),
                  Center(
                    child: Icon(
                      watched
                          ? Icons.check_circle_rounded
                          : (!TvModeService.of(context) &&
                                  TvRemoteService.instance.playOnTv
                              ? Icons.tv_rounded
                              : Icons.play_circle_fill_rounded),
                      color: watched
                          ? const Color(0xFF18C75A)
                          : (!TvModeService.of(context) &&
                                  TvRemoteService.instance.playOnTv
                              ? const Color(0xFF18C75A)
                              : Colors.white),
                      size: 26,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ep. ${ep.episodeNumber} · ${ep.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: headingColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        ep.duration.isNotEmpty ? ep.duration : 'HD',
                        style: TextStyle(color: subColor, fontSize: 11),
                      ),
                      if (epDl?.isCompleted == true) ...[
                        const SizedBox(width: 8),
                        const Text(
                          'Sin conexión',
                          style: TextStyle(
                            color: Color(0xFF18C75A),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ] else if (epDl != null && epDl.isActive) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${(epDl.progress * 100).round()}%',
                          style: TextStyle(
                            color: accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ] else if (watched) ...[
                        const SizedBox(width: 8),
                        const Text(
                          'Visto',
                          style: TextStyle(
                            color: Color(0xFF18C75A),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (!TvModeService.of(context) &&
                TvRemoteService.instance.isTvOnline) ...[
              IconButton(
                tooltip: 'Ver en Smart TV',
                icon: Icon(
                  TvRemoteService.instance.playOnTv
                      ? Icons.cast_connected_rounded
                      : Icons.cast_rounded,
                  size: 20,
                  color: TvRemoteService.instance.playOnTv
                      ? const Color(0xFF18C75A)
                      : subColor,
                ),
                onPressed: () => _sendEpisodeToTv(ep, globalIndex),
              ),
              const SizedBox(width: 2),
            ],
            _buildEpisodeDownloadButton(
                context, ep, globalIndex, epDl, accent, subColor),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodeDownloadButton(
    BuildContext context,
    VodEpisode ep,
    int globalIndex,
    OfflineDownloadItem? dl,
    Color accent,
    Color subColor,
  ) {
    final isDone = dl?.isCompleted == true;
    final isActive = dl?.isActive == true;
    final isPaused = dl?.status == DownloadStatus.paused;
    final isFailed = dl?.status == DownloadStatus.failed;

    return IconButton(
      key: ValueKey('vod-ep-dl-s${ep.seasonNumber}-e${ep.episodeNumber}'),
      tooltip: isDone
          ? 'Descargado sin conexión'
          : (isActive
              ? 'Pausar descarga'
              : (isPaused || isFailed
                  ? 'Reanudar descarga'
                  : 'Descargar episodio')),
      visualDensity: VisualDensity.compact,
      onPressed: () async {
        if (dl == null) {
          await _vault.enqueueEpisode(_item, ep);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Descargando T${ep.seasonNumber}·E${ep.episodeNumber} para ver sin conexión...',
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        } else if (isDone) {
          await _showCompletedDownloadActions(
            context,
            dl,
            () => _openPlayer(
              episode: ep,
              episodeList: _episodes,
              initialEpisodeIndex: globalIndex >= 0 ? globalIndex : 0,
            ),
          );
        } else if (isActive) {
          await _vault.pauseDownload(dl.id);
        } else {
          await _vault.resumeDownload(dl.id);
        }
      },
      icon: isActive
          ? SizedBox(
              width: 22,
              height: 22,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: dl!.status == DownloadStatus.resolving
                        ? null
                        : dl.progress.clamp(0.05, 1.0),
                    strokeWidth: 2.2,
                    color: accent,
                  ),
                  Icon(Icons.pause_rounded, size: 12, color: accent),
                ],
              ),
            )
          : isDone
              ? const Icon(
                  Icons.offline_pin_rounded,
                  color: Color(0xFF18C75A),
                  size: 22,
                )
              : isPaused
                  ? const Icon(
                      Icons.play_circle_outline_rounded,
                      color: Colors.amberAccent,
                      size: 22,
                    )
                  : isFailed
                      ? const Icon(
                          Icons.refresh_rounded,
                          color: Colors.redAccent,
                          size: 21,
                        )
                      : InutilIcon(
                          InutilGlyph.download,
                          size: 19,
                          color: subColor,
                        ),
    );
  }

  Future<void> _showCompletedDownloadActions(
    BuildContext context,
    OfflineDownloadItem dl,
    VoidCallback onPlay,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.cardSurfaceFor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dl.isSeries ? '${dl.title} · ${dl.displaySubtitle}' : dl.title,
                style: appListCardTitleStyle(ctx),
              ),
              const SizedBox(height: 4),
              Text(
                '${OfflineVaultService.formatBytes(dl.downloadedBytes)} · Disponible sin conexión',
                style: appListCardSubtitleStyle(ctx),
              ),
              const SizedBox(height: 14),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.play_circle_fill_rounded,
                  color: Color(0xFF18C75A),
                ),
                title: const Text('Reproducir sin conexión'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  onPlay();
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_special_outlined),
                title: const Text('Abrir mis descargas'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                  );
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Eliminar descarga',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await _vault.deleteDownload(dl.id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showBatchDownloadSheet(
    BuildContext context,
    List<VodEpisode> seasonEpisodes,
  ) async {
    final next3 = seasonEpisodes
        .where((e) =>
            _vault.findCompletedEpisode(
                _item.id, e.seasonNumber, e.episodeNumber) ==
            null)
        .take(3)
        .toList();

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.cardSurfaceFor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Descargar ${_item.title}',
                style: appSectionTitleStyle(ctx),
              ),
              const SizedBox(height: 4),
              Text(
                'Guarda varios episodios para verlos cuando no tengas internet.',
                style: appListCardSubtitleStyle(ctx),
              ),
              const SizedBox(height: 12),
              if (next3.isNotEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.downloading_rounded,
                    color: AppColors.accentFor(ctx),
                  ),
                  title: Text(
                    'Próximos ${next3.length} episodios (T$_selectedSeason)',
                  ),
                  subtitle: Text(
                    'Ep. ${next3.first.episodeNumber}–${next3.last.episodeNumber}',
                  ),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final added =
                        await _vault.enqueueEpisodesBatch(_item, next3);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            added > 0
                                ? '$added episodios añadidos a tus descargas.'
                                : 'Esos episodios ya están descargados o en cola.',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.playlist_add_check_rounded,
                  color: AppColors.accentFor(ctx),
                ),
                title: Text(
                  'Toda la Temporada $_selectedSeason (${seasonEpisodes.length} eps)',
                ),
                subtitle: Text(
                  'Calidad actual: ${_vault.quality.label}',
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  final added =
                      await _vault.enqueueEpisodesBatch(_item, seasonEpisodes);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          added > 0
                              ? '$added episodios en cola de descarga cifrada.'
                              : 'Todos los episodios de esta temporada ya están descargados.',
                        ),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.lock_outline_rounded),
                title: const Text('Ir a Mis Descargas'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaChip(BuildContext context, String text, {Color? fg}) {
    final surface = AppColors.elevatedSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final labelColor = fg ?? AppColors.contentHeadingFor(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: 0.7),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: labelColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// Fila de estrellas al estilo de la referencia (v3.3.19): 5 estrellas sobre
  /// la escala del proveedor (que viene en 0-10), con medios rellenos. El número
  /// se muestra tal cual y con `/10`: los proveedores no publican recuento de
  /// votos, así que no se inventa el `(393K)` de la referencia.
  Widget _starsRow(BuildContext context, String rating) {
    final stars = starsFromRating(rating);
    const gold = AppColors.ratingGold;
    final dim = AppColors.contentSubtitleFor(context).withValues(alpha: 0.55);
    final tv = TvModeService.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 5; i++)
            Icon(
              stars >= i + 1
                  ? Icons.star_rounded
                  : stars > i
                      ? Icons.star_half_rounded
                      : Icons.star_outline_rounded,
              size: tv ? 30 : 22,
              color: stars > i ? gold : dim,
            ),
          const SizedBox(width: 10),
          Text(
            'Media: $rating/10',
            style: TextStyle(
              color: AppColors.contentHeadingFor(context),
              fontSize: tv ? 20 : 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
