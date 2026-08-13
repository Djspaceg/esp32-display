#!/usr/bin/env python3
"""Tests for tools/espdisp.py. Run it: tools/test_espdisp.py"""
#
# WHY NO TEST FRAMEWORK: this repo has no Python test harness and adding pytest
# would put a third-party dependency in front of a tool whose whole premise is
# that it needs none - the machine it was written on has no pyserial, which is
# why espdisp.py drives a tty through termios in the first place. unittest would
# be stdlib, but firmware/test/run_tests.sh already sets the house style for a
# check-counting runner ("OK: N checks passed", non-zero exit on the first
# failure), and matching it means one shape of test output across the repo. So:
# a plain script, invoked by path, no harness, no dependencies.
#
# What is worth testing here is what the tool decides, not what it runs. The
# refusals are the point - resolve_board exists to refuse rather than guess a
# chip, classify_ota_target exists to refuse a push at the wrong panel, and
# check_password_policy exists to refuse a password the firmware would not store.
# Those guards were the only unguarded thing left in the change, and none of them
# need hardware to exercise.
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest.mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import espdisp  # noqa: E402

checks = 0
failures = 0


def check(condition, what):
    global checks, failures
    checks += 1
    if not condition:
        failures += 1
        print("FAIL: %s" % what)


def check_equal(got, want, what):
    check(got == want, "%s: got %r, want %r" % (what, got, want))


def check_fails(fn, needle, what):
    """A Fail is the tool's one user-facing error path: one line, no traceback."""
    global checks, failures
    checks += 1
    try:
        fn()
    except espdisp.Fail as exc:
        if needle not in str(exc):
            failures += 1
            print("FAIL: %s: message %r lacks %r" % (what, str(exc), needle))
        return
    except Exception as exc:  # noqa: BLE001 - a traceback is itself the bug
        failures += 1
        print("FAIL: %s: raised %s instead of Fail" % (what, type(exc).__name__))
        return
    failures += 1
    print("FAIL: %s: did not refuse" % what)


def check_accepts(fn, what):
    """The other half: something that must NOT refuse.

    Counted rather than just called, so a guard that becomes too strict is
    reported as a failure like any other instead of ending the run in a traceback.
    """
    global checks, failures
    checks += 1
    try:
        fn()
    except espdisp.Fail as exc:
        failures += 1
        print("FAIL: %s: refused with %r" % (what, str(exc)))
    except Exception as exc:  # noqa: BLE001
        failures += 1
        print("FAIL: %s: raised %s" % (what, type(exc).__name__))


# --------------------------------------------------------------------------
# the board table: these two strings are the reason the tool exists


def test_board_table():
    check_equal(
        espdisp.BOARDS["c6"].fqbn,
        "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M",
        "C6 FQBN",
    )
    check_equal(
        espdisp.BOARDS["s3"].fqbn,
        "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi",
        "S3 FQBN",
    )
    # No PartitionScheme= on either: the default table already has two app slots
    # and otadata, so OTA needed no change. If that ever has to change it must
    # change in the README too, and this is the tripwire.
    for key, board in espdisp.BOARDS.items():
        check("PartitionScheme" not in board.fqbn, "%s uses the default scheme" % key)
    check_equal(espdisp.board_key_for_fqbn("esp32:esp32:esp32c6"), "c6", "FQBN -> key")
    check_equal(
        espdisp.board_key_for_fqbn("esp32:esp32:esp32s3:PSRAM=opi"), "s3",
        "FQBN with options -> key")
    check_equal(espdisp.board_key_for_fqbn("esp32:esp32:esp32c3"), None, "unknown chip")
    check_equal(espdisp.board_key_for_fqbn("nonsense"), None, "malformed FQBN")
    check_equal(espdisp.board_key_for_chip("esp32c6"), "c6", "chip -> key")
    check_equal(espdisp.board_key_for_chip("ESP32S3"), "s3", "chip -> key, any case")
    check_equal(espdisp.board_key_for_chip(""), None, "no chip -> no key")


# --------------------------------------------------------------------------
# resolve_board: the refusal matrix, which is the guard against flashing the
# wrong image and was itself unguarded against regression


def test_resolve_board():
    c6_port = espdisp.PortInfo("/dev/cu.usbmodem1", ["c6"], "c6 board")
    s3_port = espdisp.PortInfo("/dev/cu.usbmodem2", ["s3"], "s3 board")
    blank = espdisp.PortInfo("/dev/cu.usbmodem3", [], "unknown")
    both = espdisp.PortInfo("/dev/cu.usbmodem4", ["c6", "s3"], "ambiguous")

    # arduino-cli named one board: that is the answer, no probing needed.
    check_equal(espdisp.resolve_board(None, c6_port).key, "c6", "port names c6")
    check_equal(espdisp.resolve_board(None, s3_port).key, "s3", "port names s3")

    # An explicit board agreeing with the port, and an explicit board for a port
    # arduino-cli could not identify - both fine.
    check_equal(espdisp.resolve_board("c6", c6_port).key, "c6", "explicit agrees")
    check_equal(espdisp.resolve_board("s3", blank).key, "s3", "explicit, port silent")
    check_equal(espdisp.resolve_board("c6", None).key, "c6", "explicit, no port")

    # An explicit board contradicting the port is refused, and the message names
    # both the fix and the escape hatch - there is no override flag, so a user
    # whose arduino-cli is wrong needs to be told where to go instead.
    check_fails(
        lambda: espdisp.resolve_board("s3", c6_port),
        "contradicts",
        "explicit board contradicting the port",
    )
    check_fails(
        lambda: espdisp.resolve_board("s3", c6_port),
        "no flag to override",
        "the refusal admits it cannot be overridden",
    )
    check_fails(
        lambda: espdisp.resolve_board("s3", c6_port),
        "arduino-cli compile -b esp32:esp32:esp32s3",
        "the refusal spells out the raw command as the way past",
    )

    # No board and nothing to go on: refuse, naming both choices. Probing is
    # tried first, so it is stubbed out - a real probe resets the board - and its
    # progress line is swallowed to keep this runner's output as quiet as
    # firmware/test/run_tests.sh.
    with unittest.mock.patch.object(
        espdisp, "probe_chip", return_value=None
    ), unittest.mock.patch("sys.stdout", io.StringIO()):
        check_fails(
            lambda: espdisp.resolve_board(None, blank),
            "could not determine which chip",
            "silent port, probe fails",
        )
        check_fails(
            lambda: espdisp.resolve_board(None, both),
            "could not determine which chip",
            "ambiguous port, probe fails",
        )
    # And when probing does answer, it is believed.
    with unittest.mock.patch.object(
        espdisp, "probe_chip", return_value="s3"
    ), unittest.mock.patch("sys.stdout", io.StringIO()):
        check_equal(espdisp.resolve_board(None, blank).key, "s3", "probe answers")
    check_fails(
        lambda: espdisp.resolve_board(None, None),
        "--board is required",
        "no port at all (the compile path)",
    )


# --------------------------------------------------------------------------
# the OTA target check: the network path had no equivalent of the USB
# cross-check, so --board was taken on trust over the wire


# A capture of the shape `arduino-cli board list --json` returns, with one
# serial port and one panel discovered by the bundled mdns-discovery. The
# property names are the ones mdns-discovery sets from the TXT record
# (arduino/mdns-discovery main.go toDiscoveryPort), and `board` is what
# ESPmDNS's enableArduino() publishes: ARDUINO_VARIANT, i.e. esp32c6 / esp32s3.
DISCOVERY_JSON = {
    "detected_ports": [
        {
            "port": {
                "address": "/dev/cu.usbmodem1101",
                "protocol": "serial",
                "properties": {"vid": "0x303A", "pid": "0x1001"},
            }
        },
        {
            "port": {
                "address": "192.168.1.42",
                "protocol": "network",
                "properties": {
                    "board": "esp32c6",
                    "hostname": "panel.local.",
                    "port": "3232",
                    "auth_upload": "yes",
                },
            }
        },
        {
            "port": {
                "address": "192.168.1.43",
                "protocol": "network",
                "properties": {
                    "board": "esp32s3",
                    "hostname": "round-panel.local.",
                    "port": "3232",
                },
            }
        },
    ]
}


def test_network_discovery():
    ports = espdisp.parse_network_ports(DISCOVERY_JSON)
    check_equal(len(ports), 2, "serial ports are not network ports")
    check_equal(ports[0].address, "192.168.1.42", "network address")
    check_equal(ports[0].board, "esp32c6", "board TXT record")
    check_equal(ports[0].hostname, "panel.local", "hostname, trailing dot stripped")

    # Nothing to parse is not an error: no panels found is a normal answer.
    check_equal(espdisp.parse_network_ports({}), [], "empty payload")
    check_equal(
        espdisp.parse_network_ports({"detected_ports": None}), [], "null ports")
    check_equal(
        espdisp.parse_network_ports(
            {"detected_ports": [{"port": {"protocol": "network"}}]}),
        [],
        "a network port with no address and no hostname is dropped")
    # A panel discovered but publishing no board record still resolves, so the
    # caller can say "found it, cannot place it" rather than nothing at all.
    partial = espdisp.parse_network_ports(
        {"detected_ports": [{"port": {
            "address": "10.0.0.5", "protocol": "network",
            "properties": {"hostname": "mystery.local."}}}]})
    check_equal(len(partial), 1, "board-less panel is still a port")
    check_equal(partial[0].board, "", "board-less panel has no board")

    # Every way a user names the same panel.
    for host in ("192.168.1.42", "panel.local", "panel.local.", "PANEL", "panel"):
        found = espdisp.network_port_for_host(ports, host)
        check(found is not None and found.board == "esp32c6", "host %r resolves" % host)
    check_equal(
        espdisp.network_port_for_host(ports, "round-panel.local").board,
        "esp32s3",
        "the other panel resolves to the other board")
    # An unknown host is None, never a guess: the caller must be able to tell
    # "not found" from "wrong board", because only one of them refuses.
    check_equal(
        espdisp.network_port_for_host(ports, "10.0.0.9"), None, "unknown address")
    check_equal(
        espdisp.network_port_for_host(ports, "other.local"), None, "unknown name")
    check_equal(espdisp.network_port_for_host(ports, ""), None, "empty host")
    check_equal(espdisp.network_port_for_host([], "panel.local"), None, "no panels")


def test_classify_ota_target():
    c6, s3 = espdisp.BOARDS["c6"], espdisp.BOARDS["s3"]

    check_equal(espdisp.classify_ota_target(c6, "esp32c6"), espdisp.TARGET_OK, "c6 ok")
    check_equal(espdisp.classify_ota_target(s3, "esp32s3"), espdisp.TARGET_OK, "s3 ok")
    check_equal(
        espdisp.classify_ota_target(c6, "ESP32C6 "), espdisp.TARGET_OK,
        "case and whitespace do not make a mismatch")

    # The case this whole check exists for.
    check_equal(
        espdisp.classify_ota_target(c6, "esp32s3"), espdisp.TARGET_WRONG,
        "S3 panel, C6 image")
    check_equal(
        espdisp.classify_ota_target(s3, "esp32c6"), espdisp.TARGET_WRONG,
        "C6 panel, S3 image")

    # Anything this tool cannot place is UNKNOWN, not WRONG. Refusing on an
    # unrecognised board would turn "I do not know" into "you are wrong", and
    # would break the day a third variant is added to the firmware first.
    for advertised in ("", "   ", "esp32c3", "esp32", "nonsense"):
        check_equal(
            espdisp.classify_ota_target(c6, advertised), espdisp.TARGET_UNKNOWN,
            "board=%r cannot be placed" % advertised)


def test_discovery_command():
    """The invocation that produces the payload every other check is fed by hand.

    Worth asserting precisely because getting it wrong is silent: run_capture
    turns an OSError into a non-zero result, a non-zero result becomes [], and []
    means "could not confirm", which prints a note and pushes. A typo here would
    not raise, it would quietly turn the guard off.
    """
    with unittest.mock.patch.object(espdisp, "arduino_cli", return_value="/bin/acli"):
        cmd = espdisp.discovery_command(5)

    check_equal(cmd[0], "/bin/acli", "the arduino-cli this tool resolved")
    check_equal(
        cmd[1:],
        ["board", "list", "--discovery-timeout", "5s", "--json"],
        "discovery argument shape")
    # The duration needs its unit or arduino-cli rejects it, and --json is what
    # makes the output parseable at all: both are easy to lose in an edit.
    check("5s" in cmd, "the timeout carries its unit")
    check("--json" in cmd, "output stays machine-readable")

    # Whole seconds, with a floor of one. A fractional flag value has to become an
    # integer somewhere, and "0s" would be a browse that cannot find anything -
    # indistinguishable from the guard being skipped, but without saying so.
    #
    # The 0 and negative cases pin the floor of a pure function, NOT a path the
    # CLI can reach: cmd_ota gates on `> 0`, so anything at or below zero skips
    # the check and never calls this. Kept because the floor is the function's
    # own contract - a caller that does not come through cmd_ota must not get a
    # `0s` browse either.
    check_equal(espdisp.discovery_seconds(5.0), 5, "the common case")
    check_equal(espdisp.discovery_seconds(0.4), 1, "a fraction still browses")
    check_equal(espdisp.discovery_seconds(0.0), 1, "never 0s")
    check_equal(espdisp.discovery_seconds(-3.0), 1, "nor negative")
    check_equal(espdisp.discovery_seconds(2.6), 3, "rounded, not truncated")
    with unittest.mock.patch.object(espdisp, "arduino_cli", return_value="/bin/acli"):
        check_equal(
            espdisp.discovery_command(espdisp.discovery_seconds(0.4))[4], "1s",
            "and the floor reaches the command line")


