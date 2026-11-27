import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_info.dart';
import '../models/models.dart';
import '../services/artwork_cache_service.dart';
import '../services/firebase_auth_service.dart';
import '../services/my_list_service.dart';
import '../services/offline_vault_service.dart';
import '../services/play_target.dart';
import '../services/tv_mode_service.dart';
import '../services/tv_remote_service.dart';
import '../services/tv_taste_profile_service.dart';
import '../services/watch_history.dart';
import '../services/xuper_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import '../widgets/content_rail.dart';
import '../widgets/continue_watching_rail.dart';
import '../widgets/fast_artwork.dart';
import '../widgets/hero_carousel.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/vod_detail_modal.dart';
import 'downloads_screen.dart';
import 'player_screen.dart';

/// Pestaña Inicio de InútilTV v3.0 — estilo editorial Inútil Music:
/// - Hero HD con estrenos reales de TMDB.
/// - Seguir viendo + Mi Lista persistente.
/// - Accesos directos a Deportes en Vivo y Canales de México verificados.
/// - Rieles editoriales limpios con espacio inferior para la barra flotante Liquid Glass.
class HomeTab extends StatefulWidget {
  final void Function(Channel channel)? onPlayChannel;
  final VoidCallback? onGoLiveTv;
  final VoidCallback? onGoMovies;
  final VoidCallback? onGoSeries;
  final VoidCallback? onGoAnime;
  final bool isTabActive;

  const HomeTab({
    super.key,
    this.onPlayChannel,
    this.onGoLiveTv,
    this.onGoMovies,
    this.onGoSeries,
    this.onGoAnime,
    this.isTabActive = true,
  });

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  final _service = XuperService();
  final _history = WatchHistory();
  final _myList = MyListService.instance;
  final _vault = OfflineVaultService.instance;
  final _homeScrollController = ScrollController();
  final _heroPlayFocusNode = FocusNode(debugLabel: 'heroPlayFocus');

  bool _loading = true;
  bool _heroInView = true;
  int _featuredSeed = 0;
  List<Channel> _sportsChannels = [];
  List<Channel> _mexicoChannels = [];
  String _quickFilter = 'Todo';

  static const List<String> _quickFilters = [
    'Todo',
    'En Vivo',
    'Cine',
    'Series',
    'Anime',
    'Mi Lista',
    'Descargas',
  ];

  String _greetingText() {
    final hour = DateTime.now().hour;
    final prefix = hour < 12
        ? 'Buenos días'
        : (hour < 19 ? 'Buenas tardes' : 'Buenas noches');
    final user = InutilAuthService.instance.currentUser;
    final rawName = user?.displayName.trim() ?? '';
    final firstName = rawName.isNotEmpty
        ? rawName.split(' ').first
        : (user?.email.split('@').first ?? '');
    return firstName.isNotEmpty ? '$prefix, $firstName' : prefix;
  }

  @override
  void initState() {
    super.initState();
    _homeScrollController.addListener(_onHomeScroll);
    _loadData();
  }

  void _onHomeScroll() {
    if (!_homeScrollController.hasClients) return;
    final visible = _homeScrollController.offset < 340;
    if (visible != _heroInView && mounted) {
      setState(() => _heroInView = visible);
    }
  }

