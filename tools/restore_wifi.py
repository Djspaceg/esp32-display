#!/usr/bin/env python3
"""Restore device WiFi credentials from firmware/display_stream/wifi_config.h
over serial, without printing the secrets."""
import base64
import re
import sys
import time

import serial

port = sys.argv[1]
cfg = open("firmware/display_stream/wifi_config.h").read()
ssid = re.search(r'#define WIFI_SSID "(.*)"', cfg).group(1)
password = re.search(r'#define WIFI_PASSWORD "(.*)"', cfg).group(1)

cmd = "CFGWIFI %s %s\n" % (
    base64.b64encode(ssid.encode()).decode(),
    base64.b64encode(password.encode()).decode(),
)

s = serial.Serial(port, 115200, timeout=0.5)
s.reset_input_buffer()
s.write(cmd.encode())
s.flush()

deadline = time.time() + 8
buf = b""
while time.time() < deadline:
    buf += s.read(512)
    for line in buf.split(b"\n"):
        text = line.strip().decode(errors="replace")
        if text.startswith(("CFGOK", "CFGERR")):
            print(text)
            s.close()
            sys.exit(0 if text.startswith("CFGOK") else 1)
s.close()
print("TIMEOUT")
sys.exit(1)
