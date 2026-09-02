import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/reference.dart';
import '../services/keti_ble.dart';

/// Where the link states on screen come from.
///
/// The default is [RigMode.reference]: nothing is attached, so no link is claimed either way.
/// The previous generation of this console showed a green header and minutes-old counters
/// after its gateway had gone silent, because it watched the connection rather than the data.
/// So an unattached console here says "no rig" instead of drawing a healthy vehicle.
enum RigMode {
  /// Static harness reference. Ports show what they are wired to, not whether they are up.
  reference,

  /// A scripted rig with injected faults, stamped SIMULATED everywhere it is visible.
  simulated,

  /// The real rig over GATT. Nothing is generated: a path is faulted because its own module said
  /// so, and a module that has gone quiet reads stale rather than reading at its last value.
  live,
}

enum LinkState { unknown, up, degraded, down }

class RigSnapshot {
  final RigMode mode;

  /// Keyed by ACU_IT port id ('2-3'), by ACU_NO jack id ('CAM 3'), and by ACU_NO LAN index
  /// ('lan0'..'lan3').
  final Map<String, LinkState> links;

  /// Mb/s on the links that carry a rate, same keys. Empty in reference mode.
  final Map<String, double> rates;

  final DateTime at;

  const RigSnapshot({
    required this.mode,
    required this.links,
    required this.rates,
    required this.at,
  });

  LinkState link(String key) =>
      mode == RigMode.reference ? LinkState.unknown : (links[key] ?? LinkState.unknown);

  double? rate(String key) => mode == RigMode.reference ? null : rates[key];

  int get downCount => links.values.where((s) => s == LinkState.down).length;
}

/// A named fault the demo can inject, so a walkthrough is a sequence of states rather than a
/// sequence of taps.
class Scenario {
  final String id;
  final String title;
  final String detail;

  /// Port / jack keys forced down.
  final Set<String> down;

  /// Keys forced to a degraded link.
  final Set<String> degraded;

  const Scenario(this.id, this.title, this.detail, {this.down = const {}, this.degraded = const {}});
}

const scenarios = <Scenario>[
  Scenario('normal', 'All links up', 'Every labelled port carrying traffic.'),
  Scenario('fk_front', 'Falcon K1 front down', 'Port 0-1 lost. Roof forward LiDAR gone; front cover falls to the Hummingbird.',
      down: {'0-1'}),
  Scenario('hb_rear', 'Hummingbird rear down', 'Port 0-2 lost. Rear cover falls to the roof-rear Falcon.',
      down: {'0-2'}),
  Scenario('backbone10g', 'ACU_NO 10G backbone down', 'Port 1-1 lost. Camera traffic has to fall back to the 1G link on port 1-2.',
      down: {'1-1'}, degraded: {'1-2'}),
  Scenario('cam3', 'CAM 3 jack down', 'Side LH FRT and Side RH RR both lost — one dual jack carries two feeds.',
      down: {'CAM 3'}),
  Scenario('path3', 'TSN path 3 cut', 'The front cross-link is gone. The two front switches can only reach each other through the centre.',
      down: {'path3'}),
  Scenario('path1', 'TSN path 1 cut', 'Front A to rear is gone. Everything the front pair carries has to take path 2.',
      down: {'path1'}, degraded: {'path2'}),
  Scenario('path2', 'TSN path 2 cut', 'Front B to rear is gone. Path 1 carries both halves.',
      down: {'path2'}, degraded: {'path1'}),
  Scenario('bothpaths', 'Both TSN paths cut', 'No route left between the front pair and the rear switch.',
      down: {'path1', 'path2'}),
  Scenario('tcu', 'TCU_M link down', 'Port 2-2 lost. Telematics off the ACU_IT side; ACU_NO still reaches TCU-M on its own 1G links.',
      down: {'2-2'}),
];

class RigController extends ChangeNotifier {
  RigController() {
    _ble.states.listen((s) {
      _rig = s;
      if (_mode == RigMode.live) _recompute();
      notifyListeners();
    });
  }

  final KetiBle _ble = KetiBle();
  RigState _rig = const RigState();

  /// What the rig itself is reporting. Exposed so the chrome can say "no rig found" rather than
  /// implying one is attached.
  RigState get rig => _rig;

  RigMode _mode = RigMode.reference;
  Scenario _scenario = scenarios.first;
  Timer? _tick;
  final _rnd = Random(7);
  RigSnapshot _snapshot = RigSnapshot(
    mode: RigMode.reference,
    links: const {},
    rates: const {},
    at: DateTime.fromMillisecondsSinceEpoch(0),
  );

  /// Paths the operator has opened with an injection module, independent of the scenario. On the
  /// rig this is a relay in an inline module; here it is the same state the relay would put the
  /// link in, and it only means anything under the simulated rig.
  final _cuts = <int>{};

  /// Live, this is the module's own answer; simulated, it is the state we put it in. Never the
  /// state we asked for: a write that went out is not a relay that opened.
  bool isCut(int path) => switch (_mode) {
        RigMode.live => _rig.path(path)?.faulted ?? false,
        _ => _cuts.contains(path),
      };

  /// True where the module was answering and has stopped. A stale reading is not a reading.
  bool isStale(int path) => _mode == RigMode.live && _rig.isStale(path);

  /// True where there is something on the other end of this module to talk to.
  bool canCut(int path) => switch (_mode) {
        RigMode.simulated => true,
        RigMode.live => _rig.path(path) != null,
        RigMode.reference => false,
      };

