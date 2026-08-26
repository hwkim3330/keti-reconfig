import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../core/js_scripts.dart';
import '../models/fault_data.dart';
import '../providers/fault_provider.dart';
import '../providers/hardware_reconfig_provider.dart';
import '../providers/vehicle_position_provider.dart';
import '../services/hardware_reconfig_service.dart';
import '../services/vehicle_position_service.dart';
import '../providers/viewer_service_provider.dart';

class CarViewerScreen extends ConsumerStatefulWidget {
  const CarViewerScreen({super.key});

  @override
  ConsumerState<CarViewerScreen> createState() => _CarViewerScreenState();
}

class _CarViewerScreenState extends ConsumerState<CarViewerScreen> {
  var _labelsVisible = false;
  var _lastAlertSequence = -1;
  var _metricsVisible = true;
  var _pathPanelVisible = false;
  /// The evidence column is 318 px of mostly-static text. Hiding it is the cheapest way to
  /// give the vehicle and the path diagram room, and it is the panel an operator needs least
  /// while actually injecting a fault -- unlike the scenario rail, which is how you inject one.
  var _evidenceVisible = true;

  /// Tilt-to-orbit, off by default.
  ///
  /// Deliberately opt-in: a console whose camera drifts every time somebody picks the tablet
  /// up is worse than one that stays put, and while it is on the tilt owns the camera, so a
  /// finger drag would just be fought. One control, one owner.
  var _tiltEnabled = false;
  StreamSubscription<AccelerometerEvent>? _tiltSubscription;

  /// Low-passed gravity vector. Raw accelerometer output jitters by a degree or two at rest,
  /// which on a camera reads as a shake.
  double _gravityX = 0;
  double _gravityY = 0;
  DateTime _lastOrbitAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _toggleTilt() {
    setState(() => _tiltEnabled = !_tiltEnabled);
    if (!_tiltEnabled) {
      _tiltSubscription?.cancel();
      _tiltSubscription = null;
      ref.read(viewerServiceProvider).resetCameraOrbit();
      return;
    }
    _tiltSubscription = accelerometerEventStream().listen((event) {
      // Exponential smoothing, then clamp. The clamp matters as much as the smoothing: the
      // vehicle should never end up upside down or looking at its own back, so tilt moves the
      // camera within a window around the opening three-quarter view rather than mapping the
      // whole sphere.
      const alpha = 0.15;
      _gravityX = _gravityX + alpha * (event.x - _gravityX);
      _gravityY = _gravityY + alpha * (event.y - _gravityY);

      final now = DateTime.now();
      if (now.difference(_lastOrbitAt) < const Duration(milliseconds: 90)) return;
      _lastOrbitAt = now;

      // Landscape tablet: x is the long axis, y the short one. 9.8 is 1 g, so dividing by it
      // gives roughly the sine of the tilt.
      final theta = (45 + (_gravityX / 9.8) * 45).clamp(5.0, 85.0);
      final phi = (65 - (_gravityY / 9.8) * 25).clamp(45.0, 85.0);
      ref.read(viewerServiceProvider).setCameraOrbit(theta, phi);
    });
  }
  var _shellOpacity = 0.15;
  _ScenarioDef _selectedScenario = _ScenarioDef.values.first;

  /// Real measurements, replacing three hardcoded strings that looked like readings.
  ///
  /// `switchTime: '34ms'` and its neighbours were constants in the scenario table --
  /// nothing was ever timed. On a validation console that is the worst kind of UI: it
  /// survives being asked "what did you measure to get 34 ms?" only until someone asks.
  /// These two are timed off the controller's own state stream, the same evidence the soak
  /// script uses.
  DateTime? _commandSentAt;
  Map<String, String> _commandIntent = const {};
  Duration? _lastCommandRoundTrip;
  DateTime? _nodeLostAt;
  Duration? _lastHeal;
  bool _nodesHeldOnce = false;

  /// Starts the clock for the next relay confirmation. `intent` is the channel state the
  /// action is expected to produce; the clock stops when the controller reports it.
  void _armCommandTimer(Map<String, String> intent) {
    _commandSentAt = DateTime.now();
    _commandIntent = intent;
  }

