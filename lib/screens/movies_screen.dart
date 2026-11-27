import 'dart:async';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/artwork_cache_service.dart';
import '../services/cuevana_poseidon_service.dart';
import '../services/tv_mode_service.dart';
import '../services/vod_catalog_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import '../widgets/catalog_empty_state.dart';
import '../widgets/inutil_tv_keyboard.dart';
import '../widgets/poster_card.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/vod_detail_modal.dart';

/// Catálogo de Películas de InútilTV v3.0 — estética editorial Inútil Music:
/// - Portadas TMDB HD 2:3 con `expandInGrid: true` (CERO empalmes ni 404x.jpg).
/// - Géneros oficiales + Tendencias + Clásicos permanentes.
class MoviesScreen extends StatefulWidget {
  const MoviesScreen({super.key});

  @override
  State<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends State<MoviesScreen> {
  final _catalog = VodCatalogService();
  final _searchCtl = TextEditingController();
  late final FocusNode _searchFocus = TvFocusable.createTextFieldFocusNode(
    controller: _searchCtl,
    tvKeyboardTitle: 'Buscar películas en HD',
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
  String _selectedGenrePath = '';
  String _selectedGenreLabel = 'Estrenos';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scrollCtl.addListener(_onScroll);
    _loadPage(page: 1, reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollCtl.dispose();
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
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

  Future<void> _loadPage({
    required int page,
    bool reset = false,
    String? genre,
  }) async {
    final token = ++_requestToken;
    if (reset) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _hasMore = true;
        _currentPage = page;
        if (genre != null) _selectedGenrePath = genre;
      });
    }

    final newItems = await _catalog.getMovies(
      page: page,
      genre: _selectedGenrePath.isNotEmpty ? _selectedGenrePath : null,
    );
    final cayoLaRed = _catalog.ultimoErrorDeRed;

    if (!mounted || token != _requestToken) return;
    setState(() {
      _falloDeRed = cayoLaRed;
      if (reset) {
        _items = newItems;
        _hasMore = newItems.length >= 12;
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

    setState(() {});
    final token = ++_requestToken;
    _debounce = Timer(const Duration(milliseconds: 320), () async {
      if (!mounted || token != _requestToken) return;
      setState(() => _loading = true);
      final results = await _catalog.searchMovies(q);
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
          maxConcurrent: 6,
          limit: 18,
        ),
      );
    });
  }

  void _onSelectGenre(String path, String label) {
    if (_selectedGenrePath == path) return;
    setState(() {
      _selectedGenrePath = path;
      _selectedGenreLabel = label;
      _searchCtl.clear();
    });
    _loadPage(page: 1, reset: true, genre: path);
  }

  void _showDetails(VodItem item) {
    final similar = _items
        .where((m) => m.id != item.id)
        .take(8)
        .toList();

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
          // Buscador sobrio estilo Inútil Music (en Smart TV se usa el botón Buscar del menú lateral)
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
              readOnly: TvModeService.of(context),
              showCursor: true,
              onTap: TvModeService.of(context)
                  ? () => InutilTvKeyboard.showModal(
                        context,
                        controller: _searchCtl,
                        title: 'Buscar películas en HD',
                        mode: InutilTvKeyboardMode.search,
                        onChanged: _onSearchChanged,
                      )
                  : null,
              onChanged: _onSearchChanged,
              style: TextStyle(
                color: AppColors.contentHeadingFor(context),
                fontSize: 13.5,
              ),
              decoration: InputDecoration(
                filled: false,
                hintText: 'Buscar películas en HD...',
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

        // Chips de género limpios
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: appPagePaddingHorizontal,
            ),
            children: [
              _genreChip(
                context,
                label: 'Estrenos',
                selected: _selectedGenrePath.isEmpty,
                onTap: () => _onSelectGenre('', 'Estrenos'),
              ),
              for (final g in CuevanaPoseidonService.genres)
                _genreChip(
                  context,
                  label: g['label']!,
                  selected: _selectedGenrePath == g['path'],
                  onTap: () => _onSelectGenre(g['path']!, g['label']!),
                ),
              _genreChip(
                context,
                label: 'Clásicos',
                selected: _selectedGenrePath == 'clasicos',
                onTap: () => _onSelectGenre('clasicos', 'Clásicos'),
              ),
            ],
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
                    : _selectedGenreLabel,
                style: appListCardTitleStyle(context),
              ),
              Text(
                '${_items.length} títulos',
                style: TextStyle(
                  color: subColor,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 4),

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
                          6,
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

  Widget _genreChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final subColor = AppColors.contentSubtitleFor(context);

    return TvFocusable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      margin: const EdgeInsets.only(right: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? accent : surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? accent : border,
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? onAccent : subColor,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildSkeletonGrid(BuildContext context, int columns) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        appPagePaddingHorizontal,
        6,
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
      tituloSinResultados: 'No se encontraron películas',
      icono: InutilGlyph.movies,
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
