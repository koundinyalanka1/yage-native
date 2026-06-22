import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ═══════════════════════════════════════════════════════════════════════
//  Native type definitions for yage_rcheevos.c
// ═══════════════════════════════════════════════════════════════════════

// ── Lifecycle ──
typedef YageRcInitNative = Int32 Function(Pointer<Void> yageCore);
typedef YageRcInit = int Function(Pointer<Void> yageCore);

typedef YageRcDestroyNative = Void Function();
typedef YageRcDestroy = void Function();

// ── Configuration ──
typedef YageRcSetHardcoreNative = Void Function(Int32 enabled);
typedef YageRcSetHardcore = void Function(int enabled);

typedef YageRcSetEncoreNative = Void Function(Int32 enabled);
typedef YageRcSetEncore = void Function(int enabled);

typedef YageRcGetUserAgentClauseNative = Int32 Function(
    Pointer<Utf8> buffer, Int32 bufferSize);
typedef YageRcGetUserAgentClause = int Function(
    Pointer<Utf8> buffer, int bufferSize);

// ── User / Session ──
typedef YageRcBeginLoginNative = Void Function(
    Pointer<Utf8> username, Pointer<Utf8> token);
typedef YageRcBeginLogin = void Function(
    Pointer<Utf8> username, Pointer<Utf8> token);

typedef YageRcIsLoggedInNative = Int32 Function();
typedef YageRcIsLoggedIn = int Function();

typedef YageRcGetUserDisplayNameNative = Pointer<Utf8> Function();
typedef YageRcGetUserDisplayName = Pointer<Utf8> Function();

typedef YageRcLogoutNative = Void Function();
typedef YageRcLogout = void Function();

// ── Game ──
typedef YageRcBeginLoadGameNative = Void Function(Pointer<Utf8> hash);
typedef YageRcBeginLoadGame = void Function(Pointer<Utf8> hash);

typedef YageRcIsGameLoadedNative = Int32 Function();
typedef YageRcIsGameLoaded = int Function();

typedef YageRcGetGameTitleNative = Pointer<Utf8> Function();
typedef YageRcGetGameTitle = Pointer<Utf8> Function();

typedef YageRcGetGameIdNative = Uint32 Function();
typedef YageRcGetGameId = int Function();

typedef YageRcGetGameBadgeUrlNative = Pointer<Utf8> Function();
typedef YageRcGetGameBadgeUrl = Pointer<Utf8> Function();

typedef YageRcUnloadGameNative = Void Function();
typedef YageRcUnloadGame = void Function();

typedef YageRcResetNative = Void Function();
typedef YageRcReset = void Function();

// ── Frame Processing ──
typedef YageRcDoFrameNative = Void Function();
typedef YageRcDoFrame = void Function();

typedef YageRcIdleNative = Void Function();
typedef YageRcIdle = void Function();

// ── Achievement Info ──
typedef YageRcGetAchievementCountNative = Uint32 Function();
typedef YageRcGetAchievementCount = int Function();

typedef YageRcGetUnlockedCountNative = Uint32 Function();
typedef YageRcGetUnlockedCount = int Function();

typedef YageRcGetTotalPointsNative = Uint32 Function();
typedef YageRcGetTotalPoints = int Function();

typedef YageRcGetUnlockedPointsNative = Uint32 Function();
typedef YageRcGetUnlockedPoints = int Function();

// ── HTTP Bridge ──
typedef YageRcGetPendingRequestNative = Uint32 Function();
typedef YageRcGetPendingRequest = int Function();

typedef YageRcGetRequestUrlNative = Pointer<Utf8> Function(Uint32 requestId);
typedef YageRcGetRequestUrl = Pointer<Utf8> Function(int requestId);

typedef YageRcGetRequestPostDataNative = Pointer<Utf8> Function(
    Uint32 requestId);
typedef YageRcGetRequestPostData = Pointer<Utf8> Function(int requestId);

typedef YageRcGetRequestContentTypeNative = Pointer<Utf8> Function(
    Uint32 requestId);
typedef YageRcGetRequestContentType = Pointer<Utf8> Function(int requestId);

typedef YageRcSubmitResponseNative = Void Function(
    Uint32 requestId, Pointer<Utf8> body, Uint32 bodyLength, Int32 httpStatus);
typedef YageRcSubmitResponse = void Function(
    int requestId, Pointer<Utf8> body, int bodyLength, int httpStatus);

