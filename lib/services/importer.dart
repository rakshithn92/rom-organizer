import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'zip_classifier.dart';

/// Result of importing one zip.
class ImportResult {
  final String gameFolder; // absolute path of the created game folder
  final int baseFiles;
  final int updateFiles;
  final int dlcFiles;
  final bool fullyExtracted; // every zip entry now exists on disk
  final String? error;
  const ImportResult({
    required this.gameFolder,
    required this.baseFiles,
    required this.updateFiles,
    required this.dlcFiles,
    required this.fullyExtracted,
    this.error,
  });
}

/// Extracts a game zip into the organized library layout:
///
///   root/Game Title/
///     base files
///     update/
///       update files
///
/// DLC files (if any) go into a `dlc/` subfolder. After extraction it verifies
/// every zip entry exists on disk so the caller can safely delete the zip.
class Importer {
  final String libraryRoot;

  Importer(this.libraryRoot);

  /// Imports [zipPath] into a new folder named [gameTitle] under [libraryRoot].
  /// Returns the result; on failure, [ImportResult.error] is set.
  Future<ImportResult> importZip(String zipPath, String gameTitle) async {
    final gameFolder = p.join(libraryRoot, gameTitle);
    try {
      final bytes = await File(zipPath).readAsBytes();
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(bytes, verify: false);
      } catch (_) {
        return ImportResult(
          gameFolder: gameFolder,
          baseFiles: 0,
          updateFiles: 0,
          dlcFiles: 0,
          fullyExtracted: false,
          error: 'Not a valid zip archive.',
        );
      }
      if (archive.isEmpty) {
        return ImportResult(
          gameFolder: gameFolder,
          baseFiles: 0,
          updateFiles: 0,
          dlcFiles: 0,
          fullyExtracted: false,
          error: 'Not a valid zip archive.',
        );
      }

      Directory(gameFolder).createSync(recursive: true);
      final updateDir = p.join(gameFolder, 'update');
      final dlcDir = p.join(gameFolder, 'dlc');

      var base = 0, upd = 0, dlc = 0;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final kind = ZipClassifier.classifyPath(f.name);
        final destDir = switch (kind) {
          RomEntryKind.update => updateDir,
          RomEntryKind.dlc => dlcDir,
          _ => gameFolder,
        };
        Directory(destDir).createSync(recursive: true);
        final dest = p.join(destDir, p.basename(f.name));
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

      final fully = _verify(archive, gameFolder);
      return ImportResult(
        gameFolder: gameFolder,
        baseFiles: base,
        updateFiles: upd,
        dlcFiles: dlc,
        fullyExtracted: fully,
      );
    } catch (e) {
      return ImportResult(
        gameFolder: gameFolder,
        baseFiles: 0,
        updateFiles: 0,
        dlcFiles: 0,
        fullyExtracted: false,
        error: e.toString(),
      );
    }
  }

  /// True if every file entry in [archive] now exists on disk under [root]
  /// (base files at root, update/dlc in their subfolders).
  bool _verify(Archive archive, String root) {
    for (final f in archive.files) {
      if (!f.isFile) continue;
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

  /// Re-checks whether every entry of the zip at [zipPath] is present under
  /// [gameFolder] (without re-extracting). Used to decide if the zip can be
  /// deleted after a partial extraction.
  Future<bool> verifyExtracted(String zipPath, String gameFolder) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      if (archive.isEmpty) return false;
      return _verify(archive, gameFolder);
    } catch (_) {
      return false;
    }
  }
}
