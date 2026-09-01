import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/traffic_gen_provider.dart';
import 'switch_console_screen.dart';

/// Show mode — the demo's hero. A live 3-switch FRER ring with one big
/// PROTECTED / DEGRADED verdict, driven by chapter buttons that run the story.
///
/// Topology (rear switch C is the hub): the video on A reaches the receiver on
/// C over TWO disjoint routes — the **direct** link A→C and the **detour**
/// A→B→C. FRER replicates over both, so cutting any single link keeps the video
/// alive. B is the detour zone and also carries the flood. The detailed
/// CBS/TAS/FRER config lives behind the gear.
class ShowScreen extends ConsumerStatefulWidget {
  const ShowScreen({super.key});
  @override
  ConsumerState<ShowScreen> createState() => _ShowScreenState();
}

// Three D10s: A=.1 (video zone), B=.2 (detour + flood), C=.4 rear (receiver).
const _swA = 'D10-1', _swB = 'D10-2', _swC = 'D10-4 · rear';

// Colours
const _bg = Color(0xFF0E1117);
const _card = Color(0xFF1A1F29);
const _indigo = Color(0xFF7C7CFF);
const _blue = Color(0xFF6F97B3);
const _amber = Color(0xFFC69256);
const _green = Color(0xFF5FA87F);
const _flowUp = Color(0xFF44CC77);
const _flowIdle = Color(0xFF3A6B57);
const _bad = Color(0xFFCF6A60);
const _floodC = Color(0xFFE0B050);

class _ShowScreenState extends ConsumerState<ShowScreen> {
  bool _flood = false;
  bool _cbs = false;
  bool _frer = true;
  final _cut = <int>{}; // 0 = direct A-C, 1 = detour A-B-C

  Future<void> _send(String c) => ref.read(trafficGenProvider.notifier).sendControl(c);

  bool get _protected {
    if (_flood && !_cbs) return false;       // flood starves the video queue
    if (_cut.length >= 2) return false;       // both routes gone
    if (_cut.isNotEmpty && !_frer) return false; // a route down and no redundancy
    return true;
  }

