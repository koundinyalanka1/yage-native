import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Connection states for the link cable.
enum LinkCableState {
  disconnected,
  hosting,   // TCP server listening, waiting for peer
  joining,   // TCP client connecting to host
  connected, // Bidirectional link established
}

/// Message types for the link cable protocol.
class _MsgType {
  static const int handshake    = 0x01;
  static const int handshakeAck = 0x02;
  static const int sioData      = 0x03;
  static const int ping         = 0x04;
  static const int pong         = 0x05;
  static const int disconnect   = 0x06;
}

/// Network link cable service — enables two devices running the same ROM
/// to exchange serial I/O data over a TCP connection, emulating the
/// Game Boy link cable.
///
/// Protocol (binary over TCP):
///   [1 byte type] [2 bytes payload length (big-endian)] [payload...]
///
/// Usage:
///   1. One player calls [host] — starts a TCP server and shows their IP.
///   2. The other player calls [join] with the host's IP.
///   3. Once connected, the emulator frame loop calls [pollAndExchange]
///      each frame to check for pending SIO transfers and forward data.
class LinkCableService extends ChangeNotifier {
  static const int defaultPort = 7269; // "YAGE" on keypad, roughly

  LinkCableState _state = LinkCableState.disconnected;
  LinkCableState get state => _state;

  ServerSocket? _server;
  Socket? _socket;
  String? _peerAddress;
  String? get peerAddress => _peerAddress;

  // Room code for display (derived from port)
  String? _roomCode;
  String? get roomCode => _roomCode;

  // ROM hash for handshake validation
  int _romHash = 0;

  // Incoming data buffer
  final List<int> _recvBuffer = [];

  // Pending incoming SIO byte (set when we receive sioData from peer)
  int? _pendingIncomingByte;

  // Whether we already sent our outgoing byte and are waiting for a reply
  bool _awaitingReply = false;

  // Latency tracking
  DateTime? _lastPingSent;
  int _latencyMs = 0;
  int get latencyMs => _latencyMs;

  // Ping timer
  Timer? _pingTimer;

  // Host timeout timer — auto-disconnects if no peer connects within the limit
  Timer? _hostTimeoutTimer;
  static const Duration defaultHostTimeout = Duration(minutes: 5);

  // Guard against overlapping disconnect() calls
  bool _disconnecting = false;

  // Error message
  String? _error;
  String? get error => _error;

