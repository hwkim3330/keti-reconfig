import 'dart:math' as math;
import 'dart:ui';

/// A very small solid-geometry kit: enough to build the ACUs and the LiDARs out of boxes,
/// extruded profiles and cylinders, and to draw them with a painter's algorithm.
///
/// There is no renderer here on purpose. The projection is orthographic and the parts are convex
/// and well separated, so sorting quads back to front by their centre depth is correct, costs
/// nothing, and keeps the whole thing inside CustomPaint -- which is what makes it repaint in a
/// frame where the WebView scene it replaces took about a second to come back.
class V3 {
  final double x, y, z;

  const V3(this.x, this.y, this.z);

  V3 operator +(V3 o) => V3(x + o.x, y + o.y, z + o.z);
  V3 operator -(V3 o) => V3(x - o.x, y - o.y, z - o.z);
  V3 operator *(double s) => V3(x * s, y * s, z * s);

  V3 cross(V3 o) => V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double dot(V3 o) => x * o.x + y * o.y + z * o.z;

  double get length => math.sqrt(x * x + y * y + z * z);

  V3 get unit {
    final l = length;
    return l == 0 ? this : V3(x / l, y / l, z / l);
  }

  /// Rotation about the vertical axis, for parts that do not face straight ahead.
  V3 yawed(double a) => V3(x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a), z);
}

class Quad {
  final List<V3> p;
  final Color colour;

  /// 0 = flat fill, 1 = fully shaded by the light. Glass and emissive faces sit near 0 so they
  /// stay bright whichever way the part is turned.
  final double shading;
  final double alpha;
  final bool outline;

  const Quad(this.p, this.colour, {this.shading = 1, this.alpha = 1, this.outline = true});

  V3 get centre => V3(
        (p[0].x + p[1].x + p[2].x + p[3].x) / 4,
        (p[0].y + p[1].y + p[2].y + p[3].y) / 4,
        (p[0].z + p[1].z + p[2].z + p[3].z) / 4,
      );

  V3 get normal => (p[1] - p[0]).cross(p[3] - p[0]).unit;
}

/// Builds a part in its own frame: x right, y towards the vehicle's rear, z up.
class Mesh {
  final List<Quad> quads = [];

  void add(Quad q) => quads.add(q);

  void addAll(Iterable<Quad> qs) => quads.addAll(qs);

  /// An axis-aligned box. [half] is the half-extent on each axis.
  void box(
    V3 c,
    V3 half,
    Color colour, {
    Color? top,
    double shading = 1,
    double alpha = 1,
    bool outline = true,
  }) {
    final x0 = c.x - half.x, x1 = c.x + half.x;
    final y0 = c.y - half.y, y1 = c.y + half.y;
    final z0 = c.z - half.z, z1 = c.z + half.z;
    void q(List<V3> pts, Color col) =>
        add(Quad(pts, col, shading: shading, alpha: alpha, outline: outline));
    q([V3(x0, y0, z1), V3(x1, y0, z1), V3(x1, y1, z1), V3(x0, y1, z1)], top ?? colour); // top
    q([V3(x0, y1, z0), V3(x1, y1, z0), V3(x1, y0, z0), V3(x0, y0, z0)], colour); // bottom
    q([V3(x0, y0, z0), V3(x1, y0, z0), V3(x1, y0, z1), V3(x0, y0, z1)], colour); // front (-y)
    q([V3(x1, y1, z0), V3(x0, y1, z0), V3(x0, y1, z1), V3(x1, y1, z1)], colour); // back (+y)
    q([V3(x0, y1, z0), V3(x0, y0, z0), V3(x0, y0, z1), V3(x0, y1, z1)], colour); // left
    q([V3(x1, y0, z0), V3(x1, y1, z0), V3(x1, y1, z1), V3(x1, y0, z1)], colour); // right
  }

