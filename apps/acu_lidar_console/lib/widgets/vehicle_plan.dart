import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/reference.dart';
import '../core/theme.dart';
import '../providers/rig_provider.dart';

/// The vehicle with every device from the sheets on it, drawn natively.
///
/// One projector serves both views. At pitch = pi/2 the vertical axis collapses and the scene is
/// a plan drawing; anywhere below that it is an axonometric 3D view you can swing by dragging.
/// The console this was cloned from ran its 3D in a WebView, which cost about a second of blank
/// frame on this tablet every time the page rebuilt -- and a harness drawing does not need a
/// renderer, only a projection.
class VehicleView extends StatefulWidget {
  final RigSnapshot snapshot;
  final String? selectedNodeId;
  final ValueChanged<String?> onSelect;
  final bool showCameras;
  final bool showCables;

  /// true = plan (top-down), false = the 3D view.
  final bool plan;

  const VehicleView({
    super.key,
    required this.snapshot,
    required this.selectedNodeId,
    required this.onSelect,
    required this.plan,
    this.showCameras = true,
    this.showCables = true,
  });

  @override
  State<VehicleView> createState() => _VehicleViewState();
}

class _VehicleViewState extends State<VehicleView> with SingleTickerProviderStateMixin {
  static const _planPitch = math.pi / 2;
  static const _isoPitch = 0.74;
  static const _planYaw = -math.pi / 2;

