import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:retropal/core/mgba_bindings.dart';
import 'package:retropal/services/bios_service.dart';

void main() {
  group('BiosService BIOS specs', () {
    test('uses verified FreeIntv hashes for Intellivision BIOSes', () {
      final specs = BiosService.specsFor(GamePlatform.intv);
      final exec = specs.firstWhere((spec) => spec.id == 'exec');
      final grom = specs.firstWhere((spec) => spec.id == 'grom');

      expect(exec.filename, 'exec.bin');
      expect(exec.expectedSize, 8192);
      expect(exec.md5, contains('62e761035cb657903761800f4437b8af'));
      expect(exec.sha1, contains('5a65b922b562cb1f57dab51b73151283f0e20c7a'));

      expect(grom.filename, 'grom.bin');
      expect(grom.expectedSize, 2048);
      expect(grom.md5, contains('0cd5946c6473e42e8e4c2137785e427f'));
      expect(grom.sha1, contains('f9608bb4ad1cfe3640d02844c7ad8e0bcd974917'));
    });

    test('keeps documented MD5 hashes for NDS and PS1 BIOSes', () {
      final ndsSpecs = BiosService.specsFor(GamePlatform.nds);
      final ps1Specs = BiosService.specsFor(GamePlatform.ps1);

      expect(
        ndsSpecs.firstWhere((spec) => spec.id == 'bios7').md5,
        contains('df692a80a5b1bc90728bc3dfc76cd948'),
      );
      expect(
        ndsSpecs.firstWhere((spec) => spec.id == 'bios9').md5,
        contains('a392174eb3e572fed6447e956bde4b25'),
      );
      expect(
        ps1Specs.firstWhere((spec) => spec.id == 'scph5500').md5,
        contains('8dd7d5296a650fac7319bce665a6a53c'),
      );
      expect(
        ps1Specs.firstWhere((spec) => spec.id == 'scph5501').md5,
        contains('490f666e1afb15b7362b406ed1cea246'),
      );
      expect(
        ps1Specs.firstWhere((spec) => spec.id == 'scph5502').md5,
        contains('32736f17079d0b2b7024407c39bd3050'),
      );
    });

    test('hash verification ignores the reference size', () {
      final bytes = <int>[1, 2, 3, 4, 5];
      final spec = BiosSpec(
        id: 'demo',
        filename: 'demo.bin',
        label: 'Demo',
        description: 'Demo',
        expectedSize: 999999,
        md5: [crypto.md5.convert(bytes).toString()],
        sha1: [crypto.sha1.convert(bytes).toString()],
      );

      expect(BiosService.bytesMatchHashesForSpec(spec, bytes), isTrue);
    });

    test('hash verification rejects mismatched dumps', () {
      final bytes = <int>[1, 2, 3, 4, 5];
      final spec = BiosSpec(
        id: 'demo',
        filename: 'demo.bin',
        label: 'Demo',
        description: 'Demo',
        expectedSize: bytes.length,
        md5: ['00000000000000000000000000000000'],
        sha1: [crypto.sha1.convert(bytes).toString()],
      );

      expect(BiosService.bytesMatchHashesForSpec(spec, bytes), isFalse);
    });
  });
}
