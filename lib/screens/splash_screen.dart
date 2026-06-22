import 'dart:async';

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
import '../services/retro_achievements_service.dart';
import '../services/settings_service.dart';
import '../services/tv_http_server.dart';
import '../utils/device_memory.dart';
import '../utils/theme.dart';
import '../utils/tv_detector.dart';
import 'home_screen.dart';

/// Splash screen shown at app startup.
///
/// Responsibilities:
///   1. Display branding (logo + app name) immediately on first frame.
///   2. Run all heavy initialisation tasks AFTER the first frame renders
///      to avoid ANR on slow devices (especially Android TV):
///      • Firebase
///      • Game database (SQLite)
///      • TV detection
///      • Device memory detection
///      • AdMob (mobile only — skipped on TV)
///   3. Build the full app with providers only after init completes.
///   4. Navigate to [HomeScreen] once providers are ready.
///
/// A minimum display time of 1.5 s ensures the logo is seen even when
/// everything loads instantly (cached data on subsequent launches).
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

    // Fade-in animation for the logo / text
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();

    // Kick off async init after the first frame to avoid ANR
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    final stopwatch = Stopwatch()..start();

    try {
      // ── Required-before-first-frame init (all fast / local) ──────
      // Everything in this group must complete before we navigate to
      // HomeScreen because the home UI depends on the results:
      //   • Firebase (Crashlytics hook-up) — capped at 4 s so a slow
      //     network never blocks the app from starting.
      //   • GameDatabase — home lists games from SQLite.
      //   • TvDetector — theme and UI scaling.
      //   • initDeviceMemory — used by home / settings.
      //   • RemoveAdsPurchaseService.loadCachedEntitlementOnly — pure
      //     SharedPreferences read; decides whether to show banner ads.
      //   • AdService.ensureUnlockStatesLoaded — local prefs; cheats /
      //     slot-unlock UI reads these.
      await Future.wait([
        _initFirebase().timeout(
          const Duration(seconds: 4),
          onTimeout: () {
            debugPrint(
              'SplashScreen: Firebase init timed out — continuing '
              'without it (no analytics this session)',
            );
          },
        ),
        TvDetector.initialize(),
        initDeviceMemory(),
      ]);

      await _initDatabase(migrateLegacyData: !TvDetector.isTV);

      if (!TvDetector.isTV) {
        await Future.wait([
          RemoveAdsPurchaseService.instance.loadCachedEntitlementOnly(),
          AdService.instance.ensureUnlockStatesLoaded(),
        ]);
      }

      // ── Deferred init (networked; runs AFTER navigation) ─────────
      // These used to block the splash on cold starts with slow Wi-Fi:
      //   • UMP consent round-trip (even for non-EEA users)
      //   • MobileAds.initialize() — mediation adapter handshakes
      //   • IAP Play-Billing: isAvailable / queryProductDetails /
      //     restorePurchases
      // They're fire-and-forget; services update their own state and
      // notify listeners when ready, so any UI depending on them will
      // rebuild the moment the network call returns.
      unawaited(_deferredNetworkInit());

      // ── Enforce minimum display time for branding ────────
      // TV users prioritize startup speed over branding impression.
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

  /// Best-effort initialization of networked services.
  ///
  /// Runs outside the splash critical path. Each step is guarded so a
  /// timeout or failure in one doesn't block the others, and none of them
  /// can ever re-throw into the splash flow.
  Future<void> _deferredNetworkInit() async {
    // Give the UI a frame to paint HomeScreen before we kick off ads /
    // consent — this is the whole point of running off the splash path.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    if (TvDetector.isTV) return;

    final iap = RemoveAdsPurchaseService.instance;
    unawaited(
      iap.initializeStoreInBackground().catchError((Object e) {
        debugPrint('SplashScreen: deferred IAP init failed — $e');
      }),
    );

    // If the user has already paid to remove ads (cached locally), skip
    // the UMP / AdMob round-trips entirely.
    if (iap.adsRemoved || TvDetector.isTV) return;

    unawaited(
      AdService.instance
          .initializeWithConsent(ConsentService.instance)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              debugPrint(
                'SplashScreen: deferred AdMob/UMP init timed out — '
                'ads will retry on next launch',
              );
            },
          )
          .catchError((Object e) {
            debugPrint('SplashScreen: deferred AdMob init failed — $e');
          }),
    );
  }

  Future<void> _initFirebase() async {
    try {
      await Firebase.initializeApp();

      if (!kDebugMode) {
        FlutterError.onError = (FlutterErrorDetails details) {
          // Downgrade network errors from image loading to non-fatal.
          // SocketException during image fetch (e.g. RetroAchievements badges)
          // should not be recorded as a fatal crash.
          final exception = details.exception;
          final isImageNetworkError =
              details.stack.toString().contains('ImageStreamCompleter') ||
              details.library == 'image resource service';
          final isSocketError =
              exception.toString().contains('SocketException') ||
              exception.toString().contains('Connection reset') ||
              exception.toString().contains('Connection refused') ||
              exception.toString().contains('connection abort') ||
              exception.toString().contains('HttpException') ||
              exception.toString().contains('HandshakeException');

          if (isImageNetworkError || isSocketError) {
            // Record as non-fatal so we still see it in dashboard
            FirebaseCrashlytics.instance.recordError(
              details.exception,
              details.stack,
              reason: details.library ?? 'network error',
              fatal: false,
            );
          } else {
            FirebaseCrashlytics.instance.recordFlutterFatalError(details);
          }
        };
        PlatformDispatcher.instance.onError = (error, stack) {
          // Downgrade network errors to non-fatal at platform level too
          final desc = error.toString();
          final isNetworkError =
              desc.contains('SocketException') ||
              desc.contains('Connection reset') ||
              desc.contains('Connection refused') ||
              desc.contains('connection abort') ||
              desc.contains('HttpException') ||
              desc.contains('HandshakeException');
          FirebaseCrashlytics.instance.recordError(
            error,
            stack,
            fatal: !isNetworkError,
          );
          return true;
        };
      }
    } catch (e) {
      debugPrint('Firebase init failed — running without analytics: $e');
      // Non-fatal: continue without Firebase
    }
  }

  Future<void> _initDatabase({bool migrateLegacyData = true}) async {
    final db = GameDatabase();
    await db.open(migrateLegacyData: migrateLegacyData);
    _gameDatabase = db;
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  // ═════════════════════════════════════════════════════════════════════
  //  UI
  // ═════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    // Once initialized, wrap in providers and navigate to home
    if (_initialized && _gameDatabase != null) {
      return _buildFullApp();
    }

    // Show error state if init failed
    if (_errorMessage != null) {
      return _buildErrorScreen();
    }

    // Show splash while loading
    return _buildSplashUI();
  }

  /// Build the full app with all providers after initialization.
  Widget _buildFullApp() {
    return AppProviders(
      gameDatabase: _gameDatabase!,
      deferStartupLoads: TvDetector.isTV,
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
              // ── Glowing app icon ─────────────────────────────────
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

              // ── App name ─────────────────────────────────────────
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

              // ── Tagline ──────────────────────────────────────────
              Text(
                'Emulator to play Retro Games',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textMuted,
                  letterSpacing: 1.5,
                ),
              ),

              const SizedBox(height: 48),

              // ── Subtle loading indicator ─────────────────────────
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

/// The fully themed app widget, shown after initialization.
///
/// Listens to [SettingsService] for theme changes and applies system UI
/// colors accordingly. Also maps TV remote buttons to activation intents.
///
/// **Nested [MaterialApp]**: The bootstrap [MaterialApp] in [RetroPalAppBootstrap]
/// keeps [SplashScreen]; once init completes, this widget builds a **second**
/// [MaterialApp] for the real UI. On Android TV, running without this inner
/// [MaterialApp] has been observed to get the process killed by the system—so
/// the nesting is intentional, not an oversight.
///
/// **Navigator**: Two apps means two [Navigator]s. [showDialog] defaults to
/// `useRootNavigator: true` and would attach to the **outer** navigator while
/// [HomeScreen] lives under the **inner** one—mismatched [Navigator.pop] can
/// remove the home route (black screen). App dialogs that sit above
/// [HomeScreen] must use `useRootNavigator: false` (and matching pops).
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

    // Stop HTTP server when app exits or goes to background
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

        // Update system nav bar color to match theme
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarColor: colors.backgroundDark,
            systemNavigationBarIconBrightness: Brightness.light,
          ),
        );

        // Map typical Android TV remote and gamepad "Select" buttons to
        // standard activation. This makes all standard Flutter buttons
        // clickable via D-Pad Center or Gamepad A.
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
          // Inner MaterialApp: required for stable TV launches (see [_ThemedApp] doc).
          child: MaterialApp(
            title: 'RetroPal',
            debugShowCheckedModeBanner: false,
            theme: YageTheme.darkTheme(colors),
            builder: TvDetector.isTV
                ? (context, child) {
                    // 10-foot UI: scale all text ~1.3x for TV viewing distance
                    // and add overscan-safe padding (many TVs crop 3-5% edges).
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

/// Splash placeholder shown briefly while providers finish loading.
///
/// Once [SettingsService.whenLoaded] completes, this widget navigates to
/// [HomeScreen] via [Navigator.pushReplacement]. This avoids the fragile
/// pattern of swapping [MaterialApp.home] — which does not reliably
/// replace the displayed route in Navigator 1.0's route stack.
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
    // Gate the first HomeScreen frame on two things:
    //   1. SettingsService loaded — so the full theme is applied.
    //   2. RetroAchievements login state restored — so a returning, logged-in
    //      user sees achievement-gated UI (and game launches that enable
    //      achievements) correctly on the very first frame, instead of after a
    //      late rebuild. We await `whenLocallyReady`, which resolves as soon as
    //      the stored session is read and does NOT wait for the network
    //      profile refresh.
    //
    // Both are wrapped in a hard timeout and a try/catch so a slow/offline
    // device — or a missing provider — can never strand the user on the
    // splash. If the gate is released early we navigate anyway; the services
    // are ChangeNotifiers, so the home UI still updates reactively once they
    // settle.
    if (!TvDetector.isTV) {
      try {
        final settings = context.read<SettingsService>();
        final raService = context.read<RetroAchievementsService>();
        await Future.wait(<Future<void>>[
          settings.whenLoaded,
          raService.whenLocallyReady,
        ]).timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint(
          'SplashScreen: startup gate released early ($e) — continuing',
        );
      }
    }

    if (!mounted || _navigated) return;
    _navigated = true;

    // pushReplacement on the INNER navigator — this context is inside the
    // inner MaterialApp, so Navigator.of(context) finds the right one.
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => const HomeScreen(),
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
