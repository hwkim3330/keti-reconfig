import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/traffic_gen_provider.dart';
import 'switch_console_screen.dart';

/// Show mode — the demo's hero. A live network topology (the Pis + the D10
/// switches + their links) with one big PROTECTED / DEGRADED verdict, driven by
/// chapter buttons that run the TSN story. The detailed config lives behind the
/// gear (the console). Switches are data-driven so a 3rd D10 is one list entry.
class ShowScreen extends ConsumerStatefulWidget {
  const ShowScreen({super.key});
  @override
  ConsumerState<ShowScreen> createState() => _ShowScreenState();
}

/// The switches on the FRER ring, in order. Add the 3rd D10 here later.
const _switches = ['D10-1', 'D10-2'];

class _ShowScreenState extends ConsumerState<ShowScreen> {
  // Local demo state — drives the topology + verdict. (Live D10 state over BLE
  // status can fold in later; for the show the chapter you ran is the truth.)
  bool _flood = false;
  bool _cbs = false;
  bool _frer = true;
  final _cut = <int>{}; // which ring links are cut: 0 = upper, 1 = lower

  Future<void> _send(String c) => ref.read(trafficGenProvider.notifier).sendControl(c);

  bool get _protected {
    // Flood without CBS starves the video; a cut link without FRER breaks it.
    if (_flood && !_cbs) return false;
    if (_cut.isNotEmpty && !_frer) return false;
    if (_cut.length >= 2) return false; // both ring links gone: nothing left
    return true;
  }