  /// Called on every hardware snapshot. Times the two things worth timing, nothing else.
  void _observe(HardwareReconfigState hardware) {
    if (!hardware.connected) return;

    final sentAt = _commandSentAt;
    if (sentAt != null && _commandIntent.isNotEmpty) {
      final satisfied = _commandIntent.entries.every(
        (entry) => hardware.channels[entry.key] == entry.value,
      );
      if (satisfied) {
        _lastCommandRoundTrip = DateTime.now().difference(sentAt);
        _commandSentAt = null;
        _commandIntent = const {};
      }
    }

    // A node dropping and coming back is the self-heal. Timed end to end here rather than
    // quoting a number from the firmware's point of view.
    //
    // Two things must be true before a missing node counts as a loss, or the panel reports
    // its own startup as a self-heal. The service seeds both nodes offline, which looks
    // exactly like a real loss; and with no gateway link we have nobody to ask about the
    // nodes at all. So: only while connected, and only once we have actually held them.
    // Same guard as the controller's own watchdog -- you cannot lose what you never had.
    final nodes = hardware.pathNodes;
    if (!hardware.connected) {
      _nodeLostAt = null;
    } else if (nodes.isNotEmpty) {
      final anyLost = nodes.values.any((online) => !online);
      if (!anyLost) {
        _nodesHeldOnce = true;
        if (_nodeLostAt != null) {
          _lastHeal = DateTime.now().difference(_nodeLostAt!);
          _nodeLostAt = null;
        }
      } else if (_nodesHeldOnce && _nodeLostAt == null) {
        _nodeLostAt = DateTime.now();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(faultProvider));
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      ref.read(hardwareReconfigServiceProvider).recover();
    });
  }

  Future<void> _waitForJsAndInitialize() async {
    final service = ref.read(viewerServiceProvider);
    for (var i = 0; i < 24; i++) {
      await Future.delayed(const Duration(milliseconds: 180));
      if (!mounted) return;
      if (await service.isJsReady()) {
        await service.initializeLabelHotspots();
        await service.toggleHotspots(_labelsVisible);
        return;
      }
    }
    await service.initializeLabelHotspots();
    await service.toggleHotspots(_labelsVisible);
  }

  /// The channel state a scenario is expected to leave behind, used to time the relay
  /// confirmation. Scenarios that fan out over time (the sequence) are not timed.
  static const _scenarioIntent = <String, Map<String, String>>{
    'normal': {'tsn_front_a': 'NORMAL', 'tsn_front_b': 'NORMAL', 'tsn_rear': 'NORMAL'},
    'path1': {'tsn_front_a': 'FAULT'},
    'path2': {'tsn_front_b': 'FAULT'},
    'path3': {'tsn_rear': 'FAULT'},
    'dualFront': {'tsn_front_a': 'FAULT', 'tsn_front_b': 'FAULT'},
    'allPaths': {'tsn_front_a': 'FAULT', 'tsn_front_b': 'FAULT', 'tsn_rear': 'FAULT'},
  };

  @override
  void dispose() {
    _tiltSubscription?.cancel();
    super.dispose();
  }

  Future<void> _applyScenario(_ScenarioDef scenario) async {
    setState(() => _selectedScenario = scenario);
    final intent = _scenarioIntent[scenario.id];
    if (intent != null) _armCommandTimer(intent);
    ref.read(faultProvider.notifier).applyScenario(scenario.id);
    final hardware = ref.read(hardwareReconfigServiceProvider);
    if (scenario.id == 'normal' || scenario.id == 'recoveryAudit') {
      hardware.recover();
    } else if (scenario.id == 'path1') {
      hardware.setExclusivePathFault(1);
    } else if (scenario.id == 'path2') {
      hardware.setExclusivePathFault(2);
    } else if (scenario.id == 'path3') {
      hardware.setExclusivePathFault(3);
    } else if (scenario.id == 'dualFront') {
      hardware.setChannel('tsn_front_a', 'FAULT');
      hardware.setChannel('tsn_front_b', 'FAULT');
      hardware.setChannel('tsn_rear', 'NORMAL');
    } else if (scenario.id == 'allPaths') {
      hardware.setChannel('tsn_front_a', 'FAULT');
      hardware.setChannel('tsn_front_b', 'FAULT');
      hardware.setChannel('tsn_rear', 'FAULT');
    } else if (scenario.id == 'sequence') {
      for (final id in ['tsn_front_a', 'tsn_front_b', 'tsn_rear']) {
        hardware.recover();
        await Future<void>.delayed(const Duration(milliseconds: 450));
        hardware.setChannel(id, 'FAULT');
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
      hardware.recover();
    } else {
      hardware.setChannel(
        'tsn_front_a',
        scenario.id == 'switchA' ? 'FAULT' : 'NORMAL',
      );
      hardware.setChannel(
        'tsn_front_b',
        scenario.id == 'switchB' ? 'FAULT' : 'NORMAL',
      );
      hardware.setChannel(
        'tsn_rear',
        scenario.id == 'switchRear' ? 'FAULT' : 'NORMAL',
      );
    }
  }

  void _recover() {
    ref.read(faultProvider.notifier).clearAll();
    ref.read(hardwareReconfigServiceProvider).recover();
    ref.read(viewerServiceProvider).resetCameraOrbit();
    setState(() => _selectedScenario = _ScenarioDef.values.first);
  }

  void _toggleLabels() {
    setState(() => _labelsVisible = !_labelsVisible);
    ref.read(viewerServiceProvider).toggleHotspots(_labelsVisible);
  }

  /// Raises a banner when a path node's lower button calls out which path it is.
  /// Keyed on the controller's sequence so the same alert is shown once.
  void _showPathAlert(HardwareReconfigState hardware) {
    final event = hardware.event;
    if (!event.startsWith('path_alert_')) return;
    if (hardware.sequence == _lastAlertSequence) return;
    _lastAlertSequence = hardware.sequence;
    final path = event.substring('path_alert_'.length);
    // Buzz and chime so the alert lands even when nobody is looking at the
    // tablet. The 7-inch board has no buzzer, so the tablet carries the sound.
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('PATH $path is calling out from the bench'),
          backgroundColor: const Color(0xFF0F766E),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final faults = ref.watch(faultProvider).values.toList();
    final hardware =
        ref.watch(hardwareReconfigProvider).valueOrNull ??
        const HardwareReconfigState();
    final vehiclePosition =
        ref.watch(vehiclePositionProvider).valueOrNull ??
        const VehiclePosition(status: PositionStatus.idle);
    _observe(hardware);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _showPathAlert(hardware),
    );
    final mode = hardware.connected
        ? _ReconfigMode.fromHardware(hardware.mode, faults)
        : _ReconfigMode.fromScenario(_selectedScenario, faults);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFFF2F4F7)),
          ModelViewer(
            backgroundColor: const Color(0xFFF2F4F7),
            id: 'car',
            src: 'lib/assets/roii_reconfig_recon.glb',
            alt: 'PLEOS reconfigurable E/E architecture vehicle',
            interpolationDecay: 200,
            disablePan: true,
            disableTap: true,
            disableZoom: false,
            cameraControls: true,
            autoRotate: false,
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
            child: _TopBar(
              mode: mode,
              scenario: _selectedScenario,
              hardware: hardware,
            ),
          ),
          Positioned(
            left: 14,
            top: 78,
            bottom: 118,
            child: _ScenarioRail(
              selected: _selectedScenario,
              onSelected: _applyScenario,
            ),
          ),
          if (_evidenceVisible)
            Positioned(
              right: 14,
              top: 78,
              bottom: 118,
              child: _EvidencePanel(
                scenario: _selectedScenario,
                mode: mode,
                faults: faults,
                hardware: hardware,
                vehiclePosition: vehiclePosition,
              ),
            ),
          if (_pathPanelVisible)
            Positioned(
              left: 248,
              // Take the evidence column's room when it is hidden rather than leaving a gap.
              right: _evidenceVisible ? 348 : 14,
              bottom: 118,
              child: _ModeCard(
                mode: mode,
                scenario: _selectedScenario,
                hardware: hardware,
              ),
            ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 14,
            child: _BottomConsole(
              labelsVisible: _labelsVisible,
              metricsVisible: _metricsVisible,
              pathPanelVisible: _pathPanelVisible,
              evidenceVisible: _evidenceVisible,
              tiltEnabled: _tiltEnabled,
              shellOpacity: _shellOpacity,
              mode: mode,
              onToggleLabels: _toggleLabels,
              onToggleMetrics: () =>
                  setState(() => _metricsVisible = !_metricsVisible),
              onTogglePathPanel: () =>
                  setState(() => _pathPanelVisible = !_pathPanelVisible),
              onToggleEvidence: () =>
                  setState(() => _evidenceVisible = !_evidenceVisible),
              onToggleTilt: _toggleTilt,
              onShellOpacityChanged: (value) {
                setState(() => _shellOpacity = value);
                ref.read(viewerServiceProvider).setVehicleShellOpacity(value);
              },
              onRecover: _recover,
            ),
          ),
          if (_metricsVisible)
            Positioned(
              left: 248,
              right: 348,
              bottom: 72,
              child: _TimelinePanel(
                scenario: _selectedScenario,
                mode: mode,
                commandRoundTrip: _lastCommandRoundTrip,
                lastHeal: _lastHeal,
              ),
            ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.mode,
    required this.scenario,
    required this.hardware,
  });

  final _ReconfigMode mode;
  final _ScenarioDef scenario;
  final HardwareReconfigState hardware;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // The institute's own mark, not a stand-in glyph. Same source file as the
            // launcher icon and the 7-inch header, so one logo drives all three.
            Image.asset('lib/assets/keti_logo.png', height: 22),
            const SizedBox(width: 12),
            const Text(
              'KETI Reconfig Studio',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: Color(0xFF172033),
              ),
            ),
            const SizedBox(width: 14),
            _StatusPill(
              label: '7-inch gateway',
              value: hardware.connected
                  ? 'BLE control #${hardware.sequence}'
                  : 'Offline',
              color: hardware.connected
                  ? const Color(0xFF0F766E)
                  : const Color(0xFF64748B),
              activity: hardware.connected,
            ),
            const SizedBox(width: 8),
            _StatusPill(
              label: 'Inline injector',
              value: hardware.ioNodeConnected ? 'USB armed' : 'Safe bypass',
              color: hardware.ioNodeConnected
                  ? const Color(0xFF0F766E)
                  : const Color(0xFF64748B),
            ),
            const SizedBox(width: 8),
            _StatusPill(
              // Two nodes, because there are only two. Path 3's relay is driven from the
              // 7-inch's own GPIO, so it has no node to answer for it -- and cramming it in
              // here as `P3 LOCAL OK` mashed a control source and a state into one token
              // that read like neither. Path 3's health is in the evidence panel with the
              // other two links, where it belongs.
              label: 'Path nodes',
              value:
                  'P1 ${hardware.pathNodes['PLEOS-PATH1'] == true ? 'ACK' : '--'}'
                  '  ·  '
                  'P2 ${hardware.pathNodes['PLEOS-PATH2'] == true ? 'ACK' : '--'}',
              color: hardware.connected && hardware.pathNodes.isEmpty
                  ? const Color(0xFF0F766E)
                  : hardware.pathNodes.values
                            .where((online) => online)
                            .length ==
                        2
                  ? const Color(0xFF0F766E)
                  : const Color(0xFFD97706),
            ),
            const SizedBox(width: 8),
            _StatusPill(
              label: 'Scenario',
              value: scenario.title,
              color: scenario.color,
            ),
          ],
        ),
      ),
    );
  }
}

