import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../utils/tv_detector.dart';

const _deviceChannel = MethodChannel('com.yourmateapps.retropal/device');

class RomFolderService {
  static Future<bool> hasUsableFolder(String? folderUriOrPath) async {
    if (folderUriOrPath == null) return false;
    final value = folderUriOrPath.trim();
    if (value.isEmpty) return false;

    if (Platform.isAndroid && value.startsWith('content://')) {
      try {
        final ok = await _deviceChannel.invokeMethod<bool>(
          'checkHasUriPermission',
          {'uri': value},
        );
        return ok ?? false;
      } catch (e) {
        debugPrint('RomFolderService: checkHasUriPermission failed — $e');
        return false;
      }
    }

    try {
      return await Directory(value).exists();
    } catch (e) {
      debugPrint('RomFolderService: folder path check failed — $e');
      return false;
    }
  }

  static Future<String?> pickFolder(dynamic context) async {
    if (TvDetector.isTV) {
      return null;
    }

    if (Platform.isAndroid) {
      try {
        final uri = await _deviceChannel.invokeMethod<String>('pickRomsFolder');
        return uri;
      } catch (e) {
        debugPrint('RomFolderService: pickRomsFolder failed — $e');
        return null;
      }
    }

    try {
      return await FilePicker.platform.getDirectoryPath();
    } catch (e) {
      debugPrint('RomFolderService: getDirectoryPath failed — $e');
      return null;
    }
  }

  static Future<List<String>> importFromFolder(String folderUriOrPath) async {
    if (Platform.isAndroid && folderUriOrPath.startsWith('content://')) {
      try {
        final result = await _deviceChannel.invokeMethod<List<dynamic>>(
          'importFromFolderUri',
          {'treeUri': folderUriOrPath},
        );
        return (result ?? []).cast<String>();
      } catch (e) {
        debugPrint('RomFolderService: importFromFolderUri failed — $e');
        return [];
      }
    }
    return [];
  }

  static Future<bool> copySaveFromUserFolder(
    String folderUriOrPath,
    String fileName,
    String destPath,
  ) async {
    if (Platform.isAndroid && folderUriOrPath.startsWith('content://')) {
      try {
        final success = await _deviceChannel.invokeMethod<bool>(
          'copySaveFromUserFolder',
          {
            'treeUri': folderUriOrPath,
            'fileName': fileName,
            'destPath': destPath,
          },
        );
        return success ?? false;
      } catch (e) {
        debugPrint('RomFolderService: copySaveFromUserFolder failed — $e');
        return false;
      }
    }
    try {
      final sourceFile = File(p.join(folderUriOrPath, fileName));
      if (!await sourceFile.exists()) return false;
      await sourceFile.copy(destPath);
      return true;
    } catch (e) {
      debugPrint('RomFolderService: copy from path failed — $e');
      return false;
    }
  }

  static Future<bool> copySaveToUserFolder(
    String folderUriOrPath,
    String sourceFilePath,
  ) async {
    if (Platform.isAndroid && folderUriOrPath.startsWith('content://')) {
      try {
        final success = await _deviceChannel.invokeMethod<bool>(
          'copySaveToUserFolder',
          {'treeUri': folderUriOrPath, 'sourcePath': sourceFilePath},
        );
        return success ?? false;
      } catch (e) {
        debugPrint('RomFolderService: copySaveToUserFolder failed — $e');
        return false;
      }
    }
    try {
      final destDir = Directory(folderUriOrPath);
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
      }
      final fileName = sourceFilePath.split(RegExp(r'[/\\]')).last;
      final destFile = File('${destDir.path}/$fileName');
      if (await destFile.exists()) {
        await destFile.delete();
      }
      await File(sourceFilePath).copy(destFile.path);
      return true;
    } catch (e) {
      debugPrint('RomFolderService: copy to path failed — $e');
      return false;
    }
  }

  static bool get isSupported => true;
}
