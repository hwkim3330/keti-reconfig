import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../core/constants.dart';
import '../core/js_scripts.dart';
import '../providers/keti_link_provider.dart';
import '../providers/traffic_gen_provider.dart';
import '../providers/viewer_service_provider.dart';
import '../services/keti_link_service.dart';
import 'traffic_gen_screen.dart';

/// The console: switch port state on one side, the two fault-injection paths on the other.
///
/// Every number on this screen is either measured or explicitly marked as not measured. The
/// previous rig showed a green header and minutes-old counters after its gateway had gone
/// silent, because it watched the connection rather than the data.
class SwitchConsoleScreen extends ConsumerStatefulWidget {
  const SwitchConsoleScreen({super.key});

  @override
  ConsumerState<SwitchConsoleScreen> createState() => _SwitchConsoleScreenState();
}

class _SwitchConsoleScreenState extends ConsumerState<SwitchConsoleScreen> {
  Timer? _tick;

  /// Throughput needs two readings, so the previous snapshot is kept to subtract from.
  SwitchSnapshot? _previous;
  final _rates = <String, double>{};

  /// Built once and reused. The freshness tick rebuilds this screen every second, and letting
  /// that rebuild the viewer made the model visibly drift.
  Widget? _viewer;

  /// The shell is held mostly transparent so the boards inside stay visible. The demo is about
  /// what is wired inside the vehicle, and an opaque body hides exactly that.
  double _shellOpacity = 0.15;
  bool _labelsVisible = true;

  /// What the model is currently showing as faulted, so the alert is only pushed on a change.
  /// Re-sending it every frame would restart the flash animation continuously.
  final _shownFaults = <int>{};

  String _scenario = 'normal';

  /// A short rolling history per port, for the sparklines. Kept here rather than in the
  /// service because it is a view concern: the service reports what is true now.
  final _history = <String, List<double>>{};
  static const _historyLength = 40;

  /// What happened, and when. A demo is a sequence of events and the console was showing only
  /// the latest state -- which cannot answer "did that fault actually apply, and when".
  final _events = <_Event>[];
  final _lastPathFault = <int, bool>{};
  bool? _lastSwitchLive;

  void _log(String text, {bool warn = false}) {
    _events.insert(0, _Event(text, DateTime.now(), warn));
    if (_events.length > 40) _events.removeLast();
  }
  bool _leftVisible = true;

  /// The right panel is an inspector: it shows the switch, or one port of it. Depth is a push
  /// and a back, not a popup -- a modal over a live console hides the very state being
  /// demonstrated, and a 12-port switch with per-port settings needs somewhere to put them
  /// that does not grow another window.
  String? _selectedPort;

  void _selectPort(String? name) => setState(() => _selectedPort = name);
  bool _rightVisible = true;

  /// The inspector widens rather than only scrolling. Per-port TSN configuration is long --
  /// a gate schedule alone is taller than the panel -- and reading it through a narrow slit
  /// is worse than giving it room. The model stays visible either way.
  bool _rightWide = false;

  /// Which switch the inspector is showing. With one switch this never changes and the console
  /// shows no selector for it -- a single-switch rig should not be made to navigate.
  KetiDevice? _activeSwitch;
  bool _showQuietPorts = false;

  /// A scenario is just the fault state each path should end up in. Kept as data rather than
  /// as a sequence of taps so the console can say what it asked for and, separately, what the
  /// modules reported back.
  static const _scenarios = <_Scenario>[
    // The RECON modes, as far as one switch can show them. Each is a fault and the schedule
    // that answers it: the point of the project is that a link going down changes the gate
    // schedules, and a scenario that only flips a relay tells half the story.
    _Scenario('normal', 'Mode 0 - normal', 'All paths up', {1: false, 2: false},
        schedule: 'tc7', schedulePort: '1'),
    _Scenario('path1', 'Mode 1 - path 1 down', 'Reroute, tighter gates', {1: true, 2: false},
        schedule: 'strict', schedulePort: '1'),
    _Scenario('path2', 'Mode 2 - path 2 down', 'Reroute, fast cycle', {1: false, 2: true},
        schedule: 'fast', schedulePort: '1'),
    // "Both down" dropped: with both ring links cut there is no path left for FRER
    // to recover over, so it only shows a dead link, not the seamless story.
    // A switch-side link failure, a different layer from a relay cut on a path module. The
    // switch dying outright is deliberately not a scenario: the console would lose the data it
    // reports with, so that is a state to display well, not a button.
    _Scenario('switchPort', 'Switch port 1 down', 'Switch-side link', {},
        switchPort: false, switchPortName: '1'),
    _Scenario('switchPortUp', 'Switch port 1 up', 'Switch-side link', {},
        switchPort: true, switchPortName: '1'),
  ];

  Future<void> _runScenario(_Scenario scenario) async {
    setState(() => _scenario = scenario.id);
    final service = ref.read(ketiLinkServiceProvider);
    _log('Sequence: ${scenario.title}');
    for (final entry in scenario.faults.entries) {
      await service.setPathFault(entry.key, entry.value);
    }
    final target = _activeSwitch ?? KetiDevice.switch1;
    if (scenario.switchPort != null) {
      await service.setPortEnabled(target, scenario.switchPortName, scenario.switchPort!);
    }
    if (scenario.schedule != null) {
      await service.setSchedule(target, scenario.schedulePort, scenario.schedule!);
    }
  }

