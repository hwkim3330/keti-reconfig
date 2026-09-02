import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/reference.dart';
import '../core/theme.dart';
import '../providers/rig_provider.dart';
import '../widgets/vehicle_plan.dart' show kindColour, runColour;

/// What the whole thing is wired like: every box, every run between them, and the port the run
/// lands on. The page this replaced drew the connectors themselves in detail, which is the wrong
/// question -- on the vehicle nobody asks what a cavity looks like, they ask what is plugged into
/// what and which port it is.
class WiringScreen extends ConsumerStatefulWidget {
  const WiringScreen({super.key});

  @override
  ConsumerState<WiringScreen> createState() => _WiringScreenState();
}

class _WiringScreenState extends ConsumerState<WiringScreen> {
  /// false = the harness exactly as the a2z sheets draw it. true = with the KETI backbone
  /// inserted, which is a different diagram and never a reading of the sheets.
  bool _backbone = false;

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
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('CONNECTION DIAGRAM', style: Type.label),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          _backbone
                              ? 'Forward sensors aggregated by the front switch pair; the cameras stay on their own coax into the Orin.'
                              : 'Every sensor straight into an ACU port, as the sheets draw it.',
                          style: Type.tiny,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _ModeToggle(
                        backbone: _backbone,
                        onChanged: (v) => setState(() => _backbone = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _Diagram(
                      backbone: _backbone,
                      snapshot: rig.snapshot,
                      selectedId: selected,
                      onSelect: (id) {
                        ref.read(selectedNodeProvider.notifier).state = id;
                        ref.read(selectedPortProvider.notifier).state =
                            id == null ? null : nodeById(id)?.acuPort;
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _Legend(backbone: _backbone),
        ],
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  final bool backbone;
  final ValueChanged<bool> onChanged;

  const _ModeToggle({required this.backbone, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool on, VoidCallback tap) => GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            tap();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: on ? Tone.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: on
                  ? const [BoxShadow(color: Color(0x141B2A44), blurRadius: 6, offset: Offset(0, 1))]
                  : null,
            ),
            child: Text(label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: on ? Tone.ink : Tone.faint,
                )),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Tone.sunken,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Tone.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('Sheet wiring', !backbone, () => onChanged(false)),
          seg('With TSN backbone', backbone, () => onChanged(true)),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final bool backbone;

  const _Legend({required this.backbone});

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String label, {bool dashed = false}) => Padding(
          padding: const EdgeInsets.only(right: 18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(size: const Size(20, 3), painter: _Swatch(c, dashed)),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(fontSize: 11, color: Tone.muted)),
            ],
          ),
        );

    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          item(Tone.lidar, 'LiDAR run'),
          item(Tone.camera, 'Camera coax'),
          item(Tone.acu, 'ACU to ACU / peripheral'),
          if (backbone) item(Tone.tsn, 'TSN trunk'),
          item(Tone.hairlineStrong, 'Not on the sheets', dashed: true),
          const Spacer(),
          const Text('Port numbers are the sheet labels; tap a box for what backs them',
              style: Type.tiny),
        ],
      ),
    );
  }
}

class _Swatch extends CustomPainter {
  final Color colour;
  final bool dashed;

  _Swatch(this.colour, this.dashed);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = colour
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    if (!dashed) {
      canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), p);
      return;
    }
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, size.height / 2), Offset(x + 4, size.height / 2), p);
    }
  }

  @override
  bool shouldRepaint(covariant _Swatch old) => old.colour != colour || old.dashed != dashed;
}

// ---------------------------------------------------------------------------
// The diagram
// ---------------------------------------------------------------------------

/// A box in the diagram. Columns run left to right: what senses, what switches, what computes,
/// what listens.
class _Box {
  final String id;
  final String title;
  final String sub;
  final NodeKind kind;
  final int column;

