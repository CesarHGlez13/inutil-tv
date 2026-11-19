# Changelog — InútilTV

## 3.3.12 — 2026-11-19
- **Botón Circular Flotante del Control Remoto (FAB):**
  - Incorporado botón flotante circular de control remoto (`52x52` con icono de mando a distancia) en la pantalla móvil, situado cómodamente sobre la barra de navegación para abrir y cerrar el mando con un solo toque desde cualquier pantalla.
  - El botón circular indica el estado en vivo de la Smart TV con iluminación verde y punto de actividad pulsante.
  - Integrado botón circular de mando en la cabecera del modal de detalle junto al botón de cerrar.
  - Eliminada la barra inferior/SnackBar que bloqueaba los gestos e impedía deslizar hacia arriba.
- **Pausa y Detención Automática al Cambiar a Móvil:**
  - Al seleccionar «Móvil» en el selector o al abrir cualquier capítulo/película en el teléfono, la Smart TV se pausa/detiene inmediatamente (`sendPause` / `sendStop`), impidiendo que continúe sonando en la sala.

## 3.3.11 — 2026-11-19
- **Detección Inmediata de Smart TV Cerrada (Cero Falso Positivo):**
  - Implementado `WidgetsBindingObserver` en `TvRemoteService`: cuando la app en la Smart TV se cierra, minimiza o va a segundo plano (`paused`, `detached`, `hidden`), notifica inmediatamente su estado como desconectada (`online: false`) y cierra sus sockets.
  - Detección LAN instantánea de puerto cerrado (`Connection refused` en 38443) en el celular: si la app en la Smart TV está cerrada, el celular no espera 5 minutos ni depende de cachés viejas en la nube; la marca desconectada en menos de 1 segundo.
  - Al estar la TV cerrada, el botón principal en el móvil muestra directamente «Reproducir» o «Continuar» en lugar de «Ver en Smart TV», y oculta el selector hasta que la Smart TV vuelva a abrirse.

## 3.3.10 — 2026-11-19
- **Sincronización Total de Versión y Corrección de Bucle OTA:**
  - Corregida la constante interna `AppInfo.appVersion` a `3.3.10` en estricta sincronización con `pubspec.yaml` (eliminando el falso diálogo de actualización pendiente en inicio).
  - Integrado test unitario de validación estricta para impedir desfasajes futuros entre `pubspec.yaml` y `app_info.dart`.
  - Handoff inteligente celular ⇄ Smart TV verificado con detención automática de reproducción duplicada.
- **Handoff Inteligente Smart TV ⇄ Celular (Cero Duplicidad):**
  - Al cambiar el destino a «Móvil», la Smart TV se pausa automáticamente de inmediato para que no siga sonando en la sala.
  - Al abrir un capítulo o película en el celular, la Smart TV se detiene por completo (`sendStop`), eliminando reproducciones simultáneas y desincronización de títulos.
  - **Transferencia Continua de Tiempo:** al pasar de Smart TV a móvil, el reproductor del teléfono hereda el segundo exacto que estaba sonando en la TV para continuar viendo sin perder el hilo.
- **Detección Automática de IP LAN (`lanHost`) y Enlace Cero Latencia:**
  - La Smart TV autodetecta su dirección IPv4 en la red local (`192.168.x.x`) y la publica directamente en su estado, permitiendo que el celular se conecte de inmediato vía HTTP en menos de 2 ms sin depender de barridos lentos de subred.
  - Prioridad absoluta del enlace LAN sobre la nube: los datos en vivo de la red local jamás son sobreescritos por datos antiguos o desactualizados.
- **Protección Antitormenta de Cuota Firestore (429):**
  - Pausa inteligente del sondeo en la nube ante errores 429 (`RESOURCE_EXHAUSTED`), canalizando el 100% de los controles y estado por la red local a coste y latencia cero.
- **Control Remoto Móvil Perfeccionado:**
  - Botón dedicado «Cerrar / Detener» disponible en todo momento para detener cualquier serie, anime o película en la TV con un solo toque.
  - Limpieza inmediata del estado activo (`clearTvPlayback`) al cerrar el reproductor en la TV.

