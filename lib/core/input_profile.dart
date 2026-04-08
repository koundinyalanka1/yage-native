import '../core/mgba_bindings.dart';

abstract class InputProfile {
  GamePlatform get platform;

  String get name;

  int transformKeys(int gbaKeyBitmask) => gbaKeyBitmask;

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

class N64InputProfile implements InputProfile {
  @override
  GamePlatform get platform => GamePlatform.n64;

  @override
  String get name => 'N64 Controller Profile';

  @override
  int transformKeys(int gbaKeyBitmask) => gbaKeyBitmask;

  @override
  String getLabelForButton(int gbaKeyBit) {
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

InputProfile getInputProfileForPlatform(GamePlatform platform) {
  return switch (platform) {
    GamePlatform.n64 => N64InputProfile(),
    _ => DefaultInputProfile(platform),
  };
}