  /// Offset from the column position. Used for the three switches: a column of three says
  /// nothing about which of them the traffic ends at, and a triangle with the centre switch on
  /// its own apex says it at a glance.
  final Offset nudge;

  const _Box(this.id, this.title, this.sub, this.kind, this.column,
      {this.nudge = Offset.zero});
}

/// A run between two boxes. [port] is the sheet's own label for where it lands.
class _Run {
  final String from;
  final String to;
  final String? port;
  final String? rate;
  final Color colour;

  /// A run the sheets do not draw: the KETI trunks, and the side LiDARs that terminate nowhere.
  final bool dashed;

  /// Which rig key carries this run's state, if any.
  final String? stateKey;

  /// Set on the three inter-switch links: each has an inline injection module the tablet can open.
  final int? path;
  final bool injector;

  /// False where the module is expected but not confirmed on the rig.
  final bool confirmed;

  const _Run(
    this.from,
    this.to, {
    this.port,
    this.rate,
    this.colour = Tone.acu,
    this.dashed = false,
    this.stateKey,
    this.path,
    this.injector = false,
    this.confirmed = true,
  });
}

const _boxes = <_Box>[
  _Box('fk_front', 'Falcon K1 F', 'roof front', NodeKind.lidar, 0),
  _Box('hb_front', 'Hummingbird F', 'front fascia', NodeKind.lidar, 0),
  _Box('lidar_rh', 'Side LiDAR RH', 'roof edge', NodeKind.lidar, 0),
  _Box('lidar_lh', 'Side LiDAR LH', 'roof edge', NodeKind.lidar, 0),
  _Box('fk_rear', 'Falcon K1 R', 'roof rear', NodeKind.lidar, 0),
  _Box('hb_rear', 'Hummingbird R', 'rear fascia', NodeKind.lidar, 0),
  _Box('cameras', '10 cameras', 'CAM 1-5 · direct to Orin', NodeKind.camera, 0),
  // Ordered A, R, B so the column puts the centre switch between the two front ones; the nudges
  // then pull the pair back and push the centre forward, giving the triangle.
  _Box('tsn_fa', 'TSN-F A', 'front, path 1', NodeKind.tsn, 1, nudge: Offset(-70, 0)),
  _Box('tsn_r', 'TSN-R', 'centre · to ACU_IT', NodeKind.tsn, 1, nudge: Offset(96, 0)),
  _Box('tsn_fb', 'TSN-F B', 'front, path 2', NodeKind.tsn, 1, nudge: Offset(-70, 0)),
  _Box('acu_it', 'ACU_IT', '3 connectors, 10 ports', NodeKind.acu, 2),
  _Box('acu_no', 'ACU_NO', '5 jacks, 4-way LAN', NodeKind.acu, 2),
  _Box('display', 'DISPLAY', 'cabin', NodeKind.display, 3),
  _Box('tcu_m', 'TCU_M', 'telematics, main', NodeKind.tcu, 3),
  _Box('tcu_s', 'TCU_S', 'telematics, sub', NodeKind.tcu, 3),
];

/// The harness as the sheets draw it.
List<_Run> _sheetRuns() => [
      for (final n in lidarNodes.where((n) => n.acuPort != null))
        _Run(n.id, 'acu_it',
            port: n.acuPort,
            rate: portById(n.acuPort!)!.speed.value.replaceAll('BASE-T1', 'B-T1'),
            colour: Tone.lidar,
            stateKey: n.acuPort),
      const _Run('cameras', 'acu_no',
          port: 'CAM 1-5', rate: '10 feeds', colour: Tone.camera, stateKey: 'CAM 1'),
      const _Run('acu_no', 'acu_it', port: '1-1', rate: '10GB-T1', stateKey: '1-1'),
      const _Run('acu_no', 'acu_it', port: '1-2', rate: '1000B-T1', stateKey: '1-2'),
      const _Run('acu_no', 'tcu_m', port: 'LAN', rate: '2x 1G · Orin A/B', stateKey: 'lan0'),
      const _Run('acu_it', 'display', port: '2-1', rate: '1000B-T1', stateKey: '2-1'),
      const _Run('acu_it', 'tcu_m', port: '2-2', rate: '1000B-T1', stateKey: '2-2'),
      const _Run('acu_it', 'tcu_s', port: '1-4', rate: '1000B-T1', stateKey: '1-4'),
      // The two side units have part numbers and outlines and nothing else. Drawn reaching for a
      // port that the document set never names.
      const _Run('lidar_lh', 'acu_it', port: '?', rate: 'no port named', colour: Tone.lidar, dashed: true),
      const _Run('lidar_rh', 'acu_it', port: '?', rate: 'no port named', colour: Tone.lidar, dashed: true),
    ];

