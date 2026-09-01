import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/traffic_gen_provider.dart';
import '../providers/keti_link_provider.dart';
import '../widgets/shaper_config.dart';

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

// Refined light palette — restrained grayscale + one accent + status only.
const _bg = Color(0xFFF4F4F6);   // clean canvas
const _ink = Color(0xFF15151A);  // deep near-black for headings
const _ink2 = Color(0xFF8A8A92); // soft secondary
const _hair = Color(0xFFEAEAEF); // hairline borders / dividers
const _blue = Color(0xFF0A84FF); // the single accent
const _green = Color(0xFF2FC85A);
const _red = Color(0xFFFF453A);
const _orange = Color(0xFFF59E0B);
const _idle = Color(0xFFDADAE0);

// Soft, diffuse elevation (premium depth, not a hard drop shadow).
const _shadowSoft = [BoxShadow(color: Color(0x0A000000), blurRadius: 24, offset: Offset(0, 8))];
const _shadowCard = [BoxShadow(color: Color(0x0D000000), blurRadius: 20, offset: Offset(0, 6))];

class _ShowScreenState extends ConsumerState<ShowScreen> with SingleTickerProviderStateMixin {
  bool _flood = false, _cbs = false, _frer = true;
  final _cut = <int>{}; // 0 = direct A-C, 1 = detour A-B-C

  // Drives the flowing-dot "data path" indicators so the topology reads as live.
  late final AnimationController _flow =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

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

