import 'dart:convert';

import '../core/mgba_bindings.dart';

/// Position and size for a single gamepad button.
///
/// Coordinates are pure fractions of the FULL phone screen — the only
/// constant the layout is anchored to. (x, y) is the button's top-left
/// corner: x 0.0 = left screen border, 1.0 = right border; y 0.0 = top
/// border, 1.0 = bottom border. Positions never reference the game screen
/// or any other button, so moving one element never shifts another.
class ButtonLayout {
  final double x; // Top-left X as a fraction of screen width (0.0 - 1.0)
  final double y; // Top-left Y as a fraction of screen height (0.0 - 1.0)
  final double size; // Scale multiplier (1.0 = default)

  const ButtonLayout({required this.x, required this.y, this.size = 1.0});

  ButtonLayout copyWith({double? x, double? y, double? size}) {
    return ButtonLayout(
      x: x ?? this.x,
      y: y ?? this.y,
      size: size ?? this.size,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ButtonLayout &&
          x == other.x &&
          y == other.y &&
          size == other.size;

  @override
  int get hashCode => Object.hash(x, y, size);

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'size': size};

  factory ButtonLayout.fromJson(Map<String, dynamic> json) {
    return ButtonLayout(
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
      size: (json['size'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// Complete gamepad layout configuration
class GamepadLayout {
  final ButtonLayout dpad;
  final ButtonLayout aButton;
  final ButtonLayout bButton;
  final ButtonLayout lButton;
  final ButtonLayout rButton;
  final ButtonLayout startButton;
  final ButtonLayout selectButton;

  /// SNES face buttons (optional — only used when platform is SNES).
  final ButtonLayout? xButton;
  final ButtonLayout? yButton;

  /// PS1 trigger buttons (optional — only used when platform is PS1).
  /// Null on saved layouts created before L2/R2 became editable; callers fall
  /// back to a derived default position in that case.
  final ButtonLayout? l2Button;
  final ButtonLayout? r2Button;

  const GamepadLayout({
    required this.dpad,
    required this.aButton,
    required this.bButton,
    required this.lButton,
    required this.rButton,
    required this.startButton,
    required this.selectButton,
    this.xButton,
    this.yButton,
    this.l2Button,
    this.r2Button,
  });

  /// Portrait layout — every value is a fraction of the FULL screen.
  /// The game sits in the top ~45%; controls live in the lower half. None of
  /// these positions reference the game screen, so they never move when the
  /// game size/position changes, and each button is independent of the others.
  static const GamepadLayout defaultPortrait = GamepadLayout(
    // D-pad: lower-left.
    dpad: ButtonLayout(x: 0.04, y: 0.72, size: 1.30),

    // A button: upper-right of the face cluster.
    aButton: ButtonLayout(x: 0.78, y: 0.69, size: 1.20),

    // B button: lower-left of the face cluster.
    bButton: ButtonLayout(x: 0.56, y: 0.82, size: 1.20),

    // L shoulder: left side, above the d-pad.
    lButton: ButtonLayout(x: 0.04, y: 0.54, size: 1.10),

    // R shoulder: right side, above the face cluster.
    rButton: ButtonLayout(x: 0.81, y: 0.54, size: 1.10),

    // Select: center-left.
    selectButton: ButtonLayout(x: 0.23, y: 0.60, size: 1.05),

    // Start: center-right.
    startButton: ButtonLayout(x: 0.62, y: 0.60, size: 1.05),

    // SNES X: upper-left of the face cluster (grid: X A / B Y).
    xButton: ButtonLayout(x: 0.56, y: 0.69, size: 1.10),

    // SNES Y: lower-right of the face cluster (grid: X A / B Y).
    yButton: ButtonLayout(x: 0.78, y: 0.82, size: 1.10),
  );

  /// NDS Portrait layout — diamond ABXY pattern like a real DS.
  /// The controls are spaced to avoid collision resolution flattening
  /// the diamond or pushing Start/Select below the clusters.
  ///
  /// Diamond arrangement (DS standard):
  ///       X
  ///    Y     A
  ///       B
  static const GamepadLayout defaultNdsPortrait = GamepadLayout(
    // D-pad: lower-left, overlaying the bottom screen edge.
    dpad: ButtonLayout(x: 0.03, y: 0.79, size: 1.00),

    // Face buttons in diamond pattern (right side)
    //       X (top)
    //    Y     A (middle)
    //       B (bottom)
    xButton: ButtonLayout(x: 0.73, y: 0.71, size: 0.85),
    yButton: ButtonLayout(x: 0.60, y: 0.81, size: 0.85),
    aButton: ButtonLayout(x: 0.86, y: 0.81, size: 0.85),
    bButton: ButtonLayout(x: 0.73, y: 0.91, size: 0.85),

    // L shoulder: left, above the d-pad.
    lButton: ButtonLayout(x: 0.04, y: 0.62, size: 1.00),

    // R shoulder: right, above the face cluster.
    rButton: ButtonLayout(x: 0.81, y: 0.62, size: 1.00),

    // Select/Start: center, tucked below L/R.
    selectButton: ButtonLayout(x: 0.33, y: 0.68, size: 0.70),

    startButton: ButtonLayout(x: 0.52, y: 0.68, size: 0.70),
  );

  /// NDS Landscape layout — full-width game with buttons overlaid at
  /// the screen edges. NDS landscape uses absolute screen coordinates
  /// instead of the generic side-zone mapper.
  ///
  /// Diamond arrangement:
  ///       X
  ///    Y     A
  ///       B
  static const GamepadLayout defaultNdsLandscape = GamepadLayout(
    // D-pad: left edge, vertically centered.
    dpad: ButtonLayout(x: 0.03, y: 0.55, size: 0.90),

    // Face buttons in diamond pattern (right edge)
    xButton: ButtonLayout(x: 0.86, y: 0.40, size: 0.85),
    yButton: ButtonLayout(x: 0.80, y: 0.55, size: 0.85),
    aButton: ButtonLayout(x: 0.92, y: 0.55, size: 0.85),
    bButton: ButtonLayout(x: 0.86, y: 0.69, size: 0.85),

    // L shoulder: top-left.
    lButton: ButtonLayout(x: 0.10, y: 0.21, size: 0.90),

    // R shoulder: top-right.
    rButton: ButtonLayout(x: 0.85, y: 0.21, size: 0.90),

    // Select/Start: upper center, tucked below L/R.
    selectButton: ButtonLayout(x: 0.23, y: 0.36, size: 0.85),

    startButton: ButtonLayout(x: 0.73, y: 0.36, size: 0.85),
  );

  /// Landscape layout — every value is a fraction of the FULL screen. The
  /// game is centered; controls hug the left and right phone borders and
  /// overlay the game translucently. Positions are independent of the game
  /// rectangle and of each other.
  static const GamepadLayout defaultLandscape = GamepadLayout(
    // D-pad: left side, vertically centered.
    dpad: ButtonLayout(x: 0.04, y: 0.38, size: 1.25),

    // A button: right of the face cluster.
    aButton: ButtonLayout(x: 0.90, y: 0.46, size: 1.15),

    // B button: bottom of the face cluster.
    bButton: ButtonLayout(x: 0.85, y: 0.66, size: 1.15),

    // L shoulder: top-left.
    lButton: ButtonLayout(x: 0.05, y: 0.16, size: 1.05),

    // R shoulder: top-right.
    rButton: ButtonLayout(x: 0.90, y: 0.16, size: 1.05),

    // Select: bottom-left.
    selectButton: ButtonLayout(x: 0.05, y: 0.84, size: 1.00),

    // Start: bottom-right.
    startButton: ButtonLayout(x: 0.90, y: 0.86, size: 1.00),

    // SNES X: top of the face cluster (diamond: X top, Y/A mid, B bottom).
    xButton: ButtonLayout(x: 0.85, y: 0.29, size: 1.05),

    // SNES Y: left of the face cluster.
    yButton: ButtonLayout(x: 0.78, y: 0.46, size: 1.05),
  );

  /// Two-button console layouts (GB/GBC, NES, Sega 8-bit, PCE, NGP,
  /// WonderSwan, A2600, fantasy consoles). L/R and X/Y are intentionally still
  /// populated because the layout object is shared, but VirtualGamepad hides
  /// the slots those platforms do not expose.
  static const GamepadLayout defaultTwoButtonPortrait = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.72, size: 1.30),
    aButton: ButtonLayout(x: 0.78, y: 0.70, size: 1.20),
    bButton: ButtonLayout(x: 0.56, y: 0.81, size: 1.20),
    lButton: ButtonLayout(x: 0.04, y: 0.54, size: 1.10),
    rButton: ButtonLayout(x: 0.81, y: 0.54, size: 1.10),
    selectButton: ButtonLayout(x: 0.31, y: 0.62, size: 1.00),
    startButton: ButtonLayout(x: 0.53, y: 0.62, size: 1.00),
  );

  static const GamepadLayout defaultTwoButtonLandscape = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.40, size: 1.25),
    aButton: ButtonLayout(x: 0.90, y: 0.42, size: 1.15),
    bButton: ButtonLayout(x: 0.82, y: 0.62, size: 1.15),
    lButton: ButtonLayout(x: 0.05, y: 0.16, size: 1.05),
    rButton: ButtonLayout(x: 0.90, y: 0.16, size: 1.05),
    selectButton: ButtonLayout(x: 0.38, y: 0.84, size: 0.95),
    startButton: ButtonLayout(x: 0.52, y: 0.84, size: 0.95),
  );

  /// Nintendo 64 uses the generic visible slots, but its Select slot is
  /// labelled Z in VirtualGamepad. Keep Z near the left trigger by default
  /// rather than down with SNES-style Select.
  static const GamepadLayout defaultN64Portrait = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.72, size: 1.30),
    aButton: ButtonLayout(x: 0.78, y: 0.70, size: 1.20),
    bButton: ButtonLayout(x: 0.58, y: 0.82, size: 1.10),
    lButton: ButtonLayout(x: 0.04, y: 0.56, size: 1.05),
    rButton: ButtonLayout(x: 0.81, y: 0.56, size: 1.05),
    selectButton: ButtonLayout(x: 0.28, y: 0.61, size: 0.95), // Z
    startButton: ButtonLayout(x: 0.52, y: 0.61, size: 1.00),
  );

