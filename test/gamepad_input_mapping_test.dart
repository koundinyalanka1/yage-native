import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retropal/core/mgba_bindings.dart';
import 'package:retropal/services/gamepad_input.dart';

void main() {
  group('physical controller mappings', () {
    test('two-button/default consoles use Nintendo-style A/B positions', () {
      final mapping = GamepadMapper.mappingForPlatform(GamePlatform.gba);

      expect(mapping[LogicalKeyboardKey.gameButtonA], GBAKey.b);
      expect(mapping[LogicalKeyboardKey.gameButtonB], GBAKey.a);
      expect(mapping[LogicalKeyboardKey.gameButtonLeft1], GBAKey.l);
      expect(mapping[LogicalKeyboardKey.gameButtonRight1], GBAKey.r);
      expect(mapping[LogicalKeyboardKey.gameButtonStart], GBAKey.start);
      expect(mapping[LogicalKeyboardKey.gameButtonSelect], GBAKey.select);
    });

    test('SNES and NDS expose the full Nintendo face-button diamond', () {
      for (final platform in [GamePlatform.snes, GamePlatform.nds]) {
        final mapping = GamepadMapper.mappingForPlatform(platform);

        expect(
          mapping[LogicalKeyboardKey.gameButtonA],
          GBAKey.b,
          reason: '${platform.name} south -> B',
        );
        expect(
          mapping[LogicalKeyboardKey.gameButtonB],
          GBAKey.a,
          reason: '${platform.name} east -> A',
        );
        expect(
          mapping[LogicalKeyboardKey.gameButtonX],
          GBAKey.y,
          reason: '${platform.name} west -> Y',
        );
        expect(
          mapping[LogicalKeyboardKey.gameButtonY],
          GBAKey.x,
          reason: '${platform.name} north -> X',
        );
      }
    });

    test(
      'Genesis six-button controls match Genesis Plus GX RetroPad inputs',
      () {
        final mapping = GamepadMapper.mappingForPlatform(GamePlatform.md);

        expect(mapping[LogicalKeyboardKey.gameButtonX], GBAKey.y); // A
        expect(mapping[LogicalKeyboardKey.gameButtonA], GBAKey.b); // B
        expect(mapping[LogicalKeyboardKey.gameButtonB], GBAKey.a); // C
        expect(mapping[LogicalKeyboardKey.gameButtonLeft1], GBAKey.l); // X
        expect(mapping[LogicalKeyboardKey.gameButtonY], GBAKey.x); // Y
        expect(mapping[LogicalKeyboardKey.gameButtonRight1], GBAKey.r); // Z
        expect(mapping[LogicalKeyboardKey.gameButtonSelect], GBAKey.select);
        expect(mapping[LogicalKeyboardKey.gameButtonMode], GBAKey.select);
        expect(mapping[LogicalKeyboardKey.gameButtonStart], GBAKey.start);
      },
    );

    test('PlayStation maps modern controller positions to PSX RetroPad', () {
      final mapping = GamepadMapper.mappingForPlatform(GamePlatform.ps1);

      expect(mapping[LogicalKeyboardKey.gameButtonA], GBAKey.b); // Cross
      expect(mapping[LogicalKeyboardKey.gameButtonB], GBAKey.a); // Circle
      expect(mapping[LogicalKeyboardKey.gameButtonX], GBAKey.y); // Square
      expect(mapping[LogicalKeyboardKey.gameButtonY], GBAKey.x); // Triangle
      expect(mapping[LogicalKeyboardKey.gameButtonLeft1], GBAKey.l);
      expect(mapping[LogicalKeyboardKey.gameButtonRight1], GBAKey.r);
      expect(mapping[LogicalKeyboardKey.gameButtonLeft2], GBAKey.l2);
      expect(mapping[LogicalKeyboardKey.gameButtonRight2], GBAKey.r2);
      expect(mapping[LogicalKeyboardKey.gameButtonThumbLeft], GBAKey.l3);
      expect(mapping[LogicalKeyboardKey.gameButtonThumbRight], GBAKey.r3);
    });

    test('N64 maps A/B/Z and leaves C-buttons unmapped for now', () {
      final mapping = GamepadMapper.mappingForPlatform(GamePlatform.n64);

      expect(mapping[LogicalKeyboardKey.gameButtonA], GBAKey.b); // N64 A
      expect(mapping[LogicalKeyboardKey.gameButtonB], GBAKey.y); // N64 B
      expect(mapping[LogicalKeyboardKey.gameButtonLeft2], GBAKey.l2); // Z
      expect(mapping[LogicalKeyboardKey.gameButtonZ], GBAKey.l2);
      expect(mapping[LogicalKeyboardKey.gameButtonLeft1], GBAKey.l);
      expect(mapping[LogicalKeyboardKey.gameButtonRight1], GBAKey.r);
      expect(mapping.containsKey(LogicalKeyboardKey.gameButtonX), isFalse);
      expect(mapping.containsKey(LogicalKeyboardKey.gameButtonY), isFalse);
    });

    test('Intellivision exposes keypad and side-button inputs', () {
      final mapping = GamepadMapper.mappingForPlatform(GamePlatform.intv);

      expect(mapping[LogicalKeyboardKey.gameButtonLeft2], GBAKey.l2); // Clear
      expect(mapping[LogicalKeyboardKey.gameButtonRight2], GBAKey.r2); // Enter
      expect(mapping[LogicalKeyboardKey.gameButtonThumbLeft], GBAKey.l3); // 0
      expect(mapping[LogicalKeyboardKey.gameButtonThumbRight], GBAKey.r3); // 5
      expect(mapping[LogicalKeyboardKey.gameButtonA], GBAKey.a);
      expect(mapping[LogicalKeyboardKey.gameButtonB], GBAKey.b);
      expect(mapping[LogicalKeyboardKey.gameButtonX], GBAKey.x);
      expect(mapping[LogicalKeyboardKey.gameButtonY], GBAKey.y);
    });
  });
}
