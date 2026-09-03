/// The four fault-injection path modules, over GATT.
///
/// Each module is an ESP32-S3 SuperMini that decides its own number from its eFuse MAC
/// (`firmware/path_module`), advertises as `KETI-PATH<n>`, and exposes one characteristic that is
/// both the command sink and the state source:
///
///   service  9a1e0001-4d3b-4a2f-9c6e-3f1d7b8a2c40
///   control  9a1e0002-4d3b-4a2f-9c6e-3f1d7b8a2c40   write `!SET:FAULT` / `!SET:NORMAL` / `!SYNC`
///                                                   notify `!STATE:<seq>:<path>:<state>:<relay>:<event>`
///
/// There is no pairing and no key: the tablet writes a UTF-8 string to a well-known handle. That
/// is why the two modules added later needed only a MAC-table entry and a reflash to join, and
/// why this app reaches all four with one code path.
///
/// **A connection is not a link.** Every report carries when it was heard. The modules heartbeat
/// once a second while a central is attached, so anything older than [staleAfter] is reported
/// stale rather than redrawn at its last value -- the previous rig showed minutes-old state under
/// a green header because it watched the GATT connection instead of the data.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

const int pathCount = 4;

/// Grace before a connected-but-silent module is called stale. Four heartbeats: long enough that
/// a single dropped notification on a busy 2.4 GHz bench does not flicker the tile.
const Duration staleAfter = Duration(seconds: 4);

final Guid _serviceUuid = Guid('9a1e0001-4d3b-4a2f-9c6e-3f1d7b8a2c40');
final Guid _controlUuid = Guid('9a1e0002-4d3b-4a2f-9c6e-3f1d7b8a2c40');

String pathName(int n) => 'KETI-PATH$n';

/// What one module last said about itself.
@immutable
class PathReport {
  const PathReport({
    required this.path,
    required this.faulted,
    required this.relayClosed,
    required this.sequence,
    required this.event,
    required this.at,
  });

  final int path;
  final bool faulted;
  final bool relayClosed;
  final int sequence;
  final String event;
  final DateTime at;

  bool staleAt(DateTime now) => now.difference(at) > staleAfter;
}

enum LinkState { missing, connecting, connected }

@immutable
class PathLink {
  const PathLink({
    required this.path,
    required this.state,
    this.report,
    this.rssi,
    this.pending = false,
  });

  final int path;
  final LinkState state;
  final PathReport? report;
  final int? rssi;

  /// A command has been written and the module has not yet reported the new state. Held so the
  /// button cannot be hammered into a queue of writes the operator never sees land.
  final bool pending;

  PathLink copyWith({
    LinkState? state,
    PathReport? report,
    int? rssi,
    bool? pending,
    bool clearReport = false,
  }) =>
      PathLink(
        path: path,
        state: state ?? this.state,
        report: clearReport ? null : (report ?? this.report),
        rssi: rssi ?? this.rssi,
        pending: pending ?? this.pending,
      );
}

enum AdapterState { unsupported, unauthorised, off, ready }

@immutable
class LogLine {
  const LogLine(this.at, this.path, this.text);
  final DateTime at;

  /// 0 for a line about the rig as a whole rather than one module.
  final int path;
  final String text;
}

/// The rig as one object: scan, connect, subscribe, command, and the log of what happened.
class Rig extends ChangeNotifier {
  Rig() {
    _init();
  }

  AdapterState _adapter = AdapterState.off;
  AdapterState get adapter => _adapter;

  /// Only meaningful below API 31: a scan on Android 6..11 returns nothing at all, with no error,
  /// when location services are off.
  bool locationBlocked = false;

  bool _scanning = false;
  bool get scanning => _scanning;

  final Map<int, PathLink> _links = {
    for (var n = 1; n <= pathCount; n++)
      n: PathLink(path: n, state: LinkState.missing),
  };
  Map<int, PathLink> get links => _links;

  final List<LogLine> _log = [];
  List<LogLine> get log => List.unmodifiable(_log);

  final Map<int, BluetoothDevice> _devices = {};
  final Map<int, BluetoothCharacteristic> _controls = {};
  final Map<int, StreamSubscription<List<int>>> _valueSubs = {};
  final Map<int, StreamSubscription<BluetoothConnectionState>> _connSubs = {};
  final Set<int> _connecting = {};

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _tick;
  Timer? _rescan;
  bool _disposed = false;

  int get connectedCount =>
      _links.values.where((l) => l.state == LinkState.connected).length;

  /// True when every module is connected *and* still talking. This is the one indicator worth
  /// putting on the header, so it is computed from the reports rather than the sockets.
  bool get allLive {
    final now = DateTime.now();
    return _links.values.every((l) =>
        l.state == LinkState.connected &&
        l.report != null &&
        !l.report!.staleAt(now));
  }

