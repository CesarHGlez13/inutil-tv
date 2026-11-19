import 'dart:async';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/artwork_cache_service.dart';
import '../services/jkanime_service.dart';
import '../services/tv_mode_service.dart';
import '../services/vod_catalog_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import '../widgets/catalog_empty_state.dart';
import '../widgets/poster_card.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/vod_detail_modal.dart';

/// Pestaña dedicada de Anime de InútilTV v3.0 (+5,000 títulos HD):
/// - Portadas HD reales (sin miniaturas borrosas de 60px).
/// - Búsqueda sin sensibilidad a acentos ("dragón ball" encuentra DBZ y Super).
/// - Cuadrícula 2:3 sin empalmes (`expandInGrid: true`) y respaldo automático TioAnime.
class AnimeScreen extends StatefulWidget {
  const AnimeScreen({super.key});

  @override
  State<AnimeScreen> createState() => _AnimeScreenState();
}

class _AnimeScreenState extends State<AnimeScreen> {
  final _catalog = VodCatalogService();
  final _scrollCtl = ScrollController();
  final _searchCtl = TextEditingController();
  late final FocusNode _searchFocus =
      TvFocusable.createTextFieldFocusNode(controller: _searchCtl);

  List<VodItem> _items = [];
  int _page = 1;
  int _requestToken = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _falloDeRed = false;
  bool _hasMore = true;
  bool _isSearching = false;
  String _selectedGenrePath = '';
  String _selectedGenreLabel = 'Populares';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadPage(page: 1, reset: true);
    _scrollCtl.addListener(_onScroll);
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
    if (_isSearching || _loadingMore || _loading || !_hasMore) return;
    if (_scrollCtl.position.pixels >=
        _scrollCtl.position.maxScrollExtent - 600) {
      _loadPage(page: _page + 1);
    }
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

  Future<void> _loadPage({required int page, bool reset = false}) async {
    final token = ++_requestToken;
    if (reset) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _page = 1;
        _hasMore = true;
      });
    } else {
      setState(() => _loadingMore = true);
    }

    final list = await _catalog.getAnime(
      page: page,
      genre: _selectedGenrePath.isEmpty ? null : _selectedGenrePath,
    );
    final cayoLaRed = _catalog.ultimoErrorDeRed;
    if (!mounted || token != _requestToken) return;

    setState(() {
      _falloDeRed = cayoLaRed;
      if (reset) {
        _items = list;
        _hasMore = list.length >= 12;
      } else {
        final seen = _items.map((e) => e.id).toSet();
        final added = list.where((e) => seen.add(e.id)).toList();
        _items.addAll(added);
        _hasMore = added.isNotEmpty;
      }
      _page = page;
      _loading = false;
      _loadingMore = false;
    });
    unawaited(
      ArtworkCacheService.instance.prefetchUrls(
        list.map((e) => e.poster),
        tier: ArtworkTier.poster,
        maxConcurrent: 6,
        limit: 24,
      ),
    );
  }

  void _onSearchChanged(String q) {
    _debounce?.cancel();
    final trimmed = q.trim();
    if (trimmed.isEmpty) {
      setState(() => _isSearching = false);
      _loadPage(page: 1, reset: true);
      return;
    }
    final token = ++_requestToken;
    setState(() {
      _isSearching = true;
      _loading = true;
    });
    _debounce = Timer(const Duration(milliseconds: 320), () async {
      if (!mounted || token != _requestToken) return;
      final results = await _catalog.searchAnime(trimmed);
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
    final w = MediaQuery.of(context).size.width;
    final columns = w > 900 ? 6 : (w > 600 ? 4 : 3);
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
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
              border: Border.all(color: border, width: 0.8),
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
                hintText: 'Buscar anime (Dragon Ball, One Piece, Jujutsu)...',
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

        if (!_isSearching) ...[
          SizedBox(
            height: 36,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: appPagePaddingHorizontal,
              ),
              itemCount: JkAnimeService.genres.length,
              itemBuilder: (context, idx) {
                final g = JkAnimeService.genres[idx];
                final path = g['path']!;
                final label = g['label']!;
                final selected = path == _selectedGenrePath;
                return TvFocusable(
                  onTap: () {
                    setState(() {
                      _selectedGenrePath = path;
                      _selectedGenreLabel = label;
                    });
                    _loadPage(page: 1, reset: true);
                  },
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
              },
            ),
          ),
          const SizedBox(height: 8),
        ],

        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: appPagePaddingHorizontal,
            vertical: 2,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _isSearching
                    ? 'Resultados para "${_searchCtl.text.trim()}"'
                    : '$_selectedGenreLabel · Sub Español',
                style: appListCardTitleStyle(context),
              ),
              Text(
                '${_items.length} animes',
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
              ? Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      color: accent,
                      strokeWidth: 2.2,
                    ),
                  ),
                )
              : _items.isEmpty
                  ? CatalogEmptyState(
                      fallaRed: _falloDeRed,
                      onRetry: _reintentar,
                      tituloSinResultados: 'No se encontraron animes',
                      icono: InutilGlyph.anime,
                    )
                  : RefreshIndicator(
                      color: accent,
                      backgroundColor: AppColors.elevatedSurfaceFor(context),
                      onRefresh: () => _loadPage(page: 1, reset: true),
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
                            return Container(
                              decoration: BoxDecoration(
                                color: AppColors.elevatedSurfaceFor(context),
                                borderRadius: BorderRadius.circular(appArtworkRadius),
                              ),
                            );
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
}
