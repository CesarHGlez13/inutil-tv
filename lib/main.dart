import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide Playable;

import 'models/models.dart';
import 'screens/anime_screen.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_tab.dart';
import 'screens/movies_screen.dart';
import 'screens/player_screen.dart';
import 'screens/search_screen.dart';
import 'screens/series_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/tv_screen.dart';
import 'services/app_settings_service.dart';
import 'services/artwork_cache_service.dart';
import 'services/firebase_auth_service.dart';
import 'services/inutil_cloud_backup_service.dart';
import 'services/inutil_promo_popup_service.dart';
import 'services/my_list_service.dart';
import 'services/network_config_service.dart';
import 'services/offline_vault_service.dart';
import 'services/tv_mode_service.dart';
import 'services/tv_remote_service.dart';
import 'services/vod_catalog_service.dart';
import 'services/xuper_service.dart';
import 'theme/app_colors.dart';
import 'theme/app_ui.dart';
import 'theme/inutil_icons.dart';
import 'widgets/glass_surface.dart';
import 'widgets/inutil_auth_gate.dart';
import 'widgets/inutil_onboarding_tour.dart';
import 'widgets/inutil_support_popup.dart';
import 'widgets/inutil_update_gate.dart';
import 'widgets/tv_focusable.dart';
import 'widgets/tv_remote_sheet.dart';

/// Altura visible de la barra de navegación flotante (cápsula de 5 secciones
/// + botón circular de Búsqueda de 56 dp). Medido sobre captura real en
/// Xiaomi (1080x2400 @420dpi): 142 px físicos ≈ 54 dp → 58 dp con holgura.
const double _kLiquidNavHeight = 58;

/// Separación vertical entre la barra de navegación y el FAB del control
/// remoto, para que nunca queden "empalmados".
const double _kFabNavGap = 14;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Red tolerante a restricciones (DNS seguro / proxy de empresa). Debe
  // instalarse antes de la primera petición, incluida la caché de carátulas.
  NetworkConfigService.instance.installGlobalOverride();
  unawaited(NetworkConfigService.instance.load());
  unawaited(TvModeService.instance.initialize());
  MediaKit.ensureInitialized();
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 400;
  imageCache.maximumSizeBytes = 96 * 1024 * 1024;
  ArtworkCacheService.instance.initialize();
  runApp(const InutilTvApp());
}

class InutilTvApp extends StatefulWidget {
  const InutilTvApp({super.key});

  @override
  State<InutilTvApp> createState() => _InutilTvAppState();
}

class _InutilTvAppState extends State<InutilTvApp> {
  final _settings = AppSettingsService.instance;

  @override
  void initState() {
    super.initState();
    _settings.load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_settings, TvModeService.instance]),
      builder: (context, _) {
        final accent = _settings.accent;
        final surface = _settings.surfaceMode;
        return MaterialApp(
          title: 'InútilTV',
          debugShowCheckedModeBanner: false,
          // Mapeo global del botón OK (`select`) y botón A de controles Android TV
          // para que cualquier botón/diálogo Material responda al control remoto.
          shortcuts: <ShortcutActivator, Intent>{
            ...WidgetsApp.defaultShortcuts,
            const SingleActivator(LogicalKeyboardKey.select):
                const ActivateIntent(),
            const SingleActivator(LogicalKeyboardKey.gameButtonA):
                const ActivateIntent(),
          },
          themeMode: _settings.themeMode.materialMode,
          theme: AppColors.buildLightTheme(
            accent: accent,
            surfaceBackgroundMode: surface,
          ),
          darkTheme: AppColors.buildDarkTheme(
            accent: accent,
            surfaceBackgroundMode: surface,
          ),
          home: const InutilUpdateGate(
            child: InutilAuthGate(child: MainScaffold()),
          ),
        );
      },
    );
  }
}

