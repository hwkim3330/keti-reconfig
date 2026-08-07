import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../core/constants.dart';
import '../core/js_scripts.dart';
import '../providers/keti_link_provider.dart';
import '../providers/viewer_service_provider.dart';
import '../services/keti_link_service.dart';

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
  bool _leftVisible = true;
  bool _rightVisible = true;

  /// A scenario is just the fault state each path should end up in. Kept as data rather than
  /// as a sequence of taps so the console can say what it asked for and, separately, what the
  /// modules reported back.
  static const _scenarios = <_Scenario>[
    _Scenario('normal', 'All paths normal', 'Baseline', {1: false, 2: false}),
    _Scenario('path1', 'Path 1 link down', 'Single path fault', {1: true, 2: false}),
    _Scenario('path2', 'Path 2 link down', 'Single path fault', {1: false, 2: true}),
    _Scenario('both', 'Both paths down', 'Compound fault', {1: true, 2: true}),
  ];

  Future<void> _runScenario(_Scenario scenario) async {
    setState(() => _scenario = scenario.id);
    final service = ref.read(ketiLinkServiceProvider);
    for (final entry in scenario.faults.entries) {
      await service.setPathFault(entry.key, entry.value);
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
          if (delta >= 0) _rates[port.name] = delta * 8 / seconds / 1000.0;
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
    _updateRates(state.switchSnapshot);
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
            src: 'lib/assets/roii_reconfig.glb',
            alt: 'KETI reconfigurable vehicle',
            disablePan: true,
            disableTap: true,
            cameraControls: true,
            autoRotate: false,
            // model-viewer swings a hand cursor across the model to invite a drag. On a fixed
            // console it just looks like the vehicle is drifting.
            interactionPrompt: InteractionPrompt.none,
            cameraOrbit: '45deg 68deg 105%',
            cameraTarget: 'auto 8m auto',
            relatedJs: modelViewerScript,
            onWebViewCreated: (controller) {
              ref.read(viewerServiceProvider).setController(controller);
              _waitForJsAndInitialize();
            },
          ),
          Positioned(left: 14, right: 14, top: 10, child: _Header(state: state)),
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
              ),
            ),
          if (_rightVisible)
            Positioned(
              right: 14,
              top: 76,
              bottom: 14,
              width: 336,
              child: _SwitchPanel(state: state, rates: _rates),
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
  const _Header({required this.state});

  final KetiState state;

  @override
  Widget build(BuildContext context) {
    final snapshot = state.switchSnapshot;
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
          for (final device in KetiDevice.values) ...[
            _LinkPill(
              label: device.label,
              connected: state.connected.contains(device),
              fresh: switch (device) {
                KetiDevice.switchController => _fresh(snapshot?.receivedAt),
                KetiDevice.path1 => _fresh(state.pathSnapshots[1]?.receivedAt),
                KetiDevice.path2 => _fresh(state.pathSnapshots[2]?.receivedAt),
              },
            ),
            const SizedBox(width: 6),
          ],
          const Spacer(),
          if (state.scanning)
            const Text('scanning...',
                style: TextStyle(fontSize: 11, color: Color(0xFF7A8699))),
        ],
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

class _Scenario {
  const _Scenario(this.id, this.title, this.subtitle, this.faults);

  final String id;
  final String title;
  final String subtitle;
  final Map<int, bool> faults;
}

class _ScenarioRail extends ConsumerWidget {
  const _ScenarioRail({
    required this.state,
    required this.selected,
    required this.onSelect,
  });

  final KetiState state;
  final String selected;
  final Future<void> Function(_Scenario) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = KetiDevice.values
        .where((d) => d != KetiDevice.switchController)
        .every((d) => state.connected.contains(d));

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
          // Separate from the scenario buttons on purpose: one is what was asked for, the
          // other is what the hardware says happened, and a console that shows only the first
          // proves nothing.
          for (final path in [1, 2])
            _PathStatusLine(
              path: path,
              snapshot: state.pathSnapshots[path],
              connected: state.connected
                  .contains(path == 1 ? KetiDevice.path1 : KetiDevice.path2),
            ),
          const Spacer(),
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
        ],
      ),
    );
  }
}

class _SwitchPanel extends ConsumerWidget {
  const _SwitchPanel({required this.state, required this.rates});

  final KetiState state;
  final Map<String, double> rates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = state.switchSnapshot;
    final connected = state.connected.contains(KetiDevice.switchController);
    final fresh = _fresh(snapshot?.receivedAt);

    return _Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            snapshot?.platform.isNotEmpty == true ? snapshot!.platform : 'TSN switch',
            style: _kPanelTitle,
          ),
          const SizedBox(height: 6),
          if (!connected)
            const _Note('No link to the switch controller -- nothing measured')
          else if (snapshot == null)
            const _Note('Connected, waiting for the first snapshot')
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
              child: ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: snapshot.ports.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, thickness: 1, color: Color(0xFFF0F2F6)),
                itemBuilder: (_, i) => _PortRow(
                  port: snapshot.ports[i],
                  kbps: rates[snapshot.ports[i].name],
                  stale: !fresh,
                  onSetEnabled: (enabled) => ref
                      .read(ketiLinkServiceProvider)
                      .setPortEnabled(snapshot.ports[i].name, enabled),
                ),
              ),
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
    required this.stale,
    required this.onSetEnabled,
  });

  final SwitchPort port;
  final double? kbps;
  final bool stale;
  final void Function(bool enabled) onSetEnabled;

  @override
  Widget build(BuildContext context) {
    final faulty = port.inErrors + port.outErrors + port.inDiscards + port.outDiscards > 0;
    // The controller reaches the switch through this port. Disabling it would strand the
    // controller with no way back, so the control is shown and disabled rather than hidden --
    // an absent button invites someone to wonder where it went.
    final protected = port.name == '1';
    final accent = stale || !port.up ? const Color(0xFF9AA3B2) : const Color(0xFF0F766E);

    return Padding(
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
          const SizedBox(height: 7),
          _Bar(kbps: kbps ?? 0, muted: stale || !port.up),
          const SizedBox(height: 7),
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
    );
  }

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// A log scale, because idle management traffic and a loaded port are orders of magnitude
/// apart and a linear bar would show the quiet ports as nothing at all.
class _Bar extends StatelessWidget {
  const _Bar({required this.kbps, this.muted = false});

  final double kbps;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final fraction = kbps <= 0
        ? 0.0
        : ((kbps.clamp(0.1, 100000) / 0.1) / 1000000).clamp(0.0, 1.0);
    final scaled = kbps <= 0 ? 0.0 : (0.12 + 0.88 * (fraction == 0 ? 0 : _log10(kbps + 1) / 5));
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: scaled.clamp(0.0, 1.0),
        minHeight: 3,
        backgroundColor: const Color(0xFFEEF1F5),
        valueColor: AlwaysStoppedAnimation(
            muted ? const Color(0xFFD3D9E2) : const Color(0xFF2563EB)),
      ),
    );
  }

  static double _log10(double v) {
    var result = 0.0;
    var x = v;
    while (x >= 10) {
      x /= 10;
      result += 1;
    }
    return result + (x - 1) / 9;
  }
}
