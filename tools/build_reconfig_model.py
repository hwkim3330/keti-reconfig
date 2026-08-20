"""From v3 (cylinders removed), build v5:
  - reduce each path's 3 parallel end stubs to a single centreline wire
  - a thin line bridging front<->rear
  - a SMALL injection-module box, TEXTURE-MAPPED on all faces with a label image
    ("PATH 1" / "PATH 2") -> demonstrates a real image texture on 3D geometry.
Added geometry uses KHR_materials_unlit so the texture shows as-is.
"""
import json, base64, struct, io
import numpy as np
from PIL import Image, ImageDraw, ImageFont

SRC = "lib/assets/roii_reconfig.glb"
DST = "lib/assets/roii_reconfig_recon.glb"
LOGO = "/home/kim/keti-reconfig/traffic_generator/web/keti.png"
REAR_NEW_Z = -13.0   # move the rear switch to the back (was z=-4), mirroring the front
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

g = json.load(open(SRC))
nodes, meshes, acc, bufviews = g["nodes"], g["meshes"], g["accessors"], g["bufferViews"]
mats = {i: m.get("name", "") for i, m in enumerate(g["materials"])}
for key in ("images", "samplers", "textures", "extensionsUsed"):
    g.setdefault(key, [])
if "KHR_materials_unlit" not in g["extensionsUsed"]:
    g["extensionsUsed"].append("KHR_materials_unlit")

# ---- remove the Path 1/2 cylinder bodies + their wireframes (nodes 39,40,43,44) ----
for _i in (39, 40, 43, 44):
    g["nodes"][_i].pop("mesh", None)
print("removed path cylinders (39,40,43,44)")

# ---- hide off-centre stubs (keep x=±2.0 centreline) ----
def nm(n):
    if "matrix" in n: return np.array(n["matrix"], float).reshape(4, 4).T
    T = np.eye(4)
    if "translation" in n: T[:3, 3] = n["translation"]
    R = np.eye(4)
    if "rotation" in n:
        x, y, z, w = n["rotation"]
        R[:3, :3] = np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],
                              [2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],
                              [2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])
    S = np.eye(4)
    if "scale" in n:
        for i in range(3): S[i, i] = n["scale"][i]
    return T @ R @ S
world = {}
for r in g["scenes"][g.get("scene", 0)]["nodes"]:
    st = [(r, np.eye(4))]
    while st:
        i, p = st.pop(); world[i] = p @ nm(nodes[i])
        for c in nodes[i].get("children", []): st.append((c, world[i]))
def cx_of(i):
    mi = nodes[i]["mesh"]; cs = []
    for pr in meshes[mi]["primitives"]:
        a = pr["attributes"].get("POSITION")
        if a is None: continue
        mn, mx = acc[a]["min"], acc[a]["max"]
        for xx in (mn[0], mx[0]):
            for yy in (mn[1], mx[1]):
                for zz in (mn[2], mx[2]):
                    cs.append((world[i] @ np.array([xx, yy, zz, 1.0]))[:3])
    cs = np.array(cs); return (cs.min(0)[0] + cs.max(0)[0]) / 2
hidden = 0
for i, n in enumerate(nodes):
    if n.get("mesh") is None: continue
    name = mats.get(meshes[n["mesh"]]["primitives"][0].get("material"), "")
    if "connection-" in name and ("Path1" in name or "Path2" in name):
        if abs(abs(cx_of(i)) - 2.0) > 0.1:
            n.pop("mesh", None); hidden += 1
print("hidden stubs:", hidden)

# --- declutter: remove peripheral ECU boxes (solid + white wireframe) ---
def world_center(i):
    mi = nodes[i].get("mesh")
    if mi is None: return None
    pts = []
    for pr in meshes[mi]["primitives"]:
        a = pr["attributes"].get("POSITION")
        if a is None: continue
        mn, mx = acc[a]["min"], acc[a]["max"]
        for xx in (mn[0], mx[0]):
            for yy in (mn[1], mx[1]):
                for zz in (mn[2], mx[2]):
                    pts.append((world[i] @ np.array([xx, yy, zz, 1.0]))[:3])
    if not pts: return None
    pts = np.array(pts); return (pts.min(0) + pts.max(0)) / 2
