import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rom_organizer/config/app_paths.dart';
import 'package:rom_organizer/services/import_coordinator.dart';
import 'package:rom_organizer/services/importer.dart';
import 'package:rom_organizer/services/tag_db.dart';
import 'package:rom_organizer/services/title_parser.dart';

/// Build a zip in memory from a map of path -> content.
Uint8List makeZip(Map<String, String> entries) {
  final archive = Archive();
  for (final e in entries.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value.codeUnits));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// In-memory [TagDb] stand-in: the coordinator only needs the settings read for
/// the API key and the title-ID map. Keeps these tests free of sqflite.
class _FakeDb extends TagDb {
  final Map<String, String> settings = {};
  final Map<String, String> titleIds = {};

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> saveSetting(String key, String value) async {
    settings[key] = value;
  }

  @override
  Future<void> saveTitleId(String folderPath, String titleId) async {
    titleIds[folderPath] = TitleParser.canonicalBaseTitleId(titleId);
  }

  @override
  Future<String?> titleIdForFolder(String folderPath) async =>
      titleIds[folderPath];

  @override
  Future<String?> folderForTitleId(String titleId) async {
    final wanted = TitleParser.canonicalBaseTitleId(titleId);
    for (final e in titleIds.entries) {
      if (e.value == wanted) return e.key;
    }
    return null;
  }
}

/// Importer whose per-path outcome is scripted, so the coordinator's own
/// bookkeeping (counting, deferral, swallowing failures) can be observed
/// without a real archive.
class _ScriptedImporter extends Importer {
  _ScriptedImporter(super.libraryRoot);

  final Map<String, ImportResult> responses = {};
  final Set<String> throwers = {};
  final List<String> dispatched = [];

  @override
  Future<ImportResult> importArchive(
    String archivePath,
    String gameTitle, {
    String? targetFolder,
  }) async {
    if (throwers.contains(archivePath)) throw const FormatException('bad zip');
    dispatched.add(archivePath);
    return responses[archivePath]!;
  }

  @override
  Future<ImportResult> importFile(
    String filePath,
    String gameTitle, {
    String? targetFolder,
  }) async {
    if (throwers.contains(filePath)) throw const FormatException('bad rom');
    dispatched.add(filePath);
    return responses[filePath]!;
  }
}

