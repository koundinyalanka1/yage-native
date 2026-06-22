import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/game_rom.dart';
import 'app_version_service.dart';

/// Service for exporting / importing save data as ZIP archives,
/// with optional Google Drive cloud backup.
class SaveBackupService {
  /// Web OAuth client ID (`client_type`: 3 in `android/app/google-services.json`).
  /// Required so [GoogleSignIn] can obtain credentials usable with
  /// the Drive API.
  static const String _googleDriveServerClientId =
      '288724007264-ro3h6i998kv6gbhjieut43nbke5puvva.apps.googleusercontent.com';
  // ─────────────────────────────────────────────
  //  ZIP Export
  // ─────────────────────────────────────────────

  /// Export save files for ALL games into a ZIP.
  /// Returns the saved ZIP path, or null if cancelled / failed.
  static Future<String?> exportAllSaves({
    required List<GameRom> games,
    required String? appSaveDir,
    void Function(int done, int total)? onProgress,
  }) async {
    final files = await _collectSaveFiles(games, appSaveDir, onProgress);
    if (files.isEmpty) return null;
    return _writeZip(files, 'retropal_saves');
  }

  /// Export save files for a SINGLE game into a ZIP.
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

  /// Let the user pick where to save the ZIP (file picker).
  ///
  /// The temp ZIP at [tempZipPath] is always deleted when this method
  /// returns — whether the user saved, cancelled, or an error occurred.
  static Future<String?> saveZipToUserLocation(String tempZipPath) async {
    try {
      final bytes = await File(tempZipPath).readAsBytes();
      final result = await FilePicker.saveFile(
        dialogTitle: 'Save backup ZIP',
        fileName: p.basename(tempZipPath),
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: bytes,
      );
      if (result == null) return null;
      return result.endsWith('.zip') ? result : '$result.zip';
    } catch (e) {
      debugPrint('Error saving ZIP: $e');
      return null;
    } finally {
      deleteTempZip(tempZipPath);
    }
  }