/// The same harness with the KETI backbone inserted: the forward sensors are aggregated by the
/// front pair, the three switches are linked to each other, and each of those three links has an
/// injection module in it.
List<_Run> _backboneRuns() => [
      const _Run('fk_front', 'tsn_fa', colour: Tone.lidar, dashed: true),
      const _Run('hb_front', 'tsn_fa', colour: Tone.lidar, dashed: true),
      const _Run('lidar_rh', 'tsn_fa', colour: Tone.lidar, dashed: true),
      const _Run('lidar_lh', 'tsn_fb', colour: Tone.lidar, dashed: true),
      const _Run('fk_rear', 'tsn_r', colour: Tone.lidar, dashed: true),
      const _Run('hb_rear', 'tsn_r', colour: Tone.lidar, dashed: true),
      const _Run('cameras', 'acu_no', port: 'CAM 1-5', rate: 'direct to Orin', colour: Tone.camera, stateKey: 'CAM 1'),
      for (final t in tsnTrunks)
        _Run(
          t.from,
          t.to,
          port: t.path == null ? 'trunk' : 'Path ${t.path}',
          rate: t.injector
              ? (t.confirmed ? 'injection module' : 'module not confirmed')
              : 'to ACU_IT',
          colour: Tone.tsn,
          dashed: true,
          stateKey: t.path == null ? 'trunk' : 'path${t.path}',
          path: t.path,
          injector: t.injector,
          confirmed: t.confirmed,
        ),
      const _Run('acu_no', 'acu_it', port: '1-1', rate: '10GB-T1', stateKey: '1-1'),
      const _Run('acu_it', 'display', port: '2-1', rate: '1000B-T1', stateKey: '2-1'),
      const _Run('acu_it', 'tcu_m', port: '2-2', rate: '1000B-T1', stateKey: '2-2'),
      const _Run('acu_it', 'tcu_s', port: '1-4', rate: '1000B-T1', stateKey: '1-4'),
    ];

/// One run, resolved to screen geometry. Built once per layout so the painter and the injection
/// module buttons sit on exactly the same curve.
class _Wire {
  final _Run run;
  final Offset start;
  final Offset end;
  final bool forward;
  final Path path;
  final Offset mid;

  _Wire({
    required this.run,
    required this.start,
    required this.end,
    required this.forward,
    required this.path,
    required this.mid,
  });
}

class _Diagram extends ConsumerWidget {
  final bool backbone;
  final RigSnapshot snapshot;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  const _Diagram({
    required this.backbone,
    required this.snapshot,
    required this.selectedId,
    required this.onSelect,
  });