  Future<void> _init() async {
    if (!await FlutterBluePlus.isSupported) {
      _adapter = AdapterState.unsupported;
      notifyListeners();
      return;
    }
    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      final was = _adapter;
      _adapter = switch (s) {
        BluetoothAdapterState.on => AdapterState.ready,
        BluetoothAdapterState.unauthorized => AdapterState.unauthorised,
        BluetoothAdapterState.unavailable => AdapterState.unsupported,
        _ => AdapterState.off,
      };
      if (_adapter != was) {
        _note(0, 'bluetooth ${_adapter.name}');
        if (_adapter == AdapterState.ready) {
          startScan();
        } else {
          _dropAll();
        }
        notifyListeners();
      }
    });

    // One timer redraws the ages and expires stale reports. Every tile reads the same clock, so
    // there is no per-tile timer to leak on a device this small.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_links.values.any((l) => l.report != null)) notifyListeners();
    });
  }

  // ---------------------------------------------------------------------------
  // scanning
  // ---------------------------------------------------------------------------

  Future<void> startScan() async {
    if (_disposed || _scanning || _adapter != AdapterState.ready) return;
    if (_links.values.every((l) => l.state == LinkState.connected)) return;
    _scanning = true;
    notifyListeners();

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
    try {
      // Filtered on the service UUID the firmware puts in the advertisement, with the name in the
      // scan response. Unfiltered scanning on this tablet returns the whole room and costs more
      // than the radio work.
      await FlutterBluePlus.startScan(
        withServices: [_serviceUuid],
        timeout: const Duration(seconds: 20),
      );
    } catch (e) {
      _note(0, 'scan failed: $e');
    }
    _scanning = false;
    _scheduleRescan();
    notifyListeners();
  }

  /// Android throttles an app to five scan starts per 30 s and then silently stops returning
  /// results. Restarts are spaced rather than chained off the previous scan ending.
  void _scheduleRescan() {
    _rescan?.cancel();
    if (_disposed) return;
    if (_links.values.every((l) => l.state == LinkState.connected)) return;
    _rescan = Timer(const Duration(seconds: 7), startScan);
  }

  void _onScanResults(List<ScanResult> results) {
    for (final r in results) {
      final name = r.device.platformName.isNotEmpty
          ? r.device.platformName
          : r.advertisementData.advName;
      for (var n = 1; n <= pathCount; n++) {
        if (name != pathName(n)) continue;
        _links[n] = _links[n]!.copyWith(rssi: r.rssi);
        if (_links[n]!.state == LinkState.missing) _connect(n, r.device);
      }
      if (name == 'KETI-PATH-UNKNOWN') {
        _noteOnce('unknown', 0,
            'a module is advertising as PATH-UNKNOWN: its MAC is not in the firmware table');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // connection
  // ---------------------------------------------------------------------------

  Future<void> _connect(int n, BluetoothDevice device) async {
    if (_connecting.contains(n)) return;
    _connecting.add(n);
    _links[n] = _links[n]!.copyWith(state: LinkState.connecting);
    notifyListeners();

    try {
      await _connSubs[n]?.cancel();
      _connSubs[n] = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) _onDisconnected(n);
      });

      await device.connect(
          license: License.nonprofit, timeout: const Duration(seconds: 12));
      final services = await device.discoverServices();
      BluetoothCharacteristic? control;
      for (final s in services) {
        if (s.serviceUuid != _serviceUuid) continue;
        for (final c in s.characteristics) {
          if (c.characteristicUuid == _controlUuid) control = c;
        }
      }
      if (control == null) {
        _note(n, 'connected but the control characteristic is missing');
        await device.disconnect();
        return;
      }

      await _valueSubs[n]?.cancel();
      _valueSubs[n] = control.onValueReceived.listen((v) => _onNotify(n, v));
      await control.setNotifyValue(true);

      _devices[n] = device;
      _controls[n] = control;
      _links[n] = _links[n]!.copyWith(state: LinkState.connected, pending: false);
      _note(n, 'connected');
      notifyListeners();

      // Ask for state immediately. The module only heartbeats once a second, and a tile that sits
      // blank for a second after connecting reads as a failure.
      await control.write(utf8.encode('!SYNC'), withoutResponse: false);
    } catch (e) {
      _note(n, 'connect failed: $e');
      _links[n] = _links[n]!.copyWith(state: LinkState.missing);
      notifyListeners();
    } finally {
      _connecting.remove(n);
      _scheduleRescan();
    }
  }

  void _onDisconnected(int n) {
    _valueSubs[n]?.cancel();
    _valueSubs.remove(n);
    _controls.remove(n);
    _devices.remove(n);
    if (_links[n]!.state != LinkState.missing) _note(n, 'lost');
    // The report is dropped, not kept greyed out: on disconnect the firmware restores the relay
    // to NORMAL by itself, so the last value we hold is known to be wrong from that moment.
    _links[n] = PathLink(path: n, state: LinkState.missing, rssi: _links[n]!.rssi);
    notifyListeners();
    _scheduleRescan();
  }

  void _dropAll() {
    for (var n = 1; n <= pathCount; n++) {
      _devices[n]?.disconnect();
      _onDisconnected(n);
    }
  }

  // ---------------------------------------------------------------------------
  // state decoding
  // ---------------------------------------------------------------------------

  /// `!STATE:<seq>:<path>:<NORMAL|FAULT>:<relay>:<event>`
  void _onNotify(int n, List<int> value) {
    final text = utf8.decode(value, allowMalformed: true).trim();
    if (!text.startsWith('!STATE:')) return;
    final parts = text.split(':');
    if (parts.length < 6) return;
    final seq = int.tryParse(parts[1]) ?? 0;
    final reported = int.tryParse(parts[2]) ?? 0;
    final faulted = parts[3] == 'FAULT';
    final relay = parts[4] == '1';
    final event = parts.sublist(5).join(':');

    // The module names itself in every report. If that disagrees with the advertised name we
    // connected on, say so rather than filing the state under the wrong tile.
    if (reported != n) {
      _noteOnce('mismatch$n', n,
          'reports itself as path $reported but advertises as ${pathName(n)}');
      return;
    }

    final was = _links[n]!.report;
    _links[n] = _links[n]!.copyWith(
      report: PathReport(
        path: n,
        faulted: faulted,
        relayClosed: relay,
        sequence: seq,
        event: event,
        at: DateTime.now(),
      ),
      pending: false,
    );
    if (was == null || was.faulted != faulted) {
      _note(n, faulted ? 'CUT ($event)' : 'RESTORED ($event)');
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // commands
  // ---------------------------------------------------------------------------

  Future<void> setFault(int n, bool faulted) async {
    final control = _controls[n];
    if (control == null) {
      _note(n, 'not connected: command dropped');
      return;
    }
    _links[n] = _links[n]!.copyWith(pending: true);
    notifyListeners();
    try {
      await control.write(
        utf8.encode(faulted ? '!SET:FAULT' : '!SET:NORMAL'),
        withoutResponse: false,
      );
    } catch (e) {
      _note(n, 'command failed: $e');
      _links[n] = _links[n]!.copyWith(pending: false);
      notifyListeners();
    }
  }

  Future<void> toggle(int n) async {
    final r = _links[n]?.report;
    if (r == null) return;
    await setFault(n, !r.faulted);
  }

  /// Apply a whole rig state at once. Writes are sequential: four concurrent GATT writes on this
  /// tablet's stack queue anyway, and serialising them keeps the log in the order things happened.
  Future<void> setAll(bool faulted) async {
    for (var n = 1; n <= pathCount; n++) {
      if (_links[n]!.state == LinkState.connected) await setFault(n, faulted);
    }
  }

  /// Cut exactly one path and restore the rest -- the shape every reconfiguration scenario takes.
  Future<void> cutOnly(int n) async {
    for (var i = 1; i <= pathCount; i++) {
      if (_links[i]!.state != LinkState.connected) continue;
      await setFault(i, i == n);
    }
  }

  /// Ask Android to turn the radio on, rather than sending the operator to Settings. This app is
  /// the home screen: "go to Settings" means leaving the only thing on the tablet that shows the
  /// rig. On API 25 this raises the system consent dialog and comes back through [adapterState].
  Future<void> turnOnBluetooth() async {
    try {
      await FlutterBluePlus.turnOn();
    } catch (e) {
      _note(0, 'bluetooth on failed: $e');
      notifyListeners();
    }
  }

  Future<void> resync() async {
    for (final entry in _controls.entries) {
      try {
        await entry.value.write(utf8.encode('!SYNC'), withoutResponse: false);
      } catch (_) {}
    }
    startScan();
  }

  // ---------------------------------------------------------------------------
  // log
  // ---------------------------------------------------------------------------

  final Set<String> _onceKeys = {};

  void _note(int path, String text) {
    _log.insert(0, LogLine(DateTime.now(), path, text));
    if (_log.length > 200) _log.removeLast();
  }

  void _noteOnce(String key, int path, String text) {
    if (!_onceKeys.add(key)) return;
    _note(path, text);
    notifyListeners();
  }

  void clearLog() {
    _log.clear();
    _onceKeys.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _rescan?.cancel();
    _scanSub?.cancel();
    _adapterSub?.cancel();
    for (final s in _valueSubs.values) {
      s.cancel();
    }
    for (final s in _connSubs.values) {
      s.cancel();
    }
    super.dispose();
  }
}
