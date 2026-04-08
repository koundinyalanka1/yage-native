import 'dart:async';
import 'dart:collection';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/rcheevos_bindings.dart';

const String _emulatorUserAgent = 'YAGE/1.0';

class RcheevosClient extends ChangeNotifier {
  final RcheevosBindings _bindings;
  bool _initialized = false;
  bool _loggedIn = false;
  bool _gameLoaded = false;
  String? _gameTitle;
  int _gameId = 0;
  String? _gameBadgeUrl;
  Timer? _pollTimer;
  bool _polling = false;          
  int _consecutiveIdlePolls = 0;  

  static const int _pollFastMs   = 16;   
  static const int _pollSlowMs   = 500;  
  static const int _idleThreshold = 10;  
  final _eventController = StreamController<RcEvent>.broadcast();
  final Queue<RcEvent> _notificationQueue = Queue();
  bool get isInitialized => _initialized;
  bool get isLoggedIn => _loggedIn;
  bool get isGameLoaded => _gameLoaded;
  String? get gameTitle => _gameTitle;
  int get gameId => _gameId;
  String? get gameBadgeUrl => _gameBadgeUrl;

  Stream<RcEvent> get events => _eventController.stream;

  bool get hasNotification => _notificationQueue.isNotEmpty;

  RcEvent? get nextNotification =>
      _notificationQueue.isNotEmpty ? _notificationQueue.first : null;

  RcEvent? consumeNotification() {
    if (_notificationQueue.isEmpty) return null;
    return _notificationQueue.removeFirst();
  }

  RcheevosClient(this._bindings);

  static String? _safeUtf8ToString(Pointer<Utf8>? ptr) {
    if (ptr == null) return null;
    if (ptr == nullptr || ptr.address == 0) return null;
    try {
      return ptr.toDartString();
    } catch (e) {
      debugPrint('RcheevosClient: failed to read native string at ${ptr.address} — $e');
      return null;
    }
  }

  bool initialize(Pointer<Void> yageCorePtr) {
    if (!_bindings.isLoaded) {
      if (!_bindings.load()) {
        debugPrint('RcheevosClient: bindings failed to load');
        return false;
      }
    }
    if (yageCorePtr == nullptr || yageCorePtr.address == 0) {
      debugPrint('RcheevosClient: invalid yageCore pointer');
      return false;
    }

    try {
      final result = _bindings.rcInit!(yageCorePtr);
      if (result != 0) {
        debugPrint('RcheevosClient: rc_init failed ($result)');
        return false;
      }
    } catch (e) {
      debugPrint('RcheevosClient: rc_init FFI error — $e');
      return false;
    }

    _initialized = true;
    _startPolling();

    debugPrint('RcheevosClient: initialized');
    notifyListeners();
    return true;
  }

  void shutdown({bool notify = true}) {
    _stopPolling();

    if (_initialized && _bindings.isLoaded) {
      try {
        _bindings.rcDestroy!();
      } catch (e) {
        debugPrint('RcheevosClient: rc_destroy FFI error — $e');
      }
    }

    _initialized = false;
    _loggedIn = false;
    _gameLoaded = false;
    _gameTitle = null;
    _gameId = 0;
    _gameBadgeUrl = null;
    _notificationQueue.clear();

    debugPrint('RcheevosClient: shutdown');
    if (notify) {
      notifyListeners();
    }
  }

  void setHardcoreEnabled(bool enabled) {
    if (!_initialized) return;
    _bindings.rcSetHardcore!(enabled ? 1 : 0);
  }

  void setEncoreEnabled(bool enabled) {
    if (!_initialized) return;
    _bindings.rcSetEncore!(enabled ? 1 : 0);
  }

  String? getUserAgentClause() {
    if (!_initialized) return null;
    final buf = calloc<Uint8>(256).cast<Utf8>();
    try {
      final len = _bindings.rcGetUserAgentClause!(buf, 256);
      if (len > 0) return buf.toDartString();
      return null;
    } finally {
      calloc.free(buf);
    }
  }

