import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_providers.dart';
import '../services/ad_service.dart';
import '../services/consent_service.dart';
import '../services/game_database.dart';
import '../services/remove_ads_purchase_service.dart';
import '../services/settings_service.dart';
import '../services/tv_http_server.dart';
import '../utils/device_memory.dart';
import '../utils/theme.dart';
import '../utils/tv_detector.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  bool _initialized = false;
  GameDatabase? _gameDatabase;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    final stopwatch = Stopwatch()..start();

    try {
      await Future.wait([
        _initFirebase(),
        _initDatabase(),
        TvDetector.initialize(),
        initDeviceMemory(),
      ]);

      await RemoveAdsPurchaseService.instance.initialize();
      if (!TvDetector.isTV && !RemoveAdsPurchaseService.instance.adsRemoved) {
        await AdService.instance.initializeWithConsent(ConsentService.instance);
      }
      await AdService.instance.ensureUnlockStatesLoaded();
      final elapsed = stopwatch.elapsedMilliseconds;
      final minDisplayMs = TvDetector.isTV ? 800 : 1500;
      if (elapsed < minDisplayMs) {
        await Future.delayed(Duration(milliseconds: minDisplayMs - elapsed));
      }

      if (!mounted) return;

      setState(() {
        _initialized = true;
      });
    } catch (e) {
      debugPrint('SplashScreen: initialization failed — $e');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to initialize: $e';
        });
      }
    }
  }

  Future<void> _initFirebase() async {
    try {
      await Firebase.initializeApp();

      if (!kDebugMode) {
        FlutterError.onError =
            FirebaseCrashlytics.instance.recordFlutterFatalError;
        PlatformDispatcher.instance.onError = (error, stack) {
          FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
          return true;
        };
      }
    } catch (e) {
      debugPrint('Firebase init failed — running without analytics: $e');
    }
  }

  Future<void> _initDatabase() async {
    final db = GameDatabase();
    await db.open();
    _gameDatabase = db;
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initialized && _gameDatabase != null) {
      return _buildFullApp();
    }
    if (_errorMessage != null) {
      return _buildErrorScreen();
    }
    return _buildSplashUI();
  }

  Widget _buildFullApp() {
    return AppProviders(
      gameDatabase: _gameDatabase!,
      child: _ThemedApp(fadeAnimation: _fadeAnimation),
    );
  }

  Widget _buildErrorScreen() {
    final colors = AppThemes.defaultTheme;
    return Scaffold(
      backgroundColor: colors.backgroundDark,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 64, color: colors.error),
              const SizedBox(height: 16),
              Text(
                'Initialization Failed',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                style: TextStyle(color: colors.textMuted),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSplashUI() {
    final colors = AppThemes.defaultTheme;
    return Scaffold(
      backgroundColor: colors.backgroundDark,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: colors.primary.withAlpha(120),
                      blurRadius: 40,
                      spreadRadius: 4,
                    ),
                    BoxShadow(
                      color: colors.accent.withAlpha(60),
                      blurRadius: 60,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Image.asset(
                    'assets/images/app_icon.png',
                    width: 120,
                    height: 120,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),

              const SizedBox(height: 28),
              Text(
                'RetroPal',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                  letterSpacing: 4,
                ),
              ),

              const SizedBox(height: 8),
              Text(
                'Emulator to play Retro Games',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textMuted,
                  letterSpacing: 1.5,
                ),
              ),

              const SizedBox(height: 48),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: colors.primary.withAlpha(180),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemedApp extends StatefulWidget {
  final Animation<double> fadeAnimation;

  const _ThemedApp({required this.fadeAnimation});

  @override
  State<_ThemedApp> createState() => _ThemedAppState();
}

class _ThemedAppState extends State<_ThemedApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onDetach: _shutdownHttpServer,
      onInactive: _shutdownHttpServer,
    );
  }

  void _shutdownHttpServer() {
    if (TvHttpServer.instance.isRunning) {
      TvHttpServer.instance.stop();
    }
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _shutdownHttpServer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsService>(
      builder: (context, settingsService, _) {
        final colors = AppThemes.getById(
          settingsService.settings.selectedTheme,
        );
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarColor: colors.backgroundDark,
            systemNavigationBarIconBrightness: Brightness.light,
          ),
        );
        return Shortcuts(
          shortcuts: <LogicalKeySet, Intent>{
            LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
            LogicalKeySet(LogicalKeyboardKey.gameButtonA):
                const ActivateIntent(),
            LogicalKeySet(LogicalKeyboardKey.gameButtonStart):
                const ActivateIntent(),
            LogicalKeySet(LogicalKeyboardKey.numpadEnter):
                const ActivateIntent(),
          },
          child: MaterialApp(
            title: 'RetroPal',
            debugShowCheckedModeBanner: false,
            theme: YageTheme.darkTheme(colors),
            builder: TvDetector.isTV
                ? (context, child) {
                    final mq = MediaQuery.of(context);
                    return MediaQuery(
                      data: mq.copyWith(
                        textScaler: const TextScaler.linear(1.3),
                        padding: mq.padding + const EdgeInsets.all(24),
                      ),
                      child: child ?? const SizedBox.shrink(),
                    );
                  }
                : null,
            home: _SplashPlaceholder(
              fadeAnimation: widget.fadeAnimation,
              colors: colors,
            ),
          ),
        );
      },
    );
  }
}

class _SplashPlaceholder extends StatefulWidget {
  final Animation<double> fadeAnimation;
  final AppColorTheme colors;

  const _SplashPlaceholder({required this.fadeAnimation, required this.colors});

  @override
  State<_SplashPlaceholder> createState() => _SplashPlaceholderState();
}

class _SplashPlaceholderState extends State<_SplashPlaceholder> {
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _waitAndNavigate());
  }

  Future<void> _waitAndNavigate() async {
    final settings = context.read<SettingsService>();
    await settings.whenLoaded;

    if (!mounted || _navigated) return;
    _navigated = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Scaffold(
      backgroundColor: colors.backgroundDark,
      body: Center(
        child: FadeTransition(
          opacity: widget.fadeAnimation,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: colors.primary.withAlpha(120),
                      blurRadius: 40,
                      spreadRadius: 4,
                    ),
                    BoxShadow(
                      color: colors.accent.withAlpha(60),
                      blurRadius: 60,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Image.asset(
                    'assets/images/app_icon.png',
                    width: 120,
                    height: 120,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'RetroPal',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Emulator to play Retro Games',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textMuted,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 48),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: colors.primary.withAlpha(180),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
