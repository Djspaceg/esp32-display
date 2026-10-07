#!/usr/bin/env python3
"""Regenerate the boot screen's image asset from its PNG.

Reads firmware/display_stream/boot_image.png (8-bit RGBA, any size up to
255x255) and writes firmware/display_stream/boot_image.h: the picture already
composited over the boot screen's background colour and converted to RGB565,
keeping only the pixels that differ from that background, as runs per row. The
firmware draws it at its native size and never scales it.

Standard library only, so it runs wherever the rest of tools/ does.

    python3 tools/generate_boot_image.py            # rewrite the header
    python3 tools/generate_boot_image.py --check    # fail if it is stale
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
import zlib
from typing import List, Tuple

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SKETCH = REPO_ROOT / "firmware" / "display_stream"
DEFAULT_INPUT = SKETCH / "boot_image.png"
DEFAULT_OUTPUT = SKETCH / "boot_image.h"
# The boot screen's background (boot_screen_model.h checks it matches): the
# dark grey the panel has always shown while it starts.
DEFAULT_BACKGROUND = 0x2104
# Background pixels this close together inside a row are stored rather than
# starting a new run: two pixels cost less than a run header.
MERGE_GAP = 2


def read_rgba_png(path: pathlib.Path) -> Tuple[int, int, List[bytes]]:
    """Decode a non-interlaced 8-bit RGBA PNG into rows of RGBA bytes."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("%s: not a PNG" % path)
    pos = 8
    width = height = 0
    idat = b""
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(
                ">IIBBBBB", body)
            if (depth, colour, interlace) != (8, 6, 0):
                raise SystemExit(
                    "%s: need 8-bit RGBA, non-interlaced (got depth %d, "
                    "colour type %d, interlace %d)"
                    % (path, depth, colour, interlace))
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if not (0 < width <= 255 and 0 < height <= 255):
        raise SystemExit("%s: %dx%d; the asset format holds up to 255x255"
                         % (path, width, height))
    raw = zlib.decompress(idat)
    stride = width * 4
    rows: List[bytes] = []
    previous = bytearray(stride)
    at = 0
    for _ in range(height):
        kind = raw[at]
        line = bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for x in range(stride):
            left = line[x - 4] if x >= 4 else 0
            up = previous[x]
            corner = previous[x - 4] if x >= 4 else 0
            if kind == 1:
                line[x] = (line[x] + left) & 0xFF
            elif kind == 2:
                line[x] = (line[x] + up) & 0xFF
            elif kind == 3:
                line[x] = (line[x] + ((left + up) >> 1)) & 0xFF
            elif kind == 4:
                guess = left + up - corner
                to_left, to_up, to_corner = (
                    abs(guess - left), abs(guess - up), abs(guess - corner))
                if to_left <= to_up and to_left <= to_corner:
                    line[x] = (line[x] + left) & 0xFF
                elif to_up <= to_corner:
                    line[x] = (line[x] + up) & 0xFF
                else:
                    line[x] = (line[x] + corner) & 0xFF
            elif kind != 0:
                raise SystemExit("%s: unknown PNG filter %d" % (path, kind))
        rows.append(bytes(line))
        previous = line
    return width, height, rows


def expand565(colour: int) -> Tuple[int, int, int]:
    r, g, b = (colour >> 11) & 0x1F, (colour >> 5) & 0x3F, colour & 0x1F
    return (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)


