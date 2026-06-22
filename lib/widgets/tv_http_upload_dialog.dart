import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

import '../services/cover_art_service.dart';
import '../services/game_library_service.dart';
import '../services/settings_service.dart';
import '../services/tv_http_server.dart';
import '../utils/theme.dart';
import 'tv_focusable.dart';

/// Dialog for TV that shows HTTP server upload instructions.
/// Users can upload ROMs from their phone/computer via a web browser.
class TvHttpUploadDialog extends StatefulWidget {
  final BuildContext parentContext;
  final bool allowSkip;

  const TvHttpUploadDialog({
    super.key,
    required this.parentContext,
    this.allowSkip = true,
  });

  @override
  State<TvHttpUploadDialog> createState() => _TvHttpUploadDialogState();
}

class _TvHttpUploadDialogState extends State<TvHttpUploadDialog> {
  final _server = TvHttpServer.instance;
  bool _isStarting = true;
  bool _isScanning = false;
  String? _serverUrl;
  String? _error;
  int _importedCount = 0;
  Timer? _scanTimer;

  /// Prevents double [Done] / concurrent closes; [pop] after async must be guarded.
  bool _didPop = false;

  // Focus nodes for TV navigation
  final FocusScopeNode _dialogScopeNode = FocusScopeNode(
    debugLabel: 'TvHttpUploadScope',
  );
  final FocusNode _scanFocusNode = FocusNode(debugLabel: 'ScanButton');
  final FocusNode _doneFocusNode = FocusNode(debugLabel: 'DoneButton');

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _dialogScopeNode.dispose();
    _scanFocusNode.dispose();
    _doneFocusNode.dispose();
    super.dispose();
  }

  Future<void> _startServer() async {
    setState(() {
      _isStarting = true;
      _error = null;
    });

    try {
      final url = await _server.start();
      if (mounted) {
        setState(() {
          _serverUrl = url;
          _isStarting = false;
        });

        // Start periodic scanning for new ROMs (every 5 seconds to reduce CPU)
        _startScanning();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isStarting = false;
        });
      }
    }
  }

  void _startScanning() {
    // Scan less frequently (5 seconds) to reduce main thread work
    _scanTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isScanning) {
        _scanForNewRoms();
      }
    });
  }

  /// Scan for new ROMs in background isolate
  Future<void> _scanForNewRoms({bool isManual = false}) async {
    if (_isScanning) return;
    _isScanning = true;

    if (isManual && mounted) {
      setState(() {});
    }

    try {
      final appDir = await getApplicationSupportDirectory();
      final romsPath = p.join(appDir.path, 'roms');
      final romsDir = Directory(romsPath);

      if (!await romsDir.exists()) {
        return;
      }

      if (!widget.parentContext.mounted) return;

      final library = widget.parentContext.read<GameLibraryService>();

      // Get existing paths
      final existingPaths = library.games.map((g) => g.path).toSet();

      // Scan for new ROM files in compute isolate to avoid blocking UI
      final newFiles = await compute(
        _scanDirectoryIsolate,
        _ScanParams(dirPath: romsPath, existingPaths: existingPaths),
      );

      if (newFiles.isEmpty) return;
      if (!widget.parentContext.mounted) return;

      // Add new games (this must be on main thread due to DB access)
      // Re-read existing paths in case another scan added games while isolate ran
      final currentPaths = library.games.map((g) => g.path).toSet();
      final coverService = widget.parentContext.read<CoverArtService>();

      for (final filePath in newFiles) {
        if (!widget.parentContext.mounted) break;
        if (currentPaths.contains(filePath)) continue;

        final game = await library.addRom(filePath);
        if (game != null) {
          currentPaths.add(filePath);

          if (mounted) {
            setState(() {
              _importedCount += 1;
            });
          }

          // Instantly sync cover art before proceeding to the next file
          if (game.coverPath == null) {
            try {
              final path = await coverService.fetchCoverArt(game);
              if (path != null && widget.parentContext.mounted) {
                await library.setCoverArt(game, path);
              }
            } catch (e) {
              debugPrint('TvHttpUploadDialog: failed to fetch cover art — $e');
            }
          }

          // Yield slightly to maintain 60fps UI while downloading
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
    } catch (e) {
      debugPrint('Error scanning for ROMs: $e');
    } finally {
      _isScanning = false;
      if (isManual && mounted) {
        setState(() {});
      }
    }
  }

  /// Manual scan triggered by "Scan Now" button
  Future<void> _manualScan() async {
    await _scanForNewRoms(isManual: true);
  }

  /// [showDialog] uses the root navigator by default; popping after [await] can run
  /// when the route is already gone (double Done, focus + button, etc.) — that
  /// throws inside [NavigatorState.pop] (`Bad state: No element`).
  void _safePop(bool? value) {
    if (_didPop || !mounted) return;
    try {
      // Prefer inner navigator — matches [showDialog(useRootNavigator: false)]
      // used from Home / ROM setup (nested MaterialApp in SplashScreen).
      final nav =
          Navigator.maybeOf(context, rootNavigator: false) ??
          Navigator.maybeOf(context);
      if (nav != null && nav.canPop()) {
        nav.pop(value);
        _didPop = true;
      }
    } catch (e, st) {
      debugPrint('TvHttpUploadDialog: Navigator.pop failed — $e\n$st');
    }
  }

  Future<void> _done() async {
    if (_didPop) return;
    // Stop periodic scanning to prevent race with the final scan
    _scanTimer?.cancel();
    _scanTimer = null;
    final parentCtx = widget.parentContext;

    // Final scan to catch any uploads since the last periodic scan
    await _scanForNewRoms(isManual: true);
    if (!mounted || _didPop) return;
    if (parentCtx.mounted) {
      parentCtx.read<SettingsService>().markRomFolderSetupCompleted();
    }
    _safePop(true);
  }

  void _skip() {
    if (!widget.allowSkip || _didPop) return;
    widget.parentContext.read<SettingsService>().markRomFolderSetupCompleted();
    _safePop(false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);

    return FocusScope(
      node: _dialogScopeNode,
      autofocus: true,
      onFocusChange: (focused) {
        // Aggressively trap focus: if the dialog is visible but loses focus
        // (e.g. background list rebuilt and tried to steal it), pull it back!
        if (!focused && mounted) {
          Future.microtask(() {
            if (mounted) _dialogScopeNode.requestFocus();
          });
        }
      },
      child: PopScope(
        canPop: widget.allowSkip,
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
            SingleActivator(LogicalKeyboardKey.goBack): DismissIntent(),
            SingleActivator(LogicalKeyboardKey.browserBack): DismissIntent(),
          },
          child: Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  if (widget.allowSkip) _skip();
                  return null;
                },
              ),
            },
            child: Dialog(
              backgroundColor: colors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: colors.primary.withAlpha(100),
                  width: 2,
                ),
              ),
              child: Container(
                constraints: const BoxConstraints(
                  maxWidth: 550,
                  maxHeight: 600,
                ),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Title
                    Row(
                      children: [
                        Icon(Icons.upload_file, color: colors.accent, size: 28),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Upload ROMs via Web Browser',
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Content
                    Flexible(
                      child: SingleChildScrollView(
                        child: _buildContent(colors),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Buttons at the bottom
                    _buildButtons(colors),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(AppColorTheme colors) {
    if (_isStarting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: colors.accent),
            const SizedBox(height: 16),
            Text(
              'Starting server...',
              style: TextStyle(color: colors.textSecondary),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.error.withAlpha(51),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: colors.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Failed to start server: $_error',
                style: TextStyle(color: colors.error),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Instructions
        Text(
          'On your phone or computer, open a web browser and go to:',
          style: TextStyle(color: colors.textSecondary, fontSize: 15),
        ),
        const SizedBox(height: 12),

        // Server URL
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: BoxDecoration(
            color: colors.backgroundDark,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.accent, width: 2),
          ),
          child: Column(
            children: [
              SelectableText(
                _serverUrl ?? '',
                style: TextStyle(
                  color: colors.accent,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.wifi, color: colors.success, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    'Server is running',
                    style: TextStyle(color: colors.success, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Quick steps (condensed)
        Text(
          'Quick Steps:',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        _buildCompactStep(
          colors,
          '1',
          'Open a browser on your phone/computer & go to the URL above',
        ),
        _buildCompactStep(
          colors,
          '2',
          'If your ROMs are inside a ZIP or archive, extract them first',
        ),
        _buildCompactStep(
          colors,
          '3',
          'Upload the ROM files directly — not the ZIP',
        ),

        const SizedBox(height: 12),

        // ZIP warning
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: colors.warning.withAlpha(30),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.warning.withAlpha(100)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: colors.warning, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'ZIP files are not auto-extracted. Upload the individual ROM files (.gba, .nes, .sfc, etc.) for them to appear in your library.',
                  style: TextStyle(color: colors.warning, fontSize: 12),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // Supported formats (smaller)
        Text(
          'Supported: .gba .gb .gbc .nes .unf .unif .sfc .smc .sg .sms .gg .md .gen .smd .bin .pce .sgx .cue .z64 .n64 .v64 .ngp .ngc .ws .wsc .a26 .vb .tic .p8 .p8.png',
          style: TextStyle(color: colors.textMuted, fontSize: 12),
        ),

        // Import count
        if (_importedCount > 0) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.success.withAlpha(51),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle, color: colors.success, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Imported $_importedCount game${_importedCount == 1 ? '' : 's'}!',
                  style: TextStyle(
                    color: colors.success,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCompactStep(AppColorTheme colors, String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: colors.accent.withAlpha(60),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  color: colors.accent,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildButtons(AppColorTheme colors) {
    if (_isStarting) {
      return const SizedBox.shrink();
    }

    if (_error != null) {
      return Center(
        child: TvFocusable(
          autofocus: true,
          animate: false,
          borderRadius: BorderRadius.circular(12),
          onTap: _skip,
          child: TextButton(
            onPressed: _skip,
            child: Text('Close', style: TextStyle(color: colors.textMuted)),
          ),
        ),
      );
    }

    // Use Column layout for TV - easier to navigate with D-pad
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Scan Now button
        SizedBox(
          width: double.infinity,
          child: TvFocusable(
            autofocus: true,
            focusNode: _scanFocusNode,
            animate: false,
            borderRadius: BorderRadius.circular(12),
            onTap: _isScanning ? null : _manualScan,
            child: OutlinedButton.icon(
              onPressed: _isScanning ? null : _manualScan,
              icon: _isScanning
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.accent,
                      ),
                    )
                  : Icon(Icons.refresh, size: 20, color: colors.accent),
              label: Text(
                _isScanning ? 'Scanning...' : 'Scan Now',
                style: TextStyle(color: colors.accent, fontSize: 16),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: colors.accent, width: 2),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Done button
        SizedBox(
          width: double.infinity,
          child: TvFocusable(
            focusNode: _doneFocusNode,
            animate: false,
            borderRadius: BorderRadius.circular(12),
            onTap: _done,
            onBack: widget.allowSkip ? _skip : null,
            child: FilledButton.icon(
              onPressed: _done,
              icon: Icon(Icons.check, size: 20, color: colors.backgroundDark),
              label: const Text('Done', style: TextStyle(fontSize: 16)),
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.backgroundDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Parameters for the isolate scan function
class _ScanParams {
  final String dirPath;
  final Set<String> existingPaths;

  _ScanParams({required this.dirPath, required this.existingPaths});
}

/// Scan directory for ROM files in a separate isolate
List<String> _scanDirectoryIsolate(_ScanParams params) {
  final newFiles = <String>[];
  final romExtensions = {
    '.gba',
    '.gbc',
    '.gb',
    '.sgb',
    '.nes',
    '.unf',
    '.unif',
    '.sfc',
    '.smc',
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
    '.sms',
    '.gg',
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

  void scanDir(Directory dir) {
    try {
      for (final entity in dir.listSync()) {
        if (entity is Directory) {
          scanDir(entity);
        } else if (entity is File) {
          final lpath = entity.path.toLowerCase();
          final ext = lpath.endsWith('.p8.png')
              ? '.p8.png'
              : p.extension(entity.path).toLowerCase();
          if (romExtensions.contains(ext) &&
              !params.existingPaths.contains(entity.path)) {
            newFiles.add(entity.path);
          }
        }
      }
    } catch (e) {
      debugPrint('TvHttpUpload: failed to scan directory "${dir.path}" — $e');
    }
  }

  final dir = Directory(params.dirPath);
  if (dir.existsSync()) {
    scanDir(dir);
  }

  return newFiles;
}

/// Show the TV HTTP upload dialog.
Future<bool?> showTvHttpUploadDialog(BuildContext context) async {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: false,
    builder: (_) => TvHttpUploadDialog(parentContext: context, allowSkip: true),
  );
}
