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
/// every archive entry exists on disk (at its recorded size) so the caller can
/// safely delete the archive. Only Switch ROM entries (.nsp/.xci/.nsz/.xcz/
/// .nca) are extracted — anything else in the archive is ignored.
///
/// Archives are read from disk lazily (streaming): entries are decompressed
/// straight to destination files in bounded chunks, so peak memory stays
/// small no matter how large the archive is. Every written entry is checked
/// against the archive's recorded size (and CRC-32 when the format stores
/// one) before it is renamed to its final name, so a truncated or corrupted
/// download is rejected instead of certified as fully extracted.
class Importer {
  final String libraryRoot;

  Importer(this.libraryRoot);

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
  String _resolveGameFolder(String gameTitle) {
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

  /// Imports [archivePath] into a new folder named [gameTitle] under
  /// [libraryRoot]. Returns the result; on failure, [ImportResult.error] is
  /// set. If the archive contains no Switch ROM files, [error] explains that.
  Future<ImportResult> importArchive(
    String archivePath,
    String gameTitle, {
    String? targetFolder,
  }) => Isolate.run(
    () => _importArchiveSync(archivePath, gameTitle, targetFolder),
  );

  ImportResult _importArchiveSync(
    String archivePath,
    String gameTitle,
    String? targetFolder,
  ) {
    late final String gameFolder;
    final tempFiles = <String>[];
    try {
      gameFolder = targetFolder == null
          ? _resolveGameFolder(gameTitle)
          : SafePaths.existingGameFolder(libraryRoot, targetFolder);
      // Stream the archive from disk: entries stay file-backed views and are
      // decompressed on demand, so peak memory is ~1 MB regardless of size
      // (Switch ROM archives are routinely multi-GB — a full in-RAM decode
      // would OOM-kill the app).
      final decoded = _openArchive(archivePath, tempFiles);
      final archive = decoded?.archive;
      if (archive == null) {
        return _err(
          gameFolder,
          'Not a valid archive (unsupported or corrupt).',
        );
      }
      if (archive.isEmpty) {
        return _err(gameFolder, 'Archive is empty.');
      }
      final romEntries = archive.files
          .where(
            (f) =>
                f.isFile && SupportedFormats.switchRoms.contains(_ext(f.name)),
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
        (f) => ZipClassifier.classifyPath(f.name) == RomEntryKind.base,
      );
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
      final skipped = <String>{};
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
          // A same-named file already existed, so THIS archive entry was not
          // written. Its bytes are not on disk — an exists-only check would be
          // fooled by the pre-existing file and wrongly certify extraction.
          skipped.add(f.name);
          continue;
        }
        // Stream to a .tmp then rename: a truncated write (crash/disk full)
        // can never be mistaken for a complete file by _verify, because the
        // final name only appears after the full content is on disk.
        final tmpDest = '$dest.import-tmp';
        if (!_writeEntry(f, tmpDest)) {
          return _err(
            gameFolder,
            'Archive entry "${f.name}" is corrupt (checksum mismatch). '
            'The file was not imported; the archive was not modified.',
          );
        }
        File(tmpDest).renameSync(dest);
        switch (kind) {
          case RomEntryKind.update:
            upd++;
          case RomEntryKind.dlc:
            dlc++;
          default:
            base++;
        }
      }

      final fully = skipped.isEmpty && _verify(romEntries, gameFolder);
      return ImportResult(
        gameFolder: gameFolder,
        baseFiles: base,
        updateFiles: upd,
        dlcFiles: dlc,
        fullyExtracted: fully,
        titleId: titleId,
      );
    } catch (e) {
      return _err(targetFolder ?? libraryRoot, _friendlyFileError(e));
    } finally {
      for (final tmp in tempFiles) {
        try {
          File(tmp).deleteSync();
        } catch (_) {
          // Best effort; the OS temp dir is cleaned periodically anyway.
        }
      }
    }
  }

  /// Opens an archive lazily and returns it with any input streams that must
  /// stay open while its entries are read. For gz/bz2/xz the decompressed tar
  /// is materialized into a temp file (also returned in [tempFiles] so the
  /// caller can delete it once done); its entries then stream from that file.
  _OpenArchive? _openArchive(String archivePath, List<String> tempFiles) {
    final ext = _ext(archivePath);
    switch (ext) {
      case '.zip':
      case '.tar':
        final input = InputFileStream(archivePath);
        try {
          final archive = ext == '.zip'
              ? ZipDecoder().decodeStream(input)
              : TarDecoder().decodeStream(input);
          return _OpenArchive(archive, inputs: [input]);
        } catch (_) {
          input.closeSync();
          return null;
        }
      case '.gz' || '.tgz':
      case '.bz2' || '.tbz2':
      case '.xz' || '.txz':
        final isXz = ext == '.xz' || ext == '.txz';
        final tmpTar = '$archivePath.extract-tmp';
        final input = InputFileStream(archivePath);
        final out = OutputFileStream(tmpTar);
        // Register the temp file before decoding so the caller's cleanup still
        // removes it when the decode or the tar parse below fails.
        tempFiles.add(tmpTar);
        try {
          // verify: true checks the container's own checksum while decoding,
          // catching truncated or corrupted downloads before the tar is even
          // parsed. Gzip throws a FormatException on corruption; gzip and
          // bzip2 also report corruption by returning false.
          //
          // xz must NOT be gated on the return value: in archive 4.2.0 the
          // stream index stores its record lengths as multibyte integers that
          // the encoder writes high-bits-first while the decoder reads them
          // low-bits-first, so every record of 128 or more fails index
          // validation. Any xz written by the package's own XZEncoder is
          // therefore reported as false even though its block data decoded
          // normally (which is also why verify: true buys nothing for xz).
          // The decode is still run, but for xz only an exception counts as a
          // failure here; the result is validated below instead. The real
          // content gate is downstream in _writeEntry (per-entry size +
          // CRC-32).
          final ok = switch (ext) {
            '.gz' ||
            '.tgz' => GZipDecoder().decodeStream(input, out, verify: true),
            '.bz2' ||
            '.tbz2' => BZip2Decoder().decodeStream(input, out, verify: true),
            // xz: decode, but ignore the (unreliable) return value.
            _ => XZDecoder().decodeStream(input, out, verify: true),
          };
          if (!isXz && !ok) return null;
        } catch (_) {
          return null;
        } finally {
          out.closeSync();
          input.closeSync();
        }
        // xz has no usable success signal, so fall back to checking the
        // decoded bytes themselves: an empty temp tar means the decode
        // produced nothing at all.
        if (isXz) {
          final tmpTarFile = File(tmpTar);
          if (!tmpTarFile.existsSync() || tmpTarFile.lengthSync() == 0) {
            return null;
          }
          // A complete tar ends with two 512-byte zero blocks. A stream
          // truncated mid-block still decodes to a parseable — but silently
          // short — entry, which would otherwise be certified as fully
          // extracted; requiring the end marker rejects those truncations.
          if (!_tarEndMarkerPresent(tmpTarFile)) return null;
        }
        try {
          final tarInput = InputFileStream(tmpTar);
          final archive = TarDecoder().decodeStream(tarInput);
          return _OpenArchive(archive, inputs: [tarInput]);
        } catch (_) {
          return null;
        }
      default:
        return null; // unsupported format (e.g. .7z)
    }
  }

  /// Whether [file] carries the end-of-archive marker of a tar (two 512-byte
  /// all-zero blocks, tolerating trailing zero padding). Used to validate xz
  /// decodes, whose decoder gives no trustworthy success signal.
  static bool _tarEndMarkerPresent(File file) {
    final length = file.lengthSync();
    if (length < 1024) return false;
    const blockSize = 512;
    final input = InputFileStream(file.path);
    try {
      final toRead = length < blockSize * 64 ? length : blockSize * 64;
      input.setPosition(length - toRead);
      final tail = input.readBytes(toRead).toUint8List();
      // Walk the trailing zero padding back to the first non-zero byte; a
      // well-formed tar then has at least two zero blocks before it.
      var end = tail.length;
      while (end > 0 && tail[end - 1] == 0) {
        end--;
      }
      return tail.length - end >= blockSize * 2;
    } catch (_) {
      return false;
    } finally {
      input.closeSync();
    }
  }

  /// Writes one archive entry to [destPath] via a streaming decompress and
  /// validates it against the entry's recorded integrity metadata (size, plus
  /// CRC-32 when the container provides one). Returns false — without leaving
  /// a partial file — if the content is corrupt or the write came up short.
  bool _writeEntry(ArchiveFile f, String destPath) {
    final out = OutputFileStream(destPath);
    try {
      f.writeContent(out, freeMemory: false);
    } catch (_) {
      // Decompression failure (corrupt stream) — discard the partial file.
      out.closeSync();
      try {
        File(destPath).deleteSync();
      } catch (_) {}
      return false;
    }
    out.closeSync();
    final file = File(destPath);
    final sizeOk = file.lengthSync() == f.size;
    if (!sizeOk) {
      try {
        file.deleteSync();
      } catch (_) {}
      return false;
    }
    final expectedCrc = f.crc32;
    if (expectedCrc != null && expectedCrc != 0) {
      var crc = 0;
      final input = InputFileStream(destPath);
      try {
        const chunkSize = 1024 * 1024;
        while (!input.isEOS) {
          final n = input.length < chunkSize ? input.length : chunkSize;
          final chunk = input.readBytes(n).toUint8List();
          crc = getCrc32(chunk, crc);
        }
      } finally {
        input.closeSync();
      }
      if (crc != expectedCrc) {
        try {
          file.deleteSync();
        } catch (_) {}
        return false;
      }
    }
    return true;
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

  /// True if every ROM entry in [entries] now exists on disk under [root]
  /// (base files at root, update/dlc in their subfolders) at its full
  /// recorded size. An exists-only check would certify a truncated write
  /// (crash / disk-full mid-extraction) and the caller would then delete the
  /// archive, losing the only copy.
  bool _verify(List<ArchiveFile> entries, String root) {
    for (final f in entries) {
      final kind = ZipClassifier.classifyPath(f.name);
      final dir = switch (kind) {
        RomEntryKind.update => p.join(root, 'update'),
        RomEntryKind.dlc => p.join(root, 'dlc'),
        _ => root,
      };
      final file = File(p.join(dir, p.basename(f.name)));
      if (!file.existsSync() || file.lengthSync() != f.size) {
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
      final tempFiles = <String>[];
      _OpenArchive? opened;
      try {
        opened = _openArchive(archivePath, tempFiles);
        final archive = opened?.archive;
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
      } finally {
        opened?.closeInputs();
        for (final tmp in tempFiles) {
          try {
            File(tmp).deleteSync();
          } catch (_) {}
        }
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
      // "Game.v1.6.0" group together. Also strip a trailing update marker so
      // "Game Update v1.6.0" and "Game v1.5.0" group together (DLC is not
      // stripped — it lives in a different folder and would over-merge).
      final base = p
          .basenameWithoutExtension(f.path)
          .replaceAll(RegExp(r'v\d+(\.\d+)*', caseSensitive: false), '')
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
                  SupportedFormats.switchRoms.contains(_ext(f.path)),
            );
        final hasUpdate = Directory(p.join(e.path, 'update')).existsSync();
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
          if (sub == 'update' || sub == 'dlc') {
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

/// A decoded archive plus the input streams backing its (lazily-read)
/// entries. The caller must close [inputs] after the last entry is read.
class _OpenArchive {
  final Archive archive;
  final List<InputFileStream> inputs;

  _OpenArchive(this.archive, {required this.inputs});

  void closeInputs() {
    for (final input in inputs) {
      try {
        input.closeSync();
      } catch (_) {}
    }
  }
}
