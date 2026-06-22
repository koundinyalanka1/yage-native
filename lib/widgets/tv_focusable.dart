import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/tv_detector.dart';
import '../utils/theme.dart';

/// Wraps any widget so it is D-pad / keyboard focusable and shows
/// a highlight ring when focused.  Enter, Space, and Gamepad-A
/// trigger [onTap].  Gamepad-B / Escape invoke [onBack] if provided.
///
/// On touchscreen-only devices this is essentially transparent.
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onBack;
  final bool autofocus;
  final FocusNode? focusNode;
  final BorderRadius borderRadius;

  /// Whether to animate the focus glow. When `false`, a static highlight
  /// ring is shown instead of the pulsing glow — better for dialog buttons
  /// where the pulse can look like a distracting blink.
  final bool animate;

  /// When true, use a subtle focus ring (thinner border, lower glow) so the
  /// focus highlight does not dominate secondary actions like Cancel.
  final bool subtleFocus;

  /// Called when the focus state changes. Useful for tracking which widget
  /// in a list/grid was last focused so focus can be restored later.
  final ValueChanged<bool>? onFocusChanged;

  /// When true (default), the wrapped [child] subtree is removed from focus
  /// traversal so that nested Material widgets (IconButton, ListTile, buttons,
  /// InkWell, …) do not register their own competing focus nodes. Without this,
  /// a single logical control produces two D-pad stops and two highlights on
  /// TV. Set to false only when the child genuinely needs its own internal
  /// focus (e.g. it contains a text field).
  final bool excludeChildFocus;

  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onBack,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.animate = true,
    this.subtleFocus = false,
    this.onFocusChanged,
    this.excludeChildFocus = true,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable>
    with SingleTickerProviderStateMixin {
  late final FocusNode _focusNode;
  bool _focused = false;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  /// Keys that trigger "select" / onTap
  static final _selectKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.numpadEnter,
    // Gamepad
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.gameButtonStart,
    // D-Pad Centers (some remotes map to these)
    LogicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaPlay,
  };

  /// Keys that trigger "back" / onBack
  static final _backKeys = {
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.gameButtonB,
    LogicalKeyboardKey.goBack,
    LogicalKeyboardKey.browserBack,
  };

  /// Keys that trigger the long-press / context-menu action on TV.
  /// Uses the keyboard context-menu key and gamepad Select (View/Back
  /// button).  Note: gameButtonX is intentionally excluded — it is
  /// mapped to GBA B in the gamepad mapper and would conflict in-game.
  /// gameButtonSelect is safe here because TvFocusable widgets are only
  /// focused outside gameplay (home screen, menus) where GBA Select is
  /// not needed.
  static final _contextKeys = {
    LogicalKeyboardKey.gameButtonSelect,
    LogicalKeyboardKey.contextMenu,
  };

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _focusNode.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (_selectKeys.contains(event.logicalKey)) {
      widget.onTap?.call();
      return KeyEventResult.handled;
    }
    if (_contextKeys.contains(event.logicalKey) && widget.onLongPress != null) {
      widget.onLongPress!();
      return KeyEventResult.handled;
    }
    if (_backKeys.contains(event.logicalKey) && widget.onBack != null) {
      widget.onBack!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (widget.animate) {
          if (focused) {
            _pulseController.repeat(reverse: true);
          } else {
            _pulseController.stop();
            _pulseController.reset();
          }
        }
        if (focused && TvDetector.isTV) {
          HapticFeedback.selectionClick();
        }
        widget.onFocusChanged?.call(focused);
      },
      onKeyEvent: _handleKey,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        // The Focus node above is the single focus owner for this control, so
        // exclude the child subtree from focus traversal. This stops nested
        // Material widgets from adding a second D-pad stop / duplicate
        // highlight on the same control (see [excludeChildFocus]).
        child: ExcludeFocus(
          excluding: widget.excludeChildFocus,
          child: AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              const borderWidth = 2.5;
              // Pulse drives a soft focus glow so the highlight reads clearly
              // from across a room (10-foot UI). 1.0 when not animating.
              final pulse = widget.animate ? _pulseAnimation.value : 1.0;
              final showGlow = widget.animate && !widget.subtleFocus;
              final focusBorderColor =
                  colors.accent.withAlpha(widget.subtleFocus ? 80 : 255);
              return AnimatedScale(
                scale: _focused ? 1.04 : 1.0,
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: _focused
                      ? BoxDecoration(
                          borderRadius: widget.borderRadius,
                          border: Border.all(
                            color: focusBorderColor,
                            width: borderWidth,
                          ),
                          boxShadow: showGlow
                              ? [
                                  BoxShadow(
                                    color: colors.accent
                                        .withAlpha((70 * pulse).round()),
                                    blurRadius: 6 + 10 * pulse,
                                    spreadRadius: 1 + 1.5 * pulse,
                                  ),
                                ]
                              : null,
                        )
                      : BoxDecoration(
                          borderRadius: widget.borderRadius,
                          border: Border.all(
                            color: Colors.transparent,
                            width: borderWidth,
                          ),
                        ),
                  child: child,
                ),
              );
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Wraps a scrollable list / grid to provide D-pad hold-to-scroll
/// acceleration.  When a directional key is held down, focus traversal
/// progressively speeds up — instead of moving one item per key repeat,
/// it skips multiple items, making navigation through 50+ item lists viable.
///
/// On devices without a D-pad / gamepad this is effectively a no-op (the
/// Focus node never receives key-repeat events for directional keys).
class TvScrollAccelerator extends StatefulWidget {
  final Widget child;

  const TvScrollAccelerator({super.key, required this.child});

  @override
  State<TvScrollAccelerator> createState() => _TvScrollAcceleratorState();
}

class _TvScrollAcceleratorState extends State<TvScrollAccelerator> {
  int _repeatCount = 0;

  static final _directions = <LogicalKeyboardKey, TraversalDirection>{
    LogicalKeyboardKey.arrowUp: TraversalDirection.up,
    LogicalKeyboardKey.arrowDown: TraversalDirection.down,
    LogicalKeyboardKey.arrowLeft: TraversalDirection.left,
    LogicalKeyboardKey.arrowRight: TraversalDirection.right,
  };

  /// Progressive acceleration curve.
  /// Returns the number of **extra** focus steps to perform on top of
  /// the default one-item-per-repeat that Flutter's shortcut system
  /// already handles.
  int _extraSteps(int repeat) {
    if (repeat < 5) return 0; //  1× — normal one-at-a-time
    if (repeat < 12) return 1; // 2×
    if (repeat < 25) return 3; // 4×
    return 7; //                  8×
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final dir = _directions[event.logicalKey];
    if (dir == null) return KeyEventResult.ignored;

    if (event is KeyRepeatEvent) {
      _repeatCount++;
      final extra = _extraSteps(_repeatCount);
      if (extra > 0) {
        // Programmatically move focus by [extra] additional items.
        // focusInDirection is synchronous and updates primaryFocus
        // immediately, so sequential calls are safe.
        for (int i = 0; i < extra; i++) {
          primaryFocus?.focusInDirection(dir);
        }
      }
    } else if (event is KeyDownEvent) {
      _repeatCount = 0;
    } else if (event is KeyUpEvent) {
      _repeatCount = 0;
    }

    // Always return ignored so the framework's own directional-focus
    // shortcut still fires and moves focus by its normal +1 step.
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      canRequestFocus: false, // invisible to focus traversal
      skipTraversal: true,
      child: widget.child,
    );
  }
}