REMOVE_ECUS = {"ACU_IT", "Sub_VCU", "CMU", "ACU_NO", "EDR/DSSA", "VCU", "TCU"}
ecu_centers = []
for i, n in enumerate(nodes):
    if n.get("mesh") is None: continue
    if mats.get(meshes[n["mesh"]]["primitives"][0].get("material"), "") in REMOVE_ECUS:
        c = world_center(i)
        if c is not None: ecu_centers.append(c)
        n.pop("mesh", None)
# their white wireframe twins sit at the same centre
removed_wf = 0
for i, n in enumerate(nodes):
    if n.get("mesh") is None: continue
    nm2 = mats.get(meshes[n["mesh"]]["primitives"][0].get("material"), "")
    if "wireframe" in nm2:
        c = world_center(i)
        if c is not None and any(np.linalg.norm(c - ec) < 0.6 for ec in ecu_centers):
            n.pop("mesh", None); removed_wf += 1
print("removed ECUs:", len(ecu_centers), "wireframes:", removed_wf)

# also remove the wires/ports that fed those now-gone ECUs (they dangle otherwise)
REMOVE_TOKENS = ("ACU_IT", "Sub_VCU", "CMU", "ACU_NO", "EDR", "DSSA", "VCU", "TCU")
removed_links = 0
for i, n in enumerate(nodes):
    if n.get("mesh") is None: continue
    nm2 = mats.get(meshes[n["mesh"]]["primitives"][0].get("material"), "")
    if (nm2.startswith("connection-") or nm2.startswith("port-")) and any(t in nm2 for t in REMOVE_TOKENS):
        n.pop("mesh", None); removed_links += 1
print("removed dangling wires/ports:", removed_links)

# --- move the rear switch (TSN-R) to the back of the vehicle ---
parent = {}
for pi, n in enumerate(nodes):
    for c in n.get("children", []): parent[c] = pi
# hide the original front & rear switch boxes (+ their wireframes); both are
# re-added below as textured boxes (TSN-F A / TSN-F B / TSN-R).
for i in (3, 4, 7, 8):
    nodes[i].pop("mesh", None)
print("hid original Front/Rear switch boxes (3,4,7,8)")

# hide everything that used to wire into the OLD rear-switch spot (they'd dangle):
# the path rear stubs and the multi-segment rear-lidar link (to be redrawn as one line).
hid_rz = 0
for i, n in enumerate(nodes):
    if n.get("mesh") is None: continue
    nm3 = mats.get(meshes[n["mesh"]]["primitives"][0].get("material"), "")
    if (nm3.startswith("connection-") or nm3.startswith("port-")) and "RearZC" in nm3:
        n.pop("mesh", None); hid_rz += 1
print("hid old rear-switch wires/ports:", hid_rz)

# remove the InlineESP marker boxes: ESP-AB on the front switch (node 171) and the
# two at the path locations (172,173) which duplicate the textured PATH boxes.
for i in (171, 172, 173):
    nodes[i].pop("mesh", None)
print("removed InlineESP boxes 171,172,173")

# the front lidar->front-switch links are big diagonal blobs; hide them and redraw
# as clean single lines below (lidar-focused cleanup).
hid_fl = 0
for i, n in enumerate(nodes):
    if n.get("mesh") is None: continue
    nm4 = mats.get(meshes[n["mesh"]]["primitives"][0].get("material"), "")
    if (nm4.startswith("connection-") or nm4.startswith("port-")) and \
       ("Lidar-FrontZC" in nm4 or "FrontZC-Path" in nm4):   # front lidar blobs + leftover path stubs
        n.pop("mesh", None); hid_fl += 1
print("hid front-lidar/path stubs:", hid_fl)

# (front/rear switches are re-added as textured boxes in the geometry section below)

# --- tidy wiring: one calm colour for every connection segment ---
recolored = 0
for i, m in enumerate(g["materials"]):
    if m.get("name", "").startswith("connection-"):
        m.setdefault("pbrMetallicRoughness", {})["baseColorFactor"] = [0.10, 0.42, 0.95, 1.0]  # clear blue = healthy
        recolored += 1
print("recolored wires:", recolored)

# ---- geometry buffers ----
pos = bytearray(); uv = bytearray(); idx = bytearray()
specs = []  # (pos_off, uv_off, vcount, pmin, pmax, idx_off, icount, material)

