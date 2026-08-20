import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/traffic_gen_ble.dart';
import '../services/traffic_gen_service.dart';

/// Connection lifecycle to the Pi, distinct from whether pktgen is *running*.
enum TgLink { connecting, online, offline }

/// How the tablet reaches the generator. WiFi is the full HTTP path (rich stream
/// editor + live rates); BLE is the Bluetooth path (start/stop + presets + live
/// rates) that needs no network, matching the reconfig demo's BLE-central model.
enum TgTransport { wifi, ble }

class TrafficGenState {
  const TrafficGenState({
    this.transport = TgTransport.wifi,
    this.link = TgLink.connecting,
    this.system,
    this.config,
    this.status = TgStatus.unknown,
    this.last = TgSample.zero,
    this.history = const [],
    this.plan,
    this.message,
    this.isError = false,
  });

  final TgTransport transport;
  final TgLink link;
  final TgSystem? system;
  final TgConfig? config;
  final TgStatus status;
  final TgSample last;
  final List<TgSample> history;
  final Map<String, dynamic>? plan;
  final String? message;
  final bool isError;

  bool get running => status.running;
  bool get isBle => transport == TgTransport.ble;

  double get plannedMbps => ((plan?['total_mbps'] ?? 0) as num).toDouble();
  double get plannedPps => ((plan?['total_pps'] ?? 0) as num).toDouble();
  bool get plannedOverLine => plannedMbps > 1000;

  TrafficGenState copyWith({
    TgTransport? transport,
    TgLink? link,
    TgSystem? system,
    TgConfig? config,
    TgStatus? status,
    TgSample? last,
    List<TgSample>? history,
    Map<String, dynamic>? plan,
    String? message,
    bool? isError,
    bool clearMessage = false,
  }) {
    return TrafficGenState(
      transport: transport ?? this.transport,
      link: link ?? this.link,
      system: system ?? this.system,
      config: config ?? this.config,
      status: status ?? this.status,
      last: last ?? this.last,
      history: history ?? this.history,
      plan: plan ?? this.plan,
      message: clearMessage ? null : (message ?? this.message),
      isError: clearMessage ? false : (isError ?? this.isError),
    );
  }
}

class TrafficGenNotifier extends StateNotifier<TrafficGenState> {
  TrafficGenNotifier(this._svc) : super(const TrafficGenState()) {
    connect();
  }

  final TrafficGenService _svc;
  final TrafficGenBle _ble = TrafficGenBle();
  StreamSubscription? _wsSub;
  StreamSubscription? _bleLinkSub, _bleSampleSub, _bleRunSub;
  Timer? _reconnect, _bleRetry;
  bool _disposed = false;

  static const _historyCap = 240;

  String get baseUrl => _svc.baseUrl;

  Future<void> setEndpoint(String host, int port) async {
    _svc.setEndpoint(host, port);
    await connect();
  }

  // -- transport ------------------------------------------------------------
  Future<void> setTransport(TgTransport t) async {
    if (t == state.transport) return;
    state = state.copyWith(transport: t, history: const [], clearMessage: true);
    if (t == TgTransport.ble) {
      _wsSub?.cancel();
      _reconnect?.cancel();
      _startBle();
    } else {
      _stopBle();
      await connect();
    }
  }

  void _startBle() {
    state = state.copyWith(link: TgLink.connecting);
    _bleLinkSub = _ble.link.listen((up) {
      state = state.copyWith(link: up ? TgLink.online : TgLink.offline);
      if (!up && !_disposed && state.isBle) {
        _bleRetry?.cancel();
        _bleRetry = Timer(const Duration(seconds: 3), () { if (state.isBle) _ble.connect(); });
      }
    });
    _bleSampleSub = _ble.samples.listen((s) {
      final h = [...state.history, s];
      state = state.copyWith(
        last: s,
        history: h.length > _historyCap ? h.sublist(h.length - _historyCap) : h,
      );
    });
    _bleRunSub = _ble.running.listen((r) {
      state = state.copyWith(
          status: TgStatus(running: r, iface: 'eth0', linkMbps: null, operstate: 'up', elapsed: 0, error: null));
    });
    _ble.connect();
  }

