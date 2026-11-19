import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

String formatCookieHeader(String setCookie) {
  final cookies = <String>[];
  final parts = setCookie.split(RegExp(r',\s*(?=[a-zA-Z0-9_\-]+=[^;]+)'));
  for (final p in parts) {
    final firstPart = p.split(';').first.trim();
    if (firstPart.contains('=')) {
      cookies.add(firstPart);
    }
  }
  return cookies.join('; ');
}

void main() {
  test('Test JKAnime ajax_search with properly formatted Cookie header', () async {
    final client = http.Client();
    final homeRes = await client.get(
      Uri.parse('https://jkanime.net/'),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      },
    );
    final rawCookie = homeRes.headers['set-cookie'] ?? '';
    final cookieHeader = formatCookieHeader(rawCookie);
    final tokenMatch = RegExp(r'''name="csrf-token"\s+content="([^"]+)"''').firstMatch(homeRes.body);
    final csrfToken = tokenMatch?.group(1) ?? '';
    print('Cookie Header: $cookieHeader');
    print('CSRF Token: $csrfToken');

    final searchRes = await client.post(
      Uri.parse('https://jkanime.net/ajax_search'),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        'Referer': 'https://jkanime.net/',
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRF-TOKEN': csrfToken,
        if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      },
      body: {
        '_token': csrfToken,
        'q': 'naruto',
      },
    );

    print('Search Status: ${searchRes.statusCode}');
    if (searchRes.statusCode == 200) {
      final json = jsonDecode(searchRes.body) as List;
      print('SUCCESS! Found ${json.length} anime results:');
      for (final item in json.take(5)) {
        print('  - ${item['title']} (${item['slug']})');
      }
    } else {
      print('Failed body: ${searchRes.body.substring(0, 100)}');
    }
  });
}