def add_line(cx, cy, cz, sx, sy, sz, material):
    hx, hy, hz = sx/2, sy/2, sz/2
    v = [(cx-hx,cy-hy,cz-hz),(cx+hx,cy-hy,cz-hz),(cx+hx,cy+hy,cz-hz),(cx-hx,cy+hy,cz-hz),
         (cx-hx,cy-hy,cz+hz),(cx+hx,cy-hy,cz+hz),(cx+hx,cy+hy,cz+hz),(cx-hx,cy+hy,cz+hz)]
    tris = [(0,1,2),(0,2,3),(4,6,5),(4,7,6),(0,4,5),(0,5,1),(1,5,6),(1,6,2),(2,6,7),(2,7,3),(3,7,4),(3,4,0)]
    po = len(pos)//12; uo = len(uv)//8
    for p in v: pos.extend(struct.pack("<3f", *p)); uv.extend(struct.pack("<2f", 0.0, 0.0))
    io_ = len(idx)
    for t in tris:
        for k in t: idx.extend(struct.pack("<H", k))
    specs.append((po, uo, 8, [cx-hx,cy-hy,cz-hz], [cx+hx,cy+hy,cz+hz], io_, len(tris)*3, material))

def add_line_between(p0, p1, th, material):
    """A thin box drawn from p0 to p1 (any direction)."""
    p0 = np.array(p0, float); p1 = np.array(p1, float)
    d = p1 - p0; L = float(np.linalg.norm(d))
    if L < 1e-6: return
    u = d / L
    z = np.array([0, 0, 1.0])
    vv = np.cross(z, u); c = float(np.dot(z, u))
    if np.linalg.norm(vv) < 1e-8:
        R = np.eye(3) if c > 0 else np.diag([1.0, -1.0, -1.0])
    else:
        K = np.array([[0, -vv[2], vv[1]], [vv[2], 0, -vv[0]], [-vv[1], vv[0], 0]])
        R = np.eye(3) + K + K @ K * (1.0 / (1.0 + c))
    mid = (p0 + p1) / 2
    h = th / 2
    corners_local = [(-h,-h,-L/2),(h,-h,-L/2),(h,h,-L/2),(-h,h,-L/2),
                     (-h,-h,L/2),(h,-h,L/2),(h,h,L/2),(-h,h,L/2)]
    v = [tuple((R @ np.array(cl)) + mid) for cl in corners_local]
    tris = [(0,1,2),(0,2,3),(4,6,5),(4,7,6),(0,4,5),(0,5,1),(1,5,6),(1,6,2),(2,6,7),(2,7,3),(3,7,4),(3,4,0)]
    po = len(pos)//12; uo = len(uv)//8
    for p in v: pos.extend(struct.pack("<3f", *p)); uv.extend(struct.pack("<2f", 0.0, 0.0))
    io_ = len(idx)
    for t in tris:
        for k in t: idx.extend(struct.pack("<H", k))
    arr = np.array(v)
    specs.append((po, uo, 8, arr.min(0).tolist(), arr.max(0).tolist(), io_, len(tris)*3, material))

def add_decal(cx, cy, cz, w, dd, material):
    """A flat quad lying on top of a box (normal +Y), UV-mapped to the whole image."""
    hw, hd = w/2, dd/2
    verts = [(cx-hw,cy,cz+hd),(cx+hw,cy,cz+hd),(cx+hw,cy,cz-hd),(cx-hw,cy,cz-hd)]
    uvs = [(1,1),(0,1),(0,0),(1,0)]          # flipped so the label reads upright from the front view
    tris = [(0,1,2),(0,2,3)]
    po = len(pos)//12; uo = len(uv)//8
    for k, vv in enumerate(verts):
        pos.extend(struct.pack("<3f", *vv)); uv.extend(struct.pack("<2f", *uvs[k]))
    io_ = len(idx)
    for t in tris:
        for k in t: idx.extend(struct.pack("<H", k))
    arr = np.array(verts)
    specs.append((po, uo, 4, arr.min(0).tolist(), arr.max(0).tolist(), io_, 6, material))