/// Shell principal de InútilTV v3.0 — diseñado 1:1 con el lenguaje visual de
/// Inútil Music:
/// - App 100% para usuario (administración exclusivamente desde Firebase Web).
/// - Encabezado editorial limpio con título tipográfico + acceso a Ajustes.
/// - Cápsula inferior flotante Liquid Glass con glifos geométricos [InutilIcon]
///   y botón circular independiente de búsqueda (firma visual de la familia Inútil).
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _navIndex = 0;
  final Set<int> _mountedTabs = {0};
  bool _tvRailFocused = false;
  final FocusNode _tvContentContainerNode = FocusNode(
    debugLabel: 'tv_content_area',
    canRequestFocus: false,
  );
  final FocusNode _tvRailContainerNode = FocusNode(
    debugLabel: 'tv_side_rail',
    canRequestFocus: false,
  );

  static const _tabs = [
    (label: 'Inicio', title: 'InútilTV', glyph: InutilGlyph.home),
    (label: 'En Vivo', title: 'TV en Vivo', glyph: InutilGlyph.liveTv),
    (label: 'Cine', title: 'Películas', glyph: InutilGlyph.movies),
    (label: 'Series', title: 'Series', glyph: InutilGlyph.series),
    (label: 'Anime', title: 'Anime', glyph: InutilGlyph.anime),
  ];

  Timer? _promoPopupTimer;

  @override
  void initState() {
    super.initState();
    AppSettingsService.instance.load();
    MyListService.instance.load();
    OfflineVaultService.instance.initialize();
    XuperService().initialize();
    // Deja listos los respaldos del catálogo (empaquetado + última copia
    // buena) mientras arranca la sesión, para que Cine, Series y Anime nunca
    // aparezcan vacíos si la red del usuario no deja entrar a los servidores.
    unawaited(VodCatalogService().initialize());
    TvRemoteService.instance.registerTvLaunchHandler(_handleRemoteTvLaunch);
    TvRemoteService.instance.registerSystemNavigationHandler(_handleRemoteNavigation);
    TvRemoteService.instance.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_runPostAuthExperience());
    });
  }

  @override
  void dispose() {
    _promoPopupTimer?.cancel();
    _tvContentContainerNode.dispose();
    _tvRailContainerNode.dispose();
    TvRemoteService.instance.registerTvLaunchHandler(null);
    TvRemoteService.instance.registerSystemNavigationHandler(null);
    TvRemoteService.instance.stop();
    InutilTvCloudBackupService.instance.stopAutoSync();
    super.dispose();
  }

  /// Abre en la Smart TV la película, episodio o canal enviado desde el celular.
  void _handleRemoteTvLaunch(TvRemoteCommand cmd) {
    if (!mounted) return;
    final nav = Navigator.of(context);
    // Si ya había un reproductor abierto, lo cerramos para evitar doble audio.
    nav.popUntil((route) => route.isFirst);

    if (cmd.action == 'play_vod') {
      final rawItem = cmd.payload['item'];
      if (rawItem is! Map<String, dynamic>) return;
      final item = VodItem.fromJson(rawItem);
      final rawEp = cmd.payload['episode'];
      final ep = rawEp is Map<String, dynamic> ? VodEpisode.fromJson(rawEp) : null;
      final posSec = (cmd.payload['positionSec'] as num?)?.toInt() ?? 0;

      nav.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            title: ep != null ? '${item.title} · ${ep.title}' : item.title,
            subtitle: item.genre.isNotEmpty ? item.genre : item.year,
            posterUrl: item.poster,
            playables: ep != null
                ? ep.sources
                    .map(
                      (s) => Playable(
                        s.server.isNotEmpty ? s.server : s.quality,
                        s.url,
                        headers: s.headers,
                        subtitles: s.subtitles,
                      ),
                    )
                    .toList()
                : item.sources
                    .map(
                      (s) => Playable(
                        s.server.isNotEmpty ? s.server : s.quality,
                        s.url,
                        headers: s.headers,
                        subtitles: s.subtitles,
                      ),
                    )
                    .toList(),
            vodItem: item,
            episodeList: ep != null ? [ep] : null,
            initialEpisodeIndex: 0,
            initialPosition: posSec > 5 ? Duration(seconds: posSec) : null,
          ),
        ),
      );
    } else if (cmd.action == 'play_channel') {
      final rawCh = cmd.payload['channel'];
      if (rawCh is! Map<String, dynamic>) return;
      final ch = Channel.fromJson(rawCh);
      nav.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            title: ch.name,
            subtitle: ch.group,
            posterUrl: ch.logo,
            playables: ch.sources
                .map(
                  (s) => Playable(
                    s.server.isNotEmpty ? s.server : s.quality,
                    s.url,
                    headers: s.headers,
                    subtitles: s.subtitles,
                  ),
                )
                .toList(),
            channelList: [ch],
            initialChannelIndex: 0,
          ),
        ),
      );
    }
  }

  void _simulateKey(LogicalKeyboardKey key) {
    try {
      ServicesBinding.instance.keyEventManager.handleKeyData(
        ui.KeyData(
          timeStamp:
              Duration(milliseconds: DateTime.now().millisecondsSinceEpoch),
          type: ui.KeyEventType.down,
          physical: 0,
          logical: key.keyId,
          character: null,
          synthesized: true,
        ),
      );
      ServicesBinding.instance.keyEventManager.handleKeyData(
        ui.KeyData(
          timeStamp:
              Duration(milliseconds: DateTime.now().millisecondsSinceEpoch + 15),
          type: ui.KeyEventType.up,
          physical: 0,
          logical: key.keyId,
          character: null,
          synthesized: true,
        ),
      );
    } catch (_) {}
  }

  /// Ejecuta acciones del control remoto móvil sobre la navegación y menú de la Smart TV.
  void _handleRemoteNavigation(TvRemoteCommand cmd) {
    if (!mounted) return;
    debugPrint('📺 [MainScaffold] Ejecutando navegación remota: ${cmd.action}');
    switch (cmd.action) {
      case 'dpad_up':
        if (FocusManager.instance.primaryFocus == null) _focusTvRail();
        final moved = FocusManager.instance.primaryFocus
            ?.focusInDirection(TraversalDirection.up) ?? false;
        if (!moved) _simulateKey(LogicalKeyboardKey.arrowUp);
        break;
      case 'dpad_down':
        if (FocusManager.instance.primaryFocus == null) _focusTvRail();
        final moved = FocusManager.instance.primaryFocus
            ?.focusInDirection(TraversalDirection.down) ?? false;
        if (!moved) _simulateKey(LogicalKeyboardKey.arrowDown);
        break;
      case 'dpad_left':
        if (FocusManager.instance.primaryFocus == null) _focusTvRail();
        final moved = FocusManager.instance.primaryFocus
            ?.focusInDirection(TraversalDirection.left) ?? false;
        if (!moved) _simulateKey(LogicalKeyboardKey.arrowLeft);
        break;
      case 'dpad_right':
        if (FocusManager.instance.primaryFocus == null) _focusTvRail();
        final moved = FocusManager.instance.primaryFocus
            ?.focusInDirection(TraversalDirection.right) ?? false;
        if (!moved || _tvRailContainerNode.hasFocus) {
          _focusTvContent();
        }
        if (!moved) _simulateKey(LogicalKeyboardKey.arrowRight);
        break;
      case 'dpad_center':
      case 'select':
        final focus = FocusManager.instance.primaryFocus;
        if (focus != null && focus.context != null) {
          Actions.invoke(focus.context!, const ActivateIntent());
        } else {
          _simulateKey(LogicalKeyboardKey.select);
        }
        break;
      case 'back':
        final nav = Navigator.maybeOf(context);
        if (nav != null && nav.canPop()) {
          nav.pop();
        } else if (_navIndex != 0) {
          _selectTab(0);
        } else {
          _simulateKey(LogicalKeyboardKey.goBack);
        }
        break;
      case 'home':
        Navigator.of(context).popUntil((route) => route.isFirst);
        _selectTab(0);
        _focusTvRail();
        break;
      case 'nav_tab':
        final idx = (cmd.payload['index'] as num?)?.toInt() ?? 0;
        if (idx >= 0 && idx < _tabs.length) {
          Navigator.of(context).popUntil((route) => route.isFirst);
          _selectTab(idx);
        }
        break;
      case 'open_search':
        Navigator.of(context).popUntil((route) => route.isFirst);
        _openSearch();
        break;
      case 'keyboard_text':
        final text = (cmd.payload['text'] ?? '').toString();
        SearchScreen.injectText(text);
        break;
      case 'keyboard_submit':
        SearchScreen.submitSearch();
        break;
      case 'keyboard_clear':
        SearchScreen.clearSearch();
        break;
    }
  }

  Future<void> _runPostAuthExperience() async {
    if (InutilAuthService.instance.isOnlineValidationDisabled) return;

    // 1. Restaurar respaldo en la nube si la instalación es nueva + auto-sync
    final backup = InutilTvCloudBackupService.instance;
    if (backup.canSync) {
      unawaited(backup.pullAndRestoreIfEmpty());
      backup.startAutoSync();
    }

    // 2. Recorrido guiado interactivo solo la primera vez
    if (await InutilOnboardingTour.shouldShow()) {
      if (!mounted) return;
      await InutilOnboardingTour.show(
        context,
        inactivityDays: InutilAuthService.instance.inactivityPolicyDays,
      );
      return;
    }

    // 3. Pop-up creativo rotativo de apoyo o aviso remoto de Firebase (sin invadir arranque)
    _promoPopupTimer = Timer(const Duration(seconds: 6), () async {
      if (!mounted) return;
      final campaign =
          await InutilPromoPopupService.instance.evaluateScheduledPopup();
      if (!mounted || campaign == null) return;
      await InutilSupportPopupDialog.show(context, campaign);
    });
  }

  void _selectTab(int index) {
    final safe = index.clamp(0, _tabs.length - 1);
    if (safe == _navIndex) return;
    HapticFeedback.selectionClick();
    AppSettingsService.instance.immersiveLandscape.value = false;
    setState(() {
      _mountedTabs.add(safe);
      _navIndex = safe;
    });
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
  }

  void _openDownloads() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DownloadsScreen()),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isTv = TvModeService.of(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark,
      ),
      child: ValueListenableBuilder<bool>(
        valueListenable: AppSettingsService.instance.immersiveLandscape,
        builder: (context, isImmersive, _) {
          final tabsStack = IndexedStack(
            index: _navIndex,
            children: [
              ExcludeFocus(
                excluding: _navIndex != 0,
                child: HomeTab(
                  isTabActive: _navIndex == 0,
                  onGoLiveTv: () => _selectTab(1),
                  onGoMovies: () => _selectTab(2),
                  onGoSeries: () => _selectTab(3),
                  onGoAnime: () => _selectTab(4),
                ),
              ),
              ExcludeFocus(
                excluding: _navIndex != 1,
                child: _mountedTabs.contains(1)
                    ? TvScreen(isTabActive: _navIndex == 1)
                    : const SizedBox.shrink(),
              ),
              ExcludeFocus(
                excluding: _navIndex != 2,
                child: _mountedTabs.contains(2)
                    ? const MoviesScreen()
                    : const SizedBox.shrink(),
              ),
              ExcludeFocus(
                excluding: _navIndex != 3,
                child: _mountedTabs.contains(3)
                    ? const SeriesScreen()
                    : const SizedBox.shrink(),
              ),
              ExcludeFocus(
                excluding: _navIndex != 4,
                child: _mountedTabs.contains(4)
                    ? const AnimeScreen()
                    : const SizedBox.shrink(),
              ),
            ],
          );

          if (isTv) {
            return PopScope(
              canPop: _navIndex == 0 && _tvRailFocused && !isImmersive,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop || isImmersive) return;
                if (!_tvRailFocused) {
                  // En Smart TV, Atrás desde el catálogo regresa el foco al menú lateral
                  _focusTvRail();
                } else if (_navIndex != 0) {
                  _selectTab(0);
                }
              },
              child: Scaffold(
                backgroundColor: theme.scaffoldBackgroundColor,
                body: SafeArea(
                  child: Row(
                    children: [
                      if (!isImmersive) _buildTvSideRail(context),
                      Expanded(
                        child: Focus(
                          focusNode: _tvContentContainerNode,
                          canRequestFocus: false,
                          child: tabsStack,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return Scaffold(
            backgroundColor: theme.scaffoldBackgroundColor,
            extendBody: true,
            appBar: isImmersive ? null : _buildEditorialHeader(context),
            body: Stack(
              children: [
                tabsStack,
                if (!isImmersive)
                  Positioned(
                    right: 18,
                    // El FAB del control remoto NUNCA puede quedar por debajo
                    // de la barra flotante (Inicio / En vivo / Buscar): se
                    // apila encima del botón circular de Búsqueda.
                    bottom: _liquidNavTopOffset(context),
                    child: _buildFloatingRemoteFab(context),
                  ),
                if (!isImmersive)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _buildFloatingLiquidNav(context),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _focusTvContent() {
    // Mueve el foco al primer elemento enfocable visible del contenido actual
    // (evitando que el menú lateral atrape al usuario).
    final descendants = _tvContentContainerNode.descendants.where(
      (n) => n.canRequestFocus && !n.skipTraversal && n.context != null,
    );
    if (descendants.isNotEmpty) {
      descendants.first.requestFocus();
    }
  }

  void _focusTvRail() {
    final descendants = _tvRailContainerNode.descendants.where(
      (n) => n.canRequestFocus && !n.skipTraversal && n.context != null,
    );
    if (descendants.isNotEmpty) {
      descendants.first.requestFocus();
    }
  }

  /// Menú lateral nativo para Smart TV / Android TV / TV Box (navegable 100%
  /// con D-pad; usa [Focus] en vez de [FocusScope] para NO atrapar el foco y
  /// permite salir libremente hacia el catálogo con Flecha Derecha).
  Widget _buildTvSideRail(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppColors.accentFor(context);
    final headingColor = AppColors.contentHeadingFor(context);
    final subColor = AppColors.contentSubtitleFor(context);
    final expanded = _tvRailFocused;

    return Focus(
      focusNode: _tvRailContainerNode,
      canRequestFocus: false,
      onFocusChange: (hasFocus) {
        if (_tvRailFocused != hasFocus) {
          setState(() => _tvRailFocused = hasFocus);
        }
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          // Intento geométrico primero; si no salta, envía foco directo al contenido
          final moved = FocusManager.instance.primaryFocus
                  ?.focusInDirection(TraversalDirection.right) ??
              false;
          if (!moved || _tvRailContainerNode.hasFocus) {
            _focusTvContent();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOutCubic,
          width: expanded ? 210 : 80,
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border(
              right: BorderSide(
                color: AppColors.dividerFor(context),
                width: 0.9,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showLabels = constraints.maxWidth >= 135;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Marca InútilTV
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 2, 4, 18),
                    child: Row(
                      mainAxisAlignment: showLabels
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      children: [
                        if (showLabels) ...[
                          Flexible(
                            child: Text(
                              'Inútil',
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              softWrap: false,
                              style: appTabTitleStyle(context).copyWith(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.8,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'TV',
                            style: TextStyle(
                              color: AppColors.onAccentFor(context),
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Acceso rápido a Búsqueda
                  _tvRailItem(
                    context,
                    label: 'Buscar',
                    glyph: InutilGlyph.search,
                    selected: false,
                    expanded: showLabels,
                    accent: accent,
                    headingColor: headingColor,
                    subColor: subColor,
                    onTap: _openSearch,
                  ),
                  const SizedBox(height: 6),

                  // Secciones principales
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < _tabs.length; i++) ...[
                            _tvRailItem(
                              context,
                              label: _tabs[i].label,
                              glyph: _tabs[i].glyph,
                              selected: _navIndex == i,
                              expanded: showLabels,
                              accent: accent,
                              headingColor: headingColor,
                              subColor: subColor,
                              autofocus: i == 0 && _navIndex == 0,
                              onTap: () {
                                if (_navIndex == i) {
                                  _focusTvContent();
                                } else {
                                  _selectTab(i);
                                }
                              },
                            ),
                            const SizedBox(height: 4),
                          ],
                        ],
                      ),
                    ),
                  ),

                  Divider(color: AppColors.dividerFor(context), height: 18),

                  // Descargas con badge
                  ListenableBuilder(
                    listenable: OfflineVaultService.instance,
                    builder: (context, _) {
                      final vault = OfflineVaultService.instance;
                      final count = vault.activeCount > 0
                          ? vault.activeCount
                          : vault.completedCount;
                      return _tvRailItem(
                        context,
                        label: count > 0 ? 'Descargas ($count)' : 'Descargas',
                        glyph: InutilGlyph.download,
                        selected: false,
                        expanded: showLabels,
                        accent: accent,
                        headingColor: headingColor,
                        subColor: subColor,
                        onTap: _openDownloads,
                      );
                    },
                  ),
                  const SizedBox(height: 4),

                  // Ajustes
                  _tvRailItem(
                    context,
                    label: 'Ajustes',
                    glyph: InutilGlyph.settings,
                    selected: false,
                    expanded: showLabels,
                    accent: accent,
                    headingColor: headingColor,
                    subColor: subColor,
                    onTap: _openSettings,
                  ),
                ],
              );
            },
          ),
      ),
    );
  }

  Widget _tvRailItem(
    BuildContext context, {
    required String label,
    required InutilGlyph glyph,
    required bool selected,
    required bool expanded,
    required Color accent,
    required Color headingColor,
    required Color subColor,
    required VoidCallback onTap,
    bool autofocus = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TvFocusable(
      autofocus: autofocus,
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      focusScale: 1.03,
      builder: (context, focused, _) {
        final bg = focused
            ? accent.withValues(alpha: isDark ? 0.22 : 0.16)
            : (selected
                ? accent.withValues(alpha: isDark ? 0.14 : 0.11)
                : Colors.transparent);
        final fg = (focused || selected) ? accent : subColor;
        return Container(
          height: 46,
          padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 0),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment:
                expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              InutilIcon(glyph, size: 21, color: fg, filled: selected || focused),
              if (expanded) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: (focused || selected) ? headingColor : subColor,
                      fontSize: 13.5,
                      fontWeight: (focused || selected)
                          ? FontWeight.w800
                          : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Encabezado editorial sobrio (idéntico al ritmo visual de Inútil Music)
  PreferredSizeWidget _buildEditorialHeader(BuildContext context) {
    final theme = Theme.of(context);
    final currentTab = _tabs[_navIndex];
    final headingColor = AppColors.contentHeadingFor(context);

    return PreferredSize(
      preferredSize: const Size.fromHeight(60),
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            border: Border(
              bottom: BorderSide(
                color: AppColors.dividerFor(context),
                width: 0.7,
              ),
            ),
          ),
          child: Row(
            children: [
              if (_navIndex == 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Inútil',
                      style: appTabTitleStyle(context).copyWith(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.9,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6.5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accentFor(context),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        'TV',
                        style: TextStyle(
                          color: AppColors.onAccentFor(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  ],
                )
              else
                Text(
                  currentTab.title,
                  style: appTabTitleStyle(context),
                ),
              const Spacer(),
              // Botón Mi Smart TV / Vincular por QR / Control remoto
              ListenableBuilder(
                listenable: TvRemoteService.instance,
                builder: (context, _) {
                  final online = TvRemoteService.instance.isTvOnline;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _headerActionButton(
                        context,
                        tooltip: online
                            ? 'Controlar mi Smart TV'
                            : 'Vincular Smart TV con QR',
                        onTap: () => TvRemoteSheet.show(context),
                        child: InutilIcon(
                          InutilGlyph.liveTv,
                          size: 20,
                          color: online
                              ? const Color(0xFF18C75A)
                              : headingColor,
                        ),
                      ),
                      if (online)
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: const Color(0xFF18C75A),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: theme.scaffoldBackgroundColor,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(width: 8),
              ListenableBuilder(
                listenable: OfflineVaultService.instance,
                builder: (context, _) {
                  final vault = OfflineVaultService.instance;
                  final badgeCount =
                      vault.activeCount > 0 ? vault.activeCount : vault.completedCount;
                  final isActive = vault.activeCount > 0;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _headerActionButton(
                        context,
                        tooltip: 'Descargas sin conexión',
                        onTap: _openDownloads,
                        child: InutilIcon(
                          InutilGlyph.download,
                          size: 20,
                          color: isActive
                              ? AppColors.accentFor(context)
                              : headingColor,
                        ),
                      ),
                      if (badgeCount > 0)
                        Positioned(
                          top: -2,
                          right: -2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? AppColors.accentFor(context)
                                  : const Color(0xFF18C75A),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              badgeCount > 99 ? '99+' : '$badgeCount',
                              style: TextStyle(
                                color: isActive
                                    ? AppColors.onAccentFor(context)
                                    : Colors.black,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(width: 8),
              _headerActionButton(
                context,
                tooltip: 'Ajustes y Cuenta',
                onTap: _openSettings,
                child: InutilIcon(
                  InutilGlyph.settings,
                  size: 21,
                  color: headingColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerActionButton(
    BuildContext context, {
    required String tooltip,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.cardSurfaceFor(context),
        shape: CircleBorder(
          side: BorderSide(color: AppColors.cardBorderFor(context), width: 0.8),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 40, height: 40, child: Center(child: child)),
        ),
      ),
    );
  }

  /// Cápsula inferior flotante Liquid Glass + botón circular de Búsqueda
  /// (misma silueta icónica que Inútil Music).
  /// Margen inferior real de la barra flotante: es el `SafeArea(minimum:)`
  /// aplicado en [_buildFloatingLiquidNav], es decir `max(mínimo, inset)`
  /// (en MIUI/HyperOS con barra de gestos el inset puede superar los 40 dp).
  double _liquidNavBottomInset(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    final minimum = inset > 0 ? 6.0 : 12.0;
    return inset > minimum ? inset : minimum;
  }

  /// Distancia desde el borde inferior de la pantalla hasta el borde superior
  /// de la barra flotante. Se usa para anclar el FAB del control remoto
  /// SIEMPRE por encima de la barra, sin solapar el botón de Búsqueda.
  double _liquidNavTopOffset(BuildContext context) =>
      _liquidNavBottomInset(context) + _kLiquidNavHeight + _kFabNavGap;

  Widget _buildFloatingLiquidNav(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final accent = AppColors.accentFor(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactiveColor = isDark
        ? Colors.white.withValues(alpha: 0.52)
        : Colors.black.withValues(alpha: 0.52);

    return SafeArea(
      top: false,
      minimum: EdgeInsets.fromLTRB(14, 0, 14, bottomInset > 0 ? 6 : 12),
      child: Row(
        children: [
          // Cápsula principal con las 5 secciones
          Expanded(
            child: GlassSurface(
              borderRadius: BorderRadius.circular(30),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                children: [
                  for (var i = 0; i < _tabs.length; i++)
                    Expanded(
                      child: _navItem(
                        context,
                        label: _tabs[i].label,
                        glyph: _tabs[i].glyph,
                        selected: _navIndex == i,
                        accent: accent,
                        inactiveColor: inactiveColor,
                        onTap: () => _selectTab(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Botón circular flotante independiente de Búsqueda (firma Inútil Music)
          Tooltip(
            message: 'Buscar',
            child: TvFocusable(
              onTap: _openSearch,
              borderRadius: BorderRadius.circular(28),
              child: GlassSurface(
                borderRadius: BorderRadius.circular(28),
                padding: EdgeInsets.zero,
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: Center(
                    child: InutilIcon(
                      InutilGlyph.search,
                      size: 22,
                      color: AppColors.contentHeadingFor(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Botón circular flotante de Control Remoto Smart TV (FAB).
  /// Permite abrir y cerrar el mando con un toque desde cualquier lugar del móvil.
  Widget _buildFloatingRemoteFab(BuildContext context) {
    return ListenableBuilder(
      listenable: TvRemoteService.instance,
      builder: (context, _) {
        final online = TvRemoteService.instance.isTvOnline;
        final playing = TvRemoteService.instance.tvState.isPlaying;

        return Tooltip(
          message: TvRemoteSheet.isOpen
              ? 'Cerrar control remoto'
              : (online ? 'Abrir control remoto Smart TV' : 'Vincular Smart TV con QR'),
          child: TvFocusable(
            onTap: () => TvRemoteSheet.show(context),
            borderRadius: BorderRadius.circular(28),
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF131318).withValues(alpha: 0.90),
                border: Border.all(
                  color: online
                      ? const Color(0xFF18C75A).withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.18),
                  width: online ? 2.0 : 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: online
                        ? const Color(0xFF18C75A).withValues(alpha: 0.35)
                        : Colors.black.withValues(alpha: 0.35),
                    blurRadius: online ? 14 : 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.settings_remote_rounded,
                    size: 25,
                    color: online ? const Color(0xFF18C75A) : Colors.white70,
                  ),
                  if (online)
                    Positioned(
                      top: 9,
                      right: 9,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: playing
                              ? const Color(0xFF18C75A)
                              : const Color(0xFF38BDF8),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: (playing
                                      ? const Color(0xFF18C75A)
                                      : const Color(0xFF38BDF8))
                                  .withValues(alpha: 0.85),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _navItem(
    BuildContext context, {
    required String label,
    required InutilGlyph glyph,
    required bool selected,
    required Color accent,
    required Color inactiveColor,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeBg = selected
        ? (isDark
            ? accent.withValues(alpha: 0.16)
            : accent.withValues(alpha: 0.14))
        : Colors.transparent;
    final fg = selected ? accent : inactiveColor;

    return TvFocusable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      focusScale: 1.02,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        decoration: BoxDecoration(
          color: activeBg,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InutilIcon(glyph, size: 20, color: fg, filled: selected),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 10,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
