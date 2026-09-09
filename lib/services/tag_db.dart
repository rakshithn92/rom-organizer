import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite persistence for app settings (TheGamesDB API key, cached cover art).
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

  /// Removes a setting entirely (a real delete, not a blank write).
  Future<void> deleteSetting(String key) async {
    final db = await _database;
    await db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }
}