def test_verify_ota_target():
    c6 = espdisp.BOARDS["c6"]
    ports = espdisp.parse_network_ports(DISCOVERY_JSON)

    def run(board, host, discovered):
        """verify_ota_target with discovery stubbed, returning what it printed."""
        out = io.StringIO()
        with unittest.mock.patch.object(
            espdisp, "discovered_network_ports", return_value=discovered
        ), unittest.mock.patch("sys.stdout", out):
            espdisp.verify_ota_target(board, host, 5.0)
        return out.getvalue()

    check("Confirmed" in run(c6, "panel.local", ports), "agreement is confirmed")

    # A panel nobody can find is a warning, not a refusal. mDNS not answering is
    # not evidence about the chip, and pushing to a panel on another subnet -
    # which works today - must keep working.
    text = run(c6, "10.0.0.9", ports)
    check("Not found" in text, "an undiscovered panel is only a note")
    check("taken on trust" in text, "and says what that means")
    check(len(run(c6, "panel.local", [])) > 0, "discovery finding nothing is survivable")

    # A board it cannot place is also only a note.
    mystery = [espdisp.NetworkPort("10.0.0.5", "mystery.local", "esp32c3")]
    check("cannot place" in run(c6, "10.0.0.5", mystery), "unplaceable board is a note")

    # A definite contradiction refuses, and names the target to use instead.
    check_fails(
        lambda: run(c6, "round-panel.local", ports),
        "advertises board=esp32s3",
        "pushing a C6 image at the S3 panel")
    check_fails(
        lambda: run(c6, "round-panel.local", ports),
        "--board s3",
        "and the refusal names the right target")


# --------------------------------------------------------------------------
# the password: bounds in bytes, and the encoding the tool now owns


def test_password_policy():
    check_equal(espdisp.OTA_PASSWORD_MIN, 8, "floor matches the firmware")
    check_equal(espdisp.OTA_PASSWORD_MAX, 64, "ceiling matches the firmware")

    check_accepts(
        lambda: espdisp.check_password_policy("12345678"), "exactly the floor")
    check_accepts(
        lambda: espdisp.check_password_policy("x" * 64), "exactly the ceiling")

    check_fails(
        lambda: espdisp.check_password_policy("1234567"), "at least 8",
        "one byte under the floor")
    check_fails(
        lambda: espdisp.check_password_policy("x" * 65), "at most 64",
        "one byte over the ceiling")

    # Bytes, not characters, because that is what the firmware counts. Two
    # emoji are 8 bytes and acceptable; one is 4 and is not.
    check_accepts(
        lambda: espdisp.check_password_policy("\U0001F511\U0001F511"),
        "8 bytes of two characters")
    check_fails(
        lambda: espdisp.check_password_policy("\U0001F511"), "is 4 bytes",
        "4 bytes of one character is refused")
    # And a 64-character password of 2-byte characters is 128 bytes: refused,
    # where a character count would have waved it through.
    check_fails(
        lambda: espdisp.check_password_policy("\u00e9" * 64), "is 128 bytes",
        "a multi-byte password is measured in bytes")


def test_cfgotapw_line():
    # The whole reason this function exists: `echo 'pw' | base64` appends a
    # newline, storing a password one byte longer than the one typed, which then
    # fails every push with an auth error and no hint why. Encoding here cannot
    # make that mistake.
    check_equal(
        espdisp.cfgotapw_line("a-real-password"),
        "CFGOTAPW YS1yZWFsLXBhc3N3b3Jk",
        "base64 of the password, and nothing else")
    check(
        "\n" not in espdisp.cfgotapw_line("a-real-password"),
        "no newline anywhere in the line")
    # Round-trips to exactly the bytes the pusher will send, for a password full
    # of the characters base64 is there to protect.
    import base64 as b64

    for password in ("a-real-password", "with space", "quote'and\"dquote",
                     "\U0001F511\U0001F511", "tab\tand=equals", "12345678"):
        line = espdisp.cfgotapw_line(password)
        check(line.startswith("CFGOTAPW "), "the line is a CFGOTAPW command")
        check(" " not in line[len("CFGOTAPW "):],
              "the encoded argument has no space to break the line at: %r" % password)
        decoded = b64.b64decode(line[len("CFGOTAPW "):])
        check_equal(decoded, password.encode("utf-8"), "round trip of %r" % password)

    # "clear" is the panel's off switch and is compared before any decode, so an
    # encoded password can never be mistaken for it - including the password
    # "clear" itself, which encodes to something else entirely.
    check_equal(
        espdisp.cfgotapw_line("clearclear"), "CFGOTAPW Y2xlYXJjbGVhcg==",
        "a password containing the token is still just a payload")


def test_espota_command():
    cmd = espdisp.espota_command(
        "/core/tools/espota.py", "panel.local", 3232, "hunter2hunter2",
        "/tmp/out/display_stream.ino.bin", 10)

    check_equal(cmd[0], sys.executable, "run with this interpreter, not a bare python3")
    check_equal(cmd[1], "/core/tools/espota.py", "the core's own pusher")
    # The recipe the core uses (platform.txt line 384), plus -r for progress.
    check_equal(
        cmd[2:],
        ["-r", "-i", "panel.local", "-p", "3232", "-a", "hunter2hunter2",
         "-f", "/tmp/out/display_stream.ino.bin", "-t", "10"],
        "espota argument shape")
    check_equal(espdisp.OTA_PORT, 3232, "ArduinoOTA's default port")


def test_app_image_picks_the_app_not_the_flash_image():
    # mkdtemp rather than a fixed /tmp path, which is what cmd_ota already does
    # for the directory it exports into. The fixture matters here: this test adds
    # a second candidate image partway through to check the ambiguous case, so a
    # directory surviving from a previous run - two concurrent runs, a SIGKILL, or
    # a path another user on the machine already owns - poisons the FIRST check
    # rather than failing visibly at the end.
    tmp = tempfile.mkdtemp(prefix="espdisp-test-images-")
    # The export directory also holds <sketch>.ino.merged.bin - the whole-flash
    # image with the bootloader and partition table in it, right for esptool over
    # USB and 8MB of wrong for an app slot.
    for name in ("display_stream.ino.bin", "display_stream.ino.merged.bin",
                 "display_stream.ino.elf", "display_stream.ino.map"):
        with open(os.path.join(tmp, name), "w") as fh:
            fh.write("x")
    try:
        check_equal(
            os.path.basename(espdisp.app_image(tmp)), "display_stream.ino.bin",
            "the bare app image is chosen")

        empty = os.path.join(tmp, "empty")
        os.makedirs(empty, exist_ok=True)
        check_fails(
            lambda: espdisp.app_image(empty), "expected exactly one",
            "an empty directory is refused rather than pushing nothing")

        with open(os.path.join(tmp, "other.ino.bin"), "w") as fh:
            fh.write("x")
        check_fails(
            lambda: espdisp.app_image(tmp), "expected exactly one",
            "two candidate images are refused rather than picked between")
    finally:
        # rmtree rather than the hand-rolled walk this used to do: with mkdtemp the
        # directory is ours alone, so there is nothing to be careful about.
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------
# the firmware bundle: the file format is a contract with the Mac app, which
# reads it on a machine that may never have seen this repo, so both sides of it
# are pinned here - the byte layout because a silent change to it breaks a
# reader that cannot be recompiled from here, and every refusal individually
# because a bundle arriving from elsewhere is the one input this tool cannot
# trust at all.


# Two stand-ins for real images, small enough to assert on. FAKE_C6 contains both
# generations' bundle magic on purpose: the payload area is framed by the
# manifest's offsets, so a reader that scanned for a marker rather than doing
# arithmetic would find one here and go wrong. Both carry non-UTF-8 bytes, because
# an app image is not text and nothing in this path may treat it as text.
FAKE_C6 = b"\x00\x01\x02\xffc6 image ESPDISPFW2\nESPDISPFW1\n\x00 tail"
FAKE_S3 = bytes(range(256)) + b"\xffs3 image"


def fake_flash_payloads(key):
    """Stand-ins for the three parts a blank board needs, one set per board.

    Distinct per board on purpose: identical bytes would let a reader that mixed
    up whose bootloader is whose pass anyway. The leading bytes are the real magic
    of each kind of file - 0xE9 for an ESP image, 0xAA 0x50 for a partition table -
    so nothing here is accidentally plausible for the wrong role.
    """
    tag = key.encode("ascii")
    return {
        espdisp.FLASH_ROLE_BOOTLOADER: b"\xe9" + tag + b" bootloader\n",
        espdisp.FLASH_ROLE_PARTITIONS: b"\xaaP" + tag + b" table\n",
        espdisp.FLASH_ROLE_BOOT_APP0: b"ota " + tag + b"\n",
    }


def flash_entries(key):
    """The three pre-offset flash part entries for a board, in write order.

    The addresses are the real ones, not invented: the bootloader goes to 0x0 for
    both of this repo's chips (boards.txt gives esp32c6 and esp32s3
    build.bootloader_addr=0x0), the partition table to 0x8000 and boot_app0 to
    0xe000, which is the argv in platform.txt:346.
    """
    payloads = fake_flash_payloads(key)
    addresses = {
        espdisp.FLASH_ROLE_BOOTLOADER: 0x0,
        espdisp.FLASH_ROLE_PARTITIONS: 0x8000,
        espdisp.FLASH_ROLE_BOOT_APP0: 0xE000,
    }
    filenames = {
        espdisp.FLASH_ROLE_BOOTLOADER: "display_stream.ino.bootloader.bin",
        espdisp.FLASH_ROLE_PARTITIONS: "display_stream.ino.partitions.bin",
        espdisp.FLASH_ROLE_BOOT_APP0: "boot_app0.bin",
    }
    return [
        {
            "role": role,
            "address": addresses[role],
            "filename": filenames[role],
            "bytes": len(payloads[role]),
            "sha256": espdisp.sha256_hex(payloads[role]),
        }
        for role in espdisp.REQUIRED_FLASH_ROLES
    ]


def image_entry(key, blob):
    """One pre-offset manifest entry, the way cmd_bundle builds them."""
    return {
        "board": key,
        "chip": espdisp.BOARDS[key].chip,
        "fqbn": espdisp.BOARDS[key].fqbn,
        "filename": "display_stream.ino.bin",
        "bytes": len(blob),
        "sha256": espdisp.sha256_hex(blob),
        "app_address": 0x10000,
        "flash_parts": flash_entries(key),
    }


def payload_bytes(*keys_and_blobs):
    """Payload order, spelled out: each image's app, then that image's parts.

    The one rule the format has about where payloads go, written here rather than
    asked of the writer, so the refusal tests below assemble files that are wrong
    in exactly one way instead of wrong about the order as well.
    """
    out = b""
    for key, blob in keys_and_blobs:
        out += blob
        payloads = fake_flash_payloads(key)
        for role in espdisp.REQUIRED_FLASH_ROLES:
            out += payloads[role]
    return out


SAMPLE_PAYLOADS = (("c6", FAKE_C6), ("s3", FAKE_S3))


def sample_manifest(entries=None):
    if entries is None:
        entries = [image_entry("c6", FAKE_C6), image_entry("s3", FAKE_S3)]
    return espdisp.bundle_manifest(
        "1.2.0",
        entries,
        "2026-01-02T03:04:05Z",
        source_commit="a" * 40,
        source_dirty=False,
    )


def sample_flash_payloads(*keys):
    return {espdisp.BOARDS[key].chip: fake_flash_payloads(key) for key in keys}


def sample_bundle():
    manifest = sample_manifest()
    return manifest, espdisp.pack_bundle(
        manifest,
        {"esp32c6": FAKE_C6, "esp32s3": FAKE_S3},
        sample_flash_payloads("c6", "s3"),
    )


def handmade_bundle(manifest_bytes, payload=b"", magic=None, line=None):
    """Assemble bundle bytes without going through pack_bundle.

    pack_bundle checks its own output, which is right for a writer and useless
    for testing a reader: every file worth refusing is one pack_bundle would not
    have produced. So the rejection tests build the bytes directly.
    """
    if magic is None:
        magic = espdisp.BUNDLE_MAGIC
    if line is None:
        line = ("%010d\n" % len(manifest_bytes)).encode("ascii")
    return magic + line + manifest_bytes + payload


