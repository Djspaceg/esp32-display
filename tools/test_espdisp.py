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


# Two stand-ins for real images, small enough to assert on. FAKE_C6 contains the
# bundle magic on purpose: the payload area is framed by the manifest's offsets,
# so a reader that scanned for a marker rather than doing arithmetic would find
# one here and go wrong. Both carry non-UTF-8 bytes, because an app image is not
# text and nothing in this path may treat it as text.
FAKE_C6 = b"\x00\x01\x02\xffc6 image ESPDISPFW1\n\x00 tail"
FAKE_S3 = bytes(range(256)) + b"\xffs3 image"


def image_entry(key, blob):
    """One pre-offset manifest entry, the way cmd_bundle builds them."""
    return {
        "board": key,
        "chip": espdisp.BOARDS[key].chip,
        "fqbn": espdisp.BOARDS[key].fqbn,
        "filename": "display_stream.ino.bin",
        "bytes": len(blob),
        "sha256": espdisp.sha256_hex(blob),
    }


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


def sample_bundle():
    manifest = sample_manifest()
    return manifest, espdisp.pack_bundle(
        manifest, {"esp32c6": FAKE_C6, "esp32s3": FAKE_S3}
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


def test_bundle_layout_is_pinned():
    """The file's bytes, asserted literally.

    This is the one test that would notice the format changing. The Mac app
    reading these files is a separate implementation that cannot be recompiled
    from this repo, and a file already handed to someone cannot be recalled, so
    the layout has to break a test rather than break a reader. Written out by
    hand for the same reason firmware/test and Tests/SenderProtocolTests assert
    the same band bytes independently: agreement between two hand-written
    versions is the check.
    """
    payload = b"\x00\x01\x02\xffnot really firmware\n"
    manifest = {
        "format": 1,
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
                "offset": 372,  # 22 + 350, and pack_bundle refuses if it is not
                "sha256": (
                    "93fcaa5a244cfb4bd4d8255e820062cc"
                    "4ff5ffa650e1317546bbee66d8d6c4d8"),
            }
        ],
    }
    # The manifest as it must appear on disk: sorted keys, no spaces. 350 bytes.
    want_json = (
        b'{"built_at":"2026-01-02T03:04:05Z","firmware_version":"9.9.9","format":1,'
        b'"images":[{"board":"c6","bytes":24,"chip":"esp32c6",'
        b'"filename":"display_stream.ino.bin","fqbn":"esp32:esp32:esp32c6",'
        b'"offset":372,"sha256":"93fcaa5a244cfb4bd4d8255e820062cc'
        b'4ff5ffa650e1317546bbee66d8d6c4d8"}],"source_commit":null,'
        b'"source_dirty":false,"tool":"espdisp.py bundle"}')
    check_equal(len(want_json), 350, "the hand-written manifest is 350 bytes")
    check_equal(espdisp.encode_manifest(manifest), want_json, "canonical encoding")

    data = espdisp.pack_bundle(manifest, {"esp32c6": payload})

    # The 22-byte prefix, literally: magic line, then ten zero-padded digits and
    # a newline. Everything after this is found by arithmetic on those digits.
    check_equal(data[:22], b"ESPDISPFW1\n0000000350\n", "the fixed 22-byte prefix")
    check_equal(data[:11], b"ESPDISPFW1\n", "magic line, generation included")
    check_equal(data[11:21], b"0000000350", "ten digits, zero padded")
    check_equal(data[21:22], b"\n", "and a newline")
    check_equal(data[22:372], want_json, "the manifest sits at offset 22")
    check_equal(data[372:], payload, "the payload starts where the manifest says")
    check_equal(len(data), 396, "22 + 350 + 24")
    check_equal(
        data, b"ESPDISPFW1\n0000000350\n" + want_json + payload,
        "the whole file, byte for byte")

    # And it reads back, so the pin describes a file this tool accepts rather
    # than a shape nobody parses.
    got_manifest, payloads = espdisp.unpack_bundle(data)
    check_equal(got_manifest, manifest, "the manifest survives a round trip")
    check_equal(payloads, {"esp32c6": payload}, "so does the payload")


