import 'package:flutter/foundation.dart';

import '../core/mgba_bindings.dart';
import '../models/cheat.dart';
import 'emulator_service.dart';
import 'game_database.dart';

class CheatSession extends ChangeNotifier {
  final EmulatorService _emulator;
  final GameDatabase _database;

  bool _hasSession = false;
  String _gamePath = '';
  final List<Cheat> _cheats = [];
  int _nextCoreIndex = 0;

  CheatSession(this._emulator, this._database);

  List<Cheat> get cheats => List.unmodifiable(_cheats);
  bool get hasSession => _hasSession;
  bool get isCheatsSupported => _emulator.isCheatsSupported;

  Future<void> startSession(String gamePath) async {
    endSession();
    _hasSession = true;
    _gamePath = gamePath;
    _cheats.clear();
    _nextCoreIndex = 0;
    notifyListeners();
    await _loadPersistedCheats();
  }

  Future<void> _loadPersistedCheats() async {
    try {
      final saved = await _database.getCheatsForGame(_gamePath);
      if (saved.isEmpty) return;

      for (final cheat in saved) {
        cheat.coreIndex = _nextCoreIndex++;
        _cheats.add(cheat);
        if (cheat.isActive) {
          final ok = _emulator.cheatSet(cheat.coreIndex, true, cheat.cheatCode);
          if (!ok) {
            cheat.isActive = false;
            _database.updateCheatActive(cheat.id, false);
            debugPrint(
              'CheatSession: core rejected persisted cheat '
              '"${cheat.title}" — deactivated',
            );
          }
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint('CheatSession: failed to load persisted cheats — $e');
    }
  }

  void endSession() {
    if (!_hasSession) return;

    _emulator.cheatReset();
    _cheats.clear();
    _hasSession = false;
    _gamePath = '';
    _nextCoreIndex = 0;
    notifyListeners();
  }

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
      coreIndex: _nextCoreIndex++,
    );
    _cheats.add(cheat);
    notifyListeners();
    _database.upsertCheat(cheat);

    return cheat;
  }

  Future<void> removeCheat(String cheatId) async {
    final index = _cheats.indexWhere((c) => c.id == cheatId);
    if (index == -1) return;

    final cheat = _cheats[index];
    if (cheat.isActive) {
      _emulator.cheatSet(cheat.coreIndex, false, cheat.cheatCode);
    }
    _cheats.removeAt(index);
    notifyListeners();

    _database.deleteCheat(cheatId);
  }

  Future<bool> toggleCheat(String cheatId) async {
    final cheat = _cheats.firstWhere(
      (c) => c.id == cheatId,
      orElse: () => throw StateError('Cheat not found: $cheatId'),
    );

    if (cheat.isActive) {
      _emulator.cheatSet(cheat.coreIndex, false, cheat.cheatCode);
      cheat.isActive = false;
    } else {
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
        'CheatSession: activated "${cheat.title}" '
        '(index=${cheat.coreIndex})',
      );
    }
    notifyListeners();
    _database.updateCheatActive(cheatId, cheat.isActive);

    return true;
  }
}
