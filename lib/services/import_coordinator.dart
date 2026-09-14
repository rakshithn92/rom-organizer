import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/app_paths.dart';
import '../config/supported_formats.dart';
import 'importer.dart';
import 'rom_scanner.dart';
import 'tag_db.dart';
import 'thegamesdb_client.dart';
import 'title_parser.dart';

/// Tallies produced by [ImportCoordinator.importPaths].
class ImportReport {
  /// Files written into the library.
  final int imported;

  /// Files deliberately not imported (undecodable archive, missing base game,
  /// failed import).
  final int skipped;

  /// Successfully imported files whose original must be deleted by hand
  /// (Android refused to remove it after the copy).
  final int warnings;

  const ImportReport({
    required this.imported,
    required this.skipped,
    required this.warnings,
  });
}

/// The library workflow behind the import screen: title lookup, title-ID
/// matching, and the two-pass auto-import.
///
/// This is plain Dart with no Flutter imports so the workflow can be unit
/// tested and reused outside the UI. Storage ([TagDb]) and the file operations
/// ([Importer]) are constructor-injected, which is the app's DI seam: tests
/// supply fakes, the app takes the defaults.
class ImportCoordinator {
  final TagDb db;
  final Importer importer;

  /// Scans the library for a game folder by title ID. Only used to backfill
  /// IDs for libraries created before IDs were persisted.
  final RomScanner _scanner = RomScanner();

  ImportCoordinator({TagDb? db, Importer? importer})
      : db = db ?? TagDb(),
        importer = importer ?? Importer(AppPaths.libraryRoot);

  /// Archives the `archive` package cannot decode in-app. They are still
  /// listed by the scanner so the UI can explain what to do with them.
  static bool isUndecodableArchive(String path) {
    final ext = p.extension(path).toLowerCase();
    return SupportedFormats.externallyExtractedArchives.contains(ext);
  }

  /// Resolves the real game title from TheGamesDB (if a key is set), falling
  /// back to the parsed filename [candidate].
  Future<String> resolveTitle(String candidate) async {
    final key = await db.getSetting('thegamesdb_api_key');
    if (key != null && key.isNotEmpty) {
      try {
        final meta = await TheGamesDbClient.searchOnce(key, candidate);
        if (meta != null && meta.title.isNotEmpty) return meta.title;
      } on TheGamesDbException {
        // Bad key / rate limit: the parsed candidate is still usable.
      } catch (_) {
        // Network or parse failure: same fallback.
      }
    }
    return candidate;
  }

  /// Resolves the target game folder for [fileName] by title ID first. Update
  /// IDs are normalized to their corresponding base-game IDs by [TagDb], so an
  /// update lands in the base's folder regardless of how their titles differ.
  /// Returns null if no title ID match is found (caller falls back to
  /// name-based resolution).
  Future<String?> resolveTargetByTitleId(String fileName) async {
    final id = TitleParser.titleId(fileName);
    if (id == null) return null;
    final stored = await db.folderForTitleId(id);
    if (stored != null && Directory(stored).existsSync()) return stored;

    final libraryRoot = Directory(importer.libraryRoot);
    final discovered = _scanner.findGameFolderByTitleId(libraryRoot, id);
    if (discovered != null) await db.saveTitleId(discovered, id);
    return discovered;
  }

  /// Persists the title ID of an import onto its base game folder so future
  /// updates can match it. Only base files carry a title ID — an import that
  /// produced none (a lone update or DLC) must not overwrite the base's ID.
  Future<void> saveTitleIdFor(ImportResult result, String sourceFileName) async {
    if (result.baseFiles <= 0) return;
    final id = result.titleId ?? TitleParser.titleId(sourceFileName);
    if (id != null) await db.saveTitleId(result.gameFolder, id);
  }

  /// Imports every path in [paths] into the library.
  ///
  /// Two passes: an update processed before its base game is refused, so
  /// refused entries are retried once after the first pass has imported their
  /// base. A second refusal counts as skipped — the retry is bounded.
  ///
  /// One bad file never aborts the batch; it is counted as skipped.
  Future<ImportReport> importPaths(
    List<String> paths, {
    required bool deleteArchives,
  }) async {
    var imported = 0, skipped = 0, warnings = 0;

    // Imports one file, updating the counters. Returns true when the file was
    // refused only because its base game had not been imported yet — the
    // caller defers those to a second pass.
    Future<bool> process(String path) async {
      // 7z/rar can't be decoded in-app — skip them.
      if (isUndecodableArchive(path)) {
        skipped++;
        return false;
      }
      final isArchive =
          SupportedFormats.archives.contains(p.extension(path).toLowerCase());
      final fileName = p.basename(path);
      final title = await resolveTitle(TitleParser.clean(fileName));
      // Match by title ID first (update IDs normalize to their base IDs).
      final target = await resolveTargetByTitleId(fileName);

      final result = isArchive
          ? await importer.importArchive(path, title, targetFolder: target)
          : await importer.importFile(path, title, targetFolder: target);
      if (result.error == null) {
        imported++;
        if (result.warning != null) warnings++;
        await saveTitleIdFor(result, fileName);
        // Delete the archive only if the user chose to.
        if (isArchive && result.fullyExtracted && deleteArchives) {
          try {
            File(path).deleteSync();
          } catch (_) {
            // Non-fatal — leave the archive.
          }
        }
        return false;
      }
      if (result.error!.contains('Import the base game first')) {
        // The base may appear later in this same batch — don't count it yet.
        return true;
      }
      skipped++;
      return false;
    }

    final deferred = <String>[];
    for (final path in paths) {
      try {
        if (await process(path)) deferred.add(path);
      } catch (_) {
        skipped++;
      }
    }
    for (final path in deferred) {
      try {
        if (await process(path)) skipped++;
      } catch (_) {
        skipped++;
      }
    }
    return ImportReport(imported: imported, skipped: skipped, warnings: warnings);
  }
}
