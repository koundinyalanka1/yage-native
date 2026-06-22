import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens an http(s) [uri] without delegating straight to a broken default app.
///
/// On Android, [LaunchMode.externalApplication] can resolve to a handler whose
/// activity is not exported (e.g. an in-app browser inside another app), which
/// throws [PlatformException] / `SecurityException`. Custom Tabs /
/// [LaunchMode.inAppBrowserView] stays in-process and avoids that path.
Future<void> safeLaunchHttpUrl(BuildContext context, Uri uri) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    debugPrint('safeLaunchHttpUrl: unsupported scheme ${uri.scheme}');
    return;
  }

  Future<bool> tryMode(LaunchMode mode) async {
    try {
      return await launchUrl(uri, mode: mode);
    } on PlatformException catch (e, st) {
      debugPrint('safeLaunchHttpUrl: $mode failed — $e\n$st');
      return false;
    }
  }

  if (await tryMode(LaunchMode.inAppBrowserView)) return;
  if (await tryMode(LaunchMode.platformDefault)) return;
  if (await tryMode(LaunchMode.externalApplication)) return;

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open link.\n$uri')),
    );
  }
}
