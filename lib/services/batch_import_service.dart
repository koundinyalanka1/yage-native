import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../utils/device_memory.dart';
import 'game_database.dart';
import 'retro_achievements_service.dart';

class BatchImportConfig {
  final int batchSize;
  final int parallelHashWorkers;
  final bool useIsolate;
  final Duration yieldInterval;

  const BatchImportConfig({
    required this.batchSize,
    required this.parallelHashWorkers,
    required this.useIsolate,
    required this.yieldInterval,
  });

  static const small = BatchImportConfig(
    batchSize: 50,
    parallelHashWorkers: 1,
    useIsolate: false,
    yieldInterval: Duration.zero,
  );

  static const medium = BatchImportConfig(
    batchSize: 50,
    parallelHashWorkers: 2,
    useIsolate: true,
    yieldInterval: Duration(milliseconds: 16),
  );

  static const large = BatchImportConfig(
    batchSize: 50,
    parallelHashWorkers: 1,
    useIsolate: true,
    yieldInterval: Duration(milliseconds: 32),
  );

  static const lowMemory = BatchImportConfig(
    batchSize: 25,
    parallelHashWorkers: 1,
    useIsolate: true,
    yieldInterval: Duration(milliseconds: 50),
  );

  static BatchImportConfig forContext({
    required int fileCount,
    int? deviceMemoryMB,
  }) {
    final memMB = deviceMemoryMB ?? 4096;
    if (memMB < 2048) {
      return lowMemory;
    }
    if (fileCount < 50) {
      return small;
    } else if (fileCount < 500) {
      return medium;
    } else {
      return memMB < 3072 ? lowMemory : large;
    }
  }
}

typedef ImportProgressCallback = void Function(BatchImportProgress progress);

typedef BatchImportedCallback = void Function(List<GameRom> games);

class BatchImportProgress {
  final int totalFiles;
  final int processedFiles;
  final int importedGames;
  final int skippedDuplicates;
  final String? currentFile;
  final bool isComplete;
  final String? error;

  const BatchImportProgress({
    required this.totalFiles,
    required this.processedFiles,
    required this.importedGames,
    required this.skippedDuplicates,
    this.currentFile,
    this.isComplete = false,
    this.error,
  });

  double get progress => totalFiles > 0 ? processedFiles / totalFiles : 0.0;

  BatchImportProgress copyWith({
    int? processedFiles,
    int? importedGames,
    int? skippedDuplicates,
    String? currentFile,
    bool? isComplete,
    String? error,
  }) {
    return BatchImportProgress(
      totalFiles: totalFiles,
      processedFiles: processedFiles ?? this.processedFiles,
      importedGames: importedGames ?? this.importedGames,
      skippedDuplicates: skippedDuplicates ?? this.skippedDuplicates,
      currentFile: currentFile ?? this.currentFile,
      isComplete: isComplete ?? this.isComplete,
      error: error ?? this.error,
    );
  }
}

