#!/usr/bin/env python3
"""Make every icon synthgui needs from assets/OpenXC7Logo.jpg (needs Pillow; the .icns also needs macOS's iconutil).

    python3 assets/make-icons.py

writes assets/icon/:
    synthgui-{16,24,32,48,64,128,256,512}.png   Linux (hicolor), and the window icon embedded in the program (assets/icons.qrc)
    synthgui.ico                                Windows: the icon of synthgui.exe (assets/synthgui.rc), PNG frames from 16 to 256
    synthgui.icns                               macOS: the app bundle's icon (CMake copies it into Contents/Resources)

The icons are committed, so a build needs none of this.  Each is the logo on a white rounded tile (its background is white);
from 128 px up it is the whole logo, below that the circle alone, because the wordmark cannot be read at those sizes.  The
macOS icon follows Apple's grid (body 824 of 1024, a soft shadow), the others fill more of the square.
"""
import io, os, shutil, struct, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter

here = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(here, "OpenXC7Logo.jpg")
OUT = os.path.join(here, "icon")
SS = 4                                   # draw at 4x and shrink: smooth corners

def master():
    im = Image.open(SRC).convert("RGB")
    # the JPEG's "white" is 250-254: make it white so the tile has no visible edge
    return im.point(lambda v: min(255, round(v * 255 / 242)))

FULL = (20, 29, 620, 629)                # the logo, circle and wordmark, centred with a margin
MARK = (151, 86, 487, 422)               # the circle alone (it spans 189,123 to 450,384)

def icon(size, mac=False, logo=None):
    logo = logo or master()
    n = size * SS
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    body = round(n * (824 / 1024 if mac else 0.96))
    off = (n - body) // 2
    radius = round(body * 0.2237)
    if mac:                              # the soft shadow Apple's template carries
        sh = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle((off, off + n // 80, off + body, off + body + n // 80), radius, fill=(0, 0, 0, 70))
        canvas = Image.alpha_composite(canvas, sh.filter(ImageFilter.GaussianBlur(n / 120)))
    tile = Image.new("RGBA", (body, body), (255, 255, 255, 255))
    crop = logo.crop(FULL if size >= 128 else MARK)
    inner = round(body * (0.94 if size >= 128 else 0.90))
    crop = crop.resize((inner, inner), Image.LANCZOS)
    tile.paste(crop, ((body - inner) // 2, (body - inner) // 2))
    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, body - 1, body - 1), radius, fill=255)
    tile.putalpha(mask)
    # a hairline edge, so the white tile has an outline on a white background
    edge = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, body - 1, body - 1), radius, outline=(120, 130, 145, 90), width=max(1, SS))
    tile = Image.alpha_composite(tile, edge)
    canvas.alpha_composite(tile, (off, off))
    return canvas.resize((size, size), Image.LANCZOS)

def png_bytes(im):
    b = io.BytesIO(); im.save(b, "PNG", optimize=True); return b.getvalue()

def write_ico(path, sizes):
    frames = [png_bytes(icon(s)) for s in sizes]
    head = struct.pack("<HHH", 0, 1, len(sizes))
    off = 6 + 16 * len(sizes)
    entries = b""
    for s, data in zip(sizes, frames):
        entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), off)
        off += len(data)
    with open(path, "wb") as f:
        f.write(head + entries + b"".join(frames))

def main():
    os.makedirs(OUT, exist_ok=True)
    logo = master()
    for s in (16, 24, 32, 48, 64, 128, 256, 512):
        icon(s, logo=logo).save(os.path.join(OUT, "synthgui-%d.png" % s), optimize=True)
    write_ico(os.path.join(OUT, "synthgui.ico"), (16, 24, 32, 48, 64, 128, 256))
    if shutil.which("iconutil"):
        with tempfile.TemporaryDirectory() as t:
            iset = os.path.join(t, "synthgui.iconset")
            os.makedirs(iset)
            for s in (16, 32, 128, 256, 512):
                icon(s, mac=True, logo=logo).save(os.path.join(iset, "icon_%dx%d.png" % (s, s)))
                icon(2 * s, mac=True, logo=logo).save(os.path.join(iset, "icon_%dx%d@2x.png" % (s, s)))
            subprocess.run(["iconutil", "-c", "icns", iset, "-o", os.path.join(OUT, "synthgui.icns")], check=True)
    else:
        print("iconutil not found: synthgui.icns not rebuilt (it is committed)", file=sys.stderr)
    for f in sorted(os.listdir(OUT)):
        print("%-18s %6d bytes" % (f, os.path.getsize(os.path.join(OUT, f))))

main()
