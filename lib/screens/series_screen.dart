import 'dart:async';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/artwork_cache_service.dart';
import '../services/tv_mode_service.dart';
import '../services/tv_taste_profile_service.dart';
import '../services/vod_catalog_service.dart';
import '../services/watch_history.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import '../widgets/catalog_empty_state.dart';
import '../widgets/poster_card.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/vod_detail_modal.dart';

/// Catálogo dedicado de Series de InútilTV v3.0 (sin sub-pestaña duplicada de Anime).
/// Portadas HD TMDB, sinopsis reales y episodios completos en 1 petición.
class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key});

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  final _catalog = VodCatalogService();
  final _searchCtl = TextEditingController();
  late final FocusNode _searchFocus = TvFocusable.createTextFieldFocusNode(
    controller: _searchCtl,
    tvKeyboardTitle: 'Buscar series en HD',
    onChanged: _onSearchChanged,
  );
  final _scrollCtl = ScrollController();

  List<VodItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _falloDeRed = false;
  int _currentPage = 1;
  int _requestToken = 0;
  String _selectedCategory = 'para_ti';
  Timer? _debounce;

  static const _categories = [
    (id: 'para_ti', label: 'Para ti'),
    (id: 'recientes', label: 'Recientes'),
    (id: 'populares', label: 'Populares HD'),
    (id: 'tendencias', label: 'Tendencias'),
    (id: 'estrenos', label: 'Estrenos'),
    // Géneros de SeriesKao añadidos en v3.3.16 (slugs del propio sitio,
    // verificados en vivo: 200 OK con 24 tarjetas por página).
    (id: 'gen:accion', label: 'Acción'),
    (id: 'gen:comedia', label: 'Comedia'),
    (id: 'gen:crimen', label: 'Crimen'),
    (id: 'gen:animacion', label: 'Animación'),
    (id: 'gen:drama', label: 'Drama'),
    (id: 'gen:fantasia', label: 'Fantasía'),
    (id: 'gen:aventura', label: 'Aventura'),
    (id: 'gen:ciencia-ficcion', label: 'Sci-Fi'),
    (id: 'gen:dorama', label: 'Doramas'),
    (id: 'gen:familia', label: 'Familia'),
    (id: 'gen:documental', label: 'Documentales'),
    (id: 'gen:belica', label: 'Bélica'),
  ];

  @override
  void initState() {
    super.initState();
    _scrollCtl.addListener(_onScroll);
    TvTasteProfileService.instance.addListener(_onTasteUpdated);
    _loadPage(page: 1, reset: true);
  }

  @override
  void dispose() {
    TvTasteProfileService.instance.removeListener(_onTasteUpdated);
    _debounce?.cancel();
    _scrollCtl.dispose();
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onTasteUpdated() {
    if (!mounted ||
        _selectedCategory != 'para_ti' ||
        _searchCtl.text.trim().isNotEmpty ||
        _items.isEmpty) {
      return;
    }
    setState(() {
      _items = _rankSeriesForUser(_items);
    });
  }

  List<VodItem> _rankSeriesForUser(List<VodItem> list) {
    final taste = TvTasteProfileService.instance;
    final summary = taste.computeSummary();
    final history = WatchHistory().items;
    final scored = list
        .map((it) => MapEntry(
              it,
              taste.scoreItem(
                it,
                summary: summary,
                history: history,
                applyImpressionPenalty: false,
              ),
            ))
        .toList();
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).toList();
  }

  Future<List<VodItem>> _fetchPersonalizedSeriesPage(int page) async {
    await TvTasteProfileService.instance.load();
    final taste = TvTasteProfileService.instance;
    final summary = taste.computeSummary();
    final futures = <Future<List<VodItem>>>[
      _catalog.getSeries(page: page, category: 'recientes'),
      _catalog.getSeries(page: page, category: 'populares'),
    ];
    if (page == 1) {
      for (final g in summary.topGenres(2)) {
        final slug = TvTasteProfileService.toSeriesCategorySlug(g.key);
        if (slug != null) {
          futures.add(_catalog.getSeries(page: 1, category: slug));
          break;
        }
      }
    }
    final batches = await Future.wait(
      futures.map((f) => f.catchError((_) => const <VodItem>[])),
    );
    final merged = VodCatalogService.groupByShowStateless([
      for (final b in batches) ...b,
    ]);
    return _rankSeriesForUser(merged);
  }

  void _onScroll() {
    if (_scrollCtl.position.pixels >=
            _scrollCtl.position.maxScrollExtent - 600 &&
        !_loadingMore &&
        !_loading &&
        _hasMore) {
      _loadMore();
    }
  }

  Future<void> _loadPage({required int page, bool reset = false}) async {
    final token = ++_requestToken;
    if (reset) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _hasMore = true;
        _currentPage = page;
      });
    }

    final newItems = _selectedCategory == 'para_ti'
        ? await _fetchPersonalizedSeriesPage(page)
        : await _catalog.getSeries(
            page: page,
            category: _selectedCategory,
          );
    final cayoLaRed = _catalog.ultimoErrorDeRed;
    if (!mounted || token != _requestToken) return;
    setState(() {
      _falloDeRed = cayoLaRed;
      if (reset) {
        _items = newItems;
        _hasMore = newItems.length >= 10;
        _loading = false;
      } else {
        final existingIds = _items.map((i) => i.id).toSet();
        final added = newItems.where((i) => !existingIds.contains(i.id)).toList();
        _items.addAll(added);
        _hasMore = added.isNotEmpty;
        _loadingMore = false;
      }
    });
    unawaited(
      ArtworkCacheService.instance.prefetchUrls(
        newItems.map((e) => e.poster),
        tier: ArtworkTier.poster,
        maxConcurrent: 6,
        limit: 24,
      ),
    );
  }

  Future<void> _loadMore() async {
    if (_searchCtl.text.trim().isNotEmpty || !_hasMore) return;
    setState(() => _loadingMore = true);
    _currentPage++;
    await _loadPage(page: _currentPage, reset: false);
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      _loadPage(page: 1, reset: true);
      return;
    }
    if (q.length < 2) return;

    final token = ++_requestToken;
    _debounce = Timer(const Duration(milliseconds: 520), () async {
      if (!mounted || token != _requestToken) return;
      setState(() => _loading = true);
      final results = await _catalog.searchSeries(q);
      if (!mounted || token != _requestToken) return;
      setState(() {
        _items = results;
        _hasMore = false;
        _loading = false;
      });
      unawaited(
        ArtworkCacheService.instance.prefetchUrls(
          results.map((e) => e.poster),
          tier: ArtworkTier.poster,
          maxConcurrent: TvModeService.instance.isTv ? 3 : 5,
          limit: TvModeService.instance.isTv ? 12 : 18,
        ),
      );
    });
  }

  void _showDetails(VodItem item) {
    final similar = _items.where((m) => m.id != item.id).take(8).toList();
    VodDetailModal.show(
      context,
      item,
      recommendations: similar,
      onSelectSimilar: _showDetails,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = TvModeService.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final columns = screenWidth > 900 ? 6 : (screenWidth > 600 ? 4 : 3);
    final accent = AppColors.accentFor(context);
    final subColor = AppColors.contentSubtitleFor(context);

    return Column(
      children: [
        if (isTv)
          const SizedBox(height: 14)
        else
          Padding(
          padding: const EdgeInsets.fromLTRB(
            appPagePaddingHorizontal,
            12,
            appPagePaddingHorizontal,
            10,
          ),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.inputSurfaceFor(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.cardBorderFor(context),
                width: 0.8,
              ),
            ),
            child: TextField(
              controller: _searchCtl,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              style: TextStyle(
                color: AppColors.contentHeadingFor(context),
                fontSize: 13.5,
              ),
              decoration: InputDecoration(
                filled: false,
                hintText: 'Buscar series en HD...',
                hintStyle: TextStyle(color: subColor, fontSize: 13),
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(12),
                  child: InutilIcon(
                    InutilGlyph.search,
                    size: 18,
                    color: subColor,
                  ),
                ),
                suffixIcon: _searchCtl.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.close_rounded, color: subColor, size: 18),
                        onPressed: () {
                          _searchCtl.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
        ),

        // Píldoras de categoría de Series verificadas
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: appPagePaddingHorizontal,
            ),
            itemCount: _categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, idx) {
              final cat = _categories[idx];
              final active = _selectedCategory == cat.id &&
                  _searchCtl.text.trim().isEmpty;
              return TvFocusable(
                onTap: () {
                  if (_selectedCategory == cat.id &&
                      _searchCtl.text.trim().isEmpty) {
                    return;
                  }
                  _searchCtl.clear();
                  setState(() => _selectedCategory = cat.id);
                  _loadPage(page: 1, reset: true);
                },
                borderRadius: BorderRadius.circular(18),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active
                        ? accent
                        : AppColors.elevatedSurfaceFor(context),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: active ? accent : AppColors.cardBorderFor(context),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    cat.label,
                    style: TextStyle(
                      color: active ? AppColors.onAccentFor(context) : subColor,
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 8),

        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: appPagePaddingHorizontal,
            vertical: 2,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _searchCtl.text.trim().isNotEmpty
                    ? 'Resultados'
                    : _categories
                        .firstWhere((c) => c.id == _selectedCategory)
                        .label,
                style: appListCardTitleStyle(context),
              ),
              Text(
                '${_items.length} series',
                style: TextStyle(
                  color: subColor,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        Expanded(
          child: _loading
              ? _buildSkeletonGrid(context, columns)
              : _items.isEmpty
                  ? _buildEmptyState(context)
                  : RefreshIndicator(
                      color: accent,
                      backgroundColor: AppColors.elevatedSurfaceFor(context),
                      onRefresh: () {
                        _catalog.clearPageCaches();
                        return _loadPage(page: 1, reset: true);
                      },
                      child: GridView.builder(
                        controller: _scrollCtl,
                        cacheExtent: 900,
                        addAutomaticKeepAlives: false,
                        padding: const EdgeInsets.fromLTRB(
                          appPagePaddingHorizontal,
                          4,
                          appPagePaddingHorizontal,
                          112,
                        ),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          childAspectRatio: 0.56,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 14,
                        ),
                        itemCount: _items.length + (_loadingMore ? columns : 0),
                        itemBuilder: (context, index) {
                          if (index >= _items.length) {
                            return _buildShimmerItem(context);
                          }
                          final item = _items[index];
                          return PosterCard(
                            key: ValueKey(item.id),
                            item: item,
                            expandInGrid: true,
                            onTap: () => _showDetails(item),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildSkeletonGrid(BuildContext context, int columns) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        appPagePaddingHorizontal,
        4,
        appPagePaddingHorizontal,
        112,
      ),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: 0.56,
        crossAxisSpacing: 10,
        mainAxisSpacing: 14,
      ),
      itemCount: columns * 3,
      itemBuilder: (_, __) => _buildShimmerItem(context),
    );
  }

  Widget _buildShimmerItem(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.elevatedSurfaceFor(context),
        borderRadius: BorderRadius.circular(appArtworkRadius),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final buscando = _searchCtl.text.trim().isNotEmpty;
    return CatalogEmptyState(
      fallaRed: _falloDeRed && !buscando,
      onRetry: _reintentar,
      tituloSinResultados: 'No se encontraron series',
      icono: InutilGlyph.series,
    );
  }

  /// Vuelve a la red tras un catálogo que no llegó (descarta los cachés).
  Future<void> _reintentar() async {
    _catalog.clearPageCaches();
    setState(() {
      _loading = true;
      _falloDeRed = false;
    });
    await _loadPage(page: 1, reset: true);
  }
}
