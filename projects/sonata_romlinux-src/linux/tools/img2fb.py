#!/usr/bin/env python3
"""Convert an image to the raw frame the Sonata LCD wants: 160x128, RGB565, little endian, 40960 bytes.

    img2fb.py picture.png frame.raw [--gz] [--stretch]

With Pillow installed (pip install pillow) any common image format works; the picture is scaled to fit 160x128 and
centred on black (--stretch fills the whole frame instead).  Without Pillow only binary PPM (P6) files are read.
Serve the result to the board, for example:  python3 -m http.server 8000   and on the board:  fbget http://pc:8000/frame.raw
"""
import gzip, struct, sys

W, H = 160, 128

def read_ppm(path):
    data = open(path, "rb").read()
    parts, pos = [], 0
    while len(parts) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos)
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        parts.append(data[pos:end])
        pos = end
    if parts[0] != b"P6" or int(parts[3]) != 255:
        sys.exit("only 8-bit binary PPM (P6) is read without Pillow")
    w, h = int(parts[1]), int(parts[2])
    pix = data[pos + 1:pos + 1 + w * h * 3]
    return w, h, [tuple(pix[i:i + 3]) for i in range(0, len(pix), 3)]

def scale(w, h, pix, stretch):
    """nearest neighbour; returns W*H pixels"""
    if stretch:
        tw, th = W, H
    else:
        k = min(W / w, H / h)
        tw, th = max(1, int(w * k)), max(1, int(h * k))
    ox, oy = (W - tw) // 2, (H - th) // 2
    out = [(0, 0, 0)] * (W * H)
    for y in range(th):
        for x in range(tw):
            out[(oy + y) * W + ox + x] = pix[(y * h // th) * w + x * w // tw]
    return out

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    stretch, gz = "--stretch" in sys.argv, "--gz" in sys.argv
    if len(args) != 2:
        sys.exit(__doc__)
    try:
        from PIL import Image
        im = Image.open(args[0]).convert("RGB")
        if stretch:
            im = im.resize((W, H), Image.LANCZOS)
            out = list(im.getdata())
        else:
            im.thumbnail((W, H), Image.LANCZOS)
            canvas = Image.new("RGB", (W, H), (0, 0, 0))
            canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
            out = list(canvas.getdata())
    except ImportError:
        w, h, pix = read_ppm(args[0])
        out = scale(w, h, pix, stretch)
    raw = b"".join(struct.pack("<H", (r >> 3) << 11 | (g >> 2) << 5 | b >> 3) for r, g, b in out)
    assert len(raw) == W * H * 2
    if gz:
        raw = gzip.compress(raw, 9, mtime=0)
    open(args[1], "wb").write(raw)
    print("%s: %d bytes" % (args[1], len(raw)))

main()