  /// A true three-quarter angle: the vehicle runs diagonally, so a long thin body fills a
  /// roughly square panel instead of leaving half of it white.
  static const _isoYaw = -math.pi / 4 - 0.12;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
    value: widget.plan ? 0 : 1,
  );

  /// Extra swing the user has dragged in, on top of the two presets. Reset when the view is
  /// switched, so the toggle always lands somewhere legible.
  double _dragYaw = 0;
  double _dragPitch = 0;
  Offset? _last;

  @override
  void didUpdateWidget(VehicleView old) {
    super.didUpdateWidget(old);
    if (old.plan != widget.plan) {
      _dragYaw = 0;
      _dragPitch = 0;
      widget.plan ? _anim.reverse() : _anim.forward();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(_anim.value);
        final pitch = (_planPitch + (_isoPitch - _planPitch) * t + _dragPitch).clamp(0.16, math.pi / 2);
        final yaw = _planYaw + (_isoYaw - _planYaw) * t + _dragYaw;
        return LayoutBuilder(
          builder: (context, c) {
            final size = Size(c.maxWidth, c.maxHeight);
            final layout = _Layout(size, yaw: yaw, pitch: pitch, showCameras: widget.showCameras);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => widget.onSelect(layout.hitTest(d.localPosition)),
              onPanStart: (d) => _last = d.localPosition,
              onPanUpdate: (d) {
                final prev = _last ?? d.localPosition;
                setState(() {
                  _dragYaw += (d.localPosition.dx - prev.dx) * 0.006;
                  _dragPitch -= (d.localPosition.dy - prev.dy) * 0.005;
                  _last = d.localPosition;
                });
              },
              onPanEnd: (_) => _last = null,
              onDoubleTap: () => setState(() {
                _dragYaw = 0;
                _dragPitch = 0;
              }),
              child: CustomPaint(
                size: size,
                painter: _Painter(
                  layout: layout,
                  snapshot: widget.snapshot,
                  selectedNodeId: widget.selectedNodeId,
                  showCameras: widget.showCameras,
                  showCables: widget.showCables,
                  flat: pitch > _planPitch - 0.02,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Projection
// ---------------------------------------------------------------------------

/// Vehicle envelope in metres. Not from the sheets -- the sheets show mounting photos, not a
/// package drawing -- so it is a shuttle-sized box that makes the device layout readable.
const _len = 5.2;
const _wid = 2.05;
const _hgt = 2.35;

class _Layout {
  final Size size;
  final double yaw;
  final double pitch;
  final bool showCameras;

  late final double _scale;
  late final Offset _origin;
  final Map<String, Offset> nodes = {};

  _Layout(this.size, {required this.yaw, required this.pitch, this.showCameras = true}) {
    // Linear projection, so fitting is one pass: project the envelope at unit scale, then scale
    // and centre what came out.
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final x in [-_wid / 2, _wid / 2]) {
      for (final y in [-_len / 2, _len / 2]) {
        for (final z in [0.0, _hgt]) {
          final p = _raw(x, y, z);
          minX = math.min(minX, p.dx);
          maxX = math.max(maxX, p.dx);
          minY = math.min(minY, p.dy);
          maxY = math.max(maxY, p.dy);
        }
      }
    }
    // Room at the sides for the flank labels, and a little at the top for FRONT/REAR.
    final availW = size.width - 96;
    final availH = size.height - 44;
    _scale = math.min(availW / (maxX - minX), availH / (maxY - minY));
    _origin = Offset(
      size.width / 2 - (minX + maxX) / 2 * _scale,
      size.height / 2 - (minY + maxY) / 2 * _scale,
    );
    for (final n in allNodes) {
      if (!showCameras && n.kind == NodeKind.camera) continue;
      nodes[n.id] = at(n.pos, heightOf(n));
    }
  }

  Offset _raw(double x, double y, double z) {
    final sx = x * math.cos(yaw) - y * math.sin(yaw);
    final sy = x * math.sin(yaw) + y * math.cos(yaw);
    return Offset(sx, sy * math.sin(pitch) - z * math.cos(pitch));
  }

  Offset project(double x, double y, double z) => _origin + _raw(x, y, z) * _scale;

  /// Sheet coordinates (x -1..1 lateral, y 0..1 front to rear) plus a normalised height.
  Offset at(Offset p, double h) =>
      project(p.dx * _wid / 2, (p.dy - 0.5) * _len, h * _hgt);

  String? hitTest(Offset tap) {
    String? best;
    var bestD = 30.0;
    for (final e in nodes.entries) {
      final d = (e.value - tap).distance;
      if (d < bestD) {
        bestD = d;
        best = e.key;
      }
    }
    return best;
  }
}

/// Where each device sits vertically. Read off the mounting photos: roof units on the roof,
/// bumper units at fascia height, ACUs on the floor of the rear compartment.
double heightOf(Node n) {
  if (n.id.startsWith('fk_')) return 1.02;
  if (n.id.startsWith('hb_')) return 0.30;
  if (n.id == 'lidar_lh' || n.id == 'lidar_rh') return 0.96;
  if (n.kind == NodeKind.acu || n.kind == NodeKind.tcu) return 0.10;
  if (n.id == 'display') return 0.62;
  if (n.id.contains('roof')) return 0.90;
  if (n.id.startsWith('cam_tf')) return 0.80;
  if (n.id == 'cam_rear') return 0.34;
  return 0.62; // flank cameras
}

Color kindColour(NodeKind k) => switch (k) {
      NodeKind.lidar => Tone.lidar,
      NodeKind.camera => Tone.camera,
      NodeKind.acu => Tone.acu,
      NodeKind.tcu => Tone.other,
      NodeKind.display => Tone.other,
    };

Color linkColour(LinkState s, Color fallback) => switch (s) {
      LinkState.up => Tone.ok,
      LinkState.degraded => Tone.warn,
      LinkState.down => Tone.bad,
      LinkState.unknown => fallback,
    };

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _Painter extends CustomPainter {
  final _Layout layout;
  final RigSnapshot snapshot;
  final String? selectedNodeId;
  final bool showCameras;
  final bool showCables;
  final bool flat;

  /// Label rectangles already committed this frame, so the next label can step aside instead of
  /// printing on top. Ten camera names around one shuttle is dense enough that fixed offsets
  /// collide on every layout.
  final List<Rect> _taken = [];

  _Painter({
    required this.layout,
    required this.snapshot,
    required this.selectedNodeId,
    required this.showCameras,
    required this.showCables,
    required this.flat,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _taken.clear();
    _paintBody(canvas);
    if (showCables) _paintCables(canvas);

    // Painter's algorithm: far devices first, so a roof unit overlaps the floor behind it.
    final ordered = [...allNodes]
      ..removeWhere((n) => !showCameras && n.kind == NodeKind.camera)
      ..sort((a, b) => layout.nodes[a.id]!.dy.compareTo(layout.nodes[b.id]!.dy));
    for (final n in ordered) {
      _paintNode(canvas, n);
    }
    // Labels last, over everything, and the selected one first so it always wins a collision.
    final labelled = [...ordered]..sort((a, b) {
        if (a.id == selectedNodeId) return -1;
        if (b.id == selectedNodeId) return 1;
        return 0;
      });
    for (final n in labelled) {
      _paintLabel(canvas, n);
    }
  }

  /// The body as a translucent box: floor polygon, roof polygon, and the four corner posts.
  /// Flattened to pitch = pi/2 the posts vanish and it reads as the plan outline.
  void _paintBody(Canvas canvas) {
    List<Offset> ring(double z) {
      const r = 0.55; // corner radius, metres
      final pts = <Offset>[];
      void corner(double cx, double cy, double a0) {
        for (var i = 0; i <= 6; i++) {
          final a = a0 + i * (math.pi / 2) / 6;
          pts.add(layout.project(cx + r * math.cos(a), cy + r * math.sin(a), z));
        }
      }

      corner(_wid / 2 - r, _len / 2 - r, 0);
      corner(-_wid / 2 + r, _len / 2 - r, math.pi / 2);
      corner(-_wid / 2 + r, -_len / 2 + r, math.pi);
      corner(_wid / 2 - r, -_len / 2 + r, -math.pi / 2);
      return pts;
    }

    Path pathOf(List<Offset> pts) {
      final p = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final o in pts.skip(1)) {
        p.lineTo(o.dx, o.dy);
      }
      return p..close();
    }

    final floor = ring(0);
    final roof = ring(_hgt);

    canvas.drawPath(pathOf(floor), Paint()..color = const Color(0xFFE3E8F0));
    // Corner posts, so the box has visible height without drawing every panel.
    final post = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFFC3CCDA);
    for (var i = 0; i < floor.length; i += 6) {
      canvas.drawLine(floor[i], roof[i], post);
    }
    canvas.drawPath(pathOf(roof), Paint()..color = const Color(0xFFEFF3F9).withValues(alpha: flat ? 0 : 0.82));
    canvas.drawPath(
      pathOf(roof),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = const Color(0xFFB9C3D3),
    );
    canvas.drawPath(
      pathOf(floor),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xFFC3CCDA),
    );

    // Wheels, on the floor plane.
    for (final y in [-_len * 0.30, _len * 0.30]) {
      for (final x in [-_wid / 2 - 0.06, _wid / 2 + 0.06]) {
        final a = layout.project(x, y - 0.34, 0);
        final b = layout.project(x, y + 0.34, 0);
        canvas.drawLine(
          a,
          b,
          Paint()
            ..strokeWidth = 7
            ..strokeCap = StrokeCap.round
            ..color = const Color(0xFFC0C9D8),
        );
      }
    }

    _text(canvas, 'FRONT', layout.project(0, -_len / 2 - 0.42, 0),
        size: 10, colour: Tone.faint, weight: FontWeight.w800, centre: true, spacing: 1.6);
    _text(canvas, 'REAR', layout.project(0, _len / 2 + 0.30, 0),
        size: 10, colour: Tone.faint, weight: FontWeight.w800, centre: true, spacing: 1.6);
  }

  /// Sensor-to-ACU cables, routed down the flank the way a loom runs rather than straight
  /// across the cabin.
  void _paintCables(Canvas canvas) {
    final acuNode = nodeById('acu_it')!;
    for (final n in allNodes) {
      if (n.acuPort == null) continue;
      final state = snapshot.link(n.acuPort!);
      final colour = linkColour(state, const Color(0xFFB3BECE));
      final selected = selectedNodeId == n.id;

      // Three points in vehicle space: the device, a waypoint on the nearest flank at floor
      // level, and the ACU.
      final side = n.pos.dx.abs() < 0.2 ? (n.pos.dy < 0.5 ? -1.0 : 1.0) : n.pos.dx.sign;
      final wp = Offset(side * 0.82, (n.pos.dy + 0.78) / 2);
      final path = Path();
      final a = layout.nodes[n.id] ?? layout.at(n.pos, heightOf(n));
      final m = layout.at(wp, 0.16);
      final b = layout.at(acuNode.pos, heightOf(acuNode));
      path.moveTo(a.dx, a.dy);
      path.quadraticBezierTo(m.dx, m.dy, b.dx, b.dy);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 3.0 : 1.5
          ..color = colour.withValues(alpha: selected ? 0.95 : 0.5),
      );
      if (state == LinkState.down) {
        for (final metric in path.computeMetrics()) {
          final tan = metric.getTangentForOffset(metric.length * 0.5);
          if (tan == null) continue;
          final p = Paint()
            ..color = Tone.bad
            ..strokeWidth = 2.4
            ..strokeCap = StrokeCap.round;
          canvas.drawLine(tan.position + const Offset(-5, -5), tan.position + const Offset(5, 5), p);
          canvas.drawLine(tan.position + const Offset(5, -5), tan.position + const Offset(-5, 5), p);
          break;
        }
      }
    }
  }

  void _paintNode(Canvas canvas, Node n) {
    final c = layout.nodes[n.id];
    if (c == null) return;
    final base = kindColour(n.kind);
    final state = n.acuPort != null ? snapshot.link(n.acuPort!) : LinkState.unknown;
    final colour = state == LinkState.unknown ? base : linkColour(state, base);
    final selected = selectedNodeId == n.id;

    // A stem to the floor, so a roof device does not float free of the body.
    if (!flat && n.kind != NodeKind.acu && n.kind != NodeKind.tcu) {
      final foot = layout.at(n.pos, 0);
      canvas.drawLine(
        c,
        foot,
        Paint()
          ..strokeWidth = 1
          ..color = colour.withValues(alpha: 0.22),
      );
    }

    if (selected) {
      canvas.drawCircle(c, 20, Paint()..color = colour.withValues(alpha: 0.18));
    }

    switch (n.kind) {
      case NodeKind.lidar:
        for (var i = 0; i < 3; i++) {
          canvas.drawCircle(
            c,
            10.0 + i * 5.5,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = colour.withValues(alpha: 0.22 - i * 0.06),
          );
        }
        canvas.drawCircle(c, 7.5, Paint()..color = colour);
        canvas.drawCircle(c, 3.0, Paint()..color = Colors.white.withValues(alpha: 0.92));
      case NodeKind.camera:
        canvas.drawCircle(c, 5.0, Paint()..color = colour);
        canvas.drawCircle(
          c,
          5.0,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = Colors.white,
        );
      case NodeKind.acu:
        _box(canvas, c, n.name.replaceAll('ACU_', 'ACU '), colour, 11);
      case NodeKind.tcu:
      case NodeKind.display:
        _box(canvas, c, n.name, colour.withValues(alpha: 0.88), 9.5);
    }
  }

  void _box(Canvas canvas, Offset c, String label, Color colour, double fontSize) {
    final tp = _painter(label, size: fontSize, colour: Colors.white, weight: FontWeight.w900);
    final r = RRect.fromRectAndRadius(
      Rect.fromCenter(center: c, width: tp.width + 18, height: tp.height + 11),
      const Radius.circular(6),
    );
    canvas.drawRRect(r, Paint()..color = colour);
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - tp.height / 2));
    _taken.add(r.outerRect.inflate(2));
  }

  void _paintLabel(Canvas canvas, Node n) {
    if (n.kind == NodeKind.acu || n.kind == NodeKind.tcu || n.kind == NodeKind.display) return;
    final c = layout.nodes[n.id];
    if (c == null) return;
    final selected = selectedNodeId == n.id;
    // Ten camera names around one shuttle at 1280x800 cannot all be legible, and a screen of
    // overlapping labels is worse than none. Cameras stay dots until tapped; they are named in
    // the ACU_NO jack strip and in the inspector, where there is room for the full name.
    if (n.kind == NodeKind.camera && !selected) return;
    final label = switch (n.kind) {
      NodeKind.lidar => n.name.replaceAll(' · ', ' '),
      _ => n.name,
    };
    final tp = _painter(
      label,
      size: 10,
      colour: selected ? Tone.text : Tone.muted,
      weight: selected ? FontWeight.w800 : FontWeight.w600,
    );

    // Try the flank first -- outboard reads best -- then work around the device.
    const gap = 13.0;
    final outboard = n.pos.dx >= 0 ? 1 : -1;
    final candidates = <Offset>[
      Offset(outboard * (gap + tp.width / 2), 0),
      Offset(-outboard * (gap + tp.width / 2), 0),
      Offset(0, -(gap + tp.height / 2)),
      Offset(0, gap + tp.height / 2),
      Offset(outboard * (gap + tp.width / 2), -(gap + tp.height / 2)),
      Offset(outboard * (gap + tp.width / 2), gap + tp.height / 2),
      Offset(-outboard * (gap + tp.width / 2), -(gap + tp.height / 2)),
      Offset(-outboard * (gap + tp.width / 2), gap + tp.height / 2),
      Offset(0, -(gap + tp.height * 1.9)),
      Offset(0, gap + tp.height * 1.9),
    ];
    Rect? chosen;
    for (final d in candidates) {
      final r = Rect.fromCenter(center: c + d, width: tp.width + 4, height: tp.height + 2);
      if (r.left < 2 || r.right > layout.size.width - 2) continue;
      if (_taken.any((t) => t.overlaps(r))) continue;
      chosen = r;
      break;
    }
    chosen ??= Rect.fromCenter(
      center: c + candidates.first,
      width: tp.width + 4,
      height: tp.height + 2,
    );
    _taken.add(chosen.inflate(1));

    // A leader line whenever the label had to move off the device's shoulder.
    final away = (chosen.center - c).distance;
    if (away > gap + tp.width / 2 + 6) {
      canvas.drawLine(
        c,
        chosen.center,
        Paint()
          ..strokeWidth = 0.8
          ..color = Tone.faint.withValues(alpha: 0.5),
      );
    }
    // A pad behind the text, or it fights the body fill underneath.
    canvas.drawRRect(
      RRect.fromRectAndRadius(chosen.inflate(2), const Radius.circular(4)),
      Paint()..color = Colors.white.withValues(alpha: 0.82),
    );
    tp.paint(canvas, Offset(chosen.left + 2, chosen.top + 1));
  }

  TextPainter _painter(String s,
      {double size = 11, Color colour = Tone.text, FontWeight weight = FontWeight.w600, double spacing = 0}) {
    return TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontSize: size, color: colour, fontWeight: weight, letterSpacing: spacing),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _text(
    Canvas canvas,
    String s,
    Offset at, {
    double size = 11,
    Color colour = Tone.text,
    FontWeight weight = FontWeight.w600,
    bool centre = false,
    double spacing = 0,
  }) {
    final tp = _painter(s, size: size, colour: colour, weight: weight, spacing: spacing);
    tp.paint(canvas, Offset(centre ? at.dx - tp.width / 2 : at.dx, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _Painter old) => true;
}
