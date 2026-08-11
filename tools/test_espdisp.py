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
import sys
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


def test_app_image_picks_the_app_not_the_flash_image(tmp="/tmp/espdisp-test-images"):
    # The export directory also holds <sketch>.ino.merged.bin - the whole-flash
    # image with the bootloader and partition table in it, right for esptool over
    # USB and 8MB of wrong for an app slot.
    os.makedirs(tmp, exist_ok=True)
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
        for root, _, files in os.walk(tmp, topdown=False):
            for name in files:
                os.unlink(os.path.join(root, name))
            os.rmdir(root)


def main():
    test_board_table()
    test_resolve_board()
    test_network_discovery()
    test_classify_ota_target()
    test_verify_ota_target()
    test_password_policy()
    test_cfgotapw_line()
    test_espota_command()
    test_app_image_picks_the_app_not_the_flash_image()

    if failures:
        print("FAILED: %d of %d checks" % (failures, checks))
        return 1
    print("OK: %d checks passed" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
