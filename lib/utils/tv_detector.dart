import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Detects whether the app is running on an Android TV device.
class TvDetector {
  static const _channel = MethodChannel('com.yourmateapps.retropal/device');

  static bool _checked = false;
  static bool _isTV = false;

  /// Whether the device is a television. Cached after first call.
  static bool get isTV => _isTV;

  /// Initialise detection. Call once at app startup (e.g. in main).
  /// Safe to call multiple times — only the first call queries the platform.
  static Future<void> initialize() async {
    if (_checked) return;
    _checked = true;
    try {
      _isTV = await _channel.invokeMethod<bool>('isTelevision') ?? false;
    } catch (e) {
      debugPrint('TvDetector: platform channel failed — $e');
      _isTV = false;
    }
  }
}
