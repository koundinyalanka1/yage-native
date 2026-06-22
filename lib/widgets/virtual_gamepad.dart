import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mgba_bindings.dart';
import '../models/gamepad_layout.dart';
import '../models/gamepad_skin.dart';
import '../utils/theme.dart';

/// Virtual gamepad for touch input
class VirtualGamepad extends StatefulWidget {
  final void Function(int keys) onKeysChanged;
  final void Function(double x, double y)? onAnalogChanged;
  final void Function(double x, double y)? onRightAnalogChanged;
  final double opacity;
  final double scale;
  final bool enableVibration;
  final GamepadLayout layout;
  final bool editMode;
  final void Function(GamepadLayout)? onLayoutChanged;
  final bool useJoystick; // true = joystick, false = d-pad
  final GamepadSkinType skin;

  /// Current platform — controls which buttons are shown.
  ///   • Two-button consoles: A, B, Start, Select, D-pad
  ///   • SNES/NDS/PS1/MD: extra face buttons where the console has them
  ///   • GBA/N64/VB: shoulder buttons in addition to A/B
  final GamePlatform platform;

  const VirtualGamepad({
    super.key,
    required this.onKeysChanged,
    this.onAnalogChanged,
    this.onRightAnalogChanged,
    this.opacity = 0.7,
    this.scale = 1.0,
    this.enableVibration = true,
    required this.layout,
    this.editMode = false,
    this.onLayoutChanged,
    this.useJoystick = false,
    this.skin = GamepadSkinType.classic,
    this.platform = GamePlatform.gba,
  });

  @override
  State<VirtualGamepad> createState() => _VirtualGamepadState();
}

/// The on-screen label and the GBAKey bit a given face/shoulder slot should
/// emit for the current platform.
///
/// Every button bit travels through the native input callback as a 1:1
/// RetroPad button (A->JOYPAD_A, B->JOYPAD_B, etc.), but each libretro core
/// then remaps the RetroPad to its own console differently. Genesis Plus GX
/// and mupen64plus in particular scramble the face buttons, so a slot's
/// correct key is platform-specific. This keeps the printed label and the bit
/// it sends in agreement.
///
/// Mappings verified against upstream core sources / libretro docs:
/// - Genesis Plus GX: JOYPAD_Y->A, B->B, A->C, L->X, X->Y, R->Z,
///   SELECT->Mode.
/// - mupen64plus-next: JOYPAD_B->N64 A, Y->N64 B, L2->Z, L->L, R->R.
({String label, int key}) virtualGamepadSlotBinding(
  GamePlatform platform,
  GamepadButton slot,
) {
  switch (platform) {
    // Sega Genesis / Mega Drive. Three-button games use A/B/C; six-button
    // games add X/Y/Z. Mode sits on the Select slot.
    case GamePlatform.md:
      switch (slot) {
        case GamepadButton.aButton:
          return (label: 'A', key: GBAKey.y);
        case GamepadButton.bButton:
          return (label: 'B', key: GBAKey.b);
        case GamepadButton.xButton:
          return (label: 'C', key: GBAKey.a);
        case GamepadButton.yButton:
          return (label: 'Z', key: GBAKey.r);
        case GamepadButton.lButton:
          return (label: 'X', key: GBAKey.l);
        case GamepadButton.rButton:
          return (label: 'Y', key: GBAKey.x);
        case GamepadButton.selectButton:
          return (label: 'MODE', key: GBAKey.select);
        case GamepadButton.startButton:
          return (label: 'START', key: GBAKey.start);
        // Mega Drive has no L2/R2; the slots are unused.
        case GamepadButton.l2Button:
        case GamepadButton.r2Button:
        case GamepadButton.dpad:
          return (label: '', key: 0);
      }
    // Nintendo 64. A/B corrected: the core puts N64 A on RetroPad B and N64
    // B on RetroPad Y. Z is a trigger on JOYPAD_L2, not Select.
    case GamePlatform.n64:
      switch (slot) {
        case GamepadButton.aButton:
          return (label: 'A', key: GBAKey.b);
        case GamepadButton.bButton:
          return (label: 'B', key: GBAKey.y);
        case GamepadButton.lButton:
          return (label: 'L', key: GBAKey.l);
        case GamepadButton.rButton:
          return (label: 'R', key: GBAKey.r);
        case GamepadButton.selectButton:
          return (label: 'Z', key: GBAKey.l2);
        case GamepadButton.startButton:
          return (label: 'START', key: GBAKey.start);
        // N64 routes Z to the Select slot; L2/R2 slots are unused.
        case GamepadButton.xButton:
        case GamepadButton.yButton:
        case GamepadButton.l2Button:
        case GamepadButton.r2Button:
        case GamepadButton.dpad:
          return (label: '', key: 0);
      }
    // RetroPad-identity cores (GB/GBC/GBA/NES/SNES/PS1/NDS, etc.).
    default:
      switch (slot) {
        case GamepadButton.aButton:
          return (label: 'A', key: GBAKey.a);
        case GamepadButton.bButton:
          return (label: 'B', key: GBAKey.b);
        case GamepadButton.xButton:
          return (label: 'X', key: GBAKey.x);
        case GamepadButton.yButton:
          return (label: 'Y', key: GBAKey.y);
        case GamepadButton.lButton:
          return (label: 'L', key: GBAKey.l);
        case GamepadButton.rButton:
          return (label: 'R', key: GBAKey.r);
        case GamepadButton.startButton:
          return (label: 'START', key: GBAKey.start);
        case GamepadButton.selectButton:
          return (label: 'SELECT', key: GBAKey.select);
        // PS1 triggers (RetroPad L2/R2). Other RetroPad-identity platforms
        // simply never render these slots (gated by showL2R2).
        case GamepadButton.l2Button:
          return (label: 'L2', key: GBAKey.l2);
        case GamepadButton.r2Button:
          return (label: 'R2', key: GBAKey.r2);
        case GamepadButton.dpad:
          return (label: '', key: 0);
      }
  }
}

class _VirtualGamepadState extends State<VirtualGamepad> {
  int _currentKeys = 0;
  GamepadButton? _selectedButton;
  late GamepadLayout _editingLayout;
  late GamepadSkinData _resolvedSkin;

