import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/mgba_bindings.dart';
import '../core/rcheevos_hash_bindings.dart';
import '../models/game_rom.dart';
import '../models/ra_achievement.dart';

// ═══════════════════════════════════════════════════════════════════════
//  RetroAchievements Console ID mapping
// ═══════════════════════════════════════════════════════════════════════

/// Maps internal [GamePlatform] values to RetroAchievements console IDs.
///
/// Official RA console IDs for supported platforms:
///   • Mega Drive     → 1
///   • SNES           → 3
///   • Game Boy       → 4
///   • Game Boy Advance → 5
///   • Game Boy Color → 6
///   • NES            → 7
///   • PC Engine      → 8
///   • Master System  → 11
///   • Game Gear      → 15
///   • TIC-80         → 65
///   • PICO-8         → 68
class RAConsoleId {
  RAConsoleId._();

  static const int megaDrive = 1;
  static const int nintendo64 = 2;
  static const int snes = 3;
  static const int gameBoy = 4;
  static const int gameBoyAdvance = 5;
  static const int gameBoyColor = 6;
  static const int nes = 7;
  static const int pcEngine = 8;
  static const int masterSystem = 11;
  static const int gameGear = 15;
  static const int sg1000 = 33;
  static const int neoGeoPocket = 14;
  static const int wonderSwan = 53;
  static const int atari2600 = 25;
  static const int virtualBoy = 28;
  static const int nintendoDS = 18;
  static const int playStation = 12;
  static const int intellivision = 45;
  static const int tic80 = 65;
  static const int pico = 68;

  /// Resolve [GamePlatform] → RA console ID.
  /// Returns `null` for unknown / unsupported platforms.
  static int? fromPlatform(GamePlatform platform) {
    return switch (platform) {
      GamePlatform.gb => gameBoy,
      GamePlatform.gba => gameBoyAdvance,
      GamePlatform.gbc => gameBoyColor,
      GamePlatform.nes => nes,
      GamePlatform.snes => snes,
      GamePlatform.sms => masterSystem,
      GamePlatform.gg => gameGear,
      GamePlatform.md => megaDrive,
      GamePlatform.pce => pcEngine,
      GamePlatform.sgx => pcEngine,
      GamePlatform.n64 => nintendo64,
      GamePlatform.sg1000 => sg1000,
      GamePlatform.ngp => neoGeoPocket,
      GamePlatform.ws => wonderSwan,
      GamePlatform.wsc => wonderSwan,
      GamePlatform.a2600 => atari2600,
      GamePlatform.vb => virtualBoy,
      GamePlatform.tic80 => tic80,
      GamePlatform.pico8 => pico,
      GamePlatform.nds => nintendoDS,
      GamePlatform.ps1 => playStation,
      GamePlatform.intv => intellivision,
      GamePlatform.unknown => null,
    };
  }

