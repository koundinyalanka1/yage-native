import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/ra_achievement.dart';
import '../utils/theme.dart';
import '../widgets/tv_focusable.dart';

/// Full-screen dialog/page showing all achievements for the current game.
///
/// Displays achievements in a scrollable list grouped by status:
///   • Earned (hardcore) — gold accent
///   • Earned (softcore) — green accent
///   • Locked — greyed out
///
/// Each item shows the badge image, title, description, points, and
/// an earned date if applicable.
class AchievementsScreen extends StatefulWidget {
  final RAGameData gameData;
  final bool isHardcore;

  const AchievementsScreen({
    super.key,
    required this.gameData,
    required this.isHardcore,
  });

  @override
  State<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends State<AchievementsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      if (mounted) {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<RAAchievement> get _allAchievements => widget.gameData.achievements;

  List<RAAchievement> get _earnedHardcore =>
      _allAchievements.where((a) => a.isEarnedHardcore).toList();

  List<RAAchievement> get _earnedSoftcore =>
      _allAchievements.where((a) => a.isEarned && !a.isEarnedHardcore).toList();

  List<RAAchievement> get _locked =>
      _allAchievements.where((a) => !a.isEarned).toList();

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final total = _allAchievements.length;
    final earnedCount = widget.isHardcore
        ? _earnedHardcore.length
        : _allAchievements.where((a) => a.isEarned).length;
    final earnedPts = widget.isHardcore
        ? widget.gameData.earnedPointsHardcore
        : widget.gameData.earnedPoints;
    final totalPts = widget.gameData.totalPoints;
    final progress = total > 0 ? earnedCount / total : 0.0;

    final indicatorColor = widget.isHardcore ? Colors.amber : colors.accent;

    return Scaffold(
      backgroundColor: colors.backgroundDark,
      appBar: AppBar(
        backgroundColor: colors.surface,
        leading: TvFocusable(
          onTap: () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(8),
          child: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.gameData.title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '$earnedCount / $total achievements • '
              '$earnedPts / $totalPts pts',
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
        ),
      ),
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Column(
            children: [
              // ── Progress bar + Tab bar ──
              FocusTraversalOrder(
                order: const NumericFocusOrder(0),
                child: Material(
                  color: colors.surface,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: colors.backgroundDark,
                            color: indicatorColor,
                          ),
                        ),
                      ),
                      TabBar(
                        controller: _tabController,
                        indicatorColor: indicatorColor,
                        labelColor: colors.textPrimary,
                        unselectedLabelColor: colors.textMuted,
                        labelStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overlayColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.focused)) {
                            return indicatorColor.withAlpha(50);
                          }
                          if (states.contains(WidgetState.hovered)) {
                            return indicatorColor.withAlpha(25);
                          }
                          return null;
                        }),
                        splashBorderRadius: BorderRadius.circular(8),
                        dividerHeight: 0,
                        tabs: [
                          Tab(text: 'All ($total)'),
                          Tab(
                            text:
                                'Earned (${_earnedHardcore.length + _earnedSoftcore.length})',
                          ),
                          Tab(text: 'Locked (${_locked.length})'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // ── Tab content ──
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildList(_allAchievements),
                      _buildList([..._earnedHardcore, ..._earnedSoftcore]),
                      _buildList(_locked),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<RAAchievement> achievements) {
    final colors = AppColorTheme.of(context);
    if (achievements.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.emoji_events_outlined,
              size: 48,
              color: colors.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              'No achievements',
              style: TextStyle(fontSize: 16, color: colors.textMuted),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: achievements.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final ach = achievements[index];
        return TvFocusable(
          autofocus: index == 0,
          borderRadius: BorderRadius.circular(12),
          child: _AchievementTile(
            achievement: ach,
            isHardcoreMode: widget.isHardcore,
          ),
        );
      },
    );
  }
}

/// A single achievement tile in the list.
class _AchievementTile extends StatelessWidget {
  final RAAchievement achievement;
  final bool isHardcoreMode;

  const _AchievementTile({
    required this.achievement,
    required this.isHardcoreMode,
  });

  bool get _isEarned =>
      isHardcoreMode ? achievement.isEarnedHardcore : achievement.isEarned;

  DateTime? get _dateEarned =>
      isHardcoreMode ? achievement.dateEarnedHardcore : achievement.dateEarned;

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final isHcEarned = achievement.isEarnedHardcore;
    final isSoftOnly = achievement.isEarned && !achievement.isEarnedHardcore;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _isEarned
            ? (isHcEarned
                  ? Colors.amber.withAlpha(15)
                  : Colors.green.withAlpha(15))
            : colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isEarned
              ? (isHcEarned
                    ? Colors.amber.withAlpha(80)
                    : Colors.green.withAlpha(80))
              : colors.surfaceLight,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Badge image
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 48,
              height: 48,
              child: CachedNetworkImage(
                imageUrl: _isEarned
                    ? achievement.badgeUrl
                    : achievement.badgeLockedUrl,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(
                  color: colors.backgroundLight,
                  child: const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                errorWidget: (context, url, error) => Container(
                  color: colors.backgroundLight,
                  child: Icon(
                    _isEarned
                        ? Icons.emoji_events
                        : Icons.emoji_events_outlined,
                    size: 24,
                    color: _isEarned ? Colors.amber : colors.textMuted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Text content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title row
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        achievement.title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _isEarned
                              ? colors.textPrimary
                              : colors.textSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Points badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _isEarned
                            ? (isHcEarned
                                  ? Colors.amber.withAlpha(40)
                                  : Colors.green.withAlpha(40))
                            : colors.backgroundLight,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${achievement.points} pts',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: _isEarned
                              ? (isHcEarned ? Colors.amber : Colors.green)
                              : colors.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),

                // Description
                Text(
                  achievement.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: _isEarned ? colors.textSecondary : colors.textMuted,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),

                // Type tag + earned date
                if (achievement.type != null || _dateEarned != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // Type tag
                      if (achievement.type != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: _typeColor(achievement.type!).withAlpha(30),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _typeColor(
                                achievement.type!,
                              ).withAlpha(80),
                              width: 0.5,
                            ),
                          ),
                          child: Text(
                            _typeLabel(achievement.type!),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: _typeColor(achievement.type!),
                            ),
                          ),
                        ),

                      // Hardcore / softcore badge
                      if (_isEarned) ...[
                        if (achievement.type != null) const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: isHcEarned
                                ? Colors.redAccent.withAlpha(30)
                                : isSoftOnly
                                ? Colors.blue.withAlpha(30)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            isHcEarned ? 'Hardcore' : 'Softcore',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: isHcEarned
                                  ? Colors.redAccent
                                  : Colors.blue,
                            ),
                          ),
                        ),
                      ],

                      const Spacer(),

                      // Earned date
                      if (_dateEarned != null)
                        Text(
                          _formatDate(_dateEarned!),
                          style: TextStyle(
                            fontSize: 10,
                            color: colors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ],

                // Rarity info
                if (achievement.numAwarded > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${achievement.numAwardedHardcore} HC / '
                    '${achievement.numAwarded} players earned',
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.textMuted.withAlpha(150),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _typeLabel(String type) {
    return switch (type) {
      'progression' => 'Progression',
      'win_condition' => 'Win Condition',
      'missable' => 'Missable',
      _ => type,
    };
  }

  static Color _typeColor(String type) {
    return switch (type) {
      'progression' => Colors.blue,
      'win_condition' => Colors.green,
      'missable' => Colors.orange,
      _ => Colors.grey,
    };
  }

  static String _formatDate(DateTime date) {
    final months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month]} ${date.day}, ${date.year}';
  }
}
