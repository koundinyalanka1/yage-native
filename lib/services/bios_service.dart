import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/mgba_bindings.dart';

/// Source category of a BIOS file slot.
///
/// • `required_` — the file is needed for proper emulation.
/// • `optional` — additional region BIOS that improves compatibility.
/// • `bundled` — provided by the app (e.g. OpenBIOS) as a fallback.
enum BiosKind { required_, optional, bundled }

/// Spec for a single BIOS file expected by a libretro core.
@immutable
class BiosSpec {
  /// Stable identifier used in UI / API (`'bios7'`, `'scph5501'`, etc.).
  final String id;

  /// Exact filename the libretro core looks for in the system dir.
  /// Case-sensitive on Linux/Android, so we always deploy lowercase.
  final String filename;

  /// Human-readable label shown in the BIOS settings tab.
  final String label;

  /// Short description (e.g. region, purpose).
  final String description;

  /// Reference file size in bytes. Validation uses known hashes instead.
  final int expectedSize;

  /// Optional MD5 hashes (lowercase hex).
  final List<String> md5;

  /// Optional SHA-1 hashes (lowercase hex).
  final List<String> sha1;

  /// Whether the file is required, optional, or bundled.
  final BiosKind kind;

  bool get hasKnownHashes => md5.isNotEmpty || sha1.isNotEmpty;

  const BiosSpec({
    required this.id,
    required this.filename,
    required this.label,
    required this.description,
    required this.expectedSize,
    this.md5 = const [],
    this.sha1 = const [],
    this.kind = BiosKind.required_,
  });
}

/// Runtime status for one BIOS slot in the system directory.
@immutable
class BiosFileStatus {
  final BiosSpec spec;

  /// Whether a file with the expected filename exists.
  final bool exists;

  /// Whether the existing file passed the optional hash check.
  final bool valid;

  /// File size on disk (0 if missing).
  final int actualSize;

  /// Whether a known hash was available for this BIOS slot.
  final bool hashChecked;

  /// Whether the hash check passed. True for slots without known hashes.
  final bool hashValid;

  const BiosFileStatus({
    required this.spec,
    required this.exists,
    required this.valid,
    required this.actualSize,
    required this.hashChecked,
    required this.hashValid,
  });
}

/// Outcome of `BiosService.gateForLaunch()`.
@immutable
class BiosGateResult {
  final bool allowed;
  final String? blockReason;
  final bool usingHle;

  const BiosGateResult.allow({this.usingHle = false})
    : allowed = true,
      blockReason = null;

  const BiosGateResult.block(String reason)
    : allowed = false,
      blockReason = reason,
      usingHle = false;
}

/// Service that owns the libretro **system** directory and all BIOS
/// import / validation logic.
///
/// The system directory is created once under
/// `getApplicationSupportDirectory()/system`. Both the libretro cores (via
/// `coreSetSystemDir`) and the TV HTTP server upload to this folder, so all
/// status queries go through this single source of truth.
class BiosService extends ChangeNotifier {
  static const String _bundledOpenBiosAsset = 'assets/system/openbios.bin';
  static const String _openBiosFilename = 'openbios.bin';

  String? _systemDir;
  bool _openBiosDeployed = false;

  /// Returns the absolute path to the libretro system directory, creating it
  /// on first call. The returned path is cached for the process lifetime.
  Future<String> getSystemDir() async {
    final cached = _systemDir;
    if (cached != null) return cached;
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'system'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _systemDir = dir.path;
    return dir.path;
  }

