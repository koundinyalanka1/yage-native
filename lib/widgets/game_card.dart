import 'dart:io';

import 'package:flutter/material.dart';

import '../models/game_rom.dart';
import '../core/mgba_bindings.dart';
import '../utils/tv_detector.dart';
import '../utils/theme.dart';

class GameCard extends StatelessWidget {
  final GameRom game;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isSelected;

  const GameCard({
    super.key,
    required this.game,
    required this.onTap,
    this.onLongPress,
    this.isSelected = false,
  });

  Color _platformColor(AppColorTheme colors) => switch (game.platform) {
    GamePlatform.gb => colors.gbColor,
    GamePlatform.gbc => colors.gbcColor,
    GamePlatform.gba => colors.gbaColor,
    GamePlatform.nes => colors.nesColor,
    GamePlatform.snes => colors.snesColor,
    GamePlatform.sms => colors.smsColor,
    GamePlatform.gg => colors.ggColor,
    GamePlatform.md => colors.mdColor,
    GamePlatform.pce => colors.mdColor,
    GamePlatform.sgx => colors.mdColor,
    GamePlatform.n64 => colors.mdColor,
    GamePlatform.sg1000 => colors.smsColor,
    GamePlatform.ngp => colors.ngpColor,
    GamePlatform.ws => colors.wsColor,
    GamePlatform.wsc => colors.wscColor,
    GamePlatform.unknown => colors.textMuted,
  };

  IconData get _platformIcon => switch (game.platform) {
    GamePlatform.gb => Icons.sports_esports,
    GamePlatform.gbc => Icons.gamepad,
    GamePlatform.gba => Icons.videogame_asset,
    GamePlatform.nes => Icons.tv,
    GamePlatform.snes => Icons.games,
    GamePlatform.sms => Icons.smart_display,
    GamePlatform.gg => Icons.phone_android,
    GamePlatform.md => Icons.album,
    GamePlatform.pce => Icons.album,
    GamePlatform.sgx => Icons.album,
    GamePlatform.n64 => Icons.sports_esports,
    GamePlatform.sg1000 => Icons.videogame_asset_outlined,
    GamePlatform.ngp => Icons.gamepad_outlined,
    GamePlatform.ws => Icons.smartphone,
    GamePlatform.wsc => Icons.smartphone,
    GamePlatform.unknown => Icons.help_outline,
  };

