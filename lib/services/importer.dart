import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../config/supported_formats.dart';
import '../models/import_result.dart';
import 'file_mover.dart';
import 'safe_paths.dart';
import 'title_parser.dart';
import 'version_parser.dart';
import 'zip_classifier.dart';

export '../models/import_result.dart';

/// Archive formats we can decode (via the `archive` package).
/// NOTE: 7z and rar are NOT decodable in-app — the `archive` package has no
/// decoders for them. They're still listed so the app can SEE those files and
/// guide the user to extract them with Android's built-in extractor.
const Set<String> kArchiveExtensions = SupportedFormats.archives;

/// Extracts a game archive into the organized library layout:
///
///   root/Game Title/
///     base files
///     update/
///       update files
///
/// DLC files (if any) go into a `dlc/` subfolder. After extraction it verifies
/// every archive entry exists on disk so the caller can safely delete the
/// archive. Only Switch ROM entries (.nsp/.xci/.nsz/.xcz/.nca) are extracted —
/// anything else in the archive is ignored.
class Importer {
  final String libraryRoot;

  Importer(this.libraryRoot);

  /// Resolves the game folder for [gameTitle]. If a folder with the same name
  /// already exists (case-insensitive), returns it so the import MERGES into
  /// the existing game instead of creating a duplicate folder. Otherwise
  /// returns the new path.
  String _resolveGameFolder(String gameTitle) {
    final safeTitle = SafePaths.gameFolderName(gameTitle);
    final root = Directory(libraryRoot);
    if (root.existsSync()) {
      final dirs = root
          .listSync(followLinks: false)
          .whereType<Directory>()
          .toList();

      // 1. Exact case-insensitive match.
      for (final e in dirs) {
        if (e.path.split('/').last.toLowerCase() == safeTitle.toLowerCase()) {
          return e.path;
        }
      }

    }
    return SafePaths.gameFolder(libraryRoot, safeTitle);
  }

  /// Imports [archivePath] into a new folder named [gameTitle] under
  /// [libraryRoot]. Returns the result; on failure, [ImportResult.error] is
  /// set. If the archive contains no Switch ROM files, [error] explains that.
  Future<ImportResult> importArchive(
    String archivePath,
    String gameTitle, {
    String? targetFolder,
  }) =>
      Isolate.run(
        () => _importArchiveSync(archivePath, gameTitle, targetFolder),
      );

  ImportResult _importArchiveSync(
    String archivePath,
    String gameTitle,
    String? targetFolder,
  ) {
    late final String gameFolder;
    try {
      gameFolder = targetFolder == null
          ? _resolveGameFolder(gameTitle)
          : SafePaths.existingGameFolder(libraryRoot, targetFolder);
      final bytes = File(archivePath).readAsBytesSync();
      final archive = _decode(archivePath, bytes);
      if (archive == null) {
        return _err(gameFolder, 'Not a valid archive (unsupported or corrupt).');
      }
      if (archive.isEmpty) {
        return _err(gameFolder, 'Archive is empty.');
      }

      // Validate: does the archive actually contain Switch ROM files?
      final romEntries = archive.files
          .where(
            (f) =>
                f.isFile &&
                SupportedFormats.switchRoms.contains(_ext(f.name)),
          )
          .toList();
      if (romEntries.isEmpty) {
        return _err(
          gameFolder,
          'No Switch ROM files (.nsp/.xci/.nsz/.xcz/.nca) found in this '
          'archive. Please provide a Switch ROM archive only.',
        );
      }

      // An archive with only updates/DLC and no base ROM must not create a
      // new folder on its own (would spawn an orphan "empty game").
      final hasBase = romEntries.any(
          (f) => ZipClassifier.classifyPath(f.name) == RomEntryKind.base);
      if (!hasBase && !Directory(gameFolder).existsSync()) {
        return _err(
          gameFolder,
          'This archive contains only updates/DLC, but no base game is in '
          'the library. Import the base game first.',
        );
      }

      Directory(gameFolder).createSync(recursive: true);
      String? titleId;
      final updateDir = p.join(gameFolder, 'update');
      final dlcDir = p.join(gameFolder, 'dlc');

      var base = 0, upd = 0, dlc = 0;
      for (final f in romEntries) {
        final kind = ZipClassifier.classifyPath(f.name);
        if (kind == RomEntryKind.base) {
          final entryId = TitleParser.titleId(f.name);
          if (entryId != null) {
            titleId = TitleParser.canonicalBaseTitleId(entryId);
          }
        }
        final destDir = switch (kind) {
          RomEntryKind.update => updateDir,
          RomEntryKind.dlc => dlcDir,
          _ => gameFolder,
        };
        Directory(destDir).createSync(recursive: true);
        final dest = p.join(destDir, p.basename(f.name));
        // Never overwrite an existing file — a duplicate basename (e.g. two
        // entries in different subfolders both named update.nsp) would
        // otherwise silently destroy the first one.
        if (File(dest).existsSync()) {
          continue;
        }
        File(dest).writeAsBytesSync(f.content);
        switch (kind) {
          case RomEntryKind.update:
            upd++;
          case RomEntryKind.dlc:
            dlc++;
          default:
            base++;
        }
      }

      final fully = _verify(romEntries, gameFolder);
      return ImportResult(
        gameFolder: gameFolder,
        baseFiles: base,
        updateFiles: upd,
        dlcFiles: dlc,
        fullyExtracted: fully,
        titleId: titleId,
      );
    } catch (e) {
      return _err(
        targetFolder ?? libraryRoot,
        _friendlyFileError(e),
      );
    }
  }