  /// Human-readable label for a console ID (for debug / logging).
  static String label(int id) {
    return switch (id) {
      megaDrive => 'Mega Drive',
      nintendo64 => 'Nintendo 64',
      snes => 'SNES',
      gameBoy => 'Game Boy',
      gameBoyAdvance => 'Game Boy Advance',
      gameBoyColor => 'Game Boy Color',
      nes => 'NES',
      pcEngine => 'PC Engine / TurboGrafx-16',
      masterSystem => 'Master System',
      gameGear => 'Game Gear',
      sg1000 => 'SG-1000',
      neoGeoPocket => 'Neo Geo Pocket',
      wonderSwan => 'WonderSwan',
      atari2600 => 'Atari 2600',
      virtualBoy => 'Virtual Boy',
      nintendoDS => 'Nintendo DS',
      playStation => 'PlayStation',
      intellivision => 'Intellivision',
      tic80 => 'TIC-80',
      pico => 'PICO-8',
      _ => 'Unknown ($id)',
    };
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Game session tracking
// ═══════════════════════════════════════════════════════════════════════

/// Tracks the RetroAchievements state for the currently loaded game.
class RAGameSession {
  /// The RA-assigned game ID (> 0 means achievements are available).
  final int gameId;

  /// The MD5 hash that was sent to the API.
  final String romHash;

  /// The RA console ID used.
  final int consoleId;

  /// Whether achievements are enabled for this session.
  /// `true` when [gameId] > 0 and the user is logged in.
  final bool achievementsEnabled;

  /// The local ROM file path this session was created for.
  ///
  /// Used to verify that an existing session actually belongs to the game
  /// being launched.  Without this check, a session left over from a
  /// previous game (e.g. achievements browsed from the home screen, or an
  /// exit path that skipped endGameSession) was reused verbatim for the
  /// next game — its title toast popped up in the wrong game and, far
  /// worse, the native rcheevos client loaded the OLD game's achievement
  /// set and evaluated it against the NEW game's memory, firing bogus
  /// unlock notifications.
  final String romPath;

  const RAGameSession({
    required this.gameId,
    required this.romHash,
    required this.consoleId,
    required this.achievementsEnabled,
    required this.romPath,
  });

  @override
  String toString() =>
      'RAGameSession(gameId=$gameId, hash=$romHash, '
      'console=${RAConsoleId.label(consoleId)}, '
      'achievements=${achievementsEnabled ? "ON" : "OFF"})';
}

/// Represents the authenticated RetroAchievements user profile.
class RAUserProfile {
  final String username;
  final String profileImageUrl;
  final int totalPoints;
  final int totalSoftcorePoints;
  final int totalTruePoints;
  final int? softcoreRank;
  final String memberSince;
  final String? motto;

  const RAUserProfile({
    required this.username,
    required this.profileImageUrl,
    required this.totalPoints,
    required this.totalSoftcorePoints,
    required this.totalTruePoints,
    this.softcoreRank,
    required this.memberSince,
    this.motto,
  });

  factory RAUserProfile.fromJson(Map<String, dynamic> json) {
    final username = json['User'] as String? ?? json['user'] as String? ?? '';
    return RAUserProfile(
      username: username,
      profileImageUrl: _normalizeAvatarUrl(
        json['UserPic'] ?? json['userPic'],
        username,
      ),
      totalPoints: _toInt(json['TotalPoints'] ?? json['totalPoints']),
      totalSoftcorePoints: _toInt(
        json['TotalSoftcorePoints'] ?? json['totalSoftcorePoints'],
      ),
      totalTruePoints: _toInt(
        json['TotalTruePoints'] ?? json['totalTruePoints'],
      ),
      softcoreRank: _toOptionalPositiveInt(
        json['SoftcoreRank'] ?? json['softcoreRank'],
      ),
      memberSince:
          json['MemberSince'] as String? ??
          json['memberSince'] as String? ??
          '',
      motto: json['Motto'] as String? ?? json['motto'] as String?,
    );
  }

  factory RAUserProfile.fromLoginResponse(
    Map<String, dynamic> json,
    String fallbackUsername,
  ) {
    final username =
        json['User'] as String? ?? json['user'] as String? ?? fallbackUsername;
    return RAUserProfile(
      username: username,
      profileImageUrl: _normalizeAvatarUrl(
        json['AvatarUrl'] ?? json['UserPic'] ?? json['userPic'],
        username,
      ),
      totalPoints: _toInt(json['Score'] ?? json['TotalPoints']),
      totalSoftcorePoints: _toInt(
        json['SoftcoreScore'] ?? json['TotalSoftcorePoints'],
      ),
      totalTruePoints: _toInt(json['TotalTruePoints']),
      softcoreRank: _toOptionalPositiveInt(
        json['SoftcoreRank'] ?? json['softcoreRank'],
      ),
      memberSince: json['MemberSince'] as String? ?? '',
      motto: json['Motto'] as String?,
    );
  }

  RAUserProfile copyWith({
    int? totalPoints,
    int? totalSoftcorePoints,
    int? totalTruePoints,
    int? softcoreRank,
  }) {
    return RAUserProfile(
      username: username,
      profileImageUrl: profileImageUrl,
      totalPoints: totalPoints ?? this.totalPoints,
      totalSoftcorePoints: totalSoftcorePoints ?? this.totalSoftcorePoints,
      totalTruePoints: totalTruePoints ?? this.totalTruePoints,
      softcoreRank: softcoreRank ?? this.softcoreRank,
      memberSince: memberSince,
      motto: motto,
    );
  }

  String get displayPoints =>
      '$totalPoints points . $totalSoftcorePoints softcore points';

  String? get displaySoftcoreRank {
    final rank = softcoreRank;
    if (rank == null || rank <= 0) return null;
    return 'Softcore rank #$rank';
  }

  String get displaySummary {
    final rankLine = displaySoftcoreRank;
    if (rankLine == null) return displayPoints;
    return '$displayPoints\n$rankLine';
  }

  static String _normalizeAvatarUrl(dynamic value, String username) {
    final raw = value is String ? value : '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return 'https://retroachievements.org$raw';
    return 'https://retroachievements.org/UserPic/$username.png';
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static int? _toOptionalPositiveInt(dynamic v) {
    final value = _toInt(v);
    return value > 0 ? value : null;
  }
}

/// Result of a login attempt.
class RALoginResult {
  final bool success;
  final String? errorMessage;
  final RAUserProfile? profile;

  const RALoginResult._({
    required this.success,
    this.errorMessage,
    this.profile,
  });

  factory RALoginResult.ok(RAUserProfile profile) =>
      RALoginResult._(success: true, profile: profile);

  factory RALoginResult.error(String message) =>
      RALoginResult._(success: false, errorMessage: message);
}

/// Service for managing RetroAchievements authentication and state.
///
/// Credentials (username + password) are stored in Android Keystore /
/// iOS Keychain via [FlutterSecureStorage].  A Connect API token is
/// obtained via `login2` and used for all RA API calls.
class RetroAchievementsService extends ChangeNotifier {
  // ── Secure storage keys ──────────────────────────────────────────────
  static const String _keyUsername = 'ra_username';
  static const String _keyPassword = 'ra_password';
  static const String _keyConnectToken = 'ra_connect_token';

  // ── Secure storage instance ──────────────────────────────────────────
  // AndroidOptions: If Android keystore material becomes invalid after
  // restore/reinstall, clear secure prefs instead of repeatedly failing.
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      // If Android keystore material becomes invalid after restore/reinstall,
      // clear secure prefs instead of repeatedly failing every access.
      resetOnError: true,
    ),
  );

  static bool _isRecoveringSecureStorage = false;

  static bool _isKeystoreError(Object error) {
    if (error is! PlatformException) return false;
    final text = '${error.code} ${error.message ?? ''} ${error.details ?? ''}'
        .toLowerCase();
    return text.contains('keystore') ||
        text.contains('aeadbadtag') ||
        text.contains('unwrap') ||
        text.contains('invalidkeyexception') ||
        text.contains('failed to unwrap key') ||
        (text.contains('crypto') &&
            (text.contains('failed') || text.contains('invalid')));
  }

  static Future<void> _recoverSecureStorage() async {
    if (_isRecoveringSecureStorage) return;
    _isRecoveringSecureStorage = true;
    try {
      await _storage.deleteAll();
      debugPrint('RA secure storage: cleared corrupted keystore-backed data');
    } catch (e) {
      debugPrint('RA secure storage: deleteAll failed during recovery: $e');
    } finally {
      _isRecoveringSecureStorage = false;
    }
  }

  static Future<String?> _secureRead(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      if (!_isKeystoreError(e)) rethrow;
      if (_isRecoveringSecureStorage) {
        debugPrint('RA secure storage: read suppressed during active recovery');
        return null;
      }
      await _recoverSecureStorage();
      try {
        return await _storage.read(key: key);
      } catch (retryError) {
        debugPrint('RA secure storage read failed after recovery: $retryError');
        return null;
      }
    }
  }

