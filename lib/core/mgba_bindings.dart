import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef NativeCore = Pointer<Void>;
typedef NativeThread = Pointer<Void>;

typedef MgbaCoreCreateNative = NativeCore Function();
typedef MgbaCoreCreate = NativeCore Function();

typedef MgbaCoreInitNative = Int32 Function(NativeCore core);
typedef MgbaCoreInit = int Function(NativeCore core);

typedef MgbaCoreDestroyNative = Void Function(NativeCore core);
typedef MgbaCoreDestroy = void Function(NativeCore core);

typedef MgbaCoreLoadROMNative =
    Int32 Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreLoadROM = int Function(NativeCore core, Pointer<Utf8> path);

typedef MgbaCoreLoadBIOSNative =
    Int32 Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreLoadBIOS = int Function(NativeCore core, Pointer<Utf8> path);

typedef MgbaCoreResetNative = Void Function(NativeCore core);
typedef MgbaCoreReset = void Function(NativeCore core);

typedef MgbaCoreRunFrameNative = Void Function(NativeCore core);
typedef MgbaCoreRunFrame = void Function(NativeCore core);

typedef MgbaCoreSetKeysNative = Void Function(NativeCore core, Uint32 keys);
typedef MgbaCoreSetKeys = void Function(NativeCore core, int keys);

typedef YageCoreSetAnalogNative =
    Void Function(NativeCore core, Int16 x, Int16 y);
typedef YageCoreSetAnalog = void Function(NativeCore core, int x, int y);

typedef YageCoreSetTouchNative =
    Void Function(NativeCore core, Int16 x, Int16 y, Int32 pressed);
typedef YageCoreSetTouch =
    void Function(NativeCore core, int x, int y, int pressed);

typedef MgbaCoreGetVideoBufferNative =
    Pointer<Uint32> Function(NativeCore core);
typedef MgbaCoreGetVideoBuffer = Pointer<Uint32> Function(NativeCore core);

typedef MgbaCoreGetAudioBufferNative = Pointer<Int16> Function(NativeCore core);
typedef MgbaCoreGetAudioBuffer = Pointer<Int16> Function(NativeCore core);

typedef MgbaCoreGetAudioSamplesNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetAudioSamples = int Function(NativeCore core);

typedef MgbaCoreSaveStateNative = Int32 Function(NativeCore core, Int32 slot);
typedef MgbaCoreSaveState = int Function(NativeCore core, int slot);

typedef MgbaCoreLoadStateNative = Int32 Function(NativeCore core, Int32 slot);
typedef MgbaCoreLoadState = int Function(NativeCore core, int slot);

typedef MgbaCoreGetWidthNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetWidth = int Function(NativeCore core);

typedef MgbaCoreGetHeightNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetHeight = int Function(NativeCore core);

typedef MgbaCoreGetPlatformNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetPlatform = int Function(NativeCore core);

typedef MgbaCoreSetSaveDirNative =
    Void Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreSetSaveDir = void Function(NativeCore core, Pointer<Utf8> path);

typedef MgbaCoreSetSystemDirNative =
    Void Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreSetSystemDir =
    void Function(NativeCore core, Pointer<Utf8> path);

typedef MgbaCoreSetVolumeNative = Void Function(NativeCore core, Float volume);
typedef MgbaCoreSetVolume = void Function(NativeCore core, double volume);

typedef MgbaCoreSetAudioEnabledNative =
    Void Function(NativeCore core, Int32 enabled);
typedef MgbaCoreSetAudioEnabled = void Function(NativeCore core, int enabled);

typedef MgbaCoreSetColorPaletteNative =
    Void Function(
      NativeCore core,
      Int32 paletteIndex,
      Uint32 color0,
      Uint32 color1,
      Uint32 color2,
      Uint32 color3,
    );
typedef MgbaCoreSetColorPalette =
    void Function(
      NativeCore core,
      int paletteIndex,
      int color0,
      int color1,
      int color2,
      int color3,
    );
typedef MgbaCoreSetSgbBordersNative =
    Void Function(NativeCore core, Int32 enabled);
typedef MgbaCoreSetSgbBorders = void Function(NativeCore core, int enabled);
typedef MgbaCoreGetSramSizeNative = Int32 Function(NativeCore core);
typedef MgbaCoreGetSramSize = int Function(NativeCore core);

typedef MgbaCoreGetSramDataNative = Pointer<Uint8> Function(NativeCore core);
typedef MgbaCoreGetSramData = Pointer<Uint8> Function(NativeCore core);

typedef MgbaCoreSaveSramNative =
    Int32 Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreSaveSram = int Function(NativeCore core, Pointer<Utf8> path);

typedef MgbaCoreLoadSramNative =
    Int32 Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreLoadSram = int Function(NativeCore core, Pointer<Utf8> path);
typedef MgbaCoreRewindInitNative =
    Int32 Function(NativeCore core, Int32 capacity);
typedef MgbaCoreRewindInit = int Function(NativeCore core, int capacity);

typedef MgbaCoreRewindDeinitNative = Void Function(NativeCore core);
typedef MgbaCoreRewindDeinit = void Function(NativeCore core);

typedef MgbaCoreRewindPushNative = Int32 Function(NativeCore core);
typedef MgbaCoreRewindPush = int Function(NativeCore core);

typedef MgbaCoreRewindPopNative = Int32 Function(NativeCore core);
typedef MgbaCoreRewindPop = int Function(NativeCore core);

typedef MgbaCoreRewindCountNative = Int32 Function(NativeCore core);
typedef MgbaCoreRewindCount = int Function(NativeCore core);
typedef MgbaCoreLinkIsSupportedNative = Int32 Function(NativeCore core);
typedef MgbaCoreLinkIsSupported = int Function(NativeCore core);

typedef MgbaCoreLinkReadByteNative =
    Int32 Function(NativeCore core, Uint32 addr);
typedef MgbaCoreLinkReadByte = int Function(NativeCore core, int addr);

typedef MgbaCoreLinkWriteByteNative =
    Int32 Function(NativeCore core, Uint32 addr, Uint8 value);
typedef MgbaCoreLinkWriteByte =
    int Function(NativeCore core, int addr, int value);

typedef MgbaCoreLinkGetTransferStatusNative = Int32 Function(NativeCore core);
typedef MgbaCoreLinkGetTransferStatus = int Function(NativeCore core);

typedef MgbaCoreLinkExchangeDataNative =
    Int32 Function(NativeCore core, Uint8 incoming);
typedef MgbaCoreLinkExchangeData = int Function(NativeCore core, int incoming);
typedef MgbaCoreReadMemoryNative =
    Int32 Function(
      NativeCore core,
      Uint32 address,
      Int32 count,
      Pointer<Uint8> buffer,
    );
typedef MgbaCoreReadMemory =
    int Function(
      NativeCore core,
      int address,
      int count,
      Pointer<Uint8> buffer,
    );

typedef MgbaCoreGetMemorySizeNative =
    Int32 Function(NativeCore core, Int32 regionId);
