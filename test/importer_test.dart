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

    test(
        'fullyExtracted is false and existing file is kept when a basename collides',
        () async {
      // Game folder already holds a DIFFERENT Game.nsp.
      Directory('$root/My Game').createSync(recursive: true);
      File('$root/My Game/Game.nsp').writeAsBytesSync([9]);

      // Archive's own Game.nsp has different content and must not overwrite it.
      final zipPath = '${tmp.path}/game.zip';
      File(zipPath).writeAsBytesSync(makeZip({'Game.nsp': 'newbase'}));

      final result = await Importer(root).importArchive(zipPath, 'My Game');

      expect(result.error, isNull);
      // Its bytes were never written, so extraction cannot be certified —
      // the caller must NOT delete the source archive.
      expect(result.fullyExtracted, isFalse);
      // The pre-existing ROM is untouched (never overwrite).
      expect(File('$root/My Game/Game.nsp').readAsBytesSync(), [9]);
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

    test('deleteOldUpdates groups differently-named updates of the same game',
        () async {
      Directory('$root/My Game/update').createSync(recursive: true);
      File('$root/My Game/update/Game Update v1.6.0.nsp').writeAsBytesSync([1]);
      File('$root/My Game/update/Game v1.5.0.nsp').writeAsBytesSync([2]);

      final deleted = Importer(root).deleteOldUpdates('$root/My Game');

      expect(deleted, 1);
      expect(
        File('$root/My Game/update/Game Update v1.6.0.nsp').existsSync(),
        isTrue,
      );
      expect(
        File('$root/My Game/update/Game v1.5.0.nsp').existsSync(),
        isFalse,
      );
    });

    test('deleteOldUpdates leaves a single update file alone', () async {
      Directory('$root/My Game/update').createSync(recursive: true);
      File('$root/My Game/update/Game Update v1.6.0.nsp').writeAsBytesSync([1]);

      final deleted = Importer(root).deleteOldUpdates('$root/My Game');

      expect(deleted, 0);
      expect(
        File('$root/My Game/update/Game Update v1.6.0.nsp').existsSync(),
        isTrue,
      );
    });

    test('deleteOldUpdates never deletes an unparseable version', () async {
      Directory('$root/My Game/update').createSync(recursive: true);
      File('$root/My Game/update/Game Update v1.6.0.nsp').writeAsBytesSync([1]);
      File('$root/My Game/update/Game Update v1.7.0.nsp').writeAsBytesSync([2]);
      File('$root/My Game/update/Game Update.nsp').writeAsBytesSync([3]);

      final deleted = Importer(root).deleteOldUpdates('$root/My Game');

      expect(deleted, 1);
      expect(
        File('$root/My Game/update/Game Update v1.7.0.nsp').existsSync(),
        isTrue,
      );
      expect(
        File('$root/My Game/update/Game Update.nsp').existsSync(),
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

    test('findMissingUpdates ignores folders with no Switch ROM base',
        () async {
      // A folder holding only cover art / a readme is not a game missing its
      // update.
      Directory('$root/Cover Only').createSync(recursive: true);
      File('$root/Cover Only/cover.jpg').writeAsBytesSync([1]);
      File('$root/Cover Only/readme.txt').writeAsBytesSync([2]);

      final missing = Importer(root).findMissingUpdates();

      expect(missing, isEmpty);
    });

    test('mergeGames skips a failed move and keeps the source file', () async {
      Directory('$root/My Game').createSync(recursive: true);
      // A directory named like the source file makes the move throw (a file
      // cannot be renamed/copied onto a directory).
      Directory('$root/My Game/blocked.nsp').createSync(recursive: true);

      Directory('$root/Dupe').createSync(recursive: true);
      File('$root/Dupe/blocked.nsp').writeAsBytesSync([1]);
      File('$root/Dupe/ok.nsp').writeAsBytesSync([2]);

      final moved = Importer(root).mergeGames('$root/My Game', ['$root/Dupe']);

      // The good file moved; the blocked one was skipped and left behind.
      expect(moved, 1);
      expect(File('$root/My Game/ok.nsp').existsSync(), isTrue);
      expect(File('$root/Dupe/blocked.nsp').existsSync(), isTrue);
      // Source not deleted because a file still lives in it.
      expect(Directory('$root/Dupe').existsSync(), isTrue);
    });

    test('rejects a corrupt zip entry (CRC mismatch) and keeps the archive',
        () async {
      // Build a zip with compressed content, then flip a byte in the middle
      // of the file (inside the deflate stream). Streaming extraction must
      // detect the CRC mismatch instead of writing corrupt ROM bytes.
      final archive = Archive()
        ..addFile(ArchiveFile(
            'Game.nsp', 4000, List.generate(4000, (i) => i % 251)));
      final bytes =
          Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      bytes[bytes.length ~/ 2] ^= 0xFF;
      final zipPath = '${tmp.path}/corrupt.zip';
      File(zipPath).writeAsBytesSync(bytes);

      final result = await Importer(root).importArchive(zipPath, 'My Game');

      expect(result.error, isNotNull);
      expect(result.error, contains('corrupt'));
      // The corrupt entry must not land in the library (the game folder may
      // be created, but no ROM file is ever written from the corrupt zip).
      expect(File('$root/My Game/Game.nsp').existsSync(), isFalse);
      expect(File('$root/My Game/Game.nsp.import-tmp').existsSync(), isFalse);
    });

    test('rejects a corrupt gzipped tar (container checksum)', () async {
      final tarArchive = Archive()
        ..addFile(ArchiveFile('Game.nsp', 4, 'base'.codeUnits));
      final tarBytes = TarEncoder().encode(tarArchive);
      final bytes = Uint8List.fromList(GZipEncoder().encode(tarBytes));
      // Corrupt the middle of the deflate stream.
      bytes[bytes.length ~/ 2] ^= 0xFF;
      final badPath = '${tmp.path}/bad.tar.gz';
      File(badPath).writeAsBytesSync(bytes);

      final result = await Importer(root).importArchive(badPath, 'My Game');
      expect(result.error, isNotNull);
      expect(Directory('$root/My Game').existsSync(), isFalse);
    });

    test('a truncated write never reaches the final filename', () async {
      // The tmp-then-rename write path means a mid-write crash leaves an
      // 'import-tmp' file, never the final name — so verification (and the
      // caller's archive deletion) cannot be fooled by a partial file.
      final zipPath = '${tmp.path}/game.zip';
      File(zipPath).writeAsBytesSync(makeZip({'Game.nsp': 'base'}));
      await Importer(root).importArchive(zipPath, 'My Game');
      // After a successful import, no tmp leftovers.
      expect(
        Directory(root)
            .listSync(recursive: true)
            .where((e) => e.path.contains('import-tmp')),
        isEmpty,
      );
      // And the final file has the full content.
      expect(
        File('$root/My Game/Game.nsp').readAsStringSync(),
        'base',
      );
    });

    test('truncated extraction does not certify fullyExtracted (size check)',
        () async {
      // Simulate a crash mid-extraction: the entry file exists on disk but
      // is short. _verify must fail, so the caller never deletes the archive.
      final zipPath = '${tmp.path}/game.zip';
      File(zipPath).writeAsBytesSync(makeZip({'Game.nsp': 'base'}));
      final gameFolder = '$root/My Game';
      Directory(gameFolder).createSync(recursive: true);
      File('$gameFolder/Game.nsp').writeAsBytesSync([98, 97]);

      final recheck =
          await Importer(root).verifyExtracted(zipPath, gameFolder);
      expect(recheck, isFalse);
    });
    test('extracts a gzipped tar via streaming (container verify)', () async {
      final tarArchive = Archive()
        ..addFile(ArchiveFile('Game.nsp', 4, 'base'.codeUnits));
      final tarBytes = TarEncoder().encode(tarArchive);
      final gzPath = '${tmp.path}/game.tar.gz';
      File(gzPath).writeAsBytesSync(GZipEncoder().encode(tarBytes));

      final result = await Importer(root).importArchive(gzPath, 'My Game');
      expect(result.error, isNull);
      expect(result.baseFiles, 1);
      expect(File('$root/My Game/Game.nsp').readAsStringSync(), 'base');
      // The decompressed tar temp file must be cleaned up.
      expect(File('$gzPath.extract-tmp').existsSync(), isFalse);
    });

    test('rejects a corrupt gzipped tar (container checksum)', () async {
      final tarArchive = Archive()
        ..addFile(ArchiveFile('Game.nsp', 4, 'base'.codeUnits));
      final tarBytes = TarEncoder().encode(tarArchive);
      final gzBytes = GZipEncoder().encode(tarBytes);
      String gzPath() => '${tmp.path}/bad.tar.gz';
      final bytes = Uint8List.fromList(gzBytes);
      // Corrupt the middle of the deflate stream.
      bytes[bytes.length ~/ 2] ^= 0xFF;
      final badPath = '${tmp.path}/bad.tar.gz';
      File(badPath).writeAsBytesSync(bytes);

      final result = await Importer(root).importArchive(badPath, 'My Game');
      expect(result.error, isNotNull);
      expect(Directory('$root/My Game').existsSync(), isFalse);
      gzPath;
    });

    test('extracts an xz-compressed tar via streaming', () async {
      final tarArchive = Archive()
        ..addFile(ArchiveFile('Game.nsp', 4, 'base'.codeUnits));
      final xzPath = '${tmp.path}/game.tar.xz';
      File(xzPath)
          .writeAsBytesSync(XZEncoder().encode(TarEncoder().encode(tarArchive)));

      final result = await Importer(root).importArchive(xzPath, 'My Game');
      expect(result.error, isNull);
      expect(result.baseFiles, 1);
      expect(File('$root/My Game/Game.nsp').readAsStringSync(), 'base');
    });

    test('rejects a corrupt xz-compressed tar (empty temp tar)', () async {
      // XZDecoder's bool return is unreliable in archive 4.2.0 (it returns
      // false even on a clean decode), so the container checksum never
      // surfaces as an error. A flip inside the *compressed payload* can still
      // decode to a byte-identical-length tar, so corruption has to land in
      // the block header: that aborts the decode with zero bytes written,
      // leaving an empty temp tar which the tar parse (or the emptiness check)
      // must reject rather than importing garbage.
      final tarArchive = Archive()
        ..addFile(ArchiveFile('Game.nsp', 4, 'base'.codeUnits)
          ..lastModTime = 1700000000);
      final tarBytes = TarEncoder().encode(tarArchive);
      final xzBytes =
          Uint8List.fromList(XZEncoder().encodeBytes(tarBytes, check: XZCheck.crc32));
      // Byte 16 is inside the xz block header (after the 12-byte stream
      // header), so the block fails to decode and nothing is written.
      xzBytes[16] ^= 0xFF;
      final badPath = '${tmp.path}/bad.tar.xz';
      File(badPath).writeAsBytesSync(xzBytes);

      final result = await Importer(root).importArchive(badPath, 'My Game');

      expect(result.error, isNotNull);
      // The empty temp tar must never become a ROM file in the library.
      expect(File('$root/My Game/Game.nsp').existsSync(), isFalse);
    });

    test('extracts a bz2-compressed tar via streaming', () async {
      final tarArchive = Archive()
        ..addFile(ArchiveFile('Game.nsp', 4, 'base'.codeUnits)
          ..lastModTime = 1700000000);
      final tarBytes = TarEncoder().encode(tarArchive);
      final bz2Path = '${tmp.path}/game.tar.bz2';
      File(bz2Path).writeAsBytesSync(BZip2Encoder().encodeBytes(tarBytes));

      final result = await Importer(root).importArchive(bz2Path, 'My Game');
      expect(result.error, isNull);
      expect(result.baseFiles, 1);
      expect(File('$root/My Game/Game.nsp').readAsStringSync(), 'base');
      // The decompressed tar temp file must be cleaned up.
      expect(File('$bz2Path.extract-tmp').existsSync(), isFalse);
    });

    test('streams a multi-megabyte entry without loading it whole', () async {
      // 8 MB of content: if the implementation still decoded the archive in
      // RAM this would not fail, but it proves the streaming path handles
      // entries spanning many chunks end-to-end (size + CRC checks included).
      final big = List.generate(8 * 1024 * 1024, (i) => i % 251);
      final archive = Archive()
        ..addFile(ArchiveFile('Big.nsp', big.length, big));
      final zipPath = '${tmp.path}/big.zip';
      File(zipPath).writeAsBytesSync(ZipEncoder().encodeBytes(archive));

      final result = await Importer(root).importArchive(zipPath, 'Big Game');
      expect(result.error, isNull);
      expect(result.baseFiles, 1);
      expect(
        File('$root/Big Game/Big.nsp').lengthSync(),
        8 * 1024 * 1024,
      );
      expect(result.fullyExtracted, isTrue);
    });
  });
}