  bool _isProtected(bool directDown, bool detourDown) {
    if (_flood && !_cbs) return false;                        // flood without CBS starves the video
    if (directDown && detourDown) return false;               // both FRER paths gone
    if ((directDown || detourDown) && !_frer) return false;   // a path lost, no FRER to cover it
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
    final keti = ref.watch(ketiStateProvider).valueOrNull;
    // Real injection-module fault state (path 1 = direct, path 2 = detour), merged with
    // the local optimistic cut set so the map is right whether or not BLE telemetry is up.
    final directDown = _cut.contains(0) || (keti?.pathSnapshots[1]?.faulted ?? false);
    final detourDown = _cut.contains(1) || (keti?.pathSnapshots[2]?.faulted ?? false);
    final ok = _isProtected(directDown, detourDown);
    // Live generator telemetry: pressing Start (here or anywhere) flips tg.running + the rate.
    final floodOn = tg.running || _flood;
    final genMbps = tg.last.mbps;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(children: [
          // ---- top bar ----
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 18, 22, 6),
            child: Row(children: [
              Image.asset('lib/assets/keti_logo.png', height: 27),
              const SizedBox(width: 13),
              Container(width: 1, height: 20, color: _hair),
              const SizedBox(width: 13),
              const Text('TSN Reconfig',
                  style: TextStyle(color: _ink, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
              const Spacer(),
              _Pill(live: tg.link == TgLink.online),
              const SizedBox(width: 12),
              _CircleBtn(icon: Icons.tune_rounded, onTap: () => _openShaper(context)),
            ]),
          ),
          // ---- dashboard: live rail + topology hero ----
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _leftRail(context, tg, ok, directDown, detourDown, floodOn, genMbps),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 22, 22),
                  child: LayoutBuilder(builder: (_, c) {
                    return CustomPaint(
                      painter: _RingPainter(
                          directDown: directDown, detourDown: detourDown,
                          floodOn: floodOn, protected: ok, anim: _flow),
                      child: Stack(children: [..._linkZones(c.biggest, tg), ..._nodes(c.biggest)]),
                    );
                  }),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  void _openShaper(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => const ShaperConfig(),
      );

  Widget _leftRail(BuildContext context, TrafficGenState tg, bool ok,
      bool directDown, bool detourDown, bool floodOn, double genMbps) {
    final pathsUp = 2 - (directDown ? 1 : 0) - (detourDown ? 1 : 0);
    final scenarios = <_Scn>[
      _Scn('Normal', Icons.check_circle_outline_rounded, false, false, () {
        _inject(1, false); _inject(2, false);
        _run(['stop', 'restore:1', 'restore:2', 'frer:on'],
            () { _flood = false; _cbs = false; _frer = true; _cut.clear(); });
      }),
      _Scn('Flood', Icons.bolt_outlined, floodOn && !_cbs, false,
          () => _run(['cbs:off', 'start'], () { _flood = true; _cbs = false; })),
      _Scn('Protect · CBS', Icons.verified_user_outlined, _cbs, true,
          () => _run(['cbs:mbps:250', 'cbs:on', 'start'], () { _flood = true; _cbs = true; })),
      _Scn('Cut · inject 1', Icons.link_off_rounded, directDown, false, () => _cutRoute(0, 1)),
      _Scn('Cut · inject 2', Icons.link_off_rounded, detourDown, false, () => _cutRoute(1, 2)),
      _Scn('FRER off', Icons.shuffle_rounded, !_frer, false,
          () => _run(['frer:off'], () => _frer = false)),
      _Scn('Restore', Icons.restart_alt_rounded, false, false, () {
        _inject(1, false); _inject(2, false);
        _run(['restore:1', 'restore:2', 'frer:on'], () { _cut.clear(); _frer = true; });
      }),
    ];
    return Container(
      width: 384,
      margin: const EdgeInsets.fromLTRB(20, 6, 6, 22),
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: _shadowSoft,
        border: Border.all(color: _hair),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Video bitrate', style: TextStyle(color: _ink2, fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          _StatusChip(ok: ok),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(tg.videoMbps > 0 ? tg.videoMbps.toStringAsFixed(1) : '—',
              style: TextStyle(color: ok ? _ink : _red, fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: -1.5)),
          const SizedBox(width: 7),
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Text('Mbps', style: TextStyle(color: _ink2, fontSize: 14.5, fontWeight: FontWeight.w700)),
          ),
          const Spacer(),
          if (tg.videoMbps > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: _green, shape: BoxShape.circle)),
            ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _kpi('Reconfig', '0', 'ms', _blue)),
          const SizedBox(width: 10),
          Expanded(child: _kpi('Paths up', '$pathsUp', '/2', pathsUp == 2 ? _green : (pathsUp == 1 ? _orange : _red))),
        ]),
        const SizedBox(height: 10),
        _kpiWide('Flood load', floodOn ? '${genMbps.toStringAsFixed(0)} Mbps' : 'video only', floodOn ? _orange : _ink2, floodOn),
        const SizedBox(height: 16),
        Container(height: 1, color: _hair),
        const SizedBox(height: 14),
        const Text('SCENARIOS', style: TextStyle(color: _ink2, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
        const SizedBox(height: 11),
        Expanded(
          child: ListView.separated(
            padding: EdgeInsets.zero,
            physics: const BouncingScrollPhysics(),
            itemCount: scenarios.length,
            separatorBuilder: (_, __) => const SizedBox(height: 7),
            itemBuilder: (_, i) => _ScenarioTile(scn: scenarios[i]),
          ),
        ),
      ]),
    );
  }

  Widget _kpi(String label, String value, String unit, Color col) => Container(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 13),
        decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(17)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: _ink2, fontSize: 11.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(value, style: TextStyle(color: col, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
            const SizedBox(width: 2),
            Text(unit, style: const TextStyle(color: _ink2, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ]),
        ]),
      );

  Widget _kpiWide(String label, String value, Color col, bool live) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(17)),
        child: Row(children: [
          Text(label, style: const TextStyle(color: _ink2, fontSize: 12.5, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (live)
            Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 7),
                decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
          Text(value, style: TextStyle(color: col, fontSize: 14.5, fontWeight: FontWeight.w700)),
        ]),
      );

  // Upright triangle: C apex (top), A & B base (bottom). Receiver above C.
  // Inverted triangle, laid out like the vehicle: D10-1 front-left and D10-2
  // front-right up top, the rear D10-4 at the bottom apex, receiver below it.
  static const _pos = {
    'video': Offset(0.09, 0.22),
    'A': Offset(0.32, 0.22),
    'B': Offset(0.68, 0.22),
    'flood': Offset(0.91, 0.22),
    'C': Offset(0.50, 0.58),
    'recv': Offset(0.50, 0.85),
  };

  List<Widget> _nodes(Size s) {
    final specs = <String, _NodeSpec>{
      'recv': _NodeSpec('Receiver · keti-rx', _green, Icons.smart_display_rounded, false),
      'C': _NodeSpec('$_swC · rear', _blue, Icons.dns_rounded, true),
      'A': _NodeSpec('$_swA · front-L', _blue, Icons.dns_rounded, true),
      'B': _NodeSpec('$_swB · front-R', _blue, Icons.dns_rounded, true),
      'video': _NodeSpec('Video Send · keti-src', _ink, Icons.videocam_rounded, false),
      'flood': _NodeSpec('Flood · keti-tx', _orange, Icons.bolt_rounded, false),
    };
    return [
      for (final e in _pos.entries)
        Positioned(
          left: e.value.dx * s.width - 60,
          top: e.value.dy * s.height - 32,
          child: GestureDetector(
            onTap: () => _showDevice(e.key),
            behavior: HitTestBehavior.opaque,
            child: _Node(spec: specs[e.key]!),
          ),
        ),
    ];
  }

  void _showDevice(String key) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _DeviceSheet(
        deviceKey: key,
        onConfigure: () {
          Navigator.of(context).maybePop();
          showModalBottomSheet<void>(
            context: context,
            backgroundColor: Colors.white,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
            builder: (_) => const ShaperConfig(),
          );
        },
      ),
    );
  }

  // Invisible tap targets over each edge midpoint, so a link opens its own sheet.
  List<Widget> _linkZones(Size s, TrafficGenState tg) {
    Offset p(String k) => Offset(_pos[k]!.dx * s.width, _pos[k]!.dy * s.height);
    final mids = {
      'src': Offset.lerp(p('video'), p('A'), 0.5)!,
      'direct': Offset.lerp(p('A'), p('C'), 0.5)!,
      'detour': Offset.lerp(p('B'), p('C'), 0.5)!,
      'delivery': Offset.lerp(p('C'), p('recv'), 0.5)!,
      'flood': Offset.lerp(p('flood'), p('B'), 0.5)!,
    };
    return [
      for (final e in mids.entries)
        Positioned(
          left: e.value.dx - 42,
          top: e.value.dy - 26,
          child: GestureDetector(
            onTap: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: Colors.white,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
              builder: (_) => _LinkSheet(linkKey: e.key),
            ),
            behavior: HitTestBehavior.opaque,
            child: const SizedBox(width: 84, height: 52),
          ),
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
        width: 118,
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: _shadowCard,
          border: Border.all(color: _hair),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: spec.color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(11)),
            child: Icon(spec.icon, color: spec.color, size: 20),
          ),
          const SizedBox(height: 8),
          Text(spec.label, textAlign: TextAlign.center,
              style: const TextStyle(color: _ink, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: -0.1)),
        ]),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.directDown,
    required this.detourDown,
    required this.floodOn,
    required this.protected,
    required this.anim,
  }) : super(repaint: anim);
  final bool directDown, detourDown, floodOn, protected;
  final Animation<double> anim;

  Offset _p(Size s, String k) {
    final o = _ShowScreenState._pos[k]!;
    return Offset(o.dx * s.width, o.dy * s.height);
  }

  // One edge: the base line plus, when the link is live, packets flowing a->b so the
  // path reads as real-time data movement rather than a static diagram.
  void _edge(Canvas canvas, Offset a, Offset b, Color col, {bool flow = false, double w = 3}) {
    canvas.drawLine(a, b, Paint()..color = col..strokeWidth = w..strokeCap = StrokeCap.round);
    if (!flow) return;
    const n = 3;
    for (int i = 0; i < n; i++) {
      final t = (anim.value + i / n) % 1.0;
      final o = Offset.lerp(a, b, t)!;
      canvas.drawCircle(o, 3.4, Paint()..color = _bg);        // halo so the dot reads over the line
      canvas.drawCircle(o, 2.1, Paint()..color = col);
    }
  }

  @override
  void paint(Canvas canvas, Size s) {
    final video = _p(s, 'video'), a = _p(s, 'A'), b = _p(s, 'B'),
        c = _p(s, 'C'), recv = _p(s, 'recv'), floodPi = _p(s, 'flood');

    _edge(canvas, video, a, _green, flow: true);                          // video source -> A (always live)
    _edge(canvas, floodPi, b, floodOn ? _orange : _idle, flow: floodOn);  // flood -> B (live when running)
    _edge(canvas, a, c, directDown ? _red : _green, flow: !directDown);   // DIRECT A->C
    _edge(canvas, a, b, detourDown ? _red : _green, flow: !detourDown);   // DETOUR base A->B
    _edge(canvas, b, c, detourDown ? _red : _green, flow: !detourDown);   // DETOUR B->C
    _edge(canvas, c, recv, protected ? _green : _red, flow: protected, w: 3.5); // delivery -> receiver
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
  bool shouldRepaint(_RingPainter o) =>
      o.directDown != directDown || o.detourDown != detourDown ||
      o.floodOn != floodOn || o.protected != protected;
}

