import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rom_organizer/services/storage_migrator.dart';

void main() {
  late Directory temporaryDirectory;
  late String library;
  late String content;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync('rom_migration_');
    library = p.join(temporaryDirectory.path, 'Download', 'ROM Manager', 'ROMs');
    content = p.join(
      temporaryDirectory.path,
      'Download',
      'ROM Manager',
      'Content',
    );
  });

  tearDown(() => temporaryDirectory.deleteSync(recursive: true));

  test('moves legacy ROM and content trees and rewrites metadata prefixes',
      () async {
    final oldRoms = Directory(p.join(temporaryDirectory.path, 'ROMs', 'Switch'))
      ..createSync(recursive: true);
    final oldContent = Directory(p.join(temporaryDirectory.path, 'Content'))
      ..createSync(recursive: true);
    File(p.join(oldRoms.path, 'Game', 'game.nsp'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    File(p.join(oldContent.path, 'cover.jpg')).writeAsBytesSync([2]);
    final rewrites = <String>[];

    final report = await StorageMigrator(
      libraryRoot: library,
      contentRoot: content,
      legacyLibraryRoots: [oldRoms.path],
      legacyContentRoots: [oldContent.path],
      migrateMetadata: (from, to) async {
        rewrites.add('$from->$to');
      },
    ).run();

    expect(report.succeeded, isTrue);
    expect(report.movedFiles, 2);
    expect(File(p.join(library, 'Game', 'game.nsp')).existsSync(), isTrue);
    expect(File(p.join(content, 'cover.jpg')).existsSync(), isTrue);
    expect(rewrites, contains('${oldRoms.path}->$library'));
  });

  test('never overwrites conflicts and leaves the source in place', () async {
    final oldRoms = Directory(p.join(temporaryDirectory.path, 'old'))
      ..createSync(recursive: true);
    Directory(library).createSync(recursive: true);
    File(p.join(oldRoms.path, 'same.nsp')).writeAsStringSync('old');
    File(p.join(library, 'same.nsp')).writeAsStringSync('new');

    final report = await StorageMigrator(
      libraryRoot: library,
      contentRoot: content,
      legacyLibraryRoots: [oldRoms.path],
      legacyContentRoots: const [],
    ).run();

    expect(report.conflicts, hasLength(1));
    expect(File(p.join(library, 'same.nsp')).readAsStringSync(), 'new');
    expect(File(p.join(oldRoms.path, 'same.nsp')).readAsStringSync(), 'old');
  });

  test('is idempotent after a completed migration', () async {
    final oldRoms = Directory(p.join(temporaryDirectory.path, 'old'))
      ..createSync(recursive: true);
    File(p.join(oldRoms.path, 'game.nsp')).writeAsBytesSync([1]);
    final migrator = StorageMigrator(
      libraryRoot: library,
      contentRoot: content,
      legacyLibraryRoots: [oldRoms.path],
      legacyContentRoots: const [],
    );

    expect((await migrator.run()).movedFiles, 1);
    final second = await migrator.run();
    expect(second.alreadyCompleted, isTrue);
    expect(second.movedFiles, 0);
  });

  test('does not mark complete while a conflict is left behind', () async {
    final oldRoms = Directory(p.join(temporaryDirectory.path, 'old'))
      ..createSync(recursive: true);
    Directory(library).createSync(recursive: true);
    File(p.join(oldRoms.path, 'same.nsp')).writeAsStringSync('old');
    File(p.join(library, 'same.nsp')).writeAsStringSync('new');
    final migrator = StorageMigrator(
      libraryRoot: library,
      contentRoot: content,
      legacyLibraryRoots: [oldRoms.path],
      legacyContentRoots: const [],
    );

    final first = await migrator.run();
    expect(first.conflicts, hasLength(1));
    expect(first.alreadyCompleted, isFalse);
    expect(File(p.join(content, '.downloads_migration_v1')).existsSync(), isFalse);

    // A retry still sees the unresolved conflict (nothing was lost).
    final second = await migrator.run();
    expect(second.alreadyCompleted, isFalse);
    expect(second.conflicts, hasLength(1));
    expect(File(p.join(library, 'same.nsp')).readAsStringSync(), 'new');
    expect(File(p.join(oldRoms.path, 'same.nsp')).readAsStringSync(), 'old');
  });

  test('skips the metadata rewrite for a source that left a conflict',
      () async {
    final oldRoms = Directory(p.join(temporaryDirectory.path, 'old'))
      ..createSync(recursive: true);
    Directory(library).createSync(recursive: true);
    File(p.join(oldRoms.path, 'same.nsp')).writeAsStringSync('old');
    File(p.join(library, 'same.nsp')).writeAsStringSync('new');
    final rewrites = <String>[];

    await StorageMigrator(
      libraryRoot: library,
      contentRoot: content,
      legacyLibraryRoots: [oldRoms.path],
      legacyContentRoots: const [],
      migrateMetadata: (from, to) async {
        rewrites.add('$from->$to');
      },
    ).run();

    expect(rewrites, isEmpty);
  });

  test('a conflicting source is not re-migrated on every launch', () async {
    final oldRoms = Directory(p.join(temporaryDirectory.path, 'old'))
      ..createSync(recursive: true);
    Directory(library).createSync(recursive: true);
    File(p.join(oldRoms.path, 'same.nsp')).writeAsStringSync('old');
    File(p.join(library, 'same.nsp')).writeAsStringSync('new');
    final migrator = StorageMigrator(
      libraryRoot: library,
      contentRoot: content,
      legacyLibraryRoots: [oldRoms.path],
      legacyContentRoots: const [],
    );

    final first = await migrator.run();
    expect(first.conflicts, hasLength(1));

    final sourceMarker = File(
      p.join(
        content,
        '.downloads_migration_v1.'
            '${oldRoms.path.replaceAll(RegExp('[^A-Za-z0-9]'), '_')}',
      ),
    );
    expect(sourceMarker.existsSync(), isTrue);

    // The second launch must not walk the source again: nothing moves, and the
    // unresolved item is still reported without a fresh scan.
    final second = await migrator.run();
    expect(second.movedFiles, 0);
    expect(second.conflicts, hasLength(1));
    expect(second.alreadyCompleted, isFalse);
    expect(File(p.join(library, 'same.nsp')).readAsStringSync(), 'new');
    expect(File(p.join(oldRoms.path, 'same.nsp')).readAsStringSync(), 'old');
    expect(
      File(p.join(content, '.downloads_migration_v1')).existsSync(),
      isFalse,
    );
  });

  test('a destination directory blocker records a conflict, never deletes it',
      () async {
    final oldRoms = Directory(p.join(temporaryDirectory.path, 'old'))
      ..createSync(recursive: true);
    File(p.join(oldRoms.path, 'blocked.nsp')).writeAsBytesSync([1]);
    File(p.join(oldRoms.path, 'free.nsp')).writeAsBytesSync([2]);
    Directory(library).createSync(recursive: true);
    // A DIRECTORY in the destination slot is a deterministic move failure: the
    // migrator must report it as a conflict and leave it alone.
    Directory(p.join(library, 'blocked.nsp')).createSync();

    final report = await StorageMigrator(
      libraryRoot: library,
      contentRoot: content,
      legacyLibraryRoots: [oldRoms.path],
      legacyContentRoots: const [],
    ).run();

    expect(report.succeeded, isTrue);
    expect(report.movedFiles, 1);
    expect(
      report.conflicts.single.source,
      p.join(oldRoms.path, 'blocked.nsp'),
    );
    expect(report.conflicts.single.destination, p.join(library, 'blocked.nsp'));
    expect(File(p.join(library, 'free.nsp')).readAsBytesSync(), [2]);
    expect(File(p.join(oldRoms.path, 'blocked.nsp')).readAsBytesSync(), [1]);
    expect(
      Directory(p.join(library, 'blocked.nsp')).listSync(),
      isEmpty,
    );
    expect(
      File(p.join(content, '.downloads_migration_v1')).existsSync(),
      isFalse,
    );
  });

  test('a blocked migration resumes once the blocker is removed', () async {
    final oldRoms = Directory(p.join(temporaryDirectory.path, 'old'))
      ..createSync(recursive: true);
    File(p.join(oldRoms.path, 'blocked.nsp')).writeAsBytesSync([1]);
    File(p.join(oldRoms.path, 'free.nsp')).writeAsBytesSync([2]);
    Directory(library).createSync(recursive: true);
    final blocker = Directory(p.join(library, 'blocked.nsp'))..createSync();
    final migrator = StorageMigrator(
      libraryRoot: library,
      contentRoot: content,
      legacyLibraryRoots: [oldRoms.path],
      legacyContentRoots: const [],
    );

    final first = await migrator.run();
    expect(first.movedFiles, 1);
    expect(first.conflicts, hasLength(1));
    expect(File(p.join(library, 'free.nsp')).readAsBytesSync(), [2]);

    // A crash between the merge and the per-root marker write leaves the moved
    // file at the destination with no marker on disk. Reproduce that exact
    // post-crash state: drop the marker the dead process never wrote, then
    // clear the blocker.
    File(p.join(
      content,
      '.downloads_migration_v1.'
          '${oldRoms.path.replaceAll(RegExp('[^A-Za-z0-9]'), '_')}',
    )).deleteSync();
    blocker.deleteSync();

    final second = await migrator.run();
    expect(second.succeeded, isTrue);
    expect(second.movedFiles, 1);
    expect(second.conflicts, isEmpty);
    expect(second.alreadyCompleted, isFalse);
    expect(File(p.join(library, 'blocked.nsp')).readAsBytesSync(), [1]);
    expect(File(p.join(library, 'free.nsp')).readAsBytesSync(), [2]);
    expect(File(p.join(oldRoms.path, 'blocked.nsp')).existsSync(), isFalse);
    expect(
      File(p.join(content, '.downloads_migration_v1')).existsSync(),
      isTrue,
    );
  });

  test('a recorded conflict is replayed instead of being retried', () async {
    final oldRoms = Directory(p.join(temporaryDirectory.path, 'old'))
      ..createSync(recursive: true);
    File(p.join(oldRoms.path, 'blocked.nsp')).writeAsBytesSync([1]);
    Directory(library).createSync(recursive: true);
    final blocker = Directory(p.join(library, 'blocked.nsp'))..createSync();
    final migrator = StorageMigrator(
      libraryRoot: library,
      contentRoot: content,
      legacyLibraryRoots: [oldRoms.path],
      legacyContentRoots: const [],
    );

    expect((await migrator.run()).conflicts, hasLength(1));

    // Clearing the blocker does NOT resume the root: its per-root marker makes
    // it processed-once, and the recorded conflict is replayed as-is.
    blocker.deleteSync();
    final second = await migrator.run();
    expect(second.movedFiles, 0);
    expect(second.conflicts, hasLength(1));
    expect(File(p.join(oldRoms.path, 'blocked.nsp')).readAsBytesSync(), [1]);
    expect(File(p.join(library, 'blocked.nsp')).existsSync(), isFalse);
    expect(
      File(p.join(content, '.downloads_migration_v1')).existsSync(),
      isFalse,
    );
  });
}
