import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/artwork_cache_service.dart';
import '../services/play_target.dart';
import '../services/tv_mode_service.dart';
import '../services/tv_remote_service.dart';
import '../services/tv_taste_profile_service.dart';
import '../services/vod_catalog_service.dart';
import '../services/xuper_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_ui.dart';
import '../theme/inutil_icons.dart';
import '../widgets/fast_artwork.dart';
import '../widgets/inutil_tv_keyboard.dart';
import '../widgets/poster_card.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/vod_detail_modal.dart';
import 'player_screen.dart';

/// Búsqueda global unificada de InútilTV v3.0 (Cine, Series, Anime y TV en Vivo).
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  /// Inyecta texto en el buscador activo desde el control remoto del celular.
  static void injectText(String text) => _SearchScreenState.injectText(text);

  /// Envía el formulario de búsqueda (quita foco del campo).
  static void submitSearch() => _SearchScreenState.submitSearch();

  /// Limpia el campo de búsqueda.
  static void clearSearch() => _SearchScreenState.clearSearch();

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  /// Registry estático para inyección de texto remoto desde el control del celular.
  static _SearchScreenState? _activeInstance;

  static void injectText(String text) {
    _activeInstance?._controller.text = text;
    _activeInstance?._runSearchNow(text);
  }

  static void submitSearch() {
    final inst = _activeInstance;
    if (inst == null) return;
    inst._runSearchNow(inst._controller.text, moveFocusToResults: true);
  }

  static void clearSearch() {
    _activeInstance?._controller.clear();
    _activeInstance?._runSearchNow('');
  }

  final _catalog = VodCatalogService();
  final _xuper = XuperService();
  final _controller = TextEditingController();
  final _firstFilterFocus = FocusNode(debugLabel: 'searchFirstFilter');
  late final FocusNode _searchFocus = TvFocusable.createTextFieldFocusNode(
    controller: _controller,
  );
  final ValueNotifier<bool> _hasText = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _searchingNotifier = ValueNotifier<bool>(false);
  bool _tvKeyboardVisible = false;

  List<VodItem> _matchedVod = [];
  List<Channel> _allChannels = [];
  List<Channel> _matchedChannels = [];
  String _activeQuery = '';
  int _requestToken = 0;
  Timer? _debounce;

  String _selectedFilter = 'Todos';
  static const List<String> _filters = [
    'Todos',
    'Películas',
    'Series',
    'Anime',
    'Canales TV',
  ];

  List<VodItem> get _filteredVod {
    switch (_selectedFilter) {
      case 'Películas':
        return _matchedVod.where((it) => !it.isSeries && !it.isAnime).toList();
      case 'Series':
        return _matchedVod.where((it) => it.isSeries && !it.isAnime).toList();
      case 'Anime':
        return _matchedVod.where((it) => it.isAnime).toList();
      case 'Canales TV':
        return [];
      default:
        return _matchedVod;
    }
  }

  List<Channel> get _filteredChannels {
    if (_selectedFilter == 'Películas' ||
        _selectedFilter == 'Series' ||
        _selectedFilter == 'Anime') {
      return [];
    }
    return _matchedChannels;
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _SearchScreenState._activeInstance = this;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _searchFocus.dispose();
    _firstFilterFocus.dispose();
    _hasText.dispose();
    _searchingNotifier.dispose();
    if (_SearchScreenState._activeInstance == this) {
      _SearchScreenState._activeInstance = null;
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final token = ++_requestToken;
    final channels = await _xuper.getLiveChannels();
    if (!mounted || token != _requestToken) return;
    setState(() {
      _allChannels = channels;
      _matchedChannels = channels.take(8).toList();
    });
    final pop = await _catalog.getMovies(page: 1, genre: 'tendencias');
    if (!mounted || token != _requestToken) return;
    final slice = pop.take(18).toList();
    setState(() => _matchedVod = slice);
    final isTv = TvModeService.instance.isTv;
    unawaited(
      ArtworkCacheService.instance.prefetchUrls(
        slice.map((e) => e.poster),
        tier: ArtworkTier.poster,
        maxConcurrent: isTv ? 3 : 5,
        limit: isTv ? 12 : 18,
      ),
    );
  }

  /// Al escribir:
  /// - CERO `setState` de la pantalla completa por tecla (actualiza solo el
  ///   icono de limpiar vía `ValueNotifier`), para que el teclado de Google TV
  ///   jamás se trabe ni pierda fluidez.
  /// - En Smart TV / Google TV NO dispara raspado de red en cada letra: busca
  ///   al pulsar "Buscar / ✓" en el teclado (o tras una pausa larga si usa el
  ///   teclado interno opcional), liberando el 100% de CPU para escribir suave.
  void _onSearchChanged(String query) {
    _debounce?.cancel();
    final q = query.trim();
    if (_hasText.value != q.isNotEmpty) {
      _hasText.value = q.isNotEmpty;
    }

    if (q.isEmpty) {
      _searchingNotifier.value = false;
      if (_activeQuery.isNotEmpty) {
        _activeQuery = '';
        setState(() {
          _matchedChannels = _allChannels.take(8).toList();
        });
        _bootstrap();
      }
      return;
    }

    final isTv = TvModeService.instance.isTv;
    // En Google TV con teclado nativo: esperar a que el usuario pulse Buscar/✓
    // (cero trabajo pesado mientras navega teclas en Gboard TV).
    if (isTv && !_tvKeyboardVisible) {
      return;
    }

    // Con teclado interno opcional o en celular: debounce prudente y mín. 2-3 letras
    final minChars = isTv ? 3 : 2;
    if (q.length < minChars) return;
    final wait = isTv
        ? const Duration(milliseconds: 1100)
        : const Duration(milliseconds: 480);
    _debounce = Timer(wait, () => _runSearchNow(q));
  }

  Future<void> _runSearchNow(
    String rawQuery, {
    bool moveFocusToResults = false,
  }) async {
    _debounce?.cancel();
    final q = rawQuery.trim();
    if (_hasText.value != q.isNotEmpty) {
      _hasText.value = q.isNotEmpty;
    }
    if (q.isEmpty) {
      _searchingNotifier.value = false;
      _activeQuery = '';
      setState(() {
        _matchedChannels = _allChannels.take(8).toList();
      });
      await _bootstrap();
      return;
    }

    final token = ++_requestToken;
    _searchingNotifier.value = true;
    final lower = q.toLowerCase();
    final matchedCh = _allChannels
        .where((c) =>
            c.name.toLowerCase().contains(lower) ||
            c.group.toLowerCase().contains(lower))
        .take(12)
        .toList();

    final vodResults = await _catalog.search(q);
    if (!mounted || token != _requestToken) return;

    _activeQuery = q;
    _searchingNotifier.value = false;
    setState(() {
      _matchedChannels = matchedCh;
      _matchedVod = vodResults;
    });

    if (moveFocusToResults && mounted) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      _firstFilterFocus.requestFocus();
    }

    if (q.length >= 2) {
      unawaited(
        TvTasteProfileService.instance.recordSearch(
          q,
          topResults: vodResults,
        ),
      );
    }
    final isTv = TvModeService.instance.isTv;
    unawaited(
      ArtworkCacheService.instance.prefetchUrls(
        vodResults.map((e) => e.poster),
        tier: ArtworkTier.poster,
        maxConcurrent: isTv ? 3 : 5,
        limit: isTv ? 12 : 18,
      ),
    );
  }

  void _showDetails(VodItem item) {
    VodDetailModal.show(context, item);
  }

  void _playChannel(Channel ch) {
    if (ch.sources.isEmpty) return;

    // "Destino: TV" activo → la señal sintoniza en la Smart TV.
    if (PlayTarget.isTvDestination(context)) {
      unawaited(_playChannelOnTv(ch));
      return;
    }

    _openChannelPlayer(ch);
  }

  Future<void> _playChannelOnTv(Channel ch) async {
    final ok = await PlayTarget.sendChannel(ch);
    if (!mounted) return;
    PlayTarget.report(context, ok: ok);
    if (ok) {
      unawaited(TvRemoteService.instance.refreshTvStateNow());
    } else {
      _openChannelPlayer(ch);
    }
  }

  void _openChannelPlayer(Channel ch) {
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
          channelList: _filteredChannels,
          initialChannelIndex:
              _filteredChannels.indexWhere((c) => c.id == ch.id).clamp(0, 999),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final columns = screenWidth > 900 ? 6 : (screenWidth > 600 ? 4 : 3);
    final accent = AppColors.accentFor(context);
    final onAccent = AppColors.onAccentFor(context);
    final surface = AppColors.cardSurfaceFor(context);
    final border = AppColors.cardBorderFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final headingColor = AppColors.contentHeadingFor(context);

    final isTv = TvModeService.of(context);
    final useOnScreenKeyboard = _tvKeyboardVisible;
    final filteredVod = _filteredVod;
    final filteredChannels = _filteredChannels;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: headingColor, size: 22),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Container(
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.inputSurfaceFor(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: border, width: 0.8),
            ),
            child: TextField(
              controller: _controller,
              focusNode: _searchFocus,
              autofocus: !useOnScreenKeyboard,
              readOnly: useOnScreenKeyboard,
              showCursor: true,
              textInputAction: TextInputAction.search,
              onChanged: _onSearchChanged,
              onSubmitted: (value) =>
                  _runSearchNow(value, moveFocusToResults: true),
              style: TextStyle(color: headingColor, fontSize: 13.5),
              decoration: InputDecoration(
                filled: false,
                hintText: isTv
                    ? 'Escribe y pulsa Buscar en el teclado...'
                    : 'Buscar películas, series, anime o canales...',
                hintStyle: TextStyle(color: subColor, fontSize: 12.5),
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(11),
                  child: InutilIcon(
                    InutilGlyph.search,
                    size: 18,
                    color: subColor,
                  ),
                ),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: _searchingNotifier,
                      builder: (context, isSearching, _) {
                        if (isSearching) {
                          return Padding(
                            padding: const EdgeInsets.all(12),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                color: accent,
                                strokeWidth: 2,
                              ),
                            ),
                          );
                        }
                        return ValueListenableBuilder<bool>(
                          valueListenable: _hasText,
                          builder: (context, hasText, _) {
                            if (!hasText) return const SizedBox.shrink();
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isTv)
                                  IconButton(
                                    tooltip: 'Buscar ahora',
                                    icon: Icon(
                                      Icons.search_rounded,
                                      color: accent,
                                      size: 20,
                                    ),
                                    onPressed: () => _runSearchNow(
                                      _controller.text,
                                      moveFocusToResults: true,
                                    ),
                                  ),
                                IconButton(
                                  icon: Icon(
                                    Icons.close_rounded,
                                    color: subColor,
                                    size: 18,
                                  ),
                                  onPressed: () {
                                    _controller.clear();
                                    _runSearchNow('');
                                  },
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                    IconButton(
                      tooltip: _tvKeyboardVisible
                          ? 'Ocultar teclado en pantalla'
                          : 'Teclado para control remoto',
                      icon: Icon(
                        _tvKeyboardVisible
                            ? Icons.keyboard_hide_rounded
                            : Icons.keyboard_alt_outlined,
                        color: _tvKeyboardVisible ? accent : subColor,
                        size: 19,
                      ),
                      onPressed: () {
                        setState(() => _tvKeyboardVisible = !_tvKeyboardVisible);
                        if (_tvKeyboardVisible) {
                          SystemChannels.textInput
                              .invokeMethod<void>('TextInput.hide');
                        } else {
                          _searchFocus.requestFocus();
                          SystemChannels.textInput
                              .invokeMethod<void>('TextInput.show');
                        }
                      },
                    ),
                  ],
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ),
      ),
      body: CustomScrollView(
        cacheExtent: isTv ? 260 : 500,
        slivers: [
          if (_tvKeyboardVisible)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  appPagePaddingHorizontal,
                  4,
                  appPagePaddingHorizontal,
                  8,
                ),
                child: InutilTvKeyboard(
                  controller: _controller,
                  mode: InutilTvKeyboardMode.search,
                  autofocusFirstKey: true,
                  onChanged: _onSearchChanged,
                  onSubmit: () => _runSearchNow(
                    _controller.text,
                    moveFocusToResults: true,
                  ),
                  onMoveDownToResults: () => _firstFilterFocus.requestFocus(),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 46,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: appPagePaddingHorizontal,
                  vertical: 6,
                ),
                itemCount: _filters.length,
                itemBuilder: (context, idx) {
                  final f = _filters[idx];
                  final isSelected = _selectedFilter == f;
                  return TvFocusable(
                    focusNode: idx == 0 ? _firstFilterFocus : null,
                    onTap: () => setState(() => _selectedFilter = f),
                    borderRadius: BorderRadius.circular(18),
                    margin: const EdgeInsets.only(right: 8),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected ? accent : surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isSelected ? accent : border,
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        f,
                        style: TextStyle(
                          color: isSelected ? onAccent : subColor,
                          fontSize: 12,
                          fontWeight:
                              isSelected ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (filteredChannels.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  appPagePaddingHorizontal,
                  14,
                  appPagePaddingHorizontal,
                  8,
                ),
                child: Text(
                  'Canales en Vivo',
                  style: appSectionTitleStyle(context),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 76,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: appPagePaddingHorizontal,
                    vertical: 4,
                  ),
                  itemCount: filteredChannels.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, i) {
                    final ch = filteredChannels[i];
                    return TvFocusable(
                      onTap: () => _playChannel(ch),
                      borderRadius: BorderRadius.circular(14),
                      focusScale: 1.03,
                      child: Container(
                        width: 170,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: border, width: 0.8),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(8),
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
                                        size: 18,
                                      ),
                                    )
                                  : Icon(Icons.tv_rounded,
                                      color: subColor, size: 18),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    ch.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: headingColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    ch.group,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: subColor,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
          if (_selectedFilter != 'Canales TV') ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  appPagePaddingHorizontal,
                  18,
                  appPagePaddingHorizontal,
                  10,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _activeQuery.isEmpty
                          ? 'Tendencias'
                          : 'Resultados ($_selectedFilter)',
                      style: appSectionTitleStyle(context),
                    ),
                    Text(
                      '${filteredVod.length}',
                      style: TextStyle(
                        color: subColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (filteredVod.isEmpty && !_searchingNotifier.value)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Center(
                    child: Column(
                      children: [
                        InutilIcon(InutilGlyph.search, size: 42, color: subColor),
                        const SizedBox(height: 12),
                        Text(
                          'Sin resultados para "$_activeQuery"',
                          textAlign: TextAlign.center,
                          style: appListCardSubtitleStyle(context),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  appPagePaddingHorizontal,
                  0,
                  appPagePaddingHorizontal,
                  36,
                ),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    childAspectRatio: 0.56,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: filteredVod.length,
                  itemBuilder: (context, i) {
                    final it = filteredVod[i];
                    return PosterCard(
                      key: ValueKey(it.id),
                      item: it,
                      expandInGrid: true,
                      onTap: () => _showDetails(it),
                    );
                  },
                ),
              ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}
