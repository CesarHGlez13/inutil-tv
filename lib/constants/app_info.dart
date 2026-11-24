/// Constantes de marca, versión, creador y apoyo de InútilTV
/// (ecosistema Familia Inútil junto con Inútil Music).
class AppInfo {
  const AppInfo._();

  static const String appName = 'InútilTV';
  static const String appVersion = '3.3.30';
  static const String creatorName = 'César';
  static const String supportEmail = 'cesarmaster133@gmail.com';

  /// «Apoyar el desarrollo / Donaciones» abre el cliente de correo del equipo
  /// con el asunto prellenado hacia el correo oficial del creador.
  static const String supportDevelopmentUrl =
      'mailto:cesarmaster133@gmail.com'
      '?subject=In%C3%BAtilTV%20-%20apoyo%20al%20desarrollo';

  static const String contactCreatorUrl =
      'mailto:cesarmaster133@gmail.com'
      '?subject=In%C3%BAtilTV%20-%20contacto%20y%20soporte';

  static const String githubProfileUrl = 'https://github.com/CesarHGlez13';
  static const String familyEcosystemLabel =
      'Familia Inútil · InútilTV & Inútil Music';

  static const List<String> whatsNewHighlights = [
    'Recomendaciones dinámicas tipo Spotify: riel "Especialmente para ti" y "Porque viste..." adaptativos',
    'Rotación y refresco instantáneo de descubrimientos con botón dedicado para Smart TV y gestos móviles',
    'Sonda de alcance y fallback automático de Relay: cero cuelgues ni fallas de Firestore fuera de casa',
    'Aislamiento estricto de sesiones multi-dispositivo y validación de licencias reforzada',
  ];
}
