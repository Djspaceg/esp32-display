#!/usr/bin/env python3
"""Send one command line to the ESP32 over serial and print the CFG* reply."""
import sys
import time

import serial

port = sys.argv[1]
command = sys.argv[2]
timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 6.0

s = serial.Serial(port, 115200, timeout=0.5)
s.reset_input_buffer()
s.write((command + "\n").encode())
s.flush()

deadline = time.time() + timeout
buf = b""
while time.time() < deadline:
    buf += s.read(512)
    for line in buf.split(b"\n"):
        text = line.strip().decode(errors="replace")
        if text.startswith(("CFGOK", "CFGERR", "CFGINFO")):
            print(text)
            s.close()
            sys.exit(0)
s.close()
print("TIMEOUT: no CFG reply")
sys.exit(1)
