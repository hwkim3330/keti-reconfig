/// Client for the pi-trafgen server (traffic_generator/server on the Pi).
///
/// The Pi is a separate IP node on the same WiFi as the tablet - it is NOT one of
/// the BLE peripherals in [KetiLinkService]. pktgen needs a full Linux TX path and
/// gigabit MAC, which the ESP32 switch controllers do not have, so the generator
/// lives on its own box and is driven over HTTP + a WebSocket for the live rates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// models
// ---------------------------------------------------------------------------
class TgInterface {
  const TgInterface({
    required this.name,
    required this.speedMbps,
    required this.operstate,
    required this.txQueues,
    required this.driver,
  });

  final String name;
  final int? speedMbps;
  final String operstate;
  final int txQueues;
  final String driver;

  factory TgInterface.fromJson(Map<String, dynamic> j) => TgInterface(
        name: j['name'] as String,
        speedMbps: j['speed_mbps'] as int?,
        operstate: (j['operstate'] ?? 'unknown') as String,
        txQueues: (j['tx_queues'] ?? 1) as int,
        driver: (j['driver'] ?? '') as String,
      );

  bool get up => operstate == 'up';
}

class TgPreset {
  const TgPreset({required this.key, required this.label, required this.note});
  final String key;
  final String label;
  final String note;
}

class TgSystem {
  const TgSystem({
    required this.pktgen,
    required this.cpus,
    required this.root,
    required this.interfaces,
    required this.presets,
  });

  final bool pktgen;
  final int cpus;
  final bool root;
  final List<TgInterface> interfaces;
  final List<TgPreset> presets;

  factory TgSystem.fromJson(Map<String, dynamic> j) => TgSystem(
        pktgen: j['pktgen'] == true,
        cpus: (j['cpus'] ?? 1) as int,
        root: j['root'] == true,
        interfaces: [
          for (final i in (j['interfaces'] as List? ?? []))
            TgInterface.fromJson(i as Map<String, dynamic>)
        ],
        presets: [
          for (final e in (j['presets'] as Map<String, dynamic>? ?? {}).entries)
            TgPreset(
              key: e.key,
              label: (e.value['label'] ?? e.key) as String,
              note: (e.value['note'] ?? '') as String,
            )
        ],
      );

  /// Reasons the generator cannot run, for showing a clear banner instead of a
  /// silent failure on Start.
  String? get blockReason {
    if (!pktgen) return 'pktgen module not loaded on the Pi';
    if (!root) return 'server is not running as root';
    return null;
  }
}

/// One stream. Field names mirror the server's StreamModel exactly so the whole
/// object round-trips through /api/config untouched.
class TgStream {
  TgStream({
    this.name = 'stream',
    this.enabled = true,
    this.queue = 0,
    this.cpu = 0,
    this.frameSize = 512,
    this.count = 0,
    this.dstMac = 'ff:ff:ff:ff:ff:ff',
    this.srcMac = '',
    this.dstIp = '10.0.100.2',
    this.srcIp = '',
    this.udpSrc = 9,
    this.udpDst = 9,
    this.vlanId,
    this.pcp = 0,
    this.rateMode = 'max',
    this.rateValue = 0,
    this.cloneSkb = 100000,
    this.burst = 8,
  });

  String name;
  bool enabled;
  int queue;
  int cpu;
  int frameSize;
  int count;
  String dstMac;
  String srcMac;
  String dstIp;
  String srcIp;
  int udpSrc;
  int udpDst;
  int? vlanId;
  int pcp;
  String rateMode; // max | mbps | pps
  double rateValue;
  int cloneSkb;
  int burst;

  factory TgStream.fromJson(Map<String, dynamic> j) => TgStream(
        name: (j['name'] ?? 'stream') as String,
        enabled: j['enabled'] != false,
        queue: (j['queue'] ?? 0) as int,
        cpu: (j['cpu'] ?? 0) as int,
        frameSize: (j['frame_size'] ?? 512) as int,
        count: (j['count'] ?? 0) as int,
        dstMac: (j['dst_mac'] ?? 'ff:ff:ff:ff:ff:ff') as String,
        srcMac: (j['src_mac'] ?? '') as String,
        dstIp: (j['dst_ip'] ?? '10.0.100.2') as String,
        srcIp: (j['src_ip'] ?? '') as String,
        udpSrc: (j['udp_src'] ?? 9) as int,
        udpDst: (j['udp_dst'] ?? 9) as int,
        vlanId: j['vlan_id'] as int?,
        pcp: (j['pcp'] ?? 0) as int,
        rateMode: (j['rate_mode'] ?? 'max') as String,
        rateValue: ((j['rate_value'] ?? 0) as num).toDouble(),
        cloneSkb: (j['clone_skb'] ?? 0) as int,
        burst: (j['burst'] ?? 0) as int,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'enabled': enabled,
        'queue': queue,
        'cpu': cpu,
        'frame_size': frameSize,
        'count': count,
        'dst_mac': dstMac,
        'src_mac': srcMac,
        'dst_ip': dstIp,
        'src_ip': srcIp,
        'udp_src': udpSrc,
        'udp_dst': udpDst,
        'vlan_id': vlanId,
        'pcp': pcp,
        'rate_mode': rateMode,
        'rate_value': rateValue,
        'clone_skb': cloneSkb,
        'burst': burst,
      };

  TgStream copy() => TgStream.fromJson(toJson());
}

class TgConfig {
  TgConfig({required this.iface, required this.streams});
  String iface;
  List<TgStream> streams;

