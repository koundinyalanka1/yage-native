/// What's New content — EDIT THIS FILE to change the release notes shown to
/// users.
///
/// HOW IT WORKS
/// ───────────
/// The What's New dialog appears **once per version** for any version that has
/// an entry below — but only once the user's library contains ROMs (either
/// they were already set up, or the user has just added some). It is not shown
/// on an empty, freshly-installed library. Once a user has seen the dialog for
/// a given version, it never shows again for that version.
///
/// TO ADD NOTES FOR A NEW RELEASE
/// ──────────────────────────────
/// 1. Bump `version:` in pubspec.yaml (e.g. `24.1.0+25`).
/// 2. Add a new [WhatsNewEntry] to the TOP of [kWhatsNewEntries] whose
///    [WhatsNewEntry.version] EXACTLY matches the marketing version in
///    pubspec — that's the part BEFORE the `+` (e.g. `'24.1.0'`).
/// 3. Fill in `title`, `intro`, `highlights`, and/or `footer` with your text.
///
/// If a version has no entry here, no dialog is shown for it.
library;

/// One release's What's New content.
class WhatsNewEntry {
  /// Marketing version this entry is for. MUST match pubspec.yaml's `version`
  /// (the part before `+`). Example: `'24.1.0'`.
  final String version;

  /// Heading shown at the top of the dialog.
  final String title;

  /// Optional short paragraph shown above the bullet list. Use `null` to omit.
  final String? intro;

  /// Bullet-point highlights — each string becomes its own bullet.
  final List<String> highlights;

  /// Optional closing line shown below the bullets. Use `null` to omit.
  final String? footer;

  const WhatsNewEntry({
    required this.version,
    this.title = "What's New",
    this.intro,
    this.highlights = const [],
    this.footer,
  });

  /// True when there is at least something to render.
  bool get hasContent =>
      (intro != null && intro!.trim().isNotEmpty) ||
      highlights.any((h) => h.trim().isNotEmpty) ||
      (footer != null && footer!.trim().isNotEmpty);
}

/// EDIT ME. Newest version first. One entry per version you want a dialog for.
///
/// The example below is wired to the current pubspec version so you can see it
/// immediately — replace the text with your real notes.
const List<WhatsNewEntry> kWhatsNewEntries = [
  WhatsNewEntry(
    version: '24.0.0', // ← keep in sync with pubspec.yaml `version:`
    title: "What's New in 24.0.0",
    intro: 'Thanks for using the app! Here are the highlights of this release:',
    highlights: [
      'Added NDS, PS1, INTV, Atari 2600, TIC-80, PICO-8 support',
      'Enhanced Graphics',
      'Bug Fixes and performance improvements.',
    ],
    footer: null,
  ),
];

/// Returns the [WhatsNewEntry] for [version] (with content), or `null` if there
/// is no entry for that version.
WhatsNewEntry? whatsNewEntryForVersion(String version) {
  for (final entry in kWhatsNewEntries) {
    if (entry.version == version && entry.hasContent) return entry;
  }
  return null;
}