typedef MgbaCoreGetMemorySize = int Function(NativeCore core, int regionId);
typedef NativeFrameCallback = Void Function(Int32 framesRun);

typedef YageFrameLoopStartNative =
    Int32 Function(
      NativeCore core,
      Pointer<NativeFunction<NativeFrameCallback>> callback,
    );
typedef YageFrameLoopStart =
    int Function(
      NativeCore core,
      Pointer<NativeFunction<NativeFrameCallback>> callback,
    );

typedef YageFrameLoopStopNative = Void Function(NativeCore core);
typedef YageFrameLoopStop = void Function(NativeCore core);

typedef YageFrameLoopSetSpeedNative =
    Void Function(NativeCore core, Int32 speedPercent);
typedef YageFrameLoopSetSpeed =
    void Function(NativeCore core, int speedPercent);

typedef YageFrameLoopSetRewindNative =
    Void Function(NativeCore core, Int32 enabled, Int32 interval);
typedef YageFrameLoopSetRewind =
    void Function(NativeCore core, int enabled, int interval);

typedef YageFrameLoopSetRcheevosNative =
    Void Function(NativeCore core, Int32 enabled);
typedef YageFrameLoopSetRcheevos = void Function(NativeCore core, int enabled);

typedef YageFrameLoopGetFpsX100Native = Int32 Function(NativeCore core);
typedef YageFrameLoopGetFpsX100 = int Function(NativeCore core);

typedef YageFrameLoopGetDisplayBufferNative =
    Pointer<Uint32> Function(NativeCore core);
typedef YageFrameLoopGetDisplayBuffer =
    Pointer<Uint32> Function(NativeCore core);

typedef YageFrameLoopGetDisplayWidthNative = Int32 Function(NativeCore core);
typedef YageFrameLoopGetDisplayWidth = int Function(NativeCore core);

typedef YageFrameLoopGetDisplayHeightNative = Int32 Function(NativeCore core);
typedef YageFrameLoopGetDisplayHeight = int Function(NativeCore core);

typedef YageFrameLoopIsRunningNative = Int32 Function(NativeCore core);
typedef YageFrameLoopIsRunning = int Function(NativeCore core);
typedef YageCoreSetCoreNative = Int32 Function(Pointer<Utf8> corePath);
typedef YageCoreSetCore = int Function(Pointer<Utf8> corePath);
typedef YageTextureBlitNative = Int32 Function(NativeCore core);
typedef YageTextureBlit = int Function(NativeCore core);

typedef YageTextureIsAttachedNative = Int32 Function(NativeCore core);
typedef YageTextureIsAttached = int Function(NativeCore core);
typedef YageGpuTextureIsReadyNative = Int32 Function(NativeCore core);
typedef YageGpuTextureIsReady = int Function(NativeCore core);

typedef YageGpuTextureInitNative =
    Int32 Function(NativeCore core, Uint32 width, Uint32 height);
typedef YageGpuTextureInit =
    int Function(NativeCore core, int width, int height);

typedef YageGpuTextureShutdownNative = Void Function(NativeCore core);
typedef YageGpuTextureShutdown = void Function(NativeCore core);

typedef YageGpuTextureGetIdNative = Uint32 Function(NativeCore core);
typedef YageGpuTextureGetId = int Function(NativeCore core);

typedef YageGpuTextureIsDirtyNative = Int32 Function(NativeCore core);
typedef YageGpuTextureIsDirty = int Function(NativeCore core);
typedef YageCoreGetOptionsJsonNative = Pointer<Utf8> Function(NativeCore core);
typedef YageCoreGetOptionsJson = Pointer<Utf8> Function(NativeCore core);

typedef YageCoreSetOptionNative =
    Int32 Function(NativeCore core, Pointer<Utf8> key, Pointer<Utf8> value);
typedef YageCoreSetOption =
    int Function(NativeCore core, Pointer<Utf8> key, Pointer<Utf8> value);

typedef YageCoreGetOptionNative =
    Pointer<Utf8> Function(NativeCore core, Pointer<Utf8> key);
typedef YageCoreGetOption =
    Pointer<Utf8> Function(NativeCore core, Pointer<Utf8> key);
typedef YageCoreCheatResetNative = Int32 Function(NativeCore core);
typedef YageCoreCheatReset = int Function(NativeCore core);

typedef YageCoreCheatSetNative =
    Int32 Function(
      NativeCore core,
      Uint32 index,
      Int32 enabled,
      Pointer<Utf8> code,
    );
typedef YageCoreCheatSet =
    int Function(NativeCore core, int index, int enabled, Pointer<Utf8> code);

class GBAKey {
  static const int a = 1 << 0;
  static const int b = 1 << 1;
  static const int select = 1 << 2;
  static const int start = 1 << 3;
  static const int right = 1 << 4;
  static const int left = 1 << 5;
  static const int up = 1 << 6;
  static const int down = 1 << 7;
  static const int r = 1 << 8;
  static const int l = 1 << 9;
  static const int x = 1 << 10;
  static const int y = 1 << 11;
}

enum GamePlatform {
  unknown,
  gb,
  gbc,
  gba,
  nes,
  snes,
  sms,
  gg,
  md,
  sg1000,
  ngp,
  ws,
  wsc,
  n64,
  pce,
  sgx,
}

