import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/reference.dart';
import '../core/theme.dart';
import '../providers/rig_provider.dart';
import '../widgets/vehicle_plan.dart' show linkColour;

/// The two ACUs as their board edges: the connector faces, laid out the way the photographs
/// show them, with the sheet's port labels on them. Tapping a port opens it in the inspector.
class AcuScreen extends ConsumerWidget {
  const AcuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: const [
        _AcuItSection(),
        SizedBox(height: 14),
        _AcuNoSection(),
        SizedBox(height: 14),
        _RevisionNote(),
      ],
    );
  }
}

class _AcuItSection extends ConsumerWidget {
  const _AcuItSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('ACU_IT · board edge', trailing: 'Sheet 1 · ACU_IT 연결구성'),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Connector 0 is four cavities in one row where the others are two; without the
              // extra share its cells are half the width and every label truncates.
              for (final conn in acuItConnectors) ...[
                Expanded(
                  flex: conn.id == '0' ? 6 : 4,
                  child: _ConnectorFace(connector: conn),
                ),
                if (conn != acuItConnectors.last) const SizedBox(width: 14),
              ],
            ],
          ),
          const SizedBox(height: 12),
          const _PanelPorts(),
        ],
      ),
    );
  }
}

/// One connector, drawn as its cavity grid. Connector 0 is a single row of four; connectors 1
/// and 2 are 2×2 with ports 1 and 2 on the top row, exactly as the photo reads.
class _ConnectorFace extends ConsumerWidget {
  final AcuConnector connector;

  const _ConnectorFace({required this.connector});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ports = acuItPorts.where((p) => p.connectorId == connector.id).toList();
    final wide = connector.id == '0';
    final cells = <Widget>[];
    final rows = wide ? 1 : 2;
    final cols = wide ? 4 : 2;
    for (var r = 0; r < rows; r++) {
      final rowCells = <Widget>[];
      for (var c = 0; c < cols; c++) {
        final port = ports.where((p) => p.row == r && p.col == c).firstOrNull;
        rowCells.add(Expanded(
          child: _PortCell(
            port: port,
            cavity: wide ? 'EH0${4 - c}' : null,
          ),
        ));
        if (c < cols - 1) rowCells.add(const SizedBox(width: 8));
      }
      // Not CrossAxisAlignment.stretch: this Row sits in a ListView, so its cross axis is
      // unbounded, and stretch would hand every cell an infinite height. Release builds do not
      // assert on that -- the page just silently lost its container fills and its second row.
      // The cells carry their own height instead.
      cells.add(Row(children: rowCells));
      if (r < rows - 1) cells.add(const SizedBox(height: 8));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(connector.title,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(connector.partNumber, style: const TextStyle(fontSize: 11, color: Tone.muted)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: const Color(0xFF1C2230),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(children: cells),
        ),
        const SizedBox(height: 7),
        Text(connector.note,
            style: const TextStyle(fontSize: 10.5, color: Tone.muted, height: 1.4)),
      ],
    );
  }
}

class _PortCell extends ConsumerWidget {
  final AcuPort? port;
  final String? cavity;

  const _PortCell({required this.port, this.cavity});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final selectedPort = ref.watch(selectedPortProvider);

    if (port == null) {
      return Container(
        height: 62,
        decoration: BoxDecoration(
          color: const Color(0xFF262E3E),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0xFF39435A)),
        ),
        alignment: Alignment.center,
        child: Text(
          cavity == null ? '—' : '$cavity\nno label',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 9.5, color: Color(0xFF7C889E), height: 1.3),
        ),
      );
    }

    final p = port!;
    final state = rig.snapshot.link(p.id);
    final dot = linkColour(state, p.used ? const Color(0xFF64748B) : const Color(0xFF3F4A60));
    final selected = selectedPort == p.id;
    final rate = rig.snapshot.rate(p.id);

    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: () {
        HapticFeedback.selectionClick();
        ref.read(selectedPortProvider.notifier).state = p.id;
        ref.read(selectedNodeProvider.notifier).state = p.peerNodeId;
      },
      child: Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2B3956) : const Color(0xFF262E3E),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: selected ? Tone.accent : const Color(0xFF39435A),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Port ${p.id}',
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF9FB0CA))),
                const Spacer(),
                Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              ],
            ),
            const SizedBox(height: 3),
            // Shrink rather than ellipsise. A cavity cell is narrow, and "허밍버드 R" cut to
            // "허밍버드…" loses the one character that says which end of the vehicle it is.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                p.short,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: p.used ? Colors.white : const Color(0xFF7C889E),
                ),
              ),
            ),
            const Spacer(),
            Text(
              // The sheet's own shorthand for the pairs -- 1000B-T1, 10GB-T1. Spelled out, it
              // wraps to three lines in a cavity-width cell.
              rate != null
                  ? '${rate.toStringAsFixed(0)} Mb/s'
                  : p.speed.value.replaceAll('BASE-T1', 'B-T1'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9.5,
                color: p.speed.from == Provenance.inferred && rate == null
                    ? const Color(0xFF6C7A93)
                    : const Color(0xFF9FB0CA),
                fontStyle: p.speed.from == Provenance.inferred && rate == null
                    ? FontStyle.italic
                    : FontStyle.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The outward-facing panel of the ACU_IT case, from the CAD view on the sheet. It is not the
/// same set of connectors as the board edge above, and mixing them up is the obvious mistake to
/// make on the rig -- so both are drawn, labelled as what they are.
class _PanelPorts extends StatelessWidget {
  const _PanelPorts();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F8FB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Tone.line),
      ),
      child: Row(
        children: [
          const Text('Case panel',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Tone.muted)),
          const SizedBox(width: 12),
          ...[
            ('TOTAL I/O', null),
            ('USB-C', null),
            ('LAN 1', null),
            ('LAN 2', Tone.bad),
            ('LAN 3', Tone.accent),
          ].map((e) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (e.$2 != null) ...[
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: e.$2, shape: BoxShape.circle)),
                      const SizedBox(width: 4),
                    ],
                    Chip2(e.$1, color: Tone.faint),
                  ],
                ),
              )),
          const Spacer(),
          const Text('Sheet marks LAN 2 red and LAN 3 blue',
              style: TextStyle(fontSize: 10.5, color: Tone.faint)),
        ],
      ),
    );
  }
}

