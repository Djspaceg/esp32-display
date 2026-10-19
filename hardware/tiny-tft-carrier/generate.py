#!/usr/bin/env python3
"""Generate the tiny TFT carrier KiCad project (schematic, board, libraries).

The carrier holds a Seeed XIAO ESP32-S3 or ESP32-C6 and the Questwise 0.42 inch
96x54 TFT breakout side by side, so the screen needs no wires.

Every coordinate lives here so a measured value can be changed in one place and
the files regenerated:

    python3 hardware/tiny-tft-carrier/generate.py

SCREEN_ROW_SPACING and the SCREEN_* outline values are photo estimates, not
published dimensions. Measure the breakout before ordering boards.
"""

import json
import os
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "tiny-tft-carrier"
LIB = NAME
NS = uuid.UUID("6f0c1d2e-6a51-4d1b-9a43-2f5b1a7c0e11")


def uid(*parts):
    return str(uuid.uuid5(NS, "/".join(str(p) for p in parts)))


def mm(v):
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


# ---------------------------------------------------------------- dimensions
# XIAO: Seeed wiki (21 x 17.8 mm) and Seeed's XIAO KiCad footprint
# (2.54 mm pitch, rows 15.24 mm apart, edge pads centred 8.455 mm out).
XIAO_PITCH = 2.54
XIAO_ROW = 15.24
XIAO_BODY = (-10.45, -8.9, 10.55, 8.9)  # USB-C end is +x
XIAO_USB = (10.55, -4.5, 12.05, 4.5)
XIAO_EDGE_PAD_Y = 8.455
XIAO_EDGE_PAD = (1.524, 2.432)

# Screen breakout: pin pitch and row spacing estimated from the seller's
# photos against a US quarter. TO MEASURE.
SCREEN_PITCH = 2.54
SCREEN_ROW_SPACING = 15.24
SCREEN_OUTLINE = (12.9, 20.8)  # x by y around its pin centre. TO MEASURE.

THT_PAD = 1.7
THT_DRILL = 1.0

# Board placement (KiCad page coordinates, mm, y down).
U1_AT = (120.0, 100.0)
J1_AT = (100.95, 100.0)
JP1_AT = (107.0, 97.8)
BOARD = (94.05, 88.5, 130.55, 111.5)

SIG_W = 0.25
PWR_W = 0.5

# XIAO pins: number -> name. 1-7 run D0..D6 along the -y row from the USB end,
# 8-14 run D7, D8, D9, D10, 3V3, GND, 5V along the +y row back to the USB end.
XIAO_PINS = {1: "D0", 2: "D1", 3: "D2", 4: "D3", 5: "D4", 6: "D5", 7: "D6",
             8: "D7", 9: "D8", 10: "D9", 11: "D10", 12: "3V3", 13: "GND",
             14: "5V"}

# Screen pins in the seller's order. The breakout is two rows of four.
SCREEN_PINS = {1: "3V3", 2: "SCLK", 3: "SDIN", 4: "GND",
               5: "BL", 6: "DC", 7: "RES", 8: "CS"}

# Carrier nets: XIAO pin -> net, screen pin -> net.
XIAO_NET = {12: "+3V3", 13: "GND", 9: "SCLK", 11: "SDIN",
            4: "DC", 5: "RES", 6: "CS", 2: "BL_D1"}
SCREEN_NET = {1: "+3V3", 2: "SCLK", 3: "SDIN", 4: "GND",
              5: "BL", 6: "DC", 7: "RES", 8: "CS"}
JP1_NET = {1: "BL", 2: "BL_D1"}
NETS = ["+3V3", "GND", "SCLK", "SDIN", "DC", "RES", "CS", "BL", "BL_D1"]


def xiao_pad_xy(n):
    if n <= 7:
        return (7.62 - XIAO_PITCH * (n - 1), -XIAO_ROW / 2)
    return (-7.62 + XIAO_PITCH * (n - 8), XIAO_ROW / 2)


def screen_pad_xy(n):
    # Screen fitted face up with its flex cable at the end away from the
    # XIAO. Column 0 is nearest the XIAO.
    #   +y row, near to far: GND, SDIN, SCLK, 3V3   (pins 4, 3, 2, 1)
    #   -y row, near to far: CS, RES, DC, BL        (pins 8, 7, 6, 5)
    col = {4: 0, 3: 1, 2: 2, 1: 3, 8: 0, 7: 1, 6: 2, 5: 3}[n]
    x = 1.5 * SCREEN_PITCH - col * SCREEN_PITCH
    y = SCREEN_ROW_SPACING / 2 if n <= 4 else -SCREEN_ROW_SPACING / 2
    return (x, y)