def to565(r: int, g: int, b: int) -> int:
    return (((r * 31 + 127) // 255) << 11) | (((g * 63 + 127) // 255) << 5) | (
        (b * 31 + 127) // 255)


def composite(rows: List[bytes], width: int, background: int) -> List[List[int]]:
    """Each pixel over the background, as RGB565."""
    bg = expand565(background)
    out = []
    for row in rows:
        line = []
        for x in range(width):
            r, g, b, a = row[x * 4:x * 4 + 4]
            mixed = [(c * a + base * (255 - a) + 127) // 255
                     for c, base in zip((r, g, b), bg)]
            line.append(to565(*mixed))
        out.append(line)
    return out


def runs_for_row(line: List[int], background: int) -> List[Tuple[int, int]]:
    """(x, length) runs covering every pixel that is not the background."""
    runs: List[Tuple[int, int]] = []
    x = 0
    width = len(line)
    while x < width:
        if line[x] == background:
            x += 1
            continue
        start = x
        end = x + 1
        while end < width:
            if line[end] != background:
                end += 1
                continue
            gap = end
            while gap < width and line[gap] == background:
                gap += 1
            if gap < width and gap - end <= MERGE_GAP:
                end = gap
                continue
            break
        runs.append((start, end - start))
        x = end
    return runs


def render_header(source: str, width: int, height: int, background: int,
                  pixels: List[List[int]]) -> Tuple[str, int]:
    row_runs: List[int] = []
    runs: List[Tuple[int, int, int]] = []
    data: List[int] = []
    for line in pixels:
        row_runs.append(len(runs))
        for x, length in runs_for_row(line, background):
            runs.append((x, length, len(data)))
            data.extend(line[x:x + length])
    row_runs.append(len(runs))

    def wrap(items: List[str], indent: str = "    ", limit: int = 80) -> str:
        lines, current = [], indent
        for item in items:
            piece = item + ","
            if len(current) + len(piece) + 1 > limit and current.strip():
                lines.append(current.rstrip())
                current = indent
            current += piece + " "
        if current.strip():
            lines.append(current.rstrip())
        return "\n".join(lines)

    stored = len(data)
    out = [
        "// Generated by tools/generate_boot_image.py from %s. Do not edit;" % source,
        "// change the PNG and rerun the script.",
        "//",
        "// %dx%d, composited over BACKGROUND and converted to RGB565. Only the"
        % (width, height),
        "// pixels that differ from BACKGROUND are stored (%d of %d), as runs per"
        % (stored, width * height),
        "// row; everything else is the background the screen is filled with.",
        "#pragma once",
        "",
        "#include <stdint.h>",
        "",
        "namespace bootimage {",
        "",
        "inline constexpr int WIDTH = %d;" % width,
        "inline constexpr int HEIGHT = %d;" % height,
        "inline constexpr uint16_t BACKGROUND = 0x%04X;" % background,
        "",
        "// x and length in pixels; pixel is the run's first entry in PIXELS.",
        "struct Run {",
        "  uint8_t x;",
        "  uint8_t length;",
        "  uint16_t pixel;",
        "};",
        "",
        "// Row y's runs are RUNS[ROW_RUNS[y]] up to RUNS[ROW_RUNS[y + 1]], left to",
        "// right.",
        "inline constexpr uint16_t ROW_RUNS[HEIGHT + 1] = {",
        wrap([str(v) for v in row_runs]),
        "};",
        "",
        "inline constexpr Run RUNS[%d] = {" % len(runs),
        wrap(["{%d, %d, %d}" % run for run in runs]),
        "};",
        "",
        "// RGB565 values; the boot screen writes them high byte first, the",
        "// panel's wire order.",
        "inline constexpr uint16_t PIXELS[%d] = {" % stored,
        wrap(["0x%04X" % v for v in data]),
        "};",
        "",
        "}  // namespace bootimage",
        "",
    ]
    return "\n".join(out), stored


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", type=pathlib.Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--background", type=lambda text: int(text, 0),
        default=DEFAULT_BACKGROUND,
        help="RGB565 colour the transparent parts are drawn over "
             "(default 0x%04X)" % DEFAULT_BACKGROUND)
    parser.add_argument(
        "--check", action="store_true",
        help="exit 1 if the output is not what the input generates")
    args = parser.parse_args(argv)

    width, height, rows = read_rgba_png(args.input)
    pixels = composite(rows, width, args.background)
    try:
        source = args.input.resolve().relative_to(SKETCH).as_posix()
    except ValueError:
        source = args.input.name
    text, stored = render_header(source, width, height, args.background, pixels)
    if args.check:
        current = args.output.read_text() if args.output.exists() else ""
        if current != text:
            print("%s is stale; run python3 tools/generate_boot_image.py"
                  % args.output, file=sys.stderr)
            return 1
        print("%s matches %s" % (args.output.name, args.input.name))
        return 0
    args.output.write_text(text)
    print("wrote %s: %dx%d, %d pixels stored" % (args.output, width, height,
                                                 stored))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