  /// Per-platform BIOS specs.  Filenames match the libretro convention so
  /// the cores find them automatically via `RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY`.
  static const Map<GamePlatform, List<BiosSpec>> specs = {
    // ── Nintendo DS (melonDS) ──────────────────────────────────────────
    // melonDS has a built-in FreeBIOS for DS mode, so all three files are
    // optional on mobile.  On TV the user must supply real dumps.
    GamePlatform.nds: [
      BiosSpec(
        id: 'bios7',
        filename: 'bios7.bin',
        label: 'ARM7 BIOS',
        description: 'Nintendo DS ARM7 BIOS · 16 KB',
        expectedSize: 16384,
        md5: ['df692a80a5b1bc90728bc3dfc76cd948'],
        sha1: ['24f67bdea115a2c847c8813a262502ee1607b7df'],
        kind: BiosKind.optional,
      ),
      BiosSpec(
        id: 'bios9',
        filename: 'bios9.bin',
        label: 'ARM9 BIOS',
        description: 'Nintendo DS ARM9 BIOS · 4 KB',
        expectedSize: 4096,
        md5: ['a392174eb3e572fed6447e956bde4b25'],
        sha1: ['1280f0d5a4f6fcf48b206f867f0fc6c75d1c19a2'],
        kind: BiosKind.optional,
      ),
      BiosSpec(
        id: 'firmware',
        filename: 'firmware.bin',
        label: 'Firmware',
        description: 'Nintendo DS Firmware · 128 KB or 256 KB',
        expectedSize: 0, // varies (128 KB original, 256 KB DSi+)
        kind: BiosKind.optional,
      ),
    ],

    // ── Sony PlayStation 1 (Beetle PSX HW) ────────────────────────────
    // Any one of the three regional BIOS files works.  OpenBIOS is deployed
    // automatically as a bundled fallback so games launch even with zero
    // user-supplied files (mobile only; TV requires a real Sony BIOS).
    GamePlatform.ps1: [
      BiosSpec(
        id: 'scph5500',
        filename: 'scph5500.bin',
        label: 'SCPH-5500 BIOS (JP)',
        description: 'Japan · 512 KB',
        expectedSize: 524288,
        md5: ['8dd7d5296a650fac7319bce665a6a53c'],
        sha1: ['b05def971d8ec59f346f2d9ac21fb742e3eb6917'],
        kind: BiosKind.required_,
      ),
      BiosSpec(
        id: 'scph5501',
        filename: 'scph5501.bin',
        label: 'US BIOS (SCPH-5501 / SCPH-1001)',
        description: 'USA · 512 KB · accepts SCPH-5501 (v3.0A) or SCPH-1001 (v2.2)',
        expectedSize: 524288,
        // The US region slot accepts any verified US Sony BIOS revision; the
        // file is deployed as scph5501.bin (the name Beetle PSX HW loads for
        // NTSC-U discs), and mednafen recognises both dumps as valid US BIOS.
        md5: [
          '490f666e1afb15b7362b406ed1cea246', // SCPH-5501 (v3.0A, 1995-12-04)
          '924e392ed05558ffdb115408c263dccf', // SCPH-1001 (v2.2,  1995-12-04)
        ],
        sha1: [
          '0555c6fae8906f3f09baf5988f00e55f88e9f30b', // SCPH-5501
          '10155d8d6e6e832d6ea66db9bc098321fb5e8ebf', // SCPH-1001
        ],
        kind: BiosKind.required_,
      ),
      BiosSpec(
        id: 'scph5502',
        filename: 'scph5502.bin',
        label: 'SCPH-5502 BIOS (EU)',
        description: 'Europe · 512 KB',
        expectedSize: 524288,
        md5: ['32736f17079d0b2b7024407c39bd3050'],
        sha1: ['f6bc2d1f5eb6593de7a1b14da97507fd6b53cb84'],
        kind: BiosKind.required_,
      ),
      BiosSpec(
        id: 'openbios',
        filename: _openBiosFilename,
        label: 'OpenBIOS (free fallback)',
        description:
            'Built into the PS1 core (GPLv2 clean-room BIOS) · used '
            'automatically when no Sony BIOS is supplied (limited '
            'compatibility). No file upload needed.',
        expectedSize: 0,
        kind: BiosKind.bundled,
      ),
    ],

    // ── Mattel Intellivision (FreeIntv) ───────────────────────────────
    // No HLE; both files are mandatory on every platform.
    GamePlatform.intv: [
      BiosSpec(
        id: 'exec',
        filename: 'exec.bin',
        label: 'Executive ROM',
        description: 'Intellivision Executive ROM (EXEC) · 8 KB',
        expectedSize: 8192,
        md5: ['62e761035cb657903761800f4437b8af'],
        sha1: ['5a65b922b562cb1f57dab51b73151283f0e20c7a'],
        kind: BiosKind.required_,
      ),
      BiosSpec(
        id: 'grom',
        filename: 'grom.bin',
        label: 'Graphics ROM',
        description: 'Intellivision Graphics ROM (GROM) · 2 KB',
        expectedSize: 2048,
        md5: ['0cd5946c6473e42e8e4c2137785e427f'],
        sha1: ['f9608bb4ad1cfe3640d02844c7ad8e0bcd974917'],
        kind: BiosKind.required_,
      ),
    ],
  };

  /// Specs for platforms that have BIOS support in this app.
  static const List<GamePlatform> biosPlatforms = [
    GamePlatform.nds,
    GamePlatform.ps1,
    GamePlatform.intv,
  ];

  /// Convenience: ordered specs for the given platform.  Empty if BIOS
  /// support is not defined for that platform.
  static List<BiosSpec> specsFor(GamePlatform platform) =>
      specs[platform] ?? const [];

