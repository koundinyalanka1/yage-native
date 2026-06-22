import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:retropal/core/mgba_bindings.dart';
import 'package:retropal/models/emulator_settings.dart';
import 'package:retropal/models/gamepad_layout.dart';
import 'package:retropal/services/settings_service.dart';
import 'package:retropal/widgets/virtual_gamepad.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('gamepad layout defaults', () {
    test('are normalized for every platform and orientation', () {
      for (final platform in GamePlatform.values) {
        for (final landscape in [false, true]) {
          final layout = GamepadLayout.defaultForPlatform(
            platform,
            landscape: landscape,
          );

          for (final entry in _allButtons(layout).entries) {
            final button = entry.value;
            expect(
              button.x,
              inInclusiveRange(0.0, 1.0),
              reason: '${platform.name} ${entry.key} x',
            );
            expect(
              button.y,
              inInclusiveRange(0.0, 1.0),
              reason: '${platform.name} ${entry.key} y',
            );
            expect(button.size, greaterThan(0), reason: entry.key);
          }
        }
      }
    });

    test('fit representative phone sizes without default button overlap', () {
      const portraitPhones = [Size(320, 568), Size(390, 844), Size(430, 932)];
      const landscapePhones = [Size(568, 320), Size(844, 390), Size(932, 430)];

      for (final platform in GamePlatform.values) {
        if (platform == GamePlatform.unknown) continue;

        for (final screen in portraitPhones) {
          _expectDefaultLayoutFits(
            platform: platform,
            screen: screen,
            landscape: false,
          );
        }
        for (final screen in landscapePhones) {
          _expectDefaultLayoutFits(
            platform: platform,
            screen: screen,
            landscape: true,
          );
        }
      }
    });
  });

  group('gamepad layout persistence', () {
    test('falls back to platform defaults until a user layout is saved', () {
      const settings = EmulatorSettings();

      expect(
        settings.gamepadLayoutForPlatform(GamePlatform.snes, landscape: false),
        GamepadLayout.defaultForPlatform(GamePlatform.snes, landscape: false),
      );
      expect(
        settings.gamepadLayoutForPlatform(GamePlatform.ps1, landscape: true),
        GamepadLayout.defaultForPlatform(GamePlatform.ps1, landscape: true),
      );
    });

    test(
      'round-trips user layouts independently per platform and orientation',
      () {
        const customizedSnesPortrait = GamepadLayout.defaultPortrait;
        final customizedPs1Landscape = GamepadLayout.defaultPs1Landscape
            .copyWith(
              aButton: const ButtonLayout(x: 0.73, y: 0.44, size: 1.37),
              l2Button: const ButtonLayout(x: 0.04, y: 0.18, size: 1.20),
              r2Button: const ButtonLayout(x: 0.91, y: 0.18, size: 1.10),
            );

        final settings = const EmulatorSettings()
            .copyWithGamepadLayoutForPlatform(
              GamePlatform.snes,
              landscape: false,
              layout: customizedSnesPortrait.copyWith(
                aButton: const ButtonLayout(x: 0.71, y: 0.76, size: 1.31),
              ),
            )
            .copyWithGamepadLayoutForPlatform(
              GamePlatform.ps1,
              landscape: true,
              layout: customizedPs1Landscape,
            );

        final restored = EmulatorSettings.fromJsonString(
          settings.toJsonString(),
        );

        expect(
          restored.gamepadLayoutForPlatform(
            GamePlatform.snes,
            landscape: false,
          ),
          settings.gamepadLayoutForPlatform(
            GamePlatform.snes,
            landscape: false,
          ),
        );
        expect(
          restored.gamepadLayoutForPlatform(GamePlatform.snes, landscape: true),
          GamepadLayout.defaultForPlatform(GamePlatform.snes, landscape: true),
        );
        expect(
          restored.gamepadLayoutForPlatform(GamePlatform.ps1, landscape: true),
          customizedPs1Landscape,
        );
        expect(
          restored.gamepadLayoutForPlatform(GamePlatform.md, landscape: true),
          GamepadLayout.defaultMdLandscape,
        );
      },
    );

    test('keeps legacy layouts without L2/R2 readable', () {
      final legacyJson = GamepadLayout.defaultPs1Portrait.toJson()
        ..remove('l2Button')
        ..remove('r2Button');

      final restored = GamepadLayout.fromJson(legacyJson);

      expect(restored.l2Button, isNull);
      expect(restored.r2Button, isNull);
      expect(restored.toJson().containsKey('l2Button'), isFalse);
      expect(restored.toJson().containsKey('r2Button'), isFalse);
    });

    test('settings service saves and reloads user adjusted layouts', () async {
      SharedPreferences.setMockInitialValues({});

      final customPcePortrait = GamepadLayout.defaultTwoButtonPortrait.copyWith(
        aButton: const ButtonLayout(x: 0.70, y: 0.74, size: 1.42),
      );

      final service = SettingsService();
      await service.load();
      await service.setGamepadLayoutForPlatform(
        GamePlatform.pce,
        landscape: false,
        layout: customPcePortrait,
      );
      await service.save();

      final reloaded = SettingsService();
      await reloaded.load();

      expect(
        reloaded.settings.gamepadLayoutForPlatform(
          GamePlatform.pce,
          landscape: false,
        ),
        customPcePortrait,
      );
      expect(
        reloaded.settings.gamepadLayoutForPlatform(
          GamePlatform.pce,
          landscape: true,
        ),
        GamepadLayout.defaultForPlatform(GamePlatform.pce, landscape: true),
      );

      service.dispose();
      reloaded.dispose();
    });
  });

  group('Genesis virtual input mapping', () {
    test('labels six-button controls to Genesis Plus GX RetroPad buttons', () {
      void expectBinding(GamepadButton button, String label, int key) {
        final binding = virtualGamepadSlotBinding(GamePlatform.md, button);
        expect(binding.label, label, reason: button.name);
        expect(binding.key, key, reason: button.name);
      }

      expectBinding(GamepadButton.aButton, 'A', GBAKey.y);
      expectBinding(GamepadButton.bButton, 'B', GBAKey.b);
      expectBinding(GamepadButton.xButton, 'C', GBAKey.a);
      expectBinding(GamepadButton.lButton, 'X', GBAKey.l);
      expectBinding(GamepadButton.rButton, 'Y', GBAKey.x);
      expectBinding(GamepadButton.yButton, 'Z', GBAKey.r);
      expectBinding(GamepadButton.startButton, 'START', GBAKey.start);
      expectBinding(GamepadButton.selectButton, 'MODE', GBAKey.select);
    });
  });

  group('PlayStation virtual input mapping', () {
    test('labels editable L2/R2 controls to RetroPad triggers', () {
      final l2 = virtualGamepadSlotBinding(
        GamePlatform.ps1,
        GamepadButton.l2Button,
      );
      final r2 = virtualGamepadSlotBinding(
        GamePlatform.ps1,
        GamepadButton.r2Button,
      );

      expect(l2.label, 'L2');
      expect(l2.key, GBAKey.l2);
      expect(r2.label, 'R2');
      expect(r2.key, GBAKey.r2);
    });
  });
}