class _ScenarioRail extends StatelessWidget {
  const _ScenarioRail({required this.selected, required this.onSelected});

  final _ScenarioDef selected;
  final ValueChanged<_ScenarioDef> onSelected;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      width: 220,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Test Sequences',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: Color(0xFF172033),
            ),
          ),
          // The subtitle used to restate Inject/Isolate/Reconfigure/Recover here, which is
          // the app's whole purpose and needs no caption. Its two lines cost exactly the
          // room the tenth scenario needed to be on screen at all.
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              itemCount: _ScenarioDef.values.length,
              separatorBuilder: (_, __) => const SizedBox(height: 5),
              itemBuilder: (context, index) {
                final scenario = _ScenarioDef.values[index];
                final active = scenario == selected;
                return Material(
                  color: active
                      ? scenario.color.withValues(alpha: 0.12)
                      : const Color(0xFFFFFFFF).withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: () => onSelected(scenario),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      // Tight on purpose: nine scenarios have to fit the tablet's
                      // column without scrolling, or the last two are invisible in a demo.
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: active
                              ? scenario.color
                              : const Color(0xFFD0D5DD),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(scenario.icon, size: 19, color: scenario.color),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  scenario.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF172033),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  scenario.category,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EvidencePanel extends StatelessWidget {
  const _EvidencePanel({
    required this.scenario,
    required this.mode,
    required this.faults,
    required this.hardware,
    required this.vehiclePosition,
  });

  final _ScenarioDef scenario;
  final _ReconfigMode mode;
  final List<FaultData> faults;
  final HardwareReconfigState hardware;
  final VehiclePosition vehiclePosition;

  static const _linkNames = {
    'tsn_front_a': 'Path 1 (F-A to R)',
    'tsn_front_b': 'Path 2 (F-B to R)',
    'tsn_rear': 'Path 3 (F-A to F-B)',
  };

  /// Reads the three links out of the controller's own snapshot.
  ///
  /// This block used to print `scenario.metrics`, a fixed list of strings per scenario --
  /// so it said "Path 1 feedback FAULT" because Path 1 had been *selected*, not because
  /// the controller had reported anything. It happened to agree with the hardware most of
  /// the time, which is exactly what makes that kind of line dangerous on a validation
  /// panel: it agrees right up until the moment the answer matters.
  List<String> get _liveMetrics {
    if (!hardware.connected) {
      return const ['No gateway link -- nothing measured'];
    }
    final lines = <String>[];
    for (final entry in _linkNames.entries) {
      final health = hardware.channels[entry.key] ?? 'UNKNOWN';
      lines.add('${entry.value}: $health');
    }
    // Path 3 is the 7-inch board's own GPIO, so only two nodes can ACK. Saying so is
    // better than printing two reports for three paths and letting the reader assume.
    final p1 = hardware.pathNodes['PLEOS-PATH1'];
    final p2 = hardware.pathNodes['PLEOS-PATH2'];
    if (p1 != null || p2 != null) {
      lines.add(
        'Node feedback: P1 ${p1 == true ? 'ACK' : 'lost'}, '
        'P2 ${p2 == true ? 'ACK' : 'lost'} '
        '(Path 3 runs off the gateway, no node)',
      );
    }
    lines.add('Gateway snapshot #${hardware.sequence}');
    return lines;
  }

  List<String> get _positionLines {
    final position = vehiclePosition.position;
    if (!vehiclePosition.hasFix || position == null) {
      return [
        switch (vehiclePosition.status) {
          PositionStatus.denied => 'No fix -- location permission not granted',
          PositionStatus.serviceOff => 'No fix -- location is off on the tablet',
          PositionStatus.waiting => 'Waiting for a fix',
          PositionStatus.failed => 'No fix -- ${vehiclePosition.detail}',
          _ => 'No fix yet',
        },
      ];
    }
    final lines = [
      '${position.latitude.toStringAsFixed(6)}, '
          '${position.longitude.toStringAsFixed(6)}',
      'Accuracy ${position.accuracy.toStringAsFixed(1)} m'
          '${position.altitude != 0 ? ', altitude ${position.altitude.toStringAsFixed(0)} m' : ''}',
      'Speed ${(position.speed * 3.6).toStringAsFixed(1)} km/h',
    ];
    if (vehiclePosition.detail.isNotEmpty) {
      lines.add('Source: ${vehiclePosition.detail}');
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    return _Glass(
      width: 318,
      padding: const EdgeInsets.all(13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Evidence / Validation',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: Color(0xFF172033),
            ),
          ),
          const SizedBox(height: 8),
          _EvidenceBlock(
            title: 'Fault chain',
            lines: [scenario.cause, scenario.effect],
          ),
          _EvidenceBlock(
            title: 'Reconfiguration',
            lines: [
              // The action is what this scenario intends. The two lines under it are what
              // the gateway actually reports -- so with no link they say "not read"
              // rather than echoing the scenario table back as if it were a measurement.
              scenario.action,
              if (hardware.connected) ...[
                'Mode: ${mode.name}',
                'MRM: ${mode.isMrm ? 'engaged' : 'standby'}',
              ] else
                'Mode / MRM: not read -- no gateway link',
            ],
          ),
          _EvidenceBlock(title: 'Measured now', lines: _liveMetrics),
          // Its own block, deliberately. The rig runs fine with no fix, so a missing
          // position must never read as a network fault sitting among the link states.
          _EvidenceBlock(title: 'Vehicle position', lines: _positionLines),
          _EvidenceBlock(
            title: 'Report mapping',
            lines: scenario.reportMapping,
          ),
          const SizedBox(height: 6),
          const Text(
            'Active faults',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: Color(0xFF667085),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: faults.isEmpty
                ? const Center(
                    child: Text(
                      'No active fault\nNetwork baseline',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF667085),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: faults.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final fault = faults[index];
                      final color = fault.severity >= 2
                          ? const Color(0xFFDC2626)
                          : const Color(0xFFF59E0B);
                      return Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: color.withValues(alpha: 0.32),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _faultTargetLabel(fault.target),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: color,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              fault.faultType,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF344054),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

String _faultTargetLabel(String target) => switch (target) {
  'Path1Route' => 'Path 1 (F-A ↔ R)',
  'Path2Route' => 'Path 2 (F-B ↔ R)',
  'Path3Route' => 'Path 3 (F-A ↔ F-B)',
  'FrontSwitchA' => 'Front A Switch',
  'FrontSwitchB' => 'Front B Switch',
  'RearSwitch' => 'Rear Switch',
  _ => target,
};

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.mode,
    required this.scenario,
    required this.hardware,
  });

  final _ReconfigMode mode;
  final _ScenarioDef scenario;
  final HardwareReconfigState hardware;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: _Glass(
        opaque: true,
        width: 430,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'FRONT INLINE RECONFIGURATION',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                color: Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 8),
            Column(
              children: [
                _PathPair(
                  fromLabel: 'F-A',
                  espLabel: 'PATH 1 / ESP-AR',
                  toLabel: 'R',
                  armed: hardware.ioNodeConnected,
                ),
                const SizedBox(height: 4),
                _PathPair(
                  fromLabel: 'F-B',
                  espLabel: 'PATH 2 / ESP-BR',
                  toLabel: 'R',
                  armed: hardware.ioNodeConnected,
                ),
                const SizedBox(height: 4),
                _PathPair(
                  fromLabel: 'F-A',
                  espLabel: 'PATH 3 / 7-INCH ESP',
                  toLabel: 'F-B',
                  armed: hardware.ioNodeConnected,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(mode.icon, color: mode.color, size: 22),
                const SizedBox(width: 8),
                Text(
                  mode.name,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: mode.color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            _ModeLine(
              label: 'Localization',
              value: mode.localization,
              color: mode.color,
            ),
            _ModeLine(
              label: 'Fusion',
              value: scenario.fusion,
              color: mode.color,
            ),
            _ModeLine(
              label: 'Planning',
              value: mode.planning,
              color: mode.color,
            ),
            _ModeLine(label: 'Control', value: mode.control, color: mode.color),
          ],
        ),
      ),
    );
  }
}

class _PathNode extends StatelessWidget {
  const _PathNode({
    required this.label,
    required this.active,
    this.warning = false,
  });

  final String label;
  final bool active;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning
        ? const Color(0xFFD97706)
        : active
        ? const Color(0xFF0F766E)
        : const Color(0xFF64748B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }
}

class _PathPair extends StatelessWidget {
  const _PathPair({
    required this.fromLabel,
    required this.espLabel,
    required this.toLabel,
    required this.armed,
  });

  final String fromLabel;
  final String espLabel;
  final String toLabel;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _PathNode(label: fromLabel, active: true),
        const Expanded(child: Divider(height: 1)),
        _PathNode(label: espLabel, active: armed, warning: !armed),
        const Expanded(child: Divider(height: 1)),
        _PathNode(label: toLabel, active: true),
      ],
    );
  }
}

