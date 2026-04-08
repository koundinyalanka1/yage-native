import '../core/mgba_bindings.dart';

enum CheatType {
  gameShark('GameShark / Action Replay'),
  gameGenie('Game Genie'),
  proActionReplay('Pro Action Replay'),
  raw('Raw / Other');

  final String label;
  const CheatType(this.label);

  static CheatType fromName(String name) {
    return CheatType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => CheatType.raw,
    );
  }
}

class Cheat {
  final String id;
  final GamePlatform system;
  final String gameId;
  String title;
  String cheatCode;
  final CheatType cheatType;

  bool isActive;

  int coreIndex;

  Cheat({
    required this.id,
    required this.system,
    required this.gameId,
    required this.title,
    required this.cheatCode,
    required this.cheatType,
    this.isActive = false,
    this.coreIndex = -1,
  });

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

