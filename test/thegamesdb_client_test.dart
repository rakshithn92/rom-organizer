import 'dart:async';
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

  test('no Switch-platform match returns the first title without boxart',
      () async {
    final client = TheGamesDbClient(
      'test-key',
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'data': {
                'games': [
                  {'id': 7, 'game_title': 'Game (Genesis)', 'platform': 18},
                  {'id': 8, 'game_title': 'Game (NES)', 'platform': 7},
                ],
              },
              'include': {
                'boxart': {
                  'base_url': {'original': 'https://images.example/'},
                  'data': {
                    '7': [
                      {'type': 'boxart', 'side': 'front', 'filename': 'a.jpg'},
                    ],
                  },
                },
              },
            }),
            200,
          )),
    );

    final result = await client.search('Game');

    expect(result?.title, 'Game (Genesis)');
    expect(result?.boxartUrl, isNull);
    client.close();
  });

  test('picks front boxart for the Switch match', () async {
    final client = TheGamesDbClient(
      'test-key',
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'data': {
                'games': [
                  {'id': 7, 'game_title': 'Game (Genesis)', 'platform': 18},
                  {'id': 42, 'game_title': 'Game', 'platform': 4971},
                ],
              },
              'include': {
                'boxart': {
                  'base_url': {'original': 'https://images.example/'},
                  'data': {
                    '42': [
                      {
                        'type': 'boxart',
                        'side': 'back',
                        'filename': 'back.jpg',
                      },
                      {
                        'type': 'boxart',
                        'side': 'front',
                        'filename': 'front.jpg',
                      },
                      {
                        'type': 'fanart',
                        'side': 'front',
                        'filename': 'fan.jpg',
                      },
                    ],
                  },
                },
              },
            }),
            200,
          )),
    );

    final result = await client.search('Game');

    expect(result?.title, 'Game');
    expect(result?.boxartUrl, 'https://images.example/front.jpg');
    client.close();
  });

  test('falls back to the first boxart entry when no front-side art',
      () async {
    final client = TheGamesDbClient(
      'test-key',
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'data': {
                'games': [
                  {'id': 42, 'game_title': 'Game', 'platform': 4971},
                ],
              },
              'include': {
                'boxart': {
                  'base_url': {'original': 'https://images.example/'},
                  'data': {
                    '42': [
                      {
                        'type': 'boxart',
                        'side': 'back',
                        'filename': 'only.jpg',
                      },
                    ],
                  },
                },
              },
            }),
            200,
          )),
    );

    final result = await client.search('Game');

    expect(result?.title, 'Game');
    expect(result?.boxartUrl, 'https://images.example/only.jpg');
    client.close();
  });

  test('throws TimeoutException when the response outlasts the timeout',
      () async {
    final client = TheGamesDbClient(
      'test-key',
      client: _SlowClient(const Duration(seconds: 5)),
      timeout: const Duration(milliseconds: 20),
    );

    await expectLater(client.search('Game'), throwsA(isA<TimeoutException>()));
    client.close();
  });
}

/// An [http.Client] whose requests never resolve within a test's lifetime.
class _SlowClient extends http.BaseClient {
  _SlowClient(this.delay);

  final Duration delay;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.delayed(delay, () => throw StateError('request never completes'));
}
