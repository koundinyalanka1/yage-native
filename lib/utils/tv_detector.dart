import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class TvDetector {
  static const _channel = MethodChannel('com.yourmateapps.retropal/device');

  static bool _checked = false;
  static bool _isTV = false;

  static bool get isTV => _isTV;

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