/// A scenario for the rail: label, icon, whether it is the current state, whether
/// it is the primary (accent) action, and what to run.
class _Scn {
  const _Scn(this.label, this.icon, this.active, this.primary, this.onTap);
  final String label;
  final IconData icon;
  final bool active, primary;
  final VoidCallback onTap;
}

/// One refined scenario row in the left rail. Inactive = white with a hairline;
/// active = filled (accent for the primary action, ink otherwise) — no candy.
class _ScenarioTile extends StatelessWidget {
  const _ScenarioTile({required this.scn});
  final _Scn scn;
  @override
  Widget build(BuildContext context) {
    final bg = scn.active ? (scn.primary ? _blue : _ink) : Colors.white;
    final fg = scn.active ? Colors.white : _ink;
    return GestureDetector(
      onTap: scn.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: scn.active ? Colors.transparent : _hair),
        ),
        child: Row(children: [
          Icon(scn.icon, size: 17, color: scn.active ? Colors.white : _ink2),
          const SizedBox(width: 12),
          Text(scn.label,
              style: TextStyle(color: fg, fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: -0.2)),
          const Spacer(),
          if (scn.active)
            const Icon(Icons.circle, size: 6, color: Colors.white),
        ]),
      ),
    );
  }
}

/// Live / offline pill with a status dot.
class _Pill extends StatelessWidget {
  const _Pill({required this.live});
  final bool live;
  @override
  Widget build(BuildContext context) {
    final c = live ? _green : _ink2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 7),
        Text(live ? 'Live' : 'Offline', style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Small PROTECTED / DEGRADED status chip beside the live bitrate.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.ok});
  final bool ok;
  @override
  Widget build(BuildContext context) {
    final c = ok ? _green : _red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ok ? Icons.shield_rounded : Icons.warning_rounded, color: c, size: 13),
        const SizedBox(width: 5),
        Text(ok ? 'PROTECTED' : 'DEGRADED',
            style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
      ]),
    );
  }
}

