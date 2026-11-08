# Generates app.ico: the pixel SOUL heart, 16-256 px. Run: python make_icon.py
import struct, zlib
HEART = [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]
RED, SHINE = (232, 28, 40, 255), (255, 150, 150, 255)

def image(size):
    px = max(1, size // 9)                     # heart is 7x6 cells, leave a margin
    w, h = 7 * px, 6 * px
    ox, oy = (size - w) // 2, (size - h) // 2 + px // 3
    img = [[(0, 0, 0, 0)] * size for _ in range(size)]
    for r, row in enumerate(HEART):
        for c, ch in enumerate(row):
            if ch != '#': continue
            col = SHINE if (r, c) == (1, 1) and size >= 32 else RED
            for y in range(oy + r * px, oy + (r + 1) * px):
                for x in range(ox + c * px, ox + (c + 1) * px):
                    img[y][x] = col
    return img

def png(img):
    size = len(img)
    raw = b"".join(b"\0" + bytes(v for p in row for v in p) for row in img)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")

def bmp(img):
    size = len(img)
    head = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    pixels = b"".join(bytes((p[2], p[1], p[0], p[3])) for row in reversed(img) for p in row)
    mask_row = ((size + 31) // 32) * 4
    return head + pixels + b"\0" * mask_row * size

sizes = [16, 24, 32, 48, 64, 256]
blobs = [png(image(s)) if s == 256 else bmp(image(s)) for s in sizes]
out = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for s, b in zip(sizes, blobs):
    out += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
open("app.ico", "wb").write(out + b"".join(blobs))
print("app.ico", len(out) + sum(map(len, blobs)), "bytes")
