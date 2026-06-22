import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/mgba_bindings.dart';
import '../utils/graphics_quality.dart';
import 'gamepad_layout.dart';
import 'gamepad_skin.dart';

/// Emulator settings configuration
class EmulatorSettings {
  final double volume;
  final bool enableSound;
  final bool showFps;
  final bool enableVibration;
  final double gamepadOpacity;
  final double gamepadScale;
  final bool enableTurbo;
  final double turboSpeed;
  final String? biosPathGba;
  final String? biosPathGb;
  final String? biosPathGbc;
  final bool skipBios;
  final int selectedColorPalette;
  final bool enableFiltering;
  final bool maintainAspectRatio;
  final int autoSaveInterval; // in seconds, 0 = disabled
  final GamepadLayout gamepadLayoutPortrait;
  final GamepadLayout gamepadLayoutLandscape;
  final bool useJoystick; // true = joystick, false = d-pad
  final bool enableExternalGamepad; // physical controller support
  final GamepadSkinType gamepadSkin; // visual theme for touch controls
  final String selectedTheme; // theme id string
  final bool enableRewind; // hold-to-rewind feature
  final int rewindBufferSeconds; // seconds of rewind history (1-60)
  final String sortOption; // persisted sort choice for the game library
  final bool isGridView; // grid vs list view on the home screen
  final bool raEnabled; // master toggle for RetroAchievements
  final bool raHardcoreMode; // RetroAchievements hardcore mode
  final bool enableSgbBorders; // SGB border rendering for GB games
  final double gameScreenScale; // game display size (0.5 = half, 1.0 = max)
  // Console-specific touch layouts with legacy dedicated storage.
  final GamepadLayout gamepadLayoutNdsPortrait;
  final GamepadLayout gamepadLayoutNdsLandscape;
  final GamepadLayout gamepadLayoutMdPortrait;
  final GamepadLayout gamepadLayoutMdLandscape;
  final Map<String, GamepadLayout> gamepadLayoutsPortraitByPlatform;
  final Map<String, GamepadLayout> gamepadLayoutsLandscapeByPlatform;

  /// User-selected ROMs folder URI (Android SAF) or path (legacy).
  /// When set, ROMs are imported from here on reinstall, and saves are synced here.
  final String? userRomsFolderUri;

  /// Graphics behaviour (stored string, backward compatible):
  /// 'auto' = Auto Optimized (default — best graphics per system/device),
  /// 'pixel' = Authentic Pixel Mode. Legacy values 'max' and 'sharp' from
  /// older builds are interpreted as Auto Optimized.
  /// See utils/graphics_quality.dart.
  final String graphicsQuality;

  const EmulatorSettings({
    this.volume = 0.8,
    this.enableSound = true,
    this.showFps = false,
    this.enableVibration = true,
    this.gamepadOpacity = 0.7,
    this.gamepadScale = 1.0,
    this.enableTurbo = false,
    this.turboSpeed = 2.0,
    this.biosPathGba,
    this.biosPathGb,
    this.biosPathGbc,
    this.skipBios = true,
    this.selectedColorPalette = 0,
    this.enableFiltering = true,
    this.maintainAspectRatio = true,
    this.autoSaveInterval = 0,
    this.gamepadLayoutPortrait = GamepadLayout.defaultPortrait,
    this.gamepadLayoutLandscape = GamepadLayout.defaultLandscape,
    this.useJoystick = false,
    this.enableExternalGamepad = true,
    this.gamepadSkin = GamepadSkinType.classic,
    this.selectedTheme = 'neon_night',
    this.enableRewind = false,
    this.rewindBufferSeconds = 3,
    this.sortOption = 'nameAsc',
    this.isGridView = true,
    this.raEnabled = true,
    this.raHardcoreMode = false,
    this.enableSgbBorders = true,
    this.gameScreenScale = 1.0,
    this.gamepadLayoutNdsPortrait = GamepadLayout.defaultNdsPortrait,
    this.gamepadLayoutNdsLandscape = GamepadLayout.defaultNdsLandscape,
    this.gamepadLayoutMdPortrait = GamepadLayout.defaultMdPortrait,
    this.gamepadLayoutMdLandscape = GamepadLayout.defaultMdLandscape,
    this.gamepadLayoutsPortraitByPlatform = const <String, GamepadLayout>{},
    this.gamepadLayoutsLandscapeByPlatform = const <String, GamepadLayout>{},
    this.userRomsFolderUri,
    this.graphicsQuality = 'auto',
  });

