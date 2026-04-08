import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mgba_bindings.dart';
import '../models/cheat.dart';
import '../models/game_rom.dart';

import '../services/cheat_session.dart';
import '../utils/tv_detector.dart';
import '../utils/theme.dart';
import '../widgets/tv_focusable.dart';

class CheatScreen extends StatefulWidget {
  final GameRom game;
  final CheatSession session;

  const CheatScreen({super.key, required this.game, required this.session});

  @override
  State<CheatScreen> createState() => _CheatScreenState();
}

class _CheatScreenState extends State<CheatScreen> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  void _goBack() => Navigator.of(context).pop();

  CheatType _defaultCheatType() => switch (widget.game.platform) {
    GamePlatform.gba => CheatType.gameShark,
    GamePlatform.gb || GamePlatform.gbc => CheatType.gameShark,
    GamePlatform.nes => CheatType.gameGenie,
    GamePlatform.snes => CheatType.proActionReplay,
    GamePlatform.md => CheatType.gameGenie,
    GamePlatform.sg1000 => CheatType.raw,
    GamePlatform.sms || GamePlatform.gg => CheatType.gameGenie,
    _ => CheatType.raw,
  };

  String _cheatCodeHint() => switch (widget.game.platform) {
    GamePlatform.gba => 'e.g. 83005E18 270F',
    GamePlatform.gb || GamePlatform.gbc => 'e.g. 01FF16D0',
    GamePlatform.nes => 'e.g. SXIOPO',
    GamePlatform.snes => 'e.g. 7E0DBE:63',
    GamePlatform.md => 'e.g. RFKA-A6WR',
    GamePlatform.sg1000 => 'Enter cheat code',
    GamePlatform.sms || GamePlatform.gg => 'e.g. 00C-28B-E66',
    _ => 'Enter cheat code',
  };

  void _showAddCheatDialog() {
    final colors = AppColorTheme.of(context);
    final titleController = TextEditingController();
    final codeController = TextEditingController();
    var selectedType = _defaultCheatType();
    final titleFocus = FocusNode();
    final codeFocus = FocusNode();

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (ctx) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (titleFocus.canRequestFocus) titleFocus.requestFocus();
        });

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final maxDialogWidth = MediaQuery.of(ctx).size.width * 0.9;
            return Focus(
              canRequestFocus: false,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    (event.logicalKey == LogicalKeyboardKey.escape ||
                        event.logicalKey == LogicalKeyboardKey.goBack ||
                        event.logicalKey == LogicalKeyboardKey.gameButtonB ||
                        event.logicalKey == LogicalKeyboardKey.browserBack)) {
                  Navigator.of(ctx).pop();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: AlertDialog(
                backgroundColor: colors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: colors.accent.withAlpha(80),
                    width: 2,
                  ),
                ),
                title: Row(
                  children: [
                    Icon(
                      Icons.add_circle_outline,
                      color: colors.accent,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        'Add Cheat Code',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: maxDialogWidth < 400 ? maxDialogWidth : 400,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: titleController,
                          focusNode: titleFocus,
                          autofocus: true,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: 'Name',
                            hintText: 'e.g. Infinite Lives',
                            border: const OutlineInputBorder(),
                            labelStyle: TextStyle(color: colors.textSecondary),
                          ),
                          style: TextStyle(color: colors.textPrimary),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: codeController,
                          focusNode: codeFocus,
                          textInputAction: TextInputAction.done,
                          decoration: InputDecoration(
                            labelText: 'Code',
                            hintText: _cheatCodeHint(),
                            border: const OutlineInputBorder(),
                            labelStyle: TextStyle(color: colors.textSecondary),
                          ),
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontFamily: 'monospace',
                          ),
                          onSubmitted: (_) {
                            _submitCheat(
                              ctx,
                              titleController,
                              codeController,
                              selectedType,
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Code Format',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: CheatType.values.map((type) {
                            final isSelected = type == selectedType;
                            return TvFocusable(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () =>
                                  setDialogState(() => selectedType = type),
                              child: ChoiceChip(
                                label: Text(
                                  type.label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isSelected
                                        ? colors.backgroundDark
                                        : colors.textSecondary,
                                  ),
                                ),
                                selected: isSelected,
                                selectedColor: colors.accent,
                                backgroundColor: colors.backgroundLight,
                                onSelected: TvDetector.isTV
                                    ? null 
                                    : (_) => setDialogState(
                                        () => selectedType = type,
                                      ),
                                side: BorderSide.none,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        if (TvDetector.isTV) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Use D-pad to navigate, Select to open keyboard',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.textMuted,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                actions: [
                  TvFocusable(
                    onTap: () => Navigator.of(ctx).pop(),
                    borderRadius: BorderRadius.circular(8),
                    subtleFocus: true,
                    child: TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text(
                        'Cancel',
                        style: TextStyle(color: colors.textMuted),
                      ),
                    ),
                  ),
                  TvFocusable(
                    onTap: () => _submitCheat(
                      ctx,
                      titleController,
                      codeController,
                      selectedType,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    child: FilledButton.icon(
                      onPressed: () => _submitCheat(
                        ctx,
                        titleController,
                        codeController,
                        selectedType,
                      ),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) {
      titleController.dispose();
      codeController.dispose();
      titleFocus.dispose();
      codeFocus.dispose();
    });
  }

  void _submitCheat(
    BuildContext ctx,
    TextEditingController titleCtrl,
    TextEditingController codeCtrl,
    CheatType type,
  ) {
    final code = codeCtrl.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Please enter a cheat code')),
        );
      return;
    }

    final title = titleCtrl.text.trim().isEmpty
        ? 'Cheat ${widget.session.cheats.length + 1}'
        : titleCtrl.text.trim();
    widget.session.addCheat(
      system: widget.game.platform,
      title: title,
      cheatCode: code,
      cheatType: type,
    );

    Navigator.of(ctx).pop();
  }

  void _onCheatTap(Cheat cheat) async {
    final ok = await widget.session.toggleCheat(cheat.id);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Failed to activate "${cheat.title}" — '
              'this core may not support cheats or the code format is invalid.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
    }
  }

  void _confirmRemoveCheat(Cheat cheat) {
    final colors = AppColorTheme.of(context);
    showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Remove Cheat?',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          'Remove "${cheat.title}"?',
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TvFocusable(
            autofocus: true,
            onTap: () => Navigator.of(ctx).pop(false),
            borderRadius: BorderRadius.circular(8),
            subtleFocus: true,
            child: TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Cancel', style: TextStyle(color: colors.textMuted)),
            ),
          ),
          TvFocusable(
            onTap: () => Navigator.of(ctx).pop(true),
            borderRadius: BorderRadius.circular(8),
            child: TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(
                backgroundColor: colors.error.withAlpha(30),
              ),
              child: Text('Remove', style: TextStyle(color: colors.error)),
            ),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) {
        widget.session.removeCheat(cheat.id); 
      }
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final scope = FocusScope.of(context);
            if (!scope.hasFocus) scope.nextFocus();
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final cheats = widget.session.cheats;
    final isTV = TvDetector.isTV;

    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.goBack ||
            event.logicalKey == LogicalKeyboardKey.browserBack ||
            event.logicalKey == LogicalKeyboardKey.gameButtonB) {
          _goBack();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: colors.backgroundDark,
        body: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(colors, isTV: isTV, emptyList: cheats.isEmpty),
                Expanded(
                  child: cheats.isEmpty
                      ? _buildEmptyState(colors)
                      : _buildCheatList(colors, cheats),
                ),
                _buildFooter(colors),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    AppColorTheme colors, {
    required bool isTV,
    required bool emptyList,
  }) {
    final addButtonAutofocus = emptyList;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          bottom: BorderSide(color: colors.surfaceLight, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          TvFocusable(
            borderRadius: BorderRadius.circular(8),
            onTap: _goBack,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.backgroundLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.arrow_back,
                color: colors.textSecondary,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cheat Codes',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${widget.game.platformShortName} · ${widget.game.name}',
                  style: TextStyle(fontSize: 13, color: colors.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TvFocusable(
            borderRadius: BorderRadius.circular(12),
            autofocus: addButtonAutofocus,
            onTap: _showAddCheatDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, color: colors.backgroundDark, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    'Add Code',
                    style: TextStyle(
                      color: colors.backgroundDark,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(AppColorTheme colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.code, size: 64, color: colors.textMuted.withAlpha(80)),
            const SizedBox(height: 20),
            Text(
              'No Cheat Codes',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap "Add Code" to enter your own cheat codes.\n'
              'Cheats are saved and will be restored next time you play.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colors.textMuted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCheatList(AppColorTheme colors, List<Cheat> cheats) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: TvScrollAccelerator(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: cheats.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final cheat = cheats[index];
            return _CheatRow(
              cheat: cheat,
              autofocus: index == 0, 
              onTap: () => _onCheatTap(cheat),
              onLongPress: () => _confirmRemoveCheat(cheat),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFooter(AppColorTheme colors) {
    if (!TvDetector.isTV) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: colors.backgroundDark,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _hintChip(colors, 'A', 'Toggle'),
          const SizedBox(width: 16),
          _hintChip(colors, 'Select', 'Remove'),
          const SizedBox(width: 16),
          _hintChip(colors, 'B', 'Back'),
        ],
      ),
    );
  }

  Widget _hintChip(AppColorTheme colors, String key, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colors.surfaceLight),
          ),
          child: Text(
            key,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              color: colors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: colors.textMuted)),
      ],
    );
  }
}

class _CheatRow extends StatelessWidget {
  final Cheat cheat;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _CheatRow({
    required this.cheat,
    required this.onTap,
    required this.onLongPress,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);

    final IconData statusIcon;
    final Color statusColor;
    final String statusLabel;

    if (cheat.isActive) {
      statusIcon = Icons.check_circle;
      statusColor = colors.success;
      statusLabel = 'Active';
    } else {
      statusIcon = Icons.toggle_off_outlined;
      statusColor = colors.accent;
      statusLabel = 'Tap to Enable';
    }

    return TvFocusable(
      borderRadius: BorderRadius.circular(12),
      autofocus: autofocus,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: cheat.isActive ? colors.success.withAlpha(20) : colors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cheat.isActive
                ? colors.success.withAlpha(80)
                : colors.surfaceLight,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cheat.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    cheat.cheatCode,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: colors.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    cheat.cheatType.label,
                    style: TextStyle(fontSize: 11, color: colors.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: statusColor.withAlpha(80)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(statusIcon, size: 16, color: statusColor),
                  const SizedBox(width: 6),
                  Text(
                    statusLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
