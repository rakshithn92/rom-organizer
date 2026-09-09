/// Parses a ROM filename into a clean searchable game title.
///
/// Strips common Switch release noise: region tags ([USA], (EUR), [EU]),
/// version tags (v1.6.0, Update), title-IDs (0100...), and file extensions.
class TitleParser {
  static final _bracketTag = RegExp(r'\[[^\]]*\]');
  static final _parenTag = RegExp(r'\([^)]*\)');
  // Match vX.Y.Z where the char before 'v' is a non-digit (space, dot,
  // underscore, bracket, start-of-string). A plain \b fails when 'v' is
  // preceded by '_' (a word char), e.g. Game_v1.6.0.nsp.
  static final _versionTag =
      RegExp(r'(?<![0-9])v\d+(\.\d+)*', caseSensitive: false);
  static final _updateWord = RegExp(r'\b(update|upd|patch|dlc|addon)\b',
      caseSensitive: false);
  static final _titleId = RegExp(r'0100[0-9A-Fa-f]{8,}');

  /// Returns a clean title for [fileName] (with or without extension).
  static String clean(String fileName) {
    var s = fileName.trim();
    // Drop extension.
    final dot = s.lastIndexOf('.');
    if (dot > 0 && s.substring(dot).length <= 5) {
      s = s.substring(0, dot);
    }

    // Strip markers that contain dots BEFORE converting dots to spaces,
    // otherwise "v1.3.0" becomes "v1 3 0" and the regex misses it.
    s = s.replaceAll(_titleId, ' ');
    s = s.replaceAll(_versionTag, ' ');
    s = s.replaceAll(_bracketTag, ' ');
    s = s.replaceAll(_parenTag, ' ');

    // Now dots/underscores are safe to turn into spaces.
    s = s.replaceAll('.', ' ').replaceAll('_', ' ');

    // Strip update/dlc words (no dots involved).
    s = s.replaceAll(_updateWord, ' ');

    // Collapse whitespace.
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }
}