Map<String, ButtonLayout> _allButtons(GamepadLayout layout) {
  return {
    'dpad': layout.dpad,
    'a': layout.aButton,
    'b': layout.bButton,
    'l': layout.lButton,
    'r': layout.rButton,
    'start': layout.startButton,
    'select': layout.selectButton,
    if (layout.xButton != null) 'x': layout.xButton!,
    if (layout.yButton != null) 'y': layout.yButton!,
    if (layout.l2Button != null) 'l2': layout.l2Button!,
    if (layout.r2Button != null) 'r2': layout.r2Button!,
  };
}

void _expectDefaultLayoutFits({
  required GamePlatform platform,
  required Size screen,
  required bool landscape,
}) {
  final layout = GamepadLayout.defaultForPlatform(
    platform,
    landscape: landscape,
  );
  final rects = _visibleButtonRects(
    platform: platform,
    layout: layout,
    screen: screen,
    landscape: landscape,
  );

  for (final rect in rects.entries) {
    expect(rect.value.left, greaterThanOrEqualTo(0), reason: rect.key);
    expect(rect.value.top, greaterThanOrEqualTo(0), reason: rect.key);
    expect(rect.value.right, lessThanOrEqualTo(screen.width), reason: rect.key);
    expect(
      rect.value.bottom,
      lessThanOrEqualTo(screen.height),
      reason: rect.key,
    );
  }

  final entries = rects.entries.toList(growable: false);
  for (var i = 0; i < entries.length; i++) {
    for (var j = i + 1; j < entries.length; j++) {
      final a = entries[i];
      final b = entries[j];
      expect(
        a.value.overlaps(b.value),
        isFalse,
        reason:
            '$platform ${landscape ? 'landscape' : 'portrait'} '
            '${a.key} overlaps ${b.key} on $screen',
      );
    }
  }
}

