import 'package:shared_preferences/shared_preferences.dart';

import '../data/whats_new.dart';
import 'app_version_service.dart';

/// Decides whether the "What's New" dialog should appear, and remembers which
/// version the user has already seen it for.
///
/// Policy: the dialog is shown **once per version** for any version that has
/// notes in [kWhatsNewEntries]. The caller (Home screen) additionally only
/// surfaces it once the library contains ROMs — either they were already set
/// up, or the user has just added some — so a brand-new empty install does not
/// see release notes before it has any games. A version with no notes advances
/// the baseline silently (nothing is shown).
class WhatsNewService {
  static const String _lastShownVersionKey = 'whats_new_last_shown_version';

  /// The entry to display on this launch, or `null` if there's nothing to show.
  ///
  /// Does not mark anything as shown — call [markCurrentVersionShown] after the
  /// dialog is actually displayed and dismissed.
  static Future<WhatsNewEntry?> pendingEntry() async {
    final prefs = await SharedPreferences.getInstance();
    final current = await AppVersionService.marketingVersion();
    final lastShown = prefs.getString(_lastShownVersionKey);

    // Already seen the dialog for the installed version.
    if (lastShown == current) return null;

    final entry = whatsNewEntryForVersion(current);
    if (entry == null) {
      // No notes authored for this version: advance the baseline so we don't
      // keep re-checking, and show nothing.
      await prefs.setString(_lastShownVersionKey, current);
      return null;
    }
    return entry;
  }

  /// Records that the What's New dialog for the installed version has been seen
  /// so it won't appear again until the version changes.
  static Future<void> markCurrentVersionShown() async {
    final prefs = await SharedPreferences.getInstance();
    final current = await AppVersionService.marketingVersion();
    await prefs.setString(_lastShownVersionKey, current);
  }

  /// Clears the "seen" record so the dialog will appear again on next launch.
  /// Handy for manual testing.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastShownVersionKey);
  }
}
