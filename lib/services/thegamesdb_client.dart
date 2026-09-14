import 'dart:convert';

import 'package:http/http.dart' as http;

/// A game title + cover art resolved from TheGamesDB.
class GameMetadata {
  final String title;
  final String? boxartUrl; // full-size boxart, if available
  const GameMetadata({required this.title, this.boxartUrl});
}

/// Raised when TheGamesDB rejects a request for a reason the user can act on:
/// a bad/forbidden API key (401/403) or a rate limit (429).
///
/// Transient failures (5xx, network errors, malformed responses) are reported
/// as "no result" (`null`) instead, so callers only surface this to the user
/// when the fix is on their side.
class TheGamesDbException implements Exception {
  final int? statusCode;
  final String message;

  const TheGamesDbException(this.statusCode, this.message);

  @override
  String toString() => statusCode == null
      ? 'TheGamesDbException: $message'
      : 'TheGamesDbException($statusCode): $message';
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
  final Duration timeout;

  TheGamesDbClient(
    this.apiKey, {
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _http = client ?? http.Client();

  /// Performs a one-off lookup and always releases its HTTP client.
  static Future<GameMetadata?> searchOnce(String apiKey, String query) async {
    final client = TheGamesDbClient(apiKey);
    try {
      return await client.search(query);
    } finally {
      client.close();
    }
  }

  /// Searches for a game by name and returns the best Switch-platform match,
  /// with its boxart. Returns null if nothing matches, or if the request fails
  /// transiently (5xx/network/malformed JSON).
  ///
  /// Throws [TheGamesDbException] when the API key is rejected (401/403) or the
  /// rate limit is hit (429).
  Future<GameMetadata?> search(String query) async {
    final uri = Uri.parse('$_base/Games/ByGameName').replace(
      queryParameters: {
        'apikey': apiKey,
        'name': query,
        'fields': 'name',
        'include': 'boxart',
      },
    );
    final resp = await _http.get(uri).timeout(timeout);
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw TheGamesDbException(
        resp.statusCode,
        'TheGamesDB rejected the API key (HTTP ${resp.statusCode}). '
        'Check the key in Settings.',
      );
    }
    if (resp.statusCode == 429) {
      throw TheGamesDbException(
        resp.statusCode,
        'TheGamesDB rate limit reached. Try again later.',
      );
    }
    if (resp.statusCode != 200) return null;

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null; // malformed/unexpected body: treat as no result
    }
    final data = body['data'] as Map<String, dynamic>?;
    final games = data?['games'] as List<dynamic>?;
    if (games == null || games.isEmpty) return null;

    // Prefer a Switch-platform match. Only a Switch match's boxart is shown —
    // a wrong-platform fallback would show a mismatched cover (e.g. Pokemon
    // Crystal showing Pokemon Gold's boxart).
    Map<String, dynamic>? pick;
    for (final g in games) {
      final game = g as Map<String, dynamic>;
      if (game['platform'] == _switchPlatformId) {
        pick = game;
        break;
      }
    }
    if (pick == null) {
      // No Switch match — return the first title but NO boxart, so the app
      // never shows a cover for the wrong game.
      final first = games.first as Map<String, dynamic>;
      return GameMetadata(
        title: (first['game_title'] ?? query) as String,
        boxartUrl: null,
      );
    }

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
    if (baseUrl != null && artData != null && artData.isNotEmpty) {
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
