import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/reference.dart';
import '../core/theme.dart';
import '../providers/rig_provider.dart';
import '../widgets/vehicle_plan.dart';
import 'model_view.dart';

/// Which of the three renderings of the same data is on screen.
enum VehicleViewMode { model, iso, plan }

/// The vehicle page is one hero and nothing else. Controls float over it as small capsules and
/// the port bar sits under it; the previous version spent a fifth of a 1280 px screen on a column
/// of cards that were, between them, four switches and a legend.
class TopologyScreen extends ConsumerStatefulWidget {
  const TopologyScreen({super.key});

  @override
  ConsumerState<TopologyScreen> createState() => _TopologyScreenState();
}

class _TopologyScreenState extends ConsumerState<TopologyScreen> {
  bool _cameras = true;
  bool _cables = true;
  double _opacity = 0.42;
  bool _wheels = false;
  bool _lights = false;
  double _orbit = 40;
  double _polar = 68;
  bool _flow = true;
  VehicleViewMode _mode = VehicleViewMode.model;

  void _select(String? id) {
    ref.read(selectedNodeProvider.notifier).state = id;
    ref.read(selectedPortProvider.notifier).state = id == null ? null : nodeById(id)?.acuPort;
  }

  @override
  Widget build(BuildContext context) {
    final rig = ref.watch(rigProvider);
    final selected = ref.watch(selectedNodeProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        children: [
          Expanded(
            child: Panel(
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: Stack(
                  children: [
                    // All three renderings stay built. Rebuilding the glTF view costs about a
                    // second of blank frame on this tablet, and a view switch that blanks is a
                    // view switch nobody uses twice.
                    Positioned.fill(
                      child: IndexedStack(
                        index: _mode.index,
                        children: [
                          ModelVehicleView(
                            selectedNodeId: selected,
                            onSelect: _select,
                            shellOpacity: _opacity,
                            wheelsTurning: _wheels,
                            lightsOn: _lights,
                            orbitDeg: _orbit,
                            polarDeg: _polar,
                            dataFlow: _flow,
                            trunkStates: {
                              for (final t in rig.trunks)
                                if (t.path != null)
                                  t.path!: switch (rig.snapshot.link('path${t.path}')) {
                                    LinkState.down => 'down',
                                    LinkState.up || LinkState.degraded => 'up',
                                    LinkState.unknown =>
                                      rig.mode == RigMode.reference ? 'up' : 'unknown',
                                  },
                            },
                          ),
                          RepaintBoundary(
                            child: VehicleView(
                              snapshot: rig.snapshot,
                              selectedNodeId: selected,
                              plan: false,
                              trunks: rig.trunks,
                              showCameras: _cameras,
                              showCables: _cables,
                              onSelect: _select,
                            ),
                          ),
                          RepaintBoundary(
                            child: VehicleView(
                              snapshot: rig.snapshot,
                              selectedNodeId: selected,
                              plan: true,
                              trunks: rig.trunks,
                              showCameras: _cameras,
                              showCables: _cables,
                              onSelect: _select,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 14,
                      top: 14,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ViewSwitch(mode: _mode, onChanged: (m) => setState(() => _mode = m)),
                          const SizedBox(height: 10),
                          if (_mode == VehicleViewMode.model) ...[
                            _OpacityCapsule(
                              value: _opacity,
                              onChanged: (v) => setState(() => _opacity = v),
                            ),
                            const SizedBox(height: 10),
                            _ToggleCapsule(
                              items: [
                                (Icons.bolt_outlined, 'Data', _flow,
                                    () => setState(() => _flow = !_flow)),
                                (Icons.rotate_right, 'Wheels', _wheels,
                                    () => setState(() => _wheels = !_wheels)),
                                (Icons.lightbulb_outline, 'Lights', _lights,
                                    () => setState(() => _lights = !_lights)),
                              ],
                            ),
                          ] else
                            _LayerCapsule(
                              cameras: _cameras,
                              cables: _cables,
                              onCameras: (v) => setState(() => _cameras = v),
                              onCables: (v) => setState(() => _cables = v),
                            ),
                        ],
                      ),
                    ),
                    Positioned(left: 14, bottom: 14, child: _Legend(mode: _mode)),
                    if (_mode == VehicleViewMode.model)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 14,
                        child: Center(
                          child: _Turntable(
                            azimuth: _orbit,
                            onAzimuth: (v) => setState(() => _orbit = v),
                            onPreset: (a, p) => setState(() {
                              _orbit = a;
                              _polar = p;
                            }),
                          ),
                        ),
                      ),
                    Positioned(
                      right: 14,
                      bottom: 14,
                      child: _Hint(
                        text: switch (_mode) {
                          VehicleViewMode.model => 'Drag to orbit · pinch to zoom',
                          VehicleViewMode.iso => 'Drag to orbit · double-tap to reset',
                          VehicleViewMode.plan => 'Top-down · drag to swing into 3D',
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _PortBar(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Floating controls
// ---------------------------------------------------------------------------

/// The capsule the floating controls share: solid translucent white rather than a blur, because
/// a BackdropFilter over a live WebView costs a frame on this tablet and buys nothing here.
class _Capsule extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _Capsule({required this.child, this.padding = const EdgeInsets.all(4)});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Tone.hairline),
        boxShadow: const [
          BoxShadow(color: Color(0x141B2A44), blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: child,
    );
  }
}

class _ViewSwitch extends StatelessWidget {
  final VehicleViewMode mode;
  final ValueChanged<VehicleViewMode> onChanged;

  const _ViewSwitch({required this.mode, required this.onChanged});

  static const _labels = {
    VehicleViewMode.model: 'Model',
    VehicleViewMode.iso: '3D',
    VehicleViewMode.plan: 'Plan',
  };

  @override
  Widget build(BuildContext context) {
    return _Capsule(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in VehicleViewMode.values)
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                onChanged(m);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: m == mode ? Tone.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _labels[m]!,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: m == mode ? Colors.white : Tone.muted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Azimuth on a bar, plus the four views anyone actually asks for. Dragging the model still
/// works — this is for when the same angle has to come back twice.
class _Turntable extends StatelessWidget {
  final double azimuth;
  final ValueChanged<double> onAzimuth;
  final void Function(double azimuth, double polar) onPreset;

  const _Turntable({required this.azimuth, required this.onAzimuth, required this.onPreset});

  static const _presets = <(String, double, double)>[
    ('ISO', 40, 68),
    ('Front', 0, 80),
    ('Side', 90, 85),
    ('Top', 0, 6),
  ];

  @override
  Widget build(BuildContext context) {
    return _Capsule(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.threed_rotation, size: 15, color: Tone.faint),
          const SizedBox(width: 8),
          SizedBox(
            width: 168,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: Tone.accent,
                inactiveTrackColor: Tone.hairlineStrong,
                thumbColor: Colors.white,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 2),
              ),
              child: Slider(value: azimuth, min: -180, max: 180, onChanged: onAzimuth),
            ),
          ),
          SizedBox(
            width: 46,
            child: Text('${azimuth.round()}°',
                textAlign: TextAlign.right,
                style: Type.monoAt(11, weight: FontWeight.w700, colour: Tone.muted)),
          ),
          const SizedBox(width: 8),
          Container(width: 1, height: 20, color: Tone.hairline),
          for (final (label, a, p) in _presets)
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                onPreset(a, p);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w700, color: Tone.muted)),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row of small on/off pills. Used for anything the model can do that is not a slider.
class _ToggleCapsule extends StatelessWidget {
  final List<(IconData, String, bool, VoidCallback)> items;

  const _ToggleCapsule({required this.items});

  @override
  Widget build(BuildContext context) {
    return _Capsule(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (icon, label, on, tap) in items)
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                tap();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: on ? Tone.accent.withValues(alpha: 0.10) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 15, color: on ? Tone.accent : Tone.faint),
                    const SizedBox(width: 6),
                    Text(label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: on ? Tone.accent : Tone.faint,
                        )),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LayerCapsule extends StatelessWidget {
  final bool cameras;
  final bool cables;
  final ValueChanged<bool> onCameras;
  final ValueChanged<bool> onCables;

  const _LayerCapsule({
    required this.cameras,
    required this.cables,
    required this.onCameras,
    required this.onCables,
  });

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, String label, bool on, VoidCallback tap) => GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            tap();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: on ? Tone.accent.withValues(alpha: 0.10) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: on ? Tone.accent : Tone.faint),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: on ? Tone.accent : Tone.faint,
                    )),
              ],
            ),
          ),
        );

    return _Capsule(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          item(Icons.videocam_outlined, 'Cameras', cameras, () => onCameras(!cameras)),
          item(Icons.polyline_outlined, 'Harness', cables, () => onCables(!cables)),
        ],
      ),
    );
  }
}

