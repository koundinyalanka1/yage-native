import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../utils/theme.dart';
import 'tv_focusable.dart';

const _deviceChannel = MethodChannel('com.yourmateapps.retropal/device');

class MediaStoreRomEntry {
  final String uri;
  final String displayName;
  final int size;
  final String relativePath;

  const MediaStoreRomEntry({
    required this.uri,
    required this.displayName,
    required this.size,
    required this.relativePath,
  });

  factory MediaStoreRomEntry.fromMap(Map<dynamic, dynamic> map) {
    return MediaStoreRomEntry(
      uri: (map['uri'] ?? '') as String,
      displayName: (map['displayName'] ?? '') as String,
      size: (map['size'] as num?)?.toInt() ?? 0,
      relativePath: (map['relativePath'] ?? '') as String,
    );
  }

  String get _sizeFormatted {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get subtitle => relativePath.isNotEmpty
      ? '$relativePath · $_sizeFormatted'
      : _sizeFormatted;
}

class TvMediaStoreBrowser extends StatefulWidget {
  final bool allowMultiple;

  const TvMediaStoreBrowser({super.key, this.allowMultiple = true});

  static Future<List<String>?> pickFiles(
    BuildContext context, {
    bool allowMultiple = true,
  }) async {
    return Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => TvMediaStoreBrowser(allowMultiple: allowMultiple),
      ),
    );
  }

  @override
  State<TvMediaStoreBrowser> createState() => _TvMediaStoreBrowserState();
}