  /// Cooldown guard so rapid touch events don't spam the haptic engine.
  final Stopwatch _hapticCooldown = Stopwatch();
  static const Duration _hapticMinInterval = Duration(milliseconds: 60);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve the skin using the current theme from the widget tree.
    // This runs after initState and whenever Theme changes.
    _resolvedSkin = GamepadSkinData.resolve(
      widget.skin,
      AppColorTheme.of(context),
    );
  }

  @override
  void initState() {
    super.initState();
    _editingLayout = widget.layout;
  }

  @override
  void didUpdateWidget(VirtualGamepad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout) {
      _editingLayout = widget.layout;
    }
    if (oldWidget.skin != widget.skin) {
      _resolvedSkin = GamepadSkinData.resolve(
        widget.skin,
        AppColorTheme.of(context),
      );
    }
  }

  void _updateKey(int key, bool pressed) {
    if (widget.editMode) return; // Disable input in edit mode

    final newKeys = pressed ? (_currentKeys | key) : (_currentKeys & ~key);

    if (newKeys != _currentKeys) {
      _currentKeys = newKeys;
      widget.onKeysChanged(_currentKeys);

      if (pressed && widget.enableVibration) {
        if (!_hapticCooldown.isRunning ||
            _hapticCooldown.elapsed >= _hapticMinInterval) {
          HapticFeedback.lightImpact();
          _hapticCooldown.reset();
          _hapticCooldown.start();
        }
      }
    }
  }

  void _onButtonDrag(GamepadButton button, Offset delta, Size screenSize) {
    if (!widget.editMode) return;

    setState(() {
      _selectedButton = button;
      final currentLayout = _getButtonLayout(button);

      // Positions are pure fractions of the full screen, so a drag delta in
      // pixels maps directly to a delta in screen fractions. Same math for
      // every orientation and platform — and only THIS button is touched,
      // so dragging it never disturbs any other button.
      final double newX = (currentLayout.x + delta.dx / screenSize.width).clamp(
        0.0,
        1.0,
      );
      final double newY = (currentLayout.y + delta.dy / screenSize.height)
          .clamp(0.0, 1.0);

      _editingLayout = _updateButtonLayout(
        button,
        currentLayout.copyWith(x: newX, y: newY),
      );
    });

    widget.onLayoutChanged?.call(_editingLayout);
  }

  /// Minimum touch target in logical pixels (per Material Design guidelines).
  static const double _minTouchTarget = 36.0;

  /// Per-button-type scale limits.
  /// D-pad / joystick can be larger; small utility buttons have a tighter range.
  static (double min, double max) _sizeRange(GamepadButton button) {
    return switch (button) {
      GamepadButton.dpad => (0.70, 2.50),
      GamepadButton.aButton => (0.70, 2.00),
      GamepadButton.bButton => (0.70, 2.00),
      GamepadButton.xButton => (0.70, 2.00),
      GamepadButton.yButton => (0.70, 2.00),
      GamepadButton.lButton => (0.80, 2.00),
      GamepadButton.rButton => (0.80, 2.00),
      GamepadButton.startButton => (0.80, 1.80),
      GamepadButton.selectButton => (0.80, 1.80),
      GamepadButton.l2Button => (0.80, 1.80),
      GamepadButton.r2Button => (0.80, 1.80),
    };
  }

  void _onButtonResize(GamepadButton button, double scaleDelta) {
    if (!widget.editMode) return;

    setState(() {
      _selectedButton = button;
      final currentLayout = _getButtonLayout(button);
      final (minScale, maxScale) = _sizeRange(button);
      final newSize = (currentLayout.size + scaleDelta).clamp(
        minScale,
        maxScale,
      );

      // Enforce a minimum pixel size so the button stays tappable.
      // Compute the smallest dimension at the candidate scale and reject
      // the resize if it would drop below the touch-target threshold.
      // Size is referenced to the screen (a phone-border constant), never the
      // game rectangle — so changing the game size never rescales the buttons.
      final screen = MediaQuery.of(context).size;
      final isPortrait =
          MediaQuery.of(context).orientation == Orientation.portrait;
      final sizeRef = isPortrait ? screen.width : screen.height;
      final baseSize = isPortrait ? sizeRef * 0.28 : sizeRef * 0.26;
      final buttonBase = isPortrait ? sizeRef * 0.17 : sizeRef * 0.16;

      final double smallestDim;
      switch (button) {
        case GamepadButton.dpad:
          smallestDim = baseSize * newSize * widget.scale;
        case GamepadButton.aButton:
        case GamepadButton.bButton:
        case GamepadButton.xButton:
        case GamepadButton.yButton:
          smallestDim = buttonBase * newSize * widget.scale;
        case GamepadButton.lButton:
        case GamepadButton.rButton:
          // Height is the smallest dimension for shoulder buttons
          smallestDim = baseSize * 0.30 * newSize * widget.scale;
        case GamepadButton.startButton:
        case GamepadButton.selectButton:
        case GamepadButton.l2Button:
        case GamepadButton.r2Button:
          smallestDim = baseSize * 0.12 * newSize * widget.scale;
      }

      if (smallestDim < _minTouchTarget && scaleDelta < 0) {
        // Would shrink below minimum tappable size — ignore
        return;
      }

      _editingLayout = _updateButtonLayout(
        button,
        currentLayout.copyWith(size: newSize),
      );
    });

    widget.onLayoutChanged?.call(_editingLayout);
  }

  ({String label, int key}) _slotBinding(GamepadButton slot) {
    return virtualGamepadSlotBinding(widget.platform, slot);
  }

  ButtonLayout _getButtonLayout(GamepadButton button) {
    switch (button) {
      case GamepadButton.dpad:
        return _editingLayout.dpad;
      case GamepadButton.aButton:
        return _editingLayout.aButton;
      case GamepadButton.bButton:
        return _editingLayout.bButton;
      case GamepadButton.lButton:
        return _editingLayout.lButton;
      case GamepadButton.rButton:
        return _editingLayout.rButton;
      case GamepadButton.startButton:
        return _editingLayout.startButton;
      case GamepadButton.selectButton:
        return _editingLayout.selectButton;
      case GamepadButton.xButton:
        return _editingLayout.xButton ?? _defaultXY(GamepadButton.xButton);
      case GamepadButton.yButton:
        return _editingLayout.yButton ?? _defaultXY(GamepadButton.yButton);
      case GamepadButton.l2Button:
        return _editingLayout.l2Button ?? _defaultL2R2(GamepadButton.l2Button);
      case GamepadButton.r2Button:
        return _editingLayout.r2Button ?? _defaultL2R2(GamepadButton.r2Button);
    }
  }

  /// Fallback position for an X/Y slot when the active layout has none saved
  /// (e.g. an older two-button layout for a platform that now shows X/Y).
  /// Uses the platform's own default for the current orientation so the
  /// button lands in a sensible spot instead of snapping to a portrait
  /// SNES position while in landscape.
  ButtonLayout _defaultXY(GamepadButton slot) {
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final platformDefault = GamepadLayout.defaultForPlatform(
      widget.platform,
      landscape: landscape,
    );
    final generic = landscape
        ? GamepadLayout.defaultLandscape
        : GamepadLayout.defaultPortrait;
    return slot == GamepadButton.xButton
        ? (platformDefault.xButton ?? generic.xButton!)
        : (platformDefault.yButton ?? generic.yButton!);
  }

  /// Fallback position for an L2/R2 trigger when the active layout has none
  /// saved (e.g. a PS1 layout created before L2/R2 became editable). Uses the
  /// platform's own default for the current orientation, and if that is also
  /// missing, derives a spot just above the matching L/R shoulder.
  ButtonLayout _defaultL2R2(GamepadButton slot) {
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final platformDefault = GamepadLayout.defaultForPlatform(
      widget.platform,
      landscape: landscape,
    );
    final isL = slot == GamepadButton.l2Button;
    final fromDefault = isL
        ? platformDefault.l2Button
        : platformDefault.r2Button;
    if (fromDefault != null) return fromDefault;
    // Derive from the shoulder: sit clearly above it, leaving enough room for
    // the compact trigger height and edit handles.
    final shoulder = isL ? platformDefault.lButton : platformDefault.rButton;
    final yOffset = landscape ? 0.12 : 0.10;
    return ButtonLayout(
      x: shoulder.x,
      y: (shoulder.y - yOffset).clamp(0.0, 1.0),
      size: 0.90,
    );
  }

  GamepadLayout _updateButtonLayout(GamepadButton button, ButtonLayout layout) {
    switch (button) {
      case GamepadButton.dpad:
        return _editingLayout.copyWith(dpad: layout);
      case GamepadButton.aButton:
        return _editingLayout.copyWith(aButton: layout);
      case GamepadButton.bButton:
        return _editingLayout.copyWith(bButton: layout);
      case GamepadButton.lButton:
        return _editingLayout.copyWith(lButton: layout);
      case GamepadButton.rButton:
        return _editingLayout.copyWith(rButton: layout);
      case GamepadButton.startButton:
        return _editingLayout.copyWith(startButton: layout);
      case GamepadButton.selectButton:
        return _editingLayout.copyWith(selectButton: layout);
      case GamepadButton.xButton:
        return _editingLayout.copyWith(xButton: layout);
      case GamepadButton.yButton:
        return _editingLayout.copyWith(yButton: layout);
      case GamepadButton.l2Button:
        return _editingLayout.copyWith(l2Button: layout);
      case GamepadButton.r2Button:
        return _editingLayout.copyWith(r2Button: layout);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Opacity(
      opacity: widget.opacity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenSize = Size(constraints.maxWidth, constraints.maxHeight);
          final layout = _editingLayout;
          final mediaQuery = MediaQuery.of(context);

          // Button sizes are referenced to the screen only (width in portrait,
          // height in landscape) — a phone-border constant. They never depend
          // on the game rectangle, so resizing/moving the game leaves the
          // controls untouched.
          final isPortrait = mediaQuery.orientation == Orientation.portrait;
          final safePadding = mediaQuery.padding;

          final sizeRef = isPortrait ? screenSize.width : screenSize.height;

          final baseSize = isPortrait ? sizeRef * 0.28 : sizeRef * 0.26;

          final buttonBase = isPortrait ? sizeRef * 0.17 : sizeRef * 0.16;
          // D-pad / joystick boost: 10% bigger in portrait, 25% bigger in
          // landscape (user request — gives more comfortable thumb target).
          final dpadBoost = isPortrait ? 1.1 : 1.25;

          // Use cached skin data (resolved in initState / didUpdateWidget)
          final skin = _resolvedSkin;

          // Pre-compute child sizes for each button so the clamp logic can
          // keep the entire widget on screen, not just its top-left corner.
          final dpadScale = layout.dpad.size * widget.scale * dpadBoost;
          final dpadSize = Size(baseSize * dpadScale, baseSize * dpadScale);

          final aSize = buttonBase * layout.aButton.size * widget.scale;
          final bSize = buttonBase * layout.bButton.size * widget.scale;

          // Genesis/Mega Drive carries its X and Y on the L/R slots but draws
          // them as round face buttons (not shoulders) so the 6-button grid
          // stays uniform. Size them like the A/B circles in that case.
          final bool mdFaceButtons = widget.platform == GamePlatform.md;

          final lScale = layout.lButton.size * widget.scale;
          final lSize = mdFaceButtons
              ? Size(buttonBase * lScale, buttonBase * lScale)
              : Size(baseSize * 0.55 * lScale, baseSize * 0.30 * lScale);

          final rScale = layout.rButton.size * widget.scale;
          final rSize = mdFaceButtons
              ? Size(buttonBase * rScale, buttonBase * rScale)
              : Size(baseSize * 0.55 * rScale, baseSize * 0.30 * rScale);

          final startScale = layout.startButton.size * widget.scale;
          // SmallButton uses padding; approximate outer size
          final startSize = Size(
            baseSize * 0.20 * startScale + baseSize * 0.20 * startScale,
            baseSize * 0.12 * startScale + baseSize * 0.12 * startScale,
          );

          final selectScale = layout.selectButton.size * widget.scale;
          final selectSize = Size(
            baseSize * 0.20 * selectScale + baseSize * 0.20 * selectScale,
            baseSize * 0.12 * selectScale + baseSize * 0.12 * selectScale,
          );

          // ── Determine active buttons based on platform ──
          final bool showLR = switch (widget.platform) {
            GamePlatform.gba ||
            GamePlatform.snes ||
            GamePlatform.md ||
            GamePlatform.n64 ||
            GamePlatform.vb ||
            GamePlatform.nds ||
            GamePlatform.ps1 ||
            // Intellivision: L/R open the FreeIntv keypad (per the core's
            // in-game help — "L/R → SHOW KEYPAD").
            GamePlatform.intv => true,
            _ => false,
          };
          // N64 omitted on purpose: its X/Y slots would be the C-buttons,
          // which live on the right analog stick and need native support.
          // Showing them would send the wrong input, so they stay hidden.
          final bool showXY = switch (widget.platform) {
            GamePlatform.snes ||
            GamePlatform.md ||
            GamePlatform.nds ||
            GamePlatform.ps1 ||
            // Intellivision: Y = top action button, X = repeat last keypad
            // entry (per the core's in-game help screen).
            GamePlatform.intv => true,
            _ => false,
          };
          // PS1 adds L2/R2 triggers. They are full members of the editable
          // layout (own position + size, persisted), sized like Start/Select.
          final bool showL2R2 = widget.platform == GamePlatform.ps1;

          // PS1 L2/R2 trigger sizes (small buttons; only computed for PS1).
          final l2Scale =
              (showL2R2
                  ? _getButtonLayout(GamepadButton.l2Button).size
                  : 0.90) *
              widget.scale;
          final r2Scale =
              (showL2R2
                  ? _getButtonLayout(GamepadButton.r2Button).size
                  : 0.90) *
              widget.scale;
          final l2Size = Size(
            baseSize * 0.20 * l2Scale + baseSize * 0.20 * l2Scale,
            baseSize * 0.12 * l2Scale + baseSize * 0.12 * l2Scale,
          );
          final r2Size = Size(
            baseSize * 0.20 * r2Scale + baseSize * 0.20 * r2Scale,
            baseSize * 0.12 * r2Scale + baseSize * 0.12 * r2Scale,
          );

          // ── Pre-compute all button sizes ──
          final buttonSizes = <GamepadButton, Size>{
            GamepadButton.dpad: dpadSize,
            GamepadButton.aButton: Size(aSize, aSize),
            GamepadButton.bButton: Size(bSize, bSize),
            if (showLR) GamepadButton.lButton: lSize,
            if (showLR) GamepadButton.rButton: rSize,
            GamepadButton.startButton: startSize,
            GamepadButton.selectButton: selectSize,
            if (showL2R2) GamepadButton.l2Button: l2Size,
            if (showL2R2) GamepadButton.r2Button: r2Size,
          };

          // SNES X / Y sizes (same sizing logic as A/B)
          if (showXY) {
            final xLayout = _getButtonLayout(GamepadButton.xButton);
            final yLayout = _getButtonLayout(GamepadButton.yButton);
            final xSize = buttonBase * xLayout.size * widget.scale;
            final ySize = buttonBase * yLayout.size * widget.scale;
            buttonSizes[GamepadButton.xButton] = Size(xSize, xSize);
            buttonSizes[GamepadButton.yButton] = Size(ySize, ySize);
          }

          // ── Compute each button's pixel position independently ──
          // Each position comes purely from that button's own screen
          // fraction. Buttons are never nudged to avoid one another, so the
          // arrangement the user makes is exactly what renders.
          final resolvedPositions = <GamepadButton, Offset>{};
          for (final btn in buttonSizes.keys) {
            resolvedPositions[btn] = _computeButtonPosition(
              layout: _getButtonLayout(btn),
              screenSize: screenSize,
              safePadding: safePadding,
              childSize: buttonSizes[btn]!,
            );
          }

          return Stack(
            children: [
              // D-Pad or Joystick
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.dpad]!,
                button: GamepadButton.dpad,
                screenSize: screenSize,
                child: widget.useJoystick
                    ? _Joystick(
                        onDirectionChanged: (up, down, left, right) {
                          _updateKey(GBAKey.up, up);
                          _updateKey(GBAKey.down, down);
                          _updateKey(GBAKey.left, left);
                          _updateKey(GBAKey.right, right);
                        },
                        onAnalogChanged: widget.onAnalogChanged != null
                            ? (x, y) {
                                // Normalize from [-1.0, 1.0] to [-32768, 32767]
                                final analogX = (x * 32767).toInt();
                                final analogY = (y * 32767).toInt();
                                widget.onAnalogChanged!(
                                  analogX.toDouble(),
                                  analogY.toDouble(),
                                );
                              }
                            : null,
                        scale: dpadScale,
                        baseSize: baseSize,
                        editMode: widget.editMode,
                        skin: skin,
                      )
                    : _DPad(
                        onDirectionChanged: (up, down, left, right) {
                          _updateKey(GBAKey.up, up);
                          _updateKey(GBAKey.down, down);
                          _updateKey(GBAKey.left, left);
                          _updateKey(GBAKey.right, right);
                        },
                        scale: dpadScale,
                        baseSize: baseSize,
                        editMode: widget.editMode,
                        skin: skin,
                      ),
              ),

              // A Button
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.aButton]!,
                button: GamepadButton.aButton,
                screenSize: screenSize,
                child: _CircleButton(
                  label: _slotBinding(GamepadButton.aButton).label,
                  color: colors.accentAlt,
                  onChanged: (pressed) => _updateKey(
                    _slotBinding(GamepadButton.aButton).key,
                    pressed,
                  ),
                  size: aSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),

              // B Button
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.bButton]!,
                button: GamepadButton.bButton,
                screenSize: screenSize,
                child: _CircleButton(
                  label: _slotBinding(GamepadButton.bButton).label,
                  color: colors.accentYellow,
                  onChanged: (pressed) => _updateKey(
                    _slotBinding(GamepadButton.bButton).key,
                    pressed,
                  ),
                  size: bSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),

              // L slot — shoulder for most cores; Genesis X face circle.
              if (showLR)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.lButton]!,
                  button: GamepadButton.lButton,
                  screenSize: screenSize,
                  child: mdFaceButtons
                      ? _CircleButton(
                          label: _slotBinding(GamepadButton.lButton).label,
                          color: colors.primary,
                          onChanged: (pressed) => _updateKey(
                            _slotBinding(GamepadButton.lButton).key,
                            pressed,
                          ),
                          size: lSize.width,
                          editMode: widget.editMode,
                          skin: skin,
                        )
                      : _ShoulderButton(
                          label: _slotBinding(GamepadButton.lButton).label,
                          onChanged: (pressed) => _updateKey(
                            _slotBinding(GamepadButton.lButton).key,
                            pressed,
                          ),
                          scale: lScale,
                          baseSize: baseSize,
                          editMode: widget.editMode,
                          skin: skin,
                        ),
                ),

              // R slot — shoulder for most cores; Genesis Y face circle.
              if (showLR)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.rButton]!,
                  button: GamepadButton.rButton,
                  screenSize: screenSize,
                  child: mdFaceButtons
                      ? _CircleButton(
                          label: _slotBinding(GamepadButton.rButton).label,
                          color: colors.success,
                          onChanged: (pressed) => _updateKey(
                            _slotBinding(GamepadButton.rButton).key,
                            pressed,
                          ),
                          size: rSize.width,
                          editMode: widget.editMode,
                          skin: skin,
                        )
                      : _ShoulderButton(
                          label: _slotBinding(GamepadButton.rButton).label,
                          onChanged: (pressed) => _updateKey(
                            _slotBinding(GamepadButton.rButton).key,
                            pressed,
                          ),
                          scale: rScale,
                          baseSize: baseSize,
                          editMode: widget.editMode,
                          skin: skin,
                        ),
                ),

              // Face button X slot (SNES X, Genesis C)
              if (showXY)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.xButton]!,
                  button: GamepadButton.xButton,
                  screenSize: screenSize,
                  child: _CircleButton(
                    label: _slotBinding(GamepadButton.xButton).label,
                    color: colors.primary,
                    onChanged: (pressed) => _updateKey(
                      _slotBinding(GamepadButton.xButton).key,
                      pressed,
                    ),
                    size: buttonSizes[GamepadButton.xButton]!.width,
                    editMode: widget.editMode,
                    skin: skin,
                  ),
                ),

              // Face button Y slot (SNES Y, Genesis Z)
              if (showXY)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.yButton]!,
                  button: GamepadButton.yButton,
                  screenSize: screenSize,
                  child: _CircleButton(
                    label: _slotBinding(GamepadButton.yButton).label,
                    color: colors.success,
                    onChanged: (pressed) => _updateKey(
                      _slotBinding(GamepadButton.yButton).key,
                      pressed,
                    ),
                    size: buttonSizes[GamepadButton.yButton]!.width,
                    editMode: widget.editMode,
                    skin: skin,
                  ),
                ),

              // Start Button
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.startButton]!,
                button: GamepadButton.startButton,
                screenSize: screenSize,
                child: _SmallButton(
                  label: _slotBinding(GamepadButton.startButton).label,
                  onChanged: (pressed) => _updateKey(
                    _slotBinding(GamepadButton.startButton).key,
                    pressed,
                  ),
                  scale: startScale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),

              // Select Button (labelled MODE for Genesis, Z for N64)
              _buildButtonAtPosition(
                position: resolvedPositions[GamepadButton.selectButton]!,
                button: GamepadButton.selectButton,
                screenSize: screenSize,
                child: _SmallButton(
                  label: _slotBinding(GamepadButton.selectButton).label,
                  onChanged: (pressed) => _updateKey(
                    _slotBinding(GamepadButton.selectButton).key,
                    pressed,
                  ),
                  scale: selectScale,
                  baseSize: baseSize,
                  editMode: widget.editMode,
                  skin: skin,
                ),
              ),

              // ── PS1 L2 / R2 triggers (editable) ──────────────────────
              // Full members of the editable layout: their position and size
              // come from resolvedPositions/buttonSizes and are persisted, so
              // they drag and resize like every other button (and only overlap
              // L/R if the user deliberately places them there). Defaults sit
              // just above the L/R shoulders.
              if (showL2R2 && resolvedPositions[GamepadButton.l2Button] != null)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.l2Button]!,
                  button: GamepadButton.l2Button,
                  screenSize: screenSize,
                  child: _SmallButton(
                    label: _slotBinding(GamepadButton.l2Button).label,
                    onChanged: (pressed) => _updateKey(
                      _slotBinding(GamepadButton.l2Button).key,
                      pressed,
                    ),
                    scale: l2Scale,
                    baseSize: baseSize,
                    editMode: widget.editMode,
                    skin: skin,
                  ),
                ),
              if (showL2R2 && resolvedPositions[GamepadButton.r2Button] != null)
                _buildButtonAtPosition(
                  position: resolvedPositions[GamepadButton.r2Button]!,
                  button: GamepadButton.r2Button,
                  screenSize: screenSize,
                  child: _SmallButton(
                    label: _slotBinding(GamepadButton.r2Button).label,
                    onChanged: (pressed) => _updateKey(
                      _slotBinding(GamepadButton.r2Button).key,
                      pressed,
                    ),
                    scale: r2Scale,
                    baseSize: baseSize,
                    editMode: widget.editMode,
                    skin: skin,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  // Position computation — pure function, no widget creation.
  //
  // A button's top-left corner is simply its (x, y) fraction times the
  // screen size — anchored to the phone borders and nothing else. The only
  // adjustment is a clamp that keeps the whole button on screen (and, in
  // landscape, below the in-game top toolbar). The clamp depends solely on
  // the screen and the button's own size, never on the game or other buttons.
  // ────────────────────────────────────────────────────────────────
  Offset _computeButtonPosition({
    required ButtonLayout layout,
    required Size screenSize,
    required EdgeInsets safePadding,
    required Size childSize,
  }) {
    final bool isPortrait = screenSize.height > screenSize.width;

    final double x = layout.x * screenSize.width;
    final double y = layout.y * screenSize.height;

    // ── Safe clamp: keep the whole button on screen. In landscape, reserve
    // a top strip so buttons never hide under the in-game toolbar. Device
    // safe areas only affect the final clamp, so normalized layouts remain
    // consistent across phones while still avoiding notches/gesture bars.
    final double minMargin = screenSize.width * 0.01;
    final double minXMargin = math.max(minMargin, safePadding.left + minMargin);
    final double maxXMargin = math.max(
      minMargin,
      safePadding.right + minMargin,
    );
    final double minYMargin = isPortrait
        ? minMargin
        : (screenSize.width * 0.107).clamp(36.0, 56.0) +
              screenSize.height * 0.02;
    final double minSafeYMargin = math.max(
      minYMargin,
      safePadding.top + minMargin,
    );
    final double maxYMargin = math.max(
      minMargin,
      safePadding.bottom + minMargin,
    );

    final double clampedX = x.clamp(
      minXMargin,
      math.max(minXMargin, screenSize.width - childSize.width - maxXMargin),
    );
    final double clampedY = y.clamp(
      minSafeYMargin,
      math.max(
        minSafeYMargin,
        screenSize.height - childSize.height - maxYMargin,
      ),
    );

    return Offset(clampedX, clampedY);
  }

  // ────────────────────────────────────────────────────────────────
  // Build a positioned button widget at a pre-computed position
  // ────────────────────────────────────────────────────────────────
  Widget _buildButtonAtPosition({
    required Offset position,
    required GamepadButton button,
    required Size screenSize,
    required Widget child,
  }) {
    final isSelected = widget.editMode && _selectedButton == button;

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: widget.editMode
          ? _EditableButtonWrapper(
              isSelected: isSelected,
              onDrag: (delta) => _onButtonDrag(button, delta, screenSize),
              onScaleUp: () => _onButtonResize(button, 0.1),
              onScaleDown: () => _onButtonResize(button, -0.1),
              onTap: () => setState(() => _selectedButton = button),
              child: child,
            )
          : child,
    );
  }
}

