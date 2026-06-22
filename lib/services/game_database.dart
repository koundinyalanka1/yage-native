import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../core/mgba_bindings.dart';
import '../models/cheat.dart';
import '../models/game_rom.dart';

/// SQLite database for persisting the game library.
///
/// Replaces the previous SharedPreferences JSON-blob approach, which does not
/// scale well as the library grows because every mutation rewrites the entire
/// blob.  With SQLite each operation is an efficient row-level write.
class GameDatabase {
  static const int _version = 3;
  static const String _dbName = 'game_library.db';

  /// SharedPreferences keys used by the legacy JSON storage.
  static const String _legacyGamesKey = 'game_library';
  static const String _legacyDirsKey = 'rom_directories';

  Database? _db;

  /// The opened database instance.  Call [open] first.
  Database get db {
    assert(
      _db != null,
      'GameDatabase.open() must be called before accessing db',
    );
    return _db!;
  }

  bool get isOpen => _db != null;

  // ──────────── Open / create ────────────

  /// Open (or create) the database and run any pending migrations.
  /// If legacy SharedPreferences data exists it is migrated automatically.
  /// Throws on disk full, permission denied, or corrupt SQLite.
  Future<void> open({bool migrateLegacyData = true}) async {
    if (_db != null) return;

    try {
      final dbPath = p.join(await getDatabasesPath(), _dbName);
      _db = await openDatabase(
        dbPath,
        version: _version,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );

      // One-time migration from SharedPreferences -> SQLite. Android TV
      // launches must not touch legacy SharedPreferences on the critical path:
      // some Sony/MediaTek builds can stall long enough to trigger a launch
      // ANR before the app receives a focused window.
      if (migrateLegacyData) {
        await _migrateLegacyData();
      }
    } catch (e) {
      _db = null;
      rethrow;
    }
  }

  /// Runs on every connection, before [onCreate] / [onUpgrade].
  ///
  /// * WAL mode is enabled automatically by sqflite_android (via
  ///   `SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING`), so no PRAGMA needed.
  /// * `busy_timeout` gives sqflite a 5 s budget to retry on contention
  ///   instead of immediately failing with `SQLITE_BUSY`.
  /// * `foreign_keys=ON` is defensive — sqflite defaults to off.
  Future<void> _onConfigure(Database db) async {
    try {
      // `PRAGMA busy_timeout=N` RETURNS the new value as a result row, so on
      // Android's SQLiteDatabase it must be issued via rawQuery — db.execute()
      // rejects statements that return rows ("Queries can be performed using
      // SQLiteDatabase query or rawQuery methods only"), which is exactly the
      // error this used to log on every launch (phone + TV).
      await db.rawQuery('PRAGMA busy_timeout = 5000');
    } catch (e) {
      debugPrint('GameDatabase: PRAGMA busy_timeout failed — $e');
    }
    try {
      await db.execute('PRAGMA foreign_keys=ON');
    } catch (e) {
      debugPrint('GameDatabase: PRAGMA foreign_keys failed — $e');
    }
  }

  /// Shared DDL for the cheats table. Defined once so onCreate and
  /// onUpgrade can't drift out of sync.
  static const String _createCheatsTableSql = '''
    CREATE TABLE IF NOT EXISTS cheats (
      id          TEXT PRIMARY KEY,
      game_path   TEXT NOT NULL,
      system      TEXT NOT NULL,
      title       TEXT NOT NULL,
      cheat_code  TEXT NOT NULL,
      cheat_type  TEXT NOT NULL,
      is_active   INTEGER NOT NULL DEFAULT 0
    )
  ''';
  static const String _createCheatsIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_cheats_game_path ON cheats(game_path)';

