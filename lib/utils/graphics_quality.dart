import 'dart:math' as math;
import 'dart:ui' show FilterQuality, Rect, Size;

import 'package:flutter/foundation.dart';

import 'tv_detector.dart';

/// ═════════════════════════════════════════════════════════════════════
///  RetroPal graphics policy — "automatic like a console"
///
///  Users see exactly ONE concept: **Auto Optimized** (default), plus one
///  optional purist toggle: **Authentic Pixel Mode**.  Everything else —
///  per-core internal resolution, filter quality, integer scaling, TV
///  adaptation — is resolved internally from device class + platform.
/// ═════════════════════════════════════════════════════════════════════

/// User-facing graphics behaviour. Exactly two modes:
///
///  * [autoOptimized] (default) — best graphics for each system and
///    device, chosen automatically. 2D systems get crisp, non-blurry
///    scaling; 3D systems get enhanced internal resolution on capable
///    phones/tablets; Android TV stays performance-first with adaptive
///    final scaling.
///  * [authenticPixel] — purist mode: exact original pixels, strict
///    integer scaling in *physical* device pixels, no filtering, no
///    anti-aliasing, no color tuning, black borders as needed.
enum GraphicsMode { autoOptimized, authenticPixel }

/// Parse the persisted `graphicsQuality` string.
///
/// Backward compatible with every value ever stored:
///   * legacy 'pixel'                  → [GraphicsMode.authenticPixel]
///   * legacy 'auto' / 'max' / 'sharp' → [GraphicsMode.autoOptimized]
///   * null / unknown                  → [GraphicsMode.autoOptimized]
GraphicsMode parseGraphicsMode(String? value) {
  return value == 'pixel'
      ? GraphicsMode.authenticPixel
      : GraphicsMode.autoOptimized;
}

/// Storage string for [mode]. Reuses the legacy 'auto' / 'pixel' values so
/// settings written by this version load fine in older builds too.
String graphicsModeToStorage(GraphicsMode mode) =>
    mode == GraphicsMode.authenticPixel ? 'pixel' : 'auto';

/// ═════════════════════════════════════════════════════════════════════
///  Internal per-core preset resolution
/// ═════════════════════════════════════════════════════════════════════

/// Internal rendering preset for the loaded core. Never shown to users.
enum CoreGraphicsPreset {
  /// Strict pixel purist: native core options, integer physical-pixel
  /// final scaling, FilterQuality.none, no color tuning.
  authenticPixel,

  /// 2D / pixel-art systems in Auto: native core resolution, smooth final
  /// scaling (no blocky pixels), mild natural color tuning.
  standard2d,

  /// 3D systems (NDS / N64 / PS1) in Auto on phones/tablets: enhanced
  /// internal resolution + quality core options, smooth final scaling.
  enhanced3d,

  /// 3D systems in Auto on Android TV: conservative native core options
  /// (full speed first) + adaptive final-scaling quality governor.
  tvAdaptive3d,
}

/// Resolve the internal preset from the user mode + platform class.
///
/// [is3D] — whether the loaded platform is hardware-3D (NDS / N64 / PS1).
/// Core options derived from this preset are LOAD-TIME ONLY: they are
/// applied before `retro_load_game` and never changed mid-game (3D cores
/// need a reload / GL context rebuild for them). Only *final scaling*
/// adapts at runtime.
CoreGraphicsPreset resolveCorePreset({
  required GraphicsMode mode,
  required bool is3D,
  bool? isTV,
}) {
  if (mode == GraphicsMode.authenticPixel) {
    return CoreGraphicsPreset.authenticPixel;
  }
  if (!is3D) return CoreGraphicsPreset.standard2d;
  return (isTV ?? TvDetector.isTV)
      ? CoreGraphicsPreset.tvAdaptive3d
      : CoreGraphicsPreset.enhanced3d;
}

/// ═════════════════════════════════════════════════════════════════════
///  Final-scaling geometry — physical-pixel aware, shared by the Android
///  Texture path, the CustomPaint fallback, and the NDS touch overlay so
///  all three always agree on where the framebuffer is on screen.
/// ═════════════════════════════════════════════════════════════════════

/// How the framebuffer should be placed and sampled inside its widget.
class DisplayGeometry {
  const DisplayGeometry({
    required this.rect,
    required this.filterQuality,
    required this.antiAlias,
    required this.integerScaled,
  });

