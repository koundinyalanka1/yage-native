import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'device_memory.dart';

/// A lightweight ZIP extractor using dart:io RandomAccessFile directly.
///
/// The `archive` package's InputFileStream-based decoder silently returns
/// zero entries for large ZIPs (400MB+ PS1 cue/bin archives). This utility
/// bypasses that by performing proper seeks on the underlying file.
///
/// Supports:
/// - Standard ZIP (PKZIP 2.0)
/// - ZIP64 extensions (files > 4GB, archives > 4GB, >65535 entries)
/// - Deflate (method 8) and Stored (method 0) entries
/// - Streaming extraction to disk without loading full entries into memory
class ZipExtractor {
  static const int _eocdSignature = 0x06054b50;
  static const int _zip64LocatorSignature = 0x07064b50;
  static const int _zip64EocdSignature = 0x06064b50;
  static const int _centralDirSignature = 0x02014b50;
  static const int _localFileSignature = 0x04034b50;
  static const int _eocdMinSize = 22;
  static const int _eocdMaxCommentLength = 65535;
  static const int _zip64LocatorSize = 20;

  /// Scratch buffer size for a single (non-pooled) extraction. Larger windows
  /// mean fewer read/write syscalls on big stored tracks.
  static const int _singleBufferSize = 8 * 1024 * 1024; // 8 MB

  /// Scratch buffer size for each worker in the pooled isolate path. Smaller so
  /// peak memory stays bounded when several entries extract concurrently.
  static const int _pooledBufferSize = 4 * 1024 * 1024; // 4 MB

  /// Max concurrent extraction workers (each with its own file handle +
  /// buffer) inside a single extraction isolate. Overlaps disk I/O across that
  /// isolate's entries.
  static const int _maxExtractWorkers = 4;

  /// Max number of parallel extraction isolates. Each runs on its own core, so
  /// CPU-bound inflate is spread across cores for multi-entry archives.
  static const int _maxExtractIsolates = 4;

