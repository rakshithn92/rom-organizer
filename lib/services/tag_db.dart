import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite persistence for ROM tags, keyed by absolute file path.
///
/// Tags are free-form strings (e.g. "favorite", "played", "to-play",
/// "multiplayer"). A ROM can have many tags; a tag can apply to many ROMs.
class TagDb {
  static Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'rom_tags.db'),
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE tags(
            path TEXT NOT NULL,
            tag TEXT NOT NULL,
            PRIMARY KEY (path, tag)
          )
        ''');
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
    return _db!;
  }

  // ---- Settings (key/value) ----
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
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// Add a tag to a ROM. No-op if already present.
  Future<void> addTag(String path, String tag) async {
    final db = await _database;
    await db.insert(
      'tags',
      {'path': path, 'tag': tag},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Remove a tag from a ROM.
  Future<void> removeTag(String path, String tag) async {
    final db = await _database;
    await db.delete('tags', where: 'path = ? AND tag = ?', whereArgs: [path, tag]);
  }

  /// All tags for a single ROM path.
  Future<List<String>> tagsFor(String path) async {
    final db = await _database;
    final rows = await db.query('tags', where: 'path = ?', whereArgs: [path]);
    return rows.map((r) => r['tag'] as String).toList();
  }

  /// All distinct tags in the library, with how many ROMs carry each.
  Future<Map<String, int>> allTags() async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT tag, COUNT(*) AS c FROM tags GROUP BY tag ORDER BY c DESC',
    );
    return {
      for (final r in rows) r['tag'] as String: r['c'] as int,
    };
  }

  /// Re-key a ROM's tags after a rename (path changed).
  Future<void> moveTags(String oldPath, String newPath) async {
    final db = await _database;
    await db.transaction((txn) async {
      final rows = await txn.query('tags', where: 'path = ?', whereArgs: [oldPath]);
      await txn.delete('tags', where: 'path = ?', whereArgs: [oldPath]);
      for (final r in rows) {
        await txn.insert('tags', {'path': newPath, 'tag': r['tag']});
      }
    });
  }
}