  @override
  void initState() {
    super.initState();
    // Staleness is a function of elapsed time, not of incoming data: without a repaint the
    // "last update" age would freeze at whatever it was when the updates stopped.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// The viewer's JavaScript is not ready the moment the WebView is created, and calling into
  /// it early silently does nothing -- hence polling for readiness rather than a fixed delay.
  Future<void> _waitForJsAndInitialize() async {
    final service = ref.read(viewerServiceProvider);
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted) return;
      if (await service.isJsReady()) break;
    }
    await service.setVehicleShellOpacity(_shellOpacity);
    await service.initializeLabelHotspots();
    await service.toggleHotspots(_labelsVisible);
  }

  /// Watches for the transitions worth recording. Derived from reported state rather than
  /// from the commands sent, so the log says what happened and not what was asked for.
  void _recordEvents(KetiState state) {
    for (final path in [1, 2]) {
      final snapshot = state.pathSnapshots[path];
      if (snapshot == null) continue;
      final was = _lastPathFault[path];
      if (was != snapshot.faulted) {
        _lastPathFault[path] = snapshot.faulted;
        if (was != null) {
          _log('Path $path ${snapshot.faulted ? "cut" : "restored"}',
              warn: snapshot.faulted);
        }
      }
    }
    final live = state.switches.values.any((s) => _fresh(s.receivedAt));
    if (_lastSwitchLive != live) {
      if (_lastSwitchLive != null) {
        _log(live ? 'Switch link restored' : 'Switch link lost', warn: !live);
      }
      _lastSwitchLive = live;
    }
  }

  /// Mirrors the two path modules onto the model: the route a fault sits on flashes, and
  /// clears when the relay goes back. The model already carries Path1Route and Path2Route
  /// materials, so this shows the physical thing rather than a symbol next to it.
  void _syncModelFaults(KetiState state) {
    final service = ref.read(viewerServiceProvider);
    for (final path in [1, 2]) {
      final snapshot = state.pathSnapshots[path];
      final connected =
          state.connected.contains(path == 1 ? KetiDevice.path1 : KetiDevice.path2);
      // With no live link there is nothing to assert about that path, so the model says
      // nothing rather than holding the last thing it was told.
      final faulted = connected && _fresh(snapshot?.receivedAt) && (snapshot?.faulted ?? false);
      final key = 'Path${path}Route';
      if (faulted && !_shownFaults.contains(path)) {
        _shownFaults.add(path);
        final config = errorHotspotConfigs[key];
        if (config != null) service.showFaultAlert(key, 2, config);
        service.setPathLabelFault(path, true);
      } else if (!faulted && _shownFaults.contains(path)) {
        _shownFaults.remove(path);
        service.hideFaultAlert(key);
        service.setPathLabelFault(path, false);
      }
    }
  }

  void _updateRates(SwitchSnapshot? snapshot) {
    if (snapshot == null) return;
    final previous = _previous;
    if (previous != null && previous.sequence != snapshot.sequence) {
      final seconds =
          snapshot.receivedAt.difference(previous.receivedAt).inMilliseconds / 1000.0;
      if (seconds > 0.2) {
        for (final port in snapshot.ports) {
          final before = previous.ports.where((p) => p.name == port.name).firstOrNull;
          if (before == null) continue;
          final delta = (port.inOctets + port.outOctets) -
              (before.inOctets + before.outOctets);
          // Counters reset when the switch reboots; a negative delta is not a rate.
          if (delta >= 0) {
            final rate = delta * 8 / seconds / 1000.0;
            _rates[port.name] = rate;
            final series = _history.putIfAbsent(port.name, () => <double>[]);
            series.add(rate);
            if (series.length > _historyLength) series.removeAt(0);
          }
        }
      }
    }
    if (previous == null || previous.sequence != snapshot.sequence) {
      _previous = snapshot;
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(ketiStateProvider);
    final state = async.valueOrNull ?? const KetiState();
    final present = state.presentSwitches;
    final active = present.contains(_activeSwitch)
        ? _activeSwitch!
        : (present.isNotEmpty ? present.first : KetiDevice.switch1);
    final snapshot = state.switches[active];
    _updateRates(snapshot);
    _recordEvents(state);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncModelFaults(state);
    });

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFFF2F4F7)),
          _viewer ??= ModelViewer(
            backgroundColor: const Color(0xFFF2F4F7),
            id: 'car',
            src: 'lib/assets/roii_reconfig_recon.glb',
            alt: 'KETI reconfigurable vehicle',
            disablePan: true,
            disableTap: true,
            cameraControls: true,
            autoRotate: false,
            // model-viewer swings a hand cursor across the model to invite a drag. On a fixed
            // console it just looks like the vehicle is drifting.
            interactionPrompt: InteractionPrompt.none,
            // Aim lower and pull in a little so the TSN boards (floor of the
            // vehicle) sit centred rather than the cabin.
            cameraOrbit: '40deg 70deg 92%',
            cameraTarget: 'auto 4.5m auto',
            relatedJs: modelViewerScript,
            onWebViewCreated: (controller) {
              ref.read(viewerServiceProvider).setController(controller);
              _waitForJsAndInitialize();
            },
          ),
          Positioned(
            left: 14,
            right: 14,
            top: 10,
            child: _Header(state: state, present: present),
          ),
          if (_leftVisible)
            Positioned(
              left: 14,
              top: 76,
              bottom: 14,
              width: 268,
              child: _ScenarioRail(
                state: state,
                selected: _scenario,
                onSelect: _runScenario,
                events: _events,
              ),
            ),
          if (_rightVisible)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              right: 14,
              top: 76,
              bottom: 14,
              width: _rightWide ? 620 : 336,
              child: _SwitchPanel(
                state: state,
                active: active,
                present: present,
                onSelectSwitch: (device) => setState(() {
                  _activeSwitch = device;
                  _selectedPort = null;
                }),
                rates: _rates,
                history: _history,
                selectedPort: _selectedPort,
                onSelectPort: _selectPort,
                wide: _rightWide,
                onToggleWide: () => setState(() => _rightWide = !_rightWide),
                showQuiet: _showQuietPorts,
                onToggleQuiet: () => setState(() => _showQuietPorts = !_showQuietPorts),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Center(
              child: _ShellSlider(
              opacity: _shellOpacity,
              labelsVisible: _labelsVisible,
              onChanged: (value) {
                setState(() => _shellOpacity = value);
                ref.read(viewerServiceProvider).setVehicleShellOpacity(value);
              },
              onToggleLabels: () {
                setState(() => _labelsVisible = !_labelsVisible);
                ref.read(viewerServiceProvider).toggleHotspots(_labelsVisible);
              },
              leftVisible: _leftVisible,
              rightVisible: _rightVisible,
              onToggleLeft: () => setState(() => _leftVisible = !_leftVisible),
              onToggleRight: () => setState(() => _rightVisible = !_rightVisible),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool _fresh(DateTime? at) =>
    at != null && DateTime.now().difference(at) < KetiLinkService.staleAfter;

String _age(DateTime? at) {
  if (at == null) return 'never';
  final seconds = DateTime.now().difference(at).inSeconds;
  return seconds <= 1 ? 'now' : '${seconds}s ago';
}

// One scale, used everywhere. Three weights and five sizes competing across two panels is
// what made the console feel busy rather than dense.
const _kPanelTitle = TextStyle(
    fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: Color(0xFF111827));
const _kSectionTitle = TextStyle(
    fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3, color: Color(0xFF9AA3B2));
const _kBody = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF374151));
const _kMuted = TextStyle(fontSize: 11, color: Color(0xFF9AA3B2));

class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x0F000000)),
        boxShadow: const [
          BoxShadow(color: Color(0x0D000000), blurRadius: 28, offset: Offset(0, 10)),
        ],
      ),
      child: child,
    );
  }
}

