import 'dart:typed_data';

/// Pure Dart LZMA decoder.
///
/// Implements the LZMA decompression algorithm (range coder + LZ77) as
/// described in the LZMA SDK specification. Used by [SevenZipExtractor] to
/// decompress 7z archive entries.
///
/// This is a from-scratch implementation — no third-party packages.
class LzmaDecoder {
  /// Decode an LZMA stream.
  ///
  /// [input] contains the LZMA compressed data.
  /// [uncompressedSize] is the expected output size (-1 if unknown, uses EOS marker).
  /// Returns the decompressed bytes.
  static Uint8List decode(Uint8List input, int uncompressedSize) {
    final decoder = _LzmaDecoderState(input, uncompressedSize);
    return decoder.decode();
  }

  /// Decode an LZMA stream with properties header (5 bytes props + 8 bytes size).
  ///
  /// Standard LZMA file format: [props(5)] [uncompressedSize(8)] [data...]
  static Uint8List decodeWithHeader(Uint8List input) {
    if (input.length < 13) {
      throw LzmaException('LZMA stream too short (${input.length} bytes)');
    }

    // Parse properties byte
    final propsByte = input[0];
    final lc = propsByte % 9;
    final remainder = propsByte ~/ 9;
    final lp = remainder % 5;
    final pb = remainder ~/ 5;
    if (pb > 4) throw LzmaException('Invalid LZMA pb=$pb');

    // Parse dictionary size (4 bytes LE)
    final dictSize = input[1] |
        (input[2] << 8) |
        (input[3] << 16) |
        (input[4] << 24);

    // Parse uncompressed size (8 bytes LE, -1 = unknown)
    int uncompressedSize = 0;
    for (int i = 0; i < 8; i++) {
      uncompressedSize |= (input[5 + i] & 0xFF) << (i * 8);
    }

    final data = input.sublist(13);
    final decoder = _LzmaDecoderState.withProps(
      data,
      uncompressedSize,
      lc,
      lp,
      pb,
      dictSize,
    );
    return decoder.decode();
  }

  /// Decode raw LZMA data with externally specified properties.
  ///
  /// Used by 7z extractor where properties are stored in the coder info.
  static Uint8List decodeRaw({
    required Uint8List input,
    required int uncompressedSize,
    required int lc,
    required int lp,
    required int pb,
    required int dictionarySize,
  }) {
    final decoder = _LzmaDecoderState.withProps(
      input,
      uncompressedSize,
      lc,
      lp,
      pb,
      dictionarySize,
    );
    return decoder.decode();
  }
}

class LzmaException implements Exception {
  final String message;
  LzmaException(this.message);
  @override
  String toString() => 'LzmaException: $message';
}

// ──────────────────────────────────────────────────────────────────────────
//  Internal decoder state
// ──────────────────────────────────────────────────────────────────────────

const int _kNumBitModelTotalBits = 11;
const int _kBitModelTotal = 1 << _kNumBitModelTotalBits;
const int _kNumMoveBits = 5;
const int _kNumStates = 12;
const int _kNumLenToPosStates = 4;
const int _kNumAlignBits = 4;
const int _kStartPosModelIndex = 4;
const int _kEndPosModelIndex = 14;
const int _kNumFullDistances = 1 << (_kEndPosModelIndex >> 1);
const int _kMatchMinLen = 2;

class _LzmaDecoderState {
  final Uint8List _input;
  int _inputPos = 0;
  final int _uncompressedSize;

  int _lc = 3;
  int _lp = 0;
  int _pb = 2;
  int _dictSize = 1 << 23; // 8 MB default

  // Range decoder state
  int _range = 0;
  int _code = 0;

  // Output buffer
  late Uint8List _output;
  int _outputPos = 0;

  // Dictionary (circular buffer)
  late Uint8List _dict;
  int _dictPos = 0;
  late int _dictSizeMask;

