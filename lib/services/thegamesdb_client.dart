import 'dart:convert';

import 'package:http/http.dart' as http;

/// A game title + cover art resolved from TheGamesDB.
class GameMetadata {
  final String title;
  final String? boxartUrl; // full-size boxart, if available
  const GameMetadata({required this.title, this.boxartUrl});
}

/// Client for TheGamesDB v1 API (https://api.thegamesdb.net).
///
/// Requires a free API key (https://thegamesdb.net -> account -> API key).
/// The key is supplied at runtime (from app settings), never hardcoded.
class TheGamesDbClient {
  static const _base = 'https://api.thegamesdb.net/v1';
  static const _switchPlatformId = 4971; // Nintendo Switch

  final String apiKey;
  final http.Client _http;

  TheGamesDbClient(this.apiKey, {http.Client? client})
      : _http = client ?? http.Client();

  /// Searches for a game by name and returns the best Switch-platform match,
  /// with its boxart. Returns null if nothing matches.
  Future<GameMetadata?> search(String query) async {
    final uri = Uri.parse('$_base/Games/ByGameName').replace(
      queryParameters: {
        'apikey': apiKey,
        'name': query,
        'fields': 'name',
        'include': 'boxart',
      },
    );
    final resp = await _http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>?;
    final games = data?['games'] as List<dynamic>?;
    if (games == null || games.isEmpty) return null;

    // Prefer a Switch-platform match; fall back to the first result.
    Map<String, dynamic>? pick;
    for (final g in games) {
      final game = g as Map<String, dynamic>;
      if (game['platform'] == _switchPlatformId) {
        pick = game;
        break;
      }
    }
    pick ??= games.first as Map<String, dynamic>;

    final id = pick['id']?.toString();
    final title = (pick['game_title'] ?? query) as String;

    // Boxart: include.boxart.base_url.original + include.boxart.data.<id>[].
    String? boxartUrl;
    final include = body['include'] as Map<String, dynamic>?;
    final boxart = include?['boxart'] as Map<String, dynamic>?;
    final baseUrl = (boxart?['base_url'] as Map<String, dynamic>?)?['original']
        as String?;
    final artData = (boxart?['data'] as Map<String, dynamic>?)?[id]
        as List<dynamic>?;
    if (baseUrl != null && artData != null) {
      for (final a in artData) {
        final m = a as Map<String, dynamic>;
        if (m['type'] == 'boxart' && m['side'] == 'front') {
          boxartUrl = '$baseUrl${m['filename']}';
          break;
        }
      }
      boxartUrl ??= '$baseUrl${artData.first['filename']}';
    }

    return GameMetadata(title: title, boxartUrl: boxartUrl);
  }

  void close() => _http.close();
}
