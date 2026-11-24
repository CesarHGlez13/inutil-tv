/// Constantes de marca, versión, creador y apoyo de Inutix TV
/// (ecosistema inutix.com junto con Inútil Music).
class AppInfo {
  const AppInfo._();

  static const String appName = 'Inutix TV';
  static const String appVersion = '3.3.35';
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
    'Nueva identidad profesional: Inutix TV con nuevo ícono IX, banner Android TV y logo oficial',
    'Blindaje total de seguridad: cero llaves de TMDB/Fanart en la app; todo servido desde Cloudflare Edge (meta.inutix.com y ota.inutix.com)',
    'Espejos VOD dinámicos (app_config/providers) y failover automático LAN → api.inutix.com → backup.inutix.com',
    'Motor ultrarrápido optimizado para redes lentas en películas, series y anime',
  ];
}
