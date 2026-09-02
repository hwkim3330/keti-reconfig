import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/reference.dart';
import '../core/theme.dart';
import '../providers/rig_provider.dart';
import 'sheet_image.dart';
import 'vehicle_plan.dart' show kindColour, linkColour;

/// The right-hand inspector. It is a push, not a popup: a modal over a live console hides the
/// state being demonstrated, which is exactly what you were pointing at.
class InspectorPanel extends ConsumerWidget {
  const InspectorPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodeId = ref.watch(selectedNodeProvider);
    final portId = ref.watch(selectedPortProvider);
    final node = nodeId == null ? null : nodeById(nodeId);
    final port = portId == null ? null : portById(portId);
    final jack = portId == null
        ? null
        : acuNoJacks.where((j) => j.id == portId).firstOrNull;

    return Container(
      width: 328,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: Tone.line)),
      ),
      child: node == null && port == null && jack == null
          ? const _Empty()
          : ListView(
              padding: const EdgeInsets.all(14),
              children: [
                Row(
                  children: [
                    const SectionTitle('Inspector'),
                    const Spacer(),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18, color: Tone.muted),
                      onPressed: () {
                        ref.read(selectedNodeProvider.notifier).state = null;
                        ref.read(selectedPortProvider.notifier).state = null;
                      },
                    ),
                  ],
                ),
                if (port != null) _PortCard(port: port),
                if (jack != null) _JackCard(jack: jack),
                if (node != null) ...[
                  if (port != null || jack != null) const SizedBox(height: 12),
                  _NodeCard(node: node),
                ],
              ],
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 4),
          SectionTitle('Inspector'),
          SizedBox(height: 16),
          Icon(Icons.touch_app_outlined, size: 28, color: Tone.faint),
          SizedBox(height: 10),
          Text(
            'Tap a device on the vehicle, or a port on either ACU, to see what the sheets say '
            'about it — connector, cavity, wire colours, and which reading is sourced.',
            style: TextStyle(fontSize: 12, color: Tone.muted, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _PortCard extends ConsumerWidget {
  final AcuPort port;

  const _PortCard({required this.port});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final state = rig.snapshot.link(port.id);
    final rate = rig.snapshot.rate(port.id);
    final conn = acuItConnectors.firstWhere((c) => c.id == port.connectorId);

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('ACU_IT · Port ${port.id}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const Spacer(),
              if (rig.mode == RigMode.simulated)
                Chip2(
                  switch (state) {
                    LinkState.up => 'UP',
                    LinkState.degraded => 'DEGRADED',
                    LinkState.down => 'DOWN',
                    LinkState.unknown => 'N/A',
                  },
                  color: linkColour(state, Tone.faint),
                  solid: state != LinkState.unknown,
                ),
            ],
          ),
          const SizedBox(height: 8),
          _Row('Label', port.label),
          _Row('Connector', conn.title),
          _Row('Part', conn.partNumber),
          _SourcedRow('Link rate', port.speed),
          if (rate != null) _Row('Rate (simulated)', '${rate.toStringAsFixed(0)} Mb/s'),
          if (!port.used) _Row('Status', 'Marked 미사용 on the sheet'),
          if (port.note != null) ...[
            const SizedBox(height: 8),
            _Warn(port.note!),
          ],
        ],
      ),
    );
  }
}

class _JackCard extends ConsumerWidget {
  final CamJack jack;

  const _JackCard({required this.jack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final state = rig.snapshot.link(jack.id);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Color(jack.dot),
                  shape: BoxShape.circle,
                  border: Border.all(color: Tone.line),
                ),
              ),
              const SizedBox(width: 8),
              Text('ACU_NO · ${jack.id}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const Spacer(),
              if (rig.mode == RigMode.simulated)
                Chip2(state == LinkState.down ? 'DOWN' : 'UP',
                    color: linkColour(state, Tone.faint), solid: true),
            ],
          ),
          const SizedBox(height: 8),
          _Row('Housing', 'KET FAKRA straight dual jack · ${jack.dotName} coding'),
          _Row('Feeds', '2 (one per coax position)'),
          const SizedBox(height: 6),
          for (final id in jack.feedNodeIds)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                onTap: () => ref.read(selectedNodeProvider.notifier).state = id,
                child: Row(
                  children: [
                    const Icon(Icons.videocam_outlined, size: 14, color: Tone.camera),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(nodeById(id)?.name ?? id,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                    Text(nodeById(id)?.model ?? '',
                        style: const TextStyle(fontSize: 11, color: Tone.muted)),
                  ],
                ),
              ),
            ),
          if (jack.altRevision != null) ...[
            const SizedBox(height: 8),
            _Warn(jack.altRevision!),
          ],
        ],
      ),
    );
  }
}

class _NodeCard extends ConsumerWidget {
  final Node node;

