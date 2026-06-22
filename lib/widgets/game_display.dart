import 'dart:async';
import 'dart:ffi' show Pointer, sizeOf;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mgba_bindings.dart';
import '../services/emulator_service.dart';
import '../utils/graphics_quality.dart';
import '../utils/tv_detector.dart';
import '../utils/theme.dart';

/// Method channel for texture creation/destruction (Android only).
const _channel = MethodChannel('com.yourmateapps.retropal/device');

/// Widget for displaying the emulator game screen.
///
/// On Android, uses a platform `Texture` widget backed by an ANativeWindow
/// for zero-copy frame delivery — no `decodeImageFromPixels`, no `ui.Image`
/// allocations, no GC pressure at 60 fps.
///
/// On other platforms (or if texture creation fails), falls back to the
/// traditional `decodeImageFromPixels` → `CustomPaint` pipeline.
class GameDisplay extends StatefulWidget {
  final EmulatorService emulator;
  final bool maintainAspectRatio;
  final bool enableFiltering;
  final bool enableNdsTouchOverlay;

  const GameDisplay({
    super.key,
    required this.emulator,
    this.maintainAspectRatio = true,
    this.enableFiltering = true,
    this.enableNdsTouchOverlay = true,
  });

  @override
  State<GameDisplay> createState() => _GameDisplayState();
}

class _GameDisplayState extends State<GameDisplay> {
  // ── Texture rendering (Android zero-copy path) ──
  int? _textureId;
  bool _textureRequested = false;

  /// Framebuffer dimensions the current texture was created with. Cores
  /// can change output size mid-game (SNES hi-res, SGB borders, PS1 video
  /// mode switches, melonDS layout flips); the monitor timer compares
  /// these against the live core dimensions and recreates the texture so
  /// stale dimensions never produce stretched/blurry output.
  int _texW = 0;
  int _texH = 0;

  // ── 1 Hz monitor: dynamic-resolution watch + adaptive governor ──
  Timer? _monitorTimer;

  /// TV adaptive final-scaling governor (Auto mode on Android TV).
  /// Samples fps + native retro_run headroom and promotes FilterQuality
  /// only after sustained headroom; demotes fast.
  final AdaptiveFilterQuality _adaptive = AdaptiveFilterQuality();

  /// Device pixel ratio, refreshed each build — display geometry is
  /// computed in PHYSICAL pixels so integer scaling lands exactly on the
  /// device pixel grid.
  double _dpr = 1.0;

  // Mild "bright and natural" matrix for hardware direct-present cores
  // (NDS / N64 / PS1).  Their pixels bypass the native software tuning in
  // yage_video.c, so the correction is applied at composite time instead.
  // Built once — values mirror the native software-core tuning.
  static final List<double> _naturalColorMatrix = buildNaturalColorMatrix();

  // Android TV stays on SHARP nearest / integer-aligned scaling — smooth
  // filtering is force-disabled here. The zero-copy Texture path now runs on
  // TV (fast, 60 Hz), but enabling the adaptive smooth-filter governor on top
  // of it was a mistake: TV upscales a low-res frame (160–256 px) to 1080p+,
  // and the TV prescale cap (2×) is far too small to keep that crisp, so the
  // GPU bicubic/bilinear softened the whole picture into "blurred colors".
  // Worse, the governor's tier-2 (FilterQuality.high) promotion measurably
  // stalled the frame loop (tv_logs: retro_run 4 ms → 19.7 ms, fps 60 → 46),
  // then demoted and flapped — so some scenes looked fine and others blurred.
  // Nearest + integer alignment is sharp, flap-free and the cheapest path, so
  // TV keeps it. The big TV win is the Texture path (60 Hz, no GC), not the
  // final filter. (Re-enabling smooth TV scaling would need a much higher
  // prescale budget and a non-flapping quality policy — see git history.)
  static const bool _disableTvGraphicsOptimizations = true;

  static bool _is3DPlatform(GamePlatform? p) =>
      p == GamePlatform.nds || p == GamePlatform.n64 || p == GamePlatform.ps1;

