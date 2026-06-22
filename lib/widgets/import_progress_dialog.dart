import 'package:archive/archive.dart';
import 'package:flutter/material.dart';

import '../models/game_rom.dart';
import '../services/batch_import_service.dart';
import '../services/game_library_service.dart';
import 'tv_focusable.dart';

/// A dialog that shows import progress for large ROM collections.
///
/// Shows a progress bar, file count, and current file being processed.
/// Designed to keep users informed during long imports (5000+ ROMs).
class ImportProgressDialog extends StatelessWidget {
  final BatchImportProgress progress;
  final VoidCallback? onCancel;

  const ImportProgressDialog({
    super.key,
    required this.progress,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progressPercent = (progress.progress * 100).toInt();

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.folder_copy_outlined),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              progress.isComplete ? 'Import Complete' : 'Importing ROMs...',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Progress bar
          LinearProgressIndicator(
            value: progress.totalFiles > 0 ? progress.progress : null,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 16),

          // Stats
          _buildStatRow(
            icon: Icons.videogame_asset,
            label: 'Processed',
            value: '${progress.processedFiles} / ${progress.totalFiles}',
          ),
          const SizedBox(height: 8),
          _buildStatRow(
            icon: Icons.add_circle_outline,
            label: 'Imported',
            value: '${progress.importedGames}',
            color: Colors.green,
          ),
          if (progress.skippedDuplicates > 0) ...[
            const SizedBox(height: 8),
            _buildStatRow(
              icon: Icons.content_copy,
              label: 'Duplicates skipped',
              value: '${progress.skippedDuplicates}',
              color: Colors.orange,
            ),
          ],

          // Current file (truncated)
          if (progress.currentFile != null && !progress.isComplete) ...[
            const SizedBox(height: 16),
            Text(
              _truncateFilePath(progress.currentFile!),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],

          // Error message
          if (progress.error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      progress.error!,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Progress percentage
          if (!progress.isComplete) ...[
            const SizedBox(height: 16),
            Center(
              child: Text(
                '$progressPercent%',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (progress.isComplete)
          TvFocusable(
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(8),
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          )
        else if (onCancel != null)
          TvFocusable(
            onTap: onCancel,
            borderRadius: BorderRadius.circular(8),
            child: TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ),
      ],
    );
  }

  Widget _buildStatRow({
    required IconData icon,
    required String label,
    required String value,
    Color? color,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.bold, color: color),
          ),
        ),
      ],
    );
  }

  String _truncateFilePath(String path) {
    // Show just the filename, not the full path
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isNotEmpty ? parts.last : path;
  }
}

/// Shows the import progress dialog.
///
/// Returns a [ValueNotifier] that can be used to update progress.
/// Call [ValueNotifier.dispose] when done.
ValueNotifier<BatchImportProgress> showImportProgressDialog(
  BuildContext context, {
  required int totalFiles,
  VoidCallback? onCancel,
}) {
  final progressNotifier = ValueNotifier<BatchImportProgress>(
    BatchImportProgress(
      totalFiles: totalFiles,
      processedFiles: 0,
      importedGames: 0,
      skippedDuplicates: 0,
    ),
  );

  showDialog(
    context: context,
    barrierDismissible: false,
    useRootNavigator: false,
    builder: (context) => ValueListenableBuilder<BatchImportProgress>(
      valueListenable: progressNotifier,
      builder: (context, progress, _) =>
          ImportProgressDialog(progress: progress, onCancel: onCancel),
    ),
  ).then((_) {
    // Dialog was closed
  });

  return progressNotifier;
}

/// Imports a list of individually-picked ROM/archive [paths] with a progress
/// dialog that shows the current ROM name and an overall percentage.
///
/// [zipPaths] is the subset of [paths] that are archives — these go through
/// [GameLibraryService.importRomZip] (which auto-extracts and imports the
/// contained ROMs, e.g. a PS1 cue/bin set); everything else is copied via
/// [GameLibraryService.importRom]. Returns all games that were added. The
/// dialog auto-closes when the import finishes.
/// When [alreadyInternal] is true the non-archive paths are assumed to live
/// in internal storage already (e.g. copied by the Android SAF importer), so
/// they are added directly via [GameLibraryService.addRom] instead of being
/// copied again with [GameLibraryService.importRom].
Future<List<GameRom>> runFileImportWithProgress(
  BuildContext context, {
  required List<String> paths,
  required Set<String> zipPaths,
  required GameLibraryService library,
  bool alreadyInternal = false,
}) async {
  if (paths.isEmpty) return const [];

  final notifier = ValueNotifier<BatchImportProgress>(
    BatchImportProgress(
      totalFiles: paths.length,
      processedFiles: 0,
      importedGames: 0,
      skippedDuplicates: 0,
      currentFile: _leafName(paths.first),
    ),
  );

  showDialog(
    context: context,
    barrierDismissible: false,
    useRootNavigator: false,
    builder: (ctx) => ValueListenableBuilder<BatchImportProgress>(
      valueListenable: notifier,
      builder: (_, progress, _) => ImportProgressDialog(progress: progress),
    ),
  );

  try {
    return await importFilesWithProgress(
      paths: paths,
      zipPaths: zipPaths,
      library: library,
      alreadyInternal: alreadyInternal,
      onProgress: (p) => notifier.value = p,
    );
  } finally {
    if (context.mounted) {
      final nav = Navigator.of(context, rootNavigator: false);
      if (nav.canPop()) nav.pop();
    }
    notifier.dispose();
  }
}