  EmulatorSettings copyWith({
    double? volume,
    bool? enableSound,
    bool? showFps,
    bool? enableVibration,
    double? gamepadOpacity,
    double? gamepadScale,
    bool? enableTurbo,
    double? turboSpeed,
    String? biosPathGba,
    String? biosPathGb,
    String? biosPathGbc,
    bool? skipBios,
    int? selectedColorPalette,
    bool? enableFiltering,
    bool? maintainAspectRatio,
    int? autoSaveInterval,
    GamepadLayout? gamepadLayoutPortrait,
    GamepadLayout? gamepadLayoutLandscape,
    bool? useJoystick,
    bool? enableExternalGamepad,
    GamepadSkinType? gamepadSkin,
    String? selectedTheme,
    bool? enableRewind,
    int? rewindBufferSeconds,
    String? sortOption,
    bool? isGridView,
    bool? raEnabled,
    bool? raHardcoreMode,
    bool? enableSgbBorders,
    double? gameScreenScale,
    GamepadLayout? gamepadLayoutNdsPortrait,
    GamepadLayout? gamepadLayoutNdsLandscape,
    GamepadLayout? gamepadLayoutMdPortrait,
    GamepadLayout? gamepadLayoutMdLandscape,
    Map<String, GamepadLayout>? gamepadLayoutsPortraitByPlatform,
    Map<String, GamepadLayout>? gamepadLayoutsLandscapeByPlatform,
    String? userRomsFolderUri,
    String? graphicsQuality,
  }) {
    return EmulatorSettings(
      volume: volume ?? this.volume,
      enableSound: enableSound ?? this.enableSound,
      showFps: showFps ?? this.showFps,
      enableVibration: enableVibration ?? this.enableVibration,
      gamepadOpacity: gamepadOpacity ?? this.gamepadOpacity,
      gamepadScale: gamepadScale ?? this.gamepadScale,
      enableTurbo: enableTurbo ?? this.enableTurbo,
      turboSpeed: turboSpeed ?? this.turboSpeed,
      biosPathGba: biosPathGba ?? this.biosPathGba,
      biosPathGb: biosPathGb ?? this.biosPathGb,
      biosPathGbc: biosPathGbc ?? this.biosPathGbc,
      skipBios: skipBios ?? this.skipBios,
      selectedColorPalette: selectedColorPalette ?? this.selectedColorPalette,
      enableFiltering: enableFiltering ?? this.enableFiltering,
      maintainAspectRatio: maintainAspectRatio ?? this.maintainAspectRatio,
      autoSaveInterval: autoSaveInterval ?? this.autoSaveInterval,
      gamepadLayoutPortrait:
          gamepadLayoutPortrait ?? this.gamepadLayoutPortrait,
      gamepadLayoutLandscape:
          gamepadLayoutLandscape ?? this.gamepadLayoutLandscape,
      useJoystick: useJoystick ?? this.useJoystick,
      enableExternalGamepad:
          enableExternalGamepad ?? this.enableExternalGamepad,
      gamepadSkin: gamepadSkin ?? this.gamepadSkin,
      selectedTheme: selectedTheme ?? this.selectedTheme,
      enableRewind: enableRewind ?? this.enableRewind,
      rewindBufferSeconds: rewindBufferSeconds ?? this.rewindBufferSeconds,
      sortOption: sortOption ?? this.sortOption,
      isGridView: isGridView ?? this.isGridView,
      raEnabled: raEnabled ?? this.raEnabled,
      raHardcoreMode: raHardcoreMode ?? this.raHardcoreMode,
      enableSgbBorders: enableSgbBorders ?? this.enableSgbBorders,
      gameScreenScale: gameScreenScale ?? this.gameScreenScale,
      gamepadLayoutNdsPortrait:
          gamepadLayoutNdsPortrait ?? this.gamepadLayoutNdsPortrait,
      gamepadLayoutNdsLandscape:
          gamepadLayoutNdsLandscape ?? this.gamepadLayoutNdsLandscape,
      gamepadLayoutMdPortrait:
          gamepadLayoutMdPortrait ?? this.gamepadLayoutMdPortrait,
      gamepadLayoutMdLandscape:
          gamepadLayoutMdLandscape ?? this.gamepadLayoutMdLandscape,
      gamepadLayoutsPortraitByPlatform:
          gamepadLayoutsPortraitByPlatform ??
          this.gamepadLayoutsPortraitByPlatform,
      gamepadLayoutsLandscapeByPlatform:
          gamepadLayoutsLandscapeByPlatform ??
          this.gamepadLayoutsLandscapeByPlatform,
      userRomsFolderUri: userRomsFolderUri ?? this.userRomsFolderUri,
      graphicsQuality: graphicsQuality ?? this.graphicsQuality,
    );
  }

