"""Clean the ROii body in Blender and export it as a named, real-scale binary GLB.

    /snap/bin/blender --background --factory-startup --python tools/clean_body.blend.py -- \
        assets/roii_body.glb assets/roii_body_clean.glb

What it fixes, and why each one matters to this console:

* **Names the parts.** Split by loose parts *before* welding — the panels are separate only in
  the unwelded mesh, because the exporter split every vertex at a UV seam and the seams follow the
  panel edges. Welded first, roof, floor, both flanks and both fascias collapse into one
  39,938-face lump. Split first and they come out as roof, floor, two flanks, two fascias and four
  wheels, which is what the model is actually made of. Each group is welded afterwards.
* **Gives each part its own material.** They all reference the same two textures, so it costs
  almost nothing, and it is the only way the app can hold the shell translucent while the wheels
  and floor stay solid: model-viewer's scene graph addresses materials, not nodes.
* **Puts it in metres, origin on the ground.** The model arrives 1.99 units long about its own
  centre. Scaled so the body is 4.0 m and dropped onto z = 0, so a mount height means something.
  4.0 m is an assumption, stated here and in the README: the sheets give no vehicle dimensions.
* **Halves the textures.** baseColor keeps its detail at 1024²; the ORM map goes to 512² because
  it is nearly a two-level mask — roughness sits at 0.25 ± 0.08 across the whole atlas, and
  metallic is bimodal, near 0 for the paint and glass and around 0.6 for the wheels and trim. A
  constant would have made the wheels plastic, so the map stays; it just does not need 2048².
"""

import math
import sys

import bmesh
import bpy
from mathutils import Vector

TARGET_LENGTH_M = 4.0
BASE_COLOR_PX = 1024
ORM_PX = 512


def tidy(obj):
    """Take the rubbish out of one part.

    The model is a single-skin export with 11,880 non-manifold edges, duplicated shells and
    zero-area scraps. Left in, they read as the jagged holes and speckle you see through a
    translucent panel: with alpha blending every interior face shows through the one in front of
    it. So interior faces go, loose geometry goes, degenerate faces go, and what is left is
    single-sided -- which is the change that actually cleans up the look, because a back face seen
    through a translucent front face is exactly the mess.
    """
    me = obj.data
    before = len(me.polygons)

    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.dissolve_degenerate(bm, dist=1e-6, edges=bm.edges)
    # Faces with no area at all: 4 of the 606 islands were nothing but these.
    dead = [f for f in bm.faces if f.calc_area() < 1e-9]
    if dead:
        bmesh.ops.delete(bm, geom=dead, context='FACES')
    # Wire and stray vertices left behind by the deletions.
    loose_v = [v for v in bm.verts if not v.link_faces]
    if loose_v:
        bmesh.ops.delete(bm, geom=loose_v, context='VERTS')
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.update()

    # Interior faces, the ones that can only be seen through another face.
    bpy.context.tool_settings.mesh_select_mode = (False, False, True)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='DESELECT')
    bpy.ops.mesh.select_interior_faces()
    bpy.ops.mesh.delete(type='FACE')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode='OBJECT')

    bpy.ops.object.shade_auto_smooth(angle=math.radians(35))
    print(f'    tidied {obj.name}: {before} -> {len(obj.data.polygons)} faces')


def classify(obj):
    """Name a loose part from where it sits and how flat it is.

    Blender's glTF import maps glTF (x, y, z) to (x, -z, y), so the vehicle's length runs along
    Blender's Y and its front — glTF +Z, the end the front bumper hotspot lands on — is at -Y.
    """
    d = obj.dimensions
    c = obj.matrix_world @ (0.125 * sum((Vector(v) for v in obj.bound_box), Vector()))

    # A wheel is a disc: thin across the vehicle and roughly as tall as it is long. The first
    # version asked only for "thin, low and outboard", which is also true of the sill strips --
    # one of them runs 0.97 m down the whole flank -- so they joined the wheel groups and dragged
    # each group's origin off the hub. The spin then looked like the wheel orbiting the car.
    if d.x < 0.09 and abs(c.x) > 0.30 and c.z < -0.30:
        ratio = d.y / d.z if d.z > 1e-6 else 99
        if 0.80 < ratio < 1.25 and 0.20 < d.z < 0.45:
            side = 'L' if c.x < 0 else 'R'
            end = 'F' if c.y < 0 else 'R'
            return f'WHEEL_{end}{side}'
        return 'SILL'
    if c.z > 0.30 and d.x > 0.4:
        return 'ROOF'
    if c.z < -0.33 and d.x > 0.4:
        return 'FLOOR'
    if d.y < 0.35 and c.y < -0.55:
        return 'FASCIA_FRONT'
    if d.y < 0.35 and c.y > 0.55:
        return 'FASCIA_REAR'
    if c.x < -0.22 and d.x < 0.25:
        return 'SIDE_L'
    if c.x > 0.22 and d.x < 0.25:
        return 'SIDE_R'
    return 'TRIM'