## 3.3.8 — 2026-11-18
- **Persistencia Inteligente de Destino (Ver en TV vs Móvil):**
  - Conmutador directo de reproducción `[ 📱 Móvil | 📺 Smart TV ]` en la ficha de anime, series y películas con persistencia automática en disco (`SharedPreferences`).
  - Al seleccionar «Ver en Smart TV», tocar cualquier capítulo subsiguiente (capítulo 2, 3, etc.) se envía de inmediato a la Smart TV sin abrir el reproductor del celular.
  - Botón Cast individual en cada fila de episodios para transmitir cualquier capítulo sin cambiar el modo general.
  - Selector de destino integrado en la cabecera del control remoto móvil (`TvRemoteSheet`).
- **Administración Profesional de Cuentas Firebase:**
  - Sección «ADMINISTRACIÓN VIP» en Ajustes para cuentas fundadoras y administradores para gestión directa de solicitudes, renovaciones, desvinculación de equipos y cambio de roles.
  - Independencia de cuotas: soporte nativo en IdentityToolkit (Firebase Auth) y CLI/Web `tvtv/tool/firebase_admin.py` para operar sin bloqueos incluso ante saturación de Firestore.
  - Reglas de seguridad actualizadas con comprobación rápida de identidades fundadoras.

## 3.3.7 — 2026-11-18
- **Control Remoto Móvil 2026 (InútilTV Connect):**
  - **Trackpad Gestual Multitáctil:** modo alternativo táctil con superficie gestual completa para deslizar suavemente en cualquier dirección y tocar para seleccionar.
  - **Keyboard Bridge (Teclado Celular → TV):** al buscar contenido, el teclado virtual del celular inyecta texto en tiempo real directamente en el buscador de la Smart TV sin tener que teclear con la cruceta en pantalla.
  - **Controles de Volumen y Feedback Visual:** botones dedicados Vol + y Vol − con barra de progreso dinámica y porcentaje sobre la pantalla del celular.
  - **Scrubbar Arrastrable y Control de Velocidad:** barra de progreso interactiva para saltar a cualquier segundo exacto y chips para cambiar la velocidad de reproducción (0.75×, 1×, 1.25×, 1.5×, 2×).
  - **Indicador de Conexión Pulsante:** animación de pulso verde que confirma la presencia en vivo y salud del enlace con la Smart TV.

## 3.3.6 — 2026-11-18
- **Smart TV Remote Connect y Handshake Automático:** solución definitiva al estado de «Desconectada · Espera unos segundos...». Al escanear el código QR o abrir el control, el celular inicia un bucle de refresco continuo acelerado (1.2 s) con tolerancia a desfaces de reloj de hasta 120 s entre dispositivos.
- **Control Remoto D-Pad Completo:** cruceta direccional táctil (Arriba, Abajo, Izquierda, Derecha y OK central) integrada en el panel del control móvil para navegar fluidamente por menús, catálogos y listas de canales en la Smart TV sin depender del mando físico.
- **Accesos Rápidos y Teclas de Función:** botones dedicados para Atrás, Inicio, Búsqueda directa y accesos rápidos de un toque a las secciones de TV en Vivo, Cine, Series y Anime.
- **Auto-recuperación de Sesión (Token Refresh 401 en Firestore):** renovación transparente del token de autenticación ante errores 401 con reintento automático, impidiendo que el mando o la sincronización queden en silencio si la sesión expira en segundo plano.
- **Sincronización de Reproducción en TV en Vivo:** los canales de TV en vivo ahora reportan en tiempo real su nombre y categoría al control remoto en el celular para monitoreo y control en vivo.