  Widget _buildPlaceholder(AppColorTheme colors) {
    final pColor = _platformColor(colors);
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _GridPatternPainter(color: pColor.withAlpha(26)),
          ),
        ),
        Center(
          child: Icon(_platformIcon, size: 48, color: pColor.withAlpha(204)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final pColor = _platformColor(colors);
    return Semantics(
      label: '${game.name}, ${game.platformName}',
      button: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: isSelected
              ? Border.all(color: colors.accent, width: 2)
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              decoration: BoxDecoration(
                color: TvDetector.isTV ? colors.surface : null,
                gradient: TvDetector.isTV
                    ? null
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [colors.surface, colors.surface.withAlpha(204)],
                      ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: TvDetector.isTV
                    ? null
                    : [
                        BoxShadow(
                          color: pColor.withAlpha(26),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: TvDetector.isTV ? pColor.withAlpha(51) : null,
                        gradient: TvDetector.isTV
                            ? null
                            : LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  pColor.withAlpha(77),
                                  pColor.withAlpha(26),
                                ],
                              ),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                      ),
                      child: Stack(
                        children: [
                          if (game.coverPath != null)
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(16),
                                ),
                                child: Image(
                                  image: TvDetector.isTV
                                      ? ResizeImage(
                                          FileImage(File(game.coverPath!)),
                                          width: 280,
                                        )
                                      : FileImage(File(game.coverPath!)),
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  frameBuilder:
                                      (
                                        context,
                                        child,
                                        frame,
                                        wasSynchronouslyLoaded,
                                      ) {
                                        if (wasSynchronouslyLoaded ||
                                            frame != null) {
                                          return child;
                                        }
                                        return AnimatedOpacity(
                                          opacity: frame == null ? 0.0 : 1.0,
                                          duration: const Duration(
                                            milliseconds: 300,
                                          ),
                                          curve: Curves.easeOut,
                                          child: child,
                                        );
                                      },
                                  errorBuilder: (context, error, stackTrace) =>
                                      _buildPlaceholder(colors),
                                ),
                              ),
                            )
                          else
                            _buildPlaceholder(colors),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: pColor,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                game.platformShortName,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: colors.backgroundDark,
                                ),
                              ),
                            ),
                          ),
                          if (game.isFavorite)
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Icon(
                                Icons.favorite,
                                size: 20,
                                color: colors.accentAlt,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 12,
                      top: 8,
                      bottom: 8,
                      right: 4,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                game.name,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: colors.textPrimary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),

                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      game.formattedSize,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: colors.textMuted,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (game.totalPlayTimeSeconds > 0) ...[
                                    Text(
                                      '  •  ',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: colors.textMuted,
                                      ),
                                    ),
                                    Icon(
                                      Icons.timer_outlined,
                                      size: 11,
                                      color: colors.textMuted,
                                    ),
                                    const SizedBox(width: 2),
                                    Flexible(
                                      child: Text(
                                        game.formattedPlayTime,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: colors.textMuted,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (onLongPress != null && !TvDetector.isTV)
                          GestureDetector(
                            onTap: onLongPress,
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 4,
                              ),
                              child: Icon(
                                Icons.more_vert,
                                size: 18,
                                color: colors.textMuted.withAlpha(140),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GridPatternPainter extends CustomPainter {
  final Paint _paint;

  _GridPatternPainter({required Color color})
    : _paint = Paint()
        ..color = color
        ..strokeWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 20.0;

    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), _paint);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), _paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class GameListTile extends StatelessWidget {
  final GameRom game;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const GameListTile({
    super.key,
    required this.game,
    required this.onTap,
    this.onLongPress,
  });

  Color _platformColor(AppColorTheme colors) => switch (game.platform) {
    GamePlatform.gb => colors.gbColor,
    GamePlatform.gbc => colors.gbcColor,
    GamePlatform.gba => colors.gbaColor,
    GamePlatform.nes => colors.nesColor,
    GamePlatform.snes => colors.snesColor,
    GamePlatform.sms => colors.smsColor,
    GamePlatform.gg => colors.ggColor,
    GamePlatform.md => colors.mdColor,
    GamePlatform.pce => colors.mdColor,
    GamePlatform.sgx => colors.mdColor,
    GamePlatform.n64 => colors.mdColor,
    GamePlatform.sg1000 => colors.smsColor,
    GamePlatform.ngp => colors.ngpColor,
    GamePlatform.ws => colors.wsColor,
    GamePlatform.wsc => colors.wscColor,
    GamePlatform.unknown => colors.textMuted,
  };

  Widget _buildLeading(AppColorTheme colors) {
    if (game.coverPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image(
          image: TvDetector.isTV
              ? ResizeImage(
                  FileImage(File(game.coverPath!)),
                  width: 56,
                  height: 56,
                )
              : FileImage(File(game.coverPath!)),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) =>
              _buildPlatformBadge(colors),
        ),
      );
    }
    return _buildPlatformBadge(colors);
  }

  Widget _buildPlatformBadge(AppColorTheme colors) {
    final pColor = _platformColor(colors);
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: pColor.withAlpha(51),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: pColor.withAlpha(128), width: 1),
      ),
      child: Center(
        child: Text(
          game.platformShortName,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: pColor,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Semantics(
      label: '${game.name}, ${game.platformName}',
      button: true,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: _buildLeading(colors),
        title: Text(
          game.name,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          game.totalPlayTimeSeconds > 0
              ? '${game.platformName} • ${game.formattedSize} • ${game.formattedPlayTime}'
              : '${game.platformName} • ${game.formattedSize}',
          style: TextStyle(fontSize: 12, color: colors.textMuted),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (game.isFavorite)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.favorite, size: 18, color: colors.accentAlt),
              ),
            if (onLongPress != null && !TvDetector.isTV)
              GestureDetector(
                onTap: onLongPress,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.more_vert,
                    size: 20,
                    color: colors.textMuted,
                  ),
                ),
              )
            else if (onLongPress == null)
              Icon(Icons.chevron_right, color: colors.textMuted),
          ],
        ),
      ),
    );
  }
}
