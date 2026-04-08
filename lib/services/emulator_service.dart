import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/input_profile.dart';
import '../core/mgba_bindings.dart';
import '../core/mgba_stub.dart';
import '../utils/device_memory.dart';
import '../models/game_rom.dart';
import '../models/emulator_settings.dart';
import 'link_cable_service.dart';
import 'rcheevos_client.dart';
import 'rom_folder_service.dart';

enum EmulatorState { uninitialized, ready, running, paused, error }

class EmulatorService extends ChangeNotifier {
  final MGBABindings _bindings = MGBABindings();
  MGBACore? _core;
  MGBAStub? _stub; 
  bool _useStub = false;

  EmulatorState _state = EmulatorState.uninitialized;
  GameRom? _currentRom;
  EmulatorSettings _settings = const EmulatorSettings();
  String? _errorMessage;
  String? _saveDir;

  String? get saveDir => _saveDir;

  Timer? _frameTimer;
  Timer? _autoSaveTimer;

  Future<void> _sramSaveLock = Future.value();
  Stopwatch? _frameStopwatch;
  int _frameCount = 0;
  double _currentFps = 0;
  double _speedMultiplier = 1.0;

  bool _frameLoopActive = false;

  bool _useNativeFrameLoop = false;

  NativeCallable<NativeFrameCallback>? _nativeFrameCallable;

  bool _useTextureRendering = false;
  bool get useTextureRendering => _useTextureRendering;

  void setTextureRendering(bool enabled) {
    _useTextureRendering = enabled;
    debugPrint(
      'EmulatorService: texture rendering ${enabled ? "enabled" : "disabled"}',
    );
  }
  final Stopwatch _playTimeStopwatch = Stopwatch();
  int _flushedPlayTimeSeconds = 0;

  LinkCableService? linkCable;

  RcheevosClient? rcheevosClient;

  late InputProfile _inputProfile;

  MGBACore? get core => _core;

  InputProfile get inputProfile => _inputProfile;

  bool get isLinkSupported {
    if (_useStub) return _stub?.isLinkSupported ?? false;
    return _core?.isLinkSupported ?? false;
  }

  bool get isRewindSupported =>
      !_useStub && _settings.enableRewind && _rewindBufferReady;

  bool get isRewindBufferReady => _rewindBufferReady;
  bool _rewindBufferReady = false;
  bool _isRewinding = false;
  int _rewindCaptureCounter = 0;
  int _rewindStepCounter = 0;
  static const int _rewindCaptureInterval = 5; 
  static const int _rewindStepFrames =
      3; 
  static const Duration _baseFrameTime = Duration(microseconds: 16742);
  Duration get _targetFrameTime => Duration(
    microseconds: (_baseFrameTime.inMicroseconds / _speedMultiplier).round(),
  );
  void Function(Uint8List pixels, int width, int height)? onFrame;
  void Function(Int16List samples, int count)? onAudio;

  EmulatorState get state => _state;
  GameRom? get currentRom => _currentRom;
  EmulatorSettings get settings => _settings;
  String? get errorMessage => _errorMessage;
  double get currentFps => _currentFps;
  bool get isRunning => _state == EmulatorState.running;
  bool get isUsingStub => _useStub;
  double get speedMultiplier => _speedMultiplier;
  bool get isRewinding => _isRewinding;

  int get sessionPlayTimeSeconds => _playTimeStopwatch.elapsed.inSeconds;

  int flushPlayTime() {
    final total = _playTimeStopwatch.elapsed.inSeconds;
    final delta = total - _flushedPlayTimeSeconds;
    _flushedPlayTimeSeconds = total;
    return delta;
  }

  void setSpeed(double speed) {
    _speedMultiplier = speed.clamp(0.25, 8.0);
    if (_useNativeFrameLoop) {
      _core?.frameLoopSetSpeed((_speedMultiplier * 100).round());
    }
    notifyListeners();
  }

  void toggleFastForward() {
    if (_speedMultiplier > 1.0) {
      _speedMultiplier = 1.0;
    } else {
      _speedMultiplier = _settings.turboSpeed;
    }
    if (_useNativeFrameLoop) {
      _core?.frameLoopSetSpeed((_speedMultiplier * 100).round());
    }
    notifyListeners();
  }

  int get screenWidth {
    if (_useStub) return _stub?.width ?? 240;
    if (_useNativeFrameLoop) return _core?.displayWidth ?? 240;
    return _core?.width ?? 240;
  }

  int get screenHeight {
    if (_useStub) return _stub?.height ?? 160;
    if (_useNativeFrameLoop) return _core?.displayHeight ?? 160;
    return _core?.height ?? 160;
  }

  GamePlatform get platform {
    if (_useStub) return _stub?.platform ?? GamePlatform.unknown;
    return _core?.platform ?? GamePlatform.unknown;
  }

