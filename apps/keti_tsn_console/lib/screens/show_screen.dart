import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/traffic_gen_provider.dart';
import '../providers/keti_link_provider.dart';
import 'switch_console_screen.dart';

/// Show mode — the demo's hero, Apple-grade light theme. A 3-switch FRER ring
/// drawn as a clean upright triangle: the rear switch C is the apex (receiver
/// hangs off it); the video zone A and the detour zone B form the base. The
/// video on A reaches C over the DIRECT edge A→C and the DETOUR A→B→C, so any
/// single cut is survived. One big PROTECTED / DEGRADED verdict; chapter buttons
/// run the story; the detailed config lives behind the gear.
class ShowScreen extends ConsumerStatefulWidget {
  const ShowScreen({super.key});
  @override
  ConsumerState<ShowScreen> createState() => _ShowScreenState();
}

// Three D10s.  A=.1 video · B=.2 detour+flood · C=.4 rear/receiver.
const _swA = 'D10-1', _swB = 'D10-2', _swC = 'D10-4';

// Apple palette (light).
const _bg = Color(0xFFF5F5F7);
const _ink = Color(0xFF1D1D1F);
const _ink2 = Color(0xFF6E6E73);
const _blue = Color(0xFF007AFF);
const _green = Color(0xFF34C759);
const _red = Color(0xFFFF3B30);
const _orange = Color(0xFFFF9500);
const _idle = Color(0xFFD2D2D7);

class _ShowScreenState extends ConsumerState<ShowScreen> {
  bool _flood = false, _cbs = false, _frer = true;
  final _cut = <int>{}; // 0 = direct A-C, 1 = detour A-B-C

  Future<void> _send(String c) => ref.read(trafficGenProvider.notifier).sendControl(c);

  // The two injection modules (KETI-PATH1/PATH2) sit inline on the rear ring legs
  // and physically open a relay -- a real cable fault, not a switch port shutdown.
  // Provisional map (which module lands on which leg is decided at install time,
  // and the Pi reports the actual faulted leg back over the path GATT):
  //   inject 1 -> route 0 = DIRECT  A->C
  //   inject 2 -> route 1 = DETOUR  B->C
  void _inject(int path, bool fault) =>
      ref.read(ketiLinkServiceProvider).setPathFault(path, fault);

  Future<void> _cutRoute(int route, int path) {
    final fault = !_cut.contains(route);
    _inject(path, fault);                                    // drive the physical module
    return _run([fault ? 'cut:$path' : 'restore:$path'],     // + switch-side, belt & suspenders
        () => fault ? _cut.add(route) : _cut.remove(route));
  }

