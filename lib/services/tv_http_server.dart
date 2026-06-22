import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/mgba_bindings.dart';
import 'bios_service.dart';

/// HTTP server for TV file management.
///
/// Provides a web interface accessible from any device on the same network,
/// allowing users to:
/// - Browse the entire app directory (ROMs, saves, etc.)
/// - Upload files to any directory
/// - Download any file
/// - Create and delete folders
/// - Delete any file or folder
class TvHttpServer {
  static TvHttpServer? _instance;
  static TvHttpServer get instance => _instance ??= TvHttpServer._();

  TvHttpServer._();

  HttpServer? _server;
  String? _appPath;
  String? _romsPath;
  String? _savesPath;
  String? _biosPath;

  /// Whether the server is currently running
  bool get isRunning => _server != null;

  /// The URL to access the server (e.g., "http://192.168.1.100:8080")
  String? get serverUrl => _serverUrl;
  String? _serverUrl;

  /// The port the server is running on
  int get port => _port;
  int _port = 8080;

  /// Stream of server status changes
  final _statusController = StreamController<bool>.broadcast();
  Stream<bool> get statusStream => _statusController.stream;

  /// Start the HTTP server
  Future<String?> start() async {
    if (_server != null) {
      return _serverUrl;
    }

    try {
      // Get the app support directory — serves as root for the file browser
      final appDir = await getApplicationSupportDirectory();
      _appPath = appDir.path;
      _romsPath = p.join(appDir.path, 'roms');
      _savesPath = p.join(appDir.path, 'saves');
      _biosPath = p.join(appDir.path, 'system');

      // Create the key directories if they don't exist
      final romsDir = Directory(_romsPath!);
      if (!await romsDir.exists()) {
        await romsDir.create(recursive: true);
      }
      final savesDir = Directory(_savesPath!);
      if (!await savesDir.exists()) {
        await savesDir.create(recursive: true);
      }
      // System directory holds BIOS files for cores that need them
      // (NDS / PS1 / Intellivision). Files dropped here are picked up
      // by libretro via RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY.
      final biosDir = Directory(_biosPath!);
      if (!await biosDir.exists()) {
        await biosDir.create(recursive: true);
      }

      // Find an available port
      _port = 8080;
      for (int i = 0; i < 10; i++) {
        try {
          _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
          break;
        } catch (e) {
          _port++;
        }
      }

      if (_server == null) {
        throw Exception('Could not find available port');
      }

      // Get the device's IP address
      final ip = await _getLocalIpAddress();
      _serverUrl = 'http://$ip:$_port';

      debugPrint('TvHttpServer started at $_serverUrl');
      debugPrint('ROMs directory: $_romsPath');

      // Handle incoming requests
      _server!.listen(_handleRequest);

      _statusController.add(true);
      return _serverUrl;
    } catch (e) {
      debugPrint('Failed to start TvHttpServer: $e');
      await stop();
      return null;
    }
  }