  Future<bool> initialize({GamePlatform? platform}) async {
    if (_state != EmulatorState.uninitialized) return true;

    try {
      if (platform != null) {
        _bindings.selectCore(platform);
        final coreLoadError = _bindings.lastCoreLoadError;
        if (coreLoadError != null) {
          _errorMessage =
              'Failed to load ${platform.name.toUpperCase()} core. '
              '$coreLoadError';
          _state = EmulatorState.error;
          notifyListeners();
          return false;
        }
      }
      if (_bindings.load()) {
        _core = MGBACore(_bindings);
        final effectivePlatform = platform ?? GamePlatform.gba;
        _inputProfile = getInputProfileForPlatform(effectivePlatform);
        debugPrint(
          'Loaded input profile: ${_inputProfile.name} for $effectivePlatform',
        );
        if (platform != null && _bindings.isCoreSelectionLoaded) {
          if (platform == GamePlatform.gb ||
              platform == GamePlatform.gbc ||
              platform == GamePlatform.gba) {
            _core!.setCoreLibrary('');
          } else {
            final coreLib = MGBABindings.platformCoreLibs[platform];
            if (coreLib != null) {
              _core!.setCoreLibrary(coreLib);
            }
          }
        }
        final saveDir = await _getSaveDirectory();
        final systemDir = await _getSystemDirectory();
        _saveDir = saveDir;
        _core!.setSystemDir(systemDir);
        _core!.setSaveDir(saveDir);
        debugPrint('Core dirs: system=$systemDir save=$saveDir');

        if (_core!.initialize()) {
          _useStub = false;
          _state = EmulatorState.ready;
          notifyListeners();
          return true;
        }
        if (platform != null &&
            platform != GamePlatform.gb &&
            platform != GamePlatform.gbc &&
            platform != GamePlatform.gba) {
          _errorMessage =
              'Failed to load ${platform.name.toUpperCase()} core. '
              'Please reinstall the app or check that cores are bundled.';
        } else {
          _errorMessage = 'Failed to initialize emulator core.';
        }
        _state = EmulatorState.error;
        notifyListeners();
        return false;
      }
      _errorMessage = 'Emulator engine not found. Please reinstall the app.';
      _state = EmulatorState.error;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('Error initializing: $e');
      _errorMessage = 'Failed to initialize emulator: $e';
      _state = EmulatorState.error;
      notifyListeners();
      return false;
    }
  }

  Future<String> _getSaveDirectory() async {
    final appDir = await getApplicationSupportDirectory();
    final saveDir = Directory(p.join(appDir.path, 'saves'));
    if (!saveDir.existsSync()) {
      saveDir.createSync(recursive: true);
    }
    return saveDir.path;
  }

  Future<String> _getSystemDirectory() async {
    final appDir = await getApplicationSupportDirectory();
    final systemDir = Directory(p.join(appDir.path, 'system'));
    if (!systemDir.existsSync()) {
      systemDir.createSync(recursive: true);
    }
    await _deploySystemFiles(systemDir.path);
    return systemDir.path;
  }

  Future<void> _deploySystemFiles(String systemDirPath) async {
    final iniFile = File(p.join(systemDirPath, 'mupen64plus.ini'));
    if (!iniFile.existsSync()) {
      try {
        final data = await rootBundle.load('native/mupen64plus.ini');
        iniFile.writeAsBytesSync(data.buffer.asUint8List());
        debugPrint('Deployed mupen64plus.ini to system dir');
      } catch (e) {
        debugPrint('Failed to deploy mupen64plus.ini: $e');
      }
    }
  }

  String _getRomSaveDir(GameRom rom) {
    return _saveDir ?? p.dirname(rom.path);
  }

  String _getSramPath(GameRom rom) {
    final saveDir = _getRomSaveDir(rom);
    final saveName = p.basenameWithoutExtension(rom.path);
    return p.join(saveDir, '$saveName.sav');
  }

  Future<void> _loadSram(GameRom rom) async {
    if (_useStub || _core == null) return;

    final saveName = '${p.basenameWithoutExtension(rom.path)}.sav';
    final internalSramPath = _getSramPath(rom);
    final folderUri = _settings.userRomsFolderUri;
    if (folderUri != null &&
        folderUri.isNotEmpty &&
        !File(internalSramPath).existsSync()) {
      try {
        final copied = await RomFolderService.copySaveFromUserFolder(
          folderUri,
          saveName,
          internalSramPath,
        );
        if (copied) {
          debugPrint('Imported SRAM from user folder: $saveName');
        }
      } catch (e) {
        debugPrint('Error importing SRAM from user folder: $e');
      }
    }

    final searchDirs = _allSaveDirectories(rom);

    for (final dir in searchDirs) {
      try {
        final sramPath = p.join(dir, saveName);
        if (File(sramPath).existsSync()) {
          final success = _core!.loadSram(sramPath);
          debugPrint('Loaded SRAM from $sramPath: $success');
          return;
        }
      } catch (e) {
        debugPrint('Error checking SRAM in $dir: $e');
      }
    }
    debugPrint('No SRAM file found for ${rom.name}');
  }

  List<String> _allSaveDirectories(GameRom rom) {
    final dirs = <String>{};
    if (_saveDir != null) dirs.add(_saveDir!);
    dirs.add(p.dirname(rom.path));
    return dirs.toList();
  }