  bool get _protected {
    if (_flood && !_cbs) return false;
    if (_cut.length >= 2) return false;
    if (_cut.isNotEmpty && !_frer) return false;
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
              padding: const EdgeInsets.fromLTRB(28, 20, 20, 6),
              child: Row(
                children: [
                  const Text('KETI TSN',
                      style: TextStyle(color: _ink, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                        color: (tg.link == TgLink.online ? _green : _ink2).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(tg.link == TgLink.online ? 'live' : 'offline',
                        style: TextStyle(
                            color: tg.link == TgLink.online ? _green : _ink2,
                            fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ),
                  const Spacer(),
                  _Verdict(protected: ok, rx: ok ? 250 : (_flood ? 40 : 0)),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.tune_rounded, color: _ink2),
                    tooltip: 'Config',
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SwitchConsoleScreen())),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(builder: (_, c) {
                return CustomPaint(
                  painter: _RingPainter(cut: _cut, flood: _flood, protected: ok),
                  child: Stack(children: _nodes(c.biggest)),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
              child: Wrap(
                spacing: 12, runSpacing: 12, alignment: WrapAlignment.center,
                children: [
                  _Chapter('Normal', Icons.check_circle_rounded, false, () {
                    _inject(1, false); _inject(2, false);
                    _run(['stop', 'restore:1', 'restore:2', 'frer:on'],
                        () { _flood = false; _cbs = false; _frer = true; _cut.clear(); });
                  }),
                  _Chapter('Flood', Icons.bolt_rounded, false, () => _run(
                      ['cbs:off', 'start'], () { _flood = true; _cbs = false; })),
                  _Chapter('Protect · CBS', Icons.shield_rounded, true, () => _run(
                      ['cbs:mbps:250', 'cbs:on', 'start'], () { _flood = true; _cbs = true; })),
                  _Chapter('Cut · inject 1', Icons.link_off_rounded, _cut.contains(0),
                      () => _cutRoute(0, 1)),
                  _Chapter('Cut · inject 2', Icons.link_off_rounded, _cut.contains(1),
                      () => _cutRoute(1, 2)),
                  _Chapter('FRER off', Icons.shuffle_rounded, false, () => _run(
                      ['frer:off'], () => _frer = false)),
                  _Chapter('Restore', Icons.restart_alt_rounded, false, () {
                    _inject(1, false); _inject(2, false);
                    _run(['restore:1', 'restore:2', 'frer:on'],
                        () { _cut.clear(); _frer = true; });
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Upright triangle: C apex (top), A & B base (bottom). Receiver above C.
  // Inverted triangle, laid out like the vehicle: D10-1 front-left and D10-2
  // front-right up top, the rear D10-4 at the bottom apex, receiver below it.
  static const _pos = {
    'video': Offset(0.08, 0.26),
    'A': Offset(0.30, 0.26),
    'B': Offset(0.70, 0.26),
    'flood': Offset(0.92, 0.26),
    'C': Offset(0.50, 0.66),
    'recv': Offset(0.50, 0.90),
  };

  List<Widget> _nodes(Size s) {
    final specs = <String, _NodeSpec>{
      'recv': _NodeSpec('Receiver Pi', _green, Icons.smart_display_rounded, false),
      'C': _NodeSpec('$_swC · rear', _blue, Icons.dns_rounded, true),
      'A': _NodeSpec('$_swA · front-L', _blue, Icons.dns_rounded, true),
      'B': _NodeSpec('$_swB · front-R', _blue, Icons.dns_rounded, true),
      'video': _NodeSpec('Video Pi', _ink, Icons.videocam_rounded, false),
      'flood': _NodeSpec('Flood Pi', _orange, Icons.bolt_rounded, false),
    };
    return [
      for (final e in _pos.entries)
        Positioned(
          left: e.value.dx * s.width - 60,
          top: e.value.dy * s.height - 32,
          child: _Node(spec: specs[e.key]!),
        ),
    ];
  }
}

class _NodeSpec {
  const _NodeSpec(this.label, this.color, this.icon, this.isSwitch);
  final String label;
  final Color color;
  final IconData icon;
  final bool isSwitch;
}

class _Node extends StatelessWidget {
  const _Node({required this.spec});
  final _NodeSpec spec;
  @override
  Widget build(BuildContext context) => Container(
        width: 120,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, 6))],
          border: Border.all(color: spec.isSwitch ? _blue.withValues(alpha: 0.25) : const Color(0xFFECECEE)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(color: spec.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(spec.icon, color: spec.color, size: 20),
          ),
          const SizedBox(height: 7),
          Text(spec.label, textAlign: TextAlign.center,
              style: const TextStyle(color: _ink, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.cut, required this.flood, required this.protected});
  final Set<int> cut;
  final bool flood, protected;

  Offset _p(Size s, String k) {
    final o = _ShowScreenState._pos[k]!;
    return Offset(o.dx * s.width, o.dy * s.height);
  }

  @override
  void paint(Canvas canvas, Size s) {
    final video = _p(s, 'video'), a = _p(s, 'A'), b = _p(s, 'B'),
        c = _p(s, 'C'), recv = _p(s, 'recv'), floodPi = _p(s, 'flood');
    Paint pen(Color col, [double w = 4]) =>
        Paint()..color = col..strokeWidth = w..strokeCap = StrokeCap.round;

    final directDown = cut.contains(0), detourDown = cut.contains(1);

    canvas.drawLine(video, a, pen(_green));
    canvas.drawLine(floodPi, b, pen(flood ? _orange : _idle));
    canvas.drawLine(a, c, pen(directDown ? _red : _green));         // DIRECT (left edge)
    canvas.drawLine(a, b, pen(detourDown ? _red : _green));         // DETOUR base
    canvas.drawLine(b, c, pen(detourDown ? _red : _green));         // DETOUR right edge
    canvas.drawLine(c, recv, pen(protected ? _green : _red, 4.5));  // delivery
    if (directDown) _x(canvas, Offset.lerp(a, c, 0.5)!);
    if (detourDown) _x(canvas, Offset.lerp(b, c, 0.5)!);

    _label(canvas, 'direct', Offset.lerp(a, c, 0.45)! + const Offset(-40, -6), directDown ? _red : _green);
    _label(canvas, 'detour', Offset.lerp(a, b, 0.5)! + const Offset(-16, 8), detourDown ? _red : _green);
  }

  void _label(Canvas canvas, String t, Offset o, Color col) {
    final tp = TextPainter(
        text: TextSpan(text: t, style: TextStyle(color: col, fontSize: 11.5, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, o);
  }

  void _x(Canvas canvas, Offset o) {
    final bg = Paint()..color = _bg;
    canvas.drawCircle(o, 11, bg);
    final p = Paint()..color = _red..strokeWidth = 3..strokeCap = StrokeCap.round;
    canvas.drawLine(o + const Offset(-6, -6), o + const Offset(6, 6), p);
    canvas.drawLine(o + const Offset(6, -6), o + const Offset(-6, 6), p);
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.cut != cut || o.flood != flood || o.protected != protected;
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.protected, required this.rx});
  final bool protected;
  final int rx;
  @override
  Widget build(BuildContext context) {
    final col = protected ? _green : _red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 14, offset: Offset(0, 5))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(protected ? Icons.verified_rounded : Icons.error_rounded, color: col, size: 19),
        const SizedBox(width: 9),
        Text(protected ? 'PROTECTED' : 'DEGRADED',
            style: TextStyle(color: col, fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
        const SizedBox(width: 10),
        Text('video $rx Mbps', style: const TextStyle(color: _ink2, fontSize: 12.5, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

class _Chapter extends StatelessWidget {
  const _Chapter(this.label, this.icon, this.primary, this.onTap);
  final String label;
  final IconData icon;
  final bool primary;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          decoration: BoxDecoration(
            color: primary ? _blue : Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 10, offset: Offset(0, 3))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: primary ? Colors.white : _blue, size: 19),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    color: primary ? Colors.white : _ink, fontSize: 14, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}
