import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class HardwareReconfigState {
  const HardwareReconfigState({
    this.connected = false,
    this.mode = 'OFFLINE',
    this.event = 'Waiting for ESP controller',
    this.channels = const {},
    this.sequence = 0,
    this.ioNodeConnected = false,
    this.pathNodes = const {},
  });

  final bool connected;
  final String mode;
  final String event;
  final Map<String, String> channels;
  final int sequence;
  final bool ioNodeConnected;
  final Map<String, bool> pathNodes;
}

class HardwareReconfigService {
  HardwareReconfigService({
    this.url = 'ws://10.0.2.2:8766',
    this.directBle = false,
  });

  final String url;
  final bool directBle;
  final _states = StreamController<HardwareReconfigState>.broadcast();
  WebSocket? _socket;
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _bleControl;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _valueSubscription;
  Timer? _retry;
  Timer? _bleRetry;
  Timer? _gatewaySilence;
  bool _disposed = false;
  bool _bleConnecting = false;
  bool _gattConnecting = false;
  final Map<String, String> _bleChannels = {};
  String _bleMode = 'UNKNOWN';
  int _bleSequence = 0;
  DateTime? _lastSyncRequestAt;
  bool _bleIoNodeConnected = false;

  // Path node liveness is reported by the 7-inch controller over !PATHNODE:.
  // It must never be inferred from advertising: once the controller connects to
  // a path node as a BLE client, that node stops advertising, so scanning would
  // report the healthy, actively-controlled case as offline.
  final Map<String, bool> _blePathNodes = {
    'PLEOS-PATH1': false,
    'PLEOS-PATH2': false,
  };

  static final Guid _bleServiceUuid = Guid(
    '7d2f0001-7c7a-4f7b-9b51-0af9a281d110',
  );
  static final Guid _bleControlUuid = Guid(
    '7d2f0002-7c7a-4f7b-9b51-0af9a281d110',
  );

  Stream<HardwareReconfigState> get states => _states.stream;

  void connect() {
    // A real tablet has no bridge to reach: ws://10.0.2.2 is an emulator-only
    // alias, so opening it would retry forever and a later drop would push a
    // blank OFFLINE state over the live BLE state.
    if (!directBle) _open();
    if (directBle) _startBleScan();
  }

