#!/usr/bin/env python3
"""Send CFGBENCH over serial and print everything the board says for a
while. Reuses tools/espdisp.py's termios-based open_serial so no pyserial is
needed. Usage: run_bench.py <port> [seconds]"""
import importlib.util
import os
import select
import sys
import time

spec = importlib.util.spec_from_file_location(
    "espdisp", "/Users/stepblk/Source/esp32-display/tools/espdisp.py")
espdisp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(espdisp)

port = sys.argv[1]
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0

fd = espdisp.open_serial(port)
try:
    time.sleep(0.3)
    # Drain stale bytes.
    while select.select([fd], [], [], 0.05)[0]:
        os.read(fd, 4096)
    os.write(fd, b"CFGBENCH\n")
    deadline = time.time() + seconds
    buf = b""
    while time.time() < deadline:
        if select.select([fd], [], [], 0.2)[0]:
            data = os.read(fd, 4096)
            if not data:
                continue
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("utf-8", "replace").rstrip()
                print(text, flush=True)
                if text.startswith("CFGOK bench complete"):
                    sys.exit(0)
                if text.startswith("CFGERR"):
                    sys.exit(1)
finally:
    os.close(fd)
