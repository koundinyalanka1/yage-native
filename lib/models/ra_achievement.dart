library;

const String _badgeCdn = 'https://media.retroachievements.org/Badge';

class RAAchievement {
  final int id;

  final String title;

  final String description;

  final int points;

  final int trueRatio;

  final String badgeName;

  final String? type;

  final String? memAddr;

  final int displayOrder;

  final int numAwarded;

  final int numAwardedHardcore;

  final DateTime? dateEarned;

  final DateTime? dateEarnedHardcore;

  const RAAchievement({
    required this.id,
    required this.title,
    required this.description,
    required this.points,
    required this.trueRatio,
    required this.badgeName,
    this.type,
    this.memAddr,
    this.displayOrder = 0,
    this.numAwarded = 0,
    this.numAwardedHardcore = 0,
    this.dateEarned,
    this.dateEarnedHardcore,
  });

  String get badgeUrl => '$_badgeCdn/$badgeName.png';

  String get badgeLockedUrl => '$_badgeCdn/${badgeName}_lock.png';

  bool get isEarned => dateEarned != null;

  bool get isEarnedHardcore => dateEarnedHardcore != null;

  factory RAAchievement.fromJson(Map<String, dynamic> json) {
    return RAAchievement(
      id: _toInt(json['ID']),
      title: json['Title'] as String? ?? '',
      description: json['Description'] as String? ?? '',
      points: _toInt(json['Points']),
      trueRatio: _toInt(json['TrueRatio']),
      badgeName: json['BadgeName'] as String? ?? '00000',
      type: (json['Type'] ?? json['type']) as String?,
      memAddr: (json['MemAddr'] ?? json['memAddr']) as String?,
      displayOrder: _toInt(json['DisplayOrder']),
      numAwarded: _toInt(json['NumAwarded']),
      numAwardedHardcore: _toInt(json['NumAwardedHardcore']),
      dateEarned: _parseDate(json['DateEarned']),
      dateEarnedHardcore: _parseDate(json['DateEarnedHardcore']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'ID': id,
      'Title': title,
      'Description': description,
      'Points': points,
      'TrueRatio': trueRatio,
      'BadgeName': badgeName,
      'type': type,
      'memAddr': memAddr,
      'DisplayOrder': displayOrder,
      'NumAwarded': numAwarded,
      'NumAwardedHardcore': numAwardedHardcore,
      'DateEarned': dateEarned?.toIso8601String(),
      'DateEarnedHardcore': dateEarnedHardcore?.toIso8601String(),
    };
  }
}

class RAGameData {
  final int gameId;

  final String title;

  final String? imageIcon;

  final String? imageBoxArt;

  final String? consoleName;

  final int numDistinctPlayers;

  final List<RAAchievement> achievements;

  final int numAwardedToUser;

  final int numAwardedToUserHardcore;

  final String? userCompletion;

  final String? userCompletionHardcore;

  final DateTime fetchedAt;

  const RAGameData({
    required this.gameId,
    required this.title,
    this.imageIcon,
    this.imageBoxArt,
    this.consoleName,
    this.numDistinctPlayers = 0,
    required this.achievements,
    this.numAwardedToUser = 0,
    this.numAwardedToUserHardcore = 0,
    this.userCompletion,
    this.userCompletionHardcore,
    required this.fetchedAt,
  });

  int get numAchievements => achievements.length;

  int get totalPoints =>
      achievements.fold(0, (sum, a) => sum + a.points);

  int get earnedPoints =>
      achievements.where((a) => a.isEarned).fold(0, (sum, a) => sum + a.points);

  int get earnedPointsHardcore => achievements
      .where((a) => a.isEarnedHardcore)
      .fold(0, (sum, a) => sum + a.points);

  String? get imageIconUrl => imageIcon != null
      ? 'https://retroachievements.org$imageIcon'
      : null;

  String? get imageBoxArtUrl => imageBoxArt != null
      ? 'https://retroachievements.org$imageBoxArt'
      : null;

  bool get isStale =>
      DateTime.now().difference(fetchedAt).inHours >= 24;

  factory RAGameData.fromJson(Map<String, dynamic> json) {
    final List<RAAchievement> achievements;
    final rawAch = json['Achievements'];
    if (rawAch is Map<String, dynamic>) {
      achievements = rawAch.values
          .map((e) => RAAchievement.fromJson(e as Map<String, dynamic>))
          .toList();
    } else if (rawAch is List) {
      achievements = rawAch
          .map((e) => RAAchievement.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      achievements = [];
    }
    achievements.sort((a, b) => a.displayOrder.compareTo(b.displayOrder));

    return RAGameData(
      gameId: _toInt(json['ID'] ?? json['gameId']),
      title: json['Title'] as String? ?? json['title'] as String? ?? '',
      imageIcon: json['ImageIcon'] as String? ?? json['imageIcon'] as String?,
      imageBoxArt:
          json['ImageBoxArt'] as String? ?? json['imageBoxArt'] as String?,
      consoleName:
          json['ConsoleName'] as String? ?? json['consoleName'] as String?,
      numDistinctPlayers: _toInt(json['NumDistinctPlayers'] ??
          json['numDistinctPlayers']),
      achievements: achievements,
      numAwardedToUser:
          _toInt(json['NumAwardedToUser'] ?? json['numAwardedToUser']),
      numAwardedToUserHardcore: _toInt(
          json['NumAwardedToUserHardcore'] ??
              json['numAwardedToUserHardcore']),
      userCompletion: json['UserCompletion'] as String? ??
          json['userCompletion'] as String?,
      userCompletionHardcore: json['UserCompletionHardcore'] as String? ??
          json['userCompletionHardcore'] as String?,
      fetchedAt: json['fetchedAt'] != null
          ? DateTime.parse(json['fetchedAt'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'gameId': gameId,
      'title': title,
      'imageIcon': imageIcon,
      'imageBoxArt': imageBoxArt,
      'consoleName': consoleName,
      'numDistinctPlayers': numDistinctPlayers,
      'Achievements': achievements.map((a) => a.toJson()).toList(),
      'numAwardedToUser': numAwardedToUser,
      'numAwardedToUserHardcore': numAwardedToUserHardcore,
      'userCompletion': userCompletion,
      'userCompletionHardcore': userCompletionHardcore,
      'fetchedAt': fetchedAt.toIso8601String(),
    };
  }

  @override
  String toString() =>
      'RAGameData(id=$gameId, "$title", '
      '${achievements.length} achievements, '
      '$earnedPoints/$totalPoints pts, '
      'stale=$isStale)';
}

int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is! String || v.isEmpty) return null;
  return DateTime.tryParse(v.replaceFirst(' ', 'T'));
}
