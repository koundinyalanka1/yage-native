import '../core/mgba_bindings.dart';

/// Per-core input profile system for platform-specific controller mapping.
///
/// ## Purpose
/// Different emulated systems have different button layouts and input schemes:
/// - GB/GBA: A, B, L, R, Start, Select, D-Pad (standard libretro mapping)
/// - SNES: A, B, X, Y, L, R, Start, Select, D-Pad
/// - N64: A, B, Z, Start, D-Pad, L, R, + Analog Stick + 4 C-buttons
/// - NES: A, B, Start, Select, D-Pad (no shoulders)
///
/// The `InputProfile` system lets each platform define:
/// 1. How to transform GBA-style bitmasks into platform-specific input states
/// 2. How to label buttons for UI/debugging
/// 3. Custom behavior hooks for platform-specific input handling
///
/// ## Usage
/// ```dart
/// // Get the profile for a platform
/// final profile = getInputProfileForPlatform(GamePlatform.n64);
///
/// // Query button labels (for UI)
/// final label = profile.getLabelForButton(GBAKey.x);  // N64: "C-Right"
///
/// // Transform keys if the core needs custom mapping
/// final customKeys = profile.transformKeys(keys);
/// emulatorService.setKeys(customKeys);
/// ```
///
/// ## Future Enhancements
/// - **Button Remapper UI**: Use `getLabelForButton()` to build a per-core button
///   remapping settings page that lets users reassign buttons.
/// - **Custom Input Transformation**: Extend `transformKeys()` to apply complex
///   remapping logic (e.g., "when N64 X is pressed, emit C-Right + C-Down").
/// - **Platform-Specific Settings**: Add methods like `getAxisSensitivity()` or
///   `getDeadzonePercent()` for fine-tuning per-platform input behavior.
/// - **Multi-profile Support**: Allow users to select between multiple profiles
///   for the same platform (e.g., "N64 Arcade Stick" vs "N64 Standard").
///
/// ## Adding a New Platform
/// 1. Create a new class extending `InputProfile` (or implementing it)
/// 2. Override `getLabelForButton()` with platform-specific names
/// 3. Override `transformKeys()` if the core needs custom mapping (usually not needed)
/// 4. Register it in `getInputProfileForPlatform()` factory function
/// 5. Example:
///    ```dart
///    class PSXInputProfile implements InputProfile {
///      @override
///      GamePlatform get platform => GamePlatform.psx; // if we add it
///      @override
///      String get name => 'PlayStation Controller Profile';
///      // ... override methods
///    }
///    ```

/// Abstract base class for platform-specific input profiles.
///
/// Each profile defines how a platform's inputs are interpreted and potentially
/// transformed before being sent to the native core. This allows cores with
/// non-standard button layouts (like N64) to customize their mappings.
abstract class InputProfile {
  /// The platform this profile is for
  GamePlatform get platform;

  /// Get a descriptive name for the profile (e.g., "N64 Controller Profile")
  String get name;

  /// Transform a bitmask of GBA-style keys into platform-specific button IDs.
  /// By default, returns the keys unchanged (assuming 1:1 libretro mapping).
  ///
  /// This could be used for cores that require specific button remapping, e.g.
  /// N64 might want to map GBAKey.x to a C-button, which isn't standard libretro.
  ///
  /// For now, this returns the keys as-is, since libretro already handles the
  /// platform-specific button mapping internally. Future extensions could use
  /// this to generate custom input states.
  int transformKeys(int gbaKeyBitmask) => gbaKeyBitmask;

  /// Get a human-readable label for a button bit (for UI/debugging)
  String getLabelForButton(int gbaKeyBit) {
    return switch (gbaKeyBit) {
      GBAKey.a => 'A',
      GBAKey.b => 'B',
      GBAKey.select => 'SELECT',
      GBAKey.start => 'START',
      GBAKey.right => 'RIGHT',
      GBAKey.left => 'LEFT',
      GBAKey.up => 'UP',
      GBAKey.down => 'DOWN',
      GBAKey.r => 'R',
      GBAKey.l => 'L',
      GBAKey.x => 'X',
      GBAKey.y => 'Y',
      _ => 'UNKNOWN',
    };
  }
}

/// Default input profile — works for GB/GBC/GBA/NES/SNES/MD/NGP/WS/WSC.
///
/// All libretro cores understand GBA-style button mappings directly, so
/// we pass buttons through unchanged.
class DefaultInputProfile implements InputProfile {
  final GamePlatform _platform;

  DefaultInputProfile(this._platform);

  @override
  GamePlatform get platform => _platform;

  @override
  String get name => 'Standard Controller Profile';

  @override
  int transformKeys(int gbaKeyBitmask) => gbaKeyBitmask;

  @override
  String getLabelForButton(int gbaKeyBit) {
    return switch (gbaKeyBit) {
      GBAKey.a => 'A',
      GBAKey.b => 'B',
      GBAKey.select => 'SELECT',
      GBAKey.start => 'START',
      GBAKey.right => 'RIGHT',
      GBAKey.left => 'LEFT',
      GBAKey.up => 'UP',
      GBAKey.down => 'DOWN',
      GBAKey.r => 'R',
      GBAKey.l => 'L',
      GBAKey.x => 'X',
      GBAKey.y => 'Y',
      _ => 'UNKNOWN',
    };
  }
}

/// N64-specific input profile.
///
/// Notes:
/// - The N64 controller has a unique layout: A, B, Z trigger, Start, D-pad, and most importantly,
///   an analog stick + 4 C buttons instead of a standard face button diamond.
/// - Mupen64Plus-Next (the libretro core) maps as follows:
///   * JOYPAD bits (A/B/Start/L/R/D-pad) map directly
///   * C-buttons are accessed via analog stick direction codes
/// - Our GBAKey system lets us use X/Y to represent extra face buttons; for N64,
///   these can be interpreted as C-button hints to the user (though the core handles them).
/// - The Z trigger is routed through Select (as established in gamepad_input.dart n64Mapping).
///
/// This profile documents N64's unique button scheme. Future enhancements could use
/// this to build custom UI or apply advanced remapping if needed.
class N64InputProfile implements InputProfile {
  @override
  GamePlatform get platform => GamePlatform.n64;

  @override
  String get name => 'N64 Controller Profile';

  @override
  int transformKeys(int gbaKeyBitmask) => gbaKeyBitmask;

  @override
  String getLabelForButton(int gbaKeyBit) {
    // For N64, provide context-aware labels
    return switch (gbaKeyBit) {
      GBAKey.a => 'A',
      GBAKey.b => 'B',
      GBAKey.select => 'Z (Trigger)',
      GBAKey.start => 'START',
      GBAKey.right => 'D-Right',
      GBAKey.left => 'D-Left',
      GBAKey.up => 'D-Up',
      GBAKey.down => 'D-Down',
      GBAKey.r => 'R',
      GBAKey.l => 'L',
      GBAKey.x => 'C-Right',
      GBAKey.y => 'C-Down',
      _ => 'UNKNOWN',
    };
  }
}

/// Factory to get the appropriate input profile for a platform.
InputProfile getInputProfileForPlatform(GamePlatform platform) {
  return switch (platform) {
    GamePlatform.n64 => N64InputProfile(),
    _ => DefaultInputProfile(platform),
  };
}
