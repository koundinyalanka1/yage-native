import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/emulator_service.dart';
import '../utils/tv_detector.dart';
import '../utils/theme.dart';

const _channel = MethodChannel('com.yourmateapps.retropal/device');

class GameDisplay extends StatefulWidget {
  final EmulatorService emulator;
  final bool maintainAspectRatio;
  final bool enableFiltering;

  const GameDisplay({
    super.key,
    required this.emulator,
    this.maintainAspectRatio = true,
    this.enableFiltering = true,
  });

  @override
  State<GameDisplay> createState() => _GameDisplayState();
}

class _GameDisplayState extends State<GameDisplay> {
  int? _textureId;
  bool _textureRequested = false;
  ui.Image? _frameImage;
  bool _isDisposed = false;

  Uint8List? _pendingPixels;
  int _pendingWidth = 0;
  int _pendingHeight = 0;
  bool _decoding = false;
  Uint8List? _bufferA;
  Uint8List? _bufferB;
  bool _useBufferA = true;

  @override
  void initState() {
    super.initState();
    _tryCreateTexture();
  }

  @override
  void didUpdateWidget(GameDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.emulator != widget.emulator) {
      _destroyTexture();
      _textureRequested = false;
      _tryCreateTexture();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    if (widget.emulator.onFrame == _onFrame) {
      widget.emulator.onFrame = null;
    }
    _frameImage?.dispose();
    _destroyTexture();
    super.dispose();
  }

  Future<void> _tryCreateTexture() async {
    if (!Platform.isAndroid) {
      _registerFallbackCallback();
      return;
    }
    if (_textureRequested) return;
    _textureRequested = true;

    try {
      final w = widget.emulator.screenWidth;
      final h = widget.emulator.screenHeight;

      final id = await _channel.invokeMethod<int>('createGameTexture', {
        'width': w,
        'height': h,
      });

      if (_isDisposed) {
        if (id != null) {
          try {
            _channel.invokeMethod('destroyGameTexture');
          } catch (e) {
            debugPrint('GameDisplay: destroyGameTexture (dispose path) — $e');
          }
        }
        _textureRequested = false;
        return;
      }

      if (id != null && mounted) {
        setState(() {
          _textureId = id;
        });
        widget.emulator.setTextureRendering(true);
        debugPrint('GameDisplay: Texture widget created (id=$id, ${w}x$h)');
      } else {
        debugPrint('GameDisplay: Texture creation returned null — falling back');
        _registerFallbackCallback();
      }
    } catch (e) {
      debugPrint('GameDisplay: Texture creation failed ($e) — falling back');
      if (!_isDisposed) {
        _registerFallbackCallback();
      }
    }
  }

  void _destroyTexture() {
    if (_textureId != null) {
      widget.emulator.setTextureRendering(false);
      try {
        _channel.invokeMethod('destroyGameTexture');
      } catch (e) {
        debugPrint('GameDisplay: destroyGameTexture platform error — $e');
      }
      _textureId = null;
      _textureRequested = false;
    }
  }

  void _registerFallbackCallback() {
    widget.emulator.onFrame = _onFrame;
  }

  Uint8List _acquireBuffer(int size) {
    if (_useBufferA) {
      if (_bufferA == null || _bufferA!.length != size) {
        _bufferA = Uint8List(size);
      }
      _useBufferA = false;
      return _bufferA!;
    } else {
      if (_bufferB == null || _bufferB!.length != size) {
        _bufferB = Uint8List(size);
      }
      _useBufferA = true;
      return _bufferB!;
    }
  }

  void _onFrame(Uint8List pixels, int width, int height) {
    if (_isDisposed) return;

    _pendingPixels = pixels;
    _pendingWidth = width;
    _pendingHeight = height;

    if (!_decoding) {
      _decodeFrame();
    }
  }

  void _decodeFrame() async {
    if (_isDisposed || _pendingPixels == null) return;

    _decoding = true;
    final pixels = _pendingPixels!;
    final width = _pendingWidth;
    final height = _pendingHeight;
    _pendingPixels = null;

    final pixelsCopy = _acquireBuffer(pixels.length);
    pixelsCopy.setAll(0, pixels);

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixelsCopy,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      targetWidth: width * 3,
      targetHeight: height * 3,
    );

    final newImage = await completer.future;

