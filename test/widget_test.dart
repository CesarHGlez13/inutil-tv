import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/m3u_parser.dart';

void main() {
  test('parsea una lista M3U extendida', () {
    const content = '''
#EXTM3U
#EXTINF:-1 tvg-id="az" tvg-logo="http://x/logo.png" group-title="Noticias",Canal Z
http://example.com/z.m3u8
#EXTINF:-1,Radio suelta
http://example.com/radio.mp3
''';
    final chs = M3uParser.parse(content);
    expect(chs.length, 2);
    expect(chs[0].name, 'Canal Z');
    expect(chs[0].group, 'Noticias');
    expect(chs[0].logo, 'http://x/logo.png');
    expect(chs[0].primaryUrl, 'http://example.com/z.m3u8');
    expect(chs[1].name, 'Radio suelta');
  });
}
