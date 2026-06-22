import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Cached device memory in MB. Fetched at startup for rewind buffer sizing.
int? deviceMemoryMB;

const _channel = MethodChannel('com.yourmateapps.retropal/device');

/// Fetch and cache total device RAM in MB. Call at app startup.
/// On Android returns total physical memory; on other platforms returns null.
Future<void> initDeviceMemory() async {
  if (deviceMemoryMB != null) return;
  try {
    if (Platform.isAndroid) {
      deviceMemoryMB = await _channel.invokeMethod<int>('getDeviceMemoryMB');
    }
  } catch (e) {
    debugPrint('DeviceMemory: failed to query device RAM — $e');
    deviceMemoryMB = null;
  }
}

/// Max rewind snapshots to avoid OOM on low-RAM devices.
/// GBA/SNES save states ~0.5–2 MB each; 720 × 1.5 MB ≈ 1 GB.
/// Returns capacity cap: 120 for <2 GB, 240 for 2–4 GB, 720 for 4+ GB.
int rewindCapacityCap() {
  final mb = deviceMemoryMB;
  if (mb == null || mb < 2048) return 120;   // <2 GB: 10 s at 12 captures/s
  if (mb < 4096) return 240;                 // 2–4 GB: 20 s
  return 720;                                // 4+ GB: 60 s
}

/// GPU capability tier for load-time 3D internal-resolution presets.
///
/// Phones/tablets in Auto Optimized mode pick a higher libretro internal
/// resolution on more capable devices (see
/// `EmulatorService._applyPlatformCoreOptions`). Device RAM is used as a
/// cheap, reliable proxy for GPU class on Android: the high-RAM SoCs ship
/// the stronger GPUs that can sustain a higher 3D render scale at full
/// speed. The tier is deliberately conservative when the figure is unknown
/// so a query failure never regresses framerate.
enum Gpu3dTier {
  /// ≤4 GB or unknown — the proven enhanced preset (2× internal). No change
  /// from the prior behaviour, so weak/old devices never regress.
  baseline,

  /// ~6 GB modern midrange+ — one step up (3× internal, more MSAA).
  high,

  /// ~8 GB+ flagship — maximum sustainable internal resolution (4×).
  ultra,
}

/// Resolve the GPU tier from cached device RAM.
///
/// Thresholds sit below the marketing number because Android's `totalMem`
/// reports usable RAM (an "8 GB" phone reports ~7 GB, a "6 GB" phone
/// ~5.5 GB). Android-only data; non-Android / unknown falls back to
/// [Gpu3dTier.baseline] (these platforms don't use the GL 3D presets).
Gpu3dTier gpu3dTier() {
  final mb = deviceMemoryMB;
  if (mb == null) return Gpu3dTier.baseline;
  if (mb >= 7168) return Gpu3dTier.ultra;  // ~8 GB+
  if (mb >= 5120) return Gpu3dTier.high;   // ~6 GB
  return Gpu3dTier.baseline;               // ≤4 GB
}