  const _NodeCard({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colour = kindColour(node.kind);
    final port = node.acuPort == null ? null : portById(node.acuPort!);
    final pinout = _pinoutFor(node);

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: colour, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(node.name,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          if (node.ko != null) ...[
            const SizedBox(height: 2),
            Text(node.ko!, style: const TextStyle(fontSize: 12, color: Tone.muted)),
          ],
          const SizedBox(height: 10),
          _Row('Model', node.model),
          if (node.connector != null) _Row('Connector', node.connector!),
          if (port != null)
            _Row('ACU_IT port', 'Port ${port.id} · ${port.label}'),
          if (node.kind == NodeKind.camera) _Row('Jack', _jackFor(node.id)),
          const SizedBox(height: 8),
          Text(node.mount, style: const TextStyle(fontSize: 11.5, color: Tone.muted, height: 1.5)),
          if (node.kind == NodeKind.lidar && node.acuPort == null) ...[
            const SizedBox(height: 8),
            const _Warn('No ACU port is named for this unit anywhere in the sheet set, and no '
                'signal table is printed for it. Where it terminates is an open question, not a '
                'gap in this console.'),
          ],
          if (pinout != null) ...[
            const SizedBox(height: 10),
            InkWell(
              onTap: () => showDialog(
                context: context,
                builder: (_) => _PinoutDialog(pinout: pinout),
              ),
              child: Row(
                children: [
                  const Icon(Icons.table_rows_outlined, size: 15, color: Tone.accent),
                  const SizedBox(width: 7),
                  Text('Pinout · ${pinout.connector}',
                      style: const TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700, color: Tone.accent)),
                ],
              ),
            ),
          ],
          if (node.refImage != null) ...[
            const SizedBox(height: 12),
            SheetImage(asset: node.refImage!, title: 'From the sheet', height: 126),
          ],
        ],
      ),
    );
  }

  Pinout? _pinoutFor(Node n) {
    if (n.model.startsWith('Falcon')) return pinouts.firstWhere((p) => p.id == 'falcon');
    if (n.model.startsWith('Hummingbird')) return pinouts.firstWhere((p) => p.id == 'hummingbird');
    if (n.model.startsWith('Hesai')) return pinouts.firstWhere((p) => p.id == 'side');
    if (n.id == 'acu_it') return pinouts.firstWhere((p) => p.id == 'acu_it_pairs');
    return null;
  }

  String _jackFor(String nodeId) {
    for (final j in acuNoJacks) {
      if (j.feedNodeIds.contains(nodeId)) return '${j.id} · ${j.dotName}';
    }
    return '—';
  }
}

class _PinoutDialog extends StatelessWidget {
  final Pinout pinout;

  const _PinoutDialog({required this.pinout});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 620,
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(pinout.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            Text(pinout.connector, style: const TextStyle(fontSize: 12, color: Tone.muted)),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final r in pinout.rows)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: const BoxDecoration(
                          border: Border(top: BorderSide(color: Tone.line)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 60,
                              child: Text(r.cav,
                                  style: const TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w800)),
                            ),
                            SizedBox(
                              width: 90,
                              child: Text(r.colour,
                                  style: const TextStyle(fontSize: 11, color: Tone.muted)),
                            ),
                            Expanded(
                              child: Text(r.signal, style: const TextStyle(fontSize: 12)),
                            ),
                            Expanded(
                              child: Text(r.comment,
                                  style: const TextStyle(fontSize: 11, color: Tone.faint)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(pinout.note,
                style: const TextStyle(fontSize: 11.5, color: Tone.text, height: 1.5)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: const TextStyle(fontSize: 11, color: Tone.muted)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

/// A value whose provenance is not a plain sheet reading gets said so, in place.
class _SourcedRow extends StatelessWidget {
  final String label;
  final Sourced<String> value;

  const _SourcedRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final inferred = value.from != Provenance.sheet;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 92,
                child: Text(label, style: const TextStyle(fontSize: 11, color: Tone.muted)),
              ),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        value.value,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: inferred ? Tone.muted : Tone.text,
                          fontStyle: inferred ? FontStyle.italic : FontStyle.normal,
                        ),
                      ),
                    ),
                    if (inferred) ...[
                      const SizedBox(width: 6),
                      const Chip2('not on sheet', color: Tone.warn),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (inferred && value.note != null)
            Padding(
              padding: const EdgeInsets.only(left: 92, top: 4),
              child: Text(value.note!,
                  style: const TextStyle(fontSize: 10.5, color: Tone.faint, height: 1.4)),
            ),
        ],
      ),
    );
  }
}

class _Warn extends StatelessWidget {
  final String text;

  const _Warn(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Tone.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Tone.warn.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 14, color: Tone.warn),
          const SizedBox(width: 7),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 11, color: Tone.text, height: 1.45)),
          ),
        ],
      ),
    );
  }
}