class _OpacityCapsule extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _OpacityCapsule({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return _Capsule(
      padding: const EdgeInsets.fromLTRB(12, 4, 10, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.opacity, size: 15, color: Tone.faint),
          const SizedBox(width: 8),
          const Text('Body',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Tone.muted)),
          const SizedBox(width: 4),
          SizedBox(
            width: 128,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: Tone.accent,
                inactiveTrackColor: Tone.hairlineStrong,
                thumbColor: Colors.white,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 2),
              ),
              child: Slider(value: value, min: 0.08, max: 1, onChanged: onChanged),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text('${(value * 100).round()}%',
                textAlign: TextAlign.right,
                style: Type.monoAt(11, weight: FontWeight.w700, colour: Tone.muted)),
          ),
        ],
      ),
    );
  }
}

class _Legend extends ConsumerWidget {
  final VehicleViewMode mode;

  const _Legend({required this.mode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final counts = <NodeKind, int>{};
    for (final n in allNodes) {
      counts[n.kind] = (counts[n.kind] ?? 0) + 1;
    }
    Widget tally(Color c, String label, int n) => Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text('$n', style: Type.monoAt(12, weight: FontWeight.w800)),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(fontSize: 11, color: Tone.muted)),
            ],
          ),
        );

    return _Capsule(
      padding: const EdgeInsets.fromLTRB(14, 9, 4, 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          tally(Tone.lidar, 'LiDAR', counts[NodeKind.lidar] ?? 0),
          tally(Tone.camera, 'cameras', counts[NodeKind.camera] ?? 0),
          tally(Tone.acu, 'ACU', counts[NodeKind.acu] ?? 0),
          tally(Tone.tsn, 'TSN', counts[NodeKind.tsn] ?? 0),
          if (rig.mode == RigMode.simulated && rig.snapshot.downCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Chip2('${rig.snapshot.downCount} down', color: Tone.bad),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;

  const _Hint({required this.text});

  @override
  Widget build(BuildContext context) {
    return _Capsule(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Text(text, style: Type.tiny),
    );
  }
}

// ---------------------------------------------------------------------------
// Port bar
// ---------------------------------------------------------------------------

/// One bar for both boxes, switched rather than stacked. Two permanent strips took a fifth of the
/// page to show twenty cells, most of which are not what anyone is looking at.
class _PortBar extends ConsumerStatefulWidget {
  const _PortBar();

  @override
  ConsumerState<_PortBar> createState() => _PortBarState();
}

class _PortBarState extends ConsumerState<_PortBar> {
  bool _no = false;

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _Toggle2(
                  left: 'ACU_IT',
                  right: 'ACU_NO',
                  rightSelected: _no,
                  onChanged: (v) => setState(() => _no = v),
                ),
                const SizedBox(height: 5),
                Text(_no ? '5 camera jacks' : '10 Ethernet ports', style: Type.tiny),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: _no ? const _JackCells() : const _PortCells()),
        ],
      ),
    );
  }
}

