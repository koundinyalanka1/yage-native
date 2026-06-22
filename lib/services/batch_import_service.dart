import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../utils/device_memory.dart';
import 'game_database.dart';
import 'retro_achievements_service.dart';

/// Configuration for batch import based on device memory and file count.
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

  /// Small library: fast sequential processing (< 50 files)
  static const small = BatchImportConfig(
    batchSize: 50,
    parallelHashWorkers: 1,
    useIsolate: false,
    yieldInterval: Duration.zero,
  );

  /// Medium library: batched processing with progress (50-500 files)
  static const medium = BatchImportConfig(
    batchSize: 50,
    parallelHashWorkers: 2,
    useIsolate: true,
    yieldInterval: Duration(milliseconds: 16),
  );

  /// Large library (500+): memory-efficient streaming
  static const large = BatchImportConfig(
    batchSize: 50,
    parallelHashWorkers: 1,
    useIsolate: true,
    yieldInterval: Duration(milliseconds: 32),
  );

  /// Low RAM device: very conservative
  static const lowMemory = BatchImportConfig(
    batchSize: 25,
    parallelHashWorkers: 1,
    useIsolate: true,
    yieldInterval: Duration(milliseconds: 50),
  );

  /// Select config based on file count and device memory.
  static BatchImportConfig forContext({
    required int fileCount,
    int? deviceMemoryMB,
  }) {
    final memMB = deviceMemoryMB ?? 4096;

    // Low RAM devices (< 2GB): always use conservative config
    if (memMB < 2048) {
      return lowMemory;
    }

    // Select based on file count (threshold: 50 files)
    if (fileCount < 50) {
      return small;
    } else if (fileCount < 500) {
      return medium;
    } else {
      // Large library (500+)
      return memMB < 3072 ? lowMemory : large;
    }
  }
}

/// Progress callback for batch import operations.
typedef ImportProgressCallback = void Function(BatchImportProgress progress);

/// Callback for when a batch of games has been imported.
/// This allows the caller to add games incrementally to their list.
typedef BatchImportedCallback = void Function(List<GameRom> games);

/// Progress information for batch import.
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

/// Service for memory-efficient batch import of large ROM collections.
///
/// Handles 5000+ ROMs by:
/// 1. Streaming directory contents (not loading all into memory)
/// 2. Processing in configurable batches
/// 3. Running hash computation in isolates
/// 4. Yielding to UI thread periodically
/// 5. Batching database writes
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
    '.z64',
    '.n64',
    '.v64',
    '.ngp',
    '.ngc',
    '.ws',
    '.wsc',
    '.a26',
    '.vb',
    '.tic',
    '.p8',
    '.p8.png',
    // Nintendo DS
    '.nds',
    // Mattel Intellivision
    '.int',
    '.itv',
    '.rom',
  };

  final GameDatabase _database;

  BatchImportService(this._database);

  /// Count ROM files in a directory without loading all into memory.
  /// Uses streaming enumeration for memory efficiency.
  Future<int> countRomFiles(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return 0;

    int count = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final lpath = entity.path.toLowerCase();
        final ext = lpath.endsWith('.p8.png')
            ? '.p8.png'
            : p.extension(entity.path).toLowerCase();
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

  /// Import ROMs from a directory using adaptive batch processing.
  ///
  /// [directoryPath] - Path to scan for ROM files
  /// [existingPaths] - Set of paths already in library (for fast duplicate check)
  /// [appSaveDir] - If set, copy matching saves (.sav, .ss0-.ss5) in same pass
  /// [onProgress] - Optional callback for progress updates
  /// [isCancelled] - When non-null, checked periodically; if true, import stops early
  /// [onBatchImported] - Optional callback invoked after each batch with new games
  ///
  /// Returns list of newly imported games.
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

    // Phase 1: Count files to determine batch config (streaming, memory efficient)
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

    // Select batch config based on count and device memory
    final config = BatchImportConfig.forContext(
      fileCount: totalCount,
      deviceMemoryMB: deviceMemoryMB,
    );

    debugPrint(
      'BatchImportService: importing $totalCount ROMs '
      'with batch size ${config.batchSize}, '
      'isolate=${config.useIsolate}',
    );

    // Phase 2: Stream and process in batches
    final importedGames = <GameRom>[];
    final newHashes = <String, String>{};
    var processedFiles = 0;
    var skippedDuplicates = 0;
    var currentBatch = <File>[];

    // Report initial progress
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

        // Skip trashed files
        final basename = p.basename(entity.path);
        if (basename.startsWith('.trashed-')) continue;

        final lpath = entity.path.toLowerCase();
        final ext = lpath.endsWith('.p8.png')
            ? '.p8.png'
            : p.extension(entity.path).toLowerCase();

        // Single pass: copy saves alongside ROM import
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

        // Quick path duplicate check (O(1))
        if (existingPaths.contains(entity.path)) {
          processedFiles++;
          skippedDuplicates++;
          continue;
        }

        currentBatch.add(entity);

        // Process batch when full
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

          // Update existing paths with newly imported
          for (final game in batchResult.games) {
            existingPaths.add(game.path);
          }

          // Notify caller with newly imported games from this batch
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

          // Yield to UI thread
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

      // Process remaining files
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

        // Notify caller with newly imported games from this batch
        if (batchResult.games.isNotEmpty) {
          onBatchImported?.call(batchResult.games);
        }
      }

      // Phase 3: Batch DB write (more efficient than individual inserts)
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

  /// Process a batch of files, computing hashes and checking for duplicates.
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

      // Compute hash in isolate for large batches
      String? hash;
      try {
        if (config.useIsolate) {
          hash = await compute(
            RetroAchievementsService.computeRAHash,
            file.path,
          );
        } else {
          // For small batches, still await but on main thread
          hash = await RetroAchievementsService.computeRAHash(file.path);
        }
      } catch (e) {
        // Hash computation failed — still add the game
        debugPrint(
          'BatchImportService: RA hash computation failed for "${file.path}" — $e',
        );
      }

      // Check for content duplicate via hash
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

  /// Scan directory and return ROM file count by platform.
  /// Useful for showing platform breakdown in import preview.
  Future<Map<GamePlatform, int>> countByPlatform(String directoryPath) async {
    final counts = <GamePlatform, int>{};
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return counts;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      final basename = p.basename(entity.path);
      if (basename.startsWith('.trashed-')) continue;

      final lpath = entity.path.toLowerCase();
      final ext = lpath.endsWith('.p8.png')
          ? '.p8.png'
          : p.extension(entity.path).toLowerCase();
      if (!_romExtensions.contains(ext)) continue;

      final game = GameRom.fromPath(entity.path);
      if (game != null) {
        counts[game.platform] = (counts[game.platform] ?? 0) + 1;
      }
    }

    return counts;
  }
}

/// Internal result of processing a batch of files.
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
