import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/geom.dart';
import '../core/reference.dart';
import '../core/theme.dart';
import '../providers/rig_provider.dart';
import 'device_meshes.dart';

/// The vehicle and every device on it, as solid geometry, drawn in a CustomPaint.
///
/// One projector serves both views. At pitch = pi/2 the vertical axis collapses and the scene is
/// a plan drawing; anywhere below that it is an axonometric where the parts read as parts. The
/// console this was cloned from ran its 3D in a WebView, which cost about a second of blank frame
/// on this tablet every time the page rebuilt. The projection is orthographic and the parts are
/// convex and well separated, so back-to-front sorting is correct and costs nothing.
class VehicleView extends StatefulWidget {
  final RigSnapshot snapshot;
  final String? selectedNodeId;
  final ValueChanged<String?> onSelect;
  final bool showCameras;
  final bool showCables;

  /// true = plan (top-down), false = the 3D view.
  final bool plan;

  /// The backbone links to draw; the A-to-B cross-link is optional.
  final List<Trunk> trunks;

  const VehicleView({
    super.key,
    required this.snapshot,
    required this.selectedNodeId,
    required this.onSelect,
    required this.plan,
    required this.trunks,
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

  /// A three-quarter angle: the vehicle runs diagonally, so a long thin body fills a roughly
  /// square panel instead of leaving half of it white.
  static const _isoYaw = -math.pi / 4 - 0.12;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
    value: widget.plan ? 0 : 1,
  );

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
        final pitch =
            (_planPitch + (_isoPitch - _planPitch) * t + _dragPitch).clamp(0.16, math.pi / 2);
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
                  trunks: widget.trunks,
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

/// Vehicle envelope in metres. Not from the sheets -- they show mounting photos, not a package
/// drawing -- so it is a shuttle-sized box that makes the device layout readable.
const _len = 5.2;
const _wid = 2.05;
const _hgt = 2.35;

class _Layout {
  final Size size;
  final double yaw;
  final double pitch;
  final bool showCameras;

  late final double scale;
  late final Offset _origin;
  final Map<String, Offset> nodes = {};

  _Layout(this.size, {required this.yaw, required this.pitch, this.showCameras = true}) {
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final x in [-_wid / 2, _wid / 2]) {
      for (final y in [-_len / 2, _len / 2]) {
        for (final z in [0.0, _hgt]) {
          final p = _raw(V3(x, y, z));
          minX = math.min(minX, p.dx);
          maxX = math.max(maxX, p.dx);
          minY = math.min(minY, p.dy);
          maxY = math.max(maxY, p.dy);
        }
      }
    }
    final availW = size.width - 210;
    final availH = size.height - 64;
    scale = math.min(availW / (maxX - minX), availH / (maxY - minY));
    _origin = Offset(
      size.width / 2 - (minX + maxX) / 2 * scale,
      size.height / 2 - (minY + maxY) / 2 * scale,
    );
    for (final n in allNodes) {
      if (!showCameras && n.kind == NodeKind.camera) continue;
      nodes[n.id] = project(anchorOf(n));
    }
  }

  Offset _raw(V3 v) {
    final sx = v.x * math.cos(yaw) - v.y * math.sin(yaw);
    final sy = v.x * math.sin(yaw) + v.y * math.cos(yaw);
    return Offset(sx, sy * math.sin(pitch) - v.z * math.cos(pitch));
  }

  Offset project(V3 v) => _origin + _raw(v) * scale;

  /// Distance towards the camera. The screen basis is (1,0,0) and (0, sin p, -cos p), so the
  /// view direction is their cross product, (0, cos p, sin p): larger is nearer.
  double depth(V3 v) {
    final sy = v.x * math.sin(yaw) + v.y * math.cos(yaw);
    return sy * math.cos(pitch) + v.z * math.sin(pitch);
  }

  String? hitTest(Offset tap) {
    String? best;
    var bestD = 32.0;
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

/// Where each device sits, in metres. Read off the mounting photos: roof units on the roof,
/// bumper units at fascia height, ACUs on the floor of the rear compartment.
V3 anchorOf(Node n) => V3(
      n.pos.dx * _wid / 2,
      (n.pos.dy - 0.5) * _len,
      heightOf(n) * _hgt,
    );

/// Mount heights, 0 at the ground and 1 at the roof. Same provenance as [Node.pos]: where the
/// reconfig model had the device, these are its numbers.
double heightOf(Node n) {
  if (n.id.startsWith('fk_')) return 0.95; // roof units; the reconfig model had none to copy
  if (n.id.startsWith('hb_')) return 0.234;
  if (n.id == 'lidar_lh' || n.id == 'lidar_rh') return 0.441;
  if (n.kind == NodeKind.acu || n.kind == NodeKind.tcu || n.kind == NodeKind.tsn) return 0.165;
  if (n.id == 'display') return 0.55;
  if (n.id.contains('roof')) return 0.50;
  if (n.id.startsWith('cam_tf')) return 0.464;
  if (n.id == 'cam_rear') return 0.395;
  return 0.487; // flank cameras
}

Color kindColour(NodeKind k) => switch (k) {
      NodeKind.lidar => Tone.lidar,
      NodeKind.camera => Tone.camera,
      NodeKind.acu => Tone.acu,
      NodeKind.tcu => Tone.aux,
      NodeKind.display => Tone.aux,
      NodeKind.tsn => Tone.tsn,
    };

/// The colour a *run* is drawn in. A healthy link keeps its family colour: painting every run
/// green when the rig is up throws away the taxonomy the legend still claims, and leaves a fault
/// with nothing to stand out against. Only trouble takes the colour away.
Color runColour(LinkState s, Color family) => switch (s) {
      LinkState.degraded => Tone.warn,
      LinkState.down => Tone.bad,
      LinkState.up || LinkState.unknown => family,
    };

/// The colour a *state dot* is drawn in, where green for up is the whole point.
Color linkColour(LinkState s, Color fallback) => switch (s) {
      LinkState.up => Tone.ok,
      LinkState.degraded => Tone.warn,
      LinkState.down => Tone.bad,
      LinkState.unknown => fallback,
    };

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

/// One thing to draw, with the depth it should be drawn at.
class _Prim {
  final double depth;
  final Quad? quad;
  final List<V3>? line;
  final Color? lineColour;
  final double lineWidth;
  final bool dashed;

  /// A harness run gets a light casing under its core so it reads as a cable against whatever it
  /// crosses. A body rail does not -- it is a construction line, and a halo makes it shout.
  final bool casing;

  /// Stroked as a dashed line. Used for the body: it is an envelope, not vehicle CAD, and a solid
  /// outline claims a shape the sheets never give.
  final bool dashPattern;

  _Prim.face(this.quad, this.depth)
      : line = null,
        lineColour = null,
        lineWidth = 0,
        dashed = false,
        casing = false,
        dashPattern = false;

  _Prim.wire(this.line, this.depth, this.lineColour, this.lineWidth,
      {this.dashed = false, this.casing = true, this.dashPattern = false})
      : quad = null;
}

class _Painter extends CustomPainter {
  final _Layout layout;
  final RigSnapshot snapshot;
  final String? selectedNodeId;
  final bool showCameras;
  final bool showCables;
  final bool flat;

  /// The backbone links currently in play; the A-to-B cross-link is optional.
  final List<Trunk> trunks;

  final List<Rect> _taken = [];

  _Painter({
    required this.layout,
    required this.snapshot,
    required this.selectedNodeId,
    required this.showCameras,
    required this.showCables,
    required this.flat,
    required this.trunks,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _taken.clear();
    _paintGround(canvas);

    final prims = <_Prim>[];
    _addShell(prims);
    _addDevices(prims);
    if (showCables) {
      _addCables(prims);
      _addTrunks(prims);
    }
    prims.sort((a, b) => a.depth.compareTo(b.depth));

    for (final p in prims) {
      if (p.quad != null) {
        _drawQuad(canvas, p.quad!);
      } else {
        _drawWire(canvas, p);
      }
    }

    _paintSelection(canvas);
    _paintLabels(canvas);
    _paintOrientation(canvas);
  }

  // -- ground -----------------------------------------------------------------

  void _paintGround(Canvas canvas) {
    if (flat) return;
    // A soft contact shadow, so the vehicle sits on something instead of floating.
    final pts = [
      for (final o in Mesh.roundedRect(_wid * 1.15, _len * 1.05, 0.7, steps: 4))
        layout.project(V3(o.dx, o.dy, 0)),
    ];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0x141B2A44)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
  }

  // -- shell ------------------------------------------------------------------

  /// The body is a package drawing, not a car: a solid floor and sills, and above them nothing
  /// but rails and posts. Filled glass walls were tried first and they grey out exactly what the
  /// view exists to show -- eighteen devices, most of them inside the cabin or on the roof.
  void _addShell(List<_Prim> out) {
    final m = Mesh();
    const sill = Color(0xFFB9C2D0);
    const floor = Color(0xFFDCE2EB);

    // The deck sits high enough that everything standing on it clears the sill. Put the deck at
    // the bottom of the body and the boxes disappear behind their own sill wall.
    m.extrude(Mesh.roundedRect(_wid * 0.94, _len * 0.97, 0.5, steps: 4), _hgt * 0.10, _hgt * 0.26,
        sill, alpha: 0.32, outline: false);
    m.extrude(Mesh.roundedRect(_wid * 0.97, _len * 0.98, 0.5, steps: 5), _hgt * 0.26, _hgt * 0.31,
        floor, cap: floor, alpha: 0.8, outline: false);
    for (final y in [-_len * 0.30, _len * 0.30]) {
      for (final x in [-_wid / 2 - 0.02, _wid / 2 + 0.02]) {
        m.box(V3(x, y, _hgt * 0.14), const V3(0.07, 0.34, 0.14), const Color(0xFF6E7787),
            outline: false);
      }
    }
    _emit(out, m);

    // The greenhouse and roof, as wire.
    const rail = Color(0xFF93A2B8);
    final waist = Mesh.roundedRect(_wid, _len, 0.55, steps: 6);
    final crown = Mesh.roundedRect(_wid * 0.95, _len * 0.93, 0.55, steps: 6);
    void loop(List<Offset> profile, double z, double width, Color colour) {
      final pts = [
        for (final o in profile) V3(o.dx, o.dy, z),
        V3(profile.first.dx, profile.first.dy, z),
      ];
      // Split so a rail behind the vehicle sorts behind what is in front of it.
      const spans = 8;
      for (var s = 0; s < spans; s++) {
        final i0 = (pts.length - 1) * s ~/ spans;
        final i1 = (pts.length - 1) * (s + 1) ~/ spans;
        final span = pts.sublist(i0, i1 + 1);
        out.add(_Prim.wire(span, layout.depth(span[span.length ~/ 2]), colour, width,
            casing: false, dashPattern: true));
      }
    }

    loop(waist, _hgt * 0.31, 1.4, rail.withValues(alpha: 0.85));
    loop(crown, _hgt * 0.86, 1.2, rail.withValues(alpha: 0.7));
    loop(crown, _hgt, 1.6, rail.withValues(alpha: 0.9));
    // Corner posts, at the four corners and the two mid-flanks.
    for (final i in [0, 6, 12, 18, 3, 15]) {
      final o = waist[i % waist.length];
      final c = crown[i % crown.length];
      out.add(_Prim.wire(
        [V3(o.dx, o.dy, _hgt * 0.31), V3(o.dx, o.dy, _hgt * 0.86), V3(c.dx, c.dy, _hgt)],
        layout.depth(V3(o.dx, o.dy, _hgt * 0.6)),
        rail.withValues(alpha: 0.55),
        1.2,
        casing: false,
        dashPattern: true,
      ));
    }
  }

  // -- devices ----------------------------------------------------------------

  void _addDevices(List<_Prim> out) {
    for (final n in allNodes) {
      if (!showCameras && n.kind == NodeKind.camera) continue;
      final mesh = meshFor(n).placed(
        anchorOf(n),
        yaw: headingFor(n),
        scale: deviceExaggeration,
      );
      final selected = selectedNodeId == n.id;
      final state = n.acuPort != null ? snapshot.link(n.acuPort!) : LinkState.unknown;
      // A faulted or selected part is tinted rather than recoloured: the shape is what says
      // which device it is, and repainting it flat red throws that away.
      final tint = selected
          ? Tone.accent
          : (state == LinkState.unknown ? null : linkColour(state, Tone.faint));
      _emit(out, mesh, tint: tint, tintAmount: selected ? 0.34 : 0.42);
    }
  }

  void _emit(List<_Prim> out, Mesh mesh, {Color? tint, double tintAmount = 0.4}) {
    for (final q in mesh.quads) {
      final colour = tint == null ? q.colour : Color.lerp(q.colour, tint, tintAmount)!;
      out.add(_Prim.face(
        Quad(q.p, colour, shading: q.shading, alpha: q.alpha, outline: q.outline),
        layout.depth(q.centre),
      ));
    }
  }

  // -- harness ----------------------------------------------------------------

  /// Cables routed out to the flank and down the sill, the way a loom actually runs, and sorted
  /// into the scene so a run behind the vehicle is drawn behind it.
  void _addCables(List<_Prim> out) {
    final acu = nodeById('acu_it')!;
    final end = anchorOf(acu) + const V3(0, 0, 0.05);
    for (final n in allNodes) {
      if (n.acuPort == null) continue;
      final start = anchorOf(n);
      final state = snapshot.link(n.acuPort!);
      final selected = selectedNodeId == n.id;
      final colour = runColour(state, const Color(0xFF93A1B5));

      final side = n.pos.dx.abs() < 0.2 ? (n.pos.dy < 0.5 ? -1.0 : 1.0) : n.pos.dx.sign;
      final via = V3(side * _wid * 0.46, (start.y + end.y) / 2, _hgt * 0.34);
      final pts = <V3>[];
      const steps = 18;
      for (var i = 0; i <= steps; i++) {
        final t = i / steps;
        final u = 1 - t;
        pts.add(V3(
          u * u * start.x + 2 * u * t * via.x + t * t * end.x,
          u * u * start.y + 2 * u * t * via.y + t * t * end.y,
          u * u * start.z + 2 * u * t * via.z + t * t * end.z,
        ));
      }
      // Split into a few spans so a cable that passes behind the body sorts correctly.
      const spans = 6;
      for (var s = 0; s < spans; s++) {
        final a = (pts.length - 1) * s ~/ spans;
        final b = (pts.length - 1) * (s + 1) ~/ spans;
        final span = pts.sublist(a, b + 1);
        final mid = span[span.length ~/ 2];
        out.add(_Prim.wire(
          span,
          layout.depth(mid),
          colour.withValues(alpha: selected ? 0.95 : 0.5),
          selected ? 3.0 : 1.7,
          dashed: state == LinkState.down,
        ));
      }
    }
  }

  /// The backbone runs. Drawn heavier than a sensor drop and in the backbone's own colour when
  /// idle, because they are the thing the reconfiguration demo is about.
  void _addTrunks(List<_Prim> out) {
    for (final t in trunks) {
      final a = nodeById(t.from), b = nodeById(t.to);
      if (a == null || b == null) continue;
      final key = t.path == null ? 'trunk' : 'path${t.path}';
      final state = snapshot.link(key);
      final selected = selectedNodeId == t.from || selectedNodeId == t.to;
      final colour = runColour(state, Tone.tsn.withValues(alpha: 0.75));

      final start = anchorOf(a) + const V3(0, 0, 0.06);
      final end = anchorOf(b) + const V3(0, 0, 0.06);
      // Out to the sill on its own side, then straight down the vehicle: two runs that never
      // share a route are the only reason the pair is worth having.
      final side = t.path == 2 ? -1.0 : 1.0;
      final via = V3(side * _wid * 0.40, (start.y + end.y) / 2, _hgt * 0.335);
      final pts = <V3>[];
      const steps = 20;
      for (var i = 0; i <= steps; i++) {
        final u = 1 - i / steps, v = i / steps;
        pts.add(V3(
          u * u * start.x + 2 * u * v * via.x + v * v * end.x,
          u * u * start.y + 2 * u * v * via.y + v * v * end.y,
          u * u * start.z + 2 * u * v * via.z + v * v * end.z,
        ));
      }
      const spans = 6;
      for (var s = 0; s < spans; s++) {
        final i0 = (pts.length - 1) * s ~/ spans;
        final i1 = (pts.length - 1) * (s + 1) ~/ spans;
        final span = pts.sublist(i0, i1 + 1);
        out.add(_Prim.wire(
          span,
          layout.depth(span[span.length ~/ 2]),
          colour.withValues(alpha: selected ? 0.98 : 0.8),
          selected ? 4.0 : 2.8,
          dashed: state == LinkState.down,
        ));
      }
    }
  }

  // -- primitives -------------------------------------------------------------

  void _drawQuad(Canvas canvas, Quad q) {
    final pts = [for (final v in q.p) layout.project(v)];
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    path.close();
    final lit = shade(q.colour, q.normal, q.shading);
    canvas.drawPath(path, Paint()..color = lit.withValues(alpha: lit.a * q.alpha));
    if (q.outline) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7
          ..color = Color.lerp(lit, const Color(0xFF0B1220), 0.42)!
              .withValues(alpha: 0.55 * q.alpha),
      );
    }
  }

  void _drawWire(Canvas canvas, _Prim p) {
    final pts = [for (final v in p.line!) layout.project(v)];
    var path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final o in pts.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    if (p.dashPattern) path = _dash(path);
    if (p.casing) {
      // Casing under core: a two-pass stroke reads as a sheathed cable rather than a hairline.
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = p.lineWidth + 1.8
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: 0.6),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = p.lineWidth
        ..strokeCap = StrokeCap.round
        ..color = p.lineColour!,
    );
    if (p.dashed) {
      final mid = pts[pts.length ~/ 2];
      final paint = Paint()
        ..color = Tone.bad
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(mid + const Offset(-5, -5), mid + const Offset(5, 5), paint);
      canvas.drawLine(mid + const Offset(5, -5), mid + const Offset(-5, 5), paint);
    }
  }

