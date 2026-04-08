import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/game_rom.dart';
import '../core/mgba_bindings.dart';
import '../utils/device_memory.dart';
import 'batch_import_service.dart';
import 'game_database.dart';
import 'retro_achievements_service.dart';
import 'rom_folder_service.dart';

class GameLibraryService extends ChangeNotifier {
  @override
  void notifyListeners() {
    _revision++;
    super.notifyListeners();
  }

  final GameDatabase _database;
  late final BatchImportService _batchImportService;

  GameLibraryService(this._database) {
    _batchImportService = BatchImportService(_database);
  }

  List<GameRom> _games = [];
  List<String> _romDirectories = [];
  bool _isLoading = false;
  String? _error;
  int _revision = 0;

  String? _internalRomsDir;

  List<GameRom> get games => _games.toList();
  List<String> get romDirectories => _romDirectories;
  bool get isLoading => _isLoading;
  String? get error => _error;
  int get revision => _revision;

  final Completer<void> _initCompleter = Completer<void>();

  Future<void> get whenReady => _initCompleter.future;

  List<GameRom> getGamesByPlatform(GamePlatform? platform) {
    if (platform == null) return _games.toList();
    return _games.where((g) => g.platform == platform).toList();
  }

  List<GameRom> get favorites => _games.where((g) => g.isFavorite).toList();

  List<GameRom> get recentlyPlayed {
    final played = _games.where((g) => g.lastPlayed != null).toList();
    played.sort((a, b) => b.lastPlayed!.compareTo(a.lastPlayed!));
    return played.take(10).toList();
  }

  Future<String> getInternalRomsDir() async {
    if (_internalRomsDir != null) return _internalRomsDir!;
    try {
      final appDir = await getApplicationSupportDirectory();
      final romsDir = Directory(p.join(appDir.path, 'roms'));
      if (!await romsDir.exists()) {
        await romsDir.create(recursive: true);
      }
      _internalRomsDir = romsDir.path;
      return _internalRomsDir!;
    } catch (e) {
      debugPrint('GameLibraryService: getInternalRomsDir failed — $e');
      rethrow;
    }
  }

  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      _games = await _database.getAllGames();
      _romDirectories = await _database.getRomDirectories();

