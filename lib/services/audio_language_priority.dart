import '../models/models.dart';
import 'app_settings_service.dart';

/// Fuente única de verdad para la prioridad de idioma de audio en Inutix TV.
///
/// Reglas de oro:
/// 1. Si el usuario configuró un idioma explícito en Ajustes
///    (`latino`, `espanol`, `sub`), siempre gana.
/// 2. En modo `auto` (por defecto), se respeta el idioma de la sesión activa
///    (p. ej. si está viendo Ep. 1 en Latino, Ep. 2/3/4 continúan en Latino;
///    si eligió manualmente Subtitulado en Ep. 1, Ep. 2 mantiene Subtitulado).
/// 3. Si aún no hay idioma de sesión activo y el modo es `auto`, el idioma
///    preferido por defecto es **Latino** (`latino` > `espanol` > `sub`), para
///    evitar que un episodio salte inesperadamente a inglés/subtitulado.
class AudioLanguagePriority {
  AudioLanguagePriority._();

  static final RegExp _reLatWord = RegExp(r'\blat\b');
  static final RegExp _reEspWord = RegExp(r'\besp\b');
  static final RegExp _reSubWord = RegExp(r'\bsub\b');
  static final RegExp _reEngWord = RegExp(r'\beng\b');
  static final RegExp _reNonAlnum = RegExp(r'[^a-z0-9]+');
  static final RegExp _reWhitespace = RegExp(r'\s+');

  static String _normalizeToken(String input) {
    if (input.isEmpty) return '';
    return input
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ñ', 'n')
        .replaceAll(_reNonAlnum, ' ')
        .replaceAll(_reWhitespace, ' ')
        .trim();
  }

  /// Normaliza cualquier etiqueta de idioma o servidor a uno de:
  /// `'latino'`, `'espanol'`, `'sub'`, o `''` (desconocido/neutro).
  static String normalizeLanguage(String raw) {
    final l = _normalizeToken(raw);
    if (l.isEmpty) return '';

    // 1. Latino primero (si una ficha indica "Latino / Sub", priorizar Latino).
    if (l.contains('latino') ||
        l.contains('es mx') ||
        l.contains('es 419') ||
        _reLatWord.hasMatch(l)) {
      return 'latino';
    }

    // 2. Subtitulado / Inglés antes que Español para que "Sub Español" no
    //    caiga erróneamente en "espanol".
    if (l.contains('subtitul') ||
        l.contains('sub espanol') ||
        l.contains('sub esp') ||
        _reSubWord.hasMatch(l) ||
        l.contains('vose') ||
        l.contains('ingles') ||
        l.contains('english') ||
        _reEngWord.hasMatch(l)) {
      return 'sub';
    }

    // 3. Español de España / Castellano.
    if (l.contains('castellano') ||
        l.contains('espana') ||
        l.contains('espanol') ||
        l.contains('spanish') ||
        l.contains('es es') ||
        _reEspWord.hasMatch(l)) {
      return 'espanol';
    }

    return '';
  }

  /// Devuelve el idioma objetivo (`'latino'`, `'espanol'` o `'sub'`).
  static String resolveDesiredAudioLang({
    String? activeSessionLang,
    String? configuredOverride,
  }) {
    final configured =
        (configuredOverride ?? AppSettingsService.instance.preferredAudioLang)
            .trim()
            .toLowerCase();
    if (configured == 'latino' ||
        configured == 'espanol' ||
        configured == 'sub') {
      return configured;
    }

    if (activeSessionLang != null && activeSessionLang.trim().isNotEmpty) {
      final normSession = normalizeLanguage(activeSessionLang);
      if (normSession.isNotEmpty) return normSession;
    }

    return 'latino';
  }

  /// Orden estricto de niveles de idioma a intentar en los proveedores.
  static List<String> languageTierOrder({
    String? desiredLang,
    String? activeSessionLang,
    String? configuredOverride,
  }) {
    final desired = _effectiveDesired(
      desiredLang: desiredLang,
      activeSessionLang: activeSessionLang,
      configuredOverride: configuredOverride,
    );
    return switch (desired) {
      'espanol' => const ['espanol', 'latino', 'sub'],
      'sub' => const ['sub', 'latino', 'espanol'],
      _ => const ['latino', 'espanol', 'sub'],
    };
  }

  /// Rango numérico para ordenar fuentes de reproducción (menor = mayor prioridad).
  /// - `-1`: descarga local sin conexión.
  /// - `0`: idioma deseado.
  /// - `1..3`: respaldos ordenados sin mezclar inglés delante de Latino.
  static int rankForLabel(
    String label, {
    String? desiredLang,
    String? activeSessionLang,
    String? configuredOverride,
  }) {
    final low = label.toLowerCase();
    if (low.contains('sin conexión') ||
        low.contains('sin conexion') ||
        low.contains('offline')) {
      return -1;
    }

    final desired = _effectiveDesired(
      desiredLang: desiredLang,
      activeSessionLang: activeSessionLang,
      configuredOverride: configuredOverride,
    );
    final lang = normalizeLanguage(label);

    if (desired == 'sub') {
      return switch (lang) {
        'sub' => 0,
        '' => 1,
        'latino' => 2,
        'espanol' => 3,
        _ => 4,
      };
    }

    if (desired == 'espanol') {
      return switch (lang) {
        'espanol' => 0,
        'latino' => 1,
        '' => 2,
        'sub' => 3,
        _ => 4,
      };
    }

    // Default ('latino'): Latino > Español > Sin etiqueta > Subtitulado/Inglés
    return switch (lang) {
      'latino' => 0,
      'espanol' => 1,
      '' => 2,
      'sub' => 3,
      _ => 4,
    };
  }

  /// Ordena de forma estable una lista de [StreamSource] poniendo primero el
  /// idioma deseado y preservando el orden de velocidad/salud dentro del mismo idioma.
  static List<StreamSource> prioritizeSources(
    List<StreamSource> raw, {
    String? desiredLang,
    String? activeSessionLang,
    String? configuredOverride,
  }) {
    if (raw.length <= 1) return List<StreamSource>.of(raw);
    final indexed = <(int idx, int rank, StreamSource src)>[
      for (var i = 0; i < raw.length; i++)
        (
          i,
          rankForLabel(
            raw[i].quality,
            desiredLang: desiredLang,
            activeSessionLang: activeSessionLang,
            configuredOverride: configuredOverride,
          ),
          raw[i],
        ),
    ];
    indexed.sort((a, b) {
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$3];
  }

  /// Indica si al menos una fuente coincide con el idioma deseado.
  static bool hasDesiredLanguage(
    List<StreamSource> sources, {
    String? desiredLang,
    String? activeSessionLang,
    String? configuredOverride,
  }) {
    final desired = _effectiveDesired(
      desiredLang: desiredLang,
      activeSessionLang: activeSessionLang,
      configuredOverride: configuredOverride,
    );
    return sources.any((s) => normalizeLanguage(s.quality) == desired);
  }

  static String _effectiveDesired({
    String? desiredLang,
    String? activeSessionLang,
    String? configuredOverride,
  }) {
    if (desiredLang != null && desiredLang.trim().isNotEmpty) {
      final norm = normalizeLanguage(desiredLang);
      if (norm.isNotEmpty) return norm;
    }
    return resolveDesiredAudioLang(
      activeSessionLang: activeSessionLang,
      configuredOverride: configuredOverride,
    );
  }
}