/// Body transparency, so the boards inside can be seen. Left adjustable rather than fixed:
/// the shell has to come back for a photograph of the vehicle itself.
class _ShellSlider extends StatelessWidget {
  const _ShellSlider({
    required this.opacity,
    required this.labelsVisible,
    required this.onChanged,
    required this.onToggleLabels,
    required this.leftVisible,
    required this.rightVisible,
    required this.onToggleLeft,
    required this.onToggleRight,
  });

  final double opacity;
  final bool labelsVisible;
  final void Function(double) onChanged;
  final VoidCallback onToggleLabels;
  final bool leftVisible;
  final bool rightVisible;
  final VoidCallback onToggleLeft;
  final VoidCallback onToggleRight;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Shell', style: _kSectionTitle),
          SizedBox(
            width: 128,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: const Color(0xFF2563EB),
                inactiveTrackColor: const Color(0xFFE6E9EF),
                thumbColor: Colors.white,
              ),
              child: Slider(value: opacity, onChanged: onChanged, min: 0, max: 1),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text('${(opacity * 100).round()}%',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: Color(0xFF6B7280))),
          ),
          const SizedBox(width: 10),
          const SizedBox(width: 6),
          _Toggle(label: 'Labels', on: labelsVisible, onTap: onToggleLabels),
          const SizedBox(width: 6),
          _Toggle(label: 'Sequences', on: leftVisible, onTap: onToggleLeft),
          const SizedBox(width: 6),
          _Toggle(label: 'Switch', on: rightVisible, onTap: onToggleRight),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // Fixed width: labels that change length reflow the row, and a tap aimed at one
        // control then lands on its neighbour.
        width: 88,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFEDF2FD) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: on ? const Color(0xFF2563EB) : const Color(0xFF9AA3B2))),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.present});

  final KetiState state;
  final List<KetiDevice> present;

  @override
  Widget build(BuildContext context) {
    // Only devices that have actually shown up. Listing three switches on a one-switch bench
    // would report two permanent failures that are not failures.
    final shown = [
      ...(present.isEmpty ? [KetiDevice.switch1] : present),
      KetiDevice.path1,
      KetiDevice.path2,
    ];
    return _Glass(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          Image.asset('lib/assets/keti_logo.png', height: 26),
          const SizedBox(width: 12),
          const Text(
            'Reconfig Console',
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2,
                color: Color(0xFF111827)),
          ),
          const SizedBox(width: 16),
          for (final device in shown) ...[
            _LinkPill(
              label: shown.length <= 3 && device.isSwitch ? 'Switch' : device.label,
              connected: state.connected.contains(device),
              fresh: switch (device) {
                KetiDevice.path1 => _fresh(state.pathSnapshots[1]?.receivedAt),
                KetiDevice.path2 => _fresh(state.pathSnapshots[2]?.receivedAt),
                _ => _fresh(state.switches[device]?.receivedAt),
              },
            ),
            const SizedBox(width: 6),
          ],
          const Spacer(),
          if (state.scanning)
            const Text('scanning...',
                style: TextStyle(fontSize: 11, color: Color(0xFF7A8699))),
          const SizedBox(width: 10),
          _TrafficButton(),
        ],
      ),
    );
  }
}

/// Opens the traffic generator console. It drives a separate IP node (the Pi
/// running pi-trafgen) over WiFi, not one of the BLE switches, so it lives behind
/// its own screen rather than in this panel.
class _TrafficButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF4A90D9),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TrafficGenScreen()),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.speed_rounded, size: 16, color: Colors.white),
              SizedBox(width: 6),
              Text('Traffic',
                  style: TextStyle(
                      color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Connected and fresh are different things, and the difference is the whole point: a GATT
/// link stays up when the peer stops talking.
class _LinkPill extends StatelessWidget {
  const _LinkPill({required this.label, required this.connected, required this.fresh});

  final String label;
  final bool connected;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    // A dot plus the name. The state word was repeated three times across the header and said
    // less than the colour of the dot already does.
    final (background, foreground) = switch ((connected, fresh)) {
      (true, true) => (const Color(0xFFECF7F2), const Color(0xFF0F766E)),
      (true, false) => (const Color(0xFFFDF4E6), const Color(0xFFB45309)),
      _ => (const Color(0xFFF3F4F7), const Color(0xFF9AA3B2)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(7)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: foreground, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: foreground)),
        ],
      ),
    );
  }
}

