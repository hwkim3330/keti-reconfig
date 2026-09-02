#!/usr/bin/env python3
"""Strip the reconfig overlay out of the ROii model and repack it as a real binary GLB.

`assets/roii_reconfig.glb` is not a GLB. It is a glTF JSON document with a base64 data-URI
buffer, written by THREE.GLTFExporter out of the reconfig console's own scene, and given a .glb
extension. Two consequences for this app:

* Of its 110 meshes, exactly one is the vehicle -- `textured_meshobj`, material `roii`, with two
  baked JPEGs. The other 109 are the previous project's overlay: ZC / ACU / TCU / Path boxes, a
  wireframe twin for each, port stubs, connection tubes, and the three InlineESP modules
  (ESP_AB, ESP_AR, ESP_BR). This console pins its own ACU, LiDAR and switch positions onto the
  body, so those baked-in boxes are a different project's answer sitting under ours.
* Base64 costs a third of the file for nothing: 3.67 MB of JSON where the same data is 2.1 MB
  binary, and it has to be decoded before anything can be drawn.

This keeps the body and nothing else, prunes every accessor, buffer view, texture and image that
the body does not use, and writes a binary GLB.

    python3 tools/repack_roii_body.py assets/roii_reconfig.glb assets/roii_body.glb
"""

import base64
import json
import struct
import sys

BODY_NODE = "textured_meshobj"


def load(path):
    with open(path, "rb") as fh:
        head = fh.read(4)
        fh.seek(0)
        raw = fh.read()
    if head == b"glTF":
        # A real GLB after all: pull the two chunks out.
        _, _, _ = struct.unpack("<III", raw[:12])
        off, js, buf = 12, None, b""
        while off + 8 <= len(raw):
            clen, ctype = struct.unpack("<II", raw[off : off + 8])
            chunk = raw[off + 8 : off + 8 + clen]
            if ctype == 0x4E4F534A:
                js = json.loads(chunk)
            else:
                buf = chunk
            off += 8 + clen
        return js, buf
    js = json.loads(raw)
    uri = js["buffers"][0]["uri"]
    assert uri.startswith("data:"), "expected an embedded buffer"
    return js, base64.b64decode(uri.split(",", 1)[1])