  /// Extrudes a closed 2-D profile (x, y) between two heights. The workhorse for the rounded
  /// cases and for the vehicle shell.
  void extrude(
    List<Offset> profile,
    double z0,
    double z1,
    Color side, {
    Color? cap,
    double alpha = 1,
    bool outline = true,
    bool capBottom = false,
    double shading = 1,
  }) {
    for (var i = 0; i < profile.length; i++) {
      final a = profile[i];
      final b = profile[(i + 1) % profile.length];
      add(Quad(
        [V3(a.dx, a.dy, z0), V3(b.dx, b.dy, z0), V3(b.dx, b.dy, z1), V3(a.dx, a.dy, z1)],
        side,
        alpha: alpha,
        outline: outline,
        shading: shading,
      ));
    }
    if (cap != null) {
      // Fanned from the centroid: the profiles here are convex, so a fan is watertight.
      final cx = profile.map((p) => p.dx).reduce((a, b) => a + b) / profile.length;
      final cy = profile.map((p) => p.dy).reduce((a, b) => a + b) / profile.length;
      for (final z in capBottom ? [z0, z1] : [z1]) {
        for (var i = 0; i < profile.length; i++) {
          final a = profile[i];
          final b = profile[(i + 1) % profile.length];
          add(Quad(
            [V3(cx, cy, z), V3(a.dx, a.dy, z), V3(b.dx, b.dy, z), V3(cx, cy, z)],
            cap,
            alpha: alpha,
            outline: false,
            shading: shading,
          ));
        }
      }
    }
  }

  /// A disc lying in the x-z plane, facing +y. [cylinder] extrudes along z, so its caps lie flat;
  /// a socket on a vertical mating face needs a face-on disc, and drawn with a cylinder it reads
  /// as an ellipse lying on the floor.
  void disc(
    V3 c,
    double r,
    Color colour, {
    int segments = 18,
    double shading = 1,
    bool outline = false,
  }) {
    for (var i = 0; i < segments; i++) {
      final a0 = i * 2 * math.pi / segments;
      final a1 = (i + 1) * 2 * math.pi / segments;
      add(Quad(
        [
          c,
          V3(c.x + r * math.cos(a0), c.y, c.z + r * math.sin(a0)),
          V3(c.x + r * math.cos(a1), c.y, c.z + r * math.sin(a1)),
          c,
        ],
        colour,
        shading: shading,
        outline: outline,
      ));
    }
  }

  void cylinder(
    V3 base,
    double r,
    double h,
    Color side, {
    Color? cap,
    int segments = 20,
    double alpha = 1,
    bool outline = false,
  }) {
    final profile = [
      for (var i = 0; i < segments; i++)
        Offset(
          base.x + r * math.cos(i * 2 * math.pi / segments),
          base.y + r * math.sin(i * 2 * math.pi / segments),
        ),
    ];
    extrude(profile, base.z, base.z + h, side,
        cap: cap, alpha: alpha, outline: outline);
  }

  /// A rounded rectangle in plan, as a profile for [extrude].
  static List<Offset> roundedRect(double w, double d, double r, {int steps = 5, Offset c = Offset.zero}) {
    final pts = <Offset>[];
    final hw = w / 2 - r, hd = d / 2 - r;
    void corner(double cx, double cy, double a0) {
      for (var i = 0; i <= steps; i++) {
        final a = a0 + i * (math.pi / 2) / steps;
        pts.add(Offset(c.dx + cx + r * math.cos(a), c.dy + cy + r * math.sin(a)));
      }
    }

    corner(hw, hd, 0);
    corner(-hw, hd, math.pi / 2);
    corner(-hw, -hd, math.pi);
    corner(hw, -hd, -math.pi / 2);
    return pts;
  }

  /// A run of cooling fins along x, the feature that identifies both ACU cases and the
  /// Hummingbird in the sheet photographs.
  void fins({
    required V3 centre,
    required int count,
    required double span,
    required double depth,
    required double height,
    required double thickness,
    required Color colour,
  }) {
    for (var i = 0; i < count; i++) {
      final t = count == 1 ? 0.5 : i / (count - 1);
      final x = centre.x - span / 2 + t * span;
      box(
        V3(x, centre.y, centre.z + height / 2),
        V3(thickness / 2, depth / 2, height / 2),
        colour,
        outline: false,
      );
    }
  }

  /// Places the part on the vehicle: yaw first, then translate.
  Mesh placed(V3 at, {double yaw = 0, double scale = 1}) {
    final out = Mesh();
    for (final q in quads) {
      out.add(Quad(
        [for (final v in q.p) (v * scale).yawed(yaw) + at],
        q.colour,
        shading: q.shading,
        alpha: q.alpha,
        outline: q.outline,
      ));
    }
    return out;
  }
}

/// An orthographic axonometric camera. Yaw turns the model about the vertical, pitch tips it;
/// at pitch = pi/2 the vertical axis collapses and the projection is a plan.
class Projector {
  final double yaw;
  final double pitch;
  final double scale;
  final Offset origin;