class BatchImportService {
  static const _romExtensions = {
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

  final GameDatabase _database;

  BatchImportService(this._database);

  Future<int> countRomFiles(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return 0;

    int count = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase();
        if (_romExtensions.contains(ext)) {
          count++;
        }
      }
    }
    return count;
  }

  static bool _isSaveFile(String name, String ext) {
    if (ext == '.sav') return true;
    return RegExp(r'\.ss[0-5]$').hasMatch(name) ||
        RegExp(r'\.ss[0-5]\.png$').hasMatch(name);
  }

  Future<List<GameRom>> importFromDirectory({
    required String directoryPath,
    required Set<String> existingPaths,
    String? appSaveDir,
    ImportProgressCallback? onProgress,
    bool Function()? isCancelled,
    void Function(List<GameRom>)? onBatchImported,
  }) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      onProgress?.call(
        const BatchImportProgress(
          totalFiles: 0,
          processedFiles: 0,
          importedGames: 0,
          skippedDuplicates: 0,
          isComplete: true,
          error: 'Directory does not exist',
        ),
      );
      return [];
    }
    final totalCount = await countRomFiles(directoryPath);
    if (totalCount == 0) {
      onProgress?.call(
        const BatchImportProgress(
          totalFiles: 0,
          processedFiles: 0,
          importedGames: 0,
          skippedDuplicates: 0,
          isComplete: true,
        ),
      );
      return [];
    }
    final config = BatchImportConfig.forContext(
      fileCount: totalCount,
      deviceMemoryMB: deviceMemoryMB,
    );

    debugPrint(
      'BatchImportService: importing $totalCount ROMs '
      'with batch size ${config.batchSize}, '
      'isolate=${config.useIsolate}',
    );
    final importedGames = <GameRom>[];
    final newHashes = <String, String>{};
    var processedFiles = 0;
    var skippedDuplicates = 0;
    var currentBatch = <File>[];
    onProgress?.call(
      BatchImportProgress(
        totalFiles: totalCount,
        processedFiles: 0,
        importedGames: 0,
        skippedDuplicates: 0,
      ),
    );

    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (isCancelled?.call() == true) break;
        if (entity is! File) continue;
        final basename = p.basename(entity.path);
        if (basename.startsWith('.trashed-')) continue;

        final ext = p.extension(entity.path).toLowerCase();
        if (appSaveDir != null && _isSaveFile(basename, ext)) {
          try {
            final saveDir = Directory(appSaveDir);
            if (!await saveDir.exists()) await saveDir.create(recursive: true);
            final dest = File(p.join(appSaveDir, basename));
            if (!await dest.exists()) {
              await entity.copy(dest.path);
            }
          } catch (e) {
            debugPrint(
              'BatchImportService: failed to copy save file "$basename" — $e',
            );
          }
          continue;
        }

        if (!_romExtensions.contains(ext)) continue;
        if (existingPaths.contains(entity.path)) {
          processedFiles++;
          skippedDuplicates++;
          continue;
        }

        currentBatch.add(entity);
        if (currentBatch.length >= config.batchSize) {
          final batchResult = await _processBatch(
            batch: currentBatch,
            config: config,
            existingPaths: existingPaths,
          );

          importedGames.addAll(batchResult.games);
          newHashes.addAll(batchResult.hashes);
          processedFiles += currentBatch.length;
          skippedDuplicates += batchResult.duplicates;
          for (final game in batchResult.games) {
            existingPaths.add(game.path);
          }
          if (batchResult.games.isNotEmpty) {
            onBatchImported?.call(batchResult.games);
          }

          onProgress?.call(
            BatchImportProgress(
              totalFiles: totalCount,
              processedFiles: processedFiles,
              importedGames: importedGames.length,
              skippedDuplicates: skippedDuplicates,
              currentFile: currentBatch.lastOrNull?.path,
            ),
          );

          currentBatch = [];
          if (config.yieldInterval > Duration.zero) {
            await Future.delayed(config.yieldInterval);
          }
        }
      }

      if (isCancelled?.call() == true) {
        onProgress?.call(
          BatchImportProgress(
            totalFiles: totalCount,
            processedFiles: processedFiles,
            importedGames: importedGames.length,
            skippedDuplicates: skippedDuplicates,
            isComplete: true,
            currentFile: null,
          ),
        );
        return importedGames;
      }
      if (currentBatch.isNotEmpty) {
        final batchResult = await _processBatch(
          batch: currentBatch,
          config: config,
          existingPaths: existingPaths,
        );

        importedGames.addAll(batchResult.games);
        newHashes.addAll(batchResult.hashes);
        processedFiles += currentBatch.length;
        skippedDuplicates += batchResult.duplicates;
        if (batchResult.games.isNotEmpty) {
          onBatchImported?.call(batchResult.games);
        }
      }
      if (importedGames.isNotEmpty) {
        await _database.upsertGames(importedGames, romHashes: newHashes);
      }

      onProgress?.call(
        BatchImportProgress(
          totalFiles: totalCount,
          processedFiles: processedFiles,
          importedGames: importedGames.length,
          skippedDuplicates: skippedDuplicates,
          isComplete: true,
        ),
      );
    } catch (e) {
      debugPrint('BatchImportService: import failed — $e');
      onProgress?.call(
        BatchImportProgress(
          totalFiles: totalCount,
          processedFiles: processedFiles,
          importedGames: importedGames.length,
          skippedDuplicates: skippedDuplicates,
          isComplete: true,
          error: e.toString(),
        ),
      );
    }

    return importedGames;
  }

  Future<_BatchResult> _processBatch({
    required List<File> batch,
    required BatchImportConfig config,
    required Set<String> existingPaths,
  }) async {
    final games = <GameRom>[];
    final hashes = <String, String>{};
    var duplicates = 0;

    for (final file in batch) {
      var game = GameRom.fromPath(file.path);
      if (game == null) continue;
      String? hash;
      try {
        if (config.useIsolate) {
          hash = await compute(
            RetroAchievementsService.computeRAHash,
            file.path,
          );
        } else {
          hash = await RetroAchievementsService.computeRAHash(file.path);
        }
      } catch (e) {
        debugPrint(
          'BatchImportService: RA hash computation failed for "${file.path}" — $e',
        );
      }
      if (hash != null) {
        final existingPath = await _database.getPathByRomHash(hash);
        if (existingPath != null) {
          duplicates++;
          continue;
        }
        hashes[file.path] = hash;
      }

      if (GameRom.isPceFamilyExtension(game.extension)) {
        game = GameRom.classifyWithRomHash(game, romHash: hash);
      }

      games.add(game);
    }

    return _BatchResult(games: games, hashes: hashes, duplicates: duplicates);
  }

  Future<Map<GamePlatform, int>> countByPlatform(String directoryPath) async {
    final counts = <GamePlatform, int>{};
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return counts;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final basename = p.basename(entity.path);
      if (basename.startsWith('.trashed-')) continue;

      final ext = p.extension(entity.path).toLowerCase();
      if (!_romExtensions.contains(ext)) continue;

      final game = GameRom.fromPath(entity.path);
      if (game != null) {
        counts[game.platform] = (counts[game.platform] ?? 0) + 1;
      }
    }

    return counts;
  }
}

class _BatchResult {
  final List<GameRom> games;
  final Map<String, String> hashes;
  final int duplicates;

  _BatchResult({
    required this.games,
    required this.hashes,
    required this.duplicates,
  });
}