    if (_isDisposed) {
      newImage.dispose();
      _decoding = false;
      return;
    }

    final oldImage = _frameImage;
    if (mounted) {
      setState(() {
        _frameImage = newImage;
      });
    }
    oldImage?.dispose();

    _decoding = false;

    if (_pendingPixels != null) {
      _decodeFrame();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);

    Widget display = Container(
      color: colors.backgroundDark,
      child: widget.maintainAspectRatio
          ? AspectRatio(
              aspectRatio: widget.emulator.screenWidth /
                  widget.emulator.screenHeight,
              child: _buildDisplay(),
            )
          : _buildDisplay(),
    );
    if (TvDetector.isTV) {
      display = RepaintBoundary(child: display);
    }

    return display;
  }

  Widget _buildDisplay() {
    if (!_isDisposed && _textureId != null) {
      return _buildTextureDisplay();
    }
    if (_frameImage == null) {
      return _buildPlaceholder();
    }

    return CustomPaint(
      painter: _GamePainter(
        image: _frameImage!,
        enableFiltering: widget.enableFiltering,
      ),
      size: Size.infinite,
    );
  }

  Widget _buildTextureDisplay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (widget.enableFiltering) {
          return Texture(
            textureId: _textureId!,
            filterQuality: FilterQuality.high,
          );
        }
        final imgW = widget.emulator.screenWidth.toDouble();
        final imgH = widget.emulator.screenHeight.toDouble();

        final scaleX = (constraints.maxWidth / imgW).floor();
        final scaleY = (constraints.maxHeight / imgH).floor();
        final scale = scaleX < scaleY ? scaleX : scaleY;

        if (scale >= 1) {
          final destW = imgW * scale;
          final destH = imgH * scale;

          return Container(
            color: const Color(0xFF000000),
            child: Center(
              child: SizedBox(
                width: destW,
                height: destH,
                child: Texture(
                  textureId: _textureId!,
                  filterQuality: FilterQuality.none,
                ),
              ),
            ),
          );
        }
        return Texture(
          textureId: _textureId!,
          filterQuality: FilterQuality.none,
        );
      },
    );
  }

  Widget _buildPlaceholder() {
    final colors = AppColorTheme.of(context);
    return Container(
      color: colors.backgroundDark,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videogame_asset,
              size: 64,
              color: colors.primary.withAlpha(128),
            ),
            const SizedBox(height: 16),
            Text(
              'NO SIGNAL',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: colors.textMuted.withAlpha(128),
                letterSpacing: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GamePainter extends CustomPainter {
  final ui.Image image;
  final bool enableFiltering;

  _GamePainter({
    required this.image,
    required this.enableFiltering,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(
      0, 0,
      image.width.toDouble(),
      image.height.toDouble(),
    );

    if (enableFiltering) {
      final paint = Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true;
      final destRect = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(image, srcRect, destRect, paint);
    } else {
      final paint = Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false;

      final imgW = image.width.toDouble();
      final imgH = image.height.toDouble();
      final scaleX = (size.width / imgW).floor();
      final scaleY = (size.height / imgH).floor();
      final scale = scaleX < scaleY ? scaleX : scaleY;

      if (scale >= 1) {
        final destW = imgW * scale;
        final destH = imgH * scale;
        final offsetX = (size.width - destW) / 2;
        final offsetY = (size.height - destH) / 2;
        if (offsetX > 0 || offsetY > 0) {
          canvas.drawRect(
            Rect.fromLTWH(0, 0, size.width, size.height),
            Paint()..color = const Color(0xFF000000),
          );
        }

        final destRect = Rect.fromLTWH(offsetX, offsetY, destW, destH);
        canvas.drawImageRect(image, srcRect, destRect, paint);
      } else {
        final destRect = Rect.fromLTWH(0, 0, size.width, size.height);
        canvas.drawImageRect(image, srcRect, destRect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GamePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.enableFiltering != enableFiltering;
  }
}

class FpsOverlay extends StatelessWidget {
  final double fps;

  const FpsOverlay({super.key, required this.fps});

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.backgroundDark.withAlpha(204),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: fps >= 55
              ? colors.success
              : fps >= 30
                  ? colors.warning
                  : colors.error,
          width: 1,
        ),
      ),
      child: Text(
        '${fps.toStringAsFixed(1)} FPS',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
      ),
    );
  }
}
