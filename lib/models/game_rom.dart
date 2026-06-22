import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/mgba_bindings.dart';

const _sentinel = Object();

/// Represents a game ROM file
class GameRom {
  /// Official SuperGrafx-exclusive HuCard titles (only 5 exist).
  /// Source: https://en.wikipedia.org/wiki/PC_Engine_SuperGrafx#Software
  /// These are normalized: lowercase, non-alphanumeric removed, partial-substring match.
  /// Ghouls'n'Ghosts is Daimakaimura, included via title search.
  /// Darius Plus (PC-SG mark) included as it had SuperGrafx-enhanced support.
  static const Set<String> _superGrafxNameMarkers = {
    // Official exclusive titles
    '1941counterattack',
    'aldynes',
    'battleace',
    'daimakaimura',
    'ghoulsnghosts', // Daimakaimura alternate English title
    'madokinggranzort',
    // Enhanced PC Engine titles with PC-SG mark
    'dariusplus',
    'dariusalpha',
  };

  static const Set<String> _pceFamilyExtensions = {'.pce', '.sgx', '.cue'};

  /// Intellivision ROM extensions. `.rom` is ambiguous (also used by NES
  /// dumps, etc.), so we additionally require a small file size to keep
  /// the false-positive rate low.
  static const Set<String> _intvExtensions = {'.int', '.itv'};

  /// Maximum size (bytes) for a `.rom` to be considered Intellivision.
  /// Real Intellivision carts are ≤ 64 KB; anything larger is almost
  /// certainly a different system.
  static const int _intvRomMaxSize = 64 * 1024;

  final String path;
  final String name;
  final String extension;
  final GamePlatform platform;
  final int sizeBytes;
  final DateTime? lastPlayed;
  final String? coverPath;
  final bool isFavorite;
  final int totalPlayTimeSeconds;

  GameRom({
    required this.path,
    required String name,
    required this.extension,
    required this.platform,
    required this.sizeBytes,
    this.lastPlayed,
    this.coverPath,
    this.isFavorite = false,
    this.totalPlayTimeSeconds = 0,
  }) : name = _sanitizeUtf16(name);

  /// Replace unpaired surrogates (invalid UTF-16 code units) with the Unicode
  /// replacement character U+FFFD. Dart strings are UTF-16 internally; if we
  /// get a malformed string from the filesystem or database, attempting to
  /// render it in a [TextSpan] crashes the framework. This makes every
  /// [GameRom.name] safe for text rendering.
  static String _sanitizeUtf16(String s) {
    // Fast path: check if any problematic code units exist.
    bool hasSurrogate = false;
    for (int i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0xD800 && c <= 0xDFFF) {
        hasSurrogate = true;
        break;
      }
    }
    if (!hasSurrogate) return s;