      _isLoading = false;
      _error = null;
      notifyListeners();
      if (!_initCompleter.isCompleted) _initCompleter.complete();
      _cleanupStaleEntriesInBackground();
    } catch (e) {
      _error = 'Failed to load library: $e';
      _isLoading = false;
      notifyListeners();
      if (!_initCompleter.isCompleted) _initCompleter.complete();
    }
  }

  void _cleanupStaleEntriesInBackground() {
    Future.microtask(() async {
      final stalePaths = <String>[];

      for (final game in List<GameRom>.from(_games)) {
        try {
          if (!await File(game.path).exists()) {
            stalePaths.add(game.path);
          }
        } catch (e) {
          debugPrint(
            'GameLibraryService: stale check failed for "${game.path}" — $e',
          );
          stalePaths.add(game.path);
        }
        await Future.delayed(Duration.zero);
      }

      if (stalePaths.isNotEmpty) {
        _games.removeWhere((g) => stalePaths.contains(g.path));
        for (final path in stalePaths) {
          await _database.deleteGame(path);
        }
        notifyListeners();
        debugPrint(
          'GameLibraryService: Cleaned up ${stalePaths.length} stale entries',
        );
      }
    });
  }

  Future<GameRom?> importRom(String sourcePath, {bool notify = true}) async {
    final romsDir = await getInternalRomsDir();
    final fileName = p.basename(sourcePath);
    final destPath = p.join(romsDir, fileName);
    if (sourcePath.startsWith(romsDir)) {
      return addRom(sourcePath, notify: notify);
    }
    try {
      await File(sourcePath).copy(destPath);
    } catch (e) {
      debugPrint('Error copying ROM to internal storage: $e');
      return null;
    }

    final game = await addRom(destPath, notify: notify);
    if (game == null) {
      try {
        await File(destPath).delete();
      } catch (e) {
        debugPrint(
          'GameLibraryService: failed to delete duplicate ROM file — $e',
        );
      }
    }
    return game;
  }

  Future<List<GameRom>> importRomZip(String zipPath) async {
    const romExtensions = {
      '.gba',
      '.gb',
      '.gbc',
      '.sgb',
      '.nes',
      '.unf',
      '.unif',
      '.sfc',
      '.smc',
      '.sms',
      '.gg',
      '.sg',
      '.md',
      '.gen',
      '.smd',
      '.bin',
      '.pce',
      '.sgx',
      '.cue',
      '.chd',
      '.z64',
      '.n64',
      '.v64',
      '.ngp',
      '.ngc',
      '.ws',
      '.wsc',
    };
    final romsDir = await getInternalRomsDir();
    final addedGames = <GameRom>[];

    try {
      final zipFile = File(zipPath);
      final zipSize = await zipFile.length();
      const lowRamLimitBytes = 10 * 1024 * 1024; 
      final memMB = deviceMemoryMB;
      if (memMB != null && memMB < 2048 && zipSize > lowRamLimitBytes) {
        debugPrint(
          'GameLibraryService: ZIP too large ($zipSize bytes) for low-RAM device ($memMB MB)',
        );
        throw ArchiveException(
          'ZIP file is too large for this device. '
          'Try a smaller archive or extract ROMs individually.',
        );
      }
      final input = InputFileStream(zipPath);
      try {
        final archive = ZipDecoder().decodeStream(input);

        for (final entry in archive.files) {
          if (!entry.isFile) continue;

          final ext = p.extension(entry.name).toLowerCase();
          if (!romExtensions.contains(ext)) continue;

          final fileName = p.basename(entry.name);
          final destPath = p.join(romsDir, fileName);

          if (await File(destPath).exists()) {
            await Future.delayed(const Duration(milliseconds: 16));
            final game = await addRom(destPath);
            if (game != null) addedGames.add(game);
            continue;
          }

          try {
            final output = OutputFileStream(destPath);
            try {
              entry.writeContent(output);
            } finally {
              await output.close();
            }
            await Future.delayed(const Duration(milliseconds: 32));

            final game = await addRom(destPath);
            if (game != null) {
              addedGames.add(game);
            } else {
              try {
                await File(destPath).delete();
              } catch (e) {
                debugPrint(
                  'GameLibraryService: failed to delete duplicate extracted ROM — $e',
                );
              }
            }
          } catch (e) {
            debugPrint('Error extracting ROM "$fileName" from ZIP: $e');
          }
        }

        await archive.clear();
      } finally {
        await input.close();
      }
    } on ArchiveException {
      rethrow;
    } catch (e) {
      debugPrint('Error reading ZIP file: $e');
    }
    try {
      final zipFile = File(zipPath);
      if (await zipFile.exists() && p.dirname(zipPath) == romsDir) {
        await zipFile.delete();
      }
    } catch (e) {
      debugPrint('GameLibraryService: failed to clean up ZIP file — $e');
    }

    return addedGames;
  }

  Future<GameRom?> addRom(String path, {bool notify = true}) async {
    var game = GameRom.fromPath(path);
    if (game == null) return null;
    if (_games.any((g) => g.path == path)) return null;
    await Future.delayed(const Duration(milliseconds: 16));
    final hash = await compute(RetroAchievementsService.computeRAHash, path);
    if (GameRom.isPceFamilyExtension(game.extension)) {
      game = GameRom.classifyWithRomHash(game, romHash: hash);
    }
    if (hash != null) {
      final existingPath = await _database.getPathByRomHash(hash);
      if (existingPath != null && existingPath != path) {
        debugPrint('GameLibraryService: skipping duplicate ROM (hash $hash)');
        return null;
      }
    }

    _games.add(game);
    if (!await _database.upsertGame(game, romHash: hash)) {
      _games.removeLast();
      return null;
    }
    if (notify) notifyListeners();
    return game;
  }

  Future<List<GameRom>> importFromDirectory(
    String path, {
    String? appSaveDir,
    ImportProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(path);
    if (!await dir.exists()) return [];
    final fileCount = await _batchImportService.countRomFiles(path);
    final batchThreshold = (deviceMemoryMB != null && deviceMemoryMB! < 2048)
        ? 20
        : 50;
    final addedGames = <GameRom>[];

    if (fileCount < batchThreshold) {
      final romExtensions = {
        '.gba',
        '.gb',
        '.gbc',
        '.sgb',
        '.nes',
        '.unf',
        '.unif',
        '.sfc',
        '.smc',
        '.sms',
        '.gg',
        '.sg',
        '.md',
        '.gen',
        '.smd',
        '.bin',
        '.pce',
        '.sgx',
        '.cue',
        '.chd',
        '.z64',
        '.n64',
        '.v64',
        '.ngp',
        '.ngc',
        '.ws',
        '.wsc',
      };
      var importedSinceNotify = 0;
      var processedCount = 0;

      if (appSaveDir != null) {
        final saveDir = Directory(appSaveDir);
        if (!await saveDir.exists()) await saveDir.create(recursive: true);
      }

      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (isCancelled?.call() == true) break;
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase();
        final name = p.basename(entity.path);
        if (appSaveDir != null) {
          final isSram = ext == '.sav';
          final isSaveState =
              RegExp(r'\.ss[0-5]$').hasMatch(name) ||
              RegExp(r'\.ss[0-5]\.png$').hasMatch(name);
          if (isSram || isSaveState) {
            try {
              final dest = File(p.join(appSaveDir, name));
              if (!await dest.exists()) {
                await entity.copy(dest.path);
              }
            } catch (e) {
              debugPrint(
                'GameLibraryService: failed to copy save file "$name" — $e',
              );
            }
            continue;
          }
        }

        if (!romExtensions.contains(ext)) continue;

        processedCount++;
        onProgress?.call(
          BatchImportProgress(
            totalFiles: fileCount,
            processedFiles: processedCount,
            importedGames: addedGames.length,
            skippedDuplicates: 0,
            currentFile: entity.path,
          ),
        );

        final game = await importRom(entity.path, notify: false);
        if (game != null) {
          addedGames.add(game);
          importedSinceNotify++;
          if (importedSinceNotify >= 3) {
            notifyListeners();
            importedSinceNotify = 0;
          }
        }
      }
      if (importedSinceNotify > 0) {
        notifyListeners();
      }
    } else {
      debugPrint('GameLibraryService: Using batch import for $fileCount ROMs');

      final existingPaths = _games.map((g) => g.path).toSet();
      await _batchImportService.importFromDirectory(
        directoryPath: path,
        existingPaths: existingPaths,
        appSaveDir: appSaveDir,
        onProgress: (progress) => onProgress?.call(progress),
        isCancelled: isCancelled,
        onBatchImported: (batchGames) {
          _games.addAll(batchGames);
          addedGames.addAll(batchGames);
          notifyListeners();
        },
      );
    }

    if (addedGames.isNotEmpty) notifyListeners();
    return addedGames;
  }

  Future<void> addRomDirectory(String path) async {
    if (_romDirectories.contains(path)) return;

    if (!await _database.addRomDirectory(path)) return;
    _romDirectories.add(path);
    await scanDirectory(path);
  }

  Future<void> scanDirectory(
    String path, {
    ImportProgressCallback? onProgress,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        _error = 'Directory does not exist: $path';
        _isLoading = false;
        notifyListeners();
        return;
      }
      final fileCount = await _batchImportService.countRomFiles(path);

      final batchThreshold = (deviceMemoryMB != null && deviceMemoryMB! < 2048)
          ? 20
          : 50;

      if (fileCount < batchThreshold) {
        final newGames = <GameRom>[];
        final hashes = <String, String>{};

        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final basename = p.basename(entity.path);
          if (basename.startsWith('.trashed-')) continue;

          final ext = p.extension(entity.path).toLowerCase();
          if (![
            '.gba',
            '.gb',
            '.gbc',
            '.sgb',
            '.nes',
            '.unf',
            '.unif',
            '.sfc',
            '.smc',
            '.sms',
            '.gg',
            '.sg',
            '.md',
            '.gen',
            '.smd',
            '.bin',
            '.pce',
            '.sgx',
            '.cue',
            '.chd',
            '.z64',
            '.n64',
            '.v64',
            '.ngp',
            '.ngc',
            '.ws',
            '.wsc',
          ].contains(ext)) {
            continue;
          }

          var game = GameRom.fromPath(entity.path);
          if (game == null || _games.any((g) => g.path == entity.path)) {
            continue;
          }
          try {
            final hash = await compute(
              RetroAchievementsService.computeRAHash,
              entity.path,
            );
            if (hash != null) {
              final existingPath = await _database.getPathByRomHash(hash);
              if (existingPath != null) continue; 
              hashes[entity.path] = hash;
              if (GameRom.isPceFamilyExtension(ext)) {
                game = GameRom.classifyWithRomHash(game, romHash: hash);
              }
            }
          } catch (e) {
            debugPrint(
              'GameLibraryService: RA hash computation failed for "${entity.path}" — $e',
            );
          }

          final resolvedGame = game!;
          _games.add(resolvedGame);
          newGames.add(resolvedGame);
        }
        if (newGames.isNotEmpty) {
          notifyListeners();
          try {
            await _database.upsertGames(newGames, romHashes: hashes);
          } catch (e) {
            debugPrint('GameLibraryService: scanDirectory upsert failed — $e');
          }
        }
      } else {
        debugPrint('GameLibraryService: Using batch scan for $fileCount ROMs');

        final existingPaths = _games.map((g) => g.path).toSet();
        await _batchImportService.importFromDirectory(
          directoryPath: path,
          existingPaths: existingPaths,
          onProgress: (progress) {
            onProgress?.call(progress);
          },
          onBatchImported: (batchGames) {
            _games.addAll(batchGames);
            notifyListeners();
          },
        );
      }

      _isLoading = false;
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to scan directory: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> removeRom(GameRom game) async {
    _games.removeWhere((g) => g.path == game.path);
    try {
      await _database.deleteGame(game.path);
    } catch (e) {
      debugPrint('GameLibraryService: removeRom delete failed — $e');
    }
    notifyListeners();
  }

  Future<void> removeRomDirectory(String path) async {
    _romDirectories.remove(path);
    final prefix = path.endsWith(p.separator) ? path : '$path${p.separator}';
    _games.removeWhere((g) => g.path.startsWith(prefix) || g.path == path);
    try {
      await _database.removeRomDirectory(path);
      await _database.deleteGamesWithPrefix(prefix);
    } catch (e) {
      debugPrint('GameLibraryService: removeRomDirectory failed — $e');
    }
    notifyListeners();
  }

  Future<void> toggleFavorite(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      _games[index] = _games[index].copyWith(
        isFavorite: !_games[index].isFavorite,
      );
      try {
        await _database.updateGame(game.path, {
          'is_favorite': _games[index].isFavorite ? 1 : 0,
        });
      } catch (e) {
        _games[index] = _games[index].copyWith(
          isFavorite: !_games[index].isFavorite,
        );
        debugPrint('GameLibraryService: toggleFavorite failed — $e');
      }
      notifyListeners();
    }
  }

  Future<void> updateLastPlayed(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      final now = DateTime.now();
      _games[index] = _games[index].copyWith(lastPlayed: now);
      try {
        await _database.updateGame(game.path, {
          'last_played': now.toIso8601String(),
        });
      } catch (e) {
        debugPrint('GameLibraryService: updateLastPlayed failed — $e');
      }
      notifyListeners();
    }
  }

  Future<void> addPlayTime(GameRom game, int seconds) async {
    if (seconds <= 0) return;
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      final newTotal = _games[index].totalPlayTimeSeconds + seconds;
      _games[index] = _games[index].copyWith(totalPlayTimeSeconds: newTotal);
      try {
        await _database.updateGame(game.path, {
          'total_play_time_seconds': newTotal,
        });
      } catch (e) {
        _games[index] = _games[index].copyWith(
          totalPlayTimeSeconds: _games[index].totalPlayTimeSeconds - seconds,
        );
        debugPrint('GameLibraryService: addPlayTime failed — $e');
      }
      notifyListeners();
    }
  }

  Future<void> setCoverArt(GameRom game, String coverPath) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      final prev = _games[index].coverPath;
      _games[index] = _games[index].copyWith(coverPath: coverPath);
      try {
        await _database.updateGame(game.path, {'cover_path': coverPath});
      } catch (e) {
        _games[index] = _games[index].copyWith(coverPath: prev);
        debugPrint('GameLibraryService: setCoverArt failed — $e');
      }
      notifyListeners();
    }
  }

  Future<void> removeCoverArt(GameRom game) async {
    final index = _games.indexWhere((g) => g.path == game.path);
    if (index != -1) {
      final prev = _games[index].coverPath;
      _games[index] = _games[index].copyWith(coverPath: null);
      try {
        await _database.updateGame(game.path, {'cover_path': null});
      } catch (e) {
        _games[index] = _games[index].copyWith(coverPath: prev);
        debugPrint('GameLibraryService: removeCoverArt failed — $e');
      }
      notifyListeners();
    }
  }

  Future<void> refresh({
    String? safFolderUri,
    ImportProgressCallback? onProgress,
  }) async {
    _isLoading = true;
    notifyListeners();
    if (safFolderUri != null) {
      try {
        await RomFolderService.importFromFolder(safFolderUri);
      } catch (e) {
        debugPrint('GameLibraryService: SAF sync on refresh failed — $e');
      }
    }
    final gameData = Map.fromEntries(_games.map((g) => MapEntry(g.path, g)));

    const romExtensions = {
      '.gba',
      '.gb',
      '.gbc',
      '.sgb',
      '.nes',
      '.unf',
      '.unif',
      '.sfc',
      '.smc',
      '.sms',
      '.gg',
      '.sg',
      '.md',
      '.gen',
      '.smd',
      '.bin',
      '.pce',
      '.sgx',
      '.cue',
      '.chd',
      '.z64',
      '.n64',
      '.v64',
      '.ngp',
      '.ngc',
      '.ws',
      '.wsc',
    };
    final chunkSize = (deviceMemoryMB != null && deviceMemoryMB! < 2048)
        ? 250
        : 500;
    final dirsToScan = List<String>.from(_romDirectories);
    try {
      final internalDir = await getInternalRomsDir();
      if (!dirsToScan.contains(internalDir)) {
        dirsToScan.add(internalDir);
      }
    } catch (e) {
      debugPrint('GameLibraryService: internal ROM dir unavailable — $e');
    }

    try {
      var processedCount = 0;
      final seenPaths = <String>{};
      var chunk = <GameRom>[];
      _games.clear();

      Future<void> mergeAndFlushChunk() async {
        if (chunk.isEmpty) return;
        for (var i = 0; i < chunk.length; i++) {
          final prev = gameData[chunk[i].path];
          if (prev != null) {
            chunk[i] = chunk[i].copyWith(
              isFavorite: prev.isFavorite,
              lastPlayed: prev.lastPlayed,
              totalPlayTimeSeconds: prev.totalPlayTimeSeconds,
              coverPath: prev.coverPath,
            );
          }
        }
        _games.addAll(chunk);
        try {
          await _database.upsertGames(chunk);
        } catch (e) {
          debugPrint('GameLibraryService: refresh upsert failed — $e');
        }
        notifyListeners();
        chunk = [];
      }

      for (final dir in dirsToScan) {
        try {
          final dirObj = Directory(dir);
          if (!await dirObj.exists()) continue;

          await for (final entity in dirObj.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is! File) continue;

            final basename = p.basename(entity.path);
            if (basename.startsWith('.trashed-')) continue;

            final ext = p.extension(entity.path).toLowerCase();
            if (!romExtensions.contains(ext)) continue;

            if (seenPaths.contains(entity.path)) continue;
            seenPaths.add(entity.path);

            var game = GameRom.fromPath(entity.path);
            if (game == null && ext == '.bin') {
              final prev = gameData[entity.path];
              if (prev != null && prev.platform == GamePlatform.md) {
                try {
                  final stat = await entity.stat();
                  game = prev.copyWith(sizeBytes: stat.size);
                } catch (e) {
                  debugPrint(
                    'GameLibraryService: failed to stat legacy .bin ROM — $e',
                  );
                }
              }
            }
            if (game != null && GameRom.isPceFamilyExtension(ext)) {
              try {
                final hash = await compute(
                  RetroAchievementsService.computeRAHash,
                  entity.path,
                );
                game = GameRom.classifyWithRomHash(game, romHash: hash);
              } catch (e) {
                debugPrint(
                  'GameLibraryService: SGX classification hash failed for "${entity.path}" — $e',
                );
              }
            }
            if (game != null) {
              chunk.add(game);
              if (chunk.length >= chunkSize) {
                await mergeAndFlushChunk();
              }
            }

            processedCount++;
            if (processedCount % 100 == 0) {
              onProgress?.call(
                BatchImportProgress(
                  totalFiles: processedCount,
                  processedFiles: processedCount,
                  importedGames: _games.length + chunk.length,
                  skippedDuplicates: 0,
                ),
              );
              await Future.delayed(Duration.zero);
            }
          }
        } catch (e) {
          debugPrint('Refresh: failed to scan "$dir" — $e');
        }
      }
      await mergeAndFlushChunk();
      try {
        final allDbGames = await _database.getAllGames();
        for (final dbGame in allDbGames) {
          if (!seenPaths.contains(dbGame.path)) {
            await _database.deleteGame(dbGame.path);
          }
        }
      } catch (e) {
        debugPrint('GameLibraryService: refresh stale cleanup failed — $e');
      }

      onProgress?.call(
        BatchImportProgress(
          totalFiles: _games.length,
          processedFiles: _games.length,
          importedGames: _games.length,
          skippedDuplicates: 0,
          isComplete: true,
        ),
      );

      _error = null;
    } catch (e) {
      debugPrint('GameLibraryService: refresh failed — $e');
      _error = 'Refresh failed: $e';
      _games = gameData.values.toList();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  List<GameRom> search(String query) {
    if (query.isEmpty) return _games;
    final lowerQuery = query.toLowerCase();
    return _games
        .where((g) => g.name.toLowerCase().contains(lowerQuery))
        .toList();
  }
}
