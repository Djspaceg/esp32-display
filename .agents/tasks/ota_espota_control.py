#!/usr/bin/env python3
"""Temporary, untracked OTA diagnostic: push the released s3 firmware to a
known panel IP through the esp32 core's own espota.py.

This is a throwaway helper under .agents/ (untracked). It does not modify any
tracked file. It reuses espdisp's verified bundle reader, password policy, and
espota command recipe rather than reimplementing them, so its behavior matches
the real `espdisp.py ota` path. The OTA password is read with no echo, validated
locally, passed to espota via argv (espota's only accepted form), and never
printed: the command line is not echoed and the variable is cleared in finally.
"""

import getpass
import os
import subprocess
import sys
import tempfile

# --- locate the repo's tools/ and import espdisp -------------------------
# This script lives at <repo>/.agents/tasks/ota_espota_control.py, so the repo
# root is two directories up and tools/ sits beside .agents/.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_TOOLS_DIR = os.path.join(_REPO_ROOT, "tools")
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)

import espdisp  # noqa: E402  (import after sys.path is set)

BUNDLE_PATH = os.path.join(
    _REPO_ROOT, "firmware-releases", "s3", "espdisp-s3-1.5.0.espdispfw"
)
TARGET = "s3"
HOST = "192.168.1.83"
PORT = espdisp.OTA_PORT  # 3232, ArduinoOTA's default and what the firmware binds
INVITATION_TIMEOUT = 10  # espota -t: seconds to wait on the OTA invitation

# espota's -I/--host_ip: force the address espota binds its TCP listener to and
# advertises to the panel as the UDP source/callback. Without it espota picks
# the OS default route, which here is the routed USB Ethernet (192.168.1.139);
# the panel then tries to call back over that path and the invitation stalls.
# Pin it to the Mac's Wi-Fi address so the OTA callback lands on the same LAN as
# the panel.
CALLBACK_IP = "192.168.1.148"


def main() -> int:
    # Full verification: hashes, contiguity, target claims, manifest shape.
    # read_bundle raises espdisp.Fail with one actionable line on any problem.
    manifest, payloads, _flash_payloads = espdisp.read_bundle(BUNDLE_PATH)

    # Require exactly the s3 application payload and nothing else. A released
    # single-family s3 bundle carries one target keyed "s3"; refuse anything
    # that does not match so we never push a payload meant for another panel.
    targets = sorted(payloads)
    if targets != [TARGET]:
        raise espdisp.Fail(
            "expected exactly the %s application payload, but the bundle carries: %s"
            % (TARGET, ", ".join(targets) or "none")
        )
    image = payloads[TARGET]

    # Non-secret facts only: version, payload size, and the payload's own hash.
    print("bundle:  %s" % BUNDLE_PATH)
    print("version: %s" % manifest.get("firmware_version"))
    print("payload: %s (%d bytes)" % (TARGET, len(image)))
    print("sha256:  %s" % espdisp.sha256_hex(image))

    # The esp32 core's own OTA pusher; same program `espdisp.py ota` runs.
    espota = espdisp.espota_path()

    # No echo, and validate with the firmware's own byte-length policy before we
    # spend time opening a socket. check_password_policy raises espdisp.Fail on a
    # password the panel would reject.
    password = getpass.getpass("OTA password for the panel: ")
    tmp_image = None
    try:
        espdisp.check_password_policy(password)

        # espota takes a file path, so materialize the verified payload to a
        # temp file. delete=False lets us close it before espota opens it and
        # remove it deterministically in finally.
        with tempfile.NamedTemporaryFile(
            prefix="espdisp-%s-" % TARGET, suffix=".bin", delete=False
        ) as fh:
            fh.write(image)
            tmp_image = fh.name

        # The official recipe (sys.executable espota.py -r -i HOST -p PORT
        # -a PASSWORD -f IMAGE -t TIMEOUT). -r gives espota's progress bar.
        cmd = espdisp.espota_command(
            espota, HOST, PORT, password, tmp_image, INVITATION_TIMEOUT
        )

        # Force espota's source/callback and IPv4 TCP listener to the Wi-Fi
        # address. -I is a non-secret flag, so insert it right after the espota
        # path (index 2, before -r); the password stays untouched further down
        # the argv. Inserting a value pair does not disturb the -a PASSWORD pair.
        cmd[2:2] = ["-I", CALLBACK_IP]

        # Non-secret: announce which interface the callback will use. Safe to
        # print because it is only the Wi-Fi address, never the command/password.
        print("callback: Wi-Fi %s" % CALLBACK_IP)

        # Do NOT print cmd: it contains the password in argv. espota with -r
        # writes its own non-secret progress and result to stdout/stderr, which
        # we inherit here. Propagate its exit status unchanged.
        result = subprocess.run(cmd)
        return result.returncode
    finally:
        # Clear the password from this process and drop the temp image.
        password = None
        del password
        if tmp_image is not None:
            try:
                os.unlink(tmp_image)
            except OSError:
                pass


if __name__ == "__main__":
    try:
        sys.exit(main())
    except espdisp.Fail as exc:
        print("error: %s" % exc, file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