def claimed_size(entry):
    """What an entry says its payload is, or 0 if it does not say a number."""
    size = entry.get("bytes")
    return size if isinstance(size, int) and not isinstance(size, bool) else 0


def handmade_manifest(images, edit=None, **overrides):
    """A manifest whose offsets are solved HERE, around a deliberate breakage.

    bundle_manifest cannot build most of what the refusal tests need - it refuses
    an image with no flash parts, and it would trip over a part that is not even
    a JSON object - so this is a second, hand-written implementation of the one
    rule the format has about where payloads go: contiguously from
    22 + len(manifest), each image's application image followed by that image's
    flash parts in listed order. Two hand-written versions of that rule agreeing
    is the same check the pinned layout test makes, one level up.

    Solving matters for a reason beyond convenience. A reader checks the
    application image's own offset before it looks at any flash part, so a
    manifest edited to be wrong about a part and left with stale offsets would be
    refused for contiguity and the refusal under test would never run. `edit` is
    applied after every assignment pass for the same reason: it is how a test
    breaks an OFFSET and still gets a manifest whose length has settled.
    """
    def copied_image(image):
        """A copy deep enough that a test cannot edit another test's fixture.

        An absent flash_parts stays absent: "this image has no such key" is one of
        the shapes under test and must not be turned into "it has one that is
        null" on the way in.
        """
        image = dict(image)
        parts = image.get("flash_parts")
        if isinstance(parts, list):
            image["flash_parts"] = [
                dict(part) if isinstance(part, dict) else part for part in parts
            ]
        return image

    manifest = {
        "format": espdisp.BUNDLE_FORMAT,
        "firmware_version": "1.2.0",
        "built_at": "2026-01-02T03:04:05Z",
        "source_commit": "a" * 40,
        "source_dirty": False,
        "tool": "espdisp.py bundle",
        "images": [copied_image(image) for image in images],
    }
    manifest.update(overrides)
    for _ in range(8):
        length = len(espdisp.encode_manifest(manifest))
        cursor = espdisp.BUNDLE_HEADER_BYTES + length
        for image in manifest["images"]:
            image["offset"] = cursor
            cursor += claimed_size(image)
            parts = image.get("flash_parts")
            if isinstance(parts, list):
                for part in parts:
                    if isinstance(part, dict):
                        part["offset"] = cursor
                        cursor += claimed_size(part)
        if edit:
            edit(manifest)
        if len(espdisp.encode_manifest(manifest)) == length:
            return manifest
    raise AssertionError("hand-solved manifest offsets did not settle")


def test_fw_version_from_sketch():
    # The real sketch, in its real spelling. Deliberately not pinned to "1.2.0":
    # the version is expected to move, and a test that had to be edited on every
    # bump would get edited without being read. What is pinned is that the
    # declaration is still findable and still looks like a version, so a rename or
    # a move of FW_VERSION fails here instead of putting the wrong number in a
    # manifest.
    version = espdisp.sketch_fw_version()
    check(bool(re.fullmatch(r"\d+\.\d+\.\d+", version)),
          "the sketch's FW_VERSION reads as a version: %r" % version)

    # The exact line from display_stream.ino:84.
    check_equal(
        espdisp.fw_version_from_sketch(
            'static String cfgName;\n'
            'static const char *FW_VERSION = "1.2.0";\n'
            'static uint8_t deviceId[6] = {0};\n'),
        "1.2.0",
        "the sketch's own spelling")
    # Spacing and the position of the * are style, not meaning.
    check_equal(
        espdisp.fw_version_from_sketch('static const char* FW_VERSION="4.5.6" ;'),
        "4.5.6", "tight spacing, star on the type")
    check_equal(
        espdisp.fw_version_from_sketch(
            '  static  const  char  *  FW_VERSION  =  "7.8.9-rc1" ;  '),
        "7.8.9-rc1", "loose spacing and a pre-release suffix")

    check_fails(
        lambda: espdisp.fw_version_from_sketch("void setup() {}\n"),
        "could not find FW_VERSION",
        "a sketch with no version at all")
    # A commented-out or renamed definition is the realistic version of that: it
    # must not match, because matching a comment would report a version the image
    # does not have.
    check_fails(
        lambda: espdisp.fw_version_from_sketch(
            '// static const char *FW_VERSION = "0.0.1";\n'
            'static const char *FIRMWARE_VERSION = "1.2.0";\n'),
        "could not find FW_VERSION",
        "a renamed constant is not silently accepted")
    check_fails(
        lambda: espdisp.fw_version_from_sketch(
            'static const char *FW_VERSION = "1.2.0";\n'
            'static const char *FW_VERSION = "9.9.9";\n'),
        "exactly one",
        "two definitions are refused rather than picked between")
    check_fails(
        lambda: espdisp.fw_version_from_sketch('static const char *FW_VERSION = "";'),
        "is empty",
        "an empty version is refused")
    check_fails(
        lambda: espdisp.sketch_fw_version("/nonexistent/display_stream.ino"),
        "cannot read",
        "a missing sketch is a plain message, not a traceback")


def test_bundle_length_line():
    # Fixed width is what puts the manifest at a constant offset, so the padding
    # and the newline are load-bearing rather than cosmetic.
    check_equal(espdisp.bundle_length_line(0), b"0000000000\n", "zero")
    check_equal(espdisp.bundle_length_line(350), b"0000000350\n", "the common case")
    check_equal(espdisp.bundle_length_line(9999999999), b"9999999999\n", "the ceiling")
    for length in (0, 1, 350, 1234567890, 9999999999):
        line = espdisp.bundle_length_line(length)
        check_equal(len(line), 11, "%d is always 11 bytes" % length)
        check_equal(int(line[:10]), length, "%d round trips" % length)

    # "%010d" widens rather than truncating, which would move the manifest and
    # turn every offset in it into a lie. Refusing is the only honest option.
    check_fails(
        lambda: espdisp.bundle_length_line(10000000000),
        "does not fit",
        "a manifest too big for the length field is refused, not truncated")
    check_fails(
        lambda: espdisp.bundle_length_line(-1), "does not fit", "a negative length")
    check_equal(espdisp.BUNDLE_HEADER_BYTES, 22, "the header is 22 bytes")


# The four payloads of the pinned generation-2 fixture, and their digests.
#
# THE DIGESTS WERE COMPUTED BY `shasum -a 256`, not by this module and not by
# CryptoKit, so the number pinned here is not something either implementation
# asserted about itself. FirmwareBundleTests.swift pins the same four.
PINNED_APP = b"\x00\x01\x02\xffnot really firmware\n"                      # 24 bytes
PINNED_BOOTLOADER = b"\xe9fake bootloader\n"                               # 17 bytes
PINNED_PARTITIONS = b"\xaaPtable\n"                                        # 8 bytes
PINNED_BOOT_APP0 = b"ota\n"                                                # 4 bytes
PINNED_APP_SHA = "93fcaa5a244cfb4bd4d8255e820062cc4ff5ffa650e1317546bbee66d8d6c4d8"
PINNED_BOOTLOADER_SHA = "382ef4f8036d992da0de16313b77e69ea18846f63f1fc8f1d1288947657c94d6"
PINNED_PARTITIONS_SHA = "e58a7c4fc196c9463c577a8efa1be0b455b2cfc09a93a7195c93bf24b94cb20c"
PINNED_BOOT_APP0_SHA = "86cc25f7b4e15df03acb972f5399782cd72c3a208e772a3f5b1fa5a38af5a8fc"


def test_bundle_layout_is_pinned():
    """The file's bytes, asserted literally.

    This is the one test that would notice the format changing. The Mac app
    reading these files is a separate implementation that cannot be recompiled
    from this repo, and a file already handed to someone cannot be recalled, so
    the layout has to break a test rather than break a reader. Written out by
    hand for the same reason firmware/test and Tests/SenderProtocolTests assert
    the same band bytes independently: agreement between two hand-written
    versions is the check.

    THE OFFSETS WERE SOLVED BY HAND, from the format definition, not copied out of
    a file this code produced - a pin taken from the implementation's own output
    passes with the implementation wrong, which is the whole failure it exists to
    catch. The arithmetic: the manifest below is 914 bytes with every offset three
    digits wide, so 22 + 914 = 936 is where the app lands, 936 + 24 = 960 the
    bootloader, 960 + 17 = 977 the partition table, 977 + 8 = 985 boot_app0, and
    985 + 4 = 989 is the whole file. Nothing in it can be out by one without
    pack_bundle refusing to write it.
    """
    manifest = {
        "format": 2,
        "firmware_version": "9.9.9",
        "built_at": "2026-01-02T03:04:05Z",
        "source_commit": None,
        "source_dirty": False,
        "tool": "espdisp.py bundle",
        "images": [
            {
                "board": "c6",
                "chip": "esp32c6",
                "fqbn": "esp32:esp32:esp32c6",
                "filename": "display_stream.ino.bin",
                "bytes": 24,
                "offset": 936,  # 22 + 914, and pack_bundle refuses if it is not
                "sha256": PINNED_APP_SHA,
                "app_address": 65536,  # 0x10000
                "flash_parts": [
                    {
                        "role": "bootloader",
                        "address": 0,  # 0x0 for this chip, out of boards.txt
                        "filename": "display_stream.ino.bootloader.bin",
                        "bytes": 17,
                        "offset": 960,
                        "sha256": PINNED_BOOTLOADER_SHA,
                    },
                    {
                        "role": "partitions",
                        "address": 32768,  # 0x8000
                        "filename": "display_stream.ino.partitions.bin",
                        "bytes": 8,
                        "offset": 977,
                        "sha256": PINNED_PARTITIONS_SHA,
                    },
                    {
                        "role": "boot_app0",
                        "address": 57344,  # 0xe000
                        "filename": "boot_app0.bin",
                        "bytes": 4,
                        "offset": 985,
                        "sha256": PINNED_BOOT_APP0_SHA,
                    },
                ],
            }
        ],
    }
    # The manifest as it must appear on disk: sorted keys, no spaces. 914 bytes.
    # Keys sorted means app_address first in an image and address first in a part,
    # and flash_parts falls between filename and fqbn - which is why payload order
    # is defined by the LIST, not by where the keys land in the encoding.
    want_json = (
        b'{"built_at":"2026-01-02T03:04:05Z","firmware_version":"9.9.9","format":2,'
        b'"images":[{"app_address":65536,"board":"c6","bytes":24,"chip":"esp32c6",'
        b'"filename":"display_stream.ino.bin","flash_parts":['
        b'{"address":0,"bytes":17,"filename":"display_stream.ino.bootloader.bin",'
        b'"offset":960,"role":"bootloader","sha256":'
        b'"382ef4f8036d992da0de16313b77e69ea18846f63f1fc8f1d1288947657c94d6"},'
        b'{"address":32768,"bytes":8,"filename":"display_stream.ino.partitions.bin",'
        b'"offset":977,"role":"partitions","sha256":'
        b'"e58a7c4fc196c9463c577a8efa1be0b455b2cfc09a93a7195c93bf24b94cb20c"},'
        b'{"address":57344,"bytes":4,"filename":"boot_app0.bin",'
        b'"offset":985,"role":"boot_app0","sha256":'
        b'"86cc25f7b4e15df03acb972f5399782cd72c3a208e772a3f5b1fa5a38af5a8fc"}],'
        b'"fqbn":"esp32:esp32:esp32c6","offset":936,'
        b'"sha256":"93fcaa5a244cfb4bd4d8255e820062cc4ff5ffa650e1317546bbee66d8d6c4d8"}],'
        b'"source_commit":null,"source_dirty":false,"tool":"espdisp.py bundle"}')
    check_equal(len(want_json), 914, "the hand-written manifest is 914 bytes")
    check_equal(espdisp.encode_manifest(manifest), want_json, "canonical encoding")

    data = espdisp.pack_bundle(
        manifest,
        {"esp32c6": PINNED_APP},
        {
            "esp32c6": {
                "bootloader": PINNED_BOOTLOADER,
                "partitions": PINNED_PARTITIONS,
                "boot_app0": PINNED_BOOT_APP0,
            }
        },
    )

    # The 22-byte prefix, literally: magic line, then ten zero-padded digits and
    # a newline. Everything after this is found by arithmetic on those digits.
    check_equal(data[:22], b"ESPDISPFW2\n0000000914\n", "the fixed 22-byte prefix")
    check_equal(data[:11], b"ESPDISPFW2\n", "magic line, generation included")
    check_equal(data[11:21], b"0000000914", "ten digits, zero padded")
    check_equal(data[21:22], b"\n", "and a newline")
    check_equal(data[22:936], want_json, "the manifest sits at offset 22")
    # Payload order, byte for byte: the app, then this image's parts in listed
    # order. A reader that put the parts before the app, or sorted them by
    # address, would fail here rather than on a board.
    check_equal(data[936:960], PINNED_APP, "the app starts where the manifest says")
    check_equal(data[960:977], PINNED_BOOTLOADER, "then the bootloader")
    check_equal(data[977:985], PINNED_PARTITIONS, "then the partition table")
    check_equal(data[985:989], PINNED_BOOT_APP0, "then boot_app0")
    check_equal(len(data), 989, "22 + 914 + 24 + 17 + 8 + 4")
    check_equal(
        data,
        b"ESPDISPFW2\n0000000914\n" + want_json + PINNED_APP + PINNED_BOOTLOADER
        + PINNED_PARTITIONS + PINNED_BOOT_APP0,
        "the whole file, byte for byte")

    # And it reads back, so the pin describes a file this tool accepts rather
    # than a shape nobody parses.
    got_manifest, payloads, flash_payloads = espdisp.unpack_bundle(data)
    check_equal(got_manifest, manifest, "the manifest survives a round trip")
    check_equal(payloads, {"esp32c6": PINNED_APP}, "so does the app payload")
    check_equal(
        flash_payloads,
        {
            "esp32c6": {
                "bootloader": PINNED_BOOTLOADER,
                "partitions": PINNED_PARTITIONS,
                "boot_app0": PINNED_BOOT_APP0,
            }
        },
        "and every flash part, keyed by role")


