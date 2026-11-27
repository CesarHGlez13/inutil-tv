import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/app_settings_service.dart';
import 'package:tubotv/services/audio_language_priority.dart';
import 'package:tubotv/services/cuevana_poseidon_service.dart';
import 'package:tubotv/services/serieskao_service.dart';
import 'package:tubotv/services/tv_taste_profile_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettingsService.instance.setPreferredAudioLang('auto');
  });

  group('v3.3.58 — Prioridad de audio Latino y continuidad entre episodios', () {
    test('normalizeLanguage reconoce Latino, Español y Subtitulado/Inglés', () {
      expect(AudioLanguagePriority.normalizeLanguage('HD · Latino'), 'latino');
      expect(AudioLanguagePriority.normalizeLanguage('LAT'), 'latino');
      expect(AudioLanguagePriority.normalizeLanguage('es-mx'), 'latino');
      expect(
        AudioLanguagePriority.normalizeLanguage('Serie · Latino / Sub'),
        'latino',
      );
      expect(
        AudioLanguagePriority.normalizeLanguage('HD · Español'),
        'espanol',
      );
      expect(AudioLanguagePriority.normalizeLanguage('Castellano'), 'espanol');
      expect(AudioLanguagePriority.normalizeLanguage('ESP'), 'espanol');
      expect(
        AudioLanguagePriority.normalizeLanguage('HD · Subtitulado'),
        'sub',
      );
      expect(AudioLanguagePriority.normalizeLanguage('Sub Español'), 'sub');
      expect(AudioLanguagePriority.normalizeLanguage('SUB'), 'sub');
      expect(AudioLanguagePriority.normalizeLanguage('English'), 'sub');
      expect(AudioLanguagePriority.normalizeLanguage('ENG'), 'sub');
      expect(AudioLanguagePriority.normalizeLanguage('Inglés'), 'sub');
      expect(AudioLanguagePriority.normalizeLanguage('VOSE'), 'sub');
      expect(AudioLanguagePriority.normalizeLanguage('Servidor HD'), '');
      // TvTasteProfileService delega en la misma normalización
      expect(
        TvTasteProfileService.normalizeAudioLang('HD · Español'),
        'espanol',
      );
    });

    test('por defecto en auto elige Latino y respeta sesión o ajuste explícito',
        () async {
      expect(AudioLanguagePriority.resolveDesiredAudioLang(), 'latino');
      expect(
        AudioLanguagePriority.resolveDesiredAudioLang(
          activeSessionLang: 'latino',
        ),
        'latino',
      );
      // Si el usuario eligió Sub manualmente en Ep. 1, Ep. 2 conserva Sub
      expect(
        AudioLanguagePriority.resolveDesiredAudioLang(activeSessionLang: 'sub'),
        'sub',
      );
      // Ajuste explícito en configuración siempre gana sobre la sesión
      await AppSettingsService.instance.setPreferredAudioLang('espanol');
      expect(
        AudioLanguagePriority.resolveDesiredAudioLang(activeSessionLang: 'sub'),
        'espanol',
      );
    });

    test(
        'prioritizeSources siempre antepone Latino sobre Subtitulado y conserva velocidad interna',
        () {
      const sources = [
        StreamSource(
          url: 'https://cdn.example/sub_fast.m3u8',
          quality: 'HD · Subtitulado',
          server: 'vidhide',
        ),
        StreamSource(
          url: 'https://cdn.example/esp.m3u8',
          quality: 'HD · Español',
          server: 'streamwish',
        ),
        StreamSource(
          url: 'https://cdn.example/lat_fast.m3u8',
          quality: 'HD · Latino',
          server: 'streamwish',
        ),
        StreamSource(
          url: 'https://cdn.example/lat_backup.m3u8',
          quality: 'HD · Latino',
          server: 'vidhide',
        ),
        StreamSource(
          url: 'http://127.0.0.1:9999/offline.mp4',
          quality: 'Sin conexión',
          server: 'offline',
        ),
      ];

      final ordered = AudioLanguagePriority.prioritizeSources(sources);
      expect(
        ordered.map((s) => s.url).toList(),
        [
          'http://127.0.0.1:9999/offline.mp4',
          'https://cdn.example/lat_fast.m3u8',
          'https://cdn.example/lat_backup.m3u8',
          'https://cdn.example/esp.m3u8',
          'https://cdn.example/sub_fast.m3u8',
        ],
      );
    });

    test(
        'SeriesKaoService.groupEmbedsByLanguageTier nunca mezcla LAT y SUB en el mismo lote',
        () {
      const embeds = [
        DecryptedEmbed(
          language: 'SUB',
          server: 'vidhide',
          url: 'https://vidhide.example/sub1',
        ),
        DecryptedEmbed(
          language: 'LAT',
          server: 'streamwish',
          url: 'https://streamwish.example/lat1',
        ),
        DecryptedEmbed(
          language: 'ENG',
          server: 'streamwish',
          url: 'https://streamwish.example/eng1',
        ),
        DecryptedEmbed(
          language: 'ESP',
          server: 'vidhide',
          url: 'https://vidhide.example/esp1',
        ),
        DecryptedEmbed(
          language: 'LATINO',
          server: 'vidhide',
          url: 'https://vidhide.example/lat2',
        ),
      ];

      final tiers = SeriesKaoService.groupEmbedsByLanguageTier(embeds);
      expect(tiers.length, 3);
      // Nivel 0: SOLO Latino (jamás mezclado con SUB/ENG)
      expect(tiers[0].every((e) => e.langLabel == 'Latino'), isTrue);
      expect(tiers[0].length, 2);
      // Nivel 1: SOLO Español
      expect(tiers[1].every((e) => e.langLabel == 'Español'), isTrue);
      expect(tiers[1].length, 1);
      // Nivel 2: SOLO Subtitulado / Inglés
      expect(tiers[2].every((e) => e.langLabel == 'Subtitulado'), isTrue);
      expect(tiers[2].length, 2);

      // Si el usuario pidió Subtitulado, ese nivel va primero
      final subFirst = SeriesKaoService.groupEmbedsByLanguageTier(
        embeds,
        desiredLang: 'sub',
      );
      expect(subFirst.first.every((e) => e.langLabel == 'Subtitulado'), isTrue);
    });

    test('CuevanaPoseidonService.poseidonLanguageOrder prioriza Latino por defecto',
        () {
      expect(
        CuevanaPoseidonService.poseidonLanguageOrder(),
        const [
          ('latino', 'Latino'),
          ('spanish', 'Español'),
          ('english', 'Subtitulado'),
        ],
      );
      expect(
        CuevanaPoseidonService.poseidonLanguageOrder(desiredLang: 'sub'),
        const [
          ('english', 'Subtitulado'),
          ('latino', 'Latino'),
          ('spanish', 'Español'),
        ],
      );
    });
  });
}