  void _stopBle() {
    _bleRetry?.cancel();
    _bleLinkSub?.cancel();
    _bleSampleSub?.cancel();
    _bleRunSub?.cancel();
    _ble.disconnect();
  }

  Future<void> connect() async {
    _reconnect?.cancel();
    _wsSub?.cancel();
    if (_disposed) return;
    state = state.copyWith(link: TgLink.connecting, clearMessage: true);
    try {
      final sys = await _svc.system();
      final cfg = await _svc.config();
      state = state.copyWith(link: TgLink.online, system: sys, config: cfg);
      await refreshPlan();
      _openWs();
    } catch (e) {
      state = state.copyWith(link: TgLink.offline, message: _clean(e), isError: true);
      _scheduleReconnect();
    }
  }

  void _openWs() {
    _wsSub = _svc.liveStream().listen(
      (msg) {
        var next = state;
        if (msg.history != null) next = next.copyWith(history: msg.history);
        if (msg.sample != null) {
          final h = [...next.history, msg.sample!];
          next = next.copyWith(
            last: msg.sample,
            history: h.length > _historyCap ? h.sublist(h.length - _historyCap) : h,
          );
        }
        if (msg.status != null) next = next.copyWith(status: msg.status, link: TgLink.online);
        state = next;
      },
      onError: (_) => _dropAndReconnect(),
      onDone: _dropAndReconnect,
      cancelOnError: true,
    );
  }

  void _dropAndReconnect() {
    if (_disposed) return;
    state = state.copyWith(link: TgLink.offline);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 2), connect);
  }

  Future<void> refreshPlan() async {
    try {
      state = state.copyWith(plan: await _svc.plan());
    } catch (_) {/* plan is advisory; a failure here should not blank the UI */}
  }

  // -- mutations, each guarded so a dead Pi shows a message not an exception ---
  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      state = state.copyWith(message: _clean(e), isError: true);
    }
  }

  Future<void> saveConfig() => _guard(() async {
        if (state.config == null) return;
        final cfg = await _svc.saveConfig(state.config!);
        state = state.copyWith(config: cfg, clearMessage: true);
        await refreshPlan();
      });

  /// Mutate the local config, push it debounced. Callers pass a closure that edits
  /// the (mutable) config in place.
  Timer? _pushDebounce;
  void edit(void Function(TgConfig cfg) change) {
    final cfg = state.config;
    if (cfg == null) return;
    change(cfg);
    state = state.copyWith(config: cfg);
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(milliseconds: 300), saveConfig);
  }

  Future<void> loadPreset(String key) => _guard(() async {
        if (state.isBle) {
          await _ble.loadPreset(key);
          state = state.copyWith(clearMessage: true);
          return;
        }
        final cfg = await _svc.loadPreset(key);
        state = state.copyWith(config: cfg, clearMessage: true);
        await refreshPlan();
      });

  Future<void> start() => _guard(() async {
        if (state.isBle) {
          await _ble.start();
          state = state.copyWith(clearMessage: true);
          return;
        }
        final st = await _svc.start();
        state = state.copyWith(status: st, clearMessage: true);
      });

  Future<void> stop() => _guard(() async {
        if (state.isBle) {
          await _ble.stop();
          state = state.copyWith(clearMessage: true);
          return;
        }
        final st = await _svc.stop();
        state = state.copyWith(status: st, clearMessage: true);
      });

  String _clean(Object e) => e.toString().replaceFirst('Exception: ', '');

  @override
  void dispose() {
    _disposed = true;
    _wsSub?.cancel();
    _reconnect?.cancel();
    _pushDebounce?.cancel();
    _stopBle();
    _ble.dispose();
    super.dispose();
  }
}

/// Default endpoint is the Pi as found on the KETI WiFi (hostname `keti`,
/// 172.31.51.228). Overridable from the screen if the lab re-addresses it.
final trafficGenServiceProvider = Provider<TrafficGenService>((ref) {
  final svc = TrafficGenService(host: '172.31.51.228', port: 8080);
  return svc;
});

final trafficGenProvider =
    StateNotifierProvider<TrafficGenNotifier, TrafficGenState>((ref) {
  return TrafficGenNotifier(ref.watch(trafficGenServiceProvider));
});
