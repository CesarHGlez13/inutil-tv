import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/pelisflix_service.dart';

void main() {
  test('PelisflixService resolves stream URL for real movie', () async {
    final svc = PelisflixService();
    final url = await svc.resolveStreamUrl('godzilla-minus-zero');
    print('Pelisflix test resolved URL: $url');
    expect(url, isNotNull);
    expect(url!.contains('.m3u8'), isTrue);
  });
}
