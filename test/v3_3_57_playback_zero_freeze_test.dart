import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/models/models.dart';
import 'package:tubotv/services/fullscreen_playback_coordinator.dart';
import 'package:tubotv/services/tv_taste_profile_service.dart';
import 'package:tubotv/services/watch_history.dart';
import 'package:tubotv/services/xuper_service.dart';

VodItem _movie(String id, String title, {String genre = 'Acción · Aventura'}) =>
    VodItem(
      id: id,
      title: title,
      slug: 'movies/$id',
      poster: 'https://example.com/$id.jpg',
      backdrop: 'https://example.com/${id}_bg.jpg',
      genre: genre,
      year: '2025',
      rating: '8.1',
      provider: 'poseidon',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TvTasteProfileService.instance.resetForTest();
    while (FullscreenPlaybackCoordinator.instance.isActive.value) {
      FullscreenPlaybackCoordinator.instance.end();
    }
    await WatchHistory().reloadFromDisk();
  });

  tearDown(() {
    while (FullscreenPlaybackCoordinator.instance.isActive.value) {
      FullscreenPlaybackCoordinator.instance.end();
    }
  });

  test('WatchHistory.record(notify: false) persiste sin despertar listeners',
      () async {
    var notifications = 0;
    void listener() => notifications++;
    WatchHistory().addListener(listener);
    addTearDown(() => WatchHistory().removeListener(listener));

    final item = _movie('m1', 'Big Fish');
    await WatchHistory().record(
      item,
      positionSec: 120,
      durationSec: 7200,
      notify: false,
    );

    expect(notifications, 0);
    expect(WatchHistory().progressFor('m1')?.positionSec, 120);

    // Al pausar / salir (notify: true por defecto), sí notifica
    await WatchHistory().record(
      item,
      positionSec: 135,
      durationSec: 7200,
    );
    expect(notifications, 1);
    expect(WatchHistory().progressFor('m1')?.positionSec, 135);
  });

  test(
      'XuperService pospone re-ranking durante reproducción fullscreen y lo ejecuta al salir',
      () async {
    final xuper = XuperService();
    xuper.setCatalogForTest(
      liveMovies: [
        for (var i = 0; i < 10; i++) _movie('mv_$i', 'Película $i'),
      ],
    );

    var xuperNotifies = 0;
    void listener() => xuperNotifies++;
    xuper.addListener(listener);
    addTearDown(() => xuper.removeListener(listener));

    // Simular reproducción a pantalla completa activa
    FullscreenPlaybackCoordinator.instance.begin();
    expect(FullscreenPlaybackCoordinator.instance.isActive.value, isTrue);

    // Aun si algún servicio notificara WatchHistory durante fullscreen,
    // XuperService NO debe disparar recompute ni notifyListeners en medio del video.
    await WatchHistory().record(
      _movie('mv_0', 'Película 0'),
      positionSec: 60,
      durationSec: 3600,
      notify: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(xuperNotifies, 0);

    // Al salir de fullscreen, debe drenar el recompute pendiente tras el debounce
    FullscreenPlaybackCoordinator.instance.end();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(xuperNotifies, greaterThanOrEqualTo(1));
  });

  test('XuperService.getFeaturedVod cachea por seed e invalida ante cambios',
      () async {
    final xuper = XuperService();
    xuper.setCatalogForTest(
      liveMovies: [
        for (var i = 0; i < 10; i++) _movie('f_$i', 'Hero $i'),
      ],
    );

    final first = xuper.getFeaturedVod(seed: 42);
    final second = xuper.getFeaturedVod(seed: 42);
    expect(identical(first, second), isTrue);
    expect(first.length, 6);

    await WatchHistory().record(
      _movie('f_0', 'Hero 0'),
      positionSec: 3550,
      durationSec: 3600,
      notify: true,
    );
    final after = xuper.getFeaturedVod(seed: 42);
    expect(identical(first, after), isFalse);
  });
}
