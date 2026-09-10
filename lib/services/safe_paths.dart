import 'package:path/path.dart' as p;

/// Validates user/API supplied folder names before filesystem operations.
abstract final class SafePaths {
  static final _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');
  static final _separators = RegExp(r'[/\\]');

  /// Produces a safe single path component or throws a user-readable error.
  static String gameFolderName(String input) {
    final value = input.trim();
    if (value.isEmpty) throw const FormatException('Game title cannot be empty.');
    if (value == '.' || value == '..') {
      throw const FormatException('Game title cannot be "." or "..".');
    }
    if (_separators.hasMatch(value) || _controlCharacters.hasMatch(value)) {
      throw const FormatException(
        'Game title cannot contain slashes or control characters.',
      );
    }
    if (value.length > 180) {
      throw const FormatException('Game title is too long.');
    }
    return value;
  }

  /// Joins [root] and a validated game title and verifies containment.
  static String gameFolder(String root, String title) {
    final result = p.normalize(p.join(root, gameFolderName(title)));
    return existingGameFolder(root, result);
  }

  /// Validates a previously persisted or explicitly selected game-folder path.
  static String existingGameFolder(String root, String candidate) {
    final normalizedRoot = p.normalize(p.absolute(root));
    final result = p.normalize(p.absolute(candidate));
    if (!p.isWithin(normalizedRoot, result)) {
      throw const FormatException('Game folder must stay inside the library.');
    }
    return result;
  }
}