class _Event {
  const _Event(this.text, this.at, this.warn);

  final String text;
  final DateTime at;
  final bool warn;
}

class _Scenario {
  const _Scenario(this.id, this.title, this.subtitle, this.faults,
      {this.switchPort, this.switchPortName = '1', this.schedule, this.schedulePort = '1'});

  final String id;
  final String title;
  final String subtitle;
  final Map<int, bool> faults;

  /// Null for path-only scenarios. Set to drive one of the switch's own ports -- never the
  /// controller's uplink, which the firmware refuses anyway.
  final bool? switchPort;
  final String switchPortName;

  /// The gate schedule this mode puts on the switch, if any. Named rather than spelled out:
  /// the controller owns the entries.
  final String? schedule;
  final String schedulePort;
}

class _ScenarioRail extends ConsumerWidget {
  const _ScenarioRail({
    required this.state,
    required this.selected,
    required this.onSelect,
    required this.events,
  });

  final KetiState state;
  final String selected;
  final Future<void> Function(_Scenario) onSelect;
  final List<_Event> events;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = [KetiDevice.path1, KetiDevice.path2].every(state.connected.contains);
    // The demo's BLE link (to Pi1 / KETI-TRAFGEN). Pi1 bridges flood + the D10s.
    final tg = ref.watch(trafficGenProvider);
    final piUp = tg.link == TgLink.online;

    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Sequences', style: _kPanelTitle),
          const SizedBox(height: 14),
          for (final scenario in _SwitchConsoleScreenState._scenarios) ...[
            _ScenarioCard(
              scenario: scenario,
              selected: scenario.id == selected,
              enabled: live,
              onTap: () => onSelect(scenario),
            ),
            const SizedBox(height: 2),
          ],
          const SizedBox(height: 18),
          const Text('Modules', style: _kSectionTitle),
          const SizedBox(height: 8),
          // The three Pis of the demo. Pi1 (sender) also drives the two D10
          // switches over JSON-RPC, so it doubles as the switch controller.
          // All three are reached through Pi1's BLE bridge; per-Pi BLE status is
          // refined once each Pi advertises its own peripheral.
          const _ModuleLine(
            name: 'Video Pi',
            connected: false,
            fresh: false,
            detail: 'HD stream',
          ),
          _ModuleLine(
            name: 'Sender Pi',
            connected: piUp,
            fresh: piUp,
            detail: tg.running ? 'flood ${tg.last.mbps.round()} Mbps' : '',
          ),
          _ModuleLine(
            name: 'Receiver Pi',
            connected: piUp,
            fresh: piUp,
            detail: 'kiosk',
          ),
          // Paths kept alongside the Pis, same row layout so the status column
          // lines up. Status-only — fault injection is driven from Sequences.
          for (final path in [1, 2])
            _ModuleLine(
              name: 'Path $path',
              connected: state.connected
                  .contains(path == 1 ? KetiDevice.path1 : KetiDevice.path2),
              fresh: _fresh(state.pathSnapshots[path]?.receivedAt),
              detail: (state.pathSnapshots[path]?.faulted ?? false) ? 'Fault' : 'Normal',
            ),
          const SizedBox(height: 18),
          const Text('Activity', style: _kSectionTitle),
          const SizedBox(height: 8),
          Expanded(
            child: events.isEmpty
                ? const Text('Nothing yet', style: _kMuted)
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: events.length,
                    itemBuilder: (_, i) => _EventRow(event: events[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ModuleLine extends StatelessWidget {
  const _ModuleLine({
    required this.name,
    required this.connected,
    required this.fresh,
    required this.detail,
  });

  final String name;
  final bool connected;
  final bool fresh;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final live = connected && fresh;
    final colour = !live ? const Color(0xFF9AA3B2) : const Color(0xFF0F766E);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(name,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const Spacer(),
          Text(
            !connected ? 'no link' : (!fresh ? 'silent' : detail),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colour),
          ),
          const SizedBox(width: 62),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final _Event event;

  @override
  Widget build(BuildContext context) {
    final at = event.at;
    final stamp = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stamp,
              style: const TextStyle(
                  fontSize: 10.5,
                  fontFeatures: [FontFeature.tabularFigures()],
                  color: Color(0xFFAAB2BF))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(event.text,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: event.warn ? const Color(0xFFB91C1C) : const Color(0xFF4B5563))),
          ),
        ],
      ),
    );
  }
}

class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({
    required this.scenario,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final _Scenario scenario;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final faulting = scenario.faults.values.any((f) => f);
    final accent = faulting ? const Color(0xFFDC2626) : const Color(0xFF0F766E);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        decoration: BoxDecoration(
          // Selection is a fill, not a border. Outlining every card at rest made the rail
          // read as a grid of buttons rather than a list with one thing chosen.
          color: selected ? const Color(0xFFF1F5FB) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(faulting ? Icons.link_off_rounded : Icons.check_rounded,
                size: 16,
                color: !enabled
                    ? const Color(0xFFC3C9D4)
                    : (selected ? accent : const Color(0xFFB4BCC9))),
            const SizedBox(width: 10),
            Expanded(
              child: Text(scenario.title,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: enabled ? const Color(0xFF1F2937) : const Color(0xFFC3C9D4))),
            ),
          ],
        ),
      ),
    );
  }
}

class _PathStatusLine extends StatelessWidget {
  const _PathStatusLine({
    required this.path,
    required this.snapshot,
    required this.connected,
  });