  /// Authentic Pixel behaviour: either the mode toggle, or the legacy
  /// Smooth Scaling flag being off (game_screen passes
  /// `settings.smoothScalingEnabled` as [GameDisplay.enableFiltering]).
  bool get _isAuthentic => !widget.enableFiltering;

  bool get _tvGraphicsOptimizationsOff =>
      _disableTvGraphicsOptimizations && TvDetector.isTV;

  /// Android TV opts out of every frontend graphics enhancement:
  /// no sharp-bilinear prescale, adaptive filtering, compositor color matrix,
  /// or antialiased final sampling. User-facing settings are left untouched;
  /// this is a device-class safety override.
  bool get _effectiveAuthentic => _isAuthentic || _tvGraphicsOptimizationsOff;

  /// Last laid-out texture bounds — input for the sharp-bilinear prescale
  /// factor computation (see [_pushDesiredPrescale]).
  Size? _texBounds;

  /// Sharp-bilinear TARGET total CPU expansion for the native blit: the
  /// framebuffer is expanded toward N× with hard nearest pixels on the CPU
  /// (via the edge-aware art-scaler + a nearest pass), then the GPU's smooth
  /// sampler covers only the remaining fractional stretch — pixel-art looks
  /// crisp AND smooth (no blocky squares, no soft mush).
  ///
  /// N ≈ round(physical scale × 0.70) — about 70% of the scale on the
  /// soft (0.5×, ~2× residual) → pixel-perfect (1.0×, 1× residual) axis, so the
  /// GPU sampler keeps only a ~1.3–1.6× stretch to smooth (sharp-bilinear,
  /// biased toward raw pixels). The native blit realizes it via an edge-aware
  /// base × nearest passes, switching to pure nearest near the top of the axis.
  /// Capped at 8 on phones (the native side additionally enforces a ~3.3 Mpx
  /// pixel budget) and 2 on TV (memory-bandwidth headroom on weak SoCs —
  /// gameplay speed first; TV keeps the old half-scale target). 1 (off)
  /// in Authentic
  /// Pixel Mode (raw pixels + FilterQuality.none need the unscaled
  /// buffer) and for 3D platforms (hardware direct-present frames never
  /// pass through the software blit; their software fallback is already
  /// smooth-filtered 3D content).
  int _desiredPrescale(Size bounds) {
    if (_effectiveAuthentic) return 1;
    // NDS / N64 are hardware direct-present (melonDS GL / mupen GL): their
    // frames render straight into the EGL window surface and never pass
    // through the software blit, so the CPU sharp-bilinear prescale is a no-op
    // for them. PS1 (Beetle PSX) now runs on the SOFTWARE renderer, whose
    // frames DO go through the software blit — so it benefits from the
    // prescale exactly like every other 2D core. Without this, PS1 was bicubic-
    // blurred from native 256/320×240 all the way up to full screen.
    final platform = widget.emulator.currentRom?.platform;
    if (platform == GamePlatform.nds || platform == GamePlatform.n64) {
      return 1;
    }
    final fbW = widget.emulator.screenWidth.toDouble();
    final fbH = widget.emulator.screenHeight.toDouble();
    if (fbW <= 0 || fbH <= 0 || bounds.width <= 0 || bounds.height <= 0) {
      return 1;
    }
    final physW = bounds.width * _dpr;
    final physH = bounds.height * _dpr;
    final scale = (physW / fbW) < (physH / fbH) ? (physW / fbW) : (physH / fbH);
    // Target TOTAL on-screen CPU expansion = a fraction of the physical
    // scale. The native blit realizes it with its edge-aware art-scaler
    // (Scale2x/3x) plus a hard-nearest pass, then the GPU bicubic finishes
    // the remaining fractional stretch (the "residual").
    //
    //   residual ≈ scale / target
    //
    //   * old soft Auto  → target ≈ scale/2   → residual ~2×   (blurry)
    //   * pixel-perfect  → target = scale      → residual 1×    (raw pixels)
    //
    // [kAutoExpandFraction] sits about two-thirds of the way toward pixel on
    // that axis: ~0.60× the scale → ~1.3–1.6× residual, so the pixel-art
    // staircase is mostly resolved with only light anti-aliasing on edges
    // (clearly biased toward pixel, short of raw). At higher fractions the
    // native blit drops the edge-aware art-scaler for pure nearest, so it
    // approaches pixel-perfect smoothly. Raise it toward 1.0 for crisper /
    // closer-to-pixel-perfect; lower it toward 0.5 for softer.
    //
    // TV stays on the old conservative ~scale/2 target (memory-bandwidth
    // headroom on weak SoCs); the native side floors art-scale cores to a
    // single Scale3x regardless, so TV output is unchanged.
    //
    // Cap: 2 on TV, 8 on phones (the native blit also clamps to a ~3.3 Mpx
    // output budget — see PRESCALE_MAX_PIXELS).
    const kAutoExpandFraction =
        0.60; // 0.5 = old soft Auto, 1.0 = pixel-perfect

    // Tiny-handheld softening (phones/tablets). Game Gear (160×144), GB/GBC
    // (160×144) and Neo Geo Pocket get blown up the most on a big phone
    // screen, so a pixel-biased prescale leaves visibly blocky pixels — the
    // "Game Gear Sonic looks too pixelated" report. Bias these toward MORE
    // GPU smoothing (lower expand fraction → larger bicubic residual) so they
    // read as a clean upscaled image rather than hard squares, while leaving
    // higher-resolution systems (NES/SNES/MD 256+px) crisp. TV keeps its own
    // conservative scale/2 target regardless.
    const kTinyHandheldExpandFraction = 0.42;
    final bool tinyHandheld =
        platform == GamePlatform.gg ||
        platform == GamePlatform.gb ||
        platform == GamePlatform.gbc ||
        platform == GamePlatform.ngp;
    final double expandFraction = tinyHandheld
        ? kTinyHandheldExpandFraction
        : kAutoExpandFraction;

    final cap = TvDetector.isTV ? 2 : 8;
    final n = TvDetector.isTV
        ? (scale / 2).ceil()
        : (scale * expandFraction).round();
    if (n < 1) return 1;
    return n > cap ? cap : n;
  }

