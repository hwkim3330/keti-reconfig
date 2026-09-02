"""Assemble the console's scene: the cleaned body, the CAD devices inside it, spinning wheels,
lamps that can be lit.

    flutter test test/export_devices_test.dart          # -> build/devices.json
    /snap/bin/blender --background --factory-startup --python tools/build_scene.blend.py -- \
        assets/roii_body_clean.glb build/devices.json assets/roii_scene.glb

The device geometry has exactly one source: `lib/widgets/device_meshes.dart`. It is exported by a
test rather than reimplemented here, because two copies of the same shapes drift the first time
either is touched.

Everything this adds is addressable by name from the app:

* `DEV_<id>` — one node per device, vertex-coloured, so the ACU casting keeps its red crown and
  the Hesai its glass waist without eleven materials each.
* `WHEEL_*` — origin moved to the wheel centre and a 360 degree spin keyframed, so the app can
  play it. glTF animation is the only way to turn a wheel in model-viewer: its scene graph can
  reach a material but not a node transform.
* `LAMP_FRONT` / `LAMP_REAR` — emissive bars. The app raises emissive strength to switch them on.
"""

import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

# Devices are drawn larger than life. At true scale an ACU is 7% of a 4 m vehicle and disappears
# inside a translucent shell; the exaggeration is uniform so they stay in proportion to each other,
# and the app says so on screen.
DEVICE_SCALE = 1.6
WHEEL_SPIN_FRAMES = 48
TRUNK_SEGMENTS = 9
TRUNK_RADIUS = 0.022


def body_bounds():
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    for o in bpy.data.objects:
        if o.type != 'MESH':
            continue
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector((min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z)))
            hi = Vector((max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z)))
    return lo, hi