def test_generation_one_layout_is_pinned_and_still_read():
    """A generation-1 file, byte for byte, and it is still accepted.

    This is the file the shipped app writes and reads today, so the bytes are
    pinned rather than described: the OTA feature works over files that already
    exist and cannot be rebuilt without this repo at the commit they came from, and
    a reader that quietly stopped taking them would break that with no error
    anyone could act on.

    Assembled by hand rather than by pack_bundle, which writes generation 2 only.
    350 bytes of manifest, so the one payload lands at 22 + 350 = 372 and the file
    is 396 bytes - the same numbers this test pinned before generation 2 existed.
    """
    want_json = (
        b'{"built_at":"2026-01-02T03:04:05Z","firmware_version":"9.9.9","format":1,'
        b'"images":[{"board":"c6","bytes":24,"chip":"esp32c6",'
        b'"filename":"display_stream.ino.bin","fqbn":"esp32:esp32:esp32c6",'
        b'"offset":372,"sha256":"93fcaa5a244cfb4bd4d8255e820062cc'
        b'4ff5ffa650e1317546bbee66d8d6c4d8"}],"source_commit":null,'
        b'"source_dirty":false,"tool":"espdisp.py bundle"}')
    check_equal(len(want_json), 350, "the hand-written v1 manifest is 350 bytes")
    data = b"ESPDISPFW1\n0000000350\n" + want_json + PINNED_APP
    check_equal(len(data), 396, "22 + 350 + 24")
    check_equal(data[:22], b"ESPDISPFW1\n0000000350\n", "generation 1's 22-byte prefix")

    manifest, payloads, flash_payloads = espdisp.unpack_bundle(data)
    check_equal(manifest["format"], 1, "read as format 1")
    check_equal(payloads, {"esp32c6": PINNED_APP}, "the app payload is reachable")
    # The one thing that is different about it, and the reason the app has to ask:
    # there is nothing here to write to a blank board.
    check_equal(flash_payloads, {}, "a v1 bundle carries no flash parts")
    check_equal(sorted(manifest["images"][0]), sorted(espdisp.IMAGE_KEYS),
                "and its image entries carry only generation 1's keys")

    # A v1 file with generation 2's magic, or the reverse, is refused: the magic
    # and the manifest's own format are two statements of one fact.
    check_fails(
        lambda: espdisp.unpack_bundle(b"ESPDISPFW2\n0000000350\n" + want_json + PINNED_APP),
        "magic means format 2",
        "generation 2's magic over a format 1 manifest")


def test_flash_part_vocabulary():
    """The role names, their order, and the two questions asked about a set."""
    # The names are in the file, so they are part of the format: a rename is a
    # format change and has to fail here rather than on a board.
    check_equal(espdisp.FLASH_ROLE_BOOTLOADER, "bootloader", "the bootloader's name")
    check_equal(espdisp.FLASH_ROLE_PARTITIONS, "partitions", "the table's name")
    check_equal(espdisp.FLASH_ROLE_BOOT_APP0, "boot_app0", "the otadata initialiser")
    # WRITE ORDER, not alphabetical: it is the order the core's own recipe uses
    # (platform.txt:346) and the order the payloads are laid down in the file.
    check_equal(
        list(espdisp.REQUIRED_FLASH_ROLES),
        ["bootloader", "partitions", "boot_app0"],
        "the three roles a blank board needs, in write order")

    check_equal(espdisp.missing_flash_roles(espdisp.REQUIRED_FLASH_ROLES), [],
                "a complete set is missing nothing")
    check_equal(espdisp.missing_flash_roles([]), list(espdisp.REQUIRED_FLASH_ROLES),
                "an empty set is missing all three")
    check_equal(
        espdisp.missing_flash_roles(["partitions", "spiffs"]),
        ["bootloader", "boot_app0"],
        "an unknown extra role neither counts nor complains")
    check_equal(
        espdisp.missing_flash_roles({"boot_app0": b"", "bootloader": b""}),
        ["partitions"],
        "and a dict of payloads answers the same question")

    check_equal(
        espdisp.conflicting_flash_address([(0x0, "bootloader"), (0x8000, "partitions")]),
        None, "distinct addresses do not clash")
    check_equal(
        espdisp.conflicting_flash_address(
            [(0x0, "bootloader"), (0x8000, "partitions"), (0x0, "spiffs")]),
        (0x0, "bootloader", "spiffs"),
        "the first pair to collide is named, in write order")
    check_equal(
        espdisp.conflicting_flash_address([]), None, "nothing cannot collide")

    # How an address is spelled for a person: wide enough for the addresses this
    # repo uses, and never a lie about a value that is not a number.
    check_equal(espdisp.flash_address_hex(0x0), "0x000000", "the bootloader's")
    check_equal(espdisp.flash_address_hex(0x8000), "0x008000", "the table's")
    check_equal(espdisp.flash_address_hex(0xE000), "0x00e000", "boot_app0's")
    check_equal(espdisp.flash_address_hex(0x10000), "0x010000", "the app's")
    check_equal(espdisp.flash_address_hex("nonsense"), "nonsense",
                "a non-number is shown as it is rather than formatted")

    # bool is an int in Python, and JSON true would sail through isinstance.
    check_equal(espdisp.is_whole_number(0), True, "zero is a whole number")
    check_equal(espdisp.is_whole_number(-1), True, "so is a negative one")
    check_equal(espdisp.is_whole_number(True), False, "JSON true is not")
    check_equal(espdisp.is_whole_number(False), False, "nor is JSON false")
    check_equal(espdisp.is_whole_number(4.0), False, "nor is a float that looks whole")
    check_equal(espdisp.is_whole_number("4"), False, "nor is a string")
    check_equal(espdisp.is_whole_number(None), False, "nor is null")


def test_bootloader_address_from_boards_txt():
    """The per-chip bootloader address, parsed rather than assumed.

    Split out of the file reading so it is testable with no core installed, and
    tested against the real spellings boards.txt uses: `esp32c6:812` and
    `esp32s3:1183` both say 0x0, and the classic ESP32 says 0x1000. A constant in
    the code would be wrong for one of those three no matter which was picked, and
    wrong silently - the flash would take the write and the chip would not boot.
    """
    text = (
        "esp32.name=ESP32 Dev Module\n"
        "esp32.build.bootloader_addr=0x1000\n"
        "esp32c6.build.mcu=esp32c6\n"
        "esp32c6.build.bootloader_addr=0x0\n"
        "esp32s3.build.bootloader_addr=0x0\n"
        "esp32h2.build.bootloader_addr=4096\n"
    )
    check_equal(espdisp.bootloader_address_from_boards_txt(text, "esp32c6"), 0x0, "C6")
    check_equal(espdisp.bootloader_address_from_boards_txt(text, "esp32s3"), 0x0, "S3")
    check_equal(
        espdisp.bootloader_address_from_boards_txt(text, "esp32"), 0x1000,
        "the classic ESP32, which is the reason this is not a constant")
    check_equal(
        espdisp.bootloader_address_from_boards_txt(text, "esp32h2"), 4096,
        "a decimal spelling reads as the same number")
    check_equal(
        espdisp.bootloader_address_from_boards_txt(text, "esp32c3"), None,
        "a chip with no such key gets no answer rather than a default")

    # The match is anchored on the whole key: a menu override or another board's
    # key must not answer for this chip. `esp32s3.menu.*` and `esp32s3_box.*` are
    # both real shapes in boards.txt.
    check_equal(
        espdisp.bootloader_address_from_boards_txt(
            "esp32s3.menu.FlashMode.qio.build.bootloader_addr=0x1000\n", "esp32s3"),
        None, "a menu override does not answer for the board")
    check_equal(
        espdisp.bootloader_address_from_boards_txt(
            "esp32s3_box.build.bootloader_addr=0x1000\n", "esp32s3"),
        None, "and neither does a board whose name starts the same way")
    check_equal(
        espdisp.bootloader_address_from_boards_txt(
            "# esp32s3.build.bootloader_addr=0x1000\n", "esp32s3"),
        None, "a commented-out line is not a value")
    # Two different answers for one chip: refused rather than picked between, the
    # same stance resolve_board and fw_version_from_sketch take.
    check_fails(
        lambda: espdisp.bootloader_address_from_boards_txt(
            "esp32s3.build.bootloader_addr=0x0\n"
            "esp32s3.build.bootloader_addr=0x1000\n", "esp32s3"),
        "different bootloader addresses",
        "two answers for one chip")
    # The same answer twice is not a contradiction.
    check_equal(
        espdisp.bootloader_address_from_boards_txt(
            "esp32s3.build.bootloader_addr=0x0\n"
            "esp32s3.build.bootloader_addr=0x0\n", "esp32s3"),
        0x0, "the same answer twice is fine")


def test_core_lookups():
    """Finding boot_app0.bin and boards.txt under the installed core.

    Mocked against a directory tree rather than the machine, so the globbing and
    the refusals are covered anywhere. The real core is then checked too, if it is
    installed, because that is the only place the answers actually come from - and
    a note is printed rather than a failure raised when it is not, since nothing
    else in this suite needs arduino-cli.
    """
    tmp = tempfile.mkdtemp(prefix="espdisp-test-core-")
    try:
        # Two core versions, because the newest has to win: the core upgrades
        # itself and a pinned version would stop resolving after that.
        for version in ("3.2.0", "3.3.11"):
            partitions = os.path.join(
                tmp, "packages", "esp32", "hardware", "esp32", version, "tools",
                "partitions")
            os.makedirs(partitions, exist_ok=True)
            with open(os.path.join(partitions, "boot_app0.bin"), "wb") as fh:
                fh.write(b"\xff" * 8192 if version == "3.3.11" else b"old")
            with open(
                os.path.join(os.path.dirname(os.path.dirname(partitions)), "boards.txt"),
                "w",
            ) as fh:
                fh.write("esp32s3.build.bootloader_addr=0x0\n")

        with unittest.mock.patch.object(espdisp, "core_data_dir", lambda: tmp):
            check_equal(
                os.path.basename(espdisp.core_hardware_dir()), "3.3.11",
                "the newest installed core wins")
            check_equal(
                espdisp.core_boot_app0(),
                os.path.join(tmp, "packages", "esp32", "hardware", "esp32", "3.3.11",
                             "tools", "partitions", "boot_app0.bin"),
                "boot_app0 comes out of that core, not out of the export directory")
            check_equal(
                espdisp.core_bootloader_address("esp32s3"), 0x0,
                "and the address comes out of its boards.txt")
            check_fails(
                lambda: espdisp.core_bootloader_address("esp32c6"),
                "no build.bootloader_addr",
                "a chip the installed core says nothing about")

        with unittest.mock.patch.object(espdisp, "core_data_dir", lambda: ""):
            check_fails(
                lambda: espdisp.core_hardware_dir(), "directories.data",
                "no arduino-cli data directory")
        empty = os.path.join(tmp, "empty")
        os.makedirs(empty, exist_ok=True)
        with unittest.mock.patch.object(espdisp, "core_data_dir", lambda: empty):
            check_fails(
                lambda: espdisp.core_hardware_dir(), "core is not installed",
                "no esp32 core under the data directory")
        # A core with no boot_app0.bin: named rather than reported as a missing
        # payload later, because the file it wants is the core's, not the user's.
        bare = os.path.join(tmp, "bare")
        os.makedirs(
            os.path.join(bare, "packages", "esp32", "hardware", "esp32", "3.3.11"),
            exist_ok=True)
        with unittest.mock.patch.object(espdisp, "core_data_dir", lambda: bare):
            check_fails(
                lambda: espdisp.core_boot_app0(), "boot_app0.bin not found",
                "a core directory with no boot_app0.bin")
            check_fails(
                lambda: espdisp.core_bootloader_address("esp32s3"), "cannot read",
                "a core directory with no boards.txt")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # And the installed core, which is where the numbers in the format's comments
    # came from. FEAT-001 measured boot_app0.bin at 8192 bytes and both of this
    # repo's chips at bootloader address 0x0; if either has moved, a bundle built
    # here is describing something else and this is where that shows up.
    try:
        real = espdisp.core_boot_app0()
    except espdisp.Fail as exc:
        print("note: skipping the installed-core checks: %s" % str(exc).splitlines()[0])
    else:
        check_equal(
            os.path.getsize(real), 8192,
            "the core's boot_app0.bin is 8192 bytes, which is what a bundle pays")
        for board in espdisp.BOARDS.values():
            check_equal(
                espdisp.core_bootloader_address(board.chip), 0x0,
                "the installed core puts the %s bootloader at 0x0" % board.chip)


