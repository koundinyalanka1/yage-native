import '../core/mgba_bindings.dart';
import 'game_rom.dart';

enum SystemFilter {
  all,
  gb,
  gbc,
  gba,
  nes,
  snes,
  n64,
  genesis,
  sms,
  gg,
  sg1000,
  pce,
  sgx,
  ngp,
  ngpc,
  ws,
  wsc,
}

class SystemFilterOption {
  final SystemFilter value;
  final String label;

  const SystemFilterOption({required this.value, required this.label});
}

const systemFilterOptions = <SystemFilterOption>[
  SystemFilterOption(value: SystemFilter.all, label: 'All Systems'),
  SystemFilterOption(value: SystemFilter.gb, label: 'Game Boy (GB)'),
  SystemFilterOption(value: SystemFilter.gbc, label: 'Game Boy Color (GBC)'),
  SystemFilterOption(value: SystemFilter.gba, label: 'Game Boy Advance (GBA)'),
  SystemFilterOption(
    value: SystemFilter.nes,
    label: 'Nintendo Entertainment System (NES)',
  ),
  SystemFilterOption(
    value: SystemFilter.snes,
    label: 'Super Nintendo Entertainment System (SNES)',
  ),
  SystemFilterOption(value: SystemFilter.n64, label: 'Nintendo 64 (N64)'),
  SystemFilterOption(value: SystemFilter.genesis, label: 'Sega Genesis (GEN)'),
  SystemFilterOption(
    value: SystemFilter.sms,
    label: 'Sega Master System (SMS)',
  ),
  SystemFilterOption(value: SystemFilter.gg, label: 'Sega Game Gear (GG)'),
  SystemFilterOption(
    value: SystemFilter.sg1000,
    label: 'Sega SG-1000 (SG-1000)',
  ),
  SystemFilterOption(
    value: SystemFilter.pce,
    label: 'PC Engine / TurboGrafx-16 (PCE)',
  ),
  SystemFilterOption(value: SystemFilter.sgx, label: 'SuperGrafx (SGX)'),
  SystemFilterOption(value: SystemFilter.ngp, label: 'Neo Geo Pocket (NGP)'),
  SystemFilterOption(
    value: SystemFilter.ngpc,
    label: 'Neo Geo Pocket Color (NGPC)',
  ),
  SystemFilterOption(value: SystemFilter.ws, label: 'WonderSwan (WS)'),
  SystemFilterOption(value: SystemFilter.wsc, label: 'WonderSwan Color (WSC)'),
];

extension SystemFilterX on SystemFilter {
  String get label {
    return systemFilterOptions.firstWhere((opt) => opt.value == this).label;
  }

  bool matchesGame(GameRom game) {
    final ext = game.extension.toLowerCase();
    return switch (this) {
      SystemFilter.all => true,
      SystemFilter.gb => game.platform == GamePlatform.gb,
      SystemFilter.gbc => game.platform == GamePlatform.gbc,
      SystemFilter.gba => game.platform == GamePlatform.gba,
      SystemFilter.nes => game.platform == GamePlatform.nes,
      SystemFilter.snes => game.platform == GamePlatform.snes,
      SystemFilter.n64 => game.platform == GamePlatform.n64,
      SystemFilter.genesis => game.platform == GamePlatform.md,
      SystemFilter.sms => game.platform == GamePlatform.sms,
      SystemFilter.gg => game.platform == GamePlatform.gg,
      SystemFilter.sg1000 => game.platform == GamePlatform.sg1000,
      SystemFilter.pce => game.platform == GamePlatform.pce,
      SystemFilter.sgx => game.platform == GamePlatform.sgx,
      SystemFilter.ngp => ext == '.ngp',
      SystemFilter.ngpc => ext == '.ngc',
      SystemFilter.ws => game.platform == GamePlatform.ws,
      SystemFilter.wsc => game.platform == GamePlatform.wsc,
    };
  }
}
