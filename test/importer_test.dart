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
      final result = await importer.importZip(zipPath, 'My Game');

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

    test('fullyExtracted is false when a zip entry is missing on disk', () async {
      final zipPath = '${tmp.path}/game.zip';
      File(zipPath).writeAsBytesSync(makeZip({
        'Game.nsp': 'base',
        'update/Game.v1.6.0.nsp': 'upd',
      }));

      final importer = Importer(root);
      final result = await importer.importZip(zipPath, 'My Game');
      expect(result.fullyExtracted, isTrue);

      // Remove the update file -> verification should now fail.
      File('$root/My Game/update/Game.v1.6.0.nsp').deleteSync();
      final recheck = await importer.verifyExtracted(zipPath, '$root/My Game');
      expect(recheck, isFalse);
    });

    test('returns an error for a non-zip file', () async {
      final zipPath = '${tmp.path}/notazip.zip';
      File(zipPath).writeAsBytesSync([1, 2, 3, 4]);
      final result = await Importer(root).importZip(zipPath, 'Bad');
      expect(result.error, isNotNull);
    });
  });
}