  static const _cardW = 168.0;
  static const _cardH = 46.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = backbone ? _backboneRuns() : _sheetRuns();
    // In sheet mode the switches are not on the vehicle as far as the document is concerned, so
    // they are simply absent rather than drawn and disclaimed.
    final boxes = _boxes.where((b) => backbone || b.kind != NodeKind.tsn).toList();

    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final rects = _layout(boxes, size);
        final wires = _wires(runs, rects);
        final rig = ref.watch(rigProvider);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _RunPainter(
                  wires: wires,
                  snapshot: snapshot,
                  selectedId: selectedId,
                  blocked: rects.values.toList(),
                ),
              ),
            ),
            for (final b in boxes)
              Positioned.fromRect(
                rect: rects[b.id]!,
                child: _Card(
                  box: b,
                  selected: b.id == selectedId,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onSelect(b.id == selectedId ? null : b.id);
                  },
                ),
              ),
            // The injection modules sit on the link they can open, because that is where the
            // hand goes: you point at the run you want gone.
            for (final w in wires.where((w) => w.run.injector))
              Positioned(
                left: w.mid.dx - 39,
                top: w.mid.dy - 15,
                width: 78,
                height: 30,
                child: _Injector(
                  path: w.run.path!,
                  cut: rig.isCut(w.run.path!),
                  confirmed: w.run.confirmed,
                  live: rig.mode == RigMode.simulated,
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    ref.read(rigProvider).toggleCut(w.run.path!);
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  Map<String, Rect> _layout(List<_Box> boxes, Size size) {
    final columns = <int, List<_Box>>{};
    for (final b in boxes) {
      (columns[b.column] ??= []).add(b);
    }
    final used = columns.keys.toList()..sort();
    final rects = <String, Rect>{};
    for (var i = 0; i < used.length; i++) {
      final col = columns[used[i]]!;
      final cx = used.length == 1
          ? size.width / 2
          : _cardW / 2 + i * (size.width - _cardW) / (used.length - 1);
      final gap = col.length < 2
          ? 0.0
          : ((size.height - col.length * _cardH) / (col.length + 1)).clamp(12.0, 44.0);
      final span = col.length * _cardH + (col.length - 1) * gap;
      var y = (size.height - span) / 2;
      for (final b in col) {
        rects[b.id] =
            Rect.fromLTWH(cx - _cardW / 2 + b.nudge.dx, y + b.nudge.dy, _cardW, _cardH);
        y += _cardH + gap;
      }
    }
    return rects;
  }

  List<_Wire> _wires(List<_Run> runs, Map<String, Rect> rects) {
    // Fan the ends so two runs between the same pair of boxes do not lie on top of each other.
    final outCount = <String, int>{}, inCount = <String, int>{};
    for (final r in runs) {
      if (!rects.containsKey(r.from) || !rects.containsKey(r.to)) continue;
      outCount[r.from] = (outCount[r.from] ?? 0) + 1;
      inCount[r.to] = (inCount[r.to] ?? 0) + 1;
    }
    final outSeen = <String, int>{}, inSeen = <String, int>{};
    final wires = <_Wire>[];

    double slot(Rect rect, int index, int total) {
      if (total <= 1) return rect.center.dy;
      final span = rect.height * 0.56;
      return rect.center.dy - span / 2 + index * span / (total - 1);
    }

    for (final r in runs) {
      final a = rects[r.from], b = rects[r.to];
      if (a == null || b == null) continue;
      final oi = outSeen[r.from] = (outSeen[r.from] ?? -1) + 1;
      final ii = inSeen[r.to] = (inSeen[r.to] ?? -1) + 1;
      final forward = b.center.dx >= a.center.dx;
      // A link between two boxes in the same column leaves and returns on the same side.
      final sameColumn = (a.center.dx - b.center.dx).abs() < 1;
      final start = sameColumn
          ? Offset(a.left, a.center.dy)
          : Offset(forward ? a.right : a.left, slot(a, oi, outCount[r.from]!));
      final end = sameColumn
          ? Offset(b.left, b.center.dy)
          : Offset(forward ? b.left : b.right, slot(b, ii, inCount[r.to]!));

      // A link between two boxes in the same column leaves and returns on the same side, so its
      // handles both point the same way; the bulge is what carries the injection module.
      final dx = sameColumn ? 44.0 : (end.dx - start.dx).abs().clamp(40.0, 150.0);
      final c1 = Offset(start.dx + (sameColumn ? -dx : (forward ? dx : -dx)), start.dy);
      final c2 = Offset(end.dx + (sameColumn ? -dx : (forward ? -dx : dx)), end.dy);
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
      // The cubic at t = 0.5, in closed form; cheaper and steadier than walking the metric.
      final mid = (start + c1 * 3 + c2 * 3 + end) / 8;
      wires.add(_Wire(run: r, start: start, end: end, forward: forward, path: path, mid: mid));
    }
    return wires;
  }
}

/// The inline fault-injection module, as a button. Tapping it opens or closes the relay in that
/// link -- the one control on this page that changes the vehicle rather than the view.
class _Injector extends StatelessWidget {
  final int path;
  final bool cut;
  final bool live;
  final bool confirmed;
  final VoidCallback onTap;

  const _Injector({
    required this.path,
    required this.cut,
    required this.live,
    required this.confirmed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colour = cut ? Tone.bad : (confirmed ? Tone.tsn : Tone.warn);
    return Tooltip(
      message: !confirmed
          ? 'A module on this link is expected but not confirmed on the rig.'
          : live
              ? (cut ? 'Path $path is open. Tap to restore.' : 'Tap to open path $path.')
              : 'No rig attached — switch to DEMO to cut a path.',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: live ? onTap : null,
          child: Container(
            decoration: BoxDecoration(
              color: cut ? Tone.bad.withValues(alpha: 0.12) : Tone.surface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: colour.withValues(alpha: live ? 0.8 : 0.45)),
              boxShadow: const [
                BoxShadow(color: Color(0x141B2A44), blurRadius: 8, offset: Offset(0, 2)),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(cut ? Icons.link_off : Icons.electrical_services_outlined,
                    size: 14, color: colour.withValues(alpha: live ? 1 : 0.55)),
                const SizedBox(width: 6),
                Text(
                  cut ? 'CUT' : (confirmed ? 'INJ $path' : 'INJ $path?'),
                  style: Type.monoAt(10.5,
                      weight: FontWeight.w800, colour: colour.withValues(alpha: live ? 1 : 0.55)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final _Box box;
  final bool selected;
  final VoidCallback onTap;

  const _Card({required this.box, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colour = kindColour(box.kind);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? colour : Tone.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? colour : Tone.hairline,
              width: selected ? 1.6 : 1,
            ),
            boxShadow: const [
              BoxShadow(color: Color(0x0F1B2A44), blurRadius: 10, offset: Offset(0, 2)),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 24,
                decoration: BoxDecoration(
                  color: selected ? Colors.white : colour,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      box.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: selected ? Colors.white : Tone.ink,
                      ),
                    ),
                    Text(
                      box.sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: selected ? Colors.white70 : Tone.faint,
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
  }
}

class _RunPainter extends CustomPainter {
  final List<_Wire> wires;
  final RigSnapshot snapshot;
  final String? selectedId;

  /// The card rectangles. A port chip that lands on a card is unreadable, and the cards are drawn
  /// on top of this painter anyway.
  final List<Rect> blocked;

  _RunPainter({
    required this.wires,
    required this.snapshot,
    required this.selectedId,
    required this.blocked,
  });

  /// Chip rectangles already committed this frame.
  final List<Rect> _taken = [];

  @override
  void paint(Canvas canvas, Size size) {
    _taken.clear();
    _taken.addAll(blocked);
    for (final w in wires) {
      final r = w.run;
      final state = r.stateKey == null ? LinkState.unknown : snapshot.link(r.stateKey!);
      final colour = runColour(state, r.colour);
      final lit = selectedId == r.from || selectedId == r.to;
      final alpha = lit ? 1.0 : (selectedId == null ? 0.62 : 0.22);

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = lit ? 2.8 : (r.injector ? 2.2 : 1.8)
        ..strokeCap = StrokeCap.round
        ..color = colour.withValues(alpha: alpha);
      canvas.drawPath(r.dashed ? _dash(w.path) : w.path, paint);

      canvas.drawCircle(w.start, lit ? 3.4 : 2.4, Paint()..color = colour.withValues(alpha: alpha));
      canvas.drawCircle(w.end, lit ? 3.4 : 2.4, Paint()..color = colour.withValues(alpha: alpha));

      // A cut run gets a real break, not just a red line: red alone reads as highlighted.
      if (state == LinkState.down && !r.injector) {
        final x = Paint()
          ..color = Tone.bad
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(w.mid + const Offset(-5, -5), w.mid + const Offset(5, 5), x);
        canvas.drawLine(w.mid + const Offset(5, -5), w.mid + const Offset(-5, 5), x);
      }

      // The injection modules carry their own label, so the port chip would only crowd them.
      if (r.port != null && !r.injector) _paintPortChip(canvas, w, colour, alpha, lit);
    }
  }

  /// The port label rides the run, near the end it lands on. That is the one fact anyone wants
  /// from a wiring diagram: which port, on which box.
  void _paintPortChip(Canvas canvas, _Wire w, Color colour, double alpha, bool lit) {
    final port = TextPainter(
      text: TextSpan(
        text: w.run.port!,
        style: Type.monoAt(10.5, weight: FontWeight.w800).copyWith(
            color: (lit ? Colors.white : colour).withValues(alpha: (alpha + 0.2).clamp(0, 1))),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rate = w.run.rate == null
        ? null
        : (TextPainter(
            text: TextSpan(
              text: w.run.rate!,
              style: Type.monoAt(9, weight: FontWeight.w600).copyWith(
                  color: (lit ? Colors.white70 : Tone.faint)
                      .withValues(alpha: (alpha + 0.2).clamp(0, 1))),
            ),
            textDirection: TextDirection.ltr,
          )..layout());

    final w0 = rate == null ? port.width : math.max(port.width, rate.width);
    final width = w0 + 16;
    final height = port.height + (rate?.height ?? 0) + 9;
    Rect? box;
    for (final t in const [0.74, 0.62, 0.50, 0.38, 0.86, 0.28]) {
      final at = _pointOn(w.path, t);
      if (at == null) continue;
      final candidate = Rect.fromCenter(center: at, width: width, height: height);
      if (_taken.any((r) => r.overlaps(candidate))) continue;
      if (blocked.any((r) => r.overlaps(candidate))) continue;
      box = candidate;
      break;
    }
    if (box == null) return; // nowhere clear to put it; a chip on top of a card says nothing
    _taken.add(box.inflate(2));
    final rr = RRect.fromRectAndRadius(box, const Radius.circular(7));
    canvas.drawRRect(
      rr,
      Paint()..color = (lit ? colour : Tone.surface).withValues(alpha: lit ? 1 : 0.94),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = (lit ? colour : Tone.hairline).withValues(alpha: (alpha + 0.3).clamp(0, 1)),
    );
    port.paint(canvas, Offset(box.left + 8, box.top + 4));
    rate?.paint(canvas, Offset(box.left + 8, box.top + 4 + port.height));
  }

  Path _dash(Path source) {
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = (d + 7).clamp(0.0, metric.length);
        out.addPath(metric.extractPath(d, end), Offset.zero);
        d += 12;
      }
    }
    return out;
  }

  Offset? _pointOn(Path path, double t) {
    for (final m in path.computeMetrics()) {
      return m.getTangentForOffset(m.length * t)?.position;
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant _RunPainter old) =>
      old.selectedId != selectedId ||
      old.snapshot != snapshot ||
      old.wires.length != wires.length ||
      old.wires.isNotEmpty && wires.isNotEmpty && old.wires.first.start != wires.first.start;
}
