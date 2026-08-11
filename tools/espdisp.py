#!/usr/bin/env python3
"""Build, flash, update, and configure the esp32-display firmware without hand-typing FQBNs."""
import argparse
import base64
import fnmatch
import getpass
import glob
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import time
from typing import List, NamedTuple, Optional


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


def probe_chip(address: str) -> Optional[str]:
    """Ask the bundled esptool which chip is on `address`.

    Returns a board key, or None if the chip could not be determined.
    UNVERIFIED against hardware: no board was attached when this was written,
    so only the failure path has been exercised. The parse accepts both the
    "Chip is ESP32-C6" and "Detecting chip type... ESP32-C6" spellings esptool
    uses.
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
    return 0


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
