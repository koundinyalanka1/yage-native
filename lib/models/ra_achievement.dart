/// Data models for RetroAchievements game & achievement metadata.
///
/// These are pure data classes with JSON serialisation for disk caching.
/// No network I/O happens here — see `RetroAchievementsService` for that.
library;

// ═══════════════════════════════════════════════════════════════════════
//  Individual achievement
// ═══════════════════════════════════════════════════════════════════════

/// Badge image base URL on the RetroAchievements CDN.
const String _badgeCdn = 'https://media.retroachievements.org/Badge';

/// A single RetroAchievements achievement with its metadata.
class RAAchievement {
  /// RA-internal achievement ID.
  final int id;

  /// Short human-readable title (e.g. "First Steps").
  final String title;

  /// Longer description of unlock criteria.
  final String description;

  /// Point value awarded for unlocking this achievement.
  final int points;

  /// RetroAchievements "TrueRatio" — weighted difficulty score.
  final int trueRatio;

  /// Badge image identifier used to build CDN URLs.
  final String badgeName;

  /// Achievement type tag from the API.
  ///
  /// Common values:
  ///   • `"progression"` — story / mandatory progress
  ///   • `"win_condition"` — game completion
  ///   • `"missable"` — can be permanently missed
  ///   • `null` — standard / unclassified
  final String? type;

  /// Raw rcheevos condition string from the `MemAddr` field of the
  /// RA `patch` endpoint.  Used by the runtime evaluator to detect
  /// unlocks in real-time by reading emulator memory each frame.
  final String? memAddr;

  /// Display order as defined by the achievement set author.
  final int displayOrder;

  /// Total number of players who have earned this (softcore).
  final int numAwarded;

  /// Total number of players who have earned this (hardcore).
  final int numAwardedHardcore;

  /// When the logged-in user earned this (softcore), or `null`.
  final DateTime? dateEarned;

  /// When the logged-in user earned this (hardcore), or `null`.
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

  // ── Computed badge URLs (loaded lazily by the UI) ──────────────────

  /// Unlocked badge image URL.
  String get badgeUrl => '$_badgeCdn/$badgeName.png';

  /// Locked / greyed-out badge image URL.
  String get badgeLockedUrl => '$_badgeCdn/${badgeName}_lock.png';

  /// Whether the logged-in user has earned this achievement (any mode).
  bool get isEarned => dateEarned != null;

  /// Whether earned in hardcore mode specifically.
  bool get isEarnedHardcore => dateEarnedHardcore != null;

  // ── JSON serialisation ─────────────────────────────────────────────

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

// ═══════════════════════════════════════════════════════════════════════
//  Game-level achievement data (the full set for one GameID)
// ═══════════════════════════════════════════════════════════════════════

/// All achievement metadata for a single RA game, plus cache bookkeeping.
class RAGameData {
  /// The RA game ID this data belongs to.
  final int gameId;

  /// Official game title from RA.
  final String title;

  /// Relative path to the game icon on RA (e.g. "/Images/012345.png").
  final String? imageIcon;

  /// Relative path to the box art on RA.
  final String? imageBoxArt;

  /// Console name (e.g. "Game Boy Advance").
  final String? consoleName;

  /// Number of distinct players who have played this game on RA.
  final int numDistinctPlayers;

  /// The full list of achievements, sorted by [displayOrder].
  final List<RAAchievement> achievements;

  /// How many achievements the user has earned (softcore).
  final int numAwardedToUser;

  /// How many achievements the user has earned (hardcore).
  final int numAwardedToUserHardcore;

  /// User completion percentage string (e.g. "45.00%").
  final String? userCompletion;

  /// User hardcore completion percentage string.
  final String? userCompletionHardcore;

  /// Timestamp when this data was fetched from the API.
  /// Used by the caching layer to determine staleness.
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

  // ── Computed properties ────────────────────────────────────────────

  /// Total number of achievements in this set.
  int get numAchievements => achievements.length;

  /// Sum of all achievement point values.
  int get totalPoints =>
      achievements.fold(0, (sum, a) => sum + a.points);

  /// Sum of points the user has earned (softcore).
  int get earnedPoints =>
      achievements.where((a) => a.isEarned).fold(0, (sum, a) => sum + a.points);

  /// Sum of points the user has earned (hardcore).
  int get earnedPointsHardcore => achievements
      .where((a) => a.isEarnedHardcore)
      .fold(0, (sum, a) => sum + a.points);

  /// Full URL for the game icon.
  String? get imageIconUrl => imageIcon != null
      ? 'https://retroachievements.org$imageIcon'
      : null;

  /// Full URL for the box art.
  String? get imageBoxArtUrl => imageBoxArt != null
      ? 'https://retroachievements.org$imageBoxArt'
      : null;

  /// Whether this cached data is stale (older than 24 hours).
  bool get isStale =>
      DateTime.now().difference(fetchedAt).inHours >= 24;

  // ── JSON serialisation (for disk cache) ────────────────────────────

  factory RAGameData.fromJson(Map<String, dynamic> json) {
    // Achievements come as a Map<String, dynamic> from the RA API,
    // but we also accept a List when reading back from our own cache.
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

    // Sort by display order so the list is always in authored sequence.
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

// ═══════════════════════════════════════════════════════════════════════
//  Shared helpers
// ═══════════════════════════════════════════════════════════════════════

/// Safely coerce a dynamic value to int (RA API sometimes returns strings).
int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// Parse an RA date string ("YYYY-MM-DD HH:MM:SS") or ISO-8601 string.
/// Returns `null` for missing / empty / unparseable values.
DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is! String || v.isEmpty) return null;
  // RA API uses space-separated format; DateTime.tryParse handles both.
  return DateTime.tryParse(v.replaceFirst(' ', 'T'));
}