def test_export_binary():
    """Picking one named binary out of an arduino-cli --output-dir export.

    The filenames are the ones a real export holds - verified against one rather
    than assumed - and "exactly one" is required for the same reason app_image
    requires it: two would mean the directory has two builds in it and either
    choice would be arbitrary.
    """
    tmp = tempfile.mkdtemp(prefix="espdisp-test-export-")
    try:
        for name in ("display_stream.ino.bin", "display_stream.ino.bootloader.bin",
                     "display_stream.ino.partitions.bin",
                     "display_stream.ino.merged.bin", "display_stream.ino.elf",
                     "display_stream.ino.map"):
            with open(os.path.join(tmp, name), "w") as fh:
                fh.write("x")

        check_equal(
            os.path.basename(espdisp.export_binary(tmp, ".ino.bootloader.bin")),
            "display_stream.ino.bootloader.bin", "the bootloader")
        check_equal(
            os.path.basename(espdisp.export_binary(tmp, ".ino.partitions.bin")),
            "display_stream.ino.partitions.bin", "the partition table")
        # The suffixes are distinct enough not to catch each other: ".ino.bin"
        # must not match ".ino.bootloader.bin" or ".ino.merged.bin", which all end
        # in the same three characters.
        check_equal(
            os.path.basename(espdisp.export_binary(tmp, ".ino.bin")),
            "display_stream.ino.bin", "and the app image, not a longer name")
        check_fails(
            lambda: espdisp.export_binary(tmp, ".ino.spiffs.bin"),
            "expected exactly one",
            "a binary the export does not hold")
        with open(os.path.join(tmp, "other.ino.bootloader.bin"), "w") as fh:
            fh.write("x")
        check_fails(
            lambda: espdisp.export_binary(tmp, ".ino.bootloader.bin"),
            "expected exactly one",
            "two candidates are refused rather than picked between")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_collect_flash_parts():
    """The three entries cmd_bundle puts in a manifest, and where each came from.

    Two out of the compile's export and boot_app0 out of the core, with the
    bootloader address read per chip - which is the whole reason this is a
    function rather than three literals.
    """
    tmp = tempfile.mkdtemp(prefix="espdisp-test-collect-")
    try:
        export = os.path.join(tmp, "export")
        os.makedirs(export, exist_ok=True)
        contents = {
            "display_stream.ino.bootloader.bin": b"\xe9 bootloader bytes",
            "display_stream.ino.partitions.bin": b"\xaaP table bytes",
            "display_stream.ino.bin": b"\x00 app bytes",
        }
        for name, blob in contents.items():
            with open(os.path.join(export, name), "wb") as fh:
                fh.write(blob)
        boot_app0 = os.path.join(tmp, "boot_app0.bin")
        with open(boot_app0, "wb") as fh:
            fh.write(b"\xff" * 8192)

        with unittest.mock.patch.object(espdisp, "core_boot_app0", lambda: boot_app0), \
                unittest.mock.patch.object(
                    espdisp, "core_bootloader_address", lambda chip: 0x0):
            entries, payloads = espdisp.collect_flash_parts(espdisp.BOARDS["s3"], export)

        check_equal(
            [entry["role"] for entry in entries],
            ["bootloader", "partitions", "boot_app0"],
            "in write order, which is also the order they land in the file")
        check_equal(
            [entry["address"] for entry in entries], [0x0, 0x8000, 0xE000],
            "each at the address the core's own recipe uses")
        check_equal(
            [entry["filename"] for entry in entries],
            ["display_stream.ino.bootloader.bin", "display_stream.ino.partitions.bin",
             "boot_app0.bin"],
            "named by the file each came from, basename only")
        check_equal(
            [entry["bytes"] for entry in entries],
            [len(contents["display_stream.ino.bootloader.bin"]),
             len(contents["display_stream.ino.partitions.bin"]), 8192],
            "with the real byte counts")
        for entry in entries:
            check_equal(
                entry["sha256"], espdisp.sha256_hex(payloads[entry["role"]]),
                "the %s entry's hash is its payload's" % entry["role"])
            check_equal(
                sorted(entry),
                sorted(key for key in espdisp.FLASH_PART_KEYS if key != "offset"),
                "the %s entry carries every key but the offset, which "
                "bundle_manifest fills in" % entry["role"])
        check_equal(
            payloads["bootloader"], contents["display_stream.ino.bootloader.bin"],
            "the bootloader payload is the export's bytes, unmodified")
        check_equal(len(payloads["boot_app0"]), 8192, "and boot_app0 is the core's")
        # The application image is NOT one of these: it is carried once, by the
        # image entry itself, and cmd_bundle reads it through app_image().
        check("app" not in payloads, "the app is not a flash part")

        # An empty part is refused rather than written: a zero-byte bootloader
        # would produce a file every hash agreed with and no board would boot.
        with open(os.path.join(export, "display_stream.ino.bootloader.bin"), "wb"):
            pass
        with unittest.mock.patch.object(espdisp, "core_boot_app0", lambda: boot_app0), \
                unittest.mock.patch.object(
                    espdisp, "core_bootloader_address", lambda chip: 0x0):
            check_fails(
                lambda: espdisp.collect_flash_parts(espdisp.BOARDS["s3"], export),
                "is empty",
                "a zero-byte binary in the export")
        # A missing one names the file rather than the role, because the fix is to
        # look at the export directory.
        os.remove(os.path.join(export, "display_stream.ino.partitions.bin"))
        with unittest.mock.patch.object(espdisp, "core_boot_app0", lambda: boot_app0), \
                unittest.mock.patch.object(
                    espdisp, "core_bootloader_address", lambda chip: 0x0):
            check_fails(
                lambda: espdisp.collect_flash_parts(espdisp.BOARDS["s3"], export),
                "expected exactly one *.ino.partitions.bin",
                "an export with no partition table in it")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_bundle_manifest_offsets():
    manifest = sample_manifest()
    raw = espdisp.encode_manifest(manifest)
    first, second = manifest["images"]

    # Absolute from the start of the file, so a reader is one slice.
    check_equal(
        first["offset"], espdisp.BUNDLE_HEADER_BYTES + len(raw),
        "the first image starts right after the manifest")
    # PAYLOAD ORDER, which generation 2 had to pick and pin: a flat walk over the
    # images, and within each image its application image followed by that image's
    # flash parts in listed order. So the second image does NOT follow the first
    # application image - it follows the first image's parts. Written out as
    # arithmetic here, because a reader that walked the apps first and the parts
    # afterwards would produce a file with the same manifest and different bytes.
    c6_parts = sum(part["bytes"] for part in first["flash_parts"])
    s3_parts = sum(part["bytes"] for part in second["flash_parts"])
    check_equal(
        second["offset"], first["offset"] + len(FAKE_C6) + c6_parts,
        "the second image follows the first image's flash parts, with no gap")
    cursor = first["offset"]
    for image in manifest["images"]:
        check_equal(image["offset"], cursor, "%s app offset" % image["chip"])
        cursor += image["bytes"]
        for part in image["flash_parts"]:
            check_equal(
                part["offset"], cursor,
                "%s %s follows with no gap" % (image["chip"], part["role"]))
            cursor += part["bytes"]
    check_equal(
        cursor,
        espdisp.BUNDLE_HEADER_BYTES + len(raw)
        + len(FAKE_C6) + c6_parts + len(FAKE_S3) + s3_parts,
        "and every payload is accounted for exactly once")
    check_equal(first["bytes"], len(FAKE_C6), "sizes come from the payloads")
    check_equal(second["bytes"], len(FAKE_S3), "for both images")
    check_equal(first["chip"], "esp32c6", "chip token, the app's vocabulary")
    check_equal(second["chip"], "esp32s3", "and the other one")
    check_equal(manifest["format"], 2, "format generation")
    check_equal(manifest["firmware_version"], "1.2.0", "version as given")
    check_equal(manifest["source_commit"], "a" * 40, "provenance is carried")
    check_equal(manifest["source_dirty"], False, "and so is cleanliness")
    check_equal(manifest["tool"], "espdisp.py bundle", "who wrote it")
    check_equal(sorted(manifest), sorted(espdisp.MANIFEST_KEYS), "no key is missing")
    for image in manifest["images"]:
        check_equal(
            sorted(image), sorted(espdisp.IMAGE_KEYS_V2), "no image key is missing")
        check_equal(
            [part["role"] for part in image["flash_parts"]],
            list(espdisp.REQUIRED_FLASH_ROLES),
            "%s lists its flash parts in write order" % image["chip"])
        for part in image["flash_parts"]:
            check_equal(
                sorted(part), sorted(espdisp.FLASH_PART_KEYS),
                "no flash part key is missing")

    # THE ADDRESSES, ASSERTED AS NUMBERS. These are the whole reason generation 2
    # exists, and 0x0 for the bootloader is the one that would be wrong if it were
    # a constant in a reader: the classic ESP32 puts it at 0x1000, and both chips
    # this repo supports put it at 0x0 (boards.txt esp32c6:812, esp32s3:1183).
    for image in manifest["images"]:
        addresses = {part["role"]: part["address"] for part in image["flash_parts"]}
        check_equal(addresses["bootloader"], 0x0,
                    "%s bootloader address" % image["chip"])
        check_equal(addresses["partitions"], 0x8000,
                    "%s partition table address" % image["chip"])
        check_equal(addresses["boot_app0"], 0xE000,
                    "%s boot_app0 address" % image["chip"])
        check_equal(image["app_address"], 0x10000, "%s app address" % image["chip"])

    # The manifest describes its own length, so the offsets are solved rather than
    # computed. A payload sized to push an offset across a digit boundary is the
    # case that catches a solver that only iterates once: the offset written must
    # still equal 22 + the length of the manifest it is written into. Generation 2
    # adds three more offsets per image to solve, which is why the last of these
    # sizes is big enough to roll every one of them over at once.
    for size in (1, 9, 10, 99, 100, 617, 1024, 65536):
        blob = b"\xa5" * size
        one = espdisp.bundle_manifest(
            "1.2.0", [image_entry("c6", blob)], "2026-01-02T03:04:05Z")
        encoded = espdisp.encode_manifest(one)
        image = one["images"][0]
        check_equal(
            image["offset"], espdisp.BUNDLE_HEADER_BYTES + len(encoded),
            "offsets settle for a %d-byte payload" % size)
        check_equal(
            image["flash_parts"][0]["offset"], image["offset"] + size,
            "and so does the first flash part's, for %d bytes" % size)
        # And the file it produces agrees, which is what the offsets are for.
        packed = espdisp.pack_bundle(one, {"esp32c6": blob}, sample_flash_payloads("c6"))
        check_equal(
            packed[image["offset"]:], payload_bytes(("c6", blob)),
            "the payloads land at the stated offsets for %d bytes" % size)

    # The offsets are filled in on COPIES. A shared list would mean the caller's
    # entry came back carrying this call's answers, so a second bundle built from
    # the same entries would start from the first one's offsets and be wrong in a
    # way every hash still agreed with.
    entry = image_entry("c6", FAKE_C6)
    parts_before = [dict(part) for part in entry["flash_parts"]]
    espdisp.bundle_manifest("1.2.0", [entry], "2026-01-02T03:04:05Z")
    check_equal(entry["flash_parts"], parts_before, "the caller's parts are untouched")
    check("offset" not in entry, "and the caller's image gained no offset")

    check_fails(
        lambda: espdisp.bundle_manifest("1.2.0", [], "2026-01-02T03:04:05Z"),
        "at least one image",
        "a manifest with no images is refused")
    # This tool writes generation 2 only, so an image with nothing for a blank
    # board is a caller bug and is refused where it is cheapest to fix.
    check_fails(
        lambda: espdisp.bundle_manifest(
            "1.2.0",
            [{k: v for k, v in image_entry("c6", FAKE_C6).items()
              if k != "flash_parts"}],
            "2026-01-02T03:04:05Z"),
        "carries no flash_parts",
        "an image with no flash parts at all is refused by the writer")


