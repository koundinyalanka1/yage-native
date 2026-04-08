import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/tv_detector.dart';
import '../utils/theme.dart';

class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onBack;
  final bool autofocus;
  final FocusNode? focusNode;
  final BorderRadius borderRadius;

  final bool animate;

  final bool subtleFocus;

  final ValueChanged<bool>? onFocusChanged;

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

  static final _selectKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.gameButtonStart,
    LogicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaPlay,
  };

  static final _backKeys = {
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.gameButtonB,
    LogicalKeyboardKey.goBack,
    LogicalKeyboardKey.browserBack,
  };

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
        child: AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            const borderWidth = 2.5;
            final focusBorderColor = colors.accent.withAlpha(widget.subtleFocus ? 80 : 255);
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
    );
  }
}

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

  int _extraSteps(int repeat) {
    if (repeat < 5) return 0; 
    if (repeat < 12) return 1; 
    if (repeat < 25) return 3; 
    return 7; 
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final dir = _directions[event.logicalKey];
    if (dir == null) return KeyEventResult.ignored;

    if (event is KeyRepeatEvent) {
      _repeatCount++;
      final extra = _extraSteps(_repeatCount);
      if (extra > 0) {
        for (int i = 0; i < extra; i++) {
          primaryFocus?.focusInDirection(dir);
        }
      }
    } else if (event is KeyDownEvent) {
      _repeatCount = 0;
    } else if (event is KeyUpEvent) {
      _repeatCount = 0;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      canRequestFocus: false, 
      skipTraversal: true,
      child: widget.child,
    );
  }
}

class AnimatedBuilder extends StatelessWidget {
  final Animation<double> animation;
  final Widget Function(BuildContext context, Widget? child) builder;
  final Widget? child;

  const AnimatedBuilder({
    super.key,
    required this.animation,
    required this.builder,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder._internal(
      animation: animation,
      builder: builder,
      child: child,
    );
  }

  static Widget _internal({
    required Animation<double> animation,
    required Widget Function(BuildContext, Widget?) builder,
    Widget? child,
  }) {
    return _AnimatedBuilderWidget(
      animation: animation,
      builder: builder,
      child: child,
    );
  }
}

class _AnimatedBuilderWidget extends AnimatedWidget {
  final Widget Function(BuildContext, Widget?) builder;
  final Widget? child;

  const _AnimatedBuilderWidget({
    required Animation<double> animation,
    required this.builder,
    this.child,
  }) : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    return builder(context, child);
  }
}
