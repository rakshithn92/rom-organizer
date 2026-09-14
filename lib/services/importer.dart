import '../models/import_result.dart';
import 'archive_importer.dart';
import 'library_maintenance.dart';
import 'rom_import_service.dart';

export '../models/import_result.dart';

/// Thin facade over the three import services, kept so callers that construct
/// an [Importer] for its whole toolbox (the screens) keep compiling:
///
///   - [ArchiveImporter] — extracting `.zip`/`.tar`/`.gz`/`.bz2`/`.xz` archives
///   - [RomImportService] — moving loose ROM files, game-folder resolution
///   - [LibraryMaintenance] — pruning old updates, finding missing updates,
///     merging duplicate game folders
///
/// New code SHOULD depend on the service it actually needs instead.
class Importer {
  final String libraryRoot;

  Importer(this.libraryRoot);

  /// Sanitizes a folder name for use as a filesystem path (see
  /// [RomImportService.sanitizeFolderName]).
  static String sanitizeFolderName(String name) =>
      RomImportService.sanitizeFolderName(name);

  /// Imports [archivePath] into a new folder named [gameTitle] under
  /// [libraryRoot], extracting base files into the game folder and
  /// update/DLC entries into their `update/` `dlc/` subfolders.
  Future<ImportResult> importArchive(
    String archivePath,
    String gameTitle, {
    String? targetFolder,
  }) => ArchiveImporter(libraryRoot).importArchive(
    archivePath,
    gameTitle,
    targetFolder: targetFolder,
  );

  /// Moves an already-extracted ROM file into the organized library layout.
  Future<ImportResult> importFile(
    String filePath,
    String gameTitle, {
    String? targetFolder,
  }) => RomImportService(libraryRoot).importFile(
    filePath,
    gameTitle,
    targetFolder: targetFolder,
  );

  /// Re-checks whether every ROM entry of the archive at [archivePath] is
  /// present under [gameFolder] (without re-extracting).
  Future<bool> verifyExtracted(String archivePath, String gameFolder) =>
      ArchiveImporter(libraryRoot).verifyExtracted(archivePath, gameFolder);

  /// Deletes old update files in a game's `update/` folder, keeping only the
  /// highest-versioned one. Returns the number of files deleted.
  int deleteOldUpdates(String gameFolder) =>
      LibraryMaintenance(libraryRoot).deleteOldUpdates(gameFolder);

  /// Returns the paths of game folders that have a base file but no `update/`
  /// folder.
  List<String> findMissingUpdates() =>
      LibraryMaintenance(libraryRoot).findMissingUpdates();

  /// Merges [sourceFolders] into [targetFolder]. Returns the number of files
  /// moved.
  int mergeGames(String targetFolder, List<String> sourceFolders) =>
      LibraryMaintenance(libraryRoot).mergeGames(targetFolder, sourceFolders);
}
