import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retropal/core/mgba_bindings.dart';
import 'package:retropal/models/game_rom.dart';

void main() {
  group('GameRom platform detection', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('retropal_rom_detect_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    File writePs1Bin(String name) {
      final file = File(p.join(tempDir.path, name));
      final bytes = List<int>.filled(64 * 1024, 0);
      final marker = 'PLAYSTATION'.codeUnits;
      const offset = 32 * 1024;
      for (var i = 0; i < marker.length; i++) {
        bytes[offset + i] = marker[i];
      }
      file.writeAsBytesSync(bytes);
      return file;
    }

    test('loose PS1 cue/bin sets are not classified as PS1 games', () {
      final bin = writePs1Bin('GAME.BIN');
      final cue = File(p.join(tempDir.path, 'Game.cue'))
        ..writeAsStringSync(
          'FILE "GAME.BIN" BINARY\n'
          '  TRACK 01 MODE2/2352\n'
          '    INDEX 01 00:00:00\n',
        );

      expect(GameRom.isLikelyPs1CueSheet(cue.path), isTrue);
      expect(GameRom.detectPlatformForFile(cue.path), GamePlatform.unknown);
      expect(GameRom.fromPath(cue.path), isNull);
      expect(GameRom.detectPlatformForFile(bin.path), GamePlatform.unknown);
      expect(GameRom.fromPath(bin.path), isNull);
    });

    test('PS1 cue detection tolerates flattened archive track paths', () {
      writePs1Bin('GAME.BIN');
      final cue = File(p.join(tempDir.path, 'Game.cue'))
        ..writeAsStringSync(
          r'FILE "tracks\GAME.BIN" BINARY'
          '\n  TRACK 01 MODE2/2352\n'
          '    INDEX 01 00:00:00\n',
        );

      expect(GameRom.isLikelyPs1CueSheet(cue.path), isTrue);
      expect(GameRom.detectPlatformForFile(cue.path), GamePlatform.unknown);
    });

    test('loose PS1 single-file formats are not imported', () {
      final chd = File(p.join(tempDir.path, 'Game.chd'))
        ..writeAsBytesSync([0, 1, 2, 3]);
      final pbp = File(p.join(tempDir.path, 'Game.pbp'))
        ..writeAsBytesSync([0, 1, 2, 3]);

      expect(GameRom.detectPlatformForFile(chd.path), GamePlatform.unknown);
      expect(GameRom.fromPath(chd.path), isNull);
      expect(GameRom.detectPlatformForFile(pbp.path), GamePlatform.unknown);
      expect(GameRom.fromPath(pbp.path), isNull);
    });
  });
}