// ── Event Bridge ──
typedef YageRcHasPendingEventNative = Int32 Function();
typedef YageRcHasPendingEvent = int Function();

// Native event struct layout:
//   uint32_t type;                     // offset 0
//   uint32_t achievement_id;           // offset 4
//   uint32_t achievement_points;       // offset 8
//   char achievement_title[256];       // offset 12
//   char achievement_description[256]; // offset 268
//   char achievement_badge_url[512];   // offset 524
//   float achievement_rarity;          // offset 1036
//   float achievement_rarity_hardcore; // offset 1040
//   uint8_t achievement_type;          // offset 1044
//   char error_message[512];           // offset 1045
//   int error_code;                    // offset 1560 (aligned)
// Total size: ~1564 bytes

typedef YageRcGetPendingEventNative = Int32 Function(Pointer<Void> outEvent);
typedef YageRcGetPendingEvent = int Function(Pointer<Void> outEvent);

typedef YageRcConsumeEventNative = Void Function();
typedef YageRcConsumeEvent = void Function();

// ── State ──
typedef YageRcGetLoadGameStateNative = Int32 Function();
typedef YageRcGetLoadGameState = int Function();

typedef YageRcIsProcessingRequiredNative = Int32 Function();
typedef YageRcIsProcessingRequired = int Function();

typedef YageRcGetHardcoreEnabledNative = Int32 Function();
typedef YageRcGetHardcoreEnabled = int Function();

// ═══════════════════════════════════════════════════════════════════════
//  Event type constants (match yage_rcheevos.h)
// ═══════════════════════════════════════════════════════════════════════

class RcEventType {
  static const int none = 0;
  static const int achievementTriggered = 1;
  static const int leaderboardStarted = 2;
  static const int leaderboardFailed = 3;
  static const int leaderboardSubmitted = 4;
  static const int challengeIndicatorShow = 5;
  static const int challengeIndicatorHide = 6;
  static const int progressIndicatorShow = 7;
  static const int progressIndicatorHide = 8;
  static const int gameCompleted = 15;
  static const int serverError = 16;
  static const int disconnected = 17;
  static const int reconnected = 18;

  // Custom events (from our wrapper)
  static const int loginSuccess = 100;
  static const int loginFailed = 101;
  static const int gameLoadSuccess = 102;
  static const int gameLoadFailed = 103;
}

// ═══════════════════════════════════════════════════════════════════════
//  Parsed event data
// ═══════════════════════════════════════════════════════════════════════

class RcEvent {
  final int type;
  final int achievementId;
  final int achievementPoints;
  final String achievementTitle;
  final String achievementDescription;
  final String achievementBadgeUrl;
  final double achievementRarity;
  final double achievementRarityHardcore;
  final int achievementType;
  final String errorMessage;
  final int errorCode;

  RcEvent({
    required this.type,
    this.achievementId = 0,
    this.achievementPoints = 0,
    this.achievementTitle = '',
    this.achievementDescription = '',
    this.achievementBadgeUrl = '',
    this.achievementRarity = 0.0,
    this.achievementRarityHardcore = 0.0,
    this.achievementType = 0,
    this.errorMessage = '',
    this.errorCode = 0,
  });

  bool get isAchievementTriggered => type == RcEventType.achievementTriggered;
  bool get isGameCompleted => type == RcEventType.gameCompleted;
  bool get isLoginSuccess => type == RcEventType.loginSuccess;
  bool get isLoginFailed => type == RcEventType.loginFailed;
  bool get isGameLoadSuccess => type == RcEventType.gameLoadSuccess;
  bool get isGameLoadFailed => type == RcEventType.gameLoadFailed;