def unconnected(ref, pin_name, pad):
    return f"unconnected-({ref}-{pin_name}-Pad{pad})"


def xiao_net(n):
    return XIAO_NET.get(n) or unconnected("U1", XIAO_PINS[n], n)


# ---------------------------------------------------------------- footprints
def font(size=1.0, thick=0.15):
    return f"(effects (font (size {mm(size)} {mm(size)}) (thickness {mm(thick)})))"


def fp_prop(key, value, at, layer, hide=False, size=1.0, thick=0.15):
    h = " (hide yes)" if hide else ""
    return (f'\t(property "{key}" "{value}" (at {mm(at[0])} {mm(at[1])} 0) '
            f'(layer "{layer}"){h} (uuid "{uid("fp", key, value, layer)}") '
            f'{font(size, thick)})\n')


def fp_rect(a, b, layer, width, tag):
    return (f'\t(fp_rect (start {mm(a[0])} {mm(a[1])}) (end {mm(b[0])} {mm(b[1])}) '
            f'(stroke (width {mm(width)}) (type solid)) (fill no) '
            f'(layer "{layer}") (uuid "{uid("fprect", tag, layer)}"))\n')


def fp_line(a, b, layer, width, tag):
    return (f'\t(fp_line (start {mm(a[0])} {mm(a[1])}) (end {mm(b[0])} {mm(b[1])}) '
            f'(stroke (width {mm(width)}) (type solid)) '
            f'(layer "{layer}") (uuid "{uid("fpline", tag, layer)}"))\n')


def fp_text(text, at, layer, tag, size=0.8, thick=0.12):
    return (f'\t(fp_text user "{text}" (at {mm(at[0])} {mm(at[1])} 0) '
            f'(layer "{layer}") (uuid "{uid("fptext", tag)}") {font(size, thick)})\n')


def pad_tht(n, xy, square, net):
    shape = "rect" if square else "circle"
    netpart = f' (net {NET_INDEX[net]} "{net}")' if net else ""
    return (f'\t(pad "{n}" thru_hole {shape} (at {mm(xy[0])} {mm(xy[1])}) '
            f'(size {mm(THT_PAD)} {mm(THT_PAD)}) (drill {mm(THT_DRILL)}) '
            f'(layers "*.Cu" "*.Mask") (remove_unused_layers no){netpart} '
            f'(uuid "{uid("pad", n, xy, "tht")}"))\n')


def pad_smd(n, xy, size, layers, net):
    netpart = f' (net {NET_INDEX[net]} "{net}")' if net else ""
    lay = " ".join(f'"{l}"' for l in layers)
    return (f'\t(pad "{n}" smd rect (at {mm(xy[0])} {mm(xy[1])}) '
            f'(size {mm(size[0])} {mm(size[1])}) (layers {lay}){netpart} '
            f'(uuid "{uid("pad", n, xy, "smd")}"))\n')


# Schematic value, datasheet and description per part; placed footprints
# carry the same fields so the board matches the schematic.
PARTS = {
    "U1": ("XIAO_ESP32_DIP14",
           "https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/",
           "Seeed Studio XIAO ESP32-S3 / ESP32-C6, 14 edge pins"),
    "J1": ("Questwise_TFT_042_96x54",
           "https://www.tindie.com/products/questwise-ventures/miniature-042-rgb-color-tft-96x54-screen-display/",
           "0.42in 96x54 RGB TFT breakout, ST7735-family, SPI, 3.3 V only"),
    "JP1": ("SolderJumper_2_Open", "", "Solder jumper, open by default"),
}


def fields(placed, ref, flip=False):
    _, sheet, desc = PARTS[ref] if placed else ("", "", "")
    layer = "B.Fab" if flip else "F.Fab"
    s = fp_prop("Footprint", "", (0, 0), layer, hide=True, size=1.27)
    s += fp_prop("Datasheet", sheet, (0, 0), layer, hide=True, size=1.27)
    s += fp_prop("Description", desc, (0, 0), layer, hide=True, size=1.27)
    return s


