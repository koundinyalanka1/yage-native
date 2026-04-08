import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class TvHttpServer {
  static TvHttpServer? _instance;
  static TvHttpServer get instance => _instance ??= TvHttpServer._();

  TvHttpServer._();

  HttpServer? _server;
  String? _appPath;
  String? _romsPath;
  String? _savesPath;

  bool get isRunning => _server != null;

  String? get serverUrl => _serverUrl;
  String? _serverUrl;

  int get port => _port;
  int _port = 8080;

  final _statusController = StreamController<bool>.broadcast();
  Stream<bool> get statusStream => _statusController.stream;

  Future<String?> start() async {
    if (_server != null) {
      return _serverUrl;
    }

    try {
      final appDir = await getApplicationSupportDirectory();
      _appPath = appDir.path;
      _romsPath = p.join(appDir.path, 'roms');
      _savesPath = p.join(appDir.path, 'saves');
      final romsDir = Directory(_romsPath!);
      if (!await romsDir.exists()) {
        await romsDir.create(recursive: true);
      }
      final savesDir = Directory(_savesPath!);
      if (!await savesDir.exists()) {
        await savesDir.create(recursive: true);
      }
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
      final ip = await _getLocalIpAddress();
      _serverUrl = 'http://$ip:$_port';

      debugPrint('TvHttpServer started at $_serverUrl');
      debugPrint('ROMs directory: $_romsPath');
      _server!.listen(_handleRequest);

      _statusController.add(true);
      return _serverUrl;
    } catch (e) {
      debugPrint('Failed to start TvHttpServer: $e');
      await stop();
      return null;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _serverUrl = null;
    _statusController.add(false);
    debugPrint('TvHttpServer stopped');
  }

  Future<String> _getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
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

  Future<void> _handleRequest(HttpRequest request) async {
    try {
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
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('Not Found');
      }
    } catch (e) {
      debugPrint('Error handling request: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Internal Server Error: $e');
    } finally {
      await request.response.close();
    }
  }

  Future<void> _serveHtml(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write(_getHtmlPage());
  }

  Future<void> _handleFilesApi(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }

    final subPath = request.uri.queryParameters['path'] ?? '';
    final fullPath = subPath.isEmpty ? _appPath! : p.join(_appPath!, subPath);
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
      String targetPath = '';
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
            final file = File(fullPath);
            await file.writeAsBytes(
              Uint8List.sublistView(
                Uint8List.fromList(data),
                contentStart,
                contentEnd,
              ),
            );

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

  Future<void> _handleFolder(HttpRequest request) async {
    final subPath = request.uri.queryParameters['path'] ?? '';
    final name = request.uri.queryParameters['name'] ?? '';

    if (request.method == 'POST') {
      if (name.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Folder name required'}));
        return;
      }

      final fullPath = p.join(_appPath!, subPath, name);
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
      'attachment; filename="${p.basename(fullPath)}"',
    );
    request.response.headers.set(
      'Content-Length',
      (await file.length()).toString(),
    );

    await request.response.addStream(file.openRead());
  }

  Future<void> _handleStatus(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'running': true,
        'romsPath': _romsPath,
        'savesPath': _savesPath,
      }),
    );
  }

  Future<void> _handleDownload(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      return;
    }
    final pathParts = request.uri.path.split('/');
    if (pathParts.length < 5) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(jsonEncode({'error': 'Invalid path'}));
      return;
    }

    final type = pathParts[3]; 
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
    request.response.headers.set('Content-Type', 'application/octet-stream');
    request.response.headers.set(
      'Content-Disposition',
      'attachment; filename="${p.basename(fullPath)}"',
    );
    request.response.headers.set(
      'Content-Length',
      (await file.length()).toString(),
    );

    await request.response.addStream(file.openRead());
  }

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
    </div>

    <div class="instructions" id="instructionsPanel">
      <div class="inst-title">&#128203; How to use</div>

      <div id="romsInst">
        <div class="step"><span class="step-num">1</span><span>Switch to the <strong>ROMs</strong> tab, then drag &amp; drop ROM files here or click <em>Select Files</em>.</span></div>
        <div class="step"><span class="step-num">2</span><span>If your ROMs are inside a ZIP or archive, <strong>extract them first</strong> — then upload the individual files.</span></div>
        <div class="step"><span class="step-num">3</span><span>Uploaded ROMs appear automatically in your game library on the TV.</span></div>
        <div class="inst-tip">&#9888;&#65039; ZIP files are <strong>not</strong> auto-extracted. Upload individual ROM files (.gba, .nes, .sfc&hellip;) for them to appear in your library.</div>
        <div class="inst-formats">Supported: .gba .gb .gbc .nes .unf .unif .sfc .smc .sg .sms .gg .md .gen .smd .bin .pce .sgx .cue .chd .z64 .n64 .v64 .ngp .ngc .ws .wsc</div>
      </div>

      <hr class="inst-divider">

      <div id="savesInst">
        <div class="step"><span class="step-num">1</span><span>Switch to the <strong>Save Files</strong> tab, then upload your <code>.sav</code> file to the <strong>root</strong> of the list (do not navigate into a subfolder first).</span></div>
        <div class="step"><span class="step-num">2</span><span><strong>Filename must match the ROM name.</strong> If your ROM is <code>SuperMario.gba</code>, the save must be named <code>SuperMario.sav</code>.</span></div>
        <div class="step"><span class="step-num">3</span><span>Save states use the full ROM name + slot: <code>SuperMario.gba.ss0</code> &hellip; <code>SuperMario.gba.ss5</code>.</span></div>
        <div class="step"><span class="step-num">&#128444;</span><span>Screenshot images (.png) are shown as <strong>inline thumbnails</strong> &mdash; click a thumbnail to open it full-size.</span></div>
        <div class="inst-tip">&#128161; After uploading, launch the game on the TV &mdash; it will automatically pick up the new save.</div>
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

    function rootPath() { return currentTab === 'roms' ? 'roms' : 'saves'; }
    function fullPath() { return currentPath ? rootPath() + '/' + currentPath : rootPath(); }
    function isScreenshotsTab() { return currentTab === 'screenshots'; }

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
      const uploadZone = document.getElementById('uploadZone');
      const instPanel = document.getElementById('instructionsPanel');
      if (tab === 'screenshots') {
        uploadZone.style.display = 'none';
        instPanel.style.display = 'none';
      } else {
        uploadZone.style.display = '';
        instPanel.style.display = '';
        document.getElementById('uploadLabel').textContent = tab === 'roms'
          ? 'Drag & drop ROM files here, or click to select'
          : 'Drag & drop saves or save states here';
      }
      refreshFiles();
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
      const label = currentTab === 'roms' ? 'ROMs' : currentTab === 'screenshots' ? 'Screenshots' : 'Saves';
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
        const msg = currentTab === 'roms' ? 'No ROM files yet' : currentTab === 'screenshots' ? 'No screenshots yet' : 'No save files yet';
        const icon = currentTab === 'roms' ? String.fromCodePoint(0x1F3AE) : currentTab === 'screenshots' ? String.fromCodePoint(0x1F5BC) : String.fromCodePoint(0x1F4BE);
        c.innerHTML = '<div class="empty-state"><div class="icon">' + icon + '</div><p>' + msg + '</p></div>';
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

    document.getElementById('folderName').addEventListener('keypress', (e) => {
      if (e.key === 'Enter') submitFolder();
    });
  </script>
</body>
</html>
''';
  }
}

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
    var boundaryStart = _indexOf(data, boundaryBytes, start);
    if (boundaryStart == -1) return;

    start = boundaryStart + boundaryBytes.length;

    while (true) {
      if (start < data.length && data[start] == 13) start++;
      if (start < data.length && data[start] == 10) start++;
      if (start + 1 < data.length &&
          data[start] == 45 &&
          data[start + 1] == 45) {
        break;
      }
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

      final contentStart = headersEnd + 4; 
      final nextBoundary = _indexOf(data, boundaryBytes, contentStart);
      if (nextBoundary == -1) break;
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
