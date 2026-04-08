import 'dart:convert';
import 'dart:ui';
import 'dart:math' as math;

class ButtonLayout {
  final double x; 
  final double y; 
  final double size; 

  const ButtonLayout({
    required this.x,
    required this.y,
    this.size = 1.0,
  });

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

  Offset toProportionalOffset(Size screenSize) {
    final unit = math.min(screenSize.width, screenSize.height);
    return Offset(
      x * unit,
      y * unit,
    );
  }

  Offset toOffset(Size screenSize) {
    return Offset(x * screenSize.width, y * screenSize.height);
  }

  static ButtonLayout fromOffset(Offset offset, Size screenSize) {
    return ButtonLayout(
      x: (offset.dx / screenSize.width).clamp(0.0, 1.0),
      y: (offset.dy / screenSize.height).clamp(0.0, 1.0),
    );
  }
  
  static ButtonLayout fromProportionalOffset(Offset offset, Size screenSize) {
    final unit = math.min(screenSize.width, screenSize.height);
    return ButtonLayout(
      x: (offset.dx / unit).clamp(0.0, 3.0), 
      y: (offset.dy / unit).clamp(0.0, 3.0),
    );
  }
}

class GamepadLayout {
  final ButtonLayout dpad;
  final ButtonLayout aButton;
  final ButtonLayout bButton;
  final ButtonLayout lButton;
  final ButtonLayout rButton;
  final ButtonLayout startButton;
  final ButtonLayout selectButton;

  final ButtonLayout? xButton;
  final ButtonLayout? yButton;

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
  });

  static const GamepadLayout defaultPortrait = GamepadLayout(
    dpad: ButtonLayout(
      x: 0.02,
      y: 0.62,
      size: 1.30,
    ),
    aButton: ButtonLayout(
      x: 0.78,
      y: 0.57,
      size: 1.20,
    ),
    bButton: ButtonLayout(
      x: 0.58,
      y: 0.72,
      size: 1.20,
    ),
    lButton: ButtonLayout(
      x: 0.02,
      y: 0.32,
      size: 1.10,
    ),
    rButton: ButtonLayout(
      x: 0.82,
      y: 0.32,
      size: 1.10,
    ),
    selectButton: ButtonLayout(
      x: 0.22,
      y: 0.42,
      size: 1.05,
    ),
    startButton: ButtonLayout(
      x: 0.62,
      y: 0.42,
      size: 1.05,
    ),
    xButton: ButtonLayout(
      x: 0.58,
      y: 0.57,
      size: 1.10,
    ),
    yButton: ButtonLayout(
      x: 0.78,
      y: 0.72,
      size: 1.10,
    ),
  );




  static const GamepadLayout defaultLandscape = GamepadLayout(
    dpad: ButtonLayout(
      x: 0.05,
      y: 0.40,
      size: 1.25,
    ),
    aButton: ButtonLayout(
      x: 0.35,
      y: 0.35,
      size: 1.15,
    ),
    bButton: ButtonLayout(
      x: 0.05,
      y: 0.52,
      size: 1.15,
    ),
    lButton: ButtonLayout(
      x: 0.20,
      y: 0.08,
      size: 1.05,
    ),
    rButton: ButtonLayout(
      x: 0.40,
      y: 0.08,
      size: 1.05,
    ),
    selectButton: ButtonLayout(
      x: 0.50,
      y: 0.85,
      size: 1.00,
    ),
    startButton: ButtonLayout(
      x: 0.20,
      y: 0.85,
      size: 1.00,
    ),
    xButton: ButtonLayout(
      x: 0.05,
      y: 0.35,
      size: 1.05,
    ),
    yButton: ButtonLayout(
      x: 0.35,
      y: 0.52,
      size: 1.05,
    ),
  );





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
          yButton == other.yButton;

  @override
  int get hashCode => Object.hash(
        dpad, aButton, bButton, lButton, rButton, startButton, selectButton,
        xButton, yButton);

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
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory GamepadLayout.fromJsonString(String json) =>
      GamepadLayout.fromJson(jsonDecode(json) as Map<String, dynamic>);
}

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
}

