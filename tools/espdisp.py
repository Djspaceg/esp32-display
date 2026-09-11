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


class Platform(NamedTuple):
    """Chip/toolchain facts shared by every carrier using this processor."""

    key: str
    chip: str
    fqbn: str
    bootloader_address: int


PLATFORMS = {
    "c6": Platform(
        "c6", "esp32c6",
        "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M", 0x0),
    "s3": Platform(
        "s3", "esp32s3",
        "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=8M,PSRAM=opi,"
        "PartitionScheme=custom",
        0x0),
    "p4": Platform(
        "p4", "esp32p4",
        "esp32:esp32:esp32p4:USBMode=default,CDCOnBoot=default,"
        "UploadMode=default,FlashSize=32M,PartitionScheme=custom,"
        "PSRAM=enabled,ChipVariant=prev3",
        0x2000),
}


class BuildTarget(NamedTuple):
    """Exact compile composition layered on top of one chip platform."""

    key: str
    platform: str
    partition_csv: Optional[str] = None
    extra_flags: Tuple[str, ...] = ()
    extra_library_dirs: Tuple[str, ...] = ()
    required_profile: Optional[str] = None
    fqbn_options: Tuple[str, ...] = ()


BUILD_TARGETS = {
    "c6": BuildTarget("c6", "c6"),
    "s3-universal": BuildTarget(
        "s3-universal", "s3", partition_csv="partitions_s3.csv",
        extra_flags=("-DESPDISP_DOOM_RUNTIME",),
        extra_library_dirs=("firmware",)),
    "p4-4b": BuildTarget(
        "p4-4b", "p4", partition_csv="partitions_p4_4b.csv",
        extra_flags=("-DESPDISP_BOARD_P4_4B", "-DESPDISP_DOOM_RUNTIME"),
        extra_library_dirs=("firmware",),
        required_profile="st7703-4b", fqbn_options=("UploadSpeed=460800",)),
}


class Family(NamedTuple):
    key: str
    platform: str
    build_target: str
    profiles: Tuple[str, ...]
    flash_sizes: Tuple[int, ...]
    partition_scheme: str
    requires_doom_wad: bool
    hardware: Dict[str, Tuple[str, ...]]
    blurb: str

    @property
    def platform_config(self) -> Platform:
        return PLATFORMS[self.platform]

    @property
    def build_config(self) -> BuildTarget:
        return BUILD_TARGETS[self.build_target]

    @property
    def chip(self) -> str:
        return self.platform_config.chip

    @property
    def fqbn(self) -> str:
        options = self.build_config.fqbn_options
        if not options:
            return self.platform_config.fqbn
        return "%s,%s" % (self.platform_config.fqbn, ",".join(options))

    @property
    def partition_csv(self) -> Optional[str]:
        return self.build_config.partition_csv

    @property
    def extra_flags(self) -> Tuple[str, ...]:
        return self.build_config.extra_flags

    @property
    def extra_library_dirs(self) -> Tuple[str, ...]:
        return self.build_config.extra_library_dirs

    @property
    def upload_speed(self) -> str:
        return fqbn_option_value(self.fqbn, "UploadSpeed") or DEFAULT_FLASH_BAUD


FAMILIES = {
    "c6": Family(
        "c6", "c6", "c6", ("st7789", "jd9853"), (8 * 1024 * 1024,),
        "default-8m", False, {
            "st7789": ("ESP32-C6-LCD-1.47",),
            "jd9853": ("ESP32-C6-Touch-LCD-1.47",),
        },
        'Universal ESP32-C6 1.47" display firmware'),
    "s3": Family(
        "s3", "s3", "s3-universal",
        ("gc9107", "st7789-130", "st7789-154", "co5300", "st77916"),
        (8 * 1024 * 1024, 16 * 1024 * 1024, 32 * 1024 * 1024),
        "universal-8m-doom-ota", True, {
            "gc9107": ("ESP32-S3-LCD-0.85",),
            "st7789-130": ("ESP32-S3-LCD-1.3", "ESP32-S3-LCD-1.3-B", "ESP32-S3-LCD-1.3-C"),
            "st7789-154": ("ESP32-S3-Touch-LCD-1.54",),
            "co5300": ("ESP32-S3-Touch-AMOLED-1.75C",),
            "st77916": ("ESP32-S3-Touch-LCD-1.85C",),
        },
        "Universal ESP32-S3 display firmware"),
    "p4": Family(
        "p4", "p4", "p4-4b", ("st7703-4b",),
        (32 * 1024 * 1024,), "p4-32m-ota", True, {
            "st7703-4b": ("ESP32-P4-WIFI6-Touch-LCD-4B",),
        },
        "Universal ESP32-P4 display firmware"),
}


def family_choices() -> List[str]:
    return sorted(FAMILIES)


def canonical_family_key(key: str) -> str:
    return key


def bundle_family_keys(requested: Optional[List[str]]) -> List[str]:
    """One current bundle carries exactly one firmware family."""
    selected = requested or []
    if len(selected) != 1 or selected[0] not in FAMILIES:
        raise Fail("bundle requires exactly one --family: c6, s3, or p4")
    return selected


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKETCH_DIR = os.path.join(REPO_ROOT, "firmware", "display_stream")
SKETCH_INO = os.path.join(SKETCH_DIR, "display_stream.ino")
# Where FW_VERSION lives since the sketch was split into modules: the device
# identity module, not the .ino (which is now only setup/loop scheduling).
FW_VERSION_SOURCE = os.path.join(SKETCH_DIR, "app_state.cpp")
RELEASE_NOTES_PATH = os.path.join(REPO_ROOT, "release-notes.md")
RELEASE_ROOT = os.path.join(REPO_ROOT, "firmware-releases")
DEV_ROOT = os.path.join(REPO_ROOT, "firmware-dev")
RELEASE_CATALOG_NAME = "manifest.json"
RELEASE_CATALOG_SCHEMA = 3
RELEASE_CATALOG_SINGLE_SCHEMA = 2
RELEASE_CATALOG_LEGACY_SCHEMA = 1
RELEASE_CATALOG_REVISION_LIMIT = 5
FIRMWARE_BUILD_MAX = (1 << 32) - 1
FIRMWARE_RELEASE_REF_ENV = "ESPDISP_RELEASE_REF"
LIBRARIES_DIR = os.path.join(REPO_ROOT, "firmware", "libraries")
DOOM_LIBRARIES_DIR = os.path.join(REPO_ROOT, "firmware")
DOOM_PARTITIONS_CSV = os.path.join(REPO_ROOT, "firmware", "partitions_s3_doom.csv")
P4_PARTITIONS_CSV = os.path.join(REPO_ROOT, "firmware", "partitions_p4_4b.csv")

# Native USB and CH343-style UART bridges both occur on supported carriers.
PORT_GLOBS = ("/dev/cu.usbmodem*", "/dev/cu.usbserial*")

BAUD = 115200
CFG_PREFIXES = ("CFGOK", "CFGERR", "CFGINFO")

# OTA. 3232 is ArduinoOTA's default and what the firmware binds.
OTA_PORT = 3232
OTA_PASSWORD_ENV = "ESPDISP_OTA_PASSWORD"
DEFAULT_FLASH_BAUD = "921600"
# Both match otapolicy::PASSWORD_MIN_BYTES / PASSWORD_MAX_BYTES in the firmware,
# and are counted in bytes for the same reason it does.
OTA_PASSWORD_MIN = 8
OTA_PASSWORD_MAX = 64


class Fail(Exception):
    """A condition the user can act on: reported as one line, never a traceback."""


# --------------------------------------------------------------------------
# process plumbing


def fqbn_option_value(fqbn: str, key: str) -> Optional[str]:
    """Return one FQBN option value, or None when that option is not pinned."""
    parts = fqbn.split(":", 3)
    if len(parts) != 4:
        return None
    for option in parts[3].split(","):
        name, sep, value = option.partition("=")
        if name == key and sep:
            return value
    return None


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


class FirmwareBuild(NamedTuple):
    number: int
    branch_suffix: str


def firmware_identity(version: str, build: int, branch_suffix: str = "") -> str:
    return "%s+%d%s" % (version, build, branch_suffix)


def firmware_output_root(
    requested: Optional[str], build: Optional[FirmwareBuild]
) -> str:
    output_root = os.path.abspath(
        requested or (DEV_ROOT if build is not None else RELEASE_ROOT))
    if build is not None:
        release_root = os.path.realpath(RELEASE_ROOT)
        candidate = os.path.realpath(output_root)
        try:
            inside_release_root = (
                os.path.commonpath([release_root, candidate]) == release_root)
        except ValueError:
            inside_release_root = False
        if inside_release_root:
            raise Fail(
                "build-numbered firmware belongs in firmware-dev, not "
                "firmware-releases; omit --output-root to use the development root")
    return output_root


def git_firmware_release_ref(repo_root: str = REPO_ROOT) -> str:
    """Resolve the canonical release ref without assuming a local branch name."""
    override = os.environ.get(FIRMWARE_RELEASE_REF_ENV, "").strip()
    if override:
        verified = run_capture(
            ["git", "-C", repo_root, "rev-parse", "--verify", "--quiet", override],
            timeout=15.0,
        )
        if verified.returncode != 0:
            raise Fail(
                "firmware release ref %r from %s does not resolve"
                % (override, FIRMWARE_RELEASE_REF_ENV)
            )
        return override

    origin_head = run_capture(
        ["git", "-C", repo_root, "symbolic-ref", "--quiet", "--short",
         "refs/remotes/origin/HEAD"],
        timeout=15.0)
    ref = origin_head.stdout.strip()
    if origin_head.returncode == 0 and ref:
        return ref
    raise Fail(
        "cannot determine the firmware release branch; set %s or fetch origin/HEAD"
        % FIRMWARE_RELEASE_REF_ENV
    )


def git_firmware_build(repo_root: str = REPO_ROOT) -> FirmwareBuild:
    """Derive the authored build and append source provenance off release."""
    shallow = run_capture(
        ["git", "-C", repo_root, "rev-parse", "--is-shallow-repository"],
        timeout=15.0)
    shallow_state = shallow.stdout.strip().lower()
    if shallow.returncode != 0 or shallow_state not in ("true", "false"):
        raise Fail("cannot determine whether the git checkout is shallow")
    if shallow_state == "true":
        raise Fail("cannot derive a reliable firmware build from a shallow git checkout")

    count = run_capture(
        ["git", "-C", repo_root, "rev-list", "--count", "HEAD"], timeout=15.0)
    raw_count = count.stdout.strip()
    if count.returncode != 0 or not raw_count.isdigit():
        raise Fail("cannot derive firmware build from `git rev-list --count HEAD`")
    number = int(raw_count)
    if not 1 <= number <= FIRMWARE_BUILD_MAX:
        raise Fail(
            "firmware build %d is outside the supported uint32 range 1..%d"
            % (number, FIRMWARE_BUILD_MAX)
        )

    release_ref = git_firmware_release_ref(repo_root)
    on_main = run_capture(
        ["git", "-C", repo_root, "merge-base", "--is-ancestor",
         "HEAD", release_ref],
        timeout=15.0)
    if on_main.returncode == 0:
        return FirmwareBuild(number, "")
    if on_main.returncode != 1:
        raise Fail("cannot determine whether firmware HEAD is on %s" % release_ref)

    short = run_capture(
        ["git", "-C", repo_root, "rev-parse", "--short=7", "HEAD"],
        timeout=15.0)
    sha = short.stdout.strip().lower()
    if short.returncode != 0 or re.fullmatch(r"[0-9a-f]{7}", sha) is None:
        raise Fail("cannot derive the short git SHA for the firmware build")
    return FirmwareBuild(number, ".g" + sha)


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
    address: str
    hostname: str
    board: str  # chip-level Arduino board token
    target: str  # firmware family: c6, s3, or p4
    profile: str  # runtime physical profile token
    partition: str  # release partition compatibility token


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
        target = (props.get("target") or "").strip().lower()
        profile = (props.get("profile") or "").strip().lower()
        partition = (props.get("partition") or "").strip().lower()
        hostname = (props.get("hostname") or "").strip().rstrip(".")
        address = (port.get("address") or "").strip()
        if not address and not hostname:
            continue
        out.append(NetworkPort(
            address, hostname, board, target, profile, partition))
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