def test_bundle_round_trip():
    manifest, data = sample_bundle()
    got, payloads, flash_payloads = espdisp.unpack_bundle(data)

    check_equal(got, manifest, "the manifest round trips unchanged")
    check_equal(sorted(payloads), ["esp32c6", "esp32s3"], "keyed by chip token")
    # Byte for byte, not merely the right length: the images are pushed to a panel
    # that validates a hash of its own, so a payload that survives with the right
    # size and the wrong bytes would be the worst possible outcome.
    check_equal(payloads["esp32c6"], FAKE_C6, "the C6 image, byte for byte")
    check_equal(payloads["esp32s3"], FAKE_S3, "the S3 image, byte for byte")
    check(
        b"ESPDISPFW2\n" in payloads["esp32c6"],
        "a payload containing the magic is framed by offsets, not by scanning")
    check(
        b"ESPDISPFW1\n" in payloads["esp32c6"],
        "and the same for the older generation's magic")
    check_equal(
        espdisp.sha256_hex(payloads["esp32c6"]), manifest["images"][0]["sha256"],
        "the hash in the manifest is the hash of the payload")

    # The flash parts, keyed by chip and then by role, byte for byte and per
    # board: identical stand-ins would let a reader that handed the C6 its S3
    # bootloader pass, and that is a payload written to address 0x0 of a board
    # with nothing else working on it.
    check_equal(sorted(flash_payloads), ["esp32c6", "esp32s3"], "parts keyed by chip")
    check_equal(flash_payloads["esp32c6"], fake_flash_payloads("c6"), "the C6's parts")
    check_equal(flash_payloads["esp32s3"], fake_flash_payloads("s3"), "the S3's parts")
    check(
        flash_payloads["esp32c6"]["bootloader"]
        != flash_payloads["esp32s3"]["bootloader"],
        "and the two boards' bootloaders are not interchangeable")
    for image in got["images"]:
        for part in image["flash_parts"]:
            check_equal(
                espdisp.sha256_hex(flash_payloads[image["chip"]][part["role"]]),
                part["sha256"],
                "the manifest's %s %s hash is the payload's"
                % (image["chip"], part["role"]))

    # A single-image bundle is a normal file, not a special case: --board c6 on a
    # machine that only owns one panel writes one.
    one = espdisp.bundle_manifest(
        "1.2.0", [image_entry("s3", FAKE_S3)], "2026-01-02T03:04:05Z")
    _, only, only_parts = espdisp.unpack_bundle(
        espdisp.pack_bundle(one, {"esp32s3": FAKE_S3}, sample_flash_payloads("s3")))
    check_equal(only, {"esp32s3": FAKE_S3}, "one image round trips too")
    check_equal(
        only_parts, {"esp32s3": fake_flash_payloads("s3")}, "and so do its parts")


def test_pack_bundle_refusals():
    """The writer's own checks: the last place a disagreement can still be fixed."""
    manifest = sample_manifest()
    both = sample_flash_payloads("c6", "s3")

    def one_image(**changes):
        """A settled single-image manifest, optionally broken in one way.

        Anything wrong with the ENTRY goes in here rather than being edited into
        the result, so bundle_manifest still settles the offsets around it: the
        writer places the application image before it looks at a flash part, and a
        manifest whose offsets no longer describe the file would be refused for
        that first and never reach the check under test.
        """
        entry = image_entry("c6", FAKE_C6)
        entry.update(changes)
        return espdisp.bundle_manifest(
            "1.2.0", [entry], "2026-01-02T03:04:05Z")

    def one_image_with_parts(mutate):
        """A settled single-image manifest whose flash parts `mutate` rewrote."""
        return one_image(flash_parts=mutate(flash_entries("c6")))

    check_fails(
        lambda: espdisp.pack_bundle(manifest, {"esp32c6": FAKE_C6}, both),
        "no payload was given",
        "a manifest listing an image nobody supplied")
    # The needle is the length message specifically, not the "the manifest says"
    # tail it shares with the hash refusal: a wrong length also hashes wrong, so a
    # looser needle would pass with the length check deleted.
    check_fails(
        lambda: espdisp.pack_bundle(
            manifest, {"esp32c6": FAKE_C6, "esp32s3": FAKE_S3 + b"!"}, both),
        "payload is %d bytes" % (len(FAKE_S3) + 1),
        "a payload whose length does not match the manifest")
    swapped = one_image()
    swapped["images"][0]["sha256"] = "0" * 64
    check_fails(
        lambda: espdisp.pack_bundle(
            swapped, {"esp32c6": FAKE_C6}, sample_flash_payloads("c6")),
        "hashes to",
        "a payload whose hash does not match the manifest")
    moved = one_image()
    moved["images"][0]["offset"] += 1
    check_fails(
        lambda: espdisp.pack_bundle(
            moved, {"esp32c6": FAKE_C6}, sample_flash_payloads("c6")),
        "do not describe this file",
        "an offset that does not describe the file being written")
    check_fails(
        lambda: espdisp.pack_bundle(dict(manifest, images=[]), {}),
        "at least one image",
        "packing nothing")

    # -- the same four checks again, for the flash parts. Separately, because a
    # payload written to an absolute flash address on a board with nothing working
    # on it is the worst place for bytes that are not what the manifest says.
    check_fails(
        lambda: espdisp.pack_bundle(manifest, {"esp32c6": FAKE_C6, "esp32s3": FAKE_S3}),
        "esp32c6 bootloader but no payload",
        "flash parts listed with no payloads supplied at all")
    short_of_one = {
        "esp32c6": {
            role: blob for role, blob in fake_flash_payloads("c6").items()
            if role != espdisp.FLASH_ROLE_BOOT_APP0
        },
        "esp32s3": fake_flash_payloads("s3"),
    }
    check_fails(
        lambda: espdisp.pack_bundle(
            manifest, {"esp32c6": FAKE_C6, "esp32s3": FAKE_S3}, short_of_one),
        "esp32c6 boot_app0 but no payload",
        "one missing flash payload, named by role")
    stretched = dict(both, esp32c6=dict(
        fake_flash_payloads("c6"),
        bootloader=fake_flash_payloads("c6")[espdisp.FLASH_ROLE_BOOTLOADER] + b"!"))
    check_fails(
        lambda: espdisp.pack_bundle(
            manifest, {"esp32c6": FAKE_C6, "esp32s3": FAKE_S3}, stretched),
        "esp32c6 bootloader payload is",
        "a flash payload whose length does not match its entry")

    def zero_the_partition_hash(parts):
        parts[1]["sha256"] = "0" * 64
        return parts

    rehashed = one_image_with_parts(zero_the_partition_hash)
    check_fails(
        lambda: espdisp.pack_bundle(
            rehashed, {"esp32c6": FAKE_C6}, sample_flash_payloads("c6")),
        "esp32c6 partitions payload hashes to",
        "a flash payload whose hash does not match its entry")
    shifted = one_image()
    shifted["images"][0]["flash_parts"][0]["offset"] += 1
    check_fails(
        lambda: espdisp.pack_bundle(
            shifted, {"esp32c6": FAKE_C6}, sample_flash_payloads("c6")),
        "do not describe this file",
        "a flash part offset that does not describe the file being written")

    # -- and the two checks that are only about generation 2's meaning: all three
    # roles present, and no two payloads claiming one flash address.
    for role in espdisp.REQUIRED_FLASH_ROLES:
        thinned = one_image_with_parts(
            lambda parts, role=role: [p for p in parts if p["role"] != role])
        check_fails(
            lambda thinned=thinned: espdisp.pack_bundle(
                thinned, {"esp32c6": FAKE_C6}, sample_flash_payloads("c6")),
            "carries no %s" % role,
            "a manifest with no %s is refused by the writer" % role)

    def collide(parts):
        parts[1]["address"] = parts[0]["address"]
        return parts

    check_fails(
        lambda: espdisp.pack_bundle(
            one_image_with_parts(collide), {"esp32c6": FAKE_C6},
            sample_flash_payloads("c6")),
        "writes both bootloader and partitions to flash address 0x0",
        "two parts at one flash address")

    def land_on_the_app(parts):
        parts[2]["address"] = 0x10000
        return parts

    check_fails(
        lambda: espdisp.pack_bundle(
            one_image_with_parts(land_on_the_app), {"esp32c6": FAKE_C6},
            sample_flash_payloads("c6")),
        "writes both the app and boot_app0 to flash address 0x10000",
        "a part landing on top of the application image")