  /// Stop the HTTP server
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _serverUrl = null;
    _statusController.add(false);
    debugPrint('TvHttpServer stopped');
  }

  /// Get the local IP address
  Future<String> _getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        // Prefer wlan/wifi interfaces
        if (interface.name.toLowerCase().contains('wlan') ||
            interface.name.toLowerCase().contains('wifi') ||
            interface.name.toLowerCase().contains('en0')) {
          for (final addr in interface.addresses) {
            if (!addr.isLoopback) {
              return addr.address;
            }
          }
        }
      }

      // Fallback to any non-loopback address
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      debugPrint('Error getting IP address: $e');
    }

    return '127.0.0.1';
  }

  /// Handle incoming HTTP requests
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      // Add CORS headers
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers.add(
        'Access-Control-Allow-Methods',
        'GET, POST, DELETE, OPTIONS',
      );
      request.response.headers.add(
        'Access-Control-Allow-Headers',
        'Content-Type',
      );

      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      final path = request.uri.path;

      if (path == '/' || path == '/index.html') {
        await _serveHtml(request);
      } else if (path == '/api/files') {
        await _handleFilesApi(request);
      } else if (path == '/api/download-file') {
        await _handleDownloadFile(request);
      } else if (path.startsWith('/api/download/')) {
        await _handleDownload(request);
      } else if (path == '/api/upload') {
        await _handleUpload(request);
      } else if (path == '/api/upload-save') {
        await _handleUploadSave(request);
      } else if (path == '/api/folder') {
        await _handleFolder(request);
      } else if (path == '/api/delete') {
        await _handleDelete(request);
      } else if (path == '/api/status') {
        await _handleStatus(request);
      } else if (path == '/api/bios-status') {
        await _handleBiosStatus(request);
      } else if (path == '/api/upload-bios') {
        await _handleUploadBios(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('Not Found');
      }
    } catch (e) {
      debugPrint('Error handling request: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        // Sanitize to ASCII to avoid secondary FormatException in write()
        final safeMsg = e.toString().replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
        request.response.write('Internal Server Error: $safeMsg');
      } catch (_) {
        // Response may already be committed; nothing more we can do.
      }
    } finally {
      await request.response.close();
    }
  }

  /// Serve the main HTML page
  Future<void> _serveHtml(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write(_getHtmlPage());
  }

  /// Handle GET /api/files - list files and folders
  ///
  /// Browses the entire app support directory. The `path` query parameter
  /// is relative to the app support root.
  Future<void> _handleFilesApi(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }

    final subPath = request.uri.queryParameters['path'] ?? '';
    final fullPath = subPath.isEmpty ? _appPath! : p.join(_appPath!, subPath);

    // Security: ensure path is within app directory
    if (!p.isWithin(_appPath!, fullPath) && fullPath != _appPath) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write(jsonEncode({'error': 'Access denied'}));
      return;
    }

    final dir = Directory(fullPath);
    if (!await dir.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'Directory not found'}));
      return;
    }

    final items = <Map<String, dynamic>>[];

    await for (final entity in dir.list()) {
      final name = p.basename(entity.path);
      final isDir = entity is Directory;
      final stat = await entity.stat();

      items.add({
        'name': name,
        'isDirectory': isDir,
        'size': isDir ? 0 : stat.size,
        'modified': stat.modified.toIso8601String(),
      });
    }

    // Sort: directories first, then by name
    items.sort((a, b) {
      if (a['isDirectory'] != b['isDirectory']) {
        return a['isDirectory'] ? -1 : 1;
      }
      return (a['name'] as String).toLowerCase().compareTo(
        (b['name'] as String).toLowerCase(),
      );
    });

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'path': subPath, 'items': items}));
  }

  /// Handle POST /api/upload - upload files to any directory
  ///
  /// The `path` form field is relative to the app support root.
  /// Streams file data to disk in chunks to avoid OOM on large uploads.
  Future<void> _handleUpload(HttpRequest request) async {
    if (request.method != 'POST') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }

    try {
      final contentType = request.headers.contentType;
      if (contentType == null ||
          !contentType.mimeType.contains('multipart/form-data')) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Invalid content type'}));
        return;
      }

      final boundary = contentType.parameters['boundary'];
      if (boundary == null) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Missing boundary'}));
        return;
      }

      // Read the full body in chunks to avoid holding the entire stream open
      // while doing synchronous boundary parsing. Cap at 200 MB.
      const maxSize = 200 * 1024 * 1024;
      final bodyBytes = BytesBuilder(copy: false);
      var totalRead = 0;
      await for (final chunk in request) {
        totalRead += chunk.length;
        if (totalRead > maxSize) {
          request.response.statusCode = HttpStatus.requestEntityTooLarge;
          request.response.write(
            jsonEncode({'error': 'Upload too large (max 200 MB)'}),
          );
          return;
        }
        bodyBytes.add(chunk);
      }
      final data = bodyBytes.takeBytes();

      final boundaryBytes = utf8.encode('--$boundary');
      final uploadedFiles = <String>[];

      // First pass: find the 'path' field value
      String targetPath = '';
      var pos = 0;
      while (true) {
        final bStart = _indexOfBytes(data, boundaryBytes, pos);
        if (bStart == -1) break;
        pos = bStart + boundaryBytes.length;
        // Skip CRLF
        if (pos < data.length && data[pos] == 13) pos++;
        if (pos < data.length && data[pos] == 10) pos++;
        // End boundary?
        if (pos + 1 < data.length && data[pos] == 45 && data[pos + 1] == 45) {
          break;
        }

        final headersEnd = _indexOfCRLFCRLF(data, pos);
        if (headersEnd == -1) break;
        final headersStr = utf8.decode(data.sublist(pos, headersEnd));

        final nameMatch = RegExp(r'name="([^"]*)"').firstMatch(headersStr);
        if (nameMatch?.group(1) == 'path') {
          final contentStart = headersEnd + 4;
          final nextB = _indexOfBytes(data, boundaryBytes, contentStart);
          if (nextB == -1) break;
          var contentEnd = nextB;
          if (contentEnd > 1 && data[contentEnd - 1] == 10) contentEnd--;
          if (contentEnd > 1 && data[contentEnd - 1] == 13) contentEnd--;
          targetPath = utf8.decode(data.sublist(contentStart, contentEnd));
          break;
        }
      }

      // Second pass: extract and write file parts
      pos = 0;
      while (true) {
        final bStart = _indexOfBytes(data, boundaryBytes, pos);
        if (bStart == -1) break;
        pos = bStart + boundaryBytes.length;
        if (pos < data.length && data[pos] == 13) pos++;
        if (pos < data.length && data[pos] == 10) pos++;
        if (pos + 1 < data.length && data[pos] == 45 && data[pos + 1] == 45) {
          break;
        }

        final headersEnd = _indexOfCRLFCRLF(data, pos);
        if (headersEnd == -1) break;
        final headersStr = utf8.decode(data.sublist(pos, headersEnd));

        final nameMatch = RegExp(r'name="([^"]*)"').firstMatch(headersStr);
        final filenameMatch = RegExp(
          r'filename="([^"]*)"',
        ).firstMatch(headersStr);

        final contentStart = headersEnd + 4;
        final nextB = _indexOfBytes(data, boundaryBytes, contentStart);
        if (nextB == -1) break;

        if (nameMatch?.group(1) == 'files' && filenameMatch != null) {
          final filename = filenameMatch.group(1)!;
          final fullPath = p.join(_appPath!, targetPath, filename);

          if (p.isWithin(_appPath!, fullPath)) {
            final dir = Directory(p.dirname(fullPath));
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }

            var contentEnd = nextB;
            if (contentEnd > 1 && data[contentEnd - 1] == 10) contentEnd--;
            if (contentEnd > 1 && data[contentEnd - 1] == 13) contentEnd--;

            // data.sublist creates a new independent copy of just the file bytes.
            // Using sublistView(Uint8List.fromList(data), ...) copies the entire
            // multipart body as the backing buffer — OOM on 32-bit devices when
            // writeAsBytes serializes the full 128MB backing to the IO isolate.
            final file = File(fullPath);
            await file.writeAsBytes(data.sublist(contentStart, contentEnd));

            uploadedFiles.add(filename);
            debugPrint('Uploaded: $filename to $fullPath');
          }
        }

        pos = nextB;
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'success': true, 'files': uploadedFiles}),
      );
    } catch (e, st) {
      debugPrint('Upload error: $e\n$st');
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Find byte pattern in data starting from offset
  int _indexOfBytes(List<int> data, List<int> pattern, int start) {
    outer:
    for (var i = start; i <= data.length - pattern.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  /// Find \r\n\r\n in data
  int _indexOfCRLFCRLF(List<int> data, int start) {
    for (var i = start; i < data.length - 3; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// Handle POST /api/folder - create folder
  ///
  /// Paths are relative to app support root.
  Future<void> _handleFolder(HttpRequest request) async {
    final subPath = request.uri.queryParameters['path'] ?? '';
    final name = request.uri.queryParameters['name'] ?? '';

    if (request.method == 'POST') {
      // Create folder
      if (name.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Folder name required'}));
        return;
      }

      final fullPath = p.join(_appPath!, subPath, name);

      // Security check
      if (!p.isWithin(_appPath!, fullPath)) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write(jsonEncode({'error': 'Access denied'}));
        return;
      }

      final dir = Directory(fullPath);
      if (await dir.exists()) {
        request.response.statusCode = HttpStatus.conflict;
        request.response.write(jsonEncode({'error': 'Folder already exists'}));
        return;
      }

      await dir.create(recursive: true);

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'success': true}));
    } else {
      request.response.statusCode = HttpStatus.methodNotAllowed;
    }
  }

  /// Handle DELETE /api/delete - delete any file or folder
  ///
  /// `path` is relative to the app support root.
  Future<void> _handleDelete(HttpRequest request) async {
    if (request.method != 'DELETE') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }

    final subPath = request.uri.queryParameters['path'] ?? '';

    if (subPath.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(jsonEncode({'error': 'Path required'}));
      return;
    }

    final fullPath = p.join(_appPath!, subPath);

    // Security check — must be within app directory
    if (!p.isWithin(_appPath!, fullPath)) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write(jsonEncode({'error': 'Access denied'}));
      return;
    }

    final file = File(fullPath);
    final dir = Directory(fullPath);

    if (await file.exists()) {
      await file.delete();
    } else if (await dir.exists()) {
      await dir.delete(recursive: true);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'Not found'}));
      return;
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'success': true}));
  }

  /// Handle GET /api/download-file - download any file by path
  ///
  /// `path` is relative to the app support root.
  Future<void> _handleDownloadFile(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }

    final subPath = request.uri.queryParameters['path'] ?? '';

    if (subPath.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(jsonEncode({'error': 'Path required'}));
      return;
    }

    final fullPath = p.join(_appPath!, subPath);

    // Security check — must be within app directory
    if (!p.isWithin(_appPath!, fullPath)) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write(jsonEncode({'error': 'Access denied'}));
      return;
    }

    final file = File(fullPath);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'File not found'}));
      return;
    }

    request.response.headers.set('Content-Type', 'application/octet-stream');
    request.response.headers.set(
      'Content-Disposition',
      _buildContentDisposition(p.basename(fullPath)),
    );
    request.response.headers.set(
      'Content-Length',
      (await file.length()).toString(),
    );

    await request.response.addStream(file.openRead());
  }

  /// Handle GET /api/status - server status
  Future<void> _handleStatus(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'running': true,
        'romsPath': _romsPath,
        'savesPath': _savesPath,
        'biosPath': _biosPath,
      }),
    );
  }

  /// Handle GET /api/bios-status — presence & validity of every known BIOS file.
  Future<void> _handleBiosStatus(HttpRequest request) async {
    if (_biosPath == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.write(jsonEncode({'error': 'Server not ready'}));
      return;
    }

    const platformKeys = {
      GamePlatform.nds: 'nds',
      GamePlatform.ps1: 'ps1',
      GamePlatform.intv: 'intv',
    };

    final result = <String, dynamic>{};
    for (final entry in platformKeys.entries) {
      final files = <Map<String, dynamic>>[];
      for (final spec in BiosService.specsFor(
        entry.key,
      ).where((spec) => spec.kind != BiosKind.bundled)) {
        final filename = spec.filename;
        final file = File(p.join(_biosPath!, filename));
        var exists = false;
        var size = 0;
        try {
          exists = await file.exists();
          if (exists) size = await file.length();
        } catch (_) {}
        final hashChecked = spec.hasKnownHashes;
        var hashValid = !hashChecked;
        if (exists && hashChecked) {
          try {
            hashValid = BiosService.bytesMatchHashesForSpec(
              spec,
              await file.readAsBytes(),
            );
          } catch (_) {
            hashValid = false;
          }
        }
        final valid = exists && (!hashChecked || hashValid);
        files.add({
          'id': spec.id,
          'filename': filename,
          'label': spec.label,
          'desc': spec.description,
          'exists': exists,
          'valid': valid,
          'size': size,
          'expectedSize': spec.expectedSize,
          'expectedMd5': spec.md5,
          'expectedSha1': spec.sha1,
          'hashChecked': hashChecked,
          'hashValid': hashValid,
        });
      }
      result[entry.value] = files;
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(result));
  }

  /// Handle POST /api/upload-bios — upload a single BIOS file by slot id.
  ///
  /// Expects multipart/form-data with fields:
  ///   `biosId`  — one of: bios7, bios9, firmware, scph5500, scph5501, scph5502, exec, grom
  ///   `file`    — the binary file data (any original filename is ignored;
  ///               the file is always written under the canonical libretro name)
  Future<void> _handleUploadBios(HttpRequest request) async {
    if (request.method != 'POST') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }

    // Allowlist: biosId -> canonical filename written to the system dir.
    final allowedIds = <String, String>{
      for (final platform in BiosService.biosPlatforms)
        for (final spec in BiosService.specsFor(platform))
          if (spec.kind != BiosKind.bundled) spec.id: spec.filename,
    };

    try {
      final contentType = request.headers.contentType;
      if (contentType == null ||
          !contentType.mimeType.contains('multipart/form-data')) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Invalid content type'}));
        return;
      }

      final boundary = contentType.parameters['boundary'];
      if (boundary == null) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Missing boundary'}));
        return;
      }

      // Cap at 4 MB — all real BIOS files are well under that.
      const maxSize = 4 * 1024 * 1024;
      final bodyBytes = BytesBuilder(copy: false);
      var totalRead = 0;
      await for (final chunk in request) {
        totalRead += chunk.length;
        if (totalRead > maxSize) {
          request.response.statusCode = HttpStatus.requestEntityTooLarge;
          request.response.write(
            jsonEncode({'error': 'File too large (max 4 MB)'}),
          );
          return;
        }
        bodyBytes.add(chunk);
      }
      final data = bodyBytes.takeBytes();
      final boundaryBytes = utf8.encode('--$boundary');

      String? biosId;
      List<int>? fileBytes;

      var pos = 0;
      while (true) {
        final bStart = _indexOfBytes(data, boundaryBytes, pos);
        if (bStart == -1) break;
        pos = bStart + boundaryBytes.length;
        if (pos < data.length && data[pos] == 13) pos++;
        if (pos < data.length && data[pos] == 10) pos++;
        if (pos + 1 < data.length && data[pos] == 45 && data[pos + 1] == 45) {
          break;
        }

        final headersEnd = _indexOfCRLFCRLF(data, pos);
        if (headersEnd == -1) break;
        final headersStr = utf8.decode(data.sublist(pos, headersEnd));

        final nameMatch = RegExp(r'name="([^"]*)"').firstMatch(headersStr);
        final contentStart = headersEnd + 4;
        final nextB = _indexOfBytes(data, boundaryBytes, contentStart);
        if (nextB == -1) break;

        var contentEnd = nextB;
        if (contentEnd > 1 && data[contentEnd - 1] == 10) contentEnd--;
        if (contentEnd > 1 && data[contentEnd - 1] == 13) contentEnd--;

        final fieldName = nameMatch?.group(1);
        if (fieldName == 'biosId') {
          biosId = utf8.decode(data.sublist(contentStart, contentEnd));
        } else if (fieldName == 'file') {
          fileBytes = data.sublist(contentStart, contentEnd);
        }
        pos = nextB;
      }

      if (biosId == null || fileBytes == null || fileBytes.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(
          jsonEncode({'error': 'Missing biosId or file data'}),
        );
        return;
      }

      final targetFilename = allowedIds[biosId];
      if (targetFilename == null) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Unknown BIOS id'}));
        return;
      }

      final targetPath = p.join(_biosPath!, targetFilename);
      await File(targetPath).writeAsBytes(fileBytes);
      // Read the file back to confirm bytes-on-disk match bytes-sent.  If
      // the core later logs "Missing bios/firmware" with a path matching
      // _biosPath, the divergence is either (a) a runtime-cache inside the
      // .so or (b) a path-string encoding mismatch — not the upload itself.
      final onDiskSize = await File(targetPath).length();
      debugPrint(
        'Uploaded BIOS: $targetFilename (${fileBytes.length} bytes, '
        'verified $onDiskSize on disk at $targetPath)',
      );

      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'success': true, 'filename': targetFilename}),
      );
    } catch (e, st) {
      debugPrint('Upload BIOS error: $e\n$st');
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Handle GET `/api/download/<type>/<filename>` - download a file
  Future<void> _handleDownload(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }

    // Parse path: /api/download/saves/filename.sav or /api/download/roms/filename.gba
    final pathParts = request.uri.path.split('/');
    if (pathParts.length < 5) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(jsonEncode({'error': 'Invalid path'}));
      return;
    }

    final type = pathParts[3]; // 'saves' or 'roms'
    final fileName = Uri.decodeComponent(pathParts.sublist(4).join('/'));

    String basePath;
    if (type == 'saves') {
      basePath = _savesPath!;
    } else if (type == 'roms') {
      basePath = _romsPath!;
    } else {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(jsonEncode({'error': 'Invalid type'}));
      return;
    }

    final fullPath = p.join(basePath, fileName);

    // Security: ensure path is within the allowed directory
    if (!p.isWithin(basePath, fullPath)) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write(jsonEncode({'error': 'Access denied'}));
      return;
    }

    final file = File(fullPath);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'File not found'}));
      return;
    }

    // Serve the file
    request.response.headers.set('Content-Type', 'application/octet-stream');
    request.response.headers.set(
      'Content-Disposition',
      _buildContentDisposition(p.basename(fullPath)),
    );
    request.response.headers.set(
      'Content-Length',
      (await file.length()).toString(),
    );

    await request.response.addStream(file.openRead());
  }

  /// Handle POST /api/upload-save - upload save files
  Future<void> _handleUploadSave(HttpRequest request) async {
    if (request.method != 'POST') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }

    try {
      final contentType = request.headers.contentType;
      if (contentType == null ||
          !contentType.mimeType.contains('multipart/form-data')) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Invalid content type'}));
        return;
      }

      final boundary = contentType.parameters['boundary'];
      if (boundary == null) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Missing boundary'}));
        return;
      }

      final transformer = MimeMultipartTransformer(boundary);
      final parts = await transformer.bind(request).toList();

      final uploadedFiles = <String>[];

      for (final part in parts) {
        final contentDisposition = part.headers['content-disposition'];
        if (contentDisposition == null) continue;

        final filenameMatch = RegExp(
          r'filename="([^"]+)"',
        ).firstMatch(contentDisposition);
        if (filenameMatch == null) continue;

        final filename = filenameMatch.group(1)!;
        final ext = p.extension(filename).toLowerCase();

        // Saves, save-state slots, PNG screenshots & slot thumbnails (*.ssN.png)
        final lower = filename.toLowerCase();
        final isSaveSlot = RegExp(r'\.ss[0-5]$').hasMatch(lower);
        final isPng = ext == '.png';
        if (ext != '.sav' && !isSaveSlot && !isPng) {
          continue;
        }

        final filePath = p.join(_savesPath!, filename);
        final file = File(filePath);

        final bytes = await part.fold<List<int>>(
          [],
          (previous, element) => previous..addAll(element),
        );

        await file.writeAsBytes(bytes);
        uploadedFiles.add(filename);
        debugPrint('Uploaded save file: $filename');
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'success': true, 'files': uploadedFiles}),
      );
    } catch (e) {
      debugPrint('Upload save error: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Build a safe Content-Disposition header value.
  ///
  /// HTTP headers must be ASCII. For filenames containing non-ASCII characters
  /// we use RFC 5987 encoding (`filename*=UTF-8''...`), falling back to an
  /// ASCII-sanitized `filename` for legacy clients.
  static String _buildContentDisposition(String filename) {
    // Check if filename is pure ASCII (printable, no quotes/backslash).
    final isAsciiSafe = filename.codeUnits.every(
      (c) => c >= 0x20 && c <= 0x7E && c != 0x22 && c != 0x5C,
    );
    if (isAsciiSafe) {
      return 'attachment; filename="$filename"';
    }
    // RFC 5987: percent-encode the UTF-8 filename.
    final encoded = Uri.encodeFull(filename).replaceAll("'", '%27');
    // Provide a safe ASCII fallback (replace non-ASCII with underscore).
    final asciiFallback = filename.replaceAll(RegExp(r'[^\x20-\x7E]'), '_');
    return "attachment; filename=\"$asciiFallback\"; filename*=UTF-8''$encoded";
  }

  /// Get the HTML page for the web interface
  String _getHtmlPage() {
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>RetroPal File Manager</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
      color: #e4e4e4; min-height: 100vh; padding: 20px;
    }
    .container { max-width: 900px; margin: 0 auto; }
    header { text-align: center; margin-bottom: 24px; padding: 20px; background: rgba(255,255,255,0.05); border-radius: 16px; }
    h1 { color: #7b68ee; margin-bottom: 8px; }
    .subtitle { color: #888; font-size: 14px; }
    .tabs { display: flex; gap: 10px; margin-bottom: 20px; }
    .tab { padding: 12px 24px; border: none; border-radius: 8px; cursor: pointer; font-size: 14px; font-weight: 500; background: #2d3748; color: #888; transition: all 0.2s; }
    .tab:hover { background: #3d4758; color: #e4e4e4; }
    .tab.active { background: #7b68ee; color: white; }
    .toolbar { display: flex; gap: 10px; margin-bottom: 20px; flex-wrap: wrap; }
    .btn { padding: 10px 20px; border: none; border-radius: 8px; cursor: pointer; font-size: 14px; font-weight: 500; transition: all 0.2s; }
    .btn-primary { background: #7b68ee; color: white; }
    .btn-primary:hover { background: #6a5acd; }
    .btn-secondary { background: #2d3748; color: #e4e4e4; }
    .btn-secondary:hover { background: #3d4758; }
    .btn-danger { background: #e53e3e; color: white; }
    .btn-danger:hover { background: #c53030; }
    .breadcrumb { display: flex; align-items: center; gap: 8px; margin-bottom: 15px; padding: 10px 15px; background: rgba(255,255,255,0.05); border-radius: 8px; font-size: 14px; flex-wrap: wrap; }
    .breadcrumb a { color: #7b68ee; text-decoration: none; }
    .breadcrumb a:hover { text-decoration: underline; }
    .breadcrumb span { color: #666; }
    .file-list { background: rgba(255,255,255,0.03); border-radius: 12px; overflow: hidden; }
    .file-item { display: flex; align-items: center; padding: 12px 16px; border-bottom: 1px solid rgba(255,255,255,0.05); transition: background 0.2s; }
    .file-item:hover { background: rgba(255,255,255,0.05); }
    .file-item:last-child { border-bottom: none; }
    .file-icon { font-size: 24px; margin-right: 12px; }
    .file-info { flex: 1; cursor: pointer; }
    .file-name { font-weight: 500; }
    .file-meta { font-size: 12px; color: #666; margin-top: 2px; }
    .file-actions { display: flex; gap: 8px; }
    .file-actions .btn { padding: 6px 12px; font-size: 12px; }
    .upload-zone { border: 2px dashed #4a5568; border-radius: 12px; padding: 40px; text-align: center; margin-bottom: 20px; transition: all 0.2s; }
    .upload-zone.dragover { border-color: #7b68ee; background: rgba(123,104,238,0.1); }
    .upload-zone p { margin-bottom: 15px; color: #888; }
    .modal { display: none; position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.7); align-items: center; justify-content: center; z-index: 1000; }
    .modal.show { display: flex; }
    .modal-content { background: #1e2638; padding: 24px; border-radius: 12px; min-width: 300px; max-width: 90%; }
    .modal-content h3 { margin-bottom: 16px; }
    .modal-content input { width: 100%; padding: 10px; border: 1px solid #4a5568; border-radius: 8px; background: #2d3748; color: #e4e4e4; margin-bottom: 16px; font-size: 14px; }
    .modal-actions { display: flex; gap: 10px; justify-content: flex-end; }
    .empty-state { text-align: center; padding: 60px 20px; color: #666; }
    .empty-state .icon { font-size: 48px; margin-bottom: 16px; }
    .progress { height: 4px; background: #2d3748; border-radius: 2px; margin-top: 10px; overflow: hidden; display: none; }
    .progress.show { display: block; }
    .progress-bar { height: 100%; background: #7b68ee; width: 0%; transition: width 0.3s; }
    .instructions { background: rgba(123,104,238,0.08); border: 1px solid rgba(123,104,238,0.25); border-radius: 12px; padding: 16px 20px; margin-bottom: 20px; }
    .inst-title { font-weight: 600; font-size: 14px; color: #b8a9ff; margin-bottom: 10px; }
    .step { display: flex; align-items: flex-start; gap: 10px; margin-bottom: 7px; font-size: 13px; color: #a0aec0; }
    .step-num { flex-shrink: 0; width: 20px; height: 20px; border-radius: 50%; background: rgba(123,104,238,0.35); color: #c8b8ff; font-size: 11px; font-weight: bold; display: flex; align-items: center; justify-content: center; margin-top: 1px; }
    .inst-tip { display: flex; align-items: flex-start; gap: 8px; margin-top: 10px; padding: 8px 12px; background: rgba(237,137,54,0.12); border: 1px solid rgba(237,137,54,0.3); border-radius: 8px; font-size: 12px; color: #f6ad55; }
    .inst-formats { margin-top: 8px; font-size: 11px; color: #555; line-height: 1.6; }
    code { background: rgba(255,255,255,0.08); padding: 1px 5px; border-radius: 4px; font-family: monospace; font-size: 12px; color: #e2b96a; }
    .bios-section { display:flex; flex-direction:column; gap:14px; }
    .bios-legal { background:rgba(237,137,54,0.1); border:1px solid rgba(237,137,54,0.3); border-radius:8px; padding:10px 14px; font-size:12px; color:#f6ad55; line-height:1.5; }
    .bios-platform { background:rgba(255,255,255,0.03); border:1px solid rgba(255,255,255,0.08); border-radius:12px; overflow:hidden; }
    .bios-platform-header { padding:13px 16px 10px; border-bottom:1px solid rgba(255,255,255,0.06); }
    .bios-platform-title { font-weight:600; font-size:14px; color:#e4e4e4; margin-bottom:3px; }
    .bios-platform-subtitle { font-size:11px; color:#666; line-height:1.4; }
    .bios-file-row { display:flex; align-items:center; gap:12px; padding:11px 16px; border-bottom:1px solid rgba(255,255,255,0.05); }
    .bios-file-row:last-of-type { border-bottom:none; }
    .bios-file-info { flex:1; min-width:0; }
    .bios-file-name { font-size:13px; color:#e2b96a; font-family:monospace; margin-bottom:2px; }
    .bios-file-desc { font-size:11px; color:#666; }
    .bios-status { width:26px; height:26px; display:flex; align-items:center; justify-content:center; font-size:15px; flex-shrink:0; border-radius:50%; }
    .bios-status.ok      { background:rgba(72,187,120,0.15); color:#48bb78; }
    .bios-status.missing { background:rgba(74,85,104,0.3);   color:#4a5568; }
    .bios-status.invalid { background:rgba(229,62,62,0.15);  color:#e53e3e; }
    .bios-status.busy    { background:rgba(123,104,238,0.15);color:#7b68ee; font-size:11px; }
    .inst-divider { border: none; border-top: 1px solid rgba(255,255,255,0.06); margin: 12px 0; }
    .thumb { display: block; max-width: 200px; max-height: 120px; border-radius: 6px; margin-top: 8px; object-fit: cover; border: 1px solid rgba(255,255,255,0.12); cursor: zoom-in; }
    .toast { position: fixed; bottom: 20px; right: 20px; background: #2d3748; padding: 12px 20px; border-radius: 8px; box-shadow: 0 4px 12px rgba(0,0,0,0.3); transform: translateY(100px); opacity: 0; transition: all 0.3s; }
    .toast.show { transform: translateY(0); opacity: 1; }
    .toast.success { border-left: 4px solid #48bb78; }
    .toast.error { border-left: 4px solid #e53e3e; }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>RetroPal File Manager</h1>
      <p class="subtitle">Manage ROMs, saves, and screenshots on your Android TV (screenshots live under Save Files)</p>
    </header>

    <div class="tabs">
      <button class="tab active" id="romsTab" onclick="switchTab('roms')">ROMs</button>
      <button class="tab" id="savesTab" onclick="switchTab('saves')">Save Files</button>
      <button class="tab" id="screenshotsTab" onclick="switchTab('screenshots')">Screenshots</button>
      <button class="tab" id="biosTab" onclick="switchTab('bios')">BIOS</button>
    </div>

    <div class="instructions" id="instructionsPanel">
      <div class="inst-title">&#128203; How to use</div>

      <div id="romsInst">
        <div class="step"><span class="step-num">1</span><span>Switch to the <strong>ROMs</strong> tab, then drag &amp; drop ROM files here or click <em>Select Files</em>.</span></div>
        <div class="step"><span class="step-num">2</span><span>If your ROMs are inside a ZIP or archive, <strong>extract them first</strong> — then upload the individual files.</span></div>
        <div class="step"><span class="step-num">3</span><span>Uploaded ROMs appear automatically in your game library on the TV.</span></div>
        <div class="inst-tip">&#9888;&#65039; ZIP files are <strong>not</strong> auto-extracted. Upload individual ROM files (.gba, .nes, .sfc&hellip;) for them to appear in your library.</div>
        <div class="inst-formats">Supported: .gba .gb .gbc .nes .unf .unif .sfc .smc .sg .sms .gg .md .gen .smd .bin .pce .sgx .cue .z64 .n64 .v64 .ngp .ngc .ws .wsc .a26 .vb .tic .p8 .p8.png .int .itv .rom<br>PS1 cue/bin ZIP import is supported from the in-app Add ROM flow; this web uploader does not auto-extract ZIPs.</div>
      </div>

      <hr class="inst-divider">

      <div id="savesInst">
        <div class="step"><span class="step-num">1</span><span>Switch to the <strong>Save Files</strong> tab, then upload your <code>.sav</code> file to the <strong>root</strong> of the list (do not navigate into a subfolder first).</span></div>
        <div class="step"><span class="step-num">2</span><span><strong>Filename must match the ROM name.</strong> If your ROM is <code>SuperMario.gba</code>, the save must be named <code>SuperMario.sav</code>.</span></div>
        <div class="step"><span class="step-num">3</span><span>Save states use the full ROM name + slot: <code>SuperMario.gba.ss0</code> &hellip; <code>SuperMario.gba.ss5</code>.</span></div>
        <div class="step"><span class="step-num">&#128444;</span><span>Screenshot images (.png) are shown as <strong>inline thumbnails</strong> &mdash; click a thumbnail to open it full-size.</span></div>
        <div class="inst-tip">&#128161; After uploading, launch the game on the TV &mdash; it will automatically pick up the new save.</div>
      </div>

      <hr class="inst-divider">

      <div id="biosInst" style="display:none">
        <div class="step"><span class="step-num">1</span><span>Switch to the <strong>BIOS</strong> tab and upload BIOS files to the root of the list. Filenames must match exactly &mdash; the libretro cores load them by name.</span></div>
        <div class="step"><span class="step-num">2</span><span><strong>Mattel Intellivision (FreeIntv):</strong> <code>exec.bin</code> (8 KB) <em>and</em> <code>grom.bin</code> (2 KB). Mandatory on every platform &mdash; no HLE exists.</span></div>
        <div class="step"><span class="step-num">3</span><span><strong>Nintendo DS (melonDS) &mdash; gameplay coming in a future update:</strong> <code>bios7.bin</code> (16 KB), <code>bios9.bin</code> (4 KB), <code>firmware.bin</code> (128/256 KB). Optional on mobile (built-in FreeBIOS HLE), required on Android TV.</span></div>
        <div class="step"><span class="step-num">4</span><span><strong>Sony PlayStation (Beetle PSX HW) &mdash; gameplay coming in a future update:</strong> any of <code>scph5500.bin</code> (JP), <code>scph5501.bin</code> (US), <code>scph5502.bin</code> (EU) &mdash; 512 KB each. OpenBIOS is bundled as a free fallback on mobile; Android TV requires a real Sony BIOS.</span></div>
        <div class="inst-tip">&#9888;&#65039; BIOS files are not provided. Only use BIOS dumps from hardware you legally own.</div>
      </div>
    </div>

    <div class="upload-zone" id="uploadZone">
      <p id="uploadLabel">Drag & drop files here, or click to select</p>
      <input type="file" id="fileInput" multiple style="display:none">
      <button class="btn btn-primary" onclick="document.getElementById('fileInput').click()">Select Files</button>
      <div class="progress" id="uploadProgress">
        <div class="progress-bar" id="progressBar"></div>
      </div>
    </div>

    <div class="toolbar">
      <button class="btn btn-secondary" onclick="createFolder()">New Folder</button>
      <button class="btn btn-secondary" onclick="refreshFiles()">Refresh</button>
    </div>

    <div class="breadcrumb" id="breadcrumb"></div>
    <div class="file-list" id="fileList"></div>

    <!-- BIOS tab: per-file upload cards (shown instead of the file browser) -->
    <div id="biosSection" style="display:none" class="bios-section">
      <div class="bios-legal">&#9888;&#65039; BIOS files are <strong>not provided</strong>. Only use dumps from hardware you legally own.<br>&#128250; <strong>Android TV:</strong> NDS requires all three files; PS1 needs at least one Sony BIOS variant; Intellivision needs both files.<br>&#128241; <strong>Mobile:</strong> NDS uses FreeBIOS HLE if files are absent; PS1 falls back to bundled OpenBIOS.</div>

      <div class="bios-platform">
        <div class="bios-platform-header">
          <div class="bios-platform-title">Mattel Intellivision (FreeIntv)</div>
          <div class="bios-platform-subtitle"><strong>Both files required on every platform</strong> &mdash; no HLE exists</div>
        </div>
        <div class="bios-file-row">
          <div class="bios-file-info"><div class="bios-file-name">exec.bin</div><div class="bios-file-desc">Executive ROM &middot; reference size: 8 192 B</div></div>
          <div class="bios-status missing" id="status-exec" title="Not uploaded">&#10007;</div>
          <input type="file" id="input-exec" style="display:none" onchange="uploadBiosFile('exec', this)">
          <button class="btn btn-primary" style="padding:6px 14px;font-size:12px;flex-shrink:0" onclick="document.getElementById('input-exec').click()">Upload</button>
        </div>
        <div class="bios-file-row">
          <div class="bios-file-info"><div class="bios-file-name">grom.bin</div><div class="bios-file-desc">Graphics ROM &middot; reference size: 2 048 B</div></div>
          <div class="bios-status missing" id="status-grom" title="Not uploaded">&#10007;</div>
          <input type="file" id="input-grom" style="display:none" onchange="uploadBiosFile('grom', this)">
          <button class="btn btn-primary" style="padding:6px 14px;font-size:12px;flex-shrink:0" onclick="document.getElementById('input-grom').click()">Upload</button>
        </div>
      </div>

      <div class="bios-platform">
        <div class="bios-platform-header">
          <div class="bios-platform-title">Nintendo DS (melonDS) &mdash; gameplay coming in a future update</div>
          <div class="bios-platform-subtitle">Optional on mobile &mdash; <strong>all three required on Android TV</strong></div>
        </div>
        <div class="bios-file-row">
          <div class="bios-file-info"><div class="bios-file-name">bios7.bin</div><div class="bios-file-desc">ARM7 BIOS &middot; reference size: 16 384 B</div></div>
          <div class="bios-status missing" id="status-bios7" title="Not uploaded">&#10007;</div>
          <input type="file" id="input-bios7" style="display:none" onchange="uploadBiosFile('bios7', this)">
          <button class="btn btn-primary" style="padding:6px 14px;font-size:12px;flex-shrink:0" onclick="document.getElementById('input-bios7').click()">Upload</button>
        </div>
        <div class="bios-file-row">
          <div class="bios-file-info"><div class="bios-file-name">bios9.bin</div><div class="bios-file-desc">ARM9 BIOS &middot; reference size: 4 096 B</div></div>
          <div class="bios-status missing" id="status-bios9" title="Not uploaded">&#10007;</div>
          <input type="file" id="input-bios9" style="display:none" onchange="uploadBiosFile('bios9', this)">
          <button class="btn btn-primary" style="padding:6px 14px;font-size:12px;flex-shrink:0" onclick="document.getElementById('input-bios9').click()">Upload</button>
        </div>
        <div class="bios-file-row">
          <div class="bios-file-info"><div class="bios-file-name">firmware.bin</div><div class="bios-file-desc">Firmware &middot; 128 KB (original DS) or 256 KB (DSi+)</div></div>
          <div class="bios-status missing" id="status-firmware" title="Not uploaded">&#10007;</div>
          <input type="file" id="input-firmware" style="display:none" onchange="uploadBiosFile('firmware', this)">
          <button class="btn btn-primary" style="padding:6px 14px;font-size:12px;flex-shrink:0" onclick="document.getElementById('input-firmware').click()">Upload</button>
        </div>
      </div>

      <div class="bios-platform">
        <div class="bios-platform-header">
          <div class="bios-platform-title">Sony PlayStation (Beetle PSX HW) &mdash; gameplay coming in a future update</div>
          <div class="bios-platform-subtitle">Any <em>one</em> of the three regional variants is enough &mdash; <strong>real BIOS required on Android TV</strong> (OpenBIOS bundled as fallback on mobile)</div>
        </div>
        <div class="bios-file-row">
          <div class="bios-file-info"><div class="bios-file-name">scph5500.bin</div><div class="bios-file-desc">Japan region BIOS &middot; reference size: 512 KB</div></div>
          <div class="bios-status missing" id="status-scph5500" title="Not uploaded">&#10007;</div>
          <input type="file" id="input-scph5500" style="display:none" onchange="uploadBiosFile('scph5500', this)">
          <button class="btn btn-primary" style="padding:6px 14px;font-size:12px;flex-shrink:0" onclick="document.getElementById('input-scph5500').click()">Upload</button>
        </div>
        <div class="bios-file-row">
          <div class="bios-file-info"><div class="bios-file-name">scph5501.bin</div><div class="bios-file-desc">USA region BIOS &middot; reference size: 512 KB</div></div>
          <div class="bios-status missing" id="status-scph5501" title="Not uploaded">&#10007;</div>
          <input type="file" id="input-scph5501" style="display:none" onchange="uploadBiosFile('scph5501', this)">
          <button class="btn btn-primary" style="padding:6px 14px;font-size:12px;flex-shrink:0" onclick="document.getElementById('input-scph5501').click()">Upload</button>
        </div>
        <div class="bios-file-row">
          <div class="bios-file-info"><div class="bios-file-name">scph5502.bin</div><div class="bios-file-desc">Europe region BIOS &middot; reference size: 512 KB</div></div>
          <div class="bios-status missing" id="status-scph5502" title="Not uploaded">&#10007;</div>
          <input type="file" id="input-scph5502" style="display:none" onchange="uploadBiosFile('scph5502', this)">
          <button class="btn btn-primary" style="padding:6px 14px;font-size:12px;flex-shrink:0" onclick="document.getElementById('input-scph5502').click()">Upload</button>
        </div>
      </div>

      <button class="btn btn-secondary" style="align-self:flex-start" onclick="loadBiosStatus()">&#8635; Refresh Status</button>
    </div>
  </div>

  <div class="modal" id="folderModal">
    <div class="modal-content">
      <h3>Create New Folder</h3>
      <input type="text" id="folderName" placeholder="Folder name">
      <div class="modal-actions">
        <button class="btn btn-secondary" onclick="closeFolderModal()">Cancel</button>
        <button class="btn btn-primary" onclick="submitFolder()">Create</button>
      </div>
    </div>
  </div>

  <div class="toast" id="toast"></div>

  <script>
    let currentTab = 'roms';
    let currentPath = '';

    function rootPath() {
      if (currentTab === 'roms') return 'roms';
      if (currentTab === 'bios') return 'system';
      return 'saves';
    }
    function fullPath() { return currentPath ? rootPath() + '/' + currentPath : rootPath(); }
    function isScreenshotsTab() { return currentTab === 'screenshots'; }
    function isBiosTab() { return currentTab === 'bios'; }

    document.addEventListener('DOMContentLoaded', () => {
      refreshFiles();
      setupDragDrop();
      document.getElementById('fileInput').addEventListener('change', (e) => {
        uploadFiles(e.target.files); e.target.value = '';
      });
    });

    function switchTab(tab) {
      currentTab = tab;
      currentPath = '';
      document.getElementById('romsTab').classList.toggle('active', tab === 'roms');
      document.getElementById('savesTab').classList.toggle('active', tab === 'saves');
      document.getElementById('screenshotsTab').classList.toggle('active', tab === 'screenshots');
      document.getElementById('biosTab').classList.toggle('active', tab === 'bios');
      const uploadZone   = document.getElementById('uploadZone');
      const instPanel    = document.getElementById('instructionsPanel');
      const toolbar      = document.querySelector('.toolbar');
      const breadcrumb   = document.getElementById('breadcrumb');
      const fileList     = document.getElementById('fileList');
      const biosSection  = document.getElementById('biosSection');
      // Toggle visibility of per-tab instruction blocks
      document.getElementById('romsInst').style.display  = tab === 'roms'  ? '' : 'none';
      document.getElementById('savesInst').style.display = tab === 'saves' ? '' : 'none';
      document.getElementById('biosInst').style.display  = 'none'; // biosSection replaces this
      if (tab === 'bios') {
        // BIOS tab: show purpose-built per-file upload cards; hide generic browser UI
        uploadZone.style.display  = 'none';
        instPanel.style.display   = 'none';
        toolbar.style.display     = 'none';
        breadcrumb.style.display  = 'none';
        fileList.style.display    = 'none';
        biosSection.style.display = '';
        loadBiosStatus();
      } else {
        // Any other tab: restore generic file browser UI
        biosSection.style.display = 'none';
        toolbar.style.display     = '';
        breadcrumb.style.display  = '';
        fileList.style.display    = '';
        if (tab === 'screenshots') {
          uploadZone.style.display = 'none';
          instPanel.style.display  = 'none';
        } else {
          uploadZone.style.display = '';
          instPanel.style.display  = '';
          document.getElementById('uploadLabel').textContent =
            tab === 'roms' ? 'Drag & drop ROM files here, or click to select'
                           : 'Drag & drop saves or save states here';
        }
        refreshFiles();
      }
    }

    function setupDragDrop() {
      const zone = document.getElementById('uploadZone');
      zone.addEventListener('dragover', (e) => { e.preventDefault(); zone.classList.add('dragover'); });
      zone.addEventListener('dragleave', () => zone.classList.remove('dragover'));
      zone.addEventListener('drop', (e) => {
        e.preventDefault(); zone.classList.remove('dragover');
        uploadFiles(e.dataTransfer.files);
      });
    }

    async function uploadFiles(files) {
      if (!files.length) return;
      const progress = document.getElementById('uploadProgress');
      const bar = document.getElementById('progressBar');
      progress.classList.add('show');
      const fd = new FormData();
      fd.append('path', fullPath());
      for (const f of files) fd.append('files', f);
      const xhr = new XMLHttpRequest();
      xhr.open('POST', '/api/upload');
      xhr.upload.onprogress = (e) => { if (e.lengthComputable) bar.style.width = (e.loaded/e.total*100)+'%'; };
      xhr.onload = () => {
        progress.classList.remove('show'); bar.style.width = '0%';
        if (xhr.status === 200) {
          showToast('Uploaded ' + JSON.parse(xhr.responseText).files.length + ' file(s)', 'success');
          refreshFiles();
        } else showToast('Upload failed', 'error');
      };
      xhr.onerror = () => { progress.classList.remove('show'); showToast('Upload failed', 'error'); };
      xhr.send(fd);
    }

    async function refreshFiles() {
      try {
        const r = await fetch('/api/files?path=' + encodeURIComponent(fullPath()));
        const data = await r.json();
        renderBreadcrumb();
        renderFileList(data.items);
      } catch (e) { showToast('Failed to load files', 'error'); }
    }

    function renderBreadcrumb() {
      const c = document.getElementById('breadcrumb');
      const label = currentTab === 'roms' ? 'ROMs'
        : currentTab === 'screenshots' ? 'Screenshots'
        : currentTab === 'bios' ? 'BIOS'
        : 'Saves';
      const parts = currentPath.split('/').filter(p => p);
      let html = '<a href="#" onclick="navigateTo(\\'\\')">' + label + '</a>';
      let path = '';
      for (const part of parts) {
        path += (path ? '/' : '') + part;
        html += ' <span>/</span> <a href="#" onclick="navigateTo(\\'' + path + '\\')">' + part + '</a>';
      }
      c.innerHTML = html;
    }

    function renderFileList(items) {
      const c = document.getElementById('fileList');
      if (isScreenshotsTab()) {
        items = items.filter(i => !i.isDirectory && i.name.toLowerCase().endsWith('.png'));
      }
      if (!items.length) {
        let msg = 'No save files yet';
        let icon = 0x1F4BE;
        if (currentTab === 'roms') { msg = 'No ROM files yet'; icon = 0x1F3AE; }
        else if (currentTab === 'screenshots') { msg = 'No screenshots yet'; icon = 0x1F5BC; }
        else if (currentTab === 'bios') { msg = 'No BIOS files uploaded'; icon = 0x1F9E0; }
        c.innerHTML = '<div class="empty-state"><div class="icon">' + String.fromCodePoint(icon) + '</div><p>' + msg + '</p></div>';
        return;
      }
      let html = '';
      for (const item of items) {
        const icon = item.isDirectory ? String.fromCodePoint(0x1F4C1) : getFileIcon(item.name);
        const size = item.isDirectory ? '' : formatSize(item.size);
        const ext = item.isDirectory ? '' : item.name.split('.').pop().toLowerCase();
        const itemPath = currentPath ? currentPath + '/' + item.name : item.name;
        html += '<div class="file-item">';
        html += '<span class="file-icon">' + icon + '</span>';
        html += '<div class="file-info" onclick="' + (item.isDirectory ? "navigateTo('" + itemPath + "')" : '') + '">';
        html += '<div class="file-name">' + item.name + '</div>';
        html += '<div class="file-meta">' + size + '</div>';
        if (!item.isDirectory && ext === 'png') {
          const thumbUrl = '/api/download-file?path=' + encodeURIComponent(rootPath() + '/' + itemPath);
          html += '<img class="thumb" src="' + thumbUrl + '" alt="" loading="lazy" onclick="window.open(this.src)" onerror="this.style.display=\\'none\\'">';
        }
        html += '</div><div class="file-actions">';
        if (!item.isDirectory) {
          const dlPath = currentPath ? rootPath() + '/' + itemPath : rootPath() + '/' + item.name;
          html += '<button class="btn btn-secondary" onclick="downloadFile(\\'' + dlPath + '\\')">' + String.fromCodePoint(0x2B07) + ' Download</button>';
        }
        const delPath = currentPath ? rootPath() + '/' + itemPath : rootPath() + '/' + item.name;
        html += '<button class="btn btn-danger" onclick="deleteItem(\\'' + delPath + '\\', ' + item.isDirectory + ')">' + String.fromCodePoint(0x1F5D1) + '</button>';
        html += '</div></div>';
      }
      c.innerHTML = html;
    }

    function getFileIcon(name) {
      const ext = name.split('.').pop().toLowerCase();
      const m = { gba:0x1F3AE, gbc:0x1F3AE, gb:0x1F3AE, nes:0x1F579, sfc:0x1F579, smc:0x1F579,
        md:0x1F3AF, bin:0x1F3AF, sms:0x1F4FA, gg:0x1F4FA, zip:0x1F4E6,
        sav:0x1F4BE, srm:0x1F4BE, ss0:0x1F4BE, ss1:0x1F4BE, ss2:0x1F4BE, ss3:0x1F4BE, ss4:0x1F4BE, ss5:0x1F4BE,
        png:0x1F5BC, jpg:0x1F5BC, jpeg:0x1F5BC };
      return m[ext] ? String.fromCodePoint(m[ext]) : String.fromCodePoint(0x1F4C4);
    }

    function formatSize(bytes) {
      if (bytes < 1024) return bytes + ' B';
      if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
      return (bytes / 1048576).toFixed(1) + ' MB';
    }

    function navigateTo(path) { currentPath = path; refreshFiles(); }

    function downloadFile(filePath) {
      window.location.href = '/api/download-file?path=' + encodeURIComponent(filePath);
    }

    function createFolder() {
      document.getElementById('folderModal').classList.add('show');
      document.getElementById('folderName').focus();
    }
    function closeFolderModal() {
      document.getElementById('folderModal').classList.remove('show');
      document.getElementById('folderName').value = '';
    }

    async function submitFolder() {
      const name = document.getElementById('folderName').value.trim();
      if (!name) return;
      try {
        const r = await fetch('/api/folder?path=' + encodeURIComponent(fullPath()) + '&name=' + encodeURIComponent(name), { method: 'POST' });
        if (r.ok) { showToast('Folder created', 'success'); closeFolderModal(); refreshFiles(); }
        else { const d = await r.json(); showToast(d.error || 'Failed', 'error'); }
      } catch (e) { showToast('Failed to create folder', 'error'); }
    }

    async function deleteItem(path, isDir) {
      const type = isDir ? 'folder' : 'file';
      if (!confirm('Delete this ' + type + '?')) return;
      try {
        const r = await fetch('/api/delete?path=' + encodeURIComponent(path), { method: 'DELETE' });
        if (r.ok) { showToast(type.charAt(0).toUpperCase() + type.slice(1) + ' deleted', 'success'); refreshFiles(); }
        else showToast('Failed to delete', 'error');
      } catch (e) { showToast('Failed to delete', 'error'); }
    }

    function showToast(msg, type) {
      const t = document.getElementById('toast');
      t.textContent = msg; t.className = 'toast show ' + type;
      setTimeout(() => t.classList.remove('show'), 3000);
    }

    // ── BIOS management ─────────────────────────────────────────────

    async function loadBiosStatus() {
      // Show spinner on all slots while fetching
      const ids = ['bios7','bios9','firmware','scph5500','scph5501','scph5502','exec','grom'];
      ids.forEach(id => {
        const el = document.getElementById('status-' + id);
        if (el) { el.className = 'bios-status busy'; el.textContent = '...'; el.title = 'Checking…'; }
      });
      try {
        const r = await fetch('/api/bios-status');
        if (!r.ok) { showToast('Failed to read BIOS status', 'error'); return; }
        const data = await r.json();
        for (const platform of Object.values(data)) {
          for (const f of platform) {
            const el = document.getElementById('status-' + f.id);
            if (!el) continue;
            if (f.valid) {
              const kb = f.size < 1024 ? f.size + ' B' : (f.size < 1048576 ? (f.size/1024).toFixed(0) + ' KB' : (f.size/1048576).toFixed(1) + ' MB');
              el.className = 'bios-status ok'; el.textContent = '\u2713'; el.title = 'OK \u2014 ' + kb;
            } else if (f.exists) {
              let reason = 'Invalid BIOS';
              if (f.hashChecked && !f.hashValid) {
                reason = 'Hash mismatch';
                if (f.expectedMd5 && f.expectedMd5.length) {
                  reason += ' \u2014 expected MD5 ' + f.expectedMd5[0];
                }
              }
              el.className = 'bios-status invalid'; el.textContent = '!'; el.title = reason;
            } else {
              el.className = 'bios-status missing'; el.textContent = '\u2717'; el.title = 'Not uploaded';
            }
          }
        }
      } catch(e) { showToast('BIOS status error: ' + e, 'error'); }
    }

    async function uploadBiosFile(biosId, inputEl) {
      const file = inputEl.files[0];
      if (!file) return;
      const statusEl = document.getElementById('status-' + biosId);
      if (statusEl) { statusEl.className = 'bios-status busy'; statusEl.textContent = '...'; statusEl.title = 'Uploading…'; }
      const fd = new FormData();
      fd.append('biosId', biosId);
      fd.append('file', file);
      try {
        const r = await fetch('/api/upload-bios', { method: 'POST', body: fd });
        const d = await r.json();
        if (r.ok && d.success) {
          showToast('\u2713 ' + d.filename + ' uploaded', 'success');
        } else {
          showToast('Upload failed: ' + (d.error || r.status), 'error');
        }
      } catch(e) { showToast('Upload error: ' + e, 'error'); }
      inputEl.value = '';
      // Refresh all statuses so the user sees the new state immediately
      loadBiosStatus();
    }

    document.getElementById('folderName').addEventListener('keypress', (e) => {
      if (e.key === 'Enter') submitFolder();
    });
  </script>
</body>
</html>
''';
  }
}

/// Simple multipart form data parser
class MimeMultipartTransformer
    implements StreamTransformer<List<int>, MimeMultipart> {
  final String boundary;

  MimeMultipartTransformer(this.boundary);

  @override
  Stream<MimeMultipart> bind(Stream<List<int>> stream) async* {
    final boundaryBytes = utf8.encode('--$boundary');
    final buffer = <int>[];

    await for (final chunk in stream) {
      buffer.addAll(chunk);
    }

    final data = buffer;
    var start = 0;

    // Find first boundary
    var boundaryStart = _indexOf(data, boundaryBytes, start);
    if (boundaryStart == -1) return;

    start = boundaryStart + boundaryBytes.length;

    while (true) {
      // Skip CRLF after boundary
      if (start < data.length && data[start] == 13) start++;
      if (start < data.length && data[start] == 10) start++;

      // Check for end boundary
      if (start + 1 < data.length &&
          data[start] == 45 &&
          data[start + 1] == 45) {
        break;
      }

      // Find headers end (double CRLF)
      final headersEnd = _indexOfCRLFCRLF(data, start);
      if (headersEnd == -1) break;

      final headersStr = utf8.decode(data.sublist(start, headersEnd));
      final headers = <String, String>{};

      for (final line in headersStr.split(RegExp(r'\r?\n'))) {
        final colonIdx = line.indexOf(':');
        if (colonIdx > 0) {
          final key = line.substring(0, colonIdx).trim().toLowerCase();
          final value = line.substring(colonIdx + 1).trim();
          headers[key] = value;
        }
      }

      final contentStart = headersEnd + 4; // Skip \r\n\r\n

      // Find next boundary
      final nextBoundary = _indexOf(data, boundaryBytes, contentStart);
      if (nextBoundary == -1) break;

      // Content ends before the boundary (minus CRLF)
      var contentEnd = nextBoundary;
      if (contentEnd > 1 && data[contentEnd - 1] == 10) contentEnd--;
      if (contentEnd > 1 && data[contentEnd - 1] == 13) contentEnd--;

      final content = data.sublist(contentStart, contentEnd);

      yield MimeMultipart(headers, Stream.value(content));

      start = nextBoundary + boundaryBytes.length;
    }
  }

  int _indexOf(List<int> data, List<int> pattern, int start) {
    outer:
    for (var i = start; i <= data.length - pattern.length; i++) {
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  int _indexOfCRLFCRLF(List<int> data, int start) {
    for (var i = start; i < data.length - 3; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  @override
  StreamTransformer<RS, RT> cast<RS, RT>() {
    throw UnimplementedError();
  }
}

/// Represents a part of a multipart form
class MimeMultipart {
  final Map<String, String> headers;
  final Stream<List<int>> _stream;

  MimeMultipart(this.headers, this._stream);

  Future<void> pipe(IOSink sink) async {
    await for (final chunk in _stream) {
      sink.add(chunk);
    }
  }

  Future<List<int>> fold<T>(
    List<int> initial,
    List<int> Function(List<int>, List<int>) combine,
  ) async {
    var result = initial;
    await for (final chunk in _stream) {
      result = combine(result, chunk);
    }
    return result;
  }
}