def xiao_footprint(placed):
    name = "XIAO_ESP32_DIP14"
    at = f" (at {mm(U1_AT[0])} {mm(U1_AT[1])})" if placed else ""
    s = (f'(footprint "{LIB + ":" if placed else ""}{name}" (version 20240108) (generator "pcbnew") (generator_version "8.0")\n'
         if not placed else f'(footprint "{LIB}:{name}" (layer "F.Cu") (uuid "{uid("U1")}"){at}\n')
    if not placed:
        s += '\t(layer "F.Cu")\n'
    s += '\t(descr "Seeed Studio XIAO (ESP32-S3 / ESP32-C6 / ESP32-C3), 2x7 2.54 mm, rows 15.24 mm, through holes plus edge pads for soldering flat")\n'
    s += '\t(tags "XIAO ESP32")\n'
    s += fp_prop("Reference", "U1" if placed else "REF**", (0, -3.0), "F.SilkS")
    s += fp_prop("Value", name, (0, 3.0), "F.Fab")
    s += fields(placed, "U1")
    s += '\t(attr through_hole)\n'
    x0, y0, x1, y1 = XIAO_BODY
    s += fp_rect((x0, y0), (x1, y1), "F.Fab", 0.1, "xiao-body")
    ux0, uy0, ux1, uy1 = XIAO_USB
    s += fp_rect((ux0, uy0), (ux1, uy1), "F.Fab", 0.1, "xiao-usb")
    s += fp_text("USB-C", (8.0, 0), "F.Fab", "xiao-usb-fab", 0.8, 0.12)
    s += fp_rect((x0 - 0.25, -10.0), (x1 + 0.25, 10.0), "F.CrtYd", 0.05, "xiao-crt")
    # Silk: the end away from USB, and a pin-1 mark beside D0.
    s += fp_line((x0 - 0.15, -8.6), (x0 - 0.15, 8.6), "F.SilkS", 0.12, "xiao-silk-end")
    s += fp_line((8.9, -6.2), (6.3, -6.2), "F.SilkS", 0.12, "xiao-silk-pin1")
    s += fp_text("XIAO S3/C6", (-2.0, -0.2), "F.SilkS", "xiao-silk-name", 0.8, 0.12)
    s += fp_text("USB >", (5.5, 1.8), "F.SilkS", "xiao-silk-usb", 0.8, 0.12)
    for n in range(1, 15):
        x, y = xiao_pad_xy(n)
        net = xiao_net(n) if placed else None
        s += pad_tht(n, (x, y), n == 1, net)
        ey = XIAO_EDGE_PAD_Y if y > 0 else -XIAO_EDGE_PAD_Y
        s += pad_smd(n, (x, ey), XIAO_EDGE_PAD, ["F.Cu", "F.Mask"], net)
    s += ')\n'
    return s


SILK_LABEL = {"SCLK": "SCK", "SDIN": "SDI"}


def screen_footprint(placed):
    name = "Questwise_TFT_042_96x54_2x4"
    if placed:
        s = f'(footprint "{LIB}:{name}" (layer "F.Cu") (uuid "{uid("J1")}") (at {mm(J1_AT[0])} {mm(J1_AT[1])})\n'
    else:
        s = f'(footprint "{name}" (version 20240108) (generator "pcbnew") (generator_version "8.0")\n\t(layer "F.Cu")\n'
    s += '\t(descr "Questwise 0.42 inch 96x54 TFT breakout, two rows of four pins. Row spacing and outline are photo estimates: measure before ordering")\n'
    s += '\t(tags "TFT ST7735")\n'
    s += fp_prop("Reference", "J1" if placed else "REF**", (0, -1.5), "F.SilkS")
    s += fp_prop("Value", PARTS["J1"][0] if placed else name, (0, 1.5), "F.Fab")
    s += fields(placed, "J1")
    s += '\t(attr through_hole)\n'
    w, h = SCREEN_OUTLINE
    s += fp_rect((-w / 2, -h / 2), (w / 2, h / 2), "F.Fab", 0.1, "tft-body")
    s += fp_text("outline TO MEASURE", (0, 4.0), "F.Fab", "tft-measure", 0.8, 0.12)
    s += fp_text("flex cable end", (-w / 2 + 2.2, 0), "F.Fab", "tft-fpc", 0.6, 0.1)
    s += fp_rect((-w / 2 - 0.25, -h / 2 - 0.25), (w / 2 + 0.25, h / 2 + 0.25), "F.CrtYd", 0.05, "tft-crt")
    # Silk labels outside each pin row, matching the screen's own printing.
    r = SCREEN_ROW_SPACING / 2
    for n, label in SCREEN_PINS.items():
        x, y = screen_pad_xy(n)
        ty = y + 2.2 if y > 0 else y - 2.2
        s += fp_text(SILK_LABEL.get(label, label), (x, ty), "F.SilkS", f"tft-silk-{label}", 0.8, 0.12)
    s += fp_line((-w / 2 + 0.6, -r + 1.4), (-w / 2 + 0.6, r - 1.4), "F.SilkS", 0.12, "tft-silk-fpc")
    for n in range(1, 9):
        net = SCREEN_NET[n] if placed else None
        s += pad_tht(n, screen_pad_xy(n), n == 1, net)
    s += ')\n'
    return s