  static Future<void> _secureWrite(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      if (!_isKeystoreError(e)) rethrow;
      if (_isRecoveringSecureStorage) {
        debugPrint('RA secure storage: write failed during active recovery');
        rethrow;
      }
      await _recoverSecureStorage();
      await _storage.write(key: key, value: value);
    }
  }

  static Future<void> _secureDelete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      if (!_isKeystoreError(e)) rethrow;
      await _recoverSecureStorage();
    }
  }

  // ── State ────────────────────────────────────────────────────────────
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _username;
  RAUserProfile? _profile;
  String? _lastError;

  // ── Connect API token ───────────────────────────────────────────────
  //  All RA API calls go through `dorequest.php` with a Connect token.
  //  Obtained via `login2` with username + password.
  String? _connectToken;

  // ── Game session state ──────────────────────────────────────────────
  RAGameSession? _activeSession;
  bool _isResolvingGame = false;

  // ── Achievement data state ─────────────────────────────────────────
  RAGameData? _gameData;
  bool _isLoadingGameData = false;

  // ── Lookup caches (avoid repeated hashing / API calls) ────────────
  //  • _romHashCache:  "romPath|fileSize" → MD5 hex string
  //  • _gameIdCache:   MD5 hex string     → RA game ID (int)
  //  Both are persisted to SharedPreferences so they survive restarts.
  static const String _prefRomHashCache = 'ra_rom_hash_cache';
  static const String _prefGameIdCache = 'ra_game_id_cache';
  Map<String, String> _romHashCache = {};
  Map<String, int> _gameIdCache = {};

  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  String? get username => _username;
  RAUserProfile? get profile => _profile;

  /// The last error message from login / init, or `null` if no error.
  /// Cleared on successful login, logout, or explicit [clearError].
  String? get lastError => _lastError;

  final Completer<void> _initCompleter = Completer<void>();

  /// Future that completes when [initialize] has finished (including the
  /// networked profile refresh).
  Future<void> get whenReady => _initCompleter.future;

  /// Completes as soon as the persisted login state has been restored from
  /// secure storage — i.e. [isLoggedIn] is authoritative — WITHOUT waiting
  /// for the network profile refresh.
  ///
  /// Use this to gate startup UI that only depends on whether the user is
  /// logged in (e.g. the home screen). For a logged-out user it completes
  /// almost immediately; for a returning user with a persisted token it
  /// completes as soon as the token is read (the profile refresh continues
  /// in the background). It is guaranteed to complete on every path —
  /// including errors — so it can never hang the app.
  final Completer<void> _localReadyCompleter = Completer<void>();
  Future<void> get whenLocallyReady => _localReadyCompleter.future;

  void _markLocallyReady() {
    if (!_localReadyCompleter.isCompleted) _localReadyCompleter.complete();
  }

  /// The active game session, if a ROM has been identified.
  RAGameSession? get activeSession => _activeSession;

  /// Whether we are currently resolving a game ID for a loaded ROM.
  bool get isResolvingGame => _isResolvingGame;

  /// Achievement metadata for the current game, or `null` if not yet loaded.
  RAGameData? get gameData => _gameData;

  /// Whether achievement data is currently being fetched from API / disk.
  bool get isLoadingGameData => _isLoadingGameData;

  /// Convenience: are achievements enabled for the current session?
  bool get achievementsEnabled => _activeSession?.achievementsEnabled ?? false;

  // ── Initialisation (call once at app start) ──────────────────────────

  /// Loads persisted credentials from secure storage and silently
  /// re-validates them.  If validation fails the user is logged out.
  Future<void> initialize() async {
    _isLoading = true;
    _lastError = null;
    notifyListeners();

    // Load lookup caches from disk (fire-and-forget-safe)
    await _loadLookupCaches();

    try {
      debugPrint('RA: Attempting to restore session from secure storage...');
      final storedUser = await _secureRead(_keyUsername);
      final storedPassword = await _secureRead(_keyPassword);

      if (storedUser != null &&
          storedUser.isNotEmpty &&
          storedPassword != null &&
          storedPassword.isNotEmpty) {
        debugPrint('RA: Stored credentials found; restoring session');
        // Try to restore persisted connect token first
        _connectToken = await _secureRead(_keyConnectToken);

        if (_connectToken != null) {
          // Token found — assume valid. Refresh through login2 to recover
          // current point totals, but stay logged in if the network is down.
          _username = storedUser;
          _profile = _buildProfile(storedUser);
          _isLoggedIn = true;
          _lastError = null;
          // Login state is authoritative from the persisted token — release
          // the startup gate now. The network profile refresh below is a
          // non-blocking nicety and must never delay reaching the home screen.
          _markLocallyReady();
          notifyListeners();
          final refreshedProfile = await _obtainConnectToken(
            storedUser,
            storedPassword,
          );
          if (refreshedProfile != null) {
            _username = refreshedProfile.username;
            _profile = refreshedProfile;
          }
          debugPrint('RA: Restored session for $storedUser');
        } else {
          // No token — re-acquire from password
          final profile = await _obtainConnectToken(storedUser, storedPassword);
          if (profile != null) {
            _username = profile.username;
            _profile = profile;
            _isLoggedIn = true;
            _lastError = null;
          } else {
            _lastError = 'Login failed — password may have changed.';
            await _clearCredentials();
          }
        }
      } else {
        debugPrint('RA: No recoverable secure credentials found');
      }
    } catch (e) {
      debugPrint('RA init error: $e');
      _lastError = 'Initialization error: $e';
    }

    _isLoading = false;
    notifyListeners();
    // Safety net: guarantee the startup gate is released on every path
    // (no stored credentials, no-token password login, or an error above).
    _markLocallyReady();
    if (!_initCompleter.isCompleted) _initCompleter.complete();
  }

  /// Build a minimal profile from username (no web API call needed).
  RAUserProfile _buildProfile(String username) {
    return RAUserProfile(
      username: username,
      profileImageUrl: 'https://retroachievements.org/UserPic/$username.png',
      totalPoints: 0,
      totalSoftcorePoints: 0,
      totalTruePoints: 0,
      memberSince: '',
    );
  }

  // ── Login ────────────────────────────────────────────────────────────

  /// Attempt to log in with the given [username] and [password].
  ///
  /// Calls the RA Connect API `login2` endpoint to validate credentials
  /// and obtain a session token.  On success the credentials are
  /// persisted to secure storage and the service is *logged in*.
  Future<RALoginResult> login(String username, String password) async {
    if (username.trim().isEmpty || password.trim().isEmpty) {
      return RALoginResult.error('Username and password are required.');
    }

    _isLoading = true;
    notifyListeners();

    try {
      final profile = await _obtainConnectToken(
        username.trim(),
        password.trim(),
      );

      if (profile != null) {
        await _secureWrite(_keyUsername, profile.username);
        await _secureWrite(_keyPassword, password.trim());

        _username = profile.username;
        _profile = profile;
        _isLoggedIn = true;
        _lastError = null;

        _isLoading = false;
        notifyListeners();
        return RALoginResult.ok(_profile!);
      } else {
        _lastError = 'Login failed — check username and password.';
        _isLoading = false;
        notifyListeners();
        return RALoginResult.error(_lastError!);
      }
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return RALoginResult.error('Unexpected error: $e');
    }
  }

  // ── Logout ───────────────────────────────────────────────────────────

  /// Wipe stored credentials, clear achievement cache, and reset state.
  Future<void> logout() async {
    await _clearCredentials();
    await _clearCachedGameData();
    _username = null;
    _profile = null;
    _isLoggedIn = false;
    _activeSession = null;
    _gameData = null;
    _lastError = null;
    _connectToken = null;
    notifyListeners();
  }

  /// Clear the last error state (e.g. after the user acknowledges it).
  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  // ── Credential helpers ───────────────────────────────────────────────

  /// Read the stored password (for pre-filling the login form).
  Future<String?> getStoredPassword() async {
    return _secureRead(_keyPassword);
  }

  Future<void> _clearCredentials() async {
    await _secureDelete(_keyUsername);
    await _secureDelete(_keyPassword);
    await _secureDelete(_keyConnectToken);
    // Also clean up legacy API key if it exists
    await _secureDelete('ra_api_key');
  }

  /// Obtain a Connect API token via `dorequest.php?r=login2`.
  ///
  /// The Connect token is used for all RA API calls (startsession,
  /// ping, awardachievement, patch, gameid).
  Future<RAUserProfile?> _obtainConnectToken(
    String username,
    String password,
  ) async {
    final uri = Uri.parse('https://retroachievements.org/dorequest.php');

    try {
      // Use POST so the password travels in the request body instead of
      // the URL.  Passwords in query strings are logged by web servers,
      // proxies, and may appear in Crashlytics crash reports.
      final response = await _httpWithRetry(
        () => http
            .post(uri, body: {'r': 'login2', 'u': username, 'p': password})
            .timeout(const Duration(seconds: 10)),
      );

      if (response.statusCode != 200) {
        debugPrint('RA Connect: login2 HTTP ${response.statusCode}');
        return null;
      }

      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> &&
          body['Success'] == true &&
          body['Token'] is String) {
        _connectToken = body['Token'] as String;
        // Persist token (NOT the password) for future sessions
        await _secureWrite(_keyConnectToken, _connectToken!);
        debugPrint('RA Connect: login2 OK — token acquired & persisted');
        return RAUserProfile.fromLoginResponse(body, username);
      }

      debugPrint('RA Connect: login2 failed — ${response.body}');
      return null;
    } catch (e) {
      debugPrint('RA Connect: login2 error: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Game Detection — ROM hash + API_GetGameID
  // ═══════════════════════════════════════════════════════════════════════

  /// Start a RetroAchievements session for the given [rom].
  ///
  /// Steps performed (all locally except the final API call):
  ///   1. Map [GameRom.platform] → RA console ID.
  ///   2. Compute the RA-compatible MD5 hash of the ROM file **locally**.
  ///      The hash is cached so subsequent calls for the same ROM are instant.
  ///      No ROM data is uploaded — only the 32-char hex hash is sent.
  ///   3. Call `API_GetGameID` with the console ID and ROM hash.
  ///      The result is cached so the API is only called once per hash.
  ///   4. If a valid game ID (> 0) is returned, enable achievements.
  ///      Otherwise disable them silently for this game.
  ///
  /// When [awaitData] is `true` (e.g. when showing the achievements list
  /// from the home screen), achievement metadata loading is awaited before
  /// returning.  When `false` (default — used during gameplay), the data
  /// loads in the background so gameplay is never blocked.
  ///
  /// The session is stored in [activeSession] and listeners are notified.
  /// If the user is not logged in, the session is still created but
  /// achievements are marked as disabled.
  Future<void> startGameSession(GameRom rom, {bool awaitData = false}) async {
    // ── 0. De-duplicate concurrent resolution for the same ROM ────────
    // The home screen fires this fire-and-forget on launch and the game
    // screen may call it again moments later.  Running two resolutions
    // concurrently is wasteful and can interleave notifications; share
    // the in-flight future instead.
    if (_inflightSessionRomPath == rom.path && _inflightSession != null) {
      await _inflightSession;
      if (awaitData &&
          _activeSession != null &&
          _activeSession!.gameId > 0 &&
          _isLoggedIn &&
          _gameData == null) {
        await _loadGameData(_activeSession!.gameId);
      }
      return;
    }

    final future = _startGameSessionInner(rom, awaitData: awaitData);
    _inflightSession = future;
    _inflightSessionRomPath = rom.path;
    try {
      await future;
    } finally {
      if (identical(_inflightSession, future)) {
        _inflightSession = null;
        _inflightSessionRomPath = null;
      }
    }
  }

  Future<void>? _inflightSession;
  String? _inflightSessionRomPath;

  Future<void> _startGameSessionInner(
    GameRom rom, {
    required bool awaitData,
  }) async {
    // ── 1. Clear any stale state from a previous game FIRST ───────────
    // A new session must never expose the previous game's session or
    // achievement data — the UI reacts to notifyListeners() and would
    // otherwise show the old game's toast (and the native client could
    // load the old game's achievement set) in the new game.
    if (_activeSession?.romPath != rom.path) {
      _activeSession = null;
      _gameData = null;
    }

    // ── 2. Console ID ─────────────────────────────────────────────────
    final consoleId = RAConsoleId.fromPlatform(rom.platform);
    if (consoleId == null) {
      debugPrint(
        'RA: Unsupported platform ${rom.platformName} — '
        'achievements disabled',
      );
      _activeSession = null;
      notifyListeners();
      return;
    }

    _isResolvingGame = true;
    notifyListeners();

    try {
      // ── 2. Compute ROM hash (cached / isolate) ─────────────────────
      final romHash = await _getOrComputeHash(rom.path, consoleId);
      if (romHash == null) {
        debugPrint(
          'RA: Failed to hash ROM ${rom.name} — '
          'achievements disabled',
        );
        _activeSession = null;
        _isResolvingGame = false;
        notifyListeners();
        return;
      }

      debugPrint(
        'RA: ROM hash for "${rom.name}" '
        '[${RAConsoleId.label(consoleId)}] = $romHash',
      );

      // ── 3. Resolve Game ID (cached / API) ──────────────────────────
      final gameId = await _getOrResolveGameId(romHash);

      // ── 4. Build session ──────────────────────────────────────────
      final enabled = gameId > 0 && _isLoggedIn;
      _activeSession = RAGameSession(
        gameId: gameId,
        romHash: romHash,
        consoleId: consoleId,
        achievementsEnabled: enabled,
        romPath: rom.path,
      );

      if (gameId > 0) {
        debugPrint(
          'RA: Game identified — ID=$gameId, '
          'achievements=${enabled ? "ENABLED" : "DISABLED (not logged in)"}',
        );
      } else {
        debugPrint(
          'RA: No game found for hash $romHash — '
          'achievements disabled',
        );
      }
    } catch (e) {
      debugPrint(
        'RA: Error during game detection: $e — '
        'achievements disabled',
      );
      _activeSession = null;
    }

    _isResolvingGame = false;
    notifyListeners();

    // ── 5. Load achievement data ──────────────────────────────────────
    if (_activeSession != null && _activeSession!.gameId > 0 && _isLoggedIn) {
      if (awaitData) {
        // Await fully — caller needs the data immediately (e.g. achievements list)
        await _loadGameData(_activeSession!.gameId);
      } else {
        // Fire-and-forget — gameplay is never blocked
        _loadGameData(_activeSession!.gameId);
      }
    }
  }

  /// End the current game session (call when the ROM is unloaded).
  void endGameSession() {
    if (_activeSession == null && _gameData == null) return;
    debugPrint('RA: Session ended for game ID=${_activeSession?.gameId}');
    _activeSession = null;
    _gameData = null;
    _isResolvingGame = false;
    _isLoadingGameData = false;
    notifyListeners();
  }

  // ── ROM Hashing (cached + background isolate) ──────────────────────

  /// Return the cached hash for [romPath], or compute it in a background
  /// isolate and cache the result.  The cache key includes file size so
  /// a replaced ROM with the same name is re-hashed automatically.
  Future<String?> _getOrComputeHash(String romPath, int consoleId) async {
    try {
      final file = File(romPath);
      if (!await file.exists()) {
        debugPrint('RA hash: file not found — $romPath');
        return null;
      }
      final size = await file.length();
      final cacheKey = 'rhash-v2|$consoleId|$romPath|$size';

      // Cache hit → instant return
      final cached = _romHashCache[cacheKey];
      if (cached != null) {
        debugPrint('RA hash: cache hit for "$romPath"');
        return cached;
      }

      // Cache miss → compute the official rcheevos hash in a background
      // isolate so large ROM/disc images never jank the UI thread.
      final hash = await compute(computeRAHashForConsole, {
        'path': romPath,
        'consoleId': consoleId,
      });
      if (hash != null) {
        _romHashCache[cacheKey] = hash;
        _persistLookupCaches(); // fire-and-forget
      }
      return hash;
    } catch (e) {
      debugPrint('RA hash error: $e');
      return null;
    }
  }

  /// Compute the RetroAchievements-compatible hash for a ROM file.
  ///
  /// **Hashing rules (per RA spec):**
  ///   • **Game Boy / GBC / GBA / SMS / GG / MD:**  MD5 of the entire ROM file.
  ///   • **NES:**  Strip the 16-byte iNES header (and 512-byte trainer if
  ///     present), then MD5 the remaining PRG+CHR data.
  ///   • **SNES:**  If the file size mod 1024 == 512, strip the 512-byte
  ///     copier header, then MD5 the rest.
  ///
  /// All hashing is done **locally** — no ROM data leaves the device.
  /// Returns the lowercase 32-character hex MD5 string, or `null` on
  /// error (file not found, read failure, etc.).
  ///
  /// Prefer [_getOrComputeHash] which adds caching on top.
  static Future<String?> computeRAHash(String romPath) async {
    try {
      final file = File(romPath);
      if (!await file.exists()) {
        debugPrint('RA hash: file not found — $romPath');
        return null;
      }

      final ext = p.extension(romPath).toLowerCase();

      // ── NES / iNES-style dumps: strip iNES header + optional trainer; else full-file MD5 (e.g. UNIF)
      if (ext == '.nes' || ext == '.unf' || ext == '.unif') {
        final bytes = await file.readAsBytes();
        if (bytes.length < 16) return null;
        // Check for iNES magic: "NES\x1A"
        final hasHeader =
            bytes[0] == 0x4E &&
            bytes[1] == 0x45 &&
            bytes[2] == 0x53 &&
            bytes[3] == 0x1A;
        if (hasHeader) {
          final hasTrainer = (bytes[6] & 0x04) != 0;
          final offset = 16 + (hasTrainer ? 512 : 0);
          if (offset >= bytes.length) return null;
          final digest = md5.convert(bytes.sublist(offset));
          return digest.toString();
        }
        // No iNES header — hash entire file
        final digest = md5.convert(bytes);
        return digest.toString();
      }

      // ── SNES: strip optional 512-byte copier header
      if (ext == '.sfc' || ext == '.smc') {
        final stat = await file.stat();
        final size = stat.size;
        final hasHeader = (size % 1024) == 512;
        if (hasHeader) {
          final bytes = await file.readAsBytes();
          final digest = md5.convert(bytes.sublist(512));
          return digest.toString();
        }
        // No copier header — stream-hash entire file
        final digest = await md5.bind(file.openRead()).first;
        return digest.toString();
      }

      // ── GB / GBC / GBA: hash entire file ──
      final digest = await md5.bind(file.openRead()).first;
      return digest.toString(); // lowercase hex string
    } catch (e) {
      debugPrint('RA hash error: $e');
      return null;
    }
  }

  /// Compute the official rcheevos hash for a file when the native wrapper is
  /// available. Falls back to the legacy Dart MD5 rules only for consoles where
  /// those rules are known to be equivalent.
  static Future<String?> computeRAHashForConsole(
    Map<String, Object?> args,
  ) async {
    final romPath = args['path'] as String?;
    final consoleId = args['consoleId'] as int?;
    if (romPath == null || romPath.isEmpty) return null;

    if (consoleId != null) {
      final nativeHash = RcheevosHashBindings.hashFile(
        consoleId: consoleId,
        path: romPath,
      );
      if (nativeHash != null) return nativeHash;

      if (_requiresNativeRcheevosHash(consoleId)) {
        debugPrint(
          'RA hash: official rcheevos hash failed for "$romPath" '
          '(${RAConsoleId.label(consoleId)})',
        );
        return null;
      }
    }

    return computeRAHash(romPath);
  }

  static bool _requiresNativeRcheevosHash(int consoleId) {
    return switch (consoleId) {
      RAConsoleId.nintendoDS ||
      RAConsoleId.playStation ||
      RAConsoleId.nintendo64 => true,
      _ => false,
    };
  }

  /// Compute content hash from bytes (for in-memory ROM data, e.g. ZIP extraction).
  /// Uses same platform-specific rules as [computeRAHash].
  static String? computeRAHashFromBytes(Uint8List bytes, String extension) {
    try {
      final ext = extension.toLowerCase();

      if (ext == '.nes' || ext == '.unf' || ext == '.unif') {
        if (bytes.length < 16) return null;
        final hasHeader =
            bytes[0] == 0x4E &&
            bytes[1] == 0x45 &&
            bytes[2] == 0x53 &&
            bytes[3] == 0x1A;
        if (hasHeader) {
          final hasTrainer = (bytes[6] & 0x04) != 0;
          final offset = 16 + (hasTrainer ? 512 : 0);
          if (offset >= bytes.length) return null;
          return md5.convert(bytes.sublist(offset)).toString();
        }
        return md5.convert(bytes).toString();
      }

      if (ext == '.sfc' || ext == '.smc') {
        final hasHeader = (bytes.length % 1024) == 512;
        if (hasHeader && bytes.length > 512) {
          return md5.convert(bytes.sublist(512)).toString();
        }
        return md5.convert(bytes).toString();
      }

      return md5.convert(bytes).toString();
    } catch (e) {
      debugPrint('RA hash from bytes error: $e');
      return null;
    }
  }

  // ── Game ID resolution (cached) ─────────────────────────────────────

  /// Return the cached game ID for [hash], or resolve it via API and
  /// cache the result.  A game ID of 0 (not recognised) is also cached
  /// so we don't keep hitting the network for unsupported ROMs.
  Future<int> _getOrResolveGameId(String hash) async {
    final cached = _gameIdCache[hash];
    if (cached != null) {
      debugPrint('RA gameId: cache hit for hash $hash → $cached');
      return cached;
    }

    final gameId = await _resolveGameId(hash);
    _gameIdCache[hash] = gameId;
    _persistLookupCaches(); // fire-and-forget
    return gameId;
  }

  // ── API_GetGameID ───────────────────────────────────────────────────

  /// Call the RetroAchievements game-ID resolution endpoint.
  ///
  /// ```
  /// GET https://retroachievements.org/dorequest.php
  ///   ?r=gameid
  ///   &m=<md5hash>
  /// ```
  ///
  /// Returns the numeric game ID (> 0) on success, or `0` if the hash
  /// is not recognised.  Network / parse errors also return `0` so that
  /// achievements are silently disabled rather than crashing the app.
  Future<int> _resolveGameId(String hash) async {
    final uri = Uri.parse(
      'https://retroachievements.org/dorequest.php',
    ).replace(queryParameters: {'r': 'gameid', 'm': hash});

    try {
      final response = await _httpWithRetry(
        () => http.get(uri).timeout(const Duration(seconds: 10)),
      );

      if (response.statusCode != 200) {
        debugPrint('RA API_GetGameID: HTTP ${response.statusCode}');
        return 0;
      }

      final dynamic body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        debugPrint('RA API_GetGameID: unexpected response format');
        return 0;
      }

      final success = body['Success'] as bool? ?? false;
      if (!success) {
        debugPrint('RA API_GetGameID: Success=false');
        return 0;
      }

      final gameId = _parseGameId(body['GameID']);
      return gameId;
    } on http.ClientException catch (e) {
      debugPrint('RA API_GetGameID network error: $e');
      return 0;
    } on FormatException catch (e) {
      debugPrint('RA API_GetGameID parse error: $e');
      return 0;
    } catch (e) {
      if (e.toString().contains('TimeoutException')) {
        debugPrint('RA API_GetGameID: timed out');
      } else {
        debugPrint('RA API_GetGameID error: $e');
      }
      return 0;
    }
  }

  /// Parse a game ID from the API response (may be int or String).
  static int _parseGameId(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Achievement Metadata — cache-first loading with background refresh
  // ═══════════════════════════════════════════════════════════════════════
  //
  //  Refresh policy:
  //  ┌──────────────────────────────────────────────────────────────────┐
  //  │ Cache state        │ Action                                     │
  //  ├────────────────────┼────────────────────────────────────────────│
  //  │ No cache           │ Fetch from API, cache result               │
  //  │ Cache < 24 h old   │ Serve cache, no network call               │
  //  │ Cache ≥ 24 h old   │ Serve cache immediately, refresh in bg     │
  //  │ Network failure    │ Serve cache (any age), or null if no cache │
  //  └──────────────────────────────────────────────────────────────────┘
  //
  //  Badge images are NOT pre-fetched. The model exposes URL getters
  //  (badgeUrl / badgeLockedUrl) that the UI loads lazily on demand
  //  via Image.network() or any caching image widget.

  /// Load achievement metadata for the given [gameId].
  ///
  /// 1. Try disk cache first (instant).
  /// 2. If cache is fresh (< 24 h) → done.
  /// 3. If cache is stale or missing → fetch from API in the background.
  /// 4. On API failure with existing cache → keep stale data.
  ///
  /// Never blocks the calling code — the UI reacts via [notifyListeners].
  Future<void> _loadGameData(int gameId) async {
    _isLoadingGameData = true;
    notifyListeners();

    try {
      // ── 1. Try disk cache ───────────────────────────────────────────
      final cached = await _readCachedGameData(gameId);

      // Session may have changed while the cache read was in flight
      // (user exited / switched games) — never apply data for a game
      // that is no longer the active session.
      if (_activeSession?.gameId != gameId) {
        _isLoadingGameData = false;
        notifyListeners();
        return;
      }

      if (cached != null) {
        _gameData = cached;
        _isLoadingGameData = false;
        notifyListeners();
        debugPrint(
          'RA: Loaded ${cached.achievements.length} achievements '
          'from cache for game $gameId '
          '(age: ${DateTime.now().difference(cached.fetchedAt).inMinutes}m)',
        );

        // ── 2. If fresh → we're done ────────────────────────────────
        if (!cached.isStale) return;

        // ── 3. Stale → background refresh ───────────────────────────
        debugPrint('RA: Cache stale for game $gameId — refreshing in bg');
        _backgroundRefresh(gameId);
        return;
      }

      // ── 4. No cache → must fetch ─────────────────────────────────
      debugPrint('RA: No cache for game $gameId — fetching from API');
      final fresh = await _fetchGameDataFromApi(gameId);
      if (_activeSession?.gameId != gameId) {
        _isLoadingGameData = false;
        notifyListeners();
        return;
      }
      if (fresh != null) {
        _gameData = fresh;
        await _writeCachedGameData(gameId, fresh);
        debugPrint(
          'RA: Fetched ${fresh.achievements.length} achievements '
          'for game $gameId',
        );
      } else {
        debugPrint('RA: Failed to fetch achievements for game $gameId');
      }
    } catch (e) {
      debugPrint('RA: Error loading game data: $e');
    }

    _isLoadingGameData = false;
    notifyListeners();
  }

  /// Refresh game data in the background (fire-and-forget).
  ///
  /// On success the in-memory [_gameData] and disk cache are updated,
  /// and listeners are notified so the UI can react.  On failure the
  /// existing (stale) cache is silently kept.
  void _backgroundRefresh(int gameId) {
    _fetchGameDataFromApi(gameId)
        .then((fresh) async {
          if (fresh == null) return;

          // Only apply if the session hasn't changed since we started
          if (_activeSession?.gameId != gameId) return;

          _gameData = fresh;
          await _writeCachedGameData(gameId, fresh);
          notifyListeners();
          debugPrint(
            'RA: Background refresh complete for game $gameId '
            '(${fresh.achievements.length} achievements)',
          );
        })
        .catchError((e) {
          debugPrint('RA: Background refresh failed for game $gameId: $e');
        });
  }

  /// Mark an achievement as earned in local state immediately after an
  /// in-game unlock event, without waiting for the next API refresh.
  ///
  /// This keeps the achievements list in sync with the notification that
  /// was already shown to the user.  The updated state is also written to
  /// the disk cache so it survives app restarts until the server-side data
  /// is re-fetched (e.g. on next session start).
  void markAchievementEarned(int achievementId, {required bool hardcore}) {
    final data = _gameData;
    if (data == null) return;

    RAAchievement? earnedAchievement;
    for (final achievement in data.achievements) {
      if (achievement.id == achievementId) {
        earnedAchievement = achievement;
        break;
      }
    }

    final alreadyEarnedAny =
        earnedAchievement != null &&
        (earnedAchievement.dateEarned != null ||
            earnedAchievement.dateEarnedHardcore != null);
    final shouldAddProfilePoints =
        earnedAchievement != null &&
        (hardcore
            ? earnedAchievement.dateEarnedHardcore == null
            : !alreadyEarnedAny);

    final now = DateTime.now().toUtc();
    final updated = data.achievements.map((a) {
      if (a.id != achievementId) return a;
      return RAAchievement(
        id: a.id,
        title: a.title,
        description: a.description,
        points: a.points,
        trueRatio: a.trueRatio,
        badgeName: a.badgeName,
        type: a.type,
        memAddr: a.memAddr,
        displayOrder: a.displayOrder,
        numAwarded: a.numAwarded,
        numAwardedHardcore: a.numAwardedHardcore,
        dateEarned: a.dateEarned ?? now,
        dateEarnedHardcore: hardcore
            ? (a.dateEarnedHardcore ?? now)
            : a.dateEarnedHardcore,
      );
    }).toList();

    _gameData = RAGameData(
      gameId: data.gameId,
      title: data.title,
      imageIcon: data.imageIcon,
      imageBoxArt: data.imageBoxArt,
      consoleName: data.consoleName,
      numDistinctPlayers: data.numDistinctPlayers,
      achievements: updated,
      numAwardedToUser: data.numAwardedToUser,
      numAwardedToUserHardcore: data.numAwardedToUserHardcore,
      userCompletion: data.userCompletion,
      userCompletionHardcore: data.userCompletionHardcore,
      fetchedAt: data.fetchedAt,
    );

    if (shouldAddProfilePoints && _profile != null) {
      final points = earnedAchievement.points;
      _profile = hardcore
          ? _profile!.copyWith(totalPoints: _profile!.totalPoints + points)
          : _profile!.copyWith(
              totalSoftcorePoints: _profile!.totalSoftcorePoints + points,
            );
    }

    notifyListeners();
    _writeCachedGameData(data.gameId, _gameData!);
  }

  /// Force a fresh fetch and cache update for the current game.
  ///
  /// Call this from the UI when the user explicitly requests a refresh
  /// (e.g. pull-to-refresh on an achievements screen).
  Future<void> refreshGameData() async {
    final gameId = _activeSession?.gameId;
    if (gameId == null || gameId <= 0 || !_isLoggedIn) return;

    _isLoadingGameData = true;
    notifyListeners();

    try {
      final fresh = await _fetchGameDataFromApi(gameId);
      if (fresh != null) {
        _gameData = fresh;
        await _writeCachedGameData(gameId, fresh);
      }
    } catch (e) {
      debugPrint('RA: Manual refresh failed: $e');
    }

    _isLoadingGameData = false;
    notifyListeners();
  }

  // ── Connect API: patch + startsession ───────────────────────────────

  /// Fetch game metadata via `dorequest.php?r=patch` and merge user
  /// unlock status from `dorequest.php?r=startsession`.
  ///
  /// Returns [RAGameData] on success, or `null` on any failure.
  Future<RAGameData?> _fetchGameDataFromApi(int gameId) async {
    if (_username == null || _connectToken == null) {
      debugPrint('RA patch: not logged in');
      return null;
    }

    try {
      // ── 1. Fetch achievement definitions via `patch` ──────────────
      final patchUri = Uri.parse('https://retroachievements.org/dorequest.php')
          .replace(
            queryParameters: {
              'r': 'patch',
              'u': _username!,
              't': _connectToken!,
              'g': gameId.toString(),
            },
          );

      final patchResp = await _httpWithRetry(
        () => http.get(patchUri).timeout(const Duration(seconds: 15)),
      );

      if (patchResp.statusCode == 401) {
        debugPrint('RA patch: 401 — refreshing token');
        if (await _refreshConnectToken()) {
          return _fetchGameDataFromApi(gameId); // retry once
        }
        return null;
      }

      if (patchResp.statusCode != 200) {
        debugPrint('RA patch: HTTP ${patchResp.statusCode}');
        return null;
      }

      final patchBody = jsonDecode(patchResp.body);
      if (patchBody is! Map<String, dynamic> || patchBody['Success'] != true) {
        debugPrint('RA patch: unexpected response');
        return null;
      }

      final patchData = patchBody['PatchData'] as Map<String, dynamic>?;
      if (patchData == null) {
        debugPrint('RA patch: no PatchData');
        return null;
      }

      // ── 2. Fetch user unlocks via `startsession` ─────────────────
      final sessionUri =
          Uri.parse('https://retroachievements.org/dorequest.php').replace(
            queryParameters: {
              'r': 'startsession',
              'u': _username!,
              't': _connectToken!,
              'g': gameId.toString(),
            },
          );

      Map<String, dynamic>? sessionData;
      try {
        final sessionResp = await _httpWithRetry(
          () => http.get(sessionUri).timeout(const Duration(seconds: 10)),
        );
        if (sessionResp.statusCode == 200) {
          final decoded = jsonDecode(sessionResp.body);
          if (decoded is Map<String, dynamic> && decoded['Success'] == true) {
            sessionData = decoded;
            debugPrint('RA API: startsession OK');
          }
        }
      } catch (e) {
        debugPrint('RA startsession error (non-fatal): $e');
      }

      // ── 3. Build RAGameData from patch + session data ─────────────
      return _buildGameDataFromPatch(gameId, patchData, sessionData);
    } on http.ClientException catch (e) {
      debugPrint('RA patch network error: $e');
      return null;
    } on FormatException catch (e) {
      debugPrint('RA patch parse error: $e');
      return null;
    } catch (e) {
      if (e.toString().contains('TimeoutException')) {
        debugPrint('RA patch: timed out');
      } else {
        debugPrint('RA patch error: $e');
      }
      return null;
    }
  }

  /// Build [RAGameData] from the Connect API `patch` response and
  /// optional `startsession` unlock data.
  RAGameData _buildGameDataFromPatch(
    int gameId,
    Map<String, dynamic> patchData,
    Map<String, dynamic>? sessionData,
  ) {
    // Collect unlock timestamps from startsession response
    final softcoreUnlocks = <int, DateTime>{};
    final hardcoreUnlocks = <int, DateTime>{};

    if (sessionData != null) {
      for (final u in sessionData['Unlocks'] as List? ?? []) {
        if (u is Map<String, dynamic>) {
          final id = u['ID'] as int? ?? 0;
          final when = u['When'] as int? ?? 0;
          if (id > 0) {
            softcoreUnlocks[id] = DateTime.fromMillisecondsSinceEpoch(
              when * 1000,
              isUtc: true,
            );
          }
        }
      }
      for (final u in sessionData['HardcoreUnlocks'] as List? ?? []) {
        if (u is Map<String, dynamic>) {
          final id = u['ID'] as int? ?? 0;
          final when = u['When'] as int? ?? 0;
          if (id > 0) {
            hardcoreUnlocks[id] = DateTime.fromMillisecondsSinceEpoch(
              when * 1000,
              isUtc: true,
            );
          }
        }
      }
    }

    // Parse achievements from PatchData.Achievements
    final rawAchievements = patchData['Achievements'] as List? ?? [];
    final achievements = <RAAchievement>[];
    int displayIdx = 0;

    for (final raw in rawAchievements) {
      if (raw is! Map<String, dynamic>) continue;
      // Only include official achievements (Flags == 3 = core set)
      final flags = raw['Flags'] as int? ?? 3;
      if (flags != 3) continue;

      final id = raw['ID'] as int? ?? 0;
      achievements.add(
        RAAchievement(
          id: id,
          title: raw['Title'] as String? ?? '',
          description: raw['Description'] as String? ?? '',
          points: raw['Points'] as int? ?? 0,
          trueRatio: 0, // not available from patch endpoint
          badgeName: (raw['BadgeName'] ?? '00000').toString(),
          type: raw['Type'] as String?,
          memAddr: raw['MemAddr'] as String?,
          displayOrder: displayIdx++,
          numAwarded: 0,
          numAwardedHardcore: 0,
          dateEarned: softcoreUnlocks[id],
          dateEarnedHardcore: hardcoreUnlocks[id],
        ),
      );
    }

    achievements.sort((a, b) => a.displayOrder.compareTo(b.displayOrder));

    final imageIcon = patchData['ImageIcon'] as String?;

    return RAGameData(
      gameId: gameId,
      title: patchData['Title'] as String? ?? 'Unknown',
      imageIcon: imageIcon,
      consoleName: null, // not in patch response
      achievements: achievements,
      fetchedAt: DateTime.now(),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Disk cache — JSON files per game, scoped to the logged-in user
  // ═══════════════════════════════════════════════════════════════════════
  //
  //  Cache directory layout:
  //    <appSupport>/ra_cache/<username>/game_<gameId>.json
  //
  //  Per-user scoping ensures that:
  //    • User A's earned-achievement timestamps don't bleed into User B
  //    • Logging out + logging in as a different user gets fresh data
  //    • Cache files are small (~5–50 KB each) and self-contained

  /// Resolve the cache directory for the current user, creating it if needed.
  Future<Directory> _getCacheDir() async {
    final appDir = await getApplicationSupportDirectory();
    final user = _username ?? '_anonymous';
    final dir = Directory(p.join(appDir.path, 'ra_cache', user));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// File path for a game's cached achievement data.
  Future<String> _cacheFilePath(int gameId) async {
    final dir = await _getCacheDir();
    return p.join(dir.path, 'game_$gameId.json');
  }

  /// Read cached [RAGameData] from disk, or `null` if not found / corrupt.
  Future<RAGameData?> _readCachedGameData(int gameId) async {
    try {
      final path = await _cacheFilePath(gameId);
      final file = File(path);
      if (!file.existsSync()) return null;

      final jsonString = await file.readAsString();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return RAGameData.fromJson(json);
    } catch (e) {
      debugPrint('RA cache read error (game $gameId): $e');
      return null;
    }
  }

  /// Write [RAGameData] to disk cache.
  Future<void> _writeCachedGameData(int gameId, RAGameData data) async {
    try {
      final path = await _cacheFilePath(gameId);
      final jsonString = jsonEncode(data.toJson());
      await File(path).writeAsString(jsonString);
      debugPrint(
        'RA: Cached achievement data for game $gameId '
        '(${jsonString.length} bytes)',
      );
    } catch (e) {
      debugPrint('RA cache write error (game $gameId): $e');
    }
  }

  // ── HTTP retry helper ───────────────────────────────────────────────

  /// Execute [request] with a single retry on transient failures (timeout,
  /// 5xx server error, or network exception).  The retry waits with
  /// exponential backoff before re-attempting.
  static Future<http.Response> _httpWithRetry(
    Future<http.Response> Function() request, {
    int maxRetries = 1,
    Duration initialDelay = const Duration(seconds: 2),
  }) async {
    int attempt = 0;
    while (true) {
      try {
        final response = await request();
        // Retry on server errors (5xx)
        if (response.statusCode >= 500 && attempt < maxRetries) {
          attempt++;
          final delay = initialDelay * (1 << (attempt - 1));
          debugPrint(
            'RA: Server error ${response.statusCode}, '
            'retrying in ${delay.inSeconds}s (attempt $attempt)',
          );
          await Future.delayed(delay);
          continue;
        }
        return response;
      } catch (e) {
        if (attempt < maxRetries) {
          attempt++;
          final delay = initialDelay * (1 << (attempt - 1));
          debugPrint(
            'RA: Request failed ($e), '
            'retrying in ${delay.inSeconds}s (attempt $attempt)',
          );
          await Future.delayed(delay);
          continue;
        }
        rethrow;
      }
    }
  }

  // ── Lookup caches (ROM hash + game ID) ──────────────────────────────

  /// Load the ROM-hash and game-ID lookup caches from SharedPreferences.
  Future<void> _loadLookupCaches() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final hashJson = prefs.getString(_prefRomHashCache);
      if (hashJson != null) {
        final decoded = jsonDecode(hashJson);
        if (decoded is Map) {
          _romHashCache = decoded.map(
            (k, v) => MapEntry(k as String, v as String),
          );
        }
      }

      final idJson = prefs.getString(_prefGameIdCache);
      if (idJson != null) {
        final decoded = jsonDecode(idJson);
        if (decoded is Map) {
          _gameIdCache = decoded.map(
            (k, v) => MapEntry(k as String, (v as num).toInt()),
          );
        }
      }

      debugPrint(
        'RA: Loaded lookup caches — '
        '${_romHashCache.length} hashes, ${_gameIdCache.length} game IDs',
      );
    } catch (e) {
      debugPrint('RA: Failed to load lookup caches: $e');
    }
  }

  /// Persist lookup caches to SharedPreferences (fire-and-forget).
  void _persistLookupCaches() {
    SharedPreferences.getInstance()
        .then((prefs) {
          prefs.setString(_prefRomHashCache, jsonEncode(_romHashCache));
          prefs.setString(_prefGameIdCache, jsonEncode(_gameIdCache));
        })
        .catchError((e) {
          debugPrint('RA: Failed to persist lookup caches: $e');
        });
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Connect API — Session, Ping, Award
  // ═══════════════════════════════════════════════════════════════════════
  //
  //  The `dorequest.php` "Connect API" requires a session token obtained
  //  via password-based login (`login2`).  The web API key is NOT
  //  accepted — it only works with the REST `API_Get*` endpoints.
  //
  //  When a Connect token is available (password login), these methods
  //  talk to the server.  Otherwise they no-op silently so we never
  //  spam 401s.
  //
  //  Achievement metadata & progress still work perfectly via the REST
  //  API (API_GetGameInfoAndUserProgress, API_GetUserProfile, etc.).

  /// Whether the Connect API is available (we have a valid token).
  bool get hasConnectToken => _connectToken != null;

  /// The raw Connect API token (for native rcheevos login).
  /// Returns null if the user is not logged in.
  String? get connectToken => _connectToken;

  /// Guard to prevent infinite refresh loops.
  bool _isRefreshingToken = false;

  /// Try to refresh the Connect token using the stored password.
  /// Returns `true` if a new token was acquired.
  Future<bool> _refreshConnectToken() async {
    if (_isRefreshingToken) return false; // prevent re-entrant loop
    if (_username == null) return false;
    final storedPassword = await _secureRead(_keyPassword);
    if (storedPassword == null || storedPassword.isEmpty) return false;
    _isRefreshingToken = true;
    try {
      debugPrint('RA: Refreshing Connect token from stored password');
      final profile = await _obtainConnectToken(_username!, storedPassword);
      if (profile != null) {
        _username = profile.username;
        _profile = profile;
      }
      return _connectToken != null;
    } finally {
      _isRefreshingToken = false;
    }
  }

  /// Set a Connect API token obtained externally (e.g. password login).
  void setConnectToken(String token) {
    _connectToken = token;
  }

  // ── Session, ping, and award APIs are now handled by the native
  //    rcheevos client (RcheevosClient).  Removed: apiStartSession(),
  //    apiPing(), apiAwardAchievement(). ──

  /// Delete all cached achievement data for the current user.
  ///
  /// Called on logout so that the next user gets a clean slate.
  Future<void> _clearCachedGameData() async {
    try {
      final dir = await _getCacheDir();
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
        debugPrint('RA: Cleared achievement cache');
      }
    } catch (e) {
      debugPrint('RA cache clear error: $e');
    }
  }
}
