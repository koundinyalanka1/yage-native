import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/mgba_bindings.dart';

const _sentinel = Object();

class GameRom {
  static const Set<String> _superGrafxNameMarkers = {
    '1941counterattack',
    'aldynes',
    'battleace',
    'daimakaimura',
    'ghoulsnghosts', 
    'madokinggranzort',
    'dariusplus',
    'dariusalpha',
  };

  static const Set<String> _pceFamilyExtensions = {
    '.pce',
    '.sgx',
    '.cue',
    '.chd',
  };

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
    required this.name,
    required this.extension,
    required this.platform,
    required this.sizeBytes,
    this.lastPlayed,
    this.coverPath,
    this.isFavorite = false,
    this.totalPlayTimeSeconds = 0,
  });

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

  static const int _megaDriveHeaderOffset = 0x100;
  static const int _megaDriveHeaderLength = 16;

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

  static bool _hasSiblingCueSheet(String filePath) {
    try {
      final dir = p.dirname(filePath);
      final stem = p.basenameWithoutExtension(filePath);
      return File(p.join(dir, '$stem.cue')).existsSync();
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
    final extension = p.extension(filePath).toLowerCase();
    return _detectPlatform(extension, filePath, romHash: romHash);
  }

  static GamePlatform _detectPlatform(
    String extension,
    String filePath, {
    String? romHash,
  }) {
    if (extension == '.bin') {
      if (isLikelyMegaDriveBin(filePath)) {
        return GamePlatform.md;
      }
      if (_hasSiblingCueSheet(filePath)) {
        return _detectPceFamilyPlatform(filePath, romHash: romHash);
      }
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
      '.pce' ||
      '.chd' ||
      '.cue' => _detectPceFamilyPlatform(filePath, romHash: romHash),
      '.z64' || '.n64' || '.v64' => GamePlatform.n64,
      '.ngp' || '.ngc' => GamePlatform.ngp,
      '.ws' => GamePlatform.ws,
      '.wsc' => GamePlatform.wsc,
      _ => GamePlatform.unknown,
    };
  }

  static bool isPceFamilyExtension(String extension) {
    return extension == '.bin' || _pceFamilyExtensions.contains(extension);
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

  static GameRom? tryFromJson(Map<String, dynamic> json) {
    try {
      return GameRom.fromJson(json);
    } catch (e) {
      debugPrint('GameRom: tryFromJson failed — $e');
      return null;
    }
  }

  static DateTime? _tryParseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

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