  /// Destination rect in LOGICAL pixels, relative to the widget origin.
  /// Offsets/sizes are aligned to the physical pixel grid when
  /// [integerScaled] is true.
  final Rect rect;

  final FilterQuality filterQuality;
  final bool antiAlias;

  /// True when the framebuffer maps 1:N onto whole physical pixels.
  final bool integerScaled;
}

/// Compute final-scaling geometry for one frame.
///
///  * [fbWidth]/[fbHeight] — framebuffer size in pixels.
///  * [bounds] — widget size in logical pixels.
///  * [devicePixelRatio] — physical pixels per logical pixel.
///  * [authentic] — Authentic Pixel Mode: strict integer physical-pixel
///    scaling, FilterQuality.none, no AA, black borders. When even 1×
///    doesn't fit, aspect-fit with nearest (never blur, never stretch).
///  * [integerAlignAuto] — when true AND [authentic] is false, Auto mode
///    uses the same integer-scaled physical-pixel-aligned geometry as
///    Authentic (pixel-perfect positioning, black borders) but with smooth
///    filtering on top (bicubic on phones, adaptive governor on TV). The
///    framebuffer is prescaled (in the native blit) toward ~0.70× this scale
///    (sharp-bilinear, biased toward pixel on the soft→pixel axis), so the
///    bicubic keeps only a ~1.3–1.6× residual to smooth the pixel-art staircase
///    while the aligned rect prevents shimmer. When false, Auto fills its
///    bounds (legacy fallback, not used by default).
///  * [preserveAspect] — honour aspect ratio in the authentic too-small
///    fallback (false = user disabled Maintain Aspect Ratio → stretch).
///  * [smoothQuality] — FilterQuality for Auto (phone: high, TV: adaptive
///    governor tier).
///
/// AUTO + INTEGER-ALIGNED (all cores, all devices): pixel-perfect rect (each
/// game pixel covers exactly k×k physical pixels — maximum geometric
/// precision, no shimmer) with the framebuffer prescaled to ~0.70× that
/// factor (biased toward pixel-perfect) so the bicubic actively smooths the
/// upscale with a ~1.3–1.6× residual (no hard nearest-neighbour staircase). 3D
/// cores additionally benefit from device-tiered enhanced internal resolution
/// (2×–4×).
///
/// AUTO + FILL (legacy fallback, integerAlignAuto=false): smooth fill of
/// the aspect-managed bounds. Not used by default.
DisplayGeometry resolveDisplayGeometry({
  required double fbWidth,
  required double fbHeight,
  required Size bounds,
  required double devicePixelRatio,
  required bool authentic,
  bool integerAlignAuto = false,
  required bool preserveAspect,
  required FilterQuality smoothQuality,
}) {
  final full = Rect.fromLTWH(0, 0, bounds.width, bounds.height);

  // ── Auto Optimized (fill path): 3D cores & TV smooth-fill their
  // aspect-managed bounds. ──
  if (!authentic && !integerAlignAuto) {
    return DisplayGeometry(
      rect: full,
      filterQuality: smoothQuality,
      antiAlias: true,
      integerScaled: false,
    );
  }

  // ── Auto Optimized (integer-aligned path) OR Authentic Pixel Mode ──
  // Both share the same integer-scaled physical-pixel-aligned geometry;
  // the only difference is filter quality (smooth vs nearest).

  // Degenerate input (no frame yet / zero-sized widget): draw full-bounds;
  // real geometry kicks in on the next layout/frame.
  if (fbWidth <= 0 ||
      fbHeight <= 0 ||
      bounds.width <= 0 ||
      bounds.height <= 0) {
    return DisplayGeometry(
      rect: full,
      filterQuality: authentic ? FilterQuality.none : smoothQuality,
      antiAlias: !authentic,
      integerScaled: false,
    );
  }

  final dpr = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
  final physW = bounds.width * dpr;
  final physH = bounds.height * dpr;
  final scale = math.min(physW / fbWidth, physH / fbHeight);
  final k = scale.floor();

  // Filter policy: Authentic = hard nearest; Auto integer-aligned = smooth
  // bicubic (same geometry, continuous pixels).
  final fq = authentic ? FilterQuality.none : smoothQuality;
  final aa = !authentic;

  // Integer scaling is a quality nicety, not a size policy. Flooring the
  // scale can throw away a LOT of screen: a 640×480 3D core on a 1080-px
  // wide phone in portrait floors 1.69× down to 1× — the game renders at
  // 59% of the available width inside black borders. So Auto mode only
  // keeps the integer-aligned rect when it covers ≥92% of the true
  // aspect-fit size; otherwise it takes the full fractional fit (the
  // sharp-bilinear prescale + bicubic filtering are built exactly for
  // fractional final scales). Authentic Pixel Mode remains strict
  // integer — that is the entire point of that mode.
  //
  // The integer-aligned branch keeps Auto GEOMETRICALLY STABLE: the rect is
  // a whole-pixel multiple centered on the device grid, so there is zero
  // sub-pixel offset and no shimmer when the camera scrolls. Smoothing is a
  // separate concern — it comes from the sharp-bilinear prescale (the CPU-
  // expanded surface is ~0.70×k, biased toward pixel-perfect, so the bicubic
  // resolves only a ~1.3–1.6× residual up to this k× rect). That residual is
  // deliberate: prescaling to the full k makes the surface map ~1:1 and the
  // bicubic a no-op, which looks as blocky as raw nearest-neighbour; prescaling
  // to only ~k/2 leaves a ~2× residual that looks soft. Keep the aligned rect
  // for stability; let the ~0.70-scale prescale + bicubic do the smoothing.
  final integerCoversEnough = k >= 1 && (authentic || k >= scale * 0.92);

  if (integerCoversEnough) {
    // Integer multiple in physical pixels, centered on the physical grid
    // so every game pixel is exactly k×k device pixels (no fractional
    // offsets, no shimmer). In Auto mode the bicubic filter produces
    // smooth gradients between neighbours at this perfect alignment.
    final destW = fbWidth * k.toDouble();
    final destH = fbHeight * k.toDouble();
    final offX = ((physW - destW) / 2).floorToDouble();
    final offY = ((physH - destH) / 2).floorToDouble();
    return DisplayGeometry(
      rect: Rect.fromLTWH(offX / dpr, offY / dpr, destW / dpr, destH / dpr),
      filterQuality: fq,
      antiAlias: aa,
      integerScaled: true,
    );
  }

  // Fractional aspect-fit: either the screen is smaller than the
  // framebuffer (k < 1), or Auto mode rejected an integer scale that
  // would waste too much screen. Authentic uses nearest (never blur);
  // Auto uses smooth (best quality).
  if (preserveAspect) {
    final destW = fbWidth * scale;
    final destH = fbHeight * scale;
    final offX = (physW - destW) / 2;
    final offY = (physH - destH) / 2;
    return DisplayGeometry(
      rect: Rect.fromLTWH(offX / dpr, offY / dpr, destW / dpr, destH / dpr),
      filterQuality: fq,
      antiAlias: aa,
      integerScaled: false,
    );
  }
  return DisplayGeometry(
    rect: full,
    filterQuality: fq,
    antiAlias: aa,
    integerScaled: false,
  );
}

