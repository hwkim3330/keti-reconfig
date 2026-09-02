import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/reference.dart';

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
  Scenario('tcu', 'TCU_M link down', 'Port 2-2 lost. Telematics off the ACU_IT side; ACU_NO still reaches TCU-M on its own 1G links.',
      down: {'2-2'}),
];

class RigController extends ChangeNotifier {
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

  RigMode get mode => _mode;
  Scenario get scenario => _scenario;
  RigSnapshot get snapshot => _snapshot;

  void setMode(RigMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _tick?.cancel();
    if (mode == RigMode.simulated) {
      _recompute();
      _tick = Timer.periodic(const Duration(milliseconds: 900), (_) => _recompute());
    } else {
      _snapshot = RigSnapshot(mode: mode, links: const {}, rates: const {}, at: DateTime.now());
    }
    notifyListeners();
  }

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
  };

  void _recompute() {
    final links = <String, LinkState>{};
    final rates = <String, double>{};
    for (final entry in _nominal.entries) {
      final key = entry.key;
      final port = portById(key);
      if (port != null && !port.used) {
        links[key] = LinkState.unknown;
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

  @override
  void dispose() {
    _tick?.cancel();
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
