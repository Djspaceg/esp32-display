#!/usr/bin/env python3
"""Cycle the board LED through named colors via CFGLED, for visual
channel-order verification. Keeps the port open across commands."""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbmodem1101"
colors = [("GREEN", 0, 255, 0), ("RED", 255, 0, 0),
          ("BLUE", 0, 0, 255), ("YELLOW", 255, 255, 0)]
cycles = 3
hold_s = 2.0

s = serial.Serial(port, 115200, timeout=0.2)
s.reset_input_buffer()
for cycle in range(cycles):
    for name, r, g, b in colors:
        s.write(f"CFGLED {r} {g} {b}\n".encode())
        s.flush()
        print(f"cycle {cycle + 1}: {name}", flush=True)
        time.sleep(hold_s)
# Let the override lapse back to the signal indicator quickly.
s.write(b"CFGLED 0 0 0\n")
s.close()
print("done - LED returns to signal colors within ~10s")