/// ═════════════════════════════════════════════════════════════════════
///  TV adaptive final-scaling governor
/// ═════════════════════════════════════════════════════════════════════

/// Adaptive `FilterQuality` governor for Android TV (Auto mode).
///
/// Final-scaling filter quality is the only thing adapted at runtime —
/// libretro core options (internal resolution, renderer, MSAA) are applied
/// at ROM-load time only, because most cores require a reload (or at least
/// a context reset) for those to change safely (see
/// docs/GRAPHICS_QUALITY.md).
///
/// Hysteresis policy:
///  * DEMOTE quickly — a single bad sample (low fps or retro_run EWMA close
///    to the frame budget) drops one tier immediately; a severely bad
///    sample drops straight to the bottom tier.
///  * PROMOTE slowly — only after [promoteAfterGoodSamples] consecutive
///    good samples (sustained headroom) does quality rise one tier, and
///    the counter restarts after every promotion.
///
/// `headroom` is `retro_run EWMA µs / core frame interval µs` — i.e. the
/// fraction of the emulation frame budget already consumed by the core
/// before any rendering/compositing cost. The thresholds intentionally
/// leave a wide stability band (0.60–0.85) so the tier doesn't flap.
class AdaptiveFilterQuality {
  AdaptiveFilterQuality({
    this.promoteAfterGoodSamples = 5,
    this.maxTier = 2,
  });

