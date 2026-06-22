import 'package:flutter/material.dart';

import '../utils/theme.dart';

/// Available gamepad visual themes
enum GamepadSkinType {
  classic,
  retro,
  minimal,
  neon,
}

/// Human-readable names for each skin
extension GamepadSkinTypeName on GamepadSkinType {
  String get label => switch (this) {
    GamepadSkinType.classic => 'Classic',
    GamepadSkinType.retro => 'Retro',
    GamepadSkinType.minimal => 'Minimal',
    GamepadSkinType.neon => 'Neon',
  };

  String get description => switch (this) {
    GamepadSkinType.classic => 'Solid filled buttons',
    GamepadSkinType.retro => 'Game Boy grey',
    GamepadSkinType.minimal => 'Outlines only',
    GamepadSkinType.neon => 'Glow effects',
  };

  IconData get icon => switch (this) {
    GamepadSkinType.classic => Icons.gamepad,
    GamepadSkinType.retro => Icons.sports_esports,
    GamepadSkinType.minimal => Icons.crop_square,
    GamepadSkinType.neon => Icons.flare,
  };
}

/// Resolved visual parameters for a gamepad skin.
/// Call [GamepadSkinData.resolve] at build time so it picks up the current
/// theme automatically via the provided [AppColorTheme].
class GamepadSkinData {
  // ── Button normal state ──
  final Color buttonFill;
  final Color buttonBorder;
  final double buttonBorderWidth;
  final Color textNormal;

  // ── Button pressed state ──
  final Color buttonFillPressed;
  final Color buttonBorderPressed;
  final Color textPressed;

  // ── D-pad ──
  final Color dpadBackground;
  final Color dpadBorder;
  final double dpadBorderWidth;
  final Color dpadCenter;
  final double dpadRadius;

  // ── Joystick ──
  final Color joystickBg;
  final Color joystickBorder;
  final double joystickBorderWidth;
  final Color stickColor;
  final Color stickBorder;
  final Color? stickHighlight; // inner dot / gradient highlight

  // ── Shadows / glow ──
  final List<BoxShadow> normalShadows;
  final List<BoxShadow> pressedShadows;

  // ── Shape ──
  final double buttonRadius;

  const GamepadSkinData({
    required this.buttonFill,
    required this.buttonBorder,
    required this.buttonBorderWidth,
    required this.textNormal,
    required this.buttonFillPressed,
    required this.buttonBorderPressed,
    required this.textPressed,
    required this.dpadBackground,
    required this.dpadBorder,
    required this.dpadBorderWidth,
    required this.dpadCenter,
    required this.dpadRadius,
    required this.joystickBg,
    required this.joystickBorder,
    required this.joystickBorderWidth,
    required this.stickColor,
    required this.stickBorder,
    this.stickHighlight,
    this.normalShadows = const [],
    this.pressedShadows = const [],
    required this.buttonRadius,
  });

  /// Resolve a skin type into concrete paint parameters using the given theme.
  static GamepadSkinData resolve(GamepadSkinType type, AppColorTheme colors) {
    return switch (type) {
      GamepadSkinType.classic => _classic(colors),
      GamepadSkinType.retro => _retro(),
      GamepadSkinType.minimal => _minimal(colors),
      GamepadSkinType.neon => _neon(colors),
    };
  }

  // ──────────────────────────────────────────────
  // Classic  — solid filled surfaces (current look)
  // ──────────────────────────────────────────────
  static GamepadSkinData _classic(AppColorTheme colors) {
    return GamepadSkinData(
      buttonFill: colors.surface.withAlpha(220),
      buttonBorder: colors.surfaceLight,
      buttonBorderWidth: 1.5,
      textNormal: colors.textSecondary,
      buttonFillPressed: colors.primary.withAlpha(230),
      buttonBorderPressed: colors.primary,
      textPressed: colors.textPrimary,
      dpadBackground: colors.surface.withAlpha(210),
      dpadBorder: colors.surfaceLight,
      dpadBorderWidth: 1.5,
      dpadCenter: colors.backgroundMedium,
      dpadRadius: 18,
      joystickBg: colors.surface.withAlpha(200),
      joystickBorder: colors.surfaceLight,
      joystickBorderWidth: 2,
      stickColor: colors.primary.withAlpha(230),
      stickBorder: colors.primary,
      stickHighlight: colors.backgroundLight.withAlpha(100),
      buttonRadius: 12,
    );
  }

