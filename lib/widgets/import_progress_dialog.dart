import 'package:flutter/material.dart';

import '../models/game_rom.dart';
import '../services/batch_import_service.dart';
import '../services/game_library_service.dart';
import 'tv_focusable.dart';

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
          LinearProgressIndicator(
            value: progress.totalFiles > 0 ? progress.progress : null,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          const SizedBox(height: 16),
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
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isNotEmpty ? parts.last : path;
  }
}

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
  });

  return progressNotifier;
}

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
      builder: (_, progress, __) => ImportProgressDialog(
        progress: progress,
        onCancel: () => cancelled = true,
      ),
    ),
  );

  try {
    final addedGames = await library.importFromDirectory(
      dirPath,
      appSaveDir: appSaveDir,
      onProgress: (p) => progressNotifier.value = p,
      isCancelled: () => cancelled,
    );

    progressNotifier.value = BatchImportProgress(
      totalFiles: progressNotifier.value.totalFiles,
      processedFiles: progressNotifier.value.processedFiles,
      importedGames: addedGames.length,
      skippedDuplicates: progressNotifier.value.skippedDuplicates,
      isComplete: true,
    );
    return addedGames;
  } finally {
    if (context.mounted) {
      final nav = Navigator.of(context, rootNavigator: false);
      if (nav.canPop()) nav.pop();
    }
    progressNotifier.dispose();
  }
}
