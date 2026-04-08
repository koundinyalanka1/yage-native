import 'package:flutter/services.dart';

import '../core/mgba_bindings.dart';

class GamepadMapper {
  static final Map<LogicalKeyboardKey, int> defaultMapping = {
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,
    LogicalKeyboardKey.gameButtonA: GBAKey.b,
    LogicalKeyboardKey.gameButtonB: GBAKey.a,
    LogicalKeyboardKey.gameButtonX: GBAKey.a, 
    LogicalKeyboardKey.gameButtonY: GBAKey.b, 
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l, 
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r, 
    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,
    LogicalKeyboardKey.keyZ: GBAKey.a,
    LogicalKeyboardKey.keyX: GBAKey.b,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.r,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.select,
    LogicalKeyboardKey.backspace: GBAKey.select,
    LogicalKeyboardKey.space: GBAKey.a,
  };

  static final Map<LogicalKeyboardKey, int> snesMapping = {
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,
    LogicalKeyboardKey.gameButtonA: GBAKey.b,
    LogicalKeyboardKey.gameButtonB: GBAKey.a,
    LogicalKeyboardKey.gameButtonX: GBAKey.x,
    LogicalKeyboardKey.gameButtonY: GBAKey.y,
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r,
    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,
    LogicalKeyboardKey.keyZ: GBAKey.a,
    LogicalKeyboardKey.keyX: GBAKey.b,
    LogicalKeyboardKey.keyC: GBAKey.x,
    LogicalKeyboardKey.keyV: GBAKey.y,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.r,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.select,
    LogicalKeyboardKey.backspace: GBAKey.select,
    LogicalKeyboardKey.space: GBAKey.a,
  };

  static final Map<LogicalKeyboardKey, int> n64Mapping = {
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,
    LogicalKeyboardKey.gameButtonA: GBAKey.a,
    LogicalKeyboardKey.gameButtonB: GBAKey.b,
    LogicalKeyboardKey.gameButtonX: GBAKey.x,
    LogicalKeyboardKey.gameButtonY: GBAKey.y,
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.select,
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r,
    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,
    LogicalKeyboardKey.keyZ: GBAKey.a,
    LogicalKeyboardKey.keyX: GBAKey.b,
    LogicalKeyboardKey.keyC: GBAKey.x,
    LogicalKeyboardKey.keyV: GBAKey.y,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.r,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.select,
    LogicalKeyboardKey.backspace: GBAKey.select,
    LogicalKeyboardKey.space: GBAKey.a,
  };

  static Map<LogicalKeyboardKey, int> mappingForPlatform(
    GamePlatform platform,
  ) {
    return switch (platform) {
      GamePlatform.snes => snesMapping,
      GamePlatform.md => snesMapping,
      GamePlatform.n64 => n64Mapping,
      _ => defaultMapping,
    };
  }

  static final Set<LogicalKeyboardKey> _gamepadOnlyKeys = {
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.gameButtonB,
    LogicalKeyboardKey.gameButtonX,
    LogicalKeyboardKey.gameButtonY,
    LogicalKeyboardKey.gameButtonLeft1,
    LogicalKeyboardKey.gameButtonRight1,
    LogicalKeyboardKey.gameButtonLeft2,
    LogicalKeyboardKey.gameButtonRight2,
    LogicalKeyboardKey.gameButtonStart,
    LogicalKeyboardKey.gameButtonSelect,
  };

  final Set<LogicalKeyboardKey> _activeKeys = {};

  int _pressedKeys = 0;

  bool _controllerDetected = false;

  Map<LogicalKeyboardKey, int> _mapping;

  GamepadMapper({Map<LogicalKeyboardKey, int>? mapping})
    : _mapping = mapping ?? defaultMapping;

  void updateMapping(Map<LogicalKeyboardKey, int> mapping) {
    _mapping = mapping;
    _rebuildBitmask();
  }

  int get keys => _pressedKeys;

  bool get controllerDetected => _controllerDetected;

  bool handleKeyEvent(KeyEvent event) {
    final logicalKey = event.logicalKey;
    if (!_mapping.containsKey(logicalKey)) return false;
    if (!_controllerDetected && _gamepadOnlyKeys.contains(logicalKey)) {
      _controllerDetected = true;
    }

    if (event is KeyDownEvent) {
      _activeKeys.add(logicalKey);
    } else if (event is KeyUpEvent) {
      _activeKeys.remove(logicalKey);
    }
    _rebuildBitmask();
    return true;
  }

  void _rebuildBitmask() {
    int mask = 0;
    for (final key in _activeKeys) {
      final gbaKey = _mapping[key];
      if (gbaKey != null) {
        mask |= gbaKey;
      }
    }
    _pressedKeys = mask;
  }

  void reset() {
    _activeKeys.clear();
    _pressedKeys = 0;
  }

  void resetDetection() {
    _controllerDetected = false;
  }
}