  /// Recompute + push the prescale factor (de-duplicated downstream).
  /// Called after texture layout and from the 1 Hz monitor so framebuffer
  /// size changes and mode toggles converge within a second.
  void _pushDesiredPrescale() {
    if (_isDisposed || !mounted) return;
    if (_textureId == null) return; // software blit path not active
    final bounds = _texBounds;
    if (bounds == null) return;
    widget.emulator.setDisplayPrescale(_desiredPrescale(bounds));
  }

  // ── Fallback: decodeImageFromPixels path ──
  ui.Image? _frameImage;
  bool _isDisposed = false;

  Uint8List? _pendingPixels;
  int _pendingWidth = 0;
  int _pendingHeight = 0;
  bool _decoding = false;

  // Double-buffer pool to avoid per-frame Uint8List allocations
  Uint8List? _bufferA;
  Uint8List? _bufferB;
  bool _useBufferA = true;

  @override
  void initState() {
    super.initState();
    _tryCreateTexture();
    _startMonitorTimer();
  }

  /// 1 Hz monitor with two duties:
  ///
  ///  1. **Dynamic resolution** (Android): if the core's framebuffer size
  ///     no longer matches the dimensions the platform texture was created
  ///     with, destroy + recreate the texture. The native side already
  ///     handles surface geometry per blit / EGL surface swap, so the swap
  ///     is safe at any frame boundary; this keeps the Flutter-side
  ///     SurfaceTexture and our aspect/integer math in sync too.
  ///  2. **TV adaptive governor** (Android TV, Auto mode): sample fps +
  ///     retro_run headroom and adapt the final-scaling FilterQuality with
  ///     hysteresis — promote slowly after sustained headroom, demote
  ///     immediately on drops. Phones never adapt; they resolve statically.
  void _startMonitorTimer() {
    if (!Platform.isAndroid) return; // texture + TV paths are Android-only
    _monitorTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isDisposed || !mounted) return;
      final emulator = widget.emulator;
      if (!emulator.isRunning) return;