  final int path;
  final PathSnapshot? snapshot;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final fresh = _fresh(snapshot?.receivedAt);
    final live = connected && fresh;
    final faulted = snapshot?.faulted ?? false;
    final colour = !live
        ? const Color(0xFF9AA5B5)
        : (faulted ? const Color(0xFFDC2626) : const Color(0xFF0F766E));
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text('Path $path',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const Spacer(),
          Text(
            !connected
                ? 'no link'
                : (!fresh
                    ? 'silent ${_age(snapshot?.receivedAt)}'
                    : (faulted ? 'Fault' : 'Normal')),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colour),
          ),
          // Modules are status-only now: path fault-injection is driven from the
          // Sequences list, not per-module Cut/Restore buttons.
        ],
      ),
    );
  }
}

class _SwitchPanel extends ConsumerWidget {
  const _SwitchPanel({
    required this.state,
    required this.active,
    required this.present,
    required this.onSelectSwitch,
    required this.rates,
    required this.history,
    required this.selectedPort,
    required this.onSelectPort,
    required this.wide,
    required this.onToggleWide,
    required this.showQuiet,
    required this.onToggleQuiet,
  });

  final KetiState state;
  final KetiDevice active;
  final List<KetiDevice> present;
  final void Function(KetiDevice) onSelectSwitch;
  final Map<String, double> rates;
  final Map<String, List<double>> history;
  final String? selectedPort;
  final void Function(String?) onSelectPort;
  final bool wide;
  final VoidCallback onToggleWide;
  final bool showQuiet;
  final VoidCallback onToggleQuiet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = state.switches[active];
    final connected = state.connected.contains(active);
    final firstSeen = state.connectedAt[active];
    final fresh = _fresh(snapshot?.receivedAt);

    final selected = selectedPort == null
        ? null
        : snapshot?.ports.where((p) => p.name == selectedPort).firstOrNull;
    // Cross-faded rather than swapped: the inspector and the port list occupy the same place,
    // and an instant switch reads as a redraw rather than as going somewhere.
    if (selected != null && snapshot != null) {
      return _Glass(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _PortInspector(
          key: ValueKey(selected.name),
          wide: wide,
          onToggleWide: onToggleWide,
          port: selected,
          kbps: rates[selected.name],
          history: history[selected.name] ?? const [],
          protected: selected.name == snapshot.protectedPort,
          stale: !fresh,
          tas: state.tas[active]?[selected.name],
          eth: state.eth[active]?[selected.name],
          onSetSchedule: (preset) => ref
              .read(ketiLinkServiceProvider)
              .setSchedule(active, selected.name, preset),
          onBack: () => onSelectPort(null),
          onSetEnabled: (enabled) => ref
              .read(ketiLinkServiceProvider)
              .setPortEnabled(active, selected.name, enabled),
          ),
        ),
      );
    }

    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  snapshot?.platform.isNotEmpty == true ? snapshot!.platform : 'TSN switch',
                  style: _kPanelTitle,
                ),
              ),
              _WidenButton(wide: wide, onTap: onToggleWide),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Named for what they do. "Reset" would cover anything from clearing a schedule
              // to wiping the device, and this only does the first.
              _TextAction(
                label: 'Clear gating',
                enabled: connected && fresh && snapshot != null,
                onTap: () => ref.read(ketiLinkServiceProvider).clearGating(active),
              ),
              const SizedBox(width: 14),
              _TextAction(
                label: 'Save to flash',
                enabled: connected && fresh && snapshot != null,
                onTap: () => ref.read(ketiLinkServiceProvider).saveConfig(active),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // TSN shapers with in-panel tabs: each feature shows the parameter
          // that matters, not just on/off. Relayed to the two D10s by Pi1.
          const Text('Shapers', style: _kSectionTitle),
          const SizedBox(height: 8),
          const _ShaperTabs(),
          if (present.length > 1) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                for (final device in present) ...[
                  GestureDetector(
                    onTap: () => onSelectSwitch(device),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: device == active
                            ? const Color(0xFFEDF2FD)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(device.label,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: device == active
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFF9AA3B2))),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ],
            ),
          ],
          const SizedBox(height: 6),
          if (!connected)
            const _Note('No link to the switch controller -- nothing measured')
          else if (snapshot == null)
            _Note(_fresh(firstSeen)
                ? 'Connected, waiting for the first snapshot'
                : 'The controller is reachable but its switch is not answering')
          else if (!fresh)
            _Note('Controller silent since ${_age(snapshot.receivedAt)} -- '
                'the values below are from snapshot #${snapshot.sequence}, not now')
          else if (!snapshot.catalogOk)
            _Note('The switch reports YANG catalog ${snapshot.catalog}, which is not the one '
                'the controller\'s SID table was built from. No port data is trustworthy.')
          else
            _Note('Ethernet ${snapshot.ethernetLinkUp ? "up" : "down"}  ·  '
                '${snapshot.ports.length} ports  ·  snapshot #${snapshot.sequence}  ·  '
                '${_age(snapshot.receivedAt)}'),
          const SizedBox(height: 10),
          if (snapshot != null && snapshot.catalogOk)
            Expanded(
              child: Builder(builder: (context) {
                // Ports with no link and no history are folded into one line. On a twelve-port
                // switch with one thing plugged in, eleven rows saying "no link" push the port
                // that is actually carrying traffic off the screen.
                final quiet = snapshot.ports
                    .where((p) => !p.up && (history[p.name] ?? const []).every((v) => v == 0))
                    .toList();
                final active =
                    snapshot.ports.where((p) => !quiet.contains(p)).toList();
                final shown = showQuiet ? snapshot.ports : active;
                return ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: shown.length + (quiet.isEmpty ? 0 : 1),
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, thickness: 1, color: Color(0xFFF0F2F6)),
                itemBuilder: (_, i) {
                  if (i == shown.length) {
                    return GestureDetector(
                      onTap: onToggleQuiet,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Row(
                          children: [
                            Text(
                              showQuiet
                                  ? 'Hide the ${quiet.length} ports with no link'
                                  : '${quiet.length} more ports, no link',
                              style: _kMuted,
                            ),
                            const Spacer(),
                            Icon(
                              showQuiet
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_down_rounded,
                              size: 18,
                              color: const Color(0xFF9AA3B2),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  return _PortRow(
                  port: shown[i],
                  kbps: rates[shown[i].name],
                  history: history[shown[i].name] ?? const [],
                  stale: !fresh,
                  protected: shown[i].name == snapshot.protectedPort,
                  onOpen: () => onSelectPort(shown[i].name),
                  onSetEnabled: (enabled) => ref
                      .read(ketiLinkServiceProvider)
                      .setPortEnabled(this.active, shown[i].name, enabled),
                );
                },
              );
              }),
            )
          else
            const Spacer(),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(fontSize: 11.5, height: 1.35, color: Color(0xFF7A8699)));
  }
}

