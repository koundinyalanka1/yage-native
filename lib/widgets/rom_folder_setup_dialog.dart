import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../models/game_rom.dart';
import '../services/cover_art_service.dart';
import '../services/game_library_service.dart';
import '../services/rom_folder_service.dart';
import '../services/settings_service.dart';
import '../utils/theme.dart';
import '../utils/tv_detector.dart';
import 'import_progress_dialog.dart';
import 'tv_focusable.dart';
import 'tv_http_upload_dialog.dart';

class RomFolderSetupDialog extends StatefulWidget {
  final bool allowSkip;

  final BuildContext parentContext;

  const RomFolderSetupDialog({
    super.key,
    this.allowSkip = true,
    required this.parentContext,
  });

  @override
  State<RomFolderSetupDialog> createState() => _RomFolderSetupDialogState();
}

class _RomFolderSetupDialogState extends State<RomFolderSetupDialog> {
  bool _isLoading = false;
  String? _error;
  int _importedCount = 0;
  final FocusNode _selectFolderFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _selectFolderFocusNode.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _selectFolderFocusNode.dispose();
    super.dispose();
  }

  Future<void> _pickAndImport(BuildContext context) async {
    if (TvDetector.isTV) {
      await _showTvHttpUpload(context);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _importedCount = 0;
    });

    final navigator = Navigator.of(context, rootNavigator: false);
    final parentContext = widget.parentContext;

    try {
      final result = await RomFolderService.pickFolder(context);
      if (!context.mounted) return;
      if (result == null) {
        setState(() => _isLoading = false);
        return;
      }

      if (!parentContext.mounted) return;
      final settings = parentContext.read<SettingsService>();
      final library = parentContext.read<GameLibraryService>();
      final coverService = parentContext.read<CoverArtService>();

      List<GameRom> addedGames = [];
      final folderUriOrPath = result;
      if (Platform.isAndroid && folderUriOrPath.startsWith('content://')) {
        final internalPaths = await RomFolderService.importFromFolder(
          folderUriOrPath,
        );
        for (final path in internalPaths) {
          if (!context.mounted) return;
          final game = await library.addRom(path);
          if (game != null) addedGames.add(game);
        }
      } else if (folderUriOrPath.isNotEmpty) {
        final appDir = await getApplicationSupportDirectory();
        final saveDir = p.join(appDir.path, 'saves');
        if (!context.mounted) return;
        addedGames = await runImportFromDirectoryWithProgress(
          context,
          dirPath: folderUriOrPath,
          library: library,
          appSaveDir: saveDir,
        );
      }

      if (!context.mounted) return;

      await settings.setUserRomsFolderUri(folderUriOrPath);
      await settings.markRomFolderSetupCompleted();
      if (addedGames.isNotEmpty) {
        _autoFetchCovers(coverService, library, addedGames);
      }

      if (!context.mounted) return;
      setState(() {
        _isLoading = false;
        _importedCount = addedGames.length;
      });

      if (!context.mounted) return;
      if (navigator.canPop()) navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _showTvHttpUpload(BuildContext context) async {
    final parentContext = widget.parentContext;
    final navigator = Navigator.of(context, rootNavigator: false);

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (ctx) => TvHttpUploadDialog(parentContext: parentContext),
    );

    if (result == true) {
      if (!parentContext.mounted) return;
      final settings = parentContext.read<SettingsService>();
      await settings.markRomFolderSetupCompleted();

      if (!context.mounted) return;
      if (navigator.canPop()) navigator.pop(true);
    }
  }

  void _autoFetchCovers(
    CoverArtService coverService,
    GameLibraryService library,
    List<GameRom> games,
  ) {
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
            'RomFolderSetup: failed to fetch cover art for "${game.name}" — $e',
          );
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }();
  }

  void _skip(BuildContext context) {
    if (widget.allowSkip) {
      final nav = Navigator.of(context, rootNavigator: false);
      if (nav.canPop()) nav.pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final maxDialogWidth = MediaQuery.of(context).size.width * 0.9;

    return PopScope(
      canPop: widget.allowSkip && !_isLoading,
      child: Shortcuts(
        shortcuts: {
          SingleActivator(LogicalKeyboardKey.escape): const DismissIntent(),
          SingleActivator(LogicalKeyboardKey.goBack): const DismissIntent(),
          SingleActivator(LogicalKeyboardKey.browserBack):
              const DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                if (widget.allowSkip && !_isLoading) _skip(context);
                return null;
              },
            ),
          },
          child: Focus(
            child: AlertDialog(
              backgroundColor: colors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: colors.primary.withAlpha(77), width: 2),
              ),
              title: Row(
                children: [
                  Icon(Icons.folder_open, color: colors.accent, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Set Up Your Games Folder',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: TvDetector.isTV ? 22 : 20,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: TvDetector.isTV
                    ? (maxDialogWidth < 400 ? maxDialogWidth : 400)
                    : (maxDialogWidth < 320 ? maxDialogWidth : 320),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose a folder to store your ROMs and save data. This lets you:\n\n'
                      '• Keep your games and saves in one place\n'
                      '• Restore everything after reinstalling the app\n'
                      '• Sync new saves to your folder automatically',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: TvDetector.isTV ? 16 : 14,
                        height: 1.5,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.error.withAlpha(51),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              color: colors.error,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: colors.error,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_importedCount > 0) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Imported $_importedCount game${_importedCount == 1 ? '' : 's'}!',
                        style: TextStyle(
                          color: colors.success,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: TvFocusable(
                          autofocus: true,
                          focusNode: _selectFolderFocusNode,
                          animate: false,
                          borderRadius: BorderRadius.circular(12),
                          onTap: _isLoading
                              ? null
                              : () => _pickAndImport(context),
                          onBack: widget.allowSkip
                              ? () => _skip(context)
                              : null,
                          child: FilledButton.icon(
                            onPressed: _isLoading
                                ? null
                                : () => _pickAndImport(context),
                            icon: _isLoading
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: colors.textPrimary,
                                    ),
                                  )
                                : Icon(
                                    Icons.folder_open,
                                    size: 18,
                                    color: colors.backgroundDark,
                                  ),
                            label: Text(
                              _isLoading ? 'Importing…' : 'Select Folder',
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: colors.accent,
                              foregroundColor: colors.backgroundDark,
                            ),
                          ),
                        ),
                      ),
                      if (widget.allowSkip)
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: TvFocusable(
                            animate: false,
                            subtleFocus: true,
                            borderRadius: BorderRadius.circular(12),
                            onTap: _isLoading ? null : () => _skip(context),
                            onBack: () => _skip(context),
                            child: TextButton(
                              onPressed: _isLoading
                                  ? null
                                  : () => _skip(context),
                              child: Text(
                                'Skip for now',
                                style: TextStyle(color: colors.textMuted),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> maybeShowRomFolderSetupDialog(BuildContext context) async {
  final settings = context.read<SettingsService>();
  final folderUri = settings.settings.userRomsFolderUri;
  final hasFolder = await RomFolderService.hasUsableFolder(folderUri);
  debugPrint(
    'RomFolderSetupDialog: gate => hasFolder=$hasFolder, '
    'folderValue=${folderUri == null || folderUri.trim().isEmpty ? '<empty>' : '<set>'}',
  );
  if (hasFolder) return;

  if (!context.mounted) return;
  final parentContext = context;
  await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: false,
    builder: (_) =>
        RomFolderSetupDialog(allowSkip: true, parentContext: parentContext),
  );
}
