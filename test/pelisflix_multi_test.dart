import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/pelisflix_service.dart';

void main() {
  test('PelisflixService resolves multiple real movies to HLS', () async {
    final svc = PelisflixService();
    final testSlugs = [
      'la-copia-perfecta',
      'el-anfitrion',
      'frostbite',
      'heartland-2',
      'como-robar-un-banco-2',
    ];

    int successCount = 0;
    for (final slug in testSlugs) {
      final url = await svc.resolveStreamUrl(slug);
      print('Slug: $slug -> $url');
      if (url != null && url.contains('.m3u8')) {
        successCount++;
      }
    }

    print('Success count: $successCount / ${testSlugs.length}');
    expect(successCount >= 4, isTrue);
  });
}