  /// The A-to-B cross-link is an option, off by default: the module in it is not confirmed on the
  /// rig, and the pair of front-to-centre runs is the part of the topology that is settled.
  bool _crossLink = false;

  bool get crossLink => _crossLink;

  void setCrossLink(bool on) {
    if (_crossLink == on) return;
    _crossLink = on;
    if (_mode == RigMode.simulated) _recompute();
    notifyListeners();
  }

  /// The trunks in play, which is every one of them except the cross-link when it is switched off.
  List<Trunk> get trunks =>
      tsnTrunks.where((t) => t.path != 3 || _crossLink).toList(growable: false);

  Future<void> toggleCut(int path) async {
    if (_mode == RigMode.live) {
      final now = _rig.path(path)?.faulted ?? false;
      await _ble.setPathFault(path, !now);
      // Nothing is set locally on purpose. The screen changes when the module says it changed.
      return;
    }
    _cuts.contains(path) ? _cuts.remove(path) : _cuts.add(path);
    if (_mode == RigMode.simulated) _recompute();
    notifyListeners();
  }

  RigMode get mode => _mode;
  Scenario get scenario => _scenario;
  RigSnapshot get snapshot => _snapshot;

  void setMode(RigMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _tick?.cancel();
    switch (mode) {
      case RigMode.simulated:
        _recompute();
        _tick = Timer.periodic(const Duration(milliseconds: 900), (_) => _recompute());
      case RigMode.live:
        _ble.start();
        _recompute();
        // The report carries its own timestamp, so the only reason to tick is to let a link go
        // stale on screen without waiting for the next notification that may never come.
        _tick = Timer.periodic(const Duration(seconds: 1), (_) => _recompute());
      case RigMode.reference:
        _snapshot = RigSnapshot(mode: mode, links: const {}, rates: const {}, at: DateTime.now());
    }
    notifyListeners();
  }

  /// Cycles reference to demo to live, which is the order they are worth trying in.
  void nextMode() => setMode(switch (_mode) {
        RigMode.reference => RigMode.simulated,
        RigMode.simulated => RigMode.live,
        RigMode.live => RigMode.reference,
      });

  void setScenario(Scenario s) {
    _scenario = s;
    if (_mode == RigMode.simulated) _recompute();
    notifyListeners();
  }

  /// Nominal load per key, in Mb/s. These are plausible sensor loads, not sheet values --
  /// which is why they only ever appear under the SIMULATED stamp.
  static const _nominal = <String, double>{
    '0-1': 640,
    '0-2': 640,
    '1-1': 4200,
    '1-2': 720,
    '1-4': 40,
    '2-1': 120,
    '2-2': 40,
    '2-3': 640,
    '2-4': 640,
    'CAM 1': 1800,
    'CAM 2': 1800,
    'CAM 3': 1800,
    'CAM 4': 1800,
    'CAM 5': 1800,
    'lan0': 300,
    'lan1': 300,
    'lan2': 4200,
    'lan3': 700,
    'path1': 2600,
    'path2': 2600,
    'path3': 1400,
    'trunk': 4200,
  };

  void _recompute() {
    if (_mode == RigMode.live) {
      _recomputeLive();
      return;
    }
    final links = <String, LinkState>{};
    final rates = <String, double>{};
    for (final entry in _nominal.entries) {
      final key = entry.key;
      final port = portById(key);
      if (port != null && !port.used) {
        links[key] = LinkState.unknown;
        continue;
      }
      final cutPath = key.startsWith('path') ? int.tryParse(key.substring(4)) : null;
      if (cutPath != null && _cuts.contains(cutPath)) {
        links[key] = LinkState.down;
        rates[key] = 0;
        continue;
      }
      if (_scenario.down.contains(key)) {
        links[key] = LinkState.down;
        rates[key] = 0;
        continue;
      }
      final degraded = _scenario.degraded.contains(key);
      links[key] = degraded ? LinkState.degraded : LinkState.up;
      final jitter = 1 + (_rnd.nextDouble() - 0.5) * 0.06;
      rates[key] = entry.value * jitter * (degraded ? 0.22 : 1);
    }
    // Port 1-3 is labelled 미사용 on the sheet; it never carries a state.
    links['1-3'] = LinkState.unknown;
    _snapshot = RigSnapshot(mode: _mode, links: links, rates: rates, at: DateTime.now());
    notifyListeners();
  }

  /// Live state covers exactly what the rig reports: the three inter-switch paths. The ACU ports
  /// come off the design sheets and nothing on the rig measures them, so they stay unknown rather
  /// than being coloured in by association.
  void _recomputeLive() {
    final links = <String, LinkState>{};
    for (var p = 1; p <= 3; p++) {
      final report = _rig.path(p);
      links['path$p'] = report == null
          ? LinkState.unknown
          : (report.faulted ? LinkState.down : LinkState.up);
    }
    final trunkUp = links['path1'] == LinkState.up || links['path2'] == LinkState.up;
    links['trunk'] = _rig.paths.isEmpty
        ? LinkState.unknown
        : (trunkUp ? LinkState.up : LinkState.down);
    _snapshot = RigSnapshot(mode: _mode, links: links, rates: const {}, at: DateTime.now());
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ble.dispose();
    super.dispose();
  }
}

final rigProvider = ChangeNotifierProvider<RigController>((ref) {
  final c = RigController();
  ref.onDispose(c.dispose);
  return c;
});

/// The node the inspector is showing, or null for the overview.
final selectedNodeProvider = StateProvider<String?>((ref) => null);

/// The ACU_IT port the inspector is showing.
final selectedPortProvider = StateProvider<String?>((ref) => null);
