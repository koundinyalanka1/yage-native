import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/mgba_bindings.dart';
import '../core/rcheevos_bindings.dart';
import '../models/emulator_settings.dart';
import '../models/game_rom.dart';
import '../models/gamepad_layout.dart';
import '../models/ra_achievement.dart';
import '../services/emulator_service.dart';
import '../services/game_database.dart';
import '../services/game_library_service.dart';
import '../services/link_cable_service.dart';
import '../services/ra_runtime_service.dart';
import '../services/rcheevos_client.dart';
import '../services/ad_service.dart';
import '../services/retro_achievements_service.dart';
import '../services/bios_service.dart';
import '../services/settings_service.dart';
import '../services/cheat_session.dart';
import '../services/gamepad_input.dart';
import '../utils/tv_detector.dart';
import '../widgets/game_display.dart';
import 'achievements_screen.dart';
import 'cheat_screen.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/virtual_gamepad.dart';
import '../utils/theme.dart';

/// Game playing screen - optimized for mobile
class GameScreen extends StatefulWidget {
  final GameRom game;

  const GameScreen({super.key, required this.game});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  bool _showControls = true;
  bool _showMenu = false;
  bool _isLandscape = false;
  bool _editingLayout = false;
  bool _ndsTouchActive = false;
  GamepadLayout? _tempLayout; // Temporary layout while editing

  /// True when controls were hidden automatically by gamepad detection
  /// (not by the user choosing "Hide Controls" in the menu).
  /// Used to auto-restore controls when the gamepad disconnects.
  bool _controllerAutoHidden = false;

  // Use a key to preserve GameDisplay state across orientation changes
  final _gameDisplayKey = GlobalKey();

  // External gamepad / keyboard input
  late final GamepadMapper _gamepadMapper = GamepadMapper(
    mapping: GamepadMapper.mappingForPlatform(widget.game.platform),
  );
  final FocusNode _focusNode = FocusNode();
  int _virtualKeys = 0;
  int _physicalKeys = 0;

  // ── Hotkey combo system ──
  // Hold Select, then press another button for shortcut actions.
  // Releasing Select without a combo sends a normal GBA Select tap.
  bool _hotkeyHeld = false;
  bool _hotkeyComboUsed = false;

  // ── RetroAchievements notification tracking ──
  bool _hasShownAchievementNotification = false;
  RAGameData? _lastGameData;
  OverlayEntry? _raToastEntry;
  String? _lastRequestedRcheevosHash;

  // ── Saved references for safe disposal ──
  // Provider lookups are unsafe in dispose(), so we capture these early
  // and reuse them everywhere instead of calling context.read<>().
  EmulatorService? _emulatorRef;
  LinkCableService? _linkCableRef;
  RetroAchievementsService? _raServiceRef;
  RARuntimeService? _raRuntimeRef;
  RcheevosClient? _rcheevosClientRef;
  StreamSubscription<RcEvent>? _rcheevosEventSub;
  SettingsService? _settingsServiceRef;
  GameLibraryService? _libraryRef;
  BiosService? _biosServiceRef;

  /// Cheat session — manages user-entered cheat codes for this game.
  late final CheatSession _cheatSession;

  /// Preloaded interstitial for exit. Shown when user confirms exit.
  InterstitialAd? _interstitialAd;

  /// Whether the 30-minute threshold was reached (for reset logic).
  bool _thirtyMinuteAdShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Start session tracking for ad timing
    AdService.instance.startSession();

    // On Android TV, hide virtual controls by default
    if (TvDetector.isTV) {
      _showControls = false;
    }

    // Keep screen awake while playing
    WakelockPlus.enable();

    // Hide system UI for immersive gaming
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // On TV, lock to landscape; on mobile allow all orientations
    if (TvDetector.isTV) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    // Start emulation, then show shortcuts help on first launch
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // If the screen was popped before the first frame (fast back-press,
      // launch error), the Element is defunct and context.read would throw.
      if (!mounted) return;
      // Capture provider references early so they are available in dispose()
      // where context.read() is unsafe (widget tree may already be torn down).
      _emulatorRef = context.read<EmulatorService>();
      _linkCableRef = context.read<LinkCableService>();
      _rcheevosClientRef = context.read<RcheevosClient>();
      _raRuntimeRef = context.read<RARuntimeService>();
      _libraryRef = context.read<GameLibraryService>();

      final emulator = _emulatorRef!;
      // Wire link cable service to emulator
      emulator.linkCable = _linkCableRef;
      // Wire native rcheevos client for per-frame achievement processing
      emulator.rcheevosClient = _rcheevosClientRef;

      // Start cheat session for this game (persisted via SQLite)
      final gameDb = context.read<GameDatabase>();
      _cheatSession = CheatSession(emulator, gameDb);
      _cheatSession.startSession(widget.game.path);

      // Capture SettingsService early — _maybeShowShortcutsHelp() and
      // _detectRetroAchievements() both read _settingsServiceRef!.
      _settingsServiceRef = context.read<SettingsService>();
      _settingsServiceRef!.addListener(_onSettingsChanged);
      // Apply initial settings immediately
      emulator.updateSettings(_settingsServiceRef!.settings);

      emulator.start();
      _syncKeys(); // Ensure keys are synced on load (clear stale state)
      _maybeShowShortcutsHelp();