def vertex_colour_material(name):
    """One material, colour taken from the mesh. The device meshes carry a colour per face and a
    material each would mean seventy of them."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes['Principled BSDF']
    attr = nt.nodes.new('ShaderNodeVertexColor')
    attr.layer_name = 'Col'
    nt.links.new(attr.outputs['Color'], bsdf.inputs['Base Color'])
    bsdf.inputs['Roughness'].default_value = 0.45
    bsdf.inputs['Metallic'].default_value = 0.1
    return mat


def build_device(dev, lo, hi, scale):
    size = hi - lo
    origin = Vector((
        (lo.x + hi.x) / 2 + dev['nx'] * size.x / 2,
        lo.y + dev['ny'] * size.y,   # front of the body is -Y, so ny runs 0 at the front
        lo.z + dev['nz'] * size.z,
    ))

    me = bpy.data.meshes.new(f"DEV_{dev['id']}")
    bm = bmesh.new()
    layer = bm.loops.layers.color.new('Col')
    yaw = Matrix.Rotation(dev['yaw'], 4, 'Z')
    for quad in dev['quads']:
        pts = []
        for p in quad['p']:
            v = yaw @ (Vector(p) * scale)
            pts.append(bm.verts.new(origin + v))
        bm.verts.ensure_lookup_table()
        try:
            face = bm.faces.new(pts)
        except ValueError:
            continue  # a degenerate quad from a fan cap; nothing to draw
        rgb = quad['c']
        colour = (
            ((rgb >> 16) & 255) / 255,
            ((rgb >> 8) & 255) / 255,
            (rgb & 255) / 255,
            quad['a'],
        )
        for loop in face.loops:
            loop[layer] = colour
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()

    obj = bpy.data.objects.new(f"DEV_{dev['id']}", me)
    obj.data.materials.append(vertex_colour_material(f"dev_{dev['id']}"))
    bpy.context.scene.collection.objects.link(obj)
    return obj


def spin_wheels():
    """Move each wheel's origin to its own centre and keyframe a full turn about the lateral axis.

    Without the origin move the wheel orbits the vehicle instead of turning."""
    scene = bpy.context.scene
    scene.frame_start = 1
    scene.frame_end = WHEEL_SPIN_FRAMES
    # Set the interpolation before inserting rather than editing curves afterwards: Blender 5
    # moved F-curves into slotted actions and Action.fcurves is gone.
    bpy.context.preferences.edit.keyframe_new_interpolation_type = 'LINEAR'
    import re
    wheels = [x for x in bpy.data.objects if re.fullmatch(r'WHEEL_[FR][LR]', x.name)]
    for o in wheels:
        bpy.ops.object.select_all(action='DESELECT')
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        # The hub, not the group centre. With the group now holding only the disc islands the
        # bounding-box centre is the hub; it was not when the sill strips were still in there.
        bpy.ops.object.origin_set(type='ORIGIN_GEOMETRY', center='BOUNDS')
        print('    hub at (%.3f %.3f %.3f)' % tuple(o.matrix_world.translation))
        o.rotation_mode = 'XYZ'
        for frame, angle in ((1, 0.0), (WHEEL_SPIN_FRAMES, -2 * math.pi)):
            o.rotation_euler = (angle, 0, 0)
            o.keyframe_insert('rotation_euler', frame=frame)
        print(f'  spin {o.name}')


def add_trunks(payload, lo, hi, scale):
    """The links between the switches, as geometry, cut into segments the app can light in turn.

    A static line says the switches are wired together. A line whose segments light one after the
    other says traffic is moving through it, and a line that goes red and stops says the module
    opened -- which is the whole demo. Nine segments per run is enough to read as motion on a
    tablet without turning into a dotted line.
    """
    size = hi - lo

    def place(dev):
        return Vector((
            (lo.x + hi.x) / 2 + dev['nx'] * size.x / 2,
            lo.y + dev['ny'] * size.y,
            lo.z + dev['nz'] * size.z + 0.04 * scale,
        ))

    by_id = {d['id']: d for d in payload['devices']}
    runs = (
        (1, 'tsn_fa', 'tsn_r'),
        (2, 'tsn_fb', 'tsn_r'),
        (3, 'tsn_fa', 'tsn_fb'),
    )
    for path, a_id, b_id in runs:
        if a_id not in by_id or b_id not in by_id:
            continue
        a, b = place(by_id[a_id]), place(by_id[b_id])
        # Bowed outboard so the three runs do not lie on top of each other, and lifted a little
        # so they read above the floor rather than inside it.
        side = 1.0 if path == 1 else (-1.0 if path == 2 else 0.0)
        mid = (a + b) / 2 + Vector((side * size.x * 0.16, 0, size.z * (0.05 if path == 3 else 0.02)))
        if path == 3:
            mid += Vector((-size.x * 0.24, 0, 0))

        pts = []
        for i in range(TRUNK_SEGMENTS + 1):
            t = i / TRUNK_SEGMENTS
            u = 1 - t
            pts.append(u * u * a + 2 * u * t * mid + t * t * b)

        for k in range(TRUNK_SEGMENTS):
            p0, p1 = pts[k], pts[k + 1]
            centre = (p0 + p1) / 2
            direction = p1 - p0
            length = direction.length
            if length < 1e-6:
                continue
            me = bpy.data.meshes.new(f'TRUNK{path}_S{k}')
            bm = bmesh.new()
            bmesh.ops.create_cube(bm, size=1.0)
            bmesh.ops.scale(bm, vec=(TRUNK_RADIUS * scale, TRUNK_RADIUS * scale, length),
                            verts=bm.verts)
            bm.to_mesh(me)
            bm.free()
            obj = bpy.data.objects.new(f'TRUNK{path}_S{k}', me)
            obj.location = centre
            obj.rotation_mode = 'QUATERNION'
            obj.rotation_quaternion = direction.to_track_quat('Z', 'Y')

            mat = bpy.data.materials.new(f'trunk{path}_s{k}')
            mat.use_nodes = True
            bsdf = mat.node_tree.nodes['Principled BSDF']
            base = (0.75, 0.25, 0.60, 1.0)
            bsdf.inputs['Base Color'].default_value = base
            bsdf.inputs['Emission Color'].default_value = base
            # Exported lit so the factor survives; the app sets the level, one segment at a time.
            bsdf.inputs['Emission Strength'].default_value = 1.0
            bsdf.inputs['Roughness'].default_value = 0.35
            me.materials.append(mat)
            bpy.context.scene.collection.objects.link(obj)
        print(f'  TRUNK{path}: {TRUNK_SEGMENTS} segments')


def rebuild_wheels():
    """Throw the imported wheels away and generate clean ones.

    The originals are a low-poly blob: the tyre reads as a pillow, the arch is surrounded by
    jagged shards left from the same low-poly skin, and the front pair arrive as two coincident
    discs that z-fight. None of that is fixable by tidying -- there is not enough geometry in
    there to be tidy. A wheel is a cylinder, a flat cover and a cross, and generated it is exact,
    lighter, and spins about an axis that is its own by construction.

    Returns the hubs so the spin can be keyframed on them.
    """
    originals = [o for o in bpy.data.objects if o.name.startswith('WHEEL_')]
    if not originals:
        return []

    hubs = []
    for o in originals:
        pts = [o.matrix_world @ Vector(c) for c in o.bound_box]
        lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
        hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
        centre = (lo + hi) / 2
        radius = max(hi.y - lo.y, hi.z - lo.z) / 2
        hubs.append((o.name, centre, radius))
        bpy.data.objects.remove(o, do_unlink=True)

    # One object per part, one material each. Packing tread, shoulders, cover, cross, cap and
    # well into a single mesh and assigning materials by face-index ranges was wrong by
    # construction: n-gon caps triangulate to different counts, so the ranges drifted and the
    # white cross came out wearing the tyre's material. Separate objects cannot drift. The cover,
    # cross and cap are parented to the tyre so the spin carries them; the well is not, because
    # a wheel arch does not turn.
    SEG = 64

    def cyl(bm, cx, cy, cz, r, w, segments=SEG):
        ret = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                                    radius1=r, radius2=r, depth=w)
        bmesh.ops.rotate(bm, verts=ret['verts'], cent=(0, 0, 0),
                         matrix=Matrix.Rotation(math.pi / 2, 3, 'Y'))
        bmesh.ops.translate(bm, verts=ret['verts'], vec=(cx, cy, cz))

    def solid(name, colour, rough, metal, build):
        me = bpy.data.meshes.new(name)
        bm = bmesh.new()
        build(bm)
        bm.to_mesh(me)
        bm.free()
        mat = bpy.data.materials.new(f'{name.lower()}')
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes['Principled BSDF']
        bsdf.inputs['Base Color'].default_value = (*colour, 1.0)
        bsdf.inputs['Roughness'].default_value = rough
        bsdf.inputs['Metallic'].default_value = metal
        mat.diffuse_color = (*colour, 1.0)
        me.materials.append(mat)
        obj = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(obj)
        return obj

    for name, centre, radius in hubs:
        side = 1.0 if centre.x > 0 else -1.0
        width = radius * 0.46
        outer = centre.x + side * width / 2
        cy, cz = centre.y, centre.z

        def tyre(bm):
            cyl(bm, centre.x, cy, cz, radius, width * 0.72)
            cyl(bm, centre.x - width * 0.43, cy, cz, radius * 0.955, width * 0.14)
            cyl(bm, centre.x + width * 0.43, cy, cz, radius * 0.955, width * 0.14)

        wheel = solid(name, (0.055, 0.058, 0.065), 0.94, 0.0, tyre)

        # A wheel face, not a texture: a recessed dish, four tapered spokes with a fillet, a rim
        # lip and a bolted cap. The two-box cross it replaces was the same shape the atlas already
        # draws flat, and at this size it read as two planks.
        cover = solid(f'{name}_DISH', (0.055, 0.058, 0.066), 0.88, 0.0,
                      lambda bm: cyl(bm, outer - side * 0.012, cy, cz, radius * 0.94, 0.006))

        def lip(bm):
            cyl(bm, outer + side * 0.004, cy, cz, radius * 1.0, 0.022)
            cyl(bm, outer + side * 0.006, cy, cz, radius * 0.93, 0.020)

        lip_obj = solid(f'{name}_LIP', (0.30, 0.32, 0.35), 0.35, 0.55, lip)

        def spokes(bm):
            face_x = outer + side * 0.008
            thick = 0.020
            inner_r, outer_r = radius * 0.19, radius * 0.93
            inner_w, outer_w = radius * 0.165, radius * 0.105
            for k in range(4):
                a = math.pi / 4 + k * math.pi / 2
                ux, uy = math.cos(a), math.sin(a)
                px, py = -uy, ux
                ring = []
                for r, hw in ((inner_r, inner_w), (outer_r, outer_w)):
                    for sw in (-1, 1):
                        for st in (-1, 1):
                            ring.append(bm.verts.new((
                                face_x + side * st * thick / 2,
                                cy + uy * r + py * sw * hw,
                                cz + ux * r + px * sw * hw,
                            )))
                # ring order: inner(-w,-t) inner(-w,+t) inner(+w,-t) inner(+w,+t) then outer
                i0, i1, i2, i3, o0, o1, o2, o3 = ring
                for quad in ((i0, i1, i3, i2), (o2, o3, o1, o0),
                             (i0, i2, o2, o0), (i3, i1, o1, o3),
                             (i1, i0, o0, o1), (i2, i3, o3, o2)):
                    try:
                        bm.faces.new(quad)
                    except ValueError:
                        pass
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

        cross_obj = solid(f'{name}_SPOKES', (0.86, 0.88, 0.90), 0.28, 0.35, spokes)

        def hub(bm):
            cyl(bm, outer + side * 0.020, cy, cz, radius * 0.21, 0.012, segments=28)
            for k in range(5):
                a = k * 2 * math.pi / 5
                cyl(bm, outer + side * 0.028, cy + math.sin(a) * radius * 0.135,
                    cz + math.cos(a) * radius * 0.135, radius * 0.028, 0.008, segments=10)

        cap = solid(f'{name}_CAP', (0.46, 0.48, 0.52), 0.32, 0.65, hub)

        for child in (cover, lip_obj, cross_obj, cap):
            child.parent = wheel
            child.matrix_parent_inverse = wheel.matrix_world.inverted()

        solid(f'WELL_{name.split("_")[1]}', (0.055, 0.058, 0.064), 0.95, 0.0,
              lambda bm: cyl(bm, centre.x - side * width * 0.55, cy, cz, radius * 1.0,
                             width * 1.5))

        faces = sum(len(o.data.polygons) for o in (wheel, cover, lip_obj, cross_obj, cap))
        print(f'  {name}: r {radius:.3f} w {width:.3f}, {faces} faces over 5 parts + well')

    # No face culling around the openings. It was tried at two radii: tight, it left the ragged
    # lip of the old cut; wide, it took 2,392 faces out of the body and the "jagged notch" beside
    # the wheel was the hole that made. A torn boundary cannot be tidied by removing more of it,
    # so the liner above covers it instead -- which is what covers it on a real vehicle.

    return hubs


def _rounded_rect(w, d, r, steps=5):
    """A rounded rectangle in plan, as (x, y) pairs. The Dart side has this in core/geom.dart;
    Blender cannot import that, and one shape is not worth a shared format."""
    pts = []
    hw, hd = w / 2 - r, d / 2 - r
    for cx, cy, a0 in ((hw, hd, 0.0), (-hw, hd, math.pi / 2),
                       (-hw, -hd, math.pi), (hw, -hd, -math.pi / 2)):
        for i in range(steps + 1):
            a = a0 + i * (math.pi / 2) / steps
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def add_valance(lo, hi):
    """A trim strip along the bottom of each fascia.

    The fascia meshes end in a torn boundary -- they were cut around the old blob wheels -- and
    that ragged white edge is what reads as a dirty bumper. A strip across it gives the bumper a
    straight bottom line, which is what the moulding does on the real thing.
    """
    size = hi - lo
    for name, y, depth in (('VALANCE_FRONT', lo.y + size.y * 0.020, 1),
                           ('VALANCE_REAR', hi.y - size.y * 0.020, -1)):
        me = bpy.data.meshes.new(name)
        bm = bmesh.new()
        ret = bmesh.ops.create_cube(bm, size=1.0)
        bmesh.ops.scale(bm, verts=ret['verts'],
                        vec=(size.x * 0.50, size.y * 0.026, size.z * 0.024))
        bmesh.ops.translate(bm, verts=ret['verts'],
                            vec=((lo.x + hi.x) / 2, y, lo.z + size.z * 0.088))
        bm.to_mesh(me)
        bm.free()
        mat = bpy.data.materials.new(f'valance_{name.lower()}')
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes['Principled BSDF']
        bsdf.inputs['Base Color'].default_value = (0.085, 0.090, 0.10, 1.0)
        bsdf.inputs['Roughness'].default_value = 0.8
        me.materials.append(mat)
        obj = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(obj)
        print(f'  {name}: {len(me.polygons)} faces')


def add_undertray(lo, hi):
    """Close the bottom.

    The shell has no underside: from below it is an open void with the wheels hanging in it and
    the arch strips floating. One plate, facing down, single-sided -- so it costs nothing from
    above, where the back face is culled, and from below the vehicle has a floor.
    """
    size = hi - lo
    z = lo.z + size.z * 0.045
    cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
    profile = _rounded_rect(size.x * 0.80, size.y * 0.95, size.x * 0.24)

    me = bpy.data.meshes.new('UNDERTRAY')
    bm = bmesh.new()
    ring = [bm.verts.new((cx + px, cy + py, z)) for px, py in profile]
    centre = bm.verts.new((cx, cy, z))
    for i in range(len(ring)):
        a, b = ring[i], ring[(i + 1) % len(ring)]
        # Wound so the normal points down; nothing above the vehicle ever sees this.
        bm.faces.new([centre, b, a])
    bm.to_mesh(me)
    bm.free()

    mat = bpy.data.materials.new('undertray')
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes['Principled BSDF']
    bsdf.inputs['Base Color'].default_value = (0.13, 0.14, 0.16, 1.0)
    bsdf.inputs['Roughness'].default_value = 0.85
    mat.use_backface_culling = True
    me.materials.append(mat)
    obj = bpy.data.objects.new('UNDERTRAY', me)
    bpy.context.scene.collection.objects.link(obj)
    print(f'  UNDERTRAY: {len(me.polygons)} faces at z {z:.3f}')


def lamp_faces_check(obj):
    return obj.data.polygons


def carve_lamps(lo, hi):
    """Light the lamps the model already has, selected by where they are.

    Three heuristics were tried and all three ran away: bright-texture caught the white bumper,
    dark-texture caught most of the front end, and adding an outward-facing test only trimmed it.
    Texture colour is the wrong handle -- the atlas is not laid out by part. So the lamps are cut
    by position, out of an orthographic front render of this body: two clusters per end at
    x = +-0.53 m and z = 0.27 m, on a body 1.84 m wide and 2.17 m tall. A box cannot run away.
    """
    size = hi - lo
    cx = (lo.x + hi.x) / 2
    # Fractions of the body, so the boxes survive a rescale.
    dx, half_w = 0.575, 0.13      # cluster centre and half width, as a fraction of half-width
    z0, z1 = 0.085, 0.175         # fraction of height
    depth = 0.10                  # fraction of length, in from the end

    for end_name, name, tint, facing in (
        ('FASCIA_FRONT', 'LAMP_FRONT', (1.0, 0.95, 0.86), -1),
        ('FASCIA_REAR', 'LAMP_REAR', (1.0, 0.22, 0.16), 1),
    ):
        src = bpy.data.objects.get(end_name)
        if src is None:
            continue
        y_end = lo.y if facing < 0 else hi.y
        me = src.data
        chosen = []
        for poly in me.polygons:
            c = src.matrix_world @ poly.center
            if abs(c.y - y_end) > size.y * depth:
                continue
            if not (lo.z + size.z * z0 <= c.z <= lo.z + size.z * z1):
                continue
            if poly.normal.y * facing < 0.35:
                continue
            offset = abs(abs(c.x - cx) - size.x / 2 * dx)
            if offset > size.x / 2 * half_w:
                continue
            chosen.append(poly.index)
        if not chosen:
            print(f'  {name}: nothing in the lamp boxes, skipped')
            continue

        pts = [src.matrix_world @ me.vertices[v].co
               for i in chosen for v in me.polygons[i].vertices]
        bx = (min(p.x for p in pts), max(p.x for p in pts))
        bz = (min(p.z for p in pts), max(p.z for p in pts))
        print(f'  {name}: {len(chosen)} faces  x {bx[0]:.2f}..{bx[1]:.2f}  z {bz[0]:.2f}..{bz[1]:.2f}')

        # Clear vertices and edges too, and set face mode *before* entering edit. The mesh
        # arrives with everything selected from the split in clean_body; clearing only the polygon
        # flags left every vertex selected, and select_mode(FACE) then re-derived "all faces" --
        # so the whole fascia separated out as the lamp and the front of the vehicle lit up.
        for v in me.vertices:
            v.select = False
        for e in me.edges:
            e.select = False
        for poly in me.polygons:
            poly.select = False
        for i in chosen:
            me.polygons[i].select = True
        bpy.context.tool_settings.mesh_select_mode = (False, False, True)
        bpy.ops.object.select_all(action='DESELECT')
        src.select_set(True)
        bpy.context.view_layer.objects.active = src
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.separate(type='SELECTED')
        bpy.ops.object.mode_set(mode='OBJECT')
        print(f'    {name} split: {len(lamp_faces_check(src))} left on {end_name}')

        lamp = [o for o in bpy.context.selected_objects if o is not src][-1]
        lamp.name = name
        lamp.data.name = name
        mat = lamp.data.materials[0].copy() if lamp.data.materials else bpy.data.materials.new(name)
        mat.name = f'lamp_{name.lower()}'
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes['Principled BSDF']
        bsdf.inputs['Emission Color'].default_value = (*tint, 1.0)
        # Exported lit, switched off by the app at load: a material exported with zero emission
        # loses its emissiveFactor and there is nothing left for anything to turn up.
        bsdf.inputs['Emission Strength'].default_value = 1.0
        if lamp.data.materials:
            lamp.data.materials[0] = mat
        else:
            lamp.data.materials.append(mat)


# No plate. It was a generated quad with text on it, and it was the untidiest thing on the
# vehicle: proud of a curved fascia, competing with the lamp panel, and its edge cutting across
# the bumper moulding. The body already carries its own plate recess in the atlas, which is
# enough -- and the console's name belongs in the console's chrome, not on the model.


def merge_wheel_animations(path):
    """Fold the four wheel clips into one.

    Blender writes an animation per action and model-viewer plays exactly one at a time, so four
    clips means one wheel turning and three standing still. The channels are independent, so
    merging them is concatenation with the sampler indices shifted."""
    import struct

    with open(path, 'rb') as fh:
        raw = fh.read()
    off, js, chunks = 12, None, []
    while off + 8 <= len(raw):
        clen, ctype = struct.unpack('<II', raw[off:off + 8])
        chunk = raw[off + 8:off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk)
        else:
            chunks.append((ctype, chunk))
        off += 8 + clen

    anims = js.get('animations', [])
    if len(anims) < 2:
        return
    channels, samplers = [], []
    for a in anims:
        base = len(samplers)
        samplers.extend(a['samplers'])
        for ch in a['channels']:
            ch = dict(ch)
            ch['sampler'] = ch['sampler'] + base
            channels.append(ch)
    js['animations'] = [{'name': 'wheels', 'channels': channels, 'samplers': samplers}]
    print(f'  merged {len(anims)} wheel clips into one with {len(channels)} channels')

    js_chunk = json.dumps(js, separators=(',', ':')).encode('utf-8')
    js_chunk += b' ' * ((4 - len(js_chunk) % 4) % 4)
    body = b''
    for _, chunk in chunks:
        body = chunk
    total = 12 + 8 + len(js_chunk) + 8 + len(body)
    out = bytearray()
    out += struct.pack('<III', 0x46546C67, 2, total)
    out += struct.pack('<II', len(js_chunk), 0x4E4F534A)
    out += js_chunk
    out += struct.pack('<II', len(body), 0x004E4942)
    out += body
    with open(path, 'wb') as fh:
        fh.write(out)


def main(body_path, devices_path, out_path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=body_path)
    lo, hi = body_bounds()
    print(f'body {tuple(round(v, 2) for v in (hi - lo))} m, origin {tuple(round(v, 2) for v in lo)}')

    payload = json.load(open(devices_path))
    for dev in payload['devices']:
        obj = build_device(dev, lo, hi, DEVICE_SCALE)
        print(f"  {obj.name}: {len(obj.data.polygons)} faces")

    rebuild_wheels()
    spin_wheels()
    add_undertray(lo, hi)
    add_valance(lo, hi)
    add_trunks(payload, lo, hi, DEVICE_SCALE)
    carve_lamps(lo, hi)

    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format='GLB',
        export_apply=True,
        export_yup=True,
        export_image_format='AUTO',
        export_jpeg_quality=90,
        export_animations=True,
        export_frame_range=True,
        # One clip, not one per wheel: model-viewer plays a single animation at a time, and
        # four separate actions means three wheels standing still.
        export_animation_mode='SCENE',
        use_selection=True,
    )
    merge_wheel_animations(out_path)
    print(f'wrote {out_path}')


if __name__ == '__main__':
    argv = sys.argv[sys.argv.index('--') + 1:]
    main(argv[0], argv[1], argv[2])