      // ── (1) Framebuffer dimension watch ──
      // Resize the SurfaceTexture IN PLACE rather than destroying and
      // recreating it. Recreation swaps the underlying ANativeWindow, which
      // orphans the native EGL window surface that the HW direct-present path
      // (NDS/N64/PS1) renders into — eglSwapBuffers then fails with
      // EGL_BAD_SURFACE forever and the screen goes black. This is exactly
      // what happens when melonDS reflows Top/Bottom → Left/Right on rotation
      // (256×384 → 512×192). The native producer already resizes its own
      // surface on a geometry change (EGL surface for HW, setBuffersGeometry
      // per blit for SW), so we only need to update the SurfaceTexture's
      // buffer size and let the new aspect ratio flow through on rebuild.
      final w = emulator.screenWidth;
      final h = emulator.screenHeight;
      if (_textureId != null && w > 0 && h > 0 && (w != _texW || h != _texH)) {
        debugPrint(
          'GameDisplay: framebuffer ${_texW}x$_texH → ${w}x$h — resizing in place',
        );
        _texW = w;
        _texH = h;
        try {
          _channel.invokeMethod('updateGameTextureSize', {
            'width': w,
            'height': h,
          });
        } catch (e) {
          debugPrint('GameDisplay: updateGameTextureSize failed — $e');
        }
        if (mounted) setState(() {});
        return; // skip governor this tick; sizes just changed
      }

      // ── (2) Sharp-bilinear prescale convergence ──
      _pushDesiredPrescale();

      // ── (3) TV adaptive final-scaling governor ──
      if (TvDetector.isTV &&
          !_tvGraphicsOptimizationsOff &&
          !_effectiveAuthentic &&
          emulator.settings.graphicsMode == GraphicsMode.autoOptimized) {
        final changed = _adaptive.addSample(
          fps: emulator.currentFps,
          targetFps: emulator.targetFps,
          headroom: emulator.retroRunHeadroom,
        );
        if (changed && mounted) setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(GameDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.emulator != widget.emulator) {
      // Emulator instance changed — destroy old texture, then recreate.
      // Reset _textureRequested so _tryCreateTexture can run (Kotlin
      // createTexture calls destroy() first, so we must clear our state).
      _destroyTexture();
      _textureRequested = false;
      _tryCreateTexture();
    }
  }

  /// `FilterQuality` for SMOOTH scaling branches (the geometry resolver
  /// decides whether a branch is smooth at all):
  ///
  ///   * Phones/tablets → `high` (Skia's bicubic — the least blurry smooth
  ///     upscale Flutter offers; trivial GPU cost at these sizes).
  ///   * Android TV → governed by [AdaptiveFilterQuality]: starts `low`
  ///     (the proven full-speed baseline), promotes to `medium`/`high`
  ///     only after sustained fps/headroom, demotes immediately on dips —
  ///     full-speed gameplay always wins over scaling quality on TV.
  FilterQuality _smoothFilterQuality() {
    if (_tvGraphicsOptimizationsOff) return FilterQuality.none;
    return TvDetector.isTV ? _adaptive.filterQuality : FilterQuality.high;
  }