  /// List all entries in a ZIP file without extracting them.
  ///
  /// Returns metadata for each file entry (name, compressed size, offset, etc.)
  /// Returns an empty list if the ZIP cannot be parsed.
  static Future<List<ZipEntry>> listEntries(String zipPath) async {
    final file = File(zipPath);
    if (!await file.exists()) return const [];

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      final fileLength = await raf.length();
      if (fileLength < _eocdMinSize) return const [];

      // Quick sanity check: read magic bytes to detect non-ZIP formats
      await raf.setPosition(0);
      final magic = await raf.read(8);
      if (magic.length >= 4) {
        final m0 = magic[0], m1 = magic[1], m2 = magic[2], m3 = magic[3];
        if (m0 == 0x37 && m1 == 0x7A && m2 == 0xBC && m3 == 0xAF) {
          debugPrint(
            'ZipExtractor: "$zipPath" is a 7z archive (not ZIP) — '
            'rename to .7z or re-archive as .zip',
          );
          return const [];
        }
        if (m0 == 0x52 && m1 == 0x61 && m2 == 0x72 && m3 == 0x21) {
          debugPrint(
            'ZipExtractor: "$zipPath" is a RAR archive (not ZIP) — '
            'rename to .rar or re-archive as .zip',
          );
          return const [];
        }
        // Valid ZIP starts with local file header (PK\x03\x04) or
        // empty archive (PK\x05\x06)
        final isZipMagic = (m0 == 0x50 && m1 == 0x4B);
        if (!isZipMagic) {
          debugPrint(
            'ZipExtractor: "$zipPath" does not start with ZIP magic '
            '(got 0x${m0.toRadixString(16)}${m1.toRadixString(16)}'
            '${m2.toRadixString(16)}${m3.toRadixString(16)})',
          );
          // Still try to find EOCD — some self-extracting ZIPs have headers
        }
      }

      final eocd = await _findEocd(raf, fileLength);
      if (eocd == null) {
        debugPrint(
          'ZipExtractor: EOCD not found in "$zipPath" '
          '(fileLength=$fileLength)',
        );
        return const [];
      }

      int centralDirOffset = eocd.centralDirOffset;
      int centralDirSize = eocd.centralDirSize;
      int entryCount = eocd.totalEntries;

      // Check for ZIP64
      final zip64 = await _readZip64(raf, eocd.eocdPosition, fileLength);
      if (zip64 != null) {
        centralDirOffset = zip64.centralDirOffset;
        centralDirSize = zip64.centralDirSize;
        entryCount = zip64.totalEntries;
      }

      // Read central directory with retry for partial reads
      await raf.setPosition(centralDirOffset);
      final dirBytes = await _readFully(raf, centralDirSize);
      if (dirBytes.length < centralDirSize) {
        debugPrint(
          'ZipExtractor: central directory truncated '
          '(expected $centralDirSize, got ${dirBytes.length})',
        );
        // Try to parse what we have anyway
      }

      final entries = <ZipEntry>[];
      int offset = 0;
      for (int i = 0; i < entryCount && offset < dirBytes.length - 46; i++) {
        final sig = _readUint32(dirBytes, offset);
        if (sig != _centralDirSignature) break;

        final compressionMethod = _readUint16(dirBytes, offset + 10);
        final crc32 = _readUint32(dirBytes, offset + 16);
        var compressedSize = _readUint32(dirBytes, offset + 20);
        var uncompressedSize = _readUint32(dirBytes, offset + 24);
        final nameLength = _readUint16(dirBytes, offset + 28);
        final extraLength = _readUint16(dirBytes, offset + 30);
        final commentLength = _readUint16(dirBytes, offset + 32);
        var localHeaderOffset = _readUint32(dirBytes, offset + 42);

        final nameStart = offset + 46;
        if (nameStart + nameLength > dirBytes.length) break;
        final name = String.fromCharCodes(
          dirBytes.sublist(nameStart, nameStart + nameLength),
        );

        // Parse ZIP64 extra field if sizes are 0xFFFFFFFF
        final extraStart = nameStart + nameLength;
        if (extraStart + extraLength <= dirBytes.length) {
          _parseZip64Extra(
            dirBytes.sublist(extraStart, extraStart + extraLength),
            compressedSize == 0xFFFFFFFF,
            uncompressedSize == 0xFFFFFFFF,
            localHeaderOffset == 0xFFFFFFFF,
            (newCompressed, newUncompressed, newOffset) {
              if (newCompressed != null) compressedSize = newCompressed;
              if (newUncompressed != null) uncompressedSize = newUncompressed;
              if (newOffset != null) localHeaderOffset = newOffset;
            },
          );
        }

        final isDirectory = name.endsWith('/') || name.endsWith('\\');
        entries.add(ZipEntry(
          name: name,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          compressionMethod: compressionMethod,
          crc32: crc32,
          localHeaderOffset: localHeaderOffset,
          isDirectory: isDirectory,
        ));

        offset = nameStart + nameLength + extraLength + commentLength;
      }

      debugPrint(
        'ZipExtractor: parsed ${entries.length} entries from "$zipPath" '
        '(fileLength=$fileLength, centralDir@$centralDirOffset, '
        'size=$centralDirSize, expectedEntries=$entryCount)',
      );
      return entries;
    } catch (e, st) {
      debugPrint('ZipExtractor: failed to list entries for "$zipPath" — $e\n$st');
      return const [];
    } finally {
      await raf?.close();
    }
  }

  /// Extract a single entry from the ZIP to the given destination path.
  ///
  /// Streams the decompressed data to disk — never loads the full entry into
  /// memory. Safe for multi-hundred-MB .bin tracks.
  static Future<bool> extractEntry(
    String zipPath,
    ZipEntry entry,
    String destPath,
  ) async {
    if (entry.isDirectory) return true;

    RandomAccessFile? raf;
    try {
      raf = await File(zipPath).open(mode: FileMode.read);
      // One-off extraction allocates its own scratch buffer.
      final buffer = Uint8List(_singleBufferSize);
      return await _extractOpenedEntry(raf, entry, destPath, buffer);
    } catch (e, st) {
      debugPrint(
        'ZipExtractor: extraction failed for "${entry.name}" → "$destPath" — $e\n$st',
      );
      return false;
    } finally {
      await raf?.close();
    }
  }

  /// Extract a single entry using an already-open [raf] and a caller-owned
  /// scratch [buffer]. Lets callers (notably the isolate path) reuse one file
  /// handle and one allocation for every entry in the archive instead of
  /// reopening the file and reallocating per entry.
  ///
  /// Writes go through a destination [RandomAccessFile] (not an [IOSink]) so
  /// stored entries can stream straight from [buffer] with zero per-chunk
  /// allocations — a large win for multi-hundred-MB PS1 `.bin` tracks.
  static Future<bool> _extractOpenedEntry(
    RandomAccessFile raf,
    ZipEntry entry,
    String destPath,
    Uint8List buffer,
  ) async {
    if (entry.isDirectory) return true;

    RandomAccessFile? out;
    try {
      await Directory(File(destPath).parent.path).create(recursive: true);

      // Read local file header to find start of data
      await raf.setPosition(entry.localHeaderOffset);
      final localHeader = await raf.read(30);
      if (localHeader.length < 30) return false;

      final sig = _readUint32(localHeader, 0);
      if (sig != _localFileSignature) {
        debugPrint(
          'ZipExtractor: bad local header signature for "${entry.name}" '
          '(got 0x${sig.toRadixString(16)})',
        );
        return false;
      }

      final localNameLen = _readUint16(localHeader, 26);
      final localExtraLen = _readUint16(localHeader, 28);
      final dataOffset =
          entry.localHeaderOffset + 30 + localNameLen + localExtraLen;

      await raf.setPosition(dataOffset);

      out = await File(destPath).open(mode: FileMode.write);

      if (entry.compressionMethod == 0) {
        // Stored — copy raw bytes through the reusable buffer.
        await _copyRawChunked(raf, out, entry.uncompressedSize, buffer);
      } else if (entry.compressionMethod == 8) {
        // Deflate — stream through dart:io's raw inflate.
        await _extractDeflated(raf, out, entry.compressedSize, buffer);
      } else {
        debugPrint(
          'ZipExtractor: unsupported compression method '
          '${entry.compressionMethod} for "${entry.name}"',
        );
        await out.close();
        out = null;
        try {
          final partial = File(destPath);
          if (await partial.exists()) await partial.delete();
        } catch (_) {}
        return false;
      }

      await out.flush();
      await out.close();
      out = null;
      return true;
    } catch (e, st) {
      debugPrint(
        'ZipExtractor: extraction failed for "${entry.name}" → "$destPath" — $e\n$st',
      );
      // Clean up partial file
      try {
        await out?.close();
      } catch (_) {}
      try {
        final partial = File(destPath);
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Extract multiple entries from a ZIP file.
  ///
  /// [extractRoot] is the base directory for extracted files.
  /// [entries] is the list of entries to extract.
  /// [nameMapper] optionally transforms entry names to destination paths.
  /// Returns paths of successfully extracted files.
  static Future<List<String>> extractEntries({
    required String zipPath,
    required String extractRoot,
    required List<ZipEntry> entries,
    String Function(String entryName)? nameMapper,
  }) async {
    final extracted = <String>[];
    for (final entry in entries) {
      if (entry.isDirectory) continue;

      final destName = nameMapper != null
          ? nameMapper(entry.name)
          : _sanitizeEntryName(entry.name);
      if (destName.isEmpty) continue;

      final destPath = '$extractRoot${Platform.pathSeparator}$destName';

      // Skip if already exists
      if (await File(destPath).exists()) {
        extracted.add(destPath);
        continue;
      }

      final success = await extractEntry(zipPath, entry, destPath);
      if (success) {
        extracted.add(destPath);
      }

      // Yield to UI
      await Future.delayed(const Duration(milliseconds: 16));
    }
    return extracted;
  }

  /// Extract multiple entries on background isolate(s).
  ///
  /// This is the fast path used for ROM imports (e.g. large PS1 cue/bin
  /// ZIPs). It avoids the per-entry main-isolate overhead of [extractEntries]
  /// (a 16 ms UI yield per entry, reopening the file handle for every entry,
  /// and decompressing on the UI isolate).
  ///
  /// When an archive holds several entries, the work is **fanned out across
  /// multiple isolates** — balanced by uncompressed size — so the CPU-bound
  /// zlib inflate runs on several cores at once instead of one. A single big
  /// track (one PS1 `.bin`) can't be split, so it runs in one isolate. The
  /// isolate count is bounded by the device's core count and available memory.
  ///
  /// Returns paths of successfully extracted files. Falls back automatically
  /// to the main-isolate [extractEntries] if isolate spawning fails.
  static Future<List<String>> extractEntriesIsolate({
    required String zipPath,
    required String extractRoot,
    required List<ZipEntry> entries,
    String Function(String entryName)? nameMapper,
  }) async {
    // Resolve destination names on this isolate (nameMapper is a closure).
    // Dedup destinations so two parallel isolates can never target the same
    // file (only possible with a malformed archive, but cheap to guard).
    final jobEntries = <ZipEntry>[];
    final destNames = <String>[];
    final seenDest = <String>{};
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      final destName = nameMapper != null
          ? nameMapper(entry.name)
          : _sanitizeEntryName(entry.name);
      if (destName.isEmpty) continue;
      if (!seenDest.add(destName)) continue;
      jobEntries.add(entry);
      destNames.add(destName);
    }
    if (jobEntries.isEmpty) return const [];

    // Decide how many parallel isolates to use. Parallelism only helps with
    // multiple entries, and is bounded by CPU cores and memory.
    final lowMem = (deviceMemoryMB ?? 4096) < 2048;
    final cores = Platform.numberOfProcessors;
    final maxIsolates = lowMem
        ? 1
        : (cores < _maxExtractIsolates ? cores : _maxExtractIsolates);
    var isolateCount = jobEntries.length < maxIsolates
        ? jobEntries.length
        : maxIsolates;
    if (isolateCount < 1) isolateCount = 1;

    try {
      // Single isolate: one job, with an in-isolate I/O pool to overlap reads
      // and writes across this isolate's entries.
      if (isolateCount == 1) {
        return await compute(
          _extractEntriesInBackground,
          _ZipExtractJob(
            zipPath: zipPath,
            extractRoot: extractRoot,
            entries: jobEntries,
            destNames: destNames,
            bufferSize: jobEntries.length <= 1
                ? _singleBufferSize
                : _pooledBufferSize,
            innerConcurrency: lowMem
                ? 1
                : (jobEntries.length < _maxExtractWorkers
                      ? jobEntries.length
                      : _maxExtractWorkers),
          ),
        );
      }

      // Multiple isolates: balance entries by uncompressed size (LPT / greedy
      // least-loaded assignment) so each core does roughly equal work.
      final order = List<int>.generate(jobEntries.length, (i) => i)
        ..sort(
          (a, b) => _entryWeight(
            jobEntries[b],
          ).compareTo(_entryWeight(jobEntries[a])),
        );
      final groupEntries = List.generate(isolateCount, (_) => <ZipEntry>[]);
      final groupNames = List.generate(isolateCount, (_) => <String>[]);
      final groupLoad = List<int>.filled(isolateCount, 0);
      for (final idx in order) {
        var min = 0;
        for (var g = 1; g < isolateCount; g++) {
          if (groupLoad[g] < groupLoad[min]) min = g;
        }
        groupEntries[min].add(jobEntries[idx]);
        groupNames[min].add(destNames[idx]);
        groupLoad[min] += _entryWeight(jobEntries[idx]);
      }

      final futures = <Future<List<String>>>[];
      for (var g = 0; g < isolateCount; g++) {
        if (groupEntries[g].isEmpty) continue;
        futures.add(
          compute(
            _extractEntriesInBackground,
            _ZipExtractJob(
              zipPath: zipPath,
              extractRoot: extractRoot,
              entries: groupEntries[g],
              destNames: groupNames[g],
              bufferSize: _pooledBufferSize,
              // Each isolate already runs on its own core; keep its inner
              // loop sequential so we don't multiply file handles/buffers.
              innerConcurrency: 1,
            ),
          ),
        );
      }
      final results = await Future.wait(futures);
      return [for (final r in results) ...r];
    } catch (e) {
      debugPrint(
        'ZipExtractor: isolate extraction failed ($e) — '
        'falling back to main-isolate path',
      );
      return extractEntries(
        zipPath: zipPath,
        extractRoot: extractRoot,
        entries: entries,
        nameMapper: nameMapper,
      );
    }
  }

  /// Weight used to balance entries across isolates — the uncompressed size
  /// (what gets written + inflated), falling back to compressed size.
  static int _entryWeight(ZipEntry e) {
    if (e.uncompressedSize > 0) return e.uncompressedSize;
    if (e.compressedSize > 0) return e.compressedSize;
    return 1;
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Private helpers
  // ────────────────────────────────────────────────────────────────────────

  /// Sanitize a ZIP entry name for safe filesystem extraction.
  static String _sanitizeEntryName(String name) {
    final cleaned = name.replaceAll('\u0000', '').trim();
    final segments = <String>[];
    for (final raw in cleaned.split(RegExp(r'[\\/]'))) {
      final seg = raw.trim();
      if (seg.isEmpty || seg == '.' || seg == '..') continue;
      // Strip ISO 9660 version suffix (";1")
      final stripped = seg.replaceFirst(RegExp(r';\d+$'), '');
      if (stripped.isNotEmpty) segments.add(stripped);
    }
    return segments.join(Platform.pathSeparator);
  }

  /// Read exactly [count] bytes from [raf], retrying partial reads.
  /// Returns fewer only if true EOF is hit.
  static Future<Uint8List> _readFully(RandomAccessFile raf, int count) async {
    final first = await raf.read(count);
    if (first.length >= count) return first;
    // Partial read — accumulate remaining bytes
    final buffer = BytesBuilder(copy: false);
    buffer.add(first);
    int remaining = count - first.length;
    while (remaining > 0) {
      final chunk = await raf.read(remaining);
      if (chunk.isEmpty) break; // true EOF
      buffer.add(chunk);
      remaining -= chunk.length;
    }
    return buffer.toBytes();
  }

  /// Find the End of Central Directory record by scanning backwards.
  static Future<_EocdRecord?> _findEocd(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    // Fast path: most ZIPs have no comment, so EOCD is in the last ~100 bytes.
    final fastSize = fileLength < 1024 ? fileLength : 1024;
    final fastStart = fileLength - fastSize;
    await raf.setPosition(fastStart);
    final fastBuffer = await _readFully(raf, fastSize);

    final fastResult = _scanForEocd(fastBuffer, fastStart);
    if (fastResult != null) return fastResult;

    // Full search: EOCD comment can be up to 65535 bytes.
    final searchSize =
        (fileLength < _eocdMinSize + _eocdMaxCommentLength)
            ? fileLength
            : _eocdMinSize + _eocdMaxCommentLength;

    if (searchSize <= fastSize) return null; // already searched everything

    final searchStart = fileLength - searchSize;
    await raf.setPosition(searchStart);
    final buffer = await _readFully(raf, searchSize);

    if (buffer.length < _eocdMinSize) {
      debugPrint(
        'ZipExtractor: could only read ${buffer.length}/$searchSize bytes '
        'from end of file (fileLength=$fileLength)',
      );
      return null;
    }

    return _scanForEocd(buffer, searchStart);
  }

  /// Scan a buffer for the EOCD signature, searching from end to start.
  static _EocdRecord? _scanForEocd(List<int> buffer, int bufferFileOffset) {
    for (int i = buffer.length - _eocdMinSize; i >= 0; i--) {
      if (_readUint32(buffer, i) == _eocdSignature) {
        // Verify the record is consistent
        final commentLen = _readUint16(buffer, i + 20);
        if (i + _eocdMinSize + commentLen == buffer.length) {
          return _EocdRecord(
            eocdPosition: bufferFileOffset + i,
            totalEntries: _readUint16(buffer, i + 10),
            centralDirSize: _readUint32(buffer, i + 12),
            centralDirOffset: _readUint32(buffer, i + 16),
          );
        }
        // Fallback: accept the signature even if comment length doesn't
        // perfectly match the remaining buffer (handles trailing bytes or
        // appended data).
        return _EocdRecord(
          eocdPosition: bufferFileOffset + i,
          totalEntries: _readUint16(buffer, i + 10),
          centralDirSize: _readUint32(buffer, i + 12),
          centralDirOffset: _readUint32(buffer, i + 16),
        );
      }
    }
    return null;
  }

  /// Read ZIP64 end-of-central-directory locator + record if present.
  static Future<_Zip64Record?> _readZip64(
    RandomAccessFile raf,
    int eocdPosition,
    int fileLength,
  ) async {
    // ZIP64 EOCD Locator sits immediately before the EOCD record
    final locatorPos = eocdPosition - _zip64LocatorSize;
    if (locatorPos < 0) return null;

    await raf.setPosition(locatorPos);
    final locator = await raf.read(_zip64LocatorSize);
    if (locator.length < _zip64LocatorSize) return null;

    if (_readUint32(locator, 0) != _zip64LocatorSignature) return null;

    final zip64EocdOffset = _readUint64(locator, 8);
    if (zip64EocdOffset >= fileLength) return null;

    // Read ZIP64 EOCD record
    await raf.setPosition(zip64EocdOffset);
    final record = await raf.read(56);
    if (record.length < 56) return null;

    if (_readUint32(record, 0) != _zip64EocdSignature) return null;

    return _Zip64Record(
      totalEntries: _readUint64(record, 32),
      centralDirSize: _readUint64(record, 40),
      centralDirOffset: _readUint64(record, 48),
    );
  }

  /// Parse ZIP64 extended information extra field (ID 0x0001).
  static void _parseZip64Extra(
    List<int> extra,
    bool needCompressed,
    bool needUncompressed,
    bool needOffset,
    void Function(int? compressed, int? uncompressed, int? offset) apply,
  ) {
    int pos = 0;
    while (pos + 4 <= extra.length) {
      final id = _readUint16(extra, pos);
      final size = _readUint16(extra, pos + 2);
      if (id == 0x0001 && pos + 4 + size <= extra.length) {
        int fieldPos = pos + 4;
        int? uncompressed, compressed, offset;
        if (needUncompressed && fieldPos + 8 <= pos + 4 + size) {
          uncompressed = _readUint64(extra, fieldPos);
          fieldPos += 8;
        }
        if (needCompressed && fieldPos + 8 <= pos + 4 + size) {
          compressed = _readUint64(extra, fieldPos);
          fieldPos += 8;
        }
        if (needOffset && fieldPos + 8 <= pos + 4 + size) {
          offset = _readUint64(extra, fieldPos);
        }
        apply(compressed, uncompressed, offset);
        return;
      }
      pos += 4 + size;
    }
  }

  /// Copy raw (stored) bytes from [raf] to [out], reusing [buffer] for every
  /// chunk. [out.writeFrom] copies synchronously, so the same buffer is safe to
  /// refill on the next iteration — no per-chunk allocation, no GC churn.
  static Future<void> _copyRawChunked(
    RandomAccessFile raf,
    RandomAccessFile out,
    int totalBytes,
    Uint8List buffer,
  ) async {
    int remaining = totalBytes;
    while (remaining > 0) {
      final toRead = remaining < buffer.length ? remaining : buffer.length;
      final n = await raf.readInto(buffer, 0, toRead);
      if (n <= 0) break;
      await out.writeFrom(buffer, 0, n);
      remaining -= n;
    }
  }

  /// Extract a Deflate-compressed entry using streaming raw inflate, writing
  /// straight to [out].
  ///
  /// Reads compressed data in chunks and pipes through [RawZLibFilter] to avoid
  /// holding the entire compressed+decompressed content in memory. The
  /// compressed input is read into a fresh list per chunk (the inflate filter
  /// may retain it past the await), while inflated output — freshly allocated
  /// by zlib — is written out immediately.
  static Future<void> _extractDeflated(
    RandomAccessFile raf,
    RandomAccessFile out,
    int compressedSize,
    Uint8List buffer,
  ) async {
    // For entries that fit the scratch buffer, use the simple all-at-once path.
    if (compressedSize <= buffer.length) {
      final n = await raf.readInto(buffer, 0, compressedSize);
      final inflated = ZLibDecoder(raw: true).convert(
        Uint8List.sublistView(buffer, 0, n),
      );
      await out.writeFrom(inflated);
      return;
    }

    // Large entries: read in chunks, feed through streaming RawZLibFilter.
    final filter = RawZLibFilter.inflateFilter(raw: true);
    final chunkSize = buffer.length; // compressed read window
    int remaining = compressedSize;

    while (remaining > 0) {
      final toRead = remaining < chunkSize ? remaining : chunkSize;
      final chunk = await raf.read(toRead);
      if (chunk.isEmpty) break;
      remaining -= chunk.length;

      // Feed chunk to the inflate filter
      filter.process(chunk, 0, chunk.length);

      // Drain all output produced by this input chunk
      List<int>? output;
      while ((output = filter.processed(flush: false)) != null) {
        await out.writeFrom(_asBytes(output!));
      }
    }

    // Finalize: flush remaining output
    List<int>? output;
    while ((output = filter.processed(end: true)) != null) {
      await out.writeFrom(_asBytes(output!));
    }
  }

  /// Coerce a filter's output to [Uint8List] for [RandomAccessFile.writeFrom]
  /// without copying when it already is one.
  static Uint8List _asBytes(List<int> data) =>
      data is Uint8List ? data : Uint8List.fromList(data);

  // ────────────────────────────────────────────────────────────────────────
  //  Binary readers (little-endian)
  // ────────────────────────────────────────────────────────────────────────

  static int _readUint16(List<int> data, int offset) {
    return data[offset] | (data[offset + 1] << 8);
  }

  static int _readUint32(List<int> data, int offset) {
    return (data[offset] |
            (data[offset + 1] << 8) |
            (data[offset + 2] << 16) |
            (data[offset + 3] << 24)) &
        0xFFFFFFFF;
  }

  static int _readUint64(List<int> data, int offset) {
    final lo = _readUint32(data, offset);
    final hi = _readUint32(data, offset + 4);
    return (hi << 32) | (lo & 0xFFFFFFFF);
  }
}

// ──────────────────────────────────────────────────────────────────────────
//  Data classes
// ──────────────────────────────────────────────────────────────────────────

/// Metadata for a single file inside a ZIP archive.
class ZipEntry {
  final String name;
  final int compressedSize;
  final int uncompressedSize;
  final int compressionMethod;
  final int crc32;
  final int localHeaderOffset;
  final bool isDirectory;

  const ZipEntry({
    required this.name,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.compressionMethod,
    required this.crc32,
    required this.localHeaderOffset,
    required this.isDirectory,
  });

  /// Get the filename leaf (last segment after any path separators).
  String get leafName {
    final parts = name.split(RegExp(r'[\\/]'));
    for (int i = parts.length - 1; i >= 0; i--) {
      if (parts[i].trim().isNotEmpty) return parts[i].trim();
    }
    return name.trim();
  }

  /// Get the file extension (lowercase, with dot).
  String get extension {
    final leaf = leafName.toLowerCase();
    final stripped = leaf.replaceFirst(RegExp(r';\d+$'), '');
    final dotIndex = stripped.lastIndexOf('.');
    if (dotIndex < 0) return '';
    return stripped.substring(dotIndex);
  }

  @override
  String toString() =>
      'ZipEntry(name=$name, compressed=$compressedSize, '
      'uncompressed=$uncompressedSize, method=$compressionMethod)';
}

class _EocdRecord {
  final int eocdPosition;
  final int totalEntries;
  final int centralDirSize;
  final int centralDirOffset;

  const _EocdRecord({
    required this.eocdPosition,
    required this.totalEntries,
    required this.centralDirSize,
    required this.centralDirOffset,
  });
}

class _Zip64Record {
  final int totalEntries;
  final int centralDirSize;
  final int centralDirOffset;

  const _Zip64Record({
    required this.totalEntries,
    required this.centralDirSize,
    required this.centralDirOffset,
  });
}

// ──────────────────────────────────────────────────────────────────────────
//  Isolate-based extraction
// ──────────────────────────────────────────────────────────────────────────

/// Parameters for [_extractEntriesInBackground]. All fields are plain data so
/// the job can cross the isolate boundary via [compute].
class _ZipExtractJob {
  final String zipPath;
  final String extractRoot;
  final List<ZipEntry> entries;

  /// Destination names parallel to [entries], pre-resolved on the caller
  /// isolate (relative to [extractRoot]).
  final List<String> destNames;

  /// Scratch buffer size each in-isolate worker allocates.
  final int bufferSize;

  /// How many in-isolate workers overlap I/O for this job's entries.
  final int innerConcurrency;

  const _ZipExtractJob({
    required this.zipPath,
    required this.extractRoot,
    required this.entries,
    required this.destNames,
    required this.bufferSize,
    required this.innerConcurrency,
  });
}

/// Top-level entry point executed inside a background isolate via [compute].
///
/// Decompresses on the worker isolate so the UI isolate stays free. Within the
/// isolate, entries are extracted through up to [_ZipExtractJob.innerConcurrency]
/// workers — each with its own file handle and scratch buffer — so disk I/O
/// overlaps. The caller ([ZipExtractor.extractEntriesIsolate]) may also run
/// several of these isolates in parallel to spread inflate across CPU cores.
/// All memory is released when the isolate exits.
Future<List<String>> _extractEntriesInBackground(_ZipExtractJob job) async {
  // Build the concrete (entry, destination) work items up front.
  final tasks = <_EntryTask>[];
  for (var i = 0; i < job.entries.length; i++) {
    final entry = job.entries[i];
    if (entry.isDirectory) continue;
    tasks.add(
      _EntryTask(
        entry,
        '${job.extractRoot}${Platform.pathSeparator}${job.destNames[i]}',
      ),
    );
  }
  if (tasks.isEmpty) return const [];

  final extracted = <String>[];
  var workerCount = job.innerConcurrency;
  if (workerCount > tasks.length) workerCount = tasks.length;
  if (workerCount < 1) workerCount = 1;
  final bufferSize = job.bufferSize;

  var next = 0; // shared cursor; increments are atomic between awaits

  Future<void> runWorker() async {
    final buffer = Uint8List(bufferSize);
    RandomAccessFile? raf;
    try {
      raf = await File(job.zipPath).open(mode: FileMode.read);
      while (true) {
        final i = next++;
        if (i >= tasks.length) break;
        final task = tasks[i];

        // Skip if already on disk (idempotent re-import).
        if (await File(task.destPath).exists()) {
          extracted.add(task.destPath);
          continue;
        }

        final ok = await ZipExtractor._extractOpenedEntry(
          raf,
          task.entry,
          task.destPath,
          buffer,
        );
        if (ok) extracted.add(task.destPath);
      }
    } catch (e) {
      // Return whatever extracted so far; caller treats empty as failure.
      debugPrint('ZipExtractor(isolate): worker error — $e');
    } finally {
      await raf?.close();
    }
  }

  await Future.wait([for (var w = 0; w < workerCount; w++) runWorker()]);
  return extracted;
}

/// A single (entry → destination path) extraction work item.
class _EntryTask {
  final ZipEntry entry;
  final String destPath;
  const _EntryTask(this.entry, this.destPath);
}