/// Wrapper for making buttons editable (draggable + resizable)
class _EditableButtonWrapper extends StatelessWidget {
  final Widget child;
  final bool isSelected;
  final void Function(Offset delta) onDrag;
  final VoidCallback onScaleUp;
  final VoidCallback onScaleDown;
  final VoidCallback onTap;

  const _EditableButtonWrapper({
    required this.child,
    required this.isSelected,
    required this.onDrag,
    required this.onScaleUp,
    required this.onScaleDown,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      onPanUpdate: (details) => onDrag(details.delta),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Selection indicator
          if (isSelected)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.accent, width: 3),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),

          // The actual button
          child,

          // Resize controls (only when selected)
          if (isSelected) ...[
            // Scale up button
            Positioned(
              top: -20,
              right: -20,
              child: GestureDetector(
                onTap: onScaleUp,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.add, color: Colors.white, size: 20),
                ),
              ),
            ),
            // Scale down button
            Positioned(
              bottom: -20,
              right: -20,
              child: GestureDetector(
                onTap: onScaleDown,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors.error,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(
                    Icons.remove,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// D-Pad widget
class _DPad extends StatefulWidget {
  final void Function(bool up, bool down, bool left, bool right)
  onDirectionChanged;
  final double scale;
  final double baseSize;
  final bool editMode;
  final GamepadSkinData skin;

  const _DPad({
    required this.onDirectionChanged,
    this.scale = 1.0,
    this.baseSize = 190.0,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_DPad> createState() => _DPadState();
}

class _DPadState extends State<_DPad> {
  bool _up = false;
  bool _down = false;
  bool _left = false;
  bool _right = false;

  void _handlePan(Offset localPosition, Size size) {
    if (widget.editMode) return;

    final center = Offset(size.width / 2, size.height / 2);
    final delta = localPosition - center;
    final deadzone = size.width * 0.15;

    final newUp = delta.dy < -deadzone;
    final newDown = delta.dy > deadzone;
    final newLeft = delta.dx < -deadzone;
    final newRight = delta.dx > deadzone;

    if (newUp != _up ||
        newDown != _down ||
        newLeft != _left ||
        newRight != _right) {
      setState(() {
        _up = newUp;
        _down = newDown;
        _left = newLeft;
        _right = newRight;
      });
      widget.onDirectionChanged(_up, _down, _left, _right);
    }
  }

  void _reset() {
    if (_up || _down || _left || _right) {
      setState(() {
        _up = false;
        _down = false;
        _left = false;
        _right = false;
      });
      widget.onDirectionChanged(false, false, false, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.baseSize * widget.scale;
    final buttonSize = size * 0.34;

    return GestureDetector(
      onPanStart: widget.editMode
          ? null
          : (details) => _handlePan(details.localPosition, Size(size, size)),
      onPanUpdate: widget.editMode
          ? null
          : (details) => _handlePan(details.localPosition, Size(size, size)),
      onPanEnd: widget.editMode ? null : (_) => _reset(),
      onPanCancel: widget.editMode ? null : _reset,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            // Background
            Center(
              child: Container(
                width: size - 16,
                height: size - 16,
                decoration: BoxDecoration(
                  color: widget.skin.dpadBackground,
                  borderRadius: BorderRadius.circular(widget.skin.dpadRadius),
                  border: Border.all(
                    color: widget.skin.dpadBorder,
                    width: widget.skin.dpadBorderWidth,
                  ),
                  boxShadow: widget.skin.normalShadows,
                ),
              ),
            ),

            // Up
            Positioned(
              top: 0,
              left: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _up,
                icon: Icons.keyboard_arrow_up,
                size: buttonSize,
                skin: widget.skin,
              ),
            ),

            // Down
            Positioned(
              bottom: 0,
              left: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _down,
                icon: Icons.keyboard_arrow_down,
                size: buttonSize,
                skin: widget.skin,
              ),
            ),

            // Left
            Positioned(
              left: 0,
              top: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _left,
                icon: Icons.keyboard_arrow_left,
                size: buttonSize,
                skin: widget.skin,
              ),
            ),

            // Right
            Positioned(
              right: 0,
              top: (size - buttonSize) / 2,
              child: _DPadButton(
                isPressed: _right,
                icon: Icons.keyboard_arrow_right,
                size: buttonSize,
                skin: widget.skin,
              ),
            ),

            // Center circle
            Center(
              child: Container(
                width: 36 * widget.scale,
                height: 36 * widget.scale,
                decoration: BoxDecoration(
                  color: widget.skin.dpadCenter,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.skin.dpadBorder,
                    width: widget.skin.dpadBorderWidth,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DPadButton extends StatelessWidget {
  final bool isPressed;
  final IconData icon;
  final double size;
  final GamepadSkinData skin;

  const _DPadButton({
    required this.isPressed,
    required this.icon,
    this.size = 60,
    required this.skin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isPressed ? skin.buttonFillPressed : skin.buttonFill,
        borderRadius: BorderRadius.circular(skin.buttonRadius),
        border: Border.all(
          color: isPressed ? skin.buttonBorderPressed : skin.buttonBorder,
          width: skin.buttonBorderWidth,
        ),
        boxShadow: isPressed ? skin.pressedShadows : skin.normalShadows,
      ),
      child: Icon(
        icon,
        color: isPressed ? skin.textPressed : skin.textNormal,
        size: size * 0.55,
      ),
    );
  }
}

class _CircleButton extends StatefulWidget {
  final String label;
  final Color color;
  final void Function(bool pressed) onChanged;
  final double size;
  final bool editMode;
  final GamepadSkinData skin;

  const _CircleButton({
    required this.label,
    required this.color,
    required this.onChanged,
    this.size = 80,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_CircleButton> createState() => _CircleButtonState();
}

class _CircleButtonState extends State<_CircleButton> {
  bool _isPressed = false;

  void _setPressed(bool pressed) {
    if (widget.editMode) return;

    if (pressed != _isPressed) {
      setState(() => _isPressed = pressed);
      widget.onChanged(pressed);
      if (pressed) HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.editMode ? null : (_) => _setPressed(true),
      onTapUp: widget.editMode ? null : (_) => _setPressed(false),
      onTapCancel: widget.editMode ? null : () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: _isPressed
              ? widget.skin.buttonFillPressed
              : widget.skin.buttonFill,
          shape: BoxShape.circle,
          border: Border.all(
            color: _isPressed
                ? widget.skin.buttonBorderPressed
                : widget.skin.buttonBorder,
            width: widget.skin.buttonBorderWidth,
          ),
          boxShadow: _isPressed
              ? widget.skin.pressedShadows
              : widget.skin.normalShadows,
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.size * 0.35,
              fontWeight: FontWeight.bold,
              color: _isPressed
                  ? widget.skin.textPressed
                  : widget.skin.textNormal,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shoulder button (L/R)
class _ShoulderButton extends StatefulWidget {
  final String label;
  final void Function(bool pressed) onChanged;
  final double scale;
  final double baseSize;
  final bool editMode;
  final GamepadSkinData skin;

  const _ShoulderButton({
    required this.label,
    required this.onChanged,
    this.scale = 1.0,
    this.baseSize = 80.0,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_ShoulderButton> createState() => _ShoulderButtonState();
}

class _ShoulderButtonState extends State<_ShoulderButton> {
  bool _isPressed = false;

  void _setPressed(bool pressed) {
    if (widget.editMode) return;

    if (pressed != _isPressed) {
      setState(() => _isPressed = pressed);
      widget.onChanged(pressed);
      if (pressed) HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.editMode ? null : (_) => _setPressed(true),
      onTapUp: widget.editMode ? null : (_) => _setPressed(false),
      onTapCancel: widget.editMode ? null : () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: widget.baseSize * 0.55 * widget.scale,
        height: widget.baseSize * 0.30 * widget.scale,
        decoration: BoxDecoration(
          color: _isPressed
              ? widget.skin.buttonFillPressed
              : widget.skin.buttonFill,
          borderRadius: BorderRadius.circular(widget.skin.buttonRadius + 2),
          border: Border.all(
            color: _isPressed
                ? widget.skin.buttonBorderPressed
                : widget.skin.buttonBorder,
            width: widget.skin.buttonBorderWidth,
          ),
          boxShadow: _isPressed
              ? widget.skin.pressedShadows
              : widget.skin.normalShadows,
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.baseSize * 0.12 * widget.scale,
              fontWeight: FontWeight.bold,
              color: _isPressed
                  ? widget.skin.textPressed
                  : widget.skin.textNormal,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small button (Start/Select)
class _SmallButton extends StatefulWidget {
  final String label;
  final void Function(bool pressed) onChanged;
  final double scale;
  final double baseSize;
  final bool editMode;
  final GamepadSkinData skin;

  const _SmallButton({
    required this.label,
    required this.onChanged,
    this.scale = 1.0,
    this.baseSize = 80.0,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
  bool _isPressed = false;

  void _setPressed(bool pressed) {
    if (widget.editMode) return;

    if (pressed != _isPressed) {
      setState(() => _isPressed = pressed);
      widget.onChanged(pressed);
      if (pressed) HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.editMode ? null : (_) => _setPressed(true),
      onTapUp: widget.editMode ? null : (_) => _setPressed(false),
      onTapCancel: widget.editMode ? null : () => _setPressed(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        padding: EdgeInsets.symmetric(
          horizontal: widget.baseSize * 0.10 * widget.scale,
          vertical: widget.baseSize * 0.06 * widget.scale,
        ),
        decoration: BoxDecoration(
          color: _isPressed
              ? widget.skin.buttonFillPressed
              : widget.skin.buttonFill,
          borderRadius: BorderRadius.circular(widget.skin.buttonRadius),
          border: Border.all(
            color: _isPressed
                ? widget.skin.buttonBorderPressed
                : widget.skin.buttonBorder,
            width: widget.skin.buttonBorderWidth,
          ),
          boxShadow: _isPressed
              ? widget.skin.pressedShadows
              : widget.skin.normalShadows,
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            fontSize: widget.baseSize * 0.09 * widget.scale,
            fontWeight: FontWeight.bold,
            color: _isPressed
                ? widget.skin.textPressed
                : widget.skin.textNormal,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

/// Joystick widget - analog-style directional input
class _Joystick extends StatefulWidget {
  final void Function(bool up, bool down, bool left, bool right)
  onDirectionChanged;
  final void Function(double x, double y)? onAnalogChanged;
  final double scale;
  final double baseSize;
  final bool editMode;
  final GamepadSkinData skin;

  const _Joystick({
    required this.onDirectionChanged,
    this.onAnalogChanged,
    this.scale = 1.0,
    this.baseSize = 190.0,
    this.editMode = false,
    required this.skin,
  });

  @override
  State<_Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<_Joystick> {
  Offset _stickPosition = Offset.zero;
  bool _up = false;
  bool _down = false;
  bool _left = false;
  bool _right = false;

  void _handlePan(Offset localPosition, Size size) {
    if (widget.editMode) return;

    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width * 0.35;
    final deadzone = size.width * 0.12;

    Offset delta = localPosition - center;

    // Clamp to max radius
    final distance = delta.distance;
    if (distance > maxRadius) {
      delta = delta * (maxRadius / distance);
    }

    setState(() {
      _stickPosition = delta;
    });

    // Calculate directions based on position
    final newUp = delta.dy < -deadzone;
    final newDown = delta.dy > deadzone;
    final newLeft = delta.dx < -deadzone;
    final newRight = delta.dx > deadzone;

    if (newUp != _up ||
        newDown != _down ||
        newLeft != _left ||
        newRight != _right) {
      _up = newUp;
      _down = newDown;
      _left = newLeft;
      _right = newRight;
      widget.onDirectionChanged(_up, _down, _left, _right);
    }

    // Emit analog values (normalized to [-1.0, 1.0] then converted to [-32768, 32767])
    if (widget.onAnalogChanged != null && distance > 0) {
      final normalizedX = (delta.dx / maxRadius).clamp(-1.0, 1.0);
      final normalizedY = (-delta.dy / maxRadius).clamp(-1.0, 1.0);
      widget.onAnalogChanged!(normalizedX, normalizedY);
    }
  }

  void _reset() {
    setState(() {
      _stickPosition = Offset.zero;
    });

    if (_up || _down || _left || _right) {
      _up = false;
      _down = false;
      _left = false;
      _right = false;
      widget.onDirectionChanged(false, false, false, false);
    }

    // Reset analog to center (0, 0)
    if (widget.onAnalogChanged != null) {
      widget.onAnalogChanged!(0.0, 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.baseSize * widget.scale;
    final stickSize = size * 0.45;

    return GestureDetector(
      onPanStart: widget.editMode
          ? null
          : (details) => _handlePan(details.localPosition, Size(size, size)),
      onPanUpdate: widget.editMode
          ? null
          : (details) => _handlePan(details.localPosition, Size(size, size)),
      onPanEnd: widget.editMode ? null : (_) => _reset(),
      onPanCancel: widget.editMode ? null : _reset,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outer ring (background)
            Container(
              width: size - 8,
              height: size - 8,
              decoration: BoxDecoration(
                color: widget.skin.joystickBg,
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.skin.joystickBorder,
                  width: widget.skin.joystickBorderWidth,
                ),
                boxShadow: widget.skin.normalShadows,
              ),
            ),

            // Direction indicators (subtle)
            ..._buildDirectionIndicators(size),

            // Movable stick
            Transform.translate(
              offset: _stickPosition,
              child: Container(
                width: stickSize,
                height: stickSize,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      widget.skin.stickColor,
                      widget.skin.stickColor.withAlpha(
                        (widget.skin.stickColor.a * 255 * 0.78).round().clamp(
                          0,
                          255,
                        ),
                      ),
                    ],
                    center: const Alignment(-0.3, -0.3),
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.skin.stickBorder,
                    width: widget.skin.joystickBorderWidth,
                  ),
                  boxShadow: widget.skin.pressedShadows.isNotEmpty
                      ? widget.skin.pressedShadows
                      : [
                          BoxShadow(
                            color: widget.skin.stickBorder.withAlpha(80),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ],
                ),
                child: widget.skin.stickHighlight != null
                    ? Center(
                        child: Container(
                          width: stickSize * 0.3,
                          height: stickSize * 0.3,
                          decoration: BoxDecoration(
                            color: widget.skin.stickHighlight,
                            shape: BoxShape.circle,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildDirectionIndicators(double size) {
    final indicatorSize = size * 0.08;
    final offset = size * 0.38;

    return [
      // Up indicator
      Positioned(
        top: size / 2 - offset - indicatorSize / 2,
        left: size / 2 - indicatorSize / 2,
        child: _DirectionIndicator(
          isActive: _up,
          size: indicatorSize,
          activeColor: widget.skin.buttonBorderPressed,
          inactiveColor: widget.skin.dpadBorder.withAlpha(100),
        ),
      ),
      // Down indicator
      Positioned(
        bottom: size / 2 - offset - indicatorSize / 2,
        left: size / 2 - indicatorSize / 2,
        child: _DirectionIndicator(
          isActive: _down,
          size: indicatorSize,
          activeColor: widget.skin.buttonBorderPressed,
          inactiveColor: widget.skin.dpadBorder.withAlpha(100),
        ),
      ),
      // Left indicator
      Positioned(
        left: size / 2 - offset - indicatorSize / 2,
        top: size / 2 - indicatorSize / 2,
        child: _DirectionIndicator(
          isActive: _left,
          size: indicatorSize,
          activeColor: widget.skin.buttonBorderPressed,
          inactiveColor: widget.skin.dpadBorder.withAlpha(100),
        ),
      ),
      // Right indicator
      Positioned(
        right: size / 2 - offset - indicatorSize / 2,
        top: size / 2 - indicatorSize / 2,
        child: _DirectionIndicator(
          isActive: _right,
          size: indicatorSize,
          activeColor: widget.skin.buttonBorderPressed,
          inactiveColor: widget.skin.dpadBorder.withAlpha(100),
        ),
      ),
    ];
  }
}

class _DirectionIndicator extends StatelessWidget {
  final bool isActive;
  final double size;
  final Color activeColor;
  final Color inactiveColor;

  const _DirectionIndicator({
    required this.isActive,
    required this.size,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isActive ? activeColor.withAlpha(200) : inactiveColor,
        shape: BoxShape.circle,
      ),
    );
  }
}
