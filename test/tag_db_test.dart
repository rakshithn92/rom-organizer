import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:rom_organizer/services/tag_db.dart';

/// TagDb memoizes its open in a static future, so every test needs its own
/// database file and a cleared memo. The ffi factory lets `getDatabasesPath()`
/// be redirected at a real temp directory without an Android plugin.
void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('tagdb_');
    await databaseFactory.setDatabasesPath(tmp.path);
    TagDb.resetForTesting();
  });

  tearDown(() {
    TagDb.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('writes, reads and deletes a setting', () async {
    final db = TagDb();
    expect(await db.getSetting('thegamesdb_api_key'), isNull);

    await db.saveSetting('thegamesdb_api_key', 'abc123');
    expect(await db.getSetting('thegamesdb_api_key'), 'abc123');

    // A repeat write replaces rather than duplicating the row.
    await db.saveSetting('thegamesdb_api_key', 'xyz');
    expect(await db.getSetting('thegamesdb_api_key'), 'xyz');

    await db.deleteSetting('thegamesdb_api_key');
    expect(await db.getSetting('thegamesdb_api_key'), isNull);
  });

  group('migratePathPrefix', () {
    test('rewrites cover: and titleid: keys onto the new prefix', () async {
      final db = TagDb();
      await db.saveSetting('cover:/old/lib/Game A', 'urlA');
      await db.saveSetting('titleid:/old/lib/Game B', '0100C1B00A3A0000');

      await db.migratePathPrefix('/old/lib', '/new/lib');

      expect(await db.getSetting('cover:/new/lib/Game A'), 'urlA');
      expect(await db.getSetting('titleid:/new/lib/Game B'), '0100C1B00A3A0000');
      expect(await db.getSetting('cover:/old/lib/Game A'), isNull);
      expect(await db.getSetting('titleid:/old/lib/Game B'), isNull);
    });

    test('keeps an existing destination value and drops the stale key',
        () async {
      final db = TagDb();
      await db.saveSetting('cover:/old/lib/Game C', 'stale');
      await db.saveSetting('cover:/new/lib/Game C', 'fresh');

      await db.migratePathPrefix('/old/lib', '/new/lib');

      expect(await db.getSetting('cover:/new/lib/Game C'), 'fresh');
      expect(await db.getSetting('cover:/old/lib/Game C'), isNull);
    });

    test('leaves non-prefixed keys and other key kinds untouched', () async {
      final db = TagDb();
      await db.saveSetting('thegamesdb_api_key', 'keepme');
      // Right shape, wrong prefix — not part of this migration.
      await db.saveSetting('cover:/elsewhere/Game D', 'other');
      // Prefixed by the old root, but not a path-bearing key kind.
      await db.saveSetting('unrelated:/old/lib/Game E', 'untouched');

      await db.migratePathPrefix('/old/lib', '/new/lib');

      expect(await db.getSetting('thegamesdb_api_key'), 'keepme');
      expect(await db.getSetting('cover:/elsewhere/Game D'), 'other');
      expect(await db.getSetting('unrelated:/old/lib/Game E'), 'untouched');
    });
  });

  group('title IDs', () {
    test('stores the canonical base ID for a folder', () async {
      final db = TagDb();

      // An update ID normalizes to its base ID on write...
      await db.saveTitleId('/lib/Mario', '0100C1B00A3A8800');
      expect(await db.titleIdForFolder('/lib/Mario'), '0100C1B00A3A8000');

      // ...so a later lookup with any variant of the ID finds the folder.
      expect(await db.folderForTitleId('0100C1B00A3A8800'), '/lib/Mario');
      expect(await db.folderForTitleId('0100c1b00a3a8000'), '/lib/Mario');
    });

    test('finds a folder whose ID was stored raw by an older version',
        () async {
      final db = TagDb();
      await db.saveSetting('titleid:/lib/Legacy', '0100c1b00a3a8800');

      expect(await db.folderForTitleId('0100C1B00A3A8000'), '/lib/Legacy');
    });

    test('returns null for an unknown or malformed ID', () async {
      final db = TagDb();
      await db.saveTitleId('/lib/Mario', '0100C1B00A3A8000');

      expect(await db.folderForTitleId('0100AAAAAAAAAA8800'), isNull);
      expect(await db.folderForTitleId('not-a-title-id'), isNull);
    });

    test('deleteTitleId removes only that folder mapping', () async {
      final db = TagDb();
      await db.saveTitleId('/lib/Mario', '0100C1B00A3A8000');
      await db.saveTitleId('/lib/Zelda', '0100152000022000');

      await db.deleteTitleId('/lib/Mario');

      expect(await db.titleIdForFolder('/lib/Mario'), isNull);
      expect(await db.folderForTitleId('0100C1B00A3A8000'), isNull);
      expect(await db.folderForTitleId('0100152000022000'), '/lib/Zelda');
      expect(await db.getSetting('cover:/lib/Mario'), isNull);
    });
  });
}