  /// Local IP addresses for display to the user.
  Future<List<String>> getLocalIPs() async {
    final ips = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          ips.add(addr.address);
        }
      }
    } catch (e) {
      debugPrint('Failed to get local IPs: $e');
    }
    return ips;
  }

  /// Start hosting a link cable session.
  /// [romHash] should be a simple hash of the ROM for validation.
  /// [timeout] controls how long the server waits for a peer before
  /// auto-disconnecting.  Defaults to [defaultHostTimeout] (5 minutes).
  /// Pass `null` to wait indefinitely (not recommended).
  Future<bool> host({
    required int romHash,
    int port = defaultPort,
    Duration? timeout = defaultHostTimeout,
  }) async {
    if (_state != LinkCableState.disconnected) {
      await disconnect();
    }

    _romHash = romHash;
    _error = null;

    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _state = LinkCableState.hosting;
      _roomCode = port.toString();
      notifyListeners();

      debugPrint('Link cable: hosting on port $port');

      // Start host timeout — auto-disconnect if no peer connects in time
      if (timeout != null) {
        _hostTimeoutTimer?.cancel();
        _hostTimeoutTimer = Timer(timeout, () async {
          if (_state == LinkCableState.hosting) {
            debugPrint('Link cable: host timed out after $timeout');
            _error = 'No one joined — timed out';
            await disconnect();
          }
        });
      }

      // Wait for incoming connection
      _server!.listen(
        (Socket socket) {
          if (_state == LinkCableState.connected) {
            // Already have a peer, reject
            socket.destroy();
            return;
          }
          // Peer connected — cancel the timeout
          _hostTimeoutTimer?.cancel();
          _hostTimeoutTimer = null;
          _handleConnection(socket);
        },
        onError: (e) async {
          debugPrint('Link cable server error: $e');
          _error = 'Server error: $e';
          await disconnect();
        },
        onDone: () async {
          if (_state == LinkCableState.hosting) {
            await disconnect();
          }
        },
      );

      return true;
    } catch (e) {
      _error = 'Failed to start server: $e';
      _state = LinkCableState.disconnected;
      notifyListeners();
      return false;
    }
  }

  /// Join an existing link cable session.
  Future<bool> join({
    required String hostAddress,
    required int romHash,
    int port = defaultPort,
  }) async {
    if (_state != LinkCableState.disconnected) {
      await disconnect();
    }

    _romHash = romHash;
    _error = null;
    _state = LinkCableState.joining;
    notifyListeners();

    try {
      final socket = await Socket.connect(
        hostAddress,
        port,
        timeout: const Duration(seconds: 10),
      );
      _handleConnection(socket);

      // Send handshake
      _sendMessage(_MsgType.handshake, _encodeHandshake());

      return true;
    } catch (e) {
      _error = 'Failed to connect: $e';
      _state = LinkCableState.disconnected;
      notifyListeners();
      return false;
    }
  }

  void _handleConnection(Socket socket) {
    _socket = socket;
    _peerAddress = socket.remoteAddress.address;
    _recvBuffer.clear();
    _pendingIncomingByte = null;
    _awaitingReply = false;

    socket.listen(
      _onData,
      onError: (e) async {
        debugPrint('Link cable socket error: $e');
        _error = 'Connection lost';
        await disconnect();
      },
      onDone: () async {
        debugPrint('Link cable: peer disconnected');
        _error = 'Peer disconnected';
        await disconnect();
      },
      cancelOnError: false,
    );

    debugPrint('Link cable: peer connected from ${socket.remoteAddress.address}');
  }

  void _onData(Uint8List data) {
    _recvBuffer.addAll(data);
    _processMessages();
  }

  void _processMessages() {
    // Parse framed messages: [type:1] [len:2 big-endian] [payload:len]
    while (_recvBuffer.length >= 3) {
      final type = _recvBuffer[0];
      final len = (_recvBuffer[1] << 8) | _recvBuffer[2];

      if (_recvBuffer.length < 3 + len) break; // Wait for more data

      final payload = _recvBuffer.sublist(3, 3 + len);
      _recvBuffer.removeRange(0, 3 + len);

      _handleMessage(type, payload);
    }
  }

  Future<void> _handleMessage(int type, List<int> payload) async {
    switch (type) {
      case _MsgType.handshake:
        _handleHandshake(payload);
        break;
      case _MsgType.handshakeAck:
        _handleHandshakeAck(payload);
        break;
      case _MsgType.sioData:
        if (payload.isNotEmpty) {
          _pendingIncomingByte = payload[0];
          _awaitingReply = false;
        }
        break;
      case _MsgType.ping:
        _sendMessage(_MsgType.pong, []);
        break;
      case _MsgType.pong:
        if (_lastPingSent != null) {
          _latencyMs = DateTime.now().difference(_lastPingSent!).inMilliseconds;
          _lastPingSent = null;
        }
        break;
      case _MsgType.disconnect:
        _error = 'Peer disconnected';
        await disconnect();
        break;
    }
  }

  Future<void> _handleHandshake(List<int> payload) async {
    if (payload.length < 5) {
      _error = 'Invalid handshake';
      await disconnect();
      return;
    }

    // Version check
    final version = payload[0];
    if (version != 1) {
      _error = 'Incompatible version';
      await disconnect();
      return;
    }

    // ROM hash check
    final peerHash = (payload[1] << 24) | (payload[2] << 16) |
                     (payload[3] << 8) | payload[4];
    if (peerHash != _romHash) {
      _error = 'ROM mismatch — both players must play the same game';
      await disconnect();
      return;
    }

    // Send ack
    _sendMessage(_MsgType.handshakeAck, _encodeHandshake());

    _state = LinkCableState.connected;
    _startPingTimer();
    notifyListeners();
    debugPrint('Link cable: handshake complete, connected!');
  }

  Future<void> _handleHandshakeAck(List<int> payload) async {
    if (payload.length < 5) {
      _error = 'Invalid handshake ack';
      await disconnect();
      return;
    }

    final peerHash = (payload[1] << 24) | (payload[2] << 16) |
                     (payload[3] << 8) | payload[4];
    if (peerHash != _romHash) {
      _error = 'ROM mismatch — both players must play the same game';
      await disconnect();
      return;
    }

    _state = LinkCableState.connected;
    _startPingTimer();
    notifyListeners();
    debugPrint('Link cable: handshake ack received, connected!');
  }

  List<int> _encodeHandshake() {
    return [
      1, // version
      (_romHash >> 24) & 0xFF,
      (_romHash >> 16) & 0xFF,
      (_romHash >> 8) & 0xFF,
      _romHash & 0xFF,
    ];
  }

  void _sendMessage(int type, List<int> payload) {
    if (_socket == null) return;
    final len = payload.length;
    final frame = Uint8List(3 + len);
    frame[0] = type;
    frame[1] = (len >> 8) & 0xFF;
    frame[2] = len & 0xFF;
    for (int i = 0; i < len; i++) {
      frame[3 + i] = payload[i];
    }
    try {
      _socket!.add(frame);
    } catch (e) {
      debugPrint('Link cable: failed to send message: $e');
    }
  }

  /// Send an outgoing SIO byte to the peer.
  void sendSioData(int byte) {
    if (_state != LinkCableState.connected) return;
    _sendMessage(_MsgType.sioData, [byte & 0xFF]);
    _awaitingReply = true;
  }

  /// Check if there is a pending incoming byte from the peer.
  bool get hasIncomingData => _pendingIncomingByte != null;

  /// Consume the pending incoming byte.
  /// Returns the byte value, or -1 if nothing pending.
  int consumeIncomingData() {
    final byte = _pendingIncomingByte;
    _pendingIncomingByte = null;
    return byte ?? -1;
  }

  /// Whether we sent data and are waiting for the peer's reply.
  bool get isAwaitingReply => _awaitingReply;

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_state == LinkCableState.connected) {
        _lastPingSent = DateTime.now();
        _sendMessage(_MsgType.ping, []);
      }
    });
  }

  /// Disconnect and clean up all resources.
  Future<void> disconnect() async {
    if (_disconnecting) return;
    _disconnecting = true;

    _pingTimer?.cancel();
    _pingTimer = null;
    _hostTimeoutTimer?.cancel();
    _hostTimeoutTimer = null;

    if (_socket != null && _state == LinkCableState.connected) {
      try {
        _sendMessage(_MsgType.disconnect, []);
      } catch (e) {
        debugPrint('LinkCableService: failed to send disconnect message — $e');
      }
    }

    try {
      await _socket?.close();
    } catch (e) {
      debugPrint('LinkCableService: failed to close socket — $e');
    }
    _socket = null;

    try {
      await _server?.close();
    } catch (e) {
      debugPrint('LinkCableService: failed to close server — $e');
    }
    _server = null;

    _peerAddress = null;
    _roomCode = null;
    _pendingIncomingByte = null;
    _awaitingReply = false;
    _latencyMs = 0;
    _recvBuffer.clear();

    final wasConnected = _state != LinkCableState.disconnected;
    _state = LinkCableState.disconnected;
    _disconnecting = false;
    if (wasConnected) notifyListeners();
  }

  /// Generate a ROM hash by streaming the **entire** file through FNV-1a.
  /// This is NOT a cryptographic hash — just enough to verify both
  /// players are running the same game.
  ///
  /// The file is read in chunks so large ROMs (up to 32 MB for GBA)
  /// never need to be fully loaded into memory.
  static Future<int> computeRomHash(String romPath) async {
    try {
      final file = File(romPath);
      if (!file.existsSync()) return 0;

      // Stream the entire file through FNV-1a
      int hash = 0x811c9dc5;
      await for (final chunk in file.openRead()) {
        for (final b in chunk) {
          hash ^= b;
          hash = (hash * 0x01000193) & 0xFFFFFFFF;
        }
      }
      // Mix in file size so identical-content files of different sizes
      // (e.g. ROM + padding) still differ.
      final size = await file.length();
      hash ^= size & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
      return hash;
    } catch (e) {
      debugPrint('Failed to compute ROM hash: $e');
      return 0;
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
