import 'dart:async';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../models/game_rom.dart';
import '../models/system_filter.dart';
import '../services/cover_art_service.dart';
import '../services/game_library_service.dart';
import '../services/emulator_service.dart';
import '../services/retro_achievements_service.dart';
import '../services/rom_folder_service.dart';

import '../services/save_backup_service.dart';
import '../utils/tv_detector.dart';
import '../widgets/banner_ad_widget.dart';
import '../widgets/game_card.dart';
import '../widgets/import_progress_dialog.dart';
import '../widgets/tv_http_upload_dialog.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/rom_folder_setup_dialog.dart';
import '../widgets/whats_new_dialog.dart';
import '../services/settings_service.dart';
import '../services/whats_new_service.dart';
import '../utils/theme.dart';
import 'achievements_screen.dart';
import 'game_screen.dart';
import 'settings_screen.dart';

/// Sort options for the game library
enum GameSortOption {
  nameAsc('Name (A-Z)', Icons.sort_by_alpha),
  nameDesc('Name (Z-A)', Icons.sort_by_alpha),
  lastPlayed('Last Played', Icons.history),
  mostPlayed('Most Played', Icons.timer),
  platform('Platform', Icons.devices),
  sizeAsc('Size (Small)', Icons.straighten),
  sizeDesc('Size (Large)', Icons.straighten);

  final String label;
  final IconData icon;
  const GameSortOption(this.label, this.icon);
}

