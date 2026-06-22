import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../models/game_rom.dart';
import '../services/batch_import_service.dart';
import '../services/cover_art_service.dart';
import '../services/game_library_service.dart';
import '../services/rom_folder_service.dart';
import '../services/settings_service.dart';
import '../utils/theme.dart';
import '../utils/tv_detector.dart';
import 'import_progress_dialog.dart';
import 'tv_focusable.dart';
import 'tv_http_upload_dialog.dart';

/// Dialog shown on first launch to encourage users to set up a ROMs folder.
///
/// When the user selects a folder:
/// 1. ROMs and saves are imported from that folder to internal storage
/// 2. The folder URI/path is persisted for future sync
/// 3. New saves will be synced to this folder when created
///
/// On reinstall: user selects the same folder again to restore ROMs and saves.
class RomFolderSetupDialog extends StatefulWidget {
  /// Whether to allow dismissing without selecting (e.g. "Skip for now").
  final bool allowSkip;

  /// Context from the caller that has [SettingsService], [GameLibraryService],
  /// [CoverArtService] in its ancestor tree. Required because the dialog is
  /// built in an overlay whose context may not include these providers.
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

  /// Live import progress, rendered inline inside this dialog (instead of
  /// stacking a separate progress dialog on top). Null until an import starts.
  final ValueNotifier<BatchImportProgress?> _progress =
      ValueNotifier<BatchImportProgress?>(null);

  @override
  void initState() {
    super.initState();
    // Request focus with a slight delay to ensure the dialog is fully built
    // and wins the focus competition against background widgets
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _selectFolderFocusNode.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    _selectFolderFocusNode.dispose();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _pickAndImport(BuildContext context) async {
    // On TV, use HTTP upload instead of file picker
    if (TvDetector.isTV) {
      await _showTvHttpUpload(context);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _importedCount = 0;
    });
    _progress.value = null;

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

      // result is a folder URI (Android SAF) or path (desktop)
      final folderUriOrPath = result;
      if (Platform.isAndroid && folderUriOrPath.startsWith('content://')) {
        // Android SAF: import from content URI. The native importer copies
        // ROMs (and any .zip archives) into internal storage and returns
        // their paths; we then add each one with inline progress (shown in
        // this same dialog) for the current ROM name + percentage,
        // auto-extracting any .zip archives (e.g. PS1 cue/bin sets) as we go.
        _progress.value = const BatchImportProgress(
          totalFiles: 0,
          processedFiles: 0,
          importedGames: 0,
          skippedDuplicates: 0,
          currentFile: 'Copying files from folder…',
        );
        final internalPaths = await RomFolderService.importFromFolder(
          folderUriOrPath,
        );
        if (!context.mounted) return;
        final zipSet = internalPaths
            .where((p) => p.toLowerCase().endsWith('.zip'))
            .toSet();
        addedGames = await importFilesWithProgress(
          paths: internalPaths,
          zipPaths: zipSet,
          library: library,
          alreadyInternal: true,
          onProgress: (pr) => _progress.value = pr,
        );
      } else if (folderUriOrPath.isNotEmpty) {
        // Direct path (desktop): copy ROMs and saves to internal storage
        final appDir = await getApplicationSupportDirectory();
        final saveDir = p.join(appDir.path, 'saves');
        if (!context.mounted) return;
        _progress.value = const BatchImportProgress(
          totalFiles: 0,
          processedFiles: 0,
          importedGames: 0,
          skippedDuplicates: 0,
          currentFile: 'Scanning folder…',
        );
        addedGames = await importDirectoryWithProgress(
          dirPath: folderUriOrPath,
          library: library,
          appSaveDir: saveDir,
          onProgress: (pr) => _progress.value = pr,
        );
      }

      if (!context.mounted) return;

      await settings.setUserRomsFolderUri(folderUriOrPath);
      await settings.markRomFolderSetupCompleted();

      // Fire-and-forget: download cover art for newly imported games
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

      if (!mounted) return;
      try {
        final nav = Navigator.of(this.context, rootNavigator: false);
        if (nav.canPop()) nav.pop(true);
      } catch (_) {
        // Dialog may already be dismissed (e.g. system back press) —
        // "No element" from Navigator.pop is safe to ignore here.
      }
    }
  }

  /// Fire-and-forget: download cover art for newly imported games.
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

  /// Inline import progress, rendered in place of the dialog's description
  /// while an import is running (no second dialog is stacked on top).
  Widget _buildProgress(AppColorTheme colors) {
    return ValueListenableBuilder<BatchImportProgress?>(
      valueListenable: _progress,
      builder: (context, p, _) {
        final determinate = p != null && p.totalFiles > 0;
        final percent = determinate ? (p.progress * 100).round() : null;
        final current = p?.currentFile;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: determinate ? p.progress : null,
                minHeight: 6,
                backgroundColor: colors.textMuted.withAlpha(38),
                valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
              ),
            ),
            const SizedBox(height: 16),
            if (determinate)
              _progressRow(
                colors,
                Icons.videogame_asset,
                'Processed',
                '${p.processedFiles} / ${p.totalFiles}',
              ),
            if (p != null && p.importedGames > 0) ...[
              const SizedBox(height: 8),
              _progressRow(
                colors,
                Icons.add_circle_outline,
                'Imported',
                '${p.importedGames}',
                valueColor: colors.success,
              ),
            ],
            if (current != null && current.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _truncateLeaf(current),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ],
            if (percent != null) ...[
              const SizedBox(height: 12),
              Center(
                child: Text(
                  '$percent%',
                  style: TextStyle(
                    color: colors.accent,
                    fontWeight: FontWeight.bold,
                    fontSize: TvDetector.isTV ? 26 : 22,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _progressRow(
    AppColorTheme colors,
    IconData icon,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: valueColor ?? colors.textSecondary),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: TvDetector.isTV ? 15 : 13,
            ),
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? colors.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: TvDetector.isTV ? 15 : 13,
          ),
        ),
      ],
    );
  }

  /// [currentFile] may be a full path or a status string (e.g.
  /// "Extracting foo.zip…"). Show just the filename for paths; pass status
  /// strings through unchanged.
  String _truncateLeaf(String value) {
    if (value.contains('/') || value.contains(r'\')) {
      final parts = value.split(RegExp(r'[/\\]'));
      return parts.isNotEmpty ? parts.last : value;
    }
    return value;
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
                      _isLoading
                          ? 'Importing Games…'
                          : 'Set Up Your Games Folder',
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
                    if (_isLoading)
                      _buildProgress(colors)
                    else
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

/// Show the ROM folder setup dialog if the user hasn't completed setup.
/// Call this after navigating to HomeScreen.
///
/// On Android TV there is no SAF folder picker UX worth surfacing — the
/// standard flow is to upload ROMs from a phone/PC over the built-in HTTP
/// server. We skip the intermediate "Set Up Your Games Folder" dialog and
/// go straight to [TvHttpUploadDialog]. When the upload finishes we mark
/// the ROM-folder setup as completed so this prompt doesn't fire again on
/// the next launch (matching the behaviour of the folder-picker path on
/// phones/tablets).
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

  if (TvDetector.isTV) {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (_) => TvHttpUploadDialog(parentContext: parentContext),
    );
    if (result == true && parentContext.mounted) {
      await parentContext.read<SettingsService>().markRomFolderSetupCompleted();
    }
    return;
  }

  await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: false,
    builder: (_) =>
        RomFolderSetupDialog(allowSkip: true, parentContext: parentContext),
  );
}