  /// Moves an already-extracted ROM file into the organized library layout.
  /// The file is classified (base/update/dlc) and placed in the game folder
  /// (or its update/ dlc/ subfolder), keeping its original filename.
  ///
  /// An update or DLC file requires an existing base-game folder — it is NOT
  /// allowed to create a new folder on its own, otherwise every update import
  /// spawns an orphan folder with no base ROM (which then shows up as an
  /// "empty game" in the library).
  Future<ImportResult> importFile(
    String filePath,
    String gameTitle, {
    String? targetFolder,
  }) =>
      Isolate.run(() => _importFileSync(filePath, gameTitle, targetFolder));

  ImportResult _importFileSync(
    String filePath,
    String gameTitle,
    String? targetFolder,
  ) {
    final kind = ZipClassifier.classifyPath(p.basename(filePath));
    late final String gameFolder;
    try {
      gameFolder = targetFolder == null
          ? _resolveGameFolder(gameTitle)
          : SafePaths.existingGameFolder(libraryRoot, targetFolder);
    } catch (e) {
      return _err(targetFolder ?? libraryRoot, _friendlyFileError(e));
    }

    // Update/DLC without an existing base-game folder -> refuse, don't create.
    if (kind != RomEntryKind.base && !Directory(gameFolder).existsSync()) {
      return _err(
        gameFolder,
        'No base game found for this ${kind == RomEntryKind.update ? 'update' : 'DLC'}. '
        'Import the base game first, or rename it to match an existing game.',
      );
    }

    try {
      final destDir = switch (kind) {
        RomEntryKind.update => p.join(gameFolder, 'update'),
        RomEntryKind.dlc => p.join(gameFolder, 'dlc'),
        _ => gameFolder,
      };
      Directory(destDir).createSync(recursive: true);
      final dest = p.join(destDir, p.basename(filePath));
      // Never overwrite an existing file — a loose ROM whose basename already
      // exists in the library (e.g. two regions both named Game.nsp) would
      // otherwise silently destroy the previous one.
      if (File(dest).existsSync()) {
        return _err(
          gameFolder,
          'A file named "${p.basename(filePath)}" already exists in this '
          'game. Rename it or remove the existing file first.',
        );
      }
      final sourceRemoved = FileMover.moveFile(filePath, dest);
      return ImportResult(
        gameFolder: gameFolder,
        baseFiles: kind == RomEntryKind.base ? 1 : 0,
        updateFiles: kind == RomEntryKind.update ? 1 : 0,
        dlcFiles: kind == RomEntryKind.dlc ? 1 : 0,
        fullyExtracted: true,
        titleId: kind == RomEntryKind.base
            ? TitleParser.titleId(p.basename(filePath))
            : null,
        warning: sourceRemoved
            ? null
            : 'The ROM was copied into the library, but Android would not '
                'remove the original file. You can delete the original '
                'manually after checking the library copy.',
      );
    } catch (e) {
      return _err(gameFolder, _friendlyFileError(e));
    }
  }