def jumper_footprint(placed):
    name = "SolderJumper_2_Open"
    pads = {1: (-0.65, 0), 2: (0.65, 0)}
    if placed:
        # Fitted on the back: KiCad stores back-side footprints mirrored.
        s = (f'(footprint "{LIB}:{name}" (layer "B.Cu") (uuid "{uid("JP1")}") '
             f'(at {mm(JP1_AT[0])} {mm(JP1_AT[1])})\n')
        side = {"F.Cu": "B.Cu", "F.Mask": "B.Mask", "F.SilkS": "B.SilkS",
                "F.Fab": "B.Fab", "F.CrtYd": "B.CrtYd"}
        fy = -1
    else:
        s = f'(footprint "{name}" (version 20240108) (generator "pcbnew") (generator_version "8.0")\n\t(layer "F.Cu")\n'
        side = {k: k for k in ("F.Cu", "F.Mask", "F.SilkS", "F.Fab", "F.CrtYd")}
        fy = 1
    s += '\t(descr "Two-pad solder jumper, open by default, 1.0 x 1.5 mm pads, 0.3 mm gap")\n'
    s += '\t(tags "solder jumper open")\n'

    def prop(key, value, at, layer, hide=False, size=1.0, thick=0.15):
        h = " (hide yes)" if hide else ""
        just = " (justify mirror)" if placed else ""
        return (f'\t(property "{key}" "{value}" (at {mm(at[0])} {mm(at[1] * fy)} 0) '
                f'(layer "{side[layer]}"){h} (uuid "{uid("jp", key, placed)}") '
                f'(effects (font (size {mm(size)} {mm(size)}) (thickness {mm(thick)})){just}))\n')

    s += prop("Reference", "JP1" if placed else "REF**", (0, -1.7), "F.SilkS", size=0.8, thick=0.12)
    s += prop("Value", name, (0, 1.9), "F.Fab")
    s += prop("Footprint", "", (0, 0), "F.Fab", hide=True, size=1.27)
    s += prop("Datasheet", "", (0, 0), "F.Fab", hide=True, size=1.27)
    s += prop("Description", PARTS["JP1"][2] if placed else "", (0, 0), "F.Fab", hide=True, size=1.27)
    s += '\t(attr smd exclude_from_pos_files exclude_from_bom)\n'
    s += fp_rect((-1.4, -1.0), (1.4, 1.0), side["F.CrtYd"], 0.05, f"jp-crt-{placed}")
    s += fp_line((-1.4, -0.95), (1.4, -0.95), side["F.SilkS"], 0.12, f"jp-silk-a-{placed}")
    s += fp_line((-1.4, 0.95), (1.4, 0.95), side["F.SilkS"], 0.12, f"jp-silk-b-{placed}")
    for n, (x, y) in pads.items():
        net = JP1_NET[n] if placed else None
        s += pad_smd(n, (x, y * fy), (1.0, 1.5), [side["F.Cu"], side["F.Mask"]], net)
    s += ')\n'
    return s


# ---------------------------------------------------------------- board
NET_INDEX = {}


def board_routes():
    """Return (layer, width, net, [points]) polylines in board coordinates."""
    ux, uy = U1_AT
    jx, jy = J1_AT

    def u(n):
        x, y = xiao_pad_xy(n)
        return (ux + x, uy + y)

    def j(n):
        x, y = screen_pad_xy(n)
        return (jx + x, jy + y)

    def lane(a, b, y):
        return [a, (a[0], y), (b[0], y), b]

    jp_bl = (JP1_AT[0] - 0.65, JP1_AT[1])     # pad 1 (BL)
    jp_d1 = (JP1_AT[0] + 0.65, JP1_AT[1])     # pad 2 (BL_D1)
    routes = [
        # Screen +y row (power row), all on the back except SCLK.
        ("B.Cu", SIG_W, "SDIN", lane(u(11), j(3), 105.8)),
        ("B.Cu", PWR_W, "+3V3", lane(u(12), j(1), 104.6)),
        ("B.Cu", PWR_W, "GND", lane(u(13), j(4), 109.4)),
        ("F.Cu", SIG_W, "SCLK", lane(u(9), j(2), 110.6)),
        # Screen -y row, all on the back.
        ("B.Cu", SIG_W, "CS", lane(u(6), j(8), 94.2)),
        ("B.Cu", SIG_W, "RES", lane(u(5), j(7), 95.2)),
        ("B.Cu", SIG_W, "DC", lane(u(4), j(6), 96.2)),
        ("B.Cu", SIG_W, "BL_D1", [u(2), (u(2)[0], jp_d1[1]), jp_d1]),
        ("B.Cu", SIG_W, "BL", [jp_bl, (j(5)[0], jp_bl[1]), j(5)]),
    ]
    return routes