class _PortRow extends StatelessWidget {
  const _PortRow({
    required this.port,
    required this.kbps,
    required this.history,
    required this.stale,
    required this.protected,
    required this.onSetEnabled,
    required this.onOpen,
  });

  final SwitchPort port;
  final double? kbps;
  final List<double> history;
  final bool stale;

  /// The controller's own uplink. Disabling it would strand the controller with no way back,
  /// so the control is shown and disabled rather than hidden -- an absent button invites
  /// someone to wonder where it went.
  final bool protected;
  final void Function(bool enabled) onSetEnabled;

  /// Opens the port's own view. The row is the target, not a chevron: a whole row is a bigger
  /// thing to hit than an icon, and there is nothing else the row does.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final faulty = port.inErrors + port.outErrors + port.inDiscards + port.outDiscards > 0;
    // Which port that is comes from the controller, not from a constant here.
    final accent = stale || !port.up ? const Color(0xFF9AA3B2) : const Color(0xFF0F766E);

    // A twelve-port switch is mostly idle ports, and giving every one of them a chart and two
    // lines of counters buries the ports that are actually carrying something. Down ports with
    // no history collapse to a single line -- still listed, still operable, just not shouting.
    if (!port.up && history.every((v) => v == 0)) {
      return GestureDetector(
        onTap: onOpen,
        behavior: HitTestBehavior.opaque,
        child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                  color: Color(0xFFD3D9E2), shape: BoxShape.circle),
            ),
            const SizedBox(width: 9),
            Text(port.name.length > 2 ? port.name : 'Port ${port.name}',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF9AA3B2))),
            const Spacer(),
            GestureDetector(
              onTap: (stale || protected) ? null : () => onSetEnabled(true),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Text(protected ? 'uplink' : 'Enable',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: (stale || protected)
                            ? const Color(0xFFC3C9D4)
                            : const Color(0xFF2563EB))),
              ),
            ),
          ],
        ),
      ),
      );
    }

    return GestureDetector(
      onTap: onOpen,
      behavior: HitTestBehavior.opaque,
      child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(port.name.length > 2 ? port.name : 'Port ${port.name}',
                  style: _kBody),
              const SizedBox(width: 7),
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(bottom: 2),
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              const Spacer(),
              // Tabular figures: without them the rate jitters sideways as digits change,
              // which reads as the number being unstable rather than the layout.
              Text(
                kbps == null ? '--' : kbps!.toStringAsFixed(1),
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: Color(0xFF111827)),
              ),
              const SizedBox(width: 3),
              const Padding(
                padding: EdgeInsets.only(bottom: 1),
                child: Text('kbps', style: _kMuted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _Spark(values: history, muted: stale || !port.up),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_bytes(port.inOctets)} in   ${_bytes(port.outOctets)} out',
                  style: _kMuted,
                ),
              ),
              GestureDetector(
                onTap: (stale || protected) ? null : () => onSetEnabled(!port.up),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  child: Text(
                    protected ? 'uplink' : (port.up ? 'Disable' : 'Enable'),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: (stale || protected)
                          ? const Color(0xFFC3C9D4)
                          : const Color(0xFF2563EB),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (faulty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${port.inErrors + port.outErrors} errors   '
                '${port.inDiscards + port.outDiscards} discards',
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFB45309)),
              ),
            ),
        ],
      ),
      ),
    );
  }

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// A short history of the port's throughput.
///
/// Scaled against this port's own maximum rather than a fixed ceiling: idle management traffic
/// and a loaded port are orders of magnitude apart, and a shared scale would flatten every
/// quiet port to a line on the floor. The number above it is the absolute value, so the shape
/// here is about change over time and nothing else.
/// One port, in full. The place per-port configuration lands as it arrives -- the RECON work
/// this console feeds into swaps per-port gate schedules, and those need a home that is not a
/// dialog stacked over the live view.
class _PortInspector extends StatelessWidget {
  const _PortInspector({
    super.key,
    required this.wide,
    required this.onToggleWide,
    required this.port,
    required this.kbps,
    required this.history,
    required this.protected,
    required this.stale,
    required this.tas,
    required this.eth,
    required this.onBack,
    required this.onSetEnabled,
    required this.onSetSchedule,
  });

  final bool wide;
  final VoidCallback onToggleWide;
  final SwitchPort port;
  final double? kbps;
  final List<double> history;
  final bool protected;
  final bool stale;
  final TasSnapshot? tas;
  final EthSnapshot? eth;
  final VoidCallback onBack;
  final void Function(bool) onSetEnabled;
  final void Function(String preset) onSetSchedule;