void main() {
  late Directory tmp;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('coord_');
    root = p.join(tmp.path, 'Switch');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('libraryRoot', () {
    test('the injected root reaches the importer it builds', () {
      // The screens resolve the profile's root at runtime and hand it to the
      // coordinator, so the default importer must address that root rather
      // than the primary-profile constant.
      final coordinator = ImportCoordinator(libraryRoot: '/resolved/lib');

      expect(coordinator.importer.libraryRoot, '/resolved/lib');
    });

    test('falls back to the primary-profile constant without a root', () {
      expect(
        ImportCoordinator().importer.libraryRoot,
        AppPaths.libraryRoot,
      );
    });

    test('an injected importer wins over the root', () {
      final coordinator = ImportCoordinator(
        importer: Importer('/explicit'),
        libraryRoot: '/resolved/lib',
      );

      expect(coordinator.importer.libraryRoot, '/explicit');
    });
  });

  group('resolveTitle', () {
    test('falls back to the candidate when no API key is stored', () async {
      final db = _FakeDb();
      final coordinator = ImportCoordinator(db: db, importer: Importer(root));

      expect(await coordinator.resolveTitle('Mario Kart 8'), 'Mario Kart 8');
    });

    test('falls back to the candidate when the stored key is blank', () async {
      final db = _FakeDb()..settings['thegamesdb_api_key'] = '';
      final coordinator = ImportCoordinator(db: db, importer: Importer(root));

      expect(await coordinator.resolveTitle('Mario Kart 8'), 'Mario Kart 8');
    });
  });

  group('isUndecodableArchive', () {
    test('is true for 7z/rar only, case-insensitively', () {
      expect(ImportCoordinator.isUndecodableArchive('/x/Game.7z'), isTrue);
      expect(ImportCoordinator.isUndecodableArchive('/x/Game.RAR'), isTrue);
      expect(ImportCoordinator.isUndecodableArchive('/x/Game.zip'), isFalse);
      expect(ImportCoordinator.isUndecodableArchive('/x/Game.nsp'), isFalse);
    });
  });

  group('resolveTargetByTitleId', () {
    test('returns null when the name carries no title ID', () async {
      final coordinator =
          ImportCoordinator(db: _FakeDb(), importer: Importer(root));

      expect(await coordinator.resolveTargetByTitleId('Game.nsp'), isNull);
    });

    test('returns the stored folder for a title ID', () async {
      final folder = p.join(root, 'Mario');
      Directory(folder).createSync(recursive: true);
      final db = _FakeDb()..titleIds[folder] = '0100C1B00A3A8000';
      final coordinator = ImportCoordinator(db: db, importer: Importer(root));

      expect(
        await coordinator.resolveTargetByTitleId(
          'Mario Update [0100C1B00A3A8800].nsp',
        ),
        folder,
      );
    });

    test('ignores a stored folder that no longer exists', () async {
      final db = _FakeDb()..titleIds[p.join(root, 'Gone')] = '0100C1B00A3A8000';
      final coordinator = ImportCoordinator(db: db, importer: Importer(root));

      expect(
        await coordinator.resolveTargetByTitleId('Mario [0100C1B00A3A8000].nsp'),
        isNull,
      );
    });

    test('backfills the ID from a pre-existing library folder', () async {
      // The folder was organized before IDs were persisted: no db row exists,
      // so the scan must find it and record the ID for next time.
      final folder = p.join(root, 'Mario');
      Directory(folder).createSync(recursive: true);
      File(p.join(folder, 'Mario [0100C1B00A3A8000].nsp')).writeAsBytesSync([1]);
      final db = _FakeDb();
      final coordinator = ImportCoordinator(db: db, importer: Importer(root));

      expect(
        await coordinator.resolveTargetByTitleId(
          'Mario Update [0100C1B00A3A8800].nsp',
        ),
        folder,
      );
      expect(db.titleIds[folder], '0100C1B00A3A8000');
    });
  });

  group('importPaths', () {
    test('imports a zip and keeps the archive by default', () async {
      // The folder is named from the cleaned file name, so "Game.zip" lands in
      // "Game/".
      final zip = p.join(tmp.path, 'Game.zip');
      File(zip).writeAsBytesSync(makeZip({'Game.nsp': 'base'}));

      final coordinator = ImportCoordinator(db: _FakeDb(), importer: Importer(root));
      final report = await coordinator.importPaths([zip], deleteArchives: false);

      expect(report.imported, 1);
      expect(report.skipped, 0);
      expect(report.warnings, 0);
      expect(File(p.join(root, 'Game', 'Game.nsp')).existsSync(), isTrue);
      expect(File(zip).existsSync(), isTrue);
    });

    test('deletes a fully extracted archive only when deleteArchives', () async {
      final zip = p.join(tmp.path, 'game.zip');
      File(zip).writeAsBytesSync(makeZip({'Game.nsp': 'base'}));

      final coordinator = ImportCoordinator(db: _FakeDb(), importer: Importer(root));
      final report = await coordinator.importPaths([zip], deleteArchives: true);

      expect(report.imported, 1);
      expect(File(zip).existsSync(), isFalse);
    });

    test('keeps an archive that is not fully extracted even when asked', () async {
      // The library already holds a different Game.nsp, so the archive's own
      // entry is never written and extraction cannot be certified.
      Directory(p.join(root, 'Game')).createSync(recursive: true);
      File(p.join(root, 'Game', 'Game.nsp')).writeAsBytesSync([9]);
      final zip = p.join(tmp.path, 'game.zip');
      File(zip).writeAsBytesSync(makeZip({'Game.nsp': 'newbase'}));

      final coordinator = ImportCoordinator(db: _FakeDb(), importer: Importer(root));
      final report = await coordinator.importPaths([zip], deleteArchives: true);

      expect(report.imported, 1);
      expect(File(zip).existsSync(), isTrue);
    });

    test('defers an update that is processed before its base game', () async {
      // Real Switch pairing: the update ID folds onto the base's `...8000`.
      final update = p.join(tmp.path, 'Mario Update [0100C1B00A3A8800].nsp');
      final base = p.join(tmp.path, 'Mario [0100C1B00A3A8000].nsp');
      File(update).writeAsBytesSync([1]);
      File(base).writeAsBytesSync([2]);

      // Deliberately update-first: it must not be written off as skipped.
      final db = _FakeDb();
      final coordinator = ImportCoordinator(db: db, importer: Importer(root));
      final report =
          await coordinator.importPaths([update, base], deleteArchives: false);

      expect(report.skipped, 0);
      expect(report.imported, 2);
      // The update landed in the base's folder because the base's ID was
      // persisted during pass 1.
      expect(db.titleIds[p.join(root, 'Mario')], '0100C1B00A3A8000');
      expect(
        File(p.join(root, 'Mario', 'Mario [0100C1B00A3A8000].nsp')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(root, 'Mario', 'update', 'Mario Update [0100C1B00A3A8800].nsp'))
            .existsSync(),
        isTrue,
      );
    });

    test('counts an update with no base anywhere as skipped', () async {
      final update = p.join(tmp.path, 'Mario Update.nsp');
      File(update).writeAsBytesSync([1]);

      final coordinator = ImportCoordinator(db: _FakeDb(), importer: Importer(root));
      final report = await coordinator.importPaths([update], deleteArchives: false);

      expect(report.imported, 0);
      expect(report.skipped, 1);
    });

    test('skips 7z/rar without dispatching them to the importer', () async {
      final importer = _ScriptedImporter(root);
      final sevenZip = p.join(tmp.path, 'Game.7z');
      final rar = p.join(tmp.path, 'Game.rar');

      final coordinator = ImportCoordinator(db: _FakeDb(), importer: importer);
      final report =
          await coordinator.importPaths([sevenZip, rar], deleteArchives: false);

      expect(report.skipped, 2);
      expect(report.imported, 0);
      expect(importer.dispatched, isEmpty);
    });

    test('counts warnings reported by the importer', () async {
      final importer = _ScriptedImporter(root);
      final path = p.join(tmp.path, 'Game.nsp');
      importer.responses[path] = const ImportResult(
        gameFolder: '/lib/Game',
        baseFiles: 1,
        updateFiles: 0,
        dlcFiles: 0,
        fullyExtracted: true,
        warning: 'original not removed',
      );

      final coordinator = ImportCoordinator(db: _FakeDb(), importer: importer);
      final report = await coordinator.importPaths([path], deleteArchives: false);

      expect(report.imported, 1);
      expect(report.warnings, 1);
      expect(report.skipped, 0);
    });

    test('one failing file does not abort the batch', () async {
      final importer = _ScriptedImporter(root);
      final bad = p.join(tmp.path, 'broken.zip');
      final good = p.join(tmp.path, 'Game.zip');
      importer.throwers.add(bad);
      importer.responses[good] = const ImportResult(
        gameFolder: '/lib/Game',
        baseFiles: 1,
        updateFiles: 0,
        dlcFiles: 0,
        fullyExtracted: true,
      );

      final coordinator = ImportCoordinator(db: _FakeDb(), importer: importer);
      final report =
          await coordinator.importPaths([bad, good], deleteArchives: true);

      expect(report.skipped, 1);
      expect(report.imported, 1);
      expect(importer.dispatched, [good]);
    });
  });

  group('saveTitleIdFor', () {
    test('persists the title ID reported by the import onto the game folder',
        () async {
      final db = _FakeDb();
      final coordinator = ImportCoordinator(db: db, importer: Importer(root));

      await coordinator.saveTitleIdFor(
        const ImportResult(
          gameFolder: '/lib/Mario',
          baseFiles: 1,
          updateFiles: 0,
          dlcFiles: 0,
          fullyExtracted: true,
          titleId: '0100C1B00A3A8800',
        ),
        'Mario [0100C1B00A3A8800].zip',
      );

      expect(db.titleIds['/lib/Mario'], '0100C1B00A3A8000');
    });

    test('parses the ID from the source name when the import found none',
        () async {
      final db = _FakeDb();
      final coordinator = ImportCoordinator(db: db, importer: Importer(root));

      await coordinator.saveTitleIdFor(
        const ImportResult(
          gameFolder: '/lib/Mario',
          baseFiles: 1,
          updateFiles: 0,
          dlcFiles: 0,
          fullyExtracted: true,
        ),
        'Mario [0100c1b00a3a8800].nsp',
      );

      expect(db.titleIds['/lib/Mario'], '0100C1B00A3A8000');
    });

    test('leaves the stored ID alone when the import had no base files',
        () async {
      final db = _FakeDb()..titleIds['/lib/Mario'] = '0100C1B00A3A8000';
      final coordinator = ImportCoordinator(db: db, importer: Importer(root));

      // A lone update import: no base files, so it must not take the folder.
      await coordinator.saveTitleIdFor(
        const ImportResult(
          gameFolder: '/lib/Mario',
          baseFiles: 0,
          updateFiles: 1,
          dlcFiles: 0,
          fullyExtracted: true,
          titleId: '0100C1B00A3A8800',
        ),
        'Mario Update [0100C1B00A3A8800].nsp',
      );

      expect(db.titleIds['/lib/Mario'], '0100C1B00A3A8000');
    });
  });
}
