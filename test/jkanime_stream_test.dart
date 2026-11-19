import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/jkanime_service.dart';

void main() {
  test('JkAnimeService resolves stream URL for episode', () async {
    final svc = JkAnimeService();
    final sources = await svc.getEpisodeSources('cyberpunk-edgerunners-2', 1);
    print('JKAnime sources: ${sources.length}');
    for (final s in sources) {
      print('Source: ${s.quality} -> ${s.url}');
    }
    expect(sources.isNotEmpty, isTrue);
  });
}