  // State
  int _state = 0;
  final _reps = Int32List(4);

  // Probability models
  late Uint16List _isMatch;
  late Uint16List _isRep;
  late Uint16List _isRepG0;
  late Uint16List _isRepG1;
  late Uint16List _isRepG2;
  late Uint16List _isRep0Long;
  late Uint16List _posSlotDecoder;
  late Uint16List _posDecoders;
  late Uint16List _posAlignDecoder;
  late Uint16List _litProbs;
  late _LenDecoder _lenDecoder;
  late _LenDecoder _repLenDecoder;

  _LzmaDecoderState(this._input, this._uncompressedSize) {
    _initProbs();
  }

  _LzmaDecoderState.withProps(
    this._input,
    this._uncompressedSize,
    this._lc,
    this._lp,
    this._pb,
    this._dictSize,
  ) {
    if (_dictSize < 1) _dictSize = 1;
    _initProbs();
  }

  void _initProbs() {
    final posStates = 1 << _pb;

    _isMatch = _createProbs(_kNumStates * posStates);
    _isRep = _createProbs(_kNumStates);
    _isRepG0 = _createProbs(_kNumStates);
    _isRepG1 = _createProbs(_kNumStates);
    _isRepG2 = _createProbs(_kNumStates);
    _isRep0Long = _createProbs(_kNumStates * posStates);
    _posSlotDecoder = _createProbs(_kNumLenToPosStates * 64);
    _posDecoders = _createProbs(1 + _kNumFullDistances - _kEndPosModelIndex);
    _posAlignDecoder = _createProbs(1 << _kNumAlignBits);
    _litProbs = _createProbs(0x300 << (_lc + _lp));
    _lenDecoder = _LenDecoder(posStates);
    _repLenDecoder = _LenDecoder(posStates);
  }

  static Uint16List _createProbs(int count) {
    final probs = Uint16List(count);
    for (int i = 0; i < count; i++) {
      probs[i] = _kBitModelTotal ~/ 2;
    }
    return probs;
  }