## 3.3.5 — 2026-11-18
- **Coordinador global de decodificadores hardware en Smart TV:** TV en Vivo destruye por completo su reproductor nativo cuando se abre una película o serie, liberando la superficie de hardware y el hilo de decodificación. Al cerrar la película, TV en Vivo se re-sintoniza limpiamente sin conflictos.
- **Escaladores ultra livianos en TV Box:** activados perfiles bilineales rápidos (`cscale=bilinear`, `dscale=bilinear`, `sws-scaler=fast_bilinear`) que evitan cualquier cálculo de reescalado en CPU por parte de mpv.
- **Sincronización de versión de la aplicación:** corregido el identificador interno de versión para evitar falsos avisos de actualización pendiente en la pantalla principal.

## 3.3.4 — 2026-11-18
- **Video ultra fluido en Smart TV y TV Box:** el video ahora se dibuja directo por el decodificador de hardware (renderizado embebido en la superficie de Android + decodificación por hardware, sin copias intermedias por CPU). Se eliminan los tirones y el «se traba» en TV en Vivo y en películas 1080p de boxes tipo Onn 4K / Amlogic.
- **El decodificador se libera al salir de En Vivo:** al cambiar de pestaña o salir de la app, TV en Vivo suelta el decodificador de hardware y deja de consumir CPU, así la película o serie que abras después arranca con toda la potencia de la box.
- **Búfer y red ajustados para boxes de 2 GB de RAM:** caché de 10 MB en modo TV para que el canal prenda más rápido y no se atragante en conexiones lentas, con decodificación por hardware habilitada para H.264, HEVC, MPEG2/4, VP8, VP9 y AV1.

## 3.3.3 — 2026-11-18
- **TV en Vivo en Smart TV sin trabas:** la lista de canales avanza uno por uno con Flecha Abajo/Arriba sin quedarse atrapada en las estrellas de favoritos ni dejar bordes fantasma; pulsar OK de nuevo sobre el canal activo abre pantalla completa al instante (0 ms, sin reconectar).
- **Pantalla completa limpia y zapping desde el control:** en TV en Vivo a pantalla completa se ve solo el canal sin iconos encima; Flecha Arriba/Abajo o CH+/CH- cambian de canal directamente, OK o Izquierda abren la mini-guía lateral y Atrás sale sin estorbar.
- **Películas, Series y Anime listos para control remoto:** los controles ya se ocultan solos al iniciar el video (sin iconos de bloqueo o rotación de celular), Flecha Izquierda/Derecha (o mantener presionado) adelanta y atrasa ±10 s con barra minimalista, OK pausa/reanuda y todos los botones y hojas de audio/subtítulos/episodios responden al D-pad con foco azul visible.

## 3.3.2 — 2026-11-18
- **Navegación libre en Smart TV:** corregido el bloqueo del menú lateral (`FocusScope`) que impedía salir con Flecha Derecha hacia las películas, series, anime y canales en vivo.
- **Buscadores y botones listos para control remoto:** los buscadores de Cine, Series, Anime y En Vivo ya no atrapan las flechas del control; el botón Atrás desde el catálogo regresa al menú lateral y los botones Reproducir/Detalles muestran foco azul nítido.

## 3.3.1 — 2026-11-18
- **Cámara del escáner QR corregida en Android moderno:** actualizado el motor de cámara compatible con la pantalla acelerada actual y reglas completas de empaquetado para que la cámara abra de inmediato al conceder permiso.
- **Vinculación rápida por código de 8 letras:** ahora también puedes tocar «Usar código» en el celular y escribir las 8 letras que muestra tu TV sin necesidad de usar la cámara.

## 3.3.0 — 2026-11-18
- **Inicio de sesión por código QR en Smart TV:** escanea el QR de la tele desde InútilTV en tu celular y la Smart TV entra automáticamente a tu cuenta sin teclear contraseñas.
- **1 celular + 1 Smart TV simultáneos:** cada cuenta gratuita mantiene vinculados hasta un celular y una Smart TV al mismo tiempo sin desplazarse entre sí.
- **Control remoto móvil y «Ver en TV»:** desde tu celular puedes enviar cualquier película, serie, anime o canal en vivo a tu Smart TV y controlar pausa, adelanto/retroceso (±10 s), volumen y cierre desde la app.
- **Modo Smart TV / Android TV / TV Box (Onn, Google TV, Fire TV):** banner oficial en el launcher, menú lateral, foco visible con control remoto en toda la app, teclado Gboard garantizado al pulsar OK y TV en Vivo en 2 paneles.

