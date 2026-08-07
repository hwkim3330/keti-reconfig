import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// The three peripherals this console drives. The tablet is the only BLE central in the rig:
/// the previous demo put an ESP32 in that role and it wedged inside the GATT client with no
/// timeout, taking down everything that was supposed to recover it.
/// One controller per switch is where the rig is going: the RECON topology is three ZCUs,
/// each with its own LAN9692. The switches are listed explicitly rather than discovered by
/// pattern -- a console that connects to whatever calls itself a switch would happily attach
/// to a neighbouring bench.
enum KetiDevice { switch1, switch2, switch3, path1, path2 }

extension KetiDeviceName on KetiDevice {
  String get advertisedName => switch (this) {
        KetiDevice.switch1 => 'KETI-SWITCH1',
        KetiDevice.switch2 => 'KETI-SWITCH2',
        KetiDevice.switch3 => 'KETI-SWITCH3',
        KetiDevice.path1 => 'KETI-PATH1',
        KetiDevice.path2 => 'KETI-PATH2',
      };

  String get label => switch (this) {
        KetiDevice.switch1 => 'Switch 1',
        KetiDevice.switch2 => 'Switch 2',
        KetiDevice.switch3 => 'Switch 3',
        KetiDevice.path1 => 'Path 1',
        KetiDevice.path2 => 'Path 2',
      };

  bool get isSwitch =>
      this == KetiDevice.switch1 || this == KetiDevice.switch2 || this == KetiDevice.switch3;
}

/// The switches, in order. Used wherever the console has to iterate them.
const kSwitchDevices = [KetiDevice.switch1, KetiDevice.switch2, KetiDevice.switch3];

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
    this.platform = '',
    this.protectedPort = '',
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

  /// What the switch calls itself, read from ietf-system. Not a constant in the app: the bench
  /// part answers LAN9662 and the target answers LAN9692, and a hardcoded label would be
  /// quietly wrong on one of them.
  final String platform;

  /// The port the controller itself reaches the switch through, as reported by the controller.
  /// Not a constant here: it was port 1 on the LAN9662 and is port 12 on the LAN9692, and a
  /// second copy of that fact would eventually disagree with the firmware that enforces it.
  final String protectedPort;
  final DateTime receivedAt;
}

/// One port's gate parameters, fetched on demand rather than carried in every snapshot.
class TasSnapshot {
  const TasSnapshot({
    required this.port,
    required this.enabled,
    required this.cycleNs,
    required this.gateStates,
    this.windows = const [],
    required this.receivedAt,
  });

  final String port;
  final bool enabled;
  final int cycleNs;
  final int gateStates;
  final List<GateWindow> windows;
  final DateTime receivedAt;
}

/// One window of the gate control list: which traffic classes are open, and for how long.
class GateWindow {
  const GateWindow(this.mask, this.nanoseconds);

  final int mask;
  final int nanoseconds;