/// Dialog-free core of [runFileImportWithProgress].
///
/// Imports each of [paths] — archives (in [zipPaths]) via
/// [GameLibraryService.importRomZip], everything else copied/added — and reports
/// progress through [onProgress]. Shows no UI of its own, so callers can render
/// progress wherever they like (e.g. inline inside another dialog).
Future<List<GameRom>> importFilesWithProgress({
  required List<String> paths,
  required Set<String> zipPaths,
  required GameLibraryService library,
  required void Function(BatchImportProgress progress) onProgress,
  bool alreadyInternal = false,
}) async {
  final added = <GameRom>[];
  if (paths.isEmpty) return added;
  var processed = 0;
  String? lastError;

  void publish({String? label, bool complete = false}) {
    onProgress(
      BatchImportProgress(
        totalFiles: paths.length,
        processedFiles: processed,
        importedGames: added.length,
        skippedDuplicates: 0,
        currentFile: label,
        isComplete: complete,
        error: lastError,
      ),
    );
  }

  for (final path in paths) {
    publish(label: _leafName(path));
    try {
      if (zipPaths.contains(path)) {
        final games = await library.importRomZip(
          path,
          onStatus: (status) => publish(label: status),
        );
        added.addAll(games);
      } else {
        final game = alreadyInternal
            ? await library.addRom(path)
            : await library.importRom(path);
        if (game != null) added.add(game);
      }
    } on ArchiveException {
      lastError = 'Failed to extract ${_leafName(path)} — file may be corrupted';
    } catch (e) {
      debugPrint('importFilesWithProgress: import failed for "$path" — $e');
    }
    processed++;
    publish(label: _leafName(path));
  }
  publish(complete: true);
  return added;
}

/// Leaf (filename) of a path, splitting on either separator.
String _leafName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isNotEmpty ? parts.last : path;
}

/// Runs [GameLibraryService.importFromDirectory] with a progress dialog.
/// Use for TV/desktop flows where the user selects a folder directly.
///
/// Shows "Importing X of Y..." with Cancel button. Returns the list of
/// imported games (or partial list if cancelled).
Future<List<GameRom>> runImportFromDirectoryWithProgress(
  BuildContext context, {
  required String dirPath,
  required GameLibraryService library,
  String? appSaveDir,
}) async {
  var cancelled = false;
  final progressNotifier = ValueNotifier<BatchImportProgress>(
    const BatchImportProgress(
      totalFiles: 0,
      processedFiles: 0,
      importedGames: 0,
      skippedDuplicates: 0,
    ),
  );

  showDialog(
    context: context,
    barrierDismissible: false,
    useRootNavigator: false,
    builder: (ctx) => ValueListenableBuilder<BatchImportProgress>(
      valueListenable: progressNotifier,
      builder: (_, progress, _) => ImportProgressDialog(
        progress: progress,
        onCancel: () => cancelled = true,
      ),
    ),
  );

  try {
    return await importDirectoryWithProgress(
      dirPath: dirPath,
      library: library,
      appSaveDir: appSaveDir,
      onProgress: (p) => progressNotifier.value = p,
      isCancelled: () => cancelled,
    );
  } finally {
    if (context.mounted) {
      final nav = Navigator.of(context, rootNavigator: false);
      if (nav.canPop()) nav.pop();
    }
    progressNotifier.dispose();
  }
}

/// Dialog-free core of [runImportFromDirectoryWithProgress].
///
/// Runs [GameLibraryService.importFromDirectory], forwarding progress through
/// [onProgress] and finishing with a terminal `isComplete` frame carrying the
/// final imported count. Shows no UI of its own.
Future<List<GameRom>> importDirectoryWithProgress({
  required String dirPath,
  required GameLibraryService library,
  required void Function(BatchImportProgress progress) onProgress,
  String? appSaveDir,
  bool Function()? isCancelled,
}) async {
  BatchImportProgress? last;
  final addedGames = await library.importFromDirectory(
    dirPath,
    appSaveDir: appSaveDir,
    onProgress: (p) {
      last = p;
      onProgress(p);
    },
    isCancelled: isCancelled,
  );

  onProgress(
    BatchImportProgress(
      totalFiles: last?.totalFiles ?? addedGames.length,
      processedFiles: last?.processedFiles ?? addedGames.length,
      importedGames: addedGames.length,
      skippedDuplicates: last?.skippedDuplicates ?? 0,
      isComplete: true,
    ),
  );
  return addedGames;
}
