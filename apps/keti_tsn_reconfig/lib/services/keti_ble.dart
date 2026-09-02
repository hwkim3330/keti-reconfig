import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// The rig, over GATT.
///
/// Six peripherals: the three LAN9692 switch controllers and the three inline injection modules
/// that sit in the links between them. The tablet is the only central -- an earlier demo put an
/// ESP32 in that role and it wedged inside the GATT client with no timeout, taking down the very
/// thing that was supposed to recover it.
///
/// The protocol is the reconfig console's, unchanged, because it is the firmware's: modules
/// publish `!STATE:<seq>:<path>:<NORMAL|FAULT>:<relay>:<event>` about once a second and take
/// `!SET:FAULT` / `!SET:NORMAL`.
///
/// One rule runs through all of this: **a connection is not a link**. Everything below carries
/// the time it was last heard from, and anything older than [staleAfter] is reported stale rather
/// than reported at its last value. The previous rig showed a green header and minutes-old
/// counters after its gateway had gone silent, because it watched the connection instead of the
/// data.
enum KetiPeer { switch1, switch2, switch3, path1, path2, path3 }

extension KetiPeerInfo on KetiPeer {
  String get advertisedName => switch (this) {
        KetiPeer.switch1 => 'KETI-SWITCH1',
        KetiPeer.switch2 => 'KETI-SWITCH2',
        KetiPeer.switch3 => 'KETI-SWITCH3',
        KetiPeer.path1 => 'KETI-PATH1',
        KetiPeer.path2 => 'KETI-PATH2',
        KetiPeer.path3 => 'KETI-PATH3',
      };

  String get label => switch (this) {
        KetiPeer.switch1 => 'TSN-F A',
        KetiPeer.switch2 => 'TSN-F B',
        KetiPeer.switch3 => 'TSN-R',
        KetiPeer.path1 => 'INJ 1',
        KetiPeer.path2 => 'INJ 2',
        KetiPeer.path3 => 'INJ 3',
      };

  bool get isPath => index >= KetiPeer.path1.index;

  /// 1..3 for the injection modules, 0 for a switch.
  int get pathNumber => isPath ? index - KetiPeer.path1.index + 1 : 0;
}

/// What one injection module last said about itself.
class PathReport {
  final int path;
  final bool faulted;
  final bool relayClosed;
  final int sequence;
  final String event;
  final DateTime at;

  const PathReport({
    required this.path,
    required this.faulted,
    required this.relayClosed,
    required this.sequence,
    required this.event,
    required this.at,
  });
}

/// What one switch controller last said. Deliberately shallow: the port map on this console comes
/// off the design sheets, so all the rig has to add is whether the controller is alive and
/// whether its own uplink is up.
class SwitchReport {
  final int sequence;
  final bool ethernetLinkUp;
  final String platform;
  final DateTime at;

  const SwitchReport({
    required this.sequence,
    required this.ethernetLinkUp,
    required this.platform,
    required this.at,
  });
}

enum BleStatus { unsupported, unauthorised, off, idle, scanning, connected }

class RigState {
  final BleStatus status;
  final Set<KetiPeer> connected;
  final Map<int, PathReport> paths;
  final Map<KetiPeer, SwitchReport> switches;
  final String? detail;

  const RigState({
    this.status = BleStatus.idle,
    this.connected = const {},
    this.paths = const {},
    this.switches = const {},
    this.detail,
  });

  bool get anyLive => connected.isNotEmpty;

  /// Fresh reports only. A report older than [KetiBle.staleAfter] is not an answer.
  PathReport? path(int n) {
    final r = paths[n];
    if (r == null) return null;
    return DateTime.now().difference(r.at) > KetiBle.staleAfter ? null : r;
  }

  bool isStale(int n) => paths[n] != null && path(n) == null;

