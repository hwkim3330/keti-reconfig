import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Android side of the launcher: the installed apps, and the two bits of device state that
/// decide whether a BLE scan can work at all.
///
/// See `android/.../MainActivity.kt`. Everything here is best-effort -- a launcher that throws
/// because it could not read the app list is worse than one that shows an empty drawer.
class Host {
  static const _channel = MethodChannel('keti/launcher');

  static Future<List<InstalledApp>> listApps() async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('listApps') ?? const [];
      return [
        for (final e in raw)
          if (e is Map) InstalledApp.fromMap(e),
      ];
    } catch (e) {
      debugPrint('listApps failed: $e');
      return const [];
    }
  }

  static Future<bool> launch(String package) async =>
      await _invokeBool('launch', {'package': package});

  static Future<bool> openSettings() => _invokeBool('openSettings');
  static Future<bool> openHomeSettings() => _invokeBool('openHomeSettings');
  static Future<bool> openLocationSettings() => _invokeBool('openLocationSettings');
  static Future<bool> isDefaultHome() => _invokeBool('isDefaultHome');
  static Future<bool> locationEnabled() => _invokeBool('locationEnabled', null, true);
  static Future<bool> blePermissionsGranted() => _invokeBool('blePermissionsGranted');
  static Future<bool> requestBlePermissions() => _invokeBool('requestBlePermissions');

  static Future<bool> _invokeBool(
    String method, [
    Map<String, Object?>? args,
    bool orElse = false,
  ]) async {
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? orElse;
    } catch (e) {
      debugPrint('$method failed: $e');
      return orElse;
    }
  }
}

@immutable
class InstalledApp {
  const InstalledApp({required this.package, required this.label, required this.icon});

  final String package;
  final String label;

  /// A 96 px PNG, decoded once by the drawer. Empty when the icon could not be rendered.
  final Uint8List icon;

  factory InstalledApp.fromMap(Map<Object?, Object?> m) => InstalledApp(
        package: (m['package'] ?? '') as String,
        label: (m['label'] ?? '') as String,
        icon: (m['icon'] as Uint8List?) ?? Uint8List(0),
      );
}
