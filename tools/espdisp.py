#!/usr/bin/env python3
"""Build, flash, update, and configure the esp32-display firmware without hand-typing FQBNs."""
import argparse
import base64
import fnmatch
import getpass
import glob
import hashlib
import json
import os
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
from typing import Dict, List, NamedTuple, Optional, Tuple


class Board(NamedTuple):
    key: str
    fqbn: str
    chip: str  # esptool/FQBN board id, used to match a detected chip
    blurb: str


# The whole point of this tool: these two strings live here instead of in
# shell history. Keep them byte-identical to the commands documented in
# README.md "Getting started" - the README is the fallback when this
# misbehaves, so the two must not drift.
BOARDS = {
    "c6": Board(
        key="c6",
        fqbn="esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M",
        chip="esp32c6",
        blurb='ESP32-C6 1.47" 172x320 - one binary serves both Waveshare variants',
    ),
    "s3": Board(
        key="s3",
        fqbn="esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi",
        chip="esp32s3",
        blurb="ESP32-S3-Touch-AMOLED-1.75C 466x466 round AMOLED (needs PSRAM=opi)",
    ),
}

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKETCH_DIR = os.path.join(REPO_ROOT, "firmware", "display_stream")
SKETCH_INO = os.path.join(SKETCH_DIR, "display_stream.ino")
LIBRARIES_DIR = os.path.join(REPO_ROOT, "firmware", "libraries")

# Both boards are native USB CDC, so they always enumerate here on macOS.
PORT_GLOB = "/dev/cu.usbmodem*"

BAUD = 115200
CFG_PREFIXES = ("CFGOK", "CFGERR", "CFGINFO")

# OTA. 3232 is ArduinoOTA's default and what the firmware binds.
OTA_PORT = 3232
OTA_PASSWORD_ENV = "ESPDISP_OTA_PASSWORD"
# Both match otapolicy::PASSWORD_MIN_BYTES / PASSWORD_MAX_BYTES in the firmware,
# and are counted in bytes for the same reason it does.
OTA_PASSWORD_MIN = 8
OTA_PASSWORD_MAX = 64


class Fail(Exception):
    """A condition the user can act on: reported as one line, never a traceback."""


# --------------------------------------------------------------------------
# process plumbing


def arduino_cli() -> str:
    path = shutil.which("arduino-cli")
    if not path:
        raise Fail(
            "arduino-cli is not on PATH. Install it (brew install arduino-cli) "
            "and add the esp32 core."
        )
    return path


def run_streaming(
    cmd: List[str], cwd: Optional[str] = None, redact: Optional[str] = None
) -> List[str]:
    """Run cmd, echo its output live, and return the lines for later inspection.

    Live echo matters because an arduino-cli compile takes minutes; a silent
    tool looks hung.

    `redact` is replaced with *** in the echoed command line. Used for the OTA
    password: espota.py accepts it only as an argument, so it cannot be kept out
    of argv, but it can be kept out of the terminal and out of any log of one.
    """
    shown = [arg.replace(redact, "***") for arg in cmd] if redact else cmd
    print("$ " + " ".join(shown), flush=True)
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    lines = []
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        lines.append(line.rstrip("\n"))
    code = proc.wait()
    if code != 0:
        raise SystemExit(code)
    return lines


def run_capture(cmd: List[str], timeout: float = 60.0) -> subprocess.CompletedProcess:
    """Run cmd quietly. Never raises on a non-zero exit; callers decide."""
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(cmd, 1, "", str(exc))


# --------------------------------------------------------------------------
# port and chip discovery


class PortInfo(NamedTuple):
    address: str
    board_keys: List[str]  # board keys arduino-cli itself claims match, may be empty
    label: str


def detected_ports() -> List[PortInfo]:
    """Parse `arduino-cli board list --json`.

    Defensive on purpose: with nothing attached this machine reports three
    unrelated serial ports with an empty "properties" and no "matching_boards"
    key at all (measured), so every field here is treated as optional.
    """
    proc = run_capture([arduino_cli(), "board", "list", "--json"], timeout=30.0)
    if proc.returncode != 0:
        raise Fail("`arduino-cli board list --json` failed:\n" + proc.stderr.strip())
    try:
        payload = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise Fail("could not parse `arduino-cli board list --json` output: %s" % exc)

    out = []
    for entry in payload.get("detected_ports") or []:
        port = entry.get("port") or {}
        address = port.get("address") or ""
        if not address:
            continue
        if (port.get("protocol") or "serial") != "serial":
            continue
        keys = []
        for match in entry.get("matching_boards") or []:
            fqbn = match.get("fqbn") or ""
            key = board_key_for_fqbn(fqbn)
            if key and key not in keys:
                keys.append(key)
        out.append(PortInfo(address, keys, port.get("label") or address))
    return sorted(out, key=lambda p: p.address)


class NetworkPort(NamedTuple):
    address: str  # IPv4 the responder answered with
    hostname: str  # SRV target, e.g. "panel.local."
    board: str  # the "board" TXT record, e.g. "esp32c6"


def parse_network_ports(payload: dict) -> List[NetworkPort]:
    """Pull the OTA-capable panels out of `arduino-cli board list --json`.

    arduino-cli runs a bundled mdns-discovery that browses `_arduino._tcp` - the
    same service the firmware registers and espota pushes to - and turns each TXT
    record into a port property, `board` included (arduino/mdns-discovery
    main.go, toDiscoveryPort). So the chip a panel is running is already
    discoverable without this tool implementing any mDNS itself.

    Split from the request so the parse can be tested against captured JSON: no
    panel is attached here, so this is the only way any of it is exercised.
    """
    out = []
    for entry in payload.get("detected_ports") or []:
        port = entry.get("port") or {}
        if (port.get("protocol") or "") != "network":
            continue
        props = port.get("properties") or {}
        board = (props.get("board") or "").strip().lower()
        hostname = (props.get("hostname") or "").strip().rstrip(".")
        address = (port.get("address") or "").strip()
        if not address and not hostname:
            continue
        out.append(NetworkPort(address, hostname, board))
    return out


def network_port_for_host(ports: List[NetworkPort], host: str) -> Optional[NetworkPort]:
    """Find the discovered panel the user means by `host`.

    Matches an IP against the address, and a name against the SRV hostname or its
    first label, because `ota panel.local`, `ota panel` and `ota 192.168.1.42` all
    name the same panel. Returns None rather than a guess when nothing matches -
    an unrecognised host is "could not confirm", never "wrong board".
    """
    wanted = host.strip().rstrip(".").lower()
    if not wanted:
        return None
    for port in ports:
        hostname = port.hostname.lower()
        if wanted in (port.address.lower(), hostname, hostname.split(".")[0]):
            return port
    return None


# What comparing --board against a discovered `board=` TXT record can conclude.
TARGET_OK = "ok"  # they agree
TARGET_WRONG = "wrong"  # it advertises the other board this tool knows
TARGET_UNKNOWN = "unknown"  # nothing to compare, or a board this tool cannot place


def classify_ota_target(board: Board, advertised: str) -> str:
    """Decide whether an advertised board contradicts the chosen target.

    Deliberately three-valued, and only TARGET_WRONG refuses. An empty or
    unrecognised `board=` means this tool cannot place the panel - a newer variant,
    a different project answering on the same service - and refusing on that would
    turn "I do not know" into "you are wrong". The USB path has the same shape: it
    only refuses when arduino-cli names a single, different board.
    """
    token = (advertised or "").strip().lower()
    if not token:
        return TARGET_UNKNOWN
    if token == board.chip:
        return TARGET_OK
    if any(token == other.chip for other in BOARDS.values()):
        return TARGET_WRONG
    return TARGET_UNKNOWN


def board_key_for_fqbn(fqbn: str) -> Optional[str]:
    """Map an arduino-cli FQBN (vendor:arch:board[:opts]) onto a board key."""
    parts = fqbn.split(":")
    if len(parts) < 3:
        return None
    board_id = parts[2].strip().lower()
    for board in BOARDS.values():
        if board_id == board.chip:
            return board.key
    return None


def candidate_ports() -> List[PortInfo]:
    return [p for p in detected_ports() if fnmatch.fnmatch(p.address, PORT_GLOB)]


def resolve_port(explicit: Optional[str]) -> PortInfo:
    if explicit:
        # Trust an explicit port even if board list did not report it: a port
        # can exist without arduino-cli enumerating it.
        for port in detected_ports():
            if port.address == explicit:
                return port
        return PortInfo(explicit, [], explicit)

    ports = candidate_ports()
    if not ports:
        raise Fail(
            "no ESP32 serial port found (looked for %s).\n"
            "  Plug the board in over USB, or pass --port <device>.\n"
            "  `%s list` shows every port arduino-cli can see."
            % (PORT_GLOB, os.path.basename(sys.argv[0]))
        )
    if len(ports) > 1:
        listing = "\n".join("    %s" % p.address for p in ports)
        raise Fail(
            "%d candidate ports found; refusing to pick one.\n%s\n"
            "  Re-run with --port <device>." % (len(ports), listing)
        )
    return ports[0]


def esptool_path() -> Optional[str]:
    """Locate the esptool the esp32 core bundles, if it is installed.

    The version directory is globbed rather than pinned: 5.3.1 is what is
    installed here today, but the core upgrades it.
    """
    proc = run_capture([arduino_cli(), "config", "get", "directories.data"], timeout=30.0)
    data_dir = proc.stdout.strip() if proc.returncode == 0 else ""
    if not data_dir:
        return None
    base = os.path.join(data_dir, "packages", "esp32", "tools", "esptool_py")
    found = []
    for name in ("esptool", "esptool.py"):  # 5.x ships a binary, 4.x a script
        found.extend(glob.glob(os.path.join(base, "*", name)))
    if not found:
        return None
    # Newest version directory wins. Lexicographic ordering is not a true
    # version sort, but any bundled esptool can report a chip id, so picking
    # the wrong one of several is harmless.
    return sorted(found)[-1]


def core_data_dir() -> str:
    proc = run_capture([arduino_cli(), "config", "get", "directories.data"], timeout=30.0)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def espota_path() -> str:
    """Locate espota.py, the OTA pusher the esp32 core ships.

    This is the same program the core's own upload recipe runs (platform.txt:
    `tools.esp_ota.upload.pattern`), and it is pure stdlib - socket, hashlib,
    argparse - so it adds no dependency. It is invoked directly rather than
    through `arduino-cli upload -l network` because arduino-cli 1.5.1 refuses an
    address it has not discovered itself (measured: `-p 192.0.2.1 -l network`
    fails with "Error getting port metadata: port not found"), which would make
    pushing to a known IP or a .local name impossible.
    """
    data_dir = core_data_dir()
    if not data_dir:
        raise Fail("could not read `arduino-cli config get directories.data`")
    pattern = os.path.join(
        data_dir, "packages", "esp32", "hardware", "esp32", "*", "tools", "espota.py"
    )
    found = sorted(glob.glob(pattern))
    if not found:
        raise Fail(
            "espota.py not found under %s.\n"
            "  Install the esp32 core: arduino-cli core install esp32:esp32" % pattern
        )
    # Newest core directory wins, same lexicographic caveat as esptool_path().
    return found[-1]


def core_hardware_dir() -> str:
    """The installed esp32 core's platform directory ({runtime.platform.path}).

    Globbed, never pinned: 3.3.11 is what is installed here today and the core
    upgrades itself. Newest directory wins, same lexicographic caveat as
    esptool_path() - and unlike there it matters slightly more, because the files
    read out of it (boot_app0.bin, boards.txt) belong to a specific core version.
    Picking the newest is the same answer arduino-cli gives an unversioned FQBN.
    """
    data_dir = core_data_dir()
    if not data_dir:
        raise Fail("could not read `arduino-cli config get directories.data`")
    pattern = os.path.join(data_dir, "packages", "esp32", "hardware", "esp32", "*")
    found = sorted(p for p in glob.glob(pattern) if os.path.isdir(p))
    if not found:
        raise Fail(
            "the esp32 core is not installed under %s.\n"
            "  Install it: arduino-cli core install esp32:esp32" % pattern
        )
    return found[-1]


def core_boot_app0() -> str:
    """boot_app0.bin, the otadata initialiser, out of the installed core.

    This one is NOT in an --output-dir export: arduino-cli exports what the
    compile produced, and boot_app0 is a fixed 8192-byte file shipped with the
    core ({runtime.platform.path}/tools/partitions/boot_app0.bin in the recipe at
    platform.txt:346). It is what makes a freshly flashed board boot the app at
    0x10000 rather than an empty ota slot, so a bundle that means to bring up a
    blank board has to carry it.
    """
    path = os.path.join(core_hardware_dir(), "tools", "partitions", "boot_app0.bin")
    if not os.path.isfile(path):
        raise Fail("boot_app0.bin not found at %s" % path)
    return path


