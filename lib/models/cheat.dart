import '../core/mgba_bindings.dart';

/// Format hint for the cheat code (shown to the user as guidance).
///
/// The libretro cores that YAGE ships with auto-detect the code format
/// from the string layout, so [CheatType] is a UX hint only — it drives
/// which chip is preselected and which example hint is shown, but the
/// native core does not receive the enum value.
enum CheatType {
  gameShark('GameShark / Action Replay'),
  gameGenie('Game Genie'),
  proActionReplay('Pro Action Replay'),
  codeBreaker('CodeBreaker'),
  raw('Raw / Other');

  final String label;
  const CheatType(this.label);

  /// Parse a [CheatType] from its [name]. Returns [raw] if unrecognised.
  static CheatType fromName(String name) {
    return CheatType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => CheatType.raw,
    );
  }

  /// Cheat formats that are typically valid for a given [platform].
  ///
  /// [CheatType.raw] is always included as a last-resort fallback for
  /// users entering codes in an unusual format. The order determines the
  /// chip order in the Add Cheat dialog; the first entry is the default.
  static List<CheatType> supportedFor(GamePlatform platform) {
    switch (platform) {
      case GamePlatform.gba:
        return const [
          CheatType.gameShark,
          CheatType.codeBreaker,
          CheatType.raw,
        ];
      case GamePlatform.gb:
      case GamePlatform.gbc:
        return const [CheatType.gameShark, CheatType.gameGenie, CheatType.raw];
      case GamePlatform.nes:
        return const [CheatType.gameGenie, CheatType.raw];
      case GamePlatform.snes:
        return const [
          CheatType.gameGenie,
          CheatType.proActionReplay,
          CheatType.raw,
        ];
      case GamePlatform.md:
      case GamePlatform.sms:
      case GamePlatform.gg:
        return const [
          CheatType.gameGenie,
          CheatType.proActionReplay,
          CheatType.raw,
        ];
      case GamePlatform.n64:
        return const [CheatType.gameShark, CheatType.raw];
      case GamePlatform.ps1:
        // GameShark / CodeBreaker are the two dominant PS1 cheat formats;
        // Beetle PSX accepts both via libretro's raw cheat-set API.
        return const [
          CheatType.gameShark,
          CheatType.codeBreaker,
          CheatType.raw,
        ];
      case GamePlatform.nds:
        // Action Replay DS codes share the GameShark family format and are
        // accepted by melonDS via the raw cheat-set API.
        return const [CheatType.gameShark, CheatType.raw];
      case GamePlatform.sg1000:
      case GamePlatform.pce:
      case GamePlatform.sgx:
      case GamePlatform.ngp:
      case GamePlatform.ws:
      case GamePlatform.wsc:
      case GamePlatform.a2600:
      case GamePlatform.vb:
      case GamePlatform.tic80:
      case GamePlatform.pico8:
      case GamePlatform.intv:
      case GamePlatform.unknown:
        return const [CheatType.raw];
    }
  }

  /// Best default format to pre-select for [platform].
  static CheatType defaultFor(GamePlatform platform) =>
      supportedFor(platform).first;
}

/// A single user-entered cheat code. All cheats are entered manually
/// by the user — no bundled cheat database (Play Store compliant).
///
/// Cheats are persisted in the SQLite database so they survive across
/// sessions. The [isActive] flag remembers the user's last toggle state
/// and cheats are re-applied to the native core when the game loads.
class Cheat {
  final String id;
  final GamePlatform system;
  final String gameId;
  String title;
  String cheatCode;
  final CheatType cheatType;

  /// Whether the user toggled this cheat on. Persisted across sessions.
  bool isActive;

  /// Index used with the libretro `retro_cheat_set` API.
  ///
  /// **Runtime-only**: intentionally not part of [toRow] / [fromRow] and
  /// not accepted by the constructor. [CheatSession] owns this field and
  /// keeps it equal to the cheat's position in the active session list
  /// (contiguous from 0). Any code outside [CheatSession] that mutates
  /// this value will desynchronise it from the native core.
  int coreIndex = -1;

  Cheat({
    required this.id,
    required this.system,
    required this.gameId,
    required this.title,
    required this.cheatCode,
    required this.cheatType,
    this.isActive = false,
  });

  /// Serialise to a map suitable for SQLite row insertion.
  Map<String, Object?> toRow() {
    return {
      'id': id,
      'game_path': gameId,
      'system': system.name,
      'title': title,
      'cheat_code': cheatCode,
      'cheat_type': cheatType.name,
      'is_active': isActive ? 1 : 0,
    };
  }

  /// Deserialise from a SQLite row map.
  factory Cheat.fromRow(Map<String, Object?> row) {
    return Cheat(
      id: row['id'] as String,
      gameId: row['game_path'] as String,
      system: GamePlatform.values.firstWhere(
        (e) => e.name == (row['system'] as String),
        orElse: () => GamePlatform.unknown,
      ),
      title: row['title'] as String,
      cheatCode: row['cheat_code'] as String,
      cheatType: CheatType.fromName(row['cheat_type'] as String),
      isActive: (row['is_active'] as int) == 1,
    );
  }
}