  factory TgConfig.fromJson(Map<String, dynamic> j) => TgConfig(
        iface: (j['iface'] ?? 'eth0') as String,
        streams: [
          for (final s in (j['streams'] as List? ?? []))
            TgStream.fromJson(s as Map<String, dynamic>)
        ],
      );

  Map<String, dynamic> toJson() =>
      {'iface': iface, 'streams': [for (final s in streams) s.toJson()]};
}

/// One live TX reading pushed over the WebSocket.
class TgSample {
  const TgSample({
    required this.t,
    required this.mbps,
    required this.pps,
    required this.sentPackets,
    required this.txErrors,
    required this.txDropped,
  });

  final double t;
  final double mbps;
  final double pps;
  final int sentPackets;
  final int txErrors;
  final int txDropped;

  factory TgSample.fromJson(Map<String, dynamic> j) => TgSample(
        t: ((j['t'] ?? 0) as num).toDouble(),
        mbps: ((j['mbps'] ?? 0) as num).toDouble(),
        pps: ((j['pps'] ?? 0) as num).toDouble(),
        sentPackets: (j['sent_packets'] ?? 0) as int,
        txErrors: (j['tx_errors'] ?? 0) as int,
        txDropped: (j['tx_dropped'] ?? 0) as int,
      );

  static const zero =
      TgSample(t: 0, mbps: 0, pps: 0, sentPackets: 0, txErrors: 0, txDropped: 0);
}

class TgStatus {
  const TgStatus({
    required this.running,
    required this.iface,
    required this.linkMbps,
    required this.operstate,
    required this.elapsed,
    required this.error,
  });

  final bool running;
  final String iface;
  final int? linkMbps;
  final String operstate;
  final double elapsed;
  final String? error;

  factory TgStatus.fromJson(Map<String, dynamic> j) => TgStatus(
        running: j['running'] == true,
        iface: (j['iface'] ?? '') as String,
        linkMbps: j['link_mbps'] as int?,
        operstate: (j['operstate'] ?? 'unknown') as String,
        elapsed: ((j['elapsed'] ?? 0) as num).toDouble(),
        error: j['error'] as String?,
      );

  static const unknown = TgStatus(
      running: false, iface: '', linkMbps: null, operstate: 'unknown', elapsed: 0, error: null);
}

class TgWsMessage {
  const TgWsMessage({this.status, this.sample, this.history});
  final TgStatus? status;
  final TgSample? sample;
  final List<TgSample>? history;
}

// ---------------------------------------------------------------------------
// service
// ---------------------------------------------------------------------------
class TrafficGenService {
  TrafficGenService({String host = '172.31.51.228', int port = 8080})
      : _host = host,
        _port = port;

  String _host;
  int _port;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 4);

  String get host => _host;
  int get port => _port;
  String get baseUrl => 'http://$_host:$_port';

  void setEndpoint(String host, int port) {
    _host = host;
    _port = port;
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> _getJson(String path) async {
    final req = await _http.getUrl(_uri(path));
    final res = await req.close().timeout(const Duration(seconds: 5));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) throw _err(body, res.statusCode);
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(String path, [Object? payload]) async {
    final req = await _http.postUrl(_uri(path));
    req.headers.contentType = ContentType.json;
    if (payload != null) req.write(jsonEncode(payload));
    final res = await req.close().timeout(const Duration(seconds: 5));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) throw _err(body, res.statusCode);
    return body.isEmpty ? {} : jsonDecode(body) as Map<String, dynamic>;
  }

  Exception _err(String body, int code) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['detail'] != null) return Exception(j['detail'].toString());
    } catch (_) {}
    return Exception('HTTP $code');
  }

  Future<TgSystem> system() async => TgSystem.fromJson(await _getJson('/api/system'));
  Future<TgConfig> config() async => TgConfig.fromJson(await _getJson('/api/config'));
  Future<TgStatus> status() async => TgStatus.fromJson(await _getJson('/api/status'));

  Future<TgConfig> saveConfig(TgConfig cfg) async =>
      TgConfig.fromJson(await _postJson('/api/config', cfg.toJson()));

  Future<TgConfig> loadPreset(String key) async =>
      TgConfig.fromJson(await _postJson('/api/preset/$key'));

  Future<TgStatus> start() async => TgStatus.fromJson(await _postJson('/api/start'));
  Future<TgStatus> stop() async => TgStatus.fromJson(await _postJson('/api/stop'));

  Future<Map<String, dynamic>> plan() => _getJson('/api/plan');

  /// Live rate stream. Reconnects are handled by the caller (the provider) so the
  /// UI can show a "reconnecting" state rather than a stall.
  Stream<TgWsMessage> liveStream() async* {
    final ws = await WebSocket.connect('ws://$_host:$_port/ws')
        .timeout(const Duration(seconds: 5));
    try {
      await for (final raw in ws) {
        final j = jsonDecode(raw as String) as Map<String, dynamic>;
        yield TgWsMessage(
          status: j['status'] != null
              ? TgStatus.fromJson(j['status'] as Map<String, dynamic>)
              : null,
          sample: j['sample'] != null
              ? TgSample.fromJson(j['sample'] as Map<String, dynamic>)
              : null,
          history: j['history'] != null
              ? [
                  for (final s in (j['history'] as List))
                    TgSample.fromJson(s as Map<String, dynamic>)
                ]
              : null,
        );
      }
    } finally {
      await ws.close();
    }
  }
}