  // ──────────────────────────────────────────────
  // Retro  — Game Boy grey, thick dark borders
  // ──────────────────────────────────────────────
  static GamepadSkinData _retro() {
    const greyLight = Color(0xFFC4C4B8);
    const greyMed = Color(0xFF9E9E92);
    const greyDark = Color(0xFF5A5A50);
    const greyBorder = Color(0xFF3A3A32);
    const greyPressed = Color(0xFF7A7A6E);
    const greyText = Color(0xFF3A3A32);
    const greyTextPressed = Color(0xFFE8E8DC);
    const greyCenter = Color(0xFF6A6A5E);

    return GamepadSkinData(
      buttonFill: greyMed.withAlpha(220),
      buttonBorder: greyBorder,
      buttonBorderWidth: 2.5,
      textNormal: greyText,
      buttonFillPressed: greyDark.withAlpha(240),
      buttonBorderPressed: greyBorder,
      textPressed: greyTextPressed,
      dpadBackground: greyLight.withAlpha(210),
      dpadBorder: greyBorder,
      dpadBorderWidth: 2.5,
      dpadCenter: greyCenter,
      dpadRadius: 10,
      joystickBg: greyLight.withAlpha(200),
      joystickBorder: greyBorder,
      joystickBorderWidth: 2.5,
      stickColor: greyDark,
      stickBorder: greyBorder,
      stickHighlight: greyPressed.withAlpha(80),
      buttonRadius: 8,
      normalShadows: [
        BoxShadow(
          color: Colors.black.withAlpha(50),
          blurRadius: 4,
          offset: const Offset(1, 2),
        ),
      ],
      pressedShadows: [
        BoxShadow(
          color: Colors.black.withAlpha(30),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
      ],
    );
  }

  // ──────────────────────────────────────────────
  // Minimal  — outlines only, transparent fills
  // ──────────────────────────────────────────────
  static GamepadSkinData _minimal(AppColorTheme colors) {
    return GamepadSkinData(
      buttonFill: Colors.transparent,
      buttonBorder: colors.textSecondary.withAlpha(120),
      buttonBorderWidth: 1.0,
      textNormal: colors.textSecondary.withAlpha(140),
      buttonFillPressed: colors.primary.withAlpha(60),
      buttonBorderPressed: colors.primary.withAlpha(200),
      textPressed: colors.textPrimary,
      dpadBackground: Colors.transparent,
      dpadBorder: colors.textSecondary.withAlpha(80),
      dpadBorderWidth: 1.0,
      dpadCenter: colors.textSecondary.withAlpha(40),
      dpadRadius: 14,
      joystickBg: Colors.transparent,
      joystickBorder: colors.textSecondary.withAlpha(100),
      joystickBorderWidth: 1.0,
      stickColor: colors.primary.withAlpha(100),
      stickBorder: colors.primary.withAlpha(180),
      stickHighlight: null,
      buttonRadius: 12,
    );
  }

  // ──────────────────────────────────────────────
  // Neon  — dark fills, bright borders, glow shadows
  // ──────────────────────────────────────────────
  static GamepadSkinData _neon(AppColorTheme colors) {
    final neonColor = colors.accent;
    final neonAlt = colors.primary;

    return GamepadSkinData(
      buttonFill: Colors.black.withAlpha(160),
      buttonBorder: neonColor.withAlpha(180),
      buttonBorderWidth: 2.0,
      textNormal: neonColor.withAlpha(200),
      buttonFillPressed: neonAlt.withAlpha(80),
      buttonBorderPressed: neonColor,
      textPressed: neonColor,
      dpadBackground: Colors.black.withAlpha(140),
      dpadBorder: neonColor.withAlpha(150),
      dpadBorderWidth: 2.0,
      dpadCenter: neonColor.withAlpha(40),
      dpadRadius: 16,
      joystickBg: Colors.black.withAlpha(140),
      joystickBorder: neonColor.withAlpha(160),
      joystickBorderWidth: 2.0,
      stickColor: neonAlt.withAlpha(200),
      stickBorder: neonColor,
      stickHighlight: neonColor.withAlpha(60),
      buttonRadius: 12,
      normalShadows: [
        BoxShadow(
          color: neonColor.withAlpha(40),
          blurRadius: 8,
          spreadRadius: 1,
        ),
      ],
      pressedShadows: [
        BoxShadow(
          color: neonColor.withAlpha(100),
          blurRadius: 16,
          spreadRadius: 3,
        ),
        BoxShadow(
          color: neonColor.withAlpha(60),
          blurRadius: 24,
          spreadRadius: 6,
        ),
      ],
    );
  }
}
