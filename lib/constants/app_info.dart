/// Constantes de marca, versión, creador y apoyo de Inutix TV
/// (ecosistema inutix.com junto con Inutix Music).
class AppInfo {
  const AppInfo._();

  static const String appName = 'Inutix TV';
  static const String appVersion = '3.3.46';
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
    'Anime en redes de empresa, hoteles y aeropuertos, ahora completo: la app usa el camino que sí le responde para la lista, la ficha, la búsqueda y el reproductor, sin vueltas innecesarias',
    'Anime completo en redes de empresa, hoteles y aeropuertos: la app prueba primero el camino que sí le responde, así la lista, la ficha y los episodios no se cortan por un intento perdido',
    'La conexión con tu servidor de datos se recupera sola: si se reinicia con la app abierta, la app lo detecta y vuelve a él sin que hagas nada',
    'Anime completo en redes de empresa, hoteles y aeropuertos: al reproducir un episodio la app usa primero la dirección que sí le responde, así el video arranca sin que configures nada',
    'Anime en redes de empresa, hoteles y aeropuertos: si tu red no deja entrar a la lista, la app cambia sola al camino alterno y carga la lista, la ficha, los episodios y el video sin que configures nada',
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