  /// Delete a temp ZIP file if it exists.  Call this when the temp file
  /// is no longer needed (e.g. after sharing or when a dialog closes).
  static void deleteTempZip(String? path) {
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      debugPrint('SaveBackupService: failed to delete temp ZIP — $e');
    }
  }

  /// Share the ZIP via the system share sheet (Google Drive, email, etc.).
  ///
  /// The temp ZIP at [zipPath] is deleted after the share sheet is
  /// dismissed (or on error).
  static Future<void> shareZip(String zipPath) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(zipPath)],
          subject: 'RetroPal Save Backup',
          text: 'RetroPal save data backup',
        ),
      );
    } catch (e) {
      debugPrint('Error sharing ZIP: $e');
    } finally {
      deleteTempZip(zipPath);
    }
  }

  // ─────────────────────────────────────────────
  //  ZIP Import
  // ─────────────────────────────────────────────

  /// Let user pick a ZIP file via system file picker.
  /// Returns the path to the selected ZIP, or null if cancelled.
  static Future<String?> pickZipFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Select backup ZIP',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.single.path;
  }

  /// Preview the contents of a backup ZIP without restoring.
  /// Returns metadata about what would be restored.
  static Future<ImportPreview> previewZip({
    required String zipPath,
    required List<GameRom> games,
  }) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final fileSize = bytes.length;

      // Build a lookup: romBaseName -> game
      final gameMap = <String, GameRom>{};
      for (final game in games) {
        final baseName = p.basenameWithoutExtension(game.path);
        gameMap[baseName] = game;
      }

      // Parse metadata if present
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

      // Count matching and unmatched files per game
      final matchedGames = <String, List<String>>{}; // baseName -> [filenames]
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

  /// Let user pick a ZIP and import saves into the app save directory.
  /// Returns the number of files restored.
  static Future<int> importFromZipPicker({
    required List<GameRom> games,
    String? appSaveDir,
  }) async {
    final path = await pickZipFile();
    if (path == null) return 0;

    return importFromZip(zipPath: path, games: games, appSaveDir: appSaveDir);
  }

  /// Import saves from a ZIP file, matching files to existing ROMs by name.
  ///
  /// When [appSaveDir] is provided, files are written there (the app's
  /// internal save directory).  Otherwise falls back to the ROM's directory.
  static Future<int> importFromZip({
    required String zipPath,
    required List<GameRom> games,
    String? appSaveDir,
    void Function(int done, int total)? onProgress,
  }) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Ensure the app save directory exists
      if (appSaveDir != null) {
        final dir = Directory(appSaveDir);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
      }

      // Build a lookup: romBaseName -> target save directory
      final saveDirMap = <String, String>{};
      for (final game in games) {
        final baseName = p.basenameWithoutExtension(game.path);
        // Prefer app save dir; fall back to ROM dir
        saveDirMap[baseName] = appSaveDir ?? p.dirname(game.path);
      }

      // Count restorable files for progress
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

  // ─────────────────────────────────────────────
  //  Google Drive
  // ─────────────────────────────────────────────

  static bool _signInInitialized = false;
  static GoogleSignInAccount? _currentUser;

  /// One-time setup: registers the auth-event stream listener and attempts a
  /// silent session restore. Safe to call multiple times.
  static Future<void> _ensureSignInInitialized() async {
    if (_signInInitialized) return;
    _signInInitialized = true;
    await GoogleSignIn.instance.initialize(
      serverClientId: _googleDriveServerClientId,
    );
    GoogleSignIn.instance.authenticationEvents.listen(
      (event) {
        if (event is GoogleSignInAuthenticationEventSignIn) {
          _currentUser = event.user;
        } else if (event is GoogleSignInAuthenticationEventSignOut) {
          _currentUser = null;
        }
      },
      // Auth failures surface via the caller's try-catch; suppress unhandled
      // zone errors from the stream's error channel.
      onError: (_) {},
    );
    // Silently restore a prior session (no-op if none exists).
    await GoogleSignIn.instance.attemptLightweightAuthentication();
  }

  /// Returns an authenticated Drive HTTP client for [_currentUser], or null.
  ///
  /// [authorizeScopes] shows a consent dialog if the Drive scope has not yet
  /// been granted — this is separate from sign-in in the v7 API.
  static Future<http.Client?> _driveHttpClient() async {
    final account = _currentUser;
    if (account == null) return null;
    try {
      final authz = await account.authorizationClient
          .authorizeScopes([drive.DriveApi.driveFileScope]);
      return authz.authClient(scopes: [drive.DriveApi.driveFileScope]);
    } catch (e) {
      debugPrint('SaveBackupService: Drive authorization failed — $e');
      return null;
    }
  }

  /// Returns true if a Google account is currently signed in.
  static Future<bool> isGoogleSignedIn() async {
    try {
      await _ensureSignInInitialized();
      return _currentUser != null;
    } catch (e) {
      debugPrint('SaveBackupService: isGoogleSignedIn check failed — $e');
      return false;
    }
  }

  /// Interactive Google Sign-In. Returns true on success.
  ///
  /// IMPORTANT — GMS error [16] "Account reauth failed" is caused by a
  /// signing-certificate SHA-1 mismatch, not a code bug. Fix:
  ///   1. Get the correct SHA-1:
  ///      - Debug: keytool -list -v -keystore ~/.android/debug.keystore
  ///      - Release: Play Console → Setup → App Signing → App signing key cert
  ///   2. Register the SHA-1 in Google Cloud Console →
  ///      APIs & Services → Credentials → your Android OAuth client.
  ///   3. Re-download google-services.json.
  static Future<bool> googleSignIn() async {
    try {
      if (Platform.isAndroid) {
        final available = await _checkGooglePlayServices();
        if (!available) {
          debugPrint(
            'Google Sign-In skipped: Google Play Services unavailable.',
          );
          return false;
        }
      }
      await _ensureSignInInitialized();

      // Session was silently restored by attemptLightweightAuthentication —
      // no interactive flow needed.
      if (_currentUser != null) return true;

      // Interactive account picker. The v7 API separates authentication (who
      // you are) from Drive scope authorization (handled in _driveHttpClient).
      await GoogleSignIn.instance.authenticate();
      return _currentUser != null;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        // GMS [16]: a stale Credential Manager entry may be interfering.
        // disconnect() revokes the server-side token AND clears the local
        // Credential Manager state (more thorough than signOut()).
        debugPrint(
          'Google Sign-In: canceled/reauth error — clearing credentials and retrying…',
        );
        try {
          await GoogleSignIn.instance.disconnect();
        } catch (_) {
          await GoogleSignIn.instance.signOut();
        }
        _currentUser = null;

        try {
          await GoogleSignIn.instance.authenticate();
          return _currentUser != null;
        } catch (retryError) {
          debugPrint('Google Sign-In retry failed: $retryError');
          return false;
        }
      }
      debugPrint('Google Sign-In failed (${e.code}): ${e.description}');
      return false;
    } catch (e) {
      debugPrint('Google Sign-In error: $e');
      return false;
    }
  }

  /// Returns true if Google Play Services is available and up-to-date.
  static Future<bool> _checkGooglePlayServices() async {
    try {
      const channel = MethodChannel('com.yourmateapps.retropal/device');
      final result = await channel.invokeMethod<String>(
        'checkGooglePlayServices',
      );
      return result == 'available';
    } catch (e) {
      // If the check itself fails, allow sign-in attempt anyway.
      debugPrint('GMS availability check failed: $e');
      return true;
    }
  }

  /// Sign out of Google.
  static Future<void> googleSignOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('SaveBackupService: Google Sign-Out failed — $e');
    }
  }

  /// Upload a ZIP to Google Drive in a "RetroPal" folder.
  /// Returns the Drive file ID, or null on failure.
  static Future<String?> uploadToDrive(String zipPath) async {
    try {
      final httpClient = await _driveHttpClient();
      if (httpClient == null) return null;

      final driveApi = drive.DriveApi(httpClient);

      // Find or create "RetroPal" folder
      final folderId = await _getOrCreateDriveFolder(driveApi, 'RetroPal');

      // Check for an existing file with the same name and update it
      // instead of creating a duplicate.
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
        // Update the existing file's content in place
        result = await driveApi.files.update(
          drive.File()..name = fileName,
          existing.files!.first.id!,
          uploadMedia: media,
        );
      } else {
        // No existing file — create a new one
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

  /// List backup ZIPs in the "RetroPal" Drive folder.
  static Future<List<drive.File>> listDriveBackups() async {
    try {
      final httpClient = await _driveHttpClient();
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

  /// Download a backup ZIP from Google Drive to a temp path.
  static Future<String?> downloadFromDrive(String fileId) async {
    try {
      final httpClient = await _driveHttpClient();
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
    // Search for existing folder
    final existing = await api.files.list(
      q: "name='$folderName' and mimeType='application/vnd.google-apps.folder' and trashed=false",
      $fields: 'files(id)',
    );
    if (existing.files != null && existing.files!.isNotEmpty) {
      return existing.files!.first.id!;
    }

    // Create new folder
    final folder = drive.File()
      ..name = folderName
      ..mimeType = 'application/vnd.google-apps.folder';
    final created = await api.files.create(folder);
    return created.id!;
  }

  // ─────────────────────────────────────────────
  //  Internal helpers
  // ─────────────────────────────────────────────

  /// Collect all save files for a set of games.
  /// Returns map of ZIP-internal paths → file bytes.
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

      // Directories to scan for this game's saves
      final dirs = <String>{romDir};
      if (appSaveDir != null && appSaveDir != romDir) {
        dirs.add(appSaveDir);
      }

      for (final dir in dirs) {
        // SRAM
        _tryAddFile(files, dir, '$baseName.sav', baseName);

        // Save states + thumbnails — use full basename to match native
        for (int slot = 0; slot < 6; slot++) {
          _tryAddFile(files, dir, '$romBase.ss$slot', baseName);
          _tryAddFile(files, dir, '$romBase.ss$slot.png', baseName);
        }

        // Timestamped screenshots
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

    // Add metadata
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

  /// Create a ZIP from the file map and write to temp directory.
  /// Returns the temp ZIP path.
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

/// Preview information about a backup ZIP to be imported.
class ImportPreview {
  final String zipPath;
  final int zipSizeBytes;
  final String? exportDate;
  final int totalFiles;

  /// Map of ROM base names → list of save file names that will be restored.
  final Map<String, List<String>> matchedGames;

  /// Files in the ZIP that don't match any game in the library.
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