# What comparing --family against discovered identity metadata can conclude.
TARGET_OK = "ok"  # they agree
TARGET_WRONG = "wrong"  # it advertises the other board this tool knows
TARGET_UNKNOWN = "unknown"  # nothing to compare, or a board this tool cannot place
TARGET_OLD_LAYOUT = "old-layout"  # same family, but OTA cannot replace its table

LEGACY_PARTITION_SCHEMES = {
    "s3": {"universal-8m-ota"},
}


def classify_ota_target(
    family: Family,
    advertised_family: str,
    advertised_chip: str,
    advertised_profile: str = "",
    advertised_partition: str = "",
) -> str:
    """Require independent family, chip, profile, and partition evidence."""
    family_token = (advertised_family or "").strip().lower()
    chip = (advertised_chip or "").strip().lower()
    profile = (advertised_profile or "").strip().lower()
    partition = (advertised_partition or "").strip().lower()
    known_chips = {candidate.chip for candidate in FAMILIES.values()}
    known_profiles = {
        item for candidate in FAMILIES.values() for item in candidate.profiles
    }
    known_partitions = {
        candidate.partition_scheme for candidate in FAMILIES.values()
    }
    if family_token and family_token != family.key:
        return TARGET_WRONG
    if chip and chip != family.chip:
        return TARGET_WRONG if chip in known_chips else TARGET_UNKNOWN
    if profile and profile not in family.profiles:
        return TARGET_WRONG if profile in known_profiles else TARGET_UNKNOWN
    if partition and partition != family.partition_scheme:
        if partition in LEGACY_PARTITION_SCHEMES.get(family.key, set()):
            return TARGET_OLD_LAYOUT
        return TARGET_WRONG if partition in known_partitions else TARGET_UNKNOWN
    if (family_token == family.key and chip == family.chip and
            profile in family.profiles and
            partition == family.partition_scheme):
        return TARGET_OK
    return TARGET_UNKNOWN


def board_key_for_fqbn(fqbn: str) -> Optional[str]:
    """Map an Arduino FQBN to its one firmware family."""
    parts = fqbn.split(":")
    if len(parts) < 3:
        return None
    chip = parts[2].strip().lower()
    matches = [family for family in FAMILIES.values() if chip == family.chip]
    return matches[0].key if len(matches) == 1 else None


def candidate_ports() -> List[PortInfo]:
    return [
        p for p in detected_ports()
        if any(fnmatch.fnmatch(p.address, pattern) for pattern in PORT_GLOBS)
    ]


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
            % (", ".join(PORT_GLOBS), os.path.basename(sys.argv[0]))
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
        # resolve_family and fw_version_from_sketch take, and this one would put an
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
    """Ask esptool for the IDF chip token; it cannot identify the carrier."""
    tool = esptool_path()
    if not tool:
        return None
    cmd = [tool, "--port", address, "--connect-attempts", "2", "chip-id"]
    if tool.endswith(".py"):
        cmd = [sys.executable] + cmd
    proc = run_capture(cmd, timeout=60.0)
    blob = (proc.stdout or "") + (proc.stderr or "")
    if "chip-id" in blob and re.search(r"(No such command|Usage:)", blob):
        cmd[-1] = "chip_id"
        proc = run_capture(cmd, timeout=60.0)
        blob = (proc.stdout or "") + (proc.stderr or "")
    found = re.findall(
        r"(?:Chip is|Detecting chip type\.\.\.)\s*(ESP32[\w-]*)", blob)
    if not found:
        return None
    return re.sub(r"[^a-z0-9]", "", found[0].lower())



def _validate_flash_profile(family: Family, profile: Optional[str]) -> None:
    """Require carrier evidence for compile-fixed artifacts before USB writes."""
    required = family.build_config.required_profile
    if required is not None and profile != required:
        raise Fail(
            "%s uses exact build target %s; re-run with --profile %s"
            % (family.key, family.build_config.key, required))
    if profile is not None and profile not in family.profiles:
        raise Fail("profile %s is not supported by family %s" % (profile, family.key))


def resolve_family(
    explicit: Optional[str], port: Optional[PortInfo], profile: Optional[str] = None
) -> Family:
    """Select a family without inferring a compile-fixed carrier from its chip."""
    if explicit:
        family = FAMILIES[explicit]
        reported = port.board_keys[0] if port and len(port.board_keys) == 1 else None
        if reported and reported != family.key:
            raise Fail(
                "--family %s contradicts %s, which reports family %s"
                % (family.key, port.address, reported))
        _validate_flash_profile(family, profile)
        return family
    if port is None:
        raise Fail("--family is required here (one of: %s)" % ", ".join(FAMILIES))
    if len(port.board_keys) == 1:
        family = FAMILIES[port.board_keys[0]]
        _validate_flash_profile(family, profile)
        return family
    print("Probing %s for its chip type..." % port.address, flush=True)
    chip = probe_chip(port.address)
    matches = [family for family in FAMILIES.values() if family.chip == chip]
    if len(matches) == 1:
        family = matches[0]
        _validate_flash_profile(family, profile)
        print("Detected %s family %s." % (chip, family.key), flush=True)
        return family
    raise Fail(
        "could not determine the firmware family on %s; re-run with --family %s"
        % (port.address, "|".join(FAMILIES)))


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
#   offset 0        "ESPDISPFW3\n"   11 bytes, magic and format generation
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
# WHAT GENERATIONS ADDED. Generation 2 added the bootloader, partition table and
# boot_app0 needed to bring up a blank board. Generation 3 makes exact firmware
# targets first-class: every image carries one or more `targets`, duplicate chips
# are valid, and one exact target can be claimed by only one image. This matters
# for s3-175 and s3-185: esptool sees the same ESP32-S3 chip in both, while their
# panel geometry, controller and pin configuration require different firmware.
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

BUNDLE_MAGIC_V1 = b"ESPDISPFW1\n"
BUNDLE_FORMAT_V1 = 1
BUNDLE_MAGIC_V2 = b"ESPDISPFW2\n"
BUNDLE_FORMAT_V2 = 2
BUNDLE_MAGIC_V3 = b"ESPDISPFW3\n"
BUNDLE_FORMAT_V3 = 3
BUNDLE_MAGIC = BUNDLE_MAGIC_V3
BUNDLE_FORMAT = BUNDLE_FORMAT_V3
# Every magic has the same width, preserving the byte-exact 22-byte header and
# all generation-1/2 offsets. The writer emits v3; pack_bundle can still assemble
# a pinned legacy manifest with its matching legacy magic.
BUNDLE_GENERATIONS = {
    BUNDLE_MAGIC_V1: BUNDLE_FORMAT_V1,
    BUNDLE_MAGIC_V2: BUNDLE_FORMAT_V2,
    BUNDLE_MAGIC_V3: BUNDLE_FORMAT_V3,
}
BUNDLE_MAGIC_BY_FORMAT = {
    generation: magic for magic, generation in BUNDLE_GENERATIONS.items()
}
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
# Generation 1's image keys, generation 2's blank-board additions, and
# generation 3's exact compatible-target list.
IMAGE_KEYS = ("board", "chip", "fqbn", "filename", "offset", "bytes", "sha256")
IMAGE_KEYS_V2 = IMAGE_KEYS + ("app_address", "flash_parts")
IMAGE_KEYS_V3 = IMAGE_KEYS_V2 + ("targets",)
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


LEGACY_TARGET_BY_BOARD = {
    "c6": "c6",
    "s3": "s3-175",
    "s3-085": "s3-085",
    "s3-154": "s3-154",
    "s3-175": "s3-175",
    "s3-185": "s3-185",
}


def image_targets(image: dict, generation: int) -> List[str]:
    """Return exact targets for one image, translating legacy board names."""
    if generation >= BUNDLE_FORMAT_V3:
        targets = image.get("targets")
        if not isinstance(targets, list) or not targets:
            raise Fail("a format-3 image requires a non-empty targets list")
        exact: List[str] = []
        for target in targets:
            if (
                not isinstance(target, str)
                or not target.strip()
                or target != target.strip()
            ):
                raise Fail("format-3 image has no usable target: %r" % target)
            if target in exact:
                raise Fail("format-3 image lists target %s twice" % target)
            exact.append(target)
        return exact

    board = image.get("board")
    if not isinstance(board, str) or not board.strip():
        raise Fail("legacy image has no usable board: %r" % board)
    token = board.strip().lower()
    return [LEGACY_TARGET_BY_BOARD.get(token, token)]


def validate_target_claims(images: List[dict], generation: int) -> List[List[str]]:
    """Validate image target lists and reject duplicate v3 target claims."""
    result = [image_targets(image, generation) for image in images]
    if generation < BUNDLE_FORMAT_V3:
        return result

    claimed: Dict[str, int] = {}
    for index, targets in enumerate(result):
        for target in targets:
            if target in claimed:
                raise Fail(
                    "target %s is claimed by both image %d and image %d"
                    % (target, claimed[target], index)
                )
            claimed[target] = index
    return result


# The one spelling of FW_VERSION in the sketch (app_state.cpp; `static` is
# optional because the definition has external linkage there). Loose
# about whitespace and the position of the `*`, strict about everything that
# makes it a definition, so a rename or a move breaks loudly here rather than
# quietly producing a manifest with the wrong version in it.
FW_VERSION_RE = re.compile(
    r'^\s*(?:static\s+)?const\s+char\s*\*\s*FW_VERSION\s*=\s*"([^"\n]*)"\s*;',
    re.MULTILINE
)
SEMVER_IDENTIFIER_RE = r"(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-(" + SEMVER_IDENTIFIER_RE + r"(?:\." + SEMVER_IDENTIFIER_RE + r")*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)

# Release-note source reasons are deliberately finite and stable.
RELEASE_REASON_TITLE = "expected exact title '# Release Notes'"
RELEASE_REASON_NO_SECTIONS = "document contains no release sections"
RELEASE_REASON_HEADING = "section heading must be exactly '## <SemVer 2.0.0>'"
RELEASE_REASON_VERSION = "version %s is not SemVer 2.0.0"
RELEASE_REASON_PRE_SECTION = "content appears before the first release section"
RELEASE_REASON_ITEM_MARKER = "item must begin with '- '"
RELEASE_REASON_ITEM_LENGTH = "item text must contain 1–280 Unicode scalars"
RELEASE_REASON_FORBIDDEN = "item text contains forbidden scalar U+%04X"
RELEASE_REASON_EDGE_WHITESPACE = "item text has forbidden leading or trailing whitespace"
RELEASE_REASON_VERB = "item text must begin with Added, Changed, Fixed, or Removed"
RELEASE_REASON_PUNCTUATION = "item text must end with '.', '!', or '?'"
RELEASE_REASON_SECTION_COUNT = "section must contain 1–32 items"
RELEASE_REASON_DUPLICATE = "duplicate version %s"
RELEASE_REASON_ORDER = "version %s is not older than %s"
RELEASE_REASON_MISSING = "no section exactly matching FW_VERSION %s"
RELEASE_REASON_CR = "carriage return byte is not allowed"
RELEASE_REASON_UTF8 = "not valid UTF-8"
RELEASE_REASON_CANNOT_READ = "cannot read"
RELEASE_REASON_FW_VERSION = "FW_VERSION %s is not SemVer 2.0.0"
RELEASE_REASON_REQUESTED_VERSION = "requested FW_VERSION %s is not SemVer 2.0.0"