  @override
  Widget build(BuildContext context) {
    // Scrollable: with a schedule drawn out the inspector is taller than the panel, and a
    // clipped timeline is worse than one that scrolls.
    return SingleChildScrollView(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: onBack,
                behavior: HitTestBehavior.opaque,
                child: const Row(
                  children: [
                    Icon(Icons.chevron_left_rounded, size: 20, color: Color(0xFF2563EB)),
                    Text('Switch',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2563EB))),
                  ],
                ),
              ),
            ),
            _WidenButton(wide: wide, onTap: onToggleWide),
          ],
        ),
        const SizedBox(height: 10),
        Text(port.name.length > 2 ? port.name : 'Port ${port.name}', style: _kPanelTitle),
        const SizedBox(height: 4),
        Text(
          '${port.up ? "Link up" : "Link down"}'
          '${eth != null && eth!.speedMbps > 0 ? "  ·  ${eth!.speedMbps} Mbps" : ""}'
          '${protected ? "  ·  controller uplink" : ""}',
          style: _kMuted,
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(kbps == null ? '--' : kbps!.toStringAsFixed(1),
                style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.6,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: Color(0xFF111827))),
            const SizedBox(width: 5),
            const Text('kbps', style: _kMuted),
          ],
        ),
        const SizedBox(height: 8),
        _Spark(values: history, muted: stale || !port.up),
        const SizedBox(height: 18),
        const Text('Counters', style: _kSectionTitle),
        const SizedBox(height: 8),
        _Stat('In', '${port.inOctets} B', '${port.inUnicast} unicast'),
        _Stat('Out', '${port.outOctets} B', '${port.outUnicast} unicast'),
        _Stat('Errors', '${port.inErrors} in', '${port.outErrors} out'),
        _Stat('Discards', '${port.inDiscards} in', '${port.outDiscards} out'),
        // Frames the MAC threw away. A console that only shows a link as up or down
        // cannot show a link that is up and bad, which is the more interesting failure.
        if (eth != null && !eth!.healthy)
          _Stat('Bad frames', '${eth!.fcsErrors} FCS',
              '${eth!.oversize} over, ${eth!.undersize} under'),
        const SizedBox(height: 18),
        const Text('Configuration', style: _kSectionTitle),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
                child: Text('Administrative state',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF374151)))),
            GestureDetector(
              onTap: (stale || protected) ? null : () => onSetEnabled(!port.up),
              behavior: HitTestBehavior.opaque,
              child: Text(
                protected ? 'protected' : (port.up ? 'Disable' : 'Enable'),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: (stale || protected)
                        ? const Color(0xFFC3C9D4)
                        : const Color(0xFF2563EB)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Text('Time-aware shaper', style: _kSectionTitle),
        const SizedBox(height: 8),
        if (tas == null)
          const Text('Not reported for this port', style: _kMuted)
        else ...[
          _Stat('Gate control', tas!.enabled ? 'Enabled' : 'Disabled',
              tas!.cycleNs == 0 ? 'no cycle set' : '${tas!.cycleNs / 1000} us cycle'),
          _Stat('Gates open', _gateList(tas!.gateStates), ''),
          if (tas!.windows.isNotEmpty) ...[
            const SizedBox(height: 12),
            _GateTimeline(windows: tas!.windows),
          ],
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final preset in _kPresets)
              GestureDetector(
                onTap: stale ? null : () => onSetSchedule(preset.id),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE3E8EF)),
                  ),
                  child: Text(preset.label,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: stale
                              ? const Color(0xFFC3C9D4)
                              : const Color(0xFF2563EB))),
                ),
              ),
          ],
        ),
      ],
      ),
    );
  }
}

/// oper-gate-states is a bitmask, one bit per traffic class. 255 means every gate is open,
/// which is what a port with no schedule looks like -- worth saying in words rather than
/// leaving the reader to decode 0xFF.
String _gateList(int mask) {
  if (mask == 255) return 'all (no schedule)';
  final open = <String>[];
  for (var tc = 0; tc < 8; ++tc) {
    if ((mask >> tc) & 1 == 1) open.add('TC$tc');
  }
  return open.isEmpty ? 'none' : open.join(' ');
}

/// One cycle of the gate control list, drawn as a row per traffic class.
///
/// This is the picture the whole demo is about: RECON swaps these schedules when a link fails,
/// and a table of numbers does not show that happening. Widths are proportional to each
/// window's duration, so the shape is the schedule.
class _GateTimeline extends StatelessWidget {
  const _GateTimeline({required this.windows});

  final List<GateWindow> windows;