  Future<void> _chapter(String name, List<String> cmds, VoidCallback local) async {
    setState(local);
    for (final c in cmds) {
      await _send(c);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tg = ref.watch(trafficGenProvider);
    final ok = _protected;
    return Scaffold(
      backgroundColor: const Color(0xFF0E1117),
      body: SafeArea(
        child: Column(
          children: [
            // ── top bar: title · verdict · gear ──────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 16, 8),
              child: Row(
                children: [
                  const Text('KETI TSN',
                      style: TextStyle(
                          color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 1)),
                  const SizedBox(width: 10),
                  Text(tg.link == TgLink.online ? '● live' : '○ offline',
                      style: TextStyle(
                          color: tg.link == TgLink.online ? const Color(0xFF44CC77) : const Color(0xFF5A6472),
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _Verdict(protected: ok, rx: ok ? 250 : (_flood ? 40 : 0)),
                  const SizedBox(width: 14),
                  IconButton(
                    icon: const Icon(Icons.tune, color: Color(0xFF9AA3B2)),
                    tooltip: 'Config',
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SwitchConsoleScreen())),
                  ),
                ],
              ),
            ),
            // ── hero: the network ────────────────────────────────────────
            Expanded(
              child: LayoutBuilder(builder: (_, c) {
                return CustomPaint(
                  painter: _TopologyPainter(cut: _cut, flood: _flood, protected: ok),
                  child: Stack(children: _nodes(c.biggest)),
                );
              }),
            ),
            // ── chapters ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _Chapter('Normal', Icons.check_circle_outline, () => _chapter(
                      'Normal', ['stop', 'restore:1', 'restore:2', 'frer:on'],
                      () { _flood = false; _cbs = false; _frer = true; _cut.clear(); })),
                  _Chapter('Flood', Icons.warning_amber, () => _chapter(
                      'Flood', ['cbs:off', 'start'], () { _flood = true; _cbs = false; })),
                  _Chapter('Protect (CBS)', Icons.shield_outlined, () => _chapter(
                      'Protect', ['cbs:mbps:250', 'cbs:on', 'start'], () { _flood = true; _cbs = true; })),
                  _Chapter('Cut link', Icons.link_off, () => _chapter(
                      'Cut', [_cut.contains(0) ? 'cut:2' : 'cut:1'],
                      () { _cut.add(_cut.contains(0) ? 1 : 0); })),
                  _Chapter('Restore', Icons.link, () => _chapter(
                      'Restore', ['restore:1', 'restore:2'], () => _cut.clear())),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Node cards positioned by fraction; the painter uses the same fractions.
  List<Widget> _nodes(Size s) {
    final n = <_NodeSpec>[
      _NodeSpec('Video Pi', 0.09, 0.24, const Color(0xFF6F97B3), Icons.videocam),
      _NodeSpec('Sender Pi', 0.09, 0.74, const Color(0xFFC69256), Icons.bolt),
      for (var i = 0; i < _switches.length; i++)
        _NodeSpec(_switches[i], 0.34 + i * 0.24, 0.5, const Color(0xFF7C7CFF), Icons.developer_board),
      _NodeSpec('Receiver Pi', 0.9, 0.5, const Color(0xFF5FA87F), Icons.smart_display),
    ];
    return [
      for (final sp in n)
        Positioned(
          left: sp.fx * s.width - 55,
          top: sp.fy * s.height - 30,
          child: _Node(spec: sp),
        ),
    ];
  }
}

class _NodeSpec {
  const _NodeSpec(this.label, this.fx, this.fy, this.color, this.icon);
  final String label;
  final double fx, fy;
  final Color color;
  final IconData icon;
}

class _Node extends StatelessWidget {
  const _Node({required this.spec});
  final _NodeSpec spec;
  @override
  Widget build(BuildContext context) => Container(
        width: 110,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1F29),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: spec.color.withOpacity(0.6), width: 1.4),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(spec.icon, color: spec.color, size: 22),
          const SizedBox(height: 5),
          Text(spec.label,
              style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Draws the links between the fixed fractional node positions.
class _TopologyPainter extends CustomPainter {
  _TopologyPainter({required this.cut, required this.flood, required this.protected});
  final Set<int> cut;
  final bool flood;
  final bool protected;

  Offset _p(Size s, double fx, double fy) => Offset(fx * s.width, fy * s.height);

  @override
  void paint(Canvas canvas, Size s) {
    final video = _p(s, 0.09, 0.24);
    final sender = _p(s, 0.09, 0.74);
    final sw1 = _p(s, 0.34, 0.5);
    final sw2 = _p(s, 0.34 + (_switchesLen - 1) * 0.24, 0.5);
    final recv = _p(s, 0.9, 0.5);

    Paint line(Color c, {double w = 3}) =>
        Paint()..color = c..strokeWidth = w..strokeCap = StrokeCap.round;

    const up = Color(0xFF3A6B57);       // idle link
    const flow = Color(0xFF44CC77);     // active/protected flow
    const bad = Color(0xFFCF6A60);      // cut / flooded
    const amber = Color(0xFFE0B050);    // flood

    // feeders
    canvas.drawLine(video, sw1, line(flow));
    canvas.drawLine(sender, sw1, line(flood ? amber : up));
    // ring links sw1<->sw2 (upper + lower)
    final upA = sw1 + const Offset(0, -22), upB = sw2 + const Offset(0, -22);
    final loA = sw1 + const Offset(0, 22), loB = sw2 + const Offset(0, 22);
    canvas.drawLine(upA, upB, line(cut.contains(0) ? bad : flow, w: 3));
    canvas.drawLine(loA, loB, line(cut.contains(1) ? bad : flow, w: 3));
    if (cut.contains(0)) _x(canvas, (upA + upB) / 2, bad);
    if (cut.contains(1)) _x(canvas, (loA + loB) / 2, bad);
    // sw2 -> receiver
    canvas.drawLine(sw2, recv, line(protected ? flow : bad, w: 3.5));
  }

  double get _switchesLen => _switches.length.toDouble();

  void _x(Canvas canvas, Offset o, Color c) {
    final p = Paint()..color = c..strokeWidth = 3..strokeCap = StrokeCap.round;
    canvas.drawLine(o + const Offset(-7, -7), o + const Offset(7, 7), p);
    canvas.drawLine(o + const Offset(7, -7), o + const Offset(-7, 7), p);
  }

  @override
  bool shouldRepaint(_TopologyPainter old) =>
      old.cut != cut || old.flood != flood || old.protected != protected;
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.protected, required this.rx});
  final bool protected;
  final int rx;
  @override
  Widget build(BuildContext context) {
    final c = protected ? const Color(0xFF44CC77) : const Color(0xFFCF6A60);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: c.withOpacity(0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: c, width: 1.4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(protected ? Icons.verified : Icons.error_outline, color: c, size: 18),
        const SizedBox(width: 8),
        Text(protected ? 'PROTECTED' : 'DEGRADED',
            style: TextStyle(color: c, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
        const SizedBox(width: 10),
        Text('video ${rx} Mbps',
            style: const TextStyle(color: Color(0xFF9AA3B2), fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _Chapter extends StatelessWidget {
  const _Chapter(this.label, this.icon, this.onTap);
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1F29),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2A313D)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: const Color(0xFF7C7CFF), size: 18),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}
