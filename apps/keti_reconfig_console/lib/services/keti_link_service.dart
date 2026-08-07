import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// The three peripherals this console drives. The tablet is the only BLE central in the rig:
/// the previous demo put an ESP32 in that role and it wedged inside the GATT client with no
/// timeout, taking down everything that was supposed to recover it.
enum KetiDevice { switchController, path1, path2 }

extension KetiDeviceName on KetiDevice {
  String get advertisedName => switch (this) {
        KetiDevice.switchController => 'KETI-SWITCH',
        KetiDevice.path1 => 'KETI-PATH1',
        KetiDevice.path2 => 'KETI-PATH2',
      };

  String get label => switch (this) {
        KetiDevice.switchController => 'Switch',
        KetiDevice.path1 => 'Path 1',
        KetiDevice.path2 => 'Path 2',
      };
}

class SwitchPort {
  const SwitchPort({
    required this.index,
    required this.name,
    required this.up,
    required this.inOctets,
    required this.outOctets,
    required this.inUnicast,
    required this.outUnicast,
    required this.inErrors,
    required this.outErrors,
    required this.inDiscards,
    required this.outDiscards,
  });

  final int index;
  final String name;
  final bool up;
  final int inOctets;
  final int outOctets;
  final int inUnicast;
  final int outUnicast;
  final int inErrors;
  final int outErrors;
  final int inDiscards;
  final int outDiscards;
}

/// One complete reading of the switch. Ports are however many arrived -- the bench LAN9662
/// reports three, the target LAN9692 will report more, and nothing here assumes a count.
class SwitchSnapshot {
  const SwitchSnapshot({
    required this.sequence,
    required this.ports,
    required this.ethernetLinkUp,
    required this.catalogOk,
    required this.catalog,
    required this.receivedAt,
  });

  final int sequence;
  final List<SwitchPort> ports;
  final bool ethernetLinkUp;

  /// False when the switch reports a YANG catalog other than the one the controller's SID
  /// table was generated from. The SIDs then address different nodes, so the counters would be
  /// wrong in a way that still looks plausible -- the controller sends no ports at all.
  final bool catalogOk;
  final String catalog;
  final DateTime receivedAt;
}

class PathSnapshot {
  const PathSnapshot({
    required this.path,
    required this.faulted,
    required this.relayClosed,
    required this.sequence,
    required this.event,
    required this.receivedAt,
  });

  final int path;
  final bool faulted;
  final bool relayClosed;
  final int sequence;
  final String event;
  final DateTime receivedAt;
}

/// Everything the console knows, and when it learned it.
class KetiState {
  const KetiState({
    this.connected = const {},
    this.switchSnapshot,
    this.pathSnapshots = const {},
    this.scanning = false,
  });

  final Set<KetiDevice> connected;
  final SwitchSnapshot? switchSnapshot;
  final Map<int, PathSnapshot> pathSnapshots;
  final bool scanning;

  KetiState copyWith({
    Set<KetiDevice>? connected,
    SwitchSnapshot? switchSnapshot,
    Map<int, PathSnapshot>? pathSnapshots,
    bool? scanning,
  }) {
    return KetiState(
      connected: connected ?? this.connected,
      switchSnapshot: switchSnapshot ?? this.switchSnapshot,
      pathSnapshots: pathSnapshots ?? this.pathSnapshots,
      scanning: scanning ?? this.scanning,
    );
  }
}

/// Holds one GATT link per peripheral and turns their notification lines into state.
///
/// Freshness is tracked per device rather than inferred from the connection. A GATT link stays
/// up when the peer stops talking, and a console that only watches the link shows the last
/// values it received as though they were current -- which is how the previous rig quoted a
/// measurement taken minutes before the gateway died.
class KetiLinkService {
  static final Guid _switchService = Guid('9a1e0101-4d3b-4a2f-9c6e-3f1d7b8a2c40');
  static final Guid _switchState = Guid('9a1e0102-4d3b-4a2f-9c6e-3f1d7b8a2c40');
  static final Guid _pathService = Guid('9a1e0001-4d3b-4a2f-9c6e-3f1d7b8a2c40');
  static final Guid _pathControl = Guid('9a1e0002-4d3b-4a2f-9c6e-3f1d7b8a2c40');

