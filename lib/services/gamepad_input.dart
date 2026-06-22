import 'package:flutter/services.dart';

import '../core/mgba_bindings.dart';

/// Maps physical gamepad and keyboard buttons to GBA key bitmask values.
///
/// Supports:
/// - Standard Bluetooth/USB gamepads (D-pad, face buttons, shoulders, start/select)
/// - Keyboard fallbacks (arrows, Z/X, A/S, Enter, Shift)
/// - Platform-specific layouts for consoles whose RetroPad mapping differs
///
/// Gamepad face buttons are treated by their common modern positions:
/// `gameButtonA` = south, `B` = east, `X` = west, `Y` = north.
class GamepadMapper {
  /// Default mapping for GB/GBC/GBA/NES: LogicalKeyboardKey → GBAKey bitmask
  static final Map<LogicalKeyboardKey, int> defaultMapping = {
    // ── D-pad (arrow keys — used by both keyboard and gamepad D-pad) ──
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,

    // ── Gamepad face buttons ──
    // Nintendo-style logical mapping: south button acts as B, east as A.
    LogicalKeyboardKey.gameButtonA: GBAKey.b,
    LogicalKeyboardKey.gameButtonB: GBAKey.a,
    LogicalKeyboardKey.gameButtonX: GBAKey.a, // alternate A
    LogicalKeyboardKey.gameButtonY: GBAKey.b, // alternate B
    // ── Shoulder buttons / triggers ──
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l, // trigger → L
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r, // trigger → R
    // ── Start / Select ──
    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,

    // ── Keyboard fallbacks ──
    LogicalKeyboardKey.keyZ: GBAKey.a,
    LogicalKeyboardKey.keyX: GBAKey.b,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.r,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.select,
    LogicalKeyboardKey.backspace: GBAKey.select,
    LogicalKeyboardKey.space: GBAKey.a,
  };