  bool isOpen(int trafficClass) => (mask >> trafficClass) & 1 == 1;
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
    this.switches = const {},
    this.pathSnapshots = const {},
    this.tas = const {},
    this.scanning = false,
  });

  final Set<KetiDevice> connected;
  final Map<KetiDevice, SwitchSnapshot> switches;
  final Map<int, PathSnapshot> pathSnapshots;
  final Map<KetiDevice, Map<String, TasSnapshot>> tas;

  /// The switches that have ever reported, in device order. One switch is the common case and
  /// the console shows no selector for it.
  List<KetiDevice> get presentSwitches =>
      kSwitchDevices.where(switches.containsKey).toList();
  final bool scanning;

  KetiState copyWith({
    Set<KetiDevice>? connected,
    Map<KetiDevice, SwitchSnapshot>? switches,
    Map<int, PathSnapshot>? pathSnapshots,
    Map<KetiDevice, Map<String, TasSnapshot>>? tas,
    bool? scanning,
  }) {
    return KetiState(
      connected: connected ?? this.connected,
      switches: switches ?? this.switches,
      pathSnapshots: pathSnapshots ?? this.pathSnapshots,
      tas: tas ?? this.tas,
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
  final _partialPorts = <KetiDevice, List<SwitchPort>>{};
  final _partialSequence = <KetiDevice, int>{};
  final _expectedPorts = <KetiDevice, int>{};
  final _pendingHeader = <KetiDevice, SwitchSnapshot>{};
  final _platform = <KetiDevice, String>{};

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
      final wantedService = which.isSwitch ? _switchService : _pathService;
      final wantedCharacteristic = which.isSwitch ? _switchState : _pathControl;
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
      if (!which.isSwitch) await sendPath(which, '!SYNC');
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
      _onSwitchHeader(which, line);
    } else if (line.startsWith('!PORT:')) {
      _onPort(which, line);
    } else if (line.startsWith('!GCL:')) {
      _onGcl(which, line);
    } else if (line.startsWith('!TAS:')) {
      _onTas(which, line);
    } else if (line.startsWith('!PLATFORM:')) {
      _onPlatform(which, line);
    } else if (line.startsWith('!STATE:')) {
      _onPathState(line);
    }
  }

  void _onSwitchHeader(KetiDevice which, String line) {
    // !SWITCH:<seq>:<portCount>:<LINK|NOLINK>:<CATALOG_OK|CATALOG_BAD>:<catalog>:<uplinkPort>
    final f = line.split(':');
    if (f.length < 6) return;
    final sequence = int.tryParse(f[1]) ?? -1;
    _partialSequence[which] = sequence;
    _partialPorts[which] = <SwitchPort>[];
    _pendingHeader[which] = SwitchSnapshot(
      sequence: sequence,
      ports: const [],
      ethernetLinkUp: f[3] == 'LINK',
      catalogOk: f[4] == 'CATALOG_OK',
      catalog: f[5],
      protectedPort: f.length > 6 ? f[6] : '',
      receivedAt: DateTime.now(),
    );
    _expectedPorts[which] = int.tryParse(f[2]) ?? 0;
    // Nothing is published yet. A snapshot arrives as a header followed by one line per port,
    // and emitting on each line made the console redraw the list thirteen times a cycle,
    // growing from one port to all of them -- which is the flicker. A partial snapshot is also
    // not a reading: it is a reading in progress.
    if (_expectedPorts[which] == 0) _publishSwitch(which);
  }

  void _onPlatform(KetiDevice which, String line) {
    final f = line.split(':');
    if (f.length < 3) return;
    _platform[which] = f.sublist(2).join(':');
  }

  void _onTas(KetiDevice which, String line) {
    // !TAS:<seq>:<port>:<ON|OFF>:<cycleNs>:<gateStates>
    final f = line.split(':');
    if (f.length < 6) return;
    _state = _state.copyWith(tas: {
      ..._state.tas,
      which: {
        ...(_state.tas[which] ?? const {}),
        f[2]: TasSnapshot(
          port: f[2],
          enabled: f[3] == 'ON',
          cycleNs: int.tryParse(f[4]) ?? 0,
          gateStates: int.tryParse(f[5]) ?? 0,
          receivedAt: DateTime.now(),
        ),
      },
    });
    _emit();
  }

  /// Windows arrive separately from the rest of the gate parameters, so they are merged onto
  /// whatever TAS snapshot is already held for that port rather than replacing it.
  void _onGcl(KetiDevice which, String line) {
    // !GCL:<seq>:<port>:<mask>,<ns>;<mask>,<ns>;...
    final f = line.split(':');
    if (f.length < 4) return;
    final port = f[2];
    final windows = <GateWindow>[];
    for (final chunk in f[3].split(';')) {
      final parts = chunk.split(',');
      if (parts.length != 2) continue;
      final mask = int.tryParse(parts[0]);
      final ns = int.tryParse(parts[1]);
      if (mask == null || ns == null) continue;
      windows.add(GateWindow(mask, ns));
    }
    final existing = _state.tas[which]?[port];
    if (existing == null) return;
    _state = _state.copyWith(tas: {
      ..._state.tas,
      which: {
        ...(_state.tas[which] ?? const {}),
        port: TasSnapshot(
          port: port,
          enabled: existing.enabled,
          cycleNs: existing.cycleNs,
          gateStates: existing.gateStates,
          windows: windows,
          receivedAt: DateTime.now(),
        ),
      },
    });
    _emit();
  }

  void _onPort(KetiDevice which, String line) {
    // !PORT:<seq>:<i>:<name>:<UP|DOWN>:in:out:inUni:outUni:inErr:outErr:inDisc:outDisc
    final f = line.split(':');
    if (f.length < 13) return;
    final sequence = int.tryParse(f[1]) ?? -1;
    // A port from a different snapshot than the header would mix two readings into one row.
    if (sequence != _partialSequence[which]) return;
    int at(int i) => int.tryParse(f[i]) ?? 0;
    (_partialPorts[which] ??= <SwitchPort>[]).add(SwitchPort(
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
    if ((_partialPorts[which]?.length ?? 0) >= (_expectedPorts[which] ?? 0)) {
      _publishSwitch(which);
    }
  }

  void _publishSwitch(KetiDevice which) {
    final header = _pendingHeader[which];
    if (header == null) return;
    _state = _state.copyWith(switches: {
      ..._state.switches,
      which: SwitchSnapshot(
        sequence: header.sequence,
        ports: List.unmodifiable(_partialPorts[which] ?? const <SwitchPort>[]),
        ethernetLinkUp: header.ethernetLinkUp,
        catalogOk: header.catalogOk,
        catalog: header.catalog,
        platform: _platform[which] ?? '',
        protectedPort: header.protectedPort,
        receivedAt: DateTime.now(),
      ),
    });
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

  /// Asks the controller to enable or disable a switch port. The console deliberately does not
  /// know any SIDs: the controller owns the generated table and is the only thing that checked
  /// the device's catalog, so it is the only thing entitled to write.
  Future<bool> setPortEnabled(KetiDevice which, String port, bool enabled) {
    return sendPath(which, '!PORT:$port:${enabled ? 'UP' : 'DOWN'}');
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