def write_board():
    for i, n in enumerate(NETS + sorted(
            unconnected("U1", XIAO_PINS[p], p) for p in XIAO_PINS if p not in XIAO_NET), start=1):
        NET_INDEX[n] = i
    out = ['(kicad_pcb (version 20240108) (generator "pcbnew") (generator_version "8.0")\n',
           '\t(general (thickness 1.6) (legacy_teardrops no))\n',
           '\t(paper "A4")\n',
           '\t(title_block (title "Tiny TFT carrier: XIAO ESP32-S3/C6 + Questwise 0.42in 96x54 TFT") (rev "A") '
           '(comment 1 "Screen row spacing and outline are photo estimates: TO MEASURE before ordering"))\n',
           '\t(layers\n']
    for idx, name, kind, alias in [
            (0, "F.Cu", "signal", None), (31, "B.Cu", "signal", None),
            (32, "B.Adhes", "user", "B.Adhesive"), (33, "F.Adhes", "user", "F.Adhesive"),
            (34, "B.Paste", "user", None), (35, "F.Paste", "user", None),
            (36, "B.SilkS", "user", "B.Silkscreen"), (37, "F.SilkS", "user", "F.Silkscreen"),
            (38, "B.Mask", "user", None), (39, "F.Mask", "user", None),
            (40, "Dwgs.User", "user", "User.Drawings"), (41, "Cmts.User", "user", "User.Comments"),
            (42, "Eco1.User", "user", "User.Eco1"), (43, "Eco2.User", "user", "User.Eco2"),
            (44, "Edge.Cuts", "user", None), (45, "Margin", "user", None),
            (46, "B.CrtYd", "user", "B.Courtyard"), (47, "F.CrtYd", "user", "F.Courtyard"),
            (48, "B.Fab", "user", None), (49, "F.Fab", "user", None)]:
        a = f' "{alias}"' if alias else ""
        out.append(f'\t\t({idx} "{name}" {kind}{a})\n')
    out.append('\t)\n')
    out.append('\t(setup (pad_to_mask_clearance 0) (allow_soldermask_bridges_in_footprints no))\n')
    out.append('\t(net 0 "")\n')
    for n, i in NET_INDEX.items():
        out.append(f'\t(net {i} "{n}")\n')
    out.append(xiao_footprint(True))
    out.append(screen_footprint(True))
    out.append(jumper_footprint(True))
    x0, y0, x1, y1 = BOARD
    out.append(f'\t(gr_rect (start {mm(x0)} {mm(y0)}) (end {mm(x1)} {mm(y1)}) '
               f'(stroke (width 0.1) (type default)) (fill no) (layer "Edge.Cuts") (uuid "{uid("edge")}"))\n')
    texts = [
        ("Tiny TFT carrier rev A", (103.0, 89.6), "B.SilkS"),
        ("JP1 bridged: D1 drives BL", (108.0, 100.6), "B.SilkS"),
        ("JP1 open: backlight always on", (108.0, 102.0), "B.SilkS"),
    ]
    for text, (tx, ty), layer in texts:
        just = " (justify mirror)" if layer.startswith("B.") else ""
        out.append(f'\t(gr_text "{text}" (at {mm(tx)} {mm(ty)} 0) (layer "{layer}") '
                   f'(uuid "{uid("text", text)}") (effects (font (size 0.8 0.8) (thickness 0.12)){just}))\n')
    for layer, width, net, pts in board_routes():
        for a, b in zip(pts, pts[1:]):
            if a == b:
                continue
            out.append(f'\t(segment (start {mm(a[0])} {mm(a[1])}) (end {mm(b[0])} {mm(b[1])}) '
                       f'(width {mm(width)}) (layer "{layer}") (net {NET_INDEX[net]}) '
                       f'(uuid "{uid("seg", net, a, b)}"))\n')
    out.append(')\n')
    with open(os.path.join(HERE, f"{NAME}.kicad_pcb"), "w") as f:
        f.writelines(out)


def write_footprint_lib():
    d = os.path.join(HERE, f"{NAME}.pretty")
    os.makedirs(d, exist_ok=True)
    for name, fn in [("XIAO_ESP32_DIP14", xiao_footprint),
                     ("Questwise_TFT_042_96x54_2x4", screen_footprint),
                     ("SolderJumper_2_Open", jumper_footprint)]:
        with open(os.path.join(d, f"{name}.kicad_mod"), "w") as f:
            f.write(fn(False))