  /// Nintendo diamond mapping: south->B, east->A, west->Y, north->X.
  ///
  /// Used by SNES and NDS so a modern Bluetooth/USB pad lines up with the
  /// physical console button positions rather than the printed Xbox labels.
  static final Map<LogicalKeyboardKey, int> nintendoFourButtonMapping = {
    // ── D-pad ──
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,

    // ── Gamepad face buttons (Nintendo diamond) ──
    LogicalKeyboardKey.gameButtonA: GBAKey.b,
    LogicalKeyboardKey.gameButtonB: GBAKey.a,
    LogicalKeyboardKey.gameButtonX: GBAKey.y,
    LogicalKeyboardKey.gameButtonY: GBAKey.x,
    // ── Shoulder buttons / triggers ──
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r,

    // ── Start / Select ──
    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,

    // ── Keyboard fallbacks ──
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

  /// Backwards-compatible alias for older call sites/tests.
  static Map<LogicalKeyboardKey, int> get snesMapping =>
      nintendoFourButtonMapping;

  /// PlayStation RetroPad mapping: south->Cross, east->Circle, west->Square,
  /// north->Triangle. Beetle/Mednafen PSX follows libretro's standard PSX
  /// mapping where Cross/B, Circle/A, Square/Y, Triangle/X.
  static final Map<LogicalKeyboardKey, int> ps1Mapping = {
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,

    LogicalKeyboardKey.gameButtonA: GBAKey.b, // Cross
    LogicalKeyboardKey.gameButtonB: GBAKey.a, // Circle
    LogicalKeyboardKey.gameButtonX: GBAKey.y, // Square
    LogicalKeyboardKey.gameButtonY: GBAKey.x, // Triangle

    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l2,
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r2,
    LogicalKeyboardKey.gameButtonThumbLeft: GBAKey.l3,
    LogicalKeyboardKey.gameButtonThumbRight: GBAKey.r3,

    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,

    LogicalKeyboardKey.keyZ: GBAKey.b,
    LogicalKeyboardKey.keyX: GBAKey.a,
    LogicalKeyboardKey.keyC: GBAKey.y,
    LogicalKeyboardKey.keyV: GBAKey.x,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.r,
    LogicalKeyboardKey.keyQ: GBAKey.l2,
    LogicalKeyboardKey.keyW: GBAKey.r2,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.select,
    LogicalKeyboardKey.backspace: GBAKey.select,
    LogicalKeyboardKey.space: GBAKey.b,
  };

  /// Sega Genesis / Mega Drive six-button mapping for Genesis Plus GX.
  ///
  /// Modern controller spread:
  /// - west/south/east -> A/B/C
  /// - L1/north/R1 -> X/Y/Z
  /// - Select/Mode -> Genesis Mode
  static final Map<LogicalKeyboardKey, int> mdMapping = {
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,

    LogicalKeyboardKey.gameButtonX: GBAKey.y, // Genesis A (JOYPAD_Y)
    LogicalKeyboardKey.gameButtonA: GBAKey.b, // Genesis B (JOYPAD_B)
    LogicalKeyboardKey.gameButtonB: GBAKey.a, // Genesis C (JOYPAD_A)
    LogicalKeyboardKey.gameButtonC: GBAKey.a,
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l, // Genesis X (JOYPAD_L)
    LogicalKeyboardKey.gameButtonY: GBAKey.x, // Genesis Y (JOYPAD_X)
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r, // Genesis Z (JOYPAD_R)
    LogicalKeyboardKey.gameButtonZ: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r,

    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,
    LogicalKeyboardKey.gameButtonMode: GBAKey.select,

    LogicalKeyboardKey.keyZ: GBAKey.y,
    LogicalKeyboardKey.keyX: GBAKey.b,
    LogicalKeyboardKey.keyC: GBAKey.a,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.x,
    LogicalKeyboardKey.keyD: GBAKey.r,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.select,
    LogicalKeyboardKey.backspace: GBAKey.select,
    LogicalKeyboardKey.space: GBAKey.b,
  };

  /// N64 mapping: expose the buttons this KeyEvent path can send accurately.
  ///
  /// Notes:
  /// - Mupen64Plus-Next puts N64 A on RetroPad B and N64 B on RetroPad Y.
  /// - Z is JOYPAD_L2. The C-buttons need right-analog support, so X/Y face
  ///   buttons intentionally stay unmapped here instead of sending wrong input.
  /// - True analog-stick axes are not delivered through Flutter KeyEvent; touch
  ///   joystick support uses EmulatorService.setAnalog separately.
  static final Map<LogicalKeyboardKey, int> n64Mapping = {
    // ── D-pad ──
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,

    // ── Face buttons ──
    LogicalKeyboardKey.gameButtonA: GBAKey.b, // N64 A
    LogicalKeyboardKey.gameButtonB: GBAKey.y, // N64 B
    // ── Shoulder / trigger ──
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l2,
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r,
    LogicalKeyboardKey.gameButtonZ: GBAKey.l2,

    // ── Start / Select ──
    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.l2,

    // ── Keyboard fallbacks ──
    LogicalKeyboardKey.keyZ: GBAKey.b,
    LogicalKeyboardKey.keyX: GBAKey.y,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.r,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.l2,
    LogicalKeyboardKey.backspace: GBAKey.l2,
    LogicalKeyboardKey.space: GBAKey.b,
  };

  /// Intellivision / FreeIntv mapping.
  ///
  /// The disc uses the D-pad. A/B/Y/X match the on-screen controls:
  /// right action, left action, top action, repeat last keypad entry.
  /// The full 1-9 keypad needs right-stick analog input, but physical
  /// keyboards/gamepads can still send the discrete 0/5/Clear/Enter binds.
  static final Map<LogicalKeyboardKey, int> intvMapping = {
    LogicalKeyboardKey.arrowUp: GBAKey.up,
    LogicalKeyboardKey.arrowDown: GBAKey.down,
    LogicalKeyboardKey.arrowLeft: GBAKey.left,
    LogicalKeyboardKey.arrowRight: GBAKey.right,

    LogicalKeyboardKey.gameButtonA: GBAKey.a, // right action
    LogicalKeyboardKey.gameButtonB: GBAKey.b, // left action
    LogicalKeyboardKey.gameButtonY: GBAKey.y, // top action
    LogicalKeyboardKey.gameButtonX: GBAKey.x, // repeat last keypad entry
    LogicalKeyboardKey.gameButtonLeft1: GBAKey.l,
    LogicalKeyboardKey.gameButtonRight1: GBAKey.r,
    LogicalKeyboardKey.gameButtonLeft2: GBAKey.l2, // keypad Clear
    LogicalKeyboardKey.gameButtonRight2: GBAKey.r2, // keypad Enter
    LogicalKeyboardKey.gameButtonThumbLeft: GBAKey.l3, // keypad 0
    LogicalKeyboardKey.gameButtonThumbRight: GBAKey.r3, // keypad 5

    LogicalKeyboardKey.gameButtonStart: GBAKey.start,
    LogicalKeyboardKey.gameButtonSelect: GBAKey.select,

    LogicalKeyboardKey.keyZ: GBAKey.a,
    LogicalKeyboardKey.keyX: GBAKey.b,
    LogicalKeyboardKey.keyC: GBAKey.y,
    LogicalKeyboardKey.keyV: GBAKey.x,
    LogicalKeyboardKey.keyA: GBAKey.l,
    LogicalKeyboardKey.keyS: GBAKey.r,
    LogicalKeyboardKey.keyQ: GBAKey.l2,
    LogicalKeyboardKey.keyW: GBAKey.r2,
    LogicalKeyboardKey.digit0: GBAKey.l3,
    LogicalKeyboardKey.digit5: GBAKey.r3,
    LogicalKeyboardKey.enter: GBAKey.start,
    LogicalKeyboardKey.shiftRight: GBAKey.select,
    LogicalKeyboardKey.backspace: GBAKey.select,
    LogicalKeyboardKey.space: GBAKey.a,
  };

  /// Get the appropriate mapping for the given platform.
  /// NES and GB/GBC/GBA use defaultMapping (A, B, L, R, Start, Select, D-pad).
  /// SNES/NDS use the Nintendo 4-button diamond. PS1/MD/N64 need core-specific
  /// RetroPad labels.
  static Map<LogicalKeyboardKey, int> mappingForPlatform(
    GamePlatform platform,
  ) {
    return switch (platform) {
      GamePlatform.snes || GamePlatform.nds => nintendoFourButtonMapping,
      GamePlatform.ps1 => ps1Mapping,
      GamePlatform.md => mdMapping,
      GamePlatform.n64 => n64Mapping,
      GamePlatform.intv => intvMapping,
      _ => defaultMapping,
    };
  }

  /// Keys that indicate a real gamepad (not keyboard) is in use
  static final Set<LogicalKeyboardKey> _gamepadOnlyKeys = {
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.gameButtonB,
    LogicalKeyboardKey.gameButtonC,
    LogicalKeyboardKey.gameButtonX,
    LogicalKeyboardKey.gameButtonY,
    LogicalKeyboardKey.gameButtonZ,
    LogicalKeyboardKey.gameButtonLeft1,
    LogicalKeyboardKey.gameButtonRight1,
    LogicalKeyboardKey.gameButtonLeft2,
    LogicalKeyboardKey.gameButtonRight2,
    LogicalKeyboardKey.gameButtonStart,
    LogicalKeyboardKey.gameButtonSelect,
    LogicalKeyboardKey.gameButtonMode,
    LogicalKeyboardKey.gameButtonThumbLeft,
    LogicalKeyboardKey.gameButtonThumbRight,
  };

  /// Currently pressed physical keys (logical → GBA bitmask contribution)
  final Set<LogicalKeyboardKey> _activeKeys = {};

  /// Current computed bitmask of all pressed GBA keys
  int _pressedKeys = 0;

  /// Whether an actual gamepad controller has been detected this session
  bool _controllerDetected = false;

  Map<LogicalKeyboardKey, int> _mapping;

  GamepadMapper({Map<LogicalKeyboardKey, int>? mapping})
    : _mapping = mapping ?? defaultMapping;

  /// Update the key mapping (e.g. when switching between NES/SNES/GBA).
  /// Call when the game platform changes so the controller maps correctly.
  void updateMapping(Map<LogicalKeyboardKey, int> mapping) {
    _mapping = mapping;
    _rebuildBitmask();
  }

  /// Current GBA key bitmask from physical input
  int get keys => _pressedKeys;

  /// True once a real gamepad button (not keyboard) has been pressed
  bool get controllerDetected => _controllerDetected;

  /// Handle a [KeyEvent] from Flutter's focus/keyboard system.
  /// Returns `true` if the event was recognised and consumed.
  bool handleKeyEvent(KeyEvent event) {
    final logicalKey = event.logicalKey;
    if (!_mapping.containsKey(logicalKey)) return false;

    // Detect real gamepad hardware (not just keyboard)
    if (!_controllerDetected && _gamepadOnlyKeys.contains(logicalKey)) {
      _controllerDetected = true;
    }

    if (event is KeyDownEvent) {
      _activeKeys.add(logicalKey);
    } else if (event is KeyUpEvent) {
      _activeKeys.remove(logicalKey);
    }
    // KeyRepeatEvent — key already in _activeKeys, nothing to change

    // Rebuild bitmask from all active keys
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

  /// Reset all pressed keys (e.g. when focus lost or game paused)
  void reset() {
    _activeKeys.clear();
    _pressedKeys = 0;
  }

  /// Reset the controller-detected flag so a reconnecting gamepad
  /// can be detected afresh (e.g. after a Bluetooth disconnect).
  void resetDetection() {
    _controllerDetected = false;
  }
}