  GamepadLayout gamepadLayoutForPlatform(
    GamePlatform platform, {
    required bool landscape,
  }) {
    final savedLayouts = landscape
        ? gamepadLayoutsLandscapeByPlatform
        : gamepadLayoutsPortraitByPlatform;
    final savedLayout = savedLayouts[platform.name];
    if (savedLayout != null) return savedLayout;

    return switch (platform) {
      GamePlatform.nds =>
        landscape ? gamepadLayoutNdsLandscape : gamepadLayoutNdsPortrait,
      GamePlatform.md =>
        landscape ? gamepadLayoutMdLandscape : gamepadLayoutMdPortrait,
      GamePlatform.gba || GamePlatform.unknown =>
        landscape ? gamepadLayoutLandscape : gamepadLayoutPortrait,
      _ => GamepadLayout.defaultForPlatform(platform, landscape: landscape),
    };
  }

  EmulatorSettings copyWithGamepadLayoutForPlatform(
    GamePlatform platform, {
    required bool landscape,
    required GamepadLayout layout,
  }) {
    switch (platform) {
      case GamePlatform.nds:
        return landscape
            ? copyWith(gamepadLayoutNdsLandscape: layout)
            : copyWith(gamepadLayoutNdsPortrait: layout);
      case GamePlatform.md:
        return landscape
            ? copyWith(gamepadLayoutMdLandscape: layout)
            : copyWith(gamepadLayoutMdPortrait: layout);
      case GamePlatform.gba:
      case GamePlatform.unknown:
        return landscape
            ? copyWith(gamepadLayoutLandscape: layout)
            : copyWith(gamepadLayoutPortrait: layout);
      default:
        final nextLayouts = Map<String, GamepadLayout>.from(
          landscape
              ? gamepadLayoutsLandscapeByPlatform
              : gamepadLayoutsPortraitByPlatform,
        );
        nextLayouts[platform.name] = layout;
        return landscape
            ? copyWith(
                gamepadLayoutsLandscapeByPlatform: Map.unmodifiable(
                  nextLayouts,
                ),
              )
            : copyWith(
                gamepadLayoutsPortraitByPlatform: Map.unmodifiable(nextLayouts),
              );
    }
  }

  /// Current schema version for the persisted settings JSON.
  /// Bump this when adding / removing / renaming fields so that future
  /// migration logic can detect the old format and upgrade it.
  static const int _jsonVersion = 7;

  /// Gamepad layouts saved before this version used a game-relative
  /// coordinate space (side-zones in landscape, control-area in portrait)
  /// that is incompatible with the current full-screen-fraction model.
  /// When an older blob is loaded we discard the saved layouts and fall back
  /// to the new defaults — a one-time reset, after which user edits persist.
  static const int _gamepadCoordSystemVersion = 6;

