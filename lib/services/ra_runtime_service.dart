import 'package:flutter/foundation.dart';

// ═══════════════════════════════════════════════════════════════════════
//  RetroAchievements Runtime Mode
// ═══════════════════════════════════════════════════════════════════════

/// The RA mode determines which emulator conveniences are allowed.
enum RAMode {
  /// Hardcore — no savestates, cheats, rewind, or fast-forward.
  /// Achievements are earned at full difficulty.
  hardcore,

  /// Softcore — all emulator conveniences are allowed.
  /// Achievements are still earned but tracked separately.
  softcore,

  /// Disabled — RetroAchievements runtime is not active.
  /// No restrictions, no achievement tracking.
  disabled,
}

// ═══════════════════════════════════════════════════════════════════════
//  RA Runtime Service — Mode Enforcement Only
// ═══════════════════════════════════════════════════════════════════════
//
//  Achievement evaluation, session management, unlock tracking, and API
//  submissions are all handled by the native rcheevos client
//  (RcheevosClient).  This service only manages the hardcore/softcore
//  mode toggle so the UI can block save states, fast forward, etc.

class RARuntimeService extends ChangeNotifier {
  // ── State ──────────────────────────────────────────────────────────
  RAMode _mode = RAMode.disabled;
  bool _isActive = false;

  // ── Public getters ─────────────────────────────────────────────────

  RAMode get mode => _mode;
  bool get isActive => _isActive;
  bool get isHardcore => _mode == RAMode.hardcore;
  bool get isSoftcore => _mode == RAMode.softcore;

  // ═══════════════════════════════════════════════════════════════════
  //  Lifecycle
  // ═══════════════════════════════════════════════════════════════════

  /// Activate the RA runtime mode for a game session.
  ///
  /// [hardcoreMode] — whether to enforce hardcore restrictions.
  void activate({required bool hardcoreMode}) {
    _mode = hardcoreMode ? RAMode.hardcore : RAMode.softcore;
    _isActive = true;

    debugPrint('RA Runtime: Activated in ${_mode.name} mode');
    notifyListeners();
  }

  /// Deactivate the RA runtime (call when the game exits).
  void deactivate() {
    if (!_isActive) return;

    _isActive = false;
    _mode = RAMode.disabled;

    debugPrint('RA Runtime: Deactivated');
    notifyListeners();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Mode Enforcement
  // ═══════════════════════════════════════════════════════════════════

  /// Whether save states are allowed in the current mode.
  bool get allowSaveStates => _mode != RAMode.hardcore;

  /// Whether loading save states is allowed.
  bool get allowLoadStates => _mode != RAMode.hardcore;

  /// Whether fast-forward is allowed.
  bool get allowFastForward => _mode != RAMode.hardcore;

  /// Whether rewind is allowed.
  bool get allowRewind => _mode != RAMode.hardcore;

  /// Whether cheats are allowed.
  bool get allowCheats => _mode != RAMode.hardcore;

  /// Whether slow-motion is allowed (speed < 1.0).
  bool get allowSlowMotion => _mode != RAMode.hardcore;

  /// Check if an emulator action is allowed and return a reason if blocked.
  /// Returns null if allowed, or a user-facing message if blocked.
  String? checkAction(String action) {
    if (_mode != RAMode.hardcore) return null;

    return switch (action) {
      'saveState' => 'Save states are disabled in Hardcore mode',
      'loadState' => 'Save states are disabled in Hardcore mode',
      'fastForward' => 'Fast forward is disabled in Hardcore mode',
      'rewind' => 'Rewind is disabled in Hardcore mode',
      'cheat' => 'Cheats are disabled in Hardcore mode',
      'slowMotion' => 'Slow motion is disabled in Hardcore mode',
      _ => null,
    };
  }
}
