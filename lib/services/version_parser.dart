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
  static final _vTag = RegExp(r'v(\d+(?:\.\d+)*)', caseSensitive: false);
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

/// A comparable semantic-ish version (major.minor.patch).
class Version implements Comparable<Version> {
  final int major;
  final int minor;
  final int patch;

  const Version(this.major, this.minor, this.patch);

  factory Version.fromString(String s) {
    final parts = s.split('.');
    int get(int i) => i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0;
    return Version(get(0), get(1), get(2));
  }

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch';
}
