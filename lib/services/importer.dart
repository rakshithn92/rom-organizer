import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'rom_scanner.dart';
import 'zip_classifier.dart';

/// Result of importing one archive.
class ImportResult {
  final String gameFolder; // absolute path of the created game folder
  final int baseFiles;
  final int updateFiles;
  final int dlcFiles;
  final bool fullyExtracted; // every archive entry now exists on disk
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

/// Archive formats we can decode (via the `archive` package).
/// NOTE: 7z and rar are NOT decodable in-app — the `archive` package has no
/// decoders for them. They're still listed so the app can SEE those files and
/// guide the user to extract them with Android's built-in extractor.
const Set<String> kArchiveExtensions = {
  '.zip', '.tar', '.gz', '.tgz', '.bz2', '.tbz2', '.xz', '.txz', '.7z', '.rar',
};

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
    final root = Directory(libraryRoot);
    if (root.existsSync()) {
      for (final e in root.listSync(followLinks: false)) {
        if (e is Directory &&
            e.path.split('/').last.toLowerCase() == gameTitle.toLowerCase()) {
          return e.path;
        }
      }
    }
    return p.join(libraryRoot, gameTitle);
  }

  /// Imports [archivePath] into a new folder named [gameTitle] under
  /// [libraryRoot]. Returns the result; on failure, [ImportResult.error] is
  /// set. If the archive contains no Switch ROM files, [error] explains that.
  Future<ImportResult> importArchive(String archivePath, String gameTitle) async {
    final gameFolder = _resolveGameFolder(gameTitle);
    try {
      final bytes = await File(archivePath).readAsBytes();
      final archive = _decode(archivePath, bytes);
      if (archive == null) {
        return _err(gameFolder, 'Not a valid archive (unsupported or corrupt).');
      }
      if (archive.isEmpty) {
        return _err(gameFolder, 'Archive is empty.');
      }

      // Validate: does the archive actually contain Switch ROM files?
      final romEntries = archive.files.where((f) =>
          f.isFile && kSwitchRomExtensions.contains(_ext(f.name))).toList();
      if (romEntries.isEmpty) {
        return _err(
          gameFolder,
          'No Switch ROM files (.nsp/.xci/.nsz/.xcz/.nca) found in this '
          'archive. Please provide a Switch ROM archive only.',
        );
      }

      Directory(gameFolder).createSync(recursive: true);
      final updateDir = p.join(gameFolder, 'update');
      final dlcDir = p.join(gameFolder, 'dlc');

      var base = 0, upd = 0, dlc = 0;
      for (final f in romEntries) {
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

      final fully = _verify(romEntries, gameFolder);
      return ImportResult(
        gameFolder: gameFolder,
        baseFiles: base,
        updateFiles: upd,
        dlcFiles: dlc,
        fullyExtracted: fully,
      );
    } catch (e) {
      return _err(gameFolder, e.toString());
    }
  }

  /// Moves an already-extracted ROM file into the organized library layout.
  /// The file is classified (base/update/dlc) and placed in the game folder
  /// (or its update/ dlc/ subfolder), keeping its original filename.
  Future<ImportResult> importFile(String filePath, String gameTitle) async {
    final gameFolder = _resolveGameFolder(gameTitle);
    try {
      final kind = ZipClassifier.classifyPath(p.basename(filePath));
      final destDir = switch (kind) {
        RomEntryKind.update => p.join(gameFolder, 'update'),
        RomEntryKind.dlc => p.join(gameFolder, 'dlc'),
        _ => gameFolder,
      };
      Directory(destDir).createSync(recursive: true);
      final dest = p.join(destDir, p.basename(filePath));
      File(filePath).renameSync(dest);
      return ImportResult(
        gameFolder: gameFolder,
        baseFiles: kind == RomEntryKind.base ? 1 : 0,
        updateFiles: kind == RomEntryKind.update ? 1 : 0,
        dlcFiles: kind == RomEntryKind.dlc ? 1 : 0,
        fullyExtracted: true,
      );
    } catch (e) {
      return _err(gameFolder, e.toString());
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
  Future<bool> verifyExtracted(String archivePath, String gameFolder) async {
    try {
      final bytes = await File(archivePath).readAsBytes();
      final archive = _decode(archivePath, bytes);
      if (archive == null || archive.isEmpty) return false;
      final romEntries = archive.files.where((f) =>
          f.isFile && kSwitchRomExtensions.contains(_ext(f.name))).toList();
      return _verify(romEntries, gameFolder);
    } catch (_) {
      return false;
    }
  }

  ImportResult _err(String gameFolder, String message) => ImportResult(
        gameFolder: gameFolder,
        baseFiles: 0,
        updateFiles: 0,
        dlcFiles: 0,
        fullyExtracted: false,
        error: message,
      );

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
            e.renameSync(dest);
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
                  f.renameSync(dest);
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
}