class MGBABindings {
  bool _isLoaded = false;
  late final MgbaCoreCreate coreCreate;
  late final MgbaCoreInit coreInit;
  late final MgbaCoreDestroy coreDestroy;
  late final MgbaCoreLoadROM coreLoadROM;
  late final MgbaCoreLoadBIOS coreLoadBIOS;
  late final MgbaCoreReset coreReset;
  late final MgbaCoreRunFrame coreRunFrame;
  late final MgbaCoreSetKeys coreSetKeys;
  late final YageCoreSetAnalog coreSetAnalog;
  late final YageCoreSetTouch coreSetTouch;
  late final MgbaCoreGetVideoBuffer coreGetVideoBuffer;
  late final MgbaCoreGetAudioBuffer coreGetAudioBuffer;
  late final MgbaCoreGetAudioSamples coreGetAudioSamples;
  late final MgbaCoreSaveState coreSaveState;
  late final MgbaCoreLoadState coreLoadState;
  late final MgbaCoreGetWidth coreGetWidth;
  late final MgbaCoreGetHeight coreGetHeight;
  late final MgbaCoreGetPlatform coreGetPlatform;
  late final MgbaCoreSetSaveDir coreSetSaveDir;
  late final MgbaCoreSetSystemDir coreSetSystemDir;
  late final MgbaCoreGetSramSize coreGetSramSize;
  late final MgbaCoreGetSramData coreGetSramData;
  late final MgbaCoreSaveSram coreSaveSram;
  late final MgbaCoreLoadSram coreLoadSram;
  late final MgbaCoreSetVolume coreSetVolume;
  late final MgbaCoreSetAudioEnabled coreSetAudioEnabled;
  late final MgbaCoreSetColorPalette coreSetColorPalette;
  MgbaCoreSetSgbBorders? coreSetSgbBorders;
  bool _sgbBordersLoaded = false;
  bool get isSgbBordersLoaded => _sgbBordersLoaded;
  late final MgbaCoreRewindInit coreRewindInit;
  late final MgbaCoreRewindDeinit coreRewindDeinit;
  late final MgbaCoreRewindPush coreRewindPush;
  late final MgbaCoreRewindPop coreRewindPop;
  late final MgbaCoreRewindCount coreRewindCount;
  MgbaCoreLinkIsSupported? coreLinkIsSupported;
  MgbaCoreLinkReadByte? coreLinkReadByte;
  MgbaCoreLinkWriteByte? coreLinkWriteByte;
  MgbaCoreLinkGetTransferStatus? coreLinkGetTransferStatus;
  MgbaCoreLinkExchangeData? coreLinkExchangeData;
  bool _linkLoaded = false;
  bool get isLinkLoaded => _linkLoaded;
  MgbaCoreReadMemory? coreReadMemory;
  MgbaCoreGetMemorySize? coreGetMemorySize;
  bool _memoryReadLoaded = false;
  bool get isMemoryReadLoaded => _memoryReadLoaded;
  YageFrameLoopStart? frameLoopStart;
  YageFrameLoopStop? frameLoopStop;
  YageFrameLoopSetSpeed? frameLoopSetSpeed;
  YageFrameLoopSetRewind? frameLoopSetRewind;
  YageFrameLoopSetRcheevos? frameLoopSetRcheevos;
  YageFrameLoopGetFpsX100? frameLoopGetFpsX100;
  YageFrameLoopGetDisplayBuffer? frameLoopGetDisplayBuffer;
  YageFrameLoopGetDisplayWidth? frameLoopGetDisplayWidth;
  YageFrameLoopGetDisplayHeight? frameLoopGetDisplayHeight;
  YageFrameLoopIsRunning? frameLoopIsRunning;
  bool _frameLoopLoaded = false;
  bool get isFrameLoopLoaded => _frameLoopLoaded;
  YageTextureBlit? textureBlit;
  YageTextureIsAttached? textureIsAttached;
  bool _textureLoaded = false;
  bool get isTextureLoaded => _textureLoaded;
  YageGpuTextureIsReady? gpuTextureIsReady;
  YageGpuTextureInit? gpuTextureInit;
  YageGpuTextureShutdown? gpuTextureShutdown;
  YageGpuTextureGetId? gpuTextureGetId;
  YageGpuTextureIsDirty? gpuTextureIsDirty;
  bool _gpuTextureLoaded = false;
  bool get isGpuTextureLoaded => _gpuTextureLoaded;
  YageCoreGetOptionsJson? coreGetOptionsJson;
  YageCoreSetOption? coreSetOption;
  YageCoreGetOption? coreGetOption;
  bool _optionsUiLoaded = false;
  bool get isOptionsUiLoaded => _optionsUiLoaded;
  YageCoreCheatReset? coreCheatReset;
  YageCoreCheatSet? coreCheatSet;
  bool _cheatsLoaded = false;
  bool get isCheatsLoaded => _cheatsLoaded;
  YageCoreSetCore? coreSetCore;
  bool _coreSelectionLoaded = false;
  bool get isCoreSelectionLoaded => _coreSelectionLoaded;

  bool get isLoaded => _isLoaded;

  String _selectedCoreLib = 'libmgba_libretro_android.so';
  String? _lastCoreLoadError;
  String? get lastCoreLoadError => _lastCoreLoadError;

  static const platformCoreLibs = <GamePlatform, String>{
    GamePlatform.gb: 'libmgba_libretro_android.so',
    GamePlatform.gbc: 'libmgba_libretro_android.so',
    GamePlatform.gba: 'libmgba_libretro_android.so',
    GamePlatform.nes: 'libfceumm_libretro_android.so',
    GamePlatform.snes: 'libsnes9x2010_libretro_android.so',
    GamePlatform.sms: 'libgenesis_plus_gx_libretro_android.so',
    GamePlatform.gg: 'libgenesis_plus_gx_libretro_android.so',
    GamePlatform.md: 'libgenesis_plus_gx_libretro_android.so',
    GamePlatform.pce: 'libmednafen_pce_fast_libretro_android.so',
    GamePlatform.sgx: 'libmednafen_supergrafx_libretro_android.so',
    GamePlatform.sg1000: 'libgenesis_plus_gx_libretro_android.so',
    GamePlatform.ngp: 'libmednafen_ngp_libretro_android.so',
    GamePlatform.ws: 'libmednafen_wswan_libretro_android.so',
    GamePlatform.wsc: 'libmednafen_wswan_libretro_android.so',
    GamePlatform.n64: 'libmupen64plus_next_gles3_libretro_android.so',
  };

  void selectCore(GamePlatform platform) {
    _selectedCoreLib = platformCoreLibs[platform] ?? _selectedCoreLib;
    _lastCoreLoadError = null;

    if (Platform.isAndroid) {
      try {
        DynamicLibrary.open(_selectedCoreLib);
        debugPrint('Pre-loaded libretro core: $_selectedCoreLib');
      } catch (e) {
        _lastCoreLoadError =
            'Could not pre-load $_selectedCoreLib on this device: $e';
        debugPrint('Warning: Could not pre-load core $_selectedCoreLib: $e');
      }
    }
  }