class _Toggle2 extends StatelessWidget {
  final String left;
  final String right;
  final bool rightSelected;
  final ValueChanged<bool> onChanged;

  const _Toggle2({
    required this.left,
    required this.right,
    required this.rightSelected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool on, VoidCallback tap) => Expanded(
          child: GestureDetector(
            onTap: tap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(vertical: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? Tone.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                boxShadow: on
                    ? const [BoxShadow(color: Color(0x141B2A44), blurRadius: 6, offset: Offset(0, 1))]
                    : null,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: on ? Tone.ink : Tone.faint,
                ),
              ),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Tone.sunken,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Tone.hairline),
      ),
      child: Row(
        children: [
          seg(left, !rightSelected, () => onChanged(false)),
          seg(right, rightSelected, () => onChanged(true)),
        ],
      ),
    );
  }
}

class _PortCells extends ConsumerWidget {
  const _PortCells();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final selectedPort = ref.watch(selectedPortProvider);
    return Row(
      children: [
        for (final p in acuItPorts)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(selectedPortProvider.notifier).state = p.id;
                  ref.read(selectedNodeProvider.notifier).state = p.peerNodeId;
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  decoration: BoxDecoration(
                    color: selectedPort == p.id ? Tone.accent.withValues(alpha: 0.09) : Tone.sunken,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selectedPort == p.id ? Tone.accent : Tone.hairline,
                      width: selectedPort == p.id ? 1.4 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(p.id,
                              style: Type.monoAt(10.5, weight: FontWeight.w700, colour: Tone.faint)),
                          const Spacer(),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: linkColour(rig.snapshot.link(p.id),
                                  p.used ? Tone.hairlineStrong : Tone.hairline),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          p.short,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: p.used ? Tone.ink : Tone.faint,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _JackCells extends ConsumerWidget {
  const _JackCells();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final selectedPort = ref.watch(selectedPortProvider);
    return Row(
      children: [
        for (final j in acuNoJacks)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  HapticFeedback.selectionClick();
                  ref.read(selectedPortProvider.notifier).state = j.id;
                  ref.read(selectedNodeProvider.notifier).state = j.feedNodeIds.first;
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: selectedPort == j.id ? Tone.accent.withValues(alpha: 0.09) : Tone.sunken,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selectedPort == j.id ? Tone.accent : Tone.hairline,
                      width: selectedPort == j.id ? 1.4 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: Color(j.dot),
                              shape: BoxShape.circle,
                              border: Border.all(color: Tone.hairlineStrong),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(j.id, style: Type.monoAt(10.5, weight: FontWeight.w800)),
                          const Spacer(),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: linkColour(rig.snapshot.link(j.id), Tone.hairlineStrong),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        j.feedNodeIds.map(shortName).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10.5, color: Tone.muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
