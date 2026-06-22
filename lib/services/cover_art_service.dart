import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../utils/device_memory.dart';

// ═══════════════════════════════════════════════════════════════════════
//  CoverArtService — fuzzy-matched cover art from LibRetro Thumbnails
// ═══════════════════════════════════════════════════════════════════════
//
//  Flow:
//    1. On first use, fetch the full game-name index from LibRetro's
//       public directory listing for the platform (one-time ~200 KB).
//    2. Clean the ROM filename → extract title → normalize to
//       lowercase alphanumeric only.
//    3. Find the best fuzzy match in the index via substring matching
//       on the normalized strings. This handles spelling variations
//       like "Dragonball" vs "Dragon Ball", stripped regions, etc.
//    4. Download the matched thumbnail and cache it locally.
//
//  No login, no API key, no external service.
// ═══════════════════════════════════════════════════════════════════════

class CoverArtService extends ChangeNotifier {
  final Set<String> _fetchingPaths = {};
  int _batchTotal = 0;
  int _batchDone = 0;

  bool get isBatchFetching => _batchTotal > 0;
  int get batchTotal => _batchTotal;
  int get batchDone => _batchDone;
  bool isFetching(String romPath) => _fetchingPaths.contains(romPath);

  // ── LibRetro system names ──────────────────────────────────────────

  static const _libretroSystem = <GamePlatform, String>{
    GamePlatform.gba: 'Nintendo - Game Boy Advance',
    GamePlatform.gbc: 'Nintendo - Game Boy Color',
    GamePlatform.gb: 'Nintendo - Game Boy',
    GamePlatform.nes: 'Nintendo - Nintendo Entertainment System',
    GamePlatform.snes: 'Nintendo - Super Nintendo Entertainment System',
    GamePlatform.sms: 'Sega - Master System - Mark III',
    GamePlatform.gg: 'Sega - Game Gear',
    GamePlatform.md: 'Sega - Mega Drive - Genesis',
    GamePlatform.sg1000: 'Sega - SG-1000',
    // ngp is handled per-extension in _getLibretroSystem (NGP vs NGPC)
    GamePlatform.ws: 'Bandai - WonderSwan',
    GamePlatform.wsc: 'Bandai - WonderSwan Color',
    GamePlatform.n64: 'Nintendo - Nintendo 64',
    GamePlatform.nds: 'Nintendo - Nintendo DS',
    GamePlatform.pce: 'NEC - PC Engine - TurboGrafx 16',
    GamePlatform.sgx: 'NEC - PC Engine SuperGrafx',
    GamePlatform.a2600: 'Atari - 2600',
    GamePlatform.vb: 'Nintendo - Virtual Boy',
    GamePlatform.tic80: 'TIC-80',
    GamePlatform.ps1: 'Sony - PlayStation',
    GamePlatform.intv: 'Mattel - Intellivision',
    // PICO-8 (Lexaloffle) — no official libretro-thumbnails system; carts are
    // typically provided with embedded label art. Cover lookup is skipped.
  };

  /// Resolve the LibRetro thumbnail system folder for [rom].
  ///
  /// Most platforms have a 1-to-1 mapping. The exception is NGP: both the
  /// monochrome Neo Geo Pocket (.ngp) and the color variant (.ngc) share the
  /// same [GamePlatform.ngp] enum value, so we inspect the file extension to
  /// pick the correct thumbnail folder.
  static String? _getLibretroSystem(GameRom rom) {
    if (rom.platform == GamePlatform.ngp) {
      // .ngc = Neo Geo Pocket Color; anything else (incl. .ngp) = monochrome
      return rom.extension == '.ngc'
          ? 'SNK - Neo Geo Pocket Color'
          : 'SNK - Neo Geo Pocket';
    }
    return _libretroSystem[rom.platform];
  }

  // ── In-memory game-name index (per system) ─────────────────────────
  // LRU eviction: on low-RAM devices, cap cached platforms to avoid OOM.
  // ~200 KB per platform; 5 platforms ≈ 1 MB. Cap at 2–3 on <2 GB RAM.

  /// system → list of thumbnail filenames (without .png)
  final Map<String, List<String>> _indexCache = {};

  /// system → normalized versions for fast matching
  final Map<String, List<String>> _indexNormCache = {};

  /// LRU order: most recently used last.
  final List<String> _indexLruOrder = [];

  int get _maxCachedPlatforms {
    final mb = deviceMemoryMB;
    if (mb == null || mb < 2048) return 2; // <2 GB: 2 platforms (~400 KB)
    if (mb < 4096) return 3; // 2–4 GB: 3 platforms
    return 5; // 4+ GB: all platforms
  }