      // Show BIOS/HLE mode toast for NDS games
      if (widget.game.platform == GamePlatform.nds) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!mounted) return;
          _showNdsBiosToast(usingHle: emulator.isHleMode);
        });
      }

      // Listen for BIOS file changes while mid-game (e.g. user adds/removes
      // BIOS files from Settings and returns without relaunching the game).
      _biosServiceRef = context.read<BiosService>();
      _biosServiceRef!.addListener(_onBiosChanged);

      // Capture RetroAchievements service early — _detectRetroAchievements()
      // reads _raServiceRef!.
      _raServiceRef = context.read<RetroAchievementsService>();
      _raServiceRef!.addListener(_onRetroAchievementsChanged);

      // Listen for native rcheevos events (achievement unlocks, etc.)
      _rcheevosEventSub = _rcheevosClientRef!.events.listen(_onRcheevosEvent);

      // Detect RetroAchievements game ID in the background.
      // This does NOT block gameplay — achievements are enabled async.
      _detectRetroAchievements();

      // Preload exit interstitial (mobile + TV, not during gameplay)
      if (AdService.instance.isAvailable) {
        _loadExitInterstitial();
      }
    });
  }

  void _loadExitInterstitial() {
    try {
      InterstitialAd.load(
        adUnitId: AdUnitIds.interstitial,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            _interstitialAd = ad;
            _interstitialAd!
                .fullScreenContentCallback = FullScreenContentCallback(
              onAdDismissedFullScreenContent: (ad) {
                ad.dispose();
                _interstitialAd = null;
                // Reset counters based on whether this was a 30-min forced ad
                if (_thirtyMinuteAdShown) {
                  AdService.instance.resetAll();
                } else {
                  AdService.instance.resetExitCount();
                }
                _exitGame();
              },
              onAdFailedToShowFullScreenContent: (ad, error) {
                debugPrint('InterstitialAd: failed to show — ${error.message}');
                ad.dispose();
                _interstitialAd = null;
                _exitGame();
              },
            );
          },
          onAdFailedToLoad: (error) {
            debugPrint('InterstitialAd: failed to load — ${error.message}');
          },
        ),
      );
    } catch (e) {
      // Don't crash if ad loading fails
      debugPrint('InterstitialAd: exception during load — $e');
    }
  }

  /// Exit with interstitial ad, using simplified logic:
  ///   - Under 30 mins cumulative play: show ad every 3rd exit.
  ///   - 30+ mins cumulative play: show ad immediately, reset all counters.
  void _onExitWithAd() {
    // End session to update cumulative time
    AdService.instance.endSession();

    // Check if we should show an ad
    if (_interstitialAd != null && AdService.instance.shouldShowExitAd()) {
      // Track if this is a 30-minute forced ad for reset logic
      _thirtyMinuteAdShown = AdService.instance.shouldShowTimeBasedAd();

      try {
        _interstitialAd!.show();
        _interstitialAd = null; // disposed in callback → calls _exitGame
        return;
      } catch (e) {
        // Don't crash if ad fails to show
        debugPrint('InterstitialAd: exception during show — $e');
        _interstitialAd?.dispose();
        _interstitialAd = null;
      }
    }

    _exitGame();
  }

  /// Shows the NDS BIOS/HLE status toast.  Extracted so both the initial
  /// launch toast and the live [_onBiosChanged] listener can reuse it.
  void _showNdsBiosToast({required bool usingHle}) {
    // On TV, HLE is not a valid state (gate blocks launch without BIOS).
    // Guard here so a hypothetical edge-case never shows a misleading toast.
    if (usingHle && TvDetector.isTV) return;
    if (usingHle) {
      _showRAToast(
        title: 'Using FreeBIOS (no BIOS files)',
        subtitle: 'A few games (e.g. Pokémon) may show a "communication '
            'error" when loading a save. Add real bios7/bios9/firmware in '
            'Settings → BIOS for full save compatibility.',
        icon: Icons.info_outline,
        accentColor: Colors.orange,
        duration: const Duration(seconds: 6),
      );
    } else {
      _showRAToast(
        title: 'BIOS files detected',
        subtitle: 'Using real NDS BIOS',
        icon: Icons.verified_outlined,
        accentColor: Colors.green,
        duration: const Duration(seconds: 3),
      );
    }
  }

  /// Called when [BiosService] notifies (e.g. user adds/removes BIOS files
  /// from Settings while the game screen is still on the stack).  Re-checks
  /// current BIOS availability and shows an updated toast for NDS games.
  void _onBiosChanged() {
    if (!mounted) return;
    if (widget.game.platform != GamePlatform.nds) return;
    _biosServiceRef!.hasUserRealBios(GamePlatform.nds).then((hasReal) {
      if (!mounted) return;
      _showNdsBiosToast(usingHle: !hasReal);
    });
  }

  /// Show a styled toast banner at the top of the screen with an optional
  /// image (e.g. game icon or badge) and description text.
  ///
  /// Automatically dismisses after [duration].  If another toast is already
  /// showing it is replaced immediately.
  void _showRAToast({
    required String title,
    String? subtitle,
    String? imageUrl,
    IconData icon = Icons.emoji_events,
    Color accentColor = Colors.amber,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    // Remove existing toast if any
    _raToastEntry?.remove();
    _raToastEntry = null;

    final overlay = Overlay.of(context);

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _RATopToast(
        title: title,
        subtitle: subtitle,
        imageUrl: imageUrl,
        icon: icon,
        accentColor: accentColor,
        onDismissed: () {
          entry.remove();
          if (_raToastEntry == entry) _raToastEntry = null;
        },
        duration: duration,
      ),
    );

    _raToastEntry = entry;
    overlay.insert(entry);
  }

  /// Called when SettingsService changes.  Pushes the new settings to the
  /// emulator service outside of build() so that any resulting
  /// notifyListeners() calls don't trigger an infinite rebuild loop.
  void _onSettingsChanged() {
    if (!mounted) return;
    _emulatorRef!.updateSettings(_settingsServiceRef!.settings);
  }

  /// Called when RetroAchievementsService state changes.
  /// Shows the "X / Y achievements" in-app toast when data finishes loading.
  void _onRetroAchievementsChanged() {
    if (!mounted) return;

    final raService = _raServiceRef!;
    final gameData = raService.gameData;
    final session = raService.activeSession;

    // Only show notification once per session, when data becomes available.
    // The gameData must belong to the ACTIVE session — during a session
    // switch the service may briefly still hold the previous game's data,
    // and showing it here was the "previous game's notification pops up in
    // the next game" bug.
    if (gameData != null &&
        gameData != _lastGameData &&
        session != null &&
        session.gameId > 0 &&
        gameData.gameId == session.gameId &&
        gameData.achievements.isNotEmpty &&
        !_hasShownAchievementNotification) {
      _lastGameData = gameData;
      _hasShownAchievementNotification = true;

      final earned = gameData.achievements.where((a) => a.isEarned).length;
      final total = gameData.achievements.length;
      final points = gameData.earnedPoints;
      final totalPts = gameData.totalPoints;

      _showRAToast(
        title: gameData.title,
        subtitle: '$earned/$total achievements · $points/$totalPts pts',
        imageUrl: gameData.imageIconUrl,
      );
    }
  }

  /// Handle events from the native rcheevos client.
  void _onRcheevosEvent(RcEvent event) {
    if (!mounted) return;
    final colors = AppColorTheme.of(context);

    switch (event.type) {
      case RcEventType.achievementTriggered:
        // Check if this achievement was already earned (re-achieved via encore)
        final isReachieved =
            _raServiceRef?.gameData?.achievements.any(
              (a) =>
                  a.id == event.achievementId &&
                  (a.isEarned || a.isEarnedHardcore),
            ) ??
            false;

        _showRAToast(
          title: event.achievementTitle,
          subtitle:
              '${event.achievementDescription}\n'
              '${event.achievementPoints} pts',
          imageUrl: event.achievementBadgeUrl.isNotEmpty
              ? event.achievementBadgeUrl
              : null,
          icon: isReachieved ? Icons.replay : Icons.emoji_events,
          accentColor: isReachieved
              ? Colors.teal
              : (_rcheevosClientRef?.isHardcoreEnabled ?? false)
              ? Colors.amber
              : colors.accent,
          duration: const Duration(seconds: 5),
        );

        // Immediately mark the achievement as earned in local state so the
        // achievements list reflects the unlock without waiting for the
        // next API refresh cycle.
        if (!isReachieved) {
          _raServiceRef?.markAchievementEarned(
            event.achievementId,
            hardcore: _rcheevosClientRef?.isHardcoreEnabled ?? false,
          );
        }
        break;

      case RcEventType.gameCompleted:
        _showRAToast(
          title: 'Mastered!',
          subtitle: 'All achievements unlocked! 🎉',
          icon: Icons.star,
          accentColor: Colors.amber,
          duration: const Duration(seconds: 8),
        );
        break;

      case RcEventType.gameLoadSuccess:
        // Update achievement count display — only if the Dart-side
        // RetroAchievementsService hasn't already shown the same toast.
        final client = _rcheevosClientRef;
        if (client != null && !_hasShownAchievementNotification) {
          final summary = client.getAchievementSummary();
          if (summary.total > 0) {
            _hasShownAchievementNotification = true;
            _showRAToast(
              title: client.gameTitle ?? 'Game Loaded',
              subtitle:
                  '${summary.unlocked}/${summary.total} achievements · '
                  '${summary.unlockedPoints}/${summary.totalPoints} pts',
              imageUrl: client.gameBadgeUrl,
            );
          }
        }
        break;

      case RcEventType.gameLoadFailed:
        debugPrint('RcheevosClient: Game load failed: ${event.errorMessage}');
        _lastRequestedRcheevosHash = null;
        break;

      case RcEventType.loginSuccess:
        debugPrint('RcheevosClient: Login successful');
        // Now load the game if we have a pending hash
        _onRcheevosLoginSuccess();
        break;

      case RcEventType.loginFailed:
        debugPrint('RcheevosClient: Login failed: ${event.errorMessage}');
        break;

      default:
        break;
    }
  }

  /// After native rcheevos login succeeds, load the game.
  void _onRcheevosLoginSuccess() {
    if (!mounted) return;
    final raService = _raServiceRef;
    if (raService == null) return;

    final session = raService.activeSession;
    // Only load the achievement set if the session belongs to THIS game —
    // never feed a stale session's hash to the native client.
    if (session != null &&
        session.romHash.isNotEmpty &&
        session.romPath == widget.game.path) {
      final client = _rcheevosClientRef;
      if (client == null || !client.isInitialized) return;

      final settings = _settingsServiceRef?.settings;
      if (settings != null) {
        client.setHardcoreEnabled(settings.raHardcoreMode);
      }
      client.setEncoreEnabled(true);

      if (_lastRequestedRcheevosHash == session.romHash) return;
      _lastRequestedRcheevosHash = session.romHash;
      client.beginLoadGame(session.romHash);
    }
  }

  @override
  void didUpdateWidget(covariant GameScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.platform != widget.game.platform) {
      _gamepadMapper.updateMapping(
        GamepadMapper.mappingForPlatform(widget.game.platform),
      );
    }
  }

  @override
  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
      // Remove RA listeners (using saved references — safe in dispose)
      _settingsServiceRef?.removeListener(_onSettingsChanged);
      _settingsServiceRef = null;
      _raServiceRef?.removeListener(_onRetroAchievementsChanged);
      _raServiceRef = null;
      _biosServiceRef?.removeListener(_onBiosChanged);
      _biosServiceRef = null;
      _rcheevosEventSub?.cancel();
      _rcheevosEventSub = null;
      // Remove any lingering RA toast.  Wrapped in try-catch because the
      // overlay entry may have been removed already by its own animation.
      try {
        _raToastEntry?.remove();
      } catch (e) {
        debugPrint('GameScreen: failed to remove RA toast overlay — $e');
      }
      _raToastEntry = null;
      _focusNode.dispose();

      // End cheat session (clears native cheats)
      _cheatSession.endSession();
      _cheatSession.dispose();

      // Disconnect link cable and clean up emulator references
      // Uses saved refs — context.read() is unsafe in dispose().
      _linkCableRef?.disconnect();
      _emulatorRef?.linkCable = null;
      _emulatorRef?.rcheevosClient = null;

      // Fully shut down the native rcheevos client so it re-initialises
      // cleanly when the user enters a game again.  Without this, the
      // singleton stays in _initialized=true / _gameLoaded=false limbo
      // and the next session never loads the game → no achievement events.
      _rcheevosClientRef?.shutdown(notify: false);
      _rcheevosClientRef = null;

      _emulatorRef = null;
      _linkCableRef = null;
      _raRuntimeRef = null;
      _libraryRef = null;

      _interstitialAd?.dispose();
      _interstitialAd = null;

      // Allow screen to sleep again
      WakelockPlus.disable();
    } finally {
      // System-level cleanup runs even if earlier dispose steps throw,
      // so orientation / system-UI changes never leak to other screens.
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || _emulatorRef == null) return;
    final emulator = _emulatorRef!;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Persist the battery save (SRAM) before the OS can reclaim the
      // backgrounded process. An in-game save only updates the core's
      // in-memory SRAM buffer; pause() alone never writes it to disk, so a
      // save made right before the app is swiped away / killed while in the
      // background would otherwise be lost (reload shows "New Game").
      //
      // pause() stops the native frame loop synchronously, so the subsequent
      // SRAM read in flushSramSync() does not race retro_run, and the flush
      // completes before this callback returns (durable even if the process
      // is killed moments later).
      emulator.pause();
      emulator.flushSramSync();
      _flushPlayTime();
    } else if (state == AppLifecycleState.resumed) {
      if (!_showMenu) {
        emulator.start();
      }
      // If controls were auto-hidden by gamepad detection, restore them on
      // resume — the gamepad may have been disconnected while the app was
      // backgrounded (e.g. Bluetooth turned off, controller powered down).
      // Reset detection so a reconnecting gamepad is noticed again.
      if (_controllerAutoHidden && !_showControls) {
        setState(() {
          _showControls = true;
          _controllerAutoHidden = false;
        });
        _gamepadMapper.resetDetection();
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('Touch controls restored'),
              duration: Duration(seconds: 2),
            ),
          );
      }
    }
  }

  void _toggleMenu() {
    final emulator = _emulatorRef!;

    setState(() {
      _showMenu = !_showMenu;
    });

    if (_showMenu) {
      _gamepadMapper.reset();
      _physicalKeys = 0;
      emulator.pause();
    } else {
      emulator.start();
      // Re-request focus for gamepad input
      _focusNode.requestFocus();
    }
  }

  /// Merge virtual and physical keys and push to emulator
  void _syncKeys() {
    int keys = _virtualKeys | _physicalKeys;
    if (kDebugMode && keys != 0) {
      debugPrint(
        'Input: _syncKeys keys=0x${keys.toRadixString(16)} (v=$_virtualKeys p=$_physicalKeys) core=${_emulatorRef?.core != null}',
      );
    }
    _emulatorRef?.setKeys(keys);
  }

  /// Called by VirtualGamepad when touch keys change
  void _onVirtualKeysChanged(int keys) {
    _virtualKeys = keys;
    _syncKeys();
  }

  /// Called by VirtualGamepad when analog stick changes
  void _onVirtualAnalogChanged(double x, double y) {
    _emulatorRef?.setAnalog(x, y);
  }

  /// Called by VirtualGamepad when right-stick analog helpers change.
  void _onVirtualRightAnalogChanged(double x, double y) {
    _emulatorRef?.setRightAnalog(x, y);
  }

  // ─────────────────────────────────────────────────────────────────────
  //  Key / gamepad input handling
  // ─────────────────────────────────────────────────────────────────────

  /// The gamepad button used as the hotkey modifier.  Hold this and press
  /// another button to trigger a shortcut.  If released without a combo,
  /// a normal GBA Select tap is sent so in-game Select still works.
  static const _hotkeyModifier = LogicalKeyboardKey.gameButtonSelect;

  /// Combo actions when [_hotkeyModifier] is held.
  static final _baseHotkeyActions = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.gameButtonStart: 'menu', // Select+Start → pause menu
    LogicalKeyboardKey.gameButtonA: 'quickSave', // Select+A     → quick save
    LogicalKeyboardKey.gameButtonB: 'quickLoad', // Select+B     → quick load
    LogicalKeyboardKey.gameButtonRight1:
        'fastForward', // Select+R1    -> fast forward
  };

  /// Back / Escape — opens menu during gameplay, closes it when shown.
  /// These are TV-remote / keyboard keys that never conflict with GBA.
  static final _backKeys = {
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.goBack,
  };

  /// Keyboard-only shortcuts (no gamepad conflict).
  static final _keyboardShortcuts = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.f1: 'menu',
    LogicalKeyboardKey.f5: 'quickSave',
    LogicalKeyboardKey.f9: 'quickLoad',
    LogicalKeyboardKey.tab: 'fastForward',
  };

  void _executeShortcutAction(String action) {
    switch (action) {
      case 'menu':
        _toggleMenu();
      case 'quickSave':
        _doQuickSave();
      case 'quickLoad':
        _doQuickLoad();
      case 'fastForward':
        final blocked = _raRuntimeRef!.checkAction('fastForward');
        if (blocked != null) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(blocked),
                duration: const Duration(seconds: 2),
              ),
            );
          return;
        }
        _emulatorRef!.toggleFastForward();
        break;
    }
  }

  /// When Select is released without triggering any combo, briefly send
  /// a GBA Select press so the button still works for in-game menus.
  void _simulateSelectTap() {
    _physicalKeys |= GBAKey.select;
    _syncKeys();
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) {
        _physicalKeys &= ~GBAKey.select;
        _syncKeys();
      }
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final settings = _settingsServiceRef!.settings;
    if (!settings.enableExternalGamepad) return KeyEventResult.ignored;

    // ── Hotkey modifier (Select button) ──────────────────────────────
    if (event.logicalKey == _hotkeyModifier) {
      if (event is KeyDownEvent) {
        _hotkeyHeld = true;
        _hotkeyComboUsed = false;
        return KeyEventResult.handled; // suppress GBA Select
      }
      if (event is KeyUpEvent) {
        _hotkeyHeld = false;
        if (!_hotkeyComboUsed && !_showMenu && !_editingLayout) {
          // No combo was triggered — treat as a normal GBA Select tap
          _simulateSelectTap();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled; // suppress repeats
    }

    // ── Hotkey combos: Select + button ───────────────────────────────
    if (_hotkeyHeld && event is KeyDownEvent) {
      final action = _baseHotkeyActions[event.logicalKey];
      if (action != null) {
        _hotkeyComboUsed = true;
        _executeShortcutAction(action);
        return KeyEventResult.handled;
      }
    }

    // ── Back / Escape: open menu during gameplay, close it when shown ─
    if (event is KeyDownEvent && _backKeys.contains(event.logicalKey)) {
      if (_showMenu) {
        _toggleMenu();
        return KeyEventResult.handled;
      } else if (_editingLayout) {
        _cancelEditLayout();
        return KeyEventResult.handled;
      } else {
        _toggleMenu();
        return KeyEventResult.handled;
      }
    }

    // ── While the pause menu is shown, let it handle its own D-pad ───
    if (_showMenu || _editingLayout) return KeyEventResult.ignored;

    // ── Keyboard-only shortcuts (F1, F5, F9, Tab) ────────────────────
    if (event is KeyDownEvent) {
      final action = _keyboardShortcuts[event.logicalKey];
      if (action != null) {
        _executeShortcutAction(action);
        return KeyEventResult.handled;
      }
    }

    // ── Pass remaining keys to the GBA gamepad mapper ────────────────
    final wasDetected = _gamepadMapper.controllerDetected;
    final handled = _gamepadMapper.handleKeyEvent(event);
    if (handled) {
      _physicalKeys = _gamepadMapper.keys;
      _syncKeys();

      // Auto-hide virtual gamepad the first time a real controller is detected
      if (!wasDetected && _gamepadMapper.controllerDetected && _showControls) {
        setState(() {
          _showControls = false;
          _controllerAutoHidden = true;
        });
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'Controller detected — touch controls hidden. Tap screen to restore.',
              ),
              duration: Duration(seconds: 3),
            ),
          );
      }

      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Detect RetroAchievements game ID for the loaded ROM,
  /// then activate the RA runtime for per-frame achievement processing.
  ///
  /// Skipped entirely when RetroAchievements is disabled in settings.
  /// Runs asynchronously in the background so gameplay is never blocked.
  /// On success, [RetroAchievementsService.activeSession] is populated
  /// and the RA runtime is activated with mode enforcement enabled.
  /// Shows explicit user feedback about achievement support status.
  Future<void> _detectRetroAchievements() async {
    final settings = _settingsServiceRef!.settings;
    if (!settings.raEnabled) {
      _showRAToast(
        title: 'RetroAchievements Off',
        subtitle: 'Enable in Settings to track achievements',
        icon: Icons.emoji_events_outlined,
        accentColor: Colors.grey,
        duration: const Duration(seconds: 3),
      );
      return;
    }

    final raService = _raServiceRef!;

    if (!raService.isLoggedIn) {
      // TODO: Uncomment once RA approval is granted
      // _showRAToast(
      //   title: 'Not Logged In',
      //   subtitle: 'Log in to RetroAchievements in Settings',
      //   icon: Icons.login,
      //   accentColor: Colors.orange,
      //   duration: const Duration(seconds: 3),
      // );
      return;
    }

    // Reset notification flag for new game session
    _hasShownAchievementNotification = false;
    _lastGameData = null;

    // startGameSession may already have been fired from the home screen
    // (fire-and-forget).  Calling it again is safe — hash + gameId are
    // cached so it returns almost instantly if already resolved.  If the
    // home-screen call is still in-flight, we just wait for it.
    // An existing session only counts if it was created for THIS ROM.
    // A session left over from another game (achievements browsed from
    // the home screen, an exit path that skipped endGameSession, …) must
    // be replaced — reusing it would load the previous game's achievement
    // set into the native client and show its notifications in this game.
    final existingSession = raService.activeSession;
    final alreadyResolved =
        existingSession != null &&
        existingSession.gameId > 0 &&
        existingSession.romPath == widget.game.path &&
        !raService.isResolvingGame;
    if (!alreadyResolved) {
      await raService.startGameSession(widget.game);
    }

    if (!mounted) return;

    final session = raService.activeSession;
    final gameData = raService.gameData;

    // Show user feedback about achievement support
    if (session == null || session.gameId <= 0) {
      // Game not recognized by RetroAchievements
      _showRAToast(
        title: 'Not Recognized',
        subtitle: 'This ROM is not in the RetroAchievements database',
        icon: Icons.info_outline,
        accentColor: Colors.white70,
        duration: const Duration(seconds: 3),
      );
      return;
    }

    // Game recognized — activate mode enforcement
    _raRuntimeRef!.activate(hardcoreMode: settings.raHardcoreMode);

    if (!mounted) return;

    // ── Native rcheevos integration ──────────────────────────────────
    // Initialize the rc_client and begin login + game load.
    final emulator = _emulatorRef!;
    final mgbaCore = emulator.core;
    final rcClient = _rcheevosClientRef;
    if (rcClient != null &&
        mgbaCore != null &&
        mgbaCore.nativeCorePtr != null) {
      var initialized = rcClient.isInitialized;
      if (!initialized) {
        initialized = rcClient.initialize(mgbaCore.nativeCorePtr!);
      }
      if (initialized) {
        // Configure mode before every game load so encore stays active for
        // already-unlocked achievements.
        rcClient.setHardcoreEnabled(settings.raHardcoreMode);
        rcClient.setEncoreEnabled(true);

        // Begin login with saved credentials — game load happens
        // in _onRcheevosLoginSuccess when the login event arrives.
        final username = raService.username;
        final token = raService.connectToken;
        if (username != null && token != null) {
          if (rcClient.isLoggedIn) {
            _onRcheevosLoginSuccess();
          } else {
            rcClient.beginLogin(username, token);
          }
        }
      }
    }

    // Show achievement count feedback (top toast with game image).
    // Guard against stale data from a previous session (see
    // _onRetroAchievementsChanged for the matching check).
    if (gameData != null &&
        gameData.gameId == session.gameId &&
        gameData.achievements.isNotEmpty) {
      final earned = gameData.achievements.where((a) => a.isEarned).length;
      final total = gameData.achievements.length;
      final points = gameData.earnedPoints;
      final totalPts = gameData.totalPoints;
      _hasShownAchievementNotification = true;
      _lastGameData = gameData;
      _showRAToast(
        title: gameData.title,
        subtitle: '$earned/$total achievements · $points/$totalPts pts',
        imageUrl: gameData.imageIconUrl,
      );
    }
  }

  /// Flush accumulated session play time to the library
  void _flushPlayTime() {
    final emulator = _emulatorRef;
    final library = _libraryRef;
    if (emulator == null || library == null) return;
    final delta = emulator.flushPlayTime();
    if (delta > 0) {
      library.addPlayTime(widget.game, delta);
    }
  }

  void _onRewindHold(bool held) {
    if (held) {
      // Block rewind in Hardcore mode
      final blocked = _raRuntimeRef!.checkAction('rewind');
      if (blocked != null) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(blocked),
              duration: const Duration(seconds: 2),
            ),
          );
        return;
      }
      if (!_emulatorRef!.isRewindSupported) {
        final emu = _emulatorRef!;
        final String msg;
        if (emu.isUsingStub) {
          msg = 'Rewind is not available in the stub emulator.';
        } else if (emu.settings.enableRewind && !emu.isRewindBufferReady) {
          msg =
              'Rewind could not start (save states unavailable or low memory). '
              'Try a smaller Rewind Buffer in Settings.';
        } else {
          msg = 'Rewind is not available.';
        }
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
          );
        return;
      }
      _emulatorRef!.startRewind();
    } else {
      _emulatorRef!.stopRewind();
    }
  }

  /// Quick-save to slot 0 and show feedback.
  /// Blocked in Hardcore mode.
  Future<void> _doQuickSave() async {
    final blocked = _raRuntimeRef!.checkAction('saveState');
    if (blocked != null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(blocked),
              duration: const Duration(seconds: 2),
            ),
          );
      }
      return;
    }

    final success = await _emulatorRef!.saveState(0);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              success ? 'Quick saved (slot 1)' : 'Quick save failed',
            ),
            duration: const Duration(seconds: 1),
          ),
        );
    }
  }

  /// Quick-load from slot 0 and show feedback.
  /// Blocked in Hardcore mode.
  Future<void> _doQuickLoad() async {
    final blocked = _raRuntimeRef!.checkAction('loadState');
    if (blocked != null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(blocked),
              duration: const Duration(seconds: 2),
            ),
          );
      }
      return;
    }

    final success = await _emulatorRef!.loadState(0);
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              success ? 'Quick loaded (slot 1)' : 'Quick load failed',
            ),
            duration: const Duration(seconds: 1),
          ),
        );
    }
  }

  /// Show the shortcuts help dialog once on the second game launch.
  /// On the first launch the user should just enjoy the game; the dialog
  /// is always available from the in-game menu anyway.
  Future<void> _maybeShowShortcutsHelp() async {
    final settingsService = _settingsServiceRef!;
    await settingsService.incrementGameLaunchCount();
    final alreadyShown = await settingsService.isShortcutsHelpShown();
    if (alreadyShown) return;

    final launchCount = await settingsService.getGameLaunchCount();
    if (launchCount >= 2 && mounted) {
      // Pause briefly so the game loads visually before the overlay appears
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      await _showShortcutsHelp();
      await settingsService.markShortcutsHelpShown();
    }
  }

  /// Import a .sav file via file picker and load it into the game.
  bool _filePickerActive = false;
  Future<void> _importSaveFile() async {
    // Guard against double-invocation — the file_picker plugin throws
    // PlatformException(already_active) if opened while already showing.
    if (_filePickerActive) return;
    _filePickerActive = true;
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Select save file',
        type: FileType.custom,
        allowedExtensions: ['sav'],
      );
      if (result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null || path.isEmpty) return;

      _toggleMenu();
      final success = await _emulatorRef!.importSramFromFile(path);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Save imported. Game reset with new save.'
                : 'Failed to import save file.',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      if (success) {
        _emulatorRef!.start();
      }
    } on PlatformException catch (e) {
      // file_picker throws 'already_active' if the picker is still showing
      // from a prior invocation — swallow it instead of crashing.
      debugPrint('FilePicker: ${e.code} — ${e.message}');
    } finally {
      _filePickerActive = false;
    }
  }

  /// Display the shortcuts reference dialog.
  Future<void> _showShortcutsHelp() {
    final emulator = _emulatorRef!;
    final wasRunning = emulator.state == EmulatorState.running;
    if (wasRunning) emulator.pause();

    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => _ShortcutsHelpDialog(platform: widget.game.platform),
    ).then((_) {
      if (mounted && wasRunning && !_showMenu) {
        emulator.start();
        _focusNode.requestFocus();
      }
    });
  }

  Future<void> _exitGame() async {
    _flushPlayTime();
    _cheatSession.endSession();

    // Await stop so the SRAM save completes before we tear down the screen.
    await _emulatorRef?.stop();

    // Deactivate the RA runtime and end the session.  This must happen
    // even if the widget was unmounted during the await above — neither
    // call needs the BuildContext, and skipping them leaves a stale RA
    // session/gameData behind that the NEXT game would pick up (wrong
    // title toast + wrong achievement set loaded into the native client).
    _raRuntimeRef?.deactivate();
    _raServiceRef?.endGameSession();

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<bool> _showExitDialog() async {
    final colors = AppColorTheme.of(context);
    final emulator = _emulatorRef!;
    final wasRunning = emulator.state == EmulatorState.running;

    // Pause while showing dialog
    if (wasRunning) {
      emulator.pause();
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.primary.withAlpha(77), width: 2),
        ),
        title: Text(
          'Exit Game?',
          style: TextStyle(
            color: colors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Your battery save data will be preserved.',
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TvFocusable(
            autofocus: true,
            animate: true,
            subtleFocus: true,
            onTap: () => Navigator.of(context).pop(false),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: colors.textMuted.withAlpha(30),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('Cancel', style: TextStyle(color: colors.textMuted)),
            ),
          ),
          TvFocusable(
            animate: true,
            onTap: () => Navigator.of(context).pop(true),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: colors.error.withAlpha(51),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Exit',
                style: TextStyle(
                  color: colors.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (result == true) {
      _onExitWithAd();
      return true;
    } else {
      // Resume if was running
      if (wasRunning && !_showMenu) {
        emulator.start();
      }
      // Restore focus so gamepad/keyboard input resumes on TV
      if (mounted) _focusNode.requestFocus();
      return false;
    }
  }

  void _showLinkCableDialog() {
    _openLinkCableDialog();
  }

  void _openLinkCableDialog() {
    final emulator = _emulatorRef!;
    final linkCable = _linkCableRef!;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => _LinkCableDialog(
        game: widget.game,
        linkCable: linkCable,
        isSupported: emulator.isLinkSupported,
      ),
    ).then((_) {
      // Restore focus so gamepad/keyboard input resumes on TV
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _toggleOrientation() {
    if (_isLandscape) {
      // Switch to portrait and lock it
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } else {
      // Switch to landscape and lock it
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final emulator = context.watch<EmulatorService>();
    final settings = context.watch<SettingsService>().settings;

    // Create the game display.
    final Widget gameDisplay = GameDisplay(
      key: _gameDisplayKey,
      emulator: emulator,
      maintainAspectRatio: settings.maintainAspectRatio,
      // Combines the legacy Smooth Scaling toggle with the Pixel graphics
      // quality mode — false means pixel-perfect integer scaling.
      enableFiltering: settings.smoothScalingEnabled,
      enableNdsTouchOverlay: widget.game.platform != GamePlatform.nds,
    );
    final Widget layoutDisplay = gameDisplay;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _showExitDialog();
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: OrientationBuilder(
            builder: (context, orientation) {
              final newLandscape = orientation == Orientation.landscape;
              // NDS: flip the melonDS screen layout when orientation changes
              // so the two DS screens reflow Top/Bottom in portrait and
              // Left/Right (side-by-side) in landscape.
              if (newLandscape != _isLandscape &&
                  widget.game.platform == GamePlatform.nds) {
                emulator.setCoreOption(
                  'melonds_screen_layout',
                  newLandscape ? 'Left/Right' : 'Top/Bottom',
                );
              }
              _isLandscape = newLandscape;

              // ── Proportional HUD metrics ──
              // All HUD element sizes & positions are derived from screen
              // dimensions so the layout scales across phones and tablets.
              final sw = MediaQuery.of(context).size.width;
              final sh = MediaQuery.of(context).size.height;
              final safeTop = MediaQuery.of(context).padding.top;
              final safeBottom = MediaQuery.of(context).padding.bottom;
              // In landscape for GBA (wide aspect ratio), shrink HUD buttons
              // so they don't eat into the already-narrow side zones.
              final bool isGbaLandscape =
                  _isLandscape && widget.game.platform == GamePlatform.gba;
              final hudBtn = isGbaLandscape
                  ? (sw * 0.082).clamp(
                      30.0,
                      44.0,
                    ) // ~23% smaller for GBA landscape
                  : (sw * 0.107).clamp(36.0, 56.0); // normal size
              final hudEdge = sw * 0.02; // edge margin
              final hudGap = sw * 0.03; // gap between btns
              final hudTop = safeTop + sh * 0.005; // top offset
              final hudStep = hudBtn + hudGap; // one btn + gap

              return Stack(
                children: [
                  // Background — solid black for clear button visibility
                  Container(color: Colors.black),

                  // Main content - different layout for portrait vs landscape
                  // No SafeArea for either - maximize game display
                  _isLandscape
                      ? _buildLandscapeLayout(emulator, settings, layoutDisplay)
                      : _buildPortraitLayout(emulator, settings, layoutDisplay),

                  // Tap-to-restore layer: when controls were auto-hidden by
                  // gamepad detection, a screen tap restores touch controls
                  // (the gamepad may have been disconnected).
                  if (_controllerAutoHidden && !_showControls && !_showMenu)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () {
                          setState(() {
                            _showControls = true;
                            _controllerAutoHidden = false;
                          });
                          _gamepadMapper.resetDetection();
                          ScaffoldMessenger.of(context)
                            ..clearSnackBars()
                            ..showSnackBar(
                              const SnackBar(
                                content: Text('Touch controls restored'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                        },
                      ),
                    ),

                  // FPS overlay — scoped Selector so 500ms FPS ticks
                  // don't rebuild the entire game screen widget tree.
                  if (settings.showFps)
                    Positioned(
                      top: hudTop,
                      right: hudEdge + hudStep,
                      child: Selector<EmulatorService, double>(
                        selector: (_, e) => e.currentFps,
                        builder: (_, fps, _) => FpsOverlay(fps: fps),
                      ),
                    ),

                  // Link cable connection indicator
                  if (context.watch<LinkCableService>().state ==
                      LinkCableState.connected)
                    Positioned(
                      top: hudTop,
                      right: hudEdge + hudStep * 2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.withAlpha(160),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.cable, size: 12, color: Colors.white),
                            SizedBox(width: 3),
                            Text(
                              'LINKED',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Demo mode indicator
                  if (emulator.isUsingStub)
                    Positioned(
                      top: hudTop,
                      left: hudEdge + hudStep,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colors.warning.withAlpha(200),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'DEMO MODE',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: colors.backgroundDark,
                          ),
                        ),
                      ),
                    ),

                  // RetroAchievements status indicator (bottom-left)
                  if (settings.raEnabled)
                    Builder(
                      builder: (context) {
                        final raService = context
                            .watch<RetroAchievementsService>();
                        final session = raService.activeSession;
                        final gameData = raService.gameData;
                        final isResolving = raService.isResolvingGame;
                        final isLoadingData = raService.isLoadingGameData;

                        if (!raService.isLoggedIn) {
                          return const SizedBox.shrink();
                        }

                        final bool hasAchievements =
                            session != null && session.gameId > 0;
                        final bool isLoading = isResolving || isLoadingData;

                        String label;
                        Color bgColor;
                        IconData icon;

                        if (isLoading) {
                          label = 'Checking...';
                          bgColor = colors.textMuted.withAlpha(180);
                          icon = Icons.sync;
                        } else if (!hasAchievements && session != null) {
                          label = 'No achievements';
                          bgColor = colors.textMuted.withAlpha(180);
                          icon = Icons.block;
                        } else if (hasAchievements && gameData != null) {
                          final earned = gameData.achievements
                              .where((a) => a.isEarned)
                              .length;
                          final total = gameData.achievements.length;
                          label = '$earned/$total';
                          bgColor = colors.accent.withAlpha(200);
                          icon = Icons.emoji_events;
                        } else if (hasAchievements) {
                          label = 'RA';
                          bgColor = colors.accent.withAlpha(200);
                          icon = Icons.emoji_events;
                        } else {
                          return const SizedBox.shrink();
                        }

                        return Positioned(
                          bottom: safeBottom + sh * 0.02,
                          left: sw * 0.04,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: bgColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(icon, size: 12, color: Colors.white),
                                const SizedBox(width: 4),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                  // Hardcore mode badge (bottom-right)
                  if (settings.raEnabled)
                    Builder(
                      builder: (context) {
                        final raRuntime = context.watch<RARuntimeService>();
                        if (!raRuntime.isHardcore) {
                          return const SizedBox.shrink();
                        }

                        return Positioned(
                          bottom: safeBottom + sh * 0.02,
                          right: sw * 0.04,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withAlpha(200),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.shield,
                                  size: 12,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'HARDCORE',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                  // Achievement unlock toasts are handled via _onRuntimeUnlock listener

                  // Menu button (hide in edit mode)
                  if (!_editingLayout)
                    Positioned(
                      top: hudTop,
                      left: hudEdge,
                      child: _MenuButton(onTap: _toggleMenu, size: hudBtn),
                    ),

                  // Rewind button (hold to rewind) - next to menu
                  if (!_editingLayout && emulator.isRewindSupported)
                    Positioned(
                      top: hudTop,
                      left: hudEdge + hudStep,
                      child: _RewindButton(
                        isActive: emulator.isRewinding,
                        onHoldChanged: _onRewindHold,
                        size: hudBtn,
                      ),
                    ),

                  // Fast forward button (hide in edit mode) - next to menu/rewind
                  if (!_editingLayout)
                    Positioned(
                      top: hudTop,
                      left:
                          hudEdge +
                          hudStep * (emulator.isRewindSupported ? 2.5 : 1.5),
                      child: _FastForwardButton(
                        isActive: emulator.speedMultiplier > 1.0,
                        speed: emulator.speedMultiplier,
                        size: hudBtn,
                        onTap: () {
                          final blocked = _raRuntimeRef!.checkAction(
                            'fastForward',
                          );
                          if (blocked != null) {
                            ScaffoldMessenger.of(context)
                              ..clearSnackBars()
                              ..showSnackBar(
                                SnackBar(
                                  content: Text(blocked),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            return;
                          }
                          emulator.toggleFastForward();
                        },
                      ),
                    ),

                  // Rotation toggle button (hide in edit mode)
                  if (!_editingLayout)
                    Positioned(
                      top: hudTop,
                      right: hudEdge,
                      child: _RotationButton(
                        isLandscape: _isLandscape,
                        onTap: () => _toggleOrientation(),
                        size: hudBtn,
                      ),
                    ),

                  // Layout editor toolbar - centered to avoid all buttons
                  if (_editingLayout)
                    Positioned(
                      top: _isLandscape
                          ? sh * 0.35
                          : safeTop + hudBtn + hudGap * 2,
                      left: _isLandscape ? sw * 0.30 : sw * 0.04,
                      right: _isLandscape ? sw * 0.30 : sw * 0.04,
                      child: _LayoutEditorToolbar(
                        onSave: _saveLayout,
                        onCancel: _cancelEditLayout,
                        onReset: _resetLayout,
                      ),
                    ),

                  // In-game menu overlay
                  if (_showMenu)
                    _InGameMenu(
                      game: widget.game,
                      raService: settings.raEnabled ? _raServiceRef : null,
                      raRuntime: settings.raEnabled ? _raRuntimeRef : null,
                      onResume: _toggleMenu,
                      onReset: () {
                        _cheatSession.endSession();
                        emulator.reset();
                        _cheatSession.startSession(widget.game.path);
                        _toggleMenu();
                      },
                      onSaveState: (slot) async {
                        // Enforce hardcore mode
                        final blocked = _raRuntimeRef!.checkAction('saveState');
                        if (blocked != null) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                              ..clearSnackBars()
                              ..showSnackBar(
                                SnackBar(
                                  content: Text(blocked),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                          }
                          return;
                        }
                        final success = await emulator.saveState(slot);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                            ..clearSnackBars()
                            ..showSnackBar(
                              SnackBar(
                                content: Text(
                                  success
                                      ? 'State saved to slot $slot'
                                      : 'Failed to save state',
                                ),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                        }
                      },
                      onLoadState: (slot) async {
                        // Enforce hardcore mode
                        final blocked = _raRuntimeRef!.checkAction('loadState');
                        if (blocked != null) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                              ..clearSnackBars()
                              ..showSnackBar(
                                SnackBar(
                                  content: Text(blocked),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                          }
                          return;
                        }
                        final success = await emulator.loadState(slot);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                            ..clearSnackBars()
                            ..showSnackBar(
                              SnackBar(
                                content: Text(
                                  success
                                      ? 'State loaded from slot $slot'
                                      : 'Failed to load state',
                                ),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          if (success) _toggleMenu();
                        }
                      },
                      onToggleControls: () {
                        setState(() {
                          _showControls = !_showControls;
                          // User is explicitly toggling — no longer auto-hidden
                          _controllerAutoHidden = false;
                        });
                      },
                      showControls: _showControls,
                      onEditLayout: _enterEditMode,
                      currentSpeed: emulator.speedMultiplier,
                      onSpeedChanged: (speed) {
                        emulator.setSpeed(speed);
                      },
                      gameScreenScale: settings.gameScreenScale,
                      onScreenScaleChanged: (scale) {
                        _settingsServiceRef!.setGameScreenScale(scale);
                      },
                      onExit: _onExitWithAd,
                      useJoystick: settings.useJoystick,
                      onToggleJoystick: () {
                        _settingsServiceRef!.toggleJoystick();
                      },
                      onScreenshot: () async {
                        final path = await emulator.captureScreenshot();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                            ..clearSnackBars()
                            ..showSnackBar(
                              SnackBar(
                                content: Text(
                                  path != null
                                      ? 'Screenshot saved'
                                      : 'Failed to capture screenshot',
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                        }
                      },
                      onShowShortcuts: () {
                        _toggleMenu(); // close menu first
                        _showShortcutsHelp();
                      },
                      onLinkCable: () {
                        _showLinkCableDialog();
                      },
                      onCheats: () {
                        // Block cheats when RetroAchievements hardcore mode is active
                        final blocked = _raRuntimeRef!.checkAction('cheat');
                        if (blocked != null) {
                          ScaffoldMessenger.of(context)
                            ..clearSnackBars()
                            ..showSnackBar(
                              SnackBar(
                                content: Text(blocked),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          return;
                        }
                        final emulator = _emulatorRef!;
                        emulator.pause();
                        _toggleMenu();
                        Navigator.of(context)
                            .push(
                              MaterialPageRoute(
                                builder: (_) => CheatScreen(
                                  game: widget.game,
                                  session: _cheatSession,
                                ),
                              ),
                            )
                            .then((_) {
                              if (mounted) {
                                emulator.start();
                                _focusNode.requestFocus();
                              }
                            });
                      },
                      onImportSave: () => _importSaveFile(),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Portrait layout: Game on top, controls on bottom - FULLY MAXIMIZED
  /// All values are PROPORTIONAL to screen size for consistent layout across devices
  Widget _buildPortraitLayout(
    EmulatorService emulator,
    EmulatorSettings settings,
    Widget gameDisplay,
  ) {
    final bool isNdsGame = widget.game.platform == GamePlatform.nds;
    final layout =
        _tempLayout ??
        settings.gamepadLayoutForPlatform(
          widget.game.platform,
          landscape: false,
        );
    final screenSize = MediaQuery.of(context).size;
    final safeArea = MediaQuery.of(context).padding;

    // Calculate optimal game display - MAXIMUM SIZE, NO PADDING
    final aspectRatio = isNdsGame
        ? 256.0 / 384.0
        : emulator.screenWidth / emulator.screenHeight;

    // Use FULL width - no padding
    final maxGameWidth = isNdsGame ? screenSize.width * 1.02 : screenSize.width;

    // Calculate height from width
    double gameWidth = maxGameWidth;
    double gameHeight = gameWidth / aspectRatio;

    // On TV, maximize game to fill screen (no touch controls needed)
    if (TvDetector.isTV) {
      // Use full screen, constrained only by aspect ratio
      final availableHeight =
          screenSize.height - safeArea.top - safeArea.bottom;

      // Try full width first
      gameWidth = screenSize.width;
      gameHeight = gameWidth / aspectRatio;

      // If too tall, constrain by height
      if (gameHeight > availableHeight) {
        gameHeight = availableHeight;
        gameWidth = gameHeight * aspectRatio;
      }

      // Center vertically
      final gameTop = safeArea.top + (availableHeight - gameHeight) / 2;

      return Stack(
        children: [
          // Game display - centered and FULLY MAXIMIZED for TV
          Positioned(
            top: gameTop,
            left: (screenSize.width - gameWidth) / 2,
            child: SizedBox(
              width: gameWidth,
              height: gameHeight,
              child: gameDisplay,
            ),
          ),
        ],
      );
    }

    // For NDS, skip the control-area height cap. The tall 256×384
    // framebuffer stays full width and controls can use a modest overlap.
    final bool isNds = widget.game.platform == GamePlatform.nds;

    // Cap game height so the gamepad area always has enough room.
    // GB/GBC (160×144, ratio ~1.11) at full width would consume ~90% of
    // the width as height, leaving almost no space for controls.
    // Limit the game to at most 42% of screen height so controls get ≥50%.
    // NDS: NO cap — maximize the dual-screen display at full width;
    // buttons overlay the bottom portion of the screen.
    if (!isNds) {
      // 0.46 (was 0.42): controls overlay-tolerate a few extra percent and
      // the old cap visibly shrank near-square systems (GB/GBC) on 16:9
      // screens — "maximum possible size" wins.
      final maxGameHeight = screenSize.height * 0.46;
      if (gameHeight > maxGameHeight) {
        gameHeight = maxGameHeight;
        gameWidth = gameHeight * aspectRatio;
      }
    }

    // Apply user game screen scale setting (1.0 = max, 0.5 = half size)
    final double screenScale = (settings.gameScreenScale as double?) ?? 1.0;
    if (screenScale < 1.0) {
      gameWidth *= screenScale;
      gameHeight *= screenScale;
    }

    // NDS: small top offset; the display is slightly oversized and clipped
    // horizontally to feel larger without adding padding.
    // Others: 7% top offset so HUD buttons don't clip the game edge.
    final gameTop = isNds
        ? safeArea.top + screenSize.height * 0.03
        : safeArea.top + screenSize.height * 0.07;

    final gameRect = Rect.fromLTWH(
      (screenSize.width - gameWidth) / 2,
      gameTop,
      gameWidth,
      gameHeight,
    );

    return _wrapNdsTouchSurface(
      emulator: emulator,
      gameRect: gameRect,
      isLandscapeLayout: false,
      child: Stack(
        children: [
          // Game display at top - FULL WIDTH, NO PADDING
          Positioned(
            top: gameTop,
            left: gameRect.left,
            child: SizedBox(
              width: gameWidth,
              height: gameHeight,
              child: gameDisplay,
            ),
          ),

          // Virtual gamepad - full-screen overlay. Button positions are pure
          // fractions of the screen, so the overlay must span the whole phone;
          // empty areas let touches fall through to the game/touch surface.
          if (_showControls)
            Positioned.fill(
              child: VirtualGamepad(
                onKeysChanged: _onVirtualKeysChanged,
                onAnalogChanged: _onVirtualAnalogChanged,
                onRightAnalogChanged: _onVirtualRightAnalogChanged,
                opacity: settings.gamepadOpacity,
                scale: settings.gamepadScale,
                enableVibration: settings.enableVibration,
                layout: layout,
                editMode: _editingLayout,
                onLayoutChanged: (newLayout) {
                  setState(() => _tempLayout = newLayout);
                },
                useJoystick: settings.useJoystick,
                skin: settings.gamepadSkin,
                platform: widget.game.platform,
              ),
            ),
        ],
      ),
    );
  }

  /// Landscape layout: Game centered, controls overlay on sides - FULLY MAXIMIZED
  Widget _buildLandscapeLayout(
    EmulatorService emulator,
    EmulatorSettings settings,
    Widget gameDisplay,
  ) {
    final bool isNdsGame = widget.game.platform == GamePlatform.nds;
    final baseLayout =
        _tempLayout ??
        settings.gamepadLayoutForPlatform(
          widget.game.platform,
          landscape: true,
        );
    final screenSize = MediaQuery.of(context).size;
    final safeArea = MediaQuery.of(context).padding;

    // Calculate game size - MAXIMUM SIZE, NO PADDING
    final aspectRatio = isNdsGame
        ? 512.0 / 192.0
        : emulator.screenWidth / emulator.screenHeight;

    // On TV, use safe area to avoid overscan but maximize within it
    final availableWidth = TvDetector.isTV
        ? screenSize.width - safeArea.left - safeArea.right
        : screenSize.width;
    final availableHeight = TvDetector.isTV
        ? screenSize.height - safeArea.top - safeArea.bottom
        : screenSize.height;

    double gameWidth;
    double gameHeight;
    if (isNdsGame) {
      gameWidth = availableWidth * 0.96;
      gameHeight = gameWidth / aspectRatio;
      final maxGameHeight = availableHeight * 0.96;
      if (gameHeight > maxGameHeight) {
        gameHeight = maxGameHeight;
        gameWidth = gameHeight * aspectRatio;
      }
    } else {
      // Calculate width from height
      gameHeight = availableHeight;
      gameWidth = gameHeight * aspectRatio;

      // If too wide, constrain by width
      if (gameWidth > availableWidth) {
        gameWidth = availableWidth;
        gameHeight = gameWidth / aspectRatio;
      }
    }

    // Cap game width so each side always has at least some space
    // for touch controls.  GB/GBC (nearly-square) would otherwise leave
    // tiny side zones and button sizes scale with gameRect.width.
    // On TV, skip this cap — no touch controls, use full screen.
    // NDS uses absolute overlay controls in VirtualGamepad, so it can use
    // the full available width.
    if (!TvDetector.isTV && !isNdsGame) {
      // 0.75 (was 0.64): on 16:9 devices the old cap cut 4:3 games to ~85%
      // of their full-height fit. Touch controls are translucent overlays
      // positioned relative to gameRect, so a modest overlap with the game
      // edges is fine — maximum game size wins.
      final maxGameWidth = screenSize.width * 0.75;
      if (gameWidth > maxGameWidth) {
        gameWidth = maxGameWidth;
        gameHeight = gameWidth / aspectRatio;
      }
    }

    // Apply user game screen scale setting (1.0 = max, 0.5 = half size)
    final double screenScale = (settings.gameScreenScale as double?) ?? 1.0;
    if (screenScale < 1.0) {
      gameWidth *= screenScale;
      gameHeight *= screenScale;
    }

    final gameRect = Rect.fromLTWH(
      (screenSize.width - gameWidth) / 2,
      (screenSize.height - gameHeight) / 2,
      gameWidth,
      gameHeight,
    );

    return _wrapNdsTouchSurface(
      emulator: emulator,
      gameRect: gameRect,
      isLandscapeLayout: true,
      child: Stack(
        children: [
          // Game display - centered and FULLY MAXIMIZED
          Center(
            child: SizedBox(
              width: gameWidth,
              height: gameHeight,
              child: gameDisplay,
            ),
          ),

          // Virtual gamepad overlay in landscape — full-screen; button
          // positions are pure fractions of the screen, independent of the game.
          if (_showControls)
            VirtualGamepad(
              onKeysChanged: _onVirtualKeysChanged,
              onAnalogChanged: _onVirtualAnalogChanged,
              onRightAnalogChanged: _onVirtualRightAnalogChanged,
              opacity: settings.gamepadOpacity,
              scale: settings.gamepadScale,
              enableVibration: settings.enableVibration,
              layout: baseLayout,
              editMode: _editingLayout,
              onLayoutChanged: (newLayout) {
                setState(() => _tempLayout = newLayout);
              },
              useJoystick: settings.useJoystick,
              skin: settings.gamepadSkin,
              platform: widget.game.platform,
            ),
        ],
      ),
    );
  }

  Widget _wrapNdsTouchSurface({
    required EmulatorService emulator,
    required Rect gameRect,
    required bool isLandscapeLayout,
    required Widget child,
  }) {
    if (widget.game.platform != GamePlatform.nds) return child;

    return SizedBox.expand(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) => _handleNdsTouch(
          emulator: emulator,
          position: event.localPosition,
          gameRect: gameRect,
          isLandscapeLayout: isLandscapeLayout,
        ),
        onPointerMove: (event) => _handleNdsTouch(
          emulator: emulator,
          position: event.localPosition,
          gameRect: gameRect,
          isLandscapeLayout: isLandscapeLayout,
        ),
        onPointerUp: (_) => _releaseNdsTouch(emulator),
        onPointerCancel: (_) => _releaseNdsTouch(emulator),
        child: child,
      ),
    );
  }

  void _handleNdsTouch({
    required EmulatorService emulator,
    required Offset position,
    required Rect gameRect,
    required bool isLandscapeLayout,
  }) {
    final point = _localToNdsPointer(
      position: position,
      gameRect: gameRect,
      isLandscapeLayout: isLandscapeLayout,
    );
    if (point == null) {
      _releaseNdsTouch(emulator);
      return;
    }

    emulator.setTouch(point.x, point.y, true);
    _ndsTouchActive = true;
  }

  ({int x, int y})? _localToNdsPointer({
    required Offset position,
    required Rect gameRect,
    required bool isLandscapeLayout,
  }) {
    if (!gameRect.contains(position) ||
        gameRect.width <= 0 ||
        gameRect.height <= 0) {
      return null;
    }

    final fbW = isLandscapeLayout ? 512.0 : 256.0;
    final fbH = isLandscapeLayout ? 192.0 : 384.0;
    final px = (position.dx - gameRect.left) / gameRect.width * fbW;
    final py = (position.dy - gameRect.top) / gameRect.height * fbH;

    if (isLandscapeLayout) {
      if (px < fbW / 2.0) return null;
    } else {
      if (py < fbH / 2.0) return null;
    }

    int normalizePointer(double pixel, double extent) {
      if (extent <= 1.0) return 0;
      final clamped = pixel.clamp(0.0, extent - 1.0).toDouble();
      final value = ((clamped / (extent - 1.0)) * 65534.0 - 32767.0).round();
      return value.clamp(-32767, 32767).toInt();
    }

    return (x: normalizePointer(px, fbW), y: normalizePointer(py, fbH));
  }

  void _releaseNdsTouch(EmulatorService emulator) {
    if (!_ndsTouchActive) return;
    emulator.setTouch(0, 0, false);
    _ndsTouchActive = false;
  }

  void _enterEditMode() {
    final settings = _settingsServiceRef!.settings;
    final p = widget.game.platform;
    setState(() {
      _editingLayout = true;
      _showMenu = false;
      _tempLayout = settings.gamepadLayoutForPlatform(
        p,
        landscape: _isLandscape,
      );
    });

    // Pause emulation while editing
    _emulatorRef!.pause();
  }

  void _saveLayout() async {
    if (_tempLayout == null) return;

    final settingsService = _settingsServiceRef!;
    final emulatorService = _emulatorRef!;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final p = widget.game.platform;

    await settingsService.setGamepadLayoutForPlatform(
      p,
      landscape: _isLandscape,
      layout: _tempLayout!,
    );
    if (!mounted) return;

    setState(() {
      _editingLayout = false;
      _tempLayout = null;
    });

    // Resume emulation
    emulatorService.start();

    if (mounted) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text('Layout saved!'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _cancelEditLayout() {
    setState(() {
      _editingLayout = false;
      _tempLayout = null;
    });

    // Resume emulation
    _emulatorRef?.start();
  }

  void _resetLayout() {
    final p = widget.game.platform;
    setState(
      () => _tempLayout = GamepadLayout.defaultForPlatform(
        p,
        landscape: _isLandscape,
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  final VoidCallback onTap;
  final double size;

  const _MenuButton({required this.onTap, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return TvFocusable(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(size * 0.27),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colors.surface.withAlpha(204),
            borderRadius: BorderRadius.circular(size * 0.27),
            border: Border.all(color: colors.surfaceLight, width: 1),
          ),
          child: Icon(
            Icons.menu,
            color: colors.textSecondary,
            size: size * 0.55,
          ),
        ),
      ),
    );
  }
}

class _RotationButton extends StatelessWidget {
  final bool isLandscape;
  final VoidCallback onTap;
  final double size;

  const _RotationButton({
    required this.isLandscape,
    required this.onTap,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return TvFocusable(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(size * 0.27),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colors.surface.withAlpha(204),
            borderRadius: BorderRadius.circular(size * 0.27),
            border: Border.all(color: colors.surfaceLight, width: 1),
          ),
          child: Icon(
            Icons.screen_rotation,
            color: colors.textSecondary,
            size: size * 0.50,
          ),
        ),
      ),
    );
  }
}

class _LayoutEditorToolbar extends StatelessWidget {
  final VoidCallback onSave;
  final VoidCallback onCancel;
  final VoidCallback onReset;

  const _LayoutEditorToolbar({
    required this.onSave,
    required this.onCancel,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(240),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.accent, width: 2),
        boxShadow: [
          BoxShadow(
            color: colors.accent.withAlpha(50),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.tune, color: colors.accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'EDIT LAYOUT',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: colors.accent,
                    letterSpacing: 2,
                  ),
                ),
              ),
              // Close button — 44pt min touch target, TV focusable, semantics
              TvFocusable(
                onTap: () {
                  HapticFeedback.lightImpact();
                  onCancel();
                },
                onBack: onCancel,
                borderRadius: BorderRadius.circular(22),
                subtleFocus: true,
                child: Semantics(
                  button: true,
                  label: 'Close layout editor',
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      onCancel();
                    },
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: Icon(
                          Icons.close,
                          color: colors.textMuted,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Instructions
          Text(
            'Drag buttons to move • Tap to select • Use +/- to resize',
            style: TextStyle(fontSize: 11, color: colors.textMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),

          // Action buttons
          Row(
            children: [
              // Reset button
              Expanded(
                child: TvFocusable(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onReset();
                  },
                  borderRadius: BorderRadius.circular(8),
                  subtleFocus: true,
                  child: Semantics(
                    button: true,
                    label: 'Reset layout to default',
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        onReset();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: colors.backgroundLight,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: colors.surfaceLight),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.restart_alt,
                              color: colors.textSecondary,
                              size: 18,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Reset',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // Save button
              Expanded(
                child: TvFocusable(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    onSave();
                  },
                  borderRadius: BorderRadius.circular(8),
                  subtleFocus: true,
                  child: Semantics(
                    button: true,
                    label: 'Save layout',
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        onSave();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.check,
                              color: colors.textPrimary,
                              size: 18,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Save',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: colors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InGameMenu extends StatelessWidget {
  final GameRom game;
  final VoidCallback onResume;
  final VoidCallback onReset;
  final void Function(int slot) onSaveState;
  final void Function(int slot) onLoadState;
  final VoidCallback onToggleControls;
  final bool showControls;
  final VoidCallback onEditLayout;
  final double currentSpeed;
  final void Function(double speed) onSpeedChanged;
  final double gameScreenScale;
  final void Function(double scale) onScreenScaleChanged;
  final VoidCallback onExit;
  final bool useJoystick;
  final VoidCallback onToggleJoystick;
  final VoidCallback onScreenshot;
  final VoidCallback onShowShortcuts;
  final VoidCallback onLinkCable;
  final VoidCallback onCheats;
  final VoidCallback onImportSave;
  final RetroAchievementsService? raService;
  final RARuntimeService? raRuntime;

  const _InGameMenu({
    required this.game,
    required this.onResume,
    required this.onReset,
    required this.onSaveState,
    required this.onLoadState,
    required this.onToggleControls,
    required this.showControls,
    required this.onEditLayout,
    required this.currentSpeed,
    required this.onSpeedChanged,
    required this.gameScreenScale,
    required this.onScreenScaleChanged,
    required this.onExit,
    required this.useJoystick,
    required this.onToggleJoystick,
    required this.onScreenshot,
    required this.onShowShortcuts,
    required this.onLinkCable,
    required this.onCheats,
    required this.onImportSave,
    this.raService,
    this.raRuntime,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: GestureDetector(
        onTap: onResume,
        child: Container(
          color: Colors.black.withAlpha(138),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // Prevent tap through
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.78,
                  margin: const EdgeInsets.all(20),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: colors.primary.withAlpha(77),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: colors.primary.withAlpha(51),
                        blurRadius: 30,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Title
                              Text(
                                'PAUSED',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: colors.accent,
                                  letterSpacing: 4,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                game.name,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),

                              // Achievement progress section
                              if (raService != null && raService!.isLoggedIn)
                                _buildAchievementSection(context),

                              // View Achievements button
                              if (raService != null &&
                                  raService!.isLoggedIn &&
                                  raService!.gameData != null &&
                                  raService!
                                      .gameData!
                                      .achievements
                                      .isNotEmpty) ...[
                                const SizedBox(height: 8),
                                _MenuActionButton(
                                  icon: Icons.emoji_events,
                                  label: 'View Achievements',
                                  onTap: () => _openAchievementsList(context),
                                ),
                              ],

                              const SizedBox(height: 20),

                              // Resume button
                              _MenuActionButton(
                                icon: Icons.play_arrow,
                                label: 'Resume',
                                onTap: onResume,
                                isPrimary: true,
                                autofocus: true,
                              ),
                              const SizedBox(height: 10),

                              // Screenshot button
                              _MenuActionButton(
                                icon: Icons.camera_alt,
                                label: 'Screenshot',
                                onTap: onScreenshot,
                              ),
                              const SizedBox(height: 10),

                              _MenuActionButton(
                                icon: Icons.code,
                                label: 'Cheats',
                                onTap: onCheats,
                              ),
                              const SizedBox(height: 10),

                              // Save/Load states
                              // On TV: stack vertically for D-pad navigation
                              // On phone: side by side
                              if (TvDetector.isTV) ...[
                                _MenuActionButton(
                                  icon: Icons.save,
                                  label: 'Save State',
                                  onTap: () => _showStateSlots(context, true),
                                ),
                                const SizedBox(height: 10),
                                _MenuActionButton(
                                  icon: Icons.upload_file,
                                  label: 'Load State',
                                  onTap: () => _showStateSlots(context, false),
                                ),
                                const SizedBox(height: 10),
                                _MenuActionButton(
                                  icon: Icons.upload,
                                  label: 'Import Save',
                                  onTap: onImportSave,
                                ),
                              ] else ...[
                                Row(
                                  children: [
                                    Expanded(
                                      child: _MenuActionButton(
                                        icon: Icons.save,
                                        label: 'Save State',
                                        onTap: () =>
                                            _showStateSlots(context, true),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _MenuActionButton(
                                        icon: Icons.upload_file,
                                        label: 'Load State',
                                        onTap: () =>
                                            _showStateSlots(context, false),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                _MenuActionButton(
                                  icon: Icons.upload,
                                  label: 'Import Save',
                                  onTap: onImportSave,
                                ),
                              ],
                              const SizedBox(height: 10),

                              // Other options
                              _MenuActionButton(
                                icon: showControls
                                    ? Icons.gamepad
                                    : Icons.gamepad_outlined,
                                label: showControls
                                    ? 'Hide Controls'
                                    : 'Show Controls',
                                onTap: onToggleControls,
                              ),
                              const SizedBox(height: 10),

                              // D-Pad / Joystick selector
                              _InputTypeSelector(
                                useJoystick: useJoystick,
                                onChanged: onToggleJoystick,
                              ),
                              const SizedBox(height: 10),

                              _MenuActionButton(
                                icon: Icons.tune,
                                label: 'Edit Layout',
                                onTap: onEditLayout,
                              ),
                              const SizedBox(height: 10),

                              // Game screen size control
                              _ScreenScaleSelector(
                                currentScale: gameScreenScale,
                                onScaleChanged: onScreenScaleChanged,
                              ),
                              const SizedBox(height: 10),

                              // Speed control
                              _SpeedSelector(
                                currentSpeed: currentSpeed,
                                onSpeedChanged: onSpeedChanged,
                              ),
                              const SizedBox(height: 10),

                              if (game.platform == GamePlatform.gb ||
                                  game.platform == GamePlatform.gbc ||
                                  game.platform == GamePlatform.gba) ...[
                                _MenuActionButton(
                                  icon: Icons.cable,
                                  label: 'Link Cable',
                                  onTap: onLinkCable,
                                ),
                                const SizedBox(height: 10),
                              ],

                              _MenuActionButton(
                                icon: Icons.keyboard,
                                label: 'Shortcuts',
                                onTap: onShowShortcuts,
                              ),
                              const SizedBox(height: 10),

                              _MenuActionButton(
                                icon: Icons.refresh,
                                label: 'Reset',
                                onTap: onReset,
                              ),
                              const SizedBox(height: 10),

                              _MenuActionButton(
                                icon: Icons.exit_to_app,
                                label: 'Exit Game',
                                onTap: onExit,
                                isDestructive: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (!TvDetector.isTV)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: IgnorePointer(
                            child: Container(
                              height: 28,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    colors.surface.withAlpha(0),
                                    colors.surface.withAlpha(245),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAchievementSection(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final session = raService?.activeSession;
    final gameData = raService?.gameData;
    final isResolving = raService?.isResolvingGame ?? false;
    final isHardcore = raRuntime?.isHardcore ?? false;

    // Still resolving game
    if (isResolving) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Checking achievements...',
              style: TextStyle(fontSize: 12, color: colors.textMuted),
            ),
          ],
        ),
      );
    }

    // Game not recognized by RA
    if (session == null || session.gameId <= 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colors.backgroundLight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.textMuted.withAlpha(60)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.block, size: 14, color: colors.textMuted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'No RetroAchievements for this ROM',
                  style: TextStyle(fontSize: 11, color: colors.textMuted),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Game recognized but data still loading
    if (gameData == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.amber,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Loading achievements...',
              style: TextStyle(fontSize: 12, color: colors.textMuted),
            ),
          ],
        ),
      );
    }

    // Have achievement data — show progress
    final total = gameData.achievements.length;
    final earned = gameData.achievements.where((a) => a.isEarned).length;
    final earnedHc = gameData.achievements
        .where((a) => a.isEarnedHardcore)
        .length;
    final displayEarned = isHardcore ? earnedHc : earned;
    final earnedPts = isHardcore
        ? gameData.earnedPointsHardcore
        : gameData.earnedPoints;
    final totalPts = gameData.totalPoints;
    final progress = total > 0 ? displayEarned / total : 0.0;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.backgroundLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isHardcore
                ? Colors.redAccent.withAlpha(80)
                : colors.accent.withAlpha(80),
          ),
        ),
        child: Column(
          children: [
            // Header row
            Row(
              children: [
                Icon(
                  Icons.emoji_events,
                  size: 16,
                  color: isHardcore ? Colors.amber : colors.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  'Achievements',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                if (isHardcore) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withAlpha(40),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.redAccent.withAlpha(100),
                        width: 0.5,
                      ),
                    ),
                    child: const Text(
                      'HC',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.redAccent,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  '$displayEarned / $total',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isHardcore ? Colors.amber : colors.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: colors.backgroundDark,
                color: isHardcore ? Colors.amber : colors.accent,
              ),
            ),
            const SizedBox(height: 6),
            // Points row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '$earnedPts / $totalPts points',
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
                if (total > 0)
                  Text(
                    '${(progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openAchievementsList(BuildContext context) {
    final gameData = raService?.gameData;
    if (gameData == null) return;
    final isHardcore = raRuntime?.isHardcore ?? false;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            AchievementsScreen(gameData: gameData, isHardcore: isHardcore),
      ),
    );
  }

  void _showStateSlots(BuildContext context, bool isSave) {
    final emulator = context.read<EmulatorService>();
    showDialog(
      context: context,
      builder: (dialogContext) => _StateSlotDialog(
        isSave: isSave,
        emulator: emulator,
        onSelect: (slot) {
          Navigator.pop(dialogContext);
          if (isSave) {
            onSaveState(slot);
          } else {
            onLoadState(slot);
          }
        },
      ),
    ).then((_) {
      // Restore focus to the pause menu so D-pad navigation works on TV
      if (context.mounted) {
        FocusScope.of(context).requestFocus();
      }
    });
  }
}

class _StateSlotDialog extends StatefulWidget {
  final bool isSave;
  final EmulatorService emulator;
  final void Function(int slot) onSelect;

  const _StateSlotDialog({
    required this.isSave,
    required this.emulator,
    required this.onSelect,
  });

  @override
  State<_StateSlotDialog> createState() => _StateSlotDialogState();
}

class _StateSlotDialogState extends State<_StateSlotDialog> {
  final Map<int, bool> _hasState = {};
  final Map<int, File?> _screenshotFiles = {};
  final Map<int, DateTime?> _timestamps = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSlotInfo();
  }

  Future<void> _loadSlotInfo() async {
    final hasState = <int, bool>{};
    final screenshotFiles = <int, File?>{};
    final timestamps = <int, DateTime?>{};

    for (int i = 0; i < 6; i++) {
      final statePath = widget.emulator.getStatePath(i);
      final ssPath = widget.emulator.getStateScreenshotPath(i);

      if (statePath != null) {
        final stateFile = File(statePath);
        if (await stateFile.exists()) {
          hasState[i] = true;
          timestamps[i] = await stateFile.lastModified();
        }
      }

      if (ssPath != null) {
        final ssFile = File(ssPath);
        if (await ssFile.exists()) {
          screenshotFiles[i] = ssFile;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _hasState.addAll(hasState);
      _screenshotFiles.addAll(screenshotFiles);
      _timestamps.addAll(timestamps);
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final maxDialogWidth = MediaQuery.of(context).size.width * 0.9;
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.primary.withAlpha(77), width: 2),
      ),
      contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      title: Row(
        children: [
          Icon(
            widget.isSave ? Icons.save : Icons.upload_file,
            color: colors.accent,
            size: 22,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              widget.isSave ? 'Save State' : 'Load State',
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
        width: maxDialogWidth < 300 ? maxDialogWidth : 300,
        child: _isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(6, (i) => _buildSlot(i)),
                  ),
                ),
              ),
      ),
      actions: [
        TvFocusable(
          onTap: () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(8),
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: colors.textMuted)),
          ),
        ),
      ],
    );
  }

  /// Handles tap on a slot. All slots are now free.
  void _onSlotTap(int index, bool hasState) {
    widget.onSelect(index);
  }

  Widget _buildSlot(int index) {
    final colors = AppColorTheme.of(context);
    final hasState = _hasState[index] == true;
    final hasScreenshot = _screenshotFiles.containsKey(index);
    final timestamp = _timestamps[index];
    final isDisabled = !widget.isSave && !hasState;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TvFocusable(
        autofocus: index == 0,
        onTap: isDisabled ? null : () => _onSlotTap(index, hasState),
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isDisabled ? null : () => _onSlotTap(index, hasState),
            borderRadius: BorderRadius.circular(12),
            child: Opacity(
              opacity: isDisabled ? 0.4 : 1.0,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.backgroundLight,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: hasState
                        ? colors.primary.withAlpha(120)
                        : colors.surfaceLight,
                    width: hasState ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    // Screenshot thumbnail (GBA 3:2 aspect ratio)
                    ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(11),
                        bottomLeft: Radius.circular(11),
                      ),
                      child: SizedBox(
                        width: 96,
                        height: 64,
                        child: hasScreenshot
                            ? Image.file(
                                _screenshotFiles[index]!,
                                fit: BoxFit.cover,
                                cacheWidth: 192,
                                errorBuilder: (_, _, _) =>
                                    _placeholderWidget(hasState),
                              )
                            : _placeholderWidget(hasState),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Slot info
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Slot ${index + 1}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: colors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              hasState && timestamp != null
                                  ? _formatTimestamp(timestamp)
                                  : 'Empty',
                              style: TextStyle(
                                fontSize: 11,
                                color: hasState
                                    ? colors.textSecondary
                                    : colors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Chevron or lock indicator
                    if (!isDisabled)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Icon(
                          Icons.chevron_right,
                          color: colors.textMuted,
                          size: 20,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholderWidget(bool hasState) {
    final colors = AppColorTheme.of(context);
    return Container(
      color: colors.backgroundDark,
      child: Center(
        child: Icon(
          hasState ? Icons.image_outlined : Icons.add_photo_alternate_outlined,
          color: colors.textMuted.withAlpha(60),
          size: 24,
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day}, $hour:$minute $amPm';
  }
}

class _MenuActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;
  final bool isDestructive;
  final bool autofocus;

  const _MenuActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
    this.isDestructive = false,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final bgColor = isPrimary
        ? colors.primary
        : isDestructive
        ? colors.error.withAlpha(51)
        : colors.backgroundLight;

    final fgColor = isPrimary
        ? colors.textPrimary
        : isDestructive
        ? colors.error
        : colors.textSecondary;

    return TvFocusable(
      onTap: onTap,
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 120;
          return Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 16,
              vertical: compact ? 10 : 12,
            ),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(12),
              border: isPrimary
                  ? null
                  : Border.all(color: colors.surfaceLight, width: 1),
            ),
            child: compact
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: fgColor, size: 18),
                      const SizedBox(height: 4),
                      Text(
                        label,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: fgColor,
                          height: 1.1,
                        ),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: fgColor, size: 20),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: fgColor,
                          ),
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

String _formatSpeedLabel(double speed) {
  if ((speed - speed.roundToDouble()).abs() < 0.0001) {
    return '${speed.toStringAsFixed(0)}x';
  }
  if ((speed * 10 - (speed * 10).roundToDouble()).abs() < 0.0001) {
    return '${speed.toStringAsFixed(1)}x';
  }
  return '${speed.toStringAsFixed(2)}x';
}

class _RewindButton extends StatelessWidget {
  final bool isActive;
  final void Function(bool held) onHoldChanged;
  final double size;

  const _RewindButton({
    required this.isActive,
    required this.onHoldChanged,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final radius = size * 0.27;
    return TvFocusable(
      onTap: () {
        HapticFeedback.lightImpact();
        onHoldChanged(!isActive);
      },
      borderRadius: BorderRadius.circular(radius),
      child: GestureDetector(
        onTapDown: (_) {
          HapticFeedback.lightImpact();
          onHoldChanged(true);
        },
        onTapUp: (_) => onHoldChanged(false),
        onTapCancel: () => onHoldChanged(false),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: isActive
                ? colors.accent.withAlpha(230)
                : colors.surface.withAlpha(204),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: isActive ? colors.accent : colors.surfaceLight,
              width: 1,
            ),
          ),
          child: Icon(
            Icons.fast_rewind,
            color: isActive ? colors.backgroundDark : colors.textSecondary,
            size: size * 0.50,
          ),
        ),
      ),
    );
  }
}

class _FastForwardButton extends StatelessWidget {
  final bool isActive;
  final double speed;
  final VoidCallback onTap;
  final double size;

  const _FastForwardButton({
    required this.isActive,
    required this.speed,
    required this.onTap,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final radius = size * 0.27;
    return TvFocusable(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(radius),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Container(
          height: size,
          padding: EdgeInsets.symmetric(horizontal: size * 0.27),
          decoration: BoxDecoration(
            color: isActive
                ? colors.accent.withAlpha(230)
                : colors.surface.withAlpha(204),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: isActive ? colors.accent : colors.surfaceLight,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.fast_forward,
                color: isActive ? colors.backgroundDark : colors.textSecondary,
                size: size * 0.45,
              ),
              if (isActive) ...[
                SizedBox(width: size * 0.09),
                Text(
                  _formatSpeedLabel(speed),
                  style: TextStyle(
                    fontSize: size * 0.27,
                    fontWeight: FontWeight.bold,
                    color: colors.backgroundDark,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline game screen size selector for the in-game menu.
/// Allows quick resizing of the game display (50% - 100%).
class _ScreenScaleSelector extends StatelessWidget {
  final double currentScale;
  final void Function(double scale) onScaleChanged;

  const _ScreenScaleSelector({
    required this.currentScale,
    required this.onScaleChanged,
  });

  static const List<double> scales = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0];

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.surfaceLight, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fit_screen, color: colors.textSecondary, size: 18),
              const SizedBox(width: 8),
              Text(
                'Screen Size',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${(currentScale * 100).round()}%',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: colors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: scales.map((scale) {
              final isSelected = (currentScale - scale).abs() < 0.01;
              final isLast = scale == scales.last;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: isLast ? 0 : 4),
                  child: GestureDetector(
                    onTap: () => onScaleChanged(scale),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? colors.accent : colors.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected
                              ? colors.accent
                              : colors.surfaceLight,
                          width: 1,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '${(scale * 100).round()}%',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected
                                ? colors.backgroundDark
                                : colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _SpeedSelector extends StatelessWidget {
  final double currentSpeed;
  final void Function(double speed) onSpeedChanged;

  const _SpeedSelector({
    required this.currentSpeed,
    required this.onSpeedChanged,
  });

  static const List<double> speeds = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0];

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final isTV = TvDetector.isTV;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.surfaceLight, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed, color: colors.textSecondary, size: 18),
              const SizedBox(width: 8),
              Text(
                'Speed',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                _formatSpeedLabel(currentSpeed),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: colors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // On TV: two rows of 3 buttons so D-pad can navigate both
          // horizontally (within a row) and vertically (between rows).
          // On phone: original single row.
          if (isTV) ...[
            _buildSpeedRow(
              context,
              colors,
              speeds.sublist(0, 3),
              isFirst: true,
            ),
            const SizedBox(height: 4),
            _buildSpeedRow(
              context,
              colors,
              speeds.sublist(3, 6),
              isFirst: false,
            ),
          ] else
            _buildSpeedRow(context, colors, speeds, isFirst: true),
        ],
      ),
    );
  }

  Widget _buildSpeedRow(
    BuildContext context,
    dynamic colors,
    List<double> rowSpeeds, {
    required bool isFirst,
  }) {
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Row(
        children: rowSpeeds.map((speed) {
          final isSelected = (currentSpeed - speed).abs() < 0.01;
          final isLast = speed == rowSpeeds.last;
          return Expanded(
            child: TvFocusable(
              onTap: () => onSpeedChanged(speed),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                margin: EdgeInsets.only(right: isLast ? 0 : 4),
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: isSelected ? colors.primary : colors.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: isSelected
                      ? null
                      : Border.all(color: colors.surfaceLight),
                ),
                child: Center(
                  child: Text(
                    _formatSpeedLabel(speed),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? colors.textPrimary : colors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Shortcuts help dialog
// ═══════════════════════════════════════════════════════════════════════

class _ShortcutsHelpDialog extends StatelessWidget {
  final GamePlatform platform;

  const _ShortcutsHelpDialog({required this.platform});

  void _dismiss(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final maxDialogWidth = MediaQuery.of(context).size.width * 0.9;
    final isGenesis = platform == GamePlatform.md;
    final modifier = isGenesis ? 'Mode' : 'Select';
    final quickSaveButton = isGenesis ? 'B' : 'A';
    final quickLoadButton = isGenesis ? 'C' : 'B';
    final fastForwardButton = isGenesis ? 'Z' : 'R1';
    final tapAction = isGenesis ? 'Genesis Mode button' : 'GBA Select button';

    // Wrap in Focus so ANY key press (gamepad, remote, keyboard) dismisses it.
    // Also wrap in GestureDetector so tapping anywhere outside the card works.
    return Focus(
      autofocus: true,
      onKeyEvent: (_, _) {
        _dismiss(context);
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _dismiss(context),
        child: AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: colors.accent.withAlpha(100), width: 2),
          ),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          title: Row(
            children: [
              Icon(Icons.keyboard, color: colors.accent, size: 22),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Shortcuts',
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
            width: maxDialogWidth < 340 ? maxDialogWidth : 340,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sectionHeader(
                    context,
                    Icons.gamepad,
                    'Gamepad combos  (hold $modifier +)',
                  ),
                  _shortcutRow(context, '$modifier + Start', 'Pause menu'),
                  _shortcutRow(
                    context,
                    '$modifier + $quickSaveButton',
                    'Quick save (slot 1)',
                  ),
                  _shortcutRow(
                    context,
                    '$modifier + $quickLoadButton',
                    'Quick load (slot 1)',
                  ),
                  _shortcutRow(
                    context,
                    '$modifier + $fastForwardButton',
                    'Fast forward',
                  ),
                  _shortcutRow(context, '$modifier (tap)', tapAction),
                  const SizedBox(height: 14),
                  _sectionHeader(
                    context,
                    Icons.keyboard_alt_outlined,
                    'Keyboard',
                  ),
                  _shortcutRow(context, 'F1', 'Pause menu'),
                  _shortcutRow(context, 'F5', 'Quick save (slot 1)'),
                  _shortcutRow(context, 'F9', 'Quick load (slot 1)'),
                  _shortcutRow(context, 'Tab', 'Fast forward'),
                  _shortcutRow(context, 'Esc', 'Toggle pause menu'),
                  const SizedBox(height: 14),
                  _sectionHeader(context, Icons.tv, 'TV / Remote'),
                  _shortcutRow(context, 'Back', 'Pause menu'),
                  _shortcutRow(context, 'L1 / R1', 'Switch tabs (home)'),
                  const SizedBox(height: 8),
                  Divider(color: colors.surfaceLight),
                  const SizedBox(height: 4),
                  Text(
                    'Press any button to dismiss.  '
                    'Open anytime from pause menu → Shortcuts.',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.textMuted,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, IconData icon, String text) {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: colors.accent.withAlpha(180), size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: colors.accent,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shortcutRow(BuildContext context, String keys, String action) {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: colors.backgroundLight,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colors.surfaceLight),
            ),
            child: Text(
              keys,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: colors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              action,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _InputTypeSelector extends StatelessWidget {
  final bool useJoystick;
  final VoidCallback onChanged;

  const _InputTypeSelector({
    required this.useJoystick,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.backgroundLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.surfaceLight, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gamepad, color: colors.textSecondary, size: 18),
              const SizedBox(width: 8),
              Text(
                'Input Type',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // D-Pad option
              Expanded(
                child: TvFocusable(
                  onTap: useJoystick ? onChanged : null,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: !useJoystick ? colors.primary : colors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: !useJoystick
                          ? null
                          : Border.all(color: colors.surfaceLight),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.control_camera,
                          size: 18,
                          color: !useJoystick
                              ? colors.textPrimary
                              : colors.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'D-Pad',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: !useJoystick
                                ? colors.textPrimary
                                : colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Joystick option
              Expanded(
                child: TvFocusable(
                  onTap: !useJoystick ? onChanged : null,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: useJoystick ? colors.primary : colors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: useJoystick
                          ? null
                          : Border.all(color: colors.surfaceLight),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.radio_button_checked,
                          size: 18,
                          color: useJoystick
                              ? colors.textPrimary
                              : colors.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Joystick',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: useJoystick
                                ? colors.textPrimary
                                : colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Link Cable Dialog
// ═══════════════════════════════════════════════════════════════

class _LinkCableDialog extends StatefulWidget {
  final GameRom game;
  final LinkCableService linkCable;
  final bool isSupported;

  const _LinkCableDialog({
    required this.game,
    required this.linkCable,
    required this.isSupported,
  });

  @override
  State<_LinkCableDialog> createState() => _LinkCableDialogState();
}

class _LinkCableDialogState extends State<_LinkCableDialog> {
  final TextEditingController _ipController = TextEditingController();
  List<String> _localIPs = [];
  bool _isBusy = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    widget.linkCable.addListener(_onLinkStateChanged);
    _loadLocalIPs();
  }

  @override
  void dispose() {
    widget.linkCable.removeListener(_onLinkStateChanged);
    _ipController.dispose();
    super.dispose();
  }

  void _onLinkStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadLocalIPs() async {
    final ips = await widget.linkCable.getLocalIPs();
    if (mounted) {
      setState(() => _localIPs = ips);
    }
  }

  Future<void> _host() async {
    setState(() {
      _isBusy = true;
      _statusMessage = 'Starting server...';
    });

    final hash = await LinkCableService.computeRomHash(widget.game.path);
    final ok = await widget.linkCable.host(romHash: hash);

    if (mounted) {
      setState(() {
        _isBusy = false;
        _statusMessage = ok
            ? 'Waiting for player 2...'
            : widget.linkCable.error;
      });
    }
  }

  Future<void> _join() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) {
      setState(() => _statusMessage = 'Enter the host\'s IP address');
      return;
    }

    setState(() {
      _isBusy = true;
      _statusMessage = 'Connecting to $ip...';
    });

    final hash = await LinkCableService.computeRomHash(widget.game.path);
    final ok = await widget.linkCable.join(hostAddress: ip, romHash: hash);

    if (mounted) {
      setState(() {
        _isBusy = false;
        _statusMessage = ok ? null : widget.linkCable.error;
      });
    }
  }

  Future<void> _disconnect() async {
    await widget.linkCable.disconnect();
    if (mounted) {
      setState(() => _statusMessage = 'Disconnected');
    }
  }

  void _showIpInputDialog() {
    final colors = AppColorTheme.of(context);
    final controller = TextEditingController(text: _ipController.text);
    final focusNode = FocusNode();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (focusNode.canRequestFocus) focusNode.requestFocus();
    });
    Future.delayed(const Duration(milliseconds: 150), () {
      if (focusNode.canRequestFocus) focusNode.requestFocus();
    });

    showDialog<void>(
      context: context,
      builder: (ctx) {
        void applyAndClose() {
          _ipController.text = controller.text;
          Navigator.of(ctx).pop();
          setState(() {});
        }

        return AlertDialog(
          backgroundColor: colors.surface,
          title: const Text('Host IP Address'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'e.g. 192.168.1.5',
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => applyAndClose(),
              ),
              const SizedBox(height: 8),
              Text(
                'Press Select to open keyboard, then Join',
                style: TextStyle(fontSize: 12, color: colors.textMuted),
              ),
            ],
          ),
          actions: [
            TvFocusable(
              onTap: () => Navigator.of(ctx).pop(),
              borderRadius: BorderRadius.circular(8),
              child: TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: colors.textMuted),
                ),
              ),
            ),
            TvFocusable(
              onTap: applyAndClose,
              borderRadius: BorderRadius.circular(8),
              child: FilledButton(
                onPressed: applyAndClose,
                child: const Text('OK'),
              ),
            ),
          ],
        );
      },
    ).then((_) {
      controller.dispose();
      focusNode.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final state = widget.linkCable.state;
    final isConnected = state == LinkCableState.connected;
    final maxDialogWidth = MediaQuery.of(context).size.width * 0.9;

    return Focus(
      // Catch back/B button to close the dialog from anywhere inside it
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.goBack ||
                event.logicalKey == LogicalKeyboardKey.browserBack ||
                event.logicalKey == LogicalKeyboardKey.gameButtonB)) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.primary.withAlpha(77), width: 2),
          ),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          title: Row(
            children: [
              Icon(Icons.cable, color: colors.accent, size: 22),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Link Cable',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
              const Spacer(),
              if (isConnected)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withAlpha(40),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${widget.linkCable.latencyMs}ms',
                        style: const TextStyle(
                          color: Colors.green,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          content: SizedBox(
            width: maxDialogWidth < 320 ? maxDialogWidth : 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status / error message
                if (_statusMessage != null || widget.linkCable.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      widget.linkCable.error ?? _statusMessage ?? '',
                      style: TextStyle(
                        color: widget.linkCable.error != null
                            ? colors.error
                            : colors.accent,
                        fontSize: 13,
                      ),
                    ),
                  ),

                if (isConnected) ...[
                  _buildConnectedView(),
                ] else if (state == LinkCableState.hosting) ...[
                  _buildHostingView(),
                ] else if (state == LinkCableState.joining) ...[
                  _buildJoiningView(),
                ] else ...[
                  _buildDisconnectedView(),
                ],
              ],
            ),
          ),
          actions: [
            if (isConnected || state == LinkCableState.hosting)
              TvFocusable(
                onTap: _isBusy ? null : _disconnect,
                borderRadius: BorderRadius.circular(8),
                child: TextButton(
                  onPressed: _isBusy ? null : _disconnect,
                  child: Text(
                    'Disconnect',
                    style: TextStyle(color: colors.error),
                  ),
                ),
              ),
            TvFocusable(
              autofocus: isConnected || state != LinkCableState.disconnected,
              onTap: () => Navigator.pop(context),
              borderRadius: BorderRadius.circular(8),
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  isConnected ? 'Done' : 'Close',
                  style: TextStyle(color: colors.textMuted),
                ),
              ),
            ),
          ],
        ), // AlertDialog
      ), // FocusTraversalGroup
    ); // Focus
  }

  Widget _buildDisconnectedView() {
    final colors = AppColorTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Connect two devices over Wi-Fi to trade, battle, or play '
          'multiplayer games using the virtual link cable.',
          style: TextStyle(color: colors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),

        // Host button
        SizedBox(
          width: double.infinity,
          child: TvFocusable(
            autofocus: true,
            onTap: _isBusy ? null : _host,
            borderRadius: BorderRadius.circular(10),
            child: ElevatedButton.icon(
              onPressed: _isBusy ? null : _host,
              icon: const Icon(Icons.wifi_tethering, size: 18),
              label: const Text('Host Game'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: colors.textPrimary,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // OR divider
        Row(
          children: [
            Expanded(child: Divider(color: colors.surfaceLight)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'OR',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
            Expanded(child: Divider(color: colors.surfaceLight)),
          ],
        ),
        const SizedBox(height: 12),

        // Join section — on TV use button + dialog so TextField can trigger keyboard
        if (TvDetector.isTV)
          TvFocusable(
            onTap: _showIpInputDialog,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: colors.backgroundLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.link, size: 20, color: colors.textMuted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _ipController.text.isEmpty
                          ? 'Enter IP address... (Press Select)'
                          : _ipController.text,
                      style: TextStyle(
                        color: _ipController.text.isEmpty
                            ? colors.textMuted
                            : colors.textPrimary,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          TextField(
            controller: _ipController,
            style: TextStyle(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Host IP address (e.g. 192.168.1.5)',
              hintStyle: TextStyle(color: colors.textMuted, fontSize: 13),
              filled: true,
              fillColor: colors.backgroundLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
            keyboardType: TextInputType.number,
          ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: TvFocusable(
            onTap: _isBusy ? null : _join,
            borderRadius: BorderRadius.circular(10),
            child: ElevatedButton.icon(
              onPressed: _isBusy ? null : _join,
              icon: const Icon(Icons.link, size: 18),
              label: const Text('Join Game'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.textPrimary,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildHostingView() {
    final colors = AppColorTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your IP Address:',
          style: TextStyle(color: colors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 6),
        for (final ip in _localIPs)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.backgroundLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                '$ip : ${LinkCableService.defaultPort}',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        if (_localIPs.isEmpty)
          Text(
            'Unable to detect IP address',
            style: TextStyle(color: colors.error, fontSize: 13),
          ),
        const SizedBox(height: 12),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Waiting for player 2 to join...',
                style: TextStyle(color: colors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildJoiningView() {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: colors.accent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Connecting...',
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectedView() {
    final colors = AppColorTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.withAlpha(20),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green.withAlpha(60)),
          ),
          child: Column(
            children: [
              const Icon(Icons.link, color: Colors.green, size: 32),
              const SizedBox(height: 8),
              Text(
                'Link Cable Connected',
                style: TextStyle(
                  color: Colors.green.shade300,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Connected to ${widget.linkCable.peerAddress}',
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Resume the game to use link cable features like trading and battling.',
          style: TextStyle(color: colors.textSecondary, fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Top toast for RA status messages
// ═══════════════════════════════════════════════════════════════════════

/// An animated top-of-screen toast with optional image and subtitle,
/// used for RetroAchievements status messages (achievement counts, etc.).
class _RATopToast extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final IconData icon;
  final Color accentColor;
  final VoidCallback onDismissed;
  final Duration duration;

  const _RATopToast({
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.icon = Icons.emoji_events,
    this.accentColor = Colors.amber,
    required this.onDismissed,
    this.duration = const Duration(seconds: 4),
  });

  @override
  State<_RATopToast> createState() => _RATopToastState();
}

class _RATopToastState extends State<_RATopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _slideAnim = Tween<Offset>(begin: const Offset(0, -1.5), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        );

    _fadeAnim = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));

    _run();
  }

  Future<void> _run() async {
    try {
      await _controller.forward();
      await Future.delayed(widget.duration);
      if (!mounted) return;
      await _controller.reverse();
      widget.onDismissed();
    } catch (e) {
      // AnimationController may be disposed if the game screen exits
      // while the toast is still visible — log for diagnostics.
      debugPrint(
        '_RATopToast: animation error (likely disposed during exit) — $e',
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final safeTop = MediaQuery.of(context).padding.top;
    final hasImage = widget.imageUrl != null && widget.imageUrl!.isNotEmpty;

    return Positioned(
      top: safeTop + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colors.surface.withAlpha(240),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: widget.accentColor.withAlpha(120),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.accentColor.withAlpha(60),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                  BoxShadow(
                    color: Colors.black.withAlpha(100),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Image or icon
                  if (hasImage)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        widget.imageUrl!,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          widget.icon,
                          color: widget.accentColor,
                          size: 28,
                        ),
                      ),
                    )
                  else
                    Icon(widget.icon, color: widget.accentColor, size: 28),
                  const SizedBox(width: 10),

                  // Text content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: colors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle!,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.textMuted,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