  /// Decodes [bytes] as an archive based on [path]'s extension. Returns null
  /// if the format is unsupported or the bytes are corrupt.
  Archive? _decode(String path, List<int> bytes) {
    final ext = _ext(path);
    try {
      switch (ext) {
        case '.zip':
          return ZipDecoder().decodeBytes(bytes, verify: false);
        case '.tar':
          return TarDecoder().decodeBytes(bytes);
        case '.gz' || '.tgz':
          return TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
        case '.bz2' || '.tbz2':
          return TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(bytes));
        case '.xz' || '.txz':
          return TarDecoder().decodeBytes(XZDecoder().decodeBytes(bytes));
        default:
          return null; // unsupported format (e.g. .7z)
      }
    } catch (_) {
      return null;
    }
  }

  /// True if every ROM entry in [entries] now exists on disk under [root]
  /// (base files at root, update/dlc in their subfolders).
  bool _verify(List<ArchiveFile> entries, String root) {
    for (final f in entries) {
      final kind = ZipClassifier.classifyPath(f.name);
      final dir = switch (kind) {
        RomEntryKind.update => p.join(root, 'update'),
        RomEntryKind.dlc => p.join(root, 'dlc'),
        _ => root,
      };
      if (!File(p.join(dir, p.basename(f.name))).existsSync()) {
        return false;
      }
    }
    return true;
  }

  /// Re-checks whether every ROM entry of the archive at [archivePath] is
  /// present under [gameFolder] (without re-extracting). Used to decide if the
  /// archive can be deleted after a partial extraction.
  Future<bool> verifyExtracted(String archivePath, String gameFolder) {
    return Isolate.run(() {
      try {
        final bytes = File(archivePath).readAsBytesSync();
        final archive = _decode(archivePath, bytes);
        if (archive == null || archive.isEmpty) return false;
        final romEntries = archive.files
            .where(
              (f) =>
                  f.isFile &&
                  SupportedFormats.switchRoms.contains(_ext(f.name)),
            )
            .toList();
        return _verify(romEntries, gameFolder);
      } catch (_) {
        return false;
      }
    });
  }

  ImportResult _err(String gameFolder, String message) => ImportResult(
        gameFolder: gameFolder,
        baseFiles: 0,
        updateFiles: 0,
        dlcFiles: 0,
        fullyExtracted: false,
        error: message,
      );

  /// Deletes old update files in a game's `update/` folder, keeping only the
  /// highest-versioned one. Returns the number of files deleted. Files with no
  /// parseable version are kept (never guessed). The base game is untouched.
  int deleteOldUpdates(String gameFolder) {
    final updateDir = Directory(p.join(gameFolder, 'update'));
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
      // "Game.v1.6.0" group together.
      final base = p
          .basenameWithoutExtension(f.path)
          .replaceAll(RegExp(r'v\d+(\.\d+)*', caseSensitive: false), '')
          .replaceAll(RegExp(r'[._\s]+$'), '')
          .trim();
      byBase.putIfAbsent(base, () => []).add(f);
    }

    var deleted = 0;
    for (final group in byBase.values) {
      if (group.length < 2) continue;
      group.sort((a, b) => VersionParser
          .parse(p.basename(b.path))!
          .compareTo(VersionParser.parse(p.basename(a.path))!));
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
        final hasBase = e.listSync(followLinks: false).any((f) => f is File);
        final hasUpdate = Directory(p.join(e.path, 'update')).existsSync();
        if (hasBase && !hasUpdate) missing.add(e.path);
      }
    }
    return missing;
  }

  /// Merges [sourceFolders] into [targetFolder], moving every file into the
  /// target's layout (base -> root, update/ -> update/, dlc/ -> dlc/), then
  /// deletes the now-empty source folders. Returns the number of files moved.
  /// Used to clean up duplicate game folders (e.g. an English and a Japanese
  /// copy of the same game, or a base/update split across two folders).
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
            FileMover.moveFile(e.path, dest);
            moved++;
          }
        } else if (e is Directory) {
          final sub = p.basename(e.path);
          if (sub == 'update' || sub == 'dlc') {
            final destDir = p.join(targetFolder, sub);
            Directory(destDir).createSync(recursive: true);
            for (final f in e.listSync(followLinks: false)) {
              if (f is File) {
                final dest = p.join(destDir, p.basename(f.path));
                if (!File(dest).existsSync()) {
                  FileMover.moveFile(f.path, dest);
                  moved++;
                }
              }
            }
          }
        }
      }
      // Remove the source folder if it's now empty (including empty
      // update/ dlc/ subdirs left behind after their files moved out).
      final remaining = srcDir.listSync(followLinks: false);
      final onlyEmptyDirs = remaining.every((e) =>
          e is Directory && e.listSync(followLinks: false).isEmpty);
      if (remaining.isEmpty || onlyEmptyDirs) {
        srcDir.deleteSync(recursive: true);
      }
    }
    return moved;
  }

  static String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i).toLowerCase();
  }

  static String _friendlyFileError(Object error) {
    if (error is FormatException) return error.message;
    if (error is FileSystemException) {
      final osMessage = error.osError?.message;
      final path = error.path;
      return [
        error.message,
        if (osMessage != null && osMessage.isNotEmpty) osMessage,
        if (path != null && path.isNotEmpty) path,
      ].join(' — ');
    }
    return error.toString();
  }
}
