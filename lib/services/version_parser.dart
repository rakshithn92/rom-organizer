/// Parses a version number out of a Switch ROM/update filename.
///
/// Handles the common formats:
///   - `Game.Update.v1.6.0.nsp`  -> 1.6.0
///   - `Game.v1.6.0.nsp`         -> 1.6.0
///   - `Game[0100...][v0].nsp`   -> 0
///   - `Game (v1.2.3).nsp`       -> 1.2.3
///
/// Returns null if no version is found.
class VersionParser {
  // Match vX.Y.Z where the char before 'v' is a non-digit (space, dot,
  // underscore, bracket, start-of-string). A plain \b fails when 'v' is
  // preceded by '_' (a word char), e.g. Game_v1.6.0.nsp.
  static final _vTag = RegExp(r'(?<![0-9])v(\d+(?:\.\d+)*)', caseSensitive: false);
  static final _bracketV = RegExp(r'\[v(\d+)\]', caseSensitive: false);

  /// Extracts the version as a comparable [Version] from [fileName].
  /// Returns null if none is present.
  static Version? parse(String fileName) {
    // Prefer the bracketed [vN] form (title-id style), then the vX.Y.Z form.
    final bracket = _bracketV.firstMatch(fileName);
    if (bracket != null) {
      return Version.fromString(bracket.group(1)!);
    }
    final v = _vTag.firstMatch(fileName);
    if (v != null) {
      return Version.fromString(v.group(1)!);
    }
    return null;
  }
}

/// A comparable semantic-ish version. Holds every numeric component found
/// (`v1.2.3.4` keeps four), because truncating to three made e.g. `v1.2.3.1`
/// and `v1.2.3.2` compare equal and deleteOldUpdates would then keep an
/// arbitrary one of the pair.
class Version implements Comparable<Version> {
  final List<int> components;

  const Version(this.components);

  factory Version.fromString(String s) => Version(
        s.split('.').map((part) => int.tryParse(part) ?? 0).toList(),
      );

  /// Pads both component lists to a common length with zeros, so `1.6`
  /// compares equal to `1.6.0` and less than `1.6.1`.
  @override
  int compareTo(Version other) {
    final len = components.length > other.components.length
        ? components.length
        : other.components.length;
    for (var i = 0; i < len; i++) {
      final a = i < components.length ? components[i] : 0;
      final b = i < other.components.length ? other.components[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(components);

  @override
  String toString() => components.join('.');
}