class _AcuNoSection extends ConsumerWidget {
  const _AcuNoSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('ACU_NO · faceplate', trailing: 'Sheet 5 · ACU2_NO'),
          const SizedBox(height: 12),
          // The faceplate as drawn: USB-C, five dual FAKRA jacks, USB-C on the top row; LAN and
          // TOTAL I/O below.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2A4A),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _FacePlateBox(label: 'USB C', width: 62),
                    const SizedBox(width: 10),
                    for (final jack in acuNoJacks) ...[
                      Expanded(child: _CamJackCell(jack: jack)),
                      const SizedBox(width: 10),
                    ],
                    const _FacePlateBox(label: 'USB C', width: 62),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 210, child: _LanBlock(snapshot: rig.snapshot)),
                    const SizedBox(width: 14),
                    const _FacePlateBox(label: 'TOTAL I/O', width: 150),
                    const Spacer(),
                    const Padding(
                      padding: EdgeInsets.only(right: 4, top: 6),
                      child: Text('a2z',
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: Colors.white70,
                              letterSpacing: -1)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const Text(fakraJackNote,
              style: TextStyle(fontSize: 11, color: Tone.muted, height: 1.45)),
        ],
      ),
    );
  }
}

class _CamJackCell extends ConsumerWidget {
  final CamJack jack;

  const _CamJackCell({required this.jack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rig = ref.watch(rigProvider);
    final state = rig.snapshot.link(jack.id);
    final selectedPort = ref.watch(selectedPortProvider);
    final selected = selectedPort == jack.id;
    final border = linkColour(state, const Color(0xFF3D4C6E));

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        HapticFeedback.selectionClick();
        ref.read(selectedPortProvider.notifier).state = jack.id;
        ref.read(selectedNodeProvider.notifier).state = jack.feedNodeIds.first;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2C3C63) : const Color(0xFF273454),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? Tone.accent : border, width: selected ? 1.6 : 1),
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
                    color: Color(jack.dot),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                ),
                const SizedBox(width: 6),
                Text(jack.id,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white)),
                const Spacer(),
                if (jack.altRevision != null)
                  const Icon(Icons.error_outline, size: 12, color: Color(0xFFE0A03A)),
              ],
            ),
            const SizedBox(height: 6),
            // Two coax positions per jack, one camera on each.
            for (final id in jack.feedNodeIds)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFF8FA3C8)),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        nodeById(id)?.name ?? id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: Color(0xFFC7D3E8)),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LanBlock extends StatelessWidget {
  final RigSnapshot snapshot;

  const _LanBlock({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF273454),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3D4C6E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('LAN · 4-way',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white)),
          const SizedBox(height: 6),
          for (var i = 0; i < acuNoLan.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: linkColour(snapshot.link('lan$i'), const Color(0xFF64748B)),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      acuNoLan[i].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: acuNoLan[i].note != null
                            ? const Color(0xFFE0A03A)
                            : const Color(0xFFC7D3E8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(acuNoLan[i].speed,
                      style: const TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF8FA3C8))),
                ],
              ),
            ),
          const SizedBox(height: 2),
          const Text('Orin A link is struck out on one revision',
              style: TextStyle(fontSize: 9, color: Color(0xFFE0A03A))),
        ],
      ),
    );
  }
}

class _FacePlateBox extends StatelessWidget {
  final String label;
  final double width;

  const _FacePlateBox({required this.label, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF273454),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF3D4C6E)),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF9FB0CA))),
    );
  }
}

class _RevisionNote extends StatelessWidget {
  const _RevisionNote();

  @override
  Widget build(BuildContext context) {
    return Panel(
      tint: const Color(0xFFFFF8EC),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.history_edu_outlined, size: 16, color: Tone.warn),
              SizedBox(width: 8),
              Text('Which revision this screen follows',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 8),
          const Text(acuItRevisionNote,
              style: TextStyle(fontSize: 11.5, color: Tone.text, height: 1.5)),
        ],
      ),
    );
  }
}
