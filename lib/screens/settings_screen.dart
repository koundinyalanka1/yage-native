import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/safe_url_launcher.dart';
import '../utils/tv_detector.dart';
import '../widgets/tv_http_upload_dialog.dart';

import '../core/mgba_bindings.dart';
import '../models/emulator_settings.dart';
import '../models/game_rom.dart';
import '../models/gamepad_skin.dart';
import '../services/bios_service.dart';
import '../services/settings_service.dart';
import '../services/game_library_service.dart';
import '../services/emulator_service.dart';
import '../services/retro_achievements_service.dart';
import '../services/save_backup_service.dart';
import '../services/consent_service.dart';
import '../services/cover_art_service.dart';
import '../services/app_version_service.dart';
import '../services/remove_ads_purchase_service.dart';
import '../utils/graphics_quality.dart';
import '../utils/theme.dart';
import '../widgets/banner_ad_widget.dart';
import '../widgets/tv_focusable.dart';
import '../widgets/rom_folder_setup_dialog.dart';
import 'ra_login_screen.dart';

const _deviceChannel = MethodChannel('com.yourmateapps.retropal/device');

/// Settings screen — organized into 5 focused tabs for quick D-pad / touch
/// navigation: Controls, BIOS, Trophies, Data, Pro.
///
/// Display options live as a sub-section inside the Controls tab so the
/// scarce top-level tab slots are reserved for high-traffic concerns
/// (controls, BIOS for NDS / PS1 / Intellivision, etc.).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabController;
  late final Future<String> _appVersionFuture;
  final FocusNode _keyFocusNode = FocusNode();
  int _activeTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(_handleTabChanged);
    _appVersionFuture = AppVersionService.pubspecStyleVersion();
    WidgetsBinding.instance.addObserver(this);
  }

  void _handleTabChanged() {
    if (!mounted) return;
    if (_activeTabIndex != _tabController.index) {
      setState(() {
        _activeTabIndex = _tabController.index;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  /// When app resumes from background (e.g. returning from external browser
  /// after opening Privacy Policy), restore focus so D-pad works again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      // Small delay allows Flutter to finish restoring the widget tree
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _keyFocusNode.requestFocus();
      });
    }
  }

  /// Gamepad L1 / R1 bumpers switch tabs, consistent with the home screen.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // L1 / PageUp → previous tab
    if (key == LogicalKeyboardKey.gameButtonLeft1 ||
        key == LogicalKeyboardKey.pageUp) {
      final newIndex = (_tabController.index - 1).clamp(
        0,
        _tabController.length - 1,
      );
      if (newIndex != _tabController.index) {
        _tabController.animateTo(newIndex);
      }
      return KeyEventResult.handled;
    }
    // R1 / PageDown → next tab
    if (key == LogicalKeyboardKey.gameButtonRight1 ||
        key == LogicalKeyboardKey.pageDown) {
      final newIndex = (_tabController.index + 1).clamp(
        0,
        _tabController.length - 1,
      );
      if (newIndex != _tabController.index) {
        _tabController.animateTo(newIndex);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);

    return Focus(
      focusNode: _keyFocusNode,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          leading: TvFocusable(
            onTap: () => Navigator.pop(context),
            borderRadius: BorderRadius.circular(8),
            child: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ),
        body: SafeArea(
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
              children: [
                // ── Tab bar ── sits in the body (not AppBar.bottom) so that
                // FocusTraversalOrder gives D-pad users a clean path:
                //   back button → tabs → tab content.
                FocusTraversalOrder(
                  order: const NumericFocusOrder(0),
                  child: Material(
                    color: colors.backgroundMedium,
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: false,
                      indicatorColor: colors.accent,
                      indicatorWeight: 3,
                      labelColor: colors.accent,
                      unselectedLabelColor: colors.textMuted,
                      labelStyle: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                      unselectedLabelStyle: const TextStyle(fontSize: 11),
                      // Prominent focus ring for TV / keyboard navigation
                      overlayColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.focused)) {
                          return colors.accent.withAlpha(50);
                        }
                        if (states.contains(WidgetState.hovered)) {
                          return colors.accent.withAlpha(25);
                        }
                        return null;
                      }),
                      splashBorderRadius: BorderRadius.circular(8),
                      dividerHeight: 0,
                      tabs: const [
                        Tab(
                          icon: Icon(Icons.sports_esports, size: 20),
                          text: 'Controls',
                        ),
                        Tab(
                          // memory chip / processor icon
                          icon: Icon(Icons.memory, size: 20),
                          text: 'BIOS',
                        ),
                        Tab(
                          icon: Icon(Icons.emoji_events, size: 20),
                          text: 'Trophies',
                        ),
                        Tab(
                          icon: Icon(Icons.folder_copy, size: 20),
                          text: 'Data',
                        ),
                        Tab(
                          icon: Icon(Icons.workspace_premium, size: 20),
                          text: 'Pro',
                        ),
                      ],
                    ),
                  ),
                ),
                // ── Tab content ──
                Expanded(
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1),
                    child: Consumer<SettingsService>(
                      builder: (context, settingsService, _) {
                        final settings = settingsService.settings;

                        return TabBarView(
                          controller: _tabController,
                          children: [
                            _buildTabTraversal(
                              0,
                              _buildControlsTab(
                                context,
                                settings,
                                settingsService,
                                colors,
                              ),
                            ),
                            _buildTabTraversal(
                              1,
                              _buildBiosTab(context, colors),
                            ),
                            _buildTabTraversal(
                              2,
                              _buildAchievementsTab(
                                context,
                                settings,
                                settingsService,
                                colors,
                              ),
                            ),
                            _buildTabTraversal(
                              3,
                              _buildDataTab(
                                context,
                                settings,
                                settingsService,
                                colors,
                              ),
                            ),
                            _buildTabTraversal(
                              4,
                              _buildProTab(
                                context,
                                settings,
                                settingsService,
                                colors,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                const BannerAdWidget(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabTraversal(int tabIndex, Widget child) {
    return FocusTraversalGroup(
      descendantsAreFocusable: _activeTabIndex == tabIndex,
      descendantsAreTraversable: _activeTabIndex == tabIndex,
      child: child,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Tab 1 — Controls (includes Display sub-section, Audio, Touch, Emulation)
  // ═══════════════════════════════════════════════════════════════════════

  Widget _buildControlsTab(
    BuildContext context,
    EmulatorSettings settings,
    SettingsService settingsService,
    AppColorTheme colors,
  ) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Theme ── (moved from former Display tab)
        _SectionHeader(title: 'Theme'),
        _ThemePicker(
          selectedThemeId: settings.selectedTheme,
          onChanged: settingsService.setAppTheme,
        ),

        const SizedBox(height: 16),

        // ── Display ── (moved from former Display tab)
        _SectionHeader(title: 'Display'),
        _SettingsCard(
          children: [
            _SwitchTile(
              icon: Icons.speed,
              title: 'Show FPS',
              subtitle: 'Display frame rate counter',
              value: settings.showFps,
              autofocus: true,
              onChanged: (_) => settingsService.toggleShowFps(),
            ),
            const Divider(height: 1),
            _SwitchTile(
              icon: Icons.aspect_ratio,
              title: 'Maintain Aspect Ratio',
              subtitle: 'Keep original game proportions',
              value: settings.maintainAspectRatio,
              onChanged: (_) => settingsService.toggleAspectRatio(),
            ),
            const Divider(height: 1),
            _SliderTile(
              icon: Icons.fit_screen,
              title: 'Game Screen Size',
              value: settings.gameScreenScale,
              min: 0.5,
              max: 1.0,
              divisions: 10,
              labelSuffix: '%',
              labelMultiplier: 100,
              onChanged: settingsService.setGameScreenScale,
            ),
            const Divider(height: 1),
            _AutoOptimizedTile(
              active: settings.graphicsMode == GraphicsMode.autoOptimized,
            ),
            const Divider(height: 1),
            _SwitchTile(
              icon: Icons.grid_on,
              title: 'Authentic Pixel Mode',
              subtitle: 'Exact original pixels with black borders',
              value: settings.graphicsMode == GraphicsMode.authenticPixel,
              onChanged: (_) => settingsService.setAuthenticPixelMode(
                settings.graphicsMode != GraphicsMode.authenticPixel,
              ),
            ),
            const Divider(height: 1),
            _PaletteTile(
              selectedIndex: settings.selectedColorPalette,
              onChanged: settingsService.setColorPalette,
            ),
            const Divider(height: 1),
            _SwitchTile(
              icon: Icons.border_all,
              title: 'SGB Borders',
              subtitle:
                  'Decorative borders for SGB-enhanced games (requires game reload)',
              value: settings.enableSgbBorders,
              onChanged: (_) => settingsService.toggleSgbBorders(),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // ── Audio ──
        _SectionHeader(title: 'Audio'),
        _SettingsCard(
          children: [
            _SwitchTile(
              icon: Icons.volume_up,
              title: 'Enable Sound',
              subtitle: 'Play game audio',
              value: settings.enableSound,
              onChanged: (_) => settingsService.toggleSound(),
            ),
            if (settings.enableSound) ...[
              const Divider(height: 1),
              _SliderTile(
                icon: Icons.volume_down,
                title: 'Volume',
                value: settings.volume,
                onChanged: settingsService.setVolume,
              ),
            ],
          ],
        ),

        const SizedBox(height: 16),

        // ── Touch Controls ──
        _SectionHeader(title: 'Touch Controls'),
        _SettingsCard(
          children: [
            _SwitchTile(
              icon: Icons.vibration,
              title: 'Haptic Feedback',
              subtitle: 'Vibrate on button press',
              value: settings.enableVibration,
              onChanged: (_) => settingsService.toggleVibration(),
            ),
            const Divider(height: 1),
            _SliderTile(
              icon: Icons.opacity,
              title: 'Gamepad Opacity',
              value: settings.gamepadOpacity,
              min: 0.1,
              max: 1.0,
              onChanged: settingsService.setGamepadOpacity,
            ),
            const Divider(height: 1),
            _SliderTile(
              icon: Icons.zoom_in,
              title: 'Gamepad Scale',
              value: settings.gamepadScale,
              min: 0.5,
              max: 2.0,
              onChanged: settingsService.setGamepadScale,
            ),
            const Divider(height: 1),
            _SwitchTile(
              icon: Icons.sports_esports,
              title: 'External Controller',
              subtitle: 'Bluetooth / USB gamepad & keyboard',
              value: settings.enableExternalGamepad,
              onChanged: (_) => settingsService.toggleExternalGamepad(),
            ),
            const Divider(height: 1),
            _GamepadSkinTile(
              selected: settings.gamepadSkin,
              onChanged: settingsService.setGamepadSkin,
            ),
          ],
        ),

        const SizedBox(height: 16),

        // ── Emulation ──
        _SectionHeader(title: 'Emulation'),
        _SettingsCard(
          children: [
            _SwitchTile(
              icon: Icons.fast_forward,
              title: 'Turbo Mode',
              subtitle: 'Fast forward emulation',
              value: settings.enableTurbo,
              onChanged: (_) => settingsService.toggleTurbo(),
            ),
            if (settings.enableTurbo) ...[
              const Divider(height: 1),
              _SliderTile(
                icon: Icons.speed,
                title: 'Turbo Speed',
                value: settings.turboSpeed,
                min: 1.5,
                max: 8.0,
                divisions: 13,
                labelSuffix: 'x',
                onChanged: settingsService.setTurboSpeed,
              ),
            ],
            const Divider(height: 1),
            _SwitchTile(
              icon: Icons.fast_rewind,
              title: 'Rewind',
              subtitle: 'Hold button to step backward in time',
              value: settings.enableRewind,
              onChanged: (_) => settingsService.toggleRewind(),
            ),
            if (settings.enableRewind) ...[
              const Divider(height: 1),
              _SliderTile(
                icon: Icons.timelapse,
                title: 'Rewind Buffer',
                value: settings.rewindBufferSeconds.toDouble(),
                min: 1.0,
                max: 60.0,
                divisions: 59,
                labelSuffix: 's',
                onChanged: (v) =>
                    settingsService.setRewindBufferSeconds(v.round()),
              ),
            ],
          ],
        ),

        const SizedBox(height: 32),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Tab 2 — BIOS (NDS, PS1, Intellivision)
  // ═══════════════════════════════════════════════════════════════════════

  Widget _buildBiosTab(BuildContext context, AppColorTheme colors) {
    return Consumer<BiosService>(
      builder: (context, biosService, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Legal note ──
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.warning.withAlpha(28),
                border: Border.all(color: colors.warning.withAlpha(80)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: colors.warning, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'BIOS files are not included. Only use BIOS dumps from '
                      'hardware you own. NDS and PS1 use HLE or OpenBIOS '
                      'fallbacks on mobile; Android TV requires real BIOS '
                      'files for all three systems.',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── NDS ──
            _BiosPlatformSection(
              platform: GamePlatform.nds,
              biosService: biosService,
              title: 'Nintendo DS',
              subtitle:
                  'melonDS · BIOS optional on mobile (FreeBIOS HLE), required on Android TV',
              autofocus: true,
            ),

            const SizedBox(height: 16),

            // ── PS1 ──
            _BiosPlatformSection(
              platform: GamePlatform.ps1,
              biosService: biosService,
              title: 'Sony PlayStation',
              subtitle:
                  'Beetle PSX HW · OpenBIOS fallback on mobile, real BIOS required on Android TV',
            ),

            const SizedBox(height: 16),

            // ── Intellivision ──
            _BiosPlatformSection(
              platform: GamePlatform.intv,
              biosService: biosService,
              title: 'Mattel Intellivision',
              subtitle:
                  'FreeIntv · No HLE exists; exec.bin + grom.bin are mandatory on every platform',
            ),

            const SizedBox(height: 16),

            _SettingsCard(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Tip: BIOS files can also be uploaded over Wi-Fi from a '
                    'desktop browser. Start the file manager from the home '
                    'screen and switch to the BIOS tab.',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 32),
          ],
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Tab 4 — Data (Library + Backup + About)
  // ═══════════════════════════════════════════════════════════════════════

  Widget _buildDataTab(
    BuildContext context,
    EmulatorSettings settings,
    SettingsService settingsService,
    AppColorTheme colors,
  ) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Library ──
        _SectionHeader(title: 'Library'),
        _SettingsCard(
          children: [
            _ActionTile(
              icon: Icons.folder,
              title: 'Manage ROM Folders',
              autofocus: true,
              onTap: () => _showRomFolders(context),
            ),
            const Divider(height: 1),
            _ActionTile(
              icon: Icons.refresh,
              title: 'Refresh Library',
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                final library = context.read<GameLibraryService>();
                final safUri = context
                    .read<SettingsService>()
                    .settings
                    .userRomsFolderUri;
                messenger
                  ..clearSnackBars()
                  ..showSnackBar(
                    const SnackBar(content: Text('Refreshing library...')),
                  );
                await library.refresh(safFolderUri: safUri);
                if (!context.mounted) return;
                messenger
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(
                        library.error == null
                            ? 'Library refreshed (${library.games.length} ROMs)'
                            : 'Refresh failed: ${library.error}',
                      ),
                    ),
                  );
              },
            ),
          ],
        ),

        const SizedBox(height: 16),

        // ── Backup & Restore ──
        _SectionHeader(title: 'Backup & Restore'),
        _SettingsCard(
          children: [
            _ActionTile(
              icon: Icons.upload_file,
              title: 'Export All Saves to ZIP',
              onTap: () => _exportAllSaves(context),
            ),
            const Divider(height: 1),
            _ActionTile(
              icon: Icons.download,
              title: 'Import Saves from ZIP',
              onTap: () => _importSaves(context),
            ),
            // Google Drive options — hidden on TV (GMS unreliable on Android TV)
            if (!TvDetector.isTV) ...[
              const Divider(height: 1),
              _ActionTile(
                icon: Icons.cloud_upload,
                title: 'Backup to Google Drive',
                onTap: () => _backupToDrive(context),
              ),
              const Divider(height: 1),
              _ActionTile(
                icon: Icons.cloud_download,
                title: 'Restore from Google Drive',
                onTap: () => _restoreFromDrive(context),
              ),
            ],
          ],
        ),

        const SizedBox(height: 16),

        // ── About ──
        _SectionHeader(title: 'About'),
        _SettingsCard(
          children: [
            FutureBuilder<String>(
              future: _appVersionFuture,
              builder: (context, snapshot) {
                final appVersion = snapshot.data ?? '...';
                return _InfoTile(
                  icon: Icons.info_outline,
                  title: 'RetroPal',
                  subtitle:
                      'Classic GB/GBC/GBA/NES/SNES Games\nVersion $appVersion',
                );
              },
            ),
            const Divider(height: 1),
            _InfoTile(
              icon: Icons.memory,
              title: 'Emulator Cores',
              subtitle:
                  'This app uses the following emulator cores:\n\n'
                  '• mGBA (GB/GBC/GBA)\n'
                  '  Mozilla Public License 2.0 (MPL-2.0)\n'
                  '  © endrift and contributors — https://mgba.io\n\n'
                  '• FCEUmm (NES)\n'
                  '  GNU General Public License v2 (GPL-2.0)\n'
                  '  © libretro and FCEUmm contributors\n\n'
                  '• Snes9x 2010 (SNES)\n'
                  '  Non-commercial license\n'
                  '  © Snes9x Team — https://www.snes9x.com\n\n'
                  '• Genesis Plus GX (Mega Drive / Genesis)\n'
                  '  Non-commercial license\n'
                  '  © Charles MacDonald, Eke-Eke — https://github.com/ekeeke/Genesis-Plus-GX\n\n'
                  '• Mupen64Plus-Next (Nintendo 64)\n'
                  '  GNU General Public License v2 or later (GPL-2.0+)\n'
                  '  © libretro and Mupen64Plus-Next contributors\n\n'
                  '• melonDS (Nintendo DS / DSi)\n'
                  '  GNU General Public License v3 (GPL-3.0)\n'
                  '  © melonDS team — https://melonds.kuribo64.net\n'
                  '  Ships with built-in FreeBIOS for HLE boot when no\n'
                  '  user BIOS is supplied.\n\n'
                  '• Beetle PSX HW (Sony PlayStation 1)\n'
                  '  GNU General Public License v2 (GPL-2.0)\n'
                  '  © Mednafen authors / libretro contributors\n\n'
                  '• OpenBIOS (PS1 free fallback BIOS)\n'
                  '  GNU General Public License v2 (GPL-2.0)\n'
                  '  © PCSX-Redux contributors — https://github.com/grumpycoders/pcsx-redux\n'
                  '  Clean-room implementation, NOT derived from Sony\n'
                  '  firmware. Bundled so PS1 games can launch without\n'
                  '  proprietary BIOS. Compatibility is limited compared\n'
                  '  to real BIOS dumps.\n\n'
                  '• FreeIntv (Mattel Intellivision)\n'
                  '  GNU General Public License v3 (GPL-3.0)\n'
                  '  © libretro and FreeIntv contributors\n\n'
                  'BIOS files are not provided. Original copyrighted BIOS '
                  'dumps must be supplied by the user — only from hardware '
                  'you legally own.',
            ),
            const Divider(height: 1),
            _ActionTile(
              icon: Icons.privacy_tip_outlined,
              title: 'Privacy Policy',
              onTap: () => safeLaunchHttpUrl(
                context,
                Uri.parse(
                  'https://yourmateapps.github.io/retropal/privacy-policy.html',
                ),
              ),
            ),
            FutureBuilder<bool>(
              future: ConsentService.instance.isPrivacyOptionsRequired,
              builder: (context, snapshot) {
                if (snapshot.data == true) {
                  return Column(
                    children: [
                      const Divider(height: 1),
                      _ActionTile(
                        icon: Icons.settings_accessibility,
                        title: 'Manage Ad Preferences',
                        onTap: () =>
                            ConsentService.instance.showPrivacyOptionsForm(),
                      ),
                    ],
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            _ActionTile(
              icon: Icons.description_outlined,
              title: 'Open-Source Licenses',
              onTap: () async {
                final appVersion = await _appVersionFuture;
                if (!context.mounted) return;
                showLicensePage(
                  context: context,
                  applicationName: 'RetroPal',
                  applicationVersion: appVersion,
                );
              },
            ),
            const Divider(height: 1),
            _ActionTile(
              icon: Icons.restore,
              title: 'Reset to Defaults',
              onTap: () => _confirmReset(context, settingsService),
              isDestructive: true,
            ),
          ],
        ),

        const SizedBox(height: 16),

        _SettingsCard(
          children: const [
            Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'This app is not affiliated with or endorsed by any console manufacturers. All trademarks belong to their respective owners.',
              ),
            ),
          ],
        ),

        const SizedBox(height: 32),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Tab 5 — RetroPal Pro
  // ═══════════════════════════════════════════════════════════════════════

  Widget _buildProTab(
    BuildContext context,
    EmulatorSettings settings,
    SettingsService settingsService,
    AppColorTheme colors,
  ) {
    return Consumer<RemoveAdsPurchaseService>(
      builder: (context, purchaseService, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Hero section ──
            _SettingsCard(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 20,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.workspace_premium,
                        size: 48,
                        color: colors.accent,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'RetroPal Pro',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Enjoy uninterrupted gaming with a one-time purchase.\n'
                        'Remove all ads permanently on mobile app and support development.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── Purchase status / actions ──
            if (purchaseService.adsRemoved) ...[
              _SettingsCard(
                children: [
                  _InfoTile(
                    icon: Icons.verified,
                    title: 'Pro Activated',
                    subtitle:
                        'Thanks for supporting RetroPal! All ads are removed in the mobile app.',
                  ),
                ],
              ),
            ] else ...[
              _SectionHeader(title: 'Remove Ads'),
              _SettingsCard(
                children: [
                  _ActionTile(
                    icon: Icons.sports_esports,
                    title: purchaseService.isPurchasing
                        ? 'Processing purchase...'
                        : 'Buy RetroPal Pro',
                    autofocus: true,
                    onTap: purchaseService.isPurchasing
                        ? () {}
                        : () => _buyRemoveAds(context),
                  ),
                  const Divider(height: 1),
                  _ActionTile(
                    icon: Icons.restore,
                    title: purchaseService.isPurchasing
                        ? 'Checking purchases...'
                        : 'Restore Purchases',
                    onTap: purchaseService.isPurchasing
                        ? () {}
                        : () => _restoreRemoveAdsPurchase(context),
                  ),
                ],
              ),
            ],

            if (purchaseService.errorMessage != null &&
                purchaseService.errorMessage!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  purchaseService.errorMessage!,
                  style: TextStyle(fontSize: 12, color: colors.warning),
                ),
              ),
            ],

            const SizedBox(height: 16),

            // ── What you get ──
            _SectionHeader(title: 'What You Get'),
            _SettingsCard(
              children: [
                _InfoTile(
                  icon: Icons.block,
                  title: 'No Banner Ads',
                  subtitle: 'Remove banner ads from every screen.',
                ),
                const Divider(height: 1),
                _InfoTile(
                  icon: Icons.skip_next,
                  title: 'No Interstitial Ads',
                  subtitle: 'No more full-screen ads between sessions.',
                ),
                const Divider(height: 1),
                _InfoTile(
                  icon: Icons.all_inclusive,
                  title: 'Lifetime Access',
                  subtitle:
                      'One-time purchase — no subscriptions, no renewals.',
                ),
              ],
            ),

            const SizedBox(height: 32),
          ],
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Tab 3 — Trophies (RetroAchievements)
  // ═══════════════════════════════════════════════════════════════════════

  Widget _buildAchievementsTab(
    BuildContext context,
    EmulatorSettings settings,
    SettingsService settingsService,
    AppColorTheme colors,
  ) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionHeader(title: 'RetroAchievements (Softcore Only)'),

        // Master enable/disable toggle
        _SettingsCard(
          children: [
            _SwitchTile(
              icon: Icons.emoji_events,
              title: 'Enable RetroAchievements',
              subtitle: 'Track and earn achievements while playing (softcore)',
              value: settings.raEnabled,
              autofocus: true,
              onChanged: (_) => settingsService.toggleRA(),
            ),
          ],
        ),

        // Everything below is gated on raEnabled
        if (settings.raEnabled) ...[
          const SizedBox(height: 12),
          _RetroAchievementsTile(),

          // Show mode/notification settings only when logged in
          Consumer<RetroAchievementsService>(
            builder: (context, raService, _) {
              if (!raService.isLoggedIn) return const SizedBox.shrink();
              return Column(
                children: [
                  const SizedBox(height: 12),
                  _SettingsCard(
                    children: [
                      // TODO: Hardcore mode – requires RA approval before enabling
                      // _SwitchTile(
                      //   icon: Icons.shield,
                      //   title: 'Hardcore Mode',
                      //   subtitle:
                      //       'Disable savestates, cheats, rewind, and fast-forward',
                      //   value: settings.raHardcoreMode,
                      //   onChanged: (_) =>
                      //       settingsService.toggleRAHardcoreMode(),
                      // ),
                      // const Divider(height: 1),
                      _ActionTile(
                        icon: Icons.key,
                        title: 'Change Password',
                        onTap: () async {
                          await raService.logout();
                          if (context.mounted) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const RALoginScreen(),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 12),

          // Disclosure
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: colors.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Uses RetroAchievements. Your credentials are stored '
                    'securely on-device and shared only with '
                    'retroachievements.org.',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.textMuted,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 32),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Action methods
  // ═══════════════════════════════════════════════════════════════════════

  void _showRomFolders(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final library = context.read<GameLibraryService>();

    showModalBottomSheet(
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.surfaceLight,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'ROM Folders',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (library.romDirectories.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              'No folders added yet',
                              style: TextStyle(color: colors.textMuted),
                            ),
                          )
                        else
                          ...library.romDirectories.asMap().entries.map((
                            entry,
                          ) {
                            final index = entry.key;
                            final dir = entry.value;
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: ListTile(
                                      leading: Icon(
                                        Icons.folder,
                                        color: colors.accent,
                                      ),
                                      title: Text(
                                        dir.split(RegExp(r'[/\\]')).last,
                                        style: TextStyle(
                                          color: colors.textPrimary,
                                        ),
                                      ),
                                      subtitle: Text(
                                        dir,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: colors.textMuted,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  FocusTraversalOrder(
                                    order: NumericFocusOrder(index.toDouble()),
                                    child: TvFocusable(
                                      autofocus: index == 0,
                                      onTap: () {
                                        library.removeRomDirectory(dir);
                                        setState(() {});
                                      },
                                      borderRadius: BorderRadius.circular(8),
                                      child: IconButton(
                                        icon: Icon(
                                          Icons.delete,
                                          color: colors.error,
                                        ),
                                        onPressed: () {
                                          library.removeRomDirectory(dir);
                                          setState(() {});
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TvFocusable(
                                onTap: () =>
                                    _openRomFolderSetup(context, setState),
                                borderRadius: BorderRadius.circular(8),
                                child: OutlinedButton.icon(
                                  onPressed: () =>
                                      _openRomFolderSetup(context, setState),
                                  icon: const Icon(Icons.folder_open),
                                  label: const Text(
                                    'Set up ROM folder (sync saves)',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TvFocusable(
                                autofocus: library.romDirectories.isEmpty,
                                onTap: () => _addFolderFromSettings(
                                  context,
                                  library,
                                  setState,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                child: ElevatedButton.icon(
                                  onPressed: () => _addFolderFromSettings(
                                    context,
                                    library,
                                    setState,
                                  ),
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add Folder'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Open the ROM folder setup dialog (set folder for sync, import on reinstall).
  ///
  /// On Android TV there is no native folder picker worth surfacing — ROMs
  /// arrive via the built-in HTTP upload server. Short-circuit to that
  /// dialog directly so TV users never see the intermediate "Set Up Your
  /// Games Folder" step.
  Future<void> _openRomFolderSetup(
    BuildContext context,
    void Function(void Function()) setState,
  ) async {
    final parentContext = context;

    if (TvDetector.isTV) {
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: false,
        builder: (_) => TvHttpUploadDialog(parentContext: parentContext),
      );
      if (result == true && parentContext.mounted) {
        await parentContext
            .read<SettingsService>()
            .markRomFolderSetupCompleted();
      }
      if (context.mounted) setState(() {});
      return;
    }

    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (_) =>
          RomFolderSetupDialog(allowSkip: true, parentContext: parentContext),
    );
    if (context.mounted) setState(() {});
  }

  /// Add folder: on TV use HTTP upload; on phone use SAF; on desktop use FilePicker.
  Future<void> _addFolderFromSettings(
    BuildContext context,
    GameLibraryService library,
    void Function(void Function()) setState,
  ) async {
    List<String>? importedPaths;

    // On TV, use HTTP upload instead of folder picker
    if (TvDetector.isTV) {
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: false,
        builder: (ctx) => TvHttpUploadDialog(parentContext: context),
      );
      if (!context.mounted) return;
      if (result == true) {
        setState(() {});
      }
      return;
    }

    // Phone/tablet: use native SAF folder picker
    if (Platform.isAndroid) {
      try {
        final result = await _deviceChannel.invokeMethod<List<dynamic>>(
          'importRomsFromFolder',
        );
        importedPaths = result?.cast<String>();
      } catch (e) {
        debugPrint('SettingsScreen: SAF folder import failed — $e');
        importedPaths = null;
      }
    }

    if (!context.mounted) return;

    // Android SAF: add each imported file
    if (importedPaths != null && importedPaths.isNotEmpty && context.mounted) {
      final addedGames = <GameRom>[];
      for (final path in importedPaths) {
        if (!context.mounted) break;
        final game = await library.addRom(path);
        if (game != null) addedGames.add(game);
      }
      if (context.mounted) setState(() {});
      if (addedGames.isNotEmpty && context.mounted) {
        _autoFetchCovers(context, addedGames, library);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                addedGames.isNotEmpty
                    ? 'Imported ${addedGames.length} ROM${addedGames.length == 1 ? '' : 's'} from folder'
                    : 'No new ROM files found in selected folder',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
      }
      return;
    }

    if (importedPaths != null && importedPaths.isEmpty && context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('No ROM files found in selected folder'),
            duration: Duration(seconds: 2),
          ),
        );
      return;
    }

    // Non-Android or FilePicker path (desktop, iOS)
    if (!Platform.isAndroid && context.mounted) {
      final result = await FilePicker.getDirectoryPath();
      if (!context.mounted) return;
      if (result != null) {
        await library.addRomDirectory(result);
        if (!context.mounted) return;
        setState(() {});
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(content: Text('Folder added')));
      }
    }
  }

  /// Fire-and-forget: download cover art for newly imported games.
  void _autoFetchCovers(
    BuildContext context,
    List<GameRom> games,
    GameLibraryService library,
  ) {
    final coverService = context.read<CoverArtService>();
    () async {
      for (final game in games) {
        if (game.coverPath != null) continue;
        try {
          final path = await coverService.fetchCoverArt(game);
          if (path != null) {
            await library.setCoverArt(game, path);
          }
        } catch (e) {
          debugPrint(
            'SettingsScreen: failed to fetch cover art for "${game.name}" — $e',
          );
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }();
  }

  void _confirmReset(BuildContext context, SettingsService settings) {
    final colors = AppColorTheme.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          'Reset Settings?',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          'This will reset all settings to their default values.',
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TvFocusable(
            autofocus: true,
            onTap: () => Navigator.pop(dialogContext),
            borderRadius: BorderRadius.circular(8),
            child: TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
          ),
          TvFocusable(
            onTap: () {
              settings.resetToDefaults();
              Navigator.pop(dialogContext);
            },
            borderRadius: BorderRadius.circular(8),
            child: TextButton(
              onPressed: () {
                settings.resetToDefaults();
                Navigator.pop(dialogContext);
              },
              child: Text('Reset', style: TextStyle(color: colors.error)),
            ),
          ),
        ],
      ),
    ).then((_) {
      // Restore focus to settings list after dialog dismissal for TV
      if (mounted) _keyFocusNode.requestFocus();
    });
  }

  Future<void> _exportAllSaves(BuildContext context) async {
    final library = context.read<GameLibraryService>();
    final emulator = context.read<EmulatorService>();
    final messenger = ScaffoldMessenger.of(context);
    final games = library.games;

    if (games.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('No games in library to export')),
        );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _BackupProgressDialog(
        title: 'Exporting Saves',
        games: games,
        appSaveDir: emulator.saveDir,
      ),
    ).then((_) {
      // Restore focus to settings list after dialog dismissal for TV
      if (mounted) _keyFocusNode.requestFocus();
    });
  }

  Future<void> _importSaves(BuildContext context) async {
    final library = context.read<GameLibraryService>();
    final emulator = context.read<EmulatorService>();
    final messenger = ScaffoldMessenger.of(context);
    final games = library.games;

    if (games.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Add games to library first before importing saves'),
          ),
        );
      return;
    }

    final zipPath = await SaveBackupService.pickZipFile();
    if (zipPath == null || !mounted) return;

    // Use this.context after mounted check since the parameter context
    // shouldn't be used after an async gap
    showDialog(
      context: this.context,
      barrierDismissible: false,
      builder: (ctx) => _ImportRestoreDialog(
        zipPath: zipPath,
        games: games,
        appSaveDir: emulator.saveDir,
      ),
    ).then((_) {
      // Restore focus to settings list after dialog dismissal for TV
      if (mounted) _keyFocusNode.requestFocus();
    });
  }

  Future<void> _backupToDrive(BuildContext context) async {
    final library = context.read<GameLibraryService>();
    final emulator = context.read<EmulatorService>();
    final messenger = ScaffoldMessenger.of(context);
    final games = library.games;

    if (games.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('No games in library to backup')),
        );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          _DriveBackupDialog(games: games, appSaveDir: emulator.saveDir),
    ).then((_) {
      // Restore focus to settings list after dialog dismissal for TV
      if (mounted) _keyFocusNode.requestFocus();
    });
  }

  Future<void> _restoreFromDrive(BuildContext context) async {
    final library = context.read<GameLibraryService>();
    final emulator = context.read<EmulatorService>();
    final messenger = ScaffoldMessenger.of(context);

    if (library.games.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Add games to library first before restoring'),
          ),
        );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _DriveRestoreDialog(
        games: library.games,
        appSaveDir: emulator.saveDir,
      ),
    ).then((_) {
      // Restore focus to settings list after dialog dismissal for TV
      if (mounted) _keyFocusNode.requestFocus();
    });
  }

  Future<void> _buyRemoveAds(BuildContext context) async {
    final purchaseService = context.read<RemoveAdsPurchaseService>();
    final started = await purchaseService.buyRemoveAds();
    if (!context.mounted) return;

    final message = started
        ? 'Purchase started. Complete checkout to remove ads.'
        : (purchaseService.errorMessage ?? 'Could not start purchase.');

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _restoreRemoveAdsPurchase(BuildContext context) async {
    final purchaseService = context.read<RemoveAdsPurchaseService>();
    await purchaseService.restorePurchases();
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          purchaseService.adsRemoved
              ? 'Purchase restored. Ads are now disabled.'
              : 'Restore started. If eligible, ads will be removed automatically.',
        ),
      ),
    );
  }
}

/// Collapsible accordion section for grouping related settings.
class _CollapsibleSection extends StatefulWidget {
  final String title;
  final IconData icon;
  final bool initiallyExpanded;
  final Widget child;

  const _CollapsibleSection({
    required this.title,
    required this.icon,
    this.initiallyExpanded = false, // ignore: unused_element_parameter
    required this.child,
  });

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection>
    with SingleTickerProviderStateMixin {
  late bool _expanded;
  late final AnimationController _animController;
  late final Animation<double> _expandAnimation;
  late final Animation<double> _rotateAnimation;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: _expanded ? 1.0 : 0.0,
    );
    _expandAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    );
    _rotateAnimation = Tween<double>(begin: 0, end: 0.5).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _animController.forward();
    } else {
      _animController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.surfaceLight, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TvFocusable(
            onTap: _toggle,
            borderRadius: const BorderRadius.all(Radius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(widget.icon, color: colors.accent, size: 22),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.title.toUpperCase(),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: colors.primary,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  RotationTransition(
                    turns: _rotateAnimation,
                    child: Icon(Icons.expand_more, color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ),
          SizeTransition(
            sizeFactor: _expandAnimation,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Divider(height: 1, color: colors.surfaceLight),
                widget.child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: colors.primary,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.surfaceLight, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(children: children),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool autofocus;

  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return TvFocusable(
      autofocus: autofocus,
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: Icon(icon, color: colors.accent),
        title: Text(
          title,
          style: TextStyle(fontSize: 14, color: colors.textPrimary),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: colors.textMuted),
        ),
        trailing: IgnorePointer(
          child: Switch(value: value, onChanged: onChanged),
        ),
        onTap: () => onChanged(!value),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String labelSuffix;
  final double labelMultiplier;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.labelSuffix = '',
    this.labelMultiplier = 1.0,
    required this.onChanged,
  });

  /// Step size for D-pad left/right adjustment.
  double get _step {
    if (divisions != null) return (max - min) / divisions!;
    return (max - min) * 0.05; // 5% steps
  }

  void _increment() {
    final next = (value + _step).clamp(min, max);
    onChanged(next);
  }

  void _decrement() {
    final next = (value - _step).clamp(min, max);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.gameButtonRight1) {
          // At max → let the focus system handle it (navigate away)
          if ((value - max).abs() < 0.001) return KeyEventResult.ignored;
          _increment();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.gameButtonLeft1) {
          // At min → let the focus system handle it (navigate away)
          if ((value - min).abs() < 0.001) return KeyEventResult.ignored;
          _decrement();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TvFocusable(
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: colors.accent, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(fontSize: 14, color: colors.textPrimary),
                    ),
                  ),
                  Text(
                    '${(value * labelMultiplier).toStringAsFixed(labelMultiplier > 1 ? 0 : 1)}$labelSuffix',
                    style: TextStyle(fontSize: 12, color: colors.accent),
                  ),
                ],
              ),
              IgnorePointer(
                ignoring: false,
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool isDestructive;
  final bool autofocus;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.isDestructive = false,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return TvFocusable(
      autofocus: autofocus,
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: Icon(
          icon,
          color: isDestructive ? colors.error : colors.accent,
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            color: isDestructive ? colors.error : colors.textPrimary,
          ),
        ),
        trailing: Icon(Icons.chevron_right, color: colors.textMuted),
        onTap: onTap,
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _InfoTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return TvFocusable(
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: Icon(icon, color: colors.accent),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: colors.textPrimary,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: colors.textMuted),
        ),
      ),
    );
  }
}

/// "Auto Optimized" graphics tile — purely informational, like a console.
///
/// There is no mode picker: Auto Optimized chooses the best graphics for
/// each system and device automatically (crisp scaling for 2D systems,
/// enhanced resolution for 3D systems on capable phones/tablets,
/// performance-first adaptive quality on Android TV). The only choice
/// users get is the Authentic Pixel Mode toggle right below this tile.
class _AutoOptimizedTile extends StatelessWidget {
  final bool active;

  const _AutoOptimizedTile({required this.active});

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(
            Icons.auto_awesome,
            color: active ? colors.accent : colors.textMuted,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Auto Optimized',
                  style: TextStyle(fontSize: 14, color: colors.textPrimary),
                ),
                Text(
                  active
                      ? 'Best graphics for each system and device'
                      : 'Off while Authentic Pixel Mode is on',
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
              ],
            ),
          ),
          if (active) Icon(Icons.check_circle, color: colors.success, size: 20),
        ],
      ),
    );
  }
}

class _PaletteTile extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const _PaletteTile({required this.selectedIndex, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.palette, color: colors.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GB Color Palette',
                      style: TextStyle(fontSize: 14, color: colors.textPrimary),
                    ),
                    Text(
                      'Custom colors for original Game Boy',
                      style: TextStyle(fontSize: 12, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 60,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: GBColorPalette.palettes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final palette = GBColorPalette.palettes[index];
                final isSelected = index == selectedIndex;
                return TvFocusable(
                  onTap: () => onChanged(index),
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 72,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? colors.primary
                            : colors.surfaceLight,
                        width: isSelected ? 2.5 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(10),
                            ),
                            child: Row(
                              children: [
                                for (final color in palette)
                                  Expanded(
                                    child: Container(
                                      color: Color(0xFF000000 | color),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? colors.primary.withValues(alpha: 0.15)
                                : colors.surface,
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(10),
                            ),
                          ),
                          child: Text(
                            GBColorPalette.names[index],
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isSelected
                                  ? colors.primary
                                  : colors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemePicker extends StatelessWidget {
  final String selectedThemeId;
  final ValueChanged<String> onChanged;

  const _ThemePicker({required this.selectedThemeId, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.surfaceLight, width: 1),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.color_lens, color: colors.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'App Theme',
                      style: TextStyle(fontSize: 14, color: colors.textPrimary),
                    ),
                    Text(
                      'Choose your vibe',
                      style: TextStyle(fontSize: 12, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...AppThemes.all.map((theme) {
            final isSelected = theme.id == selectedThemeId;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TvFocusable(
                onTap: () => onChanged(theme.id),
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.primary.withAlpha(30)
                        : colors.backgroundLight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? theme.primary : colors.surfaceLight,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Color swatch preview
                      Container(
                        width: 44,
                        height: 32,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(
                            colors: [theme.primary, theme.accent],
                          ),
                        ),
                        child: Center(
                          child: Text(
                            theme.emoji,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      // Name and color dots
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              theme.name,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                color: isSelected
                                    ? theme.primary
                                    : colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                _colorDot(theme.backgroundDark),
                                _colorDot(theme.surface),
                                _colorDot(theme.primary),
                                _colorDot(theme.accent),
                                _colorDot(theme.textPrimary),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Check mark
                      if (isSelected)
                        Icon(
                          Icons.check_circle,
                          color: theme.primary,
                          size: 22,
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _colorDot(Color color) {
    return Container(
      width: 14,
      height: 14,
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withAlpha(40), width: 0.5),
      ),
    );
  }
}

/// Gamepad skin picker — horizontal chips with mini preview
class _GamepadSkinTile extends StatelessWidget {
  final GamepadSkinType selected;
  final ValueChanged<GamepadSkinType> onChanged;

  const _GamepadSkinTile({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.brush, color: colors.accent, size: 20),
              const SizedBox(width: 12),
              Text(
                'Button Skin',
                style: TextStyle(fontSize: 14, color: colors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: GamepadSkinType.values.map((skin) {
              final isSelected = skin == selected;
              final skinData = GamepadSkinData.resolve(skin, colors);
              return TvFocusable(
                onTap: () => onChanged(skin),
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? colors.primary.withAlpha(40)
                        : colors.surface.withAlpha(120),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? colors.primary : colors.surfaceLight,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Mini preview: two small circles showing button style
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _MiniButtonPreview(
                            fill: skinData.buttonFill,
                            border: skinData.buttonBorder,
                            borderWidth: skinData.buttonBorderWidth,
                            shadows: skinData.normalShadows,
                          ),
                          const SizedBox(width: 4),
                          _MiniButtonPreview(
                            fill: skinData.buttonFillPressed,
                            border: skinData.buttonBorderPressed,
                            borderWidth: skinData.buttonBorderWidth,
                            shadows: skinData.pressedShadows,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        skin.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: isSelected
                              ? colors.primary
                              : colors.textSecondary,
                        ),
                      ),
                    ],
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

class _MiniButtonPreview extends StatelessWidget {
  final Color fill;
  final Color border;
  final double borderWidth;
  final List<BoxShadow> shadows;

  const _MiniButtonPreview({
    required this.fill,
    required this.border,
    required this.borderWidth,
    required this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: borderWidth.clamp(0.5, 2.0)),
        boxShadow: shadows,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
//  RetroAchievements account tile
// ─────────────────────────────────────────────────────────

class _RetroAchievementsTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Consumer<RetroAchievementsService>(
      builder: (context, raService, _) {
        if (raService.isLoading) {
          return _SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.accent,
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        if (raService.isLoggedIn) {
          final profile = raService.profile;
          return _SettingsCard(
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: colors.primary,
                  backgroundImage: profile != null
                      ? NetworkImage(profile.profileImageUrl)
                      : null,
                  child: profile == null
                      ? Icon(Icons.person, color: colors.textPrimary)
                      : null,
                ),
                title: Text(
                  raService.username ?? 'Player',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  profile?.displaySummary ?? '0 points . 0 softcore points',
                  style: TextStyle(fontSize: 11, color: colors.textMuted),
                ),
              ),
              const Divider(height: 1),
              _ActionTile(
                icon: Icons.logout,
                title: 'Sign Out',
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: colors.surface,
                      title: Text(
                        'Sign out of RetroAchievements?',
                        style: TextStyle(color: colors.textPrimary),
                      ),
                      content: Text(
                        'You will no longer earn achievements until you sign in again.',
                        style: TextStyle(color: colors.textSecondary),
                      ),
                      actions: [
                        TvFocusable(
                          onTap: () => Navigator.pop(ctx, false),
                          borderRadius: BorderRadius.circular(8),
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel'),
                          ),
                        ),
                        TvFocusable(
                          onTap: () => Navigator.pop(ctx, true),
                          borderRadius: BorderRadius.circular(8),
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(
                              'Sign Out',
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true && context.mounted) {
                    raService.logout();
                  }
                },
                isDestructive: true,
              ),
            ],
          );
        }

        // Not logged in — show error banner if login failed
        return _SettingsCard(
          children: [
            // Error banner (invalid credentials, network failure, etc.)
            if (raService.lastError != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.error.withAlpha(20),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: colors.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        raService.lastError!,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.error,
                          height: 1.4,
                        ),
                      ),
                    ),
                    TvFocusable(
                      onTap: raService.clearError,
                      borderRadius: BorderRadius.circular(8),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: colors.error.withAlpha(160),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Icon(
                    Icons.emoji_events_outlined,
                    size: 40,
                    color: colors.textMuted,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sign in to track achievements',
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  TvFocusable(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      raService.clearError();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RALoginScreen(),
                        ),
                      );
                    },
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.login, size: 18),
                        label: const Text('Sign In'),
                        onPressed: () {
                          raService.clearError();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const RALoginScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────
//  Backup / Restore dialogs
// ─────────────────────────────────────────────────────────

/// Dialog that exports all saves to ZIP and offers Save / Share options.
class _BackupProgressDialog extends StatefulWidget {
  final List<GameRom> games;
  final String? appSaveDir;

  const _BackupProgressDialog({
    required this.title,
    required this.games,
    required this.appSaveDir,
  });

  final String title;

  @override
  State<_BackupProgressDialog> createState() => _BackupProgressDialogState();
}

class _BackupProgressDialogState extends State<_BackupProgressDialog> {
  String _status = 'Collecting save files…';
  double _progress = 0;
  String? _zipPath;
  bool _done = false;
  bool _error = false;

  @override
  void dispose() {
    // Clean up temp ZIP when the dialog is dismissed
    SaveBackupService.deleteTempZip(_zipPath);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _export();
  }

  Future<void> _export() async {
    try {
      final zipPath = await SaveBackupService.exportAllSaves(
        games: widget.games,
        appSaveDir: widget.appSaveDir,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _progress = total > 0 ? done / total : 0;
              _status = 'Scanning game $done of $total…';
            });
          }
        },
      );

      if (!mounted) return;

      if (zipPath == null) {
        setState(() {
          _status = 'No save files found.';
          _done = true;
        });
        return;
      }

      final fileSize = File(zipPath).lengthSync();
      final sizeMb = (fileSize / (1024 * 1024)).toStringAsFixed(1);

      setState(() {
        _zipPath = zipPath;
        _status = 'Backup ready! ($sizeMb MB)';
        _done = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Export failed: $e';
          _done = true;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            _error
                ? Icons.error_outline
                : (_done ? Icons.check_circle : Icons.archive),
            color: _error
                ? colors.error
                : (_done ? colors.accent : colors.textSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.title,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_done) ...[
            LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              backgroundColor: colors.surfaceLight,
              valueColor: AlwaysStoppedAnimation(colors.accent),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            _status,
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
        ],
      ),
      actions: [
        if (_done && !_error)
          TvFocusable(
            onTap: _zipPath != null
                ? () {
                    SaveBackupService.shareZip(_zipPath!);
                  }
                : null,
            borderRadius: BorderRadius.circular(8),
            child: TextButton.icon(
              icon: const Icon(Icons.share, size: 18),
              label: const Text('Share'),
              onPressed: _zipPath != null
                  ? () {
                      SaveBackupService.shareZip(_zipPath!);
                    }
                  : null,
            ),
          ),
        if (_done && !_error)
          TvFocusable(
            onTap: _zipPath != null
                ? () async {
                    final navigator = Navigator.of(context);
                    final messenger = ScaffoldMessenger.of(context);
                    final saved = await SaveBackupService.saveZipToUserLocation(
                      _zipPath!,
                    );
                    if (saved != null && mounted) {
                      navigator.pop();
                      messenger
                        ..clearSnackBars()
                        ..showSnackBar(
                          SnackBar(content: Text('Saved to $saved')),
                        );
                    }
                  }
                : null,
            borderRadius: BorderRadius.circular(8),
            child: TextButton.icon(
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('Save to…'),
              onPressed: _zipPath != null
                  ? () async {
                      final navigator = Navigator.of(context);
                      final messenger = ScaffoldMessenger.of(context);
                      final saved =
                          await SaveBackupService.saveZipToUserLocation(
                            _zipPath!,
                          );
                      if (saved != null && mounted) {
                        navigator.pop();
                        messenger
                          ..clearSnackBars()
                          ..showSnackBar(
                            SnackBar(content: Text('Saved to $saved')),
                          );
                      }
                    }
                  : null,
            ),
          ),
        TvFocusable(
          onTap: () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(8),
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              _done || _error ? 'Close' : 'Cancel',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

/// Dialog that previews a backup ZIP and lets the user confirm the import.
class _ImportRestoreDialog extends StatefulWidget {
  final String zipPath;
  final List<GameRom> games;
  final String? appSaveDir;

  const _ImportRestoreDialog({
    required this.zipPath,
    required this.games,
    this.appSaveDir,
  });

  @override
  State<_ImportRestoreDialog> createState() => _ImportRestoreDialogState();
}

class _ImportRestoreDialogState extends State<_ImportRestoreDialog> {
  ImportPreview? _preview;
  String _status = 'Reading backup…';
  bool _loading = true;
  bool _restoring = false;
  bool _done = false;
  bool _error = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    try {
      final preview = await SaveBackupService.previewZip(
        zipPath: widget.zipPath,
        games: widget.games,
      );

      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
        if (preview.matchedFileCount == 0) {
          _status =
              'No matching save files found.\n'
              'Make sure the games are in your library.';
          _error = true;
        } else {
          _status = '';
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Failed to read ZIP: $e';
          _loading = false;
          _error = true;
        });
      }
    }
  }

  Future<void> _restore() async {
    if (_restoring) return;
    setState(() {
      _restoring = true;
      _status = 'Restoring saves…';
      _progress = 0;
    });

    try {
      final count = await SaveBackupService.importFromZip(
        zipPath: widget.zipPath,
        games: widget.games,
        appSaveDir: widget.appSaveDir,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _progress = total > 0 ? done / total : 0;
              _status = 'Restoring file $done of $total…';
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _done = true;
          _restoring = false;
          _status = count > 0
              ? 'Successfully restored $count save file${count == 1 ? '' : 's'}!'
              : 'No files were restored.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Restore failed: $e';
          _restoring = false;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final preview = _preview;
    final showPreview = preview != null && !_restoring && !_done && !_error;

    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            _error
                ? Icons.error_outline
                : (_done ? Icons.check_circle : Icons.download),
            color: _error
                ? colors.error
                : (_done ? colors.accent : colors.textSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Import Saves',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_loading || _restoring) ...[
              LinearProgressIndicator(
                value: _restoring && _progress > 0 ? _progress : null,
                backgroundColor: colors.surfaceLight,
                valueColor: AlwaysStoppedAnimation(colors.accent),
              ),
              const SizedBox(height: 12),
            ],

            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _status,
                  style: TextStyle(
                    color: _error
                        ? colors.error
                        : (_done ? colors.accent : colors.textSecondary),
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

            // Preview section
            if (showPreview) ...[
              // ZIP info
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.archive, size: 16, color: colors.accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Backup: ${preview.zipSizeFormatted}',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (preview.exportDateFormatted != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Created: ${preview.exportDateFormatted}',
                        style: TextStyle(fontSize: 12, color: colors.textMuted),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '${preview.matchedFileCount} file${preview.matchedFileCount == 1 ? '' : 's'} '
                      'for ${preview.matchedGames.length} game${preview.matchedGames.length == 1 ? '' : 's'} '
                      'will be restored',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.accent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (preview.unmatchedFiles.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${preview.unmatchedFiles.length} file${preview.unmatchedFiles.length == 1 ? '' : 's'} '
                        'skipped (no matching game in library)',
                        style: TextStyle(fontSize: 11, color: colors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // Game list
              if (preview.matchedGames.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: preview.matchedGames.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: colors.surfaceLight),
                    itemBuilder: (context, index) {
                      final entry = preview.matchedGames.entries.elementAt(
                        index,
                      );
                      final gameName = entry.key;
                      final files = entry.value;

                      // Categorize files
                      final hasSram = files.any((f) => f.endsWith('.sav'));
                      final stateCount = files
                          .where((f) => RegExp(r'\.ss\d$').hasMatch(f))
                          .length;
                      final screenshotCount = files
                          .where((f) => f.endsWith('.png'))
                          .length;

                      final details = <String>[];
                      if (hasSram) details.add('SRAM');
                      if (stateCount > 0) {
                        details.add(
                          '$stateCount save state${stateCount == 1 ? '' : 's'}',
                        );
                      }
                      if (screenshotCount > 0) {
                        details.add(
                          '$screenshotCount screenshot${screenshotCount == 1 ? '' : 's'}',
                        );
                      }

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 4,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.videogame_asset,
                              size: 16,
                              color: colors.accent,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    gameName,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.textPrimary,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (details.isNotEmpty)
                                    Text(
                                      details.join(' · '),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: colors.textMuted,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

              const SizedBox(height: 8),

              // Warning
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Colors.orange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This will overwrite any existing save data for the matched games.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade300,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        // Restore button (only shown during preview)
        if (showPreview && preview.matchedFileCount > 0)
          TvFocusable(
            onTap: _restore,
            borderRadius: BorderRadius.circular(8),
            child: TextButton.icon(
              icon: Icon(Icons.restore, size: 18, color: colors.accent),
              label: Text('Restore', style: TextStyle(color: colors.accent)),
              onPressed: _restore,
            ),
          ),
        // Close / Cancel
        TvFocusable(
          onTap: _restoring ? null : () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(8),
          child: TextButton(
            onPressed: _restoring ? null : () => Navigator.pop(context),
            child: Text(
              _done || _error ? 'Close' : 'Cancel',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

/// Dialog that handles Google Drive backup (sign in → export → upload).
class _DriveBackupDialog extends StatefulWidget {
  final List<GameRom> games;
  final String? appSaveDir;

  const _DriveBackupDialog({required this.games, required this.appSaveDir});

  @override
  State<_DriveBackupDialog> createState() => _DriveBackupDialogState();
}

class _DriveBackupDialogState extends State<_DriveBackupDialog> {
  String _status = 'Signing in to Google…';
  bool _done = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      // Step 1: Sign in
      final signedIn = await SaveBackupService.googleSignIn();
      if (!signedIn) {
        if (mounted) {
          setState(() {
            _status =
                'Google Sign-In cancelled or failed.\n\n'
                'Make sure Google Sign-In is configured in your project.';
            _done = true;
            _error = true;
          });
        }
        return;
      }

      // Step 2: Export to ZIP
      if (mounted) setState(() => _status = 'Creating backup ZIP…');
      final zipPath = await SaveBackupService.exportAllSaves(
        games: widget.games,
        appSaveDir: widget.appSaveDir,
      );

      if (zipPath == null) {
        if (mounted) {
          setState(() {
            _status = 'No save files found to backup.';
            _done = true;
          });
        }
        return;
      }

      // Step 3: Upload to Drive
      if (mounted) setState(() => _status = 'Uploading to Google Drive…');
      final fileId = await SaveBackupService.uploadToDrive(zipPath);

      if (mounted) {
        setState(() {
          _done = true;
          if (fileId != null) {
            _status =
                'Backup uploaded to Google Drive!\n'
                'Saved in the "RetroPal" folder.';
          } else {
            _status = 'Upload to Google Drive failed.';
            _error = true;
          }
        });
      }

      // Clean up temp ZIP
      try {
        File(zipPath).deleteSync();
      } catch (e) {
        debugPrint('SettingsScreen: failed to delete temp ZIP — $e');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Error: $e';
          _done = true;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            _error
                ? Icons.error_outline
                : (_done ? Icons.cloud_done : Icons.cloud_upload),
            color: _error
                ? colors.error
                : (_done ? colors.accent : colors.textSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Google Drive Backup',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_done) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          Text(
            _status,
            style: TextStyle(
              color: _error ? colors.error : colors.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TvFocusable(
          onTap: () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(8),
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              _done ? 'Close' : 'Cancel',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

/// Dialog that lists Drive backups and lets user pick one to restore.
class _DriveRestoreDialog extends StatefulWidget {
  final List<GameRom> games;
  final String? appSaveDir;

  const _DriveRestoreDialog({required this.games, this.appSaveDir});

  @override
  State<_DriveRestoreDialog> createState() => _DriveRestoreDialogState();
}

class _DriveRestoreDialogState extends State<_DriveRestoreDialog> {
  String _status = 'Signing in to Google…';
  List<drive.File>? _backups;
  bool _loading = true;
  bool _error = false;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  Future<void> _loadBackups() async {
    try {
      final signedIn = await SaveBackupService.googleSignIn();
      if (!signedIn) {
        if (mounted) {
          setState(() {
            _status = 'Google Sign-In cancelled or failed.';
            _loading = false;
            _error = true;
          });
        }
        return;
      }

      if (mounted) setState(() => _status = 'Loading backups…');
      final backups = await SaveBackupService.listDriveBackups();

      if (mounted) {
        setState(() {
          _backups = backups;
          _loading = false;
          _status = backups.isEmpty
              ? 'No backups found in Google Drive.\n'
                    'Use "Backup to Google Drive" first.'
              : 'Select a backup to restore:';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Error: $e';
          _loading = false;
          _error = true;
        });
      }
    }
  }

  Future<void> _restore(drive.File backup) async {
    if (_restoring) return;
    setState(() {
      _restoring = true;
      _status = 'Downloading ${backup.name}…';
    });

    try {
      final zipPath = await SaveBackupService.downloadFromDrive(backup.id!);
      if (!mounted) return;
      if (zipPath == null) {
        if (mounted) {
          setState(() {
            _status = 'Download failed.';
            _restoring = false;
            _error = true;
          });
        }
        return;
      }

      if (mounted) setState(() => _status = 'Restoring saves…');
      final count = await SaveBackupService.importFromZip(
        zipPath: zipPath,
        games: widget.games,
        appSaveDir: widget.appSaveDir,
      );

      // Clean up temp file
      try {
        File(zipPath).deleteSync();
      } catch (e) {
        debugPrint('SettingsScreen: failed to delete temp Drive ZIP — $e');
      }

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text(
                count > 0
                    ? 'Restored $count save file${count == 1 ? '' : 's'} from Drive'
                    : 'No matching save files found in backup',
              ),
            ),
          );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Restore failed: $e';
          _restoring = false;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(
            _error ? Icons.error_outline : Icons.cloud_download,
            color: _error ? colors.error : colors.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Restore from Drive',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading || _restoring) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            Text(
              _status,
              style: TextStyle(
                color: _error ? colors.error : colors.textSecondary,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            if (_backups != null && _backups!.isNotEmpty && !_restoring) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 250),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _backups!.length,
                  itemBuilder: (context, index) {
                    final backup = _backups![index];
                    final modified = backup.modifiedTime;
                    final sizeBytes = int.tryParse(backup.size ?? '') ?? 0;
                    final sizeMb = (sizeBytes / (1024 * 1024)).toStringAsFixed(
                      1,
                    );
                    final dateStr = modified != null
                        ? '${modified.year}-${modified.month.toString().padLeft(2, '0')}-${modified.day.toString().padLeft(2, '0')} '
                              '${modified.hour.toString().padLeft(2, '0')}:${modified.minute.toString().padLeft(2, '0')}'
                        : 'Unknown date';

                    return TvFocusable(
                      onTap: () => _restore(backup),
                      borderRadius: BorderRadius.circular(8),
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.archive, size: 20),
                        title: Text(
                          backup.name ?? 'Backup',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '$dateStr · $sizeMb MB',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.textMuted,
                          ),
                        ),
                        onTap: () => _restore(backup),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TvFocusable(
          onTap: _restoring ? null : () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(8),
          child: TextButton(
            onPressed: _restoring ? null : () => Navigator.pop(context),
            child: Text('Close', style: TextStyle(color: colors.textSecondary)),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  BIOS tab — per-platform section
// ═══════════════════════════════════════════════════════════════════════

class _BiosPlatformSection extends StatefulWidget {
  final GamePlatform platform;
  final BiosService biosService;
  final String title;
  final String subtitle;
  final bool autofocus;

  const _BiosPlatformSection({
    required this.platform,
    required this.biosService,
    required this.title,
    required this.subtitle,
    this.autofocus = false,
  });

  @override
  State<_BiosPlatformSection> createState() => _BiosPlatformSectionState();
}

class _BiosPlatformSectionState extends State<_BiosPlatformSection> {
  late Future<List<BiosFileStatus>> _statusFuture;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _statusFuture = widget.biosService.listBios(widget.platform);
    });
  }

  Future<String?> _pickBiosSourcePath() async {
    if (Platform.isAndroid) {
      try {
        final path = await _deviceChannel.invokeMethod<String>('pickBiosFile');
        if (path != null) return path;
      } catch (e) {
        debugPrint('SettingsScreen: native BIOS picker failed — $e');
      }
    }

    final result = await FilePicker.pickFile(type: FileType.any);
    return result?.path;
  }

  Future<void> _pickAndImport(BiosSpec spec) async {
    final sourcePath = await _pickBiosSourcePath();
    if (sourcePath == null) return;
    final ok = await widget.biosService.importBiosFile(
      platform: widget.platform,
      biosId: spec.id,
      sourcePath: sourcePath,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok != null
                ? 'Imported ${spec.label} as ${spec.filename}'
                : 'Failed to import ${spec.label}',
          ),
        ),
      );
    _refresh();
  }

  Future<void> _delete(BiosSpec spec) async {
    await widget.biosService.deleteBios(
      platform: widget.platform,
      biosId: spec.id,
    );
    if (!mounted) return;
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(title: widget.title),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            widget.subtitle,
            style: TextStyle(
              fontSize: 12,
              color: colors.textMuted,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<BiosFileStatus>>(
          future: _statusFuture,
          builder: (context, snapshot) {
            final statuses = snapshot.data ?? const <BiosFileStatus>[];
            return _SettingsCard(
              children: [
                for (var i = 0; i < statuses.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _BiosFileTile(
                    status: statuses[i],
                    autofocus: widget.autofocus && i == 0,
                    onImport: () => _pickAndImport(statuses[i].spec),
                    onDelete: statuses[i].spec.kind == BiosKind.bundled
                        ? null
                        : () => _delete(statuses[i].spec),
                  ),
                ],
                if (statuses.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No BIOS files defined.',
                      style: TextStyle(color: colors.textMuted),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _BiosFileTile extends StatelessWidget {
  final BiosFileStatus status;
  final VoidCallback onImport;
  final VoidCallback? onDelete;
  final bool autofocus;

  const _BiosFileTile({
    required this.status,
    required this.onImport,
    required this.onDelete,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final spec = status.spec;
    final IconData icon;
    final Color iconColor;
    final String statusText;
    if (!status.exists) {
      icon = Icons.remove_circle_outline;
      iconColor = colors.textMuted;
      statusText = spec.kind == BiosKind.bundled
          ? 'Will deploy on first launch'
          : 'Missing';
    } else if (status.valid) {
      icon = Icons.check_circle;
      iconColor = colors.success;
      statusText = spec.kind == BiosKind.bundled ? 'Bundled · active' : 'OK';
    } else {
      icon = Icons.error_outline;
      iconColor = colors.warning;
      statusText = status.hashChecked
          ? 'Hash mismatch'
          : 'Invalid · ${status.actualSize} B';
    }
    return TvFocusable(
      autofocus: autofocus,
      onTap: onImport,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          spec.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 11,
                          color: iconColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${spec.filename} · ${spec.description}',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.textMuted,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            if (onDelete != null && status.exists) ...[
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Delete ${spec.filename}',
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: colors.textMuted,
                ),
                onPressed: onDelete,
              ),
            ],
            const SizedBox(width: 4),
            Icon(
              spec.kind == BiosKind.bundled
                  ? Icons.lock_outline
                  : Icons.upload_file,
              size: 18,
              color: spec.kind == BiosKind.bundled
                  ? colors.textMuted
                  : colors.accent,
            ),
          ],
        ),
      ),
    );
  }
}