Map<String, Rect> _visibleButtonRects({
  required GamePlatform platform,
  required GamepadLayout layout,
  required Size screen,
  required bool landscape,
}) {
  final sizeRef = landscape ? screen.height : screen.width;
  final baseSize = landscape ? sizeRef * 0.26 : sizeRef * 0.28;
  final buttonBase = landscape ? sizeRef * 0.16 : sizeRef * 0.17;
  final dpadBoost = landscape ? 1.25 : 1.1;
  final mdFaceButtons = platform == GamePlatform.md;

  Size circle(ButtonLayout button) {
    final size = buttonBase * button.size;
    return Size(size, size);
  }

  Size shoulder(ButtonLayout button) {
    if (mdFaceButtons) return circle(button);
    return Size(baseSize * 0.55 * button.size, baseSize * 0.30 * button.size);
  }

  Size small(ButtonLayout button) {
    return Size(baseSize * 0.40 * button.size, baseSize * 0.24 * button.size);
  }

  final buttons = <String, (ButtonLayout, Size)>{
    'dpad': (layout.dpad, Size.square(baseSize * layout.dpad.size * dpadBoost)),
    'a': (layout.aButton, circle(layout.aButton)),
    'b': (layout.bButton, circle(layout.bButton)),
    'start': (layout.startButton, small(layout.startButton)),
    'select': (layout.selectButton, small(layout.selectButton)),
  };

  if (_showsLr(platform)) {
    buttons['l'] = (layout.lButton, shoulder(layout.lButton));
    buttons['r'] = (layout.rButton, shoulder(layout.rButton));
  }

  if (_showsXy(platform)) {
    final xButton = layout.xButton ?? GamepadLayout.defaultPortrait.xButton!;
    final yButton = layout.yButton ?? GamepadLayout.defaultPortrait.yButton!;
    buttons['x'] = (xButton, circle(xButton));
    buttons['y'] = (yButton, circle(yButton));
  }

  if (_showsL2R2(platform)) {
    final l2Button =
        layout.l2Button ??
        (landscape
            ? GamepadLayout.defaultPs1Landscape.l2Button!
            : GamepadLayout.defaultPs1Portrait.l2Button!);
    final r2Button =
        layout.r2Button ??
        (landscape
            ? GamepadLayout.defaultPs1Landscape.r2Button!
            : GamepadLayout.defaultPs1Portrait.r2Button!);
    buttons['l2'] = (l2Button, small(l2Button));
    buttons['r2'] = (r2Button, small(r2Button));
  }

  return {
    for (final entry in buttons.entries)
      entry.key: _rectFor(
        layout: entry.value.$1,
        childSize: entry.value.$2,
        screen: screen,
        landscape: landscape,
      ),
  };
}

bool _showsLr(GamePlatform platform) {
  return switch (platform) {
    GamePlatform.gba ||
    GamePlatform.snes ||
    GamePlatform.md ||
    GamePlatform.n64 ||
    GamePlatform.vb ||
    GamePlatform.nds ||
    GamePlatform.ps1 => true,
    _ => false,
  };
}

bool _showsXy(GamePlatform platform) {
  return switch (platform) {
    GamePlatform.snes ||
    GamePlatform.md ||
    GamePlatform.nds ||
    GamePlatform.ps1 => true,
    _ => false,
  };
}

bool _showsL2R2(GamePlatform platform) {
  return platform == GamePlatform.ps1;
}

Rect _rectFor({
  required ButtonLayout layout,
  required Size childSize,
  required Size screen,
  required bool landscape,
}) {
  final x = layout.x * screen.width;
  final y = layout.y * screen.height;
  final minMargin = screen.width * 0.01;
  final minYMargin = landscape
      ? (screen.width * 0.107).clamp(36.0, 56.0) + screen.height * 0.02
      : minMargin;
  final left = x
      .clamp(
        minMargin,
        math.max(minMargin, screen.width - childSize.width - minMargin),
      )
      .toDouble();
  final top = y
      .clamp(
        minYMargin,
        math.max(minYMargin, screen.height - childSize.height - minMargin),
      )
      .toDouble();

  return Rect.fromLTWH(left, top, childSize.width, childSize.height);
}
