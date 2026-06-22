import 'package:flutter/foundation.dart';

import '../core/mgba_bindings.dart';
import '../models/cheat.dart';
import 'emulator_service.dart';
import 'game_database.dart';

/// Manages cheat codes for the current gaming session.
///
/// Cheats are **persisted** in the SQLite database so they survive across
/// app restarts. When a session starts, previously saved cheats for the
/// game are loaded from the DB and any that were marked active are
/// re-applied to the native core.
///
/// All cheats are free to add and toggle without restrictions.
class CheatSession extends ChangeNotifier {
  final EmulatorService _emulator;
  final GameDatabase _database;

  bool _disposed = false;
  bool _hasSession = false;

  /// The ROM path used as the unique key for DB persistence.
  String _gamePath = '';
  final List<Cheat> _cheats = [];

  CheatSession(this._emulator, this._database);

  // ── Public getters ──

  List<Cheat> get cheats => List.unmodifiable(_cheats);
  bool get hasSession => _hasSession;
  bool get isCheatsSupported => _emulator.isCheatsSupported;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    endSession();
    _disposed = true;
    super.dispose();
  }

  // ── Session lifecycle ──

  /// Start a new cheat session for the given game.
  ///
  /// [gamePath] is the ROM file path — used as the DB key so cheats
  /// persist across sessions. Previously saved cheats are loaded from
  /// the database and any that were active are re-applied to the core.
  Future<void> startSession(String gamePath) async {
    endSession();
    if (_disposed) return;
    _hasSession = true;
    _gamePath = gamePath;
    _cheats.clear();
    notifyListeners();

    // Load persisted cheats for this game.
    await _loadPersistedCheats();
  }

  /// Load cheats from the database and re-apply active ones to the core.
  Future<void> _loadPersistedCheats() async {
    try {
      final saved = await _database.getCheatsForGame(_gamePath);
      if (saved.isEmpty) return;
      _cheats.addAll(saved);
      // Assign contiguous coreIndex values and push active cheats to the
      // native core. Any cheat the core rejects is auto-deactivated.
      _resync();
      notifyListeners();
    } catch (e) {
      debugPrint('CheatSession: failed to load persisted cheats — $e');
    }
  }

  /// End the current session, clearing cheats from the native core.
  ///
  /// Persisted cheats remain in the database — only runtime state is cleared.
  void endSession() {
    if (!_hasSession) return;

    // Best-effort reset — safe to call even if the core is already gone.
    try {
      _emulator.cheatReset();
    } catch (e) {
      debugPrint('CheatSession: cheatReset during endSession failed — $e');
    }
    _cheats.clear();
    _hasSession = false;
    _gamePath = '';
    notifyListeners();
  }

  /// Reset the native cheat list and re-apply every active cheat under a
  /// fresh, contiguous [Cheat.coreIndex]. Call this whenever the session
  /// list changes structurally (load, remove) so the native core's
  /// indices stay aligned with ours.
  ///
  /// If the core rejects an active cheat it is silently deactivated and
  /// the DB is updated.
  void _resync() {
    if (!_emulator.isCheatsSupported) {
      for (var i = 0; i < _cheats.length; i++) {
        _cheats[i].coreIndex = i;
      }
      return;
    }

    _emulator.cheatReset();
    for (var i = 0; i < _cheats.length; i++) {
      final c = _cheats[i];
      c.coreIndex = i;
      if (!c.isActive) continue;
      final ok = _emulator.cheatSet(i, true, c.cheatCode);
      if (!ok) {
        c.isActive = false;
        _database.updateCheatActive(c.id, false);
        debugPrint(
          'CheatSession: core rejected cheat "${c.title}" during resync '
          '— deactivated',
        );
      }
    }
  }

  // ── Cheat management ──

  /// Add a new user-entered cheat code.
  ///
  /// Does NOT activate it — the user must toggle it on.
  /// The cheat is immediately persisted to the database.
  Future<Cheat> addCheat({
    required GamePlatform system,
    required String title,
    required String cheatCode,
    required CheatType cheatType,
  }) async {
    final cheat = Cheat(
      id: 'cheat_${DateTime.now().microsecondsSinceEpoch}',
      system: system,
      gameId: _gamePath,
      title: title.trim(),
      cheatCode: cheatCode.trim(),
      cheatType: cheatType,
    );

    // Persist first while [coreIndex] is still its default sentinel
    // (-1). The DB row intentionally does not store coreIndex, making
    // this ordering explicit: the DB is the source of truth for the
    // durable fields, and coreIndex is assigned only after persistence.
    await _database.upsertCheat(cheat);

    // New cheats start inactive, so no cheatSet call is needed — they
    // only occupy a native slot once toggled on. Just append and record
    // their runtime index.
    cheat.coreIndex = _cheats.length;
    _cheats.add(cheat);
    notifyListeners();

    return cheat;
  }

  /// Remove a cheat. Deactivates it first if active, then deletes from DB
  /// and re-syncs remaining cheats so their [Cheat.coreIndex] stays
  /// contiguous and aligned with the native core.
  Future<void> removeCheat(String cheatId) async {
    final index = _cheats.indexWhere((c) => c.id == cheatId);
    if (index == -1) return;

    _cheats.removeAt(index);
    // A libretro core has no `retro_cheat_remove`; the only safe way to
    // drop a single entry is to reset the core's cheat list and push the
    // survivors back with their new indices.
    _resync();
    notifyListeners();

    await _database.deleteCheat(cheatId);
  }

  /// Toggle a cheat on or off.
  ///
  /// Returns `true` if the toggle succeeded, `false` if the native core
  /// rejected the cheat code (e.g. unsupported format, core doesn't
  /// implement cheats).
  Future<bool> toggleCheat(String cheatId) async {
    final cheat = _cheats.firstWhere(
      (c) => c.id == cheatId,
      orElse: () => throw StateError('Cheat not found: $cheatId'),
    );

    if (cheat.isActive) {
      // Deactivate in place — no index shuffle needed.
      _emulator.cheatSet(cheat.coreIndex, false, cheat.cheatCode);
      cheat.isActive = false;
      notifyListeners();
      await _database.updateCheatActive(cheatId, false);
      return true;
    }

    final ok = _emulator.cheatSet(cheat.coreIndex, true, cheat.cheatCode);
    if (!ok) {
      debugPrint(
        'CheatSession: core rejected cheat "${cheat.title}" — '
        'the core may not support cheats or the code format is wrong',
      );
      notifyListeners();
      return false;
    }
    cheat.isActive = true;
    debugPrint(
      'CheatSession: activated "${cheat.title}" (index=${cheat.coreIndex})',
    );
    notifyListeners();
    await _database.updateCheatActive(cheatId, true);
    return true;
  }
}