  Uint8List decode() {
    // Determine output size
    final outputSize = _uncompressedSize == -1
        ? (_dictSize * 2).clamp(1 << 20, 1 << 30)
        : _uncompressedSize;
    _output = Uint8List(outputSize);
    _outputPos = 0;

    // Use dict size rounded up to power of 2 for masking
    int realDictSize = _dictSize;
    if (realDictSize < 4096) realDictSize = 4096;
    // Round up to power of 2
    int ds = 1;
    while (ds < realDictSize) {
      ds <<= 1;
    }
    _dict = Uint8List(ds);
    _dictSizeMask = ds - 1;
    _dictPos = 0;

    // Initialize range decoder
    _initRangeDecoder();

    // Initialize reps
    _reps[0] = _reps[1] = _reps[2] = _reps[3] = 0;

    // Main decode loop
    while (true) {
      if (_uncompressedSize != -1 && _outputPos >= _uncompressedSize) break;

      final posState = _outputPos & ((1 << _pb) - 1);
      if (_decodeBit(_isMatch, _state * (1 << _pb) + posState) == 0) {
        // Literal
        _decodeLiteral();
        _state = _state < 4 ? 0 : (_state < 10 ? _state - 3 : _state - 6);
      } else {
        // Match or rep
        int len;
        if (_decodeBit(_isRep, _state) != 0) {
          // Rep match
          if (_decodeBit(_isRepG0, _state) == 0) {
            if (_decodeBit(_isRep0Long, _state * (1 << _pb) + posState) == 0) {
              // ShortRep
              _state = _state < 7 ? 9 : 11;
              _putByte(_dict[(_dictPos - _reps[0] - 1) & _dictSizeMask]);
              continue;
            }
          } else {
            int dist;
            if (_decodeBit(_isRepG1, _state) == 0) {
              dist = _reps[1];
            } else {
              if (_decodeBit(_isRepG2, _state) == 0) {
                dist = _reps[2];
              } else {
                dist = _reps[3];
                _reps[3] = _reps[2];
              }
              _reps[2] = _reps[1];
            }
            _reps[1] = _reps[0];
            _reps[0] = dist;
          }
          len = _repLenDecoder.decode(this, posState) + _kMatchMinLen;
          _state = _state < 7 ? 8 : 11;
        } else {
          // Normal match
          _reps[3] = _reps[2];
          _reps[2] = _reps[1];
          _reps[1] = _reps[0];
          len = _lenDecoder.decode(this, posState) + _kMatchMinLen;
          _state = _state < 7 ? 7 : 10;

          final posSlot = _decodeTree(
            _posSlotDecoder,
            _getLenToPosState(len) * 64,
            6,
          );
          if (posSlot >= _kStartPosModelIndex) {
            final numDirectBits = (posSlot >> 1) - 1;
            int dist = (2 | (posSlot & 1)) << numDirectBits;
            if (posSlot < _kEndPosModelIndex) {
              dist += _decodeReverseBits(
                _posDecoders,
                dist - posSlot - 1,
                numDirectBits,
              );
            } else {
              dist += _decodeDirectBits(numDirectBits - _kNumAlignBits) <<
                  _kNumAlignBits;
              dist += _decodeReverseBits(
                _posAlignDecoder,
                0,
                _kNumAlignBits,
              );
            }
            _reps[0] = dist;
          } else {
            _reps[0] = posSlot;
          }
        }

        if (_reps[0] == 0xFFFFFFFF) break; // EOS marker
        if (_outputPos == 0 && _reps[0] == 0) {
          // First byte: distance 0 is invalid before any output
          break;
        }
        if (_reps[0] >= _outputPos && _outputPos < _dictSize) {
          // Haven't filled the dictionary yet — distance is too large
          break;
        }

        _copyMatch(_reps[0], len);
      }
    }

    if (_outputPos < _output.length) {
      return Uint8List.sublistView(_output, 0, _outputPos);
    }
    return _output;
  }

  void _initRangeDecoder() {
    if (_inputPos < _input.length) {
      _inputPos++; // skip first byte (must be 0)
    }
    _code = 0;
    _range = 0xFFFFFFFF;
    for (int i = 0; i < 4; i++) {
      _code = (_code << 8) | _readByte();
    }
  }

  int _readByte() {
    if (_inputPos >= _input.length) return 0;
    return _input[_inputPos++];
  }

  void _normalize() {
    if ((_range & 0xFFFFFFFF) < 0x01000000) {
      _range = (_range << 8) & 0xFFFFFFFF;
      _code = ((_code << 8) | _readByte()) & 0xFFFFFFFF;
    }
  }

  int _decodeBit(Uint16List probs, int index) {
    _normalize();
    final prob = probs[index];
    final bound = (_range >>> 11) * prob;
    if ((_code & 0xFFFFFFFF) < (bound & 0xFFFFFFFF)) {
      _range = bound;
      probs[index] = (prob + ((_kBitModelTotal - prob) >> _kNumMoveBits))
          .toUnsigned(16);
      return 0;
    } else {
      _range = (_range - bound) & 0xFFFFFFFF;
      _code = (_code - bound) & 0xFFFFFFFF;
      probs[index] = (prob - (prob >> _kNumMoveBits)).toUnsigned(16);
      return 1;
    }
  }

  int _decodeDirectBits(int numBits) {
    int result = 0;
    for (int i = numBits; i > 0; i--) {
      _normalize();
      _range = (_range >>> 1) & 0xFFFFFFFF;
      _code = (_code - _range) & 0xFFFFFFFF;
      // If code "underflowed" (was < range before subtraction), high bit is set
      final t = (_code >> 31) & 1; // bit 31 of the 32-bit value
      // If t == 1, code was < range, so add range back
      _code = (_code + (_range & (0 - t))) & 0xFFFFFFFF;
      result = (result << 1) | (1 - t);
    }
    return result;
  }