  /// Single source of truth for where/how the framebuffer is drawn inside
  /// a widget of [bounds] logical pixels. Shared by the Texture path, the
  /// CustomPaint fallback, and the NDS touch overlay so they always agree.
  ///
  /// All cores use integer-aligned geometry (pixel-perfect physical-pixel
  /// alignment, same rect as Authentic) with smooth filtering. With the
  /// framebuffer prescaled to the matching integer factor the surface maps
  /// 1:1 onto this rect — crisp, no bicubic softening or ringing. 3D cores
  /// additionally benefit from enhanced internal resolution (2×).
  DisplayGeometry _resolveGeometry(Size bounds) {
    final emulator = widget.emulator;
    return resolveDisplayGeometry(
      fbWidth: emulator.screenWidth.toDouble(),
      fbHeight: emulator.screenHeight.toDouble(),
      bounds: bounds,
      devicePixelRatio: _dpr,
      authentic: _effectiveAuthentic,
      integerAlignAuto: true,
      preserveAspect: widget.maintainAspectRatio || _effectiveAuthentic,
      smoothQuality: _smoothFilterQuality(),
    );
  }

  /// Whether to wrap the display in the mild bright/natural color matrix.
  ///
  /// Only for hardware direct-present platforms (NDS / N64 / PS1): their
  /// frames go core → EGL window surface → Texture widget without ever
  /// touching the native software conversion in yage_video.c, so the
  /// compositor-level ColorFiltered is the ONLY place color tuning can
  /// happen for them (and it covers the CustomPaint/readback fallback for
  /// those platforms too, which equally bypasses the native tuning).
  /// Software-rendered cores are tuned natively instead — applying the
  /// matrix to them as well would double-tune.
  ///
  /// Never applied in Authentic Pixel Mode (authentic = original colors).
  bool get _applyCompositorColorTuning {
    if (_effectiveAuthentic) return false;
    if (widget.emulator.settings.graphicsMode != GraphicsMode.autoOptimized) {
      return false;
    }
    return _is3DPlatform(widget.emulator.currentRom?.platform);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _monitorTimer?.cancel();
    _monitorTimer = null;
    // Only clear if we're the current callback
    if (widget.emulator.onFrame == _onFrame) {
      widget.emulator.onFrame = null;
    }
    _frameImage?.dispose();
    _destroyTexture();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Texture path (Android)
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _tryCreateTexture() async {
    if (!Platform.isAndroid) {
      // Texture rendering not supported — use fallback
      _registerFallbackCallback();
      return;
    }
    // ── 32-bit ARM: skip the zero-copy SurfaceTexture path ──
    // Flutter's external-texture consumer (the "JNISurfaceTexture" thread)
    // uploads the producer buffer to a GL texture with vectorised (NEON)
    // copies. On 32-bit ARM (armeabi-v7a) those can hit a misaligned address
    // and the kernel raises SIGBUS / BUS_ADRALN — a hard native crash. This is
    // exactly the Road Rash (Genesis, 320×224) crash on the 32-bit Sony BRAVIA:
    // it died a few seconds in, right after a 256×192 → 320×224 video-mode
    // change. 64-bit ARM (arm64-v8a) tolerates unaligned access, so the fault
    // cannot occur there. The architecture — not the device being a TV — is
    // what matters, so gate on pointer width: this also protects any 32-bit
    // phone. 32-bit devices use the (now full-rate) callback path below, which
    // never touches an external SurfaceTexture.
    //
    // If a 64-bit TV ever shows SurfaceTexture instability, tighten this to
    // `if (sizeOf<Pointer>() < 8 || TvDetector.isTV)`.
    final bool is64BitAbi = sizeOf<Pointer>() >= 8;
    if (!is64BitAbi) {
      widget.emulator.setTextureRendering(false);
      debugPrint(
        'GameDisplay: 32-bit ABI — zero-copy texture path disabled '
        '(SurfaceTexture SIGBUS risk); using full-rate callback fallback',
      );
      _registerFallbackCallback();
      return;
    }
    // 64-bit ARM (phones + modern TVs): zero-copy Texture path — full-rate
    // GPU compositing, no per-frame ui.Image allocation / GC. Stable here
    // because arm64 has no unaligned-access fault. If createGameTexture ever
    // fails we still fall back to the (full-rate) callback path below.
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
        // Widget was disposed while we awaited — always destroy to avoid
        // orphaned ANativeWindow / TextureRegistry entry.
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
          _texW = w;
          _texH = h;
        });
        widget.emulator.setTextureRendering(true);
        debugPrint('GameDisplay: Texture widget created (id=$id, ${w}x$h)');
      } else {
        // Fallback
        debugPrint(
          'GameDisplay: Texture creation returned null — falling back',
        );
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
      _texW = 0;
      _texH = 0;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  Fallback path (decodeImageFromPixels)
  // ═══════════════════════════════════════════════════════════════════

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

    // Pre-scale during decode on SMOOTH (Auto) paths for tiny retro
    // framebuffers: expanding the pixels first means the final filtered
    // stretch only covers the remaining fraction, which keeps pixel-art
    // edges defined under the smoothening filter ("sharp bilinear"-ish)
    // while still looking smooth. 5× approximates the native blit's
    // toward-pixel target (~0.70× the typical on-screen scale → ~1.3–1.5×
    // GPU residual). Skipped on TV (large per-frame ARGB allocations) and in
    // Authentic Pixel Mode, where the integer-scaling math needs the RAW
    // framebuffer and nearest sampling must see original pixels (pre-scaling
    // would soften them).
    const int kFallbackPrescale = 5;
    final bool prescale =
        width <= 300 &&
        height <= 300 &&
        !TvDetector.isTV &&
        !_effectiveAuthentic;
    final completer = Completer<ui.Image>();
    if (prescale) {
      ui.decodeImageFromPixels(
        pixelsCopy,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
        targetWidth: width * kFallbackPrescale,
        targetHeight: height * kFallbackPrescale,
      );
    } else {
      ui.decodeImageFromPixels(
        pixelsCopy,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
    }

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

  // ═══════════════════════════════════════════════════════════════════
  //  Build
  // ═══════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final isNdsGame = widget.emulator.currentRom?.platform == GamePlatform.nds;

    // Physical pixels per logical pixel — all display geometry is computed
    // on the physical grid so integer scaling has no fractional offsets.
    _dpr = MediaQuery.of(context).devicePixelRatio;

    Widget display = Container(
      color: colors.backgroundDark,
      child: widget.maintainAspectRatio && !isNdsGame
          ? AspectRatio(
              aspectRatio:
                  widget.emulator.screenWidth / widget.emulator.screenHeight,
              child: _buildDisplay(),
            )
          : _buildDisplay(),
    );

    // Mild bright/natural color correction for hardware direct-present
    // platforms (NDS / N64 / PS1). Applied at the compositor level so it
    // affects the Android Texture (EGL direct-present) path and the
    // CustomPaint fallback identically. Software cores are tuned natively
    // in yage_video.c instead (see _applyCompositorColorTuning).
    if (_applyCompositorColorTuning) {
      display = ColorFiltered(
        colorFilter: ColorFilter.matrix(_naturalColorMatrix),
        child: display,
      );
    }

    // NDS games need a touch overlay on the bottom screen. The libretro
    // melonDS core hands us a single framebuffer with both screens packed
    // (256×384 stacked in portrait, 512×192 side-by-side in landscape) and
    // expects libretro pointer coordinates normalized to -32767..32767.
    if (widget.enableNdsTouchOverlay && isNdsGame) {
      display = _NdsTouchOverlay(
        emulator: widget.emulator,
        // The overlay must agree with the render path about where the
        // framebuffer actually is (integer-scaled with borders in
        // Authentic Pixel Mode, filled in Auto) or stylus taps would
        // land on the wrong DS pixels.
        displayRect: (size) => _resolveGeometry(size).rect,
        child: display,
      );
    }

    // Isolate the game display from menu/overlay repaints so in-game menu
    // animations don't force the emulator surface to repaint. This is useful
    // on every Android form factor, not just TV.
    display = RepaintBoundary(child: display);

    return display;
  }

  Widget _buildDisplay() {
    // ── Texture path (Android zero-copy) ──
    // Guard: never build texture UI after dispose (async create may complete late).
    if (!_isDisposed && _textureId != null) {
      return _buildTextureDisplay();
    }

    // ── Fallback path (decodeImageFromPixels) ──
    if (_frameImage == null) {
      return _buildPlaceholder();
    }

    return CustomPaint(
      painter: _GamePainter(
        image: _frameImage!,
        // Same geometry resolver as the Texture path — the painter
        // recomputes per paint() because geometry depends on canvas size.
        devicePixelRatio: _dpr,
        authentic: _effectiveAuthentic,
        integerAlignAuto: true,
        preserveAspect: widget.maintainAspectRatio || _effectiveAuthentic,
        smoothQuality: _smoothFilterQuality(),
      ),
      size: Size.infinite,
    );
  }

  Widget _buildTextureDisplay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounds = Size(constraints.maxWidth, constraints.maxHeight);
        final geo = _resolveGeometry(bounds);

        // Feed the sharp-bilinear prescale with the actual on-screen size
        // (pushed post-frame; de-duplicated, so this is cheap).
        _texBounds = bounds;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _pushDesiredPrescale(),
        );

        final texture = Texture(
          textureId: _textureId!,
          filterQuality: geo.filterQuality,
        );

        // Full-bleed (smooth/fill branches): no positioning needed.
        if ((geo.rect.width - bounds.width).abs() < 0.75 &&
            (geo.rect.height - bounds.height).abs() < 0.75) {
          return texture;
        }

        // Letterboxed (integer-scaled / aspect-fit): place the texture at
        // the exact physically-aligned rect, black borders around it.
        return Container(
          color: const Color(0xFF000000),
          child: Stack(
            children: [Positioned.fromRect(rect: geo.rect, child: texture)],
          ),
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

/// Fallback painter (decodeImageFromPixels path).
///
/// Uses the SAME `resolveDisplayGeometry` as the Android Texture path so
/// both pipelines place and sample the framebuffer identically: integer
/// physical-pixel scaling in Authentic Pixel Mode, and integer-aligned
/// (prescale-matched, crisp) geometry with smooth filtering in Auto.
class _GamePainter extends CustomPainter {
  final ui.Image image;
  final double devicePixelRatio;
  final bool authentic;
  final bool integerAlignAuto;
  final bool preserveAspect;
  final FilterQuality smoothQuality;

  _GamePainter({
    required this.image,
    required this.devicePixelRatio,
    required this.authentic,
    this.integerAlignAuto = false,
    required this.preserveAspect,
    required this.smoothQuality,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );

    final geo = resolveDisplayGeometry(
      fbWidth: image.width.toDouble(),
      fbHeight: image.height.toDouble(),
      bounds: size,
      devicePixelRatio: devicePixelRatio,
      authentic: authentic,
      integerAlignAuto: integerAlignAuto,
      preserveAspect: preserveAspect,
      smoothQuality: smoothQuality,
    );

    // Fill the letterbox bars with black when the dest rect doesn't cover
    // the full canvas.
    if (geo.rect.left > 0 ||
        geo.rect.top > 0 ||
        geo.rect.right < size.width ||
        geo.rect.bottom < size.height) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF000000),
      );
    }

    final paint = Paint()
      ..filterQuality = geo.filterQuality
      ..isAntiAlias = geo.antiAlias;
    canvas.drawImageRect(image, srcRect, geo.rect, paint);
  }

  @override
  bool shouldRepaint(_GamePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.devicePixelRatio != devicePixelRatio ||
        oldDelegate.authentic != authentic ||
        oldDelegate.preserveAspect != preserveAspect ||
        oldDelegate.smoothQuality != smoothQuality;
  }
}

