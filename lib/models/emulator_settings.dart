import 'dart:convert';

import 'gamepad_layout.dart';
import 'gamepad_skin.dart';

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
  final int autoSaveInterval; 
  final GamepadLayout gamepadLayoutPortrait;
  final GamepadLayout gamepadLayoutLandscape;
  final bool useJoystick; 
  final bool enableExternalGamepad; 
  final GamepadSkinType gamepadSkin; 
  final String selectedTheme; 
  final bool enableRewind; 
  final int rewindBufferSeconds; 
  final String sortOption; 
  final bool isGridView; 
  final bool raEnabled; 
  final bool raHardcoreMode; 
  final bool enableSgbBorders; 
  final String? userRomsFolderUri;

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
    this.userRomsFolderUri,
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
    String? userRomsFolderUri,
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
      userRomsFolderUri: userRomsFolderUri ?? this.userRomsFolderUri,
    );
  }

  static const int _jsonVersion = 3;

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
      'userRomsFolderUri': userRomsFolderUri,
    };
  }

  factory EmulatorSettings.fromJson(Map<String, dynamic> json) {
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
      gamepadLayoutPortrait: json['gamepadLayoutPortrait'] != null
          ? GamepadLayout.fromJson(
              json['gamepadLayoutPortrait'] as Map<String, dynamic>,
            )
          : GamepadLayout.defaultPortrait,
      gamepadLayoutLandscape: json['gamepadLayoutLandscape'] != null
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
      userRomsFolderUri: json['userRomsFolderUri'] as String?,
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
          userRomsFolderUri == other.userRomsFolderUri;

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
    userRomsFolderUri,
  ]);

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

  String toJsonString() => jsonEncode(toJson());

  factory EmulatorSettings.fromJsonString(String json) =>
      EmulatorSettings.fromJson(jsonDecode(json) as Map<String, dynamic>);
}

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
    [0x9BBC0F, 0x8BAC0F, 0x306230, 0x0F380F], 
    [0x7B8210, 0x5A7942, 0x39594A, 0x294139], 
    [0xC4CFA1, 0x8B956D, 0x4D533C, 0x1F1F1F], 
    [0x00B581, 0x009A71, 0x00694A, 0x004F3B], 
    [0xFFE4C2, 0xDCA456, 0xA9604C, 0x422936], 
    [0xFFFFFF, 0xAAAAAA, 0x555555, 0x000000], 
    [0xF7E7C6, 0xD68E49, 0xA63725, 0x331E50], 
  ];
}
