import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/geom.dart';
import '../core/reference.dart';


/// Solid models of the hardware, built from the CAD views on the design sheets.
///
/// Every proportion below is read off a specific picture, and the comment on each builder says
/// which one. Nothing here is a manufacturer drawing: these are shapes that carry the features
/// you identify a part by on the vehicle -- which end the window is on, which face the fins are
/// on, where the connector comes out -- at the size that makes those features legible.

/// Real envelopes, in metres.
const _acuSize = V3(0.30, 0.24, 0.095);
const _hummingbirdSize = V3(0.12, 0.10, 0.095);
const _falconSize = V3(0.14, 0.21, 0.068);
const _hesaiSize = V3(0.103, 0.103, 0.075);
const _cameraSize = V3(0.042, 0.048, 0.034);
const _radarSize = V3(0.088, 0.026, 0.062);
const _switchSize = V3(0.165, 0.120, 0.042);

/// Devices are drawn oversize. At true scale an ACU is 6% of the vehicle's length and lands on
/// about ten pixels here, which is a dot with extra steps. The exaggeration is uniform, so the
/// parts stay in proportion to each other, and the view says so on screen.
const deviceExaggeration = 2.6;

class _Palette {
  static const acuFinRed = Color(0xFFC0736B);
  static const acuFinAlu = Color(0xFFC5CAD2);
  static const acuBody = Color(0xFF6D7358); // olive side walls, as the CAD renders them
  static const acuFaceDark = Color(0xFF3B424C);
  static const acuFaceGreen = Color(0xFF2F6B3F);
  static const bracket = Color(0xFF9BA2AB);
  static const connector = Color(0xFF2E6FD0);
  static const led = Color(0xFF56D07A);

  static const alu = Color(0xFFB6BCC5);
  static const aluDark = Color(0xFF959CA6);
  static const lens = Color(0xFF232B36);
  static const glass = Color(0xFFD9D8F4);
  static const casting = Color(0xFF7C8593);
  static const castingDark = Color(0xFF5A626F);

  static const hesaiBlue = Color(0xFF2F46DE);
  static const hesaiCap = Color(0xFF11172E);
  static const hesaiGlass = Color(0xFF0B1128);

  static const switchCase = Color(0xFF20262F);
  static const switchBand = Color(0xFFBE3F97);

  static const radarBody = Color(0xFF3A414C);
  static const radome = Color(0xFFCF8434);

  static const camBody = Color(0xFF2B323D);
  static const panel = Color(0xFFCBD2DC);
  static const panelDark = Color(0xFF39424F);
}

/// The a2z ACU case, from the CATIA views on sheets 1 and 5.
///
/// Both boxes are the same casting: an olive lower body carrying a coloured faceplate, and a
/// finned heatsink on top whose crown is narrower than its base, so the sides step in twice.
/// Only the anodising and the faceplate differ -- red heatsink and a dark grey face on ACU_IT,
/// bare aluminium and a green face on ACU_NO.
Mesh _acuCase({required bool it}) {
  final m = Mesh();
  final w = _acuSize.x, d = _acuSize.y, h = _acuSize.z;
  final bodyH = h * 0.42;
  final shoulderH = h * 0.16;
  final finH = h * 0.42;

  // Lower body. The faceplate is a thin slab on the front so it reads as a separate part.
  m.box(V3(0, 0, bodyH / 2), V3(w / 2, d / 2, bodyH / 2), _Palette.acuBody);
  m.box(
    V3(0, -d / 2 - 0.002, bodyH / 2),
    V3(w / 2, 0.002, bodyH / 2),
    it ? _Palette.acuFaceDark : _Palette.acuFaceGreen,
  );

  // Heatsink base and its chamfered shoulder.
  final fin = it ? _Palette.acuFinRed : _Palette.acuFinAlu;
  m.box(V3(0, 0, bodyH + shoulderH / 2), V3(w / 2, d / 2, shoulderH / 2), fin);
  final crown = w * 0.80;
  m.extrude(
    [
      Offset(-crown / 2, -d / 2),
      Offset(crown / 2, -d / 2),
      Offset(crown / 2, d / 2),
      Offset(-crown / 2, d / 2),
    ],
    bodyH + shoulderH,
    bodyH + shoulderH + finH * 0.22,
    fin,
    cap: fin,
  );

  // Fins: they run front to back and repeat across the width.
  m.fins(
    centre: V3(0, 0, bodyH + shoulderH + finH * 0.22),
    count: 17,
    span: crown * 0.94,
    depth: d * 0.92,
    height: finH * 0.78,
    thickness: w * 0.016,
    colour: fin,
  );

  // Mounting straps: a steel plate down each flank with two bosses.
  for (final s in [-1.0, 1.0]) {
    m.box(V3(s * (w / 2 + 0.008), 0, bodyH * 0.55), V3(0.004, d * 0.44, bodyH * 0.42),
        _Palette.bracket, outline: false);
    for (final y in [-d * 0.3, d * 0.3]) {
      m.cylinder(V3(s * (w / 2 + 0.014), y, bodyH * 0.2), 0.012, 0.012, _Palette.bracket,
          cap: _Palette.bracket, segments: 10);
    }
  }

  // Front panel furniture. Positions follow the faceplate drawings, not just the renders.
  final z = bodyH * 0.5;
  final fy = -d / 2 - 0.005;
  void port(double cx, double cw, double ch, {Color colour = _Palette.connector}) {
    m.box(V3(cx, fy, z), V3(cw / 2, 0.004, ch / 2), colour, outline: false);
  }

  if (it) {
    port(-w * 0.30, w * 0.20, bodyH * 0.34); // TOTAL I/O
    for (var i = 0; i < 4; i++) {
      m.box(V3(-w * 0.10, fy, bodyH * 0.28 + i * bodyH * 0.13), V3(0.004, 0.003, 0.004),
          _Palette.led, shading: 0.2, outline: false);
    }
    port(-w * 0.01, w * 0.05, bodyH * 0.22); // USB-C
    port(w * 0.10, w * 0.09, bodyH * 0.26); // LAN 1
    port(w * 0.24, w * 0.09, bodyH * 0.30); // LAN 2
    port(w * 0.37, w * 0.09, bodyH * 0.30); // LAN 3
  } else {
    port(-w * 0.40, w * 0.05, bodyH * 0.22); // USB-C
    for (var i = 0; i < 5; i++) {
      port(-w * 0.24 + i * w * 0.115, w * 0.085, bodyH * 0.24); // CAM 1-5
    }
    port(w * 0.41, w * 0.05, bodyH * 0.22); // USB-C
    port(-w * 0.34, w * 0.10, bodyH * 0.26); // LAN, lower row
    port(w * 0.02, w * 0.17, bodyH * 0.22); // TOTAL I/O, lower row
  }
  return m;
}