  bool load() {
    if (_isLoaded) return true;

    try {
      _lastCoreLoadError = null;
      if (Platform.isAndroid) {
        try {
          DynamicLibrary.open(_selectedCoreLib);
          debugPrint('Loaded libretro core: $_selectedCoreLib');
        } catch (e) {
          _lastCoreLoadError =
              'Could not load $_selectedCoreLib on this device: $e';
          debugPrint('Warning: Could not pre-load core $_selectedCoreLib: $e');
        }
      }

      String libraryPath;

      if (Platform.isWindows) {
        libraryPath = 'yage_core.dll';
      } else if (Platform.isLinux) {
        libraryPath = 'libyage_core.so';
      } else if (Platform.isMacOS) {
        libraryPath = 'libyage_core.dylib';
      } else if (Platform.isAndroid) {
        libraryPath = 'libyage_core.so';
      } else {
        throw UnsupportedError('Unsupported platform');
      }

      final lib = DynamicLibrary.open(libraryPath);
      final bindCoreCreate = lib
          .lookup<NativeFunction<MgbaCoreCreateNative>>('yage_core_create')
          .asFunction<MgbaCoreCreate>();
      final bindCoreInit = lib
          .lookup<NativeFunction<MgbaCoreInitNative>>('yage_core_init')
          .asFunction<MgbaCoreInit>();
      final bindCoreDestroy = lib
          .lookup<NativeFunction<MgbaCoreDestroyNative>>('yage_core_destroy')
          .asFunction<MgbaCoreDestroy>();
      final bindCoreLoadROM = lib
          .lookup<NativeFunction<MgbaCoreLoadROMNative>>('yage_core_load_rom')
          .asFunction<MgbaCoreLoadROM>();
      final bindCoreLoadBIOS = lib
          .lookup<NativeFunction<MgbaCoreLoadBIOSNative>>('yage_core_load_bios')
          .asFunction<MgbaCoreLoadBIOS>();
      final bindCoreReset = lib
          .lookup<NativeFunction<MgbaCoreResetNative>>('yage_core_reset')
          .asFunction<MgbaCoreReset>();
      final bindCoreRunFrame = lib
          .lookup<NativeFunction<MgbaCoreRunFrameNative>>('yage_core_run_frame')
          .asFunction<MgbaCoreRunFrame>();
      final bindCoreSetKeys = lib
          .lookup<NativeFunction<MgbaCoreSetKeysNative>>('yage_core_set_keys')
          .asFunction<MgbaCoreSetKeys>();
      final bindCoreSetAnalog = lib
          .lookup<NativeFunction<YageCoreSetAnalogNative>>(
            'yage_core_set_analog',
          )
          .asFunction<YageCoreSetAnalog>();
      final bindCoreSetTouch = lib
          .lookup<NativeFunction<YageCoreSetTouchNative>>('yage_core_set_touch')
          .asFunction<YageCoreSetTouch>();
      final bindCoreGetVideoBuffer = lib
          .lookup<NativeFunction<MgbaCoreGetVideoBufferNative>>(
            'yage_core_get_video_buffer',
          )
          .asFunction<MgbaCoreGetVideoBuffer>();
      final bindCoreGetAudioBuffer = lib
          .lookup<NativeFunction<MgbaCoreGetAudioBufferNative>>(
            'yage_core_get_audio_buffer',
          )
          .asFunction<MgbaCoreGetAudioBuffer>();
      final bindCoreGetAudioSamples = lib
          .lookup<NativeFunction<MgbaCoreGetAudioSamplesNative>>(
            'yage_core_get_audio_samples',
          )
          .asFunction<MgbaCoreGetAudioSamples>();
      final bindCoreSaveState = lib
          .lookup<NativeFunction<MgbaCoreSaveStateNative>>(
            'yage_core_save_state',
          )
          .asFunction<MgbaCoreSaveState>();
      final bindCoreLoadState = lib
          .lookup<NativeFunction<MgbaCoreLoadStateNative>>(
            'yage_core_load_state',
          )
          .asFunction<MgbaCoreLoadState>();
      final bindCoreGetWidth = lib
          .lookup<NativeFunction<MgbaCoreGetWidthNative>>('yage_core_get_width')
          .asFunction<MgbaCoreGetWidth>();
      final bindCoreGetHeight = lib
          .lookup<NativeFunction<MgbaCoreGetHeightNative>>(
            'yage_core_get_height',
          )
          .asFunction<MgbaCoreGetHeight>();
      final bindCoreGetPlatform = lib
          .lookup<NativeFunction<MgbaCoreGetPlatformNative>>(
            'yage_core_get_platform',
          )
          .asFunction<MgbaCoreGetPlatform>();
      final bindCoreSetSaveDir = lib
          .lookup<NativeFunction<MgbaCoreSetSaveDirNative>>(
            'yage_core_set_save_dir',
          )
          .asFunction<MgbaCoreSetSaveDir>();
      final bindCoreSetSystemDir = lib
          .lookup<NativeFunction<MgbaCoreSetSystemDirNative>>(
            'yage_core_set_system_dir',
          )
          .asFunction<MgbaCoreSetSystemDir>();
      final bindCoreGetSramSize = lib
          .lookup<NativeFunction<MgbaCoreGetSramSizeNative>>(
            'yage_core_get_sram_size',
          )
          .asFunction<MgbaCoreGetSramSize>();
      final bindCoreGetSramData = lib
          .lookup<NativeFunction<MgbaCoreGetSramDataNative>>(
            'yage_core_get_sram_data',
          )
          .asFunction<MgbaCoreGetSramData>();
      final bindCoreSaveSram = lib
          .lookup<NativeFunction<MgbaCoreSaveSramNative>>('yage_core_save_sram')
          .asFunction<MgbaCoreSaveSram>();
      final bindCoreLoadSram = lib
          .lookup<NativeFunction<MgbaCoreLoadSramNative>>('yage_core_load_sram')
          .asFunction<MgbaCoreLoadSram>();
      final bindCoreSetVolume = lib
          .lookup<NativeFunction<MgbaCoreSetVolumeNative>>(
            'yage_core_set_volume',
          )
          .asFunction<MgbaCoreSetVolume>();
      final bindCoreSetAudioEnabled = lib
          .lookup<NativeFunction<MgbaCoreSetAudioEnabledNative>>(
            'yage_core_set_audio_enabled',
          )
          .asFunction<MgbaCoreSetAudioEnabled>();
      final bindCoreSetColorPalette = lib
          .lookup<NativeFunction<MgbaCoreSetColorPaletteNative>>(
            'yage_core_set_color_palette',
          )
          .asFunction<MgbaCoreSetColorPalette>();
      final bindCoreRewindInit = lib
          .lookup<NativeFunction<MgbaCoreRewindInitNative>>(
            'yage_core_rewind_init',
          )
          .asFunction<MgbaCoreRewindInit>();
      final bindCoreRewindDeinit = lib
          .lookup<NativeFunction<MgbaCoreRewindDeinitNative>>(
            'yage_core_rewind_deinit',
          )
          .asFunction<MgbaCoreRewindDeinit>();
      final bindCoreRewindPush = lib
          .lookup<NativeFunction<MgbaCoreRewindPushNative>>(
            'yage_core_rewind_push',
          )
          .asFunction<MgbaCoreRewindPush>();
      final bindCoreRewindPop = lib
          .lookup<NativeFunction<MgbaCoreRewindPopNative>>(
            'yage_core_rewind_pop',
          )
          .asFunction<MgbaCoreRewindPop>();
      final bindCoreRewindCount = lib
          .lookup<NativeFunction<MgbaCoreRewindCountNative>>(
            'yage_core_rewind_count',
          )
          .asFunction<MgbaCoreRewindCount>();
      coreCreate = bindCoreCreate;
      coreInit = bindCoreInit;
      coreDestroy = bindCoreDestroy;
      coreLoadROM = bindCoreLoadROM;
      coreLoadBIOS = bindCoreLoadBIOS;
      coreReset = bindCoreReset;
      coreRunFrame = bindCoreRunFrame;
      coreSetKeys = bindCoreSetKeys;
      coreSetAnalog = bindCoreSetAnalog;
      coreSetTouch = bindCoreSetTouch;
      coreGetVideoBuffer = bindCoreGetVideoBuffer;
      coreGetAudioBuffer = bindCoreGetAudioBuffer;
      coreGetAudioSamples = bindCoreGetAudioSamples;
      coreSaveState = bindCoreSaveState;
      coreLoadState = bindCoreLoadState;
      coreGetWidth = bindCoreGetWidth;
      coreGetHeight = bindCoreGetHeight;
      coreGetPlatform = bindCoreGetPlatform;
      coreSetSaveDir = bindCoreSetSaveDir;
      coreSetSystemDir = bindCoreSetSystemDir;
      coreGetSramSize = bindCoreGetSramSize;
      coreGetSramData = bindCoreGetSramData;
      coreSaveSram = bindCoreSaveSram;
      coreLoadSram = bindCoreLoadSram;
      coreSetVolume = bindCoreSetVolume;
      coreSetAudioEnabled = bindCoreSetAudioEnabled;
      coreSetColorPalette = bindCoreSetColorPalette;
      coreRewindInit = bindCoreRewindInit;
      coreRewindDeinit = bindCoreRewindDeinit;
      coreRewindPush = bindCoreRewindPush;
      coreRewindPop = bindCoreRewindPop;
      coreRewindCount = bindCoreRewindCount;

      _isLoaded = true;
      debugPrint(
        'YAGE core library loaded successfully (all ${31} symbols bound)',
      );
      try {
        coreLinkIsSupported = lib
            .lookup<NativeFunction<MgbaCoreLinkIsSupportedNative>>(
              'yage_core_link_is_supported',
            )
            .asFunction<MgbaCoreLinkIsSupported>();
        coreLinkReadByte = lib
            .lookup<NativeFunction<MgbaCoreLinkReadByteNative>>(
              'yage_core_link_read_byte',
            )
            .asFunction<MgbaCoreLinkReadByte>();
        coreLinkWriteByte = lib
            .lookup<NativeFunction<MgbaCoreLinkWriteByteNative>>(
              'yage_core_link_write_byte',
            )
            .asFunction<MgbaCoreLinkWriteByte>();
        coreLinkGetTransferStatus = lib
            .lookup<NativeFunction<MgbaCoreLinkGetTransferStatusNative>>(
              'yage_core_link_get_transfer_status',
            )
            .asFunction<MgbaCoreLinkGetTransferStatus>();
        coreLinkExchangeData = lib
            .lookup<NativeFunction<MgbaCoreLinkExchangeDataNative>>(
              'yage_core_link_exchange_data',
            )
            .asFunction<MgbaCoreLinkExchangeData>();
        _linkLoaded = true;
        debugPrint('Link cable symbols loaded successfully');
      } catch (e) {
        debugPrint(
          'Link cable symbols not available (native lib rebuild needed): $e',
        );
        _linkLoaded = false;
      }
      try {
        coreReadMemory = lib
            .lookup<NativeFunction<MgbaCoreReadMemoryNative>>(
              'yage_core_read_memory',
            )
            .asFunction<MgbaCoreReadMemory>();
        coreGetMemorySize = lib
            .lookup<NativeFunction<MgbaCoreGetMemorySizeNative>>(
              'yage_core_get_memory_size',
            )
            .asFunction<MgbaCoreGetMemorySize>();
        _memoryReadLoaded = true;
        debugPrint('Memory read symbols loaded successfully');
      } catch (e) {
        debugPrint(
          'Memory read symbols not available (native lib rebuild needed): $e',
        );
        _memoryReadLoaded = false;
      }
      try {
        frameLoopStart = lib
            .lookup<NativeFunction<YageFrameLoopStartNative>>(
              'yage_frame_loop_start',
            )
            .asFunction<YageFrameLoopStart>();
        frameLoopStop = lib
            .lookup<NativeFunction<YageFrameLoopStopNative>>(
              'yage_frame_loop_stop',
            )
            .asFunction<YageFrameLoopStop>();
        frameLoopSetSpeed = lib
            .lookup<NativeFunction<YageFrameLoopSetSpeedNative>>(
              'yage_frame_loop_set_speed',
            )
            .asFunction<YageFrameLoopSetSpeed>();
        frameLoopSetRewind = lib
            .lookup<NativeFunction<YageFrameLoopSetRewindNative>>(
              'yage_frame_loop_set_rewind',
            )
            .asFunction<YageFrameLoopSetRewind>();
        frameLoopSetRcheevos = lib
            .lookup<NativeFunction<YageFrameLoopSetRcheevosNative>>(
              'yage_frame_loop_set_rcheevos',
            )
            .asFunction<YageFrameLoopSetRcheevos>();
        frameLoopGetFpsX100 = lib
            .lookup<NativeFunction<YageFrameLoopGetFpsX100Native>>(
              'yage_frame_loop_get_fps_x100',
            )
            .asFunction<YageFrameLoopGetFpsX100>();
        frameLoopGetDisplayBuffer = lib
            .lookup<NativeFunction<YageFrameLoopGetDisplayBufferNative>>(
              'yage_frame_loop_get_display_buffer',
            )
            .asFunction<YageFrameLoopGetDisplayBuffer>();
        frameLoopGetDisplayWidth = lib
            .lookup<NativeFunction<YageFrameLoopGetDisplayWidthNative>>(
              'yage_frame_loop_get_display_width',
            )
            .asFunction<YageFrameLoopGetDisplayWidth>();
        frameLoopGetDisplayHeight = lib
            .lookup<NativeFunction<YageFrameLoopGetDisplayHeightNative>>(
              'yage_frame_loop_get_display_height',
            )
            .asFunction<YageFrameLoopGetDisplayHeight>();
        frameLoopIsRunning = lib
            .lookup<NativeFunction<YageFrameLoopIsRunningNative>>(
              'yage_frame_loop_is_running',
            )
            .asFunction<YageFrameLoopIsRunning>();
        _frameLoopLoaded = true;
        debugPrint('Native frame loop symbols loaded successfully');
      } catch (e) {
        debugPrint('Native frame loop symbols not available: $e');
        _frameLoopLoaded = false;
      }
      try {
        textureBlit = lib
            .lookup<NativeFunction<YageTextureBlitNative>>('yage_texture_blit')
            .asFunction<YageTextureBlit>();
        textureIsAttached = lib
            .lookup<NativeFunction<YageTextureIsAttachedNative>>(
              'yage_texture_is_attached',
            )
            .asFunction<YageTextureIsAttached>();
        _textureLoaded = true;
        debugPrint('Texture rendering symbols loaded successfully');
      } catch (e) {
        debugPrint('Texture rendering symbols not available: $e');
        _textureLoaded = false;
      }
      try {
        coreSetSgbBorders = lib
            .lookup<NativeFunction<MgbaCoreSetSgbBordersNative>>(
              'yage_core_set_sgb_borders',
            )
            .asFunction<MgbaCoreSetSgbBorders>();
        _sgbBordersLoaded = true;
        debugPrint('SGB border control symbol loaded successfully');
      } catch (e) {
        debugPrint('SGB border control not available: $e');
        _sgbBordersLoaded = false;
      }
      try {
        coreSetCore = lib
            .lookup<NativeFunction<YageCoreSetCoreNative>>('yage_core_set_core')
            .asFunction<YageCoreSetCore>();
        _coreSelectionLoaded = true;
        debugPrint('Core selection symbol loaded successfully');
      } catch (e) {
        debugPrint('Core selection not available (single-core build): $e');
        _coreSelectionLoaded = false;
      }
      try {
        coreCheatReset = lib
            .lookup<NativeFunction<YageCoreCheatResetNative>>(
              'yage_core_cheat_reset',
            )
            .asFunction<YageCoreCheatReset>();
        coreCheatSet = lib
            .lookup<NativeFunction<YageCoreCheatSetNative>>(
              'yage_core_cheat_set',
            )
            .asFunction<YageCoreCheatSet>();
        _cheatsLoaded = true;
        debugPrint('Cheat code symbols loaded successfully');
      } catch (e) {
        debugPrint('Cheat code symbols not available: $e');
        _cheatsLoaded = false;
      }
      try {
        gpuTextureIsReady = lib
            .lookup<NativeFunction<YageGpuTextureIsReadyNative>>(
              'yage_gpu_texture_is_ready',
            )
            .asFunction<YageGpuTextureIsReady>();
        gpuTextureInit = lib
            .lookup<NativeFunction<YageGpuTextureInitNative>>(
              'yage_gpu_texture_init',
            )
            .asFunction<YageGpuTextureInit>();
        gpuTextureShutdown = lib
            .lookup<NativeFunction<YageGpuTextureShutdownNative>>(
              'yage_gpu_texture_shutdown',
            )
            .asFunction<YageGpuTextureShutdown>();
        gpuTextureGetId = lib
            .lookup<NativeFunction<YageGpuTextureGetIdNative>>(
              'yage_gpu_texture_get_id',
            )
            .asFunction<YageGpuTextureGetId>();
        gpuTextureIsDirty = lib
            .lookup<NativeFunction<YageGpuTextureIsDirtyNative>>(
              'yage_gpu_texture_is_dirty',
            )
            .asFunction<YageGpuTextureIsDirty>();
        _gpuTextureLoaded = true;
        debugPrint('GPU zero-copy texture symbols loaded successfully');
      } catch (e) {
        debugPrint('GPU zero-copy texture symbols not available: $e');
        _gpuTextureLoaded = false;
      }
      try {
        coreGetOptionsJson = lib
            .lookup<NativeFunction<YageCoreGetOptionsJsonNative>>(
              'yage_core_get_options_json',
            )
            .asFunction<YageCoreGetOptionsJson>();
        coreSetOption = lib
            .lookup<NativeFunction<YageCoreSetOptionNative>>(
              'yage_core_set_option',
            )
            .asFunction<YageCoreSetOption>();
        coreGetOption = lib
            .lookup<NativeFunction<YageCoreGetOptionNative>>(
              'yage_core_get_option',
            )
            .asFunction<YageCoreGetOption>();
        _optionsUiLoaded = true;
        debugPrint('Core options UI symbols loaded successfully');
      } catch (e) {
        debugPrint('Core options UI symbols not available: $e');
        _optionsUiLoaded = false;
      }

      return true;
    } catch (e) {
      debugPrint('Failed to load YAGE core library: $e');
      return false;
    }
  }
}