  /// Returns the canonical filename libretro expects for [platform] / [biosId].
  static String? filenameFor(GamePlatform platform, String biosId) {
    for (final s in specsFor(platform)) {
      if (s.id == biosId) return s.filename;
    }
    return null;
  }

  static bool bytesMatchHashesForSpec(BiosSpec spec, List<int> bytes) {
    if (!spec.hasKnownHashes) return true;
    final md5Ok =
        spec.md5.isEmpty ||
        spec.md5.contains(crypto.md5.convert(bytes).toString());
    final sha1Ok =
        spec.sha1.isEmpty ||
        spec.sha1.contains(crypto.sha1.convert(bytes).toString());
    return md5Ok && sha1Ok;
  }

  /// Deploys the bundled OpenBIOS asset into the system directory if it's
  /// not already present. Safe to call repeatedly — does nothing after the
  /// first successful copy. Returns `true` when the file exists in the
  /// system dir after the call.
  Future<bool> deployOpenBiosFallback() async {
    if (_openBiosDeployed) return true;
    try {
      final systemDir = await getSystemDir();
      final target = File(p.join(systemDir, _openBiosFilename));
      if (await target.exists()) {
        _openBiosDeployed = true;
        return true;
      }
      // Try to load the bundled asset.  Missing asset is non-fatal — PS1
      // games will then require a user-supplied BIOS.
      try {
        final data = await rootBundle.load(_bundledOpenBiosAsset);
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
        _openBiosDeployed = true;
        debugPrint('BiosService: deployed OpenBIOS to ${target.path}');
        return true;
      } catch (e) {
        debugPrint(
          'BiosService: OpenBIOS asset not bundled — '
          'PS1 games will need user BIOS. Reason: $e',
        );
        return false;
      }
    } catch (e) {
      debugPrint('BiosService: deployOpenBiosFallback failed — $e');
      return false;
    }
  }

  /// Imports a BIOS file from [sourcePath] into the system directory, named
  /// according to the spec's expected filename.  Returns the deployed path
  /// on success, `null` on failure.
  Future<String?> importBiosFile({
    required GamePlatform platform,
    required String biosId,
    required String sourcePath,
  }) async {
    final spec = specsFor(platform).firstWhereOrNull((s) => s.id == biosId);
    if (spec == null) {
      debugPrint('BiosService: unknown bios id "$biosId" for $platform');
      return null;
    }
    try {
      final src = File(sourcePath);
      if (!await src.exists()) {
        debugPrint('BiosService: source missing — $sourcePath');
        return null;
      }
      final systemDir = await getSystemDir();
      final dst = File(p.join(systemDir, spec.filename));
      await src.copy(dst.path);
      notifyListeners();
      return dst.path;
    } catch (e) {
      debugPrint('BiosService: import failed — $e');
      return null;
    }
  }

  /// Deletes the file for [biosId] under [platform], if present.
  Future<void> deleteBios({
    required GamePlatform platform,
    required String biosId,
  }) async {
    final spec = specsFor(platform).firstWhereOrNull((s) => s.id == biosId);
    if (spec == null) return;
    // Bundled fallbacks are not user-deletable: removing OpenBIOS would
    // be silently re-deployed on the next launch anyway.
    if (spec.kind == BiosKind.bundled) return;
    try {
      final systemDir = await getSystemDir();
      final f = File(p.join(systemDir, spec.filename));
      if (await f.exists()) await f.delete();
      notifyListeners();
    } catch (e) {
      debugPrint('BiosService: delete failed — $e');
    }
  }

  /// Status for every spec under [platform].
  Future<List<BiosFileStatus>> listBios(GamePlatform platform) async {
    final specs = specsFor(platform);
    if (specs.isEmpty) return const [];
    final systemDir = await getSystemDir();
    final result = <BiosFileStatus>[];
    for (final spec in specs) {
      final f = File(p.join(systemDir, spec.filename));
      var exists = false;
      var size = 0;
      try {
        exists = await f.exists();
        if (exists) size = await f.length();
      } catch (_) {}
      final hashChecked = spec.hasKnownHashes;
      var hashValid = !hashChecked;
      if (exists && hashChecked) {
        try {
          hashValid = bytesMatchHashesForSpec(spec, await f.readAsBytes());
        } catch (_) {
          hashValid = false;
        }
      }
      result.add(
        BiosFileStatus(
          spec: spec,
          exists: exists,
          valid: exists && (!hashChecked || hashValid),
          actualSize: size,
          hashChecked: hashChecked,
          hashValid: hashValid,
        ),
      );
    }
    return result;
  }

