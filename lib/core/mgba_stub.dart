import 'dart:typed_data';

import '../models/game_rom.dart';
import 'mgba_bindings.dart';

/// Stub implementation of mGBA core for testing UI without native library
/// This simulates the emulator interface with fake data
class MGBAStub {
  bool _isRunning = false;
  int _width = 240;
  int _height = 160;
  GamePlatform _platform = GamePlatform.gba;
  int _currentKeys = 0;
  int _frameCount = 0;

  bool get isRunning => _isRunning;
  int get width => _width;
  int get height => _height;
  GamePlatform get platform => _platform;

  /// Initialize (always succeeds in stub)
  bool initialize() => true;

  /// Load a ROM file (simulates loading)
  bool loadROM(String path) {
    // Detect platform from extension
    if (path.endsWith('.gb')) {
      _platform = GamePlatform.gb;
      _width = 160;
      _height = 144;
    } else if (path.endsWith('.gbc')) {
      _platform = GamePlatform.gbc;
      _width = 160;
      _height = 144;
    } else if (path.endsWith('.nes') ||
        path.endsWith('.unf') ||
        path.endsWith('.unif')) {
      _platform = GamePlatform.nes;
      _width = 256;
      _height = 240;
    } else if (path.endsWith('.sfc') || path.endsWith('.smc')) {
      _platform = GamePlatform.snes;
      _width = 256;
      _height = 224;
    } else if (path.endsWith('.sg')) {
      _platform = GamePlatform.sg1000;
      _width = 256;
      _height = 192;
    } else if (path.endsWith('.sms')) {
      _platform = GamePlatform.sms;
      _width = 256;
      _height = 192;
    } else if (path.endsWith('.gg')) {
      _platform = GamePlatform.gg;
      _width = 160;
      _height = 144;
    } else if (path.endsWith('.md') || path.endsWith('.gen')) {
      _platform = GamePlatform.md;
      _width = 320;
      _height = 224;
    } else if (path.endsWith('.bin')) {
      if (GameRom.isLikelyMegaDriveBin(path)) {
        _platform = GamePlatform.md;
        _width = 320;
        _height = 224;
      } else {
        _platform = GamePlatform.gba;
        _width = 240;
        _height = 160;
      }
    } else {
      _platform = GamePlatform.gba;
      _width = 240;
      _height = 160;
    }
    _isRunning = true;
    return true;
  }

  bool loadBIOS(String path) => true;

  void setSaveDir(String path) {}

  void runFrame() {
    if (!_isRunning) return;
    _frameCount++;
  }

  void setKeys(int keys) {
    _currentKeys = keys;
  }

  void pressKey(int key) {
    _currentKeys |= key;
  }

  void releaseKey(int key) {
    _currentKeys &= ~key;
  }

  /// Generate a test pattern based on input state
  Uint8List? getVideoBuffer() {
    if (!_isRunning) return null;

    final pixels = Uint8List(_width * _height * 4);
    
    // Create an animated gradient pattern
    final time = _frameCount / 60.0;
    
    for (int y = 0; y < _height; y++) {
      for (int x = 0; x < _width; x++) {
        final i = (y * _width + x) * 4;
        
        // Base gradient
        final nx = x / _width;
        final ny = y / _height;
        
        // Animate based on frame count
        final wave = (sin((nx + time) * 3.14159 * 2) + 1) / 2;
        final wave2 = (sin((ny + time * 0.7) * 3.14159 * 2) + 1) / 2;
        
        // Show input visualization
        int r = ((wave * 100) + 50).toInt();
        int g = ((wave2 * 80) + 30).toInt();
        int b = ((nx * ny * 150) + 50).toInt();
        
        // Highlight based on key presses
        if (_currentKeys & GBAKey.up != 0 && y < _height ~/ 4) {
          g = 255;
        }
        if (_currentKeys & GBAKey.down != 0 && y > _height * 3 ~/ 4) {
          g = 255;
        }
        if (_currentKeys & GBAKey.left != 0 && x < _width ~/ 4) {
          r = 255;
        }
        if (_currentKeys & GBAKey.right != 0 && x > _width * 3 ~/ 4) {
          r = 255;
        }
        if (_currentKeys & GBAKey.a != 0) {
          b = 255;
        }
        if (_currentKeys & GBAKey.b != 0) {
          r = 255; g = 255;
        }
        
        pixels[i] = r.clamp(0, 255);
        pixels[i + 1] = g.clamp(0, 255);
        pixels[i + 2] = b.clamp(0, 255);
        pixels[i + 3] = 255;
      }
    }

    return pixels;
  }

  (Int16List?, int) getAudioBuffer() {
    // Return silence
    return (null, 0);
  }

  bool saveState(int slot) => true;
  bool loadState(int slot) => true;
  
  // SRAM stubs (no-op in demo mode)
  int getSramSize() => 0;
  bool saveSram(String path) => true;
  bool loadSram(String path) => true;

  // Audio volume stubs
  void setVolume(double volume) {}
  void setAudioEnabled(bool enabled) {}

  // Color palette stub
  void setColorPalette(int paletteIndex, List<int> colors) {}

  // Rewind stubs
  int rewindInit(int capacity) => 0;
  void rewindDeinit() {}
  int rewindPush() => 0;
  int rewindPop() => -1; // No states available in stub
  int rewindCount() => 0;

  // Link cable stubs
  bool get isLinkSupported => false;
  int linkReadByte(int addr) => -1;
  int linkWriteByte(int addr, int value) => -1;
  int linkGetTransferStatus() => -1;
  int linkExchangeData(int incoming) => -1;

  // Memory read stubs (for RetroAchievements — no-op in demo mode)
  bool get isMemoryReadSupported => false;
  int readByte(int address) => 0;
  int getMemorySize(int regionId) => 0;

  void reset() {
    _frameCount = 0;
  }

  void dispose() {
    _isRunning = false;
  }
}

double sin(double x) {
  // Simple sine approximation
  x = x % (3.14159 * 2);
  if (x < 0) x += 3.14159 * 2;
  
  // Taylor series approximation
  double result = x;
  double term = x;
  for (int i = 1; i < 10; i++) {
    term *= -x * x / ((2 * i) * (2 * i + 1));
    result += term;
  }
  return result;
}