  void _evictIndexIfNeeded(String system) {
    if (_indexCache.length < _maxCachedPlatforms) return;
    if (_indexCache.containsKey(system)) {
      _indexLruOrder.remove(system);
      _indexLruOrder.add(system);
      return;
    }
    while (_indexCache.length >= _maxCachedPlatforms &&
        _indexLruOrder.isNotEmpty) {
      final evict = _indexLruOrder.removeAt(0);
      _indexCache.remove(evict);
      _indexNormCache.remove(evict);
      debugPrint('CoverArt: evicted index for "$evict" (LRU)');
    }
  }

  // ── Cache directory ────────────────────────────────────────────────

  String? _cacheDir;

  Future<String> _getCoverCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    try {
      final appDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(appDir.path, 'cover_art'));
      if (!await dir.exists()) await dir.create(recursive: true);
      _cacheDir = dir.path;
      return _cacheDir!;
    } catch (e) {
      debugPrint('CoverArt: _getCoverCacheDir failed — $e');
      rethrow;
    }
  }

  // ═════════════════════════════════════════════════════════════════════
  //  Public API
  // ═════════════════════════════════════════════════════════════════════

  /// Fetch cover art for a single ROM.
  Future<String?> fetchCoverArt(GameRom rom) async {
    if (_fetchingPaths.contains(rom.path)) return null;

    final system = _getLibretroSystem(rom);
    if (system == null) return null;

    _fetchingPaths.add(rom.path);
    notifyListeners();

    try {
      // Check local cache first
      final cacheKey = _sanitizeFilename(rom.name);
      final cached = await _getCachedCover(cacheKey);
      if (cached != null) {
        debugPrint('CoverArt: cache hit for "${rom.name}"');
        return cached;
      }

      // Ensure we have the game-name index for this platform
      final index = await _getIndex(system);
      if (index.isEmpty) {
        debugPrint('CoverArt: empty index for $system');
        return null;
      }

      // Extract clean title and find best match
      final cleanTitle = _extractTitle(rom.name);
      debugPrint('CoverArt: "${rom.name}" → clean: "$cleanTitle"');

      final matchedName = _findBestMatch(cleanTitle, system);
      if (matchedName == null) {
        debugPrint('CoverArt: ✗ no match for "$cleanTitle"');
        return null;
      }
      debugPrint('CoverArt: ✓ matched → "$matchedName"');

      // Download the thumbnail
      final localPath = await _downloadThumbnail(system, matchedName, cacheKey);
      return localPath;
    } catch (e) {
      debugPrint('CoverArt: error: $e');
      return null;
    } finally {
      _fetchingPaths.remove(rom.path);
      notifyListeners();
    }
  }

  /// Max concurrent cover downloads. Reduced on low-RAM to avoid
  /// competing with import and UI. Public for callers that batch manually.
  int get maxConcurrentDownloads {
    final mb = deviceMemoryMB;
    if (mb == null || mb < 2048) return 1; // <2 GB: 1 at a time
    if (mb < 4096) return 2; // 2–4 GB: 2
    return 3; // 4+ GB: 3
  }

  /// [onCoverReady] is called as soon as each individual cover is
  /// downloaded, so the UI can show it immediately instead of waiting
  /// for the entire batch to finish.
  Future<Map<String, String>> fetchAllCoverArt(
    List<GameRom> games, {
    Future<void> Function(String romPath, String coverPath)? onCoverReady,
  }) async {
    final toFetch = games.where((g) => g.coverPath == null).toList();
    if (toFetch.isEmpty) return {};

    _batchTotal = toFetch.length;
    _batchDone = 0;
    notifyListeners();

    final results = <String, String>{};

    for (int i = 0; i < toFetch.length; i += maxConcurrentDownloads) {
      final chunk = toFetch.skip(i).take(maxConcurrentDownloads).toList();
      final futures = chunk.map((game) async {
        final path = await fetchCoverArt(game);
        if (path != null) {
          results[game.path] = path;
          await onCoverReady?.call(game.path, path);
        }
        _batchDone++;
        notifyListeners();
      });
      await Future.wait(futures);
    }

    _batchTotal = 0;
    _batchDone = 0;
    notifyListeners();
    return results;
  }

  // ═════════════════════════════════════════════════════════════════════
  //  Game-name index: fetch, parse, cache
  // ═════════════════════════════════════════════════════════════════════

  /// Get the game-name index for a platform (memory → disk → network).
  Future<List<String>> _getIndex(String system) async {
    _evictIndexIfNeeded(system);

    // 1. Memory cache
    if (_indexCache.containsKey(system)) {
      _indexLruOrder.remove(system);
      _indexLruOrder.add(system);
      return _indexCache[system]!;
    }

    // 2. Disk cache
    final diskNames = await _readIndexFromDisk(system);
    if (diskNames != null && diskNames.isNotEmpty) {
      _evictIndexIfNeeded(system);
      _indexCache[system] = diskNames;
      _indexNormCache[system] = diskNames.map(_normalize).toList();
      _indexLruOrder.add(system);
      debugPrint(
        'CoverArt: loaded ${diskNames.length} names from disk '
        'for "$system"',
      );
      return diskNames;
    }

    // 3. Network fetch
    debugPrint('CoverArt: fetching index for "$system" from LibRetro…');
    final names = await _fetchIndexFromNetwork(system);
    if (names.isNotEmpty) {
      _evictIndexIfNeeded(system);
      _indexCache[system] = names;
      _indexNormCache[system] = names.map(_normalize).toList();
      _indexLruOrder.add(system);
      _writeIndexToDisk(system, names); // fire-and-forget
      debugPrint('CoverArt: indexed ${names.length} games for "$system"');
    }
    return names;
  }

  /// Fetch the directory listing HTML and parse all .png filenames.
  Future<List<String>> _fetchIndexFromNetwork(String system) async {
    final url =
        'https://thumbnails.libretro.com/'
        '${Uri.encodeComponent(system)}/Named_Boxarts/';

    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        debugPrint('CoverArt: index fetch HTTP ${resp.statusCode}');
        return [];
      }

      // Parse href="*.png" from the Apache directory listing
      final pattern = RegExp(r'href="([^"]+\.png)"', caseSensitive: false);
      final names = <String>[];
      for (final match in pattern.allMatches(resp.body)) {
        final encoded = match.group(1)!;
        final decoded = Uri.decodeComponent(encoded);
        // Strip .png extension to get the game name
        final name = decoded.substring(0, decoded.length - 4);
        names.add(name);
      }
      return names;
    } catch (e) {
      debugPrint('CoverArt: index fetch failed: $e');
      return [];
    }
  }

  /// Read cached index from disk.
  Future<List<String>?> _readIndexFromDisk(String system) async {
    try {
      final dir = await _getCoverCacheDir();
      final file = File(
        p.join(dir, '_index_${_sanitizeFilename(system)}.json'),
      );
      if (!await file.exists()) return null;

      // Refresh if older than 7 days
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified).inDays > 7) return null;

      final json = await file.readAsString();
      final list = (jsonDecode(json) as List).cast<String>();
      return list;
    } catch (e) {
      debugPrint('CoverArt: disk index read error: $e');
      return null;
    }
  }

  /// Write index to disk for future use.
  Future<void> _writeIndexToDisk(String system, List<String> names) async {
    try {
      final dir = await _getCoverCacheDir();
      final file = File(
        p.join(dir, '_index_${_sanitizeFilename(system)}.json'),
      );
      await file.writeAsString(jsonEncode(names));
    } catch (e) {
      debugPrint('CoverArt: disk index write error: $e');
    }
  }

  // ═════════════════════════════════════════════════════════════════════
  //  Fuzzy matching
  // ═════════════════════════════════════════════════════════════════════

  /// Find the best matching game name from the cached index.
  ///
  /// Strategy: normalize both the query and every candidate to
  /// lowercase-alphanumeric-only, then check if the query is a
  /// substring of the candidate. Among all matches, prefer the one
  /// where the query covers the largest fraction of the candidate
  /// (i.e. the candidate is the shortest / closest match).
  String? _findBestMatch(String romTitle, String system) {
    final names = _indexCache[system];
    final norms = _indexNormCache[system];
    if (names == null || norms == null) return null;

    final queryNorm = _normalize(romTitle);
    if (queryNorm.length < 4) return null; // too short to match reliably

    String? bestMatch;
    double bestScore = 0;

    for (int i = 0; i < names.length; i++) {
      final candNorm = norms[i];
      if (candNorm.isEmpty) continue;

      // Check if normalized query is a substring of normalized candidate
      if (candNorm.contains(queryNorm)) {
        // Score: fraction of the candidate covered by the query.
        // Higher = closer match (shorter candidate = better).
        final score = queryNorm.length / candNorm.length;
        if (score > bestScore) {
          bestScore = score;
          bestMatch = names[i];
        }
      }
    }

    // Require at least 35% coverage to avoid false positives
    if (bestScore >= 0.35) return bestMatch;

    // Fallback: try the reverse — candidate is substring of query
    // (handles cases where ROM name has extra junk)
    bestScore = 0;
    bestMatch = null;
    for (int i = 0; i < names.length; i++) {
      final candNorm = norms[i];
      if (candNorm.length < 6) continue; // skip very short candidates

      if (queryNorm.contains(candNorm)) {
        final score = candNorm.length / queryNorm.length;
        if (score > bestScore) {
          bestScore = score;
          bestMatch = names[i];
        }
      }
    }

    return bestScore >= 0.5 ? bestMatch : null;
  }

  /// Normalize a string for matching: lowercase, alphanumeric only.
  ///
  /// "Dragon Ball Z - Buu's Fury (USA)" → "dragonballzbuusfuryusa"
  /// "Dragonball Z - Buu's Fury # GBA"  → "dragonballzbuusfurygba"
  ///
  /// After stripping platform tags (GBA/GBC/GB) from the ROM title
  /// in [_extractTitle], both normalize to the same prefix, enabling
  /// substring matching.
  static String _normalize(String s) {
    return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  // ═════════════════════════════════════════════════════════════════════
  //  Title extraction from ROM filename
  // ═════════════════════════════════════════════════════════════════════

  /// Extract a clean game title from a ROM filename.
  ///
  /// Examples:
  ///   "1636 - Pokemon Fire Red (U)(Squirrels)"
  ///     → "Pokemon Fire Red"
  ///   "Pokemon - Yellow Version - Special Pikachu Edition (USA, Europe) (GBC,SGB Enhanced)"
  ///     → "Pokemon Yellow Version Special Pikachu Edition"
  ///   "Dragonball Z - Buu's Fury # GBA"
  ///     → "Dragonball Z Buus Fury"
  static String _extractTitle(String name) {
    var title = name;

    // Remove all (...) and [...] groups
    title = title
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
        .replaceAll(RegExp(r'\s*\[[^\]]*\]'), '')
        .trim();

    // Strip leading release/catalog number: "1636 - Title" → "Title"
    title = title.replaceFirst(RegExp(r'^\d{3,5}\s*[-–]\s*'), '');

    // Strip platform tags
    title = title.replaceAll(RegExp(r'\bGBA\b', caseSensitive: false), '');
    title = title.replaceAll(RegExp(r'\bGBC\b', caseSensitive: false), '');
    title = title.replaceAll(RegExp(r'(?<![A-Za-z])GB(?![A-Za-z])'), '');

    // Strip # and other stray special characters
    title = title.replaceAll('#', '');

    // Strip trailing version/rev markers
    title = title.replaceFirst(RegExp(r'\s+[vV]\d+(\.\d+)*\s*$'), '');

    // Strip trailing standalone 4+ digit numbers (release codes)
    title = title.replaceFirst(RegExp(r'\s+\d{4,}\s*$'), '');

    // Clean up leftover punctuation at edges
    title = title
        .replaceAll(RegExp(r'^[\s\-_.]+'), '')
        .replaceAll(RegExp(r'[\s\-_.]+$'), '');

    // Replace underscores with spaces, collapse whitespace
    title = title
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    return title;
  }

  // ═════════════════════════════════════════════════════════════════════
  //  Download & cache
  // ═════════════════════════════════════════════════════════════════════

  /// Download a specific thumbnail by its exact LibRetro name.
  Future<String?> _downloadThumbnail(
    String system,
    String gameName,
    String cacheKey,
  ) async {
    final encodedSystem = Uri.encodeComponent(system);
    final encodedName = Uri.encodeComponent(gameName);
    final url =
        'https://thumbnails.libretro.com/'
        '$encodedSystem/Named_Boxarts/$encodedName.png';

    try {
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200 || resp.bodyBytes.length < 200) {
        debugPrint('CoverArt: download failed HTTP ${resp.statusCode}');
        return null;
      }

      final dir = await _getCoverCacheDir();
      final localPath = p.join(dir, '$cacheKey.png');
      try {
        await File(localPath).writeAsBytes(resp.bodyBytes);
      } catch (e) {
        debugPrint('CoverArt: file write failed (disk full?): $e');
        return null;
      }
      debugPrint('CoverArt: saved → $localPath');
      return localPath;
    } catch (e) {
      debugPrint('CoverArt: download error: $e');
      return null;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────

  Future<String?> _getCachedCover(String cacheKey) async {
    try {
      final dir = await _getCoverCacheDir();
      final file = File(p.join(dir, '$cacheKey.png'));
      if (await file.exists() && await file.length() > 200) return file.path;
    } catch (e) {
      debugPrint('CoverArt: _getCachedCover error: $e');
    }
    return null;
  }

  static String _sanitizeFilename(String s) {
    return s
        .replaceAll(RegExp(r'[&*/:<>?\\|"]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
  }
}
