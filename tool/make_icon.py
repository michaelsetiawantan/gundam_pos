#!/usr/bin/env python3
"""Gundam POS launcher icon generator — dependency-free (zlib + math only).

Draws the petrol/teal brand tile and a stylised "G" mark with signed-distance
fields, so edges are antialiased analytically (no supersampling, no PIL).

    python3 make_icon.py tile   <out.png> <size>   # legacy full-bleed launcher icon
    python3 make_icon.py fg     <out.png> <size>   # adaptive foreground, mark only, transparent
    python3 make_icon.py bg     <out.png> <size>   # adaptive background (flat petrol)

Then downsample for the Android densities with ffmpeg (or any resizer). See
tool/README-icons.md for the exact mipmap sizes.
"""
import math
import struct
import sys
import zlib

# brand tokens — mirror of web/app/globals.css (petrol/teal design system)
PETROL = (0x15, 0x3B, 0x44)
TEAL = (0x0E, 0x82, 0x76)
MARK = (0xEA, 0xF7, 0xF4)

# The G aperture: the ring breaks between these screen angles (degrees, 0 = east,
# clockwise because y grows downwards). The crossbar meets the ring's lower-right
# stroke OUTSIDE the gap, so the junction is flush — a notch reads as a glitch at
# launcher sizes.
GAP_START, GAP_END = 300.0, 352.0


def _smoothstep(edge0, edge1, x):
    if edge1 == edge0:
        return 1.0 if x >= edge1 else 0.0
    t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)


def _over(dst, src, a):
    return tuple(d + (s - d) * a for d, s in zip(dst, src))


def rounded_box_sdf(px, py, cx, cy, hw, hh, r):
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


def render(mode, size):
    """Raw RGBA rows for a size×size image.

    mode 'tile': full-bleed gradient square (launchers apply their own mask, so a
    pre-baked squircle would double-mask and leave black corners).
    mode 'fg':   the G mark alone on transparency, in the adaptive safe zone.
    mode 'bg':   flat petrol square for the adaptive background layer.
    """
    S = float(size)
    k = S / 512.0
    aa = 1.2 * k

    # mark geometry in the 512-unit design space; for 'fg' the whole mark is
    # shrunk into the adaptive safe zone (~66% of the canvas).
    if mode == "fg":
        scale, cx = 0.62, 256.0
    else:
        scale, cx = 1.0, 256.0
    cy = 256.0
    ring_r = 124.0 * scale
    ring_w = 44.0 * scale
    bar_hh = 22.0 * scale
    bar_cy = cy + 36.0 * scale
    # end the bar inside the ring stroke at that height -> flush junction
    dy = bar_cy - cy
    bar_end = cx + math.sqrt(max(ring_r, 0.0) ** 2 - dy ** 2) + ring_w * 0.35
    bar_start = cx - 6.0 * scale

    rows = bytearray()
    for y in range(size):
        py = y + 0.5
        for x in range(size):
            px = x + 0.5

            if mode == "bg":
                col, cov = PETROL, 1.0
            elif mode == "bgonly":
                # gradient tile with no mark: the "G" glyph is composited on top by
                # ffmpeg drawtext so the letterform comes from a real bold font.
                col = tuple(
                    PETROL[i] + (TEAL[i] - PETROL[i]) * (px / S * 0.6 + (1.0 - py / S) * 0.4)
                    for i in range(3)
                )
                cov = 1.0
            else:
                cov = 1.0
                if mode == "tile":
                    col = tuple(
                        PETROL[i] + (TEAL[i] - PETROL[i]) * (px / S * 0.6 + (1.0 - py / S) * 0.4)
                        for i in range(3)
                    )
                else:
                    col = (0.0, 0.0, 0.0)
                    cov = 0.0  # transparent until the mark paints

                dx, dyv = px - cx * k, py - cy * k
                dist = math.hypot(dx, dyv)
                ang = math.degrees(math.atan2(dyv, dx)) % 360.0
                in_gap = GAP_START < ang < GAP_END
                ring = (1.0 - _smoothstep(0.0, aa, abs(dist - ring_r * k) - ring_w * k / 2.0))
                if in_gap:
                    ring = 0.0
                bar = 1.0 - _smoothstep(
                    0.0, aa,
                    rounded_box_sdf(px, py, (bar_start + bar_end) / 2 * k, bar_cy * k,
                                    (bar_end - bar_start) / 2 * k, bar_hh * k, bar_hh * k),
                )
                mark = max(ring, bar)
                if mark > 0.004:
                    col = _over(col, MARK, mark)
                    cov = max(cov, mark)

            rows += bytes((int(col[0] + 0.5), int(col[1] + 0.5), int(col[2] + 0.5), int(cov * 255 + 0.5)))
    return bytes(rows)


def write_png(path, mode, size):
    raw = render(mode, size)
    stride = size * 4
    filtered = b"".join(b"\x00" + raw[y * stride:(y + 1) * stride] for y in range(size))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(filtered, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)
    print(f"wrote {path} ({mode} {size}x{size})")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "tile"
    out = sys.argv[2] if len(sys.argv) > 2 else "icon.png"
    px = int(sys.argv[3]) if len(sys.argv) > 3 else 512
    write_png(out, cmd, px)
