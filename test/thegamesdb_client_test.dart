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
}
