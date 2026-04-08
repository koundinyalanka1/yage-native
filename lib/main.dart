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
    final dynamic androidPlatformAddition =
        InAppPurchaseAndroidPlatformAddition;
    try {
      androidPlatformAddition.enablePendingPurchases();
    } catch (_) {
    }
  }
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
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
      systemNavigationBarColor: Color(0xFF0D0D1A), 
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const RetroPalAppBootstrap());
}

class RetroPalAppBootstrap extends StatelessWidget {
  const RetroPalAppBootstrap({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppThemes.defaultTheme;

    return MaterialApp(
      title: 'RetroPal',
      debugShowCheckedModeBanner: false,
      theme: YageTheme.darkTheme(colors),
      home: const SplashScreen(),
    );
  }
}
