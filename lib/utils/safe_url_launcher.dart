import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

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
