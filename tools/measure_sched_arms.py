#!/usr/bin/env python3
"""Interleaved scheduling-arm measurement for the S3 tile draw path.

Answers docs/tile-stream-plan.md section 17.6 item 3: does re-prioritising
udpReceiveTask (boot: 9) against loopTask (boot: 1) relieve the measured
draw starvation? Arms swap priorities live through the CFGTUNE rxprio /
loopprio knobs over USB serial while `espdisp.py tile-motion` offers a fixed
load over WiFi, and the panel's own 5 s serial stats are parsed per arm.

Arms are interleaved (A B C A B C ...) per the repo's measurement discipline:
run-to-run spread is ~4 fps peak-to-peak (section 17.11), so blocked sampling
lies.

PRECONDITION (section 17.17, learned the hard way): the panel's link must be
able to carry the offered rate, or every arm collapses identically and the
run measures the radio. Check first that `ping -s 1450` to the panel is
lossless and that a probe run accepts most of what it offers; the per-call
inflation the arms exist to relieve only appears above ~430 accepted
datagrams/s, which needs roughly RSSI -60s. Quiesce every sender (pause the
app's panels or quit it - it un-pauses on its own supervision) before
starting.

Usage:
  python3 tools/measure_sched_arms.py --port /dev/cu.usbmodemXXXX \
      --host 192.168.1.83 --target-fps 25 --half --seconds 25 --rounds 2
"""
import argparse
import os
import re
import select
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import espdisp  # noqa: E402  (open_serial: termios-only, no pyserial)

# (label, rxprio, loopprio)
ARMS = [
    ("A rx9 loop1 baseline", 9, 1),
    ("B rx9 loop9 equal", 9, 9),
    ("C rx9 loop10 draw-above", 9, 10),
]

FRAMES_RE = re.compile(
    r"frames=(\d+) dropped=(\d+) partial=(\d+) packets=(\d+)")
TILEDRAW_RE = re.compile(
    r"tiledraw: (\d+) passes, (\d+) calls, (\d+) gateblocked \| per pass: "
    r"(\d+) us total = spin (\d+) \+ gather (\d+) \+ queue (\d+) \+ bar (\d+)")


class Serial:
    """One long-lived raw tty session: CFGTUNE writes and stats reads share
    the fd, because two opens of the same /dev/cu.* device conflict."""

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

    def command(self, line, timeout=4.0):
        os.write(self.fd, (line + "\n").encode())
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            fresh = []
            self.drain(0.3, fresh)
            for text in fresh:
                if text.startswith(("CFGOK", "CFGERR")):
                    return text
        raise RuntimeError("no reply to %r" % line)


def run_sample(ser, args, label, rxprio, loopprio, log):
    print("== %s ==" % label, flush=True)
    print("  %s" % ser.command("CFGTUNE rxprio %d" % rxprio), flush=True)
    print("  %s" % ser.command("CFGTUNE loopprio %d" % loopprio), flush=True)
    lines = []
    cmd = [sys.executable, os.path.join(HERE, "espdisp.py"), "tile-motion",
           args.host, "--target-fps", str(args.target_fps),
           "--seconds", str(args.seconds)]
    if args.half:
        cmd.append("--half")
    proc = subprocess.Popen(cmd, cwd=REPO, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    while proc.poll() is None:
        ser.drain(0.5, lines)
    tool_out = proc.stdout.read() if proc.stdout else ""
    ser.drain(7.0, lines)  # catch the final 5 s report

    log.write("\n===== %s =====\n--- serial ---\n" % label)
    log.write("\n".join(lines) + "\n--- tile-motion ---\n" + tool_out + "\n")

    frames = [m for m in (FRAMES_RE.search(l) for l in lines) if m]
    stats = {}
    if len(frames) >= 2:
        first, last = frames[0], frames[-1]
        secs = 5.0 * (len(frames) - 1)
        for key, idx in (("complete_fps", 1), ("dropped_ps", 2),
                         ("partial_ps", 3), ("packets_ps", 4)):
            stats[key] = (int(last.group(idx)) - int(first.group(idx))) / secs
    tds = [m for m in (TILEDRAW_RE.search(l) for l in lines) if m]
    passes = sum(int(m.group(1)) for m in tds)
    calls = sum(int(m.group(2)) for m in tds)
    if passes > 0:
        def weighted(i):
            return sum(int(m.group(i)) * int(m.group(1)) for m in tds) / passes
        stats["gateblocked"] = sum(int(m.group(3)) for m in tds)
        stats["pass_us"] = weighted(4)
        stats["spin_us"] = weighted(5)
        stats["gather_us"] = weighted(6)
        stats["queue_us"] = weighted(7)
        stats["calls_per_pass"] = calls / passes
        if calls > 0:
            stats["gq_per_call_us"] = (
                sum((int(m.group(6)) + int(m.group(7))) * int(m.group(1))
                    for m in tds) / calls)
    tail = [l for l in tool_out.splitlines() if l.strip()][-3:]
    return stats, tail


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", required=True, help="panel's /dev/cu.* tty")
    parser.add_argument("--host", required=True, help="panel IP for tile-motion")
    parser.add_argument("--target-fps", type=int, default=25)
    parser.add_argument("--seconds", type=int, default=25)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--half", action="store_true",
                        help="half-res BC1 (~17 datagrams/frame vs 66)")
    parser.add_argument("--log", default="/tmp/measure_sched_arms.log")
    args = parser.parse_args()

    ser = Serial(args.port)
    results = []
    with open(args.log, "w") as log:
        junk = []
        ser.drain(3.0, junk)  # settle: drop boot noise and stale reports
        log.write("\n".join(junk) + "\n")
        for rnd in range(args.rounds):
            for label, rxprio, loopprio in ARMS:
                tag = "%s round%d" % (label, rnd + 1)
                stats, tail = run_sample(ser, args, tag, rxprio, loopprio, log)
                results.append((tag, stats, tail))
                time.sleep(4)
        # Leave the panel at boot defaults; the knobs are non-persisted but a
        # measurement session should not depend on a later reboot.
        ser.command("CFGTUNE rxprio 9")
        ser.command("CFGTUNE loopprio 1")

    print("\n===== SUMMARY (offered: %d fps%s, raw log: %s) ====="
          % (args.target_fps, " half-res" if args.half else " full-res",
             args.log))
    for tag, stats, tail in results:
        print("\n%s" % tag)
        for key in ("complete_fps", "partial_ps", "dropped_ps", "packets_ps",
                    "calls_per_pass", "gq_per_call_us", "pass_us", "spin_us",
                    "gather_us", "queue_us", "gateblocked"):
            if key in stats:
                print("  %-16s %.1f" % (key, stats[key]))
        for line in tail:
            print("  tool| %s" % line)


if __name__ == "__main__":
    main()