def bootloader_address_from_boards_txt(text: str, chip: str) -> Optional[int]:
    """`<chip>.build.bootloader_addr` out of boards.txt, or None if absent.

    Split out from the file reading so the parse is testable with no core
    installed. Deliberately narrow: only the exact `<chip>.build.bootloader_addr`
    key, so a menu override or a different board's key cannot answer for this one.
    """
    pattern = re.compile(
        r"^%s\.build\.bootloader_addr\s*=\s*(0[xX][0-9a-fA-F]+|\d+)\s*$"
        % re.escape(chip),
        re.MULTILINE,
    )
    found = pattern.findall(text)
    if not found:
        return None
    if len({value.lower() for value in found}) > 1:
        # Two different answers for one chip. Refusing to pick is the same stance
        # resolve_board and fw_version_from_sketch take, and this one would put an
        # image at the wrong flash address.
        raise Fail(
            "boards.txt gives %s %d different bootloader addresses (%s)"
            % (chip, len(set(found)), ", ".join(sorted(set(found))))
        )
    return int(found[0], 0)


def core_bootloader_address(chip: str) -> int:
    """Where this chip's second-stage bootloader goes, read out of the core.

    Read rather than hardcoded because it is per-chip data: 0x0 for esp32c6 and
    esp32s3, 0x1000 for the classic ESP32. A constant here would be wrong for
    some board this repo does not support yet, and it would be wrong silently -
    the flash would take the write and the chip would not boot.
    """
    path = os.path.join(core_hardware_dir(), "boards.txt")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        raise Fail("cannot read %s: %s" % (path, exc.strerror or exc))
    address = bootloader_address_from_boards_txt(text, chip)
    if address is None:
        raise Fail(
            "%s has no build.bootloader_addr in %s, so there is no way to say "
            "where its bootloader goes" % (chip, path)
        )
    return address


def probe_chip(address: str) -> Optional[str]:
    """Ask the bundled esptool which chip is on `address`.

    Returns a board key, or None if the chip could not be determined.

    VERIFIED against hardware, for esptool 5.3.1 and one chip: run against an
    attached ESP32-S3 it matched on "Detecting chip type... ESP32-S3", derived the
    token esp32s3 and returned 's3'. That is the only one of the two spellings
    below that 5.3.1 prints - it says "Connected to ESP32-S3 on <port>:" and
    "Chip type:          ESP32-S3 (QFN56) (revision v0.2)", and never "Chip is".
    The "Chip is" alternative is esptool 4.x's spelling and is kept for a 4.x
    esptool.py, which esptool_path() still locates deliberately; it is UNVERIFIED,
    because no 4.x esptool has been run against a board here.

    UNVERIFIED for the C6: no C6 was attached, so only the S3 half of the board
    table has been exercised end to end.
    """
    tool = esptool_path()
    if not tool:
        return None
    cmd = [tool, "--port", address, "--connect-attempts", "2", "chip-id"]
    if tool.endswith(".py"):
        cmd = [sys.executable] + cmd
    proc = run_capture(cmd, timeout=60.0)
    blob = (proc.stdout or "") + (proc.stderr or "")
    if "chip-id" in blob and re.search(r"(No such command|Usage:)", blob):
        # esptool 4.x spells it with an underscore.
        cmd[-1] = "chip_id"
        proc = run_capture(cmd, timeout=60.0)
        blob = (proc.stdout or "") + (proc.stderr or "")
    for raw in re.findall(r"(?:Chip is|Detecting chip type\.\.\.)\s*(ESP32[\w-]*)", blob):
        token = re.sub(r"[^a-z0-9]", "", raw.lower())
        for board in BOARDS.values():
            if token.startswith(board.chip):
                return board.key
    return None


def resolve_board(explicit: Optional[str], port: Optional[PortInfo]) -> Board:
    """Pick a board, or refuse.

    Never guesses. Both boards are native USB CDC at VID 0x303A PID 0x1001, so
    neither the port name nor the VID/PID distinguishes a C6 from the S3, and a
    tool that picked one would be picking for the user with nothing to go on.

    A wrong guess is not fatal to a board - the core's upload recipe passes
    `--chip {build.mcu}` to esptool (platform.txt line 346) and esptool refuses a
    chip that is not the one it was told to expect. What a refusal here buys is
    the difference between that and a message that names the fix, before a
    multi-minute compile rather than after it.
    """
    if explicit:
        board = BOARDS[explicit]
        # Free cross-check: if arduino-cli itself named a single, different
        # board for this port, the user has almost certainly typed the wrong
        # target. This costs no extra port access.
        if port and len(port.board_keys) == 1 and port.board_keys[0] != board.key:
            raise Fail(
                "--board %s contradicts %s, which arduino-cli reports as %s.\n"
                "  Re-run with --board %s, or with --port pointing at the other board.\n"
                "  There is no flag to override this. If arduino-cli is the one that\n"
                "  is wrong, the explicit commands in README.md \"Getting started\"\n"
                "  do the same job with nothing in the way:\n"
                "    arduino-cli compile -b %s --libraries %s .\n"
                "    arduino-cli upload -b %s -p %s ."
                % (
                    board.key,
                    port.address,
                    port.board_keys[0],
                    port.board_keys[0],
                    board.fqbn,
                    LIBRARIES_DIR,
                    board.fqbn,
                    port.address,
                )
            )
        return board

    if port is None:
        raise Fail("--board is required here (one of: %s)" % ", ".join(BOARDS))

    if len(port.board_keys) == 1:
        return BOARDS[port.board_keys[0]]

    print("Probing %s for its chip type..." % port.address, flush=True)
    key = probe_chip(port.address)
    if key:
        print("Detected %s (%s)." % (BOARDS[key].chip, key), flush=True)
        return BOARDS[key]

    raise Fail(
        "could not determine which chip is on %s.\n"
        "  Both boards are native USB CDC (VID 0x303A PID 0x1001), so the port\n"
        "  name cannot tell them apart, and probing did not answer either.\n"
        "  Re-run with --board %s." % (port.address, "|".join(BOARDS))
    )


# --------------------------------------------------------------------------
# stdlib serial (no pyserial: it is not installed for any python3 here)


