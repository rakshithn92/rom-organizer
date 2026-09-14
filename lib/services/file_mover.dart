import 'dart:io';

import 'package:path/path.dart' as p;

/// Centralized, non-overwriting file and directory move operations.
abstract final class FileMover {
  /// Returns whether the original was removed. A `false` result means the
  /// destination copy is complete but Android refused to delete the source.
  static bool moveFile(String source, String destination) {
    if (File(destination).existsSync()) {
      throw FileSystemException('Destination file already exists', destination);
    }
    // `renameSync` would silently REPLACE an existing destination, so two
    // concurrent moves racing the exists-check could destroy the first
    // winner's file. An exclusive claim prevents that: a non-empty claim
    // directory can only be renamed into place once (POSIX rename onto a
    // non-empty directory fails), and it is released when the move ends.
    final claim = _claim(destination);
    try {
      try {
        File(source).renameSync(destination);
        return true;
      } on FileSystemException {
        try {
          File(source).copySync(destination);
        } on FileSystemException {
          // A failed fallback must leave the original intact and remove only
          // the incomplete copy produced by this operation; otherwise a
          // retry would see a corrupt destination and refuse with
          // "already exists".
          final partial = File(destination);
          if (partial.existsSync()) partial.deleteSync();
          rethrow;
        }
        try {
          File(source).deleteSync();
          return true;
        } on FileSystemException {
          // The copy is complete; Android just refused to remove the source.
          return false;
        }
      }
    } finally {
      _release(claim);
    }
  }

  /// Atomically reserves [destination] for this move. Throws when a
  /// concurrent move holds the claim (the publish rename onto a non-empty
  /// claim directory fails, giving exclusive-create semantics).
  static Directory _claim(String destination) {
    final fixed = '$destination.claim';
    final staging = Directory(
      '$fixed.${DateTime.now().microsecondsSinceEpoch}.${_claimSeq++}',
    )..createSync(recursive: true);
    // A marker makes the staging dir non-empty, so the publish rename can
    // only ever land on a fixed path that is absent or empty (a stale claim
    // from a crashed run is always empty and thus self-healing).
    File(p.join(staging.path, 'held')).writeAsBytesSync(const []);
    staging.renameSync(fixed);
    return staging;
  }

  /// Releases a claim: removes the fixed claim path (best effort — it may
  /// already be gone).
  static void _release(Directory staging) {
    final fixed = staging.path.substring(0, staging.path.indexOf('.claim.'));
    try {
      Directory('$fixed.claim').deleteSync(recursive: true);
    } catch (_) {}
  }

  static int _claimSeq = 0;
  static void moveDirectory(String source, String destination) {
    if (Directory(destination).existsSync()) {
      throw FileSystemException(
        'Destination directory already exists',
        destination,
      );
    }
    try {
      Directory(source).renameSync(destination);
    } on FileSystemException {
      try {
        _copyDirectory(Directory(source), destination);
        Directory(source).deleteSync(recursive: true);
      } catch (_) {
        // A failed fallback must leave the original intact and remove only the
        // incomplete copy produced by this operation.
        final partial = Directory(destination);
        if (partial.existsSync()) partial.deleteSync(recursive: true);
        rethrow;
      }
    }
  }

  static void _copyDirectory(Directory source, String destination) {
    Directory(destination).createSync(recursive: true);
    for (final entry in source.listSync(followLinks: false)) {
      final target = p.join(destination, p.basename(entry.path));
      if (entry is File) {
        entry.copySync(target);
      } else if (entry is Directory) {
        _copyDirectory(entry, target);
      }
    }
  }
}