  static const GamepadLayout defaultN64Landscape = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.40, size: 1.25),
    aButton: ButtonLayout(x: 0.90, y: 0.46, size: 1.15),
    bButton: ButtonLayout(x: 0.78, y: 0.66, size: 1.05),
    lButton: ButtonLayout(x: 0.05, y: 0.18, size: 1.00),
    rButton: ButtonLayout(x: 0.90, y: 0.18, size: 1.00),
    selectButton: ButtonLayout(x: 0.08, y: 0.33, size: 0.95), // Z
    startButton: ButtonLayout(x: 0.88, y: 0.84, size: 0.95),
  );

  /// PlayStation keeps the four face-button diamond, with L/R lowered enough
  /// that the derived L2/R2 buttons have room above them in landscape.
  static const GamepadLayout defaultPs1Portrait = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.72, size: 1.30),
    xButton: ButtonLayout(x: 0.56, y: 0.69, size: 1.10),
    aButton: ButtonLayout(x: 0.78, y: 0.69, size: 1.20),
    bButton: ButtonLayout(x: 0.56, y: 0.82, size: 1.20),
    yButton: ButtonLayout(x: 0.78, y: 0.82, size: 1.10),
    lButton: ButtonLayout(x: 0.04, y: 0.56, size: 1.00),
    rButton: ButtonLayout(x: 0.81, y: 0.56, size: 1.00),
    selectButton: ButtonLayout(x: 0.23, y: 0.62, size: 0.95),
    startButton: ButtonLayout(x: 0.62, y: 0.62, size: 0.95),
    // L2/R2 triggers sit clearly above the L/R shoulders by default.
    l2Button: ButtonLayout(x: 0.04, y: 0.47, size: 0.90),
    r2Button: ButtonLayout(x: 0.81, y: 0.47, size: 0.90),
  );

  static const GamepadLayout defaultPs1Landscape = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.40, size: 1.25),
    xButton: ButtonLayout(x: 0.85, y: 0.36, size: 1.05),
    yButton: ButtonLayout(x: 0.78, y: 0.54, size: 1.05),
    aButton: ButtonLayout(x: 0.90, y: 0.54, size: 1.15),
    bButton: ButtonLayout(x: 0.85, y: 0.73, size: 1.15),
    lButton: ButtonLayout(x: 0.05, y: 0.28, size: 0.95),
    rButton: ButtonLayout(x: 0.90, y: 0.28, size: 0.95),
    selectButton: ButtonLayout(x: 0.05, y: 0.93, size: 0.95),
    startButton: ButtonLayout(x: 0.90, y: 0.93, size: 0.95),
    // L2/R2 triggers sit clearly above the L/R shoulders by default.
    l2Button: ButtonLayout(x: 0.05, y: 0.16, size: 0.90),
    r2Button: ButtonLayout(x: 0.90, y: 0.16, size: 0.90),
  );

  /// Sega Genesis / Mega Drive layouts — the six face buttons are arranged as
  /// a real 6-button pad's 2×3 grid (X Y Z on top, A B C on the bottom row),
  /// all rendered as uniform circles. The slot→button remap lives in
  /// VirtualGamepad (`_slotBinding`): the L/R *slots* carry X/Y, the X/Y slots
  /// carry C/Z, and Select carries Mode. Coordinates are full-screen fractions
  /// like every other layout.
  ///
  ///   X  Y  Z   ← L-slot  R-slot  Y-slot
  ///   A  B  C   ← A-slot  B-slot  X-slot
  static const GamepadLayout defaultMdLandscape = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.40, size: 1.25),
    // Top row: X Y Z.
    lButton: ButtonLayout(x: 0.72, y: 0.34, size: 0.85), // X
    rButton: ButtonLayout(x: 0.81, y: 0.34, size: 0.85), // Y
    yButton: ButtonLayout(x: 0.90, y: 0.34, size: 0.85), // Z
    // Bottom row: A B C.
    aButton: ButtonLayout(x: 0.72, y: 0.58, size: 0.85), // A
    bButton: ButtonLayout(x: 0.81, y: 0.58, size: 0.85), // B
    xButton: ButtonLayout(x: 0.90, y: 0.58, size: 0.85), // C
    // Mode + Start, bottom centre-right.
    selectButton: ButtonLayout(x: 0.60, y: 0.86, size: 0.85), // MODE
    startButton: ButtonLayout(x: 0.73, y: 0.86, size: 0.85),
  );

  ///   X  Y  Z
  ///   A  B  C
  static const GamepadLayout defaultMdPortrait = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.72, size: 1.30),
    // Top row: X Y Z.
    lButton: ButtonLayout(x: 0.46, y: 0.66, size: 0.80), // X
    rButton: ButtonLayout(x: 0.64, y: 0.66, size: 0.80), // Y
    yButton: ButtonLayout(x: 0.82, y: 0.66, size: 0.80), // Z
    // Bottom row: A B C.
    aButton: ButtonLayout(x: 0.46, y: 0.78, size: 0.80), // A
    bButton: ButtonLayout(x: 0.64, y: 0.78, size: 0.80), // B
    xButton: ButtonLayout(x: 0.82, y: 0.78, size: 0.80), // C
    // Mode + Start, lower centre.
    selectButton: ButtonLayout(x: 0.45, y: 0.90, size: 0.75), // MODE
    startButton: ButtonLayout(x: 0.64, y: 0.90, size: 0.75),
  );

  /// Mattel Intellivision (FreeIntv). The disc maps to the d-pad and the
  /// console's three side action buttons plus the keypad are surfaced as a
  /// full face/shoulder set, matching the core's in-game help screen:
  ///   A → right action   B → left action   Y → top action
  ///   X → repeat last keypad entry         L/R → open the keypad
  /// L/R bring up FreeIntv's built-in keypad; move the cursor with the disc and
  /// press a face button to enter a digit. (Physical L2/R2 = keypad Clear/Enter.)
  /// Face buttons use the SNES-style 2×2 grid:  X A / B Y.
  static const GamepadLayout defaultIntvPortrait = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.72, size: 1.30),
    xButton: ButtonLayout(x: 0.56, y: 0.69, size: 1.05),
    aButton: ButtonLayout(x: 0.78, y: 0.69, size: 1.20),
    bButton: ButtonLayout(x: 0.56, y: 0.82, size: 1.20),
    yButton: ButtonLayout(x: 0.78, y: 0.82, size: 1.05),
    lButton: ButtonLayout(x: 0.04, y: 0.54, size: 1.10),
    rButton: ButtonLayout(x: 0.81, y: 0.54, size: 1.10),
    selectButton: ButtonLayout(x: 0.23, y: 0.60, size: 1.05),
    startButton: ButtonLayout(x: 0.62, y: 0.60, size: 1.05),
  );

  static const GamepadLayout defaultIntvLandscape = GamepadLayout(
    dpad: ButtonLayout(x: 0.04, y: 0.38, size: 1.25),
    xButton: ButtonLayout(x: 0.85, y: 0.29, size: 1.00),
    aButton: ButtonLayout(x: 0.90, y: 0.46, size: 1.15),
    bButton: ButtonLayout(x: 0.85, y: 0.66, size: 1.15),
    yButton: ButtonLayout(x: 0.78, y: 0.46, size: 1.00),
    lButton: ButtonLayout(x: 0.05, y: 0.16, size: 1.05),
    rButton: ButtonLayout(x: 0.90, y: 0.16, size: 1.05),
    selectButton: ButtonLayout(x: 0.05, y: 0.84, size: 1.00),
    startButton: ButtonLayout(x: 0.90, y: 0.86, size: 1.00),
  );

  static GamepadLayout defaultForPlatform(
    GamePlatform platform, {
    required bool landscape,
  }) {
    return switch (platform) {
      GamePlatform.nds =>
        landscape
            ? GamepadLayout.defaultNdsLandscape
            : GamepadLayout.defaultNdsPortrait,
      GamePlatform.md =>
        landscape
            ? GamepadLayout.defaultMdLandscape
            : GamepadLayout.defaultMdPortrait,
      GamePlatform.n64 =>
        landscape
            ? GamepadLayout.defaultN64Landscape
            : GamepadLayout.defaultN64Portrait,
      GamePlatform.ps1 =>
        landscape
            ? GamepadLayout.defaultPs1Landscape
            : GamepadLayout.defaultPs1Portrait,
      GamePlatform.intv =>
        landscape
            ? GamepadLayout.defaultIntvLandscape
            : GamepadLayout.defaultIntvPortrait,
      GamePlatform.gb ||
      GamePlatform.gbc ||
      GamePlatform.nes ||
      GamePlatform.sms ||
      GamePlatform.gg ||
      GamePlatform.sg1000 ||
      GamePlatform.pce ||
      GamePlatform.sgx ||
      GamePlatform.ngp ||
      GamePlatform.ws ||
      GamePlatform.wsc ||
      GamePlatform.a2600 ||
      GamePlatform.tic80 ||
      GamePlatform.pico8 =>
        landscape
            ? GamepadLayout.defaultTwoButtonLandscape
            : GamepadLayout.defaultTwoButtonPortrait,
      GamePlatform.gba ||
      GamePlatform.snes ||
      GamePlatform.vb ||
      GamePlatform.unknown =>
        landscape
            ? GamepadLayout.defaultLandscape
            : GamepadLayout.defaultPortrait,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GamepadLayout &&
          dpad == other.dpad &&
          aButton == other.aButton &&
          bButton == other.bButton &&
          lButton == other.lButton &&
          rButton == other.rButton &&
          startButton == other.startButton &&
          selectButton == other.selectButton &&
          xButton == other.xButton &&
          yButton == other.yButton &&
          l2Button == other.l2Button &&
          r2Button == other.r2Button;

  @override
  int get hashCode => Object.hash(
    dpad,
    aButton,
    bButton,
    lButton,
    rButton,
    startButton,
    selectButton,
    xButton,
    yButton,
    l2Button,
    r2Button,
  );

  GamepadLayout copyWith({
    ButtonLayout? dpad,
    ButtonLayout? aButton,
    ButtonLayout? bButton,
    ButtonLayout? lButton,
    ButtonLayout? rButton,
    ButtonLayout? startButton,
    ButtonLayout? selectButton,
    ButtonLayout? xButton,
    ButtonLayout? yButton,
    ButtonLayout? l2Button,
    ButtonLayout? r2Button,
  }) {
    return GamepadLayout(
      dpad: dpad ?? this.dpad,
      aButton: aButton ?? this.aButton,
      bButton: bButton ?? this.bButton,
      lButton: lButton ?? this.lButton,
      rButton: rButton ?? this.rButton,
      startButton: startButton ?? this.startButton,
      selectButton: selectButton ?? this.selectButton,
      xButton: xButton ?? this.xButton,
      yButton: yButton ?? this.yButton,
      l2Button: l2Button ?? this.l2Button,
      r2Button: r2Button ?? this.r2Button,
    );
  }

  Map<String, dynamic> toJson() => {
    'dpad': dpad.toJson(),
    'aButton': aButton.toJson(),
    'bButton': bButton.toJson(),
    'lButton': lButton.toJson(),
    'rButton': rButton.toJson(),
    'startButton': startButton.toJson(),
    'selectButton': selectButton.toJson(),
    if (xButton != null) 'xButton': xButton!.toJson(),
    if (yButton != null) 'yButton': yButton!.toJson(),
    if (l2Button != null) 'l2Button': l2Button!.toJson(),
    if (r2Button != null) 'r2Button': r2Button!.toJson(),
  };

  factory GamepadLayout.fromJson(Map<String, dynamic> json) {
    return GamepadLayout(
      dpad: json['dpad'] != null
          ? ButtonLayout.fromJson(json['dpad'])
          : GamepadLayout.defaultPortrait.dpad,
      aButton: json['aButton'] != null
          ? ButtonLayout.fromJson(json['aButton'])
          : GamepadLayout.defaultPortrait.aButton,
      bButton: json['bButton'] != null
          ? ButtonLayout.fromJson(json['bButton'])
          : GamepadLayout.defaultPortrait.bButton,
      lButton: json['lButton'] != null
          ? ButtonLayout.fromJson(json['lButton'])
          : GamepadLayout.defaultPortrait.lButton,
      rButton: json['rButton'] != null
          ? ButtonLayout.fromJson(json['rButton'])
          : GamepadLayout.defaultPortrait.rButton,
      startButton: json['startButton'] != null
          ? ButtonLayout.fromJson(json['startButton'])
          : GamepadLayout.defaultPortrait.startButton,
      selectButton: json['selectButton'] != null
          ? ButtonLayout.fromJson(json['selectButton'])
          : GamepadLayout.defaultPortrait.selectButton,
      xButton: json['xButton'] != null
          ? ButtonLayout.fromJson(json['xButton'])
          : null,
      yButton: json['yButton'] != null
          ? ButtonLayout.fromJson(json['yButton'])
          : null,
      l2Button: json['l2Button'] != null
          ? ButtonLayout.fromJson(json['l2Button'])
          : null,
      r2Button: json['r2Button'] != null
          ? ButtonLayout.fromJson(json['r2Button'])
          : null,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory GamepadLayout.fromJsonString(String json) =>
      GamepadLayout.fromJson(jsonDecode(json) as Map<String, dynamic>);
}

/// Button identifiers for editing
enum GamepadButton {
  dpad,
  aButton,
  bButton,
  lButton,
  rButton,
  startButton,
  selectButton,
  xButton,
  yButton,
  l2Button,
  r2Button,
}