  int _decodeTree(Uint16List probs, int offset, int numBits) {
    int m = 1;
    for (int i = 0; i < numBits; i++) {
      m = (m << 1) | _decodeBit(probs, offset + m);
    }
    return m - (1 << numBits);
  }

  int _decodeReverseBits(Uint16List probs, int offset, int numBits) {
    int m = 1;
    int symbol = 0;
    for (int i = 0; i < numBits; i++) {
      final bit = _decodeBit(probs, offset + m);
      m = (m << 1) | bit;
      symbol |= bit << i;
    }
    return symbol;
  }

  void _decodeLiteral() {
    final prevByte = _outputPos > 0
        ? _dict[(_dictPos - 1) & _dictSizeMask]
        : 0;
    final litState = ((_outputPos & ((1 << _lp) - 1)) << _lc) +
        ((prevByte & 0xFF) >>> (8 - _lc));
    final probsOffset = 0x300 * litState;

    int symbol;
    if (_state >= 7) {
      // Use match byte for context — shift left each iteration per LZMA spec
      int matchByte = _dict[(_dictPos - _reps[0] - 1) & _dictSizeMask];
      symbol = 1;
      do {
        final matchBit = (matchByte >> 7) & 1;
        matchByte = (matchByte << 1) & 0xFF;
        final bit = _decodeBit(
          _litProbs,
          probsOffset + ((1 + matchBit) << 8) + symbol,
        );
        symbol = (symbol << 1) | bit;
        if (matchBit != bit) break;
      } while (symbol < 0x100);
      while (symbol < 0x100) {
        symbol = (symbol << 1) | _decodeBit(_litProbs, probsOffset + symbol);
      }
    } else {
      symbol = 1;
      while (symbol < 0x100) {
        symbol = (symbol << 1) | _decodeBit(_litProbs, probsOffset + symbol);
      }
    }
    _putByte(symbol & 0xFF);
  }

  void _putByte(int b) {
    _dict[_dictPos & _dictSizeMask] = b;
    _dictPos++;
    if (_outputPos < _output.length) {
      _output[_outputPos] = b;
    }
    _outputPos++;
  }

  void _copyMatch(int dist, int len) {
    for (int i = 0; i < len; i++) {
      final b = _dict[(_dictPos - dist - 1) & _dictSizeMask];
      _putByte(b);
      if (_uncompressedSize != -1 && _outputPos >= _uncompressedSize) break;
    }
  }

  static int _getLenToPosState(int len) {
    final adjusted = len - _kMatchMinLen;
    if (adjusted < _kNumLenToPosStates) return adjusted;
    return _kNumLenToPosStates - 1;
  }
}

// ──────────────────────────────────────────────────────────────────────────
//  Length decoder
// ──────────────────────────────────────────────────────────────────────────

class _LenDecoder {
  late Uint16List _choice;
  late Uint16List _lowCoder;
  late Uint16List _midCoder;
  late Uint16List _highCoder;
  final int _numPosStates;

  _LenDecoder(this._numPosStates) {
    _choice = _LzmaDecoderState._createProbs(2);
    _lowCoder = _LzmaDecoderState._createProbs(_numPosStates * 8);
    _midCoder = _LzmaDecoderState._createProbs(_numPosStates * 8);
    _highCoder = _LzmaDecoderState._createProbs(256);
  }

  int decode(_LzmaDecoderState state, int posState) {
    if (state._decodeBit(_choice, 0) == 0) {
      return state._decodeTree(_lowCoder, posState * 8, 3);
    }
    if (state._decodeBit(_choice, 1) == 0) {
      return 8 + state._decodeTree(_midCoder, posState * 8, 3);
    }
    return 16 + state._decodeTree(_highCoder, 0, 8);
  }
}