    // Slow path: rebuild string, replacing unpaired surrogates.
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0xD800 && c <= 0xDBFF) {
        // High surrogate — check if followed by a valid low surrogate.
        if (i + 1 < s.length) {
          final next = s.codeUnitAt(i + 1);
          if (next >= 0xDC00 && next <= 0xDFFF) {
            // Valid surrogate pair — keep both.
            buf.writeCharCode(c);
            buf.writeCharCode(next);
            i++;
            continue;
          }
        }
        // Unpaired high surrogate.
        buf.writeCharCode(0xFFFD);
      } else if (c >= 0xDC00 && c <= 0xDFFF) {
        // Unpaired low surrogate.
        buf.writeCharCode(0xFFFD);
      } else {
        buf.writeCharCode(c);
      }
    }
    return buf.toString();
  }

  /// Create from file path
  static GameRom? fromPath(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    final ext = p.extension(filePath).toLowerCase();
    final platform = detectPlatformForFile(filePath);
    if (platform == GamePlatform.unknown) return null;

    final name = p.basenameWithoutExtension(filePath);
    final stat = file.statSync();

    return GameRom(
      path: filePath,
      name: name,
      extension: ext,
      platform: platform,
      sizeBytes: stat.size,
    );
  }

  static GameRom classifyWithRomHash(GameRom game, {String? romHash}) {
    final resolvedPlatform = detectPlatformForFile(game.path, romHash: romHash);
    return resolvedPlatform == game.platform
        ? game
        : game.copyWith(platform: resolvedPlatform);
  }

  /// Sega Mega Drive / Genesis cartridge ROMs store a 16-byte system ID at 0x100
  /// (`"SEGA MEGA DRIVE "` or `"SEGA GENESIS    "`). Used to disambiguate `.bin`,
  /// which is also used for PS1 tracks, disc dumps, Intellivision, etc.
  static const int _megaDriveHeaderOffset = 0x100;
  static const int _megaDriveHeaderLength = 16;

  /// Returns true when [filePath] looks like a standard MD/Genesis **cartridge** ROM.
  /// Does not catch every rip (e.g. byte-swapped images without this ASCII header).
  static bool isLikelyMegaDriveBin(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;
      if (file.lengthSync() < _megaDriveHeaderOffset + _megaDriveHeaderLength) {
        return false;
      }
      final raf = file.openSync(mode: FileMode.read);
      try {
        raf.setPositionSync(_megaDriveHeaderOffset);
        final bytes = raf.readSync(_megaDriveHeaderLength);
        if (bytes.length < _megaDriveHeaderLength) return false;
        final id = String.fromCharCodes(bytes);
        return id.startsWith('SEGA MEGA DRIVE') ||
            id.startsWith('SEGA GENESIS');
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      debugPrint(
        'GameRom: failed to read Mega Drive header for "$filePath" — $e',
      );
      return false;
    }
  }

  /// PC Engine CD games commonly use `.cue` + `.bin` pairs.
  /// Use a sibling cue-sheet heuristic to route ambiguous `.bin` files.
  static bool _hasSiblingCueSheet(String filePath) {
    try {
      final dir = p.dirname(filePath);
      final stem = p.basenameWithoutExtension(filePath);
      return File(p.join(dir, '$stem.cue')).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Returns true if [filePath] looks like a PS1 disc image.
  /// PS1 discs have the ASCII string "PLAYSTATION" near the start of the
  /// first data track and `SYSTEM.CNF` in the disc filesystem. Scanning the
  /// first 256 KB catches both cases without reading huge files.
  static const int _ps1ScanSize = 256 * 1024;
  static bool _isLikelyPs1Disc(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;
      final raf = file.openSync(mode: FileMode.read);
      try {
        final length = raf.lengthSync();
        final readLen = length < _ps1ScanSize ? length : _ps1ScanSize;
        if (readLen <= 0) return false;
        final bytes = raf.readSync(readLen);
        // Search for "PLAYSTATION" or "SYSTEM.CNF" markers.
        const playstation = [
          0x50,
          0x4C,
          0x41,
          0x59,
          0x53,
          0x54,
          0x41,
          0x54,
          0x49,
          0x4F,
          0x4E,
        ]; // "PLAYSTATION"
        const systemCnf = [
          0x53,
          0x59,
          0x53,
          0x54,
          0x45,
          0x4D,
          0x2E,
          0x43,
          0x4E,
          0x46,
        ]; // "SYSTEM.CNF"
        return _containsBytes(bytes, playstation) ||
            _containsBytes(bytes, systemCnf);
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      debugPrint('GameRom: failed to scan PS1 markers for "$filePath" — $e');
      return false;
    }
  }

  static bool _containsBytes(List<int> haystack, List<int> needle) {
    if (needle.isEmpty || haystack.length < needle.length) return false;
    outer:
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// Cue sheets are tiny text files: load and look for PSX track markers.
  ///
  /// Used by ZIP import only. Loose PS1 cue/bin sets are intentionally not
  /// classified as PS1; the supported PS1 import shape is a ZIP containing the
  /// `.cue` file and its `.bin` tracks.
  static bool isLikelyPs1CueSheet(String cuePath) {
    try {
      final cue = File(cuePath);
      if (!cue.existsSync()) return false;
      final text = cue.readAsStringSync();
      final lower = text.toLowerCase();
      // PS1 cues commonly reference SLUS / SLES / SCUS / SCES / SCPS / SLPS
      // identifiers in the .bin filename. If those are absent, fall back to
      // scanning the referenced .bin file for the PLAYSTATION marker.
      if (RegExp(
        r'(SLUS|SLES|SCUS|SCES|SCPS|SLPS|SLPM|SCAJ|SIPS)',
        caseSensitive: false,
      ).hasMatch(lower)) {
        return true;
      }
      for (final binName in _cueReferencedFileNames(text)) {
        final binPath = _cueReferenceToPath(cuePath, binName);
        if (_isLikelyPs1Disc(binPath)) return true;

        final normalizedBinName = binName.replaceAll(r'\', p.separator);
        final flattenedBinPath = p.join(
          p.dirname(cuePath),
          p.basename(normalizedBinName),
        );
        if (flattenedBinPath != binPath && _isLikelyPs1Disc(flattenedBinPath)) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static Iterable<String> _cueReferencedFileNames(String cueText) sync* {
    for (final match in RegExp(
      r'^\s*FILE\s+"([^"]+)"',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(cueText)) {
      final reference = match.group(1)?.trim();
      if (reference != null && reference.isNotEmpty) yield reference;
    }

    for (final match in RegExp(
      r'^\s*FILE\s+(.+?)\s+(?:BINARY|MOTOROLA|AIFF|WAVE|MP3)',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(cueText)) {
      final reference = match.group(1)?.trim();
      if (reference == null || reference.isEmpty || reference.startsWith('"')) {
        continue;
      }
      yield reference;
    }
  }

  static String _cueReferenceToPath(String cuePath, String reference) {
    final normalizedReference = reference.replaceAll(r'\', p.separator);
    return p.join(p.dirname(cuePath), normalizedReference);
  }

  /// Intellivision `.rom` dumps are ≤ 64 KB. Reject anything larger.
  static bool _isLikelyIntellivisionRom(String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;
      final size = file.lengthSync();
      return size > 0 && size <= _intvRomMaxSize;
    } catch (_) {
      return false;
    }
  }

  static String _normalizedBaseName(String filePath) {
    final baseName = p.basenameWithoutExtension(filePath).toLowerCase();
    return baseName.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  static bool _isLikelySuperGrafxName(String filePath) {
    final normalized = _normalizedBaseName(filePath);
    return _superGrafxNameMarkers.any(normalized.contains);
  }

  static bool _isKnownSuperGrafxHash(String? romHash) {
    // Known SGX title hashes can be added here as they are verified.
    const knownSuperGrafxHashes = <String>{};
    if (romHash == null || romHash.isEmpty) return false;
    return knownSuperGrafxHashes.contains(romHash.toLowerCase());
  }

  static GamePlatform _detectPceFamilyPlatform(
    String filePath, {
    String? romHash,
  }) {
    if (_isKnownSuperGrafxHash(romHash) || _isLikelySuperGrafxName(filePath)) {
      return GamePlatform.sgx;
    }
    return GamePlatform.pce;
  }

  static GamePlatform detectPlatformForFile(
    String filePath, {
    String? romHash,
  }) {
    // PICO-8 cart with `.p8.png` double extension is detected first because
    // `p.extension()` would otherwise return `.png` and be treated as unknown.
    if (filePath.toLowerCase().endsWith('.p8.png')) {
      return GamePlatform.pico8;
    }
    final extension = p.extension(filePath).toLowerCase();
    return _detectPlatform(extension, filePath, romHash: romHash);
  }

  static GamePlatform _detectPlatform(
    String extension,
    String filePath, {
    String? romHash,
  }) {
    // `.bin` is ambiguous — Mega Drive cartridge, PC Engine CD track, or PS1
    // track. PS1 cue/bin support uses the `.cue` as the game entry, so a
    // PS1-looking `.bin` stays `unknown` instead of becoming a duplicate.
    if (extension == '.bin') {
      if (isLikelyMegaDriveBin(filePath)) {
        return GamePlatform.md;
      }
      if (_hasSiblingCueSheet(filePath)) {
        // PS1 disc track → ignore; otherwise treat as PC Engine CD.
        if (_isLikelyPs1Disc(filePath)) return GamePlatform.unknown;
        return _detectPceFamilyPlatform(filePath, romHash: romHash);
      }
      // No sibling cue: not a supported cartridge/disc container.
      return GamePlatform.unknown;
    }
    // `.cue` references one or more loose `.bin` tracks. Loose PS1 cue/bin
    // files are not a supported import shape; PS1 cue/bin support is limited
    // to validated ZIP imports.
    if (extension == '.cue') {
      if (isLikelyPs1CueSheet(filePath)) return GamePlatform.unknown;
      return _detectPceFamilyPlatform(filePath, romHash: romHash);
    }
    // PS1 CHD is intentionally not exposed; supported PS1 imports are ZIPs
    // containing `.cue` + `.bin`. Do not misclassify loose CHDs as another
    // platform.
    if (extension == '.chd') {
      return GamePlatform.unknown;
    }
    // `.rom` is only Intellivision when small enough to be a real cart.
    if (extension == '.rom') {
      if (_isLikelyIntellivisionRom(filePath)) return GamePlatform.intv;
      return GamePlatform.unknown;
    }
    return switch (extension) {
      '.gba' => GamePlatform.gba,
      '.gb' => GamePlatform.gb,
      '.gbc' => GamePlatform.gbc,
      '.sgb' => GamePlatform.gb,
      '.nes' || '.unf' || '.unif' => GamePlatform.nes,
      '.sg' => GamePlatform.sg1000,
      '.sfc' => GamePlatform.snes,
      '.smc' => GamePlatform.snes,
      '.sms' => GamePlatform.sms,
      '.gg' => GamePlatform.gg,
      '.md' || '.gen' || '.smd' => GamePlatform.md,
      '.sgx' => GamePlatform.sgx,
      '.pce' => _detectPceFamilyPlatform(filePath, romHash: romHash),
      '.z64' || '.n64' || '.v64' => GamePlatform.n64,
      '.ngp' || '.ngc' => GamePlatform.ngp,
      '.ws' => GamePlatform.ws,
      '.wsc' => GamePlatform.wsc,
      '.a26' => GamePlatform.a2600,
      '.vb' => GamePlatform.vb,
      '.tic' => GamePlatform.tic80,
      '.p8' => GamePlatform.pico8,
      '.nds' => GamePlatform.nds,
      '.int' || '.itv' => GamePlatform.intv,
      _ => GamePlatform.unknown,
    };
  }

  static bool isPceFamilyExtension(String extension) {
    return extension == '.bin' || _pceFamilyExtensions.contains(extension);
  }

  /// Returns true if [extension] is unambiguously a PS1 disc-image format.
  static bool isPs1OnlyExtension(String extension) {
    return false;
  }

  /// Returns true if [extension] is unambiguously an Intellivision dump.
  static bool isIntellivisionExtension(String extension) {
    return _intvExtensions.contains(extension);
  }

  String get platformName {
    if (extension == '.sgb') return 'Super Game Boy';
    return switch (platform) {
      GamePlatform.gba => 'Game Boy Advance',
      GamePlatform.gb => 'Game Boy',
      GamePlatform.gbc => 'Game Boy Color',
      GamePlatform.nes => 'Nintendo Entertainment System',
      GamePlatform.snes => 'Super Nintendo',
      GamePlatform.sms => 'Sega Master System',
      GamePlatform.gg => 'Sega Game Gear',
      GamePlatform.md => 'Sega Mega Drive / Genesis',
      GamePlatform.pce => 'PC Engine / TurboGrafx-16',
      GamePlatform.sgx => 'SuperGrafx',
      GamePlatform.n64 => 'Nintendo 64',
      GamePlatform.sg1000 => 'Sega SG-1000',
      GamePlatform.ngp => 'Neo Geo Pocket / Color',
      GamePlatform.ws => 'WonderSwan',
      GamePlatform.wsc => 'WonderSwan Color',
      GamePlatform.a2600 => 'Atari 2600',
      GamePlatform.vb => 'Nintendo Virtual Boy',
      GamePlatform.tic80 => 'TIC-80',
      GamePlatform.pico8 => 'PICO-8',
      GamePlatform.nds => 'Nintendo DS',
      GamePlatform.ps1 => 'Sony PlayStation',
      GamePlatform.intv => 'Mattel Intellivision',
      GamePlatform.unknown => 'Unknown',
    };
  }

  String get platformShortName {
    if (extension == '.sgb') return 'SGB';
    if (platform == GamePlatform.ngp) {
      return extension == '.ngc' ? 'NGPC' : 'NGP';
    }
    return switch (platform) {
      GamePlatform.gba => 'GBA',
      GamePlatform.gb => 'GB',
      GamePlatform.gbc => 'GBC',
      GamePlatform.nes => 'NES',
      GamePlatform.snes => 'SNES',
      GamePlatform.sms => 'SMS',
      GamePlatform.gg => 'GG',
      GamePlatform.md => 'MD',
      GamePlatform.pce => 'PCE',
      GamePlatform.sgx => 'SGX',
      GamePlatform.n64 => 'N64',
      GamePlatform.sg1000 => 'SG-1000',
      GamePlatform.ngp => 'NGP',
      GamePlatform.ws => 'WS',
      GamePlatform.wsc => 'WSC',
      GamePlatform.a2600 => 'A2600',
      GamePlatform.vb => 'VB',
      GamePlatform.tic80 => 'TIC-80',
      GamePlatform.pico8 => 'PICO-8',
      GamePlatform.nds => 'NDS',
      GamePlatform.ps1 => 'PS1',
      GamePlatform.intv => 'INTV',
      GamePlatform.unknown => '???',
    };
  }

  String get formattedSize {
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    } else if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  /// Format total play time as a human-readable string
  String get formattedPlayTime {
    if (totalPlayTimeSeconds <= 0) return 'Never played';
    final hours = totalPlayTimeSeconds ~/ 3600;
    final minutes = (totalPlayTimeSeconds % 3600) ~/ 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m';
    } else {
      return '<1m';
    }
  }

  GameRom copyWith({
    String? path,
    String? name,
    String? extension,
    GamePlatform? platform,
    int? sizeBytes,
    Object? lastPlayed = _sentinel,
    Object? coverPath = _sentinel,
    bool? isFavorite,
    int? totalPlayTimeSeconds,
  }) {
    return GameRom(
      path: path ?? this.path,
      name: name ?? this.name,
      extension: extension ?? this.extension,
      platform: platform ?? this.platform,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      lastPlayed: lastPlayed == _sentinel
          ? this.lastPlayed
          : lastPlayed as DateTime?,
      coverPath: coverPath == _sentinel ? this.coverPath : coverPath as String?,
      isFavorite: isFavorite ?? this.isFavorite,
      totalPlayTimeSeconds: totalPlayTimeSeconds ?? this.totalPlayTimeSeconds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'name': name,
      'extension': extension,
      'platform': platform.name,
      'sizeBytes': sizeBytes,
      'lastPlayed': lastPlayed?.toIso8601String(),
      'coverPath': coverPath,
      'isFavorite': isFavorite,
      'totalPlayTimeSeconds': totalPlayTimeSeconds,
    };
  }

  factory GameRom.fromJson(Map<String, dynamic> json) {
    // Required fields — fail fast with a clear message if missing.
    final path = json['path'] as String?;
    final name = json['name'] as String?;
    final ext = json['extension'] as String?;
    if (path == null || name == null || ext == null) {
      throw FormatException(
        'GameRom.fromJson: missing required field(s) — '
        'path=$path, name=$name, extension=$ext',
      );
    }

    return GameRom(
      path: path,
      name: name,
      extension: ext,
      platform: _parsePlatform(json['platform']),
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      lastPlayed: _tryParseDateTime(json['lastPlayed']),
      coverPath: json['coverPath'] as String?,
      isFavorite: json['isFavorite'] as bool? ?? false,
      totalPlayTimeSeconds: json['totalPlayTimeSeconds'] as int? ?? 0,
    );
  }

  /// Safely try to parse a [GameRom] from JSON.
  /// Returns `null` on any error (missing fields, wrong types, etc.)
  /// instead of throwing — ideal for loading potentially-corrupt persisted data.
  static GameRom? tryFromJson(Map<String, dynamic> json) {
    try {
      return GameRom.fromJson(json);
    } catch (e) {
      debugPrint('GameRom: tryFromJson failed — $e');
      return null;
    }
  }

  /// Parse a date-time value that may be null, a String, or already invalid.
  static DateTime? _tryParseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  /// Parse platform from JSON, supporting both the current string format
  /// (.name) and the legacy int index format for backwards compatibility.
  static GamePlatform _parsePlatform(dynamic value) {
    if (value is String) {
      return GamePlatform.values.firstWhere(
        (e) => e.name == value,
        orElse: () => GamePlatform.unknown,
      );
    }
    if (value is int && value >= 0 && value < GamePlatform.values.length) {
      return GamePlatform.values[value];
    }
    return GamePlatform.unknown;
  }
}