/// Round icon button (config), soft elevation + hairline.
class _CircleBtn extends StatelessWidget {
  const _CircleBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: _shadowCard, border: Border.all(color: _hair)),
          child: Icon(icon, color: _ink, size: 20),
        ),
      );
}

/// Per-device detail sheet, opened by tapping a node. Shows identity + role, live
/// status where the telemetry carries it (the flood generator's rate/running from
/// the BLE bridge), and the relevant actions: switches jump to shaper config;
/// the flood node starts/stops the generator.
class _DeviceSheet extends ConsumerWidget {
  const _DeviceSheet({required this.deviceKey, required this.onConfigure});
  final String deviceKey;
  final VoidCallback onConfigure;

  // title, host, ip, role, icon, kind(sw|pi|flood)
  static const _info = {
    'video': ['Video Send', 'keti-src', '192.168.77.10', 'MPEG-TS 소스 · ffmpeg 1080p H.264 → UDP :5000', 'pi'],
    'A': ['D10-1 · front-L', 'KSwitch D10', '192.168.100.1', 'FRER 전달 노드 · 우회 사본을 통과시킴', 'sw'],
    'B': ['D10-2 · front-R', 'KSwitch D10', '192.168.100.2', 'FRER generation · 사본 2개 복제 (Gi 1/4 · 1/6)', 'sw'],
    'C': ['D10-4 · rear', 'KSwitch D10', '192.168.100.4', 'FRER recovery + CBS · 중복 제거 후 수신 egress', 'sw'],
    'recv': ['Receiver', 'keti-rx', '192.168.77.12', '영상 표시 · mpegts.js 키오스크 (HW 디코드)', 'pi'],
    'flood': ['Flood', 'keti-tx', '192.168.100.10', '트래픽 생성 · pktgen 홍수 (best-effort TC0)', 'flood'],
  };

