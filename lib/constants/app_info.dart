/// Constantes de marca, versión, creador y apoyo de Inutix TV
/// (ecosistema inutix.com junto con Inutix Music).
class AppInfo {
  const AppInfo._();

  static const String appName = 'Inutix TV';
  static const String appVersion = '3.3.38';
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
    'Mayor disponibilidad en películas y series: búsqueda y reproducción automática más estable',
    'Funciona en redes de empresa, hoteles y aeropuertos, incluso cuando tu red exige un punto de salida',
    'Nueva identidad oficial Inutix TV con el logo renovado iX TV en móvil y Android TV',
    'Detección automática de la configuración de red de tu Wi‑Fi sin afectar la reproducción local',
    'Reproducción más rápida y estable en películas, series y anime, incluso en conexiones lentas',
    'Control remoto por Wi-Fi más seguro y privado, exclusivo para los dispositivos de tu propia cuenta',
  ];
}