## 3.2.7 — 2026-11-18
- **Modo Smart TV / Android TV / TV Box (Onn, Google TV, Fire TV):** la app ahora aparece directo en la pantalla de inicio de tu TV con banner propio y activa automáticamente el menú lateral de Smart TV.
- **Control remoto completo:** flechas, botón OK y resaltado visible con auto-desplazamiento en inicio, películas, series, anime, canales en vivo, episodios, búsqueda, descargas y ajustes.
- **TV en Vivo para pantalla grande:** vista dividida con guía de canales a la izquierda y reproductor en vivo a la derecha + pantalla completa con cambio de canal desde el mando.
- **Reproductor adaptado al mando:** botón OK y Play/Pausa, Izquierda/Derecha para avanzar o retroceder 10 s, Arriba/Abajo o Canal+/- para cambiar de canal en vivo, y botón Atrás en dos pasos (primero oculta controles, luego sale).
- **Selector de diseño en Ajustes:** puedes dejarlo en Automático o cambiar manualmente entre Smart TV y Celular en cualquier dispositivo.

## 3.2.6 — 2026-11-18
- **Cine, Series y Anime ya no quedan vacíos:** cuando la red del usuario no deja entrar a los servidores, la app muestra el catálogo que ya tenía guardado en lugar de una pantalla en blanco.
- **Botón Reintentar en las pestañas vacías:** el aviso ahora dice la verdad (no llegó el catálogo por la red) y permite volver a intentar sin cerrar la aplicación.
- **Última lista buena guardada en el teléfono:** la primera vez que el catálogo responde se guarda una copia local, y esa copia es el primer respaldo cuando después falla la red.
- **Prueba de conexión más justa:** el frente de video pregunta a dos servidores distintos; si uno responde, la prueba pasa en verde en vez de acusar a tu red.
- **Avisos que no confunden:** si un servidor responde saturado se sugiere reintentar, no culpar a la conexión de la empresa.
- **Portada en lugar de recuadro gris:** si la imagen grande del inicio no llega, se usa la portada del título y, si tampoco hay, un degradado con el color de la app.
- **Arranque anticipado:** el catálogo se carga mientras inicia la sesión, así las pestañas muestran contenido desde el primer toque.

## 3.2.5 — 2026-11-18
- **Ya funciona en WiFi de empresa, hotel o aeropuerto:** antes el video no cargaba o la app abría a medias; ahora entra normal.
- **La app encuentra los servidores aunque tu red los esconda o los bloquee.** Si tu red no permite ese camino, vuelve sola al método de siempre, así que nunca empeora nada.
- **Punto de salida para empresas:** si tu empresa te dio una dirección de salida especial, escríbela una vez y el video, el catálogo, las portadas, tu cuenta y las actualizaciones saldrán por ahí.
- **Detecta redes que revisan el tráfico:** si el filtro de tu empresa interfiere con la conexión, la app lo nota y reintenta en vez de quedarse en «No se pudo reproducir el video».
- **Prueba de conexión en Ajustes:** en segundos te dice si el problema es tu wifi, tu empresa o el servidor.
- **El reproductor te dice qué hacer:** cuando el fallo viene de la red verás una sugerencia concreta y breve, no un aviso genérico.
- **Textos más claros en Ajustes** y pantallas sin nombres técnicos: todo se entiende sin saber de redes.

## 3.2.4 — 2026-11-18
- **Interfaz más limpia en Descargas y Ajustes:** se simplificaron los textos visibles para el usuario, eliminando mensajes y detalles técnicos innecesarios.
- **Reproductor más discreto:** los estados de carga y el selector de servidores ahora muestran únicamente etiquetas limpias (`Servidor 1 · Latino`, `Servidor 2 · Subtitulado`, `Sin conexión`) sin mostrar nombres internos de fuentes.
- **Estética 100 % unificada con Inútil Music:** diálogos, pantallas de acceso y actualizaciones completamente adaptados al tema Oscuro/Claro y a los 18 colores de acento.