  Future<void> saveSram() {
    final previous = _sramSaveLock;
    final completer = Completer<void>();
    _sramSaveLock = completer.future;

    return previous
        .then((_) async {
          if (_useStub || _core == null || _currentRom == null) return;

          try {
            final sramPath = _getSramPath(_currentRom!);
            final success = _core!.saveSram(sramPath);
            debugPrint('Saved SRAM to $sramPath: $success');
            if (success) _syncSaveToUserFolder(sramPath);
          } catch (e) {
            debugPrint('Error saving SRAM: $e');
          }
        })
        .whenComplete(() {
          completer.complete();
        });
  }

  static final _deviceChannel = MethodChannel(
    'com.yourmateapps.retropal/device',
  );

  Future<bool> importSramFromFile(String sourcePathOrUri) async {
    if (_useStub || _core == null || _currentRom == null) return false;

    try {
      final sramPath = _getSramPath(_currentRom!);
      final saveDir = Directory(p.dirname(sramPath));
      if (!saveDir.existsSync()) {
        saveDir.createSync(recursive: true);
      }

      String? sourcePath = sourcePathOrUri;
      bool isTempFile = false;
      if (sourcePathOrUri.startsWith('content://')) {
        sourcePath = await _deviceChannel.invokeMethod<String>(
          'copyUriToInternalStorage',
          {'uri': sourcePathOrUri},
        );
        if (sourcePath == null) return false;
        isTempFile = true;
      }

      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) return false;
      await _sramSaveLock;
      final wasNative = _useNativeFrameLoop;
      if (wasNative) _stopNativeFrameLoop();
      _stopAutoSaveTimer();

      try {
        await sourceFile.copy(sramPath);
        if (isTempFile) {
          try {
            await sourceFile.delete();
          } catch (_) {}
        }
        final success = _core!.loadSram(sramPath);
        if (!success) return false;
        _core!.reset();
        _applyAudioSettings();
        _applyColorPalette();
      } finally {
        if (wasNative && _state == EmulatorState.running) {
          _startNativeFrameLoop();
        }
        _startAutoSaveTimer();
      }

      _syncSaveToUserFolder(sramPath);
      debugPrint('Imported SRAM from $sourcePathOrUri');
      return true;
    } catch (e) {
      debugPrint('Error importing SRAM: $e');
      return false;
    }
  }

  void _syncSaveToUserFolder(String sourcePath) {
    final folderUri = _settings.userRomsFolderUri;
    if (folderUri == null || folderUri.isEmpty) return;
    unawaited(RomFolderService.copySaveToUserFolder(folderUri, sourcePath));
  }

  Future<int> deleteSaveData(GameRom rom) async {
    int deleted = 0;
    final saveDir = _getRomSaveDir(rom);
    final baseName = p.basenameWithoutExtension(rom.path);
    final romBase = p.basename(rom.path);
    final dirs = <String>{saveDir};
    if (_saveDir != null && _saveDir != saveDir) {
      dirs.add(_saveDir!);
    }

    for (final dir in dirs) {
      final sramFile = File(p.join(dir, '$baseName.sav'));
      if (sramFile.existsSync()) {
        try {
          sramFile.deleteSync();
          deleted++;
        } catch (e) {
          debugPrint('Failed to delete SRAM file ${sramFile.path}: $e');
        }
      }
      for (int slot = 0; slot < 6; slot++) {
        final stateFile = File(p.join(dir, '$romBase.ss$slot'));
        if (stateFile.existsSync()) {
          try {
            stateFile.deleteSync();
            deleted++;
          } catch (e) {
            debugPrint('Failed to delete save state ${stateFile.path}: $e');
          }
        }
        final ssFile = File(p.join(dir, '$romBase.ss$slot.png'));
        if (ssFile.existsSync()) {
          try {
            ssFile.deleteSync();
            deleted++;
          } catch (e) {
            debugPrint('Failed to delete screenshot ${ssFile.path}: $e');
          }
        }
      }
      try {
        final directory = Directory(dir);
        if (directory.existsSync()) {
          for (final entity in directory.listSync()) {
            if (entity is File) {
              final name = p.basename(entity.path);
              if (name.startsWith('${baseName}_') && name.endsWith('.png')) {
                try {
                  entity.deleteSync();
                  deleted++;
                } catch (e) {
                  debugPrint('Failed to delete screenshot ${entity.path}: $e');
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Failed to list save directory $dir: $e');
      }
    }

    debugPrint('Deleted $deleted save file(s) for ${rom.name}');
    return deleted;
  }

  Future<bool> loadRom(GameRom rom) async {
    final platformChanged = _currentRom?.platform != rom.platform;
    if (platformChanged ||
        (_currentRom == null && (_core != null || _stub != null))) {
      _stub?.dispose();
      _stub = null;
      _core?.dispose();
      _core = null;
      _currentRom = null;
      _state = EmulatorState.uninitialized;
    }
    if (_state == EmulatorState.uninitialized) {
      if (!await initialize(platform: rom.platform)) return false;
    }

    try {
      if (_useStub) {
        _rewindBufferReady = false;
        _stub!.loadROM(rom.path);
        _currentRom = rom.copyWith(lastPlayed: DateTime.now());
        _state = EmulatorState.paused;
        notifyListeners();
        return true;
      }
      final biosPath = _getBiosPath(rom.platform);
      if (biosPath != null && File(biosPath).existsSync()) {
        _core!.loadBIOS(biosPath);
      }
      if (rom.platform == GamePlatform.gb || rom.platform == GamePlatform.gbc) {
        _core!.setSgbBorders(_settings.enableSgbBorders);
      }
      final romSaveDir = _getRomSaveDir(rom);
      _core!.setSaveDir(romSaveDir);

      if (!_core!.loadROM(rom.path)) {
        _errorMessage = 'Failed to load ROM: ${rom.name}';
        notifyListeners();
        return false;
      }
      await _loadSram(rom);
      _applyAudioSettings();
      _applyColorPalette();
      if (_settings.enableRewind) {
        _initRewind();
      } else {
        final hadBuffer = _rewindBufferReady;
        _rewindBufferReady = false;
        _core!.rewindDeinit();
        if (hadBuffer) notifyListeners();
      }

      _currentRom = rom.copyWith(lastPlayed: DateTime.now());
      _state = EmulatorState.paused;
      setKeys(0);
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Error loading ROM: $e';
      notifyListeners();
      return false;
    }
  }

  String? _getBiosPath(GamePlatform platform) {
    return switch (platform) {
      GamePlatform.gba => _settings.biosPathGba,
      GamePlatform.gb => _settings.biosPathGb,
      GamePlatform.gbc => _settings.biosPathGbc,
      _ => null,
    };
  }

  void start() {
    if (_state != EmulatorState.paused) return;
    if (!_useStub && _core == null) return;
    if (_useStub && _stub == null) return;

    _state = EmulatorState.running;
    _frameLoopActive = true;
    _frameStopwatch = Stopwatch()..start();
    _frameCount = 0;
    _playTimeStopwatch.start();
    _startFrameLoop();
    _startAutoSaveTimer();
    notifyListeners();
  }

  bool get _canUseNativeFrameLoop {
    if (_useStub || _core == null) return false;
    if (Platform.isWindows) return false;
    return _core!.isFrameLoopSupported;
  }

  Future<void> pause() async {
    if (_state != EmulatorState.running) return;
    if (_isRewinding) stopRewind();
    _frameLoopActive = false;
    _state = EmulatorState.paused;
    _stopNativeFrameLoop();

    _frameTimer?.cancel();
    _frameTimer = null;
    _playTimeStopwatch.stop();
    _stopAutoSaveTimer();

    notifyListeners();
  }

  void togglePause() {
    if (_state == EmulatorState.running) {
      pause();
    } else if (_state == EmulatorState.paused) {
      start();
    }
  }

  void reset() {
    final wasNative = _useNativeFrameLoop;
    if (wasNative) _stopNativeFrameLoop();

    if (_useStub) {
      _stub?.reset();
    } else {
      _core?.reset();
    }
    if (_state == EmulatorState.paused) {
      _runSingleFrame();
    }
    if (wasNative && _state == EmulatorState.running) {
      _startNativeFrameLoop();
    }
  }

  void _startFrameLoop() {
    if (_canUseNativeFrameLoop && !_isRewinding) {
      _startNativeFrameLoop();
      return;
    }
    _startDartFrameLoop();
  }

  void _startDartFrameLoop() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _lastFrameTime = DateTime.now();
    _frameAccumulator = Duration.zero;
    _scheduleNextTick();
  }

  void _startNativeFrameLoop() {
    if (_useNativeFrameLoop) return; 
    _nativeFrameCallable?.close();
    _nativeFrameCallable = NativeCallable<NativeFrameCallback>.listener(
      _onNativeFrameReady,
    );
    final core = _core!;
    core.frameLoopSetSpeed((_speedMultiplier * 100).round());
    _syncNativeRewindCapture();
    core.frameLoopSetRcheevos(enabled: rcheevosClient != null);

    final ok = core.startFrameLoop(_nativeFrameCallable!.nativeFunction);
    if (ok) {
      _useNativeFrameLoop = true;
      debugPrint('EmulatorService: using native frame loop');
    } else {
      debugPrint(
        'EmulatorService: native frame loop failed, falling back to Dart Timer',
      );
      _nativeFrameCallable?.close();
      _nativeFrameCallable = null;
      _startDartFrameLoop();
    }
  }

  void _stopNativeFrameLoop() {
    if (!_useNativeFrameLoop) return;
    _core?.stopFrameLoop();
    _nativeFrameCallable?.close();
    _nativeFrameCallable = null;
    _useNativeFrameLoop = false;
  }

  void _onNativeFrameReady(int framesRun) {
    if (!_frameLoopActive || !_useNativeFrameLoop) return;
    if (!_useTextureRendering) {
      final core = _core;
      if (core != null && onFrame != null) {
        final pixels = core.getDisplayBuffer();
        if (pixels != null) {
          final w = core.displayWidth;
          final h = core.displayHeight;
          onFrame!(pixels, w, h);
        }
      }
    }
    _pollLinkCable();
    final c = core;
    if (c != null) {
      final nativeFps = c.getFrameLoopFps();
      if (nativeFps > 0) {
        _currentFps = nativeFps;
        if (_settings.showFps) {
          notifyListeners();
        }
      }
    }
  }

  void _scheduleNextTick() {
    if (!_frameLoopActive || _state != EmulatorState.running) return;

    final now = DateTime.now();
    final elapsed = now.difference(_lastFrameTime);
    _lastFrameTime = now;
    _frameAccumulator += elapsed;
    int framesRun = 0;
    while (_frameLoopActive &&
        _frameAccumulator >= _targetFrameTime &&
        framesRun < 3) {
      _runFrame();
      _frameAccumulator -= _targetFrameTime;
      framesRun++;
    }
    if (_frameAccumulator > _targetFrameTime * 5) {
      _frameAccumulator = Duration.zero;
    }
    if (!_frameLoopActive) return;
    final remaining = _targetFrameTime - _frameAccumulator;
    final delay = remaining > Duration.zero ? remaining : Duration.zero;
    _frameTimer = Timer(delay, _scheduleNextTick);
  }

  DateTime _lastFrameTime = DateTime.now();
  Duration _frameAccumulator = Duration.zero;

  void _runFrame() {
    if (!_frameLoopActive) return;
    if (_isRewinding && !_useStub) {
      _rewindStepCounter++;
      if (_rewindStepCounter >= _rewindStepFrames) {
        _rewindStepCounter = 0;
        _performRewindStep();
      }
      _frameCount++;
      _updateFps();
      return;
    }
    if (_useStub) {
      if (_stub == null || !_stub!.isRunning) return;
      _stub!.runFrame();
      _frameCount++;

      final pixels = _stub!.getVideoBuffer();
      if (pixels != null && onFrame != null) {
        onFrame!(pixels, _stub!.width, _stub!.height);
      }
    } else {
      if (_core == null || !_core!.isRunning) return;
      _core!.runFrame();
      _frameCount++;

      if (_useTextureRendering) {
        _core!.textureBlit();
      } else {
        final pixels = _core!.getVideoBuffer();
        if (pixels != null && onFrame != null) {
          onFrame!(pixels, _core!.width, _core!.height);
        }
      }
      if (isRewindSupported) {
        _rewindCaptureCounter++;
        if (_rewindCaptureCounter >= _rewindCaptureInterval) {
          _rewindCaptureCounter = 0;
          _core!.rewindPush();
        }
      }
      _pollLinkCable();
      rcheevosClient?.doFrame();
    }

    _updateFps();
  }

  void _updateFps() {
    if (_frameStopwatch != null &&
        _frameStopwatch!.elapsedMilliseconds >= 500) {
      _currentFps = _frameCount * 1000 / _frameStopwatch!.elapsedMilliseconds;
      _frameCount = 0;
      _frameStopwatch!.reset();
      _frameStopwatch!.start();

      if (_settings.showFps) {
        notifyListeners();
      }
    }
  }

  void _runSingleFrame() {
    if (_useStub) {
      if (_stub == null || !_stub!.isRunning) return;
      _stub!.runFrame();
      final pixels = _stub!.getVideoBuffer();
      if (pixels != null && onFrame != null) {
        onFrame!(pixels, _stub!.width, _stub!.height);
      }
    } else {
      if (_core == null || !_core!.isRunning) return;
      _core!.runFrame();
      if (_useTextureRendering) {
        _core!.textureBlit();
      } else {
        final pixels = _core!.getVideoBuffer();
        if (pixels != null && onFrame != null) {
          onFrame!(pixels, _core!.width, _core!.height);
        }
      }
    }
  }

  void _syncNativeRewindCapture() {
    if (!_useNativeFrameLoop || _core == null) return;
    _core!.frameLoopSetRewind(
      enabled: isRewindSupported,
      interval: _rewindCaptureInterval,
    );
  }

  void _initRewind() {
    if (_useStub || _core == null) {
      _rewindBufferReady = false;
      return;
    }
    if (!_settings.enableRewind) {
      final was = _rewindBufferReady;
      _rewindBufferReady = false;
      _core!.rewindDeinit();
      _syncNativeRewindCapture();
      if (was) notifyListeners();
      return;
    }

    final capturesPerSecond = 60.0 / _rewindCaptureInterval;
    final requested = (capturesPerSecond * _settings.rewindBufferSeconds)
        .round();
    final cap = rewindCapacityCap();
    final capacity = requested.clamp(12, cap);
    if (capacity < requested) {
      debugPrint('Rewind: capped to $capacity snapshots (device RAM)');
    }
    final result = _core!.rewindInit(capacity);
    final wasReady = _rewindBufferReady;
    _rewindBufferReady = (result == 0);
    if (!_rewindBufferReady) {
      debugPrint(
        'Rewind: init failed (code=$result, capacity=$capacity). '
        'Core may not expose serialization yet, or allocation failed.',
      );
      _core!.rewindDeinit();
    }
    _rewindCaptureCounter = 0;
    _syncNativeRewindCapture();
    if (wasReady != _rewindBufferReady) notifyListeners();
  }

  void startRewind() {
    if (!isRewindSupported) return;
    if (_state != EmulatorState.running || _core == null) return;
    final wasNative = _useNativeFrameLoop;
    if (wasNative) {
      _stopNativeFrameLoop();
    }

    _isRewinding = true;
    _rewindStepCounter = 0;
    _core!.setAudioEnabled(false);
    if (wasNative) {
      _startDartFrameLoop();
    }
    _performRewindStep();

    notifyListeners();
  }

  void stopRewind() {
    if (!_isRewinding) return;

    _isRewinding = false;
    if (_core != null) {
      _applyAudioSettings();
    }
    if (_canUseNativeFrameLoop && _state == EmulatorState.running) {
      _frameTimer?.cancel();
      _frameTimer = null;
      _startNativeFrameLoop();
    }

    notifyListeners();
  }

  void _performRewindStep() {
    if (_core == null || !_rewindBufferReady) return;

    final count = _core!.rewindCount();
    if (count <= 0) {
      debugPrint('Rewind buffer empty — auto-stopping rewind');
      stopRewind();
      return;
    }

    final popResult = _core!.rewindPop();
    if (popResult != 0) {
      debugPrint(
        'Rewind pop failed (result=$popResult) — auto-stopping rewind',
      );
      stopRewind();
      return;
    }
    if (_core == null || !_core!.isRunning) return;
    _core!.runFrame();

    if (_useTextureRendering) {
      _core!.textureBlit();
    } else {
      final pixels = _core!.getVideoBuffer();
      if (pixels != null && onFrame != null) {
        onFrame!(pixels, _core!.width, _core!.height);
      }
    }
  }

  static const int _gbRegSB = 0xFF01; 
  static const int _gbaRegSIODATA8 =
      0x0400012A; 
  static const int _gbaRegSIODATA32 =
      0x04000120; 
  static const int _gbaRegSIOCNT = 0x04000128; 

  void _pollLinkCable() {
    final lc = linkCable;
    if (lc == null || lc.state != LinkCableState.connected) return;
    if (_useStub || _core == null) return;
    final p = platform;
    if (p != GamePlatform.gb &&
        p != GamePlatform.gbc &&
        p != GamePlatform.gba) {
      return;
    }
    if (lc.hasIncomingData) {
      final status = _core!.linkGetTransferStatus();
      if (status >= 0) {
        final incoming = lc.consumeIncomingData();
        if (incoming >= 0) {
          _core!.linkExchangeData(incoming);
        }
      }
    }
    final status = _core!.linkGetTransferStatus();
    if (status == 1 && !lc.isAwaitingReply) {
      final outgoing = _readSioOutgoing();
      if (outgoing >= 0) {
        lc.sendSioData(outgoing);
      }
    }
  }

  int _readSioOutgoing() {
    if (_core == null) return -1;

    final plat = platform;
    if (plat == GamePlatform.gba) {
      final siocntHi = _core!.linkReadByte(_gbaRegSIOCNT + 1);
      if (siocntHi < 0) return -1;
      final is32bit = (siocntHi & (1 << 4)) != 0;
      return _core!.linkReadByte(is32bit ? _gbaRegSIODATA32 : _gbaRegSIODATA8);
    }
    return _core!.linkReadByte(_gbRegSB);
  }

  void setVolume(double volume) {
    if (_useStub) {
      _stub?.setVolume(volume);
    } else {
      _core?.setVolume(volume);
    }
  }

  void setAudioEnabled(bool enabled) {
    if (_useStub) {
      _stub?.setAudioEnabled(enabled);
    } else {
      _core?.setAudioEnabled(enabled);
    }
  }

  void setColorPalette(int paletteIndex, List<int> colors) {
    if (_useStub) {
      _stub?.setColorPalette(paletteIndex, colors);
    } else {
      _core?.setColorPalette(paletteIndex, colors);
    }
  }

  void setSgbBorders(bool enabled) {
    if (!_useStub) {
      _core?.setSgbBorders(enabled);
    }
  }

  bool get isCheatsSupported {
    if (_useStub) return false;
    return _core?.isCheatsSupported ?? false;
  }

  bool cheatReset() {
    if (_useStub || _core == null) return false;
    return _core!.cheatReset();
  }

  bool cheatSet(int index, bool enabled, String code) {
    if (_useStub || _core == null) return false;
    return _core!.cheatSet(index, enabled, code);
  }

  void setKeys(int keys) {
    final transformedKeys = _inputProfile.transformKeys(keys);
    if (kDebugMode && keys != 0) {
      debugPrint(
        'Input: EmulatorService.setKeys raw=0x${keys.toRadixString(16)} mapped=0x${transformedKeys.toRadixString(16)} profile=${_inputProfile.name} useStub=$_useStub core=${_core != null}',
      );
    }
    if (_useStub) {
      _stub?.setKeys(transformedKeys);
    } else {
      _core?.setKeys(transformedKeys);
    }
  }

  void setAnalog(double x, double y) {
    if (!_useStub) {
      _core?.setAnalog(x.toInt(), y.toInt());
    }
  }

  void pressKey(int key) {
    if (_useStub) {
      _stub?.pressKey(key);
    } else {
      _core?.pressKey(key);
    }
  }

  void releaseKey(int key) {
    if (_useStub) {
      _stub?.releaseKey(key);
    } else {
      _core?.releaseKey(key);
    }
  }

  Uint8List? getVideoBufferRaw() {
    if (_useStub) return _stub?.getVideoBuffer();
    return _core?.getVideoBuffer();
  }

  String? getStatePath(int slot) {
    if (_currentRom == null) return null;
    final romBase = p.basename(_currentRom!.path);
    final fileName = '$romBase.ss$slot';
    for (final dir in _allSaveDirectories(_currentRom!)) {
      final path = p.join(dir, fileName);
      if (File(path).existsSync()) return path;
    }
    final saveDir = _getRomSaveDir(_currentRom!);
    return p.join(saveDir, fileName);
  }

  String? getStateScreenshotPath(int slot) {
    if (_currentRom == null) return null;
    final romBase = p.basename(_currentRom!.path);
    final fileName = '$romBase.ss$slot.png';
    for (final dir in _allSaveDirectories(_currentRom!)) {
      final path = p.join(dir, fileName);
      if (File(path).existsSync()) return path;
    }
    final saveDir = _getRomSaveDir(_currentRom!);
    return p.join(saveDir, fileName);
  }

  Future<bool> saveState(int slot) async {
    final wasNative = _useNativeFrameLoop;
    if (wasNative) _stopNativeFrameLoop();

    bool success;
    if (_useStub) {
      success = _stub?.saveState(slot) ?? false;
    } else if (_core == null) {
      if (wasNative) _startNativeFrameLoop();
      return false;
    } else {
      success = _core!.saveState(slot);
    }
    if (success) {
      await _saveStateScreenshot(slot);
      final statePath = getStatePath(slot);
      final screenshotPath = getStateScreenshotPath(slot);
      if (statePath != null) _syncSaveToUserFolder(statePath);
      if (screenshotPath != null) _syncSaveToUserFolder(screenshotPath);
    }

    if (wasNative && _state == EmulatorState.running) _startNativeFrameLoop();
    return success;
  }

  Future<bool> loadState(int slot) async {
    final wasNative = _useNativeFrameLoop;
    if (wasNative) _stopNativeFrameLoop();

    if (_useStub) {
      final success = _stub?.loadState(slot) ?? false;
      if (success && _state == EmulatorState.paused) {
        _runSingleFrame();
      }
      if (wasNative && _state == EmulatorState.running) _startNativeFrameLoop();
      return success;
    }
    if (_core == null) {
      if (wasNative && _state == EmulatorState.running) _startNativeFrameLoop();
      return false;
    }
    final success = _core!.loadState(slot);
    if (success && _state == EmulatorState.paused) {
      _runSingleFrame();
    }

    if (wasNative && _state == EmulatorState.running) _startNativeFrameLoop();
    return success;
  }

  Future<void> _saveStateScreenshot(int slot) async {
    final path = getStateScreenshotPath(slot);
    if (path == null) return;

    final pixels = getVideoBufferRaw();
    if (pixels == null) return;

    final w = screenWidth;
    final h = screenHeight;

    try {
      final pixelsCopy = Uint8List.fromList(pixels);

      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixelsCopy,
        w,
        h,
        ui.PixelFormat.rgba8888,
        (image) => completer.complete(image),
      );
      final image = await completer.future;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      if (byteData != null) {
        await File(path).writeAsBytes(byteData.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('Error saving state screenshot: $e');
    }
  }

  Future<String?> captureScreenshot() async {
    if (_currentRom == null) return null;

    final pixels = getVideoBufferRaw();
    if (pixels == null) return null;

    final w = screenWidth;
    final h = screenHeight;

    try {
      final pixelsCopy = Uint8List.fromList(pixels);

      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixelsCopy,
        w,
        h,
        ui.PixelFormat.rgba8888,
        (image) => completer.complete(image),
      );
      final image = await completer.future;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      if (byteData == null) return null;

      final saveDir = _getRomSaveDir(_currentRom!);
      final romName = p.basenameWithoutExtension(_currentRom!.path);
      final ts = DateTime.now();
      final stamp =
          '${ts.year}${ts.month.toString().padLeft(2, '0')}'
          '${ts.day.toString().padLeft(2, '0')}_'
          '${ts.hour.toString().padLeft(2, '0')}'
          '${ts.minute.toString().padLeft(2, '0')}'
          '${ts.second.toString().padLeft(2, '0')}';
      final filePath = p.join(saveDir, '${romName}_$stamp.png');

      await File(filePath).writeAsBytes(byteData.buffer.asUint8List());
      debugPrint('Screenshot saved to $filePath');
      _syncSaveToUserFolder(filePath);
      return filePath;
    } catch (e) {
      debugPrint('Error capturing screenshot: $e');
      return null;
    }
  }

  void updateSettings(EmulatorSettings newSettings) {
    if (_settings == newSettings) return;

    final oldSettings = _settings;
    _settings = newSettings;
    if (oldSettings.volume != newSettings.volume ||
        oldSettings.enableSound != newSettings.enableSound) {
      _applyAudioSettings();
    }
    if (oldSettings.selectedColorPalette != newSettings.selectedColorPalette) {
      _applyColorPalette();
    }
    if (oldSettings.turboSpeed != newSettings.turboSpeed &&
        _speedMultiplier > 1.0) {
      _speedMultiplier = newSettings.turboSpeed;
      if (_useNativeFrameLoop) {
        _core?.frameLoopSetSpeed((_speedMultiplier * 100).round());
      }
      notifyListeners();
    }
    if (oldSettings.enableTurbo &&
        !newSettings.enableTurbo &&
        _speedMultiplier > 1.0) {
      _speedMultiplier = 1.0;
      if (_useNativeFrameLoop) {
        _core?.frameLoopSetSpeed(100);
      }
      notifyListeners();
    }
    if (oldSettings.enableRewind != newSettings.enableRewind) {
      if (newSettings.enableRewind &&
          !_useStub &&
          _core != null &&
          _state != EmulatorState.uninitialized &&
          _currentRom != null) {
        _initRewind();
      } else if (!newSettings.enableRewind) {
        if (_isRewinding) stopRewind();
        if (!_useStub && _core != null) {
          _core!.rewindDeinit();
          final wasReady = _rewindBufferReady;
          _rewindBufferReady = false;
          if (wasReady) notifyListeners();
        }
      }
    }
    if (oldSettings.rewindBufferSeconds != newSettings.rewindBufferSeconds &&
        newSettings.enableRewind &&
        !_useStub &&
        _core != null &&
        _state != EmulatorState.uninitialized &&
        _currentRom != null) {
      _initRewind();
    }
    if (_useNativeFrameLoop &&
        _core != null &&
        (oldSettings.enableRewind != newSettings.enableRewind ||
            oldSettings.rewindBufferSeconds !=
                newSettings.rewindBufferSeconds)) {
      _syncNativeRewindCapture();
    }
    if (oldSettings.enableSgbBorders != newSettings.enableSgbBorders) {
      if (!_useStub && _core != null) {
        _core!.setSgbBorders(newSettings.enableSgbBorders);
      }
    }
    if (oldSettings.autoSaveInterval != newSettings.autoSaveInterval &&
        _state == EmulatorState.running) {
      _startAutoSaveTimer();
    }
  }

  void _applyAudioSettings() {
    setAudioEnabled(_settings.enableSound);
    setVolume(_settings.enableSound ? _settings.volume : 0.0);
  }

  void _applyColorPalette() {
    final paletteIndex = _settings.selectedColorPalette;
    if (platform != GamePlatform.gb) {
      setColorPalette(-1, [0, 0, 0, 0]);
      return;
    }

    if (paletteIndex < 0 || paletteIndex >= GBColorPalette.palettes.length) {
      setColorPalette(-1, [0, 0, 0, 0]);
      return;
    }

    final palette = GBColorPalette.palettes[paletteIndex];
    final colors = palette.map((c) => 0xFF000000 | c).toList();
    setColorPalette(paletteIndex, colors);
  }

  void _startAutoSaveTimer() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;

    final interval = _settings.autoSaveInterval;
    if (interval <= 0) return;

    _autoSaveTimer = Timer.periodic(Duration(seconds: interval), (_) {
      if (_state == EmulatorState.running) {
        saveSram();
        debugPrint('Auto-save SRAM (every ${interval}s)');
      }
    });
  }

  void _stopAutoSaveTimer() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
  }

  Future<void> stop() async {
    if (_isRewinding) stopRewind();
    _frameLoopActive = false;
    _stopNativeFrameLoop();

    _frameTimer?.cancel();
    _frameTimer = null;
    _playTimeStopwatch.stop();
    _stopAutoSaveTimer();
    await saveSram();
    _sramSaveLock = Future.value();
    _isRewinding = false;
    _rewindBufferReady = false;
    _rewindCaptureCounter = 0;
    _rewindStepCounter = 0;

    if (_useStub) {
      _stub?.dispose();
      _stub = null;
    } else {
      _core?.dispose();
      _core = null;
    }
    _playTimeStopwatch.reset();
    _flushedPlayTimeSeconds = 0;
    _currentRom = null;
    _state = EmulatorState.uninitialized;
    _frameCount = 0;
    _currentFps = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _frameLoopActive = false;
    _frameTimer?.cancel();
    _autoSaveTimer?.cancel();
    try {
      if (_currentRom != null) {
        final saveDir = _getRomSaveDir(_currentRom!);
        final sramPath = p.join(
          saveDir,
          '${p.basenameWithoutExtension(_currentRom!.path)}.sav',
        );
        if (_useStub) {
          _stub?.saveSram(sramPath);
        } else {
          _core?.saveSram(sramPath);
        }
        _syncSaveToUserFolder(sramPath);
      }
    } catch (e) {
      debugPrint('dispose: SRAM flush failed — $e');
    }

    _stub?.dispose();
    _core?.dispose();
    super.dispose();
  }
}