  /// The switch controller publishes every two seconds and the path modules every second, so
  /// this is several missed updates rather than a tight deadline.
  static const staleAfter = Duration(seconds: 6);

  final _states = StreamController<KetiState>.broadcast();
  Stream<KetiState> get states => _states.stream;

  KetiState _state = const KetiState();
  KetiState get state => _state;

  final _devices = <KetiDevice, BluetoothDevice>{};
  final _controls = <KetiDevice, BluetoothCharacteristic>{};
  final _subscriptions = <KetiDevice, StreamSubscription<List<int>>>{};
  final _connectionSubscriptions =
      <KetiDevice, StreamSubscription<BluetoothConnectionState>>{};
  final _connecting = <KetiDevice>{};
  final _partialPorts = <SwitchPort>[];
  int _partialSequence = -1;
  SwitchSnapshot? _pendingHeaderless;

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  Timer? _rescan;
  bool _disposed = false;

  void _emit() {
    if (!_disposed && !_states.isClosed) _states.add(_state);
  }

  Future<void> start() async {
    if (!await FlutterBluePlus.isSupported) return;
    await _scan();
  }

  Future<void> _scan() async {
    if (_disposed) return;
    final missing = KetiDevice.values.where((d) => !_devices.containsKey(d)).toList();
    if (missing.isEmpty) return;

    _state = _state.copyWith(scanning: true);
    _emit();
    try {
      await _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final name = result.advertisementData.advName;
          for (final device in KetiDevice.values) {
            if (name == device.advertisedName && !_devices.containsKey(device)) {
              _connect(device, result.device);
            }
          }
        }
      });
      // One long window with the results listener connecting as devices appear, rather than
      // short scans separated by sleeps: a board that reboots just after a window closes
      // would otherwise stay invisible for as long as the gap.
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 25));
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
    } catch (_) {
      // No adapter, or the scan was stopped underneath us. The retry below covers both.
    } finally {
      _state = _state.copyWith(scanning: false);
      _emit();
      _rescan?.cancel();
      if (!_disposed) {
        _rescan = Timer(const Duration(milliseconds: 600), _scan);
      }
    }
  }

  Future<void> _connect(KetiDevice which, BluetoothDevice device) async {
    if (_disposed || _devices.containsKey(which) || _connecting.contains(which)) return;
    _connecting.add(which);
    try {
      await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 10));
      _devices[which] = device;
      await device.requestMtu(247);

      await _connectionSubscriptions[which]?.cancel();
      _connectionSubscriptions[which] = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) _dropped(which);
      });

      final services = await device.discoverServices(timeout: 15);
      final wantedService =
          which == KetiDevice.switchController ? _switchService : _pathService;
      final wantedCharacteristic =
          which == KetiDevice.switchController ? _switchState : _pathControl;
      final service = services.firstWhere((s) => s.uuid == wantedService);
      final characteristic =
          service.characteristics.firstWhere((c) => c.uuid == wantedCharacteristic);
      _controls[which] = characteristic;

      await _subscriptions[which]?.cancel();
      _subscriptions[which] =
          characteristic.lastValueStream.listen((value) => _onLine(which, value));
      await characteristic.setNotifyValue(true);

      _state = _state.copyWith(connected: {..._state.connected, which});
      _emit();
      if (which != KetiDevice.switchController) {
        await sendPath(which, '!SYNC');
      }
    } catch (_) {
      try {
        await device.disconnect();
      } catch (_) {
        // Already gone; the drop handler below is what matters.
      }
      _dropped(which);
    } finally {
      _connecting.remove(which);
    }
  }

  void _dropped(KetiDevice which) {
    _devices.remove(which);
    _controls.remove(which);
    _subscriptions[which]?.cancel();
    _subscriptions.remove(which);
    _connectionSubscriptions[which]?.cancel();
    _connectionSubscriptions.remove(which);
    // Say it. Tearing down quietly leaves the last values on screen with nothing behind them.
    _state = _state.copyWith(connected: {..._state.connected}..remove(which));
    _emit();
    if (!_disposed) {
      _rescan?.cancel();
      _rescan = Timer(const Duration(milliseconds: 400), _scan);
    }
  }

  void _onLine(KetiDevice which, List<int> value) {
    final line = utf8.decode(value, allowMalformed: true).trim();
    if (line.isEmpty) return;
    if (line.startsWith('!SWITCH:')) {
      _onSwitchHeader(line);
    } else if (line.startsWith('!PORT:')) {
      _onPort(line);
    } else if (line.startsWith('!STATE:')) {
      _onPathState(line);
    }
  }

  void _onSwitchHeader(String line) {
    // !SWITCH:<seq>:<portCount>:<LINK|NOLINK>:<CATALOG_OK|CATALOG_BAD>:<catalog>
    final f = line.split(':');
    if (f.length < 6) return;
    _partialSequence = int.tryParse(f[1]) ?? -1;
    _partialPorts.clear();
    _pendingHeaderless = SwitchSnapshot(
      sequence: _partialSequence,
      ports: const [],
      ethernetLinkUp: f[3] == 'LINK',
      catalogOk: f[4] == 'CATALOG_OK',
      catalog: f[5],
      receivedAt: DateTime.now(),
    );
    final expected = int.tryParse(f[2]) ?? 0;
    if (expected == 0) _publishSwitch();
  }

  void _onPort(String line) {
    // !PORT:<seq>:<i>:<name>:<UP|DOWN>:in:out:inUni:outUni:inErr:outErr:inDisc:outDisc
    final f = line.split(':');
    if (f.length < 13) return;
    final sequence = int.tryParse(f[1]) ?? -1;
    // A port from a different snapshot than the header would mix two readings into one row.
    if (sequence != _partialSequence) return;
    int at(int i) => int.tryParse(f[i]) ?? 0;
    _partialPorts.add(SwitchPort(
      index: at(2),
      name: f[3],
      up: f[4] == 'UP',
      inOctets: at(5),
      outOctets: at(6),
      inUnicast: at(7),
      outUnicast: at(8),
      inErrors: at(9),
      outErrors: at(10),
      inDiscards: at(11),
      outDiscards: at(12),
    ));
    _publishSwitch();
  }

  void _publishSwitch() {
    final header = _pendingHeaderless;
    if (header == null) return;
    _state = _state.copyWith(
      switchSnapshot: SwitchSnapshot(
        sequence: header.sequence,
        ports: List.unmodifiable(_partialPorts),
        ethernetLinkUp: header.ethernetLinkUp,
        catalogOk: header.catalogOk,
        catalog: header.catalog,
        receivedAt: DateTime.now(),
      ),
    );
    _emit();
  }

  void _onPathState(String line) {
    // !STATE:<seq>:<path>:<NORMAL|FAULT>:<relay>:<event>
    final f = line.split(':');
    if (f.length < 6) return;
    final path = int.tryParse(f[2]) ?? 0;
    if (path == 0) return;
    final snapshot = PathSnapshot(
      path: path,
      faulted: f[3] == 'FAULT',
      relayClosed: f[4] == '1',
      sequence: int.tryParse(f[1]) ?? 0,
      event: f[5],
      receivedAt: DateTime.now(),
    );
    _state = _state.copyWith(
      pathSnapshots: {..._state.pathSnapshots, path: snapshot},
    );
    _emit();
  }

  Future<bool> sendPath(KetiDevice which, String command) async {
    final characteristic = _controls[which];
    if (characteristic == null) return false;
    try {
      await characteristic.write(utf8.encode(command), withoutResponse: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setPathFault(int path, bool faulted) {
    final which = path == 1 ? KetiDevice.path1 : KetiDevice.path2;
    return sendPath(which, faulted ? '!SET:FAULT' : '!SET:NORMAL');
  }

  Future<void> dispose() async {
    _disposed = true;
    _rescan?.cancel();
    await _scanSubscription?.cancel();
    for (final s in _subscriptions.values) {
      await s.cancel();
    }
    for (final s in _connectionSubscriptions.values) {
      await s.cancel();
    }
    for (final d in _devices.values) {
      await d.disconnect();
    }
    await _states.close();
  }
}
