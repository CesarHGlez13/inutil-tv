/// Constantes de marca, versión, creador y apoyo de Inutix TV
/// (ecosistema inutix.com junto con Inutix Music).
class AppInfo {
  const AppInfo._();

  static const String appName = 'Inutix TV';
  static const String appVersion = '3.3.36';
  static const String creatorName = 'César';
  static const String supportEmail = 'cesarmaster133@gmail.com';

  /// «Apoyar el desarrollo / Donaciones» abre el cliente de correo del equipo
  /// con el asunto prellenado hacia el correo oficial del creador.
  static const String supportDevelopmentUrl =
      'mailto:cesarmaster133@gmail.com'
      '?subject=Inutix%20TV%20-%20apoyo%20al%20desarrollo';

  static const String contactCreatorUrl =
      'mailto:cesarmaster133@gmail.com'
      '?subject=Inutix%20TV%20-%20contacto%20y%20soporte';

  static const String githubProfileUrl = 'https://github.com/CesarHGlez13';
  static const String familyEcosystemLabel =
      'Ecosistema inutix.com · Inutix TV & Inutix Music';

  static const List<String> whatsNewHighlights = [
    'Nueva identidad oficial Inutix TV con el logo renovado iX TV en móvil y Android TV',
    'Detección automática del proxy Wi-Fi configurado en tu dispositivo para mejor compatibilidad en redes con proxy',
    'Reproducción más rápida y estable en películas, series y anime, incluso en conexiones lentas',
    'Control remoto por Wi-Fi más seguro y privado, exclusivo para los dispositivos de tu propia cuenta',
  ];
}