  Path _dash(Path source) {
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        out.addPath(metric.extractPath(d, (d + 6).clamp(0.0, metric.length)), Offset.zero);
        d += 11;
      }
    }
    return out;
  }

  // -- annotation -------------------------------------------------------------

  void _paintSelection(Canvas canvas) {
    if (selectedNodeId == null) return;
    final c = layout.nodes[selectedNodeId!];
    if (c == null) return;
    for (var i = 2; i >= 0; i--) {
      canvas.drawCircle(
        c,
        20.0 + i * 7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Tone.accent.withValues(alpha: 0.30 - i * 0.09),
      );
    }
  }

  void _paintLabels(Canvas canvas) {
    final ordered = [...allNodes]
      ..removeWhere((n) => !showCameras && n.kind == NodeKind.camera)
      ..sort((a, b) {
        if (a.id == selectedNodeId) return -1;
        if (b.id == selectedNodeId) return 1;
        // Nearer parts get first refusal on their own shoulder.
        return layout.depth(anchorOf(b)).compareTo(layout.depth(anchorOf(a)));
      });
    for (final n in ordered) {
      _paintLabel(canvas, n);
    }
  }

  void _paintLabel(Canvas canvas, Node n) {
    final c = layout.nodes[n.id];
    if (c == null) return;
    final selected = selectedNodeId == n.id;
    // Ten camera names around one shuttle at 1280x800 cannot all be legible, and a screen of
    // overlapping labels is worse than none. Cameras stay parts until tapped; they are named in
    // the ACU_NO jack strip and in the inspector, where there is room for the full name.
    if (n.kind == NodeKind.camera && !selected) return;

    final label = switch (n.kind) {
      NodeKind.lidar => n.name.replaceAll(' · ', ' '),
      _ => n.name,
    };
    final tp = _painter(
      label,
      size: 10.5,
      colour: selected ? Colors.white : Tone.ink,
      weight: FontWeight.w700,
    );

    const gap = 16.0;
    final outboard = n.pos.dx >= 0 ? 1 : -1;
    final candidates = <Offset>[
      Offset(outboard * (gap + tp.width / 2), -6),
      Offset(-outboard * (gap + tp.width / 2), -6),
      Offset(0, -(gap + tp.height)),
      Offset(0, gap + tp.height),
      Offset(outboard * (gap + tp.width / 2), -(gap + tp.height)),
      Offset(outboard * (gap + tp.width / 2), gap + tp.height),
      Offset(-outboard * (gap + tp.width / 2), -(gap + tp.height)),
      Offset(-outboard * (gap + tp.width / 2), gap + tp.height),
      Offset(0, -(gap + tp.height * 2.2)),
      Offset(0, gap + tp.height * 2.2),
    ];
    Rect? chosen;
    for (final d in candidates) {
      final r = Rect.fromCenter(center: c + d, width: tp.width + 16, height: tp.height + 9);
      if (r.left < 2 || r.right > layout.size.width - 2) continue;
      if (_taken.any((t) => t.overlaps(r))) continue;
      chosen = r;
      break;
    }
    chosen ??= Rect.fromCenter(
      center: c + candidates.first,
      width: tp.width + 16,
      height: tp.height + 9,
    );
    _taken.add(chosen.inflate(2));

    // Leader from the part to the tag, drawn before the tag so it tucks under it.
    canvas.drawLine(
      c,
      chosen.center,
      Paint()
        ..strokeWidth = 1
        ..color = (selected ? Tone.accent : Tone.hairlineStrong).withValues(alpha: 0.9),
    );
    canvas.drawCircle(c, 2.6, Paint()..color = selected ? Tone.accent : Tone.hairlineStrong);

    final rr = RRect.fromRectAndRadius(chosen, const Radius.circular(7));
    canvas.drawRRect(
      rr,
      Paint()
        ..color = selected ? Tone.accent : Colors.white.withValues(alpha: 0.94),
    );
    if (!selected) {
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Tone.hairline,
      );
    }
    // A colour tick on the leading edge says which family the part belongs to.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(chosen.left + 5, chosen.center.dy - 4, 3, 8),
        const Radius.circular(2),
      ),
      Paint()..color = selected ? Colors.white : kindColour(n.kind),
    );
    tp.paint(canvas, Offset(chosen.left + 13, chosen.center.dy - tp.height / 2));
  }

  /// A quiet caption: which way the vehicle faces, and the one thing about this drawing that is
  /// not to scale.
  void _paintOrientation(Canvas canvas) {
    final front = layout.project(V3(0, -_len / 2 - 0.78, 0));
    final rear = layout.project(V3(0, _len / 2 + 0.62, 0));
    _text(canvas, 'FRONT', front, size: 9.5, colour: Tone.faint, weight: FontWeight.w800, spacing: 1.8, centre: true);
    _text(canvas, 'REAR', rear, size: 9.5, colour: Tone.faint, weight: FontWeight.w800, spacing: 1.8, centre: true);
    _text(
      canvas,
      'Devices from the sheet CAD, ${deviceExaggeration.toStringAsFixed(1)}× oversize · '
      'body is an envelope, not vehicle CAD',
      Offset(10, layout.size.height - 12),
      size: 9.5,
      colour: Tone.faint,
      weight: FontWeight.w600,
    );
  }

  TextPainter _painter(String s,
      {double size = 11,
      Color colour = Tone.ink,
      FontWeight weight = FontWeight.w600,
      double spacing = 0}) {
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
    Color colour = Tone.ink,
    FontWeight weight = FontWeight.w600,
    bool centre = false,
    double spacing = 0,
  }) {
    final tp = _painter(s, size: size, colour: colour, weight: weight, spacing: spacing);
    tp.paint(canvas, Offset(centre ? at.dx - tp.width / 2 : at.dx, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _Painter old) =>
      old.layout.yaw != layout.yaw ||
      old.layout.pitch != layout.pitch ||
      old.layout.size != layout.size ||
      old.snapshot != snapshot ||
      old.selectedNodeId != selectedNodeId ||
      old.showCameras != showCameras ||
      old.showCables != showCables ||
      old.flat != flat ||
      old.trunks.length != trunks.length;
}
