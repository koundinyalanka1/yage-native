import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef _YageRcHashFileNative =
    Int32 Function(
      Uint32 consoleId,
      Pointer<Utf8> path,
      Pointer<Utf8> outHash,
      Int32 outHashSize,
    );
typedef _YageRcHashFile =
    int Function(
      int consoleId,
      Pointer<Utf8> path,
      Pointer<Utf8> outHash,
      int outHashSize,
    );

/// Lightweight binding for official rcheevos file hashing.
class RcheevosHashBindings {
  RcheevosHashBindings._();

  static _YageRcHashFile? _hashFile;
  static bool _loadAttempted = false;

  static String? hashFile({required int consoleId, required String path}) {
    final hashFile = _resolveHashFile();
    if (hashFile == null) return null;

    final pathPtr = path.toNativeUtf8();
    final outPtr = calloc<Uint8>(33).cast<Utf8>();
    try {
      final ok = hashFile(consoleId, pathPtr, outPtr, 33) != 0;
      if (!ok) return null;
      final hash = outPtr.toDartString();
      return hash.length == 32 ? hash : null;
    } catch (e) {
      debugPrint('RcheevosHashBindings: hash FFI failed for "$path" - $e');
      return null;
    } finally {
      malloc.free(pathPtr);
      calloc.free(outPtr);
    }
  }

  static _YageRcHashFile? _resolveHashFile() {
    if (_hashFile != null) return _hashFile;
    if (_loadAttempted) return null;
    _loadAttempted = true;

    try {
      final libraryPath = switch (true) {
        _ when Platform.isWindows => 'yage_core.dll',
        _ when Platform.isLinux => 'libyage_core.so',
        _ when Platform.isMacOS => 'libyage_core.dylib',
        _ when Platform.isAndroid => 'libyage_core.so',
        _ => throw UnsupportedError('Unsupported platform'),
      };

      final lib = DynamicLibrary.open(libraryPath);
      _hashFile = lib
          .lookup<NativeFunction<_YageRcHashFileNative>>('yage_rc_hash_file')
          .asFunction<_YageRcHashFile>();
      return _hashFile;
    } catch (e) {
      debugPrint('RcheevosHashBindings: unavailable - $e');
      return null;
    }
  }
}
