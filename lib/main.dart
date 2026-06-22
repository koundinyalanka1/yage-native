import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'screens/splash_screen.dart';
import 'utils/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    // Older versions of in_app_purchase_android exposed this static call.
    // Newer versions removed it (pending purchases are always enabled), so we
    // invoke dynamically to support both APIs without crashing.
    final dynamic androidPlatformAddition =
        InAppPurchaseAndroidPlatformAddition;
    try {
      androidPlatformAddition.enablePendingPurchases();
    } catch (_) {
      // No-op on newer package versions.
    }
  }

  // ── SQLite FFI for desktop (Windows / Linux) ─────────────────────
  // This is synchronous and fast — safe to do before runApp.
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // ── System UI (safe to set before the first frame) ─────────────────
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0D0D1A), // default backgroundDark
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // ── IMPORTANT: Do NOT await heavy initialization here! ────────────
  // Firebase, database, TV detection, AdMob, etc. are all deferred to
  // the SplashScreen to avoid ANR on slow devices (especially Android TV).
  // The first frame must render quickly to get a focused window.

  runApp(const RetroPalAppBootstrap());
}

/// Minimal bootstrap widget that shows splash immediately.
///
/// Heavy initialization (Firebase, database, etc.) happens inside
/// [SplashScreen] after the first frame renders, avoiding ANR.
class RetroPalAppBootstrap extends StatelessWidget {
  const RetroPalAppBootstrap({super.key});

  @override
  Widget build(BuildContext context) {
    // Use a minimal theme for the bootstrap phase.
    // The full themed app is built inside SplashScreen after init.
    final colors = AppThemes.defaultTheme;

    return MaterialApp(
      title: 'RetroPal',
      debugShowCheckedModeBanner: false,
      theme: YageTheme.darkTheme(colors),
      home: const SplashScreen(),
    );
  }
}
