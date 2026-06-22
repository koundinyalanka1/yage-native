import 'package:flutter/material.dart';

import '../data/whats_new.dart';
import '../utils/theme.dart';

/// Shows the What's New dialog for [entry]. Styled to match the app's other
/// dialogs (surface background, rounded accent border, single primary action).
Future<void> showWhatsNewDialog(BuildContext context, WhatsNewEntry entry) {
  return showDialog<void>(
    context: context,
    // Match the rest of the app: dialogs use the nested navigator created by
    // the in-app MaterialApp, not the root one.
    useRootNavigator: false,
    barrierDismissible: true,
    builder: (context) => WhatsNewDialog(entry: entry),
  );
}

class WhatsNewDialog extends StatelessWidget {
  final WhatsNewEntry entry;

  const WhatsNewDialog({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final size = MediaQuery.of(context).size;

    final highlights =
        entry.highlights.where((h) => h.trim().isNotEmpty).toList();
    final hasIntro = entry.intro != null && entry.intro!.trim().isNotEmpty;
    final hasFooter = entry.footer != null && entry.footer!.trim().isNotEmpty;

    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.accent.withAlpha(90), width: 2),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      title: Row(
        children: [
          Icon(Icons.auto_awesome_rounded, color: colors.accent, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.title,
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: size.height * 0.55,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasIntro) ...[
                Text(
                  entry.intro!.trim(),
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
                if (highlights.isNotEmpty || hasFooter)
                  const SizedBox(height: 14),
              ],
              for (final h in highlights)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 6, right: 11),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: colors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          h.trim(),
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 14,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (hasFooter) ...[
                if (highlights.isNotEmpty) const SizedBox(height: 4),
                Text(
                  entry.footer!.trim(),
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      actions: [
        // Softer "tonal" action button. A solid neon-accent fill with white
        // text read as too bright, so the accent is now reserved for the text
        // and border over a translucent fill. The fill and border brighten on
        // focus/hover/press so the selection stays obvious for D-pad / TV
        // remote navigation (and the dialog is freely dismissable with Back).
        FilledButton(
          autofocus: true,
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              final active = states.contains(WidgetState.focused) ||
                  states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.pressed);
              return colors.accent.withAlpha(active ? 64 : 28);
            }),
            foregroundColor: WidgetStateProperty.all(colors.accent),
            overlayColor:
                WidgetStateProperty.all(colors.accent.withAlpha(30)),
            shape: WidgetStateProperty.resolveWith((states) {
              final active = states.contains(WidgetState.focused) ||
                  states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.pressed);
              return RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: colors.accent.withAlpha(active ? 200 : 110),
                  width: 1.5,
                ),
              );
            }),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            child: Text(
              'Got it',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}
