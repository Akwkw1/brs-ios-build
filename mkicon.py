#!/usr/bin/env python3
"""纯标准库画图标：深色底 + 金色雷达。用法: mkicon.py <App 目录>"""
import math
import os
import struct
import sys
import zlib

GOLD = (1.00, 0.77, 0.00)
GOLD_DIM = (0.62, 0.48, 0.08)
GREEN = (0.30, 0.92, 0.52)


def mix(a, b, t):
    return (a[0] + (b[0] - a[0]) * t,
            a[1] + (b[1] - a[1]) * t,
            a[2] + (b[2] - a[2]) * t)


def over(dst, src, alpha):
    return mix(dst, src, max(0.0, min(1.0, alpha)))


def cov(d_norm, scale, w_px):
    """d_norm 为归一化距离，scale 为每单位的像素数，w_px 为线宽（像素）。"""
    d = abs(d_norm) * scale
    return max(0.0, min(1.0, w_px * 0.5 + 0.5 - d))


def render(n):
    ss = 2
    N = n * ss
    scale = N / 2.0
    acc = [[[0.0, 0.0, 0.0] for _ in range(n)] for _ in range(n)]

    for y in range(N):
        fy = (y + 0.5) / N * 2.0 - 1.0
        for x in range(N):
            fx = (x + 0.5) / N * 2.0 - 1.0
            r = math.hypot(fx, fy)

            # 背景：中心略亮的径向渐变
            col = mix((0.115, 0.115, 0.125), (0.030, 0.030, 0.035), min(1.0, r * 0.95))

            # 圆角方形遮罩（圆角半径 0.30）
            ax, ay = abs(fx), abs(fy)
            lim = 0.955
            corner = 0.30
            inside = True
            if ax > lim - corner and ay > lim - corner:
                cx, cy = ax - (lim - corner), ay - (lim - corner)
                inside = math.hypot(cx, cy) <= corner
            elif ax > lim or ay > lim:
                inside = False

            if not inside:
                col = (0.0, 0.0, 0.0)
            else:
                # 外框
                col = over(col, GOLD,
                           cov(r - (lim - 0.018), scale, 2.4) * 0.85)

                # 扫描扇形（从左上扫到右侧）
                if r < 0.90 and r > 0.02:
                    ang = math.degrees(math.atan2(-fy, fx)) % 360.0  # 逆时针、y 向上
                    start, span = 96.0, 64.0
                    d = (ang - start) % 360.0
                    if d < span:
                        fade = (1.0 - d / span) ** 1.6
                        radial = 1.0 - (r / 0.90) ** 0.7
                        beam = 0.55 * fade * radial
                        # 前缘更亮
                        edge = 1.0 - min(1.0, d / 5.0)
                        beam += 0.30 * edge * radial
                        col = over(col, GOLD, beam)

                # 同心圆
                for ring in (0.30, 0.56, 0.82):
                    c = cov(r - ring, scale, 2.0) * 0.55
                    if c > 0:
                        col = over(col, GOLD, c)
                # 十字
                if r < 0.90:
                    c = max(cov(fx, scale, 1.6), cov(fy, scale, 1.6)) * 0.20
                    col = over(col, GOLD_DIM, c)

                # 光点
                for (bx, by, s, bright) in (
                    (0.34, 0.40, 0.055, 1.0),
                    (-0.46, -0.30, 0.038, 0.75),
                    (0.12, -0.62, 0.030, 0.55),
                ):
                    bd = math.hypot(fx - bx, fy - by)
                    if bd < s:
                        glow = (1.0 - bd / s)
                        col = over(col, GREEN, (glow ** 1.5) * bright)

            px, py = x // ss, y // ss
            tgt = acc[py][px]
            tgt[0] += col[0]
            tgt[1] += col[1]
            tgt[2] += col[2]

    per = float(ss * ss)
    rows = []
    for row in acc:
        rows.append([(int(min(255, round(c[0] / per * 255))),
                      int(min(255, round(c[1] / per * 255))),
                      int(min(255, round(c[2] / per * 255)))) for c in row])
    return rows


def write_png(path, rows, w, h):
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for (r, g, b) in row:
            raw += bytes((r, g, b))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    app = sys.argv[1]
    targets = {
        "AppIcon60x60@2x.png": 120,
        "AppIcon60x60@3x.png": 180,
        "AppIcon76x76@2x~ipad.png": 152,
        "AppIcon83.5x83.5@2x~ipad.png": 167,
        "AppIcon1024.png": 1024,
    }
    for name, size in targets.items():
        rows = render(size)
        write_png(os.path.join(app, name), rows, size, size)
        print("icon", name, size)


if __name__ == "__main__":
    main()
