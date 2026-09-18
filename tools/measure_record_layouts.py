#!/usr/bin/env python3
"""Measure what RECORD COUNT costs the panel, independently of packet count.

Answers the open question left by evidence/fullframe-fps-466 section 4: the
panel's per-datagram cost is understood, but the cost attributable to the number
of RECORDS inside those datagrams is not. Three layouts carry the same pixels in
the same number of datagrams (or fewer) with wildly different record counts, so
comparing them isolates record-handling cost from radio cost.

  single      one record per visible tile - the most records possible
  fill        coalesce contiguous tiles into runs that fill each datagram
  production  what the shipped sender actually emits

WHAT THE BUILDERS SHOW BEFORE ANY PANEL IS INVOLVED (run --dry-run): since the
sender's packet-fill fix shipped, `production` and `fill` are the same layout -
92/65 versus 91/66 records/datagrams in full BC1, and 44/16 in both for half.
The three-arm plan in evidence/fullframe-fps-466 section 4 predates that fix and
quotes `production` at 98/97 and 30/24, which the shipped sender can no longer
produce. So the experiment reduces to TWO distinct arms, and is sharper for it:
`single` at 719 records / 66 datagrams against `fill` at 91 / 66. Near-identical
datagram counts, a 7.9x difference in records - which is exactly the falsifier
that section states.

MEASUREMENT ONLY. This adds no wire format and changes no firmware. It selects
among layouts the current protocol already expresses, which is why it can run
before any protocol work is authorised.

WHY INTERLEAVED: run-to-run spread on this panel is about 4 fps peak-to-peak
(docs/tile-stream-plan.md section 17.11), so blocked sampling lies. Layouts are
rotated per round (A B C A B C ...) and every other variable - pixels, frame
rate, codec, receive-core setting, all CFGTUNE values - is held fixed.

LINK-HEALTH GATE, learned the hard way in section 17.17: if the link cannot
carry the offered rate, every arm collapses identically and the run measures the
radio instead of the firmware. A 1450-byte ping must be lossless with typical
RTT under about 15 ms or the run is refused. This is not a CFGRXCORE A/B; all
arms use one unchanged core setting.

Quiesce every other sender first - pause the app's panels or quit it, since it
un-pauses under its own supervision - or its frames are counted as ours.

Usage, with no board attached, to print the layouts and their costs:
  python3 tools/measure_record_layouts.py --dry-run

Usage against a panel:
  python3 tools/measure_record_layouts.py \\
      --serial /dev/cu.usbmodemXXXX --host 192.168.1.83 --codec bc1 \\
      --layouts single,fill,production --target-fps 8 \\
      --seconds 25 --rounds 4 --log /tmp/record-layout-full.log
  python3 tools/measure_record_layouts.py \\
      --serial /dev/cu.usbmodemXXXX --host 192.168.1.83 --codec half-bc1 \\
      --layouts single,fill,production --target-fps 25 \\
      --seconds 25 --rounds 4 --log /tmp/record-layout-half.log
"""
import argparse
import os
import re
import select
import socket
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import espdisp  # noqa: E402  (open_serial: termios-only, no pyserial)

UDP_PORT = 5568
LAYOUTS = ("single", "fill", "production")
CODECS = {"bc1": espdisp.TILE_CODEC_BC1,
          "half-bc1": espdisp.TILE_CODEC_HALF_BC1}
# Payload bytes one 16x16 tile encodes to. BC1 is 8 bytes per 4x4 block; the
# half-resolution codec encodes a quarter of the pixels, so a quarter of that.
TILE_BYTES = {"bc1": 128, "half-bc1": 32}
# The datagram budget less the 6-byte tile header.
RECORD_SPACE = espdisp.TILE_PACKET_BUDGET - 6
# A record's runLen field is 5 bits, biased by one.
MAX_RUN = 32

FRAMES_RE = re.compile(
    r"frames=(\d+) dropped=(\d+) partial=(\d+) packets=(\d+)")
TILEDRAW_RE = re.compile(
    r"tiledraw: (\d+) passes, (\d+) calls, (\d+) gateblocked \| per pass: "
    r"(\d+) us total = spin (\d+) \+ gather (\d+) \+ queue (\d+) \+ bar (\d+)")
