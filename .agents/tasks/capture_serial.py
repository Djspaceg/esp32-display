#!/usr/bin/env python3
import fcntl
import os
import select
import struct
import sys
import termios
import time

port = sys.argv[1]
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
attrs[0] = 0
attrs[1] = 0
attrs[2] = (attrs[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)) | termios.CS8 | termios.CLOCAL | termios.CREAD
attrs[3] = 0
attrs[4] = termios.B115200
attrs[5] = termios.B115200
attrs[6][termios.VMIN] = 0
attrs[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, attrs)
termios.tcflush(fd, termios.TCIFLUSH)
mask = struct.pack("I", termios.TIOCM_RTS)
if "noreset" not in sys.argv[3:]:
    fcntl.ioctl(fd, termios.TIOCMBIS, mask)
    time.sleep(0.1)
    fcntl.ioctl(fd, termios.TIOCMBIC, mask)
end = time.monotonic() + duration
output = bytearray()
while time.monotonic() < end:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            output.extend(os.read(fd, 4096))
        except BlockingIOError:
            pass
os.close(fd)
sys.stdout.write(output.decode(errors="replace"))
