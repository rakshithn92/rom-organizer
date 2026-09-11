import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_mover.dart';

typedef PathMetadataMigrator = Future<void> Function(
  String oldPrefix,
  String newPrefix,
);

class MigrationConflict {
  final String source;
  final String destination;

  const MigrationConflict(this.source, this.destination);
}

class MigrationReport {
  final int movedFiles;
  final List<MigrationConflict> conflicts;
  final List<String> errors;
  final bool alreadyCompleted;

  const MigrationReport({
    required this.movedFiles,
    required this.conflicts,
    required this.errors,
    this.alreadyCompleted = false,
  });

  bool get succeeded => errors.isEmpty;
  bool get changed => movedFiles > 0;
}

/// Creates the Downloads-scoped layout and imports data from older releases.
///
/// The marker is written only after all readable sources have been processed.
/// Conflicting files are deliberately left at the old location and reported;
/// an existing destination is never overwritten.
class StorageMigrator {
  final String libraryRoot;
  final String contentRoot;
  final List<String> legacyLibraryRoots;
  final List<String> legacyContentRoots;
  final PathMetadataMigrator? migrateMetadata;

  StorageMigrator({
    required this.libraryRoot,
    required this.contentRoot,
    required this.legacyLibraryRoots,
    required this.legacyContentRoots,
    this.migrateMetadata,
  });

  String get _markerPath => p.join(contentRoot, '.downloads_migration_v1');

  Future<MigrationReport> run() async {
    final conflicts = <MigrationConflict>[];
    final errors = <String>[];
    var moved = 0;
    try {
      Directory(libraryRoot).createSync(recursive: true);
      Directory(contentRoot).createSync(recursive: true);
    } catch (e) {
      return MigrationReport(
        movedFiles: 0,
        conflicts: const [],
        errors: ['Could not create the ROM Manager folders: $e'],
      );
    }

    if (File(_markerPath).existsSync()) {
      return const MigrationReport(
        movedFiles: 0,
        conflicts: [],
        errors: [],
        alreadyCompleted: true,
      );
    }

    Future<void> migrateRoots(List<String> sources, String destination) async {
      for (final source in sources) {
        final sourceDir = Directory(source);
        if (!sourceDir.existsSync() || _sameOrInside(source, destination)) {
          continue;
        }
        try {
          moved += _mergeDirectory(sourceDir, Directory(destination), conflicts);
          if (migrateMetadata != null) {
            await migrateMetadata!(source, destination);
          }
          _deleteEmptyTree(sourceDir);
        } catch (e) {
          errors.add('Could not migrate $source: $e');
        }
      }
    }

    await migrateRoots(legacyLibraryRoots, libraryRoot);
    await migrateRoots(legacyContentRoots, contentRoot);

    if (errors.isEmpty) {
      try {
        File(_markerPath).writeAsStringSync('completed\n', flush: true);
      } catch (e) {
        errors.add('Could not save migration status: $e');
      }
    }
    return MigrationReport(
      movedFiles: moved,
      conflicts: conflicts,
      errors: errors,
    );
  }

  static bool _sameOrInside(String parent, String child) {
    final normalizedParent = p.normalize(p.absolute(parent));
    final normalizedChild = p.normalize(p.absolute(child));
    return normalizedChild == normalizedParent ||
        p.isWithin(normalizedParent, normalizedChild);
  }

  static int _mergeDirectory(
    Directory source,
    Directory destination,
    List<MigrationConflict> conflicts,
  ) {
    destination.createSync(recursive: true);
    var moved = 0;
    for (final entity in source.listSync(followLinks: false)) {
      final target = p.join(destination.path, p.basename(entity.path));
      if (entity is Directory) {
        if (File(target).existsSync()) {
          conflicts.add(MigrationConflict(entity.path, target));
          continue;
        }
        if (Directory(target).existsSync()) {
          moved += _mergeDirectory(entity, Directory(target), conflicts);
        } else {
          final count = _countFiles(entity);
          FileMover.moveDirectory(entity.path, target);
          moved += count;
        }
      } else if (entity is File) {
        if (File(target).existsSync() || Directory(target).existsSync()) {
          conflicts.add(MigrationConflict(entity.path, target));
          continue;
        }
        final sourceRemoved = FileMover.moveFile(entity.path, target);
        if (!sourceRemoved) {
          conflicts.add(MigrationConflict(entity.path, target));
        }
        moved++;
      }
    }
    return moved;
  }

  static int _countFiles(Directory directory) => directory
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .length;

  static void _deleteEmptyTree(Directory directory) {
    if (!directory.existsSync()) return;
    for (final child
        in directory.listSync(followLinks: false).whereType<Directory>()) {
      _deleteEmptyTree(child);
    }
    if (directory.listSync(followLinks: false).isEmpty) {
      directory.deleteSync();
    }
  }
}