def test_bundle_manifest_offsets():
    manifest = sample_manifest()
    raw = espdisp.encode_manifest(manifest)
    first, second = manifest["images"]

    # Absolute from the start of the file, so a reader is one slice.
    check_equal(
        first["offset"], espdisp.BUNDLE_HEADER_BYTES + len(raw),
        "the first image starts right after the manifest")
    check_equal(
        second["offset"], first["offset"] + len(FAKE_C6),
        "the second follows the first with no gap")
    check_equal(first["bytes"], len(FAKE_C6), "sizes come from the payloads")
    check_equal(second["bytes"], len(FAKE_S3), "for both images")
    check_equal(first["chip"], "esp32c6", "chip token, the app's vocabulary")
    check_equal(second["chip"], "esp32s3", "and the other one")
    check_equal(manifest["format"], 1, "format generation")
    check_equal(manifest["firmware_version"], "1.2.0", "version as given")
    check_equal(manifest["source_commit"], "a" * 40, "provenance is carried")
    check_equal(manifest["source_dirty"], False, "and so is cleanliness")
    check_equal(manifest["tool"], "espdisp.py bundle", "who wrote it")
    check_equal(sorted(manifest), sorted(espdisp.MANIFEST_KEYS), "no key is missing")
    for image in manifest["images"]:
        check_equal(sorted(image), sorted(espdisp.IMAGE_KEYS), "no image key is missing")

    # The manifest describes its own length, so the offsets are solved rather than
    # computed. A payload sized to push an offset across a digit boundary is the
    # case that catches a solver that only iterates once: the offset written must
    # still equal 22 + the length of the manifest it is written into.
    for size in (1, 9, 10, 99, 100, 617, 1024, 65536):
        blob = b"\xa5" * size
        one = espdisp.bundle_manifest(
            "1.2.0", [image_entry("c6", blob)], "2026-01-02T03:04:05Z")
        encoded = espdisp.encode_manifest(one)
        check_equal(
            one["images"][0]["offset"], espdisp.BUNDLE_HEADER_BYTES + len(encoded),
            "offsets settle for a %d-byte payload" % size)
        # And the file it produces agrees, which is what the offsets are for.
        packed = espdisp.pack_bundle(one, {"esp32c6": blob})
        check_equal(
            packed[one["images"][0]["offset"]:], blob,
            "the payload lands at the stated offset for %d bytes" % size)

    check_fails(
        lambda: espdisp.bundle_manifest("1.2.0", [], "2026-01-02T03:04:05Z"),
        "at least one image",
        "a manifest with no images is refused")


def test_bundle_round_trip():
    manifest, data = sample_bundle()
    got, payloads = espdisp.unpack_bundle(data)

    check_equal(got, manifest, "the manifest round trips unchanged")
    check_equal(sorted(payloads), ["esp32c6", "esp32s3"], "keyed by chip token")
    # Byte for byte, not merely the right length: the images are pushed to a panel
    # that validates a hash of its own, so a payload that survives with the right
    # size and the wrong bytes would be the worst possible outcome.
    check_equal(payloads["esp32c6"], FAKE_C6, "the C6 image, byte for byte")
    check_equal(payloads["esp32s3"], FAKE_S3, "the S3 image, byte for byte")
    check(
        b"ESPDISPFW1\n" in payloads["esp32c6"],
        "a payload containing the magic is framed by offsets, not by scanning")
    check_equal(
        espdisp.sha256_hex(payloads["esp32c6"]), manifest["images"][0]["sha256"],
        "the hash in the manifest is the hash of the payload")

    # A single-image bundle is a normal file, not a special case: --board c6 on a
    # machine that only owns one panel writes one.
    one = espdisp.bundle_manifest(
        "1.2.0", [image_entry("s3", FAKE_S3)], "2026-01-02T03:04:05Z")
    _, only = espdisp.unpack_bundle(espdisp.pack_bundle(one, {"esp32s3": FAKE_S3}))
    check_equal(only, {"esp32s3": FAKE_S3}, "one image round trips too")


