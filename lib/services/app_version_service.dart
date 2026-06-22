import 'package:package_info_plus/package_info_plus.dart';

/// Central app version source, derived from pubspec via platform package info.
class AppVersionService {
  static Future<PackageInfo>? _cachedInfo;

  static Future<PackageInfo> _packageInfo() {
    return _cachedInfo ??= PackageInfo.fromPlatform();
  }

  static Future<String> pubspecStyleVersion() async {
    final info = await _packageInfo();
    if (info.buildNumber.isEmpty) {
      return info.version;
    }
    return '${info.version}+${info.buildNumber}';
  }

  /// Marketing version only (pubspec `version` before the `+`), e.g. `24.0.0`.
  /// Used to key per-version UI like the What's New dialog so a build-number
  /// bump alone does not re-trigger it.
  static Future<String> marketingVersion() async {
    final info = await _packageInfo();
    return info.version;
  }
}