  /// Consecutive good samples (~1 s apart) required before promoting.
  final int promoteAfterGoodSamples;

  /// Highest tier this governor may reach (2 = FilterQuality.high).
  final int maxTier;

  static const _tierQualities = <FilterQuality>[
    FilterQuality.low,
    FilterQuality.medium,
    FilterQuality.high,
  ];

  int _tier = 0;
  int _goodStreak = 0;

  /// Current tier (0 = low, 1 = medium, 2 = high).
  int get tier => _tier;

  /// The `FilterQuality` for the current tier.
  FilterQuality get filterQuality => _tierQualities[_tier];

  /// Feed one sample. Returns `true` when the tier changed.
  ///
  /// [fps] — current emulation fps (<= 0 when unknown).
  /// [targetFps] — the core's nominal fps (<= 0 when unknown).
  /// [headroom] — retro_run EWMA / frame interval (<= 0 when unknown).
  bool addSample({
    required double fps,
    required double targetFps,
    required double headroom,
  }) {
    final hasFps = fps > 0 && targetFps > 0;
    final hasHeadroom = headroom > 0;

    // Without any signal, stay conservative at the current tier.
    if (!hasFps && !hasHeadroom) {
      _goodStreak = 0;
      return false;
    }

    final fpsRatio = hasFps ? fps / targetFps : 1.0;

    final severelyBad =
        (hasFps && fpsRatio < 0.70) || (hasHeadroom && headroom > 1.0);
    final bad =
        (hasFps && fpsRatio < 0.92) || (hasHeadroom && headroom > 0.85);
    final good =
        (!hasFps || fpsRatio >= 0.97) && (!hasHeadroom || headroom < 0.60);

    final oldTier = _tier;

    if (severelyBad) {
      _tier = 0;
      _goodStreak = 0;
    } else if (bad) {
      if (_tier > 0) _tier--;
      _goodStreak = 0;
    } else if (good) {
      _goodStreak++;
      if (_goodStreak >= promoteAfterGoodSamples && _tier < maxTier) {
        _tier++;
        _goodStreak = 0;
      }
    } else {
      // Neutral band — neither promote nor demote, but don't accumulate.
      _goodStreak = 0;
    }

    if (_tier != oldTier && kDebugMode) {
      debugPrint(
        'AdaptiveFilterQuality: tier $oldTier → $_tier '
        '(fps=${fps.toStringAsFixed(1)}, '
        'headroom=${headroom.toStringAsFixed(2)})',
      );
    }
    return _tier != oldTier;
  }

  void reset() {
    _tier = 0;
    _goodStreak = 0;
  }
}

/// ═════════════════════════════════════════════════════════════════════
///  "Bright and natural" color matrix (hardware direct-present cores)
/// ═════════════════════════════════════════════════════════════════════

/// Build a mild "bright and natural" 4×5 color matrix for [ColorFilter].
///
/// Used on the Flutter side ONLY for hardware-rendered direct-present
/// platforms (NDS / N64 / PS1) whose pixels never pass through the native
/// software color-tuning path in yage_video.c. Software-rendered cores get
/// the equivalent tuning natively (see yage_video_set_color_tuning), so
/// applying this matrix to them too would double-tune.
///
/// Never applied in Authentic Pixel Mode.
///
/// The defaults are intentionally gentle: slightly clearer highlights and
/// lifted midtones, natural saturation, no crushed blacks (the offset term
/// is kept >= 0), no neon oversaturation.
List<double> buildNaturalColorMatrix({
  double contrast = 1.04,
  double saturation = 1.06,
  double lift = 2.0,
}) {
  // Per-channel: out = contrast * in + offset.
  // Pivot slightly below mid-gray so the curve brightens midtones instead
  // of crushing shadows; clamp offset at >= 0 so black never goes negative.
  double offset = 255.0 * 0.5 * (1.0 - contrast) + lift;
  if (offset < 0) offset = 0;

  // Standard Rec.601 luminance weights for the saturation mix.
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final s = saturation;
  final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;

  final c = contrast;
  // Combined matrix: saturation ∘ (contrast + offset).
  return <double>[
    (sr + s) * c, sg * c, sb * c, 0, offset,
    sr * c, (sg + s) * c, sb * c, 0, offset,
    sr * c, sg * c, (sb + s) * c, 0, offset,
    0, 0, 0, 1, 0,
  ];
}
