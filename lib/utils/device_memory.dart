import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

int? deviceMemoryMB;

const _channel = MethodChannel('com.yourmateapps.retropal/device');

Future<void> initDeviceMemory() async {
  if (deviceMemoryMB != null) return;
  try {
    if (Platform.isAndroid) {
      deviceMemoryMB = await _channel.invokeMethod<int>('getDeviceMemoryMB');
    }
  } catch (e) {
    debugPrint('DeviceMemory: failed to query device RAM — $e');
    deviceMemoryMB = null;
  }
}

int rewindCapacityCap() {
  final mb = deviceMemoryMB;
  if (mb == null || mb < 2048) return 120;   
  if (mb < 4096) return 240;                 
  return 720;                                
}