  RigState copyWith({
    BleStatus? status,
    Set<KetiPeer>? connected,
    Map<int, PathReport>? paths,
    Map<KetiPeer, SwitchReport>? switches,
    String? detail,
  }) =>
      RigState(
        status: status ?? this.status,
        connected: connected ?? this.connected,
        paths: paths ?? this.paths,
        switches: switches ?? this.switches,
        detail: detail ?? this.detail,
      );
}

class KetiBle {
  static const staleAfter = Duration(seconds: 5);
  static const _rescanEvery = Duration(seconds: 6);

  static final _pathService = Guid('9a1e0001-4d3b-4a2f-9c6e-3f1d7b8a2c40');
  static final _pathControl = Guid('9a1e0002-4d3b-4a2f-9c6e-3f1d7b8a2c40');
  static final _switchService = Guid('9a1e0101-4d3b-4a2f-9c6e-3f1d7b8a2c40');
  static final _switchState = Guid('9a1e0102-4d3b-4a2f-9c6e-3f1d7b8a2c40');

  final _states = StreamController<RigState>.broadcast();
  Stream<RigState> get states => _states.stream;
  RigState get state => _state;

  RigState _state = const RigState();
  final _devices = <KetiPeer, BluetoothDevice>{};
  final _controls = <KetiPeer, BluetoothCharacteristic>{};
  final _notifies = <KetiPeer, StreamSubscription<List<int>>>{};
  final _connections = <KetiPeer, StreamSubscription<BluetoothConnectionState>>{};
  final _partial = <KetiPeer, String>{};

  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _rescan;
  Timer? _tick;
  bool _disposed = false;
  bool _running = false;