## 3.2.3 — 2026-11-18
- **Unificación visual total al estilo Inútil Music (`Carbon Black` + Modo Claro + 18 acentos):** se rediseñaron al 100 % las últimas secciones que conservaban el tema heredado azul marino y cian neón (`#0D1426` / `#00E5FF`).
- **Diálogo OTA y Pantalla de OTA Obligatoria (`InutilUpdateDialogContent` / `InutilForceUpdateScreen`):** ahora heredan `AppColors.cardSurfaceFor(context)`, `AppColors.elevatedSurfaceFor(context)`, `AppColors.accentFor(context)` y `InutilIcon`, con botones píldora y caja elevada con scroll limpio para las novedades (corrigiendo el corte de texto justo encima de la barra de progreso).
- **Acceso, Recuperación de Contraseña, Estados de Licencia e Inactividad (`InutilAuthScreen`, `InutilLicenseBlockedScreen`, `InutilInactivityPausedScreen`):** adaptados por completo a tema Oscuro/Claro y color de acento dinámico, eliminando todos los fondos azul marino, cian neón y morado fijo.
- **Limpieza general de paletas (`InutilTvWrappedDialog`, `InutilOnboardingTour`, `InutilAdminPanel`):** armonizados sobre negro carbón `#070709` con 0 colores legados restantes en `lib/`.

## 3.2.2 — 2026-11-18
- **Eliminación de tirones en red y en descargas offline (`PlayerScreen` + `TvScreen`):** se reemplazó la configuración forzada `vo=mediacodec_embed` / `hwdec=mediacodec` por el pipeline nativo GPU de `media_kit` (`vo=gpu` + `hwdec=auto-safe` con decodificación por hardware `hwdec-codecs=all` y sincronización GPU fluida), más ajuste completo de `libmpv` (`cache=yes`, `demuxer-readahead-secs=60`, `demuxer-max-bytes=64MiB`, `framedrop=vo`, `audio-buffer=0.4`, `hr-seek=yes` y reconexión automática `stream-lavf-o`).
- **Descifrado offline sin bloquear el hilo UI (`VaultCrypto` + `HlsStreamProxy`):** nuevo Isolate trabajador persistente con transferencia `TransferableTypedData` (zero-copy) para AES-256-CTR, pre-descifrado adelantado `+2` segmentos en HLS offline y control de flujo TCP (`flush()` cada 256 KB) en MP4 offline para cero picos de RAM/GC.
- **Proxy HLS de red sin cortes:** pool HTTP Keep-Alive persistente en `HlsStreamProxy` (elimina handshakes TLS repetidos en cada segmento `.ts`), lookahead ampliado a `+4` segmentos (`36 MB` de presupuesto) y reintento automático en micro-fallos del CDN.
- **Interfaz del reproductor sin micro-rebuilds:** deduplicación de `setState` en streams `buffering`/`playing`, `RepaintBoundary` alrededor del lienzo `Video` y barra de progreso con seek limpio en `onChangeEnd`.

