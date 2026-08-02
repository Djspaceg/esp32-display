#!/usr/bin/env python3
"""Sweep sender pacing parameters and measure displayed fps from the ESP32's
serial stats lines (frames=N ...). Kills any running sender first."""
import re
import subprocess
import sys
import time

import serial

PORT = "/dev/cu.usbmodem1101"
SENDER = "mac/ESPDisplaySender/.build/debug/ESPDisplaySender"
SETTLE_S = 3
MEASURE_S = 12

combos = [
    # (fps, spacing_us)
    (40, 100),
    (40, 150),
    (40, 200),
    (40, 250),
    (40, 300),
]

def frames_counter(line):
    m = re.search(rb"frames=(\d+) dropped=(\d+) skipped=(\d+) packets=(\d+)", line)
    return tuple(int(x) for x in m.groups()) if m else None

subprocess.run(["pkill", "-f", "ESPDisplaySender"], check=False)
time.sleep(1)

s = serial.Serial(PORT, 115200, timeout=1)
results = []
for fps, spacing in combos:
    proc = subprocess.Popen(
        [SENDER, "--mode", "test", "--fps", str(fps), "--spacing-us", str(spacing)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(SETTLE_S)
    s.reset_input_buffer()

    samples = []
    t_end = time.time() + MEASURE_S
    while time.time() < t_end:
        line = s.readline()
        c = frames_counter(line)
        if c:
            samples.append((time.time(), c))
    proc.terminate()
    proc.wait()

    if len(samples) >= 2:
        (t0, c0), (t1, c1) = samples[0], samples[-1]
        dt = t1 - t0
        shown = (c1[0] - c0[0]) / dt
        dropped = (c1[1] - c0[1]) / dt
        pkts = (c1[3] - c0[3]) / dt
        line = (f"fps={fps} spacing={spacing}us -> shown={shown:.1f}/s "
                f"dropped={dropped:.1f}/s packets={pkts:.0f}/s")
    else:
        line = f"fps={fps} spacing={spacing}us -> no data"
    print(line, flush=True)
    results.append(line)

s.close()
print("--- summary ---")
for r in results:
    print(r)