  /// Starts scanning and keeps trying. Safe to call twice; safe to call on a tablet with no BLE.
  Future<void> start() async {
    if (_running || _disposed) return;
    _running = true;

    if (!await FlutterBluePlus.isSupported) {
      _emit(_state.copyWith(status: BleStatus.unsupported, detail: 'No Bluetooth on this device'));
      return;
    }
    // Android 12+ wants the runtime grants; without them the scan returns nothing and says
    // nothing, which is indistinguishable from an absent rig.
    try {
      await FlutterBluePlus.adapterState.first;
    } catch (_) {}

    FlutterBluePlus.adapterState.listen((s) {
      if (_disposed) return;
      if (s == BluetoothAdapterState.on) {
        _scan();
      } else {
        _emit(_state.copyWith(status: BleStatus.off, detail: 'Bluetooth is off'));
      }
    });

    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _emit(_state));
    _rescan = Timer.periodic(_rescanEvery, (_) => _scan());
    await _scan();
  }

  Future<void> _scan() async {
    if (_disposed) return;
    if (_devices.length == KetiPeer.values.length) return;
    if (FlutterBluePlus.isScanningNow) return;
    try {
      _emit(_state.copyWith(
          status: _state.connected.isEmpty ? BleStatus.scanning : BleStatus.connected));
      _scanSub ??= FlutterBluePlus.scanResults.listen(_onScan);
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    } on FlutterBluePlusException catch (e) {
      _emit(_state.copyWith(
        status: e.description?.toLowerCase().contains('permission') ?? false
            ? BleStatus.unauthorised
            : BleStatus.off,
        detail: e.description ?? 'Scan refused',
      ));
    } catch (e) {
      _emit(_state.copyWith(status: BleStatus.off, detail: '$e'));
    }
  }

  void _onScan(List<ScanResult> results) {
    if (_disposed) return;
    for (final r in results) {
      final name = r.advertisementData.advName;
      if (name.isEmpty) continue;
      for (final peer in KetiPeer.values) {
        // Matched by exact advertised name on purpose. A console that attaches to whatever calls
        // itself a switch would happily join a neighbouring bench.
        if (name == peer.advertisedName && !_devices.containsKey(peer)) {
          _devices[peer] = r.device;
          _connect(peer, r.device);
        }
      }
    }
  }

  Future<void> _connect(KetiPeer peer, BluetoothDevice device) async {
    _connections[peer]?.cancel();
    _connections[peer] = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _controls.remove(peer);
        _notifies.remove(peer)?.cancel();
        _devices.remove(peer);
        _emit(_state.copyWith(connected: {..._state.connected}..remove(peer)));
      }
    });
    try {
      // License.nonprofit, as in the reconfig console: KETI is a government research institute.
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 8),
        autoConnect: false,
      );
      final services = await device.discoverServices();
      final wantService = peer.isPath ? _pathService : _switchService;
      final wantChar = peer.isPath ? _pathControl : _switchState;
      final svc = services.firstWhere((s) => s.uuid == wantService);
      final chr = svc.characteristics.firstWhere((c) => c.uuid == wantChar);
      _controls[peer] = chr;
      _notifies[peer] = chr.lastValueStream.listen((v) => _onBytes(peer, v));
      await chr.setNotifyValue(true);
      _emit(_state.copyWith(
        status: BleStatus.connected,
        connected: {..._state.connected, peer},
        detail: null,
      ));
    } catch (e) {
      _devices.remove(peer);
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  /// Notifications arrive in MTU-sized pieces, so lines are reassembled per peer.
  void _onBytes(KetiPeer peer, List<int> value) {
    if (value.isEmpty) return;
    var buffer = (_partial[peer] ?? '') + utf8.decode(value, allowMalformed: true);
    while (true) {
      final cut = buffer.indexOf('\n');
      if (cut < 0) break;
      _onLine(peer, buffer.substring(0, cut).trim());
      buffer = buffer.substring(cut + 1);
    }
    // A module that never sends a newline still has to be understood.
    if (buffer.startsWith('!') && buffer.endsWith(':')) {
      // partial record, keep waiting
    } else if (buffer.startsWith('!STATE:') && buffer.split(':').length >= 6) {
      _onLine(peer, buffer.trim());
      buffer = '';
    }
    _partial[peer] = buffer;
  }

  void _onLine(KetiPeer peer, String line) {
    if (line.isEmpty) return;
    if (line.startsWith('!STATE:')) {
      // !STATE:<seq>:<path>:<NORMAL|FAULT>:<relay>:<event>
      final f = line.split(':');
      if (f.length < 6) return;
      final path = int.tryParse(f[2]) ?? peer.pathNumber;
      if (path == 0) return;
      _emit(_state.copyWith(paths: {
        ..._state.paths,
        path: PathReport(
          path: path,
          faulted: f[3] == 'FAULT',
          relayClosed: f[4] == '1',
          sequence: int.tryParse(f[1]) ?? 0,
          event: f[5],
          at: DateTime.now(),
        ),
      }));
    } else if (line.startsWith('!SW:') || line.startsWith('!HDR:')) {
      final f = line.split(':');
      _emit(_state.copyWith(switches: {
        ..._state.switches,
        peer: SwitchReport(
          sequence: int.tryParse(f.length > 1 ? f[1] : '') ?? 0,
          ethernetLinkUp: f.length > 2 && f[2] == '1',
          platform: f.length > 3 ? f[3] : '',
          at: DateTime.now(),
        ),
      }));
    }
  }

  /// Opens or closes the relay in one injection module. Returns false when the write did not go
  /// out; it never reports success on the strength of having asked -- the caller reflects the
  /// module's own `!STATE` instead.
  Future<bool> setPathFault(int path, bool faulted) async {
    final peer = switch (path) {
      1 => KetiPeer.path1,
      2 => KetiPeer.path2,
      3 => KetiPeer.path3,
      _ => null,
    };
    final chr = peer == null ? null : _controls[peer];
    if (chr == null) return false;
    try {
      await chr.write(utf8.encode(faulted ? '!SET:FAULT' : '!SET:NORMAL'), withoutResponse: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _emit(RigState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  Future<void> dispose() async {
    _disposed = true;
    _rescan?.cancel();
    _tick?.cancel();
    await _scanSub?.cancel();
    for (final s in _notifies.values) {
      await s.cancel();
    }
    for (final s in _connections.values) {
      await s.cancel();
    }
    for (final d in _devices.values) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    await _states.close();
  }
}
