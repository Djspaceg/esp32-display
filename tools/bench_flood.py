#!/usr/bin/env python3
"""Flood the panel with UDP datagrams to measure its receive ceiling.

Each datagram is a band-protocol header with a reserved bit set, so the
firmware counts it in statBadLen (the badlen= field of the 5-second serial
stats line) after traversing the full receive path - identical recv cost to
a real packet, uniform counting regardless of size or content.

Watch the serial stats concurrently (tools/bench_serial.py, or any serial
monitor) and compute badlen deltas per 5s line to get the RECEIVE rate;
this script prints only the offered SEND rate.

An unpaced flood (--rate 0) oversaturates 2.4GHz WiFi by orders of
magnitude and causes AP-level congestive loss that muddies the measurement;
prefer paced runs bracketing the expected ceiling (e.g. 1500, 2500, 5000).

Usage: bench_flood.py <ip> <size-bytes> <seconds> [--rate N]
"""
import argparse
import socket
import time

parser = argparse.ArgumentParser()
parser.add_argument("ip")
parser.add_argument("size", type=int)
parser.add_argument("seconds", type=float)
parser.add_argument("--rate", type=int, default=0,
                    help="datagrams/second; 0 = unpaced (not recommended)")
args = parser.parse_args()

if args.size < 6:
    parser.error("size must be >= 6")

# frame_id=1, band_index=0x0400 (reserved bit 10 set -> statBadLen++),
# dirty_count=1, then padding to size.
payload = bytes([0x01, 0x00, 0x00, 0x04, 0x01, 0x00]) + b"\xa5" * (args.size - 6)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)

sent = 0
start = time.time()
deadline = start + args.seconds
if args.rate <= 0:
    while time.time() < deadline:
        for _ in range(100):
            try:
                sock.sendto(payload, (args.ip, 5568))
                sent += 1
            except OSError:
                time.sleep(0.001)
else:
    # Pace in 10ms slices so short-term burstiness stays small.
    per_slice = max(1, args.rate // 100)
    next_slice = start
    while time.time() < deadline:
        for _ in range(per_slice):
            try:
                sock.sendto(payload, (args.ip, 5568))
                sent += 1
            except OSError:
                pass
        next_slice += 0.01
        delay = next_slice - time.time()
        if delay > 0:
            time.sleep(delay)

elapsed = time.time() - start
print(f"sent {sent} datagrams of {args.size}B in {elapsed:.1f}s "
      f"-> {sent / elapsed:.0f}/s offered")