class _TvMediaStoreBrowserState extends State<TvMediaStoreBrowser> {
  List<MediaStoreRomEntry> _entries = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRomFiles();
  }

  Future<void> _loadRomFiles() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _deviceChannel.invokeMethod<List<dynamic>>(
        'listRomFilesFromMediaStore',
      );
      if (!mounted) return;

      final items = (result ?? [])
          .map(
            (e) =>
                MediaStoreRomEntry.fromMap(Map<String, dynamic>.from(e as Map)),
          )
          .toList();

      items.sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );

      setState(() {
        _entries = items;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _entries = [];
          _loading = false;
          _error = 'Failed to load ROM files: $e';
        });
      }
    }
  }

  void _onEntryTap(MediaStoreRomEntry entry) {
    setState(() {
      if (_selected.contains(entry.uri)) {
        _selected.remove(entry.uri);
      } else {
        if (!widget.allowMultiple) _selected.clear();
        _selected.add(entry.uri);
      }
    });
  }

  void _selectAll() {
    setState(() {
      final uris = _entries.map((e) => e.uri).toSet();
      if (_selected.containsAll(uris)) {
        _selected.clear();
      } else {
        _selected.addAll(uris);
      }
    });
  }

  Future<void> _confirmSelection() async {
    if (_selected.isEmpty) return;

    final uris = _selected.toList();
    try {
      final paths = await _deviceChannel.invokeMethod<List<dynamic>>(
        'copyUrisToInternalStorage',
        {'uris': uris},
      );
      if (!mounted) return;
      Navigator.of(context).pop((paths ?? []).cast<String>());
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Failed to import: $e');
      }
    }
  }

  void _goBack() => Navigator.of(context).pop(null);

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.gameButtonStart ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_selected.isNotEmpty) {
        _confirmSelection();
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.goBack ||
        event.logicalKey == LogicalKeyboardKey.browserBack ||
        event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.gameButtonB) {
      _goBack();
      return KeyEventResult.handled;
    }
    if (widget.allowMultiple &&
        (event.logicalKey == LogicalKeyboardKey.gameButtonLeft1 ||
            event.logicalKey == LogicalKeyboardKey.pageUp ||
            event.logicalKey == LogicalKeyboardKey.channelUp ||
            event.logicalKey == LogicalKeyboardKey.mediaRewind)) {
      _selectAll();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  IconData _romIcon(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.gba' => Icons.videogame_asset,
      '.gbc' => Icons.gamepad,
      '.gb' => Icons.sports_esports,
      '.nes' || '.unf' || '.unif' => Icons.tv,
      '.sfc' || '.smc' => Icons.games,
      '.sms' || '.sg' => Icons.smart_display,
      '.gg' => Icons.phone_android,
      '.md' ||
      '.gen' ||
      '.bin' ||
      '.pce' ||
      '.sgx' ||
      '.cue' ||
      '.chd' => Icons.album,
      '.zip' => Icons.folder_zip,
      _ => Icons.insert_drive_file,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColorTheme.of(context);
    final canConfirm = _selected.isNotEmpty;

    return Focus(
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor: colors.backgroundDark,
        appBar: AppBar(
          backgroundColor: colors.backgroundMedium,
          automaticallyImplyLeading: false,
          title: Text(
            'Select ROMs',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        body: Column(
          children: [
            _buildGuidanceBanner(colors),

            const Divider(height: 1),
            if (!_loading && _error == null) _buildStatusBar(colors),
            Expanded(child: _buildBody(colors)),
            _buildActionBar(colors, canConfirm),
            _buildHintBar(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildGuidanceBanner(AppColorTheme colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: colors.accent.withAlpha(25),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colors.accent, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Copy your ROMs and folders to the Downloads folder for best visibility. '
              'Transfer via USB, ADB, or a file manager app.',
              style: TextStyle(
                fontSize: 13,
                color: colors.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(AppColorTheme colors) {
    final showSelectAll = widget.allowMultiple && _entries.isNotEmpty;
    final allSelected =
        showSelectAll && _entries.every((e) => _selected.contains(e.uri));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: colors.surface.withAlpha(80),
      child: Row(
        children: [
          Icon(Icons.insert_drive_file, size: 14, color: colors.textMuted),
          const SizedBox(width: 4),
          Text(
            '${_entries.length} ROM${_entries.length == 1 ? '' : 's'} found',
            style: TextStyle(fontSize: 11, color: colors.textMuted),
          ),
          if (_selected.isNotEmpty) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colors.primary.withAlpha(50),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.primary.withAlpha(100)),
              ),
              child: Text(
                '${_selected.length} selected',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: colors.primary,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (showSelectAll)
            TvFocusable(
              borderRadius: BorderRadius.circular(6),
              onTap: _selectAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      allSelected ? Icons.deselect : Icons.select_all,
                      size: 14,
                      color: colors.accent,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      allSelected ? 'Deselect all' : 'Select all',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.accent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(AppColorTheme colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: colors.error),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 16),
              TvFocusable(
                borderRadius: BorderRadius.circular(8),
                onTap: _loadRomFiles,
                onBack: _goBack,
                child: OutlinedButton.icon(
                  onPressed: _loadRomFiles,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Retry'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_off,
                size: 64,
                color: colors.textMuted.withAlpha(100),
              ),
              const SizedBox(height: 16),
              Text(
                'No ROM Files Found',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Copy your ROM files to the Downloads folder first.\n\n'
                '• Use a file manager to transfer from USB\n'
                '• Or push files via ADB from your computer\n'
                '• Supported: .gba, .gb, .gbc, .nes, .unf, .unif, .sfc, .sg, .bin, .pce, .sgx, .cue, .chd, .zip, etc.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: colors.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              TvFocusable(
                autofocus: true,
                borderRadius: BorderRadius.circular(8),
                onTap: _loadRomFiles,
                onBack: _goBack,
                child: OutlinedButton.icon(
                  onPressed: _loadRomFiles,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: TvScrollAccelerator(
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 80),
          itemCount: _entries.length,
          itemBuilder: (context, index) {
            final entry = _entries[index];
            final isSelected = _selected.contains(entry.uri);

            return TvFocusable(
              autofocus: index == 0,
              borderRadius: BorderRadius.circular(0),
              onTap: () => _onEntryTap(entry),
              onBack: _goBack,
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? colors.primary.withAlpha(40)
                        : colors.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _romIcon(entry.displayName),
                    size: 20,
                    color: isSelected ? colors.primary : colors.textMuted,
                  ),
                ),
                title: Text(
                  entry.displayName,
                  style: TextStyle(
                    color: isSelected ? colors.primary : colors.textPrimary,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: entry.subtitle.isNotEmpty
                    ? Text(
                        entry.subtitle,
                        style: TextStyle(fontSize: 12, color: colors.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : null,
                trailing: Icon(
                  isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: isSelected ? colors.primary : colors.surfaceLight,
                  size: 22,
                ),
                onTap: () => _onEntryTap(entry),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildActionBar(AppColorTheme colors, bool canConfirm) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: colors.backgroundMedium,
        border: Border(top: BorderSide(color: colors.surfaceLight, width: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TvFocusable(
            borderRadius: BorderRadius.circular(8),
            onTap: _goBack,
            onBack: _goBack,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.surfaceLight),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close, size: 18, color: colors.textSecondary),
                  const SizedBox(width: 8),
                  Text(
                    'Cancel',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (canConfirm) ...[
            const SizedBox(width: 12),
            TvFocusable(
              borderRadius: BorderRadius.circular(8),
              onTap: _confirmSelection,
              onBack: _goBack,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check, size: 18, color: colors.textPrimary),
                    const SizedBox(width: 8),
                    Text(
                      'Add ${_selected.length} ROM${_selected.length == 1 ? '' : 's'}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHintBar(AppColorTheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      decoration: BoxDecoration(
        color: colors.backgroundMedium,
        border: Border(top: BorderSide(color: colors.surfaceLight, width: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _hintChip(colors, 'OK', 'Select'),
          _hintDot(colors),
          _hintChip(colors, 'Back', 'Exit'),
          _hintDot(colors),
          _hintChip(colors, 'D-pad', 'Navigate'),
          _hintDot(colors),
          _hintChip(colors, 'Start/OK', 'Confirm'),
          if (widget.allowMultiple) ...[
            _hintDot(colors),
            _hintChip(colors, 'L1/Ch↑', 'Select All'),
          ],
        ],
      ),
    );
  }

  Widget _hintChip(AppColorTheme colors, String key, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colors.surfaceLight),
          ),
          child: Text(
            key,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              color: colors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: colors.textMuted)),
      ],
    );
  }

  Widget _hintDot(AppColorTheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        '·',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: colors.textMuted,
        ),
      ),
    );
  }
}