## 3.2.1 — 2026-11-18
- **Carátulas ultrarrápidas (`ArtworkCacheService` + `FastArtwork`):** motor propio de caché de 2 niveles (L1 RAM LRU de 32 MiB + L2 Disco persistente LRU de 100 MiB con escrituras atómicas `.tmp → rename`), pool HTTP Keep-Alive de 12 conexiones simultáneas por host, deduplicación in-flight, caché negativa temporal de URLs rotas, optimización automática de URLs TMDB (`w342` en cuadrículas y rieles, `w780` en backdrops, `w185` en logos), decodificación acotada con `ResizeImage` y prefetch paralelo de las siguientes filas.
- **Fluidez extrema a 60–120 FPS:** `MainScaffold` migrado a `IndexedStack` perezoso (cero destrucción/recarga al cambiar de pestaña y preservación total del scroll), pausa/silencio automático de `TvScreen` al cambiar de pestaña o pasar a segundo plano, eliminación de los 24+ `AnimationController` simultáneos por tarjeta en `PosterCard`, y aislamiento `RepaintBoundary` en `PosterCard`, `HeroCarousel`, `ContinueWatchingRail` y `GlassSurface`.
- **Arranque sin tirones:** decodificación de `channels_master.json` (1,183 canales) y `vod_master.json` movida a isolates en segundo plano (`compute()`) con deduplicación `_initFuture` en `XuperService` y `VodCatalogService`.
- **Correcciones generales de errores:** tokens anti-race-condition en `MoviesScreen`, `SeriesScreen`, `AnimeScreen`, `SearchScreen` y `VodDetailModal`, parada limpia `_hasMore` al final de la paginación, cancelación correcta de timers y eliminación del controlador redundante en `HeroCarousel`, y actualización instantánea del botón de limpiar búsqueda.

## 3.2.0 — 2026-11-18
- **Descargas Sin Conexión en Bóveda Cifrada AES-256 (`OfflineVaultService`):** descarga películas, series y anime completos dentro del sandbox privado de InútilTV (`ApplicationSupportDirectory/inutil_vault/` con centinela `.nomedia` y archivos opacos `.ivlt`), 100 % invisibles para la Galería y el gestor de archivos.
- **Cifrado real AES-256-CTR por título y descifrado al vuelo:** cada descarga genera su propia clave de 256 bits y nonce único guardados en almacenamiento seguro; `HlsStreamProxy` descifra al vuelo en RAM sobre `127.0.0.1` con soporte total de scrubbing (`206 Partial Content`), subtítulos offline y portadas cacheadas (0 bytes en claro en disco).
- **Funciones superiores de descarga:** pausa y reanudación real sin perder bloques al reiniciar la app, soporte universal HLS (en lotes paralelos de 4 con recorte de cabeceras PNG falsas) + MP4 por rangos, descarga por lotes («Próximos 3 episodios» / «Toda la temporada»), selector de calidad (`Máxima HD` vs `Equilibrada (Ahorro)`), «Auto-borrar al terminar de ver», hub dedicado de Descargas y reproducción offline automática en 0 ms al abrir cualquier título ya descargado.
- **Política OTA opcional por defecto:** tras esta versión base (`3.2.0`), las próximas actualizaciones serán opcionales por defecto y solo se forzarán cuando el creador las marque explícitamente como urgentes (`--urgent`).

## 3.1.0 — 2026-11-18
- **Series 100 % confiables en todos sus capítulos (Ep 1, 2, 3…):** nuevo motor primario `SeriesKaoService` + Embed69 con descifrado AES-256-CBC puro en Dart, catálogo popular curado (`Populares HD`, `Recientes`, `Estrenos`), failover automático episodio por episodio entre SeriesKao, PoseidonHD2 y PelisFlix, y sistema de salud de series (`SeriesHealthService`).
- **Proxy local HLS anti-pantalla negra (`HlsStreamProxy` en `127.0.0.1`):** normaliza segmentos disfrazados (`.image`/`.png` → `.ts`) y recorta cabeceras PNG falsas hasta el sync real MPEG-TS `0x47`, eliminando el error `not in allowed_segment_extensions` de `libmpv` en VidHide y StreamWish.
- **Precarga instantánea del siguiente episodio (`NextEpisodePreloader`):** mientras se reproduce un capítulo de Series o Anime, resuelve y pre-bufferiza en segundo plano los primeros 2–3 minutos (hasta 16 MB en HLS o 10 MB en MP4) para cambiar de capítulo al instante (<300 ms) con indicador `⚡ Instantáneo` y control en Ajustes.
- **Carrera paralela de servidores:** verificación simultánea en lotes de 3 hosts/espejos y corrección del ranking de URLs `.m3u8` en StreamWish/VidHide (`/stream/.../master.m3u8` primero), acelerando la carga inicial hasta 4×.
- **Nuevas funciones portadas de Inútil Music v2.4:** Temporizador de sueño en 1 toque dentro del reproductor y TV en Vivo (con opción «Al terminar este episodio»), Respaldo y restauración en la nube (`users/{uid}/data/tv_backup` aislado de Inútil Music y protegido contra sobrescritura en instalaciones nuevas), Recorrido guiado interactivo, InútilTV Wrapped (Resumen del Año tipo Stories), pausa automática por inactividad con botón de reactivación y heartbeat `lastActiveAt`, pop-ups rotativos de apoyo y avisos remotos (`app_config/tv_promo_popup`), y saludo contextual con filtros rápidos en Inicio.