  @override
  Widget build(BuildContext context) {
    final total = windows.fold<int>(0, (sum, w) => sum + w.nanoseconds);
    if (total <= 0) return const SizedBox.shrink();

    // Only the classes that are ever gated. Drawing eight rows when a schedule touches two
    // buries the two that matter.
    final used = <int>[];
    for (var tc = 7; tc >= 0; --tc) {
      if (windows.any((w) => w.isOpen(tc)) && windows.any((w) => !w.isOpen(tc))) used.add(tc);
    }
    if (used.isEmpty) {
      for (var tc = 7; tc >= 0; --tc) {
        if (windows.any((w) => w.isOpen(tc))) used.add(tc);
      }
    }
    // Cap the rows. A schedule that gates seven classes identically draws seven identical
    // bars, which is height without information -- the distinct shapes are what matter.
    final seen = <String>{};
    final distinct = <int>[];
    for (final tc in used) {
      final shape = windows.map((w) => w.isOpen(tc) ? '1' : '0').join();
      if (seen.add(shape)) distinct.add(tc);
    }
    final rows = distinct.take(4).toList();
    final hidden = used.length - rows.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final tc in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Text('TC$tc',
                      style: const TextStyle(
                          fontSize: 10.5, fontWeight: FontWeight.w600,
                          color: Color(0xFF9AA3B2))),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Row(
                      children: [
                        for (final w in windows)
                          Expanded(
                            flex: w.nanoseconds,
                            child: Container(
                              height: 13,
                              margin: const EdgeInsets.only(right: 1),
                              color: w.isOpen(tc)
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFFE9EDF3),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(left: 30, bottom: 3),
            child: Text('+$hidden more classes follow the same windows', style: _kMuted),
          ),
        const SizedBox(height: 3),
        Row(
          children: [
            const SizedBox(width: 30),
            Expanded(
              child: Row(
                children: [
                  for (final w in windows)
                    Expanded(
                      flex: w.nanoseconds,
                      child: Text('${w.nanoseconds ~/ 1000}us',
                          style: const TextStyle(fontSize: 9.5, color: Color(0xFFAAB2BF))),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The schedules the controller knows. Named here only for the label -- the controller holds
/// the actual windows, because it is the side that verified the catalog.
class _Preset {
  const _Preset(this.id, this.label);

  final String id;
  final String label;
}

const _kPresets = [
  _Preset('tc7', 'TC7 1 ms'),
  _Preset('strict', 'Strict 1 ms'),
  _Preset('fast', 'TC7 200 us'),
  _Preset('off', 'No gating'),
];

/// In-panel tabs for the three TSN shapers. Each tab shows the parameter that
/// matters, then Enable / Disable. Commands go over BLE to Pi1, which relays
/// them to the two D10 switches by JSON-RPC.
class _ShaperTabs extends ConsumerStatefulWidget {
  const _ShaperTabs();
  @override
  ConsumerState<_ShaperTabs> createState() => _ShaperTabsState();
}

class _ShaperTabsState extends ConsumerState<_ShaperTabs> {
  int _tab = 0; // 0 CBS, 1 TAS, 2 FRER
  final _sel = <int, String>{0: '250', 1: '1000', 2: 'vector'};

  static const _tabs = ['CBS', 'TAS', 'FRER'];
  static const _tabSub = [
    '802.1Qav · reserve the video queue',
    '802.1Qbv · time-aware gates',
    '802.1CB · seamless redundancy',
  ];
  static const _params = [
    [['100', 'Mbps'], ['250', 'Mbps'], ['500', 'Mbps']],
    [['250', 'µs'], ['500', 'µs'], ['1000', 'µs']],
    [['vector', ''], ['match', '']],
  ];
  static const _onCmd = ['cbs', 'tas', 'frer'];
  static const _param = ['cbs:mbps:', 'tas:cycle:', 'frer:alg:'];

  void _send(String c) => ref.read(trafficGenProvider.notifier).sendControl(c);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // tab strip
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F2F6),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              for (var i = 0; i < _tabs.length; i++)
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _tab = i),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: _tab == i ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                        boxShadow: _tab == i
                            ? [const BoxShadow(color: Color(0x14000000), blurRadius: 4)]
                            : null,
                      ),
                      child: Text(_tabs[i],
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _tab == i
                                  ? const Color(0xFF2563EB)
                                  : const Color(0xFF9AA3B2))),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(_tabSub[_tab], style: const TextStyle(fontSize: 11, color: Color(0xFF9AA3B2))),
        const SizedBox(height: 8),
        // parameter chips
        Wrap(
          spacing: 6,
          children: [
            for (final p in _params[_tab])
              GestureDetector(
                onTap: () {
                  setState(() => _sel[_tab] = p[0]);
                  _send('${_param[_tab]}${p[0]}');
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: _sel[_tab] == p[0] ? const Color(0xFFEDF2FD) : const Color(0xFFF5F6F9),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                        color: _sel[_tab] == p[0] ? const Color(0xFF2563EB) : const Color(0xFFE2E6EE)),
                  ),
                  child: Text('${p[0]}${p[1].isEmpty ? '' : ' ${p[1]}'}',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: _sel[_tab] == p[0]
                              ? const Color(0xFF2563EB)
                              : const Color(0xFF6B7280))),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _TextAction(label: 'Enable', enabled: true, onTap: () => _send('${_onCmd[_tab]}:on')),
            const SizedBox(width: 16),
            _TextAction(label: 'Disable', enabled: true, onTap: () => _send('${_onCmd[_tab]}:off')),
          ],
        ),
      ],
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.enabled, required this.onTap});

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(label,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: enabled ? const Color(0xFF2563EB) : const Color(0xFFC3C9D4))),
      ),
    );
  }
}

class _WidenButton extends StatelessWidget {
  const _WidenButton({required this.wide, required this.onTap});

  final bool wide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
        child: Icon(
          wide ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded,
          size: 16,
          color: const Color(0xFF9AA3B2),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.a, this.b);

  final String label;
  final String a;
  final String b;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          SizedBox(width: 78, child: Text(label, style: _kMuted)),
          Expanded(
            child: Text('$a   $b',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: Color(0xFF374151))),
          ),
        ],
      ),
    );
  }
}

class _Spark extends StatelessWidget {
  const _Spark({required this.values, required this.muted});

  final List<double> values;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: CustomPaint(
        painter: _SparkPainter(
          values: values,
          colour: muted ? const Color(0xFFD3D9E2) : const Color(0xFF2563EB),
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.values, required this.colour});

  final List<double> values;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = Paint()
      ..color = const Color(0xFFEEF1F5)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5),
        baseline);
    if (values.length < 2) return;

    var peak = 0.0;
    for (final v in values) {
      if (v > peak) peak = v;
    }
    // A flat line at zero is the honest picture of an idle port; scaling it up to fill the box
    // would invent activity that is not there.
    if (peak <= 0) return;

    final step = size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; ++i) {
      final x = i * step;
      final y = size.height - (values[i] / peak) * (size.height - 2) - 1;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = colour.withValues(alpha: 0.10));
    canvas.drawPath(
        path,
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values.length != values.length || old.colour != colour;
}