/// Hummingbird, from the bumper mounting view on sheet 2.
///
/// An aluminium block standing on a foot: the outboard face carries two stacked circular
/// apertures on a raised boss, and the inboard two-thirds of each flank is a dense vertical fin
/// stack. The connector leaves the top rear corner.
Mesh _hummingbird() {
  final m = Mesh();
  final w = _hummingbirdSize.x, d = _hummingbirdSize.y, h = _hummingbirdSize.z;

  m.box(V3(0, 0, h / 2), V3(w / 2, d / 2, h / 2), _Palette.alu);
  // Raised aperture boss on the front face, with the two windows.
  m.box(V3(-w * 0.16, -d / 2 - 0.004, h * 0.52), V3(w * 0.26, 0.005, h * 0.34),
      _Palette.aluDark, outline: false);
  for (final zc in [h * 0.70, h * 0.36]) {
    m.cylinder(V3(-w * 0.16, -d / 2 - 0.012, zc - 0.001), w * 0.15, 0.001, _Palette.lens,
        cap: _Palette.lens, segments: 16);
  }
  // Fin stack down the rear flank.
  for (var i = 0; i < 13; i++) {
    final y = -d * 0.12 + i * (d * 0.66 / 12);
    m.box(V3(w * 0.5 + 0.004, y, h * 0.52), V3(0.004, d * 0.018, h * 0.40),
        _Palette.aluDark, outline: false);
  }
  // Mount foot and the connector stub.
  m.box(V3(0, 0, h * 0.045), V3(w * 0.56, d * 0.56, h * 0.045), _Palette.aluDark, outline: false);
  m.box(V3(w * 0.24, d * 0.5 + 0.008, h * 0.86), V3(w * 0.14, 0.010, h * 0.13),
      _Palette.casting, outline: false);
  return m;
}