  Map<String, dynamic> toJson() {
    return {
      'version': _jsonVersion,
      'volume': volume,
      'enableSound': enableSound,
      'showFps': showFps,
      'enableVibration': enableVibration,
      'gamepadOpacity': gamepadOpacity,
      'gamepadScale': gamepadScale,
      'enableTurbo': enableTurbo,
      'turboSpeed': turboSpeed,
      'biosPathGba': biosPathGba,
      'biosPathGb': biosPathGb,
      'biosPathGbc': biosPathGbc,
      'skipBios': skipBios,
      'selectedColorPalette': selectedColorPalette,
      'enableFiltering': enableFiltering,
      'maintainAspectRatio': maintainAspectRatio,
      'autoSaveInterval': autoSaveInterval,
      'gamepadLayoutPortrait': gamepadLayoutPortrait.toJson(),
      'gamepadLayoutLandscape': gamepadLayoutLandscape.toJson(),
      'gamepadLayoutNdsPortrait': gamepadLayoutNdsPortrait.toJson(),
      'gamepadLayoutNdsLandscape': gamepadLayoutNdsLandscape.toJson(),
      'gamepadLayoutMdPortrait': gamepadLayoutMdPortrait.toJson(),
      'gamepadLayoutMdLandscape': gamepadLayoutMdLandscape.toJson(),
      'gamepadLayoutsPortraitByPlatform': _layoutMapToJson(
        gamepadLayoutsPortraitByPlatform,
      ),
      'gamepadLayoutsLandscapeByPlatform': _layoutMapToJson(
        gamepadLayoutsLandscapeByPlatform,
      ),
      'useJoystick': useJoystick,
      'enableExternalGamepad': enableExternalGamepad,
      'gamepadSkin': gamepadSkin.name,
      'selectedTheme': selectedTheme,
      'enableRewind': enableRewind,
      'rewindBufferSeconds': rewindBufferSeconds,
      'sortOption': sortOption,
      'isGridView': isGridView,
      'raEnabled': raEnabled,
      'raHardcoreMode': raHardcoreMode,
      'enableSgbBorders': enableSgbBorders,
      'gameScreenScale': gameScreenScale,
      'userRomsFolderUri': userRomsFolderUri,
      'graphicsQuality': graphicsQuality,
    };
  }

  factory EmulatorSettings.fromJson(Map<String, dynamic> json) {
    // Older settings stored gamepad layouts in an incompatible coordinate
    // space; ignore them so the new defaults take over once.
    final int storedVersion = (json['version'] as num?)?.toInt() ?? 0;
    final bool keepSavedLayouts = storedVersion >= _gamepadCoordSystemVersion;
    return EmulatorSettings(
      volume: (json['volume'] as num?)?.toDouble() ?? 0.8,
      enableSound: json['enableSound'] as bool? ?? true,
      showFps: json['showFps'] as bool? ?? false,
      enableVibration: json['enableVibration'] as bool? ?? true,
      gamepadOpacity: (json['gamepadOpacity'] as num?)?.toDouble() ?? 0.7,
      gamepadScale: (json['gamepadScale'] as num?)?.toDouble() ?? 1.0,
      enableTurbo: json['enableTurbo'] as bool? ?? false,
      turboSpeed: (json['turboSpeed'] as num?)?.toDouble() ?? 2.0,
      biosPathGba: json['biosPathGba'] as String?,
      biosPathGb: json['biosPathGb'] as String?,
      biosPathGbc: json['biosPathGbc'] as String?,
      skipBios: json['skipBios'] as bool? ?? true,
      selectedColorPalette: json['selectedColorPalette'] as int? ?? 0,
      enableFiltering: json['enableFiltering'] as bool? ?? true,
      maintainAspectRatio: json['maintainAspectRatio'] as bool? ?? true,
      autoSaveInterval: json['autoSaveInterval'] as int? ?? 0,
      gamepadLayoutPortrait:
          (keepSavedLayouts && json['gamepadLayoutPortrait'] != null)
          ? GamepadLayout.fromJson(
              json['gamepadLayoutPortrait'] as Map<String, dynamic>,
            )
          : GamepadLayout.defaultPortrait,
      gamepadLayoutLandscape:
          (keepSavedLayouts && json['gamepadLayoutLandscape'] != null)
          ? GamepadLayout.fromJson(
              json['gamepadLayoutLandscape'] as Map<String, dynamic>,
            )
          : GamepadLayout.defaultLandscape,
      useJoystick: json['useJoystick'] as bool? ?? false,
      enableExternalGamepad: json['enableExternalGamepad'] as bool? ?? true,
      gamepadSkin: _parseGamepadSkin(json['gamepadSkin']),
      selectedTheme: json['selectedTheme'] as String? ?? 'neon_night',
      enableRewind: json['enableRewind'] as bool? ?? false,
      rewindBufferSeconds: json['rewindBufferSeconds'] as int? ?? 3,
      sortOption: json['sortOption'] as String? ?? 'nameAsc',
      isGridView: json['isGridView'] as bool? ?? true,
      raEnabled: json['raEnabled'] as bool? ?? true,
      raHardcoreMode: json['raHardcoreMode'] as bool? ?? false,
      enableSgbBorders: json['enableSgbBorders'] as bool? ?? true,
      gameScreenScale: (json['gameScreenScale'] as num?)?.toDouble() ?? 1.0,
      gamepadLayoutNdsPortrait:
          (keepSavedLayouts && json['gamepadLayoutNdsPortrait'] != null)
          ? GamepadLayout.fromJson(
              json['gamepadLayoutNdsPortrait'] as Map<String, dynamic>,
            )
          : GamepadLayout.defaultNdsPortrait,
      gamepadLayoutNdsLandscape:
          (keepSavedLayouts && json['gamepadLayoutNdsLandscape'] != null)
          ? GamepadLayout.fromJson(
              json['gamepadLayoutNdsLandscape'] as Map<String, dynamic>,
            )
          : GamepadLayout.defaultNdsLandscape,
      gamepadLayoutMdPortrait:
          (keepSavedLayouts && json['gamepadLayoutMdPortrait'] != null)
          ? GamepadLayout.fromJson(
              json['gamepadLayoutMdPortrait'] as Map<String, dynamic>,
            )
          : GamepadLayout.defaultMdPortrait,
      gamepadLayoutMdLandscape:
          (keepSavedLayouts && json['gamepadLayoutMdLandscape'] != null)
          ? GamepadLayout.fromJson(
              json['gamepadLayoutMdLandscape'] as Map<String, dynamic>,
            )
          : GamepadLayout.defaultMdLandscape,
      gamepadLayoutsPortraitByPlatform: _parseLayoutMap(
        json['gamepadLayoutsPortraitByPlatform'],
        keepSavedLayouts,
      ),
      gamepadLayoutsLandscapeByPlatform: _parseLayoutMap(
        json['gamepadLayoutsLandscapeByPlatform'],
        keepSavedLayouts,
      ),
      userRomsFolderUri: json['userRomsFolderUri'] as String?,
      graphicsQuality: json['graphicsQuality'] as String? ?? 'auto',
    );
  }

