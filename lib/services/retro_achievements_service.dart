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
import '../models/game_rom.dart';
import '../models/ra_achievement.dart';

class RAConsoleId {
  RAConsoleId._();

  static const int megaDrive = 1;
  static const int nintendo64 = 2;
  static const int snes = 3;
  static const int gameBoy = 4;
  static const int gameBoyAdvance = 5;
  static const int gameBoyColor = 6;
  static const int nes = 7;
  static const int masterSystem = 11;
  static const int gameGear = 15;
  static const int sg1000 = 33;
  static const int neoGeoPocket = 14;
  static const int wonderSwan = 53;

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
      GamePlatform.pce => null,
      GamePlatform.sgx => null,
      GamePlatform.n64 => nintendo64,
      GamePlatform.sg1000 => sg1000,
      GamePlatform.ngp => neoGeoPocket,
      GamePlatform.ws => wonderSwan,
      GamePlatform.wsc => wonderSwan,
      GamePlatform.unknown => null,
    };
  }

  static String label(int id) {
    return switch (id) {
      megaDrive => 'Mega Drive',
      nintendo64 => 'Nintendo 64',
      snes => 'SNES',
      gameBoy => 'Game Boy',
      gameBoyAdvance => 'Game Boy Advance',
      gameBoyColor => 'Game Boy Color',
      nes => 'NES',
      masterSystem => 'Master System',
      gameGear => 'Game Gear',
      sg1000 => 'SG-1000',
      neoGeoPocket => 'Neo Geo Pocket',
      wonderSwan => 'WonderSwan',
      _ => 'Unknown ($id)',
    };
  }
}

class RAGameSession {
  final int gameId;

  final String romHash;

  final int consoleId;

  final bool achievementsEnabled;

  const RAGameSession({
    required this.gameId,
    required this.romHash,
    required this.consoleId,
    required this.achievementsEnabled,
  });

  @override
  String toString() =>
      'RAGameSession(gameId=$gameId, hash=$romHash, '
      'console=${RAConsoleId.label(consoleId)}, '
      'achievements=${achievementsEnabled ? "ON" : "OFF"})';
}

class RAUserProfile {
  final String username;
  final String profileImageUrl;
  final int totalPoints;
  final int totalSoftcorePoints;
  final int totalTruePoints;
  final String memberSince;
  final String? motto;

  const RAUserProfile({
    required this.username,
    required this.profileImageUrl,
    required this.totalPoints,
    required this.totalSoftcorePoints,
    required this.totalTruePoints,
    required this.memberSince,
    this.motto,
  });