def test_unpack_bundle_refusals():
    """Every way a bundle can be wrong, one check each.

    A bundle arrives from elsewhere - another machine, another week, an email
    round trip - so this is the tool's only defence, and "invalid bundle" would
    not tell the user whether to re-download it, rebuild it, or go and ask the
    person who sent it. Each refusal is asserted separately so that removing any
    single validation fails a test rather than being covered by its neighbour.
    """
    manifest, good = sample_bundle()
    raw = espdisp.encode_manifest(manifest)
    area = payload_bytes(*SAMPLE_PAYLOADS)

    # It reads, to begin with. Otherwise every check below could pass for the
    # wrong reason.
    check_accepts(lambda: espdisp.unpack_bundle(good), "the good bundle is accepted")

    # -- the header
    check_fails(
        lambda: espdisp.unpack_bundle(b""), "shorter than", "an empty file")
    check_fails(
        lambda: espdisp.unpack_bundle(b"ESPDISPFW2\n000"), "shorter than",
        "a file that stops inside the header")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, magic=b"NOTABUNDL1\n")),
        "does not start with the ESPDISPFW2 magic",
        "bad magic")
    check_fails(
        lambda: espdisp.unpack_bundle(b"\x00" * 64), "magic", "a file of zeros")
    # A future generation gets a message that says which ones this tool speaks,
    # rather than "not a bundle" - the file is fine, the reader is old. Generation
    # 3 is the one that does not exist yet; generation 1 does and is accepted, so
    # this is now a check that the dispatch is a lookup rather than a comparison
    # against whatever the newest magic happens to be.
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, magic=b"ESPDISPFW3\n")),
        "unsupported bundle generation",
        "a newer format generation")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, magic=b"ESPDISPFW3\n")),
        "'ESPDISPFW1', 'ESPDISPFW2'",
        "and it names both generations this tool does read")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, line=b"abcdefghij\n")),
        "not 10 digits",
        "a non-numeric length line")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, line=b"00000003501")),
        "not 10 digits",
        "a length line with no newline")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, line=b"       350\n")),
        "not 10 digits",
        "a space-padded length line")
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(raw, line=("%010d\n" % (len(raw) + 500)).encode())),
        "truncated",
        "a manifest length longer than the file")

    # -- the manifest
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(b'{"format": 2,')),
        "not valid UTF-8 JSON",
        "malformed JSON")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(b'{"format": \xff}')),
        "not valid UTF-8 JSON",
        "a manifest that is not UTF-8")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(b'["c6"]')),
        "not a JSON object",
        "a manifest that is a JSON array")
    for key in espdisp.MANIFEST_KEYS:
        short = dict(manifest)
        del short[key]
        check_fails(
            lambda short=short, key=key: espdisp.unpack_bundle(
                handmade_bundle(espdisp.encode_manifest(short), area)),
            "missing %s" % key,
            "a manifest with no %r" % key)
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(dict(manifest, format=3)), area)),
        "this tool reads formats 1 and 2",
        "an unknown format generation in the manifest")
    # THE MAGIC AND THE MANIFEST'S OWN `format` HAVE TO AGREE, both ways round.
    # Two statements of one fact, so a file where they differ is self-
    # contradictory whichever is right, and believing either would mean reading
    # one generation's body as the other's.
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(dict(manifest, format=1)), area)),
        "ESPDISPFW2 magic means format 2",
        "a format 1 manifest behind generation 2's magic")
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(raw, area, magic=espdisp.BUNDLE_MAGIC_V1)),
        "ESPDISPFW1 magic means format 1",
        "a format 2 manifest behind generation 1's magic")
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(dict(manifest, images=[])))),
        "lists no images",
        "a manifest with an empty image list")
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(dict(manifest, images={})))),
        "lists no images",
        "an images field that is not a list")
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(dict(manifest, images=["c6"])))),
        "not a JSON object",
        "an image entry that is a string")
    for key in espdisp.IMAGE_KEYS_V2:
        broken = dict(manifest)
        image = dict(broken["images"][0])
        del image[key]
        broken["images"] = [image, broken["images"][1]]
        check_fails(
            lambda broken=broken, key=key: espdisp.unpack_bundle(
                handmade_bundle(espdisp.encode_manifest(broken), area)),
            "missing %s" % key,
            "an image with no %r" % key)
    check_equal(
        sorted(espdisp.IMAGE_KEYS_V2),
        ["app_address", "board", "bytes", "chip", "filename", "flash_parts", "fqbn",
         "offset", "sha256"],
        "the generation-2 image key set is itself part of the format")
    check_equal(
        sorted(espdisp.FLASH_PART_KEYS),
        ["address", "bytes", "filename", "offset", "role", "sha256"],
        "and so is a flash part's")

    # -- the offsets, which are what make a truncated or edited file detectable
    def with_first(**changes):
        broken = dict(manifest)
        broken["images"] = [dict(broken["images"][0], **changes), broken["images"][1]]
        return handmade_bundle(espdisp.encode_manifest(broken), area)

    check_fails(
        lambda: espdisp.unpack_bundle(with_first(bytes=0)),
        "nonsensical offset/bytes",
        "a zero-length image")
    check_fails(
        lambda: espdisp.unpack_bundle(with_first(bytes=-8)),
        "nonsensical offset/bytes",
        "a negative length")
    check_fails(
        lambda: espdisp.unpack_bundle(with_first(offset=-1)),
        "nonsensical offset/bytes",
        "a negative offset")
    # true is an int in Python and would sail through an isinstance check.
    check_fails(
        lambda: espdisp.unpack_bundle(with_first(offset=True)),
        "nonsensical offset/bytes",
        "a JSON true where an offset belongs")
    check_fails(
        lambda: espdisp.unpack_bundle(with_first(bytes="24")),
        "nonsensical offset/bytes",
        "a stringly typed length")
    check_fails(
        lambda: espdisp.unpack_bundle(with_first(offset=manifest["images"][0]["offset"] + 1)),
        "contiguously",
        "a gap before the first image")
    check_fails(
        lambda: espdisp.unpack_bundle(with_first(offset=manifest["images"][0]["offset"] - 1)),
        "contiguously",
        "an image overlapping the manifest")

    second = manifest["images"][1]
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(
                espdisp.encode_manifest(
                    dict(manifest,
                         images=[manifest["images"][0],
                                 dict(second, offset=second["offset"] + 1)])),
                area)),
        "contiguously",
        "a gap between two images")

    # An offset inside the file whose length runs past the end. Built through
    # bundle_manifest so the offsets are self-consistent and only the size lies -
    # otherwise the contiguity check would fire first and this path would never
    # be reached.
    overrun = espdisp.bundle_manifest(
        "1.2.0", [dict(image_entry("c6", FAKE_C6), bytes=len(FAKE_C6) + 64)],
        "2026-01-02T03:04:05Z")
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(overrun), FAKE_C6)),
        "past the end",
        "an image that runs off the end of the file")
    check_fails(
        lambda: espdisp.unpack_bundle(good + b"junk"),
        "trailing after the last payload",
        "bytes appended after the last payload")
    check_fails(
        lambda: espdisp.unpack_bundle(good[:-1]),
        "past the end",
        "a file truncated inside the last payload")

    # -- duplicate chips: the app looks an image up by chip, so two would make
    # "the c6 image" ambiguous rather than merely redundant.
    twice = espdisp.bundle_manifest(
        "1.2.0", [image_entry("c6", FAKE_C6), image_entry("c6", FAKE_C6)],
        "2026-01-02T03:04:05Z")
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(twice),
                            payload_bytes(("c6", FAKE_C6), ("c6", FAKE_C6)))),
        "twice",
        "the same chip listed twice")

    # -- generation 2's own fields. One refusal per way a flash part can be
    # wrong, asserted separately: these are the payloads that go to absolute
    # addresses on a board with nothing working on it, so "which part" and "what
    # address" are the two things a message has to carry.
    keep = object()  # "leave app_address alone", which None cannot mean here

    def with_parts(parts, app_address=keep, edit=None):
        """A two-image file whose first image carries exactly `parts`.

        Offsets solved by handmade_manifest around whatever is wrong here, so the
        refusal that fires is the one being tested rather than the contiguity
        check the application image is measured against first.

        THE PAYLOAD AREA FOLLOWS WHAT THE MANIFEST CLAIMS. A test that drops a
        part from the list gets a file whose remaining hashes still agree, so it
        is refused for not carrying what a blank board needs - which is what it is
        testing - rather than for a hash mismatch caused by the next part's bytes
        having moved up into the gap.
        """
        first = dict(image_entry("c6", FAKE_C6), flash_parts=parts)
        if app_address is not keep:
            first["app_address"] = app_address
        built = handmade_manifest([first, image_entry("s3", FAKE_S3)], edit=edit)
        c6_parts = fake_flash_payloads("c6")
        claimed = FAKE_C6
        for part in parts if isinstance(parts, list) else []:
            if isinstance(part, dict) and part.get("role") in c6_parts:
                claimed += c6_parts[part["role"]]
        return handmade_bundle(
            espdisp.encode_manifest(built), claimed + payload_bytes(("s3", FAKE_S3)))

    good_parts = flash_entries("c6")
    # The helper is only useful if it produces a file that READS, so that every
    # refusal below is caused by the one thing that test broke.
    check_accepts(
        lambda: espdisp.unpack_bundle(with_parts([dict(p) for p in good_parts])),
        "a hand-solved manifest with correct parts is accepted")
    check_fails(
        lambda: espdisp.unpack_bundle(with_parts([])),
        "lists no flash parts",
        "a generation-2 image with an empty flash part list")
    check_fails(
        lambda: espdisp.unpack_bundle(with_parts({})),
        "lists no flash parts",
        "a flash_parts field that is not a list")
    check_fails(
        lambda: espdisp.unpack_bundle(with_parts(["bootloader"])),
        "not a JSON object",
        "a flash part that is a string")
    for key in espdisp.FLASH_PART_KEYS:
        if key == "offset":
            # The one key the solver writes, so it has to be taken away after
            # every pass rather than before the first one.
            check_fails(
                lambda: espdisp.unpack_bundle(with_parts(
                    [dict(part) for part in good_parts],
                    edit=lambda built: built["images"][0]["flash_parts"][0]
                    .pop("offset", None))),
                "missing offset",
                "a flash part with no 'offset'")
            continue
        thinned = [dict(part) for part in good_parts]
        del thinned[0][key]
        check_fails(
            lambda thinned=thinned: espdisp.unpack_bundle(with_parts(thinned)),
            "missing %s" % key,
            "a flash part with no %r" % key)
    for role in ("", "   ", 7, None):
        renamed = [dict(part) for part in good_parts]
        renamed[0]["role"] = role
        check_fails(
            lambda renamed=renamed: espdisp.unpack_bundle(with_parts(renamed)),
            "no usable role",
            "a flash part whose role is %r" % role)
    for missing in espdisp.REQUIRED_FLASH_ROLES:
        # A part dropped from the list entirely: the file is internally consistent
        # and simply cannot do the job it claims, which is a different answer from
        # "damaged" and gets a different message.
        without = [part for part in good_parts if part["role"] != missing]
        check_fails(
            lambda without=without: espdisp.unpack_bundle(with_parts(without)),
            "carries no %s" % missing,
            "a generation-2 image with no %s" % missing)
    doubled = [dict(good_parts[0]), dict(good_parts[0])] + [
        dict(part) for part in good_parts[1:]]
    check_fails(
        lambda: espdisp.unpack_bundle(with_parts(doubled)),
        "lists the bootloader part twice",
        "one role listed twice")
    for address in (-1, True, "0x0", 4.5, None):
        moved_part = [dict(part) for part in good_parts]
        moved_part[0]["address"] = address
        check_fails(
            lambda moved_part=moved_part: espdisp.unpack_bundle(
                with_parts(moved_part)),
            "nonsensical flash address",
            "a bootloader at flash address %r" % address)
    for address in (-1, True, "0x10000", None):
        check_fails(
            lambda address=address: espdisp.unpack_bundle(
                with_parts([dict(part) for part in good_parts], app_address=address)),
            "nonsensical app_address",
            "an app at flash address %r" % address)
    # Two payloads claiming one flash address, both ways round: against another
    # part, and against the application image. Only the last write would survive,
    # so it is a contradiction rather than a preference.
    collided = [dict(part) for part in good_parts]
    collided[1]["address"] = collided[0]["address"]
    check_fails(
        lambda: espdisp.unpack_bundle(with_parts(collided)),
        "writes both bootloader and partitions to flash address 0x0",
        "two flash parts at one address")
    over_app = [dict(part) for part in good_parts]
    over_app[2]["address"] = manifest["images"][0]["app_address"]
    check_fails(
        lambda: espdisp.unpack_bundle(with_parts(over_app)),
        "writes both the app and boot_app0 to flash address 0x10000",
        "a flash part on top of the application image")
    # And the extent and hash checks again, per part, because each catches a
    # different way of truncating or editing the file. These break a value the
    # solver reads rather than one it writes, so they go in as part of the entry.
    for changes, needle, what in (
        ({"bytes": 0}, "nonsensical offset/bytes", "a zero-length flash part"),
        ({"bytes": -4}, "nonsensical offset/bytes", "a negative flash part length"),
        ({"bytes": "17"}, "nonsensical offset/bytes", "a stringly typed length"),
        ({"bytes": 4.0}, "nonsensical offset/bytes", "a length written as a float"),
        ({"sha256": "0" * 64}, "hash mismatch",
         "a flash part hash that is not the payload's"),
        ({"sha256": None}, "hash mismatch", "a flash part with a null hash"),
    ):
        edited = [dict(good_parts[0], **changes)] + [
            dict(part) for part in good_parts[1:]]
        check_fails(
            lambda edited=edited: espdisp.unpack_bundle(with_parts(edited)),
            needle,
            what)
    # The offsets are what the solver writes, so breaking one means breaking it
    # after every pass - `edit` runs there for exactly this.

    def move_first_part(by=None, to=None):
        def edit(built):
            part = built["images"][0]["flash_parts"][0]
            part["offset"] = part["offset"] + by if to is None else to
        return edit

    for edit, needle, what in (
        (move_first_part(by=1), "contiguously", "a gap before a flash part"),
        (move_first_part(by=-1), "contiguously",
         "a flash part overlapping the image before it"),
        (move_first_part(to=-1), "nonsensical offset/bytes",
         "a negative flash part offset"),
        (move_first_part(to=True), "nonsensical offset/bytes",
         "a JSON true where a flash part offset belongs"),
    ):
        check_fails(
            lambda edit=edit: espdisp.unpack_bundle(
                with_parts([dict(part) for part in good_parts], edit=edit)),
            needle,
            what)
    # A part whose length runs past the end of the file: the offsets are
    # self-consistent and only the last part's size lies, so nothing fires before
    # the end-of-file check. One image, so the file stops where its bytes stop.
    stretched = [dict(part) for part in good_parts]
    stretched[2]["bytes"] += 64
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(
                espdisp.encode_manifest(
                    handmade_manifest(
                        [dict(image_entry("c6", FAKE_C6), flash_parts=stretched)])),
                payload_bytes(("c6", FAKE_C6)))),
        "past the end",
        "a flash part that runs off the end of the file")

    # -- the hashes: one flipped byte anywhere in any payload is caught, which is
    # the whole reason they are in the manifest. The offsets are named rather than
    # guessed at, so each flip is known to land in a particular payload.
    first_image = manifest["images"][0]
    for index, what in (
        (first_image["offset"], "the first byte of the C6 app image"),
        (first_image["offset"] + first_image["bytes"] // 2, "the middle of it"),
        (first_image["flash_parts"][0]["offset"], "the C6 bootloader's first byte"),
        (first_image["flash_parts"][1]["offset"] + 1, "inside the C6 partition table"),
        (len(good) - 1, "the last byte of the file, the S3's boot_app0"),
    ):
        flipped = bytearray(good)
        flipped[index] ^= 0x01
        check_fails(
            lambda flipped=flipped: espdisp.unpack_bundle(bytes(flipped)),
            "hash mismatch",
            "one flipped byte at file offset %d (%s)" % (index, what))
    zeroed = dict(manifest)
    zeroed["images"] = [dict(zeroed["images"][0], sha256="0" * 64), zeroed["images"][1]]
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(zeroed), area)),
        "hash mismatch",
        "a manifest hash that is not the payload's")

    check_fails(
        lambda: espdisp.read_bundle("/nonexistent/espdisp.espdispfw"),
        "cannot read",
        "a bundle path that does not exist")