  static Map<String, dynamic> _layoutMapToJson(
    Map<String, GamepadLayout> layouts,
  ) {
    return {
      for (final entry in layouts.entries) entry.key: entry.value.toJson(),
    };
  }

  static Map<String, GamepadLayout> _parseLayoutMap(
    dynamic value,
    bool keepSavedLayouts,
  ) {
    if (!keepSavedLayouts || value is! Map) {
      return const <String, GamepadLayout>{};
    }

    final layouts = <String, GamepadLayout>{};
    for (final entry in value.entries) {
      final rawLayout = entry.value;
      if (rawLayout is Map) {
        layouts[entry.key.toString()] = GamepadLayout.fromJson(
          Map<String, dynamic>.from(rawLayout),
        );
      }
    }
    return Map.unmodifiable(layouts);
  }

  static int _layoutMapHash(Map<String, GamepadLayout> layouts) {
    final entries = layouts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Object.hashAll(
      entries.map((entry) => Object.hash(entry.key, entry.value)),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmulatorSettings &&
          volume == other.volume &&
          enableSound == other.enableSound &&
          showFps == other.showFps &&
          enableVibration == other.enableVibration &&
          gamepadOpacity == other.gamepadOpacity &&
          gamepadScale == other.gamepadScale &&
          enableTurbo == other.enableTurbo &&
          turboSpeed == other.turboSpeed &&
          biosPathGba == other.biosPathGba &&
          biosPathGb == other.biosPathGb &&
          biosPathGbc == other.biosPathGbc &&
          skipBios == other.skipBios &&
          selectedColorPalette == other.selectedColorPalette &&
          enableFiltering == other.enableFiltering &&
          maintainAspectRatio == other.maintainAspectRatio &&
          autoSaveInterval == other.autoSaveInterval &&
          gamepadLayoutPortrait == other.gamepadLayoutPortrait &&
          gamepadLayoutLandscape == other.gamepadLayoutLandscape &&
          useJoystick == other.useJoystick &&
          enableExternalGamepad == other.enableExternalGamepad &&
          gamepadSkin == other.gamepadSkin &&
          selectedTheme == other.selectedTheme &&
          enableRewind == other.enableRewind &&
          rewindBufferSeconds == other.rewindBufferSeconds &&
          sortOption == other.sortOption &&
          isGridView == other.isGridView &&
          raEnabled == other.raEnabled &&
          raHardcoreMode == other.raHardcoreMode &&
          enableSgbBorders == other.enableSgbBorders &&
          gameScreenScale == other.gameScreenScale &&
          gamepadLayoutNdsPortrait == other.gamepadLayoutNdsPortrait &&
          gamepadLayoutNdsLandscape == other.gamepadLayoutNdsLandscape &&
          gamepadLayoutMdPortrait == other.gamepadLayoutMdPortrait &&
          gamepadLayoutMdLandscape == other.gamepadLayoutMdLandscape &&
          mapEquals(
            gamepadLayoutsPortraitByPlatform,
            other.gamepadLayoutsPortraitByPlatform,
          ) &&
          mapEquals(
            gamepadLayoutsLandscapeByPlatform,
            other.gamepadLayoutsLandscapeByPlatform,
          ) &&
          userRomsFolderUri == other.userRomsFolderUri &&
          graphicsQuality == other.graphicsQuality;

  @override
  int get hashCode => Object.hashAll([
    volume,
    enableSound,
    showFps,
    enableVibration,
    gamepadOpacity,
    gamepadScale,
    enableTurbo,
    turboSpeed,
    biosPathGba,
    biosPathGb,
    biosPathGbc,
    skipBios,
    selectedColorPalette,
    enableFiltering,
    maintainAspectRatio,
    autoSaveInterval,
    gamepadLayoutPortrait,
    gamepadLayoutLandscape,
    useJoystick,
    enableExternalGamepad,
    gamepadSkin,
    selectedTheme,
    enableRewind,
    rewindBufferSeconds,
    sortOption,
    isGridView,
    raEnabled,
    raHardcoreMode,
    enableSgbBorders,
    gameScreenScale,
    gamepadLayoutNdsPortrait,
    gamepadLayoutNdsLandscape,
    gamepadLayoutMdPortrait,
    gamepadLayoutMdLandscape,
    _layoutMapHash(gamepadLayoutsPortraitByPlatform),
    _layoutMapHash(gamepadLayoutsLandscapeByPlatform),
    userRomsFolderUri,
    graphicsQuality,
  ]);

  /// Parse gamepad skin from JSON, supporting both the current string format
  /// (.name) and the legacy int index format for backwards compatibility.
  static GamepadSkinType _parseGamepadSkin(dynamic value) {
    if (value is String) {
      return GamepadSkinType.values.firstWhere(
        (e) => e.name == value,
        orElse: () => GamepadSkinType.classic,
      );
    }
    if (value is int && value >= 0 && value < GamepadSkinType.values.length) {
      return GamepadSkinType.values[value];
    }
    return GamepadSkinType.classic;
  }

  /// Parsed graphics mode (see utils/graphics_quality.dart). Legacy
  /// 'max'/'sharp' values map to Auto Optimized; 'pixel' maps to
  /// Authentic Pixel Mode.
  GraphicsMode get graphicsMode => parseGraphicsMode(graphicsQuality);

  /// Whether the final display scaling may be smooth/filtered at all.
  /// False = Authentic Pixel behaviour (strict integer scaling).
  /// Combines the legacy Smooth Scaling toggle with the mode so settings
  /// written by any previous version keep their pixel-perfect intent.
  bool get smoothScalingEnabled =>
      enableFiltering && graphicsMode != GraphicsMode.authenticPixel;

  String toJsonString() => jsonEncode(toJson());

  factory EmulatorSettings.fromJsonString(String json) =>
      EmulatorSettings.fromJson(jsonDecode(json) as Map<String, dynamic>);
}

/// Color palettes for original Game Boy
class GBColorPalette {
  static const List<String> names = [
    'Classic Green',
    'Original DMG',
    'Pocket',
    'Light',
    'Kiosk',
    'Grayscale',
    'Super Game Boy',
  ];

  static const List<List<int>> palettes = [
    [0x9BBC0F, 0x8BAC0F, 0x306230, 0x0F380F], // Classic Green
    [0x7B8210, 0x5A7942, 0x39594A, 0x294139], // Original DMG
    [0xC4CFA1, 0x8B956D, 0x4D533C, 0x1F1F1F], // Pocket
    [0x00B581, 0x009A71, 0x00694A, 0x004F3B], // Light
    [0xFFE4C2, 0xDCA456, 0xA9604C, 0x422936], // Kiosk
    [0xFFFFFF, 0xAAAAAA, 0x555555, 0x000000], // Grayscale
    [0xF7E7C6, 0xD68E49, 0xA63725, 0x331E50], // Super Game Boy
  ];
}