def quote_release_value(value: str) -> str:
    """Render scalar content in a deterministic one-line quoted form."""
    slash = chr(0x5C)
    pieces = ["'"]
    for scalar in value:
        code = ord(scalar)
        if 0x20 <= code <= 0x7E and scalar not in ("'", slash):
            pieces.append(scalar)
        elif scalar == "'":
            pieces.append(slash + "'")
        elif scalar == slash:
            pieces.append(slash * 2)
        elif code <= 0xFFFF:
            pieces.append(slash + "u%04X" % code)
        else:
            scalar16 = code - 0x10000
            pieces.append(slash + "u%04X" % (0xD800 + (scalar16 >> 10)))
            pieces.append(slash + "u%04X" % (0xDC00 + (scalar16 & 0x3FF)))
    return "".join(pieces) + "'"


def parse_semver(value: str):
    """Return SemVer precedence parts, or None for a non-SemVer 2.0.0 value."""
    if not isinstance(value, str):
        return None
    match = SEMVER_RE.fullmatch(value)
    if not match:
        return None
    prerelease = tuple(match.group(4).split(".")) if match.group(4) else ()
    return int(match.group(1)), int(match.group(2)), int(match.group(3)), prerelease


def compare_semver(left: str, right: str) -> int:
    """Compare SemVer precedence, deliberately ignoring build metadata."""
    parsed_left, parsed_right = parse_semver(left), parse_semver(right)
    if parsed_left is None or parsed_right is None:
        raise ValueError("compare_semver needs valid SemVer values")
    if parsed_left[:3] != parsed_right[:3]:
        return -1 if parsed_left[:3] < parsed_right[:3] else 1
    pre_left, pre_right = parsed_left[3], parsed_right[3]
    if not pre_left or not pre_right:
        if not pre_left and not pre_right:
            return 0
        return 1 if not pre_left else -1
    for left_id, right_id in zip(pre_left, pre_right):
        if left_id == right_id:
            continue
        left_numeric, right_numeric = left_id.isdigit(), right_id.isdigit()
        if left_numeric and right_numeric:
            return -1 if int(left_id) < int(right_id) else 1
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return -1 if left_id < right_id else 1
    if len(pre_left) == len(pre_right):
        return 0
    return -1 if len(pre_left) < len(pre_right) else 1


def forbidden_item_scalar(code: int) -> bool:
    return (
        0x0000 <= code <= 0x001F
        or 0x007F <= code <= 0x009F and code != 0x0085
        or 0xD800 <= code <= 0xDFFF
    )


def protocol_whitespace_scalar(code: int) -> bool:
    return (
        0x0009 <= code <= 0x000D
        or code in (0x0020, 0x0085, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000)
        or 0x2000 <= code <= 0x200A
    )


def release_note_item_reason(item: str) -> Optional[str]:
    """Return the common source/manifest item grammar failure, if any."""
    if not isinstance(item, str):
        return "item must be a string"
    if not 1 <= len(item) <= 280:
        return RELEASE_REASON_ITEM_LENGTH
    for scalar in item:
        if forbidden_item_scalar(ord(scalar)):
            return RELEASE_REASON_FORBIDDEN % ord(scalar)
    if protocol_whitespace_scalar(ord(item[0])) or protocol_whitespace_scalar(ord(item[-1])):
        return RELEASE_REASON_EDGE_WHITESPACE
    if not item.startswith(("Added ", "Changed ", "Fixed ", "Removed ")):
        return RELEASE_REASON_VERB
    if not item.endswith((".", "!", "?")):
        return RELEASE_REASON_PUNCTUATION
    return None


def _release_source_error(path: str, line: int, section: Optional[str], reason: str) -> Fail:
    return Fail("release notes %s:%d: section %s: %s" % (
        path, line, section if section is not None else "none", reason))


def _cr_section(raw_before_cr: bytes) -> Optional[str]:
    section = None
    for raw_line in raw_before_cr.split(b"\n"):
        if raw_line.startswith(b"## "):
            try:
                label = raw_line[3:].decode("ascii")
            except UnicodeDecodeError:
                continue
            if parse_semver(label) is not None:
                section = label
    return section


def release_notes_for_version(path: str, version: str) -> List[str]:
    """Read, fully validate, and select one LF-delimited Markdown release section."""
    if parse_semver(version) is None:
        raise Fail("release notes %s: %s" % (
            path, RELEASE_REASON_REQUESTED_VERSION % quote_release_value(version)))
    try:
        with open(path, "rb") as source:
            raw = source.read()
    except OSError:
        raise Fail("release notes %s: %s" % (path, RELEASE_REASON_CANNOT_READ))
    cr_offset = raw.find(b"\r")
    if cr_offset >= 0:
        line = raw[:cr_offset].count(b"\n") + 1
        raise _release_source_error(path, line, _cr_section(raw[:cr_offset]), RELEASE_REASON_CR)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        line = raw[:exc.start].count(b"\n") + 1
        raise Fail("release notes %s: byte %d: line %d: %s" % (
            path, exc.start, line, RELEASE_REASON_UTF8))

    lines = text.split("\n")
    if not lines or lines[0] != "# Release Notes":
        raise _release_source_error(path, 1, None, RELEASE_REASON_TITLE)
    sections, current = [], None
    for line_number, line in enumerate(lines[1:], start=2):
        if line == "":
            continue
        if line.startswith("## "):
            label = line[3:]
            if parse_semver(label) is None:
                raise _release_source_error(
                    path, line_number, current["label"] if current else None,
                    RELEASE_REASON_VERSION % quote_release_value(label))
            current = {"label": label, "line": line_number, "items": []}
            sections.append(current)
            continue
        if line.startswith("#"):
            raise _release_source_error(
                path, line_number, current["label"] if current else None,
                RELEASE_REASON_HEADING)
        if current is None:
            raise _release_source_error(path, line_number, None, RELEASE_REASON_PRE_SECTION)
        if not line.startswith("- "):
            raise _release_source_error(
                path, line_number, current["label"], RELEASE_REASON_ITEM_MARKER)
        item = line[2:]
        reason = release_note_item_reason(item)
        if reason:
            raise _release_source_error(path, line_number, current["label"], reason)
        current["items"].append(item)

    if not sections:
        raise _release_source_error(path, 1, None, RELEASE_REASON_NO_SECTIONS)
    for section in sections:
        if not 1 <= len(section["items"]) <= 32:
            raise _release_source_error(
                path, section["line"], section["label"], RELEASE_REASON_SECTION_COUNT)
    seen = {}
    for section in sections:
        label = section["label"]
        if label in seen:
            raise Fail("release notes %s:%d,%d: %s" % (
                path, seen[label]["line"], section["line"], RELEASE_REASON_DUPLICATE % label))
        seen[label] = section
    for newer, older in zip(sections, sections[1:]):
        if compare_semver(older["label"], newer["label"]) >= 0:
            raise Fail("release notes %s:%d,%d: %s" % (
                path, newer["line"], older["line"],
                RELEASE_REASON_ORDER % (older["label"], newer["label"])))
    selected = seen.get(version)
    if selected is None:
        raise Fail("release notes %s: %s" % (path, RELEASE_REASON_MISSING % version))
    return list(selected["items"])


def fw_version_declaration(text: str) -> Tuple[str, int]:
    """Read the sole FW_VERSION declaration and its one-based source line."""
    found = list(FW_VERSION_RE.finditer(text))
    if not found:
        raise Fail(
            "could not find FW_VERSION in the sketch.\n"
            '  Expected a line like: static const char *FW_VERSION = "1.2.0";\n'
            "  If it was renamed or moved, FW_VERSION_RE in this file has to follow it."
        )
    if len(found) > 1:
        raise Fail(
            "found %d FW_VERSION definitions in the sketch (%s); there must be exactly one"
            % (len(found), ", ".join(repr(match.group(1)) for match in found))
        )
    version = found[0].group(1)
    if not version.strip():
        raise Fail("FW_VERSION in the sketch is empty; a bundle needs a version to compare")
    return version, text.count("\n", 0, found[0].start(1)) + 1


def fw_version_from_sketch(text: str) -> str:
    """Compatibility wrapper for callers that only need the version string."""
    return fw_version_declaration(text)[0]


def sketch_fw_version_declaration(path: str = FW_VERSION_SOURCE) -> Tuple[str, int]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise Fail("cannot read %s: %s" % (path, exc.strerror or exc))
    return fw_version_declaration(text)