  factory RAUserProfile.fromJson(Map<String, dynamic> json) {
    return RAUserProfile(
      username: json['User'] as String? ?? '',
      profileImageUrl:
          'https://retroachievements.org${json['UserPic'] as String? ?? ''}',
      totalPoints: _toInt(json['TotalPoints']),
      totalSoftcorePoints: _toInt(json['TotalSoftcorePoints']),
      totalTruePoints: _toInt(json['TotalTruePoints']),
      memberSince: json['MemberSince'] as String? ?? '',
      motto: json['Motto'] as String?,
    );
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

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

class RetroAchievementsService extends ChangeNotifier {
  static const String _keyUsername = 'ra_username';
  static const String _keyPassword = 'ra_password';
  static const String _keyConnectToken = 'ra_connect_token';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
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
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _username;
  RAUserProfile? _profile;
  String? _lastError;
  String? _connectToken;
  RAGameSession? _activeSession;
  bool _isResolvingGame = false;
  RAGameData? _gameData;
  bool _isLoadingGameData = false;
  static const String _prefRomHashCache = 'ra_rom_hash_cache';
  static const String _prefGameIdCache = 'ra_game_id_cache';
  Map<String, String> _romHashCache = {};
  Map<String, int> _gameIdCache = {};

  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  String? get username => _username;
  RAUserProfile? get profile => _profile;

  String? get lastError => _lastError;

  final Completer<void> _initCompleter = Completer<void>();

  Future<void> get whenReady => _initCompleter.future;

  RAGameSession? get activeSession => _activeSession;

  bool get isResolvingGame => _isResolvingGame;

  RAGameData? get gameData => _gameData;

  bool get isLoadingGameData => _isLoadingGameData;

  bool get achievementsEnabled => _activeSession?.achievementsEnabled ?? false;

  Future<void> initialize() async {
    _isLoading = true;
    _lastError = null;
    notifyListeners();
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
        _connectToken = await _secureRead(_keyConnectToken);

        if (_connectToken != null) {
          _username = storedUser;
          _profile = _buildProfile(storedUser);
          _isLoggedIn = true;
          _lastError = null;
          debugPrint('RA: Restored session for $storedUser');
        } else {
          final ok = await _obtainConnectToken(storedUser, storedPassword);
          if (ok) {
            _username = storedUser;
            _profile = _buildProfile(storedUser);
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
    if (!_initCompleter.isCompleted) _initCompleter.complete();
  }

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

  Future<RALoginResult> login(String username, String password) async {
    if (username.trim().isEmpty || password.trim().isEmpty) {
      return RALoginResult.error('Username and password are required.');
    }

    _isLoading = true;
    notifyListeners();

    try {
      final ok = await _obtainConnectToken(username.trim(), password.trim());

      if (ok) {
        await _secureWrite(_keyUsername, username.trim());
        await _secureWrite(_keyPassword, password.trim());

        _username = username.trim();
        _profile = _buildProfile(username.trim());
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

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  Future<String?> getStoredPassword() async {
    return _secureRead(_keyPassword);
  }

  Future<void> _clearCredentials() async {
    await _secureDelete(_keyUsername);
    await _secureDelete(_keyPassword);
    await _secureDelete(_keyConnectToken);
    await _secureDelete('ra_api_key');
  }

  Future<bool> _obtainConnectToken(String username, String password) async {
    final uri = Uri.parse('https://retroachievements.org/dorequest.php');

    try {
      final response = await _httpWithRetry(
        () => http
            .post(uri, body: {'r': 'login2', 'u': username, 'p': password})
            .timeout(const Duration(seconds: 10)),
      );

      if (response.statusCode != 200) {
        debugPrint('RA Connect: login2 HTTP ${response.statusCode}');
        return false;
      }

      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> &&
          body['Success'] == true &&
          body['Token'] is String) {
        _connectToken = body['Token'] as String;
        await _secureWrite(_keyConnectToken, _connectToken!);
        debugPrint('RA Connect: login2 OK — token acquired & persisted');
        return true;
      }

      debugPrint('RA Connect: login2 failed — ${response.body}');
      return false;
    } catch (e) {
      debugPrint('RA Connect: login2 error: $e');
      return false;
    }
  }

  Future<void> startGameSession(GameRom rom, {bool awaitData = false}) async {
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
      final romHash = await _getOrComputeHash(rom.path);
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
      final gameId = await _getOrResolveGameId(romHash);
      final enabled = gameId > 0 && _isLoggedIn;
      _activeSession = RAGameSession(
        gameId: gameId,
        romHash: romHash,
        consoleId: consoleId,
        achievementsEnabled: enabled,
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
    if (_activeSession != null && _activeSession!.gameId > 0 && _isLoggedIn) {
      if (awaitData) {
        await _loadGameData(_activeSession!.gameId);
      } else {
        _loadGameData(_activeSession!.gameId);
      }
    }
  }

  void endGameSession() {
    if (_activeSession == null && _gameData == null) return;
    debugPrint('RA: Session ended for game ID=${_activeSession?.gameId}');
    _activeSession = null;
    _gameData = null;
    _isResolvingGame = false;
    _isLoadingGameData = false;
    notifyListeners();
  }

  Future<String?> _getOrComputeHash(String romPath) async {
    try {
      final file = File(romPath);
      if (!await file.exists()) {
        debugPrint('RA hash: file not found — $romPath');
        return null;
      }
      final size = await file.length();
      final cacheKey = '$romPath|$size';
      final cached = _romHashCache[cacheKey];
      if (cached != null) {
        debugPrint('RA hash: cache hit for "$romPath"');
        return cached;
      }
      final hash = await compute(computeRAHash, romPath);
      if (hash != null) {
        _romHashCache[cacheKey] = hash;
        _persistLookupCaches(); 
      }
      return hash;
    } catch (e) {
      debugPrint('RA hash error: $e');
      return null;
    }
  }

  static Future<String?> computeRAHash(String romPath) async {
    try {
      final file = File(romPath);
      if (!await file.exists()) {
        debugPrint('RA hash: file not found — $romPath');
        return null;
      }

      final ext = p.extension(romPath).toLowerCase();
      if (ext == '.nes' || ext == '.unf' || ext == '.unif') {
        final bytes = await file.readAsBytes();
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
          final digest = md5.convert(bytes.sublist(offset));
          return digest.toString();
        }
        final digest = md5.convert(bytes);
        return digest.toString();
      }
      if (ext == '.sfc' || ext == '.smc') {
        final stat = await file.stat();
        final size = stat.size;
        final hasHeader = (size % 1024) == 512;
        if (hasHeader) {
          final bytes = await file.readAsBytes();
          final digest = md5.convert(bytes.sublist(512));
          return digest.toString();
        }
        final digest = await md5.bind(file.openRead()).first;
        return digest.toString();
      }
      final digest = await md5.bind(file.openRead()).first;
      return digest.toString(); 
    } catch (e) {
      debugPrint('RA hash error: $e');
      return null;
    }
  }

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

  Future<int> _getOrResolveGameId(String hash) async {
    final cached = _gameIdCache[hash];
    if (cached != null) {
      debugPrint('RA gameId: cache hit for hash $hash → $cached');
      return cached;
    }

    final gameId = await _resolveGameId(hash);
    _gameIdCache[hash] = gameId;
    _persistLookupCaches(); 
    return gameId;
  }

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

  static int _parseGameId(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  Future<void> _loadGameData(int gameId) async {
    _isLoadingGameData = true;
    notifyListeners();

    try {
      final cached = await _readCachedGameData(gameId);

      if (cached != null) {
        _gameData = cached;
        _isLoadingGameData = false;
        notifyListeners();
        debugPrint(
          'RA: Loaded ${cached.achievements.length} achievements '
          'from cache for game $gameId '
          '(age: ${DateTime.now().difference(cached.fetchedAt).inMinutes}m)',
        );
        if (!cached.isStale) return;
        debugPrint('RA: Cache stale for game $gameId — refreshing in bg');
        _backgroundRefresh(gameId);
        return;
      }
      debugPrint('RA: No cache for game $gameId — fetching from API');
      final fresh = await _fetchGameDataFromApi(gameId);
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

  void _backgroundRefresh(int gameId) {
    _fetchGameDataFromApi(gameId)
        .then((fresh) async {
          if (fresh == null) return;
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

  Future<RAGameData?> _fetchGameDataFromApi(int gameId) async {
    if (_username == null || _connectToken == null) {
      debugPrint('RA patch: not logged in');
      return null;
    }

    try {
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
          return _fetchGameDataFromApi(gameId); 
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

  RAGameData _buildGameDataFromPatch(
    int gameId,
    Map<String, dynamic> patchData,
    Map<String, dynamic>? sessionData,
  ) {
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
    final rawAchievements = patchData['Achievements'] as List? ?? [];
    final achievements = <RAAchievement>[];
    int displayIdx = 0;

    for (final raw in rawAchievements) {
      if (raw is! Map<String, dynamic>) continue;
      final flags = raw['Flags'] as int? ?? 3;
      if (flags != 3) continue;

      final id = raw['ID'] as int? ?? 0;
      achievements.add(
        RAAchievement(
          id: id,
          title: raw['Title'] as String? ?? '',
          description: raw['Description'] as String? ?? '',
          points: raw['Points'] as int? ?? 0,
          trueRatio: 0, 
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
      consoleName: null, 
      achievements: achievements,
      fetchedAt: DateTime.now(),
    );
  }

  Future<Directory> _getCacheDir() async {
    final appDir = await getApplicationSupportDirectory();
    final user = _username ?? '_anonymous';
    final dir = Directory(p.join(appDir.path, 'ra_cache', user));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _cacheFilePath(int gameId) async {
    final dir = await _getCacheDir();
    return p.join(dir.path, 'game_$gameId.json');
  }

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

  static Future<http.Response> _httpWithRetry(
    Future<http.Response> Function() request, {
    int maxRetries = 1,
    Duration initialDelay = const Duration(seconds: 2),
  }) async {
    int attempt = 0;
    while (true) {
      try {
        final response = await request();
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

  bool get hasConnectToken => _connectToken != null;

  String? get connectToken => _connectToken;

  bool _isRefreshingToken = false;

  Future<bool> _refreshConnectToken() async {
    if (_isRefreshingToken) return false; 
    if (_username == null) return false;
    final storedPassword = await _secureRead(_keyPassword);
    if (storedPassword == null || storedPassword.isEmpty) return false;
    _isRefreshingToken = true;
    try {
      debugPrint('RA: Refreshing Connect token from stored password');
      await _obtainConnectToken(_username!, storedPassword);
      return _connectToken != null;
    } finally {
      _isRefreshingToken = false;
    }
  }

  void setConnectToken(String token) {
    _connectToken = token;
  }

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