  @override
  void dispose() {
    _homeScrollController.removeListener(_onHomeScroll);
    _homeScrollController.dispose();
    _heroPlayFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadData() => _refreshHomeData(shuffle: false);

  Future<void> _refreshHomeData({bool shuffle = false}) async {
    await Future.wait([
      _history.load(),
      _myList.load(),
      TvTasteProfileService.instance.load(),
      _vault.initialize(),
      _service.refreshLiveCatalog(forceShuffle: shuffle),
    ]);
    final channels = await _service.getLiveChannels();
    if (!mounted) return;

    final sports = channels
        .where((c) => c.group.toLowerCase().contains('deport'))
        .take(12)
        .toList();

    final mex = channels
        .where((c) =>
            c.group == 'México' ||
            c.country == 'MX' ||
            c.id.contains('azteca') ||
            c.id.contains('once') ||
            c.id.contains('estrellas'))
        .take(12)
        .toList();

    setState(() {
      _sportsChannels = sports;
      _mexicoChannels = mex.isNotEmpty ? mex : channels.take(10).toList();
      if (shuffle) {
        _featuredSeed = DateTime.now().millisecondsSinceEpoch;
      }
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return _buildSkeleton(context);
    final accent = AppColors.accentFor(context);

    return ListenableBuilder(
      listenable: Listenable.merge([
        _service,
        _history,
        _myList,
        _vault,
        TvTasteProfileService.instance,
      ]),
      builder: (context, _) {
        final liveMovies = _service.getLiveMovies();
        final series = _service.getSeries();
        final anime = _service.getAnime();
        final rails = _service.getVodCategories();
        final resume = _history.items;
        final myListItems = _myList.items;

        final poolFeatured = _service.getFeaturedVod(seed: _featuredSeed);
        final featured = poolFeatured.isNotEmpty
            ? poolFeatured
            : <VodItem>[
                ...liveMovies.take(4),
                ...series.take(2),
                ...anime.take(1),
              ]
                  .where((v) => v.backdrop.isNotEmpty || v.poster.isNotEmpty)
                  .take(6)
                  .toList();

        final showHero = _quickFilter == 'Todo';
        final showLive = _quickFilter == 'Todo' || _quickFilter == 'En Vivo';
        final showMyList =
            (_quickFilter == 'Todo' || _quickFilter == 'Mi Lista') &&
                myListItems.isNotEmpty;

        final filteredRails = <MapEntry<String, List<VodItem>>>[];
        for (final rail in rails.entries) {
          final k = rail.key.toLowerCase();
          final isPersonalized = k.contains('novedades') ||
              k.contains('especialmente') ||
              k.contains('porque viste') ||
              k.contains('descubrimientos');
          if (_quickFilter == 'Todo') {
            filteredRails.add(rail);
          } else if (_quickFilter == 'Cine') {
            if (isPersonalized) {
              final onlyMovies =
                  rail.value.where((v) => !v.isSeries && !v.isAnime).toList();
              if (onlyMovies.isNotEmpty) {
                filteredRails.add(MapEntry(rail.key, onlyMovies));
              }
            } else if (!k.contains('serie') && !k.contains('anime')) {
              filteredRails.add(rail);
            }
          } else if (_quickFilter == 'Series') {
            if (isPersonalized) {
              final onlySeries =
                  rail.value.where((v) => v.isSeries && !v.isAnime).toList();
              if (onlySeries.isNotEmpty) {
                filteredRails.add(MapEntry(rail.key, onlySeries));
              }
            } else if (k.contains('serie')) {
              filteredRails.add(rail);
            }
          } else if (_quickFilter == 'Anime') {
            if (isPersonalized) {
              final onlyAnime = rail.value.where((v) => v.isAnime).toList();
              if (onlyAnime.isNotEmpty) {
                filteredRails.add(MapEntry(rail.key, onlyAnime));
              }
            } else if (k.contains('anime')) {
              filteredRails.add(rail);
            }
          }
        }

        return RefreshIndicator(
          color: accent,
          backgroundColor: AppColors.elevatedSurfaceFor(context),
          onRefresh: () => _refreshHomeData(shuffle: true),
          child: ListView(
            controller: _homeScrollController,
            cacheExtent: TvModeService.instance.isTv ? 320 : 700,
            padding: const EdgeInsets.only(top: 10, bottom: 112),
            children: [
              // 0. Saludo contextual + píldoras rápidas (estilo Inútil Music v2.2+)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: appPagePaddingHorizontal,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _greetingText(),
                        key: const ValueKey('home-contextual-greeting'),
                        style: appSectionTitleStyle(context).copyWith(
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                    TvFocusable(
                      key: const ValueKey('home-refresh-recommendations-btn'),
                      onTap: () async {
                        await _refreshHomeData(shuffle: true);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Recomendaciones y catálogo actualizados al instante',
                            ),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(20),
                      child: Tooltip(
                        message: 'Actualizar recomendaciones',
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.elevatedSurfaceFor(context),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.cardBorderFor(context),
                              width: 0.8,
                            ),
                          ),
                          child: Icon(
                            Icons.refresh_rounded,
                            size: 18,
                            color: AppColors.contentSubtitleFor(context),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Focus(
                onKeyEvent: (node, event) {
                  if (showHero &&
                      event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    _heroPlayFocusNode.requestFocus();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: appPagePaddingHorizontal,
                    ),
                    itemCount: _quickFilters.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, idx) {
                      final f = _quickFilters[idx];
                      final selected = f == _quickFilter;
                      return TvFocusable(
                        key: ValueKey('home-filter-$f'),
                        onTap: () => setState(() => _quickFilter = f),
                        borderRadius: BorderRadius.circular(18),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected
                                ? accent
                                : AppColors.elevatedSurfaceFor(context),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: selected
                                  ? accent
                                  : AppColors.cardBorderFor(context),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            f,
                            style: TextStyle(
                              color: selected
                                  ? AppColors.onAccentFor(context)
                                  : AppColors.contentSubtitleFor(context),
                              fontSize: 12,
                              fontWeight:
                                  selected ? FontWeight.w800 : FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 1. Hero Carousel con Estrenos TMDB HD
              if (showHero) ...[
                HeroCarousel(
                  featured: featured,
                  active: widget.isTabActive && _heroInView,
                  onPlay: _playVod,
                  onDetails: _showDetails,
                  playFocusNode: _heroPlayFocusNode,
                  onHeroFocused: () {
                    // Scroll al tope para que el hero se vea completo
                    if (_homeScrollController.hasClients) {
                      _homeScrollController.animateTo(
                        0,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
              ],

              // 2. Seguir viendo
              if (showHero)
                ContinueWatchingRail(
                  history: resume,
                  onResume: _resumeWatching,
                  onRemove: (e) => _history.remove(e.id),
                  onClear: () => _history.clear(),
                  upFocusNode: _heroPlayFocusNode,
                ),

              // 3. Mi Lista
              if (showMyList) ...[
                ContentRail(
                  title: 'Mi Lista',
                  items: myListItems,
                  onTap: _showDetails,
                ),
                const SizedBox(height: 6),
              ] else if (_quickFilter == 'Mi Lista') ...[
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Aún no tienes títulos en Mi Lista. Toca "Mi Lista" en cualquier película, serie o anime para guardarlo y respaldarlo en la nube.',
                    textAlign: TextAlign.center,
                    style: appListCardSubtitleStyle(context),
                  ),
                ),
              ],

              // 3.5 Bóveda de Descargas sin conexión (cuando el filtro es Descargas)
              if (_quickFilter == 'Descargas')
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: appPagePaddingHorizontal,
                    vertical: 8,
                  ),
                  child: Material(
                    color: AppColors.cardSurfaceFor(context),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(appCardRadius),
                      side: BorderSide(
                        color: AppColors.cardBorderFor(context),
                        width: 0.85,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(appCardRadius),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DownloadsScreen(),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
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
                                  InutilGlyph.download,
                                  size: 22,
                                  color: accent,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Descargas sin conexión',
                                    style: appListCardTitleStyle(context),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _vault.items.isEmpty
                                        ? 'Descarga películas, series o anime para verlos sin internet.'
                                        : '${_vault.completedCount} disponibles · ${_vault.activeCount} en curso · ${OfflineVaultService.formatBytes(_vault.totalVaultBytes)}',
                                    style: appListCardSubtitleStyle(context),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: AppColors.contentSubtitleFor(context),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

              // 4. Deportes en Vivo
              if (showLive && _sportsChannels.isNotEmpty) ...[
                _sectionHeader(
                  context,
                  title: 'Deportes en Vivo',
                  actionLabel: 'Ver guía',
                  onAction: widget.onGoLiveTv,
                ),
                SizedBox(
                  height: 112,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: appPagePaddingHorizontal,
                    ),
                    itemCount: _sportsChannels.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) =>
                        _buildLiveChannelCard(context, _sportsChannels[index]),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 5. Rieles editoriales VOD
              for (final rail in filteredRails) ...[
                ContentRail(
                  title: rail.key,
                  items: rail.value,
                  onTap: _showDetails,
                  onMore: rail.key.toLowerCase().contains('anime')
                      ? widget.onGoAnime
                      : rail.key.toLowerCase().contains('serie')
                          ? widget.onGoSeries
                          : widget.onGoMovies,
                ),
                const SizedBox(height: 8),
              ],

              // 6. Canales de México
              if (showLive && _mexicoChannels.isNotEmpty) ...[
                _sectionHeader(
                  context,
                  title: 'Canales de México',
                  actionLabel: 'Ver todos',
                  onAction: widget.onGoLiveTv,
                ),
                SizedBox(
                  height: 112,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: appPagePaddingHorizontal,
                    ),
                    itemCount: _mexicoChannels.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) =>
                        _buildLiveChannelCard(context, _mexicoChannels[index]),
                  ),
                ),
              ],

              const SizedBox(height: 26),

              Center(
                child: Text(
                  '${AppInfo.appName} v${AppInfo.appVersion} · Familia Inutix',
                  style: TextStyle(
                    color: AppColors.contentSubtitleFor(context)
                        .withValues(alpha: 0.55),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionHeader(
    BuildContext context, {
    required String title,
    required String actionLabel,
    VoidCallback? onAction,
  }) {
    final subColor = AppColors.contentSubtitleFor(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        appPagePaddingHorizontal,
        10,
        10,
        appSectionTitleGap,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: appSectionTitleStyle(context),
            ),
          ),
          if (onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: subColor,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    actionLabel,
                    style: TextStyle(
                      color: subColor,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right_rounded, size: 17, color: subColor),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSkeleton(BuildContext context) {
    final surface = AppColors.elevatedSurfaceFor(context);
    return ListView(
      padding: const EdgeInsets.only(top: 12, bottom: 112),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Container(
          height: 310,
          margin:
              const EdgeInsets.symmetric(horizontal: appPagePaddingHorizontal),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Center(
            child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                color: AppColors.accentFor(context),
                strokeWidth: 2.2,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        ContentRail(
          title: 'Cargando catálogo',
          items: const [],
          loading: true,
          onTap: (_) {},
        ),
      ],
    );
  }

  Widget _buildLiveChannelCard(BuildContext context, Channel ch) {
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final titleColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);

    return TvFocusable(
      onTap: () {
        if (widget.onPlayChannel != null) {
          widget.onPlayChannel!(ch);
        } else {
          _playLiveDirect(ch);
        }
      },
      borderRadius: BorderRadius.circular(appCardRadius),
      focusScale: 1.04,
      child: Container(
        width: 158,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(appCardRadius),
          border: Border.all(color: border, width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ch.logo.isNotEmpty
                      ? FastArtwork(
                          url: ch.logo,
                          tier: ArtworkTier.thumbnail,
                          cacheWidth: 120,
                          fit: BoxFit.contain,
                          errorWidget: Icon(
                            Icons.tv_rounded,
                            color: subColor,
                            size: 20,
                          ),
                        )
                      : Icon(Icons.tv_rounded, color: subColor, size: 20),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.liveRed.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.liveRed.withValues(alpha: 0.45),
                      width: 0.6,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 2.4,
                        backgroundColor: AppColors.liveRed,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'EN VIVO',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ch.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  ch.sources.length > 1
                      ? '${ch.group} · ${ch.sources.length} señales'
                      : ch.group,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: subColor,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showDetails(VodItem item) {
    final pool = [
      ..._service.getLiveMovies(),
      ..._service.getSeries(),
      ..._service.getAnime(),
    ];
    final similar = pool
        .where((m) =>
            m.id != item.id &&
            m.isSeries == item.isSeries &&
            m.isAnime == item.isAnime)
        .take(8)
        .toList();

    VodDetailModal.show(
      context,
      item,
      recommendations: similar,
      onSelectSimilar: _showDetails,
    );
  }

  void _playVod(VodItem item, {Duration? initialPosition}) {
    if (item.isSeries) {
      _showDetails(item);
      return;
    }

    // "Destino: TV" activo → la película arranca en la Smart TV, no aquí.
    if (PlayTarget.isTvDestination(context)) {
      unawaited(_playVodOnTv(item, initialPosition: initialPosition));
      return;
    }

    _openVodPlayer(item, initialPosition: initialPosition);
  }

  Future<void> _playVodOnTv(VodItem item, {Duration? initialPosition}) async {
    final ok = await PlayTarget.sendVod(item, position: initialPosition);
    if (!mounted) return;
    PlayTarget.report(context, ok: ok);
    if (ok) {
      unawaited(TvRemoteService.instance.refreshTvStateNow());
    } else {
      // Sin TV que responda no dejamos al usuario sin reproducción.
      _openVodPlayer(item, initialPosition: initialPosition);
    }
  }

  void _openVodPlayer(VodItem item, {Duration? initialPosition}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: item.title,
          subtitle:
              '${item.year.isNotEmpty ? "${item.year} · " : ""}${item.genre}',
          posterUrl: item.backdrop.isNotEmpty ? item.backdrop : item.poster,
          playables: [
            for (final s in item.sources)
              Playable(
                s.quality.isEmpty ? 'Servidor Directo' : s.quality,
                s.url,
                headers: s.headers,
              ),
          ],
          isVod: true,
          isAnime: item.isAnime,
          animeId: item.isAnime ? item.id : null,
          vodItem: item,
          initialPosition: initialPosition,
        ),
      ),
    );
  }

  void _resumeWatching(WatchProgress entry) {
    final pool = [
      ..._service.getMovies(),
      ..._service.getSeries(),
      ..._service.getAnime(),
    ];
    final match = pool.where((v) => v.id == entry.id).toList();
    final item = match.isNotEmpty ? match.first : entry.toVodItem();
    final resumePos = entry.positionSec > 10 && !entry.finished
        ? Duration(seconds: entry.positionSec.round())
        : null;

    if (entry.isSeries || item.isSeries) {
      _showDetails(item);
    } else {
      _playVod(item, initialPosition: resumePos);
    }
  }

  void _playLiveDirect(Channel ch) {
    if (ch.sources.isEmpty) return;

    // "Destino: TV" activo → la señal sintoniza en la Smart TV.
    if (PlayTarget.isTvDestination(context)) {
      unawaited(_playLiveOnTv(ch));
      return;
    }

    _openLivePlayer(ch);
  }

  Future<void> _playLiveOnTv(Channel ch) async {
    final ok = await PlayTarget.sendChannel(ch);
    if (!mounted) return;
    PlayTarget.report(context, ok: ok);
    if (ok) {
      unawaited(TvRemoteService.instance.refreshTvStateNow());
    } else {
      _openLivePlayer(ch);
    }
  }

  void _openLivePlayer(Channel ch) {
    final list = _sportsChannels.any((c) => c.id == ch.id)
        ? _sportsChannels
        : _mexicoChannels;
    final idx = list.indexWhere((c) => c.id == ch.id);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: ch.name,
          subtitle: ch.group,
          playables: [
            for (final s in ch.sources)
              Playable(
                s.quality.isEmpty ? 'Señal En Vivo' : s.quality,
                s.url,
                headers: s.headers,
              ),
          ],
          channelList: list.isNotEmpty ? list : [ch],
          initialChannelIndex: idx >= 0 ? idx : 0,
        ),
      ),
    );
  }
}