# ---------------------------------------------------------------- symbols
SYM_FONT = "(effects (font (size 1.27 1.27)))"


def sym_pin(name, num, at, angle, length=2.54):
    return (f'\t\t\t(pin passive line (at {mm(at[0])} {mm(at[1])} {angle}) (length {mm(length)}) '
            f'(name "{name}" {SYM_FONT}) (number "{num}" {SYM_FONT}))\n')


def sym_prop(key, value, at, hide=False):
    h = " (hide yes)" if hide else ""
    return (f'\t\t(property "{key}" "{value}" (at {mm(at[0])} {mm(at[1])} 0) '
            f'(effects (font (size 1.27 1.27)){h}))\n')


SYMBOLS = {}


def define_symbols():
    # XIAO: left side D0..D6 top to bottom; right side 5V..D7 top to bottom,
    # the order the pins sit on the module.
    s = sym_prop("Reference", "U", (0, 11.43))
    s += sym_prop("Value", "XIAO_ESP32_DIP14", (0, -11.43))
    s += sym_prop("Footprint", f"{LIB}:XIAO_ESP32_DIP14", (0, -13.97), True)
    s += sym_prop("Datasheet", "https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/", (0, -16.51), True)
    s += sym_prop("Description", "Seeed Studio XIAO ESP32-S3 / ESP32-C6, 14 edge pins", (0, -19.05), True)
    body = ('\t\t(symbol "XIAO_ESP32_DIP14_0_1"\n'
            '\t\t\t(rectangle (start -10.16 10.16) (end 10.16 -10.16) '
            '(stroke (width 0.254) (type default)) (fill (type background)))\n\t\t)\n')
    pins = '\t\t(symbol "XIAO_ESP32_DIP14_1_1"\n'
    for n in range(1, 8):
        pins += sym_pin(XIAO_PINS[n], n, (-12.7, 7.62 - 2.54 * (n - 1)), 0)
    for n in range(8, 15):
        pins += sym_pin(XIAO_PINS[n], n, (12.7, -7.62 + 2.54 * (n - 8)), 180)
    pins += '\t\t)\n'
    SYMBOLS["XIAO_ESP32_DIP14"] = s + body + pins

    s = sym_prop("Reference", "J", (0, 7.62))
    s += sym_prop("Value", "Questwise_TFT_042_96x54", (0, -7.62))
    s += sym_prop("Footprint", f"{LIB}:Questwise_TFT_042_96x54_2x4", (0, -10.16), True)
    s += sym_prop("Datasheet", "https://www.tindie.com/products/questwise-ventures/miniature-042-rgb-color-tft-96x54-screen-display/", (0, -12.7), True)
    s += sym_prop("Description", "0.42in 96x54 RGB TFT breakout, ST7735-family, SPI, 3.3 V only", (0, -15.24), True)
    body = ('\t\t(symbol "Questwise_TFT_042_96x54_0_1"\n'
            '\t\t\t(rectangle (start -7.62 6.35) (end 7.62 -6.35) '
            '(stroke (width 0.254) (type default)) (fill (type background)))\n\t\t)\n')
    pins = '\t\t(symbol "Questwise_TFT_042_96x54_1_1"\n'
    for n in range(1, 5):
        pins += sym_pin(SCREEN_PINS[n], n, (-10.16, 3.81 - 2.54 * (n - 1)), 0)
    for n in range(5, 9):
        pins += sym_pin(SCREEN_PINS[n], n, (10.16, 3.81 - 2.54 * (n - 5)), 180)
    pins += '\t\t)\n'
    SYMBOLS["Questwise_TFT_042_96x54"] = s + body + pins

    s = sym_prop("Reference", "JP", (0, 2.54))
    s += sym_prop("Value", "SolderJumper_2_Open", (0, -2.54))
    s += sym_prop("Footprint", f"{LIB}:SolderJumper_2_Open", (0, -5.08), True)
    s += sym_prop("Datasheet", "", (0, -7.62), True)
    s += sym_prop("Description", "Solder jumper, open by default", (0, -10.16), True)
    body = ('\t\t(symbol "SolderJumper_2_Open_0_1"\n'
            '\t\t\t(rectangle (start -1.524 0.762) (end -0.254 -0.762) '
            '(stroke (width 0) (type default)) (fill (type outline)))\n'
            '\t\t\t(rectangle (start 0.254 0.762) (end 1.524 -0.762) '
            '(stroke (width 0) (type default)) (fill (type outline)))\n\t\t)\n')
    pins = '\t\t(symbol "SolderJumper_2_Open_1_1"\n'
    pins += sym_pin("A", 1, (-3.81, 0), 0, 2.286)
    pins += sym_pin("B", 2, (3.81, 0), 180, 2.286)
    pins += '\t\t)\n'
    SYMBOLS["SolderJumper_2_Open"] = s + body + pins