  static const _icon = {
    'video': Icons.videocam_rounded, 'A': Icons.dns_rounded, 'B': Icons.dns_rounded,
    'C': Icons.dns_rounded, 'recv': Icons.smart_display_rounded, 'flood': Icons.bolt_rounded,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = _info[deviceKey]!;
    final kind = d[4];
    final tg = ref.watch(trafficGenProvider);
    final color = kind == 'sw' ? _blue : (kind == 'flood' ? _orange : _ink);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(
            color: const Color(0xFFE2E6EE), borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Icon(_icon[deviceKey], color: color, size: 24)),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d[0], style: const TextStyle(color: _ink, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
            Text('${d[1]} · ${d[2]}', style: const TextStyle(color: _ink2, fontSize: 12.5, fontWeight: FontWeight.w500)),
          ]),
        ]),
        const SizedBox(height: 14),
        Text(d[3], style: const TextStyle(color: _ink2, fontSize: 13, height: 1.4)),
        const SizedBox(height: 16),
        // live status line
        if (kind == 'flood')
          _statRow('생성 속도', tg.running ? '${tg.last.mbps.toStringAsFixed(0)} Mbps · ${(tg.last.pps / 1000).toStringAsFixed(0)}k pps' : '정지', tg.running ? _orange : _ink2)
        else if (kind == 'sw')
          _statRow('링크', '1 Gbps · Gi 1/1·1/2·1/4·1/6', _green)
        else
          _statRow('상태', tg.link == TgLink.online ? '연결됨' : '오프라인', tg.link == TgLink.online ? _green : _ink2),
        const SizedBox(height: 18),
        // actions
        if (kind == 'sw') ...[
          Row(children: [
            Expanded(child: _btn('Ping', const Color(0xFFF0F2F6), _ink,
                () => ref.read(trafficGenProvider.notifier).sendControl('q:ping:${d[2]}'))),
            const SizedBox(width: 12),
            Expanded(child: _btn('포트 상태', const Color(0xFFF0F2F6), _ink,
                () => ref.read(trafficGenProvider.notifier).sendControl('q:ports:${d[2]}'))),
          ]),
          if (tg.queryResp.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12)),
              child: Text(tg.queryResp, style: const TextStyle(color: _ink, fontSize: 12.5, height: 1.45, fontWeight: FontWeight.w500)),
            ),
          ],
          const SizedBox(height: 12),
          _btn('Shaper 설정 (CBS · TAS · FRER)', _blue, Colors.white, onConfigure),
        ] else if (kind == 'flood') ...[
          Row(children: [
            Expanded(child: _btn('Start', _orange, Colors.white,
                () => ref.read(trafficGenProvider.notifier).sendControl('start'))),
            const SizedBox(width: 12),
            Expanded(child: _btn('Stop', const Color(0xFFF0F2F6), _ink,
                () => ref.read(trafficGenProvider.notifier).sendControl('stop'))),
          ]),
          if (tg.history.length > 1) ...[
            const SizedBox(height: 16),
            Row(children: [
              const Text('생성 속도', style: TextStyle(color: _ink2, fontSize: 12, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${tg.last.mbps.toStringAsFixed(0)} Mbps · ${(tg.last.pps / 1000).toStringAsFixed(0)}k pps',
                  style: const TextStyle(color: _orange, fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            _Sparkline(values: tg.history.map((e) => e.mbps).toList(), color: _orange),
          ],
        ] else
          _btn('닫기', const Color(0xFFF0F2F6), _ink, () => Navigator.of(context).maybePop()),
      ]),
    );
  }

  Widget _statRow(String k, String v, Color col) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Text(k, style: const TextStyle(color: _ink2, fontSize: 12.5, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(v, style: TextStyle(color: col, fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _btn(String label, Color bg, Color fg, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(height: 46, alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(13)),
            child: Text(label, style: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w700))),
      );
}

/// Per-link detail sheet: which ports it runs on and its rate. The flood link
/// shows the live generated rate; the video links show the stream rate.
class _LinkSheet extends ConsumerWidget {
  const _LinkSheet({required this.linkKey});
  final String linkKey;

  // title, endpoints, speed, kind(video|ring|flood)
  static const _info = {
    'src': ['영상 소스 링크', 'keti-src → D10-1 (Gi 1/1)', '1 Gbps', 'video'],
    'direct': ['DIRECT · FRER 사본', 'D10-1 → D10-4 · Gi 1/6 ↔ Gi 1/4', '1 Gbps', 'ring'],
    'detour': ['DETOUR · FRER 사본', 'D10-2 → D10-4 · Gi 1/6 ↔ Gi 1/6', '1 Gbps', 'ring'],
    'delivery': ['수신 전달 (복구 후)', 'D10-4 → keti-rx · Gi 1/2 · CBS 250M q6', '1 Gbps', 'video'],
    'flood': ['플러드 주입', 'keti-tx → D10-2 · TC0 best-effort', '1 Gbps', 'flood'],
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = _info[linkKey]!;
    final tg = ref.watch(trafficGenProvider);
    final kind = d[3];
    final rateLabel = kind == 'flood'
        ? (tg.running ? '${tg.last.mbps.toStringAsFixed(0)} Mbps · ${(tg.last.pps / 1000).toStringAsFixed(0)}k pps' : '정지')
        : '영상 ~8 Mbps (1080p H.264)';
    final rateCol = kind == 'flood' ? (tg.running ? _orange : _ink2) : _green;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(
            color: const Color(0xFFE2E6EE), borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(
              color: _blue.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.route_rounded, color: _blue, size: 23)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d[0], style: const TextStyle(color: _ink, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
            Text(d[1], style: const TextStyle(color: _ink2, fontSize: 12.5, fontWeight: FontWeight.w500)),
          ])),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Text('링크 속도', style: TextStyle(color: _ink2, fontSize: 12.5, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(d[2], style: const TextStyle(color: _ink, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Text(kind == 'flood' ? '생성 트래픽' : '스트림', style: const TextStyle(color: _ink2, fontSize: 12.5, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(rateLabel, style: TextStyle(color: rateCol, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }
}

/// Minimal live sparkline (single series, thin 2px line + faint fill, no axes) for
/// the generated-rate history. Recessive by design -- the number beside it carries
/// the value; this just shows the shape (flood spikes) over time.
class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.values, required this.color});
  final List<double> values;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        height: 62,
        width: double.infinity,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(color: const Color(0xFFF7F8FA), borderRadius: BorderRadius.circular(12)),
        child: CustomPaint(painter: _SparkPainter(values, color)),
      );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color);
  final List<double> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size s) {
    if (values.length < 2) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final scale = maxV < 1 ? 1.0 : maxV;
    final dx = s.width / (values.length - 1);
    double y(double v) => s.height - (v / scale) * (s.height - 8) - 4;
    final line = Path()..moveTo(0, y(values.first));
    for (var i = 1; i < values.length; i++) {
      line.lineTo(i * dx, y(values[i]));
    }
    final fill = Path.from(line)
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_SparkPainter o) => o.values.length != values.length || o.color != color;
}
