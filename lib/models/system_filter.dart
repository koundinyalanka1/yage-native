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
  nds,
  ps1,
  intv,
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
  a2600,
  vb,
  tic80,
  pico8,
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
  SystemFilterOption(value: SystemFilter.nds, label: 'Nintendo DS (NDS)'),
  SystemFilterOption(
    value: SystemFilter.ps1,
    label: 'Sony PlayStation (PS1) (zip file with .cue, .bin only)',
  ),
  SystemFilterOption(
    value: SystemFilter.intv,
    label: 'Mattel Intellivision (INTV)',
  ),
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
  SystemFilterOption(value: SystemFilter.a2600, label: 'Atari 2600 (A2600)'),
  SystemFilterOption(value: SystemFilter.vb, label: 'Virtual Boy (VB)'),
  SystemFilterOption(value: SystemFilter.tic80, label: 'TIC-80'),
  SystemFilterOption(value: SystemFilter.pico8, label: 'PICO-8'),
];

/// Platforms not yet available on Android TV (work in progress).
const tvRestrictedPlatforms = <SystemFilter>{SystemFilter.nds, SystemFilter.ps1};

/// Platform filter options visible on TV (excludes WIP platforms).
const tvSystemFilterOptions = <SystemFilterOption>[
  // Computed at compile time — all entries except nds/ps1.
  ...[
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
    SystemFilterOption(
      value: SystemFilter.intv,
      label: 'Mattel Intellivision (INTV)',
    ),
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
    SystemFilterOption(value: SystemFilter.a2600, label: 'Atari 2600 (A2600)'),
    SystemFilterOption(value: SystemFilter.vb, label: 'Virtual Boy (VB)'),
    SystemFilterOption(value: SystemFilter.tic80, label: 'TIC-80'),
    SystemFilterOption(value: SystemFilter.pico8, label: 'PICO-8'),
  ],
];

/// [GamePlatform] values restricted on TV (mirrors [tvRestrictedPlatforms]).
const tvRestrictedGamePlatforms = <GamePlatform>{GamePlatform.nds, GamePlatform.ps1};

extension SystemFilterX on SystemFilter {
  String get label {
    // Defensive: never throw if a SystemFilter value isn't in the options
    // list (e.g. a new enum value added without a matching option). Fall
    // back to the enum name instead of crashing via firstWhere's StateError.
    for (final opt in systemFilterOptions) {
      if (opt.value == this) return opt.label;
    }
    return name;
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
      SystemFilter.nds => game.platform == GamePlatform.nds,
      SystemFilter.ps1 => game.platform == GamePlatform.ps1,
      SystemFilter.intv => game.platform == GamePlatform.intv,
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
      SystemFilter.a2600 => game.platform == GamePlatform.a2600,
      SystemFilter.vb => game.platform == GamePlatform.vb,
      SystemFilter.tic80 => game.platform == GamePlatform.tic80,
      SystemFilter.pico8 => game.platform == GamePlatform.pico8,
    };
  }
}
