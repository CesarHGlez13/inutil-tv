import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/models/models.dart';

void main() {
  test('Benchmark channels_master.json parse speed', () {
    final sw = Stopwatch()..start();
    final file = File('assets/channels_master.json');
    expect(file.existsSync(), true);

    final str = file.readAsStringSync();
    final jsonList = json.decode(str) as List;
    final channels = jsonList.map((e) => Channel.fromJson(e as Map<String, dynamic>)).toList();

    sw.stop();
    print('SUCCESS: Parsed ${channels.length} channels in ${sw.elapsedMilliseconds} ms!');
    expect(channels.length, greaterThan(1000));
  });
}
