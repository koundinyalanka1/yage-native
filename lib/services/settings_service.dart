import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/mgba_bindings.dart';
import '../models/emulator_settings.dart';
import '../models/gamepad_layout.dart';
import '../models/gamepad_skin.dart';

/// Service for managing app and emulator settings.
///
/// Uses debounced auto-save so that rapid changes (e.g. dragging a slider)
/// are batched into a single write, while still persisting promptly.
class SettingsService extends ChangeNotifier {
  static const String _settingsKey = 'emulator_settings';
  static const String _shortcutsShownKey = 'shortcuts_help_shown';
  static const String _gameLaunchCountKey = 'game_launch_count';
  static const Duration _saveDebounceDuration = Duration(milliseconds: 500);

  EmulatorSettings _settings = const EmulatorSettings();
  bool _isLoaded = false;
  Timer? _saveDebounceTimer;
  bool _hasPendingSave = false;

  final Completer<void> _loadCompleter = Completer<void>();

  EmulatorSettings get settings => _settings;
  bool get isLoaded => _isLoaded;

  /// Future that completes when [load] has finished.
  Future<void> get whenLoaded => _loadCompleter.future;

  /// Load settings from storage
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_settingsKey);

      if (json != null) {
        _settings = EmulatorSettings.fromJsonString(json);
      }

      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      // Use defaults on error
      _settings = const EmulatorSettings();
      _isLoaded = true;
      notifyListeners();
    } finally {
      if (!_loadCompleter.isCompleted) _loadCompleter.complete();
    }
  }

  /// Persist current settings to storage immediately.
  Future<void> save() async {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _hasPendingSave = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_settingsKey, _settings.toJsonString());
    } catch (e) {
      debugPrint('Failed to save settings: $e');
    }
  }

  /// Schedule a debounced save.  If another change arrives within the debounce
  /// window the timer resets, batching rapid-fire updates into one write.
  void _scheduleSave() {
    _hasPendingSave = true;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(_saveDebounceDuration, () {
      save();
    });
  }

  /// Update a single setting.
  ///
  /// Listeners are notified immediately so the UI reflects the change at once,
  /// while the actual disk write is debounced to avoid excessive I/O.
  Future<void> update(
    EmulatorSettings Function(EmulatorSettings) updater,
  ) async {
    _settings = updater(_settings);
    notifyListeners();
    _scheduleSave();
  }

  /// Flush any pending save and release resources.
  @override
  void dispose() {
    if (_hasPendingSave) {
      // Fire-and-forget: best-effort flush before the service is torn down.
      save();
    }
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    super.dispose();
  }

  /// Update volume
  Future<void> setVolume(double volume) async {
    await update((s) => s.copyWith(volume: volume.clamp(0.0, 1.0)));
  }

  /// Toggle sound
  Future<void> toggleSound() async {
    await update((s) => s.copyWith(enableSound: !s.enableSound));
  }

  /// Toggle FPS display
  Future<void> toggleShowFps() async {
    await update((s) => s.copyWith(showFps: !s.showFps));
  }

  /// Toggle vibration
  Future<void> toggleVibration() async {
    await update((s) => s.copyWith(enableVibration: !s.enableVibration));
  }

  /// Set gamepad opacity
  Future<void> setGamepadOpacity(double opacity) async {
    await update((s) => s.copyWith(gamepadOpacity: opacity.clamp(0.1, 1.0)));
  }

  /// Set gamepad scale
  Future<void> setGamepadScale(double scale) async {
    await update((s) => s.copyWith(gamepadScale: scale.clamp(0.5, 2.0)));
  }

  /// Toggle turbo mode
  Future<void> toggleTurbo() async {
    await update((s) => s.copyWith(enableTurbo: !s.enableTurbo));
  }

  /// Set turbo speed
  Future<void> setTurboSpeed(double speed) async {
    await update((s) => s.copyWith(turboSpeed: speed.clamp(1.5, 8.0)));
  }

  /// Set GBA BIOS path
  Future<void> setGbaBiosPath(String? path) async {
    await update((s) => s.copyWith(biosPathGba: path));
  }

  /// Set GB BIOS path
  Future<void> setGbBiosPath(String? path) async {
    await update((s) => s.copyWith(biosPathGb: path));
  }

  /// Set GBC BIOS path
  Future<void> setGbcBiosPath(String? path) async {
    await update((s) => s.copyWith(biosPathGbc: path));
  }

  /// Toggle skip BIOS
  Future<void> toggleSkipBios() async {
    await update((s) => s.copyWith(skipBios: !s.skipBios));
  }

  /// Set app theme
  Future<void> setAppTheme(String themeId) async {
    await update((s) => s.copyWith(selectedTheme: themeId));
  }

  /// Set color palette
  Future<void> setColorPalette(int index) async {
    await update((s) => s.copyWith(selectedColorPalette: index));
  }

  /// Toggle filtering
  Future<void> toggleFiltering() async {
    await update((s) => s.copyWith(enableFiltering: !s.enableFiltering));
  }

  /// Toggle Authentic Pixel Mode (the only graphics choice users see —
  /// everything else is Auto Optimized).
  ///
  /// Also keeps the legacy Smooth Scaling flag coherent: Authentic Pixel
  /// disables filtering (strict integer scaling), turning it off restores
  /// filtering so users who had disabled the removed toggle in an old
  /// build aren't stuck on a pixelated look with no visible switch.
  Future<void> setAuthenticPixelMode(bool enabled) async {
    await update(
      (s) => s.copyWith(
        graphicsQuality: enabled ? 'pixel' : 'auto',
        enableFiltering: !enabled,
      ),
    );
  }

  /// Toggle aspect ratio maintenance
  Future<void> toggleAspectRatio() async {
    await update(
      (s) => s.copyWith(maintainAspectRatio: !s.maintainAspectRatio),
    );
  }

  /// Set auto save interval
  Future<void> setAutoSaveInterval(int seconds) async {
    await update((s) => s.copyWith(autoSaveInterval: seconds));
  }

  /// Reset to defaults
  Future<void> resetToDefaults() async {
    _settings = const EmulatorSettings();
    notifyListeners();
    await save();
  }

  /// Set portrait gamepad layout
  Future<void> setGamepadLayoutPortrait(GamepadLayout layout) async {
    await update((s) => s.copyWith(gamepadLayoutPortrait: layout));
  }

  /// Set landscape gamepad layout
  Future<void> setGamepadLayoutLandscape(GamepadLayout layout) async {
    await update((s) => s.copyWith(gamepadLayoutLandscape: layout));
  }

  /// Set NDS portrait gamepad layout
  Future<void> setGamepadLayoutNdsPortrait(GamepadLayout layout) async {
    await update((s) => s.copyWith(gamepadLayoutNdsPortrait: layout));
  }

  /// Set NDS landscape gamepad layout
  Future<void> setGamepadLayoutNdsLandscape(GamepadLayout layout) async {
    await update((s) => s.copyWith(gamepadLayoutNdsLandscape: layout));
  }

  /// Set Genesis/Mega Drive portrait gamepad layout
  Future<void> setGamepadLayoutMdPortrait(GamepadLayout layout) async {
    await update((s) => s.copyWith(gamepadLayoutMdPortrait: layout));
  }

  /// Set Genesis/Mega Drive landscape gamepad layout
  Future<void> setGamepadLayoutMdLandscape(GamepadLayout layout) async {
    await update((s) => s.copyWith(gamepadLayoutMdLandscape: layout));
  }

  /// Set the editable touch layout for a specific console/orientation.
  Future<void> setGamepadLayoutForPlatform(
    GamePlatform platform, {
    required bool landscape,
    required GamepadLayout layout,
  }) async {
    await update(
      (s) => s.copyWithGamepadLayoutForPlatform(
        platform,
        landscape: landscape,
        layout: layout,
      ),
    );
  }

  /// Set game screen display scale (0.5 - 1.0)
  Future<void> setGameScreenScale(double scale) async {
    await update((s) => s.copyWith(gameScreenScale: scale.clamp(0.5, 1.0)));
  }

  /// Reset gamepad layouts to defaults
  Future<void> resetGamepadLayouts() async {
    await update(
      (s) => s.copyWith(
        gamepadLayoutPortrait: GamepadLayout.defaultPortrait,
        gamepadLayoutLandscape: GamepadLayout.defaultLandscape,
        gamepadLayoutNdsPortrait: GamepadLayout.defaultNdsPortrait,
        gamepadLayoutNdsLandscape: GamepadLayout.defaultNdsLandscape,
        gamepadLayoutMdPortrait: GamepadLayout.defaultMdPortrait,
        gamepadLayoutMdLandscape: GamepadLayout.defaultMdLandscape,
        gamepadLayoutsPortraitByPlatform: const <String, GamepadLayout>{},
        gamepadLayoutsLandscapeByPlatform: const <String, GamepadLayout>{},
      ),
    );
  }

  /// Toggle between D-pad and Joystick
  Future<void> toggleJoystick() async {
    await update((s) => s.copyWith(useJoystick: !s.useJoystick));
  }

  /// Set joystick mode explicitly
  Future<void> setUseJoystick(bool useJoystick) async {
    await update((s) => s.copyWith(useJoystick: useJoystick));
  }

  /// Toggle external gamepad support
  Future<void> toggleExternalGamepad() async {
    await update(
      (s) => s.copyWith(enableExternalGamepad: !s.enableExternalGamepad),
    );
  }

  /// Set gamepad visual skin
  Future<void> setGamepadSkin(GamepadSkinType skin) async {
    await update((s) => s.copyWith(gamepadSkin: skin));
  }

  /// Toggle rewind feature
  Future<void> toggleRewind() async {
    await update((s) => s.copyWith(enableRewind: !s.enableRewind));
  }

  /// Set rewind buffer duration in seconds
  Future<void> setRewindBufferSeconds(int seconds) async {
    await update((s) => s.copyWith(rewindBufferSeconds: seconds.clamp(1, 60)));
  }

  /// Set the sort option for the game library (stored as enum name string)
  Future<void> setSortOption(String sortOption) async {
    await update((s) => s.copyWith(sortOption: sortOption));
  }

  /// Toggle between grid and list view on the home screen
  Future<void> setGridView(bool isGridView) async {
    await update((s) => s.copyWith(isGridView: isGridView));
  }

  /// Toggle RetroAchievements master enable/disable
  Future<void> toggleRA() async {
    await update((s) => s.copyWith(raEnabled: !s.raEnabled));
  }

  /// Set RetroAchievements enabled explicitly
  Future<void> setRAEnabled(bool enabled) async {
    await update((s) => s.copyWith(raEnabled: enabled));
  }

  /// Toggle RetroAchievements hardcore mode
  Future<void> toggleRAHardcoreMode() async {
    await update((s) => s.copyWith(raHardcoreMode: !s.raHardcoreMode));
  }

  /// Set RetroAchievements hardcore mode explicitly
  Future<void> setRAHardcoreMode(bool enabled) async {
    await update((s) => s.copyWith(raHardcoreMode: enabled));
  }

  /// Toggle SGB (Super Game Boy) border rendering
  Future<void> toggleSgbBorders() async {
    await update((s) => s.copyWith(enableSgbBorders: !s.enableSgbBorders));
  }

  /// Set the user-selected ROMs folder URI (Android SAF) or path.
  /// When set, saves are synced here and ROMs/saves are imported on reinstall.
  Future<void> setUserRomsFolderUri(String? uri) async {
    await update((s) => s.copyWith(userRomsFolderUri: uri));
  }

  // ── One-time flags (stored outside the main settings blob) ──────────

  static const String _setupCompletedKey = 'rom_folder_setup_completed';

  /// Whether the user has completed the ROM folder setup (selected a folder).
  Future<bool> hasCompletedRomFolderSetup() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_setupCompletedKey) ?? false;
  }

  /// Mark ROM folder setup as completed (user selected a folder).
  Future<void> markRomFolderSetupCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_setupCompletedKey, true);
  }

  /// Reset setup flag (e.g. for testing).
  Future<void> resetRomFolderSetup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_setupCompletedKey);
  }

  /// Whether the shortcuts help dialog has already been shown once.
  Future<bool> isShortcutsHelpShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_shortcutsShownKey) ?? false;
  }

  /// Mark the shortcuts help dialog as shown so it won't auto-appear again.
  Future<void> markShortcutsHelpShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shortcutsShownKey, true);
  }

  /// Get how many times a game has been launched.
  Future<int> getGameLaunchCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_gameLaunchCountKey) ?? 0;
  }

  /// Increment the game launch counter.
  Future<void> incrementGameLaunchCount() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_gameLaunchCountKey) ?? 0;
    await prefs.setInt(_gameLaunchCountKey, count + 1);
  }
}