IN_BOM = {"SolderJumper_2_Open": "no"}


def symbol_block(name, qualified):
    full = f"{LIB}:{name}" if qualified else name
    return (f'\t(symbol "{full}" (pin_names (offset 1.016)) (exclude_from_sim no) '
            f'(in_bom {IN_BOM.get(name, "yes")}) (on_board yes)\n' + SYMBOLS[name] + '\t)\n')


def write_symbol_lib():
    with open(os.path.join(HERE, f"{NAME}.kicad_sym"), "w") as f:
        f.write('(kicad_symbol_lib (version 20231120) (generator "kicad_symbol_editor") (generator_version "8.0")\n')
        for name in SYMBOLS:
            f.write(symbol_block(name, False))
        f.write(')\n')


# ---------------------------------------------------------------- schematic
ROOT = uid("root-sheet")


def write_schematic():
    out = [f'(kicad_sch (version 20231120) (generator "eeschema") (generator_version "8.0")\n',
           f'\t(uuid "{ROOT}")\n', '\t(paper "A4")\n',
           '\t(title_block (title "Tiny TFT carrier") (rev "A") '
           '(comment 1 "XIAO ESP32-S3 or ESP32-C6 + Questwise 0.42in 96x54 TFT, no wires") '
           '(comment 2 "Screen row spacing and outline are photo estimates: TO MEASURE"))\n',
           '\t(lib_symbols\n']
    for name in SYMBOLS:
        out.append(symbol_block(name, True))
    out.append('\t)\n')

    def place(lib_name, ref, value, at, pins, fields):
        s = (f'\t(symbol (lib_id "{LIB}:{lib_name}") (at {mm(at[0])} {mm(at[1])} 0) (unit 1) '
             f'(exclude_from_sim no) (in_bom {IN_BOM.get(lib_name, "yes")}) (on_board yes) (dnp no) (uuid "{uid("sym", ref)}")\n')
        for key, val, off, hide in fields(ref, value):
            h = " (hide yes)" if hide else ""
            s += (f'\t\t(property "{key}" "{val}" (at {mm(at[0] + off[0])} {mm(at[1] + off[1])} 0) '
                  f'(effects (font (size 1.27 1.27)){h}))\n')
        for p in pins:
            s += f'\t\t(pin "{p}" (uuid "{uid("pin", ref, p)}"))\n'
        s += (f'\t\t(instances (project "{NAME}" (path "/{ROOT}" (reference "{ref}") (unit 1))))\n\t)\n')
        return s

    def fields_for(lib_name, foot, sheet, desc, top, bottom):
        def f(ref, value):
            return [("Reference", ref, (0, -top), False),
                    ("Value", value, (0, bottom), False),
                    ("Footprint", f"{LIB}:{foot}", (0, bottom + 2.54), True),
                    ("Datasheet", sheet, (0, bottom + 5.08), True),
                    ("Description", desc, (0, bottom + 7.62), True)]
        return f

    U1 = (88.9, 101.6)
    J1 = (190.5, 101.6)
    JP1 = (152.4, 63.5)
    out.append(place("XIAO_ESP32_DIP14", "U1", "XIAO_ESP32_DIP14", U1, range(1, 15),
                     fields_for("XIAO_ESP32_DIP14", "XIAO_ESP32_DIP14",
                                "https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/",
                                "Seeed Studio XIAO ESP32-S3 / ESP32-C6, 14 edge pins", 11.43, 11.43)))
    out.append(place("Questwise_TFT_042_96x54", "J1", "Questwise_TFT_042_96x54", J1, range(1, 9),
                     fields_for("Questwise_TFT_042_96x54", "Questwise_TFT_042_96x54_2x4",
                                "https://www.tindie.com/products/questwise-ventures/miniature-042-rgb-color-tft-96x54-screen-display/",
                                "0.42in 96x54 RGB TFT breakout, ST7735-family, SPI, 3.3 V only", 7.62, 7.62)))
    out.append(place("SolderJumper_2_Open", "JP1", "SolderJumper_2_Open", JP1, range(1, 3),
                     fields_for("SolderJumper_2_Open", "SolderJumper_2_Open", "",
                                "Solder jumper, open by default", 2.54, 2.54)))

    def label(net, at, right):
        angle, just = (0, "left") if right else (180, "right")
        return (f'\t(global_label "{net}" (shape passive) (at {mm(at[0])} {mm(at[1])} {angle}) '
                f'(fields_autoplaced yes) (effects (font (size 1.27 1.27)) (justify {just})) '
                f'(uuid "{uid("label", net, at)}")\n'
                f'\t\t(property "Intersheetrefs" "${{INTERSHEET_REFS}}" (at {mm(at[0])} {mm(at[1])} 0) '
                f'(effects (font (size 1.27 1.27)) (hide yes)))\n\t)\n')

    def noconn(at):
        return f'\t(no_connect (at {mm(at[0])} {mm(at[1])}) (uuid "{uid("nc", at)}"))\n'

    for n in range(1, 15):
        if n <= 7:
            at, right = (U1[0] - 12.7, U1[1] - (7.62 - 2.54 * (n - 1))), False
        else:
            at, right = (U1[0] + 12.7, U1[1] - (-7.62 + 2.54 * (n - 8))), True
        out.append(label(XIAO_NET[n], at, right) if n in XIAO_NET else noconn(at))
    for n in range(1, 9):
        if n <= 4:
            at, right = (J1[0] - 10.16, J1[1] - (3.81 - 2.54 * (n - 1))), False
        else:
            at, right = (J1[0] + 10.16, J1[1] - (3.81 - 2.54 * (n - 5))), True
        out.append(label(SCREEN_NET[n], at, right))
    out.append(label(JP1_NET[1], (JP1[0] - 3.81, JP1[1]), False))
    out.append(label(JP1_NET[2], (JP1[0] + 3.81, JP1[1]), True))

    notes = [
        ((30.48, 129.54),
         "Pin map (XIAO pin = ESP32-S3 GPIO / ESP32-C6 GPIO):\\n"
         "SCLK = D8 = GPIO7 / GPIO19\\nSDIN = D10 = GPIO9 / GPIO18\\n"
         "DC = D3 = GPIO4 / GPIO21\\nRES = D4 = GPIO5 / GPIO22\\nCS = D5 = GPIO6 / GPIO23\\n"
         "BL = D1 = GPIO2 / GPIO1, only when JP1 is bridged\\n"
         "Unused on purpose: D0, D2 (S3 strapping GPIO3), D6/D7 (UART0), D9, 5V"),
        ((129.54, 50.8),
         "JP1 open (as made): the screen keeps BL pulled high, backlight always on.\\n"
         "Bridge JP1 to switch the backlight from D1 (high = on)."),
        ((129.54, 129.54),
         "Screen breakout: two rows of four pins, 2.54 mm pitch.\\n"
         "Row spacing 15.24 mm and outline about 12.9 x 20.8 mm are photo estimates: TO MEASURE.\\n"
         "Fit the screen face up, flex cable at the end away from the XIAO."),
    ]
    for (x, y), text in notes:
        out.append(f'\t(text "{text}" (exclude_from_sim no) (at {mm(x)} {mm(y)} 0) '
                   f'(effects (font (size 1.27 1.27)) (justify left top)) (uuid "{uid("note", x, y)}"))\n')
    out.append('\t(sheet_instances (path "/" (page "1")))\n)\n')
    with open(os.path.join(HERE, f"{NAME}.kicad_sch"), "w") as f:
        f.writelines(out)


