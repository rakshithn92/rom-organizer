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
    try {
      File(source).renameSync(destination);
      return true;
    } on FileSystemException {
      try {
        File(source).copySync(destination);
      } on FileSystemException {
        // A failed fallback must leave the original intact and remove only the
        // incomplete copy produced by this operation; otherwise a retry would
        // see a corrupt destination and refuse with "already exists".
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
  }

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