class _TimelinePanel extends StatelessWidget {
  const _TimelinePanel({
    required this.scenario,
    required this.mode,
    required this.commandRoundTrip,
    required this.lastHeal,
  });

  final _ScenarioDef scenario;
  final _ReconfigMode mode;
  final Duration? commandRoundTrip;
  final Duration? lastHeal;

  @override
  Widget build(BuildContext context) {
    // Two timed values and a plain statement of what the rig is doing. What used to be here
    // -- a six-step Inject..Recover chain with `active: true` hardcoded on every step, and
    // three metric chips reading from constants in the scenario table -- showed the same
    // thing whatever the hardware was doing.
    final roundTrip = commandRoundTrip;
    final heal = lastHeal;
    return _Glass(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Text(
              scenario.modeName,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: mode.color,
              ),
            ),
            const SizedBox(width: 14),
            // Not "command -> relay", which is what this used to claim. The clock stops when
            // the gateway echoes its own channel state, and at that instant the gateway has
            // not yet told the node anything -- it pushes to the nodes later, from loop().
            // The relay follows within a tick or two of that. Reading the real relay time
            // needs the node's `applied` over BLE, which today only rides the CBOR/serial
            // link, so it cannot be measured from here without a firmware change.
            _MetricChip(
              label: 'command → gateway',
              value: roundTrip == null
                  ? '--'
                  : '${roundTrip.inMilliseconds} ms',
              color: mode.color,
            ),
            const SizedBox(width: 6),
            _MetricChip(
              label: 'last self-heal',
              value: heal == null ? 'none' : '${heal.inSeconds} s',
              color: const Color(0xFF0F766E),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomConsole extends StatelessWidget {
  const _BottomConsole({
    required this.labelsVisible,
    required this.metricsVisible,
    required this.pathPanelVisible,
    required this.evidenceVisible,
    required this.tiltEnabled,
    required this.shellOpacity,
    required this.mode,
    required this.onToggleLabels,
    required this.onToggleMetrics,
    required this.onTogglePathPanel,
    required this.onToggleEvidence,
    required this.onToggleTilt,
    required this.onShellOpacityChanged,
    required this.onRecover,
  });

  final bool labelsVisible;
  final bool metricsVisible;
  final bool pathPanelVisible;
  final bool evidenceVisible;
  final bool tiltEnabled;
  final double shellOpacity;
  final _ReconfigMode mode;
  final VoidCallback onToggleLabels;
  final VoidCallback onToggleMetrics;
  final VoidCallback onTogglePathPanel;
  final VoidCallback onToggleEvidence;
  final VoidCallback onToggleTilt;
  final ValueChanged<double> onShellOpacityChanged;
  final VoidCallback onRecover;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: _Glass(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Wrap(
          spacing: 7,
          runSpacing: 7,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // One segmented group for the four layer toggles, then the shell slider, then a
            // gap and the single action. Six identical outlined buttons in a row read as a
            // pile; grouping by what they do reads as three things.
            //
            // The labels are also fixed now. They used to swap between `Show X` and `Hide X`,
            // so pressing one changed its own width and reflowed the whole row -- the same
            // button was somewhere else the next time you reached for it. State is shown by
            // fill instead, which is what a toggle is for.
            _LayerToggles(
              items: [
                _LayerToggle(
                  icon: Icons.label_rounded,
                  label: 'Labels',
                  active: labelsVisible,
                  onTap: onToggleLabels,
                ),
                _LayerToggle(
                  icon: Icons.timeline_rounded,
                  label: 'Metrics',
                  active: metricsVisible,
                  onTap: onToggleMetrics,
                ),
                _LayerToggle(
                  icon: Icons.hub_rounded,
                  label: 'Paths',
                  active: pathPanelVisible,
                  onTap: onTogglePathPanel,
                ),
                _LayerToggle(
                  icon: Icons.fact_check_rounded,
                  label: 'Evidence',
                  active: evidenceVisible,
                  onTap: onToggleEvidence,
                ),
                _LayerToggle(
                  icon: Icons.screen_rotation_rounded,
                  label: 'Tilt',
                  active: tiltEnabled,
                  onTap: onToggleTilt,
                ),
              ],
            ),
            _ShellOpacityControl(
              value: shellOpacity,
              onChanged: onShellOpacityChanged,
            ),
            // The only action in the row, and the only filled control, held apart from the
            // view toggles so it cannot be pressed by reflex while reaching for one.
            const SizedBox(width: 10),
            _ToolButton(
              icon: Icons.verified_user_rounded,
              label: mode.isMrm ? 'MRM validate' : 'Recover validate',
              active: mode.isFaulted,
              onTap: onRecover,
            ),
          ],
        ),
      ),
    );
  }
}

