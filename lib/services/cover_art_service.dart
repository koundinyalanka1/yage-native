import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/mgba_bindings.dart';
import '../models/game_rom.dart';
import '../utils/device_memory.dart';

class CoverArtService extends ChangeNotifier {
  final Set<String> _fetchingPaths = {};
  int _batchTotal = 0;
  int _batchDone = 0;

  bool get isBatchFetching => _batchTotal > 0;
  int get batchTotal => _batchTotal;
  int get batchDone => _batchDone;
  bool isFetching(String romPath) => _fetchingPaths.contains(romPath);

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
    GamePlatform.ngp: 'SNK - Neo Geo Pocket Color',
    GamePlatform.ws: 'Bandai - WonderSwan',
    GamePlatform.wsc: 'Bandai - WonderSwan Color',
    GamePlatform.n64: 'Nintendo - Nintendo 64',
    GamePlatform.pce: 'NEC - PC Engine - TurboGrafx 16',
    GamePlatform.sgx: 'NEC - PC Engine SuperGrafx',
  };

  final Map<String, List<String>> _indexCache = {};

  final Map<String, List<String>> _indexNormCache = {};

  final List<String> _indexLruOrder = [];

  int get _maxCachedPlatforms {
    final mb = deviceMemoryMB;
    if (mb == null || mb < 2048) return 2; 
    if (mb < 4096) return 3; 
    return 5; 
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

  Future<String?> fetchCoverArt(GameRom rom) async {
    if (_fetchingPaths.contains(rom.path)) return null;

    final system = _libretroSystem[rom.platform];
    if (system == null) return null;

    _fetchingPaths.add(rom.path);
    notifyListeners();

    try {
      final cacheKey = _sanitizeFilename(rom.name);
      final cached = await _getCachedCover(cacheKey);
      if (cached != null) {
        debugPrint('CoverArt: cache hit for "${rom.name}"');
        return cached;
      }
      final index = await _getIndex(system);
      if (index.isEmpty) {
        debugPrint('CoverArt: empty index for $system');
        return null;
      }
      final cleanTitle = _extractTitle(rom.name);
      debugPrint('CoverArt: "${rom.name}" → clean: "$cleanTitle"');

      final matchedName = _findBestMatch(cleanTitle, system);
      if (matchedName == null) {
        debugPrint('CoverArt: ✗ no match for "$cleanTitle"');
        return null;
      }
      debugPrint('CoverArt: ✓ matched → "$matchedName"');
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

  int get maxConcurrentDownloads {
    final mb = deviceMemoryMB;
    if (mb == null || mb < 2048) return 1; 
    if (mb < 4096) return 2; 
    return 3; 
  }

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

  Future<List<String>> _getIndex(String system) async {
    _evictIndexIfNeeded(system);
    if (_indexCache.containsKey(system)) {
      _indexLruOrder.remove(system);
      _indexLruOrder.add(system);
      return _indexCache[system]!;
    }
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
    debugPrint('CoverArt: fetching index for "$system" from LibRetro…');
    final names = await _fetchIndexFromNetwork(system);
    if (names.isNotEmpty) {
      _evictIndexIfNeeded(system);
      _indexCache[system] = names;
      _indexNormCache[system] = names.map(_normalize).toList();
      _indexLruOrder.add(system);
      _writeIndexToDisk(system, names); 
      debugPrint('CoverArt: indexed ${names.length} games for "$system"');
    }
    return names;
  }

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
      final pattern = RegExp(r'href="([^"]+\.png)"', caseSensitive: false);
      final names = <String>[];
      for (final match in pattern.allMatches(resp.body)) {
        final encoded = match.group(1)!;
        final decoded = Uri.decodeComponent(encoded);
        final name = decoded.substring(0, decoded.length - 4);
        names.add(name);
      }
      return names;
    } catch (e) {
      debugPrint('CoverArt: index fetch failed: $e');
      return [];
    }
  }

  Future<List<String>?> _readIndexFromDisk(String system) async {
    try {
      final dir = await _getCoverCacheDir();
      final file = File(
        p.join(dir, '_index_${_sanitizeFilename(system)}.json'),
      );
      if (!await file.exists()) return null;
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

  String? _findBestMatch(String romTitle, String system) {
    final names = _indexCache[system];
    final norms = _indexNormCache[system];
    if (names == null || norms == null) return null;

    final queryNorm = _normalize(romTitle);
    if (queryNorm.length < 4) return null; 

    String? bestMatch;
    double bestScore = 0;

    for (int i = 0; i < names.length; i++) {
      final candNorm = norms[i];
      if (candNorm.isEmpty) continue;
      if (candNorm.contains(queryNorm)) {
        final score = queryNorm.length / candNorm.length;
        if (score > bestScore) {
          bestScore = score;
          bestMatch = names[i];
        }
      }
    }
    if (bestScore >= 0.35) return bestMatch;
    bestScore = 0;
    bestMatch = null;
    for (int i = 0; i < names.length; i++) {
      final candNorm = norms[i];
      if (candNorm.length < 6) continue; 

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

  static String _normalize(String s) {
    return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static String _extractTitle(String name) {
    var title = name;
    title = title
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
        .replaceAll(RegExp(r'\s*\[[^\]]*\]'), '')
        .trim();
    title = title.replaceFirst(RegExp(r'^\d{3,5}\s*[-–]\s*'), '');
    title = title.replaceAll(RegExp(r'\bGBA\b', caseSensitive: false), '');
    title = title.replaceAll(RegExp(r'\bGBC\b', caseSensitive: false), '');
    title = title.replaceAll(RegExp(r'(?<![A-Za-z])GB(?![A-Za-z])'), '');
    title = title.replaceAll('#', '');
    title = title.replaceFirst(RegExp(r'\s+[vV]\d+(\.\d+)*\s*$'), '');
    title = title.replaceFirst(RegExp(r'\s+\d{4,}\s*$'), '');
    title = title
        .replaceAll(RegExp(r'^[\s\-_.]+'), '')
        .replaceAll(RegExp(r'[\s\-_.]+$'), '');
    title = title
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    return title;
  }

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