def logo_label_texture(name):
    """A clean white plate (25:18) : KETI logo on top, the switch name below."""
    W, H = 500, 360
    im = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    d = ImageDraw.Draw(im)
    logo = Image.open(LOGO).convert("RGBA")
    lw = int(W * 0.72); lh = int(logo.height * lw / logo.width)
    logo = logo.resize((lw, lh))
    im.paste(logo, ((W - lw)//2, 26), logo)
    f = ImageFont.truetype(FONT, 74)
    tb = d.textbbox((0, 0), name, font=f)
    d.text(((W-(tb[2]-tb[0]))/2 - tb[0], 26 + lh + 18), name, font=f, fill=(20, 32, 64, 255))
    buf = io.BytesIO(); im.save(buf, "PNG")
    g["images"].append({"uri": "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()})
    if not g["samplers"]:
        g["samplers"].append({"magFilter":9729,"minFilter":9987,"wrapS":10497,"wrapT":10497})
    g["textures"].append({"source": len(g["images"])-1, "sampler": 0})
    return len(g["textures"]) - 1

def add_textured_cube(cx, cy, cz, s, material):
    h = s/2
    # 6 faces, 4 verts each, UV (0,0)(1,0)(1,1)(0,1) upright on side faces
    faces = [
        # +Z front
        [(cx-h,cy-h,cz+h),(cx+h,cy-h,cz+h),(cx+h,cy+h,cz+h),(cx-h,cy+h,cz+h)],
        # -Z back
        [(cx+h,cy-h,cz-h),(cx-h,cy-h,cz-h),(cx-h,cy+h,cz-h),(cx+h,cy+h,cz-h)],
        # +X right
        [(cx+h,cy-h,cz+h),(cx+h,cy-h,cz-h),(cx+h,cy+h,cz-h),(cx+h,cy+h,cz+h)],
        # -X left
        [(cx-h,cy-h,cz-h),(cx-h,cy-h,cz+h),(cx-h,cy+h,cz+h),(cx-h,cy+h,cz-h)],
        # +Y top
        [(cx-h,cy+h,cz+h),(cx+h,cy+h,cz+h),(cx+h,cy+h,cz-h),(cx-h,cy+h,cz-h)],
        # -Y bottom
        [(cx-h,cy-h,cz-h),(cx+h,cy-h,cz-h),(cx+h,cy-h,cz+h),(cx-h,cy-h,cz+h)],
    ]
    uvs = [(0,1),(1,1),(1,0),(0,0)]  # v flipped so text is upright
    po = len(pos)//12; uo = len(uv)//8
    base = 0; tris = []
    allv = []
    for f in faces:
        for k,vv in enumerate(f):
            pos.extend(struct.pack("<3f", *vv)); uv.extend(struct.pack("<2f", *uvs[k])); allv.append(vv)
        tris += [(base,base+1,base+2),(base,base+2,base+3)]; base += 4
    io_ = len(idx)
    for t in tris:
        for k in t: idx.extend(struct.pack("<H", k))
    a = np.array(allv)
    specs.append((po, uo, len(faces)*4, a.min(0).tolist(), a.max(0).tolist(), io_, len(tris)*3, material))

def add_textured_box(cx, cy, cz, sx, sy, sz, material):
    hx, hy, hz = sx/2, sy/2, sz/2
    faces = [
        [(cx-hx,cy-hy,cz+hz),(cx+hx,cy-hy,cz+hz),(cx+hx,cy+hy,cz+hz),(cx-hx,cy+hy,cz+hz)],
        [(cx+hx,cy-hy,cz-hz),(cx-hx,cy-hy,cz-hz),(cx-hx,cy+hy,cz-hz),(cx+hx,cy+hy,cz-hz)],
        [(cx+hx,cy-hy,cz+hz),(cx+hx,cy-hy,cz-hz),(cx+hx,cy+hy,cz-hz),(cx+hx,cy+hy,cz+hz)],
        [(cx-hx,cy-hy,cz-hz),(cx-hx,cy-hy,cz+hz),(cx-hx,cy+hy,cz+hz),(cx-hx,cy+hy,cz-hz)],
        [(cx-hx,cy+hy,cz+hz),(cx+hx,cy+hy,cz+hz),(cx+hx,cy+hy,cz-hz),(cx-hx,cy+hy,cz-hz)],
        [(cx-hx,cy-hy,cz-hz),(cx+hx,cy-hy,cz-hz),(cx+hx,cy-hy,cz+hz),(cx-hx,cy-hy,cz+hz)],
    ]
    uvs = [(0,1),(1,1),(1,0),(0,0)]
    po = len(pos)//12; uo = len(uv)//8; base = 0; tris = []; allv = []
    for f in faces:
        for k, vv in enumerate(f):
            pos.extend(struct.pack("<3f", *vv)); uv.extend(struct.pack("<2f", *uvs[k])); allv.append(vv)
        tris += [(base,base+1,base+2),(base,base+2,base+3)]; base += 4
    io_ = len(idx)
    for t in tris:
        for k in t: idx.extend(struct.pack("<H", k))
    a = np.array(allv)
    specs.append((po, uo, len(faces)*4, a.min(0).tolist(), a.max(0).tolist(), io_, len(tris)*3, material))

def unlit(color=None, tex=None, name=None):
    pbr = {"metallicFactor": 0.0, "roughnessFactor": 1.0}
    if color: pbr["baseColorFactor"] = color
    if tex is not None: pbr["baseColorTexture"] = {"index": tex}
    g["materials"].append({"name": name or f"added-{len(g['materials'])}", "pbrMetallicRoughness": pbr,
                           "extensions": {"KHR_materials_unlit": {}}})
    return len(g["materials"]) - 1

def label_texture(text, bg, tcolor=(255, 255, 255, 255), fs=64):
    W = H = 256
    im = Image.new("RGBA", (W, H), bg)
    d = ImageDraw.Draw(im)
    f = ImageFont.truetype(FONT, fs)
    tb = d.textbbox((0, 0), text, font=f)
    d.text(((W-(tb[2]-tb[0]))/2 - tb[0], (H-(tb[3]-tb[1]))/2 - tb[1]), text, font=f, fill=tcolor)
    buf = io.BytesIO(); im.save(buf, "PNG")
    g["images"].append({"uri": "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()})
    if not g["samplers"]:
        g["samplers"].append({"magFilter":9729,"minFilter":9987,"wrapS":10497,"wrapT":10497})
    g["textures"].append({"source": len(g["images"])-1, "sampler": 0})
    return len(g["textures"]) - 1

# Path lines: blue when healthy. Named so the app's fault system (alertMaterialGroups)
# can flip them red when the path goes down.
mat_line1 = unlit(color=[0.10,0.42,0.95,1.0], name="Path1-line")
mat_line2 = unlit(color=[0.10,0.42,0.95,1.0], name="Path2-line")
tex1 = label_texture("PATH 1", (24,140,80,255))     # green plate
tex2 = label_texture("PATH 2", (40,90,200,255))     # blue plate
mat_box1 = unlit(color=[1,1,1,1], tex=tex1)
mat_box2 = unlit(color=[1,1,1,1], tex=tex2)

# path line now spans from the front stub (z~10.5) to the moved rear switch's front face
FE = 10.5
RE = REAR_NEW_Z + 2.0          # rear switch front face
line_c = (FE + RE) / 2
line_len = FE - RE
for x, mline, mbox in ((2.0, mat_line1, mat_box1), (-2.0, mat_line2, mat_box2)):
    add_line(x, 4.0, line_c, 0.16, 0.16, line_len, mline)
    add_textured_cube(x, 4.0, 0.0, 0.9, mbox)   # injection module at the centre of the line

# one clean blue line from the rear-centre LiDAR to the moved rear switch
mat_rl = unlit(color=[0.10, 0.42, 0.95, 1.0], name="RearLidar-line")
rl_z0, rl_z1 = -18.5, REAR_NEW_Z - 2.0
add_line(0.0, 4.6, (rl_z0 + rl_z1) / 2, 0.16, 0.16, rl_z1 - rl_z0, mat_rl)

# --- switches: solid body + the TSN ZCU project badge decal on top (25:18) ---
BADGE = "/home/kim/keti-reconfig/tools/tsn_zcu.png"
DECAL_AR = 250.0 / 180.0   # matches the badge aspect (1478x1064)
def badge_texture():
    im = Image.open(BADGE).convert("RGBA").transpose(Image.FLIP_LEFT_RIGHT)  # un-mirror for the top decal
    im.thumbnail((720, 720))   # keep the glb small; still crisp on a box top
    buf = io.BytesIO(); im.save(buf, "PNG")
    g["images"].append({"uri": "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()})
    if not g["samplers"]:
        g["samplers"].append({"magFilter":9729,"minFilter":9987,"wrapS":10497,"wrapT":10497})
    g["textures"].append({"source": len(g["images"])-1, "sampler": 0})
    return len(g["textures"]) - 1
mat_body = unlit(color=[0.93, 0.80, 0.16, 1.0])   # switch body
mat_badge = unlit(color=[1, 1, 1, 1], tex=badge_texture())
g["materials"][mat_badge]["doubleSided"] = True
def switch_box(cx, cy, cz, sx, sy, sz, name):
    add_line(cx, cy, cz, sx, sy, sz, mat_body)
    # largest 25:18 rectangle that fits on the box top, centred
    w = min(sx * 0.9, sz * 0.9 * DECAL_AR); dd = w / DECAL_AR
    add_decal(cx, cy + sy/2 + 0.03, cz, w, dd, mat_badge)
# box footprints are 25:18 (x:z) so the label decal fills the whole top
FAx, FBx, FZ = 3.4, -3.4, 13.0
switch_box(FAx, 4.2, FZ, 4.6, 2.4, 3.31, "TSN-F A")   # front A (right)
switch_box(FBx, 4.2, FZ, 4.6, 2.4, 3.31, "TSN-F B")   # front B (left)
switch_box(0.0, 4.0, REAR_NEW_Z, 5.5, 1.8, 3.96, "TSN-R")  # rear (smaller)

# line linking the two front switches (A <-> B)
mat_fab = unlit(color=[0.10, 0.42, 0.95, 1.0], name="FrontAB-line")
add_line_between((FAx, 4.2, FZ), (FBx, 4.2, FZ), 0.16, mat_fab)

# clean lidar lines into the front switches (blue)
mat_fll = unlit(color=[0.10, 0.42, 0.95, 1.0], name="FLidar-line")
add_line_between((-8.5, 9.0, 16.2), (FBx, 5.5, FZ + 2), 0.16, mat_fll)  # front-left lidar -> B
add_line_between((8.3, 9.0, 16.2), (FAx, 5.5, FZ + 2), 0.16, mat_fll)   # front-right lidar -> A
add_line_between((0.0, 5.5, 18.5), (0.0, 5.0, FZ + 3.5), 0.16, mat_fll)  # front-centre lidar -> front

# ---- pack buffer ----
while len(pos) % 4: pos.append(0)
while len(uv) % 4: uv.append(0)
pos_off, uv_off, idx_off = 0, len(pos), len(pos)+len(uv)
blob = bytes(pos)+bytes(uv)+bytes(idx)
bi = len(g["buffers"])
g["buffers"].append({"byteLength": len(blob), "uri": "data:application/octet-stream;base64,"+base64.b64encode(blob).decode()})
pv = len(bufviews); bufviews.append({"buffer":bi,"byteOffset":pos_off,"byteLength":len(pos),"target":34962})
uvv = len(bufviews); bufviews.append({"buffer":bi,"byteOffset":uv_off,"byteLength":len(uv),"target":34962})
iv = len(bufviews); bufviews.append({"buffer":bi,"byteOffset":idx_off,"byteLength":len(idx),"target":34963})

added = []
for po, uo, vc, pmin, pmax, io_, ic, matx in specs:
    pa = len(acc); acc.append({"bufferView":pv,"byteOffset":po*12,"componentType":5126,"count":vc,"type":"VEC3","min":pmin,"max":pmax})
    ua = len(acc); acc.append({"bufferView":uvv,"byteOffset":uo*8,"componentType":5126,"count":vc,"type":"VEC2"})
    ia = len(acc); acc.append({"bufferView":iv,"byteOffset":io_,"componentType":5123,"count":ic,"type":"SCALAR"})
    mi = len(meshes); meshes.append({"primitives":[{"attributes":{"POSITION":pa,"TEXCOORD_0":ua},"indices":ia,"material":matx}]})
    ni = len(nodes); nodes.append({"mesh":mi,"name":f"added-{ni}"}); added.append(ni)
g["scenes"][g.get("scene",0)]["nodes"].extend(added)
json.dump(g, open(DST,"w")); json.load(open(DST))
print("wrote", DST, "added", added, "bytes", len(blob))