def write_project():
    with open(os.path.join(HERE, "fp-lib-table"), "w") as f:
        f.write('(fp_lib_table\n\t(version 7)\n'
                f'\t(lib (name "{LIB}") (type "KiCad") (uri "${{KIPRJMOD}}/{NAME}.pretty") (options "") (descr "Carrier footprints"))\n)\n')
    with open(os.path.join(HERE, "sym-lib-table"), "w") as f:
        f.write('(sym_lib_table\n\t(version 7)\n'
                f'\t(lib (name "{LIB}") (type "KiCad") (uri "${{KIPRJMOD}}/{NAME}.kicad_sym") (options "") (descr "Carrier symbols"))\n)\n')
    pro = {"meta": {"filename": f"{NAME}.kicad_pro", "version": 1},
           "board": {"design_settings": {"rules": {
               "min_clearance": 0.2, "min_track_width": 0.2, "min_copper_edge_clearance": 0.5,
               "min_through_hole_diameter": 0.3, "min_hole_to_hole": 0.25}}}}
    with open(os.path.join(HERE, f"{NAME}.kicad_pro"), "w") as f:
        json.dump(pro, f, indent=2)
        f.write("\n")


def main():
    define_symbols()
    write_symbol_lib()
    write_footprint_lib()
    write_board()
    write_schematic()
    write_project()


if __name__ == "__main__":
    main()