class MGBACore {
  final MGBABindings _bindings;
  NativeCore? _corePtr;
  bool _isRunning = false;
  int _currentKeys = 0;
  int _width = 240;
  int _height = 160;
  GamePlatform _platform = GamePlatform.unknown;

  MGBACore(this._bindings);

  bool get isRunning => _isRunning;
  int get width => _width;
  int get height => _height;
  GamePlatform get platform => _platform;

  String get _logTag => '${_platform.name.toUpperCase()}Core';

  NativeCore? get nativeCorePtr => _corePtr;

  void setCoreLibrary(String coreLib) {
    if (_bindings.coreSetCore == null) return;
    final pathPtr = coreLib.toNativeUtf8();
    try {
      _bindings.coreSetCore!(pathPtr);
    } catch (e) {
      debugPrint('MGBACore.setCoreLibrary: FFI error — $e');
    } finally {
      malloc.free(pathPtr);
    }
  }

  bool initialize() {
    if (!_bindings.isLoaded) {
      if (!_bindings.load()) return false;
    }

    try {
      final core = _bindings.coreCreate();
      if (core == nullptr || core.address == 0) return false;

      final result = _bindings.coreInit(core);
      if (result != 0) {
        try {
          _bindings.coreDestroy(core);
        } catch (e) {
          debugPrint(
            'MGBACore.initialize: coreDestroy failed after init error: $e',
          );
        }
        return false;
      }

      _corePtr = core;
      return true;
    } catch (e) {
      debugPrint('MGBACore.initialize: FFI error — $e');
      return false;
    }
  }

