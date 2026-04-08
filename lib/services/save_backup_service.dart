import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/game_rom.dart';
import 'app_version_service.dart';

class SaveBackupService {
  static const String _googleDriveServerClientId =
      '288724007264-ro3h6i998kv6gbhjieut43nbke5puvva.apps.googleusercontent.com';

  static Future<String?> exportAllSaves({
    required List<GameRom> games,
    required String? appSaveDir,
    void Function(int done, int total)? onProgress,
  }) async {
    final files = await _collectSaveFiles(games, appSaveDir, onProgress);
    if (files.isEmpty) return null;
    return _writeZip(files, 'retropal_saves');
  }

  static Future<String?> exportGameSaves({
    required GameRom game,
    required String? appSaveDir,
  }) async {
    final files = await _collectSaveFiles([game], appSaveDir, null);
    if (files.isEmpty) return null;
    final safeName = p
        .basenameWithoutExtension(game.path)
        .replaceAll(RegExp(r'[^\w\-.]'), '_');
    return _writeZip(files, 'retropal_${safeName}_saves');
  }

  static Future<String?> saveZipToUserLocation(String tempZipPath) async {
    try {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save backup ZIP',
        fileName: p.basename(tempZipPath),
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null) return null;
      final destPath = result.endsWith('.zip') ? result : '$result.zip';
      await File(tempZipPath).copy(destPath);
      return destPath;
    } catch (e) {
      debugPrint('Error saving ZIP: $e');
      return null;
    } finally {
      deleteTempZip(tempZipPath);
    }
  }

  static void deleteTempZip(String? path) {
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      debugPrint('SaveBackupService: failed to delete temp ZIP — $e');
    }
  }

  static Future<void> shareZip(String zipPath) async {
    try {
      await Share.shareXFiles(
        [XFile(zipPath)],
        subject: 'RetroPal Save Backup',
        text: 'RetroPal save data backup',
      );
    } catch (e) {
      debugPrint('Error sharing ZIP: $e');
    } finally {
      deleteTempZip(zipPath);
    }
  }

  static Future<String?> pickZipFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select backup ZIP',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.single.path;
  }

  static Future<ImportPreview> previewZip({
    required String zipPath,
    required List<GameRom> games,
  }) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final fileSize = bytes.length;
      final gameMap = <String, GameRom>{};
      for (final game in games) {
        final baseName = p.basenameWithoutExtension(game.path);
        gameMap[baseName] = game;
      }
      String? exportDate;
      ArchiveFile? metaEntry;
      try {
        metaEntry = archive.files.firstWhere(
          (f) => f.name.endsWith('_metadata.json'),
        );
      } catch (e) {
        debugPrint('SaveBackupService: no metadata entry in ZIP — $e');
      }
      if (metaEntry != null) {
        try {
          final json =
              jsonDecode(utf8.decode(metaEntry.content as List<int>))
                  as Map<String, dynamic>;
          exportDate = json['exportDate'] as String?;
        } catch (e) {
          debugPrint('SaveBackupService: failed to parse ZIP metadata — $e');
        }
      }
      final matchedGames = <String, List<String>>{}; 
      final unmatchedFiles = <String>[];
      int totalFiles = 0;

      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        final parts = p.split(entry.name);
        if (parts.length < 2) continue;
        final fileName = parts.last;
        if (fileName == '_metadata.json') continue;

        totalFiles++;
        final gameFolderName = parts[parts.length - 2];

        if (gameMap.containsKey(gameFolderName)) {
          matchedGames.putIfAbsent(gameFolderName, () => []).add(fileName);
        } else {
          unmatchedFiles.add('$gameFolderName/$fileName');
        }
      }

      return ImportPreview(
        zipPath: zipPath,
        zipSizeBytes: fileSize,
        exportDate: exportDate,
        totalFiles: totalFiles,
        matchedGames: matchedGames,
        unmatchedFiles: unmatchedFiles,
      );
    } catch (e) {
      debugPrint('Error previewing ZIP: $e');
      rethrow;
    }
  }

  static Future<int> importFromZipPicker({
    required List<GameRom> games,
    String? appSaveDir,
  }) async {
    final path = await pickZipFile();
    if (path == null) return 0;

    return importFromZip(zipPath: path, games: games, appSaveDir: appSaveDir);
  }

  static Future<int> importFromZip({
    required String zipPath,
    required List<GameRom> games,
    String? appSaveDir,
    void Function(int done, int total)? onProgress,
  }) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      if (appSaveDir != null) {
        final dir = Directory(appSaveDir);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
      }
      final saveDirMap = <String, String>{};
      for (final game in games) {
        final baseName = p.basenameWithoutExtension(game.path);
        saveDirMap[baseName] = appSaveDir ?? p.dirname(game.path);
      }
      final restorable = archive.files.where((e) {
        if (!e.isFile) return false;
        final parts = p.split(e.name);
        if (parts.length < 2) return false;
        final fileName = parts.last;
        if (fileName == '_metadata.json') return false;
        final gameFolderName = parts[parts.length - 2];
        return saveDirMap.containsKey(gameFolderName);
      }).toList();

      int restored = 0;

      for (var i = 0; i < restorable.length; i++) {
        final entry = restorable[i];
        final parts = p.split(entry.name);
        final gameFolderName = parts[parts.length - 2];
        final fileName = parts.last;

        final destDir = saveDirMap[gameFolderName]!;

        try {
          final destPath = p.join(destDir, fileName);
          final destFile = File(destPath);
          await destFile.writeAsBytes(entry.content as List<int>);
          restored++;
          debugPrint('Restored: $destPath');
        } catch (e) {
          debugPrint('Error restoring $fileName: $e');
        }

        onProgress?.call(i + 1, restorable.length);
      }

      return restored;
    } catch (e) {
      debugPrint('Error importing ZIP: $e');
      return 0;
    }
  }

  static GoogleSignIn? _googleSignIn;

  static GoogleSignIn get _signIn {
    _googleSignIn ??= GoogleSignIn(
      scopes: [drive.DriveApi.driveFileScope],
      serverClientId: _googleDriveServerClientId,
    );
    return _googleSignIn!;
  }

  static Future<bool> isGoogleSignedIn() async {
    try {
      return await _signIn.isSignedIn();
    } catch (e) {
      debugPrint('SaveBackupService: isGoogleSignedIn check failed — $e');
      return false;
    }
  }

  static Future<bool> googleSignIn() async {
    try {
      final account = await _signIn.signIn();
      return account != null;
    } catch (e) {
      debugPrint('Google Sign-In error: $e');
      return false;
    }
  }

  static Future<void> googleSignOut() async {
    try {
      await _signIn.signOut();
    } catch (e) {
      debugPrint('SaveBackupService: Google Sign-Out failed — $e');
    }
  }

  static Future<String?> uploadToDrive(String zipPath) async {
    try {
      final httpClient = await _signIn.authenticatedClient();
      if (httpClient == null) return null;

      final driveApi = drive.DriveApi(httpClient);
      final folderId = await _getOrCreateDriveFolder(driveApi, 'RetroPal');
      final fileName = p.basename(zipPath);
      final existing = await driveApi.files.list(
        q: "'$folderId' in parents and name='$fileName' and trashed=false",
        $fields: 'files(id)',
      );

      final media = drive.Media(
        File(zipPath).openRead(),
        File(zipPath).lengthSync(),
      );

      final drive.File result;
      if (existing.files != null && existing.files!.isNotEmpty) {
        result = await driveApi.files.update(
          drive.File()..name = fileName,
          existing.files!.first.id!,
          uploadMedia: media,
        );
      } else {
        final driveFile = drive.File()
          ..name = fileName
          ..parents = [folderId];
        result = await driveApi.files.create(driveFile, uploadMedia: media);
      }
      return result.id;
    } catch (e) {
      debugPrint('Drive upload error: $e');
      return null;
    }
  }

  static Future<List<drive.File>> listDriveBackups() async {
    try {
      final httpClient = await _signIn.authenticatedClient();
      if (httpClient == null) return [];

      final driveApi = drive.DriveApi(httpClient);
      final folderId = await _getOrCreateDriveFolder(driveApi, 'RetroPal');

      final result = await driveApi.files.list(
        q: "'$folderId' in parents and mimeType='application/zip' and trashed=false",
        orderBy: 'modifiedTime desc',
        $fields: 'files(id,name,modifiedTime,size)',
      );

      return result.files ?? [];
    } catch (e) {
      debugPrint('Drive list error: $e');
      return [];
    }
  }

  static Future<String?> downloadFromDrive(String fileId) async {
    try {
      final httpClient = await _signIn.authenticatedClient();
      if (httpClient == null) return null;

      final driveApi = drive.DriveApi(httpClient);
      final media =
          await driveApi.files.get(
                fileId,
                downloadOptions: drive.DownloadOptions.fullMedia,
              )
              as drive.Media;

      final tempDir = await getTemporaryDirectory();
      final tempPath = p.join(tempDir.path, 'retropal_restore.zip');
      final sink = File(tempPath).openWrite();
      await media.stream.pipe(sink);
      await sink.close();

      return tempPath;
    } catch (e) {
      debugPrint('Drive download error: $e');
      return null;
    }
  }

  static Future<String> _getOrCreateDriveFolder(
    drive.DriveApi api,
    String folderName,
  ) async {
    final existing = await api.files.list(
      q: "name='$folderName' and mimeType='application/vnd.google-apps.folder' and trashed=false",
      $fields: 'files(id)',
    );
    if (existing.files != null && existing.files!.isNotEmpty) {
      return existing.files!.first.id!;
    }
    final folder = drive.File()
      ..name = folderName
      ..mimeType = 'application/vnd.google-apps.folder';
    final created = await api.files.create(folder);
    return created.id!;
  }

  static Future<Map<String, List<int>>> _collectSaveFiles(
    List<GameRom> games,
    String? appSaveDir,
    void Function(int done, int total)? onProgress,
  ) async {
    final files = <String, List<int>>{};
    final total = games.length;

    for (var i = 0; i < games.length; i++) {
      final game = games[i];
      final baseName = p.basenameWithoutExtension(game.path);
      final romBase = p.basename(game.path);
      final romDir = p.dirname(game.path);
      final dirs = <String>{romDir};
      if (appSaveDir != null && appSaveDir != romDir) {
        dirs.add(appSaveDir);
      }

      for (final dir in dirs) {
        _tryAddFile(files, dir, '$baseName.sav', baseName);
        for (int slot = 0; slot < 6; slot++) {
          _tryAddFile(files, dir, '$romBase.ss$slot', baseName);
          _tryAddFile(files, dir, '$romBase.ss$slot.png', baseName);
        }
        try {
          final directory = Directory(dir);
          if (directory.existsSync()) {
            for (final entity in directory.listSync()) {
              if (entity is File) {
                final name = p.basename(entity.path);
                if (name.startsWith('${baseName}_') && name.endsWith('.png')) {
                  _tryAddFile(files, dir, name, baseName);
                }
              }
            }
          }
        } catch (e) {
          debugPrint(
            'SaveBackupService: failed to list screenshots in "$dir" — $e',
          );
        }
      }

      onProgress?.call(i + 1, total);
    }
    final appVersion = await AppVersionService.pubspecStyleVersion();
    final meta = {
      'app': 'RetroPal',
      'version': appVersion,
      'exportDate': DateTime.now().toIso8601String(),
      'gameCount': games.length,
      'fileCount': files.length,
      'games': games
          .map(
            (g) => {
              'name': g.name,
              'baseName': p.basenameWithoutExtension(g.path),
              'platform': g.platform.name,
            },
          )
          .toList(),
    };
    files['retropal_saves/_metadata.json'] = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(meta),
    );

    return files;
  }

  static void _tryAddFile(
    Map<String, List<int>> files,
    String dir,
    String fileName,
    String gameFolder,
  ) {
    final file = File(p.join(dir, fileName));
    if (file.existsSync()) {
      try {
        final key = 'retropal_saves/$gameFolder/$fileName';
        if (!files.containsKey(key)) {
          files[key] = file.readAsBytesSync();
        }
      } catch (e) {
        debugPrint(
          'SaveBackupService: failed to read "$fileName" for backup — $e',
        );
      }
    }
  }

  static Future<String?> _writeZip(
    Map<String, List<int>> files,
    String baseName,
  ) async {
    try {
      final archive = Archive();

      for (final entry in files.entries) {
        archive.addFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }

      final zipData = ZipEncoder().encode(archive);

      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final zipPath = p.join(tempDir.path, '${baseName}_$timestamp.zip');
      await File(zipPath).writeAsBytes(zipData);

      return zipPath;
    } catch (e) {
      debugPrint('Error creating ZIP: $e');
      return null;
    }
  }
}

class ImportPreview {
  final String zipPath;
  final int zipSizeBytes;
  final String? exportDate;
  final int totalFiles;

  final Map<String, List<String>> matchedGames;

  final List<String> unmatchedFiles;

  const ImportPreview({
    required this.zipPath,
    required this.zipSizeBytes,
    required this.exportDate,
    required this.totalFiles,
    required this.matchedGames,
    required this.unmatchedFiles,
  });

  int get matchedFileCount =>
      matchedGames.values.fold(0, (sum, files) => sum + files.length);

  String get zipSizeFormatted {
    if (zipSizeBytes < 1024) return '$zipSizeBytes B';
    if (zipSizeBytes < 1024 * 1024) {
      return '${(zipSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(zipSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String? get exportDateFormatted {
    if (exportDate == null) return null;
    try {
      final dt = DateTime.parse(exportDate!);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
          '${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      debugPrint(
        'SaveBackupService: failed to parse export date "$exportDate" — $e',
      );
      return exportDate;
    }
  }
}