## 3.0.0 — 2026-11-18
- Rediseño integral al nivel visual de Inútil Music: paleta Carbon Black (`#070709` / `#0C0C0F`), acento monocromático Blanco Puro (`#F5F7F5`) personalizable con 18 colores, 3 modos de superficie (`Liquid Glass`, `Transparente`, `Acento`), tema Oscuro/Claro/Sistema, barra flotante Liquid Glass con botón circular de búsqueda e íconos geométricos exclusivos (`InutilIcon`).
- App 100% enfocada al usuario final: se removió el panel de administración interno (la administración de usuarios, vigencia y OTA permanece exclusivamente en la consola web Firebase).
- Reproductor Cinematográfico Minimalista: estética obsidiana + botón Play blanco puro, cero colisión de controles sobre errores o pantalla de carga, eliminación del timer ciego que producía pantalla negra en 0:00 y failover automático a los 10s si un flujo no entrega fotogramas reales.
- Motor Multi-Proveedor anti-caídas para Cine y Series: doble espejo estructurado (`poseidonhd2.co` + `cuevana3.eu`) con metadatos TMDB reales (portadas HD `w500`, backdrops `w780`, sinopsis coherentes en español y calificaciones reales) + extractores reales Vidara HLS y Doodstream MP4 + validador de bytes reales (`StreamValidator`) que rechaza archivos HTML de DMCA + failover cruzado con PelisFlix.
- Portadas y cuadrículas perfeccionadas: `PosterCard` totalmente responsiva (`expandInGrid: true`, relación 2:3) con cero empalmes en grids móviles, eliminación de duplicados y `404x.jpg`, y portadas HD nítidas + búsqueda sin sensibilidad a acentos en Anime + respaldo automático TioAnime (`YourUpload` MP4).
- TV en Vivo auditada por bytes reales de segmento: 1,183 canales únicos verificados sin señales caídas ni duplicados, 106 con respaldo multi-señal integrado y sincronización automática en segundo plano (`LiveTvSyncService`) con TDTChannels, iptv-org y Free-TV.

## 2.0.0 — 2026-11-17
- Actualizaciones OTA in-app y OTA Forzosa (Kill Switch) sincronizadas con GitHub Releases (`CesarHGlez13/inutil-tv`) y Firebase (`app_config/tv_release`) desde el Panel de Control César.
- Corrección total de pantalla completa en TV en Vivo: cero reproducción doble, ocultado completo de barras en horizontal y cajón lateral de zapping rápido.
- Deportes organizados por subcategorías (Destacados, Liga MX / MX, Champions & Europa, ESPN/Fox/Claro, Sudamérica, NFL/NBA/MLB, Box/UFC y F1/Motor), limpieza de 74 URLs duplicadas y badge de calidad real detectada.
- Reproductor Cinematográfico Pro: carga paso a paso con póster difuminado, multi-servidor con cambio manual, doble toque ±10s con ripple, gestos verticales de brillo/volumen y bloqueo táctil real.
- Modo Maratón estilo Netflix/Crunchyroll: botón Omitir Intro (+85s), tarjeta flotante "Siguiente episodio en 5s", resolución automática de series PelisFlix y episodios completos en JKAnime (+1,000 caps).
- Seguir viendo con reanudación exacta, Mi Lista persistente, pestaña independiente de Anime y ajustes reales de MediaCodec y buffer 64 MB.
