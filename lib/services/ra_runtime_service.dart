import 'package:flutter/foundation.dart';

enum RAMode {
  hardcore,

  softcore,

  disabled,
}

class RARuntimeService extends ChangeNotifier {
  RAMode _mode = RAMode.disabled;
  bool _isActive = false;

  RAMode get mode => _mode;
  bool get isActive => _isActive;
  bool get isHardcore => _mode == RAMode.hardcore;
  bool get isSoftcore => _mode == RAMode.softcore;

  void activate({required bool hardcoreMode}) {
    _mode = hardcoreMode ? RAMode.hardcore : RAMode.softcore;
    _isActive = true;

    debugPrint('RA Runtime: Activated in ${_mode.name} mode');
    notifyListeners();
  }

  void deactivate() {
    if (!_isActive) return;

    _isActive = false;
    _mode = RAMode.disabled;

    debugPrint('RA Runtime: Deactivated');
    notifyListeners();
  }

  bool get allowSaveStates => _mode != RAMode.hardcore;

  bool get allowLoadStates => _mode != RAMode.hardcore;

  bool get allowFastForward => _mode != RAMode.hardcore;

  bool get allowRewind => _mode != RAMode.hardcore;

  bool get allowCheats => _mode != RAMode.hardcore;

  bool get allowSlowMotion => _mode != RAMode.hardcore;

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
