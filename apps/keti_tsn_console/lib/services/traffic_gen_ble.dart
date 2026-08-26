import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'traffic_gen_service.dart';

/// BLE control for the traffic generator, so the tablet can start/stop it over
/// Bluetooth with no WiFi - the same central role it already plays for the
/// switches. The Pi advertises as `KETI-TRAFGEN` (see traffic_generator/server/
/// ble_gatt.py) with one control characteristic (write UTF-8 commands) and one
/// status characteristic (notify compact JSON).
///
/// Commands: `start` | `stop` | `preset:<key>` | `user:<name>`
/// Status:   {"r":1,"m":999.8,"p":81258,"s":223390,"e":0}
class TrafficGenBle {
  static const advName = 'KETI-TRAFGEN';
  static final _service = Guid('4b455449-5447-454e-0000-000000000000');
  static final _controlUuid = Guid('4b455449-5447-454e-0000-000000000001');
  static final _statusUuid = Guid('4b455449-5447-454e-0000-000000000002');

  BluetoothDevice? _device;
  BluetoothCharacteristic? _control;
  BluetoothCharacteristic? _status;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _statusSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _connecting = false;
  bool _disposed = false;

  final _linkCtl = StreamController<bool>.broadcast();
  final _sampleCtl = StreamController<TgSample>.broadcast();
  final _runningCtl = StreamController<bool>.broadcast();

  /// true when connected to the peripheral.
  Stream<bool> get link => _linkCtl.stream;

  /// live rate readings decoded from status notifications.
  Stream<TgSample> get samples => _sampleCtl.stream;

  /// whether pktgen is currently running, per the peripheral.
  Stream<bool> get running => _runningCtl.stream;

  bool get connected => _control != null;

  Future<void> connect() async {
    if (_disposed || _connecting || connected) return;
    if (!await FlutterBluePlus.isSupported) return;
    _connecting = true;
    try {
      // If a previous session left the peripheral connected, re-use it instead of
      // scanning (Android keeps GATT links alive across app restarts).
      for (final d in FlutterBluePlus.connectedDevices) {
        if (d.platformName == advName || d.advName == advName) {
          await _attach(d, alreadyConnected: true);
          if (connected) return;
        }
      }
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          if (r.advertisementData.advName == advName) {
            _attach(r.device);
          }
        }
      });
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 20),
        withNames: const [advName],
      );
    } catch (_) {
      // no adapter / scan interrupted - caller retries
    } finally {
      _connecting = false;
    }
  }

  bool _attaching = false;

  Future<void> _attach(BluetoothDevice device, {bool alreadyConnected = false}) async {
    if (_disposed || connected || _attaching) return;
    _attaching = true;
    try {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      if (!alreadyConnected) {
        await device.connect(
            license: License.nonprofit, timeout: const Duration(seconds: 12));
      }
      _device = device;
      try {
        await device.requestMtu(185);
      } catch (_) {/* optional */}

      await _connSub?.cancel();
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) _dropped();
      });

      final services = await device.discoverServices(timeout: 15);
      final svc = services.firstWhere((s) => s.uuid == _service);
      _control = svc.characteristics.firstWhere((c) => c.uuid == _controlUuid);
      _status = svc.characteristics.firstWhere((c) => c.uuid == _statusUuid);

      await _status!.setNotifyValue(true);
      await _statusSub?.cancel();
      _statusSub = _status!.onValueReceived.listen(_onStatus);

      _linkCtl.add(true);
    } catch (_) {
      _dropped();
      try {
        await device.disconnect();
      } catch (_) {}
    } finally {
      _attaching = false;
    }
  }

  void _onStatus(List<int> bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final running = (j['r'] ?? 0) == 1;
      _runningCtl.add(running);
      _sampleCtl.add(TgSample(
        t: 0,
        mbps: ((j['m'] ?? 0) as num).toDouble(),
        pps: ((j['p'] ?? 0) as num).toDouble(),
        sentPackets: (j['s'] ?? 0) as int,
        txErrors: (j['e'] ?? 0) as int,
        txDropped: 0,
      ));
    } catch (_) {/* malformed frame - ignore */}
  }

  void _dropped() {
    _control = null;
    _status = null;
    _statusSub?.cancel();
    _connSub?.cancel();
    if (!_disposed) _linkCtl.add(false);
  }

  Future<void> _send(String command) async {
    final c = _control;
    if (c == null) throw Exception('not connected to $advName');
    await c.write(utf8.encode(command), withoutResponse: c.properties.writeWithoutResponse);
  }

  Future<void> start() => _send('start');
  Future<void> stop() => _send('stop');
  Future<void> loadPreset(String key) => _send('preset:$key');
  // Raw control command (D10 demo: cbs:on/off, frer:on/off, tas:on/off,
  // cut:<link>/restore:<link>) — Pi1 relays it to the switches over JSON-RPC.
  Future<void> sendRaw(String cmd) => _send(cmd);
  Future<void> loadUserPreset(String name) => _send('user:$name');

  Future<void> disconnect() async {
    await _scanSub?.cancel();
    await _statusSub?.cancel();
    await _connSub?.cancel();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _dropped();
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _linkCtl.close();
    _sampleCtl.close();
    _runningCtl.close();
  }
}

/// The built-in presets, mirrored from traffic_generator/server/presets.py, so the
/// BLE-only path (no WiFi to read /api/system) still has preset buttons.
class TgBuiltinPreset {
  const TgBuiltinPreset(this.key, this.label);
  final String key;
  final String label;
}

const kBuiltinPresets = <TgBuiltinPreset>[
  TgBuiltinPreset('cbs_tc2_tc6', 'CBS TC2 + TC6'),
  TgBuiltinPreset('line_rate_1500', '1G line rate (1500B)'),
  TgBuiltinPreset('line_rate_512', '1G line rate (512B)'),
  TgBuiltinPreset('small_frame_stress', '64B stress (4 cores)'),
  TgBuiltinPreset('pcp_sweep', 'PCP sweep (0/2/4/6)'),
  TgBuiltinPreset('background_100m', 'Background 100 Mbps'),
];