  Future<void> _onCreate(Database db, int version) async {
    try {
      await db.execute('''
        CREATE TABLE games (
          path         TEXT PRIMARY KEY,
          name         TEXT NOT NULL,
          extension    TEXT NOT NULL,
          platform     TEXT NOT NULL,
          size_bytes   INTEGER NOT NULL,
          last_played  TEXT,
          cover_path   TEXT,
          is_favorite  INTEGER NOT NULL DEFAULT 0,
          total_play_time_seconds INTEGER NOT NULL DEFAULT 0,
          rom_hash     TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE rom_directories (
          path TEXT PRIMARY KEY
        )
      ''');

      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_games_rom_hash ON games(rom_hash)',
      );

      await db.execute(_createCheatsTableSql);
      await db.execute(_createCheatsIndexSql);
    } catch (e) {
      debugPrint('GameDatabase: onCreate failed — $e');
      rethrow;
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE games ADD COLUMN rom_hash TEXT');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_games_rom_hash ON games(rom_hash)',
      );
    }
    if (oldVersion < 3) {
      await db.execute(_createCheatsTableSql);
      await db.execute(_createCheatsIndexSql);
    }
  }

  // ──────────── Legacy migration ────────────

  Future<void> _migrateLegacyData() async {
    final prefs = await SharedPreferences.getInstance();
    final gamesJson = prefs.getString(_legacyGamesKey);

    if (gamesJson == null || gamesJson.isEmpty) return;

    debugPrint('GameDatabase: migrating legacy SharedPreferences data …');

    try {
      final List<dynamic> gamesList = jsonDecode(gamesJson);
      final batch = _db!.batch();
      int skipped = 0;
      for (final json in gamesList) {
        try {
          final map = json as Map<String, dynamic>;
          // Skip entries missing required fields instead of aborting the
          // entire migration.
          if (map['path'] == null ||
              map['name'] == null ||
              map['extension'] == null) {
            skipped++;
            continue;
          }
          batch.insert(
            'games',
            _gameJsonToRow(map),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        } catch (e) {
          debugPrint('GameDatabase: skipping corrupt legacy entry — $e');
          skipped++;
        }
      }
      if (skipped > 0) {
        debugPrint('GameDatabase: skipped $skipped corrupt legacy entries');
      }

      final dirs = prefs.getStringList(_legacyDirsKey);
      if (dirs != null) {
        for (final dir in dirs) {
          batch.insert('rom_directories', {
            'path': dir,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }

      await batch.commit(noResult: true);

      // Clear legacy keys so migration runs only once.
      await prefs.remove(_legacyGamesKey);
      await prefs.remove(_legacyDirsKey);

      debugPrint(
        'GameDatabase: migration complete (${gamesList.length} games).',
      );
    } catch (e) {
      debugPrint('GameDatabase: migration failed — $e');
      // Non-fatal: the legacy data stays in SharedPreferences so the user
      // can retry on next launch.
    }
  }

  /// Convert a legacy JSON map (same format as GameRom.toJson) to a flat
  /// row map suitable for SQLite insertion.
  static Map<String, Object?> _gameJsonToRow(Map<String, dynamic> json) {
    // Platform: legacy data may store as int index or string name.
    final rawPlatform = json['platform'];
    final String platformStr;
    if (rawPlatform is String) {
      platformStr = rawPlatform;
    } else if (rawPlatform is int) {
      platformStr =
          GamePlatform.values.elementAtOrNull(rawPlatform)?.name ?? 'unknown';
    } else {
      platformStr = 'unknown';
    }

    return {
      'path': json['path'] as String,
      'name': json['name'] as String,
      'extension': json['extension'] as String,
      'platform': platformStr,
      'size_bytes': (json['sizeBytes'] as num?)?.toInt() ?? 0,
      'last_played': json['lastPlayed'] as String?,
      'cover_path': json['coverPath'] as String?,
      'is_favorite': (json['isFavorite'] as bool? ?? false) ? 1 : 0,
      'total_play_time_seconds': json['totalPlayTimeSeconds'] as int? ?? 0,
      'rom_hash': json['romHash'] as String?,
    };
  }

  // ──────────── CRUD helpers ────────────

  /// Read all games from the database, ordered by name.
  /// Returns empty list on SQLiteException, disk full, or corrupt DB.
  Future<List<GameRom>> getAllGames() async {
    try {
      final rows = await db.query('games', orderBy: 'name COLLATE NOCASE ASC');
      return rows.map(_rowToGameRom).toList();
    } catch (e) {
      debugPrint('GameDatabase: getAllGames failed — $e');
      return [];
    }
  }

  /// Insert or replace a single game.
  Future<bool> upsertGame(GameRom game, {String? romHash}) async {
    try {
      await db.insert(
        'games',
        _gameRomToRow(game, romHash: romHash),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    } catch (e) {
      debugPrint('GameDatabase: upsertGame failed — $e');
      return false;
    }
  }

  /// Insert or replace many games in a single transaction.
  Future<bool> upsertGames(
    List<GameRom> games, {
    Map<String, String>? romHashes,
  }) async {
    try {
      final batch = db.batch();
      for (final game in games) {
        final hash = romHashes?[game.path];
        batch.insert(
          'games',
          _gameRomToRow(game, romHash: hash),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      return true;
    } catch (e) {
      debugPrint('GameDatabase: upsertGames failed — $e');
      return false;
    }
  }

  /// Check if a game with the given content hash already exists.
  /// Returns the existing game's path if found, null otherwise.
  Future<String?> getPathByRomHash(String romHash) async {
    try {
      final rows = await db.query(
        'games',
        columns: ['path'],
        where: 'rom_hash = ?',
        whereArgs: [romHash],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['path'] as String;
    } catch (e) {
      debugPrint('GameDatabase: getPathByRomHash failed — $e');
      return null;
    }
  }

  /// Delete a game by path.
  Future<bool> deleteGame(String path) async {
    try {
      await db.delete('games', where: 'path = ?', whereArgs: [path]);
      return true;
    } catch (e) {
      debugPrint('GameDatabase: deleteGame failed — $e');
      return false;
    }
  }

  /// Delete all games whose path starts with [prefix].
  Future<bool> deleteGamesWithPrefix(String prefix) async {
    try {
      final escaped = prefix.replaceAll('%', r'\%').replaceAll('_', r'\_');
      await db.delete(
        'games',
        where: "path LIKE ? ESCAPE '\\'",
        whereArgs: ['$escaped%'],
      );
      return true;
    } catch (e) {
      debugPrint('GameDatabase: deleteGamesWithPrefix failed — $e');
      return false;
    }
  }

  /// Update specific columns for a game identified by [path].
  Future<bool> updateGame(String path, Map<String, Object?> values) async {
    try {
      await db.update('games', values, where: 'path = ?', whereArgs: [path]);
      return true;
    } catch (e) {
      debugPrint('GameDatabase: updateGame failed — $e');
      return false;
    }
  }

  // ──────────── ROM directories ────────────

  Future<List<String>> getRomDirectories() async {
    try {
      final rows = await db.query('rom_directories');
      return rows.map((r) => r['path'] as String).toList();
    } catch (e) {
      debugPrint('GameDatabase: getRomDirectories failed — $e');
      return [];
    }
  }

  Future<bool> addRomDirectory(String path) async {
    try {
      await db.insert('rom_directories', {
        'path': path,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      return true;
    } catch (e) {
      debugPrint('GameDatabase: addRomDirectory failed — $e');
      return false;
    }
  }

  Future<bool> removeRomDirectory(String path) async {
    try {
      await db.delete('rom_directories', where: 'path = ?', whereArgs: [path]);
      return true;
    } catch (e) {
      debugPrint('GameDatabase: removeRomDirectory failed — $e');
      return false;
    }
  }

  // ──────────── Row ↔ GameRom conversion ────────────

  static GameRom _rowToGameRom(Map<String, Object?> row) {
    return GameRom(
      path: row['path'] as String,
      name: row['name'] as String,
      extension: row['extension'] as String,
      platform: _parsePlatform(row['platform'] as String),
      sizeBytes: row['size_bytes'] as int,
      lastPlayed: row['last_played'] != null
          ? DateTime.tryParse(row['last_played'] as String)
          : null,
      coverPath: row['cover_path'] as String?,
      isFavorite: (row['is_favorite'] as int) == 1,
      totalPlayTimeSeconds: row['total_play_time_seconds'] as int? ?? 0,
    );
  }

  static Map<String, Object?> _gameRomToRow(GameRom game, {String? romHash}) {
    return {
      'path': game.path,
      'name': game.name,
      'extension': game.extension,
      'platform': game.platform.name,
      'size_bytes': game.sizeBytes,
      'last_played': game.lastPlayed?.toIso8601String(),
      'cover_path': game.coverPath,
      'is_favorite': game.isFavorite ? 1 : 0,
      'total_play_time_seconds': game.totalPlayTimeSeconds,
      'rom_hash': romHash,
    };
  }

  static GamePlatform _parsePlatform(String value) {
    return GamePlatform.values.firstWhere(
      (e) => e.name == value,
      orElse: () => GamePlatform.unknown,
    );
  }

  // ──────────── Cheats ────────────

  /// Load all cheats for a game identified by its ROM path.
  Future<List<Cheat>> getCheatsForGame(String gamePath) async {
    try {
      final rows = await db.query(
        'cheats',
        where: 'game_path = ?',
        whereArgs: [gamePath],
      );
      return rows.map(Cheat.fromRow).toList();
    } catch (e) {
      debugPrint('GameDatabase: getCheatsForGame failed — $e');
      return [];
    }
  }

  /// Insert or update a single cheat.
  Future<bool> upsertCheat(Cheat cheat) async {
    try {
      await db.insert(
        'cheats',
        cheat.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    } catch (e) {
      debugPrint('GameDatabase: upsertCheat failed — $e');
      return false;
    }
  }

  /// Update only the [is_active] flag for a cheat.
  Future<bool> updateCheatActive(String cheatId, bool isActive) async {
    try {
      await db.update(
        'cheats',
        {'is_active': isActive ? 1 : 0},
        where: 'id = ?',
        whereArgs: [cheatId],
      );
      return true;
    } catch (e) {
      debugPrint('GameDatabase: updateCheatActive failed — $e');
      return false;
    }
  }

  /// Delete a cheat by its [id].
  Future<bool> deleteCheat(String cheatId) async {
    try {
      await db.delete('cheats', where: 'id = ?', whereArgs: [cheatId]);
      return true;
    } catch (e) {
      debugPrint('GameDatabase: deleteCheat failed — $e');
      return false;
    }
  }

  /// Delete all cheats for a game.
  Future<bool> deleteCheatsForGame(String gamePath) async {
    try {
      await db.delete('cheats', where: 'game_path = ?', whereArgs: [gamePath]);
      return true;
    } catch (e) {
      debugPrint('GameDatabase: deleteCheatsForGame failed — $e');
      return false;
    }
  }

  // ──────────── Lifecycle ────────────

  Future<void> close() async {
    try {
      await _db?.close();
    } catch (e) {
      debugPrint('GameDatabase: close failed — $e');
    } finally {
      _db = null;
    }
  }
}