def main(src, dst):
    js, buf = load(src)

    node = next((n for n in js["nodes"] if n.get("name") == BODY_NODE), None)
    if node is None:
        sys.exit(f"no node named {BODY_NODE!r}; nothing to keep")
    mesh = js["meshes"][node["mesh"]]

    # Everything the body reaches, and nothing else.
    accessors, materials = [], []
    for prim in mesh["primitives"]:
        accessors.extend(prim["attributes"].values())
        if "indices" in prim:
            accessors.append(prim["indices"])
        if "material" in prim:
            materials.append(prim["material"])
    accessors = sorted(set(accessors))
    materials = sorted(set(materials))

    textures = []
    for mi in materials:
        pbr = js["materials"][mi].get("pbrMetallicRoughness", {})
        for key in ("baseColorTexture", "metallicRoughnessTexture"):
            if key in pbr:
                textures.append(pbr[key]["index"])
        for key in ("normalTexture", "occlusionTexture", "emissiveTexture"):
            if key in js["materials"][mi]:
                textures.append(js["materials"][mi][key]["index"])
    textures = sorted(set(textures))
    images = sorted({js["textures"][t]["source"] for t in textures if "source" in js["textures"][t]})
    samplers = sorted({js["textures"][t]["sampler"] for t in textures if "sampler" in js["textures"][t]})

    views = sorted(
        {js["accessors"][a]["bufferView"] for a in accessors if "bufferView" in js["accessors"][a]}
        | {js["images"][i]["bufferView"] for i in images if "bufferView" in js["images"][i]}
    )

    # Repack the buffer, four-byte aligned, and remember where each view landed.
    out = bytearray()
    view_map, new_views = {}, []
    for vi in views:
        v = js["bufferViews"][vi]
        start, length = v.get("byteOffset", 0), v["byteLength"]
        while len(out) % 4:
            out.append(0)
        entry = {"buffer": 0, "byteOffset": len(out), "byteLength": length}
        for key in ("byteStride", "target"):
            if key in v:
                entry[key] = v[key]
        view_map[vi] = len(new_views)
        new_views.append(entry)
        out.extend(buf[start : start + length])

    def remap(index_list):
        return {old: new for new, old in enumerate(index_list)}

    acc_map, mat_map = remap(accessors), remap(materials)
    tex_map, img_map, smp_map = remap(textures), remap(images), remap(samplers)

    new_accessors = []
    for a in accessors:
        entry = dict(js["accessors"][a])
        if "bufferView" in entry:
            entry["bufferView"] = view_map[entry["bufferView"]]
        new_accessors.append(entry)

    new_images = []
    for i in images:
        entry = dict(js["images"][i])
        if "bufferView" in entry:
            entry["bufferView"] = view_map[entry["bufferView"]]
        new_images.append(entry)

    new_textures = []
    for t in textures:
        entry = dict(js["textures"][t])
        if "source" in entry:
            entry["source"] = img_map[entry["source"]]
        if "sampler" in entry:
            entry["sampler"] = smp_map[entry["sampler"]]
        new_textures.append(entry)

    new_materials = []
    for mi in materials:
        entry = json.loads(json.dumps(js["materials"][mi]))
        pbr = entry.get("pbrMetallicRoughness", {})
        for key in ("baseColorTexture", "metallicRoughnessTexture"):
            if key in pbr:
                pbr[key]["index"] = tex_map[pbr[key]["index"]]
        for key in ("normalTexture", "occlusionTexture", "emissiveTexture"):
            if key in entry:
                entry[key]["index"] = tex_map[entry[key]["index"]]
        entry["name"] = "body"
        new_materials.append(entry)

    new_prims = []
    for prim in mesh["primitives"]:
        entry = {
            "attributes": {k: acc_map[v] for k, v in prim["attributes"].items()},
            "mode": prim.get("mode", 4),
        }
        if "indices" in prim:
            entry["indices"] = acc_map[prim["indices"]]
        if "material" in prim:
            entry["material"] = mat_map[prim["material"]]
        new_prims.append(entry)

    doc = {
        "asset": {"version": "2.0", "generator": "repack_roii_body.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "Body", "mesh": 0}],
        "meshes": [{"name": "Body", "primitives": new_prims}],
        "materials": new_materials,
        "accessors": new_accessors,
        "bufferViews": new_views,
        "buffers": [{"byteLength": len(out)}],
    }
    for key, value in (("textures", new_textures), ("images", new_images),
                       ("samplers", [js["samplers"][s] for s in samplers])):
        if value:
            doc[key] = value

    js_chunk = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    js_chunk += b" " * ((4 - len(js_chunk) % 4) % 4)
    bin_chunk = bytes(out) + b"\0" * ((4 - len(out) % 4) % 4)
    total = 12 + 8 + len(js_chunk) + 8 + len(bin_chunk)

    with open(dst, "wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total))
        fh.write(struct.pack("<II", len(js_chunk), 0x4E4F534A))
        fh.write(js_chunk)
        fh.write(struct.pack("<II", len(bin_chunk), 0x004E4942))
        fh.write(bin_chunk)

    tris = sum(new_accessors[p["indices"]]["count"] // 3 for p in new_prims if "indices" in p)
    print(
        f"kept 1 of {len(js['meshes'])} meshes, {len(new_materials)} of {len(js['materials'])} "
        f"materials, {tris} triangles"
    )
    print(f"wrote {dst}: {total / 1e6:.2f} MB binary GLB (was {len(json.dumps(js)) / 1e6:.2f} MB JSON)")


if __name__ == "__main__":
    main(*sys.argv[1:3])