  const Projector({
    required this.yaw,
    required this.pitch,
    required this.scale,
    required this.origin,
  });

  /// Fits [bounds] into [size], keeping [padX] free on each side and [padY] top and bottom. The
  /// projection is linear, so this is one pass: project at unit scale, then scale and centre what
  /// came out. (dart:ui has no EdgeInsets, and this file deliberately does not import Flutter.)
  factory Projector.fit({
    required Size size,
    required double yaw,
    required double pitch,
    required Iterable<V3> bounds,
    double padX = 0,
    double padY = 0,
    double shiftX = 0,
  }) {
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    for (final v in bounds) {
      final p = _raw(v, yaw, pitch);
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final w = math.max(maxX - minX, 1e-6);
    final h = math.max(maxY - minY, 1e-6);
    final scale = math.min(
      math.max(size.width - 2 * padX, 1) / w,
      math.max(size.height - 2 * padY, 1) / h,
    );
    return Projector(
      yaw: yaw,
      pitch: pitch,
      scale: scale,
      origin: Offset(
        size.width / 2 + shiftX - (minX + maxX) / 2 * scale,
        size.height / 2 - (minY + maxY) / 2 * scale,
      ),
    );
  }

  static Offset _raw(V3 v, double yaw, double pitch) {
    final sx = v.x * math.cos(yaw) - v.y * math.sin(yaw);
    final sy = v.x * math.sin(yaw) + v.y * math.cos(yaw);
    return Offset(sx, sy * math.sin(pitch) - v.z * math.cos(pitch));
  }

  Offset project(V3 v) => origin + _raw(v, yaw, pitch) * scale;

  /// Distance towards the camera. The screen basis is (1,0,0) and (0, sin p, -cos p), so the view
  /// direction is their cross product, (0, cos p, sin p): larger is nearer.
  double depth(V3 v) {
    final sy = v.x * math.sin(yaw) + v.y * math.cos(yaw);
    return sy * math.cos(pitch) + v.z * math.sin(pitch);
  }
}

/// The eight corners of an axis-aligned box, for [Projector.fit].
List<V3> boxBounds(V3 half, {V3 centre = const V3(0, 0, 0)}) => [
      for (final sx in [-1.0, 1.0])
        for (final sy in [-1.0, 1.0])
          for (final sz in [-1.0, 1.0])
            V3(centre.x + sx * half.x, centre.y + sy * half.y, centre.z + sz * half.z),
    ];

/// Fills one quad and, if it asks for it, strokes its edge in a darker tint of its own colour.
/// The outline is what makes a mass of grey castings read as separate parts.
void drawQuad(Canvas canvas, Projector p, Quad q, {double alpha = 1}) {
  final pts = [for (final v in q.p) p.project(v)];
  final path = Path()..moveTo(pts[0].dx, pts[0].dy);
  for (final o in pts.skip(1)) {
    path.lineTo(o.dx, o.dy);
  }
  path.close();
  final lit = shade(q.colour, q.normal, q.shading);
  final a = q.alpha * alpha;
  canvas.drawPath(path, Paint()..color = lit.withValues(alpha: lit.a * a));
  if (q.outline) {
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = Color.lerp(lit, const Color(0xFF0B1220), 0.42)!.withValues(alpha: 0.55 * a),
    );
  }
}

/// Draws a whole mesh back to front.
void drawMesh(Canvas canvas, Projector p, Iterable<Quad> quads, {double alpha = 1}) {
  final sorted = quads.toList()..sort((a, b) => p.depth(a.centre).compareTo(p.depth(b.centre)));
  for (final q in sorted) {
    drawQuad(canvas, p, q, alpha: alpha);
  }
}

/// Lambert-ish shading with a generous ambient floor. A CAD read wants every face legible, not a
/// dramatic one -- a face in shadow still has to show its edges.
Color shade(Color base, V3 normal, double amount) {
  const light = V3(-0.42, -0.46, 0.78);
  final ndl = normal.dot(light.unit).abs();
  final k = (1 - amount) + amount * (0.52 + 0.48 * ndl);
  return Color.from(
    alpha: base.a,
    red: (base.r * k).clamp(0, 1),
    green: (base.g * k).clamp(0, 1),
    blue: (base.b * k).clamp(0, 1),
  );
}