def test_bundle_file_round_trip():
    """Through an actual file, including the atomic write.

    The pure functions are covered above; what this adds is that the bytes
    survive the filesystem and that an interrupted write cannot leave a partial
    file behind for the app to parse.
    """
    manifest, data = sample_bundle()
    tmp = tempfile.mkdtemp(prefix="espdisp-test-bundle-")
    try:
        path = os.path.join(tmp, "espdisp-firmware-1.2.0.espdispfw")
        espdisp.write_file_atomically(path, data)
        with open(path, "rb") as fh:
            check_equal(fh.read(), data, "the file holds exactly what was packed")
        got, payloads, flash_payloads = espdisp.read_bundle(path)
        check_equal(got, manifest, "read back through the file")
        check_equal(payloads["esp32s3"], FAKE_S3, "payload survives the filesystem")
        check_equal(
            flash_payloads["esp32s3"], fake_flash_payloads("s3"),
            "and so do the parts a blank board needs")
        check_equal(os.listdir(tmp), [os.path.basename(path)], "no temp file left behind")

        # Overwriting is a replace, so a second bundle at the same path cannot
        # leave a mixture of the two.
        espdisp.write_file_atomically(path, b"shorter")
        with open(path, "rb") as fh:
            check_equal(fh.read(), b"shorter", "a rewrite replaces rather than patches")
        check_equal(os.listdir(tmp), [os.path.basename(path)], "and still nothing else")

        # A write that fails mid-way leaves the previous file alone and no
        # scratch file behind.
        class Boom(Exception):
            pass

        def explode(*_args, **_kwargs):
            raise Boom()

        with unittest.mock.patch.object(os, "replace", explode):
            try:
                espdisp.write_file_atomically(path, data)
            except Boom:
                pass
        with open(path, "rb") as fh:
            check_equal(fh.read(), b"shorter", "an interrupted write changes nothing")
        check_equal(
            os.listdir(tmp), [os.path.basename(path)],
            "and cleans up after itself")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_git_provenance():
    """Provenance is best effort, and the commands that produce it are pinned.

    Same reasoning as discovery_command: a typo here does not raise, it makes
    every bundle claim it came from nowhere, and the manifest would look
    plausible while saying nothing.
    """
    calls = []

    def stub(*results):
        queue = list(results)

        def run(cmd, timeout=None):
            calls.append(cmd)
            return queue.pop(0)

        return run

    def done(code, out):
        return subprocess.CompletedProcess([], code, out, "")

    head = done(0, "D72425B65DF66733FB34F45BB7C63F54CFE851A9\n")
    with unittest.mock.patch.object(
        espdisp, "run_capture", stub(head, done(0, ""))
    ):
        commit, dirty = espdisp.git_provenance("/repo")
    check_equal(commit, "d72425b65df66733fb34f45bb7c63f54cfe851a9", "commit, lowercased")
    check_equal(dirty, False, "an empty porcelain listing is clean")
    check_equal(calls[0], ["git", "-C", "/repo", "rev-parse", "HEAD"], "HEAD command")
    check_equal(
        calls[1], ["git", "-C", "/repo", "status", "--porcelain"], "status command")

    with unittest.mock.patch.object(
        espdisp, "run_capture", stub(head, done(0, " M tools/espdisp.py\n"))
    ):
        check_equal(espdisp.git_provenance("/repo")[1], True, "a modified file is dirty")
    # Untracked files count, deliberately: an untracked source file under
    # firmware/ is compiled into the image like any other.
    with unittest.mock.patch.object(
        espdisp, "run_capture", stub(head, done(0, "?? firmware/display_stream/new.h\n"))
    ):
        check_equal(espdisp.git_provenance("/repo")[1], True, "an untracked file is dirty")

    # No git, no .git, or a git that failed: null provenance rather than a
    # refusal, so an exported copy of this tool can still write a bundle.
    with unittest.mock.patch.object(
        espdisp, "run_capture", stub(done(128, ""))
    ):
        check_equal(espdisp.git_provenance("/repo"), (None, False), "not a git checkout")
    with unittest.mock.patch.object(
        espdisp, "run_capture", stub(done(0, "not-a-sha\n"))
    ):
        check_equal(espdisp.git_provenance("/repo"), (None, False), "a nonsense HEAD")
    with unittest.mock.patch.object(
        espdisp, "run_capture", stub(head, done(1, ""))
    ):
        check_equal(
            espdisp.git_provenance("/repo"),
            ("d72425b65df66733fb34f45bb7c63f54cfe851a9", False),
            "a known commit whose cleanliness could not be read")

    # And the real repository, which is the only end-to-end check available: this
    # test file is tracked, so HEAD must resolve here.
    commit, _ = espdisp.git_provenance()
    check(
        commit is not None and re.fullmatch(r"[0-9a-f]{40}", commit),
        "the real repo resolves a commit: %r" % commit)


def test_utc_timestamp():
    stamp = espdisp.utc_timestamp()
    check(
        bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", stamp)),
        "built_at is ISO 8601 UTC with a Z suffix: %r" % stamp)


def test_tile_stream_wire():
    # Byte-for-byte vectors written from tile_protocol.h's format comment,
    # independent of BOTH the firmware and Swift suites - a third side of
    # the no-shared-fixture rule, so a drift in any one implementation
    # fails a test somewhere instead of agreeing with itself.
    check_equal(
        espdisp.tile_header(0x1234, 5, 80),
        bytes([0x34, 0x12, 0x05, 0x80, 0x50, 0x00]),
        "tile header: LE fields, stream flag on first_tile bit 15",
    )
    check_equal(
        espdisp.tile_header(7, 899, 900, landscape=True),
        bytes([0x07, 0x00, 0x83, 0x83, 0x84, 0x83]),
        "tile header: landscape bit 15 of dirty_count, tile 899 = 0x383",
    )
    # Record: tile 5, run 3 -> tile field 0x0805; 3 payload bytes, BC1
    # (codec 2) -> len field 0x8003.
    check_equal(
        espdisp.tile_record(5, 3, espdisp.TILE_CODEC_BC1, b"\xAA\xBB\xCC"),
        bytes([0x05, 0x08, 0x03, 0x80, 0xAA, 0xBB, 0xCC]),
        "tile record: run length in bits 14..10, codec in len bits 15..14",
    )
    check_fails(
        lambda: espdisp.tile_record(0, 33, 0, b"x"),
        "out of range",
        "runs cap at 32 tiles",
    )
    # RLE565 flat runs: 129 px is one chunk (control 0xFF); 130 px is a
    # 129-run then a 1-px literal; 131 px is 129 + a 2-run.
    check_equal(espdisp.rle565_flat(0x1234, 129), bytes([0xFF, 0x12, 0x34]),
                "flat 129 px = one max repeat chunk")
    check_equal(espdisp.rle565_flat(0x1234, 130),
                bytes([0xFF, 0x12, 0x34, 0x00, 0x12, 0x34]),
                "flat 130 px = 129-run then 1-px literal")
    check_equal(espdisp.rle565_flat(0x1234, 131),
                bytes([0xFF, 0x12, 0x34, 0x80, 0x12, 0x34]),
                "flat 131 px = 129-run then 2-run")
    # BC1 flat tile: 16 blocks of [c0 LE][c1 LE][4 zero index bytes].
    flat = espdisp.bc1_flat(0xF800, 16, 16)
    check_equal(len(flat), 128, "16x16 BC1 tile is 16 blocks x 8 B")
    check_equal(flat[:8], bytes([0x00, 0xF8, 0x00, 0xF8, 0, 0, 0, 0]),
                "flat block: both endpoints the color, indices zero")
    check_equal(len(espdisp.bc1_flat(0xF800, 2, 2)), 8,
                "the 2x2 corner tile still occupies one whole block")
    # The smoke-test packet set: every datagram within budget, keyframe
    # covers all 900 tiles as 30 full-row runs, partial frame is 5 tiles.
    packets = espdisp.tile_test_packets(1)
    check(len(packets) >= 2, "at least a keyframe packet and a partial")
    total_runs = 0
    for p in packets:
        check(len(p) <= espdisp.TILE_PACKET_BUDGET, "datagram within budget")
        frame, first_field, dirty = struct.unpack("<HHH", p[:6])
        check(first_field & 0x8000 != 0, "stream flag set on every packet")
        # Walk the records; the first must match the header's first_tile.
        at = 6
        first_seen = None
        while at < len(p):
            tile_field, len_field = struct.unpack("<HH", p[at:at + 4])
            check(tile_field & 0x8000 == 0, "record reserved bit clear")
            if first_seen is None:
                first_seen = tile_field & 0x03FF
            body = len_field & 0x3FFF
            check(body > 0, "no zero-length record bodies")
            at += 4 + body
            total_runs += 1
        check_equal(at, len(p), "records tile the packet exactly")
        check_equal(first_seen, first_field & 0x03FF,
                    "header first_tile cross-checks record one")
    check_equal(total_runs, 30 + 5, "30 keyframe rows plus 5 squares")


def test_describe_bundle():
    """bundle-info's output is the whole point of the manifest, so it is checked.

    A user runs it to decide whether to hand a file to someone or push it, and
    "dirty" is the line that stops a bundle built from uncommitted work being
    mistaken for a release.
    """
    manifest = sample_manifest()
    text = "\n".join(espdisp.describe_bundle(manifest))
    check("1.2.0" in text, "the version is shown")
    check("2026-01-02T03:04:05Z" in text, "and when it was built")
    check("a" * 40 in text, "and the commit")
    check("esp32c6" in text and "esp32s3" in text, "and every chip")
    check("dirty" not in text, "a clean tree says nothing about dirt")
    check(
        manifest["images"][0]["sha256"][:16] in text,
        "a hash prefix is enough for the writer's summary")

    dirty = "\n".join(espdisp.describe_bundle(sample_manifest()))
    check("dirty" not in dirty, "still clean")
    manifest["source_dirty"] = True
    check("dirty" in "\n".join(espdisp.describe_bundle(manifest)),
          "uncommitted work is called out")
    manifest["source_commit"] = None
    check("unknown" in "\n".join(espdisp.describe_bundle(manifest)),
          "and so is a bundle from no checkout at all")

    full = "\n".join(espdisp.describe_bundle(sample_manifest(), full_hash=True))
    check(
        manifest["images"][0]["sha256"] in full,
        "bundle-info prints the whole hash, which is what shasum can be compared to")
    check(
        espdisp.BOARDS["c6"].fqbn in full, "and the FQBN each image was built with")

    # THE FLASH PARTS AND THEIR ADDRESSES. This is the only place a person can see
    # whether a file they were handed can bring up a new board, and the addresses
    # are what a reader takes from the file rather than assuming, so they are
    # printed rather than summarised.
    listing = "\n".join(espdisp.describe_bundle(sample_manifest()))
    for role in espdisp.REQUIRED_FLASH_ROLES:
        check(role in listing, "the %s is listed" % role)
    check("0x000000" in listing, "with the bootloader's flash address")
    check("0x008000" in listing, "and the partition table's")
    check("0x00e000" in listing, "and boot_app0's")
    check("0x010000" in listing, "and the application image's")
    parts = sample_manifest()["images"][0]["flash_parts"]
    check(
        parts[0]["sha256"][:16] in listing,
        "a hash prefix for each part in the summary")
    check(
        parts[0]["filename"] not in listing,
        "the source filenames stay out of the short listing")
    check(
        parts[0]["sha256"] in full and parts[0]["filename"] in full,
        "and bundle-info's long form prints both")
    check(
        "boot_app0.bin" in full,
        "including the one file that came from the core rather than the compile")

    # A generation-1 bundle: not damaged, and the one thing about it a user cannot
    # see from the listing is that it cannot bring up a blank board. So it is said.
    v1 = dict(sample_manifest(), format=1)
    v1["images"] = [
        {key: value for key, value in image.items()
         if key not in ("app_address", "flash_parts")}
        for image in v1["images"]
    ]
    older = "\n".join(espdisp.describe_bundle(v1))
    check("app only" in older, "an older bundle says it carries the app only")
    check("never been flashed" in older, "and what that means it cannot do")
    check("format 1" in older, "naming the generation it is")
    for role in espdisp.REQUIRED_FLASH_ROLES:
        check(role not in older, "and it claims no %s" % role)


def main():
    test_board_table()
    test_resolve_board()
    test_network_discovery()
    test_discovery_command()
    test_classify_ota_target()
    test_verify_ota_target()
    test_password_policy()
    test_cfgotapw_line()
    test_espota_command()
    test_app_image_picks_the_app_not_the_flash_image()
    test_fw_version_from_sketch()
    test_bundle_length_line()
    test_bundle_layout_is_pinned()
    test_generation_one_layout_is_pinned_and_still_read()
    test_flash_part_vocabulary()
    test_bootloader_address_from_boards_txt()
    test_core_lookups()
    test_export_binary()
    test_collect_flash_parts()
    test_bundle_manifest_offsets()
    test_bundle_round_trip()
    test_pack_bundle_refusals()
    test_unpack_bundle_refusals()
    test_bundle_file_round_trip()
    test_git_provenance()
    test_utc_timestamp()
    test_tile_stream_wire()
    test_describe_bundle()

    if failures:
        print("FAILED: %d of %d checks" % (failures, checks))
        return 1
    print("OK: %d checks passed" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
