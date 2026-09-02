#!/usr/bin/env python3
"""Tidy the body's atlas: flatten the baked shading on the paint, and pad the island edges.

    python3 tools/fix_textures.py assets/roii_body.glb build/tex

Two things, in the order they matter.

**The paint carries a bake.** 43% of the atlas reads as near-black, and it is tempting to call
that unused background -- but rasterising the UVs says 76.7% of the image is covered, so most of
the black is real: glass, tyres, wheel arches, the underside. What is wrong is the *light* 30%:
it is white paint with shadow and dirt baked into it, and the console lights it again, so at any
zoom it reads as grey blotching. Anything already light is pulled most of the way to one clean
paint colour. Anything dark is left exactly as it is, because that is the detail worth keeping --
window frames, badges, panel gaps.

**The remaining 23% is unused, and it is black.** Downscaled and mipmapped, that black averages
into the edge of every island. So the colour is flooded outward past the island edges, and the
mask for that has to come from the UVs: a luminance threshold cannot separate background from
window glass, because the background is not exactly black after JPEG and the two overlap between
luminance 8 and 30.

Writes `baseColor.png` and `orm.png`. `clean_body.blend.py` picks them up when the directory is
passed to it; Blender re-encodes them on export.
"""

import base64
import json
import os
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw

# How far to push the colour out past the island edge, in atlas pixels. Eight is more than a
# 1024-level mip can reach for; the cost is a slightly larger file.
DILATE_PX = 10

# A gentle lift, applied inside the mask only. The body is white paint and the atlas has it at
# luminance 160; this brings it to about 180 without touching the glass.
GAMMA = 0.86

# The atlas is a bake: the panels carry shading and dirt that the console then lights again, and
# at any zoom it reads as grey blotching across white paint. Anything already light is pulled
# most of the way to one clean paint colour; anything dark -- glass, tyres, badges, panel gaps --
# is left exactly as it is, because that is the detail worth keeping.
PAINT_ABOVE = 105
PAINT_COLOUR = (238, 240, 245)
PAINT_MIX = 0.68


def load_gltf(path):
    with open(path, 'rb') as fh:
        raw = fh.read()
    if raw[:4] == b'glTF':
        off, js, bin_chunk = 12, None, b''
        while off + 8 <= len(raw):
            clen, ctype = struct.unpack('<II', raw[off:off + 8])
            chunk = raw[off + 8:off + 8 + clen]
            if ctype == 0x4E4F534A:
                js = json.loads(chunk)
            else:
                bin_chunk = chunk
            off += 8 + clen
        return js, bin_chunk
    js = json.loads(raw)
    uri = js['buffers'][0]['uri']
    return js, base64.b64decode(uri.split(',', 1)[1])


def accessor(js, buf, index):
    a = js['accessors'][index]
    v = js['bufferViews'][a['bufferView']]
    off = v.get('byteOffset', 0) + a.get('byteOffset', 0)
    ncomp = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[a['type']]
    dt = {5121: 'u1', 5123: 'u2', 5125: 'u4', 5126: 'f4'}[a['componentType']]
    arr = np.frombuffer(buf, dtype=np.dtype('<' + dt), count=a['count'] * ncomp, offset=off)
    return arr.reshape(-1, ncomp) if ncomp > 1 else arr


def image_bytes(js, buf, index):
    img = js['images'][index]
    if 'uri' in img:
        return base64.b64decode(img['uri'].split(',', 1)[1])
    v = js['bufferViews'][img['bufferView']]
    off = v.get('byteOffset', 0)
    return buf[off:off + v['byteLength']]


def uv_mask(js, buf, size):
    """Exact island coverage, rasterised from the UVs."""
    mask = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(mask)
    for mesh in js['meshes']:
        for prim in mesh['primitives']:
            if 'TEXCOORD_0' not in prim['attributes']:
                continue
            uv = accessor(js, buf, prim['attributes']['TEXCOORD_0']).astype(np.float64)
            idx = accessor(js, buf, prim['indices']).astype(np.int64).reshape(-1, 3)
            px = np.empty_like(uv)
            px[:, 0] = uv[:, 0] * size
            px[:, 1] = uv[:, 1] * size
            for tri in idx:
                draw.polygon([tuple(px[tri[0]]), tuple(px[tri[1]]), tuple(px[tri[2]])], fill=255)
    return np.asarray(mask) > 0


def dilate(rgb, mask, rounds):
    """Push known colour outward, one ring per round."""
    out = rgb.astype(np.float32).copy()
    known = mask.copy()
    for _ in range(rounds):
        total = np.zeros_like(out)
        count = np.zeros(known.shape, dtype=np.float32)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            shifted = np.roll(out, (dy, dx), axis=(0, 1))
            valid = np.roll(known, (dy, dx), axis=(0, 1))
            total += shifted * valid[..., None]
            count += valid
        grow = (~known) & (count > 0)
        if not grow.any():
            break
        out[grow] = total[grow] / count[grow][..., None]
        known |= grow
    return np.clip(out, 0, 255).astype(np.uint8)


def main(src, outdir):
    os.makedirs(outdir, exist_ok=True)
    js, buf = load_gltf(src)
    pbr = js['materials'][0]['pbrMetallicRoughness']
    colour_i = js['textures'][pbr['baseColorTexture']['index']]['source']
    orm_i = js['textures'][pbr['metallicRoughnessTexture']['index']]['source']

    colour = Image.open(_bytes_io(image_bytes(js, buf, colour_i))).convert('RGB')
    orm = Image.open(_bytes_io(image_bytes(js, buf, orm_i))).convert('RGB')
    size = colour.size[0]
    mask = uv_mask(js, buf, size)
    print(f'atlas {size}x{size}: UV coverage {100 * mask.mean():.1f}%')

    arr = np.asarray(colour).astype(np.float32)
    lifted = 255.0 * np.power(np.clip(arr / 255.0, 0, 1), GAMMA)
    arr[mask] = lifted[mask]

    lum = arr.mean(2)
    paint = mask & (lum > PAINT_ABOVE)
    target = np.array(PAINT_COLOUR, dtype=np.float32)
    arr[paint] = arr[paint] * (1 - PAINT_MIX) + target * PAINT_MIX
    print(f'flattened {100 * paint.mean():.1f}% of the atlas to paint colour')
    padded = dilate(arr, mask, DILATE_PX)
    Image.fromarray(padded).resize((1024, 1024), Image.LANCZOS).save(
        os.path.join(outdir, 'baseColor.png'))

    orm_arr = np.asarray(orm.resize((size, size), Image.NEAREST)).astype(np.float32)
    orm_padded = dilate(orm_arr, mask, DILATE_PX)
    Image.fromarray(orm_padded).resize((512, 512), Image.LANCZOS).save(
        os.path.join(outdir, 'orm.png'))

    print(f'wrote {outdir}/baseColor.png (1024) and {outdir}/orm.png (512), '
          f'{DILATE_PX} px of island padding')


def _bytes_io(data):
    import io
    return io.BytesIO(data)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