  bool loadROM(String path) {
    if (_corePtr == null) return false;

    final pathPtr = path.toNativeUtf8();
    try {
      final result = _bindings.coreLoadROM(_corePtr as Pointer<Void>, pathPtr);
      if (result == 0) {
        _updateDimensions();
        _isRunning = true;
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('MGBACore.loadROM: FFI error — $e');
      return false;
    } finally {
      malloc.free(pathPtr);
    }
  }

  bool loadBIOS(String path) {
    if (_corePtr == null) return false;

    final pathPtr = path.toNativeUtf8();
    try {
      final result = _bindings.coreLoadBIOS(_corePtr as Pointer<Void>, pathPtr);
      return result == 0;
    } finally {
      malloc.free(pathPtr);
    }
  }

  void setSaveDir(String path) {
    if (_corePtr == null) return;

    final pathPtr = path.toNativeUtf8();
    try {
      _bindings.coreSetSaveDir(_corePtr as Pointer<Void>, pathPtr);
    } finally {
      malloc.free(pathPtr);
    }
  }

  void setSystemDir(String path) {
    if (_corePtr == null) return;

    final pathPtr = path.toNativeUtf8();
    try {
      _bindings.coreSetSystemDir(_corePtr as Pointer<Void>, pathPtr);
    } finally {
      malloc.free(pathPtr);
    }
  }

  void _updateDimensions() {
    if (_corePtr == null) return;

    try {
      _width = _bindings.coreGetWidth(_corePtr as Pointer<Void>);
      _height = _bindings.coreGetHeight(_corePtr as Pointer<Void>);

      final platformInt = _bindings.coreGetPlatform(_corePtr as Pointer<Void>);
      _platform = switch (platformInt) {
        1 => GamePlatform.gb,
        2 => GamePlatform.gbc,
        3 => GamePlatform.gba,
        4 => GamePlatform.nes,
        5 => GamePlatform.snes,
        6 => GamePlatform.sms,
        7 => GamePlatform.gg,
        8 => GamePlatform.md,
        9 => GamePlatform.sg1000,
        10 => GamePlatform.ngp,
        11 => GamePlatform.ws,
        12 => GamePlatform.wsc,
        13 => GamePlatform.n64,
        _ => GamePlatform.unknown,
      };
    } catch (e) {
      debugPrint('MGBACore._updateDimensions: FFI error — $e');
    }
  }

  void runFrame() {
    if (_corePtr == null || !_isRunning) return;
    try {
      _bindings.coreRunFrame(_corePtr as Pointer<Void>);
    } catch (e) {
      debugPrint('MGBACore.runFrame: FFI error — $e');
    }
  }

  void setKeys(int keys) {
    if (_corePtr == null) {
      if (kDebugMode && keys != 0) {
        debugPrint(
          'Input: $_logTag.setKeys SKIPPED - _corePtr is null! keys=0x${keys.toRadixString(16)}',
        );
      }
      return;
    }
    _currentKeys = keys;
    if (kDebugMode && keys != 0) {
      debugPrint(
        'Input: $_logTag.setKeys -> native keys=0x${keys.toRadixString(16)} platform=$_platform',
      );
    }
    try {
      _bindings.coreSetKeys(_corePtr as Pointer<Void>, keys);
    } catch (e) {
      debugPrint('$_logTag.setKeys: FFI error — $e');
    }
  }

  void setAnalog(int x, int y) {
    if (_corePtr == null) return;
    try {
      _bindings.coreSetAnalog(_corePtr as Pointer<Void>, x, y);
    } catch (e) {
      debugPrint('$_logTag.setAnalog: FFI error — $e');
    }
  }

  void setTouch(int x, int y, bool isDown) {
    if (_corePtr == null) return;
    try {
      _bindings.coreSetTouch(_corePtr as Pointer<Void>, x, y, isDown ? 1 : 0);
    } catch (e) {
      debugPrint('MGBACore.setTouch: FFI error — $e');
    }
  }

  void pressKey(int key) {
    setKeys(_currentKeys | key);
  }

  void releaseKey(int key) {
    setKeys(_currentKeys & ~key);
  }

  Uint8List? getVideoBuffer() {
    if (_corePtr == null) return null;

    try {
      final buffer = _bindings.coreGetVideoBuffer(_corePtr as Pointer<Void>);
      if (buffer == nullptr || buffer.address == 0) return null;

      final byteCount = _width * _height * 4;
      return Uint8List.fromList(buffer.cast<Uint8>().asTypedList(byteCount));
    } catch (e) {
      debugPrint('MGBACore.getVideoBuffer: FFI error — $e');
      return null;
    }
  }

  (Int16List?, int) getAudioBuffer() {
    if (_corePtr == null) return (null, 0);

    try {
      final samples = _bindings.coreGetAudioSamples(_corePtr as Pointer<Void>);
      if (samples == 0) return (null, 0);

      final buffer = _bindings.coreGetAudioBuffer(_corePtr as Pointer<Void>);
      if (buffer == nullptr || buffer.address == 0) return (null, 0);
      final sampleCount = samples * 2; 
      final audioData = Int16List.fromList(buffer.asTypedList(sampleCount));

      return (audioData, samples);
    } catch (e) {
      debugPrint('MGBACore.getAudioBuffer: FFI error — $e');
      return (null, 0);
    }
  }

  bool saveState(int slot) {
    if (_corePtr == null) return false;
    return _bindings.coreSaveState(_corePtr as Pointer<Void>, slot) == 0;
  }

  bool loadState(int slot) {
    if (_corePtr == null) return false;
    return _bindings.coreLoadState(_corePtr as Pointer<Void>, slot) == 0;
  }

  void reset() {
    if (_corePtr == null) return;
    _bindings.coreReset(_corePtr as Pointer<Void>);
  }

  int getSramSize() {
    if (_corePtr == null) return 0;
    return _bindings.coreGetSramSize(_corePtr as Pointer<Void>);
  }

  Pointer<Uint8>? getSramData() {
    if (_corePtr == null) return null;
    final ptr = _bindings.coreGetSramData(_corePtr as Pointer<Void>);
    return ptr == nullptr ? null : ptr;
  }

  bool saveSram(String path) {
    if (_corePtr == null) return false;
    final pathPtr = path.toNativeUtf8();
    try {
      final result = _bindings.coreSaveSram(_corePtr as Pointer<Void>, pathPtr);
      return result == 0;
    } finally {
      malloc.free(pathPtr);
    }
  }

  bool loadSram(String path) {
    if (_corePtr == null) return false;
    final pathPtr = path.toNativeUtf8();
    try {
      final result = _bindings.coreLoadSram(_corePtr as Pointer<Void>, pathPtr);
      return result == 0;
    } finally {
      malloc.free(pathPtr);
    }
  }

  void setVolume(double volume) {
    if (_corePtr == null) return;
    _bindings.coreSetVolume(_corePtr as Pointer<Void>, volume.clamp(0.0, 1.0));
  }

  void setAudioEnabled(bool enabled) {
    if (_corePtr == null) return;
    _bindings.coreSetAudioEnabled(_corePtr as Pointer<Void>, enabled ? 1 : 0);
  }

  void setColorPalette(int paletteIndex, List<int> colors) {
    if (_corePtr == null) return;
    _bindings.coreSetColorPalette(
      _corePtr as Pointer<Void>,
      paletteIndex,
      colors[0],
      colors[1],
      colors[2],
      colors[3],
    );
  }

  void setSgbBorders(bool enabled) {
    if (_corePtr == null || _bindings.coreSetSgbBorders == null) return;
    _bindings.coreSetSgbBorders!(_corePtr as Pointer<Void>, enabled ? 1 : 0);
  }

  bool get isSgbBordersSupported =>
      _bindings.isSgbBordersLoaded && _corePtr != null;

  int rewindInit(int capacity) {
    if (_corePtr == null) return -1;
    return _bindings.coreRewindInit(_corePtr as Pointer<Void>, capacity);
  }

  void rewindDeinit() {
    if (_corePtr == null) return;
    _bindings.coreRewindDeinit(_corePtr as Pointer<Void>);
  }

  int rewindPush() {
    if (_corePtr == null) return -1;
    return _bindings.coreRewindPush(_corePtr as Pointer<Void>);
  }

  int rewindPop() {
    if (_corePtr == null) return -1;
    return _bindings.coreRewindPop(_corePtr as Pointer<Void>);
  }

  int rewindCount() {
    if (_corePtr == null) return 0;
    return _bindings.coreRewindCount(_corePtr as Pointer<Void>);
  }

  bool get isLinkSupported {
    if (_corePtr == null || !_bindings.isLinkLoaded) return false;
    return _bindings.coreLinkIsSupported!(_corePtr as Pointer<Void>) == 1;
  }

  int linkReadByte(int addr) {
    if (_corePtr == null || _bindings.coreLinkReadByte == null) return -1;
    return _bindings.coreLinkReadByte!(_corePtr as Pointer<Void>, addr);
  }

  int linkWriteByte(int addr, int value) {
    if (_corePtr == null || _bindings.coreLinkWriteByte == null) return -1;
    return _bindings.coreLinkWriteByte!(_corePtr as Pointer<Void>, addr, value);
  }

  int linkGetTransferStatus() {
    if (_corePtr == null || _bindings.coreLinkGetTransferStatus == null) {
      return -1;
    }
    return _bindings.coreLinkGetTransferStatus!(_corePtr as Pointer<Void>);
  }

  int linkExchangeData(int incoming) {
    if (_corePtr == null || _bindings.coreLinkExchangeData == null) return -1;
    return _bindings.coreLinkExchangeData!(_corePtr as Pointer<Void>, incoming);
  }

  bool get isMemoryReadSupported =>
      _bindings.isMemoryReadLoaded && _corePtr != null;

  int readMemory(int address, int count, Pointer<Uint8> buffer) {
    if (_corePtr == null || _bindings.coreReadMemory == null) return -1;
    return _bindings.coreReadMemory!(
      _corePtr as Pointer<Void>,
      address,
      count,
      buffer,
    );
  }

  Pointer<Uint8>? _readBuf;

  int readByte(int address) {
    if (_corePtr == null || _bindings.coreReadMemory == null) return -1;
    _readBuf ??= calloc<Uint8>(4); 
    final read = _bindings.coreReadMemory!(
      _corePtr as Pointer<Void>,
      address,
      1,
      _readBuf!,
    );
    if (read <= 0) return -1;
    return _readBuf!.value;
  }

  int getMemorySize(int regionId) {
    if (_corePtr == null || _bindings.coreGetMemorySize == null) return 0;
    return _bindings.coreGetMemorySize!(_corePtr as Pointer<Void>, regionId);
  }

  bool get isFrameLoopSupported =>
      _bindings.isFrameLoopLoaded && _corePtr != null;

  bool startFrameLoop(
    Pointer<NativeFunction<NativeFrameCallback>> callbackPtr,
  ) {
    if (_corePtr == null || !_bindings.isFrameLoopLoaded) return false;
    final result = _bindings.frameLoopStart!(
      _corePtr as Pointer<Void>,
      callbackPtr,
    );
    return result == 0;
  }

  void stopFrameLoop() {
    if (_corePtr == null || !_bindings.isFrameLoopLoaded) return;
    _bindings.frameLoopStop!(_corePtr as Pointer<Void>);
  }

  void frameLoopSetSpeed(int speedPercent) {
    if (_corePtr == null || _bindings.frameLoopSetSpeed == null) return;
    _bindings.frameLoopSetSpeed!(_corePtr as Pointer<Void>, speedPercent);
  }

  void frameLoopSetRewind({required bool enabled, int interval = 5}) {
    if (_corePtr == null || _bindings.frameLoopSetRewind == null) return;
    _bindings.frameLoopSetRewind!(
      _corePtr as Pointer<Void>,
      enabled ? 1 : 0,
      interval,
    );
  }

  void frameLoopSetRcheevos({required bool enabled}) {
    if (_corePtr == null || _bindings.frameLoopSetRcheevos == null) return;
    _bindings.frameLoopSetRcheevos!(_corePtr as Pointer<Void>, enabled ? 1 : 0);
  }

  double getFrameLoopFps() {
    if (_corePtr == null || _bindings.frameLoopGetFpsX100 == null) return 0;
    return _bindings.frameLoopGetFpsX100!(_corePtr as Pointer<Void>) / 100.0;
  }

  Uint8List? getDisplayBuffer() {
    if (_corePtr == null || !_bindings.isFrameLoopLoaded) return null;

    try {
      final buffer = _bindings.frameLoopGetDisplayBuffer!(
        _corePtr as Pointer<Void>,
      );
      if (buffer == nullptr || buffer.address == 0) return null;

      final w = _bindings.frameLoopGetDisplayWidth!(_corePtr as Pointer<Void>);
      final h = _bindings.frameLoopGetDisplayHeight!(_corePtr as Pointer<Void>);
      if (w <= 0 || h <= 0) return null;

      final byteCount = w * h * 4;
      return Uint8List.fromList(buffer.cast<Uint8>().asTypedList(byteCount));
    } catch (e) {
      debugPrint('MGBACore.getDisplayBuffer: FFI error — $e');
      return null;
    }
  }

  int get displayWidth {
    if (_corePtr == null || _bindings.frameLoopGetDisplayWidth == null) {
      return _width;
    }
    final w = _bindings.frameLoopGetDisplayWidth!(_corePtr as Pointer<Void>);
    return w > 0 ? w : _width;
  }

  int get displayHeight {
    if (_corePtr == null || _bindings.frameLoopGetDisplayHeight == null) {
      return _height;
    }
    final h = _bindings.frameLoopGetDisplayHeight!(_corePtr as Pointer<Void>);
    return h > 0 ? h : _height;
  }

  bool get isFrameLoopRunning {
    if (_corePtr == null || _bindings.frameLoopIsRunning == null) return false;
    return _bindings.frameLoopIsRunning!(_corePtr as Pointer<Void>) != 0;
  }

  bool get isTextureSupported => _bindings.isTextureLoaded && _corePtr != null;

  bool textureBlit() {
    if (_corePtr == null || _bindings.textureBlit == null) return false;
    return _bindings.textureBlit!(_corePtr as Pointer<Void>) == 0;
  }

  bool get isTextureAttached {
    if (_corePtr == null || _bindings.textureIsAttached == null) return false;
    return _bindings.textureIsAttached!(_corePtr as Pointer<Void>) != 0;
  }

  bool get isCheatsSupported => _bindings.isCheatsLoaded && _corePtr != null;

  bool cheatReset() {
    if (_corePtr == null || _bindings.coreCheatReset == null) return false;
    return _bindings.coreCheatReset!(_corePtr as Pointer<Void>) == 0;
  }

  bool cheatSet(int index, bool enabled, String code) {
    if (_corePtr == null || _bindings.coreCheatSet == null) return false;
    final codePtr = code.toNativeUtf8();
    try {
      return _bindings.coreCheatSet!(
            _corePtr as Pointer<Void>,
            index,
            enabled ? 1 : 0,
            codePtr,
          ) ==
          0;
    } finally {
      calloc.free(codePtr);
    }
  }

  void dispose() {
    if (isFrameLoopRunning) {
      try {
        stopFrameLoop();
      } catch (e) {
        debugPrint('MGBACore.dispose: stopFrameLoop failed — $e');
      }
    }
    if (_readBuf != null) {
      calloc.free(_readBuf!);
      _readBuf = null;
    }
    if (_corePtr != null) {
      try {
        _bindings.coreDestroy(_corePtr as Pointer<Void>);
      } catch (e) {
        debugPrint('MGBACore.dispose: coreDestroy failed — $e');
      }
      _corePtr = null;
    }
    _isRunning = false;
  }
}
