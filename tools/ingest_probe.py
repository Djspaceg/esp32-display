#!/usr/bin/env python3
"""Measure how many band packets per second a panel actually accepts.

Floods the panel with valid, duplicate band-0 packets at stepped offered
rates and reads the accepted rate back off the panel's own 5s serial stats
line (packets= is cumulative), so the instrument is the device's count, not
the sender's hope. Run with the streaming app on or off; a baseline step
first measures whatever else is talking to the panel so it can be
subtracted.

The number this exists to replace: FrameSender's pacing was tuned around
"the ESP32's receive path drops heavily above ~3000 packets/s", measured on
the single-core C6. The S3 is a different chip and that constant was never
re-measured. This measures it.

Side effects on the panel, both temporary: the duplicate band traffic
competes with the app's frames for reassembly, so the picture freezes or
tears during the sweep and heals on the app's next keyframe; and the probe
briefly becomes the heartbeat reply endpoint whenever its packet was the
most recent to arrive.

Usage: ingest_probe.py <host> <serial-port> [rates-pps,...] [step-seconds]
  e.g. ingest_probe.py 192.168.1.180 /dev/cu.usbmodem101 1000,2000,4000,8000 8
"""
import os
import re
import select
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import espdisp  # open_serial: stdlib termios, no pyserial

UDP_PORT = 5568
# The S3 panel's geometry: 466x466 portrait, one 932-byte row per band,
# dirty_count 466 so the flooded frame never completes and never draws.
BAND_PAYLOAD = 932
DIRTY_COUNT = 466
STATS_RE = re.compile(r"frames=(\d+) dropped=(\d+) skipped=(\d+) packets=(\d+)")


def build_packet() -> bytes:
    # [frame_id u16][band_index u16][dirty_count u16, bit15=landscape] + payload.
    # A fixed frame id makes every packet after the first a Duplicate, which
    # the firmware counts in packets= without re-copying or drawing.
    header = struct.pack("<HHH", 7, 0, DIRTY_COUNT)
    return header + bytes([0x21, 0x04]) * (BAND_PAYLOAD // 2)  # dark gray row


class SerialStats(threading.Thread):
    """Collect (monotonic time, cumulative counters) from the 5s stats lines."""

    def __init__(self, port: str):
        super().__init__(daemon=True)
        self.fd = espdisp.open_serial(port)
        self.samples = []  # (t, frames, dropped, packets)
        self.stop = threading.Event()

    def run(self):
        buf = b""
        while not self.stop.is_set():
            ready, _, _ = select.select([self.fd], [], [], 0.2)
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 4096)
            except (BlockingIOError, OSError):
                continue
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                m = STATS_RE.search(raw.decode(errors="replace"))
                if m:
                    self.samples.append(
                        (time.monotonic(), int(m.group(1)), int(m.group(2)),
                         int(m.group(4))))

    def close(self):
        self.stop.set()
        self.join(timeout=1)
        os.close(self.fd)


def rate_between(samples, t0, t1):
    """Accepted packets/s between the stats lines nearest t0 and t1."""
    inside = [s for s in samples if t0 <= s[0] <= t1]
    if len(inside) < 2:
        return None
    first, last = inside[0], inside[-1]
    dt = last[0] - first[0]
    if dt <= 0:
        return None
    return (
        (last[3] - first[3]) / dt,   # packets/s
        (last[1] - first[1]) / dt,   # frames shown /s
        (last[2] - first[2]) / dt,   # frames dropped /s
    )


def flood(sock, dest, packet, rate_pps, seconds):
    """Offer rate_pps for `seconds`. Batched: python sleep() cannot pace
    individual sub-100us gaps, so send bursts and sleep the burst's worth
    of time. Returns what was actually offered."""
    batch = max(1, rate_pps // 200)  # ~200 wakeups/s
    interval = batch / rate_pps
    sent = 0
    start = time.monotonic()
    next_at = start
    while True:
        now = time.monotonic()
        if now - start >= seconds:
            break
        for _ in range(batch):
            try:
                sock.sendto(packet, dest)
                sent += 1
            except OSError:
                pass  # ENOBUFS under extreme rates: still an offered packet
        next_at += interval
        pause = next_at - time.monotonic()
        if pause > 0:
            time.sleep(pause)
    return sent / (time.monotonic() - start)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    host = sys.argv[1]
    serial_port = sys.argv[2]
    rates = [int(r) for r in (sys.argv[3] if len(sys.argv) > 3
                              else "1000,2000,4000,8000,12000").split(",")]
    step_s = float(sys.argv[4]) if len(sys.argv) > 4 else 8.0

    packet = build_packet()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    stats = SerialStats(serial_port)
    stats.start()

    print("packet: %d bytes (%d payload + 6 header)" % (len(packet), BAND_PAYLOAD))
    print("baseline (no flood) for %.0fs..." % (step_s + 6))
    time.sleep(step_s + 6)  # at least two 5s stats lines
    t = time.monotonic()
    base = rate_between(stats.samples, t - step_s - 6, t)
    base_pps = base[0] if base else 0.0
    print("  baseline accepted: %.0f pkt/s (the app's own traffic)" % base_pps)

    results = []
    for rate in rates:
        print("offering %d pkt/s for %.0fs..." % (rate, step_s), flush=True)
        t0 = time.monotonic()
        offered = flood(sock, (host, UDP_PORT), packet, rate, step_s)
        time.sleep(6)  # let two stats lines cover the window
        got = rate_between(stats.samples, t0, t0 + step_s + 6)
        if got is None:
            print("  no stats lines landed in the window; skipping")
            continue
        accepted = max(0.0, got[0] - base_pps)
        mbps = accepted * len(packet) * 8 / 1e6
        results.append((rate, offered, accepted, mbps, got[1], got[2]))
        print("  offered %.0f -> accepted %.0f pkt/s (%.1f Mbps), "
              "shown %.1f/s dropped %.1f/s"
              % (offered, accepted, mbps, got[1], got[2]))

    stats.close()
    print("\n%8s %10s %10s %8s" % ("offered", "achieved", "accepted", "Mbps"))
    for rate, offered, accepted, mbps, _, _ in results:
        print("%8d %10.0f %10.0f %8.1f" % (rate, offered, accepted, mbps))
    return 0


if __name__ == "__main__":
    sys.exit(main())