  /// True when every `required` spec for [platform] is present and valid.
  /// Bundled fallbacks count as satisfying their "any of" group for PS1.
  Future<bool> hasRequiredBios(GamePlatform platform) async {
    final statuses = await listBios(platform);
    if (statuses.isEmpty) return true;
    switch (platform) {
      case GamePlatform.ps1:
        // PS1: any one of scph5500/5501/5502 OR OpenBIOS satisfies launch.
        return statuses.any((s) => s.valid);
      case GamePlatform.intv:
        // Intellivision: both required files must be present.
        return statuses
            .where((s) => s.spec.kind == BiosKind.required_)
            .every((s) => s.valid);
      case GamePlatform.nds:
        // NDS has no required slots (all optional via FreeBIOS HLE).
        return true;
      // ignore: no_default_cases
      default:
        return true;
    }
  }

  /// True when the user has supplied real (non-bundled) BIOS for [platform].
  /// Used to enforce the "TV requires real BIOS" policy.
  Future<bool> hasUserRealBios(GamePlatform platform) async {
    final statuses = await listBios(platform);
    switch (platform) {
      case GamePlatform.ps1:
        // OpenBIOS bundled fallback does NOT count as user-supplied.
        return statuses
            .where((s) => s.spec.kind == BiosKind.required_)
            .any((s) => s.valid);
      case GamePlatform.nds:
        // Returns true only when all three real files (bios7.bin, bios9.bin,
        // firmware.bin) are present and valid.  On Android TV this
        // is also the gate for `gateForLaunch` — TVs require real BIOS for
        // NDS now (FreeBIOS was permissive previously).
        return statuses
            .where((s) => s.spec.kind == BiosKind.optional)
            .every((s) => s.valid);
      case GamePlatform.intv:
        return statuses
            .where((s) => s.spec.kind == BiosKind.required_)
            .every((s) => s.valid);
      // ignore: no_default_cases
      default:
        return true;
    }
  }

  /// Gates a launch attempt.  Mobile is permissive (HLE / OpenBIOS allowed);
  /// Android TV requires real BIOS for NDS, PS1, and Intellivision.
  ///
  /// [isTv] should be `TvDetector.isTV` from the caller.
  Future<BiosGateResult> gateForLaunch({
    required GamePlatform platform,
    required bool isTv,
  }) async {
    if (!biosPlatforms.contains(platform)) {
      return const BiosGateResult.allow();
    }
    if (isTv) {
      // TV requires real BIOS for every supported platform, NDS included.
      // FreeBIOS is the documented melonDS fallback but on weak TV SoCs the
      // performance / compatibility delta vs real dumps is large enough that
      // shipping FreeBIOS-by-default would be a worse user experience than
      // forcing the user to upload three small files once.
      final hasReal = await hasUserRealBios(platform);
      if (!hasReal) {
        final missing = (await listBios(platform))
            .where((s) => s.spec.kind != BiosKind.bundled && !s.valid)
            .map((s) => s.spec.filename)
            .join(', ');
        return BiosGateResult.block(
          'Real BIOS files are required to play '
          '${_platformLabel(platform)} games on Android TV. '
          'Upload ${missing.isEmpty ? "the required files" : missing} '
          'via Settings → BIOS or the on-screen file manager '
          '(http://<this-tv-ip>:8080).',
        );
      }
      return const BiosGateResult.allow();
    }
    // Mobile path: FreeBIOS / OpenBIOS allowed.
    switch (platform) {
      case GamePlatform.nds:
        final realPresent = await hasUserRealBios(platform);
        return BiosGateResult.allow(usingHle: !realPresent);
      case GamePlatform.ps1:
        // Beetle PSX HW ships a built-in OpenBIOS that boots automatically
        // when no real Sony BIOS is present (engaged via the
        // `beetle_psx_hw_override_bios=openbios` core option), so a mobile
        // launch is always allowed. `usingHle` is true whenever we fall back
        // to OpenBIOS so the caller knows to set that option.
        final realPresent = await hasUserRealBios(platform);
        return BiosGateResult.allow(usingHle: !realPresent);
      case GamePlatform.intv:
        final ok = await hasRequiredBios(platform);
        if (!ok) {
          return const BiosGateResult.block(
            'Intellivision requires both exec.bin and grom.bin BIOS files. '
            'Upload them via Settings → BIOS to play.',
          );
        }
        return const BiosGateResult.allow();
      // ignore: no_default_cases
      default:
        return const BiosGateResult.allow();
    }
  }

  static String _platformLabel(GamePlatform p) => switch (p) {
    GamePlatform.nds => 'Nintendo DS',
    GamePlatform.ps1 => 'PlayStation',
    GamePlatform.intv => 'Intellivision',
    _ => p.name,
  };
}

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