def open_serial(address: str):
    """Open a tty at 115200 raw using termios only.

    tools/serial_cmd.py uses pyserial, which is not installed on this machine;
    termios is in the standard library and does the same job for a one-line
    request/response. /dev/cu.* is used rather than /dev/tty.* so the open does
    not block on carrier detect and does not reset the board.
    """
    try:
        fd = os.open(address, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError as exc:
        raise Fail("cannot open %s: %s" % (address, exc.strerror or exc))
    try:
        attrs = termios.tcgetattr(fd)
        attrs[0] = 0  # iflag: no translation, no flow control
        attrs[1] = 0  # oflag: no post-processing
        attrs[2] = (attrs[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)) | (
            termios.CS8 | termios.CLOCAL | termios.CREAD
        )
        attrs[3] = 0  # lflag: raw, no echo, no canonical mode
        attrs[4] = BAUD
        attrs[5] = BAUD
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        termios.tcflush(fd, termios.TCIFLUSH)
    except (termios.error, OSError) as exc:
        os.close(fd)
        raise Fail("cannot configure %s: %s" % (address, exc))
    return fd


def send_config_line(address: str, line: str, timeout: float) -> str:
    """Write one config line and return the first CFG* reply, or raise on timeout."""
    fd = open_serial(address)
    try:
        os.write(fd, (line + "\n").encode())
        deadline = time.monotonic() + timeout
        buf = b""
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if not ready:
                continue
            try:
                chunk = os.read(fd, 512)
            except BlockingIOError:
                continue
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                text = raw.strip().decode(errors="replace")
                if text.startswith(CFG_PREFIXES):
                    return text
        raise Fail("no CFG reply from %s within %.1fs" % (address, timeout))
    finally:
        os.close(fd)


# --------------------------------------------------------------------------
# the firmware bundle: one file that travels
#
# `bundle` writes a single .espdispfw file holding the compiled application
# images, everything else a blank board needs written to flash, and a manifest
# describing all of it, and the Mac app opens one the user
# picks - possibly on another machine, weeks later, with no copy of this repo in
# sight. That is the whole reason for a file rather than a directory: it has to
# survive being emailed, dropped in a share, or carried on a stick.
#
# LAYOUT, byte-exact. A reader on the other side of this format implements four
# lines:
#
#   offset 0        "ESPDISPFW2\n"   11 bytes, magic and format generation
#   offset 11       "%010d\n"        11 bytes, manifest length, zero-padded ASCII
#   offset 22       manifest         UTF-8 JSON object, exactly that many bytes
#   offset 22+len   payloads         raw, in manifest order: for each image its
#                                    application image, then that image's flash
#                                    parts in listed order
#
# The fixed 22-byte prefix is the point: a reader gets the manifest without
# reading two megabytes, and the payloads stay byte-identical to arduino-cli's
# <sketch>.ino.bin, so the sha256 in the manifest is the same number
# `shasum -a 256` prints for the file the compile produced.
#
# WHAT GENERATION 2 ADDED, AND WHY IT IS A NEW GENERATION. A generation-1 bundle
# carried one application image per chip. That is exactly right for OTA - the
# image goes into an app slot and the running bootloader boots it - and it is not
# enough for a board that has never been flashed, which needs the second-stage
# bootloader, the partition table and boot_app0 written at their own flash
# addresses before the app at 0x10000 will boot at all. Generation 2 carries
# those three per image, with their addresses, so the file is a complete answer
# to "bring this board up from nothing".
#
# Extending generation 1 in place was not available. The generation-1 reader
# walks the payload area with `offset == cursor` per image and then requires
# `cursor == len(data)`, so any extra payload trips either the contiguity check
# or the trailing-bytes check. Making a file the shipped reader would accept
# means relaxing one of the two checks whose whole job is catching a truncated or
# concatenated file, on every reader, forever. Bumping the magic instead means an
# old reader refuses a new file loudly and says which side is behind - the
# message it already had for this case - and nothing that ever mattered is
# weakened.
#
# GENERATION 1 IS STILL READ, in both directions of that asymmetry: unpack_bundle
# and `bundle-info` accept one, and so does the app. A v1 file cannot flash a
# blank board, but it is a perfectly good OTA payload, and the person holding one
# cannot re-create it without this repo at the commit it was built from.
#
# WHAT IS DELIBERATELY NOT CARRIED: <sketch>.ino.merged.bin. See app_image().
#
# WHY NOT zip, tar, or base64 inside JSON. Foundation has no zip reader on
# macOS and the Compression framework only does raw deflate/zlib streams, so a
# zip would leave the app hand-parsing a central directory; tar is the same
# problem, another reader to write and test. base64 in JSON inflates 2.2MB to
# roughly 3MB and forces the whole file through a JSON parser to reach one
# image. Nothing here is compressed, because an ESP32 app image already is.
# This container is about thirty lines on each side and leaves the images
# checkable with ordinary tools.

BUNDLE_MAGIC = b"ESPDISPFW2\n"
BUNDLE_FORMAT = 2  # the `format` field inside the manifest, kept in step with the magic
BUNDLE_MAGIC_V1 = b"ESPDISPFW1\n"
BUNDLE_FORMAT_V1 = 1
# Which magic means which format. Read-only for generation 1: this tool writes
# the newest generation and only ever writes one, so there is one BUNDLE_MAGIC.
# Every magic is the same width, which is what keeps the manifest at offset 22
# for every generation and lets one reader dispatch on the first line
# (test_generation_one_layout_is_pinned_and_still_read pins that).
BUNDLE_GENERATIONS = {BUNDLE_MAGIC_V1: BUNDLE_FORMAT_V1, BUNDLE_MAGIC: BUNDLE_FORMAT}
BUNDLE_LENGTH_DIGITS = 10
BUNDLE_HEADER_BYTES = len(BUNDLE_MAGIC) + BUNDLE_LENGTH_DIGITS + 1  # 22
BUNDLE_SUFFIX = ".espdispfw"
BUNDLE_TOOL = "espdisp.py bundle"

# Every key a reader may rely on. Listed rather than checked one at a time so a
# refusal can name all of what is missing at once.
MANIFEST_KEYS = (
    "format",
    "firmware_version",
    "built_at",
    "source_commit",
    "source_dirty",
    "tool",
    "images",
)
# Generation 1's image keys, which generation 2 keeps unchanged and adds to.
IMAGE_KEYS = ("board", "chip", "fqbn", "filename", "offset", "bytes", "sha256")
IMAGE_KEYS_V2 = IMAGE_KEYS + ("app_address", "flash_parts")
FLASH_PART_KEYS = ("role", "address", "filename", "offset", "bytes", "sha256")

# The three parts a board that has never been flashed needs, in the order they
# are written. A generation-2 image must carry all three: the generation exists
# to make "this file can bring up a blank board" true of every file that claims
# it, and a reader that had to check role by role would be answering "maybe".
# Extra roles are allowed - a future writer may add a filesystem image - which is
# why this is a required subset rather than the whole vocabulary.
FLASH_ROLE_BOOTLOADER = "bootloader"
FLASH_ROLE_PARTITIONS = "partitions"
FLASH_ROLE_BOOT_APP0 = "boot_app0"
REQUIRED_FLASH_ROLES = (
    FLASH_ROLE_BOOTLOADER,
    FLASH_ROLE_PARTITIONS,
    FLASH_ROLE_BOOT_APP0,
)

# Flash addresses, from the core's own upload recipe (platform.txt:346,
# tools.esptool_py.upload.pattern_args). These three are the same for every
# chip. THE BOOTLOADER ADDRESS IS NOT: boards.txt gives esp32c6 (:812) and
# esp32s3 (:1183) a bootloader at 0x0 while the classic ESP32 uses 0x1000, so it
# is read per chip out of the installed core (core_bootloader_address) and
# carried in the manifest. A reader takes every address from the file for the
# same reason: the day a board with a different map is added, old bundles still
# describe themselves correctly.
PARTITIONS_FLASH_ADDRESS = 0x8000
BOOT_APP0_FLASH_ADDRESS = 0xE000
APP_FLASH_ADDRESS = 0x10000


def encode_manifest(manifest: dict) -> bytes:
    """The manifest's one canonical encoding.

    Sorted and compact, so encoding the same manifest twice gives the same bytes.
    bundle_manifest depends on that: the offsets it writes describe the file the
    encoded manifest is part of, so it has to be able to encode, measure, and
    encode again without the length wandering for reasons of its own.
    """
    return json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode("utf-8")


def bundle_length_line(length: int) -> bytes:
    """The 11-byte length line: ten ASCII digits, zero padded, then a newline.

    Fixed width is what puts the manifest at a constant offset. Ten digits allows
    a 10GB manifest against an actual one of a few hundred bytes, so this cannot
    be reached - but `%010d` does not truncate when a number outgrows the field,
    it widens, which would move the manifest and turn every offset inside it into
    a lie without anything noticing. So refuse instead: a manifest that does not
    fit the field is not a bundle this format can describe, and saying so is
    better than writing a file whose header disagrees with its body.
    """
    if length < 0 or length >= 10 ** BUNDLE_LENGTH_DIGITS:
        raise Fail(
            "manifest is %d bytes, which does not fit the %d-digit length field"
            % (length, BUNDLE_LENGTH_DIGITS)
        )
    return ("%0*d\n" % (BUNDLE_LENGTH_DIGITS, length)).encode("ascii")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# The one spelling of FW_VERSION in the sketch (display_stream.ino:84). Loose
# about whitespace and the position of the `*`, strict about everything that
# makes it a definition, so a rename or a move breaks loudly here rather than
# quietly producing a manifest with the wrong version in it.
FW_VERSION_RE = re.compile(
    r'^\s*static\s+const\s+char\s*\*\s*FW_VERSION\s*=\s*"([^"\n]*)"\s*;', re.MULTILINE
)


def fw_version_from_sketch(text: str) -> str:
    """Read FW_VERSION out of the sketch source.

    Read rather than passed in as a flag, because the sketch is the single source
    of truth: FW_VERSION is what EINF reports to the app, what the mDNS `fw` TXT
    record advertises, and what prints at boot. A --version flag would be a
    second place for it to be wrong, and a bundle whose manifest disagrees with
    the image it carries is worse than no manifest at all - the app compares the
    two to decide whether to offer an update.

    Refuses on zero or two matches instead of picking, the same stance
    resolve_board takes: a tool that guessed here would put the wrong number in
    front of the user at the one moment they are deciding whether to flash.
    """
    found = FW_VERSION_RE.findall(text)
    if not found:
        raise Fail(
            "could not find FW_VERSION in the sketch.\n"
            '  Expected a line like: static const char *FW_VERSION = "1.2.0";\n'
            "  If it was renamed or moved, FW_VERSION_RE in this file has to follow it."
        )
    if len(found) > 1:
        raise Fail(
            "found %d FW_VERSION definitions in the sketch (%s); there must be exactly one"
            % (len(found), ", ".join(repr(v) for v in found))
        )
    if not found[0].strip():
        raise Fail("FW_VERSION in the sketch is empty; a bundle needs a version to compare")
    return found[0]


def sketch_fw_version(path: str = SKETCH_INO) -> str:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise Fail("cannot read %s: %s" % (path, exc.strerror or exc))
    return fw_version_from_sketch(text)


def utc_timestamp() -> str:
    """ISO 8601 in UTC with a Z suffix, which is what the app's date parsing wants."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def git_provenance(repo_root: str = REPO_ROOT) -> Tuple[Optional[str], bool]:
    """(commit, dirty) for the tree the images were built from, best effort.

    Deliberately tolerant: an exported copy of this tool with no .git anywhere,
    or a machine with no git installed, should still be able to write a bundle,
    so anything short of a clean 40-hex answer means (None, False) and the
    manifest says source_commit: null. run_capture already turns an OSError into
    a non-zero result, so a missing git needs no special case here.

    `git status --porcelain` counts untracked files as dirty on purpose: an
    untracked source file under firmware/ is compiled into the image like any
    other, so it belongs in an honest answer about what these bytes came from.
    Ignored files - wifi_config.h, build directories - do not appear and do not
    count.
    """
    head = run_capture(["git", "-C", repo_root, "rev-parse", "HEAD"], timeout=15.0)
    if head.returncode != 0:
        return None, False
    commit = head.stdout.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        return None, False
    status = run_capture(["git", "-C", repo_root, "status", "--porcelain"], timeout=30.0)
    if status.returncode != 0:
        # The commit is known and the cleanliness is not. Claiming clean would be
        # the wrong way to be wrong, but so would refusing to bundle at all, so
        # this reports the commit and the safer of the two answers is the caller's
        # problem: bundle-info prints exactly what the manifest says.
        return commit, False
    return commit, bool(status.stdout.strip())


def bundle_manifest(
    firmware_version: str,
    images: List[dict],
    built_at: str,
    source_commit: Optional[str] = None,
    source_dirty: bool = False,
    tool: str = BUNDLE_TOOL,
) -> dict:
    """Build the manifest, filling in an absolute offset for every payload.

    `images` carries board, chip, fqbn, filename, bytes, sha256, app_address and
    flash_parts per image, and each flash part carries role, address, filename,
    bytes and sha256; the offsets are this function's job.

    Offsets are absolute from the start of the FILE, not relative to the payload
    area, so a reader is one slice with no arithmetic - and so it can also check
    that the payloads run contiguously from 22 + len(manifest) in listed order,
    which is what catches a truncated or hand-edited file. PAYLOAD ORDER is a flat
    walk: each image's application image, then that image's flash parts in listed
    order, then the next image. One rule, pinned literally on both sides of the
    format.

    Absolute offsets make the manifest describe its own length, so they are
    solved rather than computed: assign, re-encode, and repeat until the encoded
    length stops moving. Carrying flash parts adds offsets to solve but does not
    change the argument for the iteration bound: an offset only ever moves the
    length by gaining digits, the length therefore only grows, and each pass makes
    every offset at least as large as the last, so the fixpoint is reached from
    below. Eight passes is far more than the two it takes for a two-board bundle
    (test_bundle_manifest_offsets drives payload sizes that force rollovers).
    """
    if not images:
        raise Fail("a bundle needs at least one image")
    prepared = []
    for image in images:
        parts = image.get("flash_parts")
        if not isinstance(parts, list):
            # This tool writes generation 2 only, so an image with no flash parts
            # is a caller bug rather than an older file. Reading generation 1 is
            # unpack_bundle's business, not the writer's.
            raise Fail(
                "image for %r carries no flash_parts list; a generation-%d bundle "
                "describes what a blank board needs" % (image.get("chip"), BUNDLE_FORMAT)
            )
        # The parts are copied, not shared: this function mutates offsets, and a
        # caller's list surviving into the manifest would be mutated behind its
        # back - and a second call would then start from the first call's offsets.
        prepared.append(
            dict(image, offset=0, flash_parts=[dict(part, offset=0) for part in parts])
        )
    manifest = {
        "format": BUNDLE_FORMAT,
        "firmware_version": firmware_version,
        "built_at": built_at,
        "source_commit": source_commit,
        "source_dirty": bool(source_dirty),
        "tool": tool,
        "images": prepared,
    }
    for _ in range(8):
        length = len(encode_manifest(manifest))
        cursor = BUNDLE_HEADER_BYTES + length
        for image in manifest["images"]:
            image["offset"] = cursor
            cursor += image["bytes"]
            for part in image["flash_parts"]:
                part["offset"] = cursor
                cursor += part["bytes"]
        if len(encode_manifest(manifest)) == length:
            return manifest
    raise Fail("could not settle the manifest offsets")  # unreachable: length only grows


def missing_flash_roles(roles) -> List[str]:
    """Which of the three a blank board needs are absent, in written order."""
    present = set(roles)
    return [role for role in REQUIRED_FLASH_ROLES if role not in present]


def conflicting_flash_address(writes) -> Optional[Tuple[int, str, str]]:
    """The first flash address two different payloads both claim, if any.

    `writes` is (address, label) in write order. Two payloads at one address is a
    contradiction rather than a preference - whichever went second would be the
    only one that survived - so both sides of the format refuse it instead of
    quietly writing the file and letting a board sort it out.
    """
    seen: Dict[int, str] = {}
    for address, label in writes:
        if address in seen:
            return address, seen[address], label
        seen[address] = label
    return None


def pack_bundle(
    manifest: dict,
    payloads: Dict[str, bytes],
    flash_payloads: Optional[Dict[str, Dict[str, bytes]]] = None,
) -> bytes:
    """Serialise a manifest and its payloads into a bundle file's bytes.

    `payloads` is {chip: application image}; `flash_payloads` is
    {chip: {role: bytes}} for the parts a blank board needs.

    Re-checks the manifest against the payloads it claims to describe - present,
    right length, right hash, landing where the offsets say - because the writer
    is the last side that can still fix a disagreement. Past here it is somebody
    else's file and all they can do is refuse it. Every check applies to the flash
    parts too: they are written to absolute flash addresses on a board that
    currently has no working firmware, which is the worst place for a payload that
    is not what its manifest says.
    """
    images = manifest.get("images") or []
    if not images:
        raise Fail("a bundle needs at least one image")
    flash_payloads = flash_payloads or {}
    raw = encode_manifest(manifest)
    out = [BUNDLE_MAGIC, bundle_length_line(len(raw)), raw]
    cursor = BUNDLE_HEADER_BYTES + len(raw)

    def place(entry: dict, blob: Optional[bytes], label: str) -> None:
        """One payload, checked against its manifest entry and appended."""
        nonlocal cursor
        if blob is None:
            raise Fail("the manifest lists %s but no payload was given for it" % label)
        if len(blob) != entry["bytes"]:
            raise Fail(
                "%s payload is %d bytes, the manifest says %d"
                % (label, len(blob), entry["bytes"])
            )
        digest = sha256_hex(blob)
        if digest != entry["sha256"]:
            raise Fail(
                "%s payload hashes to %s, the manifest says %s"
                % (label, digest[:16], str(entry["sha256"])[:16])
            )
        if entry["offset"] != cursor:
            raise Fail(
                "%s is listed at offset %d but lands at %d; the manifest offsets do "
                "not describe this file" % (label, entry["offset"], cursor)
            )
        out.append(blob)
        cursor += len(blob)

    for image in images:
        chip = image["chip"]
        place(image, payloads.get(chip), chip)
        parts = image.get("flash_parts") or []
        absent = missing_flash_roles(part.get("role") for part in parts)
        if absent:
            raise Fail(
                "the %s image carries no %s; a generation-%d bundle has to describe "
                "everything a blank board needs"
                % (chip, ", ".join(absent), BUNDLE_FORMAT)
            )
        clash = conflicting_flash_address(
            [(image["app_address"], "the app")]
            + [(part["address"], part["role"]) for part in parts]
        )
        if clash:
            raise Fail(
                "the %s image writes both %s and %s to flash address 0x%x"
                % (chip, clash[1], clash[2], clash[0])
            )
        for part in parts:
            place(
                part,
                (flash_payloads.get(chip) or {}).get(part["role"]),
                "%s %s" % (chip, part["role"]),
            )
    return b"".join(out)


def is_whole_number(value) -> bool:
    """An int that is not a bool.

    bool is an int in Python and JSON true would sail through an isinstance check,
    so it is excluded explicitly rather than trusted: `"offset": true` would
    otherwise read as offset 1 and be refused for not being contiguous, a message
    pointing at the wrong problem. The Swift reader excludes it for the same
    reason, and also excludes anything WRITTEN as a float, which json.loads
    already does here (372.0 is a float and fails isinstance(int)).
    """
    return isinstance(value, int) and not isinstance(value, bool)


def unpack_bundle(
    data: bytes,
) -> Tuple[dict, Dict[str, bytes], Dict[str, Dict[str, bytes]]]:
    """Read a bundle, checking everything a reader can check.

    Returns (manifest, {chip: application image}, {chip: {role: flash part}}).
    The third is empty for a generation-1 file, which carries no flash parts.
    Raises Fail, one specific line per way a file can be wrong, because by the
    time this runs the file arrived from somewhere else and "invalid bundle" tells
    the user nothing about whether to re-download it, rebuild it, or go and find
    the person who sent it.

    Everything here is checkable without the panel: the hashes catch a corrupt or
    edited payload, and the contiguity check catches a truncation that happens to
    leave a valid-looking manifest. What it cannot check is whether the image is
    right for the panel - only the chip token in the manifest speaks to that, and
    only the panel's own image validation settles it.

    BOTH GENERATIONS ARE ACCEPTED. A generation-1 file carries application images
    and nothing else: it cannot flash a blank board, and it is still a valid OTA
    payload that the person holding it may not be able to rebuild. Refusing it
    would break a feature that works over a file nobody can re-create.
    """
    if len(data) < BUNDLE_HEADER_BYTES:
        raise Fail(
            "not a firmware bundle: %d bytes is shorter than the %d-byte header"
            % (len(data), BUNDLE_HEADER_BYTES)
        )
    generation = BUNDLE_GENERATIONS.get(bytes(data[: len(BUNDLE_MAGIC)]))
    if generation is None:
        if data.startswith(b"ESPDISPFW"):
            # A future generation. Say which ones this tool reads, so an old tool
            # meeting a new file gives an answer someone can act on.
            raise Fail(
                "unsupported bundle generation %r; this tool reads %s"
                % (
                    data[: len(BUNDLE_MAGIC)].decode("ascii", "replace").strip(),
                    ", ".join(
                        repr(magic.decode("ascii").strip())
                        for magic in sorted(BUNDLE_GENERATIONS)
                    ),
                )
            )
        raise Fail("not a firmware bundle: it does not start with the ESPDISPFW2 magic")

    line = data[len(BUNDLE_MAGIC):BUNDLE_HEADER_BYTES]
    if not line.endswith(b"\n") or not line[:-1].isdigit():
        raise Fail(
            "bundle length line is not %d digits and a newline: %r"
            % (BUNDLE_LENGTH_DIGITS, line)
        )
    length = int(line[:-1])
    end = BUNDLE_HEADER_BYTES + length
    if end > len(data):
        raise Fail(
            "bundle claims a %d-byte manifest but only %d bytes follow the header; "
            "the file is truncated" % (length, len(data) - BUNDLE_HEADER_BYTES)
        )
    try:
        manifest = json.loads(data[BUNDLE_HEADER_BYTES:end].decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise Fail("bundle manifest is not valid UTF-8 JSON: %s" % exc)
    if not isinstance(manifest, dict):
        raise Fail(
            "bundle manifest is a %s, not a JSON object" % type(manifest).__name__
        )
    missing = [key for key in MANIFEST_KEYS if key not in manifest]
    if missing:
        raise Fail("bundle manifest is missing %s" % ", ".join(missing))
    # The magic and the manifest's own `format` have to agree. They are two
    # statements of the same fact, so a file where they differ is self-
    # contradictory whichever one is right, and guessing which to believe would
    # mean reading a generation-2 body as generation 1 or the reverse.
    if manifest["format"] != generation:
        raise Fail(
            "bundle manifest says format %r but its %s magic means format %d; "
            "this tool reads formats %s"
            % (
                manifest["format"],
                BUNDLE_MAGIC_V1.decode("ascii").strip()
                if generation == BUNDLE_FORMAT_V1
                else BUNDLE_MAGIC.decode("ascii").strip(),
                generation,
                " and ".join(str(v) for v in sorted(BUNDLE_GENERATIONS.values())),
            )
        )
    images = manifest["images"]
    if not isinstance(images, list) or not images:
        raise Fail("bundle manifest lists no images")

    payloads: Dict[str, bytes] = {}
    flash_payloads: Dict[str, Dict[str, bytes]] = {}
    cursor = end

    def take(entry: dict, label: str) -> bytes:
        """One payload, framed by the manifest's own offsets and hash-checked.

        Absolute offsets are what make this arithmetic rather than scanning, and
        what make the contiguity check possible: a payload that does not start
        exactly where the last one ended means the file has been truncated,
        concatenated or edited, whatever its hashes say.
        """
        nonlocal cursor
        offset, size = entry["offset"], entry["bytes"]
        if not is_whole_number(offset) or not is_whole_number(size) or offset < 0 or size <= 0:
            raise Fail(
                "%s has a nonsensical offset/bytes pair: %r/%r" % (label, offset, size)
            )
        if offset != cursor:
            raise Fail(
                "%s is listed at offset %d, but the payloads must run "
                "contiguously from %d in listed order" % (label, offset, cursor)
            )
        if offset + size > len(data):
            raise Fail(
                "%s runs to offset %d, past the end of a %d-byte file"
                % (label, offset + size, len(data))
            )
        blob = data[offset:offset + size]
        digest = sha256_hex(blob)
        if digest != entry["sha256"]:
            raise Fail(
                "%s hash mismatch: the manifest says sha256 %s, the payload "
                "hashes to %s. The file is damaged or was edited."
                % (label, str(entry["sha256"])[:16], digest[:16])
            )
        cursor += size
        return blob

    image_keys = IMAGE_KEYS if generation == BUNDLE_FORMAT_V1 else IMAGE_KEYS_V2
    for index, image in enumerate(images):
        where = "image %d" % index
        if not isinstance(image, dict):
            raise Fail("%s is a %s, not a JSON object" % (where, type(image).__name__))
        missing = [key for key in image_keys if key not in image]
        if missing:
            raise Fail("%s is missing %s" % (where, ", ".join(missing)))
        chip = image["chip"]
        if chip in payloads:
            raise Fail(
                "bundle lists %s twice; a reader could not tell which image to push"
                % chip
            )
        payloads[chip] = take(image, "%s (%s)" % (where, chip))
        if generation == BUNDLE_FORMAT_V1:
            continue

        # -- generation 2: the parts a board with nothing on it needs.
        address = image["app_address"]
        if not is_whole_number(address) or address < 0:
            raise Fail(
                "%s (%s) has a nonsensical app_address: %r" % (where, chip, address)
            )
        parts = image["flash_parts"]
        if not isinstance(parts, list) or not parts:
            raise Fail(
                "%s (%s) lists no flash parts; a generation-%d bundle carries the "
                "bootloader, partition table and boot_app0 a blank board needs"
                % (where, chip, BUNDLE_FORMAT)
            )
        roles: Dict[str, bytes] = {}
        writes = [(address, "the app")]
        for part_index, part in enumerate(parts):
            part_where = "%s (%s) flash part %d" % (where, chip, part_index)
            if not isinstance(part, dict):
                raise Fail(
                    "%s is a %s, not a JSON object" % (part_where, type(part).__name__)
                )
            absent = [key for key in FLASH_PART_KEYS if key not in part]
            if absent:
                raise Fail("%s is missing %s" % (part_where, ", ".join(absent)))
            role = part["role"]
            if not isinstance(role, str) or not role.strip():
                raise Fail("%s has no usable role: %r" % (part_where, role))
            if role in roles:
                raise Fail(
                    "%s (%s) lists the %s part twice; a reader could not tell which "
                    "one to write" % (where, chip, role)
                )
            part_address = part["address"]
            if not is_whole_number(part_address) or part_address < 0:
                raise Fail(
                    "%s (%s) %s has a nonsensical flash address: %r"
                    % (where, chip, role, part_address)
                )
            writes.append((part_address, role))
            roles[role] = take(part, "%s (%s) %s" % (where, chip, role))
        absent_roles = missing_flash_roles(roles)
        if absent_roles:
            raise Fail(
                "%s (%s) carries no %s, so it cannot bring up a board that has "
                "nothing on it" % (where, chip, ", ".join(absent_roles))
            )
        clash = conflicting_flash_address(writes)
        if clash:
            raise Fail(
                "%s (%s) writes both %s and %s to flash address 0x%x"
                % (where, chip, clash[1], clash[2], clash[0])
            )
        flash_payloads[chip] = roles

    if cursor != len(data):
        raise Fail(
            "bundle has %d bytes trailing after the last payload" % (len(data) - cursor)
        )
    return manifest, payloads, flash_payloads


def read_bundle(path: str) -> Tuple[dict, Dict[str, bytes], Dict[str, Dict[str, bytes]]]:
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        raise Fail("cannot read %s: %s" % (path, exc.strerror or exc))
    return unpack_bundle(data)


def write_file_atomically(path: str, data: bytes) -> None:
    """Write `path` in one step, through a sibling temp file and os.replace.

    A bundle is a couple of megabytes, and the app reading one has no way to tell
    a half-written file from a damaged one beyond the hashes refusing it. So an
    interrupted run must leave either the previous file or no file, never a
    partial one. The temp file is a sibling rather than in /tmp because os.replace
    is only atomic within a filesystem.
    """
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(
        dir=directory, prefix=os.path.basename(path) + ".", suffix=".partial"
    )
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def flash_address_hex(address) -> str:
    """A flash address the way esptool and the datasheets spell one."""
    if not is_whole_number(address):
        return str(address)
    return "0x%06x" % address


def describe_bundle(manifest: dict, full_hash: bool = False) -> List[str]:
    """The manifest as lines a person reads. Shared by `bundle` and `bundle-info`."""
    commit = manifest.get("source_commit")
    if commit:
        source = "%s%s" % (commit, " (dirty)" if manifest.get("source_dirty") else "")
    else:
        source = "unknown (not built from a git checkout)"
    lines = [
        "  version:  %s" % manifest.get("firmware_version"),
        "  built at: %s" % manifest.get("built_at"),
        "  source:   %s" % source,
        "  tool:     %s (format %s)" % (manifest.get("tool"), manifest.get("format")),
    ]
    for image in manifest.get("images") or []:
        digest = str(image.get("sha256", ""))
        lines.append(
            "  image:    %-3s %-8s %8d bytes  sha256 %s"
            % (
                image.get("board"),
                image.get("chip"),
                image.get("bytes", 0),
                digest if full_hash else digest[:16] + "...",
            )
        )
        if full_hash:
            lines.append("            %s from %s" % (image.get("filename"), image.get("fqbn")))
        # The flash parts, with the address each is written to, because that is
        # the whole content of the answer to "can this file bring up a blank
        # board" - and because a reader that hardcoded these addresses instead of
        # reading them would be wrong for the first board with a different map.
        parts = image.get("flash_parts")
        if not isinstance(parts, list) or not parts:
            lines.append(
                "            app only (format %s): enough for an over-the-air "
                "update, not for a board that has never been flashed"
                % manifest.get("format")
            )
            continue
        lines.append(
            "            app        -> %s" % flash_address_hex(image.get("app_address"))
        )
        for part in parts:
            if not isinstance(part, dict):
                continue
            part_digest = str(part.get("sha256", ""))
            lines.append(
                "            %-10s -> %s %8d bytes  sha256 %s"
                % (
                    part.get("role"),
                    flash_address_hex(part.get("address")),
                    part.get("bytes", 0),
                    part_digest if full_hash else part_digest[:16] + "...",
                )
            )
            if full_hash:
                lines.append("                          %s" % part.get("filename"))
    return lines


# --------------------------------------------------------------------------
# subcommands


def report_sizes(lines: List[str]) -> None:
    """Re-echo the size lines so partition headroom is visible without scrollback."""
    wanted = [
        ln.strip()
        for ln in lines
        if ln.startswith("Sketch uses") or ln.startswith("Global variables use")
    ]
    if not wanted:
        return
    print()
    for line in wanted:
        print(line)


def compile_board(board: Board, output_dir: Optional[str] = None) -> List[str]:
    if not os.path.isdir(SKETCH_DIR):
        raise Fail("sketch directory not found: %s" % SKETCH_DIR)
    cmd = [arduino_cli(), "compile", "-b", board.fqbn, "--libraries", LIBRARIES_DIR]
    if output_dir:
        # Only the OTA path needs the binaries copied out; USB upload re-derives
        # the same build directory from the sketch path.
        cmd += ["--output-dir", output_dir]
    return run_streaming(cmd + ["."], cwd=SKETCH_DIR)


def app_image(output_dir: str) -> str:
    """Pick the application image out of a --output-dir export.

    Deliberately narrow. That directory also holds <sketch>.ino.merged.bin, a
    whole-flash image with the bootloader and partition table in it - correct for
    esptool over USB, wrong for OTA, and 8MB of wrong at that. Only the bare
    <sketch>.ino.bin goes into an app slot.

    A BUNDLE STILL DOES NOT CARRY merged.bin, now that it carries the flash parts
    a blank board needs, and the measurements are why. platform.txt:183 pads it
    with `--pad-to-size {build.flash_size}`, so the C6 export's merged.bin is
    8388608 bytes and the S3's is 16777216 - both measured from a real export of
    this sketch, and both exactly the FlashSize in that board's FQBN. A two-board
    bundle would go from the 2290544 bytes it is today to roughly 24MB, of which
    some 22MB is padding. The individual parts cost 31984 bytes for the C6
    (bootloader 20720, partitions 3072, boot_app0 8192) and 31232 for the S3
    (bootloader 19968), all measured the same way. merged.bin also describes a
    whole-flash write, which would erase NVS - and NVS is where the WiFi
    credentials and the panel's name live, so flashing one board twice would wipe
    what the user configured after the first time.
    """
    candidates = [
        p
        for p in sorted(glob.glob(os.path.join(output_dir, "*.ino.bin")))
        if not p.endswith(".merged.bin")
    ]
    if len(candidates) != 1:
        raise Fail(
            "expected exactly one application image in %s, found %d"
            % (output_dir, len(candidates))
        )
    return candidates[0]


def export_binary(output_dir: str, suffix: str) -> str:
    """The one file in an export ending in `suffix`, or a refusal.

    Verified against a real `arduino-cli compile --output-dir` export rather than
    assumed: for this sketch it holds display_stream.ino.bin,
    display_stream.ino.bootloader.bin, display_stream.ino.partitions.bin,
    display_stream.ino.merged.bin, .elf and .map. Exactly one match is required
    because two would mean the directory has two builds in it and picking either
    would be picking at random.
    """
    candidates = sorted(glob.glob(os.path.join(output_dir, "*" + suffix)))
    if len(candidates) != 1:
        raise Fail(
            "expected exactly one *%s in %s, found %d"
            % (suffix, output_dir, len(candidates))
        )
    return candidates[0]


def read_binary(path: str) -> bytes:
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError as exc:
        raise Fail("cannot read %s: %s" % (path, exc.strerror or exc))


def collect_flash_parts(
    board: Board, output_dir: str
) -> Tuple[List[dict], Dict[str, bytes]]:
    """The three extra payloads a blank board needs, with their flash addresses.

    Two come out of the compile's export; boot_app0.bin comes out of the installed
    core, because that is where the core's own upload recipe gets it
    (platform.txt:346). Returns pre-offset manifest entries in write order and
    {role: bytes} - bundle_manifest fills the offsets in.
    """
    sources = [
        (
            FLASH_ROLE_BOOTLOADER,
            core_bootloader_address(board.chip),
            export_binary(output_dir, ".ino.bootloader.bin"),
        ),
        (
            FLASH_ROLE_PARTITIONS,
            PARTITIONS_FLASH_ADDRESS,
            export_binary(output_dir, ".ino.partitions.bin"),
        ),
        (FLASH_ROLE_BOOT_APP0, BOOT_APP0_FLASH_ADDRESS, core_boot_app0()),
    ]
    entries: List[dict] = []
    payloads: Dict[str, bytes] = {}
    for role, address, path in sources:
        blob = read_binary(path)
        if not blob:
            raise Fail("%s is empty, so there is nothing to write at 0x%x" % (path, address))
        entries.append(
            {
                "role": role,
                "address": address,
                "filename": os.path.basename(path),
                "bytes": len(blob),
                "sha256": sha256_hex(blob),
            }
        )
        payloads[role] = blob
    return entries, payloads


def check_password_policy(password: str) -> None:
    """Apply the firmware's own bounds to a password, in bytes.

    Mirrors otapolicy::verifyPassword: 8..64 BYTES of the decoded password, not
    characters, which is the same distinction the firmware draws - a 6-character
    passphrase of emoji is 24 bytes and fine, a 70-character ASCII one is refused.
    Applied here so `set-password` and `ota` fail immediately instead of after a
    round trip or a multi-minute compile.

    The firmware also refuses a 0x00 byte in the password. Not checked here: argv
    and the environment cannot carry one, so there is no way to reach this function
    with such a password and a check would be unreachable code.
    """
    length = len(password.encode("utf-8"))
    if length < OTA_PASSWORD_MIN:
        raise Fail(
            "OTA password is %d bytes; the panel requires at least %d (see "
            "CFGOTAPW)" % (length, OTA_PASSWORD_MIN)
        )
    if length > OTA_PASSWORD_MAX:
        raise Fail(
            "OTA password is %d bytes; the panel stores at most %d (see CFGOTAPW)"
            % (length, OTA_PASSWORD_MAX)
        )


def ota_password(explicit: Optional[str], prompt: str = "OTA password for the panel: ") -> str:
    """Resolve the OTA password without ever printing it.

    Three sources, in order: --password, the ESPDISP_OTA_PASSWORD environment
    variable, then an interactive prompt. Never a default and never a file in the
    repo - the panel's whole defence against a firmware push from anything else on
    the LAN is this one secret.
    """
    password = explicit or os.environ.get(OTA_PASSWORD_ENV) or ""
    if not password and sys.stdin.isatty():
        password = getpass.getpass(prompt)
    if not password:
        raise Fail(
            "no OTA password.\n"
            "  Pass --password, set %s, or run this from a terminal to be asked.\n"
            "  Set the panel's password with `%s set-password`."
            % (OTA_PASSWORD_ENV, os.path.basename(sys.argv[0]))
        )
    check_password_policy(password)
    return password


def cfgotapw_line(password: str) -> str:
    """The CFGOTAPW line that stores `password`, base64 encoding and all.

    This function exists because the encoding is a trap worth owning. The panel
    takes base64 (a password may contain any character a space-delimited line
    would eat) while espota takes the same password as characters, so the user had
    to produce both by hand - and the obvious `echo 'pw' | base64` appends a
    newline, which stores a password one byte longer than the one typed and then
    fails every push with OTA_AUTH_ERROR and no hint why. `printf %s` is correct
    and easy to forget. Encoding from the same string the push will use removes
    the mismatch instead of documenting it.
    """
    return "CFGOTAPW " + base64.b64encode(password.encode("utf-8")).decode("ascii")


def discovery_seconds(timeout: float) -> int:
    """Whole seconds to browse for, at least one.

    arduino-cli wants a duration string, so a fractional --discovery-timeout has
    to become an integer somewhere. Rounding to a 1s floor rather than truncating
    keeps `--discovery-timeout 0.4` a real (if brief) browse instead of a `0s`
    that finds nothing and reads as a silent skip.

    Nothing at or below 0 arrives here from the CLI: cmd_ota gates on `> 0`, so 0
    and every negative alike mean "do not check" and this path is not called. The
    floor is still defined over the whole domain, because it is the floor of a
    pure function rather than a restatement of that gate - a caller reaching this
    directly should get a browse, not a `0s` that cannot find anything.
    """
    return max(1, int(round(timeout)))


def discovery_command(seconds: int) -> List[str]:
    """Build the `arduino-cli board list` invocation used to find panels.

    Pure, for the same reason espota_command is: this is the one part of the
    target check with no other way to be tested. Everything downstream of it -
    parse_network_ports, network_port_for_host, classify_ota_target - is covered
    against a captured payload, but the command that produces that payload is
    stubbed out in those tests. And the failure is quiet by design: run_capture
    turns OSError and TimeoutExpired into a non-zero result, a non-zero result
    becomes [], and [] prints a note and pushes anyway. So a typo in this argv
    would not surface as an error, it would surface as a guard that stopped
    guarding. Asserting the argv is what catches that.
    """
    return [
        arduino_cli(),
        "board",
        "list",
        "--discovery-timeout",
        "%ds" % seconds,
        "--json",
    ]


def discovered_network_ports(timeout: float) -> List[NetworkPort]:
    """Ask arduino-cli to browse for OTA-capable panels on the LAN.

    Failure is not an error here: the caller treats an empty list as "could not
    confirm", so a machine with mDNS blocked still gets to push.
    """
    seconds = discovery_seconds(timeout)
    proc = run_capture(discovery_command(seconds), timeout=seconds + 30.0)
    if proc.returncode != 0:
        return []
    try:
        return parse_network_ports(json.loads(proc.stdout or "{}"))
    except json.JSONDecodeError:
        return []


def verify_ota_target(board: Board, host: str, timeout: float) -> None:
    """Cross-check --board against what the panel says it is, if it can be found.

    The USB path gets this guard for free twice over - arduino-cli's own board
    matching, then esptool's --chip refusal. Over the network there was nothing:
    --board was required and then believed. But the panel publishes `board=` in the
    `_arduino._tcp` TXT record espota already browses for, so the answer is
    available for the cost of one discovery pass.

    Refuses only a definite contradiction. A panel discovery cannot find, or one
    advertising a board this tool does not know, prints a note and continues -
    mDNS not answering is not evidence about the chip, and refusing on silence
    would break pushing to a panel on another subnet, which works today.

    UNVERIFIED: no panel has been discovered by this code. The parse is tested
    against captured JSON, but that arduino-cli reports these properties for this
    firmware's TXT records is read from mdns-discovery's source, not measured.
    """
    print("Checking what %s says it is..." % host, flush=True)
    found = network_port_for_host(discovered_network_ports(timeout), host)
    if found is None:
        print(
            "  Not found by mDNS discovery, so --board %s is taken on trust.\n"
            "  A wrong target is refused by the panel rather than breaking it, but\n"
            "  it costs a compile and a transfer." % board.key
        )
        return

    verdict = classify_ota_target(board, found.board)
    if verdict == TARGET_WRONG:
        other = board_key_for_chip(found.board) or found.board
        raise Fail(
            "%s advertises board=%s, but --board %s builds for %s.\n"
            "  Pushing this image would waste a compile and a transfer: the panel\n"
            "  validates the image header's chip id and would refuse it.\n"
            "  Re-run with --board %s." % (host, found.board, board.key, board.chip, other)
        )
    if verdict == TARGET_OK:
        print("  Confirmed: %s advertises board=%s." % (host, found.board))
    else:
        print(
            "  Found %s, but it advertises board=%r, which this tool cannot place.\n"
            "  Continuing with --board %s." % (host, found.board, board.key)
        )


def board_key_for_chip(chip: str) -> Optional[str]:
    """Map an esptool/variant chip id (esp32c6) onto a board key (c6)."""
    token = (chip or "").strip().lower()
    for board in BOARDS.values():
        if board.chip == token:
            return board.key
    return None


def espota_command(
    tool: str, host: str, port: int, password: str, image: str, timeout: int
) -> List[str]:
    """Build the espota.py invocation.

    Kept as a pure function so the command line can be checked without a panel to
    push to. Mirrors the core's own recipe (platform.txt line 384: `-i <address>
    -p <port> --auth=<password> -f <image>`), with -r for a progress bar and -t
    for how long to wait on the invitation.

    sys.executable rather than a bare `python3`: espota.py is stdlib-only, so the
    interpreter already running this script will do, and that is one fewer thing
    that has to be on PATH.
    """
    return [
        sys.executable,
        tool,
        "-r",
        "-i",
        host,
        "-p",
        str(port),
        "-a",
        password,
        "-f",
        image,
        "-t",
        str(timeout),
    ]


# --------------------------------------------------------------------------
# Tile-stream smoke test (CAP_TILE_STREAM firmware, phase 3 of
# docs/tile-stream-plan.md). Hand-built packets exercising every codec and
# the reassembler before the Mac app's encoder exists. The wire vectors are
# written from tile_protocol.h's format comment, independently of BOTH the
# firmware and Swift suites - a third side of the no-shared-fixture rule.

TILE_STREAM_FLAG = 0x8000
TILE_DIM = 16
TILE_PACKET_BUDGET = 1472
TILE_CODEC_RAW = 0
TILE_CODEC_RLE = 1
TILE_CODEC_BC1 = 2
# Half-resolution BC1: BC1 of a ceil(w/2) x ceil(h/2) raster, pixel-doubled by
# the panel. A quarter of BC1's bytes; requires CAP_TILE_HALFRES.
TILE_CODEC_HALF_BC1 = 3


def tile_header(frame_id: int, first_tile: int, dirty_count: int,
                landscape: bool = False) -> bytes:
    """The 6-byte tile packet header: [frame u16][first|0x8000 u16][dirty u16]."""
    count = dirty_count | (0x8000 if landscape else 0)
    return struct.pack("<HHH", frame_id, first_tile | TILE_STREAM_FLAG, count)


def tile_record(start_tile: int, run_len: int, codec: int,
                payload: bytes) -> bytes:
    """One record: [tile: bits 9..0 start, 14..10 runLen-1][len: 13..0 bytes, 15..14 codec]."""
    if not 1 <= run_len <= 32:
        raise Fail("run length %d out of range" % run_len)
    tile_field = start_tile | ((run_len - 1) << 10)
    len_field = len(payload) | (codec << 14)
    return struct.pack("<HH", tile_field, len_field) + payload


def rle565_flat(pixel: int, count: int) -> bytes:
    """RLE565-encode `count` copies of one RGB565 pixel: repeat runs of up to
    129 (control 0x80 + n - 2), a final single pixel as a 1-pixel literal."""
    hi, lo = pixel >> 8, pixel & 0xFF
    out = bytearray()
    while count > 0:
        n = min(count, 129)
        if n == 1:
            out += bytes([0x00, hi, lo])  # literal of one: runs need >= 2
        else:
            out += bytes([0x80 + n - 2, hi, lo])
        count -= n
    return bytes(out)


def raw_flat(pixel: int, pixels: int) -> bytes:
    """A flat raster as raw big-endian RGB565."""
    return bytes([pixel >> 8, pixel & 0xFF]) * pixels


def bc1_flat(pixel: int, w: int, h: int) -> bytes:
    """BC1-encode a flat w x h raster: every block is both endpoints = the
    color (u16 LE twice) and 16 zero indices."""
    block = struct.pack("<HH", pixel, pixel) + b"\x00" * 4
    return block * (((w + 3) // 4) * ((h + 3) // 4))


def tile_test_packets(frame_id: int, width: int = 466,
                      height: int = 466) -> list:
    """Datagrams for the smoke test: a full flat-striped keyframe (every
    tile-row one full-width RLE run, 900 dirty tiles) followed by a partial
    frame of distinct raw/BC1 squares including the 2x2 corner tile. Packed
    greedily to the datagram budget; a record never spans datagrams."""
    cols = (width + TILE_DIM - 1) // TILE_DIM
    rows = (height + TILE_DIM - 1) // TILE_DIM
    stripes = [0xF800, 0x07E0, 0x001F, 0xFFE0, 0x07FF, 0xF81F]  # r g b y c m

    def pack(records, dirty, fid):
        packets = []
        current = []
        size = 6
        first = None
        for start, rec in records:
            if size + len(rec) > TILE_PACKET_BUDGET and current:
                packets.append(tile_header(fid, first, dirty) + b"".join(current))
                current, size, first = [], 6, None
            if first is None:
                first = start
            current.append(rec)
            size += len(rec)
        if current:
            packets.append(tile_header(fid, first, dirty) + b"".join(current))
        return packets

    keyframe = []
    for r in range(rows):
        row_h = min(TILE_DIM, height - r * TILE_DIM)
        color = stripes[r % len(stripes)]
        payload = rle565_flat(color, width * row_h)
        keyframe.append((r * cols, tile_record(r * cols, cols, TILE_CODEC_RLE,
                                               payload)))
    packets = pack(keyframe, cols * rows, frame_id)

    # Partial frame: four 16x16 squares around center (raw and BC1) plus the
    # 2 px corner tile, proving edge-tile arithmetic end to end.
    squares = [
        (10 * cols + 10, TILE_CODEC_RAW, raw_flat(0xFFFF, 256)),      # white
        (10 * cols + 19, TILE_CODEC_RLE, rle565_flat(0x0000, 256)),   # black
        (19 * cols + 10, TILE_CODEC_BC1, bc1_flat(0xFFFF, 16, 16)),   # white
        (19 * cols + 19, TILE_CODEC_BC1, bc1_flat(0x0000, 16, 16)),   # black
        (cols * rows - 1, TILE_CODEC_RAW,
         raw_flat(0xF800, (width - (cols - 1) * TILE_DIM)
                  * (height - (rows - 1) * TILE_DIM))),               # corner
    ]
    partial = [(t, tile_record(t, 1, codec, payload))
               for t, codec, payload in squares]
    packets += pack(partial, len(partial), (frame_id + 1) & 0xFFFF)
    return packets


def tile_visibility(width: int = 466, height: int = 466,
                    tile_dim: int = TILE_DIM) -> dict:
    """Classify every tile of a round panel's grid against the inscribed circle.

    Returns {"outside": [...], "boundary": [...], "inside": [...]} of tile
    indices. A pixel (x, y) counts as visible when its CENTRE lies inside the
    circle of radius width/2 centred on the frame's middle. A tile is
    `outside` only when its nearest pixel to the centre is still outside (so
    every pixel of it is invisible - the tiles a round-aware sender may skip
    forever), `inside` when its farthest pixel is within, and `boundary`
    otherwise: partly visible, and therefore NOT skippable.

    Deliberately conservative in the one direction that matters: skipping a
    tile that turns out to be visible leaves it permanently stale, because
    keyframes would skip it too.
    """
    cx = width / 2.0
    cy = height / 2.0
    r2 = (width / 2.0) ** 2
    cols = (width + tile_dim - 1) // tile_dim
    rows = (height + tile_dim - 1) // tile_dim
    out = {"outside": [], "boundary": [], "inside": []}
    for ty in range(rows):
        for tx in range(cols):
            x0, y0 = tx * tile_dim, ty * tile_dim
            x1 = min(x0 + tile_dim, width)   # exclusive
            y1 = min(y0 + tile_dim, height)
            # Nearest and farthest pixel centres in each axis.
            nx = min(max(cx, x0 + 0.5), x1 - 0.5)
            ny = min(max(cy, y0 + 0.5), y1 - 0.5)
            fx = x0 + 0.5 if abs(x0 + 0.5 - cx) > abs(x1 - 0.5 - cx) else x1 - 0.5
            fy = y0 + 0.5 if abs(y0 + 0.5 - cy) > abs(y1 - 0.5 - cy) else y1 - 0.5
            tile = ty * cols + tx
            if (nx - cx) ** 2 + (ny - cy) ** 2 >= r2:
                out["outside"].append(tile)
            elif (fx - cx) ** 2 + (fy - cy) ** 2 < r2:
                out["inside"].append(tile)
            else:
                out["boundary"].append(tile)
    return out


def round_mask_packets(frame_id: int, width: int = 466,
                       height: int = 466) -> list:
    """A full keyframe that colour-codes the round-glass mask, for verifying
    it against real hardware BEFORE a sender relies on it.

    Every tile is sent - nothing is masked - so the panel paints the whole
    framebuffer. Tiles a round-aware sender WOULD skip are magenta; if any
    magenta is visible on the glass the mask is wrong and would leave those
    tiles permanently stale. Boundary tiles are green, so the mask's edge is
    visible as a ring and can be compared against the glass edge; fully
    visible tiles are dark grey.
    """
    classes = tile_visibility(width, height)
    colour = {}
    for tile in classes["outside"]:
        colour[tile] = 0xF81F   # magenta: must be invisible
    for tile in classes["boundary"]:
        colour[tile] = 0x07E0   # green: the mask's edge, partly visible
    for tile in classes["inside"]:
        colour[tile] = 0x2104   # dark grey: fully visible
    cols = (width + TILE_DIM - 1) // TILE_DIM
    rows = (height + TILE_DIM - 1) // TILE_DIM

    records = []
    for tile in range(cols * rows):
        tx, ty = tile % cols, tile // cols
        w = min(TILE_DIM, width - tx * TILE_DIM)
        h = min(TILE_DIM, height - ty * TILE_DIM)
        payload = rle565_flat(colour[tile], w * h)
        records.append((tile, tile_record(tile, 1, TILE_CODEC_RLE, payload)))

    packets = []
    current, size, first = [], 6, None
    for start, rec in records:
        if size + len(rec) > TILE_PACKET_BUDGET and current:
            packets.append(tile_header(frame_id, first, cols * rows)
                           + b"".join(current))
            current, size, first = [], 6, None
        if first is None:
            first = start
        current.append(rec)
        size += len(rec)
    if current:
        packets.append(tile_header(frame_id, first, cols * rows)
                       + b"".join(current))
    return packets


def bc1_noise_tile(seed: int, w: int, h: int) -> tuple:
    """A valid BC1 payload of noise for a w x h raster, and the next seed.

    Two endpoints plus pseudo-random 2-bit indices: exactly the 8 bytes per
    4x4 block the real encoder emits, so the wire cost and the panel's decode
    cost match a genuine photo/video tile. The picture is meaningless - this
    exists to measure throughput, not quality.
    """
    blocks = ((w + 3) // 4) * ((h + 3) // 4)
    out = bytearray()
    for _ in range(blocks):
        seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF
        c0 = (seed >> 16) & 0xFFFF
        seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF
        c1 = (seed >> 16) & 0xFFFF
        # BC1's 4-colour mode needs c0 >= c1, the same rule the encoders keep.
        if c0 < c1:
            c0, c1 = c1, c0
        seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF
        out += struct.pack("<HHI", c0, c1, seed)
    return bytes(out), seed


def half_dim(d: int) -> int:
    """ceil(d / 2) - the half-res rounding rule, matching tileproto::halfDim
    and TileProtocol.halfDim. Rounds UP so pixel-doubling always covers the
    run: a 2 px edge tile halves to 1 px, never to 0."""
    return (d + 1) // 2


def motion_frame_packets(frame_id: int, seed: int, width: int = 466,
                         height: int = 466, half: bool = False) -> tuple:
    """One full-frame update covering every VISIBLE tile, packed to the
    datagram budget. Returns (packets, next seed).

    Mirrors what the real sender emits for majority-of-screen motion: the
    round mask's 719 tiles rather than all 900, records packed greedily.
    `half` switches to codec 3 (half-resolution BC1), which is the same tile
    set at a quarter of the bytes - the comparison that tells you whether the
    half-res rung is worth what it costs in resolution.
    """
    classes = tile_visibility(width, height)
    hidden = set(classes["outside"])
    cols = (width + TILE_DIM - 1) // TILE_DIM
    rows = (height + TILE_DIM - 1) // TILE_DIM
    visible = [t for t in range(cols * rows) if t not in hidden]
    codec = TILE_CODEC_HALF_BC1 if half else TILE_CODEC_BC1

    records = []
    for tile in visible:
        tx, ty = tile % cols, tile // cols
        w = min(TILE_DIM, width - tx * TILE_DIM)
        h = min(TILE_DIM, height - ty * TILE_DIM)
        if half:
            payload, seed = bc1_noise_tile(seed, half_dim(w), half_dim(h))
        else:
            payload, seed = bc1_noise_tile(seed, w, h)
        records.append((tile, tile_record(tile, 1, codec, payload)))

    packets = []
    current, size, first = [], 6, None
    for start, rec in records:
        if size + len(rec) > TILE_PACKET_BUDGET and current:
            packets.append(tile_header(frame_id, first, len(visible))
                           + b"".join(current))
            current, size, first = [], 6, None
        if first is None:
            first = start
        current.append(rec)
        size += len(rec)
    if current:
        packets.append(tile_header(frame_id, first, len(visible))
                       + b"".join(current))
    return packets, seed


def cmd_tile_motion(args) -> int:
    """Stream synthetic full-frame BC1 updates and report the offered rate.

    The measurement docs/tile-stream-plan.md section 10 asked for and never
    got: majority-of-screen motion, deterministic and independent of whatever
    happens to be on the Mac's screen. Read the panel's own `frames=` delta
    from the 5-second serial stats line for the ACHIEVED rate; this prints
    only what was offered.
    """
    # Pre-build a small rotation of frames: encoding 719 BC1 tiles in Python
    # is far slower than the wire, so building them inside the send loop
    # would measure Python instead of the panel.
    print("building frames...", flush=True)
    seed = 0xC0FFEE
    prebuilt = []
    for i in range(args.distinct_frames):
        packets, seed = motion_frame_packets(i + 1, seed, half=args.half)
        prebuilt.append(packets)
    per_frame = len(prebuilt[0])
    frame_bytes = sum(len(p) for p in prebuilt[0])
    print("%d datagrams/frame, %d bytes/frame (719 visible tiles, %s)"
          % (per_frame, frame_bytes,
             "half-res BC1 (codec 3)" if args.half else "BC1"))
    print("offering %d fps for %.0fs -> %d datagrams/s"
          % (args.target_fps, args.seconds, args.target_fps * per_frame))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    # Bind and read the panel's own EHB1 heartbeats here rather than from a
    # separate watcher: the panel replies to whoever sent it a packet LAST,
    # and this flood wins that race continuously, so any other listener would
    # see almost nothing. Reading them here also makes the offered and
    # achieved rates one self-contained measurement, with no serial cable in
    # the loop - which matters because the USB CDC on this board drops out.
    sock.bind(("", 0))
    sock.setblocking(False)
    spacing = 1.0 / (args.target_fps * per_frame)
    frame_id = 1
    sent_frames = 0
    sent_packets = 0
    first_hb = None
    first_hb_at = None
    last_hb = None
    last_hb_at = None

    def drain_heartbeats():
        nonlocal first_hb, first_hb_at, last_hb, last_hb_at
        while True:
            try:
                data, _ = sock.recvfrom(2048)
            except (BlockingIOError, OSError):
                return
            if len(data) != 24 or data[:4] != b"EHB1":
                continue
            stats = struct.unpack("<IIIII", data[4:24])
            if first_hb is None:
                first_hb, first_hb_at = stats, time.time()
            last_hb, last_hb_at = stats, time.time()

    start = time.time()
    deadline = start + args.seconds
    next_due = start
    while time.time() < deadline:
        for packet in prebuilt[sent_frames % len(prebuilt)]:
            # Rewrite the frame id so the panel treats each pass as a new
            # frame rather than a duplicate its reassembler would ignore.
            body = bytes([frame_id & 0xFF, (frame_id >> 8) & 0xFF]) + packet[2:]
            sock.sendto(body, (args.host, 5568))
            sent_packets += 1
            next_due += spacing
            delay = next_due - time.time()
            if delay > 0:
                time.sleep(delay)
        sent_frames += 1
        frame_id = (frame_id + 1) & 0xFFFF
        drain_heartbeats()
    elapsed = time.time() - start
    print("offered %d frames (%d datagrams) in %.1fs -> %.1f fps, %.0f dgram/s"
          % (sent_frames, sent_packets, elapsed, sent_frames / elapsed,
             sent_packets / elapsed))

    if first_hb is None or last_hb is None or last_hb_at == first_hb_at:
        print("no heartbeat window captured - cannot report the achieved rate")
        return 0
    span = last_hb_at - first_hb_at
    shown = last_hb[0] - first_hb[0]
    dropped = last_hb[1] - first_hb[1]
    packets = last_hb[3] - first_hb[3]
    partial = last_hb[2] - first_hb[2]
    total = shown + dropped
    # `shown` is COMPLETE frames; `partial` counts draw passes that painted an
    # incomplete frame because the panel stopped waiting for the rest. Firmware
    # predating that split reports 0 partials and folds them into shown, which
    # inflates it - see docs/tile-stream-plan.md section 17.5.
    print("ACHIEVED over %.1fs: %.1f fps complete, %.1f/s partial draws, "
          "%.0f datagrams/s accepted, %d dropped frames (%.1f%%)"
          % (span, shown / span, partial / span, packets / span, dropped,
             100.0 * dropped / total if total else 0.0))
    return 0


def cmd_tile_test(args) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.round_mask:
        classes = tile_visibility()
        total = sum(len(v) for v in classes.values())
        print("round-glass mask over a %d-tile grid:" % total)
        print("  %d skippable (magenta - MUST be invisible)"
              % len(classes["outside"]))
        print("  %d boundary  (green - the mask edge, partly visible)"
              % len(classes["boundary"]))
        print("  %d interior  (dark grey)" % len(classes["inside"]))
        # Re-send on a timer: the panel shows its idle card a few tens of
        # seconds after the last packet, which would paint over the pattern
        # while it is being inspected.
        deadline = time.time() + args.hold
        frame = args.frame_id
        rounds = 0
        while True:
            for packet in round_mask_packets(frame):
                sock.sendto(packet, (args.host, 5568))
                time.sleep(0.004)
            rounds += 1
            frame = (frame + 1) & 0xFFFF
            if time.time() >= deadline:
                break
            time.sleep(1.5)
        print("\nheld the pattern for %.0fs (%d repaints)" % (args.hold, rounds))
        print("PASS if no magenta is visible anywhere on the glass.")
        print("The green ring is the mask's outermost kept tiles; it may be")
        print("partly cut off by the glass edge - that is expected and safe.")
        return 0

    packets = tile_test_packets(args.frame_id)
    sent = 0
    for i, packet in enumerate(packets):
        sock.sendto(packet, (args.host, 5568))
        sent += len(packet)
        # The keyframe is everything but the last packet; give the panel a
        # beat to complete and draw it before the partial frame lands.
        time.sleep(0.25 if i == len(packets) - 2 else 0.005)
    print("sent %d tile-stream datagrams (%d bytes) to %s" %
          (len(packets), sent, args.host))
    print("expect: colored horizontal stripes, then white/black squares "
          "mid-panel; frames= should rise by 2 with badlen= unchanged")
    return 0


def cmd_compile(args) -> int:
    board = resolve_board(args.board, None)
    report_sizes(compile_board(board))
    return 0


def cmd_flash(args) -> int:
    # Port first: with no board attached this is where the run should stop,
    # before spending minutes on a compile.
    port = resolve_port(args.port)
    board = resolve_board(args.board, port)
    print("Target: %s (%s) on %s" % (board.key, board.fqbn, port.address), flush=True)
    lines = compile_board(board)
    run_streaming(
        [arduino_cli(), "upload", "-b", board.fqbn, "-p", port.address, "."],
        cwd=SKETCH_DIR,
    )
    report_sizes(lines)

    # For S3 board: also flash the Doom WAD if present (or download it)
    if board.key == "s3":
        _flash_doom_wad_if_available(port.address)

    return 0


# WAD auto-download and flash for the Doom Easter Egg (S3 only)
_DOOM_WAD_PATH = os.path.join(REPO_ROOT, "firmware", "doom", "doom1.wad")
_DOOM_WAD_URL = "https://distro.ibiblio.org/slitaz/sources/packages/d/doom1.wad"
_DOOM_WAD_SIZE = 4196020  # doom1.wad v1.9 is exactly this many bytes
_DOOM_WAD_PARTITION_OFFSET = 0xC00000


def _ensure_doom_wad() -> Optional[str]:
    """Return the path to doom1.wad, downloading if needed. None on failure."""
    if os.path.isfile(_DOOM_WAD_PATH):
        size = os.path.getsize(_DOOM_WAD_PATH)
        if size == _DOOM_WAD_SIZE:
            return _DOOM_WAD_PATH
        print("  doom1.wad exists but is %d bytes (expected %d), re-downloading..."
              % (size, _DOOM_WAD_SIZE))

    print("  Downloading doom1.wad (shareware, 4.0 MB)...", flush=True)
    try:
        import urllib.request
        urllib.request.urlretrieve(_DOOM_WAD_URL, _DOOM_WAD_PATH)
    except Exception as e:
        print("  Download failed: %s" % e, file=sys.stderr)
        print("  Doom Easter Egg will not be available until doom1.wad is flashed.")
        print("  Manual download: curl -L -o firmware/doom/doom1.wad '%s'" % _DOOM_WAD_URL)
        return None

    # Verify
    size = os.path.getsize(_DOOM_WAD_PATH)
    if size != _DOOM_WAD_SIZE:
        print("  WARNING: downloaded WAD is %d bytes (expected %d)" % (size, _DOOM_WAD_SIZE))
    # Verify magic
    with open(_DOOM_WAD_PATH, "rb") as f:
        magic = f.read(4)
    if magic != b"IWAD":
        print("  WARNING: file does not start with IWAD magic", file=sys.stderr)
        os.unlink(_DOOM_WAD_PATH)
        return None

    print("  doom1.wad ready (%d bytes)" % size)
    return _DOOM_WAD_PATH


def _flash_doom_wad_if_available(port_address: str) -> None:
    """Flash the Doom WAD to the S3 board's dedicated partition."""
    print("\n--- Doom Easter Egg ---")
    wad_path = _ensure_doom_wad()
    if not wad_path:
        return

    tool = esptool_path()
    if not tool:
        print("  esptool not found, skipping WAD flash")
        return

    print("  Flashing doom1.wad to partition at 0x%06X..." % _DOOM_WAD_PARTITION_OFFSET,
          flush=True)
    cmd = [
        tool,
        "--chip", "esp32s3",
        "--port", port_address,
        "--baud", "921600",
        "--no-stub",  # faster for data-only writes
        "write_flash",
        "0x%X" % _DOOM_WAD_PARTITION_OFFSET,
        wad_path,
    ]
    try:
        run_streaming(cmd)
        print("  Doom Easter Egg ready! Triple-tap BOOT to play.")
    except Exception as e:
        print("  WAD flash failed: %s" % e, file=sys.stderr)
        print("  Firmware is fine. Run 'espdisp.py flash-wad' to retry the WAD.")


def cmd_ota(args) -> int:
    # Password first: it is the one thing that can fail instantly, and finding out
    # after a multi-minute compile would be irritating.
    password = ota_password(args.password)
    tool = espota_path()
    board = BOARDS[args.board]
    print("Target: %s (%s) over the air at %s" % (board.key, board.fqbn, args.host))
    # Before the compile, so a wrong --board costs seconds instead of minutes.
    if args.discovery_timeout > 0:
        verify_ota_target(board, args.host, args.discovery_timeout)

    out_dir = tempfile.mkdtemp(prefix="espdisp-ota-")
    try:
        lines = compile_board(board, output_dir=out_dir)
        image = app_image(out_dir)
        print(
            "\nPushing %s (%d bytes) to %s:%d"
            % (os.path.basename(image), os.path.getsize(image), args.host, args.ota_port),
            flush=True,
        )
        run_streaming(
            espota_command(tool, args.host, args.ota_port, password, image, args.timeout),
            redact=password,
        )
        report_sizes(lines)
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)
    print("\nThe panel reboots itself onto the new firmware.")
    return 0


def cmd_bundle(args) -> int:
    # Version first, before any compile: it is read from the sketch and can fail
    # instantly, and finding out after two multi-minute builds would be
    # irritating. Same ordering, and the same reason, as cmd_ota's password.
    version = sketch_fw_version()
    keys = list(dict.fromkeys(args.board or sorted(BOARDS)))  # dedupe, keep order
    boards = [BOARDS[key] for key in keys]
    path = args.output or os.path.join(
        os.getcwd(), "espdisp-firmware-%s%s" % (version, BUNDLE_SUFFIX)
    )
    commit, dirty = git_provenance()
    print("Firmware %s (FW_VERSION in %s)" % (version, os.path.relpath(SKETCH_INO, REPO_ROOT)))
    print("Building: %s" % ", ".join(board.key for board in boards), flush=True)

    entries: List[dict] = []
    payloads: Dict[str, bytes] = {}
    flash_payloads: Dict[str, Dict[str, bytes]] = {}
    size_lines: List[str] = []
    out_dirs: List[str] = []
    try:
        for board in boards:
            out_dir = tempfile.mkdtemp(prefix="espdisp-bundle-%s-" % board.key)
            out_dirs.append(out_dir)
            size_lines += compile_board(board, output_dir=out_dir)
            image = app_image(out_dir)
            blob = read_binary(image)
            parts, part_payloads = collect_flash_parts(board, out_dir)
            entries.append(
                {
                    "board": board.key,
                    "chip": board.chip,
                    "fqbn": board.fqbn,
                    "filename": os.path.basename(image),
                    "bytes": len(blob),
                    "sha256": sha256_hex(blob),
                    # Where the app goes over USB. In the manifest rather than in
                    # the reader for the same reason as the bootloader address:
                    # 0x10000 is what this repo's partition table says, and the
                    # table travels in the same file, so the two cannot drift.
                    "app_address": APP_FLASH_ADDRESS,
                    "flash_parts": parts,
                }
            )
            payloads[board.chip] = blob
            flash_payloads[board.chip] = part_payloads
    finally:
        # Same shape as cmd_ota: the export directories go whatever happens, so an
        # interrupted build does not leave two megabytes per board in /tmp.
        for out_dir in out_dirs:
            shutil.rmtree(out_dir, ignore_errors=True)

    manifest = bundle_manifest(version, entries, utc_timestamp(), commit, dirty)
    data = pack_bundle(manifest, payloads, flash_payloads)
    write_file_atomically(path, data)

    report_sizes(size_lines)
    print("\nWrote %s" % path)
    print("  size:     %d bytes (%.1f MiB)" % (len(data), len(data) / (1024.0 * 1024.0)))
    for line in describe_bundle(manifest):
        print(line)

    absent = [board for board in BOARDS.values() if board.chip not in payloads]
    if absent:
        print(
            "\nThis bundle carries %d of %d images: nothing in it is for %s. The app\n"
            "  will have nothing to offer such a panel - it can only push an image the\n"
            "  file actually contains. Build without --board, or add %s, if\n"
            "  those panels need this version too."
            % (
                len(payloads),
                len(BOARDS),
                " or ".join(board.chip for board in absent),
                " ".join("--board %s" % board.key for board in absent),
            )
        )
    print(
        "\nHand this file to the Mac app (or to `%s bundle-info` first)."
        % os.path.basename(sys.argv[0])
    )
    return 0


def cmd_bundle_info(args) -> int:
    manifest, payloads, flash_payloads = read_bundle(args.path)
    size = os.path.getsize(args.path)
    print("%s" % args.path)
    print("  size:     %d bytes (%.1f MiB)" % (size, size / (1024.0 * 1024.0)))
    for line in describe_bundle(manifest, full_hash=True):
        print(line)
    # unpack_bundle already refused anything that did not add up, so reaching here
    # is the verification result: say so, rather than leaving the user to infer it
    # from the absence of an error.
    extra = sum(len(roles) for roles in flash_payloads.values())
    print(
        "\nVerified: %d image%s%s, contiguous, every sha256 matches."
        % (
            len(payloads),
            "" if len(payloads) == 1 else "s",
            "" if not extra else " plus %d flash part%s" % (extra, "" if extra == 1 else "s"),
        )
    )
    # What the file can and cannot be used for, said rather than implied. A
    # generation-1 bundle is not broken and this is not a warning about damage: it
    # is the one thing about such a file a user cannot see from the listing.
    if flash_payloads:
        print(
            "Can bring up a board that has never been flashed: carries the "
            "bootloader, partition table and boot_app0 for %s."
            % ", ".join(sorted(flash_payloads))
        )
    else:
        print(
            "Over-the-air updates only. This is a format %s bundle, so it carries no\n"
            "  bootloader, partition table or boot_app0 and cannot bring up a board "
            "that\n  has never been flashed. Rebuild it with `%s bundle` for that."
            % (manifest.get("format"), os.path.basename(sys.argv[0]))
        )
    known = [chip for chip in payloads if board_key_for_chip(chip)]
    if len(known) < len(BOARDS):
        print(
            "Carries %s. A panel running anything else finds nothing to install here."
            % ", ".join(sorted(payloads))
        )
    return 0


def cmd_set_password(args) -> int:
    # Password first, port second: a password the panel would refuse can be caught
    # instantly, and finding that out after the port hunt (or after typing it into
    # a prompt twice) is the wrong order. Same reasoning as cmd_ota.
    if args.clear:
        line = "CFGOTAPW clear"
        shown = "-> CFGOTAPW clear (this turns OTA off)"
    else:
        password = ota_password(args.password, prompt="New OTA password for the panel: ")
        line = cfgotapw_line(password)
        # The command, never the argument: the base64 is the password.
        shown = "-> CFGOTAPW <base64 password, %d bytes>" % len(
            password.encode("utf-8"))
    port = resolve_port(args.port)
    print(shown, flush=True)
    reply = send_config_line(port.address, line, args.timeout)
    print(reply)
    if reply.startswith("CFGOK"):
        print("\nThe panel reboots. Use the same password with `ota`:")
        print("  export %s='<the password>'" % OTA_PASSWORD_ENV)
        return 0
    return 1


def cmd_list(args) -> int:
    ports = detected_ports()
    candidates = [p for p in ports if fnmatch.fnmatch(p.address, PORT_GLOB)]
    if not candidates:
        print("No candidate ESP32 ports (looked for %s)." % PORT_GLOB)
    else:
        print("Candidate ESP32 ports:")
        for port in candidates:
            if len(port.board_keys) == 1:
                chip = "%s (reported by arduino-cli)" % port.board_keys[0]
            elif port.board_keys:
                chip = "ambiguous: %s" % ", ".join(port.board_keys)
            elif args.probe:
                key = probe_chip(port.address)
                chip = key if key else "unknown (probe failed)"
            else:
                chip = "unknown (pass --probe to ask esptool)"
            print("  %-32s %s" % (port.address, chip))

    others = [p for p in ports if p not in candidates]
    if others:
        print("\nOther serial ports (ignored):")
        for port in others:
            print("  %s" % port.address)
    return 0


def cmd_config(args) -> int:
    port = resolve_port(args.port)
    line = " ".join(args.words)
    print("-> %s" % line, flush=True)
    reply = send_config_line(port.address, line, args.timeout)
    print(reply)
    return 0 if reply.startswith(("CFGOK", "CFGINFO")) else 1


# --------------------------------------------------------------------------


def board_help() -> str:
    return "\n".join("  %-3s %s" % (b.key, b.blurb) for b in BOARDS.values())


def cmd_flash_wad(args) -> int:
    """Write a Doom WAD file to the S3 board's dedicated flash partition."""
    wad_path = args.wad if args.wad else _DOOM_WAD_PATH

    # Auto-download if path points to the default location and file is missing
    if wad_path == _DOOM_WAD_PATH and not os.path.isfile(wad_path):
        wad_path = _ensure_doom_wad()
        if not wad_path:
            raise Fail("Could not obtain doom1.wad")
    elif not os.path.isfile(wad_path):
        raise Fail("WAD file not found: %s" % wad_path)

    wad_size = os.path.getsize(wad_path)
    WAD_PARTITION_OFFSET = _DOOM_WAD_PARTITION_OFFSET
    WAD_PARTITION_SIZE = 0x400000  # 4MB

    if wad_size > WAD_PARTITION_SIZE:
        raise Fail(
            "WAD file too large: %d bytes (partition is %d bytes / %d MB)"
            % (wad_size, WAD_PARTITION_SIZE, WAD_PARTITION_SIZE // (1024 * 1024))
        )

    # Verify it looks like a WAD
    with open(wad_path, "rb") as f:
        magic = f.read(4)
    if magic not in (b"IWAD", b"PWAD"):
        raise Fail(
            "Not a valid WAD file (magic: %s, expected IWAD or PWAD)" % magic.hex()
        )

    port = resolve_port(args.port)
    tool = esptool_path()
    if not tool:
        raise Fail("esptool not found (install the esp32 Arduino core)")

    print(
        "Flashing WAD: %s (%d bytes / %.1f MB) to partition at 0x%06X on %s"
        % (os.path.basename(wad_path), wad_size, wad_size / (1024 * 1024),
           WAD_PARTITION_OFFSET, port.address)
    )
    print("This will take a moment (writing %.1f MB to flash)..." % (wad_size / (1024 * 1024)))

    cmd = [
        tool,
        "--chip", "esp32s3",
        "--port", port.address,
        "--baud", "921600",
        "write_flash",
        "0x%X" % WAD_PARTITION_OFFSET,
        wad_path,
    ]
    run_streaming(cmd)
    print("\nWAD flashed successfully. The Doom Easter Egg is ready!")
    print("Triple-tap BOOT to play.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="espdisp.py",
        description=__doc__,
        epilog="boards:\n" + board_help(),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # New subcommands plug in as another add_parser block plus one entry in the
    # board table if they need one.
    subs = parser.add_subparsers(dest="command", metavar="<command>")

    p_compile = subs.add_parser("compile", help="build the firmware for one board")
    p_compile.add_argument("--board", required=True, choices=sorted(BOARDS))
    p_compile.set_defaults(func=cmd_compile)

    p_flash = subs.add_parser("flash", help="build then upload over USB")
    p_flash.add_argument(
        "--board",
        choices=sorted(BOARDS),
        help="skip chip detection and build this target",
    )
    p_flash.add_argument("--port", help="serial device (default: the one %s match)" % PORT_GLOB)
    p_flash.set_defaults(func=cmd_flash)

    p_ota = subs.add_parser(
        "ota",
        help="build then push over WiFi to a panel with OTA enabled",
        description="Push firmware over the air. The panel must have an OTA "
        "password set (`config CFGOTAPW <base64 password>` over USB, once) - "
        "without one it does not listen at all. USB flashing stays the recovery "
        "route and always works.",
        epilog="The password comes from --password, else $%s, else a prompt.\n"
        "It is never echoed, but espota.py takes it as an argument, so on a\n"
        "shared machine it is briefly visible in `ps`." % OTA_PASSWORD_ENV,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p_ota.add_argument("host", help="panel address: an IP, or its mDNS name (panel.local)")
    p_ota.add_argument(
        "--board",
        required=True,
        choices=sorted(BOARDS),
        help="which target to build; required because there is no chip to probe "
        "over the network. A wrong-target push is refused by the panel's own "
        "image validation, not fatal to it, but it wastes a compile",
    )
    p_ota.add_argument("--password", help="OTA password (prefer $%s)" % OTA_PASSWORD_ENV)
    p_ota.add_argument(
        "--ota-port", type=int, default=OTA_PORT, help="panel OTA port (default %d)" % OTA_PORT
    )
    p_ota.add_argument(
        "--timeout",
        type=int,
        default=10,
        help="seconds to wait for each invitation attempt (default 10, 10 attempts)",
    )
    p_ota.add_argument(
        "--discovery-timeout",
        type=float,
        default=5.0,
        help="seconds to browse mDNS for the panel to cross-check --board "
        "(default 5; 0 or less skips the check entirely, leaving the panel itself "
        "as the only thing that will refuse a wrong-chip image)",
    )
    p_ota.set_defaults(func=cmd_ota)

    p_bundle = subs.add_parser(
        "bundle",
        help="compile and pack the firmware into one portable %s file" % BUNDLE_SUFFIX,
        description="Build the firmware and write it into a single file the Mac "
        "app can open later - on this machine or on another one, with no copy of "
        "this repo and no arduino-cli in sight. The file carries, per board, the "
        "application image plus the bootloader, partition table and boot_app0 a "
        "board that has never been flashed needs, each with the flash address it "
        "is written to, and a manifest naming the firmware version, when it was "
        "built, which commit it came from and the sha256 of every payload. Nothing "
        "is pushed: `bundle` only writes the file, and `ota` is still the way to "
        "push from here.",
        epilog="The version is read out of the sketch (FW_VERSION in\n"
        "firmware/display_stream/display_stream.ino), never passed in, so the\n"
        "manifest cannot disagree with the images beside it.\n"
        "Inspect a file with `bundle-info`.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p_bundle.add_argument(
        "--board",
        action="append",
        choices=sorted(BOARDS),
        help="build only this board; repeatable. Default is every board, because a "
        "file with one image has nothing to offer a panel of the other chip",
    )
    p_bundle.add_argument(
        "--output",
        help="where to write the bundle (default ./espdisp-firmware-<version>%s)"
        % BUNDLE_SUFFIX,
    )
    p_bundle.set_defaults(func=cmd_bundle)

    p_bundle_info = subs.add_parser(
        "bundle-info",
        help="verify a %s file and print what is in it" % BUNDLE_SUFFIX,
        description="Read a firmware bundle, check it (magic, manifest, offsets "
        "and the sha256 of every payload) and print what it holds, including "
        "whether it can bring up a board that has never been flashed. Run this "
        "before handing a file to someone, and on a file someone handed you.",
    )
    p_bundle_info.add_argument("path", help="the %s file to inspect" % BUNDLE_SUFFIX)
    p_bundle_info.set_defaults(func=cmd_bundle_info)

    p_pw = subs.add_parser(
        "set-password",
        help="set or clear the panel's OTA password over USB",
        description="Store the OTA password on a panel over USB, base64 encoding "
        "it on the way. Nothing listens for a push until this is done, and "
        "`--clear` turns OTA off again. The encoding is the point: the panel takes "
        "base64 while the pusher takes the password as characters, and the obvious "
        "`echo pw | base64` silently appends a newline, storing a password that "
        "then fails every push with an auth error.",
        epilog="The password comes from --password, else $%s, else a prompt.\n"
        "It is never printed, and neither is its base64." % OTA_PASSWORD_ENV,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p_pw.add_argument("--password", help="the new password (prefer the prompt)")
    p_pw.add_argument(
        "--clear", action="store_true", help="forget the password, turning OTA off"
    )
    p_pw.add_argument("--port", help="serial device (default: autodetected)")
    p_pw.add_argument("--timeout", type=float, default=6.0, help="reply timeout (s)")
    p_pw.set_defaults(func=cmd_set_password)

    p_tile = subs.add_parser(
        "tile-test",
        help="send hand-built tile-stream packets to a CAP_TILE_STREAM panel",
    )
    p_tile.add_argument("host", help="panel IP address")
    p_tile.add_argument(
        "--frame-id", type=int, default=1,
        help="starting frame id (bump between runs so frames are not stale)",
    )
    p_tile.add_argument(
        "--round-mask", action="store_true",
        help="paint the round-glass mask instead: tiles a round-aware sender "
             "would skip are magenta and must be invisible on the glass",
    )
    p_tile.add_argument(
        "--hold", type=float, default=30.0,
        help="seconds to keep repainting the round-mask pattern (default 30)",
    )
    p_tile.set_defaults(func=cmd_tile_test)

    p_motion = subs.add_parser(
        "tile-motion",
        help="stream synthetic full-frame BC1 updates to measure the "
             "majority-of-screen-motion ceiling",
    )
    p_motion.add_argument("host", help="panel IP address")
    p_motion.add_argument("--seconds", type=float, default=20.0)
    p_motion.add_argument(
        "--target-fps", type=int, default=45,
        help="full frames per second to offer (default 45, the paint ceiling)",
    )
    p_motion.add_argument(
        "--distinct-frames", type=int, default=4,
        help="how many distinct frames to pre-build and cycle through",
    )
    p_motion.add_argument(
        "--half", action="store_true",
        help="use half-resolution BC1 (codec 3): the same 719 tiles at a "
             "quarter of the bytes, ~17 datagrams/frame instead of 66. "
             "Needs firmware advertising CAP_TILE_HALFRES",
    )
    p_motion.set_defaults(func=cmd_tile_motion)

    p_list = subs.add_parser("list", help="show the ports and chips this tool can see")
    p_list.add_argument(
        "--probe",
        action="store_true",
        help="ask esptool for the chip type (resets each board it probes)",
    )
    p_list.set_defaults(func=cmd_list)

    p_config = subs.add_parser(
        "config",
        help="send one CFG* line over USB and print the reply",
        description="Send one config line, e.g. `config CFGSHOW` or "
        "`config CFGNAME Desk Panel`. Same protocol as tools/serial_cmd.py.",
    )
    p_config.add_argument("--port", help="serial device (default: autodetected)")
    p_config.add_argument("--timeout", type=float, default=6.0, help="reply timeout (s)")
    p_config.add_argument("words", nargs="+", metavar="CFG...")
    p_config.set_defaults(func=cmd_config)

    p_wad = subs.add_parser(
        "flash-wad",
        help="write a doom1.wad file to the S3 board's WAD partition",
        description="Writes a Doom WAD file (typically doom1.wad, the shareware "
        "version) to the dedicated flash partition on the ESP32-S3 board. The "
        "partition is at offset 0xC00000 and is 4MB (4,194,304 bytes). The WAD "
        "file must be <= 4MB. The S3 custom partition table "
        "(firmware/partitions_s3_doom.csv) must be flashed first. If no WAD "
        "path is given, auto-downloads the shareware doom1.wad.",
    )
    p_wad.add_argument("wad", nargs="?", default=None,
                       help="path to WAD file (default: auto-download doom1.wad)")
    p_wad.add_argument("--port", help="serial device (default: autodetected)")
    p_wad.set_defaults(func=cmd_flash_wad)

    return parser


def main(argv: List[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 2
    try:
        return args.func(args)
    except Fail as exc:
        print("espdisp: %s" % exc, file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\nespdisp: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