def main(src, dst):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)

    body = next(o for o in bpy.data.objects if o.type == 'MESH')
    bpy.context.view_layer.objects.active = body
    before = len(body.data.vertices)

    # Split first, weld second. The panels are separate only in the *unwelded* mesh: the exporter
    # split every vertex at a UV seam and the seams follow the panel edges, so the shell is one
    # connected surface once you merge them. Welding first collapsed roof, floor, both flanks and
    # both fascias into a single 39,938-face lump called TRIM.
    bpy.ops.object.select_all(action='DESELECT')
    body.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.separate(type='LOOSE')
    bpy.ops.object.mode_set(mode='OBJECT')

    parts = [o for o in bpy.data.objects if o.type == 'MESH']
    print(f'islands before weld: {len(parts)}  (verts {before})')

    groups = {}
    for o in parts:
        groups.setdefault(classify(o), []).append(o)
    for name in sorted(groups, key=lambda k: -sum(len(o.data.polygons) for o in groups[k])):
        tris = sum(len(o.data.polygons) for o in groups[name])
        print(f'  {name:<14} {len(groups[name]):>4} islands  {tris:>6} faces')

    # Join each group into one object, so the app addresses a part by one node name.
    merged = []
    for name, members in groups.items():
        bpy.ops.object.select_all(action='DESELECT')
        for o in members:
            o.select_set(True)
        bpy.context.view_layer.objects.active = members[0]
        if len(members) > 1:
            bpy.ops.object.join()
        joined = bpy.context.view_layer.objects.active
        joined.name = name
        joined.data.name = name
        # Weld inside the group now that the panel boundaries have done their job.
        bm = bmesh.new()
        bm.from_mesh(joined.data)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        bmesh.ops.dissolve_degenerate(bm, dist=1e-6, edges=bm.edges)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.to_mesh(joined.data)
        bm.free()
        joined.data.update()
        tidy(joined)

        # One material per part, all pointing at the same textures. model-viewer can address a
        # material but not a node, so this is what lets the shell go translucent on its own.
        if joined.data.materials:
            copy = joined.data.materials[0].copy()
            copy.name = f'part_{name}'
            # Single-sided. Exported doubleSided=false, so a translucent panel stops showing its
            # own inside; this is what turns the speckled mess into a clean pane of glass.
            copy.use_backface_culling = True
            joined.data.materials[0] = copy
        merged.append(joined)

    # One transform for the lot: metres, front on -Y, sitting on z = 0, centred left to right.
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    for o in merged:
        for corner in o.bound_box:
            w = o.matrix_world @ Vector(corner)
            lo = Vector((min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z)))
            hi = Vector((max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z)))
    scale = TARGET_LENGTH_M / (hi.y - lo.y)
    centre = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
    for o in merged:
        o.matrix_world = (
            __import__('mathutils').Matrix.Scale(scale, 4)
            @ __import__('mathutils').Matrix.Translation(-centre)
            @ o.matrix_world
        )
    size = (hi - lo) * scale
    print(f'scaled x{scale:.4f} -> {size.x:.2f} m wide, {size.y:.2f} m long, {size.z:.2f} m tall')

    for img in bpy.data.images:
        if img.size[0] <= 4:
            continue
        target = ORM_PX if 'Image_1' in img.name or img.name.endswith('_1') else BASE_COLOR_PX
        # The ORM map is a near-binary mask; the colour atlas is the one carrying badges and
        # window frames, so it keeps the larger size.
        if img.size[0] > target:
            print(f'  {img.name}: {img.size[0]}x{img.size[1]} -> {target}x{target}')
            img.scale(target, target)

    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.gltf(
        filepath=dst,
        export_format='GLB',
        export_apply=True,
        export_yup=True,
        export_image_format='JPEG',
        export_jpeg_quality=90,
        use_selection=True,
    )
    print(f'wrote {dst}')


if __name__ == '__main__':
    argv = sys.argv[sys.argv.index('--') + 1:]
    main(argv[0], argv[1])
