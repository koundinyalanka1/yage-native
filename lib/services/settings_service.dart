import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/emulator_settings.dart';
import '../models/gamepad_layout.dart';
import '../models/gamepad_skin.dart';

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

  Future<void> get whenLoaded => _loadCompleter.future;

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
      _settings = const EmulatorSettings();
      _isLoaded = true;
      notifyListeners();
    } finally {
      if (!_loadCompleter.isCompleted) _loadCompleter.complete();
    }
  }

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

  void _scheduleSave() {
    _hasPendingSave = true;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(_saveDebounceDuration, () {
      save();
    });
  }

  Future<void> update(
    EmulatorSettings Function(EmulatorSettings) updater,
  ) async {
    _settings = updater(_settings);
    notifyListeners();
    _scheduleSave();
  }

  @override
  void dispose() {
    if (_hasPendingSave) {
      save();
    }
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    super.dispose();
  }

  Future<void> setVolume(double volume) async {
    await update((s) => s.copyWith(volume: volume.clamp(0.0, 1.0)));
  }

  Future<void> toggleSound() async {
    await update((s) => s.copyWith(enableSound: !s.enableSound));
  }

  Future<void> toggleShowFps() async {
    await update((s) => s.copyWith(showFps: !s.showFps));
  }

  Future<void> toggleVibration() async {
    await update((s) => s.copyWith(enableVibration: !s.enableVibration));
  }

  Future<void> setGamepadOpacity(double opacity) async {
    await update((s) => s.copyWith(gamepadOpacity: opacity.clamp(0.1, 1.0)));
  }

  Future<void> setGamepadScale(double scale) async {
    await update((s) => s.copyWith(gamepadScale: scale.clamp(0.5, 2.0)));
  }

  Future<void> toggleTurbo() async {
    await update((s) => s.copyWith(enableTurbo: !s.enableTurbo));
  }

  Future<void> setTurboSpeed(double speed) async {
    await update((s) => s.copyWith(turboSpeed: speed.clamp(1.5, 8.0)));
  }

  Future<void> setGbaBiosPath(String? path) async {
    await update((s) => s.copyWith(biosPathGba: path));
  }

  Future<void> setGbBiosPath(String? path) async {
    await update((s) => s.copyWith(biosPathGb: path));
  }

  Future<void> setGbcBiosPath(String? path) async {
    await update((s) => s.copyWith(biosPathGbc: path));
  }

  Future<void> toggleSkipBios() async {
    await update((s) => s.copyWith(skipBios: !s.skipBios));
  }

  Future<void> setAppTheme(String themeId) async {
    await update((s) => s.copyWith(selectedTheme: themeId));
  }

  Future<void> setColorPalette(int index) async {
    await update((s) => s.copyWith(selectedColorPalette: index));
  }

  Future<void> toggleFiltering() async {
    await update((s) => s.copyWith(enableFiltering: !s.enableFiltering));
  }

  Future<void> toggleAspectRatio() async {
    await update(
      (s) => s.copyWith(maintainAspectRatio: !s.maintainAspectRatio),
    );
  }

  Future<void> setAutoSaveInterval(int seconds) async {
    await update((s) => s.copyWith(autoSaveInterval: seconds));
  }

  Future<void> resetToDefaults() async {
    _settings = const EmulatorSettings();
    notifyListeners();
    await save();
  }

  Future<void> setGamepadLayoutPortrait(GamepadLayout layout) async {
    await update((s) => s.copyWith(gamepadLayoutPortrait: layout));
  }

  Future<void> setGamepadLayoutLandscape(GamepadLayout layout) async {
    await update((s) => s.copyWith(gamepadLayoutLandscape: layout));
  }

  Future<void> resetGamepadLayouts() async {
    await update(
      (s) => s.copyWith(
        gamepadLayoutPortrait: GamepadLayout.defaultPortrait,
        gamepadLayoutLandscape: GamepadLayout.defaultLandscape,
      ),
    );
  }

  Future<void> toggleJoystick() async {
    await update((s) => s.copyWith(useJoystick: !s.useJoystick));
  }

  Future<void> setUseJoystick(bool useJoystick) async {
    await update((s) => s.copyWith(useJoystick: useJoystick));
  }

  Future<void> toggleExternalGamepad() async {
    await update(
      (s) => s.copyWith(enableExternalGamepad: !s.enableExternalGamepad),
    );
  }

  Future<void> setGamepadSkin(GamepadSkinType skin) async {
    await update((s) => s.copyWith(gamepadSkin: skin));
  }

  Future<void> toggleRewind() async {
    await update((s) => s.copyWith(enableRewind: !s.enableRewind));
  }

  Future<void> setRewindBufferSeconds(int seconds) async {
    await update((s) => s.copyWith(rewindBufferSeconds: seconds.clamp(1, 60)));
  }

  Future<void> setSortOption(String sortOption) async {
    await update((s) => s.copyWith(sortOption: sortOption));
  }

  Future<void> setGridView(bool isGridView) async {
    await update((s) => s.copyWith(isGridView: isGridView));
  }

  Future<void> toggleRA() async {
    await update((s) => s.copyWith(raEnabled: !s.raEnabled));
  }

  Future<void> setRAEnabled(bool enabled) async {
    await update((s) => s.copyWith(raEnabled: enabled));
  }

  Future<void> toggleRAHardcoreMode() async {
    await update((s) => s.copyWith(raHardcoreMode: !s.raHardcoreMode));
  }

  Future<void> setRAHardcoreMode(bool enabled) async {
    await update((s) => s.copyWith(raHardcoreMode: enabled));
  }

  Future<void> toggleSgbBorders() async {
    await update((s) => s.copyWith(enableSgbBorders: !s.enableSgbBorders));
  }

  Future<void> setUserRomsFolderUri(String? uri) async {
    await update((s) => s.copyWith(userRomsFolderUri: uri));
  }

  static const String _setupCompletedKey = 'rom_folder_setup_completed';

  Future<bool> hasCompletedRomFolderSetup() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_setupCompletedKey) ?? false;
  }

  Future<void> markRomFolderSetupCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_setupCompletedKey, true);
  }

  Future<void> resetRomFolderSetup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_setupCompletedKey);
  }

  Future<bool> isShortcutsHelpShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_shortcutsShownKey) ?? false;
  }

  Future<void> markShortcutsHelpShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shortcutsShownKey, true);
  }

  Future<int> getGameLaunchCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_gameLaunchCountKey) ?? 0;
  }

  Future<void> incrementGameLaunchCount() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(_gameLaunchCountKey) ?? 0;
    await prefs.setInt(_gameLaunchCountKey, count + 1);
  }
}
