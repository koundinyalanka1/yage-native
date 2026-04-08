import 'package:package_info_plus/package_info_plus.dart';

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
}