def sketch_fw_version(path: str = FW_VERSION_SOURCE) -> str:
    return sketch_fw_version_declaration(path)[0]


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

    `git status --porcelain` counts untracked source files as dirty. Task reports
    under `.agents/` and generated firmware output under `firmware-releases/`
    or `firmware-dev/` are excluded because neither can affect compilation;
    every other untracked file still makes provenance dirty.
    """
    head = run_capture(["git", "-C", repo_root, "rev-parse", "HEAD"], timeout=15.0)
    if head.returncode != 0:
        return None, False
    commit = head.stdout.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        return None, False
    status = run_capture(
        ["git", "-C", repo_root, "status", "--porcelain", "--untracked-files=all"],
        timeout=30.0)
    if status.returncode != 0:
        # The commit is known and the cleanliness is not. Claiming clean would be
        # the wrong way to be wrong, but so would refusing to bundle at all, so
        # this reports the commit and the safer of the two answers is the caller's
        # problem: bundle-info prints exactly what the manifest says.
        return commit, False
    relevant = []
    for line in status.stdout.splitlines():
        path = line[3:] if len(line) >= 4 else ""
        if path == ".agents" or path.startswith(".agents/"):
            continue
        if any(
            path == root or path.startswith(root + "/")
            for root in ("firmware-releases", "firmware-dev")
        ):
            continue
        relevant.append(line)
    return commit, bool(relevant)


def safe_json_key_display(value: str) -> str:
    """Render a decoded JSON key safely in a deterministic one-line error."""
    slash = chr(0x5C)
    pieces = []
    for scalar in value:
        code = ord(scalar)
        if 0x20 <= code <= 0x7E and scalar != slash:
            pieces.append(scalar)
        elif scalar == slash:
            pieces.append(slash * 2)
        elif code <= 0xFFFF:
            pieces.append(slash + "u%04X" % code)
        else:
            scalar16 = code - 0x10000
            pieces.append(slash + "u%04X" % (0xD800 + (scalar16 >> 10)))
            pieces.append(slash + "u%04X" % (0xDC00 + (scalar16 & 0x3FF)))
    return "".join(pieces)


def first_duplicate_json_member_name(raw: bytes) -> Optional[str]:
    """Return a completed manifest's first duplicate semantic object key.

    This bounded iterative structural scan intentionally does not validate JSON
    values. Native decoding remains authoritative for malformed JSON and UTF-8;
    any candidate becomes actionable only after that decoder succeeds.
    """
    index, length, candidate = 0, len(raw), None
    frames = [{"kind": "root", "state": "value"}]

    def skip_whitespace(position: int) -> int:
        while position < length and raw[position] in b" \t\n\r":
            position += 1
        return position

    def string_end(position: int) -> Optional[int]:
        # `position` points at the opening quote. Quote/backslash state is the
        # only lexical detail the structural walk needs to preserve.
        position += 1
        while position < length:
            if raw[position] == 0x22:
                return position + 1
            if raw[position] == 0x5C:
                position += 1
                if position >= length:
                    return None
            position += 1
        return None

    def begin_value(frame: dict) -> bool:
        nonlocal index
        index = skip_whitespace(index)
        if index >= length:
            return False
        token = raw[index]
        frame["state"] = "after"
        if token == 0x7B:  # {
            frames.append({"kind": "object", "state": "key", "names": set()})
            index += 1
            return True
        if token == 0x5B:  # [
            frames.append({"kind": "array", "state": "value_or_end"})
            index += 1
            return True
        if token == 0x22:
            end = string_end(index)
            if end is None:
                return False
            index = end
            return True
        if token in b",]}:":
            return False
        start = index
        while index < length and raw[index] not in b" \t\n\r,]}":
            index += 1
        return index > start

    while frames:
        frame = frames[-1]
        kind, state = frame["kind"], frame["state"]
        if kind == "root":
            if state == "value":
                if not begin_value(frame):
                    return None
            else:
                index = skip_whitespace(index)
                return candidate if index == length else None
            continue
        if kind == "object":
            if state == "key":
                index = skip_whitespace(index)
                if index >= length:
                    return None
                if raw[index] == 0x7D:  # }
                    frames.pop()
                    index += 1
                    continue
                if raw[index] != 0x22:
                    return None
                end = string_end(index)
                if end is None:
                    return None
                try:
                    name = json.loads(raw[index:end].decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    return None
                if not isinstance(name, str):
                    return None
                if name in frame["names"] and candidate is None:
                    candidate = name
                frame["names"].add(name)
                frame["state"] = "colon"
                index = end
                continue
            if state == "colon":
                index = skip_whitespace(index)
                if index >= length or raw[index] != 0x3A:  # :
                    return None
                frame["state"] = "value"
                index += 1
                continue
            if state == "value":
                if not begin_value(frame):
                    return None
                continue
            index = skip_whitespace(index)
            if index >= length:
                return None
            if raw[index] == 0x2C:  # ,
                frame["state"] = "key"
                index += 1
                continue
            if raw[index] == 0x7D:  # }
                frames.pop()
                index += 1
                continue
            return None
        if state == "value_or_end":
            index = skip_whitespace(index)
            if index >= length:
                return None
            if raw[index] == 0x5D:  # ]
                frames.pop()
                index += 1
                continue
            if not begin_value(frame):
                return None
            continue
        index = skip_whitespace(index)
        if index >= length:
            return None
        if raw[index] == 0x2C:  # ,
            frame["state"] = "value_or_end"
            index += 1
            continue
        if raw[index] == 0x5D:  # ]
            frames.pop()
            index += 1
            continue
        return None
    return None


def validated_manifest_release_notes(manifest: dict) -> Optional[List[str]]:
    """Validate optional external metadata; absent remains legacy-compatible."""
    if "release_notes" not in manifest:
        return None
    notes = manifest["release_notes"]
    if not isinstance(notes, list) or not 1 <= len(notes) <= 32:
        raise Fail("bundle manifest: release_notes: must be a list containing 1–32 items")
    validated = []
    for index, note in enumerate(notes):
        reason = release_note_item_reason(note)
        if reason:
            raise Fail("bundle manifest: release_notes[%d]: %s" % (index, reason))
        validated.append(note)
    return validated


def validated_manifest_firmware_build(manifest: dict) -> Optional[int]:
    """Validate additive build metadata; absence remains legacy-compatible."""
    if "firmware_build" not in manifest:
        return None
    build = manifest["firmware_build"]
    if (not is_whole_number(build) or
            not 1 <= build <= FIRMWARE_BUILD_MAX):
        raise Fail(
            "bundle manifest: firmware_build: must be a whole number from 1 to %d"
            % FIRMWARE_BUILD_MAX
        )
    return build


def bundle_manifest(
    firmware_version: str,
    firmware_build: int,
    images: List[dict],
    built_at: str,
    *,
    release_notes: List[str],
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
    below. Eight passes is far more than the two needed by the current
    three-target bundle (`test_bundle_manifest_offsets` drives payload sizes that
    force digit rollovers).
    """
    build = validated_manifest_firmware_build({"firmware_build": firmware_build})
    assert build is not None
    notes = validated_manifest_release_notes({"release_notes": release_notes})
    if notes is None:  # Current format-3 output is never a legacy manifest.
        raise Fail("a format-3 bundle requires release_notes")
    if not images:
        raise Fail("a bundle needs at least one image")
    validate_target_claims(images, BUNDLE_FORMAT)
    prepared = []
    for image in images:
        parts = image.get("flash_parts")
        if not isinstance(parts, list):
            # The newest writer always describes everything a blank board needs.
            # Reading generation 1 remains unpack_bundle's business.
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
        "firmware_build": build,
        "built_at": built_at,
        "source_commit": source_commit,
        "source_dirty": bool(source_dirty),
        "tool": tool,
        "release_notes": notes,
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

    Payload maps are keyed by exact target. For a multi-target image, every
    claimed target must map to the same application and flash-part bytes.

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
    generation = manifest.get("format")
    magic = BUNDLE_MAGIC_BY_FORMAT.get(generation)
    if magic is None:
        raise Fail("cannot pack unsupported bundle format %r" % generation)
    notes = validated_manifest_release_notes(manifest)
    if generation == BUNDLE_FORMAT_V3 and notes is None:
        raise Fail("bundle manifest: release_notes: required for format 3")
    targets_by_image = validate_target_claims(images, generation)
    if generation < BUNDLE_FORMAT_V3:
        seen_chips = set()
        for image in images:
            chip = image.get("chip")
            if chip in seen_chips:
                raise Fail("legacy bundle lists %s twice" % chip)
            seen_chips.add(chip)
    flash_payloads = flash_payloads or {}
    raw = encode_manifest(manifest)
    out = [magic, bundle_length_line(len(raw)), raw]
    cursor = BUNDLE_HEADER_BYTES + len(raw)

    def shared_payload(mapping: dict, targets: List[str], label: str) -> bytes:
        missing = [target for target in targets if mapping.get(target) is None]
        if missing:
            raise Fail(
                "the manifest lists %s but no payload was given for target %s"
                % (label, ", ".join(missing))
            )
        blobs = [mapping[target] for target in targets]
        if any(blob != blobs[0] for blob in blobs[1:]):
            raise Fail(
                "targets %s claim one image but were given different %s payloads"
                % (", ".join(targets), label)
            )
        return blobs[0]

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

    for image, targets in zip(images, targets_by_image):
        chip = image["chip"]
        target_label = "/".join(targets)
        place(image, shared_payload(payloads, targets, "application"), target_label)
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
                shared_payload(
                    {
                        target: (flash_payloads.get(target) or {}).get(part["role"])
                        for target in targets
                    },
                    targets,
                    part["role"],
                ),
                "%s %s" % (target_label, part["role"]),
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

    Returns maps keyed by exact target. Format 3 reads `targets`; legacy `board`
    values are translated (`s3` is always `s3-175`, never `s3-185`). The third
    map is empty for a generation-1 file, which carries no flash parts.
    Raises Fail, one specific line per way a file can be wrong, because by the
    time this runs the file arrived from somewhere else and "invalid bundle" tells
    the user nothing about whether to re-download it, rebuild it, or go and find
    the person who sent it.

    Everything here is checkable without the panel: hashes catch corrupt or
    edited payloads and contiguity catches truncation. Target claims are manifest
    metadata; same-chip image-header validation cannot distinguish s3-175 from
    s3-185, so callers must select by exact target.

    BOTH LEGACY GENERATIONS ARE ACCEPTED. A generation-1 file carries application images
    and nothing else: it cannot flash a blank board, and it is still a valid OTA
    payload that the person holding it may not be able to rebuild. Refusing it
    would break a feature that works over a file nobody can re-create.
    """
    if len(data) < BUNDLE_HEADER_BYTES:
        raise Fail(
            "not a firmware bundle: %d bytes is shorter than the %d-byte header"
            % (len(data), BUNDLE_HEADER_BYTES)
        )
    magic = bytes(data[: len(BUNDLE_MAGIC)])
    generation = BUNDLE_GENERATIONS.get(magic)
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
        raise Fail("not a firmware bundle: it does not start with an ESPDISPFW magic")

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
    raw_manifest = data[BUNDLE_HEADER_BYTES:end]
    duplicate_key = first_duplicate_json_member_name(raw_manifest)
    try:
        manifest = json.loads(raw_manifest.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise Fail("bundle manifest is not valid UTF-8 JSON: %s" % exc)
    if duplicate_key is not None:
        raise Fail("bundle manifest: duplicate key %s" % safe_json_key_display(duplicate_key))
    if not isinstance(manifest, dict):
        raise Fail(
            "bundle manifest is a %s, not a JSON object" % type(manifest).__name__
        )
    missing = [key for key in MANIFEST_KEYS if key not in manifest]
    if missing:
        raise Fail("bundle manifest is missing %s" % ", ".join(missing))
    validated_manifest_firmware_build(manifest)
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
                magic.decode("ascii", "replace").strip(),
                generation,
                " and ".join(str(v) for v in sorted(BUNDLE_GENERATIONS.values())),
            )
        )
    validated_manifest_release_notes(manifest)
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

    image_keys = (
        IMAGE_KEYS
        if generation == BUNDLE_FORMAT_V1
        else IMAGE_KEYS_V2
        if generation == BUNDLE_FORMAT_V2
        else IMAGE_KEYS_V3
    )
    seen_targets: Dict[str, int] = {}
    seen_legacy_chips = set()
    for index, image in enumerate(images):
        where = "image %d" % index
        if not isinstance(image, dict):
            raise Fail("%s is a %s, not a JSON object" % (where, type(image).__name__))
        missing = [key for key in image_keys if key not in image]
        if missing:
            raise Fail("%s is missing %s" % (where, ", ".join(missing)))
        targets = image_targets(image, generation)
        if generation >= BUNDLE_FORMAT_V3:
            for target in targets:
                if target in seen_targets:
                    raise Fail(
                        "target %s is claimed by both image %d and image %d"
                        % (target, seen_targets[target], index)
                    )
                seen_targets[target] = index
        chip = image["chip"]
        if generation < BUNDLE_FORMAT_V3:
            if chip in seen_legacy_chips:
                raise Fail(
                    "legacy bundle lists %s twice; a reader could not tell which "
                    "image to push" % chip
                )
            seen_legacy_chips.add(chip)
        app = take(image, "%s (%s; targets %s)" % (where, chip, ", ".join(targets)))
        for target in targets:
            payloads[target] = app
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
        for target in targets:
            flash_payloads[target] = dict(roles)

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
    notes = manifest.get("release_notes")
    note_line = (
        "  release notes: %d item(s)" % len(notes)
        if isinstance(notes, list)
        else "  release notes: unavailable (legacy bundle)"
    )
    version = manifest.get("firmware_version")
    build = validated_manifest_firmware_build(manifest)
    identity = (
        firmware_identity(version, build)
        if isinstance(version, str) and build is not None
        else version
    )
    lines = [
        "  version:  %s" % identity,
        "  built at: %s" % manifest.get("built_at"),
        "  source:   %s" % source,
        "  tool:     %s (format %s)" % (manifest.get("tool"), manifest.get("format")),
        note_line,
    ]
    for image in manifest.get("images") or []:
        digest = str(image.get("sha256", ""))
        generation = manifest.get("format")
        try:
            targets = image_targets(image, generation)
        except Fail:
            targets = [str(image.get("board"))]
        lines.append(
            "  image:    targets=%-17s chip=%-8s %8d bytes  sha256 %s"
            % (
                ",".join(targets),
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


def release_catalog_revision(
    version: str, build: int, artifact: str, data: bytes
) -> dict:
    return {
        "version": version,
        "build": build,
        "artifact": artifact.replace(os.sep, "/"),
        "sha256": sha256_hex(data),
        "bytes": len(data),
    }


def release_catalog_entry(
    family: Family, version: str, build: int, artifact: str, data: bytes,
    revisions: Optional[List[dict]] = None,
) -> dict:
    entry = {
        "latest_version": version,
        "latest_build": build,
        "artifact": artifact.replace(os.sep, "/"),
        "sha256": sha256_hex(data),
        "bytes": len(data),
        "chip": family.chip,
        "profiles": list(family.profiles),
        "hardware": {
            profile: list(family.hardware[profile]) for profile in family.profiles
        },
        "compatibility": {
            "flash_bytes": list(family.flash_sizes),
            "partition_scheme": family.partition_scheme,
            "bootloader_address": family.platform_config.bootloader_address,
            "partitions_address": PARTITIONS_FLASH_ADDRESS,
            "boot_app0_address": BOOT_APP0_FLASH_ADDRESS,
            "app_address": APP_FLASH_ADDRESS,
            "identity_required": ["family", "chip", "profile", "partition"],
        },
    }
    if revisions is not None:
        entry["revisions"] = revisions
    return entry


def release_catalog_revisions(output_root: str, key: str) -> List[dict]:
    """Return the newest committed generations without pruning older files."""
    family = FAMILIES[key]
    directory = os.path.join(output_root, key)
    candidates = []
    pattern = os.path.join(directory, "espdisp-%s-*%s" % (key, BUNDLE_SUFFIX))
    for path in sorted(glob.glob(pattern)):
        data = read_binary(path)
        manifest, payloads, _ = unpack_bundle(data)
        version = manifest.get("firmware_version")
        build = validated_manifest_firmware_build(manifest)
        if parse_semver(version) is None or build is None:
            continue
        relative = os.path.relpath(path, output_root)
        revision = release_catalog_revision(
            version, build, relative, data)
        validate_release_revision_shape(revision, key, "%s candidate" % key)
        if set(payloads) != {key} or len(manifest.get("images") or []) != 1:
            raise Fail("%s is not a single-family %s release" % (path, key))
        image = manifest["images"][0]
        if (image.get("targets") != [key] or
                image.get("chip") != family.chip or
                image.get("profiles") != list(family.profiles) or
                image.get("flash_sizes") != list(family.flash_sizes)):
            raise Fail("%s family identity does not match %s" % (path, key))
        candidates.append(revision)
    candidates.sort(key=lambda revision: revision["build"], reverse=True)
    builds = [revision["build"] for revision in candidates]
    if len(builds) != len(set(builds)):
        raise Fail("release catalog family %s has duplicate build generations" % key)
    if len(candidates) < RELEASE_CATALOG_REVISION_LIMIT:
        raise Fail(
            "release catalog family %s has only %d build generations; expected %d"
            % (key, len(candidates), RELEASE_CATALOG_REVISION_LIMIT)
        )
    return candidates[:RELEASE_CATALOG_REVISION_LIMIT]


def release_catalog(
    version: str, build: FirmwareBuild, output_root: str
) -> dict:
    families = {}
    identity = firmware_identity(version, build.number, build.branch_suffix)
    for key, family in FAMILIES.items():
        relative = os.path.join(
            key, "espdisp-%s-%s%s" % (key, identity, BUNDLE_SUFFIX))
        path = os.path.join(output_root, relative)
        data = read_binary(path)
        revisions = release_catalog_revisions(output_root, key)
        if revisions[0] != release_catalog_revision(
                version, build.number, relative, data):
            raise Fail(
                "new %s release is not the newest retained revision" % key)
        families[key] = release_catalog_entry(
            family, version, build.number, relative, data, revisions=revisions)
    return {
        "schema": RELEASE_CATALOG_SCHEMA,
        "generated_at": utc_timestamp(),
        "families": families,
    }


def release_artifact_is_canonical(
    relative: object, key: str, version: str, build: Optional[int]
) -> bool:
    if not isinstance(relative, str) or not relative.startswith(key + "/"):
        return False
    filename = relative[len(key) + 1:]
    if build is None:
        return filename == "espdisp-%s-%s%s" % (
            key, version, BUNDLE_SUFFIX)
    expected_name = re.compile(
        re.escape("espdisp-%s-%s+%d" % (key, version, build))
        + r"(?:\.g[0-9a-f]{7})?"
        + re.escape(BUNDLE_SUFFIX) + r"$"
    )
    return expected_name.fullmatch(filename) is not None


def validate_release_revision_shape(
    revision: object, key: str, owner: str
) -> dict:
    required = {"version", "build", "artifact", "sha256", "bytes"}
    if not isinstance(revision, dict) or set(revision) != required:
        raise Fail("%s has unexpected or missing keys" % owner)
    version = revision["version"]
    if not isinstance(version, str) or parse_semver(version) is None:
        raise Fail("%s has a non-SemVer version" % owner)
    build = revision["build"]
    if not is_whole_number(build) or not 1 <= build <= FIRMWARE_BUILD_MAX:
        raise Fail("%s has an invalid build" % owner)
    if not release_artifact_is_canonical(
            revision["artifact"], key, version, build):
        raise Fail("%s has a non-canonical artifact path" % owner)
    if not is_whole_number(revision["bytes"]) or revision["bytes"] <= 0:
        raise Fail("%s has an invalid byte size" % owner)
    if (not isinstance(revision["sha256"], str) or
            re.fullmatch(r"[0-9a-f]{64}", revision["sha256"]) is None):
        raise Fail("%s has an invalid sha256" % owner)
    return revision


def validate_release_catalog(
    catalog: dict, output_root: str, verify_files: bool = True
) -> dict:
    if not isinstance(catalog, dict):
        raise Fail("release catalog must be a JSON object")
    if set(catalog) != {"schema", "generated_at", "families"}:
        raise Fail("release catalog has unexpected or missing top-level keys")
    schema = catalog["schema"]
    if (not is_whole_number(schema) or
            schema not in (
                RELEASE_CATALOG_LEGACY_SCHEMA,
                RELEASE_CATALOG_SINGLE_SCHEMA,
                RELEASE_CATALOG_SCHEMA)):
        raise Fail(
            "release catalog schema must be %d, %d, or %d"
            % (
                RELEASE_CATALOG_LEGACY_SCHEMA,
                RELEASE_CATALOG_SINGLE_SCHEMA,
                RELEASE_CATALOG_SCHEMA,
            )
        )
    families = catalog["families"]
    if not isinstance(families, dict) or set(families) != set(FAMILIES):
        raise Fail("release catalog must list exactly c6, s3, and p4")
    root = os.path.realpath(output_root)
    required_entry = {
        "latest_version", "artifact", "sha256", "bytes", "chip",
        "profiles", "hardware", "compatibility",
    }
    if schema >= RELEASE_CATALOG_SINGLE_SCHEMA:
        required_entry.add("latest_build")
    if schema == RELEASE_CATALOG_SCHEMA:
        required_entry.add("revisions")
    required_compatibility = {
        "flash_bytes", "partition_scheme", "bootloader_address",
        "partitions_address", "boot_app0_address", "app_address",
        "identity_required",
    }
    for key, family in FAMILIES.items():
        entry = families[key]
        if not isinstance(entry, dict) or set(entry) != required_entry:
            raise Fail("release catalog family %s has unexpected or missing keys" % key)
        version = entry["latest_version"]
        if not isinstance(version, str) or parse_semver(version) is None:
            raise Fail("release catalog family %s has a non-SemVer version" % key)
        build = entry.get("latest_build")
        if schema >= RELEASE_CATALOG_SINGLE_SCHEMA:
            if (not is_whole_number(build) or
                    not 1 <= build <= FIRMWARE_BUILD_MAX):
                raise Fail("release catalog family %s has an invalid build" % key)
        else:
            build = None
        relative = entry["artifact"]
        if not release_artifact_is_canonical(relative, key, version, build):
            raise Fail("release catalog family %s has a non-canonical artifact path" % key)
        latest_revision = {
            "version": version,
            "build": build,
            "artifact": relative,
            "sha256": entry["sha256"],
            "bytes": entry["bytes"],
        }
        if schema == RELEASE_CATALOG_SCHEMA:
            revisions = entry["revisions"]
            if (not isinstance(revisions, list) or
                    len(revisions) != RELEASE_CATALOG_REVISION_LIMIT):
                raise Fail(
                    "release catalog family %s must carry exactly %d revisions"
                    % (key, RELEASE_CATALOG_REVISION_LIMIT)
                )
            revisions = [
                validate_release_revision_shape(
                    revision, key, "release catalog family %s revision %d" % (
                        key, index))
                for index, revision in enumerate(revisions)
            ]
            if revisions[0] != latest_revision:
                raise Fail(
                    "release catalog family %s latest aliases do not match revision 0"
                    % key)
            builds = [revision["build"] for revision in revisions]
            artifacts = [revision["artifact"] for revision in revisions]
            if (len(set(builds)) != len(builds) or
                    len(set(artifacts)) != len(artifacts) or
                    any(left <= right for left, right in zip(builds, builds[1:]))):
                raise Fail(
                    "release catalog family %s revisions are not unique and newest first"
                    % key)
        else:
            revisions = [latest_revision]
        if entry["chip"] != family.chip:
            raise Fail("release catalog family %s has the wrong chip" % key)
        if entry["profiles"] != list(family.profiles):
            raise Fail("release catalog family %s has incompatible profiles" % key)
        hardware = entry["hardware"]
        if not isinstance(hardware, dict) or set(hardware) != set(family.profiles):
            raise Fail("release catalog family %s has incomplete hardware mappings" % key)
        for profile in family.profiles:
            if hardware[profile] != list(family.hardware[profile]):
                raise Fail("release catalog family %s hardware mapping drifted" % key)
        compatibility = entry["compatibility"]
        if (not isinstance(compatibility, dict) or
                set(compatibility) != required_compatibility):
            raise Fail("release catalog family %s compatibility is incomplete" % key)
        expected_compatibility = release_catalog_entry(
            family, version, build or 1, relative, b"x")["compatibility"]
        if compatibility != expected_compatibility:
            raise Fail("release catalog family %s compatibility does not match its build" % key)
        if not is_whole_number(entry["bytes"]) or entry["bytes"] <= 0:
            raise Fail("release catalog family %s has an invalid byte size" % key)
        if (not isinstance(entry["sha256"], str) or
                re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]) is None):
            raise Fail("release catalog family %s has an invalid sha256" % key)
        if verify_files:
            for index, revision in enumerate(revisions):
                path = os.path.realpath(os.path.join(root, revision["artifact"]))
                try:
                    contained = os.path.commonpath([root, path]) == root
                except ValueError:
                    contained = False
                if not contained:
                    raise Fail(
                        "release catalog family %s artifact escapes the release root"
                        % key)
                data = read_binary(path)
                if len(data) != revision["bytes"]:
                    raise Fail(
                        "release catalog family %s revision %d byte size is stale"
                        % (key, index))
                if sha256_hex(data) != revision["sha256"]:
                    raise Fail(
                        "release catalog family %s revision %d sha256 is stale"
                        % (key, index))
                manifest, payloads, flash_payloads = unpack_bundle(data)
                if (manifest.get("firmware_version") != revision["version"] or
                        (revision["build"] is not None and
                         validated_manifest_firmware_build(manifest)
                            != revision["build"]) or
                        set(payloads) != {key} or
                        set(flash_payloads) != {key} or
                        len(manifest.get("images") or []) != 1):
                    raise Fail(
                        "release catalog family %s revision %d bundle metadata disagrees"
                        % (key, index))
                image = manifest["images"][0]
                if (image.get("chip") != family.chip or
                        image.get("targets") != [key] or
                        image.get("profiles") != list(family.profiles) or
                        image.get("flash_sizes") != list(family.flash_sizes)):
                    raise Fail(
                        "release catalog family %s revision %d bundle identity disagrees"
                        % (key, index))
                partition = flash_payloads[key].get(FLASH_ROLE_PARTITIONS)
                if partition is None:
                    raise Fail(
                        "release catalog family %s revision %d bundle lacks partitions"
                        % (key, index))
                _verify_app_payload(
                    family, partition, image.get("app_address"), image.get("bytes"))
                if index == 0:
                    if image.get("partition") != family.partition_scheme:
                        raise Fail(
                            "release catalog family %s latest bundle identity disagrees"
                            % key)
                    _verify_partition_payload(family, partition)
                    _verify_required_doom_flash_payload(
                        family, partition, image, flash_payloads[key])
    return catalog


def load_release_catalog(path: str, verify_files: bool = True) -> dict:
    raw = read_binary(path)
    duplicate = first_duplicate_json_member_name(raw)
    try:
        catalog = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise Fail("release catalog is not valid UTF-8 JSON: %s" % exc)
    if duplicate is not None:
        raise Fail("release catalog has duplicate key %s" %
                   safe_json_key_display(duplicate))
    return validate_release_catalog(
        catalog, os.path.dirname(os.path.abspath(path)), verify_files=verify_files)


def write_release_catalog(path: str, catalog: dict) -> None:
    validate_release_catalog(
        catalog, os.path.dirname(os.path.abspath(path)), verify_files=True)
    write_file_atomically(path, encode_manifest(catalog) + b"\n")


def cmd_release_info(args) -> int:
    catalog = load_release_catalog(args.path, verify_files=True)
    for key in FAMILIES:
        entry = catalog["families"][key]
        revisions = entry.get("revisions") or [entry]
        for revision in revisions:
            print(revision["artifact"])
    return 0


def cmd_release(args) -> int:
    version, version_line = sketch_fw_version_declaration()
    if parse_semver(version) is None:
        raise Fail("firmware/display_stream/app_state.cpp:%d: %s" % (
            version_line, RELEASE_REASON_FW_VERSION % quote_release_value(version)))
    release_notes_for_version(RELEASE_NOTES_PATH, version)
    build = git_firmware_build()
    identity = firmware_identity(version, build.number, build.branch_suffix)
    output_root = firmware_output_root(args.output_root, build)
    os.makedirs(output_root, exist_ok=True)
    staged_root = tempfile.mkdtemp(prefix="espdisp-release-")
    try:
        for key in FAMILIES:
            path = os.path.join(
                staged_root, "espdisp-%s-%s%s" % (
                    key, identity, BUNDLE_SUFFIX))
            cmd_bundle(type("BundleArgs", (), {
                "family": [key], "output": path, "firmware_build": build})())
        for key in FAMILIES:
            directory = os.path.join(output_root, key)
            os.makedirs(directory, exist_ok=True)
            filename = "espdisp-%s-%s%s" % (
                key, identity, BUNDLE_SUFFIX)
            write_file_atomically(
                os.path.join(directory, filename),
                read_binary(os.path.join(staged_root, filename)))
    finally:
        shutil.rmtree(staged_root, ignore_errors=True)
    catalog = release_catalog(version, build, output_root)
    catalog_path = os.path.join(output_root, RELEASE_CATALOG_NAME)
    write_release_catalog(catalog_path, catalog)
    print("\nWrote firmware catalog %s" % catalog_path)
    return 0


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


def validate_family_build_contract(board: Family) -> None:
    """Refuse a canonical family target whose required composition is incomplete."""
    if not board.requires_doom_wad:
        return
    if "-DESPDISP_DOOM_RUNTIME" not in board.extra_flags:
        raise Fail(
            "canonical %s build requires -DESPDISP_DOOM_RUNTIME; refusing an "
            "image with the profile-gated Doom entry path compiled out"
            % board.key.upper()
        )
    if "firmware" not in board.extra_library_dirs:
        raise Fail(
            "canonical %s build requires the firmware library path; refusing an "
            "image that cannot link the Doom source"
            % board.key.upper()
        )


DOOM_APP_MARKERS = (
    b"button: Doom requested; rebooting into isolated mode",
    b"[doom] Display bridge ready (reusing existing panel)",
)


def validate_family_app_contract(board: Family, app: bytes) -> None:
    """Refuse an exported canonical image that did not link its required feature."""
    if not board.requires_doom_wad:
        return
    missing = [marker for marker in DOOM_APP_MARKERS if marker not in app]
    if missing:
        raise Fail(
            "canonical %s application is missing linked Doom markers: %s"
            % (
                board.key.upper(),
                ", ".join(marker.decode("ascii") for marker in missing),
            )
        )


def compile_board(board: Family, output_dir: Optional[str] = None) -> List[str]:
    validate_family_build_contract(board)
    if not os.path.isdir(SKETCH_DIR):
        raise Fail("sketch directory not found: %s" % SKETCH_DIR)

    build_sketch_dir = SKETCH_DIR
    staged_root: Optional[str] = None
    cmd = [arduino_cli(), "compile", "-b", board.fqbn, "--libraries", LIBRARIES_DIR]
    for relative in board.extra_library_dirs:
        cmd += ["--libraries", os.path.join(REPO_ROOT, relative)]
    if board.partition_csv:
        partition_source = os.path.join(
            REPO_ROOT, "firmware", board.partition_csv)
        if not os.path.isfile(partition_source):
            raise Fail("partition table not found: %s" % partition_source)
        # Custom schemes read partitions.csv from the sketch. Every target gets
        # a private copy so tables cannot leak between concurrent builds.
        staged_root = tempfile.mkdtemp(prefix="espdisp-sketch-%s-" % board.key)
        build_sketch_dir = os.path.join(staged_root, "display_stream")
        shutil.copytree(
            SKETCH_DIR, build_sketch_dir,
            ignore=shutil.ignore_patterns("build", "partitions.csv"),
        )
        shutil.copy2(partition_source,
                     os.path.join(build_sketch_dir, "partitions.csv"))
    elif os.path.exists(os.path.join(SKETCH_DIR, "partitions.csv")):
        raise Fail(
            "unexpected firmware/display_stream/partitions.csv would override "
            "%s's standard partition scheme" % board.key
        )

    if board.extra_flags:
        flags = " ".join(board.extra_flags)
        cmd += [
            "--build-property", "compiler.c.extra_flags=%s" % flags,
            "--build-property", "compiler.cpp.extra_flags=%s" % flags,
        ]
    if output_dir:
        # Arduino's default sketch cache is shared by every compile of this
        # sketch, even when each caller has a distinct --output-dir. Concurrent
        # target builds can then delete or replace one another's generated
        # sources and objects. Keep the build intermediates beside this export;
        # callers already own and remove the per-operation output directory.
        cmd += [
            "--build-path", os.path.join(output_dir, "build"),
            "--output-dir", output_dir,
        ]
    try:
        lines = run_streaming(cmd + ["."], cwd=build_sketch_dir)
        if output_dir:
            validate_family_app_contract(
                board, read_binary(app_image(output_dir)))
        return lines
    finally:
        if staged_root:
            shutil.rmtree(staged_root, ignore_errors=True)


def app_image(output_dir: str) -> str:
    """Pick the application image out of a --output-dir export.

    Deliberately narrow. That directory also holds <sketch>.ino.merged.bin, a
    whole-flash image with the bootloader and partition table in it - correct for
    esptool over USB, wrong for OTA, and 8MB of wrong at that. Only the bare
    <sketch>.ino.bin goes into an app slot.

    A BUNDLE STILL DOES NOT CARRY merged.bin. It is padded to the target's full
    flash size — 8 MB for C6 and 16 MB for either S3 target — so carrying one
    merged image per exact target would add tens of megabytes, mostly padding.
    The individual bootloader, partition, and boot_app0 parts cost about 31 KB
    per target. merged.bin also describes a whole-flash write that would erase
    NVS, where WiFi credentials and the panel name live.
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
    board: Family, output_dir: str
) -> Tuple[List[dict], Dict[str, bytes]]:
    """The three extra payloads a blank board needs, with their flash addresses.

    Two come out of the compile's export; boot_app0.bin comes out of the installed
    core, because that is where the core's own upload recipe gets it
    (platform.txt:346). Returns pre-offset manifest entries in write order and
    {role: bytes} - bundle_manifest fills the offsets in.
    """
    bootloader_address = core_bootloader_address(board.chip)
    expected_bootloader = PLATFORMS[board.platform].bootloader_address
    if bootloader_address != expected_bootloader:
        raise Fail(
            "%s core bootloader address is 0x%x; target %s requires 0x%x"
            % (board.chip, bootloader_address, board.key, expected_bootloader)
        )
    sources = [
        (
            FLASH_ROLE_BOOTLOADER,
            bootloader_address,
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


def ota_target_requires_exact_discovery(family: Family) -> bool:
    return True


def verify_ota_target(family: Family, host: str, timeout: float) -> None:
    """Fail closed unless discovery supplies all independent identity fields."""
    print("Checking what %s says it is..." % host, flush=True)
    found = network_port_for_host(discovered_network_ports(timeout), host)
    if found is None:
        raise Fail(
            "%s was not found with family, chip, profile, and partition metadata; "
            "refusing OTA" % host)
    verdict = classify_ota_target(
        family, found.target, found.board, found.profile, found.partition)
    if verdict == TARGET_OLD_LAYOUT:
        raise Fail(
            "%s reports the old partition layout %r; OTA cannot replace a "
            "partition table, so this board needs a full USB write"
            % (host, found.partition)
        )
    if verdict != TARGET_OK:
        raise Fail(
            "%s reports family=%r chip=%r profile=%r partition=%r; expected "
            "family=%s chip=%s one of profiles=%s partition=%s"
            % (host, found.target, found.board, found.profile, found.partition,
               family.key, family.chip, ",".join(family.profiles),
               family.partition_scheme))
    print("  Confirmed family=%s chip=%s profile=%s partition=%s." %
          (found.target, found.board, found.profile, found.partition))


def board_keys_for_chip(chip: str) -> List[str]:
    token = (chip or "").strip().lower()
    return [family.key for family in FAMILIES.values() if family.chip == token]


def board_key_for_chip(chip: str) -> Optional[str]:
    matches = board_keys_for_chip(chip)
    return matches[0] if len(matches) == 1 else None


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

    # Merged horizontal runs split to fill each datagram, like the real
    # sender's TilePacker - not one record per tile. This tool originally
    # emitted per-tile records, which misrepresented the load in two ways at
    # once: 4 bytes of record header per TILE instead of per run (a
    # ~2.9 KB/frame overstatement), and a per-record decode entry on the
    # panel for every tile - 719 of them instead of dozens, which overstated
    # the receive task's fixed costs and made the firmware's
    # run-length-gated paths (CFGTUNE directmin) unreachable from this tool
    # entirely.
    runs = []
    for tile in visible:
        if runs and tile == runs[-1][0] + runs[-1][1] \
                and tile % cols != 0 and runs[-1][1] < 32:
            runs[-1][1] += 1
        else:
            runs.append([tile, 1])

    def encode(start, run_len, seed):
        """One record for `run_len` tiles from `start`, and the next seed."""
        tx, ty = start % cols, start // cols
        x0 = tx * TILE_DIM
        w = min((tx + run_len) * TILE_DIM, width) - x0
        h = min(TILE_DIM, height - ty * TILE_DIM)
        if half:
            payload, seed = bc1_noise_tile(seed, half_dim(w), half_dim(h))
        else:
            payload, seed = bc1_noise_tile(seed, w, h)
        return tile_record(start, run_len, codec, payload), seed

    # Conservative per-tile cost for the split decision: a full 16x16 tile
    # is 16 BC1 blocks (128 B), an 8x8 half raster is 4 (32 B); edge tiles
    # only shrink a record below the estimate, never past it.
    per_tile = 32 if half else 128
    packets = []
    current, size, first = [], 6, None

    def flush():
        nonlocal current, size, first
        if current:
            packets.append(tile_header(frame_id, first, len(visible))
                           + b"".join(current))
        current, size, first = [], 6, None

    for start, run_len in runs:
        while run_len > 0:
            take = min(run_len, (TILE_PACKET_BUDGET - size - 4) // per_tile)
            if take < 1:
                flush()
                continue
            record, seed = encode(start, take, seed)
            if first is None:
                first = start
            current.append(record)
            size += len(record)
            start += take
            run_len -= take
    flush()
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
    family = FAMILIES[args.family]
    report_sizes(compile_board(family))
    return 0


def bundle_flash_plan(
    family: Family, image: dict, app: bytes, flash_payloads: Dict[str, bytes]
) -> List[Tuple[int, str, bytes]]:
    """Return every required bundle payload in deterministic write order."""
    parts = {
        part["role"]: part
        for part in image.get("flash_parts") or []
        if isinstance(part, dict) and isinstance(part.get("role"), str)
    }
    writes = []
    for role in REQUIRED_FLASH_ROLES:
        part = parts.get(role)
        payload = flash_payloads.get(role)
        if part is None or payload is None:
            raise Fail("canonical bundle carries no %s payload" % role)
        writes.append((part["address"], role, payload))
    if family.requires_doom_wad:
        part = parts.get(_DOOM_WAD_FLASH_ROLE)
        payload = flash_payloads.get(_DOOM_WAD_FLASH_ROLE)
        if part is None or payload is None:
            raise Fail("canonical bundle carries no doom_wad payload")
        writes.append((part["address"], _DOOM_WAD_FLASH_ROLE, payload))
    writes.append((image["app_address"], "app", app))
    clash = conflicting_flash_address(
        [(address, role) for address, role, _ in writes])
    if clash:
        raise Fail(
            "canonical bundle writes both %s and %s to flash address 0x%x"
            % (clash[1], clash[2], clash[0]))
    return sorted(writes, key=lambda write: write[0])


def canonical_family_value(values: dict, family: Family):
    """Return one family entry without leaking a KeyError to the CLI."""
    if family.key not in values:
        raise Fail("no canonical release for family %s" % family.key)
    return values[family.key]


def flash_canonical_release(
    family: Family, port_address: str, catalog_path: Optional[str] = None
) -> Tuple[str, str]:
    """Verify and flash one family from the committed canonical release catalog."""
    catalog_path = catalog_path or os.path.join(RELEASE_ROOT, RELEASE_CATALOG_NAME)
    catalog = load_release_catalog(catalog_path, verify_files=True)
    release_root = os.path.dirname(os.path.abspath(catalog_path))
    entry = canonical_family_value(catalog["families"], family)
    artifact = os.path.realpath(
        os.path.join(release_root, entry["artifact"]))
    data = read_binary(artifact)
    if len(data) != entry["bytes"] or sha256_hex(data) != entry["sha256"]:
        raise Fail(
            "canonical %s artifact changed after catalog verification"
            % family.key)
    manifest, payloads, flash_payloads = unpack_bundle(data)
    image = manifest["images"][0]
    writes = bundle_flash_plan(
        family, image,
        canonical_family_value(payloads, family),
        canonical_family_value(flash_payloads, family))

    tool = esptool_path()
    if not tool:
        raise Fail("esptool not found (install the esp32 Arduino core)")
    command = [tool]
    if tool.endswith(".py"):
        command = [sys.executable, tool]
    command.extend([
        "--chip", family.chip,
        "--port", port_address,
        "--baud", family.upload_speed,
        "write_flash",
    ])

    directory = tempfile.mkdtemp(prefix="espdisp-flash-%s-" % family.key)
    try:
        for address, role, payload in writes:
            path = os.path.join(directory, "%s.bin" % role)
            with open(path, "wb") as out:
                out.write(payload)
            command.extend(["0x%X" % address, path])
        run_streaming(command)
    finally:
        shutil.rmtree(directory, ignore_errors=True)
    return artifact, manifest["firmware_version"]


def cmd_flash(args) -> int:
    port = resolve_port(args.port)
    family = resolve_family(args.family, port, args.profile)
    print("Family: %s (%s) on %s" %
          (family.key, family.fqbn, port.address), flush=True)
    artifact, version = flash_canonical_release(family, port.address)
    print(
        "\nFlashed canonical %s release %s from %s"
        % (family.key, version, artifact))
    return 0


# WAD auto-download and flash for every canonical Doom-capable family.
# The digest is the canonical shareware v1.9 IWAD (MD5
# f0cefca49926d00903cf57551d901abe). Size plus SHA-256 is checked before any
# bundle or raw write so a mirror change cannot silently reach a device.
_DOOM_WAD_PATH = os.path.join(REPO_ROOT, "firmware", "doom", "doom1.wad")
_DOOM_WAD_URL = "https://raw.githubusercontent.com/nneonneo/universal-doom/main/DOOM1.WAD"
_DOOM_WAD_SIZE = 4196020
_DOOM_WAD_SHA256 = "1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771"
_DOOM_WAD_PARTITION_SIZE = 0x401000
_DOOM_WAD_FLASH_ROLE = "doom_wad"


def _partition_entries(blob: bytes) -> List[Tuple[str, int, int, int, int]]:
    """Decode the fixed 32-byte ESP partition entries needed for safety checks."""
    entries = []
    labels = set()
    for offset in range(0, len(blob), 32):
        entry = blob[offset:offset + 32]
        if len(entry) < 32 or entry[:2] in (b"\xff\xff", b"\xeb\xeb"):
            break
        if entry[:2] != b"\xaaP":
            raise Fail("partition table has invalid magic at byte %d" % offset)
        part_type = entry[2]
        subtype = entry[3]
        address, size = struct.unpack_from("<II", entry, 4)
        label = entry[12:28].split(b"\0", 1)[0].decode("ascii", errors="replace")
        if not label or label in labels:
            raise Fail("partition table has an empty or duplicate label %r" % label)
        labels.add(label)
        entries.append((label, part_type, subtype, address, size))
    if not entries:
        raise Fail("partition table contains no entries")
    return entries


def _doom_wad_partition(blob: bytes) -> Tuple[int, int]:
    matches = [
        entry for entry in _partition_entries(blob)
        if entry[0] == _DOOM_WAD_FLASH_ROLE
    ]
    if len(matches) != 1:
        raise Fail("partition table must contain exactly one doom_wad entry")
    _, part_type, subtype, address, size = matches[0]
    if part_type != 0x42 or subtype != 0x06:
        raise Fail(
            "doom_wad partition has type/subtype 0x%02X/0x%02X, expected 0x42/0x06"
            % (part_type, subtype)
        )
    if size != _DOOM_WAD_PARTITION_SIZE:
        raise Fail(
            "doom_wad partition is %d bytes, expected %d"
            % (size, _DOOM_WAD_PARTITION_SIZE)
        )
    return address, size


def _verify_partition_payload(family: Family, blob: bytes) -> None:
    entries = _partition_entries(blob)
    by_label = {entry[0]: entry[1:] for entry in entries}
    if family.key == "p4":
        expected = {
            "nvs": (0x01, 0x02, 0x009000, 0x005000),
            "otadata": (0x01, 0x00, 0x00E000, 0x002000),
            "app0": (0x00, 0x10, 0x010000, 0x800000),
            "app1": (0x00, 0x11, 0x810000, 0x800000),
            "doom_wad": (0x42, 0x06, 0x1010000, 0x401000),
        }
    elif family.key == "s3":
        expected = {
            "nvs": (0x01, 0x02, 0x009000, 0x005000),
            "otadata": (0x01, 0x00, 0x00E000, 0x002000),
            "app0": (0x00, 0x10, 0x010000, 0x1F0000),
            "app1": (0x00, 0x11, 0x200000, 0x1F0000),
            "doom_wad": (0x42, 0x06, 0x3FF000, 0x401000),
        }
    elif family.key == "c6":
        if any(entry[0] == "doom_wad" for entry in entries):
            raise Fail("c6 partition table contains an incompatible payload")
        return
    else:
        raise Fail("unrecognised firmware family %s" % family.key)
    if set(by_label) != set(expected):
        raise Fail("%s partition labels are %s, expected %s" %
                   (family.key, ", ".join(sorted(by_label)),
                    ", ".join(sorted(expected))))
    for label, want in expected.items():
        if by_label[label] != want:
            raise Fail("%s partition %s is %r, expected %r" %
                       (family.key, label, by_label[label], want))


def _verify_app_payload(
    board: Family, partition_blob: bytes, app_address: int, app_bytes: int
) -> None:
    app_partitions = [
        entry for entry in _partition_entries(partition_blob)
        if entry[1] == 0x00 and entry[3] == app_address
    ]
    if len(app_partitions) != 1:
        raise Fail(
            "%s partition table has no unique app partition at 0x%X"
            % (board.key, app_address)
        )
    capacity = app_partitions[0][4]
    if app_bytes <= 0 or app_bytes > capacity:
        raise Fail(
            "%s application is %d bytes but its app partition holds %d"
            % (board.key, app_bytes, capacity)
        )


def _validate_doom_wad(path: str, require_shareware: bool = False) -> None:
    """Refuse a WAD that cannot safely be written to the declared partition."""
    if not os.path.isfile(path):
        raise Fail("WAD file not found: %s" % path)
    size = os.path.getsize(path)
    if size > _DOOM_WAD_PARTITION_SIZE:
        raise Fail(
            "WAD file too large: %d bytes (partition is %d bytes)"
            % (size, _DOOM_WAD_PARTITION_SIZE)
        )
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:4] not in (b"IWAD", b"PWAD"):
        raise Fail(
            "Not a valid WAD file (magic: %s, expected IWAD or PWAD)"
            % data[:4].hex()
        )
    if require_shareware:
        digest = hashlib.sha256(data).hexdigest()
        if size != _DOOM_WAD_SIZE or digest != _DOOM_WAD_SHA256:
            raise Fail(
                "doom1.wad is not the verified shareware v1.9 image "
                "(bytes=%d sha256=%s)" % (size, digest)
            )


def _add_required_doom_wad_flash_part(
    family: Family, partition_blob: bytes,
    entries: List[dict], payloads: Dict[str, bytes],
) -> None:
    """Add the verified WAD required by a canonical family bundle."""
    if not family.requires_doom_wad:
        return
    address, capacity = _doom_wad_partition(partition_blob)
    wad_path = _ensure_doom_wad()
    if wad_path is None:
        raise Fail("%s bundle requires the verified doom1.wad payload" % family.key)
    _validate_doom_wad(wad_path, require_shareware=True)
    blob = read_binary(wad_path)
    if len(blob) > capacity:
        raise Fail(
            "%s WAD is %d bytes but its partition holds %d"
            % (family.key, len(blob), capacity)
        )
    if _DOOM_WAD_FLASH_ROLE in payloads:
        raise Fail("%s bundle already contains a doom_wad payload" % family.key)
    entries.append({
        "role": _DOOM_WAD_FLASH_ROLE,
        "address": address,
        "filename": os.path.basename(wad_path),
        "bytes": len(blob),
        "sha256": sha256_hex(blob),
    })
    payloads[_DOOM_WAD_FLASH_ROLE] = blob


def _verify_required_doom_flash_payload(
    family: Family, partition_blob: bytes, image: dict,
    flash_payloads: Dict[str, bytes],
) -> None:
    """Fail closed when a Doom-required family lacks the canonical WAD write."""
    raw_parts = image.get("flash_parts") or []
    if not isinstance(raw_parts, list):
        raise Fail("%s bundle flash_parts must be a list" % family.key)
    if not family.requires_doom_wad:
        if (_DOOM_WAD_FLASH_ROLE in flash_payloads or any(
                part.get("role") == _DOOM_WAD_FLASH_ROLE
                for part in raw_parts
                if isinstance(part, dict))):
            raise Fail("%s bundle must not carry a doom_wad flash part" % family.key)
        return
    address, capacity = _doom_wad_partition(partition_blob)
    parts = [
        part for part in raw_parts
        if isinstance(part, dict)
        if part.get("role") == _DOOM_WAD_FLASH_ROLE
    ]
    payload = flash_payloads.get(_DOOM_WAD_FLASH_ROLE)
    if len(parts) != 1 or payload is None:
        raise Fail("%s bundle lacks its required doom_wad flash part" % family.key)
    part = parts[0]
    digest = sha256_hex(payload)
    if (part.get("address") != address or
            part.get("bytes") != len(payload) or
            part.get("sha256") != digest):
        raise Fail("%s doom_wad metadata does not match its partition/payload" % family.key)
    if (len(payload) != _DOOM_WAD_SIZE or len(payload) > capacity or
            digest != _DOOM_WAD_SHA256 or payload[:4] != b"IWAD"):
        raise Fail("%s bundle does not carry the verified shareware doom1.wad" % family.key)


def _ensure_doom_wad() -> Optional[str]:
    """Return a verified shareware IWAD, downloading atomically if needed."""
    if os.path.isfile(_DOOM_WAD_PATH):
        try:
            _validate_doom_wad(_DOOM_WAD_PATH, require_shareware=True)
            return _DOOM_WAD_PATH
        except Fail as exc:
            print("  %s; re-downloading..." % exc, file=sys.stderr)

    print("  Downloading verified doom1.wad shareware v1.9 (4.0 MB)...", flush=True)
    download = _DOOM_WAD_PATH + ".download"
    try:
        import urllib.request
        urllib.request.urlretrieve(_DOOM_WAD_URL, download)
        _validate_doom_wad(download, require_shareware=True)
        os.replace(download, _DOOM_WAD_PATH)
    except Exception as exc:
        try:
            os.unlink(download)
        except OSError:
            pass
        print("  Download failed verification: %s" % exc, file=sys.stderr)
        print("  Doom is unavailable until the verified doom1.wad is present.")
        return None

    print("  doom1.wad ready (%d bytes, sha256 %s)"
          % (_DOOM_WAD_SIZE, _DOOM_WAD_SHA256))
    return _DOOM_WAD_PATH


def cmd_ota(args) -> int:
    # Password first: it is the one thing that can fail instantly, and finding out
    # after a multi-minute compile would be irritating.
    password = ota_password(args.password)
    tool = espota_path()
    family = FAMILIES[args.family]
    print("Family: %s (%s) over the air at %s" %
          (family.key, family.fqbn, args.host))
    if args.discovery_timeout <= 0:
        raise Fail("--discovery-timeout must be positive for family-safe OTA")
    verify_ota_target(family, args.host, args.discovery_timeout)

    out_dir = tempfile.mkdtemp(prefix="espdisp-ota-")
    try:
        lines = compile_board(family, output_dir=out_dir)
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
    # instantly, and finding out after all target builds would be irritating.
    # Same ordering, and the same reason, as cmd_ota's password.
    version, version_line = sketch_fw_version_declaration()
    if parse_semver(version) is None:
        raise Fail("firmware/display_stream/app_state.cpp:%d: %s" % (
            version_line, RELEASE_REASON_FW_VERSION % quote_release_value(version)))
    release_notes = release_notes_for_version(RELEASE_NOTES_PATH, version)
    keys = bundle_family_keys(args.family)
    boards = [FAMILIES[key] for key in keys]
    family_key = keys[0]
    build = getattr(args, "firmware_build", None) or git_firmware_build()
    identity = firmware_identity(version, build.number, build.branch_suffix)
    path = args.output or os.path.join(
        os.getcwd(), "espdisp-%s-%s%s" %
        (family_key, identity, BUNDLE_SUFFIX)
    )
    commit, dirty = git_provenance()
    print("Firmware %s (FW_VERSION in %s)"
          % (identity, os.path.relpath(FW_VERSION_SOURCE, REPO_ROOT)))
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
            partition_blob = part_payloads[FLASH_ROLE_PARTITIONS]
            _verify_partition_payload(board, partition_blob)
            _add_required_doom_wad_flash_part(
                board, partition_blob, parts, part_payloads)
            _verify_app_payload(board, partition_blob, APP_FLASH_ADDRESS, len(blob))
            image_entry = {
                "board": board.key,
                "targets": [board.key],
                "chip": board.chip,
                "profiles": list(board.profiles),
                "flash_sizes": list(board.flash_sizes),
                "partition": board.partition_scheme,
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
            _verify_required_doom_flash_payload(
                board, partition_blob, image_entry, part_payloads)
            entries.append(image_entry)
            payloads[board.key] = blob
            flash_payloads[board.key] = part_payloads
    finally:
        # Same shape as cmd_ota: the export directories go whatever happens, so an
        # interrupted build does not leave two megabytes per board in /tmp.
        for out_dir in out_dirs:
            shutil.rmtree(out_dir, ignore_errors=True)

    manifest = bundle_manifest(
        version, build.number, entries, utc_timestamp(), release_notes=release_notes,
        source_commit=commit, source_dirty=dirty)
    data = pack_bundle(manifest, payloads, flash_payloads)
    write_file_atomically(path, data)

    report_sizes(size_lines)
    print("\nWrote %s" % path)
    print("  size:     %d bytes (%.1f MiB)" % (len(data), len(data) / (1024.0 * 1024.0)))
    for line in describe_bundle(manifest):
        print(line)

    print(
        "\nHand this family bundle to the Mac app (or inspect it with `%s bundle-info`)."
        % os.path.basename(sys.argv[0])
    )
    return 0


def cmd_bundle_info(args) -> int:
    manifest, payloads, flash_payloads = read_bundle(args.path)
    current = sorted(set(payloads).intersection(FAMILIES))
    if manifest.get("format") == BUNDLE_FORMAT_V3 and current:
        if len(current) != 1 or len(payloads) != 1 or len(manifest.get("images") or []) != 1:
            raise Fail("current bundles must contain exactly one firmware family")
        family = FAMILIES[current[0]]
        roles = flash_payloads.get(family.key) or {}
        partition_blob = roles.get(FLASH_ROLE_PARTITIONS)
        if partition_blob is None:
            raise Fail("%s carries no partition table" % args.path)
        _verify_partition_payload(family, partition_blob)
        image = manifest["images"][0]
        if (image.get("targets") != [family.key] or
                image.get("chip") != family.chip or
                image.get("profiles") != list(family.profiles) or
                image.get("flash_sizes") != list(family.flash_sizes) or
                image.get("partition") != family.partition_scheme):
            raise Fail("bundle family compatibility metadata does not match its payload")
        _verify_app_payload(
            family, partition_blob, image.get("app_address"), image.get("bytes"))
        _verify_required_doom_flash_payload(
            family, partition_blob, image, roles)
    size = os.path.getsize(args.path)
    print("%s" % args.path)
    print("  size:     %d bytes (%.1f MiB)" % (size, size / (1024.0 * 1024.0)))
    for line in describe_bundle(manifest, full_hash=True):
        print(line)
    # unpack_bundle already refused anything that did not add up, so reaching here
    # is the verification result: say so, rather than leaving the user to infer it
    # from the absence of an error.
    image_count = len(manifest.get("images") or [])
    extra = sum(
        len(image.get("flash_parts") or [])
        for image in manifest.get("images") or []
        if isinstance(image, dict)
    )
    kind = "family" if current else "target"
    print(
        "\nVerified: %d image%s covering %d %s%s%s, contiguous, every sha256 matches."
        % (
            image_count,
            "" if image_count == 1 else "s",
            len(payloads),
            kind,
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
    absent = [key for key in FAMILIES if key not in payloads]
    if absent and not current:
        print(
            "Carries historical targets %s; missing %s."
            % (", ".join(sorted(payloads)), ", ".join(sorted(absent)))
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
    candidates = [
        p for p in ports
        if any(fnmatch.fnmatch(p.address, pattern) for pattern in PORT_GLOBS)
    ]
    if not candidates:
        print("No candidate ESP32 ports (looked for %s)." %
              ", ".join(PORT_GLOBS))
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
    return "\n".join(
        "  %-7s %s" % (family.key, family.blurb)
        for family in FAMILIES.values())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="espdisp.py",
        description=__doc__,
        epilog="families:\n" + board_help(),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # New subcommands plug in as another add_parser block plus one family entry.
    subs = parser.add_subparsers(dest="command", metavar="<command>")

    p_compile = subs.add_parser("compile", help="build one firmware family")
    p_compile.add_argument("--family", required=True, choices=family_choices())
    p_compile.set_defaults(func=cmd_compile)

    p_flash = subs.add_parser(
        "flash", help="flash one canonical family release over USB")
    p_flash.add_argument(
        "--family", choices=family_choices(),
        help="release family; otherwise derive it from the attached chip")
    p_flash.add_argument(
        "--profile", choices=sorted({profile for family in FAMILIES.values()
                                      for profile in family.profiles}),
        help="physical-profile cross-check; required for p4 recovery workflows")
    p_flash.add_argument(
        "--port", help="serial device (default: the one matching %s)" %
        ", ".join(PORT_GLOBS))
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
        "--family", required=True, choices=family_choices(),
        help="firmware family; discovery must also confirm chip, profile, and partition")
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
        help="seconds to require family/chip/profile/partition metadata (default 5)",
    )
    p_ota.set_defaults(func=cmd_ota)

    p_bundle = subs.add_parser(
        "bundle",
        help="compile and pack the firmware into one portable %s file" % BUNDLE_SUFFIX,
        description="Build exactly one family and write a portable bundle the Mac "
        "app can verify later. The file carries one application image plus its "
        "bootloader, partition table, and boot_app0. It never combines families.",
        epilog="The version is read out of the sketch (FW_VERSION in\n"
        "firmware/display_stream/app_state.cpp), never passed in, so the\n"
        "manifest cannot disagree with the images beside it.\n"
        "Inspect a file with `bundle-info`.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p_bundle.add_argument(
        "--family", required=True, action="append", choices=family_choices(),
        help="build exactly one family artifact; repeated values are refused")
    p_bundle.add_argument(
        "--output",
        help="where to write the bundle (default ./espdisp-<family>-<version>%s)"
        % BUNDLE_SUFFIX,
    )
    p_bundle.set_defaults(func=cmd_bundle)

    p_release = subs.add_parser(
        "release", help="build c6, s3, and p4 artifacts with a catalog")
    p_release.add_argument(
        "--output-root",
        help="artifact directory (default firmware-dev for build-numbered firmware)")
    p_release.set_defaults(func=cmd_release)

    p_release_info = subs.add_parser(
        "release-info", help="verify a canonical catalog and print its artifact paths")
    p_release_info.add_argument("path", help="path to firmware-releases/manifest.json")
    p_release_info.set_defaults(func=cmd_release_info)

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