PING_LOSS_RE = re.compile(r"([\d.]+)% packet loss")
PING_RTT_RE = re.compile(
    r"round-trip min/avg/max/stddev = [\d.]+/([\d.]+)/")


def visible_runs(width, height):
    """Contiguous runs of visible tiles, in wire order, one list per tile row.

    Runs never span rows: tile indices are row-major, so a run that crossed a
    row boundary would address tiles the sender did not mean. Reuses the
    repo's own circle classifier rather than re-deriving which tiles the round
    glass shows - a second implementation of that mask would be a second thing
    to get wrong.
    """
    vis = espdisp.tile_visibility(width, height)
    shown = set(vis["inside"]) | set(vis["boundary"])
    cols = (width + espdisp.TILE_DIM - 1) // espdisp.TILE_DIM
    rows = (height + espdisp.TILE_DIM - 1) // espdisp.TILE_DIM
    runs = []
    for r in range(rows):
        start = None
        for c in range(cols + 1):
            index = r * cols + c
            present = c < cols and index in shown
            if present and start is None:
                start = index
            elif not present and start is not None:
                runs.append((start, index - start))
                start = None
    return runs, sum(length for _, length in runs)


def pack(records, dirty_count, frame_id):
    """Greedily fill datagrams; a record never spans one, as the firmware's
    forEachRecord requires. Mirrors espdisp.tile_test_packets's packer."""
    packets = []
    current = []
    size = 0
    first = None
    for start, rec in records:
        if size + len(rec) > RECORD_SPACE and current:
            packets.append(espdisp.tile_header(frame_id, first, dirty_count)
                           + b"".join(current))
            current, size, first = [], 0, None
        if first is None:
            first = start
        current.append(rec)
        size += len(rec)
    if current:
        packets.append(espdisp.tile_header(frame_id, first, dirty_count)
                       + b"".join(current))
    return packets


