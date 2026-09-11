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
}