  Future<void> _run(List<String> cmds, VoidCallback local) async {
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
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 16, 8),
              child: Row(
                children: [
                  const Text('KETI TSN',
                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 1)),
                  const SizedBox(width: 10),
                  Text(tg.link == TgLink.online ? '● live' : '○ offline',
                      style: TextStyle(
                          color: tg.link == TgLink.online ? _flowUp : const Color(0xFF5A6472),
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
            Expanded(
              child: LayoutBuilder(builder: (_, c) {
                final s = c.biggest;
                return CustomPaint(
                  painter: _RingPainter(cut: _cut, flood: _flood, protected: ok, frer: _frer),
                  child: Stack(children: _nodes(s)),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
              child: Wrap(
                spacing: 10, runSpacing: 10, alignment: WrapAlignment.center,
                children: [
                  _Chapter('Normal', Icons.check_circle_outline, () => _run(
                      ['stop', 'restore:1', 'restore:2', 'frer:on'],
                      () { _flood = false; _cbs = false; _frer = true; _cut.clear(); })),
                  _Chapter('Flood', Icons.warning_amber, () => _run(
                      ['cbs:off', 'start'], () { _flood = true; _cbs = false; })),
                  _Chapter('Protect · CBS', Icons.shield_outlined, () => _run(
                      ['cbs:mbps:250', 'cbs:on', 'start'], () { _flood = true; _cbs = true; })),
                  _Chapter('Cut a route', Icons.link_off, () => _run(
                      [_cut.contains(0) ? 'cut:2' : 'cut:1'],
                      () { _cut.add(_cut.contains(0) ? 1 : 0); })),
                  _Chapter('FRER off', Icons.shuffle_on_outlined, () => _run(
                      ['frer:off'], () => _frer = false)),
                  _Chapter('Restore', Icons.link, () => _run(
                      ['restore:1', 'restore:2', 'frer:on'], () { _cut.clear(); _frer = true; })),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Fractional positions shared with the painter.
  static const _pos = {
    'video': Offset(0.07, 0.30),
    'A': Offset(0.27, 0.30),
    'C': Offset(0.63, 0.30),
    'recv': Offset(0.90, 0.30),
    'B': Offset(0.45, 0.74),
    'flood': Offset(0.16, 0.74),
  };

  List<Widget> _nodes(Size s) {
    final specs = <String, _NodeSpec>{
      'video': _NodeSpec('Video Pi', _blue, Icons.videocam),
      'A': _NodeSpec(_swA, _indigo, Icons.developer_board),
      'C': _NodeSpec(_swC, _indigo, Icons.developer_board),
      'recv': _NodeSpec('Receiver Pi', _green, Icons.smart_display),
      'B': _NodeSpec(_swB, _indigo, Icons.developer_board),
      'flood': _NodeSpec('Flood Pi', _amber, Icons.bolt),
    };
    return [
      for (final e in _pos.entries)
        Positioned(
          left: e.value.dx * s.width - 58,
          top: e.value.dy * s.height - 30,
          child: _Node(spec: specs[e.key]!),
        ),
    ];
  }
}

class _NodeSpec {
  const _NodeSpec(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;
}

class _Node extends StatelessWidget {
  const _Node({required this.spec});
  final _NodeSpec spec;
  @override
  Widget build(BuildContext context) => Container(
        width: 116,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: spec.color.withValues(alpha: 0.6), width: 1.4),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(spec.icon, color: spec.color, size: 22),
          const SizedBox(height: 5),
          Text(spec.label, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.cut, required this.flood, required this.protected, required this.frer});
  final Set<int> cut;
  final bool flood, protected, frer;

  Offset _p(Size s, String k) {
    final o = _ShowScreenState._pos[k]!;
    return Offset(o.dx * s.width, o.dy * s.height);
  }

  @override
  void paint(Canvas canvas, Size s) {
    final video = _p(s, 'video'), a = _p(s, 'A'), b = _p(s, 'B'),
        c = _p(s, 'C'), recv = _p(s, 'recv'), floodPi = _p(s, 'flood');

    Paint pen(Color col, [double w = 3.2]) =>
        Paint()..color = col..strokeWidth = w..strokeCap = StrokeCap.round;

    final directDown = cut.contains(0);
    final detourDown = cut.contains(1);

    // feeders
    canvas.drawLine(video, a, pen(_flowUp));
    canvas.drawLine(floodPi, b, pen(flood ? _floodC : _flowIdle));
    // DIRECT route A→C
    canvas.drawLine(a, c, pen(directDown ? _bad : _flowUp, 3.4));
    // DETOUR route A→B→C
    canvas.drawLine(a, b, pen(detourDown ? _bad : _flowUp, 3.4));
    canvas.drawLine(b, c, pen(detourDown ? _bad : _flowUp, 3.4));
    if (directDown) _x(canvas, Offset.lerp(a, c, 0.5)!);
    if (detourDown) _x(canvas, Offset.lerp(a, b, 0.5)!);
    // delivery C→receiver
    canvas.drawLine(c, recv, pen(protected ? _flowUp : _bad, 3.6));

    // route legend near the direct link
    final tp = TextPainter(
      text: TextSpan(
          text: 'direct',
          style: TextStyle(color: (directDown ? _bad : _flowUp).withValues(alpha: 0.9), fontSize: 11, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset.lerp(a, c, 0.5)! + const Offset(-18, -22));
    final tp2 = TextPainter(
      text: TextSpan(
          text: 'detour',
          style: TextStyle(color: (detourDown ? _bad : _flowUp).withValues(alpha: 0.9), fontSize: 11, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr)
      ..layout();
    tp2.paint(canvas, Offset.lerp(a, b, 0.5)! + const Offset(6, 4));
  }

  void _x(Canvas canvas, Offset o) {
    final p = Paint()..color = _bad..strokeWidth = 3..strokeCap = StrokeCap.round;
    canvas.drawLine(o + const Offset(-7, -7), o + const Offset(7, 7), p);
    canvas.drawLine(o + const Offset(7, -7), o + const Offset(-7, 7), p);
  }

  @override
  bool shouldRepaint(_RingPainter o) =>
      o.cut != cut || o.flood != flood || o.protected != protected || o.frer != frer;
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.protected, required this.rx});
  final bool protected;
  final int rx;
  @override
  Widget build(BuildContext context) {
    final col = protected ? _flowUp : _bad;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: col.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: col, width: 1.4),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(protected ? Icons.verified : Icons.error_outline, color: col, size: 18),
        const SizedBox(width: 8),
        Text(protected ? 'PROTECTED' : 'DEGRADED',
            style: TextStyle(color: col, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
        const SizedBox(width: 10),
        Text('video $rx Mbps',
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
            color: _card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2A313D)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: _indigo, size: 18),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}