def build_layout(layout, codec, frame_id, width=466, height=466, pixel=0x07E0):
    """Datagrams for one frame in one layout. Same visible pixels every time;
    only the record framing differs, which is the whole point."""
    if layout == "production":
        # The shipped sender's own builder, so "production" cannot drift away
        # from what the app really emits.
        packets, _ = espdisp.motion_frame_packets(
            frame_id, 0xC0FFEE, half=(codec == "half-bc1"))
        return packets

    runs, tiles = visible_runs(width, height)
    per_tile = TILE_BYTES[codec]
    codec_id = CODECS[codec]
    records = []
    if layout == "single":
        for start, length in runs:
            for i in range(length):
                records.append((start + i, espdisp.tile_record(
                    start + i, 1, codec_id, bytes(per_tile))))
    elif layout == "fill":
        # Fewest records that still FILL each datagram. Built datagram by
        # datagram rather than record by record: capping run length first and
        # letting the packer sort it out is what a naive reading gives, and it
        # anti-correlates with packing density - maximal runs make records so
        # large only one fits per datagram, which costs MORE datagrams, not
        # fewer. So grow a run only while it still fits the space left in the
        # current datagram, then start a new one.
        packets = []
        current = []
        space = RECORD_SPACE
        first = None
        for start, length in runs:
            offset = 0
            while offset < length:
                room = min(MAX_RUN, length - offset, max(0, (space - 4) // per_tile))
                if room <= 0:
                    packets.append(espdisp.tile_header(frame_id, first, tiles)
                                   + b"".join(current))
                    current, space, first = [], RECORD_SPACE, None
                    continue
                if first is None:
                    first = start + offset
                rec = espdisp.tile_record(start + offset, room, codec_id,
                                          bytes(per_tile * room))
                current.append(rec)
                space -= len(rec)
                offset += room
        if current:
            packets.append(espdisp.tile_header(frame_id, first, tiles)
                           + b"".join(current))
        return packets
    else:
        raise SystemExit("unknown layout %r" % layout)
    return pack(records, tiles, frame_id)


def layout_cost(layout, codec):
    """records, datagrams and bytes for one frame, computed from the builders
    rather than quoted from a table, so a builder change shows up here."""
    packets = build_layout(layout, codec, 1)
    records = 0
    for p in packets:
        body = p[6:]
        offset = 0
        while offset + 4 <= len(body):
            length = int.from_bytes(body[offset + 2:offset + 4], "little")
            records += 1
            offset += 4 + (length & 0x3FFF)
    return records, len(packets), sum(len(p) for p in packets)


class Serial:
    """One long-lived raw tty session: a second open of the same /dev/cu.*
    conflicts, so reads and any command share this fd."""

    def __init__(self, path):
        self.fd = espdisp.open_serial(path)
        self.buf = b""

    def drain(self, seconds, sink):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.2)
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                continue
            self.buf += chunk
            while b"\n" in self.buf:
                raw, self.buf = self.buf.split(b"\n", 1)
                sink.append(raw.strip().decode(errors="replace"))


def link_is_healthy(host, max_rtt_ms=15.0):
    """The gate from section 17.17. Returns (ok, description)."""
    out = subprocess.run(["ping", "-c", "20", "-s", "1450", host],
                         capture_output=True, text=True).stdout
    loss = PING_LOSS_RE.search(out)
    rtt = PING_RTT_RE.search(out)
    if not loss:
        return False, "ping produced no statistics line"
    lost = float(loss.group(1))
    if lost > 0.0:
        return False, "%.0f%% loss on 1450-byte pings" % lost
    if not rtt:
        return False, "no round-trip statistics"
    avg = float(rtt.group(1))
    if avg > max_rtt_ms:
        return False, "average RTT %.1f ms exceeds %.1f ms" % (avg, max_rtt_ms)
    return True, "lossless, average RTT %.1f ms" % avg


def send_frames(sock, host, frames, target_fps, seconds):
    """Offer prebuilt frames at a fixed rate. Frames are prebuilt because
    encoding tiles in Python is slower than the wire, so building inside the
    loop would measure Python instead of the panel."""
    interval = 1.0 / target_fps
    deadline = time.monotonic() + seconds
    next_send = time.monotonic()
    offered = 0
    i = 0
    while time.monotonic() < deadline:
        for packet in frames[i % len(frames)]:
            sock.sendto(packet, (host, UDP_PORT))
            offered += 1
        i += 1
        next_send += interval
        sleep = next_send - time.monotonic()
        if sleep > 0:
            time.sleep(sleep)
        else:
            next_send = time.monotonic()
    return offered


def reduce_stats(lines, seconds, offered, per_frame):
    """Panel-reported rates from its own 5-second counters, which are the
    instrument - the sender only knows what it offered."""
    frames = [m for m in (FRAMES_RE.search(l) for l in lines) if m]
    stats = {"offered_dps": offered / seconds if seconds else 0.0}
    if len(frames) >= 2:
        first, last = frames[0], frames[-1]
        secs = 5.0 * (len(frames) - 1)
        for key, idx in (("complete_fps", 1), ("dropped_ps", 2),
                         ("partial_ps", 3), ("accepted_dps", 4)):
            stats[key] = (int(last.group(idx)) - int(first.group(idx))) / secs
        if per_frame:
            # The normalised figure the falsifier is stated in: accepted
            # datagrams per second divided by datagrams per frame.
            stats["frame_equivalents"] = stats["accepted_dps"] / per_frame
    tds = [m for m in (TILEDRAW_RE.search(l) for l in lines) if m]
    passes = sum(int(m.group(1)) for m in tds)
    calls = sum(int(m.group(2)) for m in tds)
    if calls > 0:
        stats["gq_per_call_us"] = (
            sum((int(m.group(6)) + int(m.group(7))) * int(m.group(1))
                for m in tds) / calls)
    return stats


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--serial", help="panel's /dev/cu.* tty")
    parser.add_argument("--host", help="panel IP")
    parser.add_argument("--codec", choices=sorted(CODECS), default="bc1")
    parser.add_argument("--layouts", default=",".join(LAYOUTS))
    parser.add_argument("--target-fps", type=int, default=8)
    parser.add_argument("--seconds", type=int, default=25)
    parser.add_argument("--rounds", type=int, default=4)
    parser.add_argument("--distinct-frames", type=int, default=4)
    parser.add_argument("--log", default="/tmp/measure_record_layouts.log")
    parser.add_argument("--dry-run", action="store_true",
                        help="print each layout's cost and exit; needs no board")
    parser.add_argument("--skip-link-check", action="store_true",
                        help="run without the ping gate; results are then not "
                             "evidence of anything about record cost")
    args = parser.parse_args()

    layouts = [l.strip() for l in args.layouts.split(",") if l.strip()]
    for layout in layouts:
        if layout not in LAYOUTS:
            raise SystemExit("unknown layout %r (choose from %s)"
                             % (layout, ", ".join(LAYOUTS)))

    print("layout costs per frame, computed from the builders:")
    print("  %-11s %-9s %9s %10s %11s %8s"
          % ("layout", "codec", "records", "datagrams", "bytes", "rec/dg"))
    costs = {}
    for codec in sorted(CODECS) if args.dry_run else [args.codec]:
        for layout in layouts:
            records, datagrams, byts = layout_cost(layout, codec)
            costs[(layout, codec)] = (records, datagrams, byts)
            print("  %-11s %-9s %9d %10d %11d %8.1f"
                  % (layout, codec, records, datagrams, byts,
                     records / datagrams if datagrams else 0.0))

    if args.dry_run:
        print("\nThe record-cost falsifier is full BC1 single vs fill: near-equal")
        print("datagram counts with an order of magnitude difference in records.")
        print("If normalised frame-equivalents do not move in the same direction")
        print("in every paired round, or the paired median change is under 5%,")
        print("record count is not the bottleneck and no wire change is justified.")
        return 0

    if not args.serial or not args.host:
        raise SystemExit("--serial and --host are required unless --dry-run")

    if args.skip_link_check:
        print("\nWARNING: link gate skipped; this run cannot support a claim "
              "about record cost.")
    else:
        ok, why = link_is_healthy(args.host)
        print("\nlink gate: %s (%s)" % ("PASS" if ok else "REFUSED", why))
        if not ok:
            print("Refusing to measure: every arm collapses identically on a "
                  "link this poor and the run would measure the radio.")
            return 2

    print("prebuilding %d frames per layout..." % args.distinct_frames,
          flush=True)
    frames = {}
    for layout in layouts:
        frames[layout] = [build_layout(layout, args.codec, i + 1)
                          for i in range(args.distinct_frames)]

    ser = Serial(args.serial)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    results = {layout: [] for layout in layouts}

    with open(args.log, "w") as log:
        log.write("codec=%s target_fps=%d seconds=%d rounds=%d\n"
                  % (args.codec, args.target_fps, args.seconds, args.rounds))
        for rnd in range(1, args.rounds + 1):
            for layout in layouts:
                per_frame = costs[(layout, args.codec)][1]
                print("== round %d / %s ==" % (rnd, layout), flush=True)
                lines = []
                ser.drain(1.0, lines)
                lines.clear()
                offered = send_frames(sock, args.host, frames[layout],
                                      args.target_fps, args.seconds)
                ser.drain(7.0, lines)  # catch the final 5 s report
                stats = reduce_stats(lines, args.seconds, offered, per_frame)
                results[layout].append(stats)
                log.write("\n===== round %d %s =====\n" % (rnd, layout))
                log.write("\n".join(lines) + "\n")
                log.write("reduced: %r\n" % (stats,))
                print("   " + "  ".join(
                    "%s=%.1f" % (k, v) for k, v in sorted(stats.items())),
                    flush=True)

    print("\nper-layout medians over %d rounds:" % args.rounds)
    for layout in layouts:
        got = [r.get("frame_equivalents") for r in results[layout]
               if r.get("frame_equivalents") is not None]
        if got:
            print("  %-11s frame_equivalents median=%.2f  from %r"
                  % (layout, statistics.median(got),
                     [round(g, 2) for g in got]))
        else:
            print("  %-11s no panel counters captured - check the serial port"
                  % layout)
    print("\nFull output: %s" % args.log)
    return 0


if __name__ == "__main__":
    sys.exit(main())
