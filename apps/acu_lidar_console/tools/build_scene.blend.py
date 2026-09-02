"""Assemble the console's scene: the cleaned body, the CAD devices inside it, spinning wheels,
lamps that can be lit, and a plate.

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
* `PLATE` — a quad carrying a generated texture, so what it says is a string in this script and
  not a repaint of the body atlas.
"""

import json
import math
import os
import subprocess
import sys
import tempfile

import bmesh
import bpy
from mathutils import Matrix, Vector

# Devices are drawn larger than life. At true scale an ACU is 7% of a 4 m vehicle and disappears
# inside a translucent shell; the exaggeration is uniform so they stay in proportion to each other,
# and the app says so on screen.
DEVICE_SCALE = 1.6
WHEEL_SPIN_FRAMES = 48
PLATE_TEXT = 'ACU / LiDAR'


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
    for o in [x for x in bpy.data.objects if x.name.startswith('WHEEL_')]:
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


def make_plate_image(path, text):
    """Rendered here rather than painted into the body atlas, so the wording stays a string.

    Run through the system interpreter, not Blender's: `sys.executable` inside Blender is Blender,
    and its bundled Python has no PIL."""
    script = f'''
from PIL import Image, ImageDraw, ImageFont
W, H = 640, 160
im = Image.new('RGB', (W, H), (250, 250, 248))
d = ImageDraw.Draw(im)
d.rounded_rectangle([5, 5, W - 6, H - 6], radius=16, outline=(24, 30, 44), width=6)
font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 56)
t = {text!r}
box = d.textbbox((0, 0), t, font=font)
d.text(((W - (box[2] - box[0])) / 2, (H - (box[3] - box[1])) / 2 - box[1]), t,
       font=font, fill=(20, 26, 40))
im.save({path!r})
'''
    subprocess.run(['/usr/bin/python3', '-c', script], check=True)


def add_plate(lo, hi, text):
    size = hi - lo
    path = os.path.join(tempfile.gettempdir(), 'acu_plate.png')
    make_plate_image(path, text)

    w = size.x * 0.22
    h = w * 160 / 640
    y = lo.y + 0.015
    z = lo.z + size.z * 0.20
    me = bpy.data.meshes.new('PLATE')
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new('UVMap')
    pts = [
        Vector((-w, y, z - h)),
        Vector((w, y, z - h)),
        Vector((w, y, z + h)),
        Vector((-w, y, z + h)),
    ]
    face = bm.faces.new([bm.verts.new(p) for p in pts])
    for loop, coord in zip(face.loops, [(0, 0), (1, 0), (1, 1), (0, 1)]):
        loop[uv].uv = coord
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()

    mat = bpy.data.materials.new('plate')
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes['Principled BSDF']
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = bpy.data.images.load(path)
    nt.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    bsdf.inputs['Roughness'].default_value = 0.5
    obj = bpy.data.objects.new('PLATE', me)
    obj.data.materials.append(mat)
    bpy.context.scene.collection.objects.link(obj)
    return obj


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
    out = bytearray()
    for ctype, chunk in chunks:
        body = chunk
    total = 12 + 8 + len(js_chunk) + 8 + len(body)
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

    spin_wheels()
    carve_lamps(lo, hi)
    add_plate(lo, hi, PLATE_TEXT)

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
