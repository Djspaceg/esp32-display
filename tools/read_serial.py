#!/usr/bin/env python3
"""Read serial output from the ESP32 for a fixed duration and print it."""
import sys
import time

import serial

port = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbmodem1101"
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0
stop_marker = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] != "-" else None
no_reset = "noreset" in sys.argv[4:]

s = serial.Serial(port, 115200, timeout=1)
if not no_reset:
    # Native USB-Serial/JTAG: pulse RTS (with DTR low) to hard-reset the
    # chip so we capture output from boot.
    s.setDTR(False)
    s.setRTS(True)
    time.sleep(0.1)
    s.setRTS(False)
end = time.time() + duration
buf = b""
while time.time() < end:
    chunk = s.read(512)
    if chunk:
        buf += chunk
        if stop_marker and stop_marker in buf:
            time.sleep(0.3)
            buf += s.read(4096)
            break
s.close()
print(buf.decode(errors="replace"))
