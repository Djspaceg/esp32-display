#!/usr/bin/env python3
"""Scratch serial capture that survives the reboot a Doom launch causes.

Timestamps every line relative to capture start, and reopens the port when the
device resets so the boot banner after a Doom request lands in the same log.
Not part of the shipped tool surface; used only to observe BOOT button gestures.
"""
import argparse
import os
import sys
import time

import serial


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=120.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--silence", type=float, default=8.0,
                    help="reopen the port after this many seconds of silence")
    args = ap.parse_args()

    start = time.time()
    deadline = start + args.seconds
    ser = None
    with open(args.out, "w", buffering=1) as log:
        def emit(text):
            line = "[%7.3f] %s" % (time.time() - start, text)
            log.write(line + "\n")
            print(line, flush=True)

        emit("capture start port=%s baud=%d window=%.0fs"
             % (args.port, args.baud, args.seconds))
        pending = b""
        last_byte_at = time.time()
        open_failure_logged = False
        while time.time() < deadline:
            if ser is None:
                if not os.path.exists(args.port):
                    time.sleep(0.2)
                    continue
                try:
                    ser = serial.Serial(args.port, args.baud, timeout=0.2)
                    emit("--- port opened ---")
                    open_failure_logged = False
                    last_byte_at = time.time()
                except Exception as exc:  # noqa: BLE001
                    # Busy is the normal case when the Mac app or another tool
                    # holds the port: wait and retry rather than giving up, and
                    # log it once so a long wait is not a silent one.
                    if not open_failure_logged:
                        emit("--- open failed, retrying: %s ---" % exc)
                        open_failure_logged = True
                    time.sleep(0.5)
                    continue
            try:
                chunk = ser.read(4096)
            except Exception as exc:  # noqa: BLE001
                emit("--- port dropped: %s ---" % exc)
                try:
                    ser.close()
                except Exception:  # noqa: BLE001
                    pass
                ser = None
                pending = b""
                continue
            if not chunk:
                # A native-USB-CDC reset re-enumerates the device, which leaves
                # this file descriptor open but permanently deaf: reads return
                # empty forever instead of raising. The firmware emits telemetry
                # every ~5s, so prolonged silence means reopen, not idle.
                if time.time() - last_byte_at >= args.silence:
                    emit("--- %.0fs silent, reopening ---" % args.silence)
                    try:
                        ser.close()
                    except Exception:  # noqa: BLE001
                        pass
                    ser = None
                    pending = b""
                    last_byte_at = time.time()
                continue
            last_byte_at = time.time()
            pending += chunk
            while b"\n" in pending:
                raw, pending = pending.split(b"\n", 1)
                emit(raw.decode("utf-8", "replace").rstrip("\r"))
        if pending:
            emit(pending.decode("utf-8", "replace").rstrip("\r"))
        emit("capture end")
    if ser is not None:
        ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