/// Falcon K1, from the roof mounting view on sheet 3.
///
/// A low pod lying on the roof: a rounded lozenge in plan, its forward half a single smooth
/// window and its rear half a finned casting, with the crown drawn in so the sides slope.
Mesh _falcon() {
  final m = Mesh();
  final w = _falconSize.x, d = _falconSize.y, h = _falconSize.z;

  final base = Mesh.roundedRect(w, d, w * 0.34, steps: 4);
  final crown = Mesh.roundedRect(w * 0.74, d * 0.80, w * 0.30, steps: 4);
  m.extrude(base, 0, h * 0.34, _Palette.casting);
  // The sloped shoulder, as a band of quads between the two profiles.
  for (var i = 0; i < base.length; i++) {
    final a = base[i], b = base[(i + 1) % base.length];
    final ca = crown[i], cb = crown[(i + 1) % crown.length];
    m.add(Quad(
      [V3(a.dx, a.dy, h * 0.34), V3(b.dx, b.dy, h * 0.34), V3(cb.dx, cb.dy, h), V3(ca.dx, ca.dy, h)],
      _Palette.casting,
    ));
  }
  m.extrude(crown, h, h, _Palette.castingDark, cap: _Palette.castingDark, outline: false);

  // The window: a facet standing proud of the forward face. Set flush, the body wall sorts in
  // front of it from most angles and the pod reads as a solid lump with no aperture at all.
  final gw = w * 0.56;
  m.add(Quad(
    [
      V3(-gw / 2, -d * 0.56, h * 0.06),
      V3(gw / 2, -d * 0.56, h * 0.06),
      V3(gw / 2, -d * 0.48, h * 0.92),
      V3(-gw / 2, -d * 0.48, h * 0.92),
    ],
    _Palette.glass,
    shading: 0.18,
  ));
  // Its surround, so the window reads as let into the casting rather than stuck on.
  for (final s in [-1.0, 1.0]) {
    m.box(V3(s * (gw / 2 + w * 0.045), -d * 0.46, h * 0.48), V3(w * 0.045, d * 0.06, h * 0.46),
        _Palette.castingDark, outline: false);
  }
  // Fins across the rear crown.
  for (var i = 0; i < 9; i++) {
    final y = d * 0.06 + i * (d * 0.30 / 8);
    m.box(V3(0, y, h + h * 0.05), V3(w * 0.30, d * 0.010, h * 0.05),
        _Palette.castingDark, outline: false);
  }
  // Harness gland at the rear, the only break-out the sheet shows.
  m.cylinder(V3(-w * 0.22, d * 0.44, h * 0.10), w * 0.10, h * 0.22, _Palette.castingDark,
      cap: _Palette.castingDark, segments: 10);
  return m;
}

/// The side LiDAR, from the unit view on sheet 4: a spinning drum with a glass band at the
/// waist, a finned crown, a base ring, and a connector stub with the pigtail.
Mesh _hesai() {
  final m = Mesh();
  final r = _hesaiSize.x / 2, h = _hesaiSize.z;

  m.cylinder(const V3(0, 0, 0), r * 0.97, h * 0.10, _Palette.hesaiCap,
      cap: _Palette.hesaiCap, segments: 22);
  m.cylinder(V3(0, 0, h * 0.10), r, h * 0.32, _Palette.hesaiBlue, segments: 22);
  m.cylinder(V3(0, 0, h * 0.42), r * 1.006, h * 0.18, _Palette.hesaiGlass, segments: 22);
  m.cylinder(V3(0, 0, h * 0.60), r, h * 0.18, _Palette.hesaiBlue, segments: 22);
  m.cylinder(V3(0, 0, h * 0.78), r * 1.02, h * 0.22, _Palette.hesaiCap,
      cap: _Palette.hesaiCap, segments: 22);
  // Crown fins, radial.
  for (var i = 0; i < 16; i++) {
    final a = i * 2 * math.pi / 16;
    final cx = math.cos(a) * r * 0.86, cy = math.sin(a) * r * 0.86;
    m.box(V3(cx, cy, h * 0.90), V3(r * 0.09, r * 0.09, h * 0.10),
        _Palette.hesaiCap, outline: false);
  }
  // Connector and pigtail.
  m.box(V3(-r * 1.16, 0, h * 0.22), V3(r * 0.22, r * 0.16, h * 0.09),
      _Palette.hesaiBlue, outline: false);
  m.box(V3(-r * 1.6, 0, h * 0.22), V3(r * 0.26, r * 0.10, h * 0.05),
      const Color(0xFFD8DCE2), outline: false);
  return m;
}

/// A radar: a flat slab with a radome standing slightly proud of it, and a bracket behind. Not a
/// manufacturer drawing -- the sheets have no radar in them at all -- but the shape is what tells
/// a radar from a camera at a glance, which is the job.
Mesh _radar() {
  final m = Mesh();
  final w = _radarSize.x, d = _radarSize.y, h = _radarSize.z;
  m.box(V3(0, 0, h / 2), V3(w / 2, d / 2, h / 2), _Palette.radarBody);
  m.box(V3(0, -d / 2 - 0.003, h / 2), V3(w * 0.42, 0.003, h * 0.40), _Palette.radome,
      shading: 0.55, outline: false);
  m.box(V3(0, d / 2 + 0.006, h / 2), V3(w * 0.20, 0.006, h * 0.22), _Palette.aluDark,
      outline: false);
  return m;
}