  void beginLogin(String username, String token) {
    if (!_initialized) return;

    final usernamePtr = username.toNativeUtf8();
    final tokenPtr = token.toNativeUtf8();
    try {
      _bindings.rcBeginLogin!(usernamePtr, tokenPtr);
      debugPrint('RcheevosClient: login started for $username');
    } finally {
      malloc.free(usernamePtr);
      malloc.free(tokenPtr);
    }
    _wakeUp();
  }

  void logout() {
    if (!_initialized) return;
    _bindings.rcLogout!();
    _loggedIn = false;
    notifyListeners();
  }

  void beginLoadGame(String hash) {
    if (!_initialized) return;

    final hashPtr = hash.toNativeUtf8();
    try {
      _bindings.rcBeginLoadGame!(hashPtr);
      debugPrint('RcheevosClient: game load started for hash $hash');
    } finally {
      malloc.free(hashPtr);
    }
    _wakeUp();
  }

  void unloadGame() {
    if (!_initialized) return;
    _bindings.rcUnloadGame!();
    _gameLoaded = false;
    _gameTitle = null;
    _gameId = 0;
    _gameBadgeUrl = null;
    _notificationQueue.clear();
    notifyListeners();
  }

  void reset() {
    if (!_initialized) return;
    _bindings.rcReset!();
  }

  void doFrame() {
    if (!_initialized || !_gameLoaded) return;
    _bindings.rcDoFrame!();
    _drainEvents();
  }

  void idle() {
    if (!_initialized) return;
    _bindings.rcIdle!();
  }

  ({int total, int unlocked, int totalPoints, int unlockedPoints})
      getAchievementSummary() {
    if (!_initialized || !_gameLoaded) {
      return (total: 0, unlocked: 0, totalPoints: 0, unlockedPoints: 0);
    }
    return (
      total: _bindings.rcGetAchievementCount!(),
      unlocked: _bindings.rcGetUnlockedCount!(),
      totalPoints: _bindings.rcGetTotalPoints!(),
      unlockedPoints: _bindings.rcGetUnlockedPoints!(),
    );
  }

  bool get isHardcoreEnabled {
    if (!_initialized) return false;
    return _bindings.rcGetHardcoreEnabled!() != 0;
  }

  void _startPolling() {
    _consecutiveIdlePolls = 0;
    _schedulePoll(Duration.zero);
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _schedulePoll(Duration delay) {
    _pollTimer?.cancel();
    if (!_initialized) return;
    _pollTimer = Timer(delay, _pollCycle);
  }

  void _wakeUp() {
    _consecutiveIdlePolls = 0;
    if (!_polling) {
      _schedulePoll(Duration.zero);
    }
  }

  Future<void> _pollCycle() async {
    if (!_initialized || _polling) return;
    _polling = true;

    bool didWork = false;
    try {
      didWork = await _processOneRequest();
      didWork |= _drainEvents();
    } finally {
      _polling = false;
    }

    if (!_initialized) return;
    if (didWork) {
      _consecutiveIdlePolls = 0;
      _schedulePoll(const Duration(milliseconds: _pollFastMs));
    } else {
      _consecutiveIdlePolls++;
      final ms = _consecutiveIdlePolls >= _idleThreshold
          ? _pollSlowMs
          : _pollFastMs;
      _schedulePoll(Duration(milliseconds: ms));
    }
  }

  Future<bool> _processOneRequest() async {
    if (!_initialized) return false;

    final requestId = _bindings.rcGetPendingRequest!();
    if (requestId == 0) return false;

    try {
      final urlPtr = _bindings.rcGetRequestUrl!(requestId);
      if (urlPtr == nullptr || urlPtr.address == 0) return false;
      final url = _safeUtf8ToString(urlPtr);
      if (url == null) return false;

      final postDataPtr = _bindings.rcGetRequestPostData!(requestId);
      final postData = _safeUtf8ToString(postDataPtr);

      final contentTypePtr = _bindings.rcGetRequestContentType!(requestId);
      final contentType = _safeUtf8ToString(contentTypePtr);
      final rcClause = getUserAgentClause() ?? '';
      final userAgent = '$_emulatorUserAgent $rcClause'.trim();

      debugPrint('RcheevosClient HTTP: ${postData != null ? "POST" : "GET"} '
          '$url (id=$requestId)');
      http.Response response;
      try {
        final uri = Uri.parse(url);
        final headers = <String, String>{
          'User-Agent': userAgent,
        };

        if (postData != null) {
          headers['Content-Type'] =
              contentType ?? 'application/x-www-form-urlencoded';
          response = await http
              .post(uri, headers: headers, body: postData)
              .timeout(const Duration(seconds: 15));
        } else {
          response = await http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 15));
        }
      } catch (e) {
        debugPrint('RcheevosClient HTTP: request failed: $e');
        _submitNativeResponse(requestId, null, 0, -1);
        return true; 
      }
      _submitNativeResponse(
        requestId,
        response.body,
        response.body.length,
        response.statusCode,
      );
    } catch (e) {
      debugPrint('RcheevosClient HTTP bridge error: $e');
    }

