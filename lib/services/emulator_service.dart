import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/input_profile.dart';
import '../core/mgba_bindings.dart';
import '../core/mgba_stub.dart';
import '../utils/device_memory.dart';
import '../utils/graphics_quality.dart';
import '../utils/tv_detector.dart';
import '../models/game_rom.dart';
import '../models/emulator_settings.dart';
import 'bios_service.dart';
import 'link_cable_service.dart';
import 'rcheevos_client.dart';
import 'rom_folder_service.dart';

/// State of the emulator
enum EmulatorState { uninitialized, ready, running, paused, error }

/// Emulator service managing the mGBA core lifecycle
/// Falls back to stub implementation if native library unavailable
class EmulatorService extends ChangeNotifier {
  static const bool _disableTvGraphicsOptimizations = true;

  final MGBABindings _bindings = MGBABindings();
  MGBACore? _core;
  MGBAStub? _stub; // Fallback stub for testing
  bool _useStub = false;

  EmulatorState _state = EmulatorState.uninitialized;
  GameRom? _currentRom;
  EmulatorSettings _settings = const EmulatorSettings();
  String? _errorMessage;
  String? _saveDir;

  /// Public accessor for the app-internal save directory (for backup service).
  String? get saveDir => _saveDir;

  Timer? _frameTimer;
  Timer? _autoSaveTimer;

  /// Simple future-chaining mutex that serializes SRAM saves so concurrent
  /// callers (auto-save timer, pause, stop) never write to the same file at
  /// the same time.
  Future<void> _sramSaveLock = Future.value();
  Stopwatch? _frameStopwatch;
  int _frameCount = 0;
  double _currentFps = 0;
  double _speedMultiplier = 1.0;

  /// Guard flag: true only while the frame loop should be actively running.
  /// Checked at the very top of every timer tick so that already-enqueued
  /// callbacks become no-ops the instant [pause] / [stop] flips it to false.
  bool _frameLoopActive = false;

  /// True when the native (pthread) frame loop is actively driving
  /// emulation instead of the Dart Timer-based loop.
  bool _useNativeFrameLoop = false;

  /// NativeCallable handle for the native frame loop callback.
  /// Must stay alive as long as the native thread is running.
  NativeCallable<NativeFrameCallback>? _nativeFrameCallable;

  /// True when frames are delivered via Android Texture widget
  /// (ANativeWindow), bypassing decodeImageFromPixels entirely.
  bool _useTextureRendering = false;
  bool get useTextureRendering => _useTextureRendering;

  int _lastDisplayWidth = 0;
  int _lastDisplayHeight = 0;
  bool _holdLastDisplayDimensions = false;

  /// HLE-mode hint set by the BIOS gate. Read once per load to configure
  /// platform-specific options (e.g. melonDS direct-boot, PCSX BIOS = HLE)
  /// before the libretro core consumes its options at `retro_load_game`.
  bool _pendingHleMode = false;

  /// Enable texture rendering mode (call after creating the platform
  /// texture via the method channel).
  void setTextureRendering(bool enabled) {
    _useTextureRendering = enabled;
    debugPrint(
      'EmulatorService: texture rendering ${enabled ? "enabled" : "disabled"}',
    );
  }

  // Play time tracking — accumulates while the emulator is running
  final Stopwatch _playTimeStopwatch = Stopwatch();
  int _flushedPlayTimeSeconds = 0;

  /// Link cable service for network multiplayer (set externally).
  LinkCableService? linkCable;

  /// Native rcheevos client for per-frame achievement processing (set externally).
  RcheevosClient? rcheevosClient;

  /// Input profile for the currently loaded platform
  late InputProfile _inputProfile;

  /// Expose the native core for memory reading (used by RA runtime).
  MGBACore? get core => _core;

  /// Get the input profile for the current platform
  InputProfile get inputProfile => _inputProfile;

  /// Whether the native core supports link cable I/O register access.
  bool get isLinkSupported {
    if (_useStub) return _stub?.isLinkSupported ?? false;
    return _core?.isLinkSupported ?? false;
  }

  /// Rewind UI / input: native core, setting on, and ring buffer initialized
  /// successfully ([_rewindBufferReady]) after load.
  bool get isRewindSupported =>
      !_useStub && _settings.enableRewind && _rewindBufferReady;

  /// Whether [yage_core_rewind_init] succeeded for the current loaded game.
  bool get isRewindBufferReady => _rewindBufferReady;

  // Rewind state
  bool _rewindBufferReady = false;
  bool _isRewinding = false;
  int _rewindCaptureCounter = 0;
  int _rewindStepCounter = 0;
  static const int _rewindCaptureInterval = 5; // Capture every 5 frames
  static const int _rewindStepFrames =
      3; // Pop state every 3 frame-ticks while rewinding

  // Frame timing (GBA runs at ~59.7275 fps)
  static const Duration _baseFrameTime = Duration(microseconds: 16742);
  Duration get _targetFrameTime => Duration(
    microseconds: (_baseFrameTime.inMicroseconds / _speedMultiplier).round(),
  );

  // Callbacks
  void Function(Uint8List pixels, int width, int height)? onFrame;
  void Function(Int16List samples, int count)? onAudio;

  EmulatorState get state => _state;
  GameRom? get currentRom => _currentRom;
  EmulatorSettings get settings => _settings;
  String? get errorMessage => _errorMessage;
  double get currentFps => _currentFps;

  bool get _tvGraphicsOptimizationsOff =>
      _disableTvGraphicsOptimizations && TvDetector.isTV;

  /// Fraction of the emulation frame budget consumed by retro_run
  /// (EWMA cost / nominal frame interval). 0 when unknown (stub mode,
  /// Dart frame loop, or older native lib without the perf probes).
  /// Used by the TV adaptive-quality governor in game_display.dart.
  double get retroRunHeadroom {
    if (_useStub || !_useNativeFrameLoop) return 0;
    final c = _core;
    if (c == null) return 0;
    final ewmaUs = c.getRetroRunEwmaUs();
    final intervalUs = c.getFrameIntervalUs();
    if (ewmaUs <= 0 || intervalUs <= 0) return 0;
    return ewmaUs / intervalUs;
  }

  /// The core's nominal fps (e.g. ~59.73 for GBA, 50 for PAL cores).
  /// 0 when unknown.
  double get targetFps {
    if (_useStub) return 0;
    final intervalUs = _core?.getFrameIntervalUs() ?? 0;
    if (intervalUs <= 0) return 0;
    return 1e6 / intervalUs;
  }

  /// Last sharp-bilinear prescale factor pushed to the native blit
  /// (0 = never pushed this session — see [setDisplayPrescale]).
  int _lastPrescale = 0;

  /// Push the sharp-bilinear integer prescale factor to the native blit
  /// path (de-duplicated). Called by GameDisplay, which computes the
  /// factor from the on-screen physical scale.
  void setDisplayPrescale(int factor) {
    if (_useStub || _core == null) return;
    if (_tvGraphicsOptimizationsOff) factor = 1;
    if (factor == _lastPrescale) return;
    _lastPrescale = factor;
    _core!.setVideoPrescale(factor);
  }

  bool get isRunning => _state == EmulatorState.running;
  bool get isUsingStub => _useStub;
  double get speedMultiplier => _speedMultiplier;
  bool get isRewinding => _isRewinding;
  bool get isHleMode => _pendingHleMode;

  /// Total play time in the current session (seconds)
  int get sessionPlayTimeSeconds => _playTimeStopwatch.elapsed.inSeconds;

  /// Consume accumulated play time since last flush.
  /// Returns seconds played since the last call to this method.
  int flushPlayTime() {
    final total = _playTimeStopwatch.elapsed.inSeconds;
    final delta = total - _flushedPlayTimeSeconds;
    _flushedPlayTimeSeconds = total;
    return delta;
  }

  /// Set emulation speed (0.5x, 1x, 2x, 4x, etc.)
  void setSpeed(double speed) {
    _speedMultiplier = speed.clamp(0.25, 8.0);
    // Propagate to native frame loop if active
    if (_useNativeFrameLoop) {
      _core?.frameLoopSetSpeed((_speedMultiplier * 100).round());
    }
    notifyListeners();
  }

  /// Toggle fast forward between 1x and the configured turbo speed from settings
  void toggleFastForward() {
    if (_speedMultiplier > 1.0) {
      _speedMultiplier = 1.0;
    } else {
      _speedMultiplier = _settings.turboSpeed;
    }
    // Propagate to native frame loop if active
    if (_useNativeFrameLoop) {
      _core?.frameLoopSetSpeed((_speedMultiplier * 100).round());
    }
    notifyListeners();
  }

  int get screenWidth {
    if (_useStub) return _stub?.width ?? 240;
    final c = _core;
    if (c == null) return 240;
    if (_holdLastDisplayDimensions && _lastDisplayWidth > 0) {
      return _lastDisplayWidth;
    }
    // Use display dimensions when native frame loop/texture rendering is
    // active (may differ from core dimensions during SGB/NDS transitions).
    if (_useNativeFrameLoop || _useTextureRendering) {
      _cacheDisplayDimensions();
      return _lastDisplayWidth > 0 ? _lastDisplayWidth : c.displayWidth;
    }
    return c.width;
  }

  int get screenHeight {
    if (_useStub) return _stub?.height ?? 160;
    final c = _core;
    if (c == null) return 160;
    if (_holdLastDisplayDimensions && _lastDisplayHeight > 0) {
      return _lastDisplayHeight;
    }
    if (_useNativeFrameLoop || _useTextureRendering) {
      _cacheDisplayDimensions();
      return _lastDisplayHeight > 0 ? _lastDisplayHeight : c.displayHeight;
    }
    return c.height;
  }

  void _cacheDisplayDimensions() {
    final c = _core;
    if (c == null) return;
    final w = c.displayWidth;
    final h = c.displayHeight;
    if (w > 0 && h > 0) {
      _lastDisplayWidth = w;
      _lastDisplayHeight = h;
    }
  }

  void _resetDisplayDimensionCache() {
    _lastDisplayWidth = 0;
    _lastDisplayHeight = 0;
    _holdLastDisplayDimensions = false;
  }

  GamePlatform get platform {
    if (_useStub) return _stub?.platform ?? GamePlatform.unknown;
    return _core?.platform ?? GamePlatform.unknown;
  }