/// Main home screen with game library
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _deviceChannel = MethodChannel(
    'com.yourmateapps.retropal/device',
  );

  late TabController _tabController;
  SystemFilter _selectedSystem = SystemFilter.all;
  String _searchQuery = '';
  late bool _isGridView;
  late GameSortOption _sortOption;
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  Timer? _romSetupFallbackTimer;
  bool _romSetupDialogAttempted = false;
  bool _whatsNewAttempted = false;

  /// Index of the last focused game card so we can restore focus after
  /// navigating away (settings, game screen) and coming back.
  int _lastFocusedGameIndex = 0;

  /// Tab index when the last game card was focused. Restore only when
  /// we're on the same tab (All=0, Recent=1, Favorites=2).
  int _lastFocusedTabIndex = 0;

  /// Whether we should restore focus to [_lastFocusedGameIndex] on the
  /// next build (set to true after returning from a pushed route).
  bool _shouldRestoreFocus = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addObserver(this);

    _searchFocusNode = FocusNode(
      debugLabel: 'SearchFocusNode',
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (!TvDetector.isTV) return KeyEventResult.ignored;

        // Open the virtual keyboard on Select/Enter
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          SystemChannels.textInput.invokeMethod('TextInput.show');
          return KeyEventResult.handled;
        }

        // Close keyboard on B/Back/Escape
        if (event.logicalKey == LogicalKeyboardKey.gameButtonB ||
            event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.goBack ||
            event.logicalKey == LogicalKeyboardKey.browserBack) {
          SystemChannels.textInput.invokeMethod('TextInput.hide');
          // Allow the key to bubble up so we can also navigate away or let the app handle back routing
          return KeyEventResult.ignored;
        }

        // Traverse away from text input since native text-input swallows D-pad Left/Right
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          node.focusInDirection(TraversalDirection.right);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          node.focusInDirection(TraversalDirection.left);
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
    );

    // Restore persisted view preferences
    final settings = context.read<SettingsService>().settings;
    _isGridView = settings.isGridView;
    _sortOption = GameSortOption.values.firstWhere(
      (o) => o.name == settings.sortOption,
      orElse: () => GameSortOption.nameAsc,
    );

    // Check if the app was opened via a file intent
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkIncomingFile());
    // Encourage ROM folder setup on first launch.
    // Use a fast path + fallback so slow debug runs on Android TV still
    // surface visible UI quickly and don't feel "stuck".
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShowRomFolderSetup(),
    );
    _romSetupFallbackTimer = Timer(
      const Duration(seconds: 2),
      _maybeShowRomFolderSetup,
    );
    // AdMob is initialized in SplashScreen before HomeScreen loads.
  }

  Future<void> _maybeShowRomFolderSetup() async {
    if (!mounted || _romSetupDialogAttempted) return;
    _romSetupDialogAttempted = true;

    final settingsService = context.read<SettingsService>();
    // Ensure provider is created early, but don't block dialog visibility on
    // library readiness (can be slow in debug/TV environments).
    context.read<GameLibraryService>();

    // Settings should usually be ready quickly; keep a hard cap so startup UI
    // is not delayed indefinitely on slow devices. On Android TV, avoid this
    // wait entirely: startup ANRs on Sony/MediaTek TVs happen while Android is
    // still waiting for a focused window, and the upload prompt can use the
    // default empty folder setting until the async settings load catches up.
    if (!TvDetector.isTV) {
      try {
        await settingsService.whenLoaded.timeout(const Duration(seconds: 3));
      } catch (_) {
        // Timeout/error fallback: continue to one-time flag check below.
      }
    }
    if (!mounted) return;

    try {
      final folderUri = settingsService.settings.userRomsFolderUri;
      final hasFolder = await RomFolderService.hasUsableFolder(folderUri);

      // On TV, ROMs are loaded via the built-in HTTP server — no need for a
      // folder setup dialog when the library already has at least one game.
      if (!mounted) return;
      final library = context.read<GameLibraryService>();
      if (TvDetector.isTV && library.games.isNotEmpty) {
        debugPrint(
          'HomeScreen: TV with ${library.games.length} ROMs — skipping setup dialog',
        );
        return;
      }

      final needsSetupDialog = !hasFolder;
      if (!mounted) return;
      debugPrint(
        'HomeScreen: ROM setup check => hasFolder=$hasFolder, '
        'folderValue=${folderUri == null || folderUri.trim().isEmpty ? '<empty>' : '<set>'}',
      );
      if (needsSetupDialog) {
        await maybeShowRomFolderSetupDialog(context);
      }
    } catch (e) {
      debugPrint('HomeScreen: failed to evaluate ROM setup prompt — $e');
      // Allow fallback timer/retry path to run again.
      _romSetupDialogAttempted = false;
    }

    // After the ROM-folder check resolves, surface the What's New dialog. This
    // is a no-op unless the installed version has notes the user hasn't seen
    // AND the library already contains ROMs (the "already set up" case). On an
    // empty library it does nothing here; a subsequent import will trigger it
    // instead. Running it here keeps it from stacking on the ROM-setup dialog.
    if (mounted) {
      await _maybeShowWhatsNew();
    }
  }

  /// Shows the What's New dialog at most once per launch, and only when:
  ///   • the installed app version has unseen release notes
  ///     (see [WhatsNewService]), AND
  ///   • the library actually contains ROMs — either they were already set up
  ///     before this launch, or the user has just added some.
  ///
  /// We never surface release notes on a brand-new, empty install before the
  /// user has any games. This method is safe to call from multiple places
  /// (startup + after each ROM import): the per-version bookkeeping in
  /// [WhatsNewService] and the [_whatsNewAttempted] one-shot guard keep it to a
  /// single appearance.
  Future<void> _maybeShowWhatsNew() async {
    if (!mounted || _whatsNewAttempted) return;

    // Require a non-empty library. Deliberately do NOT consume the one-shot
    // guard here, so that if the library is still empty at startup a later ROM
    // import in the same session can re-enter and trigger the dialog.
    final library = context.read<GameLibraryService>();
    if (library.games.isEmpty) return;

    _whatsNewAttempted = true;

    final entry = await WhatsNewService.pendingEntry();
    if (entry == null || !mounted) return;

    await showWhatsNewDialog(context, entry);
    await WhatsNewService.markCurrentVersionShown();
  }

  final FocusNode _keyFocusNode = FocusNode();

  /// Focus node for the tab bar — used to move focus from game list to tabs.
  final FocusNode _tabBarFocusNode = FocusNode();

  /// Focus node for the search bar — used to move focus from game list to header.
  late final FocusNode _searchFocusNode;

  /// Focus scope for the header/action bar — search, filter, sort buttons.
  final FocusScopeNode _headerFocusNode = FocusScopeNode();

  /// Focus scope for the game list area. Uses FocusScope so empty-state
  /// buttons (Add ROMs, Add Folder) receive D-pad focus instead of the
  /// scope itself — required for Android TV App Quality Guidelines.
  final FocusScopeNode _gameListFocusNode = FocusScopeNode();

  /// Debounced search update — waits 300ms after the last keystroke.
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _searchQuery = value);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _romSetupFallbackTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _searchController.dispose();
    _keyFocusNode.dispose();
    _tabBarFocusNode.dispose();
    _searchFocusNode.dispose();
    _headerFocusNode.dispose();
    _gameListFocusNode.dispose();
    super.dispose();
  }

  /// Gamepad L1 / R1 bumpers switch tabs, B / Back refocuses game list.
  /// UP arrow at top of game list moves focus to action bar.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // UP arrow - if in top row of game list, move to header/action bar
    if (key == LogicalKeyboardKey.arrowUp) {
      final primary = FocusManager.instance.primaryFocus;
      final inGameList =
          primary != null && primary.nearestScope == _gameListFocusNode;
      if (inGameList) {
        // Calculate columns in grid using the same values as the grid delegate.
        // Subtract the SafeArea/overscan insets the grid sits inside (on TV the
        // root injects ~24px of overscan padding that SafeArea consumes before
        // the sliver gets its width) so the column count matches what's drawn.
        final mq = MediaQuery.of(context);
        final screenWidth = mq.size.width;
        final isTv = TvDetector.isTV;
        final extent = isTv ? 224.0 : 220.0;
        final spacing = isTv ? 20.0 : 12.0;
        final pad = isTv ? 24.0 : 16.0;
        final availableWidth = screenWidth - mq.padding.horizontal - (pad * 2);

        // Mirror Flutter's SliverGridDelegateWithMaxCrossAxisExtent exactly:
        //   crossAxisCount = ceil(crossAxisExtent / (maxCrossAxisExtent + spacing))
        // so the "top row → header" check lines up with the real grid.
        int columns = (availableWidth / (extent + spacing)).ceil();
        if (columns < 1) columns = 1;

        final isInTopRow = _lastFocusedGameIndex < columns;

        if (isInTopRow) {
          // Move focus to search bar in header
          _searchFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
      }
    }

    // DOWN arrow - if in header/action bar, move focus to game list
    if (key == LogicalKeyboardKey.arrowDown) {
      final primary = FocusManager.instance.primaryFocus;
      final inHeader =
          primary != null && primary.nearestScope == _headerFocusNode;
      if (inHeader) {
        _gameListFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
    }

    // L1 / PageUp / Channel Up / Rewind → previous tab
    if (key == LogicalKeyboardKey.gameButtonLeft1 ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.f1) {
      final newIndex = (_tabController.index - 1).clamp(
        0,
        _tabController.length - 1,
      );
      if (newIndex != _tabController.index) {
        _tabController.animateTo(newIndex);
      }
      return KeyEventResult.handled;
    }
    // R1 / PageDown / Channel Down / Fast Forward → next tab
    if (key == LogicalKeyboardKey.gameButtonRight1 ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.f2) {
      final newIndex = (_tabController.index + 1).clamp(
        0,
        _tabController.length - 1,
      );
      if (newIndex != _tabController.index) {
        _tabController.animateTo(newIndex);
      }
      return KeyEventResult.handled;
    }
    // B / Back / Escape → refocus the game list when in header/tabs,
    // or show exit confirmation when already in the game list (TV requirement).
    if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      final primary = FocusManager.instance.primaryFocus;
      final inGameList =
          primary != null && primary.nearestScope == _gameListFocusNode;
      if (!inGameList) {
        _gameListFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      // Let the back button exit the app by returning ignored
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Check again when app is resumed (e.g. user opened another file while app was in background)
    if (state == AppLifecycleState.resumed) {
      _checkIncomingFile();
    }
  }

  /// Check if the app was opened via a VIEW intent with a ROM file path.
  /// If so, add it to the library and launch it immediately.
  /// Also handles ZIP files by extracting ROMs and importing them.
  Future<void> _checkIncomingFile() async {
    try {
      final path = await _deviceChannel.invokeMethod<String>('getOpenFilePath');
      if (path == null || path.isEmpty || !mounted) return;

      final library = context.read<GameLibraryService>();

      // ── Handle ZIP files: extract ROMs and import ──
      if (path.toLowerCase().endsWith('.zip')) {
        List<GameRom> games;
        try {
          games = await library.importRomZip(path);
        } on ArchiveException catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(
                const SnackBar(
                  content: Text(
                    'Failed to extract ZIP — file may be corrupted',
                  ),
                ),
              );
          }
          return;
        }
        if (!mounted) return;

        if (games.isNotEmpty) {
          // Auto-download cover art for newly imported ROMs
          _autoFetchCovers(games, library);

          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  'Imported ${games.length} ROM${games.length == 1 ? '' : 's'} from ZIP',
                ),
                duration: const Duration(seconds: 2),
              ),
            );

          // Launch the first game if only one was imported. When more than one
          // arrived we stay on Home, so surface What's New (once per version).
          if (games.length == 1) {
            _launchGame(games.first);
          } else {
            await _maybeShowWhatsNew();
          }
        } else {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              const SnackBar(
                content: Text('No valid ROM files found inside the ZIP.'),
              ),
            );
        }
        return;
      }

      // ── Handle individual ROM files ──
      final game = GameRom.fromPath(path);
      if (game == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text('Unsupported file: $path')));
        }
        return;
      }

      // Add to library if not already there
      await library.addRom(path);

      // Find the game entry (addRom might return null if it already exists)
      final libraryGame = library.games.firstWhere(
        (g) => g.path == path,
        orElse: () => game,
      );

      if (mounted) {
        _launchGame(libraryGame);
      }
    } catch (e) {
      // Channel not available (non-Android) — log for diagnostics
      debugPrint('HomeScreen: TV intent launch failed — $e');
    }
  }

  /// Sort a list of games according to the current sort option
  List<GameRom> _sortGames(List<GameRom> games) {
    final sorted = List<GameRom>.from(games);
    switch (_sortOption) {
      case GameSortOption.nameAsc:
        sorted.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case GameSortOption.nameDesc:
        sorted.sort(
          (a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()),
        );
      case GameSortOption.lastPlayed:
        sorted.sort((a, b) {
          // Games never played go to the bottom
          if (a.lastPlayed == null && b.lastPlayed == null) return 0;
          if (a.lastPlayed == null) return 1;
          if (b.lastPlayed == null) return -1;
          return b.lastPlayed!.compareTo(a.lastPlayed!); // most recent first
        });
      case GameSortOption.mostPlayed:
        sorted.sort(
          (a, b) => b.totalPlayTimeSeconds.compareTo(a.totalPlayTimeSeconds),
        );
      case GameSortOption.platform:
        sorted.sort((a, b) {
          final cmp = a.platformShortName.compareTo(b.platformShortName);
          return cmp != 0
              ? cmp
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
      case GameSortOption.sizeAsc:
        sorted.sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
      case GameSortOption.sizeDesc:
        sorted.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    }
    return sorted;
  }

  /// Show a D-pad / TV-friendly sort dialog instead of PopupMenuButton.
  void _showSortDialog() {
    final colors = AppColorTheme.of(context);
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (dialogContext) {
        final maxDialogWidth = MediaQuery.of(dialogContext).size.width * 0.9;
        return AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.primary.withAlpha(77), width: 2),
          ),
          title: Row(
            children: [
              Icon(Icons.swap_vert, color: colors.accent, size: 22),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Sort by',
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
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: SizedBox(
            width: maxDialogWidth < 300 ? maxDialogWidth : 300,
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: GameSortOption.values.asMap().entries.map((entry) {
                    final index = entry.key;
                    final opt = entry.value;
                    final isSelected = _sortOption == opt;
                    return TvFocusable(
                      autofocus:
                          isSelected ||
                          (index == 0 &&
                              !GameSortOption.values.contains(_sortOption)),
                      onTap: () {
                        setState(() => _sortOption = opt);
                        context.read<SettingsService>().setSortOption(opt.name);
                        Navigator.pop(dialogContext);
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: ListTile(
                        leading: Icon(
                          opt.icon,
                          size: 20,
                          color: isSelected ? colors.accent : null,
                        ),
                        title: Text(
                          opt.label,
                          style: TextStyle(
                            color: isSelected ? colors.accent : null,
                            fontWeight: isSelected ? FontWeight.bold : null,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(Icons.check, size: 18, color: colors.accent)
                            : null,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        dense: true,
                        onTap: () {
                          setState(() => _sortOption = opt);
                          context.read<SettingsService>().setSortOption(
                            opt.name,
                          );
                          Navigator.pop(dialogContext);
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          actions: [
            TvFocusable(
              onTap: () => Navigator.pop(dialogContext),
              borderRadius: BorderRadius.circular(8),
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: colors.textMuted),
                ),
              ),
            ),
          ],
        );
      },
    ).then((_) {
      // Restore focus to the game list on TV after dialog dismissal
      if (mounted) _gameListFocusNode.requestFocus();
    });
  }

  /// D-pad friendly platform filter dialog for TV (replaces DropdownButton).
  void _showPlatformFilterDialog() {
    final colors = AppColorTheme.of(context);
    final platforms = TvDetector.isTV
        ? tvSystemFilterOptions
        : systemFilterOptions;
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (dialogContext) {
        final maxDialogWidth = MediaQuery.of(dialogContext).size.width * 0.9;
        return AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.primary.withAlpha(77), width: 2),
          ),
          title: Row(
            children: [
              Icon(Icons.filter_list, color: colors.accent, size: 22),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Filter by System',
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
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: SizedBox(
            width: maxDialogWidth < 300 ? maxDialogWidth : 300,
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: platforms.map((p) {
                    final isSelected = _selectedSystem == p.value;
                    return TvFocusable(
                      autofocus: isSelected,
                      onTap: () {
                        setState(() => _selectedSystem = p.value);
                        Navigator.pop(dialogContext);
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: ListTile(
                        title: Text(
                          p.label,
                          style: TextStyle(
                            color: isSelected ? colors.accent : null,
                            fontWeight: isSelected ? FontWeight.bold : null,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(Icons.check, size: 18, color: colors.accent)
                            : null,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        dense: true,
                        onTap: () {
                          setState(() => _selectedSystem = p.value);
                          Navigator.pop(dialogContext);
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          actions: [
            TvFocusable(
              onTap: () => Navigator.pop(dialogContext),
              borderRadius: BorderRadius.circular(8),
              child: TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: colors.textMuted),
                ),
              ),
            ),
          ],
        );
      },
    ).then((_) {
      if (mounted) _gameListFocusNode.requestFocus();
    });
  }

  Future<void> _addRomFile() async {
    // On TV, use HTTP upload instead of file picker
    if (TvDetector.isTV) {
      await _showTvHttpUpload();
      return;
    }

    List<String>? paths;
    final zipPaths = <String>{};

    // Phone/tablet: use system file picker (SAF)
    const allowedExtensions = {
      '.gba',
      '.gb',
      '.gbc',
      '.sgb',
      '.nes',
      '.unf',
      '.unif',
      '.sfc',
      '.smc',
      '.sms',
      '.gg',
      '.sg',
      '.md',
      '.gen',
      '.smd',
      '.bin',
      '.pce',
      '.sgx',
      '.cue',
      '.z64',
      '.n64',
      '.v64',
      '.zip',
      '.ngp',
      '.ngc',
      '.ws',
      '.wsc',
      '.a26',
      '.vb',
      '.tic',
      '.p8',
      '.p8.png',
      // Nintendo DS
      '.nds',
      // Mattel Intellivision
      '.int',
      '.itv',
      '.rom',
    };
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);
      if (result != null) {
        for (final f in result.files) {
          if (f.path == null) continue;
          final name = f.name.toLowerCase();
          final dot = name.lastIndexOf('.');
          if (dot == -1) continue;
          final ext = name.endsWith('.p8.png')
              ? '.p8.png'
              : name.substring(dot);
          if (!allowedExtensions.contains(ext)) continue;
          paths ??= [];
          paths.add(f.path!);
          if (ext == '.zip') zipPaths.add(f.path!);
        }
      }
    } catch (e) {
      debugPrint('HomeScreen: file picker failed — $e');
      paths = null;
    }
    if (!mounted) return;
    if (paths != null && paths.isNotEmpty && mounted) {
      final library = context.read<GameLibraryService>();

      // Show a modal progress dialog with the current ROM name + percentage
      // while each file is copied / each archive (e.g. PS1 cue/bin ZIP) is
      // extracted and imported.
      final addedGames = await runFileImportWithProgress(
        context,
        paths: paths,
        zipPaths: zipPaths,
        library: library,
      );

      if (!mounted) return;

      if (addedGames.isNotEmpty && mounted) {
        _tabController.animateTo(0);

        // Auto-download cover art for newly imported ROMs (fire-and-forget).
        _autoFetchCovers(addedGames, library);

        // Restore focus for TV navigation
        if (TvDetector.isTV) {
          setState(() => _shouldRestoreFocus = true);
        }

        // The library now has ROMs — surface What's New (once per version).
        await _maybeShowWhatsNew();
      } else if (mounted) {
        // Let the user know when nothing was imported (e.g. ZIP with no ROMs)
        final hasZip = paths.any((p) => p.toLowerCase().endsWith('.zip'));
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                hasZip
                    ? 'No valid ROM files found inside the ZIP. PS1 ZIPs need a .cue file with its .bin tracks.'
                    : 'No valid ROM files were imported.',
              ),
            ),
          );

        // Restore focus for TV navigation even when no ROMs imported
        if (TvDetector.isTV) {
          setState(() => _shouldRestoreFocus = true);
        }
      }
    }
  }

  Future<void> _addRomFolder() async {
    // On TV, use HTTP upload instead of folder picker
    if (TvDetector.isTV) {
      await _showTvHttpUpload();
      return;
    }

    final library = context.read<GameLibraryService>();
    List<String>? importedPaths;

    // Phone/tablet: use native SAF folder picker
    try {
      final result = await _deviceChannel.invokeMethod<List<dynamic>>(
        'importRomsFromFolder',
      );
      importedPaths = result?.cast<String>();
    } catch (e) {
      debugPrint('HomeScreen: SAF folder import failed — $e');
      importedPaths = null;
    }
    if (!mounted) return;

    if (importedPaths != null && importedPaths.isNotEmpty && mounted) {
      final messenger = ScaffoldMessenger.of(context);

      // Must use the same navigator as [Navigator.pop] below — nested
      // MaterialApp in SplashScreen makes default showDialog use the outer
      // navigator while [Navigator.of(context)] from Home is the inner one,
      // so a mismatched pop can remove [HomeScreen] and leave a black screen.
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(
                    'Importing ${importedPaths!.length} ROM${importedPaths.length == 1 ? '' : 's'}…',
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final addedGames = <GameRom>[];
      try {
        for (final path in importedPaths) {
          if (!mounted) break;
          final game = await library.addRom(path);
          if (game != null) addedGames.add(game);
        }
      } finally {
        if (mounted) {
          final nav = Navigator.of(context, rootNavigator: false);
          if (nav.canPop()) nav.pop();
        }
      }

      if (addedGames.isNotEmpty && mounted) {
        _tabController.animateTo(0);
        _autoFetchCovers(addedGames, library);
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                'Imported ${addedGames.length} ROM${addedGames.length == 1 ? '' : 's'}',
              ),
              duration: const Duration(seconds: 2),
            ),
          );

        // The library now has ROMs — surface What's New (once per version).
        await _maybeShowWhatsNew();
      } else if (mounted) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('No new ROM files found in selected folder'),
              duration: Duration(seconds: 2),
            ),
          );
      }
    } else if (importedPaths != null && importedPaths.isEmpty && mounted) {
      // User selected folder via SAF but it was empty
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('No ROM files found in selected folder'),
            duration: Duration(seconds: 2),
          ),
        );
    }
    // When importedPaths == null: user cancelled SAF picker — no message
  }

  /// Navigate to settings and restore game list focus on return.
  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())).then((_) {
      if (mounted) setState(() => _shouldRestoreFocus = true);
    });
  }

  void _launchGame(GameRom game) async {
    final emulator = context.read<EmulatorService>();
    final library = context.read<GameLibraryService>();
    final settingsService = context.read<SettingsService>();
    final raService = context.read<RetroAchievementsService>();
    try {
      await settingsService.whenLoaded;
    } catch (_) {}
    if (!mounted) return;
    final settings = settingsService.settings;

    // Update last played
    await library.updateLastPlayed(game);

    // Start RA achievement session in parallel with ROM loading.
    // This kicks off hash computation + game ID lookup + achievement data
    // fetch so they're already in progress (or cached) by the time the
    // game screen's _detectRetroAchievements() runs.
    if (settings.raEnabled && raService.isLoggedIn) {
      // Fire-and-forget — don't block ROM loading
      raService.startGameSession(game);
    }

    // loadRom() needs the folder setting before melonDS opens the cartridge,
    // because melonDS reads .sav files inside retro_load_game().
    emulator.updateSettings(settings);

    // Load ROM
    final success = await emulator.loadRom(game);

    if (success && mounted) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => GameScreen(game: game)))
          .then((_) {
            if (mounted) setState(() => _shouldRestoreFocus = true);
          });
    } else if (mounted) {
      final error = emulator.errorMessage;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(error ?? 'Failed to load ${game.name}'),
            backgroundColor: AppColorTheme.of(context).error,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Focus(
      focusNode: _keyFocusNode,
      onKeyEvent: _onKeyEvent,
      autofocus: true,
      child: Scaffold(
        body: SafeArea(
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
              children: [
                // In landscape, combine header elements into a single row
                if (isLandscape)
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(0),
                    child: FocusScope(
                      node: _headerFocusNode,
                      child: _buildCompactHeader(),
                    ),
                  )
                else ...[
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(0),
                    child: FocusScope(
                      node: _headerFocusNode,
                      child: Column(
                        children: [
                          _buildHeader(),
                          _buildSearchBar(),
                          _buildPlatformFilter(),
                        ],
                      ),
                    ),
                  ),
                ],
                FocusTraversalOrder(
                  order: const NumericFocusOrder(3),
                  child: _buildTabBar(),
                ),
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(4),
                    child: FocusScope(
                      node: _gameListFocusNode,
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildAllGames(),
                          _buildRecentGames(),
                          _buildFavorites(),
                        ],
                      ),
                    ),
                  ),
                ),
                // TV bumper hint bar
                if (TvDetector.isTV) _buildTvHintBar(),
                // Banner ad at bottom (mobile only, not during gameplay)
                const BannerAdWidget(),
              ],
            ),
          ),
        ),
        // On TV don't show FAB (focus gets stuck on it) — TV has
        // Add ROM buttons in the header and empty-state instead.
        floatingActionButton: TvDetector.isTV ? null : _buildFAB(),
      ),
    );
  }

  /// Compact header for landscape mode - combines logo, search, filter in one row
  Widget _buildCompactHeader() {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Logo
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/images/app_icon.png',
              width: 36,
              height: 36,
            ),
          ),
          const SizedBox(width: 12),

          // Search bar - expanded
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _searchController,
                focusNode: TvDetector.isTV ? _searchFocusNode : null,
                onChanged: _onSearchChanged,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search...',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  prefixIcon: Icon(
                    Icons.search,
                    color: colors.textMuted,
                    size: 20,
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? TvFocusable(
                          onTap: () {
                            _searchDebounce?.cancel();
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: IconButton(
                            icon: Icon(
                              Icons.clear,
                              color: colors.textMuted,
                              size: 18,
                            ),
                            onPressed: () {
                              _searchDebounce?.cancel();
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Platform filter — dialog on TV (D-pad safe), dropdown on phone
          if (TvDetector.isTV)
            TvFocusable(
              onTap: _showPlatformFilterDialog,
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 230,
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.filter_list,
                        color: colors.textMuted,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _selectedSystem.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.arrow_drop_down,
                        color: colors.textMuted,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Focus(
              child: Builder(
                builder: (context) {
                  final focused = Focus.of(context).hasFocus;
                  return SizedBox(
                    width: 250,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: focused
                            ? Border.all(color: colors.accent, width: 2)
                            : null,
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<SystemFilter>(
                          value: _selectedSystem,
                          isExpanded: true,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textPrimary,
                          ),
                          dropdownColor: colors.surface,
                          items:
                              (TvDetector.isTV
                                      ? tvSystemFilterOptions
                                      : systemFilterOptions)
                                  .map(
                                    (option) => DropdownMenuItem<SystemFilter>(
                                      value: option.value,
                                      child: Text(
                                        option.label,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) => value == null
                              ? null
                              : setState(() => _selectedSystem = value),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(width: 8),

          // Sort button — uses dialog instead of PopupMenuButton for TV D-pad support
          TvFocusable(
            onTap: _showSortDialog,
            borderRadius: BorderRadius.circular(8),
            child: IconButton(
              icon: Icon(
                Icons.swap_vert,
                color: colors.textSecondary,
                size: 20,
              ),
              tooltip: 'Sort by',
              onPressed: _showSortDialog,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ),

          // View toggle
          TvFocusable(
            onTap: () {
              setState(() => _isGridView = !_isGridView);
              context.read<SettingsService>().setGridView(_isGridView);
            },
            borderRadius: BorderRadius.circular(8),
            child: IconButton(
              icon: Icon(
                _isGridView ? Icons.view_list : Icons.grid_view,
                color: colors.textSecondary,
                size: 20,
              ),
              onPressed: () {
                setState(() => _isGridView = !_isGridView);
                context.read<SettingsService>().setGridView(_isGridView);
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ),

          // On TV: direct focusable buttons (popup menus are hard with D-pad)
          if (TvDetector.isTV) ...[
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFile,
              child: IconButton(
                icon: Icon(Icons.add, color: colors.accent, size: 20),
                tooltip: 'Add ROMs',
                onPressed: _addRomFile,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFolder,
              child: IconButton(
                icon: Icon(
                  Icons.create_new_folder,
                  color: colors.accent,
                  size: 20,
                ),
                tooltip: 'Add Folder',
                onPressed: _addRomFolder,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _openSettings,
              child: IconButton(
                icon: Icon(
                  Icons.settings_outlined,
                  color: colors.textSecondary,
                  size: 20,
                ),
                tooltip: 'Settings',
                onPressed: _openSettings,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
          ] else ...[
            // More menu (phone/tablet compact) — Settings + Download All Cover Art
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert,
                color: colors.textSecondary,
                size: 20,
              ),
              tooltip: 'More options',
              color: colors.surface,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onSelected: (value) {
                switch (value) {
                  case 'settings':
                    _openSettings();
                  case 'download_all_covers':
                    _downloadAllCoverArt();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'download_all_covers',
                  child: ListTile(
                    leading: Icon(Icons.download),
                    title: Text('Download All Cover Art'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'settings',
                  child: ListTile(
                    leading: Icon(Icons.settings_outlined),
                    title: Text('Settings'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          // Logo/Title
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: colors.primary.withAlpha(102),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/images/app_icon.png',
                      width: 44,
                      height: 44,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'RetroPal',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: colors.textPrimary,
                          letterSpacing: 2,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      Text(
                        'Enjoy Classic Games',
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.textMuted,
                          letterSpacing: 0.5,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Sort button — uses dialog instead of PopupMenuButton for TV D-pad support
          TvFocusable(
            onTap: _showSortDialog,
            borderRadius: BorderRadius.circular(8),
            child: IconButton(
              icon: Icon(Icons.swap_vert, color: colors.textSecondary),
              tooltip: 'Sort by',
              onPressed: _showSortDialog,
            ),
          ),

          // View toggle
          TvFocusable(
            onTap: () {
              setState(() => _isGridView = !_isGridView);
              context.read<SettingsService>().setGridView(_isGridView);
            },
            borderRadius: BorderRadius.circular(8),
            child: IconButton(
              icon: Icon(
                _isGridView ? Icons.view_list : Icons.grid_view,
                color: colors.textSecondary,
              ),
              onPressed: () {
                setState(() => _isGridView = !_isGridView);
                context.read<SettingsService>().setGridView(_isGridView);
              },
            ),
          ),

          // On TV: direct focusable buttons (popup menus are hard with D-pad)
          if (TvDetector.isTV) ...[
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFile,
              child: IconButton(
                icon: Icon(Icons.add, color: colors.accent),
                tooltip: 'Add ROMs',
                onPressed: _addRomFile,
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _addRomFolder,
              child: IconButton(
                icon: Icon(Icons.create_new_folder, color: colors.accent),
                tooltip: 'Add Folder',
                onPressed: _addRomFolder,
              ),
            ),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _openSettings,
              child: IconButton(
                icon: Icon(
                  Icons.settings_outlined,
                  color: colors.textSecondary,
                ),
                tooltip: 'Settings',
                onPressed: _openSettings,
              ),
            ),
          ] else ...[
            // More menu (phone/tablet) — Settings + Download All Cover Art
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: colors.textSecondary),
              tooltip: 'More options',
              color: colors.surface,
              onSelected: (value) {
                switch (value) {
                  case 'settings':
                    _openSettings();
                  case 'download_all_covers':
                    _downloadAllCoverArt();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'download_all_covers',
                  child: ListTile(
                    leading: Icon(Icons.download),
                    title: Text('Download All Cover Art'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'settings',
                  child: ListTile(
                    leading: Icon(Icons.settings_outlined),
                    title: Text('Settings'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    final colors = AppColorTheme.of(context);

    // Provide a focus node to text fields on TV to ensure D-pad input works smoothly
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: _searchController,
        focusNode: TvDetector.isTV ? _searchFocusNode : null,
        onChanged: _onSearchChanged,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search games...',
          prefixIcon: Icon(Icons.search, color: colors.textMuted),
          suffixIcon: _searchQuery.isNotEmpty
              ? TvFocusable(
                  onTap: () {
                    _searchDebounce?.cancel();
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: IconButton(
                    icon: Icon(Icons.clear, color: colors.textMuted),
                    onPressed: () {
                      _searchDebounce?.cancel();
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  ),
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildPlatformFilter() {
    final colors = AppColorTheme.of(context);
    if (TvDetector.isTV) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TvFocusable(
            onTap: _showPlatformFilterDialog,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 280,
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.filter_list, color: colors.textMuted, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _selectedSystem.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: colors.textPrimary),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, color: colors.textMuted),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<SystemFilter>(
            value: _selectedSystem,
            isExpanded: true,
            icon: Icon(Icons.arrow_drop_down, color: colors.textMuted),
            style: TextStyle(fontSize: 13, color: colors.textPrimary),
            dropdownColor: colors.surface,
            items:
                (TvDetector.isTV ? tvSystemFilterOptions : systemFilterOptions)
                    .map(
                      (option) => DropdownMenuItem<SystemFilter>(
                        value: option.value,
                        child: Text(option.label),
                      ),
                    )
                    .toList(),
            onChanged: (value) =>
                value == null ? null : setState(() => _selectedSystem = value),
          ),
        ),
      ),
    );
  }

  List<GameRom> _applySystemFilter(List<GameRom> games) {
    // On TV, hide platforms that are still work-in-progress.
    if (TvDetector.isTV) {
      games = games
          .where((g) => !tvRestrictedGamePlatforms.contains(g.platform))
          .toList();
    }
    if (_selectedSystem == SystemFilter.all) return games;
    return games.where((g) => _selectedSystem.matchesGame(g)).toList();
  }

  Widget _buildTabBar() {
    final colors = AppColorTheme.of(context);
    return Focus(
      focusNode: _tabBarFocusNode,
      skipTraversal: !TvDetector
          .isTV, // On TV: allow D-pad to reach tabs (basic remotes have no bumpers)
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Consumer<GameLibraryService>(
          builder: (context, library, _) {
            final allCount = library.games.length;
            final recentCount = library.recentlyPlayed.length;
            final favCount = library.favorites.length;
            return TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              indicatorPadding: const EdgeInsets.all(4),
              labelColor: colors.textPrimary,
              unselectedLabelColor: colors.textMuted,
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
              // Visible focus ring for TV / D-pad navigation
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.focused)) {
                  return colors.accent.withAlpha(50);
                }
                if (states.contains(WidgetState.hovered)) {
                  return colors.accent.withAlpha(25);
                }
                return null;
              }),
              splashBorderRadius: BorderRadius.circular(10),
              dividerHeight: 0,
              tabs: [
                Tab(text: 'All Games ($allCount)', icon: null),
                Tab(text: 'Recent ($recentCount)', icon: null),
                Tab(text: 'Favorites ($favCount)', icon: null),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTvHintBar() {
    final colors = AppColorTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      color: colors.backgroundDark,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colors.surfaceLight),
                ),
                child: Text(
                  'L1',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: colors.textSecondary,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '◄  Tabs  ►',
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colors.surfaceLight),
                ),
                child: Text(
                  'R1',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colors.surfaceLight),
                ),
                child: Text(
                  'Select',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: colors.textSecondary,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  'Options',
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAllGames() {
    final colors = AppColorTheme.of(context);
    return Selector<
      GameLibraryService,
      ({List<GameRom> games, bool isLoading})
    >(
      selector: (_, lib) =>
          (games: _applySystemFilter(lib.games), isLoading: lib.isLoading),
      shouldRebuild: (prev, next) =>
          prev.isLoading != next.isLoading ||
          prev.games.length != next.games.length ||
          !_gameListsEqual(prev.games, next.games),
      builder: (context, data, _) {
        // Only show full-screen spinner on initial load (empty library).
        // During refresh, keep games visible with a subtle overlay.
        if (data.isLoading && data.games.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        var games = data.games;
        if (_searchQuery.isNotEmpty) {
          games = games
              .where(
                (g) =>
                    g.name.toLowerCase().contains(_searchQuery.toLowerCase()),
              )
              .toList();
        }
        games = _sortGames(games);

        if (games.isEmpty) {
          return _buildEmptyState();
        }

        return Stack(
          children: [
            Column(
              children: [
                if (_searchQuery.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${games.length} result${games.length == 1 ? '' : 's'} for \'$_searchQuery\'',
                        style: TextStyle(fontSize: 12, color: colors.textMuted),
                      ),
                    ),
                  ),
                Expanded(child: _buildGameList(games)),
              ],
            ),
            if (data.isLoading)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Material(
                    color: colors.surface.withAlpha(230),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Refreshing library…',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildRecentGames() {
    return Selector<GameLibraryService, List<GameRom>>(
      selector: (_, lib) => lib.recentlyPlayed,
      shouldRebuild: (prev, next) =>
          prev.length != next.length || !_gameListsEqual(prev, next),
      builder: (context, recentGames, _) {
        var games = _sortGames(recentGames);

        if (games.isEmpty) {
          return _buildEmptyState(
            icon: Icons.history,
            title: 'No Recent Games',
            subtitle: 'Games you play will appear here',
          );
        }

        return _buildGameList(games);
      },
    );
  }

  Widget _buildFavorites() {
    return Selector<GameLibraryService, List<GameRom>>(
      selector: (_, lib) => lib.favorites,
      shouldRebuild: (prev, next) =>
          prev.length != next.length || !_gameListsEqual(prev, next),
      builder: (context, favGames, _) {
        var games = _sortGames(favGames);

        if (games.isEmpty) {
          return _buildEmptyState(
            icon: Icons.favorite_border,
            title: 'No Favorites',
            subtitle: 'Long press a game to add to favorites',
          );
        }

        return _buildGameList(games);
      },
    );
  }

  /// Shallow equality check for game lists — compares paths which are
  /// the unique identity of a GameRom. Avoids unnecessary rebuilds when
  /// the library notifies but the actual list hasn't changed.
  static bool _gameListsEqual(List<GameRom> a, List<GameRom> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].path != b[i].path ||
          a[i].name != b[i].name ||
          a[i].platform != b[i].platform ||
          a[i].sizeBytes != b[i].sizeBytes ||
          a[i].coverPath != b[i].coverPath ||
          a[i].isFavorite != b[i].isFavorite ||
          a[i].lastPlayed != b[i].lastPlayed) {
        return false;
      }
    }
    return true;
  }

  /// Determines which game card index should receive autofocus.
  /// On TV: uses the last-focused index when restoring focus (only if
  /// we're on the same tab), otherwise defaults to 0 on the initial build.
  bool _shouldAutofocusIndex(BuildContext context, int index, int itemCount) {
    if (!TvDetector.isTV) return false;

    // Safety check: is another route on top? e.g. the TV upload dialog overlaying the home screen.
    // If the home screen's route is no longer current, it should not blindly autofocus.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    if (_shouldRestoreFocus &&
        _tabController.index == _lastFocusedTabIndex &&
        itemCount > 0) {
      return index == _lastFocusedGameIndex.clamp(0, itemCount - 1);
    }
    return index == 0;
  }

  Widget _buildGameList(List<GameRom> games) {
    // Clear the restore flag after this build frame so we don't keep
    // autofocusing on subsequent rebuilds (e.g. from Consumer).
    if (_shouldRestoreFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _shouldRestoreFocus = false;
      });
    }

    if (_isGridView) {
      // Responsive columns; larger cache extent for 100+ games (smoother scrolling)
      final cacheExtent = games.length > 100 ? 600.0 : 400.0;

      final tvGrid = TvDetector.isTV;
      return TvScrollAccelerator(
        child: GridView.builder(
          padding: EdgeInsets.all(tvGrid ? 24 : 16),
          scrollCacheExtent: ScrollCacheExtent.pixels(cacheExtent),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: tvGrid ? 224 : 220,
            childAspectRatio: 0.65,
            crossAxisSpacing: tvGrid ? 20 : 12,
            mainAxisSpacing: tvGrid ? 20 : 12,
          ),
          itemCount: games.length,
          itemBuilder: (context, index) {
            final game = games[index];
            return TvFocusable(
              key: ValueKey(game.path),
              autofocus: _shouldAutofocusIndex(context, index, games.length),
              onTap: () => _launchGame(game),
              onLongPress: () => _showGameOptions(game),
              onFocusChanged: (focused) {
                if (focused) {
                  _lastFocusedGameIndex = index;
                  _lastFocusedTabIndex = _tabController.index;
                }
              },
              child: GameCard(
                game: game,
                onTap: () => _launchGame(game),
                onLongPress: () => _showGameOptions(game),
              ),
            );
          },
        ),
      );
    }

    final listCacheExtent = games.length > 100 ? 600.0 : 400.0;
    return TvScrollAccelerator(
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        scrollCacheExtent: ScrollCacheExtent.pixels(listCacheExtent),
        itemCount: games.length,
        separatorBuilder: (context, index) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          final game = games[index];
          return TvFocusable(
            key: ValueKey(game.path),
            autofocus: _shouldAutofocusIndex(context, index, games.length),
            borderRadius: BorderRadius.circular(12),
            onTap: () => _launchGame(game),
            onLongPress: () => _showGameOptions(game),
            onFocusChanged: (focused) {
              if (focused) {
                _lastFocusedGameIndex = index;
                _lastFocusedTabIndex = _tabController.index;
              }
            },
            child: GameListTile(
              game: game,
              onTap: () => _launchGame(game),
              onLongPress: () => _showGameOptions(game),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState({
    IconData icon = Icons.folder_open,
    String title = 'No Games Found',
    String subtitle = 'Add ROM files or folders to get started',
  }) {
    final colors = AppColorTheme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: colors.surface,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 48,
                  color: colors.primary.withAlpha(128),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: TextStyle(fontSize: 14, color: colors.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(0),
                    child: TvFocusable(
                      autofocus: TvDetector.isTV,
                      borderRadius: BorderRadius.circular(12),
                      onTap: _addRomFile,
                      child: OutlinedButton.icon(
                        onPressed: _addRomFile,
                        icon: const Icon(Icons.add),
                        label: const Text('Add ROMs'),
                      ),
                    ),
                  ),
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: TvFocusable(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _addRomFolder,
                      child: ElevatedButton.icon(
                        onPressed: _addRomFolder,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Add Folder'),
                      ),
                    ),
                  ),
                ],
              ),
              if (TvDetector.isTV) ...[
                const SizedBox(height: 16),
                Text(
                  'Press \u24B6 to select',
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFAB() {
    return Padding(
      // Push the FAB up so it stays above the BannerAd (approx 50-60dp)
      padding: const EdgeInsets.only(bottom: 60),
      child: TvFocusable(
        borderRadius: BorderRadius.circular(16),
        onTap: _addRomFile,
        child: FloatingActionButton(
          onPressed: _addRomFile,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Future<void> _selectCoverArt(GameRom game) async {
    final library = context.read<GameLibraryService>();

    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif'],
    );
    if (!mounted) return;

    if (result != null) {
      final path = result.path;
      if (path != null) {
        await library.setCoverArt(game, path);
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              const SnackBar(
                content: Text('Cover art set!'),
                duration: Duration(seconds: 1),
              ),
            );
        }
      }
    }
  }

  /// Download cover art for a single game by its ROM hash.
  Future<void> _downloadCoverArt(GameRom game) async {
    if (!mounted) return;

    final library = context.read<GameLibraryService>();
    final coverService = context.read<CoverArtService>();

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('Searching cover art for "${game.name}"…')),
            ],
          ),
          duration: const Duration(seconds: 30),
        ),
      );

    final localPath = await coverService.fetchCoverArt(game);

    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();

    if (localPath != null) {
      await library.setCoverArt(game, localPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cover art downloaded!'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No cover art found for this ROM.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Download cover art for all games that don't have one.
  Future<void> _downloadAllCoverArt() async {
    if (!mounted) return;

    final library = context.read<GameLibraryService>();
    final coverService = context.read<CoverArtService>();
    final games = library.games;

    final gamesWithoutCover = games.where((g) => g.coverPath == null).toList();

    if (gamesWithoutCover.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('All games already have cover art.'),
            duration: Duration(seconds: 2),
          ),
        );
      return;
    }

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Downloading cover art for ${gamesWithoutCover.length} '
            'game${gamesWithoutCover.length == 1 ? '' : 's'}…',
          ),
          duration: const Duration(seconds: 60),
        ),
      );

    final results = await coverService.fetchAllCoverArt(
      gamesWithoutCover,
      onCoverReady: (romPath, coverPath) async {
        final game = games.firstWhere(
          (g) => g.path == romPath,
          orElse: () => gamesWithoutCover.first,
        );
        await library.setCoverArt(game, coverPath);
      },
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Downloaded ${results.length} of '
            '${gamesWithoutCover.length} cover art images.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  /// Show the TV HTTP upload dialog for adding ROMs via web browser.
  Future<void> _showTvHttpUpload() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (ctx) => TvHttpUploadDialog(parentContext: context),
    );

    if (!mounted) return;

    if (result == true) {
      // Library was refreshed in the dialog
      _tabController.animateTo(0);
    }

    // Restore focus for TV navigation
    setState(() => _shouldRestoreFocus = true);
  }

  /// Fire-and-forget: download cover art for a list of newly imported games.
  /// Concurrency reduced on low-RAM to avoid competing with import and UI.
  void _autoFetchCovers(List<GameRom> games, GameLibraryService library) {
    final coverService = context.read<CoverArtService>();
    final toFetch = games.where((g) => g.coverPath == null).toList();
    if (toFetch.isEmpty) return;

    final concurrency = coverService.maxConcurrentDownloads;
    () async {
      for (int i = 0; i < toFetch.length; i += concurrency) {
        final chunk = toFetch.skip(i).take(concurrency).toList();
        await Future.wait(
          chunk.map((game) async {
            try {
              final path = await coverService.fetchCoverArt(game);
              if (path != null) await library.setCoverArt(game, path);
            } catch (e) {
              debugPrint(
                'HomeScreen: failed to fetch cover art for "${game.name}" — $e',
              );
            }
          }),
        );
      }
    }();
  }

  /// Show achievements list for a game.
  ///
  /// This resolves the game ID from the ROM hash, loads achievement data,
  /// and opens the AchievementsScreen.
  Future<void> _showAchievementsForGame(GameRom game) async {
    final raService = context.read<RetroAchievementsService>();
    final settings = context.read<SettingsService>().settings;

    if (!raService.isLoggedIn) return;

    // Show loading indicator
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: 12),
              Text('Loading achievements...'),
            ],
          ),
          duration: Duration(seconds: 10),
        ),
      );

    // Start game session to resolve game ID and load data.
    // awaitData: true ensures achievement metadata is fully loaded before
    // we check gameData — avoids the screen opening with no data.
    await raService.startGameSession(game, awaitData: true);

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final gameData = raService.gameData;
    final session = raService.activeSession;

    if (session == null || session.gameId <= 0) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('This ROM is not recognized by RetroAchievements'),
            duration: Duration(seconds: 3),
          ),
        );
      return;
    }

    if (gameData == null || gameData.achievements.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('No achievements found for this game'),
            duration: Duration(seconds: 3),
          ),
        );
      return;
    }

    if (!mounted) return;

    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => AchievementsScreen(
              gameData: gameData,
              isHardcore: settings.raHardcoreMode,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() => _shouldRestoreFocus = true);
        });
  }

  void _showGameOptions(GameRom game) {
    final colors = AppColorTheme.of(context);
    final library = context.read<GameLibraryService>();

    // Resolve RA state before building the menu so we don't need a Builder
    // that returns SizedBox.shrink() — that causes a phantom focus gap on TV.
    final raService = context.read<RetroAchievementsService>();
    final settings = context.read<SettingsService>();
    final showAchievements =
        settings.settings.raEnabled && raService.isLoggedIn;

    Widget buildOptionItems(BuildContext ctx) {
      return FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TvFocusable(
              autofocus: true,
              onTap: () {
                Navigator.pop(ctx);
                _launchGame(game);
              },
              onBack: () => Navigator.pop(ctx),
              borderRadius: BorderRadius.circular(8),
              child: ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Play'),
                onTap: () {
                  Navigator.pop(ctx);
                  _launchGame(game);
                },
              ),
            ),
            if (showAchievements)
              TvFocusable(
                onTap: () {
                  Navigator.pop(ctx);
                  _showAchievementsForGame(game);
                },
                onBack: () => Navigator.pop(ctx),
                borderRadius: BorderRadius.circular(8),
                child: ListTile(
                  leading: const Icon(Icons.emoji_events, color: Colors.amber),
                  title: const Text('Achievements'),
                  subtitle: const Text('View RetroAchievements'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showAchievementsForGame(game);
                  },
                ),
              ),
            TvFocusable(
              onTap: () {
                library.toggleFavorite(game);
                Navigator.pop(ctx);
              },
              onBack: () => Navigator.pop(ctx),
              borderRadius: BorderRadius.circular(8),
              child: ListTile(
                leading: Icon(
                  game.isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: game.isFavorite ? colors.accentAlt : null,
                ),
                title: Text(
                  game.isFavorite
                      ? 'Remove from Favorites'
                      : 'Add to Favorites',
                ),
                onTap: () {
                  library.toggleFavorite(game);
                  Navigator.pop(ctx);
                },
              ),
            ),
            TvFocusable(
              onTap: () {
                Navigator.pop(ctx);
                _selectCoverArt(game);
              },
              onBack: () => Navigator.pop(ctx),
              borderRadius: BorderRadius.circular(8),
              child: ListTile(
                leading: const Icon(Icons.image),
                title: const Text('Set Cover Art'),
                subtitle: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.pop(ctx);
                  _selectCoverArt(game);
                },
              ),
            ),
            TvFocusable(
              onTap: () {
                Navigator.pop(ctx);
                _downloadCoverArt(game);
              },
              onBack: () => Navigator.pop(ctx),
              borderRadius: BorderRadius.circular(8),
              child: ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download Cover Art'),
                subtitle: const Text('Search online'),
                onTap: () {
                  Navigator.pop(ctx);
                  _downloadCoverArt(game);
                },
              ),
            ),
            if (game.coverPath != null)
              TvFocusable(
                onTap: () {
                  library.removeCoverArt(game);
                  Navigator.pop(ctx);
                },
                onBack: () => Navigator.pop(ctx),
                borderRadius: BorderRadius.circular(8),
                child: ListTile(
                  leading: const Icon(Icons.hide_image_outlined),
                  title: const Text('Remove Cover Art'),
                  onTap: () {
                    library.removeCoverArt(game);
                    Navigator.pop(ctx);
                  },
                ),
              ),
            TvFocusable(
              onTap: () {
                Navigator.pop(ctx);
                _exportGameSaves(game);
              },
              onBack: () => Navigator.pop(ctx),
              borderRadius: BorderRadius.circular(8),
              child: ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('Export Save Data'),
                subtitle: Text(
                  'Backup .sav & save states to ZIP',
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportGameSaves(game);
                },
              ),
            ),
            TvFocusable(
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteSaveData(game);
              },
              onBack: () => Navigator.pop(ctx),
              borderRadius: BorderRadius.circular(8),
              child: ListTile(
                leading: Icon(Icons.delete_sweep, color: colors.warning),
                title: Text(
                  'Delete Save Data',
                  style: TextStyle(color: colors.warning),
                ),
                subtitle: Text(
                  'Remove .sav, save states & screenshots',
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteSaveData(game);
                },
              ),
            ),
            TvFocusable(
              onTap: () {
                library.removeRom(game);
                Navigator.pop(ctx);
              },
              onBack: () => Navigator.pop(ctx),
              borderRadius: BorderRadius.circular(8),
              child: ListTile(
                leading: Icon(Icons.delete_outline, color: colors.error),
                title: Text(
                  'Remove from Library',
                  style: TextStyle(color: colors.error),
                ),
                onTap: () {
                  library.removeRom(game);
                  Navigator.pop(ctx);
                },
              ),
            ),
          ],
        ),
      );
    }

    // On TV: use a centered dialog (bottom sheets are awkward on 55" screens)
    if (TvDetector.isTV) {
      showDialog(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.primary.withAlpha(77), width: 2),
          ),
          title: Text(
            game.name,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(child: buildOptionItems(ctx)),
          ),
        ),
      ).then((_) {
        if (mounted) _gameListFocusNode.requestFocus();
      });
      return;
    }

    // Phone/tablet: use bottom sheet
    showModalBottomSheet(
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.surfaceLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    game.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(child: buildOptionItems(ctx)),
                ),
              ],
            ),
          ),
        );
      },
    ).then((_) {
      if (mounted) _gameListFocusNode.requestFocus();
    });
  }

  Future<void> _exportGameSaves(GameRom game) async {
    final colors = AppColorTheme.of(context);
    final emulator = context.read<EmulatorService>();

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Creating save backup…')));

    try {
      final zipPath = await SaveBackupService.exportGameSaves(
        game: game,
        appSaveDir: emulator.saveDir,
      );

      if (!mounted) return;

      if (zipPath == null) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text('No save files found for ${game.name}')),
          );
        return;
      }

      // Let the user choose: share or save.
      // On TV use a centered dialog; on phone use bottom sheet.
      final pickerFuture = TvDetector.isTV
          ? showDialog<void>(
              context: context,
              useRootNavigator: false,
              builder: (dialogContext) {
                return AlertDialog(
                  backgroundColor: colors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  title: Text(
                    'Save backup ready',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  content: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          game.name,
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        TvFocusable(
                          autofocus: true,
                          onTap: () {
                            Navigator.pop(dialogContext);
                            SaveBackupService.shareZip(zipPath);
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: ListTile(
                            leading: const Icon(Icons.share),
                            title: const Text('Share'),
                            subtitle: Text(
                              'Send via Google Drive, email, etc.',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.textMuted,
                              ),
                            ),
                            onTap: () {
                              Navigator.pop(dialogContext);
                              SaveBackupService.shareZip(zipPath);
                            },
                          ),
                        ),
                        TvFocusable(
                          onTap: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            Navigator.pop(dialogContext);
                            final saved =
                                await SaveBackupService.saveZipToUserLocation(
                                  zipPath,
                                );
                            if (saved != null && mounted) {
                              messenger
                                ..clearSnackBars()
                                ..showSnackBar(
                                  SnackBar(content: Text('Saved to $saved')),
                                );
                            }
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: ListTile(
                            leading: const Icon(Icons.save_alt),
                            title: const Text('Save to…'),
                            subtitle: Text(
                              'Choose a folder on this device',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.textMuted,
                              ),
                            ),
                            onTap: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              Navigator.pop(dialogContext);
                              final saved =
                                  await SaveBackupService.saveZipToUserLocation(
                                    zipPath,
                                  );
                              if (saved != null && mounted) {
                                messenger
                                  ..clearSnackBars()
                                  ..showSnackBar(
                                    SnackBar(content: Text('Saved to $saved')),
                                  );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            )
          : showModalBottomSheet<void>(
              context: context,
              backgroundColor: colors.surface,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (context) {
                return SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colors.surfaceLight,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            'Save backup ready for ${game.name}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: colors.textPrimary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FocusTraversalGroup(
                          policy: OrderedTraversalPolicy(),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TvFocusable(
                                autofocus: true,
                                onTap: () {
                                  Navigator.pop(context);
                                  SaveBackupService.shareZip(zipPath);
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: ListTile(
                                  leading: const Icon(Icons.share),
                                  title: const Text('Share'),
                                  subtitle: Text(
                                    'Send via Google Drive, email, etc.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.textMuted,
                                    ),
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    SaveBackupService.shareZip(zipPath);
                                  },
                                ),
                              ),
                              TvFocusable(
                                onTap: () async {
                                  final messenger = ScaffoldMessenger.of(
                                    context,
                                  );
                                  Navigator.pop(context);
                                  final saved =
                                      await SaveBackupService.saveZipToUserLocation(
                                        zipPath,
                                      );
                                  if (saved != null && mounted) {
                                    messenger
                                      ..clearSnackBars()
                                      ..showSnackBar(
                                        SnackBar(
                                          content: Text('Saved to $saved'),
                                        ),
                                      );
                                  }
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: ListTile(
                                  leading: const Icon(Icons.save_alt),
                                  title: const Text('Save to…'),
                                  subtitle: Text(
                                    'Choose a folder on this device',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.textMuted,
                                    ),
                                  ),
                                  onTap: () async {
                                    final messenger = ScaffoldMessenger.of(
                                      context,
                                    );
                                    Navigator.pop(context);
                                    final saved =
                                        await SaveBackupService.saveZipToUserLocation(
                                          zipPath,
                                        );
                                    if (saved != null && mounted) {
                                      messenger
                                        ..clearSnackBars()
                                        ..showSnackBar(
                                          SnackBar(
                                            content: Text('Saved to $saved'),
                                          ),
                                        );
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );

      pickerFuture.whenComplete(() {
        // Delete the temp ZIP after the bottom sheet is dismissed,
        // regardless of whether the user shared, saved, or cancelled.
        SaveBackupService.deleteTempZip(zipPath);
        // Restore focus to the game list on TV
        if (mounted) _gameListFocusNode.requestFocus();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _confirmDeleteSaveData(GameRom game) async {
    final colors = AppColorTheme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.warning.withAlpha(80), width: 2),
        ),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: colors.warning, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Delete Save Data?',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently delete all save data for:',
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              game.name,
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '• Battery save (.sav)\n'
              '• All save states (slots 0-5)\n'
              '• Save state thumbnails\n'
              '• In-game screenshots',
              style: TextStyle(color: colors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Text(
              'This cannot be undone.',
              style: TextStyle(
                color: colors.warning,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
        actions: [
          TvFocusable(
            autofocus: true,
            onTap: () => Navigator.pop(context, false),
            borderRadius: BorderRadius.circular(8),
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                'Cancel',
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
          ),
          TvFocusable(
            onTap: () => Navigator.pop(context, true),
            borderRadius: BorderRadius.circular(8),
            child: TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(
                backgroundColor: colors.warning.withAlpha(30),
              ),
              child: Text(
                'Delete',
                style: TextStyle(
                  color: colors.warning,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final emulator = context.read<EmulatorService>();
      final count = await emulator.deleteSaveData(game);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                count > 0
                    ? 'Deleted $count save file${count == 1 ? '' : 's'} for ${game.name}'
                    : 'No save files found for ${game.name}',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
      }
    }
    // Restore focus to the game list on TV after dialog dismissal
    if (mounted) _gameListFocusNode.requestFocus();
  }
}