def test_pack_bundle_refusals():
    """The writer's own checks: the last place a disagreement can still be fixed."""
    manifest = sample_manifest()

    check_fails(
        lambda: espdisp.pack_bundle(manifest, {"esp32c6": FAKE_C6}),
        "no payload was given",
        "a manifest listing an image nobody supplied")
    # The needle is the length message specifically, not the "the manifest says"
    # tail it shares with the hash refusal: a wrong length also hashes wrong, so a
    # looser needle would pass with the length check deleted.
    check_fails(
        lambda: espdisp.pack_bundle(
            manifest, {"esp32c6": FAKE_C6, "esp32s3": FAKE_S3 + b"!"}),
        "payload is %d bytes" % (len(FAKE_S3) + 1),
        "a payload whose length does not match the manifest")
    swapped = espdisp.bundle_manifest(
        "1.2.0", [image_entry("c6", FAKE_C6)], "2026-01-02T03:04:05Z")
    swapped["images"][0]["sha256"] = "0" * 64
    check_fails(
        lambda: espdisp.pack_bundle(swapped, {"esp32c6": FAKE_C6}),
        "hashes to",
        "a payload whose hash does not match the manifest")
    moved = espdisp.bundle_manifest(
        "1.2.0", [image_entry("c6", FAKE_C6)], "2026-01-02T03:04:05Z")
    moved["images"][0]["offset"] += 1
    check_fails(
        lambda: espdisp.pack_bundle(moved, {"esp32c6": FAKE_C6}),
        "do not describe this file",
        "an offset that does not describe the file being written")
    check_fails(
        lambda: espdisp.pack_bundle(dict(manifest, images=[]), {}),
        "at least one image",
        "packing nothing")


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

    # It reads, to begin with. Otherwise every check below could pass for the
    # wrong reason.
    check_accepts(lambda: espdisp.unpack_bundle(good), "the good bundle is accepted")

    # -- the header
    check_fails(
        lambda: espdisp.unpack_bundle(b""), "shorter than", "an empty file")
    check_fails(
        lambda: espdisp.unpack_bundle(b"ESPDISPFW1\n000"), "shorter than",
        "a file that stops inside the header")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, magic=b"NOTABUNDL1\n")),
        "does not start with the ESPDISPFW1 magic",
        "bad magic")
    check_fails(
        lambda: espdisp.unpack_bundle(b"\x00" * 64), "magic", "a file of zeros")
    # A future generation gets a message that says which one this tool speaks,
    # rather than "not a bundle" - the file is fine, the reader is old.
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, magic=b"ESPDISPFW2\n")),
        "unsupported bundle generation",
        "a newer format generation")
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
        lambda: espdisp.unpack_bundle(handmade_bundle(b'{"format": 1,')),
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
                handmade_bundle(espdisp.encode_manifest(short),
                                FAKE_C6 + FAKE_S3)),
            "missing %s" % key,
            "a manifest with no %r" % key)
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(dict(manifest, format=2)),
                            FAKE_C6 + FAKE_S3)),
        "this tool reads format 1",
        "an unknown format generation in the manifest")
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
    for key in espdisp.IMAGE_KEYS:
        broken = dict(manifest)
        image = dict(broken["images"][0])
        del image[key]
        broken["images"] = [image, broken["images"][1]]
        check_fails(
            lambda broken=broken, key=key: espdisp.unpack_bundle(
                handmade_bundle(espdisp.encode_manifest(broken),
                                FAKE_C6 + FAKE_S3)),
            "missing %s" % key,
            "an image with no %r" % key)

    # -- the offsets, which are what make a truncated or edited file detectable
    def with_first(**changes):
        broken = dict(manifest)
        broken["images"] = [dict(broken["images"][0], **changes), broken["images"][1]]
        return handmade_bundle(
            espdisp.encode_manifest(broken), FAKE_C6 + FAKE_S3)

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
                FAKE_C6 + FAKE_S3)),
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
        "trailing after the last image",
        "bytes appended after the last image")
    check_fails(
        lambda: espdisp.unpack_bundle(good[:-1]),
        "past the end",
        "a file truncated inside the last image")

    # -- duplicate chips: the app looks an image up by chip, so two would make
    # "the c6 image" ambiguous rather than merely redundant.
    twice = espdisp.bundle_manifest(
        "1.2.0", [image_entry("c6", FAKE_C6), image_entry("c6", FAKE_C6)],
        "2026-01-02T03:04:05Z")
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(twice), FAKE_C6 + FAKE_C6)),
        "twice",
        "the same chip listed twice")

    # -- the hashes: one flipped byte anywhere in a payload is caught, which is
    # the whole reason they are in the manifest.
    for position in (0, len(FAKE_C6) // 2, len(good) - 1):
        index = manifest["images"][0]["offset"] + position if position < len(FAKE_C6) else position
        flipped = bytearray(good)
        flipped[index] ^= 0x01
        check_fails(
            lambda flipped=flipped: espdisp.unpack_bundle(bytes(flipped)),
            "hash mismatch",
            "one flipped byte at file offset %d" % index)
    zeroed = dict(manifest)
    zeroed["images"] = [dict(zeroed["images"][0], sha256="0" * 64), zeroed["images"][1]]
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(zeroed), FAKE_C6 + FAKE_S3)),
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
        got, payloads = espdisp.read_bundle(path)
        check_equal(got, manifest, "read back through the file")
        check_equal(payloads["esp32s3"], FAKE_S3, "payload survives the filesystem")
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
    test_bundle_manifest_offsets()
    test_bundle_round_trip()
    test_pack_bundle_refusals()
    test_unpack_bundle_refusals()
    test_bundle_file_round_trip()
    test_git_provenance()
    test_utc_timestamp()
    test_describe_bundle()

    if failures:
        print("FAILED: %d of %d checks" % (failures, checks))
        return 1
    print("OK: %d checks passed" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
