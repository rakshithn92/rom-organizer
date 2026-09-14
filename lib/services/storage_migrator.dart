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
/// Each legacy root is processed at most once. After a root has been merged it
/// gets its own marker (`.downloads_migration_v1.<sanitized source>` inside the
/// content root) that records what it left behind — `completed` when clean, or
/// conflicting pairs. Later launches skip the root entirely and replay any
/// recorded conflicts from the marker instead of rescanning the tree; without
/// this a conflict that can never resolve would force a full re-migration on
/// every launch.
///
/// The global `.downloads_migration_v1` marker keeps its original meaning: it
/// is written only when every source ended with no conflicts and no errors.
///
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

  /// Per-source marker recording that [source] was already processed, so it is
  /// never merged twice. The full source path is sanitized (every
  /// non-alphanumeric character becomes `_`) because distinct legacy roots can
  /// share a basename (`.../ROM` and `.../Download/ROM`), and a shared marker
  /// would silently skip one of them.
  String _sourceMarkerPath(String source) =>
      p.join(contentRoot, '.downloads_migration_v1.${_sanitizeSource(source)}');

  static String _sanitizeSource(String source) =>
      source.replaceAll(RegExp('[^A-Za-z0-9]'), '_');

  /// A source that was clean is recorded as `completed`; one that left
  /// conflicting files behind records them (one `conflict\t<from>\t<to>` line
  /// each) so a later launch can report the same unresolved items without
  /// walking the source tree again — and so the global completion marker stays
  /// unwritten while anything is still unresolved.
  static String _encodeSourceMarker(List<MigrationConflict> conflicts) {
    if (conflicts.isEmpty) return 'completed\n';
    final buffer = StringBuffer();
    for (final conflict in conflicts) {
      buffer.writeln('conflict\t${conflict.source}\t${conflict.destination}');
    }
    return buffer.toString();
  }

  static List<MigrationConflict> _readSourceMarker(File marker) {
    final conflicts = <MigrationConflict>[];
    for (final line in marker.readAsLinesSync()) {
      final parts = line.split('\t');
      if (parts.length == 3 && parts.first == 'conflict') {
        conflicts.add(MigrationConflict(parts[1], parts[2]));
      }
    }
    return conflicts;
  }

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
        final marker = File(_sourceMarkerPath(source));
        // A source already handled by an earlier run is never merged twice.
        // Conflicts recorded in the marker are replayed so the report (and the
        // launch screen riding on it) keeps telling the user what is stuck.
        if (marker.existsSync()) {
          conflicts.addAll(_readSourceMarker(marker));
          continue;
        }
        try {
          final conflictsBefore = conflicts.length;
          moved += _mergeDirectory(sourceDir, Directory(destination), conflicts);
          // If this source left conflicting files behind, its old path still
          // legitimately holds data — rewriting its metadata prefix would
          // repoint those keys at files that never moved.
          if (migrateMetadata != null && conflicts.length == conflictsBefore) {
            await migrateMetadata!(source, destination);
          }
          _deleteEmptyTree(sourceDir);
          marker.writeAsStringSync(
            _encodeSourceMarker(conflicts.sublist(conflictsBefore)),
            flush: true,
          );
        } catch (e) {
          errors.add('Could not migrate $source: $e');
        }
      }
    }

    await migrateRoots(legacyLibraryRoots, libraryRoot);
    await migrateRoots(legacyContentRoots, contentRoot);

    // Only mark complete when nothing was left unresolved — otherwise a later
    // launch must retry the conflicting items.
    if (errors.isEmpty && conflicts.isEmpty) {
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