/// FPS counter overlay
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

// ═══════════════════════════════════════════════════════════════════════
//  NDS touch overlay (melonDS bottom-screen stylus input)
// ═══════════════════════════════════════════════════════════════════════
//
// The melonDS libretro core renders both DS screens into a single
// framebuffer, packed either Top/Bottom (256×384 portrait) or
// Left/Right (512×192 landscape).  We use the *current* screenWidth/
// screenHeight from EmulatorService to detect the layout and translate
// pointer drags inside the bottom-screen region into the 256×192 pixel
// space the core expects via `coreSetTouch`.

class _NdsTouchOverlay extends StatefulWidget {
  final EmulatorService emulator;
  final Widget child;

  /// Returns the rect (in this widget's logical coordinates) where the
  /// framebuffer is actually displayed. Supplied by [GameDisplay] from the
  /// shared geometry resolver so the overlay agrees with the render path
  /// (integer-scaled with black borders in Authentic Pixel Mode, filled
  /// in Auto).
  final Rect Function(Size widgetSize) displayRect;

  const _NdsTouchOverlay({
    required this.emulator,
    required this.displayRect,
    required this.child,
  });

  @override
  State<_NdsTouchOverlay> createState() => _NdsTouchOverlayState();
}

class _NdsTouchOverlayState extends State<_NdsTouchOverlay> {
  bool _touchActive = false;

