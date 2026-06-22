import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'lzma_decoder.dart';

/// Pure Dart 7z archive extractor.
///
/// Implements enough of the 7z format spec to handle typical PS1 ROM archives
/// (cue/bin files compressed with LZMA). Built from scratch using dart:io.
///
/// Supports:
/// - LZMA compression (method 0x030101)
/// - LZMA2 compression (method 0x21)
/// - Copy/Store (method 0x00)
/// - Solid and non-solid archives
/// - Multiple files in a single folder
class SevenZipExtractor {
  static const _signature = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];

  // Property IDs in 7z header
  static const _kEnd = 0x00;
  static const _kHeader = 0x01;
  static const _kArchiveProperties = 0x02;
  static const _kMainStreamsInfo = 0x04;
  static const _kFilesInfo = 0x05;
  static const _kPackInfo = 0x06;
  static const _kUnpackInfo = 0x07;
  static const _kSubStreamsInfo = 0x08;
  static const _kSize = 0x09;
  static const _kCRC = 0x0A;
  static const _kFolder = 0x0B;
  static const _kCodersUnpackSize = 0x0C;
  static const _kNumUnpackStream = 0x0D;
  static const _kEmptyStream = 0x0E;
  static const _kEmptyFile = 0x0F;
  static const _kAnti = 0x10;
  static const _kName = 0x11;
  static const _kCTime = 0x12;
  static const _kATime = 0x13;
  static const _kMTime = 0x14;
  static const _kAttributes = 0x15;
  static const _kEncodedHeader = 0x17;

  /// Check if a file is a 7z archive by reading its magic bytes.
  static Future<bool> is7zFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final raf = await file.open(mode: FileMode.read);
    try {
      final magic = await raf.read(6);
      if (magic.length < 6) return false;
      for (int i = 0; i < 6; i++) {
        if (magic[i] != _signature[i]) return false;
      }
      return true;
    } finally {
      await raf.close();
    }
  }

  /// List all file entries in a 7z archive.
  static Future<List<SevenZipEntry>> listEntries(String archivePath) async {
    final file = File(archivePath);
    if (!await file.exists()) return const [];

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);

      // Read and verify signature header (32 bytes)
      final sigHeader = await _readFully(raf, 32);
      if (sigHeader.length < 32) {
        debugPrint('SevenZipExtractor: file too short for 7z header');
        return const [];
      }

      // Verify magic
      for (int i = 0; i < 6; i++) {
        if (sigHeader[i] != _signature[i]) {
          debugPrint('SevenZipExtractor: invalid 7z signature');
          return const [];
        }
      }

      // Parse start header
      // Bytes 6-7: version (major, minor)
      // Bytes 8-11: start header CRC
      // Bytes 12-19: next header offset (from end of start header = byte 32)
      // Bytes 20-27: next header size
      // Bytes 28-31: next header CRC
      final nextHeaderOffset = _readUint64LE(sigHeader, 12);
      final nextHeaderSize = _readUint64LE(sigHeader, 20);

      if (nextHeaderSize == 0 || nextHeaderSize > 100 * 1024 * 1024) {
        debugPrint(
          'SevenZipExtractor: invalid next header size ($nextHeaderSize)',
        );
        return const [];
      }

      // Read the header
      final headerPos = 32 + nextHeaderOffset;
      await raf.setPosition(headerPos);
      final headerBytes = await _readFully(raf, nextHeaderSize);
      if (headerBytes.length < nextHeaderSize) {
        debugPrint('SevenZipExtractor: truncated header');
        return const [];
      }

      // Parse the header
      final reader = _ByteReader(headerBytes);
      final archive = _ArchiveInfo();

      final headerId = reader.readByte();
      if (headerId == _kEncodedHeader) {
        // Header is itself compressed — decompress it first
        final decodedHeader = await _decodeEncodedHeader(
          raf,
          reader,
          archive,
        );
        if (decodedHeader == null) {
          debugPrint('SevenZipExtractor: failed to decode encoded header');
          return const [];
        }
        final headerReader = _ByteReader(decodedHeader);
        final hId = headerReader.readByte();
        if (hId != _kHeader) {
          debugPrint('SevenZipExtractor: expected Header ID, got 0x${hId.toRadixString(16)}');
          return const [];
        }
        _parseHeader(headerReader, archive);
      } else if (headerId == _kHeader) {
        _parseHeader(reader, archive);
      } else {
        debugPrint(
          'SevenZipExtractor: unknown header ID 0x${headerId.toRadixString(16)}',
        );
        return const [];
      }

      debugPrint(
        'SevenZipExtractor: parsed ${archive.files.length} entries '
        'from "$archivePath" (${archive.folders.length} folders)',
      );
      return archive.files;
    } catch (e, st) {
      debugPrint('SevenZipExtractor: failed to list entries — $e\n$st');
      return const [];
    } finally {
      await raf?.close();
    }
  }

  /// Extract all files from a 7z archive to [extractRoot].
  ///
  /// Returns the list of paths for successfully extracted files.
  static Future<List<String>> extractAll({
    required String archivePath,
    required String extractRoot,
    Set<String>? extensionFilter,
  }) async {
    final file = File(archivePath);
    if (!await file.exists()) return const [];

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);

      // Parse headers
      final sigHeader = await _readFully(raf, 32);
      if (sigHeader.length < 32) return const [];
      for (int i = 0; i < 6; i++) {
        if (sigHeader[i] != _signature[i]) return const [];
      }

      final nextHeaderOffset = _readUint64LE(sigHeader, 12);
      final nextHeaderSize = _readUint64LE(sigHeader, 20);
      if (nextHeaderSize == 0 || nextHeaderSize > 100 * 1024 * 1024) {
        return const [];
      }

      await raf.setPosition(32 + nextHeaderOffset);
      final headerBytes = await _readFully(raf, nextHeaderSize);
      if (headerBytes.length < nextHeaderSize) return const [];

      final reader = _ByteReader(headerBytes);
      final archive = _ArchiveInfo();

      final headerId = reader.readByte();
      debugPrint('SevenZipExtractor(extract): header ID=0x${headerId.toRadixString(16)}');
      if (headerId == _kEncodedHeader) {
        final decodedHeader = await _decodeEncodedHeader(raf, reader, archive);
        if (decodedHeader == null) {
          debugPrint('SevenZipExtractor(extract): encoded header decode FAILED');
          return const [];
        }
        debugPrint('SevenZipExtractor(extract): decoded header ${decodedHeader.length} bytes');
        final headerReader = _ByteReader(decodedHeader);
        final hId = headerReader.readByte();
        if (hId != _kHeader) {
          debugPrint('SevenZipExtractor(extract): inner header ID=0x${hId.toRadixString(16)} (expected 0x01)');
          return const [];
        }
        _parseHeader(headerReader, archive);
      } else if (headerId == _kHeader) {
        _parseHeader(reader, archive);
      } else {
        return const [];
      }

      // Now extract files
      final extracted = <String>[];
      final packStart = 32 + (archive.packPos ?? 0);

      debugPrint(
        'SevenZipExtractor: archive has ${archive.files.length} files, '
        '${archive.folders.length} folders, '
        'packPos=${archive.packPos}, '
        'packSizes=${archive.packSizes}',
      );
      if (archive.files.isNotEmpty) {
        final sampleFiles = archive.files.take(5).map((f) =>
            '${f.name}(${f.size}b,dir=${f.isDirectory})').join(', ');
        debugPrint('SevenZipExtractor: sample files: $sampleFiles');
      }

      // Create directories first (they're empty streams, not in folders)
      for (final entry in archive.files) {
        if (entry.isDirectory) {
          final dirPath = '$extractRoot${Platform.pathSeparator}'
              '${_sanitizeName(entry.name)}';
          await Directory(dirPath).create(recursive: true);
        }
      }

      // Process each folder (a folder in 7z = a compression unit)
      // In 7z format, empty streams (directories, 0-byte files) do NOT belong
      // to any folder — only non-empty files are assigned to folders.
      final nonEmptyFiles = archive.files
          .where((f) => !f.isDirectory && f.size > 0)
          .toList();
      int fileIndex = 0;
      int packOffset = packStart;

      for (int fi = 0; fi < archive.folders.length; fi++) {
        final folder = archive.folders[fi];
        final numFiles = folder.numUnpackStreams > 0
            ? folder.numUnpackStreams
            : 1;

        debugPrint(
          'SevenZipExtractor: folder[$fi] numFiles=$numFiles, '
          'packSizes=${folder.packSizes}, '
          'unpackSizes=${folder.unpackSizes}, '
          'coders=${folder.coderIds.map((c) => c.map((b) => b.toRadixString(16).padLeft(2, "0")).join()).toList()}',
        );

        // Determine which files belong to this folder
        final folderFiles = <SevenZipEntry>[];
        for (int i = 0; i < numFiles && fileIndex < nonEmptyFiles.length; i++) {
          folderFiles.add(nonEmptyFiles[fileIndex]);
          fileIndex++;
        }

        // Check if any file in this folder passes the extension filter
        final hasRelevantFile = extensionFilter == null ||
            folderFiles.any((f) {
              if (f.isDirectory) return false;
              final ext = _fileExtension(f.name);
              return extensionFilter.contains(ext);
            });

        int totalPackSize = 0;
        for (final size in folder.packSizes) {
          totalPackSize += size;
        }

        if (!hasRelevantFile) {
          debugPrint(
            'SevenZipExtractor: folder[$fi] skipped — no relevant extensions '
            '(files: ${folderFiles.map((f) => "${f.name}[${_fileExtension(f.name)}]").join(", ")})',
          );
          packOffset += totalPackSize;
          continue;
        }

        debugPrint(
          'SevenZipExtractor: folder[$fi] extracting $totalPackSize packed bytes at offset $packOffset via isolate',
        );

        // Run heavy I/O + decompression + file writes in a background isolate.
        // This prevents UI jank and ensures memory is released after each
        // folder (isolate heap is freed on exit).
        final result = await compute(
          _extractFolderInBackground,
          _FolderExtractParams(
            archivePath: archivePath,
            extractRoot: extractRoot,
            packOffset: packOffset,
            totalPackSize: totalPackSize,
            coderIds: folder.coderIds,
            coderProps: folder.coderProps,
            unpackSizes: folder.unpackSizes,
            files: folderFiles
                .map((f) => _FileExtractInfo(
                      name: f.name,
                      size: f.size,
                      isDirectory: f.isDirectory,
                    ))
                .toList(),
            extensionFilter: extensionFilter?.toList(),
          ),
        );
        extracted.addAll(result);
        packOffset += totalPackSize;
      }

      debugPrint(
        'SevenZipExtractor: extracted ${extracted.length} files '
        'from "$archivePath"',
      );
      return extracted;
    } catch (e, st) {
      debugPrint('SevenZipExtractor: extraction failed — $e\n$st');
      return const [];
    } finally {
      await raf?.close();
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Header parsing
  // ──────────────────────────────────────────────────────────────────────

  static void _parseHeader(_ByteReader reader, _ArchiveInfo archive) {
    debugPrint('SevenZipExtractor: _parseHeader at pos=${reader.position}, remaining=${reader._data.length - reader.position}');
    while (true) {
      final id = reader.readByte();
      debugPrint('SevenZipExtractor: _parseHeader id=0x${id.toRadixString(16)} at pos=${reader.position}');
      if (id == _kEnd) break;

      switch (id) {
        case _kMainStreamsInfo:
          _parseMainStreamsInfo(reader, archive);
          break;
        case _kFilesInfo:
          _parseFilesInfo(reader, archive);
          break;
        case _kArchiveProperties:
          _skipArchiveProperties(reader);
          break;
        default:
          // Skip unknown property
          final size = reader.readNumber();
          debugPrint('SevenZipExtractor: _parseHeader skipping unknown id=0x${id.toRadixString(16)}, size=$size');
          reader.skip(size);
      }
    }
  }

  static void _parseMainStreamsInfo(_ByteReader reader, _ArchiveInfo archive) {
    debugPrint('SevenZipExtractor: _parseMainStreamsInfo start at pos=${reader.position}');
    while (true) {
      final id = reader.readByte();
      debugPrint('SevenZipExtractor: _parseMainStreamsInfo id=0x${id.toRadixString(16)} at pos=${reader.position}');
      if (id == _kEnd) break;

      switch (id) {
        case _kPackInfo:
          _parsePackInfo(reader, archive);
          debugPrint('SevenZipExtractor: after _parsePackInfo pos=${reader.position}');
          break;
        case _kUnpackInfo:
          _parseUnpackInfo(reader, archive);
          debugPrint('SevenZipExtractor: after _parseUnpackInfo pos=${reader.position}');
          break;
        case _kSubStreamsInfo:
          _parseSubStreamsInfo(reader, archive);
          debugPrint('SevenZipExtractor: after _parseSubStreamsInfo pos=${reader.position}');
          break;
        default:
          final size = reader.readNumber();
          reader.skip(size);
      }
    }
  }

  static void _parsePackInfo(_ByteReader reader, _ArchiveInfo archive) {
    archive.packPos = reader.readNumber();
    final numPackStreams = reader.readNumber();
    archive.packSizes = <int>[];

    while (true) {
      final id = reader.readByte();
      if (id == _kEnd) break;
      if (id == _kSize) {
        for (int i = 0; i < numPackStreams; i++) {
          archive.packSizes!.add(reader.readNumber());
        }
      } else if (id == _kCRC) {
        // Skip CRCs
        _skipCrcInfo(reader, numPackStreams);
      } else {
        final size = reader.readNumber();
        reader.skip(size);
      }
    }

    // If no sizes read, fill with zeros
    if (archive.packSizes!.length < numPackStreams) {
      while (archive.packSizes!.length < numPackStreams) {
        archive.packSizes!.add(0);
      }
    }
  }

  static void _parseUnpackInfo(_ByteReader reader, _ArchiveInfo archive) {
    while (true) {
      final id = reader.readByte();
      if (id == _kEnd) break;

      if (id == _kFolder) {
        final numFolders = reader.readNumber();
        final external = reader.readByte();
        if (external != 0) {
          // External data stream — skip for now
          reader.readNumber();
          continue;
        }
        for (int i = 0; i < numFolders; i++) {
          archive.folders.add(_parseFolder(reader));
        }
      } else if (id == _kCodersUnpackSize) {
        for (final folder in archive.folders) {
          for (int i = 0; i < folder.numCoders; i++) {
            folder.unpackSizes.add(reader.readNumber());
          }
        }
      } else if (id == _kCRC) {
        // Parse folder CRCs — mark folders that have CRCs defined
        final numFolders = archive.folders.length;
        final allDefined = reader.readByte();
        final defined = List<bool>.filled(numFolders, true);
        if (allDefined == 0) {
          _readBitVector(reader, numFolders, defined);
        }
        for (int i = 0; i < numFolders; i++) {
          if (defined[i]) {
            reader.skip(4); // skip CRC value
            archive.folders[i].hasCrc = true;
          }
        }
      } else {
        final size = reader.readNumber();
        reader.skip(size);
      }
    }

    // Assign pack sizes to folders
    int packIdx = 0;
    for (final folder in archive.folders) {
      for (int i = 0; i < folder.numPackStreams; i++) {
        if (archive.packSizes != null && packIdx < archive.packSizes!.length) {
          folder.packSizes.add(archive.packSizes![packIdx]);
        }
        packIdx++;
      }
    }
  }

  static _FolderInfo _parseFolder(_ByteReader reader) {
    final folder = _FolderInfo();
    final numCoders = reader.readNumber();
    folder.numCoders = numCoders;

    for (int i = 0; i < numCoders; i++) {
      final mainByte = reader.readByte();
      final idSize = mainByte & 0x0F;
      final isComplex = (mainByte & 0x10) != 0;
      final hasAttributes = (mainByte & 0x20) != 0;

      final codecId = reader.readBytes(idSize);
      folder.coderIds.add(codecId);

      if (isComplex) {
        folder.numInStreams = reader.readNumber();
        folder.numOutStreams = reader.readNumber();
      } else {
        folder.numInStreams = 1;
        folder.numOutStreams = 1;
      }
      folder.numPackStreams = folder.numInStreams;

      if (hasAttributes) {
        final propSize = reader.readNumber();
        folder.coderProps.add(reader.readBytes(propSize));
      } else {
        folder.coderProps.add(Uint8List(0));
      }
    }

    // BindPairs (for complex coders with multiple streams)
    if (numCoders > 1) {
      final numBindPairs = folder.numOutStreams - 1;
      for (int i = 0; i < numBindPairs; i++) {
        reader.readNumber(); // inIndex
        reader.readNumber(); // outIndex
      }
      // PackedStreams
      final numPackedStreams = folder.numInStreams - numBindPairs;
      if (numPackedStreams > 1) {
        for (int i = 0; i < numPackedStreams; i++) {
          reader.readNumber(); // packed stream index
        }
      }
      folder.numPackStreams = numPackedStreams;
    }

    return folder;
  }

  static void _parseSubStreamsInfo(
    _ByteReader reader,
    _ArchiveInfo archive,
  ) {
    debugPrint('SevenZipExtractor: _parseSubStreamsInfo start at pos=${reader.position}');
    while (true) {
      final id = reader.readByte();
      debugPrint('SevenZipExtractor: _parseSubStreamsInfo id=0x${id.toRadixString(16)} at pos=${reader.position}');
      if (id == _kEnd) break;

      if (id == _kNumUnpackStream) {
        for (final folder in archive.folders) {
          folder.numUnpackStreams = reader.readNumber();
          debugPrint('SevenZipExtractor: folder numUnpackStreams=${folder.numUnpackStreams}');
        }
      } else if (id == _kSize) {
        debugPrint('SevenZipExtractor: _parseSubStreamsInfo reading sizes, pos=${reader.position}');
        for (final folder in archive.folders) {
          if (folder.numUnpackStreams <= 1) continue;
          int sum = 0;
          for (int i = 0; i < folder.numUnpackStreams - 1; i++) {
            final size = reader.readNumber();
            folder.subStreamSizes.add(size);
            sum += size;
          }
          // Last stream size = total unpack size - sum of others
          final totalUnpack = folder.unpackSizes.isNotEmpty
              ? folder.unpackSizes.last
              : 0;
          folder.subStreamSizes.add(totalUnpack - sum);
        }
        debugPrint('SevenZipExtractor: _parseSubStreamsInfo after sizes, pos=${reader.position}');
      } else if (id == _kCRC) {
        // CRC covers: all sub-streams in multi-stream folders,
        // plus single-stream folders without CRC from UnpackInfo
        int numDigests = 0;
        for (final folder in archive.folders) {
          if (folder.numUnpackStreams == 1) {
            if (!folder.hasCrc) numDigests++;
          } else {
            numDigests += folder.numUnpackStreams;
          }
        }
        debugPrint('SevenZipExtractor: _parseSubStreamsInfo CRC numDigests=$numDigests, pos=${reader.position}');
        _skipCrcInfo(reader, numDigests);
        debugPrint('SevenZipExtractor: _parseSubStreamsInfo after CRC, pos=${reader.position}');
      } else {
        final size = reader.readNumber();
        debugPrint('SevenZipExtractor: _parseSubStreamsInfo unknown id=0x${id.toRadixString(16)}, size=$size, skipping');
        reader.skip(size);
      }
    }
  }

  static void _parseFilesInfo(_ByteReader reader, _ArchiveInfo archive) {
    final numFiles = reader.readNumber();

    // Pre-create file entries
    for (int i = 0; i < numFiles; i++) {
      archive.files.add(SevenZipEntry(name: '', size: 0, isDirectory: false));
    }

    // Track which files are empty streams (directories or 0-byte files)
    final isEmptyStream = List<bool>.filled(numFiles, false);
    final isEmptyFile = List<bool>.filled(numFiles, false);

    while (true) {
      final id = reader.readByte();
      if (id == _kEnd) break;

      final size = reader.readNumber();
      final endPos = reader.position + size;

      switch (id) {
        case _kEmptyStream:
          _readBitVector(reader, numFiles, isEmptyStream);
          break;
        case _kEmptyFile:
          int numEmpty = isEmptyStream.where((e) => e).length;
          _readBitVector(reader, numEmpty, isEmptyFile);
          break;
        case _kName:
          final external = reader.readByte();
          if (external != 0) {
            reader.skip(endPos - reader.position);
            break;
          }
          // Names are UTF-16LE, null-terminated
          for (int i = 0; i < numFiles; i++) {
            final name = _readUtf16Name(reader);
            archive.files[i] = archive.files[i].copyWith(name: name);
          }
          break;
        case _kMTime:
        case _kCTime:
        case _kATime:
        case _kAttributes:
        case _kAnti:
          reader.skip(endPos - reader.position);
          break;
        default:
          reader.skip(endPos - reader.position);
      }

      // Ensure we're at the expected position
      if (reader.position < endPos) {
        reader.skip(endPos - reader.position);
      }
    }

    // Mark directories
    for (int i = 0; i < numFiles; i++) {
      if (isEmptyStream[i]) {
        archive.files[i] = archive.files[i].copyWith(
          isDirectory: !isEmptyFile[i],
        );
      }
    }

    // Assign sizes from folder/substream info
    int fileIdx = 0;
    for (final folder in archive.folders) {
      if (folder.numUnpackStreams <= 1) {
        // Single file in folder — use folder's total unpack size
        while (fileIdx < numFiles && isEmptyStream[fileIdx]) {
          fileIdx++;
        }
        if (fileIdx < numFiles) {
          final size = folder.unpackSizes.isNotEmpty
              ? folder.unpackSizes.last
              : 0;
          archive.files[fileIdx] = archive.files[fileIdx].copyWith(size: size);
          fileIdx++;
        }
      } else {
        // Multiple files in folder — use subStreamSizes
        int subIdx = 0;
        for (int i = 0; i < folder.numUnpackStreams; i++) {
          while (fileIdx < numFiles && isEmptyStream[fileIdx]) {
            fileIdx++;
          }
          if (fileIdx < numFiles && subIdx < folder.subStreamSizes.length) {
            archive.files[fileIdx] = archive.files[fileIdx].copyWith(
              size: folder.subStreamSizes[subIdx],
            );
            fileIdx++;
            subIdx++;
          }
        }
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Decompression
  // ──────────────────────────────────────────────────────────────────────

  static Future<Uint8List?> _decodeEncodedHeader(
    RandomAccessFile raf,
    _ByteReader reader,
    _ArchiveInfo _ /* unused — we use a local temp */,
  ) async {
    // Use a LOCAL archive info so we don't pollute the caller's state.
    final temp = _ArchiveInfo();
    _parseMainStreamsInfo(reader, temp);

    if (temp.folders.isEmpty) {
      debugPrint('SevenZipExtractor: encoded header has no folders');
      return null;
    }
    final folder = temp.folders[0];

    // The pack data for the encoded header lives at byte (32 + packPos).
    final packStart = 32 + (temp.packPos ?? 0);
    await raf.setPosition(packStart);

    // Use archive-level packSizes (folder.packSizes is already a copy of them).
    int totalPackSize = 0;
    if (temp.packSizes != null && temp.packSizes!.isNotEmpty) {
      for (final s in temp.packSizes!) {
        totalPackSize += s;
      }
    } else {
      for (final s in folder.packSizes) {
        totalPackSize += s;
      }
    }

    if (totalPackSize <= 0) {
      debugPrint('SevenZipExtractor: encoded header packSize=0');
      return null;
    }

    debugPrint(
      'SevenZipExtractor: encoded header packStart=$packStart, '
      'totalPackSize=$totalPackSize, unpackSizes=${folder.unpackSizes}',
    );

    final packedData = await _readFully(raf, totalPackSize);
    final result = _decompressFolder(folder, Uint8List.fromList(packedData));
    debugPrint(
      'SevenZipExtractor: encoded header decompressed to '
      '${result?.length ?? 0} bytes (expected ${folder.unpackSizes.isNotEmpty ? folder.unpackSizes.last : "?"})',
    );
    return result;
  }

  static Uint8List? _decompressFolder(
    _FolderInfo folder,
    Uint8List packedData,
  ) {
    if (folder.coderIds.isEmpty) return packedData;

    Uint8List currentData = packedData;

    // Apply decoders in order (for multi-coder, apply sequentially)
    for (int i = 0; i < folder.coderIds.length; i++) {
      final codecId = folder.coderIds[i];
      final props = i < folder.coderProps.length
          ? folder.coderProps[i]
          : Uint8List(0);

      final unpackSize = i < folder.unpackSizes.length
          ? folder.unpackSizes[i]
          : -1;

      currentData = _decompressStream(codecId, props, currentData, unpackSize);
    }

    return currentData;
  }

  static Uint8List _decompressStream(
    Uint8List codecId,
    Uint8List props,
    Uint8List data,
    int unpackSize,
  ) {
    final methodId = _codecIdToInt(codecId);

    switch (methodId) {
      case 0x00: // Copy
        return data;

      case 0x030101: // LZMA
        return _decompressLzma(props, data, unpackSize);

      case 0x21: // LZMA2
        return _decompressLzma2(props, data, unpackSize);

      case 0x03030103: // BCJ (x86)
        return _filterBcjX86(data);

      case 0x0304: // BCJ2
        // BCJ2 is complex — for now just return data
        debugPrint('SevenZipExtractor: BCJ2 filter not supported, skipping');
        return data;

      default:
        debugPrint(
          'SevenZipExtractor: unsupported codec 0x${methodId.toRadixString(16)}',
        );
        return data;
    }
  }

  static Uint8List _decompressLzma(
    Uint8List props,
    Uint8List data,
    int unpackSize,
  ) {
    if (props.isEmpty) {
      throw LzmaException('LZMA coder has no properties');
    }

    // Props: [propsByte] [dictSize 4 bytes LE]
    final propsByte = props[0];
    final lc = propsByte % 9;
    final remainder = propsByte ~/ 9;
    final lp = remainder % 5;
    final pb = remainder ~/ 5;

    int dictSize = 0;
    if (props.length >= 5) {
      dictSize = props[1] |
          (props[2] << 8) |
          (props[3] << 16) |
          (props[4] << 24);
    }
    if (dictSize < 4096) dictSize = 4096;

    return LzmaDecoder.decodeRaw(
      input: data,
      uncompressedSize: unpackSize,
      lc: lc,
      lp: lp,
      pb: pb,
      dictionarySize: dictSize,
    );
  }

  static Uint8List _decompressLzma2(
    Uint8List props,
    Uint8List data,
    int unpackSize,
  ) {
    // LZMA2 props: single byte = dictionary size power
    int dictSizeProp = props.isNotEmpty ? props[0] : 24;
    int dictSize;
    if (dictSizeProp > 40) {
      dictSize = 0xFFFFFFFF;
    } else if (dictSizeProp == 40) {
      dictSize = 0xFFFFFFFF;
    } else {
      dictSize = (2 | (dictSizeProp & 1)) << (dictSizeProp ~/ 2 + 11);
    }

    // LZMA2 is a sequence of chunks
    final output = BytesBuilder(copy: false);
    int pos = 0;
    int lc = 3, lp = 0, pb = 2;
    // ignore: unused_local_variable
    bool needReset = true;

    while (pos < data.length) {
      final control = data[pos++];
      if (control == 0) break; // End marker

      if (control == 1 || control == 2) {
        // Uncompressed chunk
        final isReset = control == 1;
        if (isReset) needReset = true;
        if (pos + 2 > data.length) break;
        final chunkSize = ((data[pos] << 8) | data[pos + 1]) + 1;
        pos += 2;
        if (pos + chunkSize > data.length) break;
        output.add(data.sublist(pos, pos + chunkSize));
        pos += chunkSize;
      } else if (control >= 0x80) {
        // LZMA chunk
        final isReset = (control & 0x60) != 0;
        final hasNewProps = (control & 0x40) != 0;

        if (pos + 4 > data.length) break;
        final unpackSizeHi = (control & 0x1F);
        final unpackSizeLo = (data[pos] << 8) | data[pos + 1];
        final chunkUnpackSize = (unpackSizeHi << 16) + unpackSizeLo + 1;
        pos += 2;

        final compSize = ((data[pos] << 8) | data[pos + 1]) + 1;
        pos += 2;

        if (hasNewProps) {
          if (pos >= data.length) break;
          final propByte = data[pos++];
          lc = propByte % 9;
          final rem = propByte ~/ 9;
          lp = rem % 5;
          pb = rem ~/ 5;
        }

        if (isReset) needReset = true;

        if (pos + compSize > data.length) break;
        final chunkData = data.sublist(pos, pos + compSize);
        pos += compSize;

        try {
          final decoded = LzmaDecoder.decodeRaw(
            input: chunkData,
            uncompressedSize: chunkUnpackSize,
            lc: lc,
            lp: lp,
            pb: pb,
            dictionarySize: dictSize,
          );
          output.add(decoded);
          needReset = false;
        } catch (e) {
          debugPrint('SevenZipExtractor: LZMA2 chunk decode failed — $e');
          break;
        }
      } else {
        // Unknown control byte
        break;
      }
    }

    return output.toBytes();
  }

  /// Simple BCJ (x86 jump/call) filter for code stream preprocessing.
  static Uint8List _filterBcjX86(Uint8List data) {
    final output = Uint8List.fromList(data);
    int prevMask = 0;
    int pos = 0;
    const kMask = 0xFFFFFFF8; // ~7

    while (pos < output.length - 4) {
      final b = output[pos];
      if (b != 0xE8 && b != 0xE9) {
        pos++;
        prevMask = (prevMask << 1) & 7;
        continue;
      }

      final prevTest = kMask >>>
          (24 - ((prevMask >> 1) > 0 ? (prevMask >> 1) * 8 : 0));
      if ((prevMask & 1) != 0 || prevTest != 0) {
        pos++;
        prevMask = (prevMask << 1) & 7 | 1;
        continue;
      }

      // Convert relative offset to absolute
      int dest = output[pos + 1] |
          (output[pos + 2] << 8) |
          (output[pos + 3] << 16) |
          (output[pos + 4] << 24);
      dest -= pos + 5;
      output[pos + 1] = dest & 0xFF;
      output[pos + 2] = (dest >> 8) & 0xFF;
      output[pos + 3] = (dest >> 16) & 0xFF;
      output[pos + 4] = (dest >> 24) & 0xFF;

      pos += 5;
      prevMask = 0;
    }

    return output;
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Utility methods
  // ──────────────────────────────────────────────────────────────────────

  static void _skipArchiveProperties(_ByteReader reader) {
    while (true) {
      final id = reader.readByte();
      if (id == _kEnd) break;
      final size = reader.readNumber();
      reader.skip(size);
    }
  }

  static void _skipCrcInfo(_ByteReader reader, int count) {
    final allDefined = reader.readByte();
    int numDefined = count;
    if (allDefined == 0) {
      // Bit vector of which have CRCs
      numDefined = 0;
      final numBytes = (count + 7) ~/ 8;
      for (int i = 0; i < numBytes; i++) {
        final b = reader.readByte();
        for (int bit = 7; bit >= 0 && (i * 8 + (7 - bit)) < count; bit--) {
          if ((b & (1 << bit)) != 0) numDefined++;
        }
      }
    }
    // Skip the actual CRC values (4 bytes each)
    reader.skip(numDefined * 4);
  }

  static void _readBitVector(
    _ByteReader reader,
    int count,
    List<bool> vector,
  ) {
    int byte = 0;
    int mask = 0;
    for (int i = 0; i < count; i++) {
      if (mask == 0) {
        byte = reader.readByte();
        mask = 0x80;
      }
      vector[i] = (byte & mask) != 0;
      mask >>= 1;
    }
  }

  static String _readUtf16Name(_ByteReader reader) {
    final chars = <int>[];
    while (reader.hasMore) {
      final lo = reader.readByte();
      final hi = reader.readByte();
      final ch = lo | (hi << 8);
      if (ch == 0) break;
      chars.add(ch);
    }
    return String.fromCharCodes(chars);
  }

  static int _codecIdToInt(Uint8List id) {
    int result = 0;
    for (int i = 0; i < id.length; i++) {
      result = (result << 8) | id[i];
    }
    return result;
  }

  static String _fileExtension(String name) {
    final leaf = name.split(RegExp(r'[\\/]')).last.toLowerCase();
    final dot = leaf.lastIndexOf('.');
    if (dot < 0) return '';
    return leaf.substring(dot);
  }

  static String _sanitizeName(String name) {
    final cleaned = name.replaceAll('\u0000', '').trim();
    final segments = <String>[];
    for (final raw in cleaned.split(RegExp(r'[\\/]'))) {
      final seg = raw.trim();
      if (seg.isEmpty || seg == '.' || seg == '..') continue;
      segments.add(seg);
    }
    return segments.join(Platform.pathSeparator);
  }

  static Future<Uint8List> _readFully(RandomAccessFile raf, int count) async {
    final first = await raf.read(count);
    if (first.length >= count) return first;
    final buffer = BytesBuilder(copy: false);
    buffer.add(first);
    int remaining = count - first.length;
    while (remaining > 0) {
      final chunk = await raf.read(remaining);
      if (chunk.isEmpty) break;
      buffer.add(chunk);
      remaining -= chunk.length;
    }
    return buffer.toBytes();
  }

  static int _readUint64LE(List<int> data, int offset) {
    int result = 0;
    for (int i = 0; i < 8; i++) {
      result |= (data[offset + i] & 0xFF) << (i * 8);
    }
    return result;
  }
}

// ──────────────────────────────────────────────────────────────────────────
//  Isolate-based folder extraction
// ──────────────────────────────────────────────────────────────────────────

/// Parameters passed to the background isolate for folder extraction.
class _FolderExtractParams {
  final String archivePath;
  final String extractRoot;
  final int packOffset;
  final int totalPackSize;
  final List<Uint8List> coderIds;
  final List<Uint8List> coderProps;
  final List<int> unpackSizes;
  final List<_FileExtractInfo> files;
  final List<String>? extensionFilter;

  _FolderExtractParams({
    required this.archivePath,
    required this.extractRoot,
    required this.packOffset,
    required this.totalPackSize,
    required this.coderIds,
    required this.coderProps,
    required this.unpackSizes,
    required this.files,
    this.extensionFilter,
  });
}

/// Minimal file info that can be sent across isolate boundaries.
class _FileExtractInfo {
  final String name;
  final int size;
  final bool isDirectory;

  _FileExtractInfo({
    required this.name,
    required this.size,
    required this.isDirectory,
  });
}

/// Top-level function executed in a background isolate via [compute].
///
/// Performs the heavy work: reads packed data from disk, decompresses via LZMA,
/// and writes extracted files to disk. All memory allocated here is freed when
/// the isolate exits, preventing OOM from cascading between folders.
Future<List<String>> _extractFolderInBackground(
    _FolderExtractParams params) async {
  final extracted = <String>[];
  final extensionFilter =
      params.extensionFilter != null ? Set<String>.from(params.extensionFilter!) : null;

  RandomAccessFile? raf;
  try {
    raf = await File(params.archivePath).open(mode: FileMode.read);
    await raf.setPosition(params.packOffset);

    // Read packed data from disk
    Uint8List packedData = await _readFullyStandalone(raf, params.totalPackSize);

    // Close file handle immediately — we no longer need it
    await raf.close();
    raf = null;

    // Reconstruct folder info for decompression
    final folder = _FolderInfo();
    folder.coderIds.addAll(params.coderIds);
    folder.coderProps.addAll(params.coderProps);
    folder.unpackSizes.addAll(params.unpackSizes);
    folder.numCoders = params.coderIds.length;

    // Decompress (this is the memory-intensive part)
    Uint8List? unpackedData =
        SevenZipExtractor._decompressFolder(folder, packedData);

    // Release packed data immediately after decompression
    packedData = Uint8List(0);

    if (unpackedData == null) return const [];

    // Write extracted files to disk
    int dataOffset = 0;
    for (final entry in params.files) {
      if (entry.isDirectory) {
        final dirPath = '${params.extractRoot}${Platform.pathSeparator}'
            '${SevenZipExtractor._sanitizeName(entry.name)}';
        await Directory(dirPath).create(recursive: true);
        continue;
      }

      final ext = SevenZipExtractor._fileExtension(entry.name);
      if (extensionFilter != null && !extensionFilter.contains(ext)) {
        dataOffset += entry.size;
        continue;
      }

      final destName = SevenZipExtractor._sanitizeName(entry.name);
      if (destName.isEmpty) {
        dataOffset += entry.size;
        continue;
      }

      final destPath =
          '${params.extractRoot}${Platform.pathSeparator}$destName';

      if (await File(destPath).exists()) {
        extracted.add(destPath);
        dataOffset += entry.size;
        continue;
      }

      try {
        await Directory(File(destPath).parent.path).create(recursive: true);
        final end = dataOffset + entry.size;
        // Write directly from the decompressed buffer (no copy via sublist view)
        if (end <= unpackedData.length) {
          await File(destPath).writeAsBytes(
            unpackedData.buffer.asUint8List(
              unpackedData.offsetInBytes + dataOffset,
              entry.size,
            ),
          );
        } else {
          final clampedEnd = unpackedData.length.clamp(dataOffset, end);
          await File(destPath).writeAsBytes(
            unpackedData.buffer.asUint8List(
              unpackedData.offsetInBytes + dataOffset,
              clampedEnd - dataOffset,
            ),
          );
        }
        extracted.add(destPath);
      } catch (e) {
        // Silently skip files that fail to write in isolate
      }

      dataOffset += entry.size;
    }
  } catch (e) {
    // Return whatever we extracted so far
  } finally {
    await raf?.close();
  }

  return extracted;
}

/// Standalone version of _readFully for use in background isolates
/// (which cannot access instance methods on the main isolate's RAF).
Future<Uint8List> _readFullyStandalone(RandomAccessFile raf, int count) async {
  // Read in chunks to avoid a single massive allocation request that may
  // fail on memory-constrained devices.
  const chunkSize = 8 * 1024 * 1024; // 8 MB chunks
  if (count <= chunkSize) {
    final data = await raf.read(count);
    if (data.length >= count) return data;
    final buffer = BytesBuilder(copy: false);
    buffer.add(data);
    int remaining = count - data.length;
    while (remaining > 0) {
      final chunk = await raf.read(remaining.clamp(0, chunkSize));
      if (chunk.isEmpty) break;
      buffer.add(chunk);
      remaining -= chunk.length;
    }
    return buffer.toBytes();
  }

  // For large reads, accumulate in chunks
  final buffer = BytesBuilder(copy: false);
  int remaining = count;
  while (remaining > 0) {
    final toRead = remaining.clamp(0, chunkSize);
    final chunk = await raf.read(toRead);
    if (chunk.isEmpty) break;
    buffer.add(chunk);
    remaining -= chunk.length;
  }
  return buffer.toBytes();
}

// ──────────────────────────────────────────────────────────────────────────
//  Internal data classes
// ──────────────────────────────────────────────────────────────────────────

class _ByteReader {
  final List<int> _data;
  int _pos = 0;

  _ByteReader(this._data);

  int get position => _pos;
  bool get hasMore => _pos < _data.length;

  void setPosition(int p) {
    _pos = p.clamp(0, _data.length);
  }

  int readByte() {
    if (_pos >= _data.length) return 0;
    return _data[_pos++];
  }

  Uint8List readBytes(int count) {
    final end = (_pos + count).clamp(_pos, _data.length);
    final result = Uint8List.fromList(
      _data.sublist(_pos, end),
    );
    _pos = end;
    return result;
  }

  /// Read a 7z encoded number (variable-length encoding).
  ///
  /// First byte determines length:
  /// - If bit 7 is 0: value is the byte itself (0-127)
  /// - Otherwise: count leading 1-bits to find number of extra bytes
  int readNumber() {
    final first = readByte();
    int mask = 0x80;
    int value = 0;

    for (int i = 0; i < 8; i++) {
      if ((first & mask) == 0) {
        value |= (first & (mask - 1)) << (i * 8);
        return value;
      }
      value |= readByte() << (i * 8);
      mask >>= 1;
    }
    return value;
  }

  void skip(int count) {
    _pos = (_pos + count).clamp(0, _data.length);
  }
}

class _ArchiveInfo {
  int? packPos;
  List<int>? packSizes;
  final folders = <_FolderInfo>[];
  final files = <SevenZipEntry>[];
}

class _FolderInfo {
  int numCoders = 0;
  int numInStreams = 1;
  int numOutStreams = 1;
  int numPackStreams = 1;
  int numUnpackStreams = 1;
  bool hasCrc = false;
  final coderIds = <Uint8List>[];
  final coderProps = <Uint8List>[];
  final unpackSizes = <int>[];
  final packSizes = <int>[];
  final subStreamSizes = <int>[];
}

/// Metadata for a single file inside a 7z archive.
class SevenZipEntry {
  final String name;
  final int size;
  final bool isDirectory;

  const SevenZipEntry({
    required this.name,
    required this.size,
    required this.isDirectory,
  });

  SevenZipEntry copyWith({String? name, int? size, bool? isDirectory}) {
    return SevenZipEntry(
      name: name ?? this.name,
      size: size ?? this.size,
      isDirectory: isDirectory ?? this.isDirectory,
    );
  }

  String get extension {
    final leaf = name.split(RegExp(r'[\\/]')).last.toLowerCase();
    final dot = leaf.lastIndexOf('.');
    if (dot < 0) return '';
    return leaf.substring(dot);
  }

  @override
  String toString() => 'SevenZipEntry(name=$name, size=$size, dir=$isDirectory)';
}