  @override
  String toString() {
    switch (type) {
      case RcEventType.achievementTriggered:
        return 'RcEvent(achievementTriggered: "$achievementTitle" $achievementPoints pts)';
      case RcEventType.gameCompleted:
        return 'RcEvent(gameCompleted)';
      case RcEventType.loginSuccess:
        return 'RcEvent(loginSuccess)';
      case RcEventType.loginFailed:
        return 'RcEvent(loginFailed: "$errorMessage")';
      case RcEventType.gameLoadSuccess:
        return 'RcEvent(gameLoadSuccess)';
      case RcEventType.gameLoadFailed:
        return 'RcEvent(gameLoadFailed: "$errorMessage")';
      default:
        return 'RcEvent(type=$type)';
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  FFI Bindings
// ═══════════════════════════════════════════════════════════════════════

/// Dart FFI bindings for the native yage_rcheevos wrapper.
///
/// This class loads all function pointers from the yage_core shared library.
/// The functions are optional — if the symbols are not found (e.g. old build
/// without rcheevos), the bindings gracefully report unavailability.
class RcheevosBindings {
  bool _loaded = false;
  bool get isLoaded => _loaded;

  // ── Function pointers (all optional) ──
  YageRcInit? rcInit;
  YageRcDestroy? rcDestroy;
  YageRcSetHardcore? rcSetHardcore;
  YageRcSetEncore? rcSetEncore;
  YageRcGetUserAgentClause? rcGetUserAgentClause;
  YageRcBeginLogin? rcBeginLogin;
  YageRcIsLoggedIn? rcIsLoggedIn;
  YageRcGetUserDisplayName? rcGetUserDisplayName;
  YageRcLogout? rcLogout;
  YageRcBeginLoadGame? rcBeginLoadGame;
  YageRcIsGameLoaded? rcIsGameLoaded;
  YageRcGetGameTitle? rcGetGameTitle;
  YageRcGetGameId? rcGetGameId;
  YageRcGetGameBadgeUrl? rcGetGameBadgeUrl;
  YageRcUnloadGame? rcUnloadGame;
  YageRcReset? rcReset;
  YageRcDoFrame? rcDoFrame;
  YageRcIdle? rcIdle;
  YageRcGetAchievementCount? rcGetAchievementCount;
  YageRcGetUnlockedCount? rcGetUnlockedCount;
  YageRcGetTotalPoints? rcGetTotalPoints;
  YageRcGetUnlockedPoints? rcGetUnlockedPoints;
  YageRcGetPendingRequest? rcGetPendingRequest;
  YageRcGetRequestUrl? rcGetRequestUrl;
  YageRcGetRequestPostData? rcGetRequestPostData;
  YageRcGetRequestContentType? rcGetRequestContentType;
  YageRcSubmitResponse? rcSubmitResponse;
  YageRcHasPendingEvent? rcHasPendingEvent;
  YageRcGetPendingEvent? rcGetPendingEvent;
  YageRcConsumeEvent? rcConsumeEvent;
  YageRcGetLoadGameState? rcGetLoadGameState;
  YageRcIsProcessingRequired? rcIsProcessingRequired;
  YageRcGetHardcoreEnabled? rcGetHardcoreEnabled;

  // ── Pre-allocated event buffer ──
  Pointer<Void>? _eventBuffer;

  /// Public access to the event buffer for the client.
  Pointer<Void>? get eventBuffer => _eventBuffer;

  /// Size of yage_rc_event_t struct (generous allocation).
  static const int _eventStructSize = 2048;

  /// Load rcheevos bindings from the native library.
  ///
  /// Returns true if all symbols were found. Returns false if any
  /// required symbol is missing (graceful degradation).
  bool load() {
    if (_loaded) return true;

    try {
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

      // Resolve all symbols — if any fail, the whole load fails gracefully
      rcInit = lib
          .lookup<NativeFunction<YageRcInitNative>>('yage_rc_init')
          .asFunction<YageRcInit>();
      rcDestroy = lib
          .lookup<NativeFunction<YageRcDestroyNative>>('yage_rc_destroy')
          .asFunction<YageRcDestroy>();
      rcSetHardcore = lib
          .lookup<NativeFunction<YageRcSetHardcoreNative>>(
              'yage_rc_set_hardcore')
          .asFunction<YageRcSetHardcore>();
      rcSetEncore = lib
          .lookup<NativeFunction<YageRcSetEncoreNative>>('yage_rc_set_encore')
          .asFunction<YageRcSetEncore>();
      rcGetUserAgentClause = lib
          .lookup<NativeFunction<YageRcGetUserAgentClauseNative>>(
              'yage_rc_get_user_agent_clause')
          .asFunction<YageRcGetUserAgentClause>();
      rcBeginLogin = lib
          .lookup<NativeFunction<YageRcBeginLoginNative>>('yage_rc_begin_login')
          .asFunction<YageRcBeginLogin>();
      rcIsLoggedIn = lib
          .lookup<NativeFunction<YageRcIsLoggedInNative>>(
              'yage_rc_is_logged_in')
          .asFunction<YageRcIsLoggedIn>();
      rcGetUserDisplayName = lib
          .lookup<NativeFunction<YageRcGetUserDisplayNameNative>>(
              'yage_rc_get_user_display_name')
          .asFunction<YageRcGetUserDisplayName>();
      rcLogout = lib
          .lookup<NativeFunction<YageRcLogoutNative>>('yage_rc_logout')
          .asFunction<YageRcLogout>();
      rcBeginLoadGame = lib
          .lookup<NativeFunction<YageRcBeginLoadGameNative>>(
              'yage_rc_begin_load_game')
          .asFunction<YageRcBeginLoadGame>();
      rcIsGameLoaded = lib
          .lookup<NativeFunction<YageRcIsGameLoadedNative>>(
              'yage_rc_is_game_loaded')
          .asFunction<YageRcIsGameLoaded>();
      rcGetGameTitle = lib
          .lookup<NativeFunction<YageRcGetGameTitleNative>>(
              'yage_rc_get_game_title')
          .asFunction<YageRcGetGameTitle>();
      rcGetGameId = lib
          .lookup<NativeFunction<YageRcGetGameIdNative>>('yage_rc_get_game_id')
          .asFunction<YageRcGetGameId>();
      rcGetGameBadgeUrl = lib
          .lookup<NativeFunction<YageRcGetGameBadgeUrlNative>>(
              'yage_rc_get_game_badge_url')
          .asFunction<YageRcGetGameBadgeUrl>();
      rcUnloadGame = lib
          .lookup<NativeFunction<YageRcUnloadGameNative>>(
              'yage_rc_unload_game')
          .asFunction<YageRcUnloadGame>();
      rcReset = lib
          .lookup<NativeFunction<YageRcResetNative>>('yage_rc_reset')
          .asFunction<YageRcReset>();
      rcDoFrame = lib
          .lookup<NativeFunction<YageRcDoFrameNative>>('yage_rc_do_frame')
          .asFunction<YageRcDoFrame>();
      rcIdle = lib
          .lookup<NativeFunction<YageRcIdleNative>>('yage_rc_idle')
          .asFunction<YageRcIdle>();
      rcGetAchievementCount = lib
          .lookup<NativeFunction<YageRcGetAchievementCountNative>>(
              'yage_rc_get_achievement_count')
          .asFunction<YageRcGetAchievementCount>();
      rcGetUnlockedCount = lib
          .lookup<NativeFunction<YageRcGetUnlockedCountNative>>(
              'yage_rc_get_unlocked_count')
          .asFunction<YageRcGetUnlockedCount>();
      rcGetTotalPoints = lib
          .lookup<NativeFunction<YageRcGetTotalPointsNative>>(
              'yage_rc_get_total_points')
          .asFunction<YageRcGetTotalPoints>();
      rcGetUnlockedPoints = lib
          .lookup<NativeFunction<YageRcGetUnlockedPointsNative>>(
              'yage_rc_get_unlocked_points')
          .asFunction<YageRcGetUnlockedPoints>();
      rcGetPendingRequest = lib
          .lookup<NativeFunction<YageRcGetPendingRequestNative>>(
              'yage_rc_get_pending_request')
          .asFunction<YageRcGetPendingRequest>();
      rcGetRequestUrl = lib
          .lookup<NativeFunction<YageRcGetRequestUrlNative>>(
              'yage_rc_get_request_url')
          .asFunction<YageRcGetRequestUrl>();
      rcGetRequestPostData = lib
          .lookup<NativeFunction<YageRcGetRequestPostDataNative>>(
              'yage_rc_get_request_post_data')
          .asFunction<YageRcGetRequestPostData>();
      rcGetRequestContentType = lib
          .lookup<NativeFunction<YageRcGetRequestContentTypeNative>>(
              'yage_rc_get_request_content_type')
          .asFunction<YageRcGetRequestContentType>();
      rcSubmitResponse = lib
          .lookup<NativeFunction<YageRcSubmitResponseNative>>(
              'yage_rc_submit_response')
          .asFunction<YageRcSubmitResponse>();
      rcHasPendingEvent = lib
          .lookup<NativeFunction<YageRcHasPendingEventNative>>(
              'yage_rc_has_pending_event')
          .asFunction<YageRcHasPendingEvent>();
      rcGetPendingEvent = lib
          .lookup<NativeFunction<YageRcGetPendingEventNative>>(
              'yage_rc_get_pending_event')
          .asFunction<YageRcGetPendingEvent>();
      rcConsumeEvent = lib
          .lookup<NativeFunction<YageRcConsumeEventNative>>(
              'yage_rc_consume_event')
          .asFunction<YageRcConsumeEvent>();
      rcGetLoadGameState = lib
          .lookup<NativeFunction<YageRcGetLoadGameStateNative>>(
              'yage_rc_get_load_game_state')
          .asFunction<YageRcGetLoadGameState>();
      rcIsProcessingRequired = lib
          .lookup<NativeFunction<YageRcIsProcessingRequiredNative>>(
              'yage_rc_is_processing_required')
          .asFunction<YageRcIsProcessingRequired>();
      rcGetHardcoreEnabled = lib
          .lookup<NativeFunction<YageRcGetHardcoreEnabledNative>>(
              'yage_rc_get_hardcore_enabled')
          .asFunction<YageRcGetHardcoreEnabled>();

      // Allocate event buffer
      _eventBuffer = calloc<Uint8>(_eventStructSize).cast<Void>();

      _loaded = true;
      debugPrint('rcheevos bindings loaded successfully');
      return true;
    } catch (e) {
      debugPrint('rcheevos bindings failed to load: $e');
      _loaded = false;
      return false;
    }
  }

  /// Read a string from a native `Pointer<Utf8>`.
  /// Returns null if the pointer is null (nullptr) or invalid.
  static String? _readNullableString(Pointer<Utf8> ptr) {
    if (ptr == nullptr || ptr.address == 0) return null;
    try {
      return ptr.toDartString();
    } catch (e) {
      debugPrint('RcheevosBindings: failed to read native string at ${ptr.address} — $e');
      return null;
    }
  }

  /// Parse the raw event struct from the native event buffer.
  RcEvent? readEvent() {
    if (_eventBuffer == null || _eventBuffer!.address == 0) return null;

    try {
      final buf = _eventBuffer!.cast<Uint8>();

      // Read fields according to struct layout
      // uint32_t type (offset 0)
      final type = buf.cast<Uint32>().value;

      // uint32_t achievement_id (offset 4)
      final achId = (buf + 4).cast<Uint32>().value;

      // uint32_t achievement_points (offset 8)
      final achPoints = (buf + 8).cast<Uint32>().value;

      // char achievement_title[256] (offset 12)
      final titlePtr = (buf + 12).cast<Utf8>();
      final title = _readNullableString(titlePtr) ?? '';

      // char achievement_description[256] (offset 268)
      final descPtr = (buf + 268).cast<Utf8>();
      final desc = _readNullableString(descPtr) ?? '';

      // char achievement_badge_url[512] (offset 524)
      final badgePtr = (buf + 524).cast<Utf8>();
      final badge = _readNullableString(badgePtr) ?? '';

      // float achievement_rarity (offset 1036)
      final rarity = (buf + 1036).cast<Float>().value;

      // float achievement_rarity_hardcore (offset 1040)
      final rarityHc = (buf + 1040).cast<Float>().value;

      // uint8_t achievement_type (offset 1044)
      final achType = (buf + 1044).value;

      // char error_message[512] (offset 1045)
      final errMsgPtr = (buf + 1045).cast<Utf8>();
      final errMsg = _readNullableString(errMsgPtr) ?? '';

      // int error_code (offset 1560, 4-byte aligned)
      final errCode = (buf + 1560).cast<Int32>().value;

      return RcEvent(
        type: type,
        achievementId: achId,
        achievementPoints: achPoints,
        achievementTitle: title,
        achievementDescription: desc,
        achievementBadgeUrl: badge,
        achievementRarity: rarity,
        achievementRarityHardcore: rarityHc,
        achievementType: achType,
        errorMessage: errMsg,
        errorCode: errCode,
      );
    } catch (e) {
      debugPrint('RcheevosBindings.readEvent: FFI error — $e');
      return null;
    }
  }

  /// Free the event buffer. Call on dispose.
  void dispose() {
    if (_eventBuffer != null) {
      try {
        calloc.free(_eventBuffer!);
      } catch (e) {
        debugPrint('RcheevosBindings.dispose: free failed — $e');
      }
      _eventBuffer = null;
    }
  }
}