/// A camera: a small body with a lens barrel out of the front face.
Mesh _camera() {
  final m = Mesh();
  final w = _cameraSize.x, d = _cameraSize.y, h = _cameraSize.z;
  m.box(V3(0, 0, h / 2), V3(w / 2, d / 2, h / 2), _Palette.camBody);
  m.cylinder(V3(0, -d * 0.5 - 0.008, h * 0.5), w * 0.28, 0.008, _Palette.lens,
      cap: _Palette.lens, segments: 12);
  return m;
}

/// The cabin display and the two telematics boxes: plain parts, because the sheets give them
/// nothing but a port label. Drawing them as detailed as the LiDARs would imply a source that
/// does not exist.
Mesh _slab(V3 size, Color colour, {Color? face}) {
  final m = Mesh();
  m.box(V3(0, 0, size.z / 2), V3(size.x / 2, size.y / 2, size.z / 2), colour);
  if (face != null) {
    m.box(V3(0, -size.y / 2 - 0.002, size.z / 2), V3(size.x / 2 * 0.9, 0.002, size.z / 2 * 0.86),
        face, shading: 0.4, outline: false);
  }
  return m;
}

/// A TSN switch. Not an a2z part: this is the KETI box that gets inserted into the harness, so it
/// is modelled as what sits on the bench -- a shallow anodised case with a row of eight ports and
/// a status strip along the top, and a magenta band so it never gets mistaken for an ACU.
Mesh _tsnSwitch() {
  final m = Mesh();
  final w = _switchSize.x, d = _switchSize.y, h = _switchSize.z;

  m.box(V3(0, 0, h * 0.46), V3(w / 2, d / 2, h * 0.46), _Palette.switchCase);
  // Identification band across the top.
  m.box(V3(0, 0, h * 0.93), V3(w * 0.46, d * 0.44, h * 0.05), _Palette.switchBand,
      shading: 0.5, outline: false);
  // Eight ports, two rows of four, on the front face.
  for (var r = 0; r < 2; r++) {
    for (var c = 0; c < 4; c++) {
      m.box(
        V3(-w * 0.30 + c * w * 0.20, -d / 2 - 0.004, h * 0.30 + r * h * 0.34),
        V3(w * 0.065, 0.004, h * 0.115),
        _Palette.connector,
        outline: false,
      );
    }
  }
  // Link LEDs along the top edge of the face.
  for (var i = 0; i < 4; i++) {
    m.box(V3(w * 0.34, -d / 2 - 0.004, h * 0.24 + i * h * 0.16), V3(0.0035, 0.003, 0.0035),
        _Palette.led, shading: 0.15, outline: false);
  }
  // Mounting flanges.
  for (final s in [-1.0, 1.0]) {
    m.box(V3(s * (w / 2 + 0.010), 0, h * 0.06), V3(0.010, d * 0.34, h * 0.06),
        _Palette.bracket, outline: false);
  }
  return m;
}

final _cache = <String, Mesh>{};

/// The model for a device, in its own frame: x right, y towards the vehicle's rear, z up, origin
/// at the mounting face. Cached -- the geometry never changes, only where it is put.
Mesh meshFor(Node n) {
  final key = switch (n.kind) {
    NodeKind.lidar => n.model,
    NodeKind.acu => n.id,
    _ => n.kind.name,
  };
  return _cache.putIfAbsent(key, () {
    switch (n.kind) {
      case NodeKind.lidar:
        if (n.model.startsWith('Falcon')) return _falcon();
        if (n.model.startsWith('Hummingbird')) return _hummingbird();
        return _hesai();
      case NodeKind.acu:
        return _acuCase(it: n.id == 'acu_it');
      case NodeKind.radar:
        return _radar();
      case NodeKind.camera:
        return _camera();
      case NodeKind.display:
        return _slab(const V3(0.26, 0.02, 0.16), _Palette.panel, face: _Palette.panelDark);
      case NodeKind.tcu:
        return _slab(const V3(0.16, 0.13, 0.05), _Palette.panelDark);
      case NodeKind.tsn:
        return _tsnSwitch();
    }
  });
}

/// Which way the part faces, in radians about the vertical. Read from where the sheet puts the
/// device: bumper units look out of their end of the vehicle, flank units look sideways.
double headingFor(Node n) {
  // The switches face inboard, ports towards the middle of the vehicle, which is where every
  // drop and both trunks come from.
  if (n.id == 'tsn_fa' || n.id == 'tsn_fb') return math.pi;
  if (n.id == 'tsn_r') return 0;
  if (n.id.endsWith('_rear') || n.id == 'cam_rear') return math.pi;
  if (n.id.endsWith('_rl') || n.id.endsWith('_rr')) return math.pi; // rear corner radars
  if (n.id.contains('_lh') || n.id == 'lidar_lh') return math.pi / 2;
  if (n.id.contains('_rh') || n.id == 'lidar_rh') return -math.pi / 2;
  return 0; // forward
}
