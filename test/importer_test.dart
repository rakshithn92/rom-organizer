import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/services/importer.dart';
import 'package:rom_organizer/services/title_parser.dart';
import 'package:rom_organizer/services/zip_classifier.dart';

/// Build a zip in memory from a map of path -> content.
Uint8List makeZip(Map<String, String> entries) {
  final archive = Archive();
  for (final e in entries.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value.codeUnits));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('ZipClassifier', () {
    test('classifies base, update and dlc by filename markers', () {
      final entries = ZipClassifier.classify(makeZip({
        'Game.nsp': 'x',
        'Game.Update.v1.6.0.nsp': 'x',
        'Game.DLC.nsp': 'x',
      }))!;
      final byName = {for (final e in entries) e.fileName: e.kind};
      expect(byName['Game.nsp'], RomEntryKind.base);
      expect(byName['Game.Update.v1.6.0.nsp'], RomEntryKind.update);
      expect(byName['Game.DLC.nsp'], RomEntryKind.dlc);
    });

    test('classifies update/ folder entries as update', () {
      final entries = ZipClassifier.classify(makeZip({
        'Game.nsp': 'x',
        'update/Game.v1.6.0.nsp': 'x',
      }))!;
      final byName = {for (final e in entries) e.fileName: e.kind};
      expect(byName['Game.nsp'], RomEntryKind.base);
      expect(byName['Game.v1.6.0.nsp'], RomEntryKind.update);
    });

    test('classifies an update title ID with an integer version as update', () {
      final entries = ZipClassifier.classify(makeZip({
        'Game [0100C1B00A3A8800][v65536].nsp': 'x',
      }))!;

      expect(entries.single.kind, RomEntryKind.update);
    });

    test('returns null for invalid zip bytes', () {
      expect(ZipClassifier.classify(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('TitleParser', () {
    test('strips region, version and title-id tags', () {
      expect(
        TitleParser.clean('The.Legend.of.Zelda.Breath.of.the.Wild.[USA].nsp'),
        'The Legend of Zelda Breath of the Wild',
      );
    });

    test('strips update markers and version numbers', () {
      expect(
        TitleParser.clean('Super.Mario.Odyssey.Update.v1.3.0.nsp'),
        'Super Mario Odyssey',
      );
    });

    test('strips title-ids', () {
      expect(
        TitleParser.clean('Mario.Kart.8.Deluxe.0100152000022000.nsp'),
        'Mario Kart 8 Deluxe',
      );
    });
  });

  group('Importer', () {
    late Directory tmp;
    late String root;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('imp_');
      root = '${tmp.path}/Switch';
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('extracts base and update into the per-game layout', () async {
      final zipPath = '${tmp.path}/game.zip';
      File(zipPath).writeAsBytesSync(makeZip({
        'Game.nsp': 'base',
        'update/Game.v1.6.0.nsp': 'upd',
      }));

      final importer = Importer(root);
      final result = await importer.importArchive(zipPath, 'My Game');

      expect(result.error, isNull);
      expect(result.baseFiles, 1);
      expect(result.updateFiles, 1);
      expect(result.fullyExtracted, isTrue);

      expect(File('$root/My Game/Game.nsp').existsSync(), isTrue);
      expect(
        File('$root/My Game/update/Game.v1.6.0.nsp').existsSync(),
        isTrue,
      );
    });

    test('reports the base title ID discovered inside an archive', () async {
      final zipPath = '${tmp.path}/game-with-id.zip';
      File(zipPath).writeAsBytesSync(makeZip({
        'Game [0100C1B00A3A8000].nsp': 'base',
      }));

      final result =
          await Importer(root).importArchive(zipPath, 'Game With ID');

      expect(result.error, isNull);
      expect(result.titleId, '0100C1B00A3A8000');
    });

    test('rejects an archive with no Switch ROM files', () async {
      final zipPath = '${tmp.path}/notarom.zip';
      File(zipPath).writeAsBytesSync(makeZip({
        'readme.txt': 'hello',
        'photo.jpg': 'x',
      }));

      final result = await Importer(root).importArchive(zipPath, 'My Game');
      expect(result.error, isNotNull);
      expect(result.error, contains('Switch ROM'));
      // Nothing should have been extracted.
      expect(Directory('$root/My Game').existsSync(), isFalse);
    });

    test('rejects a game title that could escape the library root', () async {
      final filePath = '${tmp.path}/game.nsp';
      File(filePath).writeAsBytesSync([1]);

      final result = await Importer(root).importFile(filePath, '../outside');

      expect(result.error, contains('cannot contain slashes'));
      expect(File(filePath).existsSync(), isTrue);
      expect(Directory('${tmp.path}/outside').existsSync(), isFalse);
    });

    test('extracts a tar archive', () async {
      final tarPath = '${tmp.path}/game.tar';
      final archive = Archive();
      archive.addFile(ArchiveFile('Game.nsp', 4, 'base'.codeUnits));
      File(tarPath).writeAsBytesSync(TarEncoder().encode(archive));

      final result = await Importer(root).importArchive(tarPath, 'My Game');
      expect(result.error, isNull);
      expect(result.baseFiles, 1);
      expect(File('$root/My Game/Game.nsp').existsSync(), isTrue);
    });

    test('fullyExtracted is false when a zip entry is missing on disk', () async {
      final zipPath = '${tmp.path}/game.zip';
      File(zipPath).writeAsBytesSync(makeZip({
        'Game.nsp': 'base',
        'update/Game.v1.6.0.nsp': 'upd',
      }));

      final importer = Importer(root);
      final result = await importer.importArchive(zipPath, 'My Game');
      expect(result.fullyExtracted, isTrue);

      // Remove the update file -> verification should now fail.
      File('$root/My Game/update/Game.v1.6.0.nsp').deleteSync();
      final recheck = await importer.verifyExtracted(zipPath, '$root/My Game');
      expect(recheck, isFalse);
    });

    test('returns an error for a non-archive file', () async {
      final zipPath = '${tmp.path}/notazip.zip';
      File(zipPath).writeAsBytesSync([1, 2, 3, 4]);
      final result = await Importer(root).importArchive(zipPath, 'Bad');
      expect(result.error, isNotNull);
    });

    test('importFile moves a loose base ROM into the game folder', () async {
      final romPath = '${tmp.path}/Game.nsp';
      File(romPath).writeAsBytesSync([1, 2, 3]);
      final result = await Importer(root).importFile(romPath, 'My Game');
      expect(result.error, isNull);
      expect(result.baseFiles, 1);
      expect(File('$root/My Game/Game.nsp').existsSync(), isTrue);
      // Original is moved, not copied.
      expect(File(romPath).existsSync(), isFalse);
    });

    test('importFile routes an update file into the update/ subfolder', () async {
      // Base game must exist first (an update can't create its own folder).
      final base = '${tmp.path}/Game.nsp';
      File(base).writeAsBytesSync([1, 2, 3]);
      await Importer(root).importFile(base, 'My Game');

      final romPath = '${tmp.path}/Game.Update.v1.6.0.nsp';
      File(romPath).writeAsBytesSync([4, 5, 6]);
      final result = await Importer(root).importFile(romPath, 'My Game');
      expect(result.error, isNull);
      expect(result.updateFiles, 1);
      expect(
        File('$root/My Game/update/Game.Update.v1.6.0.nsp').existsSync(),
        isTrue,
      );
    });

    test('importing an update without a base game refuses (no orphan folder)',
        () async {
      // No base game exists in the library.
      final upd = '${tmp.path}/Game.Update.v1.6.0.nsp';
      File(upd).writeAsBytesSync([1, 2, 3]);

      final result = await Importer(root).importFile(upd, 'My Game');

      expect(result.error, isNotNull);
      expect(result.error, contains('base game'));
      // No folder should have been created.
      expect(Directory('$root/My Game').existsSync(), isFalse);
    });

    test('importFile refuses to overwrite an existing library file', () async {
      // Base game exists with a file.
      final base = '${tmp.path}/Game.nsp';
      File(base).writeAsBytesSync([1, 2, 3]);
      await Importer(root).importFile(base, 'My Game');

      // Import another file with the same basename -> must refuse, not overwrite.
      final dup = '${tmp.path}/Game.nsp';
      File(dup).writeAsBytesSync([9, 9, 9]);
      final result = await Importer(root).importFile(dup, 'My Game');

      expect(result.error, isNotNull);
      expect(result.error, contains('already exists'));
      // The original file is intact.
      expect(File('$root/My Game/Game.nsp').readAsBytesSync(), [1, 2, 3]);
    });

    test('import merges into an existing game folder (case-insensitive)', () async {
      // First import creates the folder.
      final base = '${tmp.path}/Game.nsp';
      File(base).writeAsBytesSync([1, 2, 3]);
      await Importer(root).importFile(base, 'My Game');

      // Second import of an update with a slightly different title casing
      // must MERGE into the same folder, not create a duplicate.
      final upd = '${tmp.path}/Game.Update.v1.6.0.nsp';
      File(upd).writeAsBytesSync([4, 5, 6]);
      final result = await Importer(root).importFile(upd, 'my game');

      expect(result.error, isNull);
      expect(File('$root/My Game/Game.nsp').existsSync(), isTrue);
      expect(
        File('$root/My Game/update/Game.Update.v1.6.0.nsp').existsSync(),
        isTrue,
      );
      // Only ONE game folder exists.
      final folders = Directory(root)
          .listSync(followLinks: false)
          .whereType<Directory>()
          .length;
      expect(folders, 1);
    });

    test('does not guess an update target from an ambiguous title prefix',
        () async {
      // Base folder is the short title.
      final base = '${tmp.path}/Dragon Quest XI.nsp';
      File(base).writeAsBytesSync([1, 2, 3]);
      await Importer(root).importFile(base, 'Dragon Quest XI');

      // Update resolves to the full official title (TheGamesDB style).
      final upd = '${tmp.path}/Dragon Quest XI Update v1.6.0.nsp';
      File(upd).writeAsBytesSync([4, 5, 6]);
      final result = await Importer(root).importFile(
          upd, 'Dragon Quest XI S: Echoes of an Elusive Age - Definitive Edition');

      expect(result.error, contains('No base game found'));
      expect(File(upd).existsSync(), isTrue);
      final folders = Directory(root)
          .listSync(followLinks: false)
          .whereType<Directory>()
          .length;
      expect(folders, 1);
    });

    test('importFile honors an explicit targetFolder (title-ID match)', () async {
      // Base folder exists.
      final base = '${tmp.path}/Game.nsp';
      File(base).writeAsBytesSync([1, 2, 3]);
      await Importer(root).importFile(base, 'My Game');

      // Update with a title ID, explicitly routed to the base folder.
      final upd = '${tmp.path}/[0100C1B00A3A8000] Game Update v1.6.0.nsp';
      File(upd).writeAsBytesSync([4, 5, 6]);
      final result = await Importer(root).importFile(
          upd, 'Some Other Title', targetFolder: '$root/My Game');

      expect(result.error, isNull);
      expect(
        File('$root/My Game/update/[0100C1B00A3A8000] Game Update v1.6.0.nsp')
            .existsSync(),
        isTrue,
      );
    });

    test('folder names with a colon are sanitized (Android EPERM fix)', () async {
      // A title with a colon must not create a folder containing ':'
      // (Android dart:io fails with EPERM on such paths).
      final base = '${tmp.path}/Game.nsp';
      File(base).writeAsBytesSync([1, 2, 3]);
      final result = await Importer(root)
          .importFile(base, 'Dragon Quest XI S: Echoes of an Elusive Age');

      expect(result.error, isNull);
      // The folder name has the colon replaced, not kept.
      expect(
        Directory('$root/Dragon Quest XI S - Echoes of an Elusive Age')
            .existsSync(),
        isTrue,
      );
      expect(
        Directory('$root/Dragon Quest XI S: Echoes of an Elusive Age')
            .existsSync(),
        isFalse,
      );
    });

    test('mergeGames combines duplicate folders into the target', () async {
      // Two duplicate folders: an English and a Japanese copy of the same game.
      Directory('$root/My Game EN').createSync(recursive: true);
      File('$root/My Game EN/Game.nsp').writeAsBytesSync([1, 2, 3]);
      Directory('$root/My Game EN/update').createSync(recursive: true);
      File('$root/My Game EN/update/Game.v1.6.0.nsp').writeAsBytesSync([4, 5, 6]);

      // JP copy has a distinct update file (different name -> no collision).
      Directory('$root/My Game JP').createSync(recursive: true);
      Directory('$root/My Game JP/update').createSync(recursive: true);
      File('$root/My Game JP/update/Game.v1.7.0.nsp').writeAsBytesSync([7, 8, 9]);

      final moved = Importer(root).mergeGames(
        '$root/My Game EN',
        ['$root/My Game JP'],
      );

      expect(moved, 1); // the JP update file moved into EN's update/
      expect(File('$root/My Game EN/Game.nsp').existsSync(), isTrue);
      expect(
        File('$root/My Game EN/update/Game.v1.6.0.nsp').existsSync(),
        isTrue,
      );
      expect(
        File('$root/My Game EN/update/Game.v1.7.0.nsp').existsSync(),
        isTrue,
      );
      // The JP folder is gone (its only file moved out).
      expect(Directory('$root/My Game JP').existsSync(), isFalse);
    });

    test('deleteOldUpdates keeps only the highest version', () async {
      Directory('$root/My Game/update').createSync(recursive: true);
      File('$root/My Game/update/Game.v1.6.0.nsp').writeAsBytesSync([1]);
      File('$root/My Game/update/Game.v1.7.0.nsp').writeAsBytesSync([2]);
      File('$root/My Game/update/Game.v1.5.0.nsp').writeAsBytesSync([3]);

      final deleted = Importer(root).deleteOldUpdates('$root/My Game');

      expect(deleted, 2);
      expect(
        File('$root/My Game/update/Game.v1.7.0.nsp').existsSync(),
        isTrue,
      );
      expect(
        File('$root/My Game/update/Game.v1.6.0.nsp').existsSync(),
        isFalse,
      );
      expect(
        File('$root/My Game/update/Game.v1.5.0.nsp').existsSync(),
        isFalse,
      );
    });

    test('deleteOldUpdates leaves a single update and unparseable files alone',
        () async {
      Directory('$root/My Game/update').createSync(recursive: true);
      File('$root/My Game/update/Game.v1.6.0.nsp').writeAsBytesSync([1]);
      File('$root/My Game/update/Game.weird.nsp').writeAsBytesSync([2]);

      final deleted = Importer(root).deleteOldUpdates('$root/My Game');

      expect(deleted, 0);
      expect(
        File('$root/My Game/update/Game.v1.6.0.nsp').existsSync(),
        isTrue,
      );
      expect(
        File('$root/My Game/update/Game.weird.nsp').existsSync(),
        isTrue,
      );
    });

    test('findMissingUpdates flags games with base but no update', () async {
      Directory('$root/Game A').createSync(recursive: true);
      File('$root/Game A/Game.nsp').writeAsBytesSync([1]);
      Directory('$root/Game B').createSync(recursive: true);
      File('$root/Game B/Game.nsp').writeAsBytesSync([2]);
      Directory('$root/Game B/update').createSync(recursive: true);
      File('$root/Game B/update/Game.v1.6.0.nsp').writeAsBytesSync([3]);

      final missing = Importer(root).findMissingUpdates();

      expect(missing.length, 1);
      expect(missing.single, endsWith('Game A'));
    });
  });
}
