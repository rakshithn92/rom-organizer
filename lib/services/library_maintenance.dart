import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/supported_formats.dart';
import 'file_mover.dart';
import 'import_utils.dart';
import 'version_parser.dart';

/// Housekeeping over an already-imported library: pruning superseded update
/// files, reporting games whose update is missing, and merging duplicate game
/// folders. Every operation is non-destructive to ROM content that is still
/// referenced (the newest update and the base game are never touched).
class LibraryMaintenance {
  final String libraryRoot;

  LibraryMaintenance(this.libraryRoot);

  /// Deletes old update files in a game's `update/` folder, keeping only the
  /// highest-versioned one. Returns the number of files deleted. Files with no
  /// parseable version are kept (never guessed). The base game is untouched.
  int deleteOldUpdates(String gameFolder) {
    final updateDir = Directory(p.join(gameFolder, kUpdateDir));
    if (!updateDir.existsSync()) return 0;

    final updates = <File>[];
    for (final e in updateDir.listSync(followLinks: false)) {
      if (e is File) updates.add(e);
    }
    if (updates.length < 2) return 0;

    // Group by base name (strip version), keep the highest version per group.
    final byBase = <String, List<File>>{};
    for (final f in updates) {
      final v = VersionParser.parse(p.basename(f.path));
      if (v == null) continue; // never touch unparseable files
      // Normalize the base name: strip the version, then any trailing
      // separator (dot/underscore/space) so "Game.Update.v1.6.0" and
      // "Game.v1.6.0" group together. Also strip a trailing update marker so
      // "Game Update v1.6.0" and "Game v1.5.0" group together (DLC is not
      // stripped — it lives in a different folder and would over-merge).
      final base = VersionParser.stripVersionTag(
        p.basenameWithoutExtension(f.path),
      )
          .replaceAll(RegExp(r'[._\s]+$'), '')
          .replaceAll(
            RegExp(r'[._\s]*(update|upd|patch)$', caseSensitive: false),
            '',
          )
          .trim();
      byBase.putIfAbsent(base, () => []).add(f);
    }

    var deleted = 0;
    for (final group in byBase.values) {
      if (group.length < 2) continue;
      group.sort(
        (a, b) => VersionParser.parse(
          p.basename(b.path),
        )!.compareTo(VersionParser.parse(p.basename(a.path))!),
      );
      for (final old in group.skip(1)) {
        try {
          old.deleteSync();
          deleted++;
        } catch (_) {
          // Skip files that fail to delete.
        }
      }
    }
    return deleted;
  }

  /// Returns the paths of game folders that have a base file but no `update/`
  /// folder (i.e. the game is missing its update).
  List<String> findMissingUpdates() {
    final root = Directory(libraryRoot);
    if (!root.existsSync()) return [];
    final missing = <String>[];
    for (final e in root.listSync(followLinks: false)) {
      if (e is Directory) {
        // Only a Switch ROM counts as a base — a folder holding just a
        // cover.jpg/readme.txt is not a game missing its update.
        final hasBase = e
            .listSync(followLinks: false)
            .any(
              (f) =>
                  f is File &&
                  SupportedFormats.switchRoms.contains(archiveExtOf(f.path)),
            );
        final hasUpdate = Directory(p.join(e.path, kUpdateDir)).existsSync();
        if (hasBase && !hasUpdate) missing.add(e.path);
      }
    }
    return missing;
  }

  /// Merges [sourceFolders] into [targetFolder], moving every file into the
  /// target's layout (base -> root, update/ -> update/, dlc/ -> dlc/), then
  /// deletes the now-empty source folders. Returns the number of files moved.
  /// A file whose move throws is skipped and left in the source (so the
  /// empty-folder check below never deletes it); the merge continues with the
  /// rest. Used to clean up duplicate game folders (e.g. an English and a
  /// Japanese copy of the same game, or a base/update split across two
  /// folders).
  int mergeGames(String targetFolder, List<String> sourceFolders) {
    var moved = 0;
    for (final src in sourceFolders) {
      if (src == targetFolder) continue;
      final srcDir = Directory(src);
      if (!srcDir.existsSync()) continue;
      for (final e in srcDir.listSync(followLinks: false)) {
        if (e is File) {
          final dest = p.join(targetFolder, p.basename(e.path));
          if (!File(dest).existsSync()) {
            try {
              FileMover.moveFile(e.path, dest);
              moved++;
            } catch (_) {
              // Leave the file in the source; skip it and keep going.
            }
          }
        } else if (e is Directory) {
          final sub = p.basename(e.path);
          if (sub == kUpdateDir || sub == kDlcDir) {
            final destDir = p.join(targetFolder, sub);
            Directory(destDir).createSync(recursive: true);
            for (final f in e.listSync(followLinks: false)) {
              if (f is File) {
                final dest = p.join(destDir, p.basename(f.path));
                if (!File(dest).existsSync()) {
                  try {
                    FileMover.moveFile(f.path, dest);
                    moved++;
                  } catch (_) {
                    // Leave the file in the source; skip it and keep going.
                  }
                }
              }
            }
          }
        }
      }
      // Remove the source folder if it's now empty (including empty
      // update/ dlc/ subdirs left behind after their files moved out).
      final remaining = srcDir.listSync(followLinks: false);
      final onlyEmptyDirs = remaining.every(
        (e) => e is Directory && e.listSync(followLinks: false).isEmpty,
      );
      if (remaining.isEmpty || onlyEmptyDirs) {
        srcDir.deleteSync(recursive: true);
      }
    }
    return moved;
  }
}
