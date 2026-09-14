import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models/import_result.dart';
import 'file_mover.dart';
import 'import_utils.dart';
import 'safe_paths.dart';
import 'title_parser.dart';
import 'zip_classifier.dart';

/// Imports an already-extracted ROM file into the organized library layout.
///
/// Owns the game-folder resolution (title validation + sanitizing + merging
/// into an existing folder), which [ArchiveImporter] reuses via
/// [RomImportService.resolveGameFolder].
class RomImportService {
  final String libraryRoot;

  RomImportService(this.libraryRoot);

  /// Sanitizes a folder name for use as a filesystem path. Android's dart:io
  /// fails with EPERM on file operations when a path contains a colon (or other
  /// reserved chars), so replace them with a safe separator.
  static String sanitizeFolderName(String name) {
    return name
        .replaceAll(RegExp(r'[:/\\*?"<>|]'), ' - ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Resolves the game folder for [gameTitle]. Validates the title via
  /// [SafePaths] (rejects slashes/control chars), then sanitizes reserved
  /// filesystem chars (colons etc.) for the actual folder name. If a folder
  /// with the same sanitized name already exists (case-insensitive), returns
  /// it so the import MERGES into the existing game instead of creating a
  /// duplicate folder. Otherwise returns the new path.
  ///
  /// Static because both the loose-file import and the archive import need it
  /// and it depends only on [libraryRoot].
  static String resolveGameFolder(String libraryRoot, String gameTitle) {
    // Validate (throws on slashes/control chars) — keeps the title from
    // escaping the library root.
    SafePaths.gameFolderName(gameTitle);
    final safeTitle = sanitizeFolderName(gameTitle);
    final root = Directory(libraryRoot);
    if (root.existsSync()) {
      final dirs = root
          .listSync(followLinks: false)
          .whereType<Directory>()
          .toList();

      // Exact case-insensitive match (on sanitized names, so a folder
      // created with a colon still matches a title that has one).
      final sanitizedTitle = safeTitle.toLowerCase();
      for (final e in dirs) {
        if (sanitizeFolderName(e.path.split('/').last).toLowerCase() ==
            sanitizedTitle) {
          return e.path;
        }
      }
    }
    return p.join(libraryRoot, safeTitle);
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
  }) => Isolate.run(() => _importFileSync(filePath, gameTitle, targetFolder));

  ImportResult _importFileSync(
    String filePath,
    String gameTitle,
    String? targetFolder,
  ) {
    final kind = ZipClassifier.classifyPath(p.basename(filePath));
    late final String gameFolder;
    try {
      gameFolder = targetFolder == null
          ? resolveGameFolder(libraryRoot, gameTitle)
          : SafePaths.existingGameFolder(libraryRoot, targetFolder);
    } catch (e) {
      return importError(
        targetFolder ?? libraryRoot,
        friendlyFileError(e),
      );
    }

    // Update/DLC without an existing base-game folder -> refuse, don't create.
    if (kind != RomEntryKind.base && !Directory(gameFolder).existsSync()) {
      return importError(
        gameFolder,
        'No base game found for this ${kind == RomEntryKind.update ? 'update' : 'DLC'}. '
        'Import the base game first, or rename it to match an existing game.',
      );
    }

    try {
      final destDir = switch (kind) {
        RomEntryKind.update => p.join(gameFolder, kUpdateDir),
        RomEntryKind.dlc => p.join(gameFolder, kDlcDir),
        _ => gameFolder,
      };
      Directory(destDir).createSync(recursive: true);
      final dest = p.join(destDir, p.basename(filePath));
      // Never overwrite an existing file — a loose ROM whose basename already
      // exists in the library (e.g. two regions both named Game.nsp) would
      // otherwise silently destroy the previous one.
      if (File(dest).existsSync()) {
        return importError(
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
      return importError(gameFolder, friendlyFileError(e));
    }
  }
}