  Future<void> _startBleScan() async {
    if (_disposed || _bleConnecting || _bleControl != null) return;
    _bleConnecting = true;
    try {
      if (!await FlutterBluePlus.isSupported) return;
      await _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          if (result.advertisementData.serviceUuids.contains(_bleServiceUuid) ||
              result.advertisementData.advName == 'PLEOS-RECONFIG') {
            FlutterBluePlus.stopScan();
            _connectBle(result.device);
            break;
          }
        }
      });
      // Scan in one long window and let the results listener connect the moment
      // the controller appears, then retry almost immediately. The old shape --
      // an 8 s scan followed by a fixed 8 s sleep and a 2 s retry gap -- spent
      // most of its time not listening, so a controller that rebooted just
      // after a scan window closed took over 20 s to be found. Measured 26 s to
      // reconnect, during which every operator action was lost.
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
    } catch (_) {
      // Android Automotive emulators commonly expose no BLE adapter.
    } finally {
      _bleConnecting = false;
      if (!_disposed && _bleControl == null && !_gattConnecting) {
        _bleRetry?.cancel();
        _bleRetry = Timer(const Duration(milliseconds: 400), _startBleScan);
      }
    }
  }

  Future<void> _connectBle(BluetoothDevice device) async {
    if (_disposed || _bleControl != null || _gattConnecting) return;
    _gattConnecting = true;
    _bleRetry?.cancel();
    await FlutterBluePlus.stopScan();
    try {
      await device.connect(
        license: License.nonprofit,
        mtu: null,
        timeout: const Duration(seconds: 8),
      );
      _bleDevice = device;
      await device.requestMtu(185);
      await _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) _bleDisconnected();
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final services = await device.discoverServices(timeout: 12);
      final service = services.firstWhere(
        (item) => item.uuid == _bleServiceUuid,
      );
      final control = service.characteristics.firstWhere(
        (item) => item.uuid == _bleControlUuid,
      );
      _bleControl = control;
      await _valueSubscription?.cancel();
      _valueSubscription = control.lastValueStream.listen(_onBleValue);
      await control.setNotifyValue(true);
      await _requestSync();
    } catch (_) {
      // disconnect() itself throws when the adapter went away, and that used to
      // skip _bleDisconnected(): no timer, no scan, no subscription, so the
      // service stayed dead until an app restart even after Bluetooth returned.
      try {
        await device.disconnect();
      } catch (_) {
        // Already gone; the reconnect path below is what matters.
      }
      _bleDisconnected();
    } finally {
      _gattConnecting = false;
    }
  }

  void _onBleValue(List<int> value) {
    final line = utf8.decode(value, allowMalformed: true).trim();
    var emit = false;
    if (line.startsWith('!STATE:')) {
      final fields = line.split(':');
      if (fields.length >= 4) {
        final sequence = int.tryParse(fields[1]) ?? _bleSequence;
        // The controller bumps seq once per sendState() and notifies one !STATE:
        // per bump, so a jump means a notify was dropped and the 9 !CHANNEL:
        // lines of that snapshot may be gone with it. A decrease means it
        // rebooted. Either way the cached channel map can no longer be trusted.
        if (_bleSequence != 0 &&
            (sequence < _bleSequence || sequence > _bleSequence + 1)) {
          // A failed resync write is not fatal here: the next gap retries it.
          _requestSync().ignore();
        }
        _armGatewaySilenceTimer();
        _bleSequence = sequence;
        _bleMode = fields[2];
        _bleIoNodeConnected = fields[3] == 'ONLINE';
        emit = _bleChannels.length >= 9;
      }
    } else if (line.startsWith('!CHANNEL:')) {
      final fields = line.split(':');
      if (fields.length >= 3) _bleChannels[fields[1]] = fields[2];
    } else if (line.startsWith('!PATHNODE:')) {
      final fields = line.split(':');
      if (fields.length >= 3) {
        _blePathNodes['PLEOS-PATH${fields[1]}'] = fields[2] == 'ONLINE';
      }
    } else if (line.startsWith('!EVENT:')) {
      emit = true;
    }
    if (!emit) return;
    _states.add(
      HardwareReconfigState(
        connected: true,
        mode: _bleMode,
        event: line.startsWith('!EVENT:') ? line.substring(7) : 'BLE linked',
        channels: Map.unmodifiable(_bleChannels),
        sequence: _bleSequence,
        ioNodeConnected: _bleIoNodeConnected,
        pathNodes: Map.unmodifiable(_blePathNodes),
      ),
    );
  }

  /// Asks the controller for a complete snapshot, rate limited so a burst of
  /// dropped notifications cannot turn into a !SYNC storm. Throws if the write
  /// fails so the caller on the connect path can treat it as a failed link.
  Future<void> _requestSync() async {
    final control = _bleControl;
    if (_disposed || control == null) return;
    final now = DateTime.now();
    final last = _lastSyncRequestAt;
    if (last != null && now.difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _lastSyncRequestAt = now;
    await control.write(utf8.encode('!SYNC'), withoutResponse: false);
  }

  /// The controller sends a !STATE: every second. Going quiet for much longer than that means
  /// the link is useless even while Android still reports it connected -- which is exactly
  /// what a wedged controller looks like from here: notifications stop, the GATT link stays
  /// up, and nothing arrives to correct the console. Without this the header sat green on a
  /// snapshot minutes old and the timing chips kept quoting a measurement taken before the
  /// gateway died. Silence is now treated as a lost link and torn down so the reconnect path
  /// runs.
  static const _gatewaySilenceLimit = Duration(seconds: 5);

  void _armGatewaySilenceTimer() {
    _gatewaySilence?.cancel();
    if (_disposed) return;
    _gatewaySilence = Timer(_gatewaySilenceLimit, _onGatewaySilent);
  }

  Future<void> _onGatewaySilent() async {
    if (_disposed || _bleControl == null) return;
    // Captured before the teardown clears it.
    final device = _bleDevice;
    _bleDisconnected();
    try {
      await device?.disconnect();
    } catch (_) {
      // Already gone. The rescan scheduled by _bleDisconnected is what matters.
    }
  }

  void _bleDisconnected() {
    _gatewaySilence?.cancel();
    _bleControl = null;
    _bleDevice = null;
    _gattConnecting = false;
    // Forget the sequence so the first !STATE: after reconnecting is not read
    // as a gap; _connectBle already issues its own !SYNC.
    _bleSequence = 0;
    _lastSyncRequestAt = null;
    for (final name in _blePathNodes.keys) {
      _blePathNodes[name] = false;
    }
    // Say so. This used to tear down the internals silently, so the console kept the last
    // live state on screen -- green header, path nodes still ACK -- with no link behind it.
    // Guarded the same way the bridge path guards its own drop: never blank out a state that
    // the other transport is still feeding.
    if (!_disposed && _socket == null) {
      _states.add(
        const HardwareReconfigState(event: 'Gateway link lost'),
      );
    }
    if (!_disposed) {
      _bleRetry?.cancel();
      _bleRetry = Timer(const Duration(milliseconds: 400), _startBleScan);
    }
  }

  Future<void> _open() async {
    if (_disposed || _socket != null) return;
    try {
      final socket = await WebSocket.connect(
        url,
      ).timeout(const Duration(seconds: 2));
      if (_disposed) return socket.close();
      _socket = socket;
      socket.listen(
        _onMessage,
        onDone: _disconnected,
        onError: (_) => _disconnected(),
      );
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      if (data.containsKey('error')) return;
      final channels = (data['channels'] as Map? ?? {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
      final pathNodes = (data['path_nodes'] as Map? ?? {}).map(
        (key, value) => MapEntry(
          key.toString(),
          value is Map && value['connected'] == true,
        ),
      );
      _states.add(
        HardwareReconfigState(
          connected: true,
          mode: data['mode']?.toString() ?? 'UNKNOWN',
          event: data['event']?.toString() ?? 'state',
          channels: channels,
          sequence: (data['seq'] as num?)?.toInt() ?? 0,
          ioNodeConnected: data['io_node_connected'] == true,
          pathNodes: pathNodes,
        ),
      );
    } catch (_) {
      // The host bridge validates framing and CRC. Ignore malformed JSON only.
    }
  }

  void runScenario(int scenario) =>
      _send({'command': 'scenario', 'id': scenario});

  void setChannel(String id, String health) =>
      _send({'command': 'channel', 'id': id, 'health': health});

  void setExclusivePathFault(int path) =>
      _send({'command': 'path', 'id': path});

  void recover() => _send({'command': 'recover'});

  void _send(Map<String, Object> command) {
    final control = _bleControl;
    if (control != null) {
      final String wireCommand;
      if (command['command'] == 'recover') {
        wireCommand = '!RECOVER';
      } else if (command['command'] == 'scenario') {
        wireCommand = '!SCENARIO:${command['id']}';
      } else if (command['command'] == 'path') {
        wireCommand = '!PATH:${command['id']}';
      } else {
        wireCommand = '!CHANNEL:${command['id']}:${command['health']}';
      }
      // A dropped operator command matters on a surface that drives relays, so
      // surface the failure instead of letting the future's error vanish.
      control.write(utf8.encode(wireCommand), withoutResponse: false).catchError((
        Object _,
      ) {
        _states.add(
          HardwareReconfigState(
            connected: true,
            mode: _bleMode,
            event: 'Command failed: $wireCommand',
            channels: Map.unmodifiable(_bleChannels),
            sequence: _bleSequence,
            ioNodeConnected: _bleIoNodeConnected,
            pathNodes: Map.unmodifiable(_blePathNodes),
          ),
        );
      });
      return;
    }
    _socket?.add(jsonEncode(command));
  }

  void _disconnected() {
    _socket = null;
    if (_disposed) return;
    // Never let a bridge drop overwrite a live BLE link with a blank state.
    if (_bleControl == null) _states.add(const HardwareReconfigState());
    if (!directBle) _scheduleRetry();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), _open);
  }

  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    _bleRetry?.cancel();
    _gatewaySilence?.cancel();
    if (directBle) await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _valueSubscription?.cancel();
    await _bleDevice?.disconnect();
    await _socket?.close();
    await _states.close();
  }
}