    return true;
  }

  void _submitNativeResponse(
      int requestId, String? body, int bodyLength, int httpStatus) {
    if (!_initialized) return;

    try {
      if (body != null && body.isNotEmpty) {
        final bodyPtr = body.toNativeUtf8();
        try {
          _bindings.rcSubmitResponse!(
              requestId, bodyPtr, bodyPtr.length, httpStatus);
        } finally {
          malloc.free(bodyPtr);
        }
      } else {
        _bindings.rcSubmitResponse!(
            requestId, nullptr.cast<Utf8>(), 0, httpStatus);
      }
    } catch (e) {
      debugPrint('RcheevosClient: rc_submit_response FFI error — $e');
    }
  }

  bool _drainEvents() {
    if (!_initialized) return false;

    bool didWork = false;
    try {
      while (_bindings.rcHasPendingEvent!() != 0) {
        final buf = _bindings.eventBuffer;
        if (buf == null) break;
        final result = _bindings.rcGetPendingEvent!(buf);
        if (result == 0) break;
        final event = _bindings.readEvent();
        if (event == null) {
          _bindings.rcConsumeEvent!();
          continue;
        }

        debugPrint('RcheevosClient event: $event');
        _handleEvent(event);
        _eventController.add(event);
        _bindings.rcConsumeEvent!();
        didWork = true;
      }
    } catch (e) {
      debugPrint('RcheevosClient: _drainEvents FFI error — $e');
    }
    return didWork;
  }

  void _handleEvent(RcEvent event) {
    switch (event.type) {
      case RcEventType.loginSuccess:
        _loggedIn = true;
        notifyListeners();
        break;

      case RcEventType.loginFailed:
        _loggedIn = false;
        notifyListeners();
        break;

      case RcEventType.gameLoadSuccess:
        _gameLoaded = true;
        _updateGameInfo();
        notifyListeners();
        break;

      case RcEventType.gameLoadFailed:
        _gameLoaded = false;
        _gameTitle = null;
        _gameId = 0;
        _gameBadgeUrl = null;
        notifyListeners();
        break;

      case RcEventType.achievementTriggered:
        _notificationQueue.add(event);
        notifyListeners();
        break;

      case RcEventType.gameCompleted:
        _notificationQueue.add(event);
        notifyListeners();
        break;

      case RcEventType.serverError:
        debugPrint('RcheevosClient: Server error: ${event.errorMessage}');
        break;

      case RcEventType.disconnected:
        debugPrint('RcheevosClient: Disconnected from server');
        break;

      case RcEventType.reconnected:
        debugPrint('RcheevosClient: Reconnected to server');
        break;
    }
  }

  void _updateGameInfo() {
    if (!_initialized) return;

    try {
      final titlePtr = _bindings.rcGetGameTitle!();
      _gameTitle = (titlePtr != nullptr && titlePtr.address != 0)
          ? titlePtr.toDartString()
          : null;

      _gameId = _bindings.rcGetGameId!();

      final badgePtr = _bindings.rcGetGameBadgeUrl!();
      _gameBadgeUrl = (badgePtr != nullptr && badgePtr.address != 0)
          ? badgePtr.toDartString()
          : null;

      debugPrint('RcheevosClient: Game info updated — '
          'title="$_gameTitle", id=$_gameId');
    } catch (e) {
      debugPrint('RcheevosClient: _updateGameInfo FFI error — $e');
    }
  }

  @override
  void dispose() {
    shutdown(notify: false);
    _eventController.close();
    _bindings.dispose();
    super.dispose();
  }
}
