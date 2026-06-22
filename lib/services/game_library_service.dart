import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/game_rom.dart';
import '../core/mgba_bindings.dart';
import '../utils/device_memory.dart';
import '../utils/seven_zip_extractor.dart';
import '../utils/zip_extractor.dart';
import 'batch_import_service.dart';
import 'game_database.dart';
import 'retro_achievements_service.dart';
import 'rom_folder_service.dart';

/// Service for managing the game library.
///
/// Backed by SQLite (via [GameDatabase]) so that each mutation is a cheap
/// row-level write rather than a full JSON-blob rewrite.
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

  /// Cached path to the internal ROM storage directory.
  String? _internalRomsDir;

  List<GameRom> get games => _games.toList();
  List<String> get romDirectories => _romDirectories;
  bool get isLoading => _isLoading;
  String? get error => _error;
  int get revision => _revision;

  final Completer<void> _initCompleter = Completer<void>();

  /// Future that completes when [initialize] has finished.
  Future<void> get whenReady => _initCompleter.future;

  /// Get games filtered by platform
  List<GameRom> getGamesByPlatform(GamePlatform? platform) {
    if (platform == null) return _games.toList();
    return _games.where((g) => g.platform == platform).toList();
  }

  /// Get favorite games
  List<GameRom> get favorites => _games.where((g) => g.isFavorite).toList();

  /// Get recently played games
  List<GameRom> get recentlyPlayed {
    final played = _games.where((g) => g.lastPlayed != null).toList();
    played.sort((a, b) => b.lastPlayed!.compareTo(a.lastPlayed!));
    return played.take(10).toList();
  }

  // ──────────── Internal ROM storage ────────────

  /// Returns the path to the app-internal ROMs directory, creating it if needed.
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

  // ──────────── Initialize ────────────

  /// Load the game library from SQLite.
  ///
  /// Optimization: On startup, we load all games immediately without checking
  /// if files exist. File existence checks are deferred to a background task
  /// to avoid ANR on large libraries or slow storage.
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      // Fast path: load all games from database without file checks
      _games = await _database.getAllGames();
      _romDirectories = await _database.getRomDirectories();

      _isLoading = false;
      _error = null;
      notifyListeners();

      // Complete early so UI can render immediately
      if (!_initCompleter.isCompleted) _initCompleter.complete();

      // Deferred: check for stale entries in background (non-blocking)
      _cleanupStaleEntriesInBackground();
    } catch (e) {
      _error = 'Failed to load library: $e';
      _isLoading = false;
      notifyListeners();
      if (!_initCompleter.isCompleted) _initCompleter.complete();
    }
  }

  /// Check for stale ROM entries (files that no longer exist) in background.
  /// This runs after the UI is ready to avoid blocking startup.
  void _cleanupStaleEntriesInBackground() {
    // Run in a microtask to not block the current frame
    Future.microtask(() async {
      final stalePaths = <String>[];

      for (final game in List<GameRom>.from(_games)) {
        try {
          if (!await File(game.path).exists()) {
            stalePaths.add(game.path);
          }
        } catch (e) {
          // Permission denied, I/O error — treat as stale
          debugPrint(
            'GameLibraryService: stale check failed for "${game.path}" — $e',
          );
          stalePaths.add(game.path);
        }

        // Yield to allow UI to remain responsive
        await Future.delayed(Duration.zero);
      }

      if (stalePaths.isNotEmpty) {
        // Remove stale entries
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

  // ──────────── ROM import (SAF-friendly) ────────────

  /// Import a ROM by copying it to internal storage first, then adding to library.
  ///
  /// Use this when the source file might be in a cache or SAF-provided location
  /// that could be cleaned up. The ROM is copied to the app's permanent internal
  /// roms directory. Skips duplicates (same content hash).
  /// Set [notify] to false to skip notifyListeners() (for batch operations).
  Future<GameRom?> importRom(String sourcePath, {bool notify = true}) async {
    final romsDir = await getInternalRomsDir();
    final fileName = p.basename(sourcePath);
    final destPath = p.join(romsDir, fileName);

    // If already in internal storage, just add directly
    if (sourcePath.startsWith(romsDir)) {
      return addRom(sourcePath, notify: notify);
    }

    // Copy to internal storage
    try {
      await File(sourcePath).copy(destPath);
    } catch (e) {
      debugPrint('Error copying ROM to internal storage: $e');
      return null;
    }

    final game = await addRom(destPath, notify: notify);
    if (game == null) {
      // Duplicate - remove the copied file to avoid wasting space
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

  static String _normalizedPathKey(String path) {
    return p.normalize(File(path).absolute.path).toLowerCase();
  }

  static String _cueReferenceToPath(String cuePath, String reference) {
    final normalizedReference = reference.replaceAll(r'\', p.separator);
    return p.join(p.dirname(cuePath), normalizedReference);
  }

  static String _stripIsoVersionSuffix(String value) {
    return value.replaceFirst(RegExp(r';\d+$'), '');
  }

  static String _archiveEntryLeafName(String entryName) {
    final cleaned = entryName.replaceAll('\u0000', '').trim();
    final parts = cleaned.split(RegExp(r'[\\/]'));
    for (var i = parts.length - 1; i >= 0; i--) {
      final part = parts[i].trim();
      if (part.isNotEmpty) return _stripIsoVersionSuffix(part);
    }
    return _stripIsoVersionSuffix(cleaned);
  }

  static String _archiveEntryExtension(String entryName) {
    final leafName = _archiveEntryLeafName(entryName).toLowerCase();
    final withoutIsoVersion = _stripIsoVersionSuffix(leafName);
    if (withoutIsoVersion.endsWith('.p8.png')) return '.p8.png';

    final match = RegExp(r'\.([a-z0-9]+)$').firstMatch(withoutIsoVersion);
    if (match == null) return '';
    return '.${match.group(1)}';
  }

  static String _archiveFolderNameForZip(String zipPath) {
    final baseName = p.basenameWithoutExtension(zipPath).trim();
    final cleaned = baseName
        .replaceAll('\u0000', '')
        .replaceAll(RegExp(r'[\\/]'), '_')
        .trim();
    return cleaned.isEmpty ? 'imported_game' : cleaned;
  }

  static String? _archiveEntryDestinationPath(
    String extractRoot,
    String entryName,
  ) {
    final cleaned = entryName.replaceAll('\u0000', '').trim();
    final segments = <String>[];
    for (final rawSegment in cleaned.split(RegExp(r'[\\/]'))) {
      final segment = _stripIsoVersionSuffix(rawSegment.trim());
      if (segment.isEmpty || segment == '.' || segment == '..') continue;
      segments.add(segment);
    }
    if (segments.isEmpty) return null;
    return p.joinAll([extractRoot, ...segments]);
  }

  static Future<Set<String>> _romCandidatePathsInDirectory(
    Directory directory,
    Set<String> romExtensions,
  ) async {
    final paths = <String>{};
    if (!await directory.exists()) return paths;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final ext = _archiveEntryExtension(entity.path);
      if (romExtensions.contains(ext)) paths.add(entity.path);
    }
    return paths;
  }

  static Set<String> _cueReferencedFiles(String cuePath) {
    return _cueReferencedPathCandidates(
      cuePath,
    ).map(_normalizedPathKey).toSet();
  }

  static Set<String> _cueReferencedPathCandidates(String cuePath) {
    try {
      final cue = File(cuePath);
      if (!cue.existsSync()) return const {};

      final text = cue.readAsStringSync();
      final refs = <String>{};

      for (final match in RegExp(
        r'^\s*FILE\s+"([^"]+)"',
        caseSensitive: false,
        multiLine: true,
      ).allMatches(text)) {
        final reference = match.group(1)?.trim();
        if (reference == null || reference.isEmpty) continue;
        final normalizedReference = reference.replaceAll(r'\', p.separator);
        final referencedPath = _cueReferenceToPath(cuePath, reference);
        refs.add(referencedPath);
        refs.add(_stripIsoVersionSuffix(referencedPath));
        final flattenedPath = p.join(
          p.dirname(cuePath),
          p.basename(normalizedReference),
        );
        refs.add(flattenedPath);
        refs.add(_stripIsoVersionSuffix(flattenedPath));
      }

      for (final match in RegExp(
        r'^\s*FILE\s+(.+?)\s+(?:BINARY|MOTOROLA|AIFF|WAVE|MP3)',
        caseSensitive: false,
        multiLine: true,
      ).allMatches(text)) {
        final reference = match.group(1)?.trim();
        if (reference == null ||
            reference.isEmpty ||
            reference.startsWith('"')) {
          continue;
        }
        final normalizedReference = reference.replaceAll(r'\', p.separator);
        final referencedPath = _cueReferenceToPath(cuePath, reference);
        refs.add(referencedPath);
        refs.add(_stripIsoVersionSuffix(referencedPath));
        final flattenedPath = p.join(
          p.dirname(cuePath),
          p.basename(normalizedReference),
        );
        refs.add(flattenedPath);
        refs.add(_stripIsoVersionSuffix(flattenedPath));
      }

      return refs;
    } catch (e) {
      debugPrint('GameLibraryService: failed to read cue "$cuePath" — $e');
      return const {};
    }
  }

  static bool _cueHasExistingReferencedBinTrack(String cuePath) {
    return _cueReferencedPathCandidates(cuePath).any((path) {
      if (_archiveEntryExtension(path) != '.bin') return false;
      if (File(path).existsSync()) return true;

      final dir = Directory(p.dirname(path));
      if (!dir.existsSync()) return false;
      final targetName = p.basename(path).toLowerCase();
      try {
        return dir.listSync().whereType<File>().any((file) {
          return p.basename(file.path).toLowerCase() == targetName;
        });
      } catch (_) {
        return false;
      }
    });
  }

  static Set<String> _validPs1CuePathKeysForZip(Iterable<String> paths) {
    final cuePathKeys = paths
        .where((path) => _archiveEntryExtension(path) == '.cue')
        .map(_normalizedPathKey)
        .toSet();
    final binPathKeys = paths
        .where((path) => _archiveEntryExtension(path) == '.bin')
        .map(_normalizedPathKey)
        .toSet();
    if (cuePathKeys.isEmpty || binPathKeys.isEmpty) return const {};

    // A ZIP is the PS1 candidate. Once it contains both cue and bin files,
    // accept its cue(s) as PS1. The reference parser is still used below to
    // identify specific companion tracks, but real-world cue sheets can vary
    // enough that a parser miss should not make a valid ZIP disappear.
    return cuePathKeys;
  }

  static Set<String> _binPathKeysForPaths(Iterable<String> paths) {
    return paths
        .where((path) => _archiveEntryExtension(path) == '.bin')
        .map(_normalizedPathKey)
        .toSet();
  }

  static Set<String> _cueReferencedFilesForPaths(Iterable<String> paths) {
    final refs = <String>{};
    for (final path in paths) {
      if (_archiveEntryExtension(path) != '.cue') continue;
      refs.addAll(_cueReferencedFiles(path));
    }
    return refs;
  }

  /// Import ROMs from a ZIP archive.
  ///
  /// Uses [ZipExtractor] (dart:io RandomAccessFile) for reliable extraction of
  /// large files. The `archive` package's InputFileStream decoder silently
  /// returns 0 entries for PS1-sized ZIPs (400MB+), so we bypass it entirely.
  ///
  /// Extracts archive contents to an internal folder named after the ZIP, then
  /// scans that folder for ROM files to import.
  /// PS1 `.cue` + `.bin` sets inside ZIPs are imported through the `.cue` file
  /// while keeping the `.bin` tracks beside it.
  /// Returns the list of successfully imported [GameRom]s.
  ///
  /// If the ZIP file itself is inside the internal roms directory (e.g. copied
  /// there by a VIEW intent), it is deleted after extraction to save space.
  ///
  /// [onStatus] receives short human-readable status strings (e.g. the
  /// archive being extracted, then each ROM being imported) so a progress
  /// dialog can show the current ROM name during the import.
  Future<List<GameRom>> importRomZip(
    String zipPath, {
    void Function(String status)? onStatus,
  }) async {
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
    final romsDir = await getInternalRomsDir();
    final extractDir = Directory(
      p.join(romsDir, _archiveFolderNameForZip(zipPath)),
    );
    final addedGames = <GameRom>[];
    final newlyWrittenPaths = <String>{};

    try {
      final zipFile = File(zipPath);
      final zipSize = await zipFile.length();
      debugPrint(
        'GameLibraryService: importing archive "${p.basename(zipPath)}" '
        '($zipSize bytes, deviceMemoryMB=$deviceMemoryMB) into ${extractDir.path}',
      );
      if (!await extractDir.exists()) {
        await extractDir.create(recursive: true);
      }

      onStatus?.call('Extracting ${p.basename(zipPath)}…');

      // Detect archive format and extract accordingly.
      // Many PS1 ROM archives distributed as ".zip" are actually 7z files.
      final is7z = await SevenZipExtractor.is7zFile(zipPath);

      if (is7z) {
        // ── 7z extraction path ──
        debugPrint('GameLibraryService: detected 7z format for "${p.basename(zipPath)}"');
        final extracted = await SevenZipExtractor.extractAll(
          archivePath: zipPath,
          extractRoot: extractDir.path,
          extensionFilter: romExtensions,
        );
        newlyWrittenPaths.addAll(extracted);
        if (extracted.isEmpty && zipSize > 0) {
          throw ArchiveException(
            'Archive "${p.basename(zipPath)}" (7z) extracted 0 files — '
            'file may be corrupt or use an unsupported compression method',
          );
        }
      } else {
        // ── ZIP extraction path ──
        final entries = await ZipExtractor.listEntries(zipPath);

        if (entries.isEmpty && zipSize > 0) {
          throw ArchiveException(
            'Archive "${p.basename(zipPath)}" has 0 entries — '
            'file may be corrupt or use an unsupported format',
          );
        }

        // Filter to ROM-relevant entries only
        final romEntries = entries.where((e) {
          if (e.isDirectory) return false;
          final ext = e.extension;
          if (ext == '.p8.png') return true;
          return romExtensions.contains(ext);
        }).toList();

        final sampleEntries = entries
            .take(12)
            .map((e) =>
                '${e.isDirectory ? 'dir' : 'file'}:${e.name}=>${e.extension}')
            .toList();

        // Extract all ROM entries to disk on a background isolate (keeps the
        // UI responsive and runs decompression at full speed — important for
        // large PS1 cue/bin archives).
        final extracted = await ZipExtractor.extractEntriesIsolate(
          zipPath: zipPath,
          extractRoot: extractDir.path,
          entries: romEntries,
          nameMapper: (entryName) =>
              _archiveEntryDestinationPath(extractDir.path, entryName)
                  ?.substring(extractDir.path.length + 1) ??
              '',
        );
        newlyWrittenPaths.addAll(extracted);

        if (extracted.isEmpty && sampleEntries.isNotEmpty) {
          debugPrint(
            'GameLibraryService: ZIP sample entries: ${sampleEntries.join(' | ')}',
          );
        }
      }

      // Also extract .bin entries that are referenced by .cue files but may
      // not be in romEntries (they ARE in romExtensions via '.bin', but ensure
      // all entries needed by cue sheets are present).
      // .bin is already in romExtensions, so all .bin files are extracted above.

      final candidatePaths = await _romCandidatePathsInDirectory(
        extractDir,
        romExtensions,
      );

      final cueReferencedTracks = _cueReferencedFilesForPaths(candidatePaths);
      final validPs1CuePathKeys = _validPs1CuePathKeysForZip(candidatePaths);
      final ps1CompanionBinPathKeys = validPs1CuePathKeys.isNotEmpty
          ? _binPathKeysForPaths(candidatePaths)
          : const <String>{};
      debugPrint(
        'GameLibraryService: archive import "${p.basename(zipPath)}" — '
        '${candidatePaths.length} candidate ROM files; '
        'PS1 cues=${validPs1CuePathKeys.length}, '
        'PS1 bins=${ps1CompanionBinPathKeys.length}',
      );
      final importPaths = candidatePaths.toList()
        ..sort((a, b) {
          final aExt = p.extension(a).toLowerCase();
          final bExt = p.extension(b).toLowerCase();
          if (aExt == '.cue' && bExt != '.cue') return -1;
          if (aExt != '.cue' && bExt == '.cue') return 1;
          return a.compareTo(b);
        });

      // Decide what to import (cue first), skipping companion .bin tracks that
      // belong to a cue/bin set — those stay on disk but get no game entry.
      final toImport = <({String path, GamePlatform? override})>[];
      for (final destPath in importPaths) {
        final ext = p.extension(destPath).toLowerCase();
        final pathKey = _normalizedPathKey(destPath);
        if (ext == '.bin' &&
            (cueReferencedTracks.contains(pathKey) ||
                ps1CompanionBinPathKeys.contains(pathKey))) {
          continue;
        }
        toImport.add((
          path: destPath,
          override: ext == '.cue' && validPs1CuePathKeys.contains(pathKey)
              ? GamePlatform.ps1
              : null,
        ));
      }

      if (toImport.isNotEmpty) {
        // Hash every candidate in parallel, then prepare + batch-insert. This
        // replaces the old per-ROM path, which awaited one isolate spawn per
        // file and slept 16 ms between files.
        onStatus?.call('Importing ${p.basename(toImport.first.path)}');
        final hashes = await _hashPathsParallel(
          [for (final it in toImport) it.path],
        );

        final preparedGames = <GameRom>[];
        final preparedHashes = <String, String>{};
        final seenHashes = <String>{};
        final toCleanUp = <String>[];

        for (var i = 0; i < toImport.length; i++) {
          final item = toImport[i];
          final hash = hashes[i];
          onStatus?.call(
            'Importing ${p.basename(item.path)} (${i + 1}/${toImport.length})',
          );

          // Reject within-archive content duplicates (matches the old
          // sequential behaviour where the first insert blocked later ones).
          final isDuplicate = hash != null && !seenHashes.add(hash);
          final game = isDuplicate
              ? null
              : await _prepareExtractedRom(
                  item.path,
                  hash,
                  platformOverride: item.override,
                );

          if (game != null) {
            preparedGames.add(game);
            if (hash != null) preparedHashes[game.path] = hash;
            continue;
          }

          // No game produced — schedule cleanup of the extracted file unless
          // it's a companion track we deliberately keep on disk.
          final pathKey = _normalizedPathKey(item.path);
          if (newlyWrittenPaths.contains(item.path) &&
              !cueReferencedTracks.contains(pathKey)) {
            toCleanUp.add(item.path);
          }
        }

        if (preparedGames.isNotEmpty) {
          _games.addAll(preparedGames);
          final ok = await _database.upsertGames(
            preparedGames,
            romHashes: preparedHashes,
          );
          if (ok) {
            addedGames.addAll(preparedGames);
            notifyListeners();
          } else {
            // Batch write failed — roll back the in-memory additions.
            final addedPaths = preparedGames.map((g) => g.path).toSet();
            _games.removeWhere((g) => addedPaths.contains(g.path));
          }
        }

        for (final path in toCleanUp) {
          try {
            await File(path).delete();
          } catch (e) {
            debugPrint(
              'GameLibraryService: failed to delete duplicate extracted ROM — $e',
            );
          }
        }
      }
    } on ArchiveException {
      rethrow;
    } catch (e) {
      debugPrint('Error reading ZIP file: $e');
    }

    // Clean up: if the ZIP is inside the roms directory (e.g. copied there
    // by a VIEW intent), delete it after extraction to save space.
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

  // ──────────── ROM management ────────────

  /// Add a single ROM file - returns the added game or null.
  /// Skips duplicates (same content hash) to avoid duplicate entries in the library.
  /// Set [notify] to false to skip notifyListeners() (for batch operations).
  Future<GameRom?> addRom(
    String path, {
    bool notify = true,
    GamePlatform? platformOverride,
  }) async {
    var game = GameRom.fromPath(path);
    if (platformOverride != null) {
      if (game == null) {
        final file = File(path);
        if (!file.existsSync()) return null;
        final stat = file.statSync();
        game = GameRom(
          path: path,
          name: p.basenameWithoutExtension(path),
          extension: p.extension(path).toLowerCase(),
          platform: platformOverride,
          sizeBytes: stat.size,
        );
      } else {
        game = game.copyWith(platform: platformOverride);
      }
    }
    if (game == null) return null;

    // Check if already exists by path
    if (_games.any((g) => g.path == path)) return null;

    // Yield to the UI thread before heavy IO / Isolate compute
    await Future.delayed(const Duration(milliseconds: 16));

    // Compute content hash and check for duplicate (same ROM, different path).
    // Hashing is best-effort; an RA hash failure should not block importing a
    // valid local game, especially cue/bin PS1 ZIPs.
    String? hash;
    try {
      hash = await compute(RetroAchievementsService.computeRAHash, path);
    } catch (e) {
      debugPrint('GameLibraryService: ROM hash failed for "$path" — $e');
    }
    if (platformOverride == null &&
        GameRom.isPceFamilyExtension(game.extension)) {
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

  /// Compute RA content hashes for [paths] across a few background isolates.
  ///
  /// Each isolate hashes a *group* of paths in a single [compute] call, so the
  /// cost is one isolate spawn per core (bounded) instead of one per file — a
  /// big win when an archive yields many loose ROMs. Paths are dealt out
  /// round-robin so large and small files spread evenly across cores.
  ///
  /// The result is index-aligned with [paths]; a null entry means hashing
  /// failed for that file (non-fatal — the ROM is still imported).
  Future<List<String?>> _hashPathsParallel(List<String> paths) async {
    final results = List<String?>.filled(paths.length, null);
    if (paths.isEmpty) return results;

    final lowMem = deviceMemoryMB != null && deviceMemoryMB! < 2048;
    final cores = Platform.numberOfProcessors;
    var groups = lowMem ? 1 : (cores < 4 ? cores : 4);
    if (groups > paths.length) groups = paths.length;
    if (groups < 1) groups = 1;

    // Round-robin partition: group g gets indices g, g+groups, g+2*groups, …
    final idxGroups = <List<int>>[];
    final futures = <Future<List<String?>>>[];
    for (var g = 0; g < groups; g++) {
      final idxs = <int>[];
      for (var i = g; i < paths.length; i += groups) {
        idxs.add(i);
      }
      if (idxs.isEmpty) continue;
      idxGroups.add(idxs);
      futures.add(compute(_computeRAHashesBatch, [for (final i in idxs) paths[i]]));
    }

    final grouped = await Future.wait(futures);
    for (var g = 0; g < grouped.length; g++) {
      final idxs = idxGroups[g];
      final hashes = grouped[g];
      for (var k = 0; k < idxs.length; k++) {
        results[idxs[k]] = k < hashes.length ? hashes[k] : null;
      }
    }
    return results;
  }

  /// Build a [GameRom] for an already-extracted [path] using a
  /// [precomputedHash] (may be null). Returns null when the path isn't a
  /// recognised ROM, is already in the library by path, or is a content
  /// duplicate of an existing game.
  ///
  /// Unlike [addRom] this performs no DB write, no `_games` mutation, and no
  /// artificial yield — the archive importer batches those once for the whole
  /// archive. The logic otherwise mirrors [addRom] so dedup/classification stay
  /// identical.
  Future<GameRom?> _prepareExtractedRom(
    String path,
    String? precomputedHash, {
    GamePlatform? platformOverride,
  }) async {
    var game = GameRom.fromPath(path);
    if (platformOverride != null) {
      if (game == null) {
        final file = File(path);
        if (!file.existsSync()) return null;
        final stat = file.statSync();
        game = GameRom(
          path: path,
          name: p.basenameWithoutExtension(path),
          extension: p.extension(path).toLowerCase(),
          platform: platformOverride,
          sizeBytes: stat.size,
        );
      } else {
        game = game.copyWith(platform: platformOverride);
      }
    }
    if (game == null) return null;

    // Already present by path?
    if (_games.any((g) => g.path == path)) return null;

    if (platformOverride == null &&
        GameRom.isPceFamilyExtension(game.extension)) {
      game = GameRom.classifyWithRomHash(game, romHash: precomputedHash);
    }

    // Content duplicate (same hash, different path)?
    if (precomputedHash != null) {
      final existingPath = await _database.getPathByRomHash(precomputedHash);
      if (existingPath != null && existingPath != path) return null;
    }
    return game;
  }

  /// Import ROMs and saves from a directory by copying to internal storage.
  /// Use this when setting up a user folder (e.g. on TV or reinstall).
  /// Returns the list of imported games.
  ///
  /// For large directories (100+ ROMs), uses batch processing to avoid
  /// memory issues and UI freezing.
  ///
  /// [onProgress] is called with progress updates (both fast and batch paths).
  /// [isCancelled] when non-null, is checked periodically; if it returns true,
  /// import stops early and returns games imported so far.
  /// Find every `.zip` archive under [dir] and import it via [importRomZip]
  /// (extract + add the contained ROMs). Games are appended to [out] and the
  /// UI is notified as each archive completes. Progress is reported through
  /// [onProgress] with the archive / ROM name so the import dialog can show it.
  Future<void> _importZipArchivesInDirectory(
    Directory dir,
    List<GameRom> out, {
    ImportProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final zipPaths = <String>[];
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (isCancelled?.call() == true) break;
        if (entity is! File) continue;
        if (p.extension(entity.path).toLowerCase() == '.zip') {
          zipPaths.add(entity.path);
        }
      }
    } catch (e) {
      debugPrint('GameLibraryService: zip discovery failed in "${dir.path}" — $e');
    }
    if (zipPaths.isEmpty) return;

    var processed = 0;
    for (final zipPath in zipPaths) {
      if (isCancelled?.call() == true) break;
      try {
        final games = await importRomZip(
          zipPath,
          onStatus: (status) => onProgress?.call(
            BatchImportProgress(
              totalFiles: zipPaths.length,
              processedFiles: processed,
              importedGames: out.length,
              skippedDuplicates: 0,
              currentFile: status,
            ),
          ),
        );
        if (games.isNotEmpty) {
          out.addAll(games);
          notifyListeners();
        }
      } catch (e) {
        debugPrint('GameLibraryService: failed to import zip "$zipPath" — $e');
      }
      processed++;
    }
  }

  Future<List<GameRom>> importFromDirectory(
    String path, {
    String? appSaveDir,
    ImportProgressCallback? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(path);
    if (!await dir.exists()) return [];

    final addedGames = <GameRom>[];

    // ── ZIP archives → auto-import as potential games (incl. PS1 cue/bin) ──
    // ROM folders frequently contain .zip archives (PS1 discs are usually
    // distributed as a zipped cue/bin set). The normal rom-extension scan
    // below ignores .zip, so extract + import any archives first. This runs
    // regardless of the fast/batch path chosen for loose ROMs.
    await _importZipArchivesInDirectory(
      dir,
      addedGames,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );

    // First, count files to decide on processing strategy
    final fileCount = await _batchImportService.countRomFiles(path);

    // On low-RAM (<2 GB), use batch import for 20+ files to avoid memory spikes.
    // On normal devices, fast path for <50 files.
    final batchThreshold = (deviceMemoryMB != null && deviceMemoryMB! < 2048)
        ? 20
        : 50;

    if (fileCount < batchThreshold) {
      // Fast path for small collections with throttled notifications (every 3 ROMs)
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
        final lpath = entity.path.toLowerCase();
        final ext = lpath.endsWith('.p8.png')
            ? '.p8.png'
            : p.extension(entity.path).toLowerCase();
        final name = p.basename(entity.path);

        // Single pass: copy saves alongside ROM import
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
      // Final notification for any remaining ROMs
      if (importedSinceNotify > 0) {
        notifyListeners();
      }
    } else {
      // Batch import for large collections
      debugPrint('GameLibraryService: Using batch import for $fileCount ROMs');

      final existingPaths = _games.map((g) => g.path).toSet();
      await _batchImportService.importFromDirectory(
        directoryPath: path,
        existingPaths: existingPaths,
        appSaveDir: appSaveDir,
        onProgress: (progress) => onProgress?.call(progress),
        isCancelled: isCancelled,
        onBatchImported: (batchGames) {
          // Add games incrementally as each batch completes
          _games.addAll(batchGames);
          addedGames.addAll(batchGames);
          notifyListeners();
        },
      );
    }

    // Save copy done in single pass above (fast path) or inside batch import (batch path)

    if (addedGames.isNotEmpty) notifyListeners();
    return addedGames;
  }

  /// Add a ROM directory to scan (legacy — works only when filesystem is accessible)
  Future<void> addRomDirectory(String path) async {
    if (_romDirectories.contains(path)) return;

    if (!await _database.addRomDirectory(path)) return;
    _romDirectories.add(path);
    await scanDirectory(path);
  }

  /// Scan a directory for ROM files (requires filesystem read access).
  ///
  /// For large directories (100+ ROMs), uses batch processing with progress
  /// reporting to avoid memory issues and UI freezing.
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

      // Count files first to choose processing strategy
      final fileCount = await _batchImportService.countRomFiles(path);

      final batchThreshold = (deviceMemoryMB != null && deviceMemoryMB! < 2048)
          ? 20
          : 50;

      if (fileCount < batchThreshold) {
        // Fast path for small directories - use streaming instead of toList()
        final newGames = <GameRom>[];
        final hashes = <String, String>{};

        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;

          // Skip trashed files
          final basename = p.basename(entity.path);
          if (basename.startsWith('.trashed-')) continue;

          final lpath = entity.path.toLowerCase();
          final ext = lpath.endsWith('.p8.png')
              ? '.p8.png'
              : p.extension(entity.path).toLowerCase();
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
            '.nds',
            '.int',
            '.itv',
            '.rom',
          ].contains(ext)) {
            continue;
          }

          var game = GameRom.fromPath(entity.path);
          if (game == null || _games.any((g) => g.path == entity.path)) {
            continue;
          }

          // Compute hash in isolate for dedup + DB
          try {
            final hash = await compute(
              RetroAchievementsService.computeRAHash,
              entity.path,
            );
            if (hash != null) {
              final existingPath = await _database.getPathByRomHash(hash);
              if (existingPath != null) continue; // duplicate
              hashes[entity.path] = hash;
              if (GameRom.isPceFamilyExtension(ext)) {
                game = GameRom.classifyWithRomHash(game, romHash: hash);
              }
            }
          } catch (e) {
            // Hash computation failed — still add the game
            debugPrint(
              'GameLibraryService: RA hash computation failed for "${entity.path}" — $e',
            );
          }

          final resolvedGame = game!;
          _games.add(resolvedGame);
          newGames.add(resolvedGame);
        }

        // Notify UI immediately so games appear
        if (newGames.isNotEmpty) {
          notifyListeners();
          // Persist to DB (uses cached hashes — no re-computation)
          try {
            await _database.upsertGames(newGames, romHashes: hashes);
          } catch (e) {
            debugPrint('GameLibraryService: scanDirectory upsert failed — $e');
          }
        }
      } else {
        // Use batch import for large directories
        debugPrint('GameLibraryService: Using batch scan for $fileCount ROMs');

        final existingPaths = _games.map((g) => g.path).toSet();
        await _batchImportService.importFromDirectory(
          directoryPath: path,
          existingPaths: existingPaths,
          onProgress: (progress) {
            onProgress?.call(progress);
          },
          onBatchImported: (batchGames) {
            // Add games incrementally as each batch completes
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

  /// Remove a ROM from library
  Future<void> removeRom(GameRom game) async {
    _games.removeWhere((g) => g.path == game.path);
    try {
      await _database.deleteGame(game.path);
    } catch (e) {
      debugPrint('GameLibraryService: removeRom delete failed — $e');
    }
    notifyListeners();
  }

  /// Remove a ROM directory
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

  /// Toggle favorite status
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

  /// Update last played time
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

  /// Add play time (seconds) to a game's total
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

  /// Set cover art for a game
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

  /// Remove cover art from a game
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

  /// Refresh library by rescanning all directories.
  ///
  /// Rebuilds the game list in chunks, merging metadata incrementally.
  /// On failure, restores the previous library from memory.
  ///
  /// Always includes the internal ROMs directory (intent/SAF imports)
  /// so those games are never lost on refresh.
  ///
  /// Processes in chunks (250–500 games) and updates the UI incrementally
  /// to avoid holding 5000+ games in memory on low-RAM devices.
  Future<void> refresh({
    String? safFolderUri,
    ImportProgressCallback? onProgress,
  }) async {
    _isLoading = true;
    notifyListeners();

    // Sync new ROMs from the user's SAF folder into internal storage first,
    // so the directory scan below picks them up.
    if (safFolderUri != null) {
      try {
        await RomFolderService.importFromFolder(safFolderUri);
      } catch (e) {
        debugPrint('GameLibraryService: SAF sync on refresh failed — $e');
      }
    }

    // Preserve metadata (favorites, play history, cover art, etc.). Pull from
    // SQLite too so a previous refresh that hid a ZIP-imported PS1 cue can be
    // recovered without restarting the app.
    final gameData = <String, GameRom>{};
    try {
      for (final game in await _database.getAllGames()) {
        gameData[game.path] = game;
      }
    } catch (e) {
      debugPrint('GameLibraryService: refresh DB metadata load failed — $e');
    }
    for (final game in _games) {
      gameData[game.path] = game;
    }

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
    final chunkSize = (deviceMemoryMB != null && deviceMemoryMB! < 2048)
        ? 250
        : 500;

    // Collect all directories to scan: user-added + internal storage.
    final dirsToScan = List<String>.from(_romDirectories);
    try {
      final internalDir = await getInternalRomsDir();
      if (!dirsToScan.contains(internalDir)) {
        dirsToScan.add(internalDir);
      }
    } catch (e) {
      // Internal dir unavailable — continue with user dirs only
      debugPrint('GameLibraryService: internal ROM dir unavailable — $e');
    }

    try {
      var processedCount = 0;
      final seenPaths = <String>{};
      var chunk = <GameRom>[];

      // Clear and rebuild incrementally — UI updates as each chunk completes.
      // Avoids holding 5000+ games in memory on low-RAM.
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

            final lpath = entity.path.toLowerCase();
            final ext = lpath.endsWith('.p8.png')
                ? '.p8.png'
                : p.extension(entity.path).toLowerCase();
            if (!romExtensions.contains(ext)) continue;

            if (seenPaths.contains(entity.path)) continue;
            seenPaths.add(entity.path);

            var game = GameRom.fromPath(entity.path);
            // Legacy: `.bin` was once always MD; non-standard rips may lack the
            // 0x100 Sega header. Keep the row on refresh if DB already had MD.
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
            if (game == null && ext == '.cue') {
              final prev = gameData[entity.path];
              if (prev != null &&
                  prev.platform == GamePlatform.ps1 &&
                  _cueHasExistingReferencedBinTrack(entity.path)) {
                try {
                  final stat = await entity.stat();
                  game = prev.copyWith(sizeBytes: stat.size);
                } catch (e) {
                  debugPrint(
                    'GameLibraryService: failed to stat PS1 cue ROM — $e',
                  );
                }
              }
            }
            if (game != null &&
                game.platform != GamePlatform.ps1 &&
                GameRom.isPceFamilyExtension(ext)) {
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

      // Flush remaining chunk
      await mergeAndFlushChunk();

      // Remove stale DB entries that no longer exist on disk.
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
      // Restore previous library on failure (we may have cleared _games)
      _games = gameData.values.toList();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Search games by name
  List<GameRom> search(String query) {
    if (query.isEmpty) return _games;
    final lowerQuery = query.toLowerCase();
    return _games
        .where((g) => g.name.toLowerCase().contains(lowerQuery))
        .toList();
  }
}

/// Hash a batch of ROM [paths] inside a single background isolate.
///
/// Top-level so it can run via [compute]. [RetroAchievementsService.computeRAHash]
/// is pure Dart (file read + md5), so looping it here keeps the whole group on
/// one isolate — one spawn instead of one-per-file. Index-aligned with [paths];
/// failures yield null.
Future<List<String?>> _computeRAHashesBatch(List<String> paths) async {
  final out = List<String?>.filled(paths.length, null);
  for (var i = 0; i < paths.length; i++) {
    try {
      out[i] = await RetroAchievementsService.computeRAHash(paths[i]);
    } catch (_) {
      // best-effort; leave null
    }
  }
  return out;
}
