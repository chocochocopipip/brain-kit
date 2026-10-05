#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""工程表のスクショを db の 1 文書に収める（標準ライブラリだけ）。

  python3 shot.py <in.png> --out /tmp/shot.json --ref owner/repo#N
  python3 shot.py <in.png> --max-bytes 258048 --png-out /tmp/shot.png

上限は UTF-8 の JSON 全体。小さい PNG はそのまま、大きいものは面積平均で縮める。
"""
import argparse
import base64
import datetime
import json
import math
import struct
import sys
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
MAX_PIXELS = 40000000          # 画面のスクショには十分。壊れた IHDR で巨大な領域を取らない


def read_png(data):
    if data[:8] != SIGNATURE:
        raise ValueError("PNG ではない")
    pos, header, palette, alpha, parts = 8, None, None, None, []
    ended, after_data = False, False
    while pos < len(data):
        if pos + 12 > len(data):
            raise ValueError("チャンクが途中で切れている")
        size = struct.unpack_from(">I", data, pos)[0]
        kind = data[pos + 4:pos + 8]
        end = pos + 8 + size
        if end + 4 > len(data):
            raise ValueError("チャンクの長さが不正")
        body = data[pos + 8:end]
        if not kind[0] & 32 and zlib.crc32(kind + body) & 0xffffffff != struct.unpack_from(">I", data, end)[0]:
            raise ValueError("PNG の CRC が不正")
        if header is None and kind != b"IHDR":
            raise ValueError("IHDR が先頭に無い")
        if kind == b"IHDR":
            if header is not None or size != 13:
                raise ValueError("IHDR が不正")
            header = struct.unpack(">IIBBBBB", body)
            w, h, depth, color, compression, filtering, interlace = header
            allowed = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
            if not (0 < w <= 0x7fffffff and 0 < h <= 0x7fffffff) or depth not in allowed.get(color, ()) or compression or filtering or interlace not in (0, 1):
                raise ValueError("対応していない IHDR")
            if w * h > MAX_PIXELS:
                raise ValueError("大きすぎる（%d×%d。上限 %d 画素）" % (w, h, MAX_PIXELS))
        elif kind == b"PLTE":
            if palette is not None or parts or not size or size % 3 or size > 768 or color in (0, 4):
                raise ValueError("パレットが不正")
            palette = body
        elif kind == b"tRNS":
            if alpha is not None or parts or color not in (0, 2, 3):
                raise ValueError("透過情報が不正")
            if (color == 0 and size != 2) or (color == 2 and size != 6) or (color == 3 and (palette is None or size > len(palette) // 3)):
                raise ValueError("透過情報の長さが不正")
            alpha = body
        elif kind == b"IDAT":
            if after_data or (color == 3 and palette is None):
                raise ValueError("画像データの順序が不正")
            parts.append(body)
        elif kind == b"IEND":
            if size or not parts:
                raise ValueError("終端が不正")
            ended = True
            pos = end + 4
            break
        elif not kind[0] & 32:
            raise ValueError("対応していない必須チャンク")
        if parts and kind != b"IDAT":
            after_data = True
        pos = end + 4
    if not ended or pos != len(data):
        raise ValueError("PNG の終端が不正")
    return header, palette, alpha, b"".join(parts)


def decode(parsed):
    (w, h, depth, color, _, _, interlace), palette, alpha, packed = parsed
    channels = CHANNELS[color]
    passes = [(0, 0, 1, 1)] if not interlace else [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    layouts = []
    for x, y, dx, dy in passes:
        pw, ph = max(0, (w - x + dx - 1) // dx), max(0, (h - y + dy - 1) // dy)
        if pw and ph:
            layouts.append((x, y, dx, dy, pw, ph, (pw * channels * depth + 7) // 8))
    expected = sum(ph * (stride + 1) for _, _, _, _, _, ph, stride in layouts)
    inflater = zlib.decompressobj()
    raw = inflater.decompress(packed, expected + 1)
    if len(raw) != expected or not inflater.eof or inflater.unused_data:
        raise ValueError("画像データの長さが不正")
    pixels = bytearray(w * h * 4)
    pos, bpp = 0, max(1, (channels * depth + 7) // 8)
    transparent = struct.unpack(">" + "H" * (len(alpha) // 2), alpha) if alpha is not None and color in (0, 2) else None
    colors = None
    if color == 3:
        colors = [palette[i:i + 3] + bytes([alpha[i // 3] if alpha is not None and i // 3 < len(alpha) else 255]) for i in range(0, len(palette), 3)]
    for x0, y0, dx, dy, pw, ph, stride in layouts:
        previous = bytearray(stride)
        for y in range(ph):
            method = raw[pos]
            row = bytearray(raw[pos + 1:pos + 1 + stride])
            pos += stride + 1
            if method > 4:
                raise ValueError("フィルターが不正")
            if method:
                for i in range(stride):
                    a = row[i - bpp] if i >= bpp else 0
                    b = previous[i]
                    c = previous[i - bpp] if i >= bpp else 0
                    if method == 1:
                        predictor = a
                    elif method == 2:
                        predictor = b
                    elif method == 3:
                        predictor = (a + b) // 2
                    else:
                        p = a + b - c
                        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                        predictor = a if pa <= pb and pa <= pc else b if pb <= pc else c
                    row[i] = (row[i] + predictor) & 255
            previous = row
            if depth == 16:
                values = struct.unpack(">" + "H" * (pw * channels), row)
            elif depth < 8:
                mask = (1 << depth) - 1
                values = [(row[i * depth // 8] >> (8 - depth - i * depth % 8)) & mask for i in range(pw)]
            else:
                values = row
            out = bytearray(pw * 4)
            if color in (2, 6) and depth == 8 and transparent is None:
                out[0::4], out[1::4], out[2::4] = row[0::channels], row[1::channels], row[2::channels]
                out[3::4] = row[3::4] if color == 6 else b"\xff" * pw
            else:
                for x in range(pw):
                    v = values[x * channels:(x + 1) * channels]
                    if color == 3:
                        if v[0] >= len(colors):
                            raise ValueError("パレット番号が不正")
                        rgba = colors[v[0]]
                    else:
                        scaled = [n >> 8 for n in v] if depth == 16 else [n * 255 // ((1 << depth) - 1) for n in v]
                        rgb = scaled[:3] if color in (2, 6) else scaled[:1] * 3
                        opacity = scaled[-1] if color in (4, 6) else 0 if transparent is not None and tuple(v) == transparent else 255
                        rgba = bytes(rgb + [opacity])
                    out[x * 4:x * 4 + 4] = rgba
            start = ((y0 + y * dy) * w + x0) * 4
            if dx == 1:
                pixels[start:start + pw * 4] = out
            else:
                for channel in range(4):
                    pixels[start + channel:start + pw * dx * 4:dx * 4] = out[channel::4]
    return pixels


def resize(pixels, sw, sh, w, h):
    """各出力画素が受け持つ箱の平均。元画像から毎回作る。"""
    out = bytearray(w * h * 4)
    edges = [x * sw // w for x in range(w + 1)]
    for y in range(h):
        top, bottom = y * sh // h, (y + 1) * sh // h
        for x in range(w):
            left, right = edges[x:x + 2]
            sums = [0, 0, 0, 0]
            for sy in range(top, bottom):
                start, end = (sy * sw + left) * 4, (sy * sw + right) * 4
                for c in range(4):
                    sums[c] += sum(pixels[start + c:end:4])
            area = (right - left) * (bottom - top)
            i = (y * w + x) * 4
            out[i:i + 4] = bytes((n + area // 2) // area for n in sums)
    return out


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)


def encode(pixels, w, h):
    opaque = all(a == 255 for a in pixels[3::4])
    channels = 3 if opaque else 4
    if opaque:
        rgb = bytearray(w * h * 3)
        for c in range(3):
            rgb[c::3] = pixels[c::4]
        pixels = rgb
    stride = w * channels
    raw = b"".join(b"\0" + pixels[y * stride:(y + 1) * stride] for y in range(h))
    return SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2 if opaque else 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", help="元の PNG")
    ap.add_argument("--out", default="-")
    ap.add_argument("--max-bytes", type=int, default=258048)
    for name in ("ref", "url", "caption"):
        ap.add_argument("--" + name, default="")
    ap.add_argument("--png-out")
    args = ap.parse_args()
    try:
        with open(args.input, "rb") as f:
            png = f.read()
        parsed = read_png(png)
        sw, sh = parsed[0][:2]
        w, h = sw, sh
        doc = dict(ref=args.ref, url=args.url, caption=args.caption, src_w=sw, src_h=sh,
                   taken_at=datetime.datetime.now().astimezone().isoformat(timespec="seconds"))
        pixels, scale = None, 1.0
        while True:
            doc.update(data="data:image/png;base64," + base64.b64encode(png).decode("ascii"), w=w, h=h, bytes=len(png))
            output = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            if len(output) <= args.max_bytes:
                break
            if pixels is None:
                pixels = decode(parsed)
                scale = min(0.85, math.sqrt(max(0, args.max_bytes) / float(len(output))) * 0.9)
            else:
                scale *= 0.85
            # 最後に短辺 16 px でも試す。元がそれより小さければ縮めない。
            floor = 16.0 / min(sw, sh)
            if min(w, h) <= 16:
                print("収まらない: 文書の上限を増やすか、説明を短くする", file=sys.stderr)
                return 1
            scale = max(scale, floor)
            w, h = max(16, int(sw * scale)), max(16, int(sh * scale))
            png = encode(resize(pixels, sw, sh, w, h), w, h)
        if args.out == "-":
            sys.stdout.buffer.write(output)
        else:
            with open(args.out, "wb") as f:
                f.write(output)
            print("書いた: %s（%d×%d、%.1f KB、元 %d×%d）" % (args.out, w, h, len(png) / 1024.0, sw, sh), file=sys.stderr)
        if args.png_out:
            with open(args.png_out, "wb") as f:
                f.write(png)
        return 0
    except (ValueError, OSError, zlib.error, struct.error, OverflowError) as e:
        print("PNG を処理できない: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