  /// Whether the framebuffer is in side-by-side (landscape) layout.
  bool get _isLandscapeLayout =>
      widget.emulator.screenWidth >= widget.emulator.screenHeight;

  /// Translate a pointer position inside the displayed widget into
  /// libretro pointer coordinates. Returns null when the pointer is
  /// outside the NDS bottom-screen region.
  ({int x, int y})? _localToPointer({
    required Offset local,
    required Size widgetSize,
  }) {
    final fbW = widget.emulator.screenWidth.toDouble();
    final fbH = widget.emulator.screenHeight.toDouble();
    if (fbW <= 0 || fbH <= 0) return null;

    // Where the framebuffer is actually drawn (integer-scaled, aspect-fit
    // or filled) — from the same geometry resolver as the render path.
    final rect = widget.displayRect(widgetSize);
    if (rect.width <= 0 || rect.height <= 0) return null;

    final px = (local.dx - rect.left) / rect.width * fbW;
    final py = (local.dy - rect.top) / rect.height * fbH;
    if (px < 0 || py < 0 || px >= fbW || py >= fbH) return null;

    // Identify bottom-screen region inside the framebuffer.  The melonDS
    // core receives normalized coordinates for the full framebuffer, so
    // we only use this region check to decide whether a stylus is down.
    if (_isLandscapeLayout) {
      // Left/Right layout: 512×192 — top screen on left, bottom on right
      // (melonDS default).  Reject anything in the left half.
      if (px < fbW / 2.0) return null;
    } else {
      // Top/Bottom layout: 256×384 — top screen on top half.
      if (py < fbH / 2.0) return null;
    }

    int normalizePointer(double pixel, double extent) {
      if (extent <= 1.0) return 0;
      final clamped = pixel.clamp(0.0, extent - 1.0).toDouble();
      final value = ((clamped / (extent - 1.0)) * 65534.0 - 32767.0).round();
      return value.clamp(-32767, 32767).toInt();
    }

    return (x: normalizePointer(px, fbW), y: normalizePointer(py, fbH));
  }

  void _onDown(Offset local, Size size) {
    final pt = _localToPointer(local: local, widgetSize: size);
    if (pt == null) return;
    widget.emulator.setTouch(pt.x, pt.y, true);
    _touchActive = true;
  }

  void _onMove(Offset local, Size size) {
    final pt = _localToPointer(local: local, widgetSize: size);
    if (pt == null) {
      // Pointer moved outside the bottom screen — treat as release so the
      // core doesn't keep latching the last reported coordinate.
      if (_touchActive) {
        widget.emulator.setTouch(0, 0, false);
        _touchActive = false;
      }
      return;
    }
    widget.emulator.setTouch(pt.x, pt.y, true);
    _touchActive = true;
  }

  void _onUp() {
    if (_touchActive) {
      widget.emulator.setTouch(0, 0, false);
      _touchActive = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => _onDown(e.localPosition, size),
          onPointerMove: (e) => _onMove(e.localPosition, size),
          onPointerUp: (_) => _onUp(),
          onPointerCancel: (_) => _onUp(),
          child: widget.child,
        );
      },
    );
  }
}