/// One layer toggle inside the segmented group.
class _LayerToggle {
  const _LayerToggle({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
}

/// The four view toggles as one control instead of four loose buttons.
///
/// A segmented group says "these are alternatives of the same kind" in a way a row of
/// identical outlined buttons cannot, and it gives the row a fixed width, so nothing moves
/// under the finger when a state changes.
class _LayerToggles extends StatelessWidget {
  const _LayerToggles({required this.items});

  final List<_LayerToggle> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD0D5DD)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i != 0)
              Container(width: 1, height: 22, color: const Color(0xFFE4E7EC)),
            _LayerToggleButton(item: items[i], first: i == 0, last: i == items.length - 1),
          ],
        ],
      ),
    );
  }
}

class _LayerToggleButton extends StatelessWidget {
  const _LayerToggleButton({
    required this.item,
    required this.first,
    required this.last,
  });

  final _LayerToggle item;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colour = item.active
        ? const Color(0xFF1677FF)
        : const Color(0xFF667085);
    final radius = BorderRadius.horizontal(
      left: Radius.circular(first ? 7 : 0),
      right: Radius.circular(last ? 7 : 0),
    );
    return Material(
      color: item.active ? const Color(0xFFEAF2FF) : Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: radius,
        child: Padding(
          // A fixed 96 px slot per segment: the labels differ in length, and letting them
          // size themselves is what made the row shuffle in the first place.
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SizedBox(
            width: 88,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(item.icon, color: colour, size: 15),
                const SizedBox(width: 6),
                Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: colour,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShellOpacityControl extends StatelessWidget {
  const _ShellOpacityControl({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 210,
      height: 36,
      padding: const EdgeInsets.only(left: 9, right: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD0D5DD)),
      ),
      child: Row(
        children: [
          const Icon(Icons.layers_rounded, size: 16, color: Color(0xFF344054)),
          const SizedBox(width: 5),
          Text(
            'Shell ${(value * 100).round()}%',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: Color(0xFF344054),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: value,
                min: 0,
                max: 1,
                divisions: 20,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EvidenceBlock extends StatelessWidget {
  const _EvidenceBlock({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: Color(0xFF667085),
            ),
          ),
          const SizedBox(height: 4),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '• ',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF667085),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF344054),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ModeLine extends StatelessWidget {
  const _ModeLine({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                color: Color(0xFF64748B),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w900,
              color: Color(0xFF64748B),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.value,
    required this.color,
    this.activity = false,
  });

  final String label;
  final String value;
  final Color color;
  final bool activity;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (activity) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.28),
                    blurRadius: 5,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            '$label: ',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: Color(0xFF64748B),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF1677FF) : const Color(0xFF344054);
    return Material(
      color: active ? const Color(0xFFEAF2FF) : Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? const Color(0xFF1677FF) : const Color(0xFFD0D5DD),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Glass extends StatelessWidget {
  const _Glass({
    required this.child,
    this.width,
    this.padding = const EdgeInsets.all(12),
    this.opaque = false,
  });

  final Widget child;
  final double? width;
  final EdgeInsetsGeometry padding;

  /// Fully opaque instead of the usual 94%. Panels that sit over the vehicle rather than
  /// beside it need this: with the 3D labels showing, translucency let the label text bleed
  /// through the panel and neither was readable.
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: padding,
      decoration: BoxDecoration(
        color: opaque
            ? const Color(0xFFFFFFFF)
            : const Color(0xFFFFFFFF).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD0D5DD)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _ScenarioDef {
  const _ScenarioDef({
    required this.id,
    required this.category,
    required this.title,
    required this.icon,
    required this.color,
    required this.cause,
    required this.effect,
    required this.action,
    required this.modeName,
    required this.fusion,
    required this.safetyGoal,
    required this.mrmPolicy,
    required this.reportMapping,
    required this.switchTime,
    required this.latency,
    required this.jitter,
  });

  final String id;
  final String category;
  final String title;
  final IconData icon;
  final Color color;
  final String cause;
  final String effect;
  final String action;
  final String modeName;
  final String fusion;
  final String safetyGoal;
  final String mrmPolicy;
  final List<String> reportMapping;
  final String switchTime;
  final String latency;
  final String jitter;

  static const values = [
    _ScenarioDef(
      id: 'normal',
      category: 'Baseline',
      title: 'All paths normal',
      icon: Icons.verified_rounded,
      color: Color(0xFF16A34A),
      cause: 'All three Ethernet paths are available.',
      effect: 'Front A, Front B and Rear links remain in NC pass-through.',
      action: 'Maintain nominal TSN/FRER routing and arm recovery validation.',
      modeName: 'Triple-path normal',
      fusion: 'Path A + Path B + Rear',
      safetyGoal: 'Full network availability',
      mrmPolicy: 'standby',
      reportMapping: ['3개 스위치 정상 경로 기준', 'NC pass-through 상태 검증'],
      switchTime: '0ms',
      latency: '1ms',
      jitter: '0.5ms',
    ),
    _ScenarioDef(
      id: 'path1',
      category: 'Path Fault',
      title: 'Path 1 Link Down',
      icon: Icons.cable_rounded,
      color: Color(0xFFF59E0B),
      cause: 'Front A to Rear Ethernet link is down via ESP-AR.',
      effect:
          'Path 1 (F-A ↔ R) is unavailable while Paths 2 and 3 remain healthy.',
      action:
          'Detect link loss, isolate Path 1 and retain traffic on redundant paths.',
      modeName: 'Path 1 isolated',
      fusion: 'Path 2 + Path 3 active',
      safetyGoal: 'Single-path fail-operational',
      mrmPolicy: 'standby',
      reportMapping: ['FRER Path 1 단독 고장 주입', '링크 검출 및 우회 검증'],
      switchTime: '34ms',
      latency: '1ms',
      jitter: '0.5ms',
    ),
    _ScenarioDef(
      id: 'path2',
      category: 'Path Fault',
      title: 'Path 2 Link Down',
      icon: Icons.cable_rounded,
      color: Color(0xFFF59E0B),
      cause: 'Front B to Rear Ethernet link is down via ESP-BR.',
      effect:
          'Path 2 (F-B ↔ R) is unavailable while Paths 1 and 3 remain healthy.',
      action:
          'Detect link loss, isolate Path 2 and retain traffic on redundant paths.',
      modeName: 'Path 2 isolated',
      fusion: 'Path 1 + Path 3 active',
      safetyGoal: 'Single-path fail-operational',
      mrmPolicy: 'standby',
      reportMapping: ['FRER Path 2 단독 고장 주입', '링크 검출 및 우회 검증'],
      switchTime: '35ms',
      latency: '1ms',
      jitter: '0.5ms',
    ),
    _ScenarioDef(
      id: 'path3',
      category: 'Path Fault',
      title: 'Path 3 Link Down',
      icon: Icons.cable_rounded,
      color: Color(0xFFF59E0B),
      cause: '7-inch ESP opens the Front A to Front B injection module.',
      effect:
          'Path 3 (F-A ↔ F-B) is unavailable while both rear routes remain healthy.',
      action:
          'Detect the cross-front link loss and retain traffic through Rear.',
      modeName: 'Path 3 isolated',
      fusion: 'Path 1 + Path 2 active',
      safetyGoal: 'Cross-path isolation',
      mrmPolicy: 'standby',
      reportMapping: ['7인치 ESP Path 3 단독 고장 주입', '후방 우회 경로 유지 검증'],
      switchTime: '37ms',
      latency: '1ms',
      jitter: '0.5ms',
    ),
    _ScenarioDef(
      id: 'switchA',
      category: 'Switch Fault',
      title: 'Front A Switch Fault',
      icon: Icons.hub_rounded,
      color: Color(0xFFDC2626),
      cause: 'Front A switch stops forwarding Ethernet traffic.',
      effect: 'Paths 1 and 3 are affected at the Front A endpoint.',
      action: 'Isolate Front A and reroute traffic through Front B and Rear.',
      modeName: 'Front A isolated',
      fusion: 'Front B ↔ Rear retained',
      safetyGoal: 'Switch fault containment',
      mrmPolicy: 'candidate',
      reportMapping: ['전방 A 스위치 단독 고장', '스위치 격리 및 우회 검증'],
      switchTime: 'measured',
      latency: 'measured',
      jitter: 'measured',
    ),
    _ScenarioDef(
      id: 'switchB',
      category: 'Switch Fault',
      title: 'Front B Switch Fault',
      icon: Icons.hub_rounded,
      color: Color(0xFFDC2626),
      cause: 'Front B switch stops forwarding Ethernet traffic.',
      effect: 'Paths 2 and 3 are affected at the Front B endpoint.',
      action: 'Isolate Front B and reroute traffic through Front A and Rear.',
      modeName: 'Front B isolated',
      fusion: 'Front A ↔ Rear retained',
      safetyGoal: 'Switch fault containment',
      mrmPolicy: 'candidate',
      reportMapping: ['전방 B 스위치 단독 고장', '스위치 격리 및 우회 검증'],
      switchTime: 'measured',
      latency: 'measured',
      jitter: 'measured',
    ),
    _ScenarioDef(
      id: 'switchRear',
      category: 'Switch Fault',
      title: 'Rear Switch Fault',
      icon: Icons.hub_rounded,
      color: Color(0xFFDC2626),
      cause: 'Rear switch stops forwarding Ethernet traffic.',
      effect: 'Paths 1 and 2 are affected at the Rear endpoint.',
      action: 'Isolate Rear and retain the Front A ↔ Front B path.',
      modeName: 'Rear switch isolated',
      fusion: 'Path 3 retained',
      safetyGoal: 'Switch fault containment',
      mrmPolicy: 'candidate',
      reportMapping: ['후방 스위치 단독 고장', 'Path 3 유지 및 MRM 조건 검증'],
      switchTime: 'measured',
      latency: 'measured',
      jitter: 'measured',
    ),
    _ScenarioDef(
      id: 'sequence',
      category: 'Automated Test',
      title: 'Path 1 → 2 → 3',
      icon: Icons.playlist_play_rounded,
      color: Color(0xFF1677FF),
      cause: 'Run each path fault independently in a fixed sequence.',
      effect:
          'Verifies command, feedback, isolation and recovery for all paths.',
      action: 'Inject each path for 0.9 seconds and recover between steps.',
      modeName: 'Sequence validation',
      fusion: 'P1 → recover → P2 → recover → P3 → recover',
      safetyGoal: 'Repeatable validation',
      mrmPolicy: 'not required',
      reportMapping: ['3개 경로 자동 시험 순서', '주입·검출·격리·복구 증적'],
      switchTime: 'Auto',
      latency: 'measured',
      jitter: 'measured',
    ),
    _ScenarioDef(
      id: 'dualFront',
      category: 'Compound Fault',
      title: 'Path 1 + 2 Link Down',
      icon: Icons.call_split_rounded,
      color: Color(0xFFD97706),
      cause: 'Both Front-to-Rear links are down simultaneously.',
      effect: 'Only the Front A-to-B path through the 7-inch ESP remains.',
      action: 'Validate constrained operation over Path 3 and arm MRM.',
      modeName: 'Single-path fallback',
      fusion: 'Path 3 only',
      safetyGoal: 'Degraded connectivity',
      mrmPolicy: 'candidate',
      reportMapping: ['이중 링크 고장 조합', '단일 잔여 경로 운용 검증'],
      switchTime: '72ms',
      latency: 'measured',
      jitter: 'measured',
    ),
    _ScenarioDef(
      id: 'allPaths',
      category: 'MRM Test',
      title: 'All Paths Link Down',
      icon: Icons.emergency_rounded,
      color: Color(0xFFDC2626),
      cause: 'Links for Paths 1, 2 and 3 are down simultaneously.',
      effect: 'No valid Ethernet route remains between the three switches.',
      action: 'Declare network isolation, execute MRM and verify NC recovery.',
      modeName: 'MRM safe stop',
      fusion: 'No network path',
      safetyGoal: 'Minimal risk condition',
      mrmPolicy: 'active',
      reportMapping: ['전체 네트워크 단절 고장', 'MRM 진입 및 복구 검증'],
      switchTime: 'MRM',
      latency: 'measured',
      jitter: 'measured',
    ),
  ];

  // Kept as reference material while the hardware validation UI is path-only.
  // ignore: unused_field
  static const legacyValues = [
    _ScenarioDef(
      id: 'triple',
      category: 'Baseline',
      title: 'Triple sensor normal',
      icon: Icons.verified_rounded,
      color: Color(0xFF16A34A),
      cause: 'No active electrical component fault.',
      effect: 'LiDAR/GNSS/Camera all available.',
      action: 'Keep nominal E/E topology and Autoware full stack.',
      modeName: 'Triple sensor',
      fusion: 'LiDAR 0.4 / GNSS 0.3 / Camera 0.3',
      safetyGoal: 'Full DDT',
      mrmPolicy: 'standby',
      reportMapping: ['인지범위별 삼중 센서 측위 모드', 'Lv.4 플랫폼 정상 주행 기준'],
      switchTime: '0ms',
      latency: '1ms',
      jitter: '0.5ms',
    ),
    _ScenarioDef(
      id: 'gnssDrift',
      category: 'Sensor Fault',
      title: 'GNSS drift',
      icon: Icons.satellite_alt_rounded,
      color: Color(0xFFF59E0B),
      cause: 'GNSS 좌표가 오도미터 이동거리와 불일치.',
      effect: '절대 측위 신뢰도 저하, map position jump 위험.',
      action: 'GNSS fusion weight를 0으로 낮추고 LiDAR + Camera 측위로 전환.',
      modeName: 'LiDAR + Camera',
      fusion: 'LiDAR 0.6 / GNSS 0.0 / Camera 0.4',
      safetyGoal: 'No position jump',
      mrmPolicy: 'standby',
      reportMapping: ['GNSS 오류 판정: 오도미터 이동거리 불일치', '이중 센서에서 단일/대체 측위 전환 영향 분석'],
      switchTime: '82ms',
      latency: '1ms',
      jitter: '0.5ms',
    ),
    _ScenarioDef(
      id: 'lidarFrontCenter',
      category: 'Sensor Fault',
      title: 'LiDAR-FC unavailable',
      icon: Icons.radar_rounded,
      color: Color(0xFFEF4444),
      cause: '전방 중앙 LiDAR 데이터 상실.',
      effect: '전방 point cloud coverage 감소.',
      action: '좌/우 LiDAR와 GNSS/Camera로 partial fusion 재구성.',
      modeName: 'LiDAR partial fusion',
      fusion: 'LiDAR side pair 0.5 / GNSS 0.2 / Camera 0.3',
      safetyGoal: 'Maintain DDT degraded',
      mrmPolicy: 'standby',
      reportMapping: ['4개 라이다 기반 Lv.4 차량 플랫폼', '센서 고장 시 다른 센서 데이터로 시스템 조정'],
      switchTime: '96ms',
      latency: '1ms',
      jitter: '0.6ms',
    ),
    _ScenarioDef(
      id: 'cameraLost',
      category: 'Sensor Fault',
      title: 'Camera unavailable',
      icon: Icons.videocam_off_rounded,
      color: Color(0xFFF59E0B),
      cause: '전방 카메라 신뢰도 상실.',
      effect: '차선/visual odometry 신뢰도 저하.',
      action: 'LiDAR NDT + GNSS 측위 기반 stack으로 전환.',
      modeName: 'LiDAR + GNSS',
      fusion: 'LiDAR 0.7 / GNSS 0.3 / Camera 0.0',
      safetyGoal: 'Lane-safe degraded',
      mrmPolicy: 'standby',
      reportMapping: ['이중 센서 주행 모드', 'Autoware 측위/탐지/계획/제어 pipeline'],
      switchTime: '74ms',
      latency: '1ms',
      jitter: '0.5ms',
    ),
    _ScenarioDef(
      id: 'gnssOnly',
      category: 'Sensor Fault',
      title: 'GNSS only degraded',
      icon: Icons.public_rounded,
      color: Color(0xFFDC2626),
      cause: 'LiDAR와 Camera가 동시에 제한됨.',
      effect: '자율주행 지속 가능성 낮음, MRM 후보.',
      action: 'GNSS hold로 위치를 유지하고 차선 변경/고속 제어 차단.',
      modeName: 'GNSS only',
      fusion: 'LiDAR 0.0 / GNSS 1.0 / Camera 0.0',
      safetyGoal: 'Minimal risk ready',
      mrmPolicy: 'candidate',
      reportMapping: ['단일 센서 주행 모드', '복구 불가능 결함 발생 시 단계적 저하'],
      switchTime: '118ms',
      latency: '1.4ms',
      jitter: '0.8ms',
    ),
    _ScenarioDef(
      id: 'tsnSyncLost',
      category: 'Network Fault',
      title: 'TSN time sync lost',
      icon: Icons.sync_problem_rounded,
      color: Color(0xFFEF4444),
      cause: 'Front Zonal Gateway PTP/GM 동기 상실.',
      effect: '센서 timestamp alignment 실패 위험.',
      action: 'BMCA failover와 FRER redundant path를 활성화.',
      modeName: 'TSN reconfigured',
      fusion: 'Sensor fusion held until time base validated',
      safetyGoal: 'Bounded latency',
      mrmPolicy: 'standby',
      reportMapping: ['TSN FRER 및 DetNet 지연시간 편차 보장', 'Zonal Gateway 오류검지 기능'],
      switchTime: '64ms',
      latency: '1ms',
      jitter: '0.5ms',
    ),
    _ScenarioDef(
      id: 'frerPathLost',
      category: 'Network Fault',
      title: 'FRER path A lost',
      icon: Icons.cable_rounded,
      color: Color(0xFFF59E0B),
      cause: '전방 Ethernet path A 단절.',
      effect: '중복 경로 중 하나가 손실되지만 센서 수집은 유지 가능.',
      action: 'Path B를 active로 유지하고 hitless recovery를 검증.',
      modeName: 'FRER fail-operational',
      fusion: 'Fusion unchanged, network path reweighted',
      safetyGoal: 'No packet loss impact',
      mrmPolicy: 'standby',
      reportMapping: [
        'Frame Replication and Elimination for Reliability',
        'Automotive Ethernet 기반 통합 네트워크',
      ],
      switchTime: '34ms',
      latency: '1ms',
      jitter: '0.5ms',
    ),
    _ScenarioDef(
      id: 'zgFrontIsolated',
      category: 'Zonal Gateway Fault',
      title: 'ZG-F isolated',
      icon: Icons.hub_rounded,
      color: Color(0xFFEF4444),
      cause: '전방 Zonal Gateway 통신 고립.',
      effect: '전방 센서 수집 경로와 ADS compute 입력이 제한됨.',
      action: '백업 gateway 경로로 센서 데이터를 우회하고 confidence를 낮춤.',
      modeName: 'Zonal degraded',
      fusion: 'Front sensors down-weighted, rear/side context held',
      safetyGoal: 'Fail-operational',
      mrmPolicy: 'standby/candidate',
      reportMapping: ['Zonal 아키텍처 적용 요구사항', '데이터 수집 및 고장 진단/대응 구조'],
      switchTime: '126ms',
      latency: '1.6ms',
      jitter: '0.9ms',
    ),
    _ScenarioDef(
      id: 'localizationDelayed',
      category: 'Autoware Fault',
      title: 'Localization delayed',
      icon: Icons.memory_rounded,
      color: Color(0xFFF59E0B),
      cause: 'Autoware localization callback 지연 증가.',
      effect: '측위 pipeline tail latency 증가.',
      action: '자원 스케줄링과 watchdog으로 localization node를 안정화.',
      modeName: 'Pipeline scheduled',
      fusion: 'Fusion unchanged, compute resource reallocated',
      safetyGoal: 'Bounded callback',
      mrmPolicy: 'standby',
      reportMapping: ['Autoware pipeline 성능 영향 분석', '자원 스케줄링 기술 개발'],
      switchTime: '48ms',
      latency: '1.2ms',
      jitter: '0.7ms',
    ),
    _ScenarioDef(
      id: 'compoundRain',
      category: 'Compound Fault',
      title: 'Rain/fog confidence drop',
      icon: Icons.thunderstorm_rounded,
      color: Color(0xFFDC2626),
      cause: '우천/안개/야간 환경에서 LiDAR와 Camera 신뢰도가 동시에 감소.',
      effect: '인지범위 축소, planning confidence 감소.',
      action: 'GNSS/odometry 비중을 높이고 속도 제한, 필요 시 MRM으로 전환.',
      modeName: 'Compound degraded',
      fusion: 'LiDAR 0.2 / GNSS 0.5 / Camera 0.3',
      safetyGoal: 'Controlled degradation',
      mrmPolicy: 'candidate',
      reportMapping: ['SOTIF 관점 원인 시나리오', '복합 결함 기반 시뮬레이터 검증'],
      switchTime: '142ms',
      latency: '1.8ms',
      jitter: '1.0ms',
    ),
    _ScenarioDef(
      id: 'mrmStop',
      category: 'MRM Required',
      title: 'MRM safe stop',
      icon: Icons.emergency_rounded,
      color: Color(0xFFDC2626),
      cause: '센서 조합으로 Autoware 주행 stack 유지 불가.',
      effect: '정상 또는 저하 주행 지속 불가.',
      action: 'MRM behavior로 안전 정지 trajectory를 실행.',
      modeName: 'MRM safe stop',
      fusion: 'Fusion disabled after stop target fixed',
      safetyGoal: 'Minimal risk condition',
      mrmPolicy: 'active',
      reportMapping: ['결함/오류 시나리오 기반 실차 검증', '안전성 향상 기능 재구성'],
      switchTime: '210ms',
      latency: '2ms',
      jitter: '1.2ms',
    ),
  ];
}

class _ReconfigMode {
  const _ReconfigMode({
    required this.name,
    required this.localization,
    required this.planning,
    required this.control,
    required this.color,
    required this.icon,
    required this.isFaulted,
    required this.isMrm,
  });

  final String name;
  final String localization;
  final String planning;
  final String control;
  final Color color;
  final IconData icon;
  final bool isFaulted;
  final bool isMrm;

  factory _ReconfigMode.fromScenario(
    _ScenarioDef scenario,
    List<FaultData> faults,
  ) {
    if ((scenario.id == 'normal' || scenario.id == 'triple') &&
        faults.isEmpty) {
      return const _ReconfigMode(
        name: 'Network nominal',
        localization: 'Path A + Path B + Rear confirmed',
        planning: 'Autoware route retained',
        control: 'Nominal control retained',
        color: Color(0xFF16A34A),
        icon: Icons.verified_rounded,
        isFaulted: false,
        isMrm: false,
      );
    }
    final mrm = scenario.id == 'mrmStop';
    return _ReconfigMode(
      name: scenario.modeName,
      localization: scenario.fusion,
      planning: mrm ? 'Safe stop trajectory' : 'Constraint-aware route',
      control: mrm ? 'Controlled stop' : 'Confidence-based cap',
      color: scenario.color,
      icon: mrm ? Icons.emergency_rounded : Icons.change_circle_rounded,
      isFaulted: true,
      isMrm: mrm,
    );
  }

  factory _ReconfigMode.fromHardware(String mode, List<FaultData> faults) {
    if (mode == 'MRM') {
      return const _ReconfigMode(
        name: 'MRM safe stop',
        localization: 'Dead reckoning to stop target',
        planning: 'Safe stop trajectory',
        control: 'Controlled stop + hazards',
        color: Color(0xFFDC2626),
        icon: Icons.emergency_rounded,
        isFaulted: true,
        isMrm: true,
      );
    }
    final degraded = faults.isNotEmpty;
    final normalized = degraded ? 'FRER degraded' : 'Network nominal';
    final color = degraded ? const Color(0xFFF59E0B) : const Color(0xFF16A34A);
    return _ReconfigMode(
      name: normalized,
      localization: degraded
          ? 'Redundant Ethernet route confirmed'
          : 'Three paths confirmed by ESP controller',
      planning: 'Autoware route retained',
      control: degraded ? 'Fail-operational control' : 'Nominal control',
      color: color,
      icon: degraded ? Icons.alt_route_rounded : Icons.verified_rounded,
      isFaulted: degraded,
      isMrm: false,
    );
  }
}
