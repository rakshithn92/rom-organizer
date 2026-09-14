import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'title_parser.dart';

/// SQLite persistence for app settings (TheGamesDB API key, cached cover art).
class TagDb {
  static Future<Database>? _opening;

  Future<Database> get _database {
    // Memoize the in-flight open so concurrent callers share one open (and one
    // connection) instead of racing to open the file twice.
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'rom_tags.db'),
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE settings(
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
      },
      onUpgrade: (db, oldV, newV) async {
        // v1 -> v2: add settings table for the TheGamesDB API key.
        if (oldV < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS settings(
              key TEXT PRIMARY KEY,
              value TEXT
            )
          ''');
        }
      },
    );
  }

  Future<void> saveSetting(String key, String value) async {
    final db = await _database;
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getSetting(String key) async {
    final db = await _database;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// Removes a setting entirely (a real delete, not a blank write).
  Future<void> deleteSetting(String key) async {
    final db = await _database;
    await db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  /// Rewrites cached keys that contain absolute game-folder paths after the
  /// one-time move into Downloads. Existing destination keys win.
  Future<void> migratePathPrefix(String oldPrefix, String newPrefix) async {
    final db = await _database;
    final rows = await db.query('settings');
    await db.transaction((txn) async {
      for (final row in rows) {
        final key = row['key'] as String;
        final separator = key.indexOf(':') + 1;
        final storedPath = key.substring(separator);
        final hasOldPrefix = storedPath == oldPrefix ||
            storedPath.startsWith('$oldPrefix${p.separator}');
        if ((!key.startsWith('cover:') && !key.startsWith('titleid:')) ||
            !hasOldPrefix) {
          continue;
        }
        final migratedKey =
            '${key.substring(0, separator)}$newPrefix${key.substring(separator + oldPrefix.length)}';
        await txn.insert(
          'settings',
          {'key': migratedKey, 'value': row['value']},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await txn.delete('settings', where: 'key = ?', whereArgs: [key]);
      }
    });
  }

  // ---- Title-ID metadata (base game <-> update matching) ----
  // Stored as settings rows keyed "titleid:<folderPath>" = "<titleId>".

  Future<void> saveTitleId(String folderPath, String titleId) =>
      saveSetting(
        'titleid:$folderPath',
        TitleParser.canonicalBaseTitleId(titleId),
      );

  Future<String?> titleIdForFolder(String folderPath) =>
      getSetting('titleid:$folderPath');

  Future<void> deleteTitleId(String folderPath) =>
      deleteSetting('titleid:$folderPath');

  /// Returns the folder path that has [titleId] stored, or null.
  Future<String?> folderForTitleId(String titleId) async {
    final db = await _database;
    // ORDER BY makes the first matching row deterministic (callers may return
    // to this folder path repeatedly). TagDb stays storage-only; existence
    // checks belong to the caller.
    final rows = await db.query(
      'settings',
      where: "key LIKE 'titleid:%'",
      orderBy: 'key ASC',
    );
    final wanted = TitleParser.canonicalBaseTitleId(titleId);
    for (final r in rows) {
      // Normalize both sides so databases created by older app versions, which
      // stored the raw ID, continue to work without a schema migration.
      final value = r['value'] as String?;
      if (value == null) continue;
      if (TitleParser.canonicalBaseTitleId(value) == wanted) {
        return (r['key'] as String).substring('titleid:'.length);
      }
    }
    return null;
  }
}