  /// Initialize the emulator service for the given [platform].
  ///
  /// Selects the appropriate libretro core (mGBA for GB/GBC/GBA, FCEUmm
  /// for NES, Snes9x2010 for SNES) and loads the native wrapper.
  /// If [platform] is `null`, defaults to mGBA (GB/GBA).
  Future<bool> initialize({GamePlatform? platform}) async {
    if (_state != EmulatorState.uninitialized) return true;

    try {
      // Select the right libretro core for the platform
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

      // Try to load native library first
      if (_bindings.load()) {
        _core = MGBACore(_bindings);

        // Load the input profile for this platform
        final effectivePlatform = platform ?? GamePlatform.gba;
        _inputProfile = getInputProfileForPlatform(effectivePlatform);
        debugPrint(
          'Loaded input profile: ${_inputProfile.name} for $effectivePlatform',
        );

        // If the native wrapper supports multi-core, tell it which core
        // to load before initializing. NES/SNES: set explicit path.
        // GB/GBC/GBA: clear path so we use default mGBA (avoids input regression).
        if (platform != null && _bindings.isCoreSelectionLoaded) {
          if (platform == GamePlatform.gb ||
              platform == GamePlatform.gbc ||
              platform == GamePlatform.gba) {
            // GB/GBC/GBA: clear path to use default mGBA (handles switch from other cores)
            _core!.setCoreLibrary('');
          } else {
            final coreLib = MGBABindings.platformCoreLibs[platform];
            if (coreLib != null) {
              _core!.setCoreLibrary(coreLib);
            }
          }
        }

        // Set up directories BEFORE initialize() so the core can find
        // system files (e.g. mupen64plus.ini) during retro_set_environment.
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

      // Native library not available at all
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
    // Delegate to BiosService so both the libretro core and the BIOS settings
    // tab read/write the same directory.  Falls back to the original layout
    // if path_provider somehow fails inside BiosService.
    final systemDirPath = await BiosService().getSystemDir();
    final systemDir = Directory(systemDirPath);
    if (!systemDir.existsSync()) {
      systemDir.createSync(recursive: true);
    }
    await _deploySystemFiles(systemDir.path);
    // OpenBIOS is the bundled PS1 fallback; deploying it here guarantees it
    // exists even if the user never opens the BIOS settings tab.
    await BiosService().deployOpenBiosFallback();
    return systemDir.path;
  }

  Future<void> _deploySystemFiles(String systemDirPath) async {
    // Deploy mupen64plus.ini for Mupen64Plus-Next core.
    //
    // mupen64plus-next searches for the ROM database at TWO locations
    // depending on how it was built / which working directory it inherits:
    //
    //   1. <system_dir>/mupen64plus.ini                 — libretro convention
    //   2. <system_dir>/Mupen64plus/mupen64plus.ini     — mupen's hard-coded
    //                                                     relative path
    //
    // The Android build of mupen64plus-libretro-nx prints
    //   "Unable to open rom database file './Mupen64plus/mupen64plus.ini'."
    // when it can only find (1), and then falls back to default CountPerOp /
    // CIC heuristics for ALL ROMs — breaking per-game timing for titles like
    // Goldeneye, Conker, Banjo-Tooie that need CountPerOp=3.
    //
    // We deploy to both locations so whichever path mupen searches is hit.
    Future<void> deployIniTo(String destPath) async {
      final iniFile = File(destPath);
      if (iniFile.existsSync()) return;
      try {
        final data = await rootBundle.load('native/mupen64plus.ini');
        final dir = Directory(p.dirname(destPath));
        if (!dir.existsSync()) dir.createSync(recursive: true);
        iniFile.writeAsBytesSync(data.buffer.asUint8List());
        debugPrint('Deployed mupen64plus.ini to $destPath');
      } catch (e) {
        debugPrint('Failed to deploy mupen64plus.ini to $destPath: $e');
      }
    }

    await deployIniTo(p.join(systemDirPath, 'mupen64plus.ini'));
    await deployIniTo(p.join(systemDirPath, 'Mupen64plus', 'mupen64plus.ini'));
  }

  /// Get the directory where save files are stored for a ROM.
  /// Uses the app-internal saves directory.
  String _getRomSaveDir(GameRom rom) {
    return _saveDir ?? p.dirname(rom.path);
  }

  /// Get the .sav file path for a ROM (battery/SRAM save) — stored next to the ROM
  String _getSramPath(GameRom rom) {
    final saveDir = _getRomSaveDir(rom);
    final saveName = p.basenameWithoutExtension(rom.path);
    return p.join(saveDir, '$saveName.sav');
  }

  /// Import a user-folder .sav into the app save directory before core load.
  /// Some cores (melonDS) read the save file inside retro_load_game(), so the
  /// internal copy has to exist before the generic SRAM bridge gets a chance.
  Future<void> _importSramFromUserFolderIfNeeded(GameRom rom) async {
    final saveName = '${p.basenameWithoutExtension(rom.path)}.sav';
    final internalSramPath = _getSramPath(rom);
    final internalFile = File(internalSramPath);
    final folderUri = _settings.userRomsFolderUri;

    debugPrint(
      'SaveTrace: pre-core SRAM import check platform=${rom.platform.name} '
      'save=$saveName internal=$internalSramPath '
      'internalExists=${internalFile.existsSync()} '
      'userFolder=${folderUri != null && folderUri.isNotEmpty}',
    );

    // Import .sav from user folder ONLY if no internal save exists yet.
    // This enables first-launch / cross-device sync (paste .sav into SAF folder →
    // fresh install or clear data → launch → get imported).  We intentionally skip
    // the import when an internal save is already present so that saves uploaded via
    // the web file manager (or made during a previous session) are never silently
    // overwritten by an older copy sitting in the SAF folder.
    if (folderUri != null &&
        folderUri.isNotEmpty &&
        !internalFile.existsSync()) {
      try {
        final copied = await RomFolderService.copySaveFromUserFolder(
          folderUri,
          saveName,
          internalSramPath,
        );
        if (copied) {
          final size = internalFile.existsSync()
              ? internalFile.lengthSync()
              : -1;
          debugPrint(
            'SaveTrace: imported SRAM from user folder save=$saveName '
            'bytes=$size',
          );
        } else {
          debugPrint('SaveTrace: no SRAM found in user folder for $saveName');
        }
      } catch (e) {
        debugPrint('SaveTrace: error importing SRAM from user folder: $e');
      }
    } else {
      debugPrint('SaveTrace: pre-core SRAM import skipped for $saveName');
    }
  }

  Future<void> _loadSram(GameRom rom) async {
    if (_useStub || _core == null) return;

    await _importSramFromUserFolderIfNeeded(rom);

    final saveName = '${p.basenameWithoutExtension(rom.path)}.sav';
    final internalSramPath = _getSramPath(rom);
    final internalFile = File(internalSramPath);

    debugPrint(
      'SaveTrace: loadSram start platform=${rom.platform.name} '
      'save=$saveName path=$internalSramPath '
      'exists=${internalFile.existsSync()} '
      'bytes=${internalFile.existsSync() ? internalFile.lengthSync() : -1}',
    );

    // melonDS owns cartridge SRAM internally and loads this exact .sav path
    // during retro_load_game()/retro_reset(). It intentionally reports no
    // RETRO_MEMORY_SAVE_RAM, so calling the generic SRAM bridge after load is
    // a no-op and produces misleading logs.
    if (rom.platform == GamePlatform.nds) {
      if (internalFile.existsSync()) {
        debugPrint(
          'SaveTrace: NDS SRAM ready for melonDS path=$internalSramPath '
          'bytes=${internalFile.lengthSync()}',
        );
      } else {
        debugPrint('SaveTrace: no NDS SRAM file found for ${rom.name}');
      }
      return;
    }

    final searchDirs = _allSaveDirectories(rom);

    for (final dir in searchDirs) {
      try {
        final sramPath = p.join(dir, saveName);
        if (File(sramPath).existsSync()) {
          final success = _core!.loadSram(sramPath);
          debugPrint('SaveTrace: loaded SRAM from $sramPath: $success');
          return;
        }
      } catch (e) {
        debugPrint('SaveTrace: error checking SRAM in $dir: $e');
      }
    }
    debugPrint('SaveTrace: no SRAM file found for ${rom.name}');
  }

  /// All directories where save files might live, in priority order.
  List<String> _allSaveDirectories(GameRom rom) {
    final dirs = <String>{};
    // 1. App-internal saves directory
    if (_saveDir != null) dirs.add(_saveDir!);
    // 2. Next to the ROM (for ROMs in internal storage)
    dirs.add(p.dirname(rom.path));
    return dirs.toList();
  }

  /// Save SRAM to .sav file.
  ///
  /// Uses a future-chaining lock so that concurrent callers (auto-save timer,
  /// pause, stop) are serialized — each waits for the previous write to finish
  /// before starting its own, preventing file corruption.
  Future<void> saveSram() {
    final previous = _sramSaveLock;
    final completer = Completer<void>();
    _sramSaveLock = completer.future;

    return previous
        .then((_) async {
          if (_useStub || _core == null || _currentRom == null) return;

          try {
            final sramPath = _getSramPath(_currentRom!);
            debugPrint(
              'SaveTrace: saveSram start platform=${_currentRom!.platform.name} '
              'path=$sramPath state=${_state.name}',
            );
            final success = _core!.saveSram(sramPath);
            final file = File(sramPath);
            debugPrint(
              'SaveTrace: saveSram result success=$success path=$sramPath '
              'exists=${file.existsSync()} '
              'bytes=${file.existsSync() ? file.lengthSync() : -1}',
            );
            if (success) _syncSaveToUserFolder(sramPath);
          } catch (e) {
            debugPrint('SaveTrace: error saving SRAM: $e');
          }
        })
        .whenComplete(() {
          completer.complete();
        });
  }

  /// Synchronously flush the battery save (SRAM) to disk.
  ///
  /// In-game saves only update the core's in-memory SRAM buffer; that buffer
  /// reaches the `.sav` file via [saveSram] (auto-save timer / [stop]) or this
  /// method. Use this on the app-background path, where the OS may kill the
  /// process before an async [saveSram] microtask gets a chance to run — the
  /// FFI write here completes before this call returns, so the save is durable
  /// even if the app is swiped away or reclaimed while backgrounded.
  ///
  /// MUST be called with the native frame loop stopped (e.g. right after
  /// [pause]) so the SRAM read does not race retro_run's SRAM writes.
  void flushSramSync() {
    if (_useStub || _core == null || _currentRom == null) return;
    try {
      final sramPath = _getSramPath(_currentRom!);
      final success = _core!.saveSram(sramPath);
      final file = File(sramPath);
      debugPrint(
        'SaveTrace: flushSramSync platform=${_currentRom!.platform.name} '
        'success=$success path=$sramPath '
        'exists=${file.existsSync()} '
        'bytes=${file.existsSync() ? file.lengthSync() : -1}',
      );
      // Keep any in-flight async saveSram() from later overwriting this fresh
      // write against a torn-down core.
      _sramSaveLock = Future.value();
      if (success) _syncSaveToUserFolder(sramPath);
    } catch (e) {
      debugPrint('SaveTrace: flushSramSync error: $e');
    }
  }

  static final _deviceChannel = MethodChannel(
    'com.yourmateapps.retropal/device',
  );

  /// Import a .sav file from an external path (e.g. file picker).
  /// Copies to internal storage, always naming the file after the ROM
  /// (basenameWithoutExtension(rom.path) + '.sav') so it loads correctly
  /// on next launch. Handles both file paths and content:// URIs (Android).
  /// Returns true on success.
  /// After import, saves sync to the user's ROM folder when configured.
  Future<bool> importSramFromFile(String sourcePathOrUri) async {
    if (_useStub || _core == null || _currentRom == null) return false;

    try {
      // Always use ROM-derived filename so save persists across sessions
      final sramPath = _getSramPath(_currentRom!);
      debugPrint(
        'SaveTrace: manual SRAM import start platform=${_currentRom!.platform.name} '
        'source=$sourcePathOrUri dest=$sramPath',
      );
      final saveDir = Directory(p.dirname(sramPath));
      if (!saveDir.existsSync()) {
        saveDir.createSync(recursive: true);
      }

      String? sourcePath = sourcePathOrUri;
      bool isTempFile = false;

      // On Android, file picker may return content:// URI — copy to a temp
      // location so we have a normal file path. Track it so we delete it after.
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

      // Drain any in-flight saveSram() already queued on the lock before we
      // stop the auto-save timer. Without this, a saveSram() that started
      // just before _stopAutoSaveTimer() could overwrite sramPath after we
      // copy the imported file into it.
      await _sramSaveLock;

      if (_currentRom!.platform == GamePlatform.nds && !_useStub) {
        final rom = _currentRom!;
        final wasRunning = _state == EmulatorState.running;
        final importedBytes = await sourceFile.length();
        debugPrint(
          'SaveTrace: NDS manual SRAM import will reload core '
          'source=$sourcePath bytes=$importedBytes dest=$sramPath',
        );

        _frameLoopActive = false;
        _stopNativeFrameLoop();
        _frameTimer?.cancel();
        _frameTimer = null;
        _stopAutoSaveTimer();

        try {
          // melonDS owns cartridge SRAM internally. If we copy over the .sav and
          // then call retro_reset(), the old cart SRAM manager can flush its
          // stale buffer back to the same path during LoadROM(). Dispose first,
          // then copy, then reload so melonDS opens the imported file fresh.
          _core?.dispose();
          _core = null;
          _currentRom = null;
          _state = EmulatorState.uninitialized;
          _resetDisplayDimensionCache();

          await sourceFile.copy(sramPath);
          final file = File(sramPath);
          debugPrint(
            'SaveTrace: NDS manual SRAM import copied after dispose '
            'exists=${file.existsSync()} '
            'bytes=${file.existsSync() ? file.lengthSync() : -1}',
          );

          if (isTempFile) {
            try {
              await sourceFile.delete();
            } catch (_) {}
            isTempFile = false;
          }

          final loaded = await loadRom(rom);
          debugPrint('SaveTrace: NDS manual SRAM import reload result=$loaded');
          if (!loaded) return false;
          if (wasRunning) start();
        } finally {
          if (isTempFile) {
            try {
              await sourceFile.delete();
            } catch (_) {}
          }
        }

        _syncSaveToUserFolder(sramPath);
        debugPrint('SaveTrace: manual SRAM import done from $sourcePathOrUri');
        return true;
      }

      // Stop the native frame loop and auto-save timer BEFORE writing SRAM.
      // The frame loop runs retro_run() on a native thread; calling
      // retro_get_memory_data() + fread() concurrently is a data race that
      // silently corrupts or discards the just-imported save.
      final wasNative = _useNativeFrameLoop;
      if (wasNative) _stopNativeFrameLoop();
      _stopAutoSaveTimer();

      try {
        // Overwrite the internal .sav and load it into core SRAM memory.
        await sourceFile.copy(sramPath);
        // Delete the temp copy now that the real destination has been written.
        if (isTempFile) {
          try {
            await sourceFile.delete();
          } catch (_) {}
        }
        final success = _core!.loadSram(sramPath);
        final file = File(sramPath);
        debugPrint(
          'SaveTrace: manual SRAM import load result success=$success '
          'exists=${file.existsSync()} '
          'bytes=${file.existsSync() ? file.lengthSync() : -1}',
        );
        if (!success) return false;

        // Reset the core. The frame loop is already stopped so retro_reset()
        // runs safely without racing against retro_run().
        _core!.reset();
        _applyAudioSettings();
        _applyColorPalette();
      } finally {
        // Restart the frame loop if it was running before the import.
        if (wasNative && _state == EmulatorState.running) {
          _startNativeFrameLoop();
        }
        _startAutoSaveTimer();
      }

      _syncSaveToUserFolder(sramPath);
      debugPrint('SaveTrace: manual SRAM import done from $sourcePathOrUri');
      return true;
    } catch (e) {
      debugPrint('SaveTrace: error importing SRAM: $e');
      return false;
    }
  }

  /// Sync a save file to the user's ROMs folder if one is configured.
  /// Fire-and-forget; failures are logged.
  void _syncSaveToUserFolder(String sourcePath) {
    final folderUri = _settings.userRomsFolderUri;
    if (folderUri == null || folderUri.isEmpty) {
      debugPrint('SaveTrace: user-folder sync skipped path=$sourcePath');
      return;
    }
    final file = File(sourcePath);
    debugPrint(
      'SaveTrace: user-folder sync queued path=$sourcePath '
      'exists=${file.existsSync()} '
      'bytes=${file.existsSync() ? file.lengthSync() : -1}',
    );
    unawaited(RomFolderService.copySaveToUserFolder(folderUri, sourcePath));
  }

  /// Battery-save files that some cores write directly into the save directory,
  /// alongside (or instead of) the RETRO_MEMORY_SAVE_RAM bridge that produces
  /// our `<rom>.sav`. The notable case is Beetle PSX memory card 1 (`.mcr`);
  /// the others are defensive coverage for cores that emit their own files.
  /// These are given the same backup / delete lifecycle as `<rom>.sav`.
  ///
  /// `.sav` itself is deliberately NOT in this set — it is owned by the
  /// dedicated SRAM bridge path and must not be double-handled here.
  static const Set<String> _coreManagedSaveExts = {
    '.srm',
    '.mcr',
    '.sra',
    '.eep',
    '.fla',
    '.mpk',
    '.bram',
    '.brm',
  };

  /// Whether [fileName] is a core-written battery save that belongs to the ROM
  /// whose name-without-extension is [romBase]. Matches `<romBase>.<ext>` and
  /// card-indexed variants like `<romBase>_1.<ext>` (underscore only, so e.g.
  /// "Sonic" never matches "Sonic 2"). Never matches the ROM itself, save
  /// states, or screenshots — their extensions are not in
  /// [_coreManagedSaveExts].
  bool _isCoreManagedSaveSibling(String fileName, String romBase) {
    if (!_coreManagedSaveExts.contains(p.extension(fileName).toLowerCase())) {
      return false;
    }
    final stem = p.basenameWithoutExtension(fileName).toLowerCase();
    final base = romBase.toLowerCase();
    return stem == base || stem.startsWith('${base}_');
  }

  /// All core-managed save files for [rom] across its save directories,
  /// de-duplicated by filename.
  List<File> _coreManagedSaveFiles(GameRom rom) {
    final romBase = p.basenameWithoutExtension(rom.path);
    final files = <File>[];
    final seen = <String>{};
    for (final dir in _allSaveDirectories(rom)) {
      try {
        final directory = Directory(dir);
        if (!directory.existsSync()) continue;
        for (final entity in directory.listSync()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (_isCoreManagedSaveSibling(name, romBase) && seen.add(name)) {
            files.add(entity);
          }
        }
      } catch (e) {
        debugPrint('SaveTrace: error scanning core-managed saves in $dir: $e');
      }
    }
    return files;
  }

  /// Back up any core-managed save files (e.g. PS1 memory card 1) to the user
  /// folder. MUST be called AFTER the core is disposed, because such files are
  /// only flushed to disk when the core deinits — reading them earlier would
  /// back up stale data.
  void _syncCoreManagedSavesToUserFolder(GameRom rom) {
    for (final file in _coreManagedSaveFiles(rom)) {
      debugPrint('SaveTrace: core-managed save sync path=${file.path}');
      _syncSaveToUserFolder(file.path);
    }
  }

  /// Restore core-managed save files from the user folder into the app save
  /// directory, so the core finds them when it loads. The counterpart to
  /// [_syncCoreManagedSavesToUserFolder]. Each file is fetched only when it is
  /// missing internally (i.e. effectively first launch / after a wipe), so the
  /// recursive SAF search runs at most once per game.
  ///
  /// Only `.mcr` / `.srm` are attempted — the single real case in this app is
  /// the PS1 (Beetle PSX) second memory card — and callers gate this to PS1 so
  /// no other platform pays the SAF-scan cost.
  Future<void> _importCoreManagedSavesIfNeeded(GameRom rom) async {
    final folderUri = _settings.userRomsFolderUri;
    if (folderUri == null || folderUri.isEmpty) return;
    final base = p.basenameWithoutExtension(rom.path);
    final saveDir = _getRomSaveDir(rom);
    for (final name in ['$base.mcr', '$base.srm']) {
      final dest = p.join(saveDir, name);
      if (File(dest).existsSync()) continue; // already present internally
      try {
        final copied = await RomFolderService.copySaveFromUserFolder(
          folderUri,
          name,
          dest,
        );
        if (copied) {
          debugPrint('SaveTrace: imported core-managed save $name from folder');
        }
      } catch (e) {
        debugPrint('SaveTrace: error importing core-managed save $name: $e');
      }
    }
  }

  /// Delete all save data for a game: SRAM (.sav), save states (.ss0-5),
  /// and save state thumbnails (.ss0.png-5.png).
  /// Returns the number of files deleted.
  Future<int> deleteSaveData(GameRom rom) async {
    int deleted = 0;
    final saveDir = _getRomSaveDir(rom);
    final baseName = p.basenameWithoutExtension(rom.path);
    final romBase = p.basename(rom.path);

    // Also check app-internal save dir in case saves were created there
    final dirs = <String>{saveDir};
    if (_saveDir != null && _saveDir != saveDir) {
      dirs.add(_saveDir!);
    }

    for (final dir in dirs) {
      // SRAM (.sav) — uses basenameWithoutExtension
      final sramFile = File(p.join(dir, '$baseName.sav'));
      if (sramFile.existsSync()) {
        try {
          sramFile.deleteSync();
          deleted++;
        } catch (e) {
          debugPrint('Failed to delete SRAM file ${sramFile.path}: $e');
        }
      }

      // Save states and thumbnails (slots 0-5) — use full basename to match native
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

      // Screenshots (timestamped PNGs matching <baseName>_*.png) and any
      // core-managed battery saves (e.g. PS1 memory card 1 .mcr).
      try {
        final directory = Directory(dir);
        if (directory.existsSync()) {
          for (final entity in directory.listSync()) {
            if (entity is File) {
              final name = p.basename(entity.path);
              final isScreenshot =
                  name.startsWith('${baseName}_') && name.endsWith('.png');
              final isCoreSave = _isCoreManagedSaveSibling(name, baseName);
              if (isScreenshot || isCoreSave) {
                try {
                  entity.deleteSync();
                  deleted++;
                } catch (e) {
                  debugPrint('Failed to delete save file ${entity.path}: $e');
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

  /// Load a ROM file
  Future<bool> loadRom(GameRom rom) async {
    // ── BIOS gate ─────────────────────────────────────────────────
    // For NDS / PS1 / Intellivision the libretro core needs BIOS files in
    // the system directory.  On Android TV the user must supply real BIOS;
    // on mobile we allow HLE (NDS) and OpenBIOS (PS1).
    if (BiosService.biosPlatforms.contains(rom.platform)) {
      final bios = BiosService();
      // Make sure OpenBIOS is in place before checking PS1 status.
      await bios.deployOpenBiosFallback();
      final gate = await bios.gateForLaunch(
        platform: rom.platform,
        isTv: TvDetector.isTV,
      );
      if (!gate.allowed) {
        _errorMessage = gate.blockReason;
        _state = EmulatorState.error;
        notifyListeners();
        return false;
      }
      _pendingHleMode = gate.usingHle;
    } else {
      _pendingHleMode = false;
    }

    // ── Stale-session teardown ────────────────────────────────────────
    // loadRom is only ever called from the home screen, and the normal
    // exit path runs stop() first (which nulls _currentRom and disposes
    // the core).  If we get here with a ROM still loaded, the previous
    // session ended abnormally (crash recovery, skipped stop()).  Cores
    // like mupen64plus-next cannot retro_load_game twice without a full
    // unload — doing so fails and surfaces as "Error loading ROM" on
    // every reload attempt.  Force a complete teardown so the load below
    // always starts from a clean core.
    if (_currentRom != null) {
      debugPrint(
        'EmulatorService: stale session for ${_currentRom!.name} detected '
        'on loadRom(${rom.name}) — forcing full core teardown',
      );
      _frameLoopActive = false;
      _stopNativeFrameLoop();
      _frameTimer?.cancel();
      _frameTimer = null;
      _stopAutoSaveTimer();
      _stub?.dispose();
      _stub = null;
      _core?.dispose();
      _core = null;
      _currentRom = null;
      _state = EmulatorState.uninitialized;
      _resetDisplayDimensionCache();
    }

    // Re-initialize when switching platforms (e.g. SNES→GBA or GBA→NES).
    // Also when _currentRom is null but we have core/stub — previous load may have failed.
    final platformChanged = _currentRom?.platform != rom.platform;
    if (platformChanged ||
        (_currentRom == null && (_core != null || _stub != null))) {
      _stub?.dispose();
      _stub = null;
      _core?.dispose();
      _core = null;
      _currentRom = null;
      _state = EmulatorState.uninitialized;
      _resetDisplayDimensionCache();
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

      // Native path
      final biosPath = _getBiosPath(rom.platform);
      if (biosPath != null && File(biosPath).existsSync()) {
        _core!.loadBIOS(biosPath);
      }

      // Apply platform-specific core options that the core reads at
      // retro_load_game time (must happen before loadROM below).
      _applyPlatformCoreOptions(rom.platform);

      // Apply SGB border setting before loading the ROM
      // (the core reads the option at load time — only relevant for GB)
      if (rom.platform == GamePlatform.gb || rom.platform == GamePlatform.gbc) {
        _core!.setSgbBorders(_settings.enableSgbBorders);
      }

      // Point the native core's save directory at the ROM's folder
      final romSaveDir = _getRomSaveDir(rom);
      _core!.setSaveDir(romSaveDir);

      // Some cores (notably melonDS) load cartridge saves directly inside
      // retro_load_game(), before the generic SRAM bridge can run.
      await _importSramFromUserFolderIfNeeded(rom);

      // PS1 (Beetle PSX) reads memory card 1 (.mcr) from the save directory
      // itself — it is not covered by the RETRO_MEMORY_SAVE_RAM bridge. Pull a
      // backed-up copy in before load. Gated to PS1 so no other platform pays
      // the SAF-scan cost.
      if (rom.platform == GamePlatform.ps1) {
        await _importCoreManagedSavesIfNeeded(rom);
      }

      if (!_core!.loadROM(rom.path)) {
        _errorMessage = 'Failed to load ROM: ${rom.name}';
        notifyListeners();
        return false;
      }

      // Load SRAM (battery save) if exists
      await _loadSram(rom);

      // Warm the JIT cache AFTER SRAM is restored. The native pre-roll runs a
      // few emulation frames; doing it here (rather than at the tail of the
      // native loadROM, before SRAM was injected) ensures the very first frame
      // already sees the battery save. Otherwise a game that probes its save
      // during early boot (e.g. Pokémon's Continue/New Game check) reads an
      // empty SRAM and shows "New Game" despite a valid .sav on disk.
      _core!.warmJit();

      // Apply audio settings to the native core
      _applyAudioSettings();

      // Apply color palette (for original GB games only)
      _applyColorPalette();

      // Apply mild "bright and natural" color tuning (software cores only;
      // hw direct-present cores are tuned by the Flutter compositor).
      _applyColorTuning(rom.platform);

      // Apply per-system "out of the box" 2D display FX (Auto mode only;
      // handhelds → LCD, consoles → CRT/NTSC, all 2D → art-scaling).
      _applyVideoFx(rom.platform);

      // Debug: dump the core's registered option keys so per-core presets
      // are verified against the real registry instead of guessed.
      _dumpCoreOptionsJson(rom.platform);

      // Rewind ring buffer (capacity capped by RAM — see [rewindCapacityCap]).
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
      _resetDisplayDimensionCache();
      // Native prescale resets to 1 per load (yage_video_apply_default_tuning);
      // clear the de-dup cache so GameDisplay's next push goes through.
      _lastPrescale = 0;
      // Reset input state so NES/SNES cores start with clean keys after platform switch
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

  /// Whether the load-time core presets for a 3D platform should target
  /// enhanced quality.
  ///
  /// Policy (see utils/graphics_quality.dart):
  ///  * Auto Optimized on phones/tablets → enhanced (higher internal
  ///    resolution, better filtering).
  ///  * Auto Optimized on Android TV → conservative native base (full
  ///    speed first); runtime adaptation on TV only raises the
  ///    final-scaling filter quality, never core options (those need a
  ///    reload to change safely; see docs/GRAPHICS_QUALITY.md).
  ///  * Authentic Pixel Mode → native presets everywhere.
  bool get _useEnhancedCorePresets =>
      resolveCorePreset(mode: _settings.graphicsMode, is3D: true) ==
      CoreGraphicsPreset.enhanced3d;

  /// Pushes the per-platform libretro core options that must be set before
  /// `retro_load_game`.  Called from [loadRom] right before the ROM is loaded.
  void _applyPlatformCoreOptions(GamePlatform platform) {
    final core = _core;
    if (core == null) return;
    final enhanced = _useEnhancedCorePresets;
    switch (platform) {
      case GamePlatform.nds:
        // ── Boot + screen layout ──────────────────────────────────────
        // Always direct-boot games. melonDS' full firmware boot path can stay
        // on a blank white screen on Android when any BIOS/firmware piece is
        // missing or rejected, even if the ROM itself has loaded successfully.
        core.setOption('melonds_boot_directly', 'enabled');
        // Default screen layout. On TV, always landscape (Left/Right).
        // On mobile, starts portrait (Top/Bottom) — game_screen.dart will push
        // a new value via setCoreOption when orientation flips.
        core.setOption(
          'melonds_screen_layout',
          TvDetector.isTV ? 'Left/Right' : 'Top/Bottom',
        );
        core.setOption('melonds_touch_mode', 'Touch');

        // ── Performance options (critical for TV / low-end devices) ────
        // Force DS mode — DSi adds ~10–20% CPU overhead from extra hardware
        // emulation and is unnecessary for the vast majority of DS ROMs.
        core.setOption('melonds_console_mode', 'DS');
        // ── 2D + 3D renderer pairing ────────────────────────────────────
        final useOpenGlRenderer = Platform.isAndroid;
        // OpenGL is the Android TV default: it moves 3D rasterisation and the
        // GL2D BG/OBJ compositor to GLES3. The libretro core forcibly disables
        // melonds_threaded_renderer whenever OpenGL is enabled, so do not set
        // both and pretend we have two independent renderer workers.
        core.setOption(
          'melonds_threaded_renderer',
          useOpenGlRenderer ? 'disabled' : 'enabled',
        );
        if (useOpenGlRenderer) {
          core.setOption('melonds_opengl_renderer', 'enabled');
          // Internal resolution + final filtering, by quality preset.
          //
          //  * Enhanced (Auto Optimized on phones/tablets): 2×–4× internal
          //    resolution + linear filtering, scaled by device tier (see
          //    ndsResolution below).  The core parses the leading digit of
          //    the value string (libretro.cpp: Clamp(value[0]-48, 0, 8))
          //    and GPU2D/GPU3D both honour GL_ScaleFactor, so the exact
          //    option strings below come straight from
          //    libretro_core_options.h.  Each step is 1× → k² fillrate; the
          //    tier keeps that within the GPU's budget (4× only on flagship
          //    RAM-class devices) for a dramatic sharpness gain.
          //  * Base (TV adaptive / Authentic Pixel): 1× native + nearest.
          //    Passing "1" or any unrecognised value silently falls back
          //    to 4× internally (verified in tv_logs_after.txt:
          //    viewport=2048×768 with scissor=256×384), so the default
          //    string must match the strcmp arms in the core exactly.
          // Internal resolution by device tier (Auto on phones/tablets;
          // maximum quality is the explicit goal for this device class):
          //   ultra  (~8 GB+ flagship)     → 4× native (1024×768/screen)
          //   high   (~6 GB midrange+)     → 3× native (768×576/screen)
          //   baseline (≤4 GB / unknown)   → 2× native (512×384/screen)
          // The baseline preserves the prior, proven behaviour so weaker
          // devices never regress. Strings come verbatim from
          // libretro_core_options.h: the core parses value[0]-'0' clamped
          // 0..8, and an unlisted string silently falls back to 4×, so only
          // these enumerated labels are safe. TV / Authentic stay native 1×.
          final String ndsResolution = !enhanced
              ? '1x native (256x192)'
              : switch (gpu3dTier()) {
                  Gpu3dTier.ultra => '4x native (1024x768)',
                  Gpu3dTier.high => '3x native (768x576)',
                  Gpu3dTier.baseline => '2x native (512x384)',
                };
          core.setOption('melonds_opengl_resolution', ndsResolution);
          core.setOption(
            'melonds_opengl_filtering',
            enhanced ? 'linear' : 'nearest',
          );
          // GPU 2D renderer (default on Android). The GL path moves BG/OBJ
          // raster + the 2D-over-3D composite onto the GPU (GPU2D::GLRenderer2D),
          // which the helper/JIT-bound 32-bit TV needs (~6-9 ms/frame of CPU 2D
          // work). It only engages when the GL 3D renderer is also active and
          // GLRenderer2D::Init() succeeds; otherwise the core falls back to the
          // CPU SoftRenderer automatically. Set to 'software' to force the CPU
          // path (e.g. to compare output or work around a GL issue).
          core.setOption('melonds_2d_renderer', 'opengl');
        }
        // For DS mode "Automatic" resolves to 10-bit anyway (NDS.cpp), so this
        // is the native NDS SPU bit-depth and perf-neutral vs Automatic.
        core.setOption('melonds_audio_bitrate', '10-bit');
        // Keep nearest-neighbour ("None"): it's the cheapest SPU path. Cosine/
        // Cubic add per-channel multiply-adds in the mixer hot loop, which on
        // the still-helper-heavy 32-bit TV core is enough to drop below full
        // speed — and when the emu falls behind, the frontend's elastic audio
        // slows playback to match, so the audio "sounds slow". Fidelity here
        // is gated on having CPU headroom we don't have on the weak SoC.
        core.setOption('melonds_audio_interpolation', 'None');
        // Belt-and-braces JIT pinning. arm64-v8a/x86_64 have optimized JIT
        // backends; armeabi-v7a now has a staged AArch32 backend with a small
        // native Thumb ALU/address slice, branch/memory helpers, and conservative
        // 8-instruction straight-line blocks, but it will not become a major FPS
        // lever until native memory fast paths replace most fallback calls.
        core.setOption('melonds_jit_enable', 'enabled');
        // 32 is the documented max — libretro_core_options.h enumerates
        // values 1..32 only for melonds_jit_block_size.  A previous
        // experiment set this to 64; the parser uses std::stoi() with no
        // clamp so 64 was accepted, but the option is untested above 32
        // and the measured gain was within noise.  Stay at the max safe
        // value.
        core.setOption('melonds_jit_block_size', '128');
        core.setOption('melonds_jit_branch_optimisations', 'enabled');
        core.setOption('melonds_jit_literal_optimisations', 'enabled');
        core.setOption('melonds_jit_fast_memory', 'enabled');
        // Disable optional subsystems that cost CPU/IO for almost no users.
        core.setOption('melonds_dsi_sdcard', 'disabled');
        // Use frontend firmware (no SAF lookup at boot) and don't randomize
        // the MAC every launch (avoids a small per-launch RNG cost).
        core.setOption('melonds_use_fw_settings', 'disabled');
        core.setOption('melonds_randomize_mac_address', 'disabled');
        // Screen gap: pin to zero — no compositing cost for the gap scanline.
        core.setOption('melonds_screen_gap', '0');
        break;
      case GamePlatform.sms:
      case GamePlatform.gg:
      case GamePlatform.md:
      case GamePlatform.sg1000:
        // Safe software-core performance defaults for every Android form
        // factor. These do not force a console region or remove optional
        // hardware features; they just keep expensive filters/overrides off
        // and allow automatic frame skipping only if the core falls badly
        // behind.
        core.setOption('genesis_plus_gx_blargg_ntsc_filter', 'disabled');
        core.setOption('genesis_plus_gx_lcd_filter', 'disabled');
        core.setOption('genesis_plus_gx_frameskip', 'auto');
        core.setOption('genesis_plus_gx_frameskip_threshold', '45');
        core.setOption('genesis_plus_gx_no_sprite_limit', 'disabled');
        core.setOption('genesis_plus_gx_enhanced_vscroll', 'disabled');
        core.setOption('genesis_plus_gx_overclock', '100');
        if (TvDetector.isTV) {
          // Genesis Plus GX is normally trivial for this TV CPU, but its
          // optional filters/expanded viewports are not free on the safe
          // non-texture path. Pin the TV preset to the cheapest full-speed
          // values while leaving phones/tablets on the user's quality settings.
          //
          // Values are the official Genesis Plus GX option keys/values:
          // docs.libretro.com/library/genesis_plus_gx/
          final String systemHw = switch (platform) {
            GamePlatform.gg => 'game gear',
            GamePlatform.sms => 'master system',
            GamePlatform.md => 'mega drive / genesis',
            GamePlatform.sg1000 => 'sg-1000 II',
            _ => 'auto',
          };
          core.setOption('genesis_plus_gx_system_hw', systemHw);
          core.setOption('genesis_plus_gx_region_detect', 'ntsc-u');
          core.setOption('genesis_plus_gx_overscan', 'disabled');
          core.setOption('genesis_plus_gx_left_border', 'disabled');
          core.setOption('genesis_plus_gx_gg_extra', 'disabled');
          core.setOption('genesis_plus_gx_ym2413', 'disabled');
          core.setOption('genesis_plus_gx_ym2413_core', 'mame');
          core.setOption('genesis_plus_gx_ym2612', 'mame (ym2612)');
          core.setOption('genesis_plus_gx_audio_filter', 'disabled');
        }
        break;
      case GamePlatform.ps1:
        // Beetle PSX HW has no HLE, but it ships a built-in OpenBIOS that it
        // uses when told to override the region BIOS. The correct core option
        // is `beetle_psx_hw_override_bios` with the enum value `openbios`
        // (NOT a `beetle_psx_hw_bios` filename — that key does not exist).
        // Only override when the user has no real Sony BIOS, so real dumps
        // take precedence when present.
        if (_pendingHleMode) {
          core.setOption('beetle_psx_hw_override_bios', 'openbios');
          // Best-effort skip of the BIOS boot animation. With OpenBIOS this
          // shows a non-authentic "cube" splash instead of the Sony logo; the
          // option is honoured by the official Sony BIOS and ignored by
          // OpenBIOS, so it only helps when a real dump is present.
          core.setOption('beetle_psx_hw_skip_bios', 'enabled');
        }
        // ── Renderer: use the SOFTWARE rasteriser, not the GL HW renderer ──
        //
        // Beetle PSX HW's hardware (GL) renderer drives our EGL HW-render
        // readback/present path, which is only partially functional for this
        // core. PS1 titles change their display resolution constantly
        // (240p ↔ 480i, menus vs gameplay), and on every change the HW path
        // hits the documented surface/viewport mismatch that presents
        // uninitialised VRAM as garbage "yellow/white lines" (see
        // native/yage_hw_render.c). The built-in software rasteriser renders
        // straight into the libretro video buffer — the same rock-solid path
        // NES/SNES/GBA use via the ANativeWindow blit — so games render
        // reliably across resolution switches.
        core.setOption('beetle_psx_hw_renderer', 'software');
        // The software renderer always runs at native PS1 resolution, so the
        // GL-only enhancement options (internal upscaling, internal-resolution
        // dithering, PGXP) do not apply. Pin native values explicitly so a
        // previous hardware/enhanced session cannot leak an incompatible value
        // through the persisted core-vars table (which would re-trigger the GL
        // path and the garbage frames).
        core.setOption('beetle_psx_hw_internal_resolution', '1x(native)');
        // Keep authentic native dithering on the software path; it is cheap
        // and matches real hardware output.
        core.setOption('beetle_psx_hw_dither_mode', '1x(native)');
        // PGXP geometry correction requires the hardware renderer.
        core.setOption('beetle_psx_hw_pgxp_mode', 'disabled');
        break;
      case GamePlatform.n64:
        // ── mupen64plus-next-libretro performance preset ────────────────
        //
        // NOTE ON KEY PREFIX: our mupen64plus-next build reports its option
        // keys with the legacy `mupen64plus-` prefix (verified against the
        // core-options dump in device logs), NOT `mupen64plus-next-`.
        // A wrong prefix is silent — the core just keeps every default.
        // That exact bug shipped once and disabled this whole preset (most
        // visibly FrameDuping, causing black-frame flicker in PAL titles
        // like Pokemon Stadium 2 on 60 Hz phones). If the core is ever
        // rebuilt, re-verify the prefix against the options dump.
        //
        // Defaults of the core target accuracy on a PC; the preset below
        // re-targets it for low-end ARM Android TVs and budget phones.
        //
        //  * cpucore = dynamic_recompiler  — already default on ARM but pin
        //    explicitly in case the build was made without DYNAREC (we want
        //    to fail loud on Loading rather than crawl at 5 fps).
        //  * rdp-plugin = gliden64         — fastest on mobile GPUs.  We do
        //    NOT use ParaLLEl-RDP / Angrylion because those are software
        //    rasterisers that would defeat the whole reason we're using a
        //    HW-render core on a Mali class GPU.
        //  * rsp-plugin = hle              — HLE RSP is ~2× faster than LLE
        //    and visually correct for 95% of titles.
        //  * ThreadedRenderer = True       — moves the GL submit work onto a
        //    second thread.  Same idea as melonds_threaded_renderer; the
        //    added input lag (1 frame) is invisible on TV.
        //  * FrameDuping = True            — duplicates the last frame when
        //    the GPU is idle, which produces smoother motion on display
        //    refreshes that aren't an integer multiple of the emulator's
        //    fps.  Critical on a 60 Hz TV running a 30-fps-locked N64 title.
        //  * EnableNativeResFactor = 1     — render at native (1× = 320×240
        //    for 4:3) instead of the default 640×480.  ½ the fillrate on
        //    the Mali GPU, often the bottleneck on TV SoCs.  The texture
        //    upscaler does the rest at present time.
        //  * Framerate = Original          — honour core fps (50 PAL /
        //    60 NTSC); Fullspeed mode forces 1-cycle CountPerOp and breaks
        //    many titles.
        //  * BilinearMode = standard       — cheapest bilinear path; 3point
        //    is a more accurate-to-N64 filter but ~30% more expensive.
        //  * HybridFilter = False          — cheap "hybrid integer scaling"
        //    filter is documented as slow on low-end GPUs in the option
        //    description; turn it off for TV.
        //  * MultiSampling = 0             — no MSAA on TV (huge GPU cost).
        //  * 43screensize = 640x480        — render viewport for 4:3 games.
        //  * 169screensize = 1280x720      — render viewport for widescreen.
        core.setOption('mupen64plus-cpucore', 'dynamic_recompiler');
        core.setOption('mupen64plus-rdp-plugin', 'gliden64');
        core.setOption('mupen64plus-rsp-plugin', 'hle');
        core.setOption('mupen64plus-ThreadedRenderer', 'True');
        core.setOption('mupen64plus-FrameDuping', 'True');
        core.setOption('mupen64plus-Framerate', 'Original');
        core.setOption('mupen64plus-43screensize', '640x480');
        core.setOption('mupen64plus-169screensize', '1280x720');
        if (enhanced) {
          // ── Phone/tablet max-quality preset (GLideN64), by device tier ──
          //  * EnableNativeResFactor — internal render scale over native
          //    320×240: baseline 2× (640×480), high 3× (960×720), ultra 4×
          //    (1280×960). Each step is ~k² fillrate; the tier keeps it
          //    within the GPU budget (4× only on flagship RAM-class devices).
          //    The sharpness gain over upscaled native is dramatic.
          //  * MultiSampling — 2 on baseline; 4 on high/ultra, where the
          //    higher internal res leaves edge aliasing the extra samples
          //    are worth resolving (tile GPUs resolve MSAA on-chip). Capped
          //    at 4: 8/16 cost real bandwidth for little visible gain.
          //  * BilinearMode 3point — N64's authentic 3-point filter, in
          //    every enhanced tier: visibly less blurry than 'standard'
          //    bilinear on texture edges (no diagonal smearing), cheap on
          //    phone GPUs.
          //  * HybridFilter stays False — its integer-scaling pass is
          //    documented slow on weaker GPUs and 3point already covers
          //    the sharpness goal.
          // Dynarec + HLE RSP (above) are kept in both presets. Values:
          // EnableNativeResFactor is an integer multiplier (1..8);
          // MultiSampling accepts 0/2/4/8/16.
          final (String resFactor, String msaa) = switch (gpu3dTier()) {
            Gpu3dTier.ultra => ('4', '4'),
            Gpu3dTier.high => ('3', '4'),
            Gpu3dTier.baseline => ('2', '2'),
          };
          core.setOption('mupen64plus-EnableNativeResFactor', resFactor);
          core.setOption('mupen64plus-MultiSampling', msaa);
          core.setOption('mupen64plus-BilinearMode', '3point');
          core.setOption('mupen64plus-HybridFilter', 'False');
        } else {
          // Conservative base (TV adaptive / Authentic Pixel): native res,
          // no MSAA, cheapest bilinear — the proven full-speed TV preset.
          core.setOption('mupen64plus-EnableNativeResFactor', '1');
          core.setOption('mupen64plus-MultiSampling', '0');
          core.setOption('mupen64plus-BilinearMode', 'standard');
          core.setOption('mupen64plus-HybridFilter', 'False');
        }
        // Don't override CountPerOp here — let mupen64plus.ini provide the
        // per-ROM value (deployed via _deploySystemFiles).  Setting it
        // globally would break titles that need CountPerOp=3.
        break;
      case GamePlatform.intv:
        // FreeIntv has no HLE option; no per-launch tuning needed.
        break;
      // ignore: no_default_cases
      default:
        break;
    }
  }

  /// Set a libretro core option at runtime (used by game_screen.dart to
  /// flip melonDS screen layout on orientation change).
  bool setCoreOption(String key, String value) {
    return _core?.setOption(key, value) ?? false;
  }

  /// Suppress (or restore) Firebase Analytics background telemetry while
  /// emulation is active.
  ///
  /// The Firebase Analytics SDK batches and uploads event logs on a periodic
  /// timer.  That timer fires a Dart microtask that triggers a GC cycle
  /// (~111 ms in profiler traces), producing a visible ~5 fps dip every
  /// couple of minutes during gameplay.  Disabling collection while the
  /// emulator runs stops both new-event collection AND the upload timer
  /// within the session, then we re-enable the moment the user pauses or
  /// exits the game.
  ///
  /// Crashlytics is intentionally left alone — we still want crash reports
  /// from in-game sessions.
  ///
  /// Guarded with try/catch because Firebase.initializeApp() has a 4-second
  /// timeout on the splash screen and may not be initialised in this session.
  static void _setFirebaseTelemetry({required bool enabled}) {
    // Fire-and-forget: the call is async under the hood but we don't need to
    // await it — best-effort suppression is fine.
    FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(enabled).catchError((
      Object e,
    ) {
      debugPrint(
        'EmulatorService: setAnalyticsCollectionEnabled($enabled) failed — $e',
      );
    });
  }

  /// Start emulation
  void start() {
    if (_state != EmulatorState.paused) return;
    if (!_useStub && _core == null) return;
    if (_useStub && _stub == null) return;

    _state = EmulatorState.running;
    _frameLoopActive = true;
    _frameStopwatch = Stopwatch()..start();
    _frameCount = 0;
    _playTimeStopwatch.start();
    // Suppress Firebase Analytics background upload timer while gaming to
    // avoid the ~111 ms GC pause it produces every couple of minutes.
    _setFirebaseTelemetry(enabled: false);
    // Set OpenSL buffer depth before the frame loop starts audio.
    // TV/HDMI output has ~80–120 ms hardware latency (vs ~40 ms on phone);
    // 6 buffers × 512 frames @ 32 768 Hz ≈ 94 ms queue depth prevents
    // underruns without adding CPU cost.
    _core?.setAudioBufferCount(TvDetector.isTV ? 6 : 4);
    _startFrameLoop();
    if (!_useNativeFrameLoop) {
      _holdLastDisplayDimensions = false;
    }
    _startAutoSaveTimer();
    notifyListeners();
  }

  /// Whether the native frame loop is available and should be used.
  /// Only for the real native core (not stub) and only on platforms
  /// that support pthread (Android, Linux, macOS — NOT Windows).
  bool get _canUseNativeFrameLoop {
    if (_useStub || _core == null) return false;
    if (Platform.isWindows) return false;
    return _core!.isFrameLoopSupported;
  }

  /// Pause emulation.
  ///
  /// SRAM is NOT flushed here. An in-game save only updates the core's
  /// in-memory SRAM buffer — it does NOT touch the `.sav` file. The buffer is
  /// written to disk only when:
  ///   1. The auto-save timer fires (if enabled by the user).
  ///   2. The ROM is unloaded via [stop] (exit game).
  ///   3. The app is backgrounded — the lifecycle handler calls
  ///      [flushSramSync] after pausing (see GameScreen). This is the case
  ///      that protects a save made just before the app is swiped away.
  Future<void> pause() async {
    if (_state != EmulatorState.running) return;

    // Stop rewind if active
    if (_isRewinding) stopRewind();

    // Deactivate the frame loop guard first so any already-enqueued timer
    // callbacks become no-ops before we update the rest of the state.
    _frameLoopActive = false;
    _state = EmulatorState.paused;

    _cacheDisplayDimensions();
    _holdLastDisplayDimensions =
        _lastDisplayWidth > 0 && _lastDisplayHeight > 0;

    // Stop native frame loop if active (blocks until thread exits)
    _stopNativeFrameLoop();

    _frameTimer?.cancel();
    _frameTimer = null;
    _playTimeStopwatch.stop();
    _stopAutoSaveTimer();
    // Restore Analytics collection now that gameplay is suspended.
    _setFirebaseTelemetry(enabled: true);

    notifyListeners();
  }

  /// Toggle pause/resume
  void togglePause() {
    if (_state == EmulatorState.running) {
      pause();
    } else if (_state == EmulatorState.paused) {
      start();
    }
  }

  /// Reset the emulator
  void reset() {
    // Must stop native frame loop before resetting the core —
    // retro_reset() and retro_run() must not execute concurrently.
    final wasNative = _useNativeFrameLoop;
    if (wasNative) _stopNativeFrameLoop();

    if (_useStub) {
      _stub?.reset();
    } else {
      _core?.reset();
    }
    if (_state == EmulatorState.paused) {
      _runSingleFrameIfSafe('reset');
    }

    // Restart native frame loop
    if (wasNative && _state == EmulatorState.running) {
      _startNativeFrameLoop();
    }
  }

  void _startFrameLoop() {
    // Prefer native (pthread) frame loop on supported platforms.
    // This moves emulation to a dedicated thread, keeping the Dart/UI
    // thread free for layout and painting.  The native thread signals
    // Dart at ~60 Hz for display updates regardless of turbo speed.
    if (_canUseNativeFrameLoop && !_isRewinding) {
      _startNativeFrameLoop();
      return;
    }

    // Fallback: Dart Timer-based loop (stub mode, rewind, Windows)
    _startDartFrameLoop();
  }

  /// Start the Dart Timer-based frame loop (legacy fallback).
  void _startDartFrameLoop() {
    _frameTimer?.cancel();
    _frameTimer = null;
    rcheevosClient?.setExternalFrameProcessing(false);
    _lastFrameTime = DateTime.now();
    _frameAccumulator = Duration.zero;

    // Adaptive frame loop: instead of a 1 ms periodic timer that fires
    // ~1000 times/sec (with ~940 no-ops), schedule each tick to wake up
    // right when the next frame is due. At 1× speed this means ~60
    // callbacks/sec; at 8× turbo ~480/sec — dramatically less CPU waste.
    _scheduleNextTick();
  }

  /// Start the native (pthread) frame loop.
  void _startNativeFrameLoop() {
    if (_useNativeFrameLoop) return; // already running

    // Create NativeCallable.listener — invocations from the native thread
    // are posted to the Dart event loop automatically.
    _nativeFrameCallable?.close();
    _nativeFrameCallable = NativeCallable<NativeFrameCallback>.listener(
      _onNativeFrameReady,
    );

    // Configure native thread parameters
    final core = _core!;
    core.frameLoopSetSpeed((_speedMultiplier * 100).round());
    _syncNativeRewindCapture();
    core.frameLoopSetRcheevos(enabled: rcheevosClient != null);

    final ok = core.startFrameLoop(_nativeFrameCallable!.nativeFunction);
    if (ok) {
      _useNativeFrameLoop = true;
      rcheevosClient?.setExternalFrameProcessing(true);
      debugPrint('EmulatorService: using native frame loop');
    } else {
      // Fall back to Dart Timer
      debugPrint(
        'EmulatorService: native frame loop failed, falling back to Dart Timer',
      );
      _nativeFrameCallable?.close();
      _nativeFrameCallable = null;
      rcheevosClient?.setExternalFrameProcessing(false);
      _startDartFrameLoop();
    }
  }

  /// Stop the native frame loop (blocks until thread exits).
  void _stopNativeFrameLoop() {
    if (!_useNativeFrameLoop) return;
    _core?.stopFrameLoop();
    _nativeFrameCallable?.close();
    _nativeFrameCallable = null;
    _useNativeFrameLoop = false;
    rcheevosClient?.setExternalFrameProcessing(false);
  }

  /// Called at ~60 Hz from the native thread (via NativeCallable.listener).
  /// Runs on the Dart event loop — safe to call Flutter APIs.
  void _onNativeFrameReady(int framesRun) {
    if (!_frameLoopActive || !_useNativeFrameLoop) return;

    bool displayDimensionsChanged = false;
    final c = _core;
    if (c != null) {
      final w = c.displayWidth;
      final h = c.displayHeight;
      if (w > 0 && h > 0) {
        displayDimensionsChanged =
            w != _lastDisplayWidth || h != _lastDisplayHeight;
        _lastDisplayWidth = w;
        _lastDisplayHeight = h;
        if (_holdLastDisplayDimensions) {
          _holdLastDisplayDimensions = false;
          displayDimensionsChanged = true;
        }
      }
    }

    // ── Read display buffer (only when NOT using texture rendering) ──
    // With texture rendering the native frame loop blits directly to the
    // ANativeWindow — no Dart-side buffer copy needed.
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

    if (displayDimensionsChanged) {
      notifyListeners();
    }

    rcheevosClient?.drainPendingEvents();

    // ── Link cable polling ──
    // Native side now throttles this callback to 1/3 frames (~20 Hz at
    // full speed), so polling here is at link-cable-safe rate already.
    _pollLinkCable();

    // ── FPS read + notify ──
    // Native callback comes in at ~20 Hz; we throttle the FPS overlay
    // refresh further to ~2 Hz so a Widget rebuild doesn't fire every
    // callback even when the overlay value rarely changes.
    _frameTickCounter++;
    if (_frameTickCounter >= 10) {
      _frameTickCounter = 0;
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
  }

  int _frameTickCounter = 0;

  /// Schedule the next frame tick using [Future.delayed] with a calculated
  /// sleep duration, preserving the accumulator-based catch-up model.
  void _scheduleNextTick() {
    if (!_frameLoopActive || _state != EmulatorState.running) return;

    final now = DateTime.now();
    final elapsed = now.difference(_lastFrameTime);
    _lastFrameTime = now;
    _frameAccumulator += elapsed;

    // Run frames to catch up, but cap at 3 to avoid spiral of death
    int framesRun = 0;
    while (_frameLoopActive &&
        _frameAccumulator >= _targetFrameTime &&
        framesRun < 3) {
      _runFrame();
      _frameAccumulator -= _targetFrameTime;
      framesRun++;
    }

    // If we're way behind, reset accumulator to avoid permanent catch-up
    if (_frameAccumulator > _targetFrameTime * 5) {
      _frameAccumulator = Duration.zero;
    }

    // Bail if the loop was deactivated during frame execution
    if (!_frameLoopActive) return;

    // Calculate how long to sleep until the next frame is due.
    // If the accumulator already exceeds a frame time (we're behind),
    // schedule immediately (Duration.zero) so we catch up ASAP.
    final remaining = _targetFrameTime - _frameAccumulator;
    final delay = remaining > Duration.zero ? remaining : Duration.zero;

    // Use a one-shot Timer so we get a concrete Timer reference we can
    // cancel synchronously from pause()/stop().
    _frameTimer = Timer(delay, _scheduleNextTick);
  }

  DateTime _lastFrameTime = DateTime.now();
  Duration _frameAccumulator = Duration.zero;

  void _runFrame() {
    // Bail out immediately if the loop was deactivated between iterations
    // (e.g. pause() or stop() called while we were mid-catch-up).
    if (!_frameLoopActive) return;

    // ── Rewind mode: step backward through ring buffer ──
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

    // ── Normal frame execution ──
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
        // Zero-copy: blit directly to ANativeWindow surface.
        // No Dart-side buffer copy, no decodeImageFromPixels.
        _core!.textureBlit();
      } else {
        final pixels = _core!.getVideoBuffer();
        if (pixels != null && onFrame != null) {
          onFrame!(pixels, _core!.width, _core!.height);
        }
      }

      // Note: Audio is now handled natively by OpenSL ES on Android
      // No need to process audio buffer in Dart

      // Capture rewind snapshot every N frames
      if (isRewindSupported) {
        _rewindCaptureCounter++;
        if (_rewindCaptureCounter >= _rewindCaptureInterval) {
          _rewindCaptureCounter = 0;
          _core!.rewindPush();
        }
      }

      // ── Link Cable SIO polling ──
      _pollLinkCable();

      // ── RetroAchievements per-frame processing ──
      rcheevosClient?.doFrame();
    }

    _updateFps();
  }

  void _updateFps() {
    // Calculate FPS — update every 500ms for a responsive counter
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

  void _runSingleFrameIfSafe(String reason) {
    if (_useTextureRendering && !_useStub) {
      debugPrint(
        'EmulatorService: skipped $reason single-frame refresh for '
        'texture-rendered core',
      );
      return;
    }
    _runSingleFrame();
  }

  // ── Rewind ──

  /// Push rewind capture flags to the pthread frame loop (no-op if not using it).
  void _syncNativeRewindCapture() {
    if (!_useNativeFrameLoop || _core == null) return;
    _core!.frameLoopSetRewind(
      enabled: isRewindSupported,
      interval: _rewindCaptureInterval,
    );
  }

  /// Initialize the rewind ring buffer based on current settings.
  /// Call after a ROM is loaded and the native state size is known.
  /// Capacity is capped by device memory to avoid OOM on low-RAM devices.
  void _initRewind() {
    if (_useStub || _core == null) {
      _rewindBufferReady = false;
      return;
    }
    // NDS save-state snapshots are 6–8 MB each (full ARM9 + ARM7 memory maps).
    // Even a 10-second rewind buffer would need ~500 MB — impractical on TV
    // devices where RAM is shared with the OS and display server.
    if (_currentRom?.platform == GamePlatform.nds && TvDetector.isTV) {
      final was = _rewindBufferReady;
      _rewindBufferReady = false;
      _core!.rewindDeinit();
      _syncNativeRewindCapture();
      if (was) notifyListeners();
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

  /// Start rewinding (call while the rewind button is held).
  void startRewind() {
    if (!isRewindSupported) return;
    if (_state != EmulatorState.running || _core == null) return;

    // Stop native frame loop — rewind needs Dart-side step control
    final wasNative = _useNativeFrameLoop;
    if (wasNative) {
      _stopNativeFrameLoop();
    }

    _isRewinding = true;
    _rewindStepCounter = 0;

    // Mute audio during rewind to avoid garbled sound
    _core!.setAudioEnabled(false);

    // Start Dart Timer fallback for rewind stepping
    if (wasNative) {
      _startDartFrameLoop();
    }

    // Perform an immediate first step for instant feedback
    _performRewindStep();

    notifyListeners();
  }

  /// Stop rewinding (call when the rewind button is released).
  void stopRewind() {
    if (!_isRewinding) return;

    _isRewinding = false;

    // Restore audio settings
    if (_core != null) {
      _applyAudioSettings();
    }

    // Switch back to native frame loop if available.
    // The Dart Timer loop was started for rewind stepping — kill it and
    // restart the native thread now that normal emulation resumes.
    if (_canUseNativeFrameLoop && _state == EmulatorState.running) {
      _frameTimer?.cancel();
      _frameTimer = null;
      _startNativeFrameLoop();
    }

    notifyListeners();
  }

  /// Pop one state from the rewind buffer and display it.
  ///
  /// Automatically stops rewinding when the buffer is exhausted or the pop
  /// fails, preventing repeated no-op calls and potential stale-frame display.
  void _performRewindStep() {
    if (_core == null || !_rewindBufferReady) return;

    final count = _core!.rewindCount();
    if (count <= 0) {
      // Buffer exhausted — stop rewinding so the user gets clear feedback
      // instead of silently sitting on the last frame.
      debugPrint('Rewind buffer empty — auto-stopping rewind');
      stopRewind();
      return;
    }

    final popResult = _core!.rewindPop();
    if (popResult != 0) {
      // Pop failed (corrupt buffer, internal error, etc.) — stop rewinding
      // to avoid rendering frames from an unknown state.
      debugPrint(
        'Rewind pop failed (result=$popResult) — auto-stopping rewind',
      );
      stopRewind();
      return;
    }

    // Pop succeeded — run one frame to produce video output from the
    // restored state. Re-check _core since stopRewind path above may
    // have been triggered by a concurrent pause.
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

  // ── Link Cable ──

  /// Poll the SIO registers and exchange data with the link cable peer.
  // ── Link Cable SIO register addresses ──
  // GB / GBC
  static const int _gbRegSB = 0xFF01; // Serial transfer data
  // GBA (Normal / Multi-player modes)
  static const int _gbaRegSIODATA8 =
      0x0400012A; // 8-bit serial data / multi-player send
  static const int _gbaRegSIODATA32 =
      0x04000120; // 32-bit serial data (lo halfword)
  static const int _gbaRegSIOCNT = 0x04000128; // Serial control

  /// Called once per frame when a [LinkCableService] is connected.
  /// Link cable is only supported for GB/GBC/GBA platforms.
  void _pollLinkCable() {
    final lc = linkCable;
    if (lc == null || lc.state != LinkCableState.connected) return;
    if (_useStub || _core == null) return;
    // Link cable is only for GB/GBC/GBA
    final p = platform;
    if (p != GamePlatform.gb &&
        p != GamePlatform.gbc &&
        p != GamePlatform.gba) {
      return;
    }

    // If the peer sent us a byte and a transfer is pending, inject it
    if (lc.hasIncomingData) {
      final status = _core!.linkGetTransferStatus();
      if (status >= 0) {
        // Exchange: write incoming byte, get outgoing byte, complete transfer
        final incoming = lc.consumeIncomingData();
        if (incoming >= 0) {
          _core!.linkExchangeData(incoming);
        }
      }
    }

    // If a transfer is pending on our side (master clock), send it out
    final status = _core!.linkGetTransferStatus();
    if (status == 1 && !lc.isAwaitingReply) {
      final outgoing = _readSioOutgoing();
      if (outgoing >= 0) {
        lc.sendSioData(outgoing);
      }
    }
  }

  /// Read the outgoing serial byte from the correct I/O register
  /// for the current platform.
  int _readSioOutgoing() {
    if (_core == null) return -1;

    final plat = platform;
    if (plat == GamePlatform.gba) {
      // GBA: check SIOCNT bit 12 to determine 8-bit vs 32-bit Normal mode.
      // SIOCNT is a 16-bit register at 0x04000128.  Bit 12 lives in the
      // high byte (0x04000129), at bit 4 of that byte.
      // In Multi-player mode the send register is at the same address as
      // SIODATA8, so 0x0400012A covers both Normal-8 and Multi-player.
      final siocntHi = _core!.linkReadByte(_gbaRegSIOCNT + 1);
      if (siocntHi < 0) return -1;

      // Bit 12 of SIOCNT (bit 4 in the high byte): 0 = 8-bit, 1 = 32-bit.
      final is32bit = (siocntHi & (1 << 4)) != 0;
      return _core!.linkReadByte(is32bit ? _gbaRegSIODATA32 : _gbaRegSIODATA8);
    }

    // GB / GBC: read from SB register
    return _core!.linkReadByte(_gbRegSB);
  }

  /// Set audio volume (0.0 = mute, 1.0 = full)
  void setVolume(double volume) {
    if (_useStub) {
      _stub?.setVolume(volume);
    } else {
      _core?.setVolume(volume);
    }
  }

  /// Enable or disable audio
  void setAudioEnabled(bool enabled) {
    if (_useStub) {
      _stub?.setAudioEnabled(enabled);
    } else {
      _core?.setAudioEnabled(enabled);
    }
  }

  /// Set color palette for original GB games
  /// Pass paletteIndex = -1 to disable palette remapping
  void setColorPalette(int paletteIndex, List<int> colors) {
    if (_useStub) {
      _stub?.setColorPalette(paletteIndex, colors);
    } else {
      _core?.setColorPalette(paletteIndex, colors);
    }
  }

  /// Enable or disable SGB (Super Game Boy) border rendering.
  /// Must be called before loadRom for the change to take effect.
  void setSgbBorders(bool enabled) {
    if (!_useStub) {
      _core?.setSgbBorders(enabled);
    }
  }

  // ── Cheat Codes ──

  /// Whether the loaded core supports cheat codes.
  bool get isCheatsSupported {
    if (_useStub) return false;
    return _core?.isCheatsSupported ?? false;
  }

  /// Clear all active cheats. Returns true on success.
  bool cheatReset() {
    if (_useStub || _core == null) return false;
    return _core!.cheatReset();
  }

  /// Set a cheat code at [index]. Pass [enabled] to toggle.
  bool cheatSet(int index, bool enabled, String code) {
    if (_useStub || _core == null) return false;
    return _core!.cheatSet(index, enabled, code);
  }

  /// Set key states
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

  /// Set analog stick axes (for N64 and similar cores).
  /// x, y should be in the range [-32768.0, 32767.0].
  void setAnalog(double x, double y) {
    if (!_useStub) {
      _core?.setAnalog(x.toInt(), y.toInt());
    }
    // Stub doesn't support analog
  }

  /// Set the right analog stick axes.
  ///
  /// Used by cores that expose keypad/touch helpers on the right stick
  /// (FreeIntv keypad digits, melonDS touch joystick, etc.).
  void setRightAnalog(double x, double y) {
    if (!_useStub) {
      _core?.setAnalogIndex(1, x.toInt(), y.toInt());
    }
    // Stub doesn't support analog
  }

  /// Send a touch event to the core (NDS stylus / PS1 lightgun-style cores).
  /// Coordinates are libretro pointer coordinates (-32767..32767).
  /// The caller is responsible for translating screen pixels.
  void setTouch(int x, int y, bool pressed) {
    if (_useStub) return;
    _core?.setTouch(x, y, pressed);
  }

  /// Press a key
  void pressKey(int key) {
    if (_useStub) {
      _stub?.pressKey(key);
    } else {
      _core?.pressKey(key);
    }
  }

  /// Release a key
  void releaseKey(int key) {
    if (_useStub) {
      _stub?.releaseKey(key);
    } else {
      _core?.releaseKey(key);
    }
  }

  /// Get the current video buffer (raw RGBA pixels).
  /// When the native frame loop was recently active, prefers the display
  /// buffer snapshot (which is always a complete frame).
  Uint8List? getVideoBufferRaw() {
    if (_useStub) return _stub?.getVideoBuffer();
    return _core?.getVideoBuffer();
  }

  /// Get the save state file path for a slot — stored next to the ROM.
  /// Uses full ROM filename (e.g. "Game.nes.ss0") to match native libretro.
  /// Searches all known save directories for an existing file; if none found,
  /// returns a path in the primary save directory (for creating new saves).
  String? getStatePath(int slot) {
    if (_currentRom == null) return null;
    final romBase = p.basename(_currentRom!.path);
    final fileName = '$romBase.ss$slot';

    // Search for existing state file
    for (final dir in _allSaveDirectories(_currentRom!)) {
      final path = p.join(dir, fileName);
      if (File(path).existsSync()) return path;
    }
    // Default: write to primary save dir
    final saveDir = _getRomSaveDir(_currentRom!);
    return p.join(saveDir, fileName);
  }

  /// Get the screenshot file path for a save state slot.
  /// Uses full ROM filename to match native save state naming.
  /// Searches all known save directories for an existing file.
  String? getStateScreenshotPath(int slot) {
    if (_currentRom == null) return null;
    final romBase = p.basename(_currentRom!.path);
    final fileName = '$romBase.ss$slot.png';

    // Search for existing screenshot
    for (final dir in _allSaveDirectories(_currentRom!)) {
      final path = p.join(dir, fileName);
      if (File(path).existsSync()) return path;
    }
    // Default: write to primary save dir
    final saveDir = _getRomSaveDir(_currentRom!);
    return p.join(saveDir, fileName);
  }

  /// Save state to slot (also captures a screenshot thumbnail)
  Future<bool> saveState(int slot) async {
    // Pause native frame loop to prevent concurrent core access
    final wasNative = _useNativeFrameLoop;
    final statePath = getStatePath(slot);
    debugPrint(
      'SaveTrace: saveState start slot=$slot platform=${platform.name} '
      'state=${_state.name} wasNative=$wasNative texture=$_useTextureRendering '
      'path=$statePath',
    );
    if (wasNative) {
      debugPrint('SaveTrace: saveState stopping native frame loop');
      _stopNativeFrameLoop();
    }

    bool success;
    if (_useStub) {
      success = _stub?.saveState(slot) ?? false;
    } else if (_core == null) {
      debugPrint('SaveTrace: saveState failed because core is null');
      if (wasNative) _startNativeFrameLoop();
      return false;
    } else {
      success = _core!.saveState(slot);
    }
    debugPrint(
      'SaveTrace: saveState native result slot=$slot success=$success',
    );
    if (success) {
      await _saveStateScreenshot(slot);
      final screenshotPath = getStateScreenshotPath(slot);
      if (statePath != null) {
        final file = File(statePath);
        debugPrint(
          'SaveTrace: saveState file slot=$slot path=$statePath '
          'exists=${file.existsSync()} '
          'bytes=${file.existsSync() ? file.lengthSync() : -1}',
        );
      }
      if (screenshotPath != null) {
        final file = File(screenshotPath);
        debugPrint(
          'SaveTrace: saveState screenshot slot=$slot path=$screenshotPath '
          'exists=${file.existsSync()} '
          'bytes=${file.existsSync() ? file.lengthSync() : -1}',
        );
      }
      if (statePath != null) _syncSaveToUserFolder(statePath);
      if (screenshotPath != null) _syncSaveToUserFolder(screenshotPath);
    }

    if (wasNative && _state == EmulatorState.running) {
      debugPrint('SaveTrace: saveState restarting native frame loop');
      _startNativeFrameLoop();
    }
    debugPrint('SaveTrace: saveState done slot=$slot success=$success');
    return success;
  }

  /// Load state from slot
  Future<bool> loadState(int slot) async {
    // Pause native frame loop to prevent concurrent core access
    final wasNative = _useNativeFrameLoop;
    final statePath = getStatePath(slot);
    final stateFile = statePath == null ? null : File(statePath);
    debugPrint(
      'SaveTrace: loadState start slot=$slot platform=${platform.name} '
      'state=${_state.name} wasNative=$wasNative texture=$_useTextureRendering '
      'path=$statePath exists=${stateFile?.existsSync()} '
      'bytes=${stateFile != null && stateFile.existsSync() ? stateFile.lengthSync() : -1}',
    );
    if (wasNative) {
      debugPrint('SaveTrace: loadState stopping native frame loop');
      _stopNativeFrameLoop();
    }

    if (_useStub) {
      final success = _stub?.loadState(slot) ?? false;
      debugPrint(
        'SaveTrace: loadState stub result slot=$slot success=$success',
      );
      if (success && _state == EmulatorState.paused) {
        _runSingleFrameIfSafe('load-state');
      }
      if (wasNative && _state == EmulatorState.running) {
        debugPrint('SaveTrace: loadState restarting native frame loop');
        _startNativeFrameLoop();
      }
      debugPrint('SaveTrace: loadState done slot=$slot success=$success');
      return success;
    }
    if (_core == null) {
      debugPrint('SaveTrace: loadState failed because core is null');
      if (wasNative && _state == EmulatorState.running) {
        debugPrint('SaveTrace: loadState restarting native frame loop');
        _startNativeFrameLoop();
      }
      return false;
    }
    final success = _core!.loadState(slot);
    debugPrint(
      'SaveTrace: loadState native result slot=$slot success=$success',
    );
    if (success && _state == EmulatorState.paused) {
      _runSingleFrameIfSafe('load-state');
    }

    if (wasNative && _state == EmulatorState.running) {
      debugPrint('SaveTrace: loadState restarting native frame loop');
      _startNativeFrameLoop();
    }
    debugPrint('SaveTrace: loadState done slot=$slot success=$success');
    return success;
  }

  /// Snapshot the current frame and encode it as PNG bytes.
  ///
  /// Width/height are taken from the SAME source as the pixel buffer so that
  /// `pixels.length == width * height * 4` always holds. Otherwise
  /// [ui.decodeImageFromPixels] can read past the buffer (heap OOB) when the
  /// core's framebuffer size differs from the on-screen display size — which
  /// happens with SGB borders, NDS, and dynamic-resolution PS1/N64. We use the
  /// core's own width/height (the buffer copy in [MGBACore.getVideoBuffer] is
  /// sized `width * height * 4`), plus a length backstop that skips the encode
  /// rather than risk an out-of-bounds read.
  ///
  /// The decode is bounded by a timeout so a missing callback can never leave
  /// emulation frozen (e.g. when the native frame loop was stopped for a save).
  Future<Uint8List?> _encodeCurrentFrameToPng() async {
    final Uint8List? pixels;
    final int w;
    final int h;
    if (_useStub) {
      pixels = _stub?.getVideoBuffer();
      w = _stub?.width ?? 240;
      h = _stub?.height ?? 160;
    } else {
      final c = _core;
      if (c == null) return null;
      pixels = c.getVideoBuffer();
      w = c.width;
      h = c.height;
    }
    if (pixels == null || w <= 0 || h <= 0) return null;
    // Backstop: never hand decodeImageFromPixels more pixels than we have.
    if (pixels.length < w * h * 4) {
      debugPrint(
        'EmulatorService: frame snapshot too small '
        '(${pixels.length} < ${w * h * 4}) — skipping PNG encode',
      );
      return null;
    }

    // Copy pixel data since native memory may be reused on the next frame.
    final pixelsCopy = Uint8List.fromList(pixels);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixelsCopy,
      w,
      h,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
    );
    final image = await completer.future.timeout(const Duration(seconds: 5));
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Capture the current video frame and save as PNG for save state thumbnail
  Future<void> _saveStateScreenshot(int slot) async {
    final path = getStateScreenshotPath(slot);
    if (path == null) return;

    try {
      final pngBytes = await _encodeCurrentFrameToPng();
      if (pngBytes != null) {
        await File(path).writeAsBytes(pngBytes);
      }
    } catch (e) {
      debugPrint('Error saving state screenshot: $e');
    }
  }

  /// Capture the current frame as a PNG and save it next to the ROM.
  /// Returns the saved file path on success, null on failure.
  Future<String?> captureScreenshot() async {
    if (_currentRom == null) return null;

    try {
      final pngBytes = await _encodeCurrentFrameToPng();
      if (pngBytes == null) return null;

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

      await File(filePath).writeAsBytes(pngBytes);
      debugPrint('Screenshot saved to $filePath');
      _syncSaveToUserFolder(filePath);
      return filePath;
    } catch (e) {
      debugPrint('Error capturing screenshot: $e');
      return null;
    }
  }

  /// Update settings — applies audio/palette changes to the native core immediately.
  /// Only notifies listeners if settings actually changed.
  void updateSettings(EmulatorSettings newSettings) {
    if (_settings == newSettings) return;

    final oldSettings = _settings;
    _settings = newSettings;

    // Apply audio settings changes to the native core in real-time
    if (oldSettings.volume != newSettings.volume ||
        oldSettings.enableSound != newSettings.enableSound) {
      _applyAudioSettings();
    }

    // Apply color palette changes
    if (oldSettings.selectedColorPalette != newSettings.selectedColorPalette) {
      _applyColorPalette();
    }

    // Graphics quality changed: color tuning + final scaling apply at
    // runtime immediately; core-level presets (internal resolution,
    // renderer, MSAA) are load-time options and take effect on the next
    // game launch (changing them mid-game is unsafe for hw cores — see
    // docs/GRAPHICS_QUALITY.md).
    if (oldSettings.graphicsQuality != newSettings.graphicsQuality &&
        _currentRom != null) {
      _applyColorTuning(_currentRom!.platform);
      _applyVideoFx(_currentRom!.platform);
    }

    // Apply turbo speed changes — if fast-forward is active, update to new speed
    if (oldSettings.turboSpeed != newSettings.turboSpeed &&
        _speedMultiplier > 1.0) {
      _speedMultiplier = newSettings.turboSpeed;
      if (_useNativeFrameLoop) {
        _core?.frameLoopSetSpeed((_speedMultiplier * 100).round());
      }
      notifyListeners();
    }

    // If turbo was disabled in settings while fast-forward is active, reset to 1x
    if (oldSettings.enableTurbo &&
        !newSettings.enableTurbo &&
        _speedMultiplier > 1.0) {
      _speedMultiplier = 1.0;
      if (_useNativeFrameLoop) {
        _core?.frameLoopSetSpeed(100);
      }
      notifyListeners();
    }

    // Rewind: [_initRewind] / deinit and sync pthread capture (do not gate
    // _initRewind on [isRewindSupported] — that would deadlock before first init).
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

    // Apply SGB border setting to native core
    // Note: the actual border rendering only takes effect on ROM reload,
    // but we update the native flag immediately so the next ROM load uses it.
    if (oldSettings.enableSgbBorders != newSettings.enableSgbBorders) {
      if (!_useStub && _core != null) {
        _core!.setSgbBorders(newSettings.enableSgbBorders);
      }
    }

    // Restart auto-save timer if interval changed while running
    if (oldSettings.autoSaveInterval != newSettings.autoSaveInterval &&
        _state == EmulatorState.running) {
      _startAutoSaveTimer();
    }
  }

  /// Apply current audio settings (volume + mute) to the native core
  void _applyAudioSettings() {
    setAudioEnabled(_settings.enableSound);
    setVolume(_settings.enableSound ? _settings.volume : 0.0);
  }

  /// Apply color palette to the native core (only for original GB games)
  void _applyColorPalette() {
    final paletteIndex = _settings.selectedColorPalette;

    // Only apply palette remapping for original GB games
    if (platform != GamePlatform.gb) {
      // Disable palette for non-GB games
      setColorPalette(-1, [0, 0, 0, 0]);
      return;
    }

    if (paletteIndex < 0 || paletteIndex >= GBColorPalette.palettes.length) {
      // Disable palette (use original colors)
      setColorPalette(-1, [0, 0, 0, 0]);
      return;
    }

    final palette = GBColorPalette.palettes[paletteIndex];
    // Convert 0xRRGGBB to 0xFFRRGGBB (add full alpha)
    final colors = palette.map((c) => 0xFF000000 | c).toList();
    setColorPalette(paletteIndex, colors);
  }

  /// Apply mild "bright and natural" color tuning to the native
  /// software-rendered pixel path, based on platform + quality mode.
  ///
  /// Targets: clearer highlights, slightly lifted midtones, natural
  /// saturation — never washed-out, never neon (the native side clamps).
  ///
  ///  * Android TV → neutral everywhere while TV graphics optimizations are
  ///    disabled.
  ///  * Authentic Pixel Mode → neutral everywhere (authentic colors).
  ///  * GB / GBC / GBA → strongest (still mild) preset; these games were
  ///    authored for dim, low-saturation LCDs.
  ///  * NDS / N64 / PS1 → neutral natively. Their frames are hardware
  ///    direct-presented through EGL and never pass the native software
  ///    conversion; the equivalent tuning is applied by the Flutter
  ///    ColorFiltered wrapper in game_display.dart, which covers BOTH the
  ///    Texture and CustomPaint paths. Setting it here too would
  ///    double-tune any software-fallback frames.
  ///  * All other 2D cores (NES, SNES, SMS/GG/MD/SG-1000, PCE/SGX,
  ///    NGP/NGPC, WS/WSC, Atari 2600, Virtual Boy, TIC-80, PICO-8,
  ///    Intellivision) → gentle lift.
  void _applyColorTuning(GamePlatform platform) {
    final core = _core;
    if (_useStub || core == null) return;
    if (!core.isColorTuningSupported) return;

    if (_settings.graphicsMode == GraphicsMode.authenticPixel ||
        _tvGraphicsOptimizationsOff) {
      core.setColorTuning(); // all-neutral → fast path
      return;
    }

    switch (platform) {
      case GamePlatform.gb:
      case GamePlatform.gbc:
      case GamePlatform.gba:
        core.setColorTuning(
          brightness: 1.02,
          contrast: 1.08,
          saturation: 1.06,
          gamma: 0.96,
        );
        break;
      case GamePlatform.nds:
      case GamePlatform.n64:
      case GamePlatform.ps1:
        core.setColorTuning(); // neutral — tuned in the Flutter layer
        break;
      // ignore: no_default_cases
      default:
        core.setColorTuning(
          brightness: 1.01,
          contrast: 1.03,
          saturation: 1.04,
          gamma: 0.98,
        );
        break;
    }
  }

  /// Push the per-system "out of the box" 2D display FX (Auto mode only).
  ///
  /// Mirrors [_applyColorTuning]: resolved from the frontend platform and
  /// the graphics mode, applied at ROM load and whenever the mode changes.
  /// Tuned for a SMOOTH, "less pixelated" image (the structural CRT/LCD
  /// effects that add visible pixel grids are off by default):
  ///   * Handhelds (GB/GBC/GBA/GG/NGP/WS/WSC/VB) → art-scaling + gentle
  ///     inter-frame ghosting (GB-family smear). LCD pixel grid OFF — it
  ///     darkens a line around every pixel and reads as "pixelated".
  ///   * Home consoles (NES/SNES/MD/SMS/SG-1000/PCE/SGX/Atari/Intellivision)
  ///     → art-scaling + light composite (NTSC) blend. Scanlines OFF for the
  ///     same reason.
  ///   * Fantasy consoles (TIC-80 / PICO-8) → art-scaling only.
  ///   * Authentic Pixel Mode and the hardware direct-present 3D cores
  ///     (NDS / N64 / PS1) → nothing (off).
  ///
  /// The smoothing itself comes from art-scaling (Scale2x) followed by a
  /// large GPU-bicubic residual (~scale/2) in the native blit. The scanline
  /// /grid engine is retained in native code for an optional CRT/LCD mode.
  /// Intensities are 0..100. Android TV disables all video FX while TV
  /// graphics optimizations are off. All effects no-op safely on older native
  /// libs that don't export `yage_video_set_fx`.
  void _applyVideoFx(GamePlatform platform) {
    final core = _core;
    if (_useStub || core == null) return;
    if (!core.isFxSupported) return;

    if (_settings.graphicsMode == GraphicsMode.authenticPixel ||
        _tvGraphicsOptimizationsOff) {
      core.setVideoFx(); // all-zero → native fast path
      return;
    }

    final bool tv = TvDetector.isTV;
    int ntscOf(int v) => tv ? 0 : v; // drop heavier source passes on TV
    int ghostOf(int v) => tv ? 0 : v;

    switch (platform) {
      // ── Handhelds: smooth upscale + gentle LCD ghosting ──
      // The LCD pixel grid is intentionally OFF: it darkens a line around
      // every native pixel, which reads as a heavily "pixelated" screen
      // (this was the dot-matrix grid visible on the GB high-score screen).
      // The native engine still supports it for an optional CRT/LCD mode.
      case GamePlatform.gb:
      case GamePlatform.gbc:
        core.setVideoFx(artScale: 100, ghost: ghostOf(30));
        break;
      case GamePlatform.gba:
        core.setVideoFx(artScale: 100, ghost: ghostOf(10));
        break;
      case GamePlatform.gg:
        core.setVideoFx(artScale: 100, ghost: ghostOf(24));
        break;
      case GamePlatform.ngp:
      case GamePlatform.ws:
      case GamePlatform.wsc:
        core.setVideoFx(artScale: 100, ghost: ghostOf(18));
        break;
      case GamePlatform.vb:
        core.setVideoFx(artScale: 100, ghost: ghostOf(15));
        break;
      // ── Home consoles: smooth upscale + light composite (NTSC) blend ──
      // Scanlines are OFF by default for the same reason — they add visible
      // pixel structure that fights the smooth look.
      case GamePlatform.nes:
      case GamePlatform.md:
      case GamePlatform.sms:
      case GamePlatform.sg1000:
        // Composite-heavy systems: a touch more NTSC blend.
        core.setVideoFx(artScale: 100, ntsc: ntscOf(35));
        break;
      case GamePlatform.snes:
      case GamePlatform.pce:
      case GamePlatform.sgx:
      case GamePlatform.a2600:
      case GamePlatform.intv:
        core.setVideoFx(artScale: 100, ntsc: ntscOf(25));
        break;
      // ── Fantasy consoles: clean modern pixel art, art-scale only ──
      case GamePlatform.tic80:
      case GamePlatform.pico8:
        core.setVideoFx(artScale: 100);
        break;
      // ── Hardware 3D / unknown: no software-blit FX ──
      case GamePlatform.nds:
      case GamePlatform.n64:
      case GamePlatform.ps1:
      case GamePlatform.unknown:
        core.setVideoFx(); // off
        break;
    }
  }

  /// Debug-only dump of the core's registered option keys.  Keeps the
  /// per-core preset keys in [_applyPlatformCoreOptions] honest — when a
  /// core update renames an option the mismatch shows up in logcat
  /// instead of silently no-opping.
  void _dumpCoreOptionsJson(GamePlatform platform) {
    if (!kDebugMode || _useStub) return;
    final json = _core?.getOptionsJson();
    if (json == null || json.isEmpty) return;
    // Log in chunks — logcat truncates long lines.
    debugPrint('Core options (${platform.name}):');
    for (var i = 0; i < json.length; i += 800) {
      debugPrint(
        json.substring(i, i + 800 > json.length ? json.length : i + 800),
      );
    }
  }

  /// Start the periodic auto-save timer based on settings.
  /// Does nothing if autoSaveInterval is 0 (disabled).
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

  /// Stop the auto-save timer.
  void _stopAutoSaveTimer() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
  }

  /// Stop and unload current ROM
  Future<void> stop() async {
    if (_isRewinding) stopRewind();

    final stoppingRom = _currentRom;
    final stoppingSramPath = stoppingRom == null
        ? null
        : _getSramPath(stoppingRom);

    // Deactivate the frame loop guard first so any already-enqueued timer
    // callbacks become no-ops before we tear down the core.
    _frameLoopActive = false;

    // Stop native frame loop if active (blocks until thread exits)
    _stopNativeFrameLoop();

    _frameTimer?.cancel();
    _frameTimer = null;
    _playTimeStopwatch.stop();
    _stopAutoSaveTimer();
    // Restore Analytics collection on game exit.
    _setFirebaseTelemetry(enabled: true);

    // Save SRAM before stopping, then reset the lock so any previously
    // queued saves don't execute against the destroyed core.
    await saveSram();
    _sramSaveLock = Future.value();

    // Reset rewind state
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

    // melonDS performs its final cartridge SRAM flush during core deinit.
    // Sync after dispose so the user folder/backup copy receives that final
    // write instead of the stale file that existed before unload.
    if (stoppingRom?.platform == GamePlatform.nds && stoppingSramPath != null) {
      final file = File(stoppingSramPath);
      debugPrint(
        'SaveTrace: NDS post-dispose SRAM sync path=$stoppingSramPath '
        'exists=${file.existsSync()} '
        'bytes=${file.existsSync() ? file.lengthSync() : -1}',
      );
      _syncSaveToUserFolder(stoppingSramPath);
    }

    // Generic: back up any side files the core flushed during deinit that the
    // RETRO_MEMORY_SAVE_RAM bridge does not cover (e.g. PS1 memory card 1).
    // Runs for every platform; it is a no-op when no such files exist.
    if (stoppingRom != null) {
      _syncCoreManagedSavesToUserFolder(stoppingRom);
    }

    // Reset play time tracking for next session
    _playTimeStopwatch.reset();
    _flushedPlayTimeSeconds = 0;
    _currentRom = null;
    _state = EmulatorState.uninitialized;
    _frameCount = 0;
    _currentFps = 0;
    _resetDisplayDimensionCache();
    notifyListeners();
  }

  /// Best-effort synchronous flush path for [dispose].
  ///
  /// Normally [stop] has already flushed SRAM asynchronously and set
  /// `_currentRom = null` — in that case [dispose] will see no dirty
  /// state and skip the sync write entirely, avoiding any ANR risk on
  /// large GBA flash saves (up to 128 KB).
  ///
  /// If the provider tree is torn down without a prior [stop] (app
  /// shutdown, hot restart), this is our last chance to persist. The
  /// write is bounded — a single fwrite of at most 128 KB — and only
  /// runs when dirty, so the worst-case UI-thread stall is < 20 ms on
  /// typical storage. Any failure is swallowed (we're already on the
  /// disposal path).
  @override
  void dispose() {
    _frameLoopActive = false;
    _frameTimer?.cancel();
    _autoSaveTimer?.cancel();

    String? postDisposeSyncPath;

    // Only flush if stop() hasn't already cleaned up. stop() nulls
    // _currentRom after saveSram() completes, so this branch is taken
    // solely for the "disposed without stop" shutdown path.
    if (_currentRom != null) {
      final flushWatch = Stopwatch()..start();
      try {
        final saveDir = _getRomSaveDir(_currentRom!);
        final sramPath = p.join(
          saveDir,
          '${p.basenameWithoutExtension(_currentRom!.path)}.sav',
        );
        if (_currentRom!.platform == GamePlatform.nds) {
          postDisposeSyncPath = sramPath;
        }
        if (_useStub) {
          _stub?.saveSram(sramPath);
        } else {
          _core?.saveSram(sramPath);
        }
        _syncSaveToUserFolder(sramPath);
      } catch (e) {
        debugPrint('dispose: SRAM flush failed — $e');
      } finally {
        flushWatch.stop();
        if (flushWatch.elapsedMilliseconds > 50) {
          debugPrint(
            'dispose: SRAM sync flush took ${flushWatch.elapsedMilliseconds} ms '
            '(consider calling stop() before dispose())',
          );
        }
      }
    }

    _stub?.dispose();
    _core?.dispose();
    if (postDisposeSyncPath != null) {
      _syncSaveToUserFolder(postDisposeSyncPath);
    }
    // Back up core-managed side files (e.g. PS1 memory card 1) flushed during
    // the dispose above. Only reached on the "disposed without stop()" path,
    // since stop() nulls _currentRom after its own backup.
    if (_currentRom != null) {
      _syncCoreManagedSavesToUserFolder(_currentRom!);
    }
    super.dispose();
  }
}
