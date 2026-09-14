import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rom_organizer/services/thegamesdb_client.dart';

void main() {
  test('returns Switch metadata when the box-art list is empty', () async {
    final httpClient = MockClient((request) async {
      expect(request.url.queryParameters['apikey'], 'test-key');
      expect(request.url.queryParameters['name'], 'Game');
      return http.Response(
        jsonEncode({
          'data': {
            'games': [
              {'id': 42, 'game_title': 'Game', 'platform': 4971},
            ],
          },
          'include': {
            'boxart': {
              'base_url': {'original': 'https://images.example/'},
              'data': {'42': <Object>[]},
            },
          },
        }),
        200,
      );
    });
    final client = TheGamesDbClient('test-key', client: httpClient);

    final result = await client.search('Game');

    expect(result?.title, 'Game');
    expect(result?.boxartUrl, isNull);
    client.close();
  });

  test('throws TheGamesDbException on 401 (bad API key)', () async {
    final client = TheGamesDbClient(
      'bad-key',
      client: MockClient((_) async => http.Response('Unauthorized', 401)),
    );

    await expectLater(
      client.search('Game'),
      throwsA(isA<TheGamesDbException>()
          .having((e) => e.statusCode, 'statusCode', 401)),
    );
    client.close();
  });

  test('throws TheGamesDbException on 429 (rate limited)', () async {
    final client = TheGamesDbClient(
      'test-key',
      client: MockClient((_) async => http.Response('Too Many Requests', 429)),
    );

    await expectLater(
      client.search('Game'),
      throwsA(isA<TheGamesDbException>()
          .having((e) => e.statusCode, 'statusCode', 429)),
    );
    client.close();
  });

  test('returns null on 500 (transient server error)', () async {
    final client = TheGamesDbClient(
      'test-key',
      client: MockClient((_) async => http.Response('Server Error', 500)),
    );

    expect(await client.search('Game'), isNull);
    client.close();
  });

  test('returns null on malformed JSON with a 200 status', () async {
    final client = TheGamesDbClient(
      'test-key',
      client: MockClient((_) async => http.Response('<html>not json</html>', 200)),
    );

    expect(await client.search('Game'), isNull);
    client.close();
  });
}
