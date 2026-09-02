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

class TopologyScreen extends ConsumerStatefulWidget {
  const TopologyScreen({super.key});

  @override
  ConsumerState<TopologyScreen> createState() => _TopologyScreenState();
}

class _TopologyScreenState extends ConsumerState<TopologyScreen> {
  bool _cameras = true;
  bool _cables = true;
  VehicleViewMode _mode = VehicleViewMode.iso;

  @override
  Widget build(BuildContext context) {
    final rig = ref.watch(rigProvider);
    final selected = ref.watch(selectedNodeProvider);

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 206,
            child: _Side(
              cameras: _cameras,
              cables: _cables,
              mode: _mode,
              onCameras: (v) => setState(() => _cameras = v),
              onCables: (v) => setState(() => _cables = v),
              onMode: (v) => setState(() => _mode = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Panel(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
              child: Column(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _mode == VehicleViewMode.model
                          ? ModelVehicleView(
                              selectedNodeId: selected,
                              onSelect: (id) =>
                                  ref.read(selectedNodeProvider.notifier).state = id,
                            )
                          : VehicleView(
                              snapshot: rig.snapshot,
                              selectedNodeId: selected,
                              plan: _mode == VehicleViewMode.plan,
                              showCameras: _cameras,
                              showCables: _cables,
                              onSelect: (id) {
                                ref.read(selectedNodeProvider.notifier).state = id;
                                final port = id == null ? null : nodeById(id)?.acuPort;
                                ref.read(selectedPortProvider.notifier).state = port;
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const _PortStrip(),
                  const SizedBox(height: 8),
                  const _JackStrip(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The ten ACU_IT ports under the vehicle, five to a row. One row of ten would give each cell
/// about 33 logical pixels on this tablet, which truncates every Korean label to its first
/// syllable -- and the syllable that is cut is the one saying front or rear.
class _PortStrip extends ConsumerWidget {
  const _PortStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final selectedPort = ref.watch(selectedPortProvider);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Tone.line),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 58,
            child: Text('ACU_IT\nports',
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w800, color: Tone.muted, height: 1.3)),
          ),
          Expanded(
            child: Column(
              children: [
                for (final row in [acuItPorts.sublist(0, 5), acuItPorts.sublist(5)])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        for (final p in row)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2.5),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  ref.read(selectedPortProvider.notifier).state = p.id;
                                  ref.read(selectedNodeProvider.notifier).state = p.peerNodeId;
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: selectedPort == p.id
                                        ? Tone.accent.withValues(alpha: 0.10)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: selectedPort == p.id ? Tone.accent : Tone.line,
                                      width: selectedPort == p.id ? 1.4 : 1,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(p.id,
                                          style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w800,
                                              color: Tone.muted)),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          p.short,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            color: p.used ? Tone.text : Tone.faint,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          color: linkColour(rig.snapshot.link(p.id),
                                              p.used ? Tone.faint : Tone.line),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
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

/// The five ACU_NO camera jacks, alongside the ACU_IT port strip. The cameras never touch
/// ACU_IT, so seeing both rows at once is what tells you which box a lost feed belongs to.
class _JackStrip extends ConsumerWidget {
  const _JackStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final selectedPort = ref.watch(selectedPortProvider);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Tone.line),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 58,
            child: Text('ACU_NO\ncameras',
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w800, color: Tone.muted, height: 1.3)),
          ),
          for (final j in acuNoJacks)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.5),
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    ref.read(selectedPortProvider.notifier).state = j.id;
                    ref.read(selectedNodeProvider.notifier).state = j.feedNodeIds.first;
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: selectedPort == j.id ? Tone.accent.withValues(alpha: 0.10) : Colors.white,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                        color: selectedPort == j.id ? Tone.accent : Tone.line,
                        width: selectedPort == j.id ? 1.4 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: Color(j.dot),
                            shape: BoxShape.circle,
                            border: Border.all(color: Tone.line),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(j.id,
                                      style: const TextStyle(
                                          fontSize: 10.5, fontWeight: FontWeight.w800)),
                                  const Spacer(),
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: linkColour(rig.snapshot.link(j.id), Tone.faint),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                j.feedNodeIds.map(shortName).join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 9.5, color: Tone.muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Side extends ConsumerWidget {
  final bool cameras;
  final bool cables;
  final VehicleViewMode mode;
  final ValueChanged<bool> onCameras;
  final ValueChanged<bool> onCables;
  final ValueChanged<VehicleViewMode> onMode;

  const _Side({
    required this.cameras,
    required this.cables,
    required this.mode,
    required this.onCameras,
    required this.onCables,
    required this.onMode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final counts = <NodeKind, int>{};
    for (final n in allNodes) {
      counts[n.kind] = (counts[n.kind] ?? 0) + 1;
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('View'),
              const SizedBox(height: 10),
              _Segmented(mode: mode, onChanged: onMode),
              const SizedBox(height: 8),
              Text(
                switch (mode) {
                  VehicleViewMode.model => 'glTF body. Pinch to zoom, drag to orbit.',
                  VehicleViewMode.iso => 'Schematic. Drag to orbit, double-tap to reset.',
                  VehicleViewMode.plan => 'Top-down. Drag to swing into 3D, double-tap to reset.',
                },
                style: const TextStyle(fontSize: 10.5, color: Tone.faint, height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('On the vehicle'),
              const SizedBox(height: 10),
              _CountRow(colour: Tone.lidar, label: 'LiDAR', n: counts[NodeKind.lidar] ?? 0),
              _CountRow(colour: Tone.camera, label: 'Camera feeds', n: counts[NodeKind.camera] ?? 0),
              _CountRow(colour: Tone.acu, label: 'ACU', n: counts[NodeKind.acu] ?? 0),
              _CountRow(
                colour: Tone.other,
                label: 'TCU / display',
                n: (counts[NodeKind.tcu] ?? 0) + (counts[NodeKind.display] ?? 0),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('Layers'),
              const SizedBox(height: 2),
              _Toggle(label: 'Cameras', value: cameras, onChanged: onCameras),
              _Toggle(label: 'Harness', value: cables, onChanged: onCables),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('Link'),
              const SizedBox(height: 10),
              if (rig.mode == RigMode.reference)
                const Text(
                  'No rig attached. The harness is drawn as designed; nothing here claims a link '
                  'is up. Switch to DEMO for a scripted rig.',
                  style: TextStyle(fontSize: 11, color: Tone.muted, height: 1.45),
                )
              else ...[
                _LegendRow(colour: Tone.ok, label: 'Up'),
                _LegendRow(colour: Tone.warn, label: 'Degraded'),
                _LegendRow(colour: Tone.bad, label: 'Down'),
                const SizedBox(height: 6),
                Text('${rig.snapshot.downCount} link(s) down',
                    style: const TextStyle(fontSize: 11, color: Tone.muted)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          tint: const Color(0xFFFFF8EC),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('Not on the sheets'),
              const SizedBox(height: 8),
              const Text(
                'The side LiDARs (LH / RH) have part numbers and outlines but no ACU port and no '
                'signal table anywhere in this set, so they are drawn unwired.',
                style: TextStyle(fontSize: 11, color: Tone.text, height: 1.45),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Segmented extends StatelessWidget {
  final VehicleViewMode mode;
  final ValueChanged<VehicleViewMode> onChanged;

  const _Segmented({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool selected, VoidCallback onTap) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 7),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? Tone.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : Tone.muted,
                ),
              ),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Tone.line),
      ),
      child: Row(
        children: [
          seg('Model', mode == VehicleViewMode.model, () => onChanged(VehicleViewMode.model)),
          seg('3D', mode == VehicleViewMode.iso, () => onChanged(VehicleViewMode.iso)),
          seg('Plan', mode == VehicleViewMode.plan, () => onChanged(VehicleViewMode.plan)),
        ],
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  final Color colour;
  final String label;
  final int n;

  const _CountRow({required this.colour, required this.label, required this.n});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: colour, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
          Text('$n', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  final Color colour;
  final String label;

  const _LegendRow({required this.colour, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(width: 16, height: 3, color: colour),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _Toggle({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
        Switch(value: value, onChanged: onChanged, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      ],
    );
  }
}
