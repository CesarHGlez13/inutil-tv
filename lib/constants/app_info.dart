/// Constantes de marca, versión, creador y apoyo de Inutix TV
/// (ecosistema inutix.com junto con Inutix Music).
class AppInfo {
  const AppInfo._();

  static const String appName = 'Inutix TV';
  static const String appVersion = '3.3.56';
  static const String creatorName = 'César';
  static const String supportEmail = 'cesarmaster133@gmail.com';

  /// «Apoyar el desarrollo / Donaciones» abre el cliente de correo del equipo
  /// con el asunto prellenado hacia el correo oficial del creador.
  static const String supportDevelopmentUrl = 'mailto:cesarmaster133@gmail.com'
      '?subject=Inutix%20TV%20-%20apoyo%20al%20desarrollo';

  static const String contactCreatorUrl = 'mailto:cesarmaster133@gmail.com'
      '?subject=Inutix%20TV%20-%20contacto%20y%20soporte';

  static const String githubProfileUrl = 'https://github.com/CesarHGlez13';
  static const String familyEcosystemLabel =
      'Ecosistema inutix.com · Inutix TV & Inutix Music';

  static const List<String> whatsNewHighlights = [
    'Video continuo y fluido en Smart TV y Google TV: corrige pausas momentáneas de imagen mientras el audio seguía sonando',
    'Reproducción más rápida y estable: arranque ágil de películas y series con cambio automático cuando un servidor se pausa',
    'Búsqueda y navegación más fluidas en Google TV y Smart TV, con teclado nativo por defecto y mejor respuesta del control remoto',
    'Diseño más limpio en Smart TV: marco de selección refinado en pósters y episodios con botón Play centrado',
    'Mejoras internas de estabilidad y verificación de sesión para mantener tu cuenta y reproducción siempre sincronizadas',
    'Inicio, Novedades y Series más dinámicos: las secciones principales ahora se adaptan mejor a tus gustos y rotan con contenido fresco',
    'Tu progreso siempre a salvo: al reinstalar o cambiar de equipo recuperas dónde te quedaste, tu lista, tus canales favoritos y tus preferencias',
    'Mejor escritura con control remoto: nuevo teclado integrado para buscar y escribir más fácil en Smart TV y TV Box',
    'App más limpia y ligera: se retiraron módulos obsoletos y rutas de rodeo ya sustituidas por el Modo VPN Inutix, reduciendo tamaño y arrancando más rápido',
    'Nuevo Modo VPN Inutix integrado: cifra todo el catálogo, las portadas y la reproducción de video desde dentro de la app para saltar bloqueos de oficina, escuela u hotel sin instalar apps externas',
    'La conexión con tu servidor de datos se recupera sola: si se reinicia con la app abierta, la app lo detecta y vuelve a él sin que hagas nada',
    'Tu actividad se registra al cerrar la sesión: un resumen diario en segundo plano confirma que tu cuenta sigue activa según la política de 15 días',
    'Sesión siempre estable para cuentas activas: corrige bloqueos inesperados de acceso ante cambios de red y recupera tu cuenta al instante al pulsar «Comprobar Estado»',
    'Mayor disponibilidad en películas y series: búsqueda y reproducción automática más estable',
    'Funciona en redes de empresa, hoteles y aeropuertos, incluso cuando tu red exige un punto de salida',
    'Nueva identidad oficial Inutix TV con el logo renovado iX TV en móvil y Android TV',
    'Detección automática de la configuración de red de tu Wi‑Fi sin afectar la reproducción local',
    'Reproducción más rápida y estable en películas, series y anime, incluso en conexiones lentas',
    'Control remoto por Wi-Fi más seguro y privado, exclusivo para los dispositivos de tu propia cuenta',
  ];
}
