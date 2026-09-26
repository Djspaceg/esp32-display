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
# refusals are the point - resolve_family exists to refuse rather than guess a
# chip, classify_ota_target exists to refuse a push at the wrong panel, and
# check_password_policy exists to refuse a password the firmware would not store.
# Those guards were the only unguarded thing left in the change, and none of them
# need hardware to exercise.
import argparse
import copy
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import tomllib
import unittest.mock
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board_descriptor  # noqa: E402
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


def check_call_equal(fn, want, what):
    global checks, failures
    checks += 1
    try:
        got = fn()
    except Exception as exc:  # noqa: BLE001 - report all contract failures
        failures += 1
        print("FAIL: %s: raised %s" % (what, type(exc).__name__))
        return
    if got != want:
        failures += 1
        print("FAIL: %s: got %r, want %r" % (what, got, want))


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


def check_descriptor_fails(descriptors, needle, what):
    global checks, failures
    checks += 1
    try:
        board_descriptor.validate_descriptors(descriptors)
    except board_descriptor.DescriptorError as exc:
        if needle not in str(exc):
            failures += 1
            print("FAIL: %s: message %r lacks %r" % (what, str(exc), needle))
        return
    except Exception as exc:  # noqa: BLE001
        failures += 1
        print("FAIL: %s: raised %s instead of DescriptorError" %
              (what, type(exc).__name__))
        return
    failures += 1
    print("FAIL: %s: did not refuse" % what)


def uncommented_source(source):
    """Remove C/C++ comments so disabled code cannot satisfy source contracts."""
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def defined_blocks(source, macro):
    """Return simple `#if defined(MACRO)` blocks after comments are removed."""
    source = uncommented_source(source)
    return re.findall(
        r"^[ \t]*#if[ \t]+defined\([ \t]*%s[ \t]*\)[ \t]*\n"
        r"(.*?)^[ \t]*#endif[ \t]*$" % re.escape(macro),
        source,
        flags=re.DOTALL | re.MULTILINE,
    )


def braced_body(source, opening_brace):
    """Return one C/C++ braced body and the index immediately after it."""
    depth = 0
    for index in range(opening_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening_brace + 1:index], index + 1
    return "", -1


def function_body(source, signature):
    """Return a C/C++ function body selected by a signature regex."""
    source = uncommented_source(source)
    function = re.search(signature + r"\s*\{", source)
    if function is None:
        return ""
    body, _ = braced_body(source, function.end() - 1)
    return body


# --------------------------------------------------------------------------
# the board table: these two strings are the reason the tool exists


def preprocess_board_config(*selectors, target="CONFIG_IDF_TARGET_ESP32P4"):
    """Run the host preprocessor against one chip/selector combination."""
    compiler = os.environ.get("CXX") or shutil.which("c++")
    if not compiler:
        raise RuntimeError("C++ compiler not found")
    include_dir = os.path.join(
        espdisp.REPO_ROOT, "firmware", "libraries", "espdisp_board", "src")
    command = [
        compiler, "-E", "-x", "c++", "-I", include_dir,
        "-D%s" % target,
    ]
    command.extend("-D%s" % selector for selector in selectors)
    command.append("-")
    return subprocess.run(
        command,
        input='#include "board_config.h"\n',
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )


def _historical_exact_target_board_table():
    check_equal(
        sorted(espdisp.BOARDS),
        ["c3", "c6", "p4-4b", "s3-085", "s3-154", "s3-175", "s3-185"],
        "only canonical exact targets are board-table keys")
    check_equal(
        espdisp.BOARDS["c3"].fqbn,
        "esp32:esp32:esp32c3:CDCOnBoot=cdc,FlashSize=4M,PartitionScheme=custom",
        "C3 FQBN",
    )
    check_equal(
        espdisp.BOARDS["c6"].fqbn,
        "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M",
        "C6 FQBN",
    )
    check_equal(
        espdisp.BOARDS["p4-4b"].fqbn,
        "esp32:esp32:esp32p4:USBMode=default,CDCOnBoot=default,"
        "UploadMode=default,FlashSize=32M,PartitionScheme=custom,"
        "PSRAM=enabled,ChipVariant=prev3",
        "P4 v1.3 engineering-sample FQBN",
    )
    check_equal(espdisp.BOARDS["p4-4b"].chip, "esp32p4", "P4 chip")
    check_equal(
        espdisp.PLATFORMS["p4"].chip, "esp32p4",
        "P4 chip belongs to the platform catalog")
    check("ChipVariant=prev3" in espdisp.PLATFORMS["p4"].fqbn_template,
          "P4 silicon profile belongs to the platform catalog")
    check("PSRAM=enabled" in espdisp.PLATFORMS["p4"].fqbn_template,
          "P4 memory profile belongs to the platform catalog")
    check_equal(espdisp.BOARDS["p4-4b"].target_options, (),
                "the 4B target adds no P4 platform build facts")
    check("chip" not in espdisp.Board._fields and
          "fqbn" not in espdisp.Board._fields,
          "board rows derive chip and FQBN from their platform")
    check_equal(espdisp.BOARDS["p4-4b"].extra_flags,
                ("-DESPDISP_BOARD_P4_4B",), "P4 exact selector")
    board_config_path = os.path.join(
        espdisp.REPO_ROOT, "firmware", "libraries", "espdisp_board", "src",
        "board_config.h")
    with open(board_config_path, "r", encoding="utf-8") as source_file:
        board_config_source = source_file.read()
    check("defined(ESPDISP_BOARD_P4_4B)" in board_config_source,
          "firmware consumes the P4 exact selector")
    check("ESP32-P4 builds require exactly one compatible exact board selector"
          in board_config_source,
          "firmware fails closed when a P4 selector is absent or ambiguous")
    check("platformSupportsPanel" in board_config_source,
          "platform/panel composition is executable rather than descriptive")
    p4_only = preprocess_board_config("ESPDISP_BOARD_P4_4B")
    check_equal(p4_only.returncode, 0,
                "the P4 exact selector preprocesses successfully")
    no_selector = preprocess_board_config()
    check(no_selector.returncode != 0 and
          "exactly one compatible exact board selector" in no_selector.stderr,
          "a P4 build with no exact selector fails preprocessing")
    for conflicting_selector in (
            "ESPDISP_BOARD_S3_085", "ESPDISP_BOARD_S3_154",
            "ESPDISP_DOOM_S3_175", "ESPDISP_BOARD_S3_185"):
        conflict = preprocess_board_config(
            "ESPDISP_BOARD_P4_4B", conflicting_selector)
        check(conflict.returncode != 0 and
              "exactly one compatible exact board selector" in conflict.stderr,
              "P4 plus %s fails preprocessing" % conflicting_selector)
    check_equal(espdisp.BOARDS["p4-4b"].partition_csv,
                "partitions_p4_4b.csv", "P4 isolated partition source")
    check_equal(espdisp.board_key_for_chip("esp32p4"), None,
                "P4 chip identity never auto-selects a display target")
    check_equal(
        espdisp.BOARDS["s3-175"].fqbn,
        "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,"
        "PartitionScheme=custom",
        "s3-175 FQBN",
    )
    check_equal(
        espdisp.BOARDS["s3-185"].fqbn,
        "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi",
        "s3-185 FQBN",
    )
    check_equal(
        espdisp.BOARDS["s3-085"].fqbn,
        "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=8M,PSRAM=opi",
        "s3-085 FQBN",
    )
    check_equal(
        espdisp.BOARDS["s3-085"].extra_flags,
        ("-DESPDISP_BOARD_S3_085",),
        "s3-085 uses only its exact board selector",
    )
    check_equal(
        espdisp.BOARDS["s3-154"].fqbn,
        "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi",
        "s3-154 FQBN",
    )
    check_equal(
        espdisp.BOARDS["s3-154"].extra_flags,
        ("-DESPDISP_BOARD_S3_154",),
        "s3-154 uses only its exact board selector",
    )
    for key in ("s3-085", "s3-154", "s3-175", "s3-185"):
        check_equal(espdisp.BOARDS[key].chip, "esp32s3", "%s chip" % key)
    check_equal(
        espdisp.BOARDS["s3-185"].extra_flags,
        ("-DESPDISP_BOARD_S3_185",),
        "the 1.85-inch profile has its compile-time selector")
    check_equal(
        espdisp.BOARDS["s3-175"].extra_flags,
        ("-DESPDISP_DOOM_S3_175",),
        "the 1.75-inch profile owns the Doom compile selector")
    check("PartitionScheme=custom" in espdisp.BOARDS["s3-175"].fqbn,
          "s3-175 uses the Doom partition scheme")
    for key in ("c6", "s3-085", "s3-154", "s3-185"):
        check("PartitionScheme" not in espdisp.BOARDS[key].fqbn,
              "%s keeps its default partition scheme" % key)
    check_equal(espdisp.board_key_for_fqbn("esp32:esp32:esp32c6"), "c6", "FQBN -> key")
    check_equal(
        espdisp.board_key_for_fqbn("esp32:esp32:esp32s3:PSRAM=opi"), None,
        "an S3 FQBN cannot identify the attached display")
    check_equal(
        espdisp.board_key_for_fqbn("esp32:esp32:esp32c3"), "c3",
        "C3 FQBN is a supported exact target",
    )
    check_equal(espdisp.board_key_for_fqbn("nonsense"), None, "malformed FQBN")
    check_equal(espdisp.board_key_for_chip("esp32c6"), "c6", "unique chip -> target")
    check_equal(
        espdisp.board_key_for_chip("ESP32S3"), None,
        "a shared chip cannot identify an exact target")
    check_equal(
        espdisp.board_keys_for_chip("ESP32S3"),
        ["s3-085", "s3-154", "s3-175", "s3-185"],
        "all exact S3 targets remain discoverable")
    check_equal(espdisp.canonical_board_key("s3"), "s3-175", "CLI compatibility alias")
    check_equal(espdisp.canonical_board_key("s3-185"), "s3-185", "canonical key stays exact")
    check_equal(espdisp.board_key_for_chip(""), None, "no chip -> no key")


def _historical_exact_target_argparse():
    parser = espdisp.build_parser()
    check_equal(
        espdisp.board_choices(),
        ["c3", "c6", "p4-4b", "s3", "s3-085", "s3-154", "s3-175", "s3-185"],
        "argparse accepts canonical targets plus the compatibility alias")
    for command in ("compile", "flash"):
        args = parser.parse_args([command, "--board", "s3"])
        check_equal(args.board, "s3", "%s accepts the s3 alias" % command)
    ota = parser.parse_args(["ota", "panel.local", "--board", "s3"])
    check_equal(ota.board, "s3", "OTA accepts the s3 alias")
    bundle = parser.parse_args([
        "bundle", "--board", "s3", "--board", "s3-085",
        "--board", "s3-154", "--board", "s3-175", "--board", "s3-185",
    ])
    check_equal(
        espdisp.bundle_board_keys(bundle.board),
        ["s3-175", "s3-085", "s3-154", "s3-185"],
        "alias and canonical spelling do not duplicate a bundle build")
    default_bundle = parser.parse_args(["bundle"])
    check_equal(default_bundle.board, None, "bundle selection remains optional")
    check_equal(
        espdisp.bundle_board_keys(default_bundle.board),
        ["c3", "c6", "p4-4b", "s3-085", "s3-154", "s3-175", "s3-185"],
        "default bundle builds every canonical target exactly once")
    info = parser.parse_args([
        "bundle-info", "--require-all-targets", "/tmp/firmware.espdispfw",
    ])
    check_equal(
        info.require_all_targets, True,
        "bundle-info can enforce complete packaging coverage")


# --------------------------------------------------------------------------
# resolve_board: the refusal matrix, which is the guard against flashing the
# wrong image and was itself unguarded against regression


def _historical_exact_target_resolution():
    c6_port = espdisp.PortInfo("/dev/cu.usbmodem1", ["c6"], "c6 board")
    s3_port = espdisp.PortInfo("/dev/cu.usbmodem2", ["s3-175"], "s3 board")
    blank = espdisp.PortInfo("/dev/cu.usbmodem3", [], "unknown")
    both = espdisp.PortInfo(
        "/dev/cu.usbmodem4", ["s3-175", "s3-185"], "ambiguous")

    check_equal(espdisp.resolve_board(None, c6_port).key, "c6", "port names c6")
    check_equal(
        espdisp.resolve_board(None, s3_port).key, "s3-175", "port names exact S3 target")
    check_equal(espdisp.resolve_board("c6", c6_port).key, "c6", "explicit agrees")
    check_equal(
        espdisp.resolve_board("s3", blank).key, "s3-175", "CLI alias resolves exactly")
    check_equal(
        espdisp.resolve_board("s3-185", blank).key, "s3-185", "explicit 1.85 target")
    check_equal(espdisp.resolve_board("c6", None).key, "c6", "explicit, no port")

    check_fails(
        lambda: espdisp.resolve_board("s3-175", c6_port),
        "contradicts",
        "explicit board contradicting the port",
    )
    check_fails(
        lambda: espdisp.resolve_board("s3-175", c6_port),
        "no flag to override",
        "the refusal admits it cannot be overridden",
    )
    check_fails(
        lambda: espdisp.resolve_board("s3-175", c6_port),
        "arduino-cli compile -b esp32:esp32:esp32s3",
        "the refusal spells out the raw command as the way past",
    )

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
    with unittest.mock.patch.object(
        espdisp, "probe_chip", return_value="esp32c6"
    ), unittest.mock.patch("sys.stdout", io.StringIO()):
        check_equal(espdisp.resolve_board(None, blank).key, "c6", "unique C6 probe answers")
    with unittest.mock.patch.object(
        espdisp, "probe_chip", return_value="esp32s3"
    ), unittest.mock.patch("sys.stdout", io.StringIO()):
        check_fails(
            lambda: espdisp.resolve_board(None, blank),
            "used by multiple display boards",
            "an ESP32-S3 probe requires an explicit display target")
        check_fails(
            lambda: espdisp.resolve_board(None, blank),
            "--board s3-085|s3-154|s3-175|s3-185",
            "the S3 ambiguity names all four exact choices")
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
                    "target": "c6",
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
                    "target": "s3-175",
                    "hostname": "round-panel.local.",
                    "port": "3232",
                },
            }
        },
        {
            "port": {
                "address": "192.168.1.44",
                "protocol": "network",
                "properties": {
                    "board": "esp32s3",
                    "target": "s3-185",
                    "hostname": "lcd-panel.local.",
                    "port": "3232",
                },
            }
        },
    ]
}


def _historical_exact_target_network_discovery():
    ports = espdisp.parse_network_ports(DISCOVERY_JSON)
    check_equal(len(ports), 3, "serial ports are not network ports")
    check_equal(ports[0].address, "192.168.1.42", "network address")
    check_equal(ports[0].board, "esp32c6", "board TXT record")
    check_equal(ports[0].target, "c6", "exact target TXT record")
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
    check_equal(partial[0].target, "", "target-less panel has no target")

    # Every way a user names the same panel.
    for host in ("192.168.1.42", "panel.local", "panel.local.", "PANEL", "panel"):
        found = espdisp.network_port_for_host(ports, host)
        check(found is not None and found.board == "esp32c6", "host %r resolves" % host)
    check_equal(
        espdisp.network_port_for_host(ports, "lcd-panel.local").target,
        "s3-185",
        "same-chip panels retain distinct exact targets")
    # An unknown host is None, never a guess: the caller must be able to tell
    # "not found" from "wrong board", because only one of them refuses.
    check_equal(
        espdisp.network_port_for_host(ports, "10.0.0.9"), None, "unknown address")
    check_equal(
        espdisp.network_port_for_host(ports, "other.local"), None, "unknown name")
    check_equal(espdisp.network_port_for_host(ports, ""), None, "empty host")
    check_equal(espdisp.network_port_for_host([], "panel.local"), None, "no panels")


def _historical_exact_target_ota_classification():
    c6 = espdisp.BOARDS["c6"]
    s3_175 = espdisp.BOARDS["s3-175"]
    s3_185 = espdisp.BOARDS["s3-185"]

    check_equal(
        espdisp.classify_ota_target(c6, "c6", "esp32c6"),
        espdisp.TARGET_OK, "exact C6 target")
    check_equal(
        espdisp.classify_ota_target(s3_175, "s3-175", "esp32s3"),
        espdisp.TARGET_OK, "exact S3-1.75 target")
    check_equal(
        espdisp.classify_ota_target(s3_185, "S3-185 ", "esp32s3"),
        espdisp.TARGET_OK, "target comparison normalizes case and whitespace")
    check_equal(
        espdisp.classify_ota_target(s3_185, "s3-185", "esp32c6"),
        espdisp.TARGET_WRONG, "matching target still requires a matching chip")
    check_equal(
        espdisp.classify_ota_target(s3_185, "s3-185", ""),
        espdisp.TARGET_UNKNOWN, "target without independent chip is unconfirmed")
    check_equal(
        espdisp.classify_ota_target(s3_175, "s3-185", "esp32s3"),
        espdisp.TARGET_WRONG, "same-chip exact target mismatch refuses")
    check_equal(
        espdisp.classify_ota_target(c6, "s3-175", "esp32c6"),
        espdisp.TARGET_WRONG, "exact target is classified before chip")

    check_equal(
        espdisp.classify_ota_target(c6, "", "esp32c6"),
        espdisp.TARGET_OK, "chip confirms the one known C6 target")
    check_equal(
        espdisp.classify_ota_target(s3_175, "", "esp32s3"),
        espdisp.TARGET_UNKNOWN, "S3 chip alone cannot confirm 1.75")
    check_equal(
        espdisp.classify_ota_target(s3_185, "", "esp32s3"),
        espdisp.TARGET_UNKNOWN, "S3 chip alone cannot confirm 1.85")
    check_equal(
        espdisp.classify_ota_target(c6, "", "esp32s3"),
        espdisp.TARGET_WRONG, "different known chip is wrong")
    for advertised in ("", "   ", "esp32c3", "esp32", "nonsense"):
        check_equal(
            espdisp.classify_ota_target(c6, "", advertised),
            espdisp.TARGET_UNKNOWN,
            "chip=%r cannot be placed" % advertised)


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


def _historical_exact_target_ota_verification():
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

    check_equal(
        espdisp.ota_target_requires_exact_discovery(c6), False,
        "C6 chip identity names its one exact target")
    check_equal(
        espdisp.ota_target_requires_exact_discovery(espdisp.BOARDS["s3-175"]), True,
        "S3 OTA requires exact discovered target metadata")

    # A C6 panel nobody can find is a warning, not a refusal: its chip maps to
    # one exact target and cross-subnet pushes remain possible.
    text = run(c6, "10.0.0.9", ports)
    check("Not found" in text, "an undiscovered panel is only a note")
    check("taken on trust" in text, "and says what that means")
    check(len(run(c6, "panel.local", [])) > 0, "discovery finding nothing is survivable")

    # A board it cannot place is also only a note.
    mystery = [espdisp.NetworkPort("10.0.0.5", "mystery.local", "esp32c3", "")]
    check("do not uniquely confirm" in run(c6, "10.0.0.5", mystery),
          "unplaceable metadata is a note")

    # A definite contradiction refuses, and names the target to use instead.
    check_fails(
        lambda: run(c6, "round-panel.local", ports),
        "advertises target=s3-175",
        "pushing a C6 image at the S3 panel")
    check_fails(
        lambda: run(c6, "round-panel.local", ports),
        "--board s3-175",
        "and the refusal names the exact target")
    check_fails(
        lambda: run(espdisp.BOARDS["s3-175"], "lcd-panel.local", ports),
        "advertises target=s3-185",
        "same-chip target mismatch is refused")
    legacy_s3 = [espdisp.NetworkPort(
        "192.168.1.45", "legacy.local", "esp32s3", "")]
    check_fails(
        lambda: run(espdisp.BOARDS["s3-175"], "legacy.local", legacy_s3),
        "matching exact target and chip metadata",
        "target-less S3 is refused rather than falsely confirmed")
    check_fails(
        lambda: run(espdisp.BOARDS["s3-185"], "10.0.0.9", ports),
        "was not found with exact target metadata",
        "an undiscovered S3 is refused rather than taken on trust")

    s3_085 = espdisp.BOARDS["s3-085"]
    gc9107_port = [espdisp.NetworkPort(
        "192.168.1.46", "gc9107-panel.local", "esp32s3", "s3-085")]
    check_equal(
        espdisp.classify_ota_target(s3_085, "s3-085", "esp32s3"),
        espdisp.TARGET_OK,
        "the exact GC9107 target and chip agree")
    check_equal(
        espdisp.classify_ota_target(s3_085, "s3-175", "esp32s3"),
        espdisp.TARGET_WRONG,
        "the GC9107 image refuses another exact same-chip target")
    check_equal(
        espdisp.classify_ota_target(s3_085, "", "esp32s3"),
        espdisp.TARGET_UNKNOWN,
        "the S3 chip alone cannot confirm the GC9107 target")
    check_equal(
        espdisp.ota_target_requires_exact_discovery(s3_085), True,
        "GC9107 OTA requires exact discovered target metadata")
    check("Confirmed" in run(s3_085, "gc9107-panel.local", gc9107_port),
          "matching GC9107 target metadata authorizes OTA")
    check_fails(
        lambda: run(espdisp.BOARDS["s3-175"],
                    "gc9107-panel.local", gc9107_port),
        "advertises target=s3-085",
        "another S3 image is refused for the GC9107 panel")

    disabled = espdisp.build_parser().parse_args([
        "ota", "lcd-panel.local", "--board", "s3-185",
        "--password", "12345678", "--discovery-timeout", "0",
    ])
    with unittest.mock.patch.object(espdisp, "espota_path", return_value="/tmp/espota.py"):
        check_fails(
            lambda: disabled.func(disabled),
            "--discovery-timeout cannot be disabled",
            "the CLI cannot bypass exact S3 target verification")


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
FAKE_C6 = b"\x00\x01\x02\xffc6 image ESPDISPFW3\nESPDISPFW2\nESPDISPFW1\n\x00 tail"
FAKE_S3 = bytes(range(256)) + b"\xffs3-175 image"
FAKE_S3_185 = bytes(reversed(range(256))) + b"\xffs3-185 image"


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
    """One pre-offset manifest entry for current or historical fixtures."""
    family_key = key if key in espdisp.FAMILIES else (
        "p4" if key.startswith("p4") else "s3")
    family = espdisp.FAMILIES[family_key]
    return {
        "board": key,
        "targets": [key],
        "chip": family.chip,
        "fqbn": family.fqbn,
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


SAMPLE_PAYLOADS = (("c6", FAKE_C6), ("s3-175", FAKE_S3))
GENERIC_RELEASE_NOTES = ["Added generic bundle fixture metadata."]


def sample_manifest(entries=None):
    if entries is None:
        entries = [image_entry("c6", FAKE_C6), image_entry("s3-175", FAKE_S3)]
    return espdisp.bundle_manifest(
        "1.2.0",
        192,
        entries,
        "2026-01-02T03:04:05Z",
        release_notes=GENERIC_RELEASE_NOTES,
        source_commit="a" * 40,
        source_dirty=False,
    )


def sample_flash_payloads(*keys):
    return {key: fake_flash_payloads(key) for key in keys}


def sample_bundle():
    manifest = sample_manifest()
    return manifest, espdisp.pack_bundle(
        manifest,
        {"c6": FAKE_C6, "s3-175": FAKE_S3},
        sample_flash_payloads("c6", "s3-175"),
    )


def two_s3_bundle():
    """A v3 fixture with two distinct images sharing the ESP32-S3 chip."""
    entries = [
        image_entry("s3-175", FAKE_S3),
        image_entry("s3-185", FAKE_S3_185),
    ]
    manifest = sample_manifest(entries)
    data = espdisp.pack_bundle(
        manifest,
        {"s3-175": FAKE_S3, "s3-185": FAKE_S3_185},
        sample_flash_payloads("s3-175", "s3-185"),
    )
    return manifest, data


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

    # The module's own spelling (app_state.cpp): external linkage, no static.
    check_equal(
        espdisp.fw_version_from_sketch(
            'String cfgName;\n'
            'const char *FW_VERSION = "1.2.0";\n'
            'uint8_t deviceId[6] = {0};\n'),
        "1.2.0",
        "the module's own spelling")
    # The pre-split spelling stays accepted: `static` is style, not meaning.
    check_equal(
        espdisp.fw_version_from_sketch(
            'static const char *FW_VERSION = "1.2.0";\n'),
        "1.2.0",
        "the historical static spelling")
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
        {"c6": PINNED_APP},
        {
            "c6": {
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
    check_equal(payloads, {"c6": PINNED_APP}, "so does the app payload")
    check_equal(
        flash_payloads,
        {
            "c6": {
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
    check_equal(payloads, {"c6": PINNED_APP}, "the app payload is reachable")
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


def test_legacy_target_mapping():
    """Legacy board fields map deterministically without changing legacy bytes."""
    expected = {
        "c6": "c6",
        "s3": "s3-175",
        "s3-175": "s3-175",
        "s3-185": "s3-185",
    }
    for board_name, target in expected.items():
        chip = "esp32c6" if board_name == "c6" else "esp32s3"
        entry = {
            "board": board_name,
            "chip": chip,
            "fqbn": "esp32:esp32:%s" % chip,
            "filename": "display_stream.ino.bin",
            "bytes": len(PINNED_APP),
            "sha256": PINNED_APP_SHA,
        }
        manifest = handmade_manifest([entry], format=1)
        data = handmade_bundle(
            espdisp.encode_manifest(manifest), PINNED_APP,
            magic=espdisp.BUNDLE_MAGIC_V1)
        _, payloads, flash_payloads = espdisp.unpack_bundle(data)
        check_equal(payloads, {target: PINNED_APP}, "%s maps to %s" % (board_name, target))
        check_equal(flash_payloads, {}, "legacy v1 remains app-only")

    legacy_s3 = image_entry("s3-175", FAKE_S3)
    legacy_s3["board"] = "s3"
    del legacy_s3["targets"]
    manifest = handmade_manifest([legacy_s3], format=2)
    data = handmade_bundle(
        espdisp.encode_manifest(manifest), payload_bytes(("s3-175", FAKE_S3)),
        magic=espdisp.BUNDLE_MAGIC_V2)
    _, payloads, flash_payloads = espdisp.unpack_bundle(data)
    check_equal(payloads, {"s3-175": FAKE_S3}, "v2 s3 never maps to s3-185")
    check_equal(
        flash_payloads, {"s3-175": fake_flash_payloads("s3-175")},
        "v2 flash parts use the mapped exact target")


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
        for family in espdisp.FAMILIES.values():
            expected = espdisp.PLATFORMS[family.platform].bootloader_address
            check_equal(
                espdisp.core_bootloader_address(family.chip), expected,
                "the installed core puts the %s bootloader at 0x%x"
                % (family.chip, expected))


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
            entries, payloads = espdisp.collect_flash_parts(
                espdisp.FAMILIES["s3"], export)

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
                lambda: espdisp.collect_flash_parts(
                    espdisp.FAMILIES["s3"], export),
                "is empty",
                "a zero-byte binary in the export")
        # A missing one names the file rather than the role, because the fix is to
        # look at the export directory.
        os.remove(os.path.join(export, "display_stream.ino.partitions.bin"))
        with unittest.mock.patch.object(espdisp, "core_boot_app0", lambda: boot_app0), \
                unittest.mock.patch.object(
                    espdisp, "core_bootloader_address", lambda chip: 0x0):
            check_fails(
                lambda: espdisp.collect_flash_parts(
                    espdisp.FAMILIES["s3"], export),
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
    check_equal(manifest["format"], 3, "format generation")
    check_equal(manifest["firmware_version"], "1.2.0", "version as given")
    check_equal(manifest["firmware_build"], 192, "build as given")
    check_equal(manifest["source_commit"], "a" * 40, "provenance is carried")
    check_equal(manifest["source_dirty"], False, "and so is cleanliness")
    check_equal(manifest["tool"], "espdisp.py bundle", "who wrote it")
    check_equal(
        sorted(manifest),
        sorted(espdisp.MANIFEST_KEYS + ("firmware_build", "release_notes")),
        "current writer adds build and release notes to required manifest keys")
    check_equal(manifest["release_notes"], GENERIC_RELEASE_NOTES,
                "current writer preserves ordered release notes")
    shipping = espdisp.bundle_manifest(
        "1.2.0", None, [image_entry("c6", FAKE_C6)],
        "2026-01-02T03:04:05Z",
        release_notes=GENERIC_RELEASE_NOTES,
        source_commit="a" * 40,
        source_dirty=False)
    check(
        "firmware_build" not in shipping,
        "shipping bundles omit dev build metadata")
    check_equal(
        sorted(shipping),
        sorted(espdisp.MANIFEST_KEYS + ("release_notes",)),
        "shipping writer adds no build key")
    for image in manifest["images"]:
        check_equal(
            sorted(image), sorted(espdisp.IMAGE_KEYS_V3), "no image key is missing")
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
            "1.2.0", 192, [image_entry("c6", blob)],
            "2026-01-02T03:04:05Z", release_notes=GENERIC_RELEASE_NOTES)
        encoded = espdisp.encode_manifest(one)
        image = one["images"][0]
        check_equal(
            image["offset"], espdisp.BUNDLE_HEADER_BYTES + len(encoded),
            "offsets settle for a %d-byte payload" % size)
        check_equal(
            image["flash_parts"][0]["offset"], image["offset"] + size,
            "and so does the first flash part's, for %d bytes" % size)
        # And the file it produces agrees, which is what the offsets are for.
        packed = espdisp.pack_bundle(one, {"c6": blob}, sample_flash_payloads("c6"))
        check_equal(
            packed[image["offset"]:], payload_bytes(("c6", blob)),
            "the payloads land at the stated offsets for %d bytes" % size)

    # The offsets are filled in on COPIES. A shared list would mean the caller's
    # entry came back carrying this call's answers, so a second bundle built from
    # the same entries would start from the first one's offsets and be wrong in a
    # way every hash still agreed with.
    entry = image_entry("c6", FAKE_C6)
    parts_before = [dict(part) for part in entry["flash_parts"]]
    espdisp.bundle_manifest(
        "1.2.0", 192, [entry], "2026-01-02T03:04:05Z",
        release_notes=GENERIC_RELEASE_NOTES)
    check_equal(entry["flash_parts"], parts_before, "the caller's parts are untouched")
    check("offset" not in entry, "and the caller's image gained no offset")

    check_fails(
        lambda: espdisp.bundle_manifest(
            "1.2.0", 192, [], "2026-01-02T03:04:05Z",
            release_notes=GENERIC_RELEASE_NOTES),
        "at least one image",
        "a manifest with no images is refused")
    # This tool writes generation 2 only, so an image with nothing for a blank
    # board is a caller bug and is refused where it is cheapest to fix.
    check_fails(
        lambda: espdisp.bundle_manifest(
            "1.2.0",
            192,
            [{k: v for k, v in image_entry("c6", FAKE_C6).items()
              if k != "flash_parts"}],
            "2026-01-02T03:04:05Z", release_notes=GENERIC_RELEASE_NOTES),
        "carries no flash_parts",
        "an image with no flash parts at all is refused by the writer")


    check_fails(
        lambda: espdisp.bundle_manifest(
            "1.2.0", 192, [dict(image_entry("c6", FAKE_C6), targets=[])],
            "2026-01-02T03:04:05Z", release_notes=GENERIC_RELEASE_NOTES),
        "non-empty targets list",
        "format 3 rejects an empty targets list")
    check_fails(
        lambda: espdisp.bundle_manifest(
            "1.2.0", 192, [dict(image_entry("c6", FAKE_C6), targets=["   "])],
            "2026-01-02T03:04:05Z", release_notes=GENERIC_RELEASE_NOTES),
        "no usable target",
        "format 3 rejects a blank target string")
    check_fails(
        lambda: espdisp.bundle_manifest(
            "1.2.0", 192,
            [dict(image_entry("c6", FAKE_C6), targets=["c6", "c6"])],
            "2026-01-02T03:04:05Z", release_notes=GENERIC_RELEASE_NOTES),
        "lists target c6 twice",
        "one image cannot repeat an exact target")


def test_bundle_round_trip():
    manifest, data = sample_bundle()
    got, payloads, flash_payloads = espdisp.unpack_bundle(data)

    check_equal(got, manifest, "the manifest round trips unchanged")
    check_equal(sorted(payloads), ["c6", "s3-175"], "keyed by exact target")
    check_equal(payloads["c6"], FAKE_C6, "the C6 image, byte for byte")
    check_equal(payloads["s3-175"], FAKE_S3, "the S3-1.75 image, byte for byte")
    check(b"ESPDISPFW3\n" in payloads["c6"], "v3 magic inside payload is not scanned")
    check(b"ESPDISPFW2\n" in payloads["c6"], "v2 magic inside payload is not scanned")
    check(b"ESPDISPFW1\n" in payloads["c6"], "v1 magic inside payload is not scanned")
    check_equal(
        espdisp.sha256_hex(payloads["c6"]), manifest["images"][0]["sha256"],
        "the hash in the manifest is the hash of the payload")

    check_equal(sorted(flash_payloads), ["c6", "s3-175"], "parts keyed by target")
    check_equal(flash_payloads["c6"], fake_flash_payloads("c6"), "the C6's parts")
    check_equal(
        flash_payloads["s3-175"], fake_flash_payloads("s3-175"),
        "the S3-1.75 parts")
    check(
        flash_payloads["c6"]["bootloader"]
        != flash_payloads["s3-175"]["bootloader"],
        "different targets keep distinct bootloaders")
    for image in got["images"]:
        for part in image["flash_parts"]:
            for target in image["targets"]:
                check_equal(
                    espdisp.sha256_hex(flash_payloads[target][part["role"]]),
                    part["sha256"],
                    "the manifest's %s %s hash is the payload's"
                    % (target, part["role"]))

    s3_manifest, s3_data = two_s3_bundle()
    got_s3, s3_payloads, s3_parts = espdisp.unpack_bundle(s3_data)
    check_equal(
        [image["chip"] for image in got_s3["images"]],
        ["esp32s3", "esp32s3"],
        "v3 permits duplicate chips")
    check_equal(
        sorted(s3_payloads), ["s3-175", "s3-185"],
        "two S3 images are selected by exact target")
    check_equal(s3_payloads["s3-175"], FAKE_S3, "S3-1.75 payload")
    check_equal(s3_payloads["s3-185"], FAKE_S3_185, "S3-1.85 payload")
    check_equal(s3_parts["s3-175"], fake_flash_payloads("s3-175"), "S3-1.75 parts")
    check_equal(s3_parts["s3-185"], fake_flash_payloads("s3-185"), "S3-1.85 parts")

    shared = image_entry("s3-175", FAKE_S3)
    shared["targets"] = ["s3-175", "s3-175-compatible"]
    shared_manifest = sample_manifest([shared])
    shared_data = espdisp.pack_bundle(
        shared_manifest,
        {"s3-175": FAKE_S3, "s3-175-compatible": FAKE_S3},
        {
            "s3-175": fake_flash_payloads("s3-175"),
            "s3-175-compatible": fake_flash_payloads("s3-175"),
        },
    )
    _, shared_payloads, shared_parts = espdisp.unpack_bundle(shared_data)
    check_equal(
        sorted(shared_payloads), ["s3-175", "s3-175-compatible"],
        "one image can claim multiple exact compatible profiles")
    check_equal(
        shared_payloads["s3-175-compatible"], FAKE_S3,
        "each compatible target resolves to the shared bytes")
    check_equal(
        shared_parts["s3-175-compatible"], fake_flash_payloads("s3-175"),
        "shared flash parts are also keyed by each exact target")

    one = espdisp.bundle_manifest(
        "1.2.0", 192, [image_entry("s3-175", FAKE_S3)],
        "2026-01-02T03:04:05Z", release_notes=GENERIC_RELEASE_NOTES)
    _, only, only_parts = espdisp.unpack_bundle(
        espdisp.pack_bundle(
            one, {"s3-175": FAKE_S3}, sample_flash_payloads("s3-175")))
    check_equal(only, {"s3-175": FAKE_S3}, "one image round trips too")
    check_equal(
        only_parts, {"s3-175": fake_flash_payloads("s3-175")},
        "and so do its parts")


def test_pack_bundle_refusals():
    """The writer's own checks: the last place a disagreement can still be fixed."""
    manifest = sample_manifest()
    both = sample_flash_payloads("c6", "s3-175")

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
            "1.2.0", 192, [entry], "2026-01-02T03:04:05Z",
            release_notes=GENERIC_RELEASE_NOTES)

    def one_image_with_parts(mutate):
        """A settled single-image manifest whose flash parts `mutate` rewrote."""
        return one_image(flash_parts=mutate(flash_entries("c6")))

    check_fails(
        lambda: espdisp.pack_bundle(manifest, {"c6": FAKE_C6}, both),
        "no payload was given",
        "a manifest listing an image nobody supplied")
    # The needle is the length message specifically, not the "the manifest says"
    # tail it shares with the hash refusal: a wrong length also hashes wrong, so a
    # looser needle would pass with the length check deleted.
    check_fails(
        lambda: espdisp.pack_bundle(
            manifest, {"c6": FAKE_C6, "s3-175": FAKE_S3 + b"!"}, both),
        "payload is %d bytes" % (len(FAKE_S3) + 1),
        "a payload whose length does not match the manifest")
    swapped = one_image()
    swapped["images"][0]["sha256"] = "0" * 64
    check_fails(
        lambda: espdisp.pack_bundle(
            swapped, {"c6": FAKE_C6}, sample_flash_payloads("c6")),
        "hashes to",
        "a payload whose hash does not match the manifest")
    moved = one_image()
    moved["images"][0]["offset"] += 1
    check_fails(
        lambda: espdisp.pack_bundle(
            moved, {"c6": FAKE_C6}, sample_flash_payloads("c6")),
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
        lambda: espdisp.pack_bundle(manifest, {"c6": FAKE_C6, "s3-175": FAKE_S3}),
        "no payload was given for target c6",
        "flash parts listed with no payloads supplied at all")
    short_of_one = {
        "c6": {
            role: blob for role, blob in fake_flash_payloads("c6").items()
            if role != espdisp.FLASH_ROLE_BOOT_APP0
        },
        "s3-175": fake_flash_payloads("s3-175"),
    }
    check_fails(
        lambda: espdisp.pack_bundle(
            manifest, {"c6": FAKE_C6, "s3-175": FAKE_S3}, short_of_one),
        "no payload was given for target c6",
        "one missing flash payload, named by role")
    stretched = dict(both, c6=dict(
        fake_flash_payloads("c6"),
        bootloader=fake_flash_payloads("c6")[espdisp.FLASH_ROLE_BOOTLOADER] + b"!"))
    check_fails(
        lambda: espdisp.pack_bundle(
            manifest, {"c6": FAKE_C6, "s3-175": FAKE_S3}, stretched),
        "c6 bootloader payload is",
        "a flash payload whose length does not match its entry")

    def zero_the_partition_hash(parts):
        parts[1]["sha256"] = "0" * 64
        return parts

    rehashed = one_image_with_parts(zero_the_partition_hash)
    check_fails(
        lambda: espdisp.pack_bundle(
            rehashed, {"c6": FAKE_C6}, sample_flash_payloads("c6")),
        "c6 partitions payload hashes to",
        "a flash payload whose hash does not match its entry")
    shifted = one_image()
    shifted["images"][0]["flash_parts"][0]["offset"] += 1
    check_fails(
        lambda: espdisp.pack_bundle(
            shifted, {"c6": FAKE_C6}, sample_flash_payloads("c6")),
        "do not describe this file",
        "a flash part offset that does not describe the file being written")

    # -- and the two checks that are only about generation 2's meaning: all three
    # roles present, and no two payloads claiming one flash address.
    for role in espdisp.REQUIRED_FLASH_ROLES:
        thinned = one_image_with_parts(
            lambda parts, role=role: [p for p in parts if p["role"] != role])
        check_fails(
            lambda thinned=thinned: espdisp.pack_bundle(
                thinned, {"c6": FAKE_C6}, sample_flash_payloads("c6")),
            "carries no %s" % role,
            "a manifest with no %s is refused by the writer" % role)

    def collide(parts):
        parts[1]["address"] = parts[0]["address"]
        return parts

    check_fails(
        lambda: espdisp.pack_bundle(
            one_image_with_parts(collide), {"c6": FAKE_C6},
            sample_flash_payloads("c6")),
        "writes both bootloader and partitions to flash address 0x0",
        "two parts at one flash address")

    def land_on_the_app(parts):
        parts[2]["address"] = 0x10000
        return parts

    check_fails(
        lambda: espdisp.pack_bundle(
            one_image_with_parts(land_on_the_app), {"c6": FAKE_C6},
            sample_flash_payloads("c6")),
        "writes both the app and boot_app0 to flash address 0x10000",
        "a part landing on top of the application image")


    shared = image_entry("s3-175", FAKE_S3)
    shared["targets"] = ["s3-175", "s3-compatible"]
    shared_manifest = sample_manifest([shared])
    shared_parts = fake_flash_payloads("s3-175")
    check_fails(
        lambda: espdisp.pack_bundle(
            shared_manifest,
            {"s3-175": FAKE_S3},
            {"s3-175": shared_parts}),
        "no payload was given for target s3-compatible",
        "every claimed target must key the shared application payload")
    check_fails(
        lambda: espdisp.pack_bundle(
            shared_manifest,
            {"s3-175": FAKE_S3, "s3-compatible": b"x" * len(FAKE_S3)},
            {"s3-175": shared_parts, "s3-compatible": shared_parts}),
        "different application payloads",
        "one image cannot receive different bytes for compatible targets")


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
        "does not start with an ESPDISPFW magic",
        "bad magic")
    check_fails(
        lambda: espdisp.unpack_bundle(b"\x00" * 64), "magic", "a file of zeros")
    # Generation 4 is not supported; the refusal names all three readable ones.
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, magic=b"ESPDISPFW4\n")),
        "unsupported bundle generation",
        "a newer format generation")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(raw, magic=b"ESPDISPFW4\n")),
        "'ESPDISPFW1', 'ESPDISPFW2', 'ESPDISPFW3'",
        "and it names every generation this tool reads")
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
            handmade_bundle(espdisp.encode_manifest(dict(manifest, format=4)), area)),
        "this tool reads formats 1 and 2 and 3",
        "an unknown format generation in the manifest")
    # THE MAGIC AND THE MANIFEST'S OWN `format` HAVE TO AGREE, both ways round.
    # Two statements of one fact, so a file where they differ is self-
    # contradictory whichever is right, and believing either would mean reading
    # one generation's body as the other's.
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(espdisp.encode_manifest(dict(manifest, format=1)), area)),
        "ESPDISPFW3 magic means format 3",
        "a format 1 manifest behind generation 3's magic")
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(raw, area, magic=espdisp.BUNDLE_MAGIC_V1)),
        "ESPDISPFW1 magic means format 1",
        "a format 3 manifest behind generation 1's magic")
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
    for key in espdisp.IMAGE_KEYS_V3:
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
        sorted(espdisp.IMAGE_KEYS_V3),
        ["app_address", "board", "bytes", "chip", "filename", "flash_parts", "fqbn",
         "offset", "sha256", "targets"],
        "the generation-3 image key set requires exact targets")
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
        "1.2.0", 192,
        [dict(image_entry("c6", FAKE_C6), bytes=len(FAKE_C6) + 64)],
        "2026-01-02T03:04:05Z", release_notes=GENERIC_RELEASE_NOTES)
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

    # A v3 target can be claimed once, even though two different targets may
    # share a chip. Duplicate exact-target claims are rejected.
    duplicate_target_entries = [
        image_entry("s3-175", FAKE_S3),
        image_entry("s3-175", FAKE_S3),
    ]
    check_fails(
        lambda: espdisp.bundle_manifest(
            "1.2.0", 192, duplicate_target_entries,
            "2026-01-02T03:04:05Z", release_notes=GENERIC_RELEASE_NOTES),
        "target s3-175 is claimed",
        "the same exact target claimed twice")

    # Legacy readers still reject duplicate chips, even when their board names
    # map to different modern targets.
    legacy_entries = []
    for key, blob in (("s3-175", FAKE_S3), ("s3-185", FAKE_S3_185)):
        entry = image_entry(key, blob)
        del entry["targets"]
        legacy_entries.append(entry)
    legacy_twice = handmade_manifest(legacy_entries, format=2)
    check_fails(
        lambda: espdisp.unpack_bundle(
            handmade_bundle(
                espdisp.encode_manifest(legacy_twice),
                payload_bytes(("s3-175", FAKE_S3), ("s3-185", FAKE_S3_185)),
                magic=espdisp.BUNDLE_MAGIC_V2)),
        "legacy bundle lists esp32s3 twice",
        "format 2 still rejects duplicate chips")

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
        built = handmade_manifest(
            [first, image_entry("s3-175", FAKE_S3)], edit=edit)
        c6_parts = fake_flash_payloads("c6")
        claimed = FAKE_C6
        for part in parts if isinstance(parts, list) else []:
            if isinstance(part, dict) and part.get("role") in c6_parts:
                claimed += c6_parts[part["role"]]
        return handmade_bundle(
            espdisp.encode_manifest(built),
            claimed + payload_bytes(("s3-175", FAKE_S3)))

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
        check_equal(payloads["s3-175"], FAKE_S3, "payload survives the filesystem")
        check_equal(
            flash_payloads["s3-175"], fake_flash_payloads("s3-175"),
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
        calls[1],
        ["git", "-C", "/repo", "status", "--porcelain", "--untracked-files=all"],
        "status command")

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
    with unittest.mock.patch.object(
        espdisp, "run_capture",
        stub(head, done(0, "?? firmware-dev/manifest.json\n"))
    ):
        check_equal(
            espdisp.git_provenance("/repo")[1], False,
            "generated development firmware does not dirty provenance")

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


def test_git_firmware_build():
    calls = []

    def done(code, out=""):
        return subprocess.CompletedProcess([], code, out, "")

    def stub(*results):
        queue = list(results)

        def run(cmd, timeout=None):
            calls.append(cmd)
            return queue.pop(0)

        return run

    with unittest.mock.patch.dict(os.environ, {}, clear=False), \
            unittest.mock.patch.object(
                espdisp, "run_capture",
                stub(done(0, "false\n"), done(0, "192\n"),
                     done(0, "origin/main\n"), done(0))):
        check_equal(
            espdisp.git_firmware_build("/repo"),
            espdisp.FirmwareBuild(192, ""),
            "release build uses commit count without a suffix")
    check_equal(
        calls[:4],
        [
            ["git", "-C", "/repo", "rev-parse", "--is-shallow-repository"],
            ["git", "-C", "/repo", "rev-list", "--count", "HEAD"],
            ["git", "-C", "/repo", "symbolic-ref", "--quiet", "--short",
             "refs/remotes/origin/HEAD"],
            ["git", "-C", "/repo", "merge-base", "--is-ancestor",
             "HEAD", "origin/main"],
        ],
        "build derivation commands")

    calls.clear()
    with unittest.mock.patch.dict(
            os.environ,
            {espdisp.FIRMWARE_RELEASE_REF_ENV: "refs/remotes/upstream/release"},
            clear=False), \
            unittest.mock.patch.object(
                espdisp, "run_capture",
                stub(done(0, "false\n"), done(0, "194\n"),
                     done(0, "feedface\n"), done(1), done(0, "346728d\n"))
            ):
        branch = espdisp.git_firmware_build("/repo")
    check_equal(branch, espdisp.FirmwareBuild(194, ".g346728d"),
                "branch build appends its short SHA")
    check_equal(
        espdisp.firmware_identity("1.5.0", branch.number, branch.branch_suffix),
        "1.5.0+194.g346728d", "rendered branch identity")

    for env, results, needle, label in [
        ({}, (done(0, "true\n"),), "shallow git checkout",
         "shallow clone is refused"),
        ({}, (done(2),), "whether the git checkout is shallow",
         "unknown shallow state"),
        ({}, (done(0, "false\n"), done(1)), "git rev-list",
         "missing build count"),
        ({}, (done(0, "false\n"), done(0, "0\n")), "uint32 range",
         "zero build count"),
        ({}, (done(0, "false\n"),
              done(0, str(espdisp.FIRMWARE_BUILD_MAX + 1))), "uint32 range",
         "oversized build count"),
        ({}, (done(0, "false\n"), done(0, "192\n"), done(1)),
         "release branch", "missing origin HEAD"),
        ({espdisp.FIRMWARE_RELEASE_REF_ENV: "refs/remotes/upstream/release"},
         (done(0, "false\n"), done(0, "192\n"), done(1)),
         "does not resolve", "invalid configured release ref"),
        ({}, (done(0, "false\n"), done(0, "192\n"), done(0, "origin/main\n"),
              done(2)), "origin/main", "unknown release relationship"),
        ({}, (done(0, "false\n"), done(0, "194\n"), done(0, "origin/main\n"),
              done(1), done(0, "not-sha\n")),
         "short git SHA", "invalid branch SHA"),
    ]:
        with unittest.mock.patch.dict(os.environ, env, clear=False), \
                unittest.mock.patch.object(espdisp, "run_capture", stub(*results)):
            check_fails(
                lambda: espdisp.git_firmware_build("/repo"),
                needle, label)

    try:
        real = espdisp.git_firmware_build()
    except espdisp.Fail as exc:
        message = str(exc)
        allowed = (
            "shallow git checkout" in message or
            "firmware release branch" in message
        )
        check(
            allowed,
            "real repo only skips for shallow history or an unknown release ref: %r"
            % message)
        if allowed:
            print("note: skipping the real firmware-build check: %s"
                  % message.splitlines()[0])
    else:
        check(1 <= real.number <= espdisp.FIRMWARE_BUILD_MAX,
              "the real repository yields a uint32 build")


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

    # The round-glass mask. These counts drive the hardware verification
    # pattern AND are the same numbers the Swift side computes independently
    # (TileMask); the classification was confirmed against real glass with
    # `tile-test --round-mask` - no magenta visible, boundary ring at the
    # bezel - before any sender relied on it.
    classes = espdisp.tile_visibility()
    check_equal(len(classes["outside"]), 181, "181 tiles are never visible")
    check_equal(len(classes["boundary"]), 106, "106 tiles straddle the circle")
    check_equal(len(classes["inside"]), 613, "613 tiles are fully visible")
    check_equal(sum(len(v) for v in classes.values()), 900,
                "every tile is classified exactly once")
    check_equal(len(classes["boundary"]) + len(classes["inside"]), 719,
                "719 tiles must still be sent")
    outside = set(classes["outside"])
    # The corners are hidden; the centre is not.
    for corner in (0, 29, 870, 899):
        check(corner in outside, "corner tile %d is hidden" % corner)
    for middle in (14 * 30 + 14, 15 * 30 + 15):
        check(middle not in outside, "centre tile %d is visible" % middle)
    # Every row's visible tiles form ONE contiguous span - a circle's
    # intersection with a row is convex - which is why masking never costs
    # an extra draw call on the panel.
    for row in range(30):
        vis = [c for c in range(30) if row * 30 + c not in outside]
        check(vis == list(range(vis[0], vis[-1] + 1)),
              "row %d visible tiles are contiguous" % row)
    check_equal([c for c in range(30) if 0 * 30 + c not in outside],
                list(range(9, 20)), "row 0 spans columns 9..19")
    check_equal([c for c in range(30) if 29 * 30 + c not in outside],
                list(range(12, 17)), "row 29 spans columns 12..16")
    # The verification pattern itself: every tile painted, nothing masked,
    # so a wrong mask shows up as visible magenta rather than as silence.
    mask_packets = espdisp.round_mask_packets(1)
    check(len(mask_packets) > 0, "round-mask pattern produces datagrams")
    painted = 0
    for p in mask_packets:
        check(len(p) <= espdisp.TILE_PACKET_BUDGET, "mask datagram in budget")
        _, first_field, dirty = struct.unpack("<HHH", p[:6])
        check(first_field & 0x8000 != 0, "mask packet sets the stream flag")
        check_equal(dirty, 900, "the pattern declares all 900 tiles dirty")
        at = 6
        while at < len(p):
            _, len_field = struct.unpack("<HH", p[at:at + 4])
            at += 4 + (len_field & 0x3FFF)
            painted += 1
        check_equal(at, len(p), "mask records tile the packet exactly")
    check_equal(painted, 900, "the pattern paints every tile")

    # The full-frame motion benchmark (tile-motion). Its whole purpose is to
    # cost exactly what a real majority-of-screen BC1 update costs, so the
    # per-tile size and the frame's datagram count are what matter.
    block, seed = espdisp.bc1_noise_tile(1, 16, 16)
    check_equal(len(block), 128, "a 16x16 BC1 tile is 16 blocks x 8 B")
    check(seed != 1, "the generator advances its seed")
    for i in range(0, len(block), 8):
        c0, c1 = struct.unpack("<HH", block[i:i + 4])
        check(c0 >= c1, "BC1 4-colour mode needs c0 >= c1")
    check_equal(len(espdisp.bc1_noise_tile(1, 2, 2)[0]), 8,
                "the 2x2 corner tile is one block")
    check_equal(len(espdisp.bc1_noise_tile(1, 2, 16)[0]), 32,
                "a 2x16 edge tile is 4 blocks")
    motion, _ = espdisp.motion_frame_packets(1, 0xC0FFEE)
    check_equal(len(motion), 65, "a full-frame BC1 update is 65 datagrams")
    total = sum(len(p) for p in motion)
    check(90000 < total < 96000,
          "a full BC1 frame is ~92 KB, got %d" % total)
    covered = []
    for p in motion:
        check(len(p) <= espdisp.TILE_PACKET_BUDGET, "motion datagram in budget")
        _, first_field, dirty = struct.unpack("<HHH", p[:6])
        check(first_field & 0x8000 != 0, "motion packet sets the stream flag")
        check_equal(dirty, 719,
                    "motion frames declare only the VISIBLE tiles")
        at = 6
        while at < len(p):
            tile_field, len_field = struct.unpack("<HH", p[at:at + 4])
            check_equal(len_field >> 14, espdisp.TILE_CODEC_BC1,
                        "motion records are BC1")
            # Records are merged runs now (matching TilePacker), so coverage
            # expands each record to the tiles it carries.
            start = tile_field & 0x03FF
            covered.extend(range(start, start + ((tile_field >> 10) & 0x1F) + 1))
            at += 4 + (len_field & 0x3FFF)
        check_equal(at, len(p), "motion records tile the packet exactly")
    hidden = set(espdisp.tile_visibility()["outside"])
    check_equal(len(covered), 719, "every visible tile is sent once")
    check_equal(len(set(covered)), 719, "no tile is sent twice")
    check(not (set(covered) & hidden),
          "the motion benchmark never sends a hidden tile")

    # Half-resolution BC1 (codec 3). The rounding rule first: it must round UP
    # on every axis, or pixel-doubling would leave the last row/column of an
    # odd run unwritten - and a 2 px edge tile would halve to nothing.
    check_equal(espdisp.half_dim(16), 8, "a full tile halves to 8 px")
    check_equal(espdisp.half_dim(2), 1, "a 2 px edge tile halves to 1 px")
    check_equal(espdisp.half_dim(1), 1, "half of 1 px is still a pixel")
    check_equal(espdisp.half_dim(3), 2, "odd dimensions round up")
    check_equal(espdisp.half_dim(466), 233, "the full panel halves evenly")
    check_equal(espdisp.TILE_CODEC_HALF_BC1, 3, "half-res is codec 3")

    half, _ = espdisp.bc1_noise_tile(1, espdisp.half_dim(16),
                                    espdisp.half_dim(16))
    check_equal(len(half), 32, "a half-res 16x16 tile is 4 blocks x 8 B")
    check_equal(len(espdisp.bc1_noise_tile(1, espdisp.half_dim(2),
                                          espdisp.half_dim(16))[0]), 16,
                "a half-res edge tile is 2 blocks")

    # The whole point, on the wire: the same 719 tiles, a quarter of the bytes,
    # and the datagram count that lifts the majority-of-motion ceiling.
    hmotion, _ = espdisp.motion_frame_packets(1, 0xC0FFEE, half=True)
    check_equal(len(hmotion), 16,
                "a half-res full frame is 16 datagrams, against BC1's 65")
    htotal = sum(len(p) for p in hmotion)
    check(22500 < htotal < 24000,
          "a half-res full frame is ~23.1 KB, got %d" % htotal)
    # 3.97x, not 4x: payloads quarter exactly, but full-res splits into more
    # records (92 against 44 - a run's BC1 bytes outgrow the datagram sooner)
    # and more packets, so it pays more header overhead per pixel. Worth
    # pinning because section 16's datagram arithmetic is built on these
    # figures, and a clean 4x estimate would predict the wrong packet counts.
    check_equal(round(total / htotal, 2), 3.97,
                "half-res is 3.97x smaller than BC1, header included")
    hcovered = []
    for p in hmotion:
        check(len(p) <= espdisp.TILE_PACKET_BUDGET,
              "half-res datagram in budget")
        _, first_field, dirty = struct.unpack("<HHH", p[:6])
        check(first_field & 0x8000 != 0, "half-res sets the stream flag")
        check_equal(dirty, 719, "half-res frames still declare 719 tiles")
        at = 6
        while at < len(p):
            tile_field, len_field = struct.unpack("<HH", p[at:at + 4])
            check_equal(len_field >> 14, espdisp.TILE_CODEC_HALF_BC1,
                        "half-res records carry codec 3")
            start = tile_field & 0x03FF
            hcovered.extend(
                range(start, start + ((tile_field >> 10) & 0x1F) + 1))
            at += 4 + (len_field & 0x3FFF)
        check_equal(at, len(p), "half-res records tile the packet exactly")
    check_equal(sorted(hcovered), sorted(covered),
                "half-res covers exactly the tiles full-res does")


def test_audio_wire_and_descriptor():
    """Pin the host reference to firmware/test/test_audio.cpp's exact bytes."""
    pcm_fixture = bytes.fromhex(
        "45 41 55 44 01 01 01 02 07 00 03 00 80 3e 00 00 "
        "40 01 00 00 40 e2 01 00 04 00 10 00 "
        "00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f")
    status_fixture = bytes.fromhex(
        "45 41 55 44 01 03 00 00 08 00 09 00 80 bb 00 00 "
        "00 00 00 00 0a 00 00 00 00 00 30 00 "
        "64 00 00 00 78 00 00 00 50 00 00 00 02 00 00 00 "
        "fa 00 00 00 03 00 00 00 04 00 00 00 05 00 00 00 "
        "06 00 00 00 07 00 00 00 08 00 00 00 09 00 00 00")

    check_equal(
        espdisp.audio_pcm_datagram(
            kind=espdisp.AUDIO_KIND_DOWNLINK,
            sequence=7,
            stream_generation=3,
            sample_rate=16000,
            sample_counter=320,
            timestamp_micros=123456,
            channels=2,
            pcm=bytes(range(16))),
        pcm_fixture,
        "audio encoder reproduces firmware PCM vector byte for byte",
    )
    pcm = espdisp.parse_audio_datagram(pcm_fixture)
    check_equal(pcm.kind, espdisp.AUDIO_KIND_DOWNLINK, "PCM fixture kind")
    check_equal(pcm.sequence, 7, "PCM fixture sequence")
    check_equal(pcm.stream_generation, 3, "PCM fixture stream generation")
    check_equal(pcm.sample_rate, 16000, "PCM fixture sample rate")
    check_equal(pcm.sample_counter, 320, "PCM fixture sample counter")
    check_equal(pcm.timestamp_micros, 123456, "PCM fixture timestamp")
    check_equal(pcm.frame_count, 4, "PCM fixture frame count")
    check_equal(pcm.channels, 2, "PCM fixture channels")
    check_equal(pcm.payload, bytes(range(16)), "PCM fixture payload")

    status = espdisp.parse_audio_datagram(status_fixture)
    check_equal(status.kind, espdisp.AUDIO_KIND_STATUS, "status fixture kind")
    check_equal(status.sequence, 8, "status fixture sequence")
    check_equal(status.stream_generation, 9, "status stream generation")
    check_equal(status.sample_rate, 48000, "status fixture sample rate")
    check_equal(status.timestamp_micros, 10, "status fixture timestamp")
    check_equal(
        status.status,
        espdisp.AudioStatus(
            fill_frames=100,
            target_frames=120,
            minimum_fill_frames=80,
            underruns=2,
            underrun_duration_ms=250,
            late_packets=3,
            lost_frames=4,
            hard_corrections=5,
            ingress_drops=6,
            queue_drops=7,
            engine_drops=8,
            capture_overruns=9,
        ),
        "status fixture exposes all twelve firmware fields",
    )
    check_equal(
        espdisp.format_audio_status(status.status),
        "fill=100 target=120 minimum=80 underruns=2 underrun_ms=250 "
        "late=3 lost_frames=4 corrections=5 ingress_drops=6 queue_drops=7 "
        "engine_drops=8 capture_overruns=9",
        "status output names every bring-up counter",
    )

    for mutation, needle in [
        (b"XAUD" + pcm_fixture[4:], "magic"),
        (pcm_fixture[:4] + b"\x02" + pcm_fixture[5:], "version"),
        (pcm_fixture[:5] + b"\x63" + pcm_fixture[6:], "kind"),
        (pcm_fixture[:6] + b"\x00" + pcm_fixture[7:], "flags"),
        (pcm_fixture[:-1], "length"),
    ]:
        check_fails(
            lambda mutation=mutation: espdisp.parse_audio_datagram(mutation),
            needle,
            "audio parser refuses malformed %s fixture" % needle,
        )

    descriptor = espdisp.audio_descriptor_from_txt({
        "caps": "00300000",
        "audio-port": "5569",
        "audio-version": "1",
        "audio-rate": "16000",
        "audio-play-ch": "2",
        "audio-capture-ch": "2",
    })
    check_equal(
        descriptor,
        espdisp.AudioDescriptor(
            port=5569, version=1, sample_rate=16000,
            playback_channels=2, capture_channels=2),
        "audio TXT descriptor carries rate and both channel counts",
    )
    check_equal(
        espdisp.audio_packet_frames(descriptor, 20.0),
        320,
        "packet duration is converted through advertised rate",
    )
    check_fails(
        lambda: espdisp.audio_packet_frames(descriptor, 50.0),
        "1400",
        "packet sizing refuses payloads above firmware MTU",
    )
    for records, needle in [
        ({
            "caps": "00100000", "audio-port": "5569", "audio-version": "1",
            "audio-rate": "16000", "audio-play-ch": "2",
            "audio-capture-ch": "2",
        }, "uplink"),
        ({
            "caps": "00300000", "audio-port": "5569", "audio-version": "2",
            "audio-rate": "16000", "audio-play-ch": "2",
            "audio-capture-ch": "2",
        }, "version"),
        ({
            "caps": "00300000", "audio-port": "5569", "audio-version": "1",
            "audio-rate": "0", "audio-play-ch": "2", "audio-capture-ch": "2",
        }, "rate"),
        ({
            "caps": "00300000", "audio-port": "5569", "audio-version": "1",
            "audio-rate": "16000", "audio-play-ch": "1",
        }, "audio-capture-ch"),
    ]:
        check_fails(
            lambda records=records: espdisp.audio_descriptor_from_txt(records),
            needle,
            "audio TXT descriptor refuses %s mismatch" % needle,
        )

    query = espdisp.mdns_query("_espdisp._udp.local", espdisp.DNS_TYPE_PTR)
    check_equal(query[:2], b"\x00\x00", "mDNS query uses transaction id zero")
    check_equal(
        query[-4:],
        struct.pack("!HH", espdisp.DNS_TYPE_PTR, 0x8001),
        "mDNS query requests an RFC 6762 unicast response",
    )
    txt_rdata = (
        b"\x0dcaps=00300000"
        b"\x0faudio-port=5569"
        b"\x0faudio-version=1"
        b"\x10audio-rate=16000"
        b"\x0faudio-play-ch=2"
        b"\x12audio-capture-ch=2")
    check_equal(
        espdisp.parse_dns_txt(txt_rdata),
        {
            "caps": "00300000",
            "audio-port": "5569",
            "audio-version": "1",
            "audio-rate": "16000",
            "audio-play-ch": "2",
            "audio-capture-ch": "2",
        },
        "DNS TXT parser preserves the firmware's audio keys",
    )
    check_equal(
        espdisp.audio_endpoint_host(
            "panel.local", {"fe80::1234", "192.168.1.42"}),
        "192.168.1.42",
        "audio discovery uses the parsed IPv4 address without a second DNS lookup",
    )
    check_equal(
        espdisp.audio_endpoint_host("panel.local", {"fe80::1234"}),
        "panel.local",
        "scope-less link-local IPv6 falls back to the resolvable service target",
    )

    with tempfile.TemporaryDirectory() as directory:
        good_path = os.path.join(directory, "good.wav")
        bad_path = os.path.join(directory, "bad.wav")
        with wave.open(good_path, "wb") as wav:
            wav.setnchannels(2)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(b"\x00" * 64)
        with wave.open(bad_path, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(b"\x00" * 32)
        with wave.open(good_path, "rb") as wav:
            check_accepts(
                lambda: espdisp.validate_audio_wav(wav, descriptor),
                "WAV matching advertised playback format is accepted",
            )
        with wave.open(bad_path, "rb") as wav:
            check_fails(
                lambda: espdisp.validate_audio_wav(wav, descriptor),
                "channels",
                "WAV channel mismatch is refused instead of remixed",
            )

    tone = espdisp.audio_tone_pcm(
        sample_rate=48000, channels=2, start_frame=0, frame_count=8,
        frequency=1000.0, amplitude=0.25)
    samples = struct.unpack("<16h", tone)
    check(
        all(samples[index] == samples[index + 1] for index in range(0, 16, 2)),
        "generated tone duplicates each frame across advertised channels",
    )

    args = espdisp.build_parser().parse_args(["audio", "panel.local", "--tone", "440"])
    check_equal(args.command, "audio", "audio command is wired into CLI")
    check_equal(args.packet_ms, 20.0, "audio packet duration has a tunable default")
    check_equal(args.status_interval, 1.0, "status print interval has a tunable default")
    check_equal(
        espdisp.audio_frame_limit(0.000001, 16000),
        1,
        "a positive sub-frame run still sends one descriptor-rate frame",
    )
    for seconds in (0.0, float("nan"), float("inf")):
        check_fails(
            lambda seconds=seconds: espdisp.audio_frame_limit(seconds, 16000),
            "seconds",
            "audio run duration %r is refused" % seconds,
        )
    for drain in (-0.1, float("nan"), float("inf")):
        check_fails(
            lambda drain=drain: espdisp.validate_audio_drain_seconds(drain),
            "drain",
            "audio drain duration %r is refused" % drain,
        )

    check_fails(
        lambda: espdisp.require_audio_response(0, send_only=False),
        "no valid audio response",
        "a silent panel cannot be reported as a successful audio stream",
    )
    check_accepts(
        lambda: espdisp.require_audio_response(1, send_only=False),
        "one valid status or uplink packet proves panel admission",
    )
    check_accepts(
        lambda: espdisp.require_audio_response(0, send_only=True),
        "the explicit send-only override permits an unacknowledged endpoint",
    )

    def uplink(sequence, generation, counter, values):
        payload = struct.pack("<%dh" % len(values), *values)
        return espdisp.parse_audio_datagram(espdisp.audio_pcm_datagram(
            kind=espdisp.AUDIO_KIND_UPLINK,
            sequence=sequence,
            stream_generation=generation,
            sample_rate=16000,
            sample_counter=counter,
            timestamp_micros=counter * 62,
            channels=1,
            pcm=payload,
        ))

    reorder = espdisp.AudioUplinkReorderBuffer(channels=1, window_packets=2)
    check_equal(
        reorder.push(uplink(10, 7, 100, [10, 11])),
        struct.pack("<2h", 10, 11),
        "the first uplink packet starts the captured timeline",
    )
    check_equal(
        reorder.push(uplink(12, 7, 104, [30, 31])),
        b"",
        "a future uplink packet is held inside the reorder window",
    )
    check_equal(
        reorder.push(uplink(11, 7, 102, [20, 21])),
        struct.pack("<4h", 20, 21, 30, 31),
        "reordered uplink packets are emitted in sample-counter order",
    )
    check_equal(reorder.reordered_packets, 1, "uplink reordering is reported")
    check_equal(
        reorder.push(uplink(11, 7, 102, [20, 21])),
        b"",
        "duplicate uplink packets are not appended twice",
    )
    check_equal(reorder.duplicate_packets, 1, "uplink duplicates are reported")

    gap = espdisp.AudioUplinkReorderBuffer(channels=1, window_packets=1)
    check_equal(
        gap.push(uplink(20, 3, 0, [1, 2])),
        struct.pack("<2h", 1, 2),
        "gap fixture starts with its first packet",
    )
    check_equal(
        gap.push(uplink(22, 3, 4, [5, 6])),
        b"",
        "one missing packet is held until the bounded window expires",
    )
    check_equal(
        gap.push(uplink(23, 3, 6, [7, 8])),
        b"\x00" * 4 + struct.pack("<4h", 5, 6, 7, 8),
        "expired uplink gaps become exact-duration PCM silence",
    )
    check_equal(gap.lost_frames, 2, "uplink lost frames are reported")
    bounded_gap = espdisp.AudioUplinkReorderBuffer(
        channels=1, window_packets=1)
    check_equal(
        bounded_gap.maximum_gap_frames,
        espdisp.AUDIO_MAX_PAYLOAD_BYTES,
        "uplink silence bound follows reorder depth and packet payload limit",
    )
    check_equal(
        bounded_gap.push(uplink(30, 5, 0, [1, 2])),
        struct.pack("<2h", 1, 2),
        "bounded-gap fixture starts with its first packet",
    )
    check_equal(
        bounded_gap.push(uplink(
            31, 5, bounded_gap.maximum_gap_frames + 3, [3, 4])),
        struct.pack("<2h", 3, 4),
        "an implausibly large forward gap resets without allocating silence",
    )
    check_equal(
        bounded_gap.lost_frames,
        0,
        "a rejected forward gap is not reported as synthesized loss",
    )
    check_equal(
        bounded_gap.discontinuities,
        1,
        "a rejected forward gap is reported as one discontinuity",
    )
    check_equal(
        gap.push(uplink(1, 4, 0, [9, 10])),
        struct.pack("<2h", 9, 10),
        "a new stream generation resets sequence and sample-counter state",
    )
    check_equal(gap.generation_changes, 1, "uplink generation changes are reported")

    check(espdisp.mdns_query_due(None, 1.0, 0.5),
          "an unsent mDNS question is due immediately")
    check(not espdisp.mdns_query_due(1.0, 1.49, 0.5),
          "mDNS follow-up waits for its retry cadence")
    check(espdisp.mdns_query_due(1.0, 1.5, 0.5),
          "an unanswered mDNS follow-up is retransmitted")

    invalid_args = espdisp.build_parser().parse_args(
        ["audio", "panel.local", "--tone", "440", "--seconds", "0"])
    check_fails(
        lambda: espdisp.validate_audio_local_args(invalid_args),
        "--seconds",
        "panel-independent duration validation precedes discovery",
    )
    check_equal(
        args.send_only,
        False,
        "panel acknowledgement is required unless --send-only is explicit",
    )
    check_equal(
        args.uplink_reorder_packets,
        4,
        "uplink reorder depth has a runtime default",
    )


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
    check("c6" in text and "s3-175" in text, "and every exact target")
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
        espdisp.FAMILIES["c6"].fqbn in full, "and the FQBN each image was built with")

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
         if key not in ("app_address", "flash_parts", "targets")}
        for image in v1["images"]
    ]
    older = "\n".join(espdisp.describe_bundle(v1))
    check("app only" in older, "an older bundle says it carries the app only")
    check("never been flashed" in older, "and what that means it cannot do")
    check("format 1" in older, "naming the generation it is")
    for role in espdisp.REQUIRED_FLASH_ROLES:
        check(role not in older, "and it claims no %s" % role)


def test_release_notes_source_and_manifest_contract():
    """The bundle's authoring and external-metadata contracts agree exactly."""
    def source_failure(raw, version, expected, label):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "release-notes.md")
            with open(path, "wb") as source:
                source.write(raw)
            try:
                espdisp.release_notes_for_version(path, version)
            except espdisp.Fail as exc:
                check_equal(str(exc), expected % path, label)
            else:
                check(False, "%s: did not refuse" % label)

    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "release-notes.md")
        document = (
            b"# Release Notes\n\n## 2.0.0\n\n- Fixed a newer issue.\n\n"
            b"## 1.4.2\n\n- Added generic selected metadata.\n"
        )
        with open(path, "wb") as source:
            source.write(document)
        check_equal(
            espdisp.release_notes_for_version(path, "1.4.2"),
            ["Added generic selected metadata."],
            "release source selects exact current SemVer heading")
    source_failure(
        b"# Notes\n", "1.4.2",
        "release notes %s:1: section none: expected exact title '# Release Notes'",
        "source title diagnostic")
    source_failure(
        b"# Release Notes\n\n## 1.4.2\n\n- Added missing punctuation\n", "1.4.2",
        "release notes %s:5: section 1.4.2: item text must end with '.', '!', or '?'",
        "source item diagnostic")
    source_failure(
        b"# Release Notes\n\n## 1.4.2\r\n", "1.4.2",
        "release notes %s:3: section 1.4.2: carriage return byte is not allowed",
        "CR wins before decoding or grammar")
    source_failure(
        b"# Release Notes\n\xff", "1.4.2",
        "release notes %s: byte 16: line 2: not valid UTF-8",
        "UTF-8 diagnostic includes byte and LF line")
    check_fails(
        lambda: espdisp.release_notes_for_version("not opened", "bad\nversion"),
        "requested FW_VERSION 'bad\\u000Aversion' is not SemVer 2.0.0",
        "requested version is checked before source I/O")
    check_equal(espdisp.compare_semver("1.0.0-alpha.1", "1.0.0-alpha.beta"), -1,
                "SemVer prerelease numeric identifiers sort before text")
    check_equal(espdisp.compare_semver("1.0.0+one", "1.0.0+two"), 0,
                "SemVer build metadata does not affect precedence")
    check_equal(espdisp.parse_semver("1.0.0-01"), None,
                "SemVer numeric prerelease identifiers cannot have leading zeros")

    check_fails(
        lambda: espdisp.bundle_manifest(
            "1.2.0", 192, [image_entry("c6", FAKE_C6)],
            "2026-01-02T03:04:05Z",
            release_notes=[]),
        "release_notes: must be a list containing 1–32 items",
        "writer requires nonempty release notes")
    manifest = sample_manifest()
    check_equal(
        espdisp.validated_manifest_release_notes(manifest), GENERIC_RELEASE_NOTES,
        "manifest validator preserves ordered metadata")
    legacy = handmade_manifest([image_entry("c6", FAKE_C6)])
    legacy_data = handmade_bundle(
        espdisp.encode_manifest(legacy), payload_bytes(("c6", FAKE_C6)))
    check_accepts(lambda: espdisp.unpack_bundle(legacy_data),
                  "field-free format-3 bundle remains readable")
    for value in (0, -1, espdisp.FIRMWARE_BUILD_MAX + 1, True, 192.0):
        invalid = handmade_manifest(
            [image_entry("c6", FAKE_C6)], firmware_build=value)
        check_fails(
            lambda invalid=invalid: espdisp.unpack_bundle(
                handmade_bundle(
                    espdisp.encode_manifest(invalid),
                    payload_bytes(("c6", FAKE_C6)))),
            "firmware_build: must be a whole number",
            "invalid firmware build %r" % value)
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(b'{"a":1,"a":2}')),
        "bundle manifest: duplicate key a",
        "duplicate manifest keys win before required-field validation")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(b'{"release_notes":null,"release_\\u006eotes":[]}')),
        "bundle manifest: duplicate key release_notes",
        "escaped-equivalent release-note key is a duplicate")
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(b'{"a":1,"a":')),
        "bundle manifest is not valid UTF-8 JSON",
        "native malformed JSON error wins over an incomplete duplicate scan")
    fixture_app = b"fixture-app"
    fixture_parts = {
        "bootloader": b"fixture-boot",
        "partitions": b"fixture-partitions",
        "boot_app0": b"fixture-ota",
    }
    fixture_entries = [{
        "board": "c6", "targets": ["c6"], "chip": "esp32c6",
        "fqbn": "esp32:esp32:esp32c6", "filename": "fixture.bin",
        "bytes": len(fixture_app), "sha256": espdisp.sha256_hex(fixture_app),
        "app_address": 0x10000,
        "flash_parts": [{
            "role": role, "address": address, "filename": role + ".bin",
            "bytes": len(fixture_parts[role]),
            "sha256": espdisp.sha256_hex(fixture_parts[role]),
        } for role, address in (
            ("bootloader", 0), ("partitions", 0x8000), ("boot_app0", 0xE000))],
    }]
    fixture_manifest = espdisp.bundle_manifest(
        "1.4.2", 192, fixture_entries, "2026-01-02T03:04:05Z",
        release_notes=["Added generic fixture metadata.", "Fixed generic fixture ordering."],
        source_commit="a" * 40)
    fixture_bytes = espdisp.pack_bundle(
        fixture_manifest, {"c6": fixture_app}, {"c6": fixture_parts})
    fixture_path = os.path.join(
        espdisp.REPO_ROOT, "mac", "ESPDisplaySender", "Tests", "SenderProtocolTests",
        "Fixtures", "release-notes-from-espdisp-v3.espdispfw")
    with open(fixture_path, "rb") as fixture:
        check_equal(fixture.read(), fixture_bytes,
                    "committed Swift fixture matches Python format-3 serialization")

    description = "\n".join(espdisp.describe_bundle(manifest))
    check("release notes: 1 item(s)" in description,
          "bundle-info description reports release-note count")
    check(GENERIC_RELEASE_NOTES[0] not in description,
          "bundle-info description never exposes release-note prose")


def test_bundle_release_notes_preflight_order():
    args = type("BundleArgs", (), {"family": ["c6"], "output": None})()
    with unittest.mock.patch.object(
        espdisp, "sketch_fw_version_declaration", return_value=("not-a-version", 7)), \
         unittest.mock.patch.object(
             espdisp, "bundle_family_keys", side_effect=AssertionError("family lookup ran")):
        check_fails(
            lambda: espdisp.cmd_bundle(args),
            "firmware/display_stream/app_state.cpp:7: FW_VERSION 'not-a-version' is not SemVer 2.0.0",
            "invalid FW_VERSION stops before family resolution")
    with unittest.mock.patch.object(
        espdisp, "sketch_fw_version_declaration", return_value=("1.4.2", 7)), \
         unittest.mock.patch.object(
             espdisp, "release_notes_for_version", side_effect=espdisp.Fail("source failed")), \
         unittest.mock.patch.object(
             espdisp, "bundle_family_keys", side_effect=AssertionError("family lookup ran")):
        check_fails(
            lambda: espdisp.cmd_bundle(args), "source failed",
            "release-note preflight stops before family resolution")


def test_release_notes_diagnostics_and_precedence():
    """Every finite source diagnostic and its required precedence stay pinned."""
    def source_failure(raw, expected, label, version="1.4.2"):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "release-notes.md")
            with open(path, "wb") as source:
                source.write(raw)
            try:
                espdisp.release_notes_for_version(path, version)
            except espdisp.Fail as exc:
                check_equal(str(exc), expected % path, label)
            else:
                check(False, "%s: did not refuse" % label)

    source_cases = [
        (
            b"# Notes\n",
            "release notes %s:1: section none: expected exact title '# Release Notes'",
            "title is exact",
        ),
        (
            b"# Release Notes\n",
            "release notes %s:1: section none: document contains no release sections",
            "a document needs a section",
        ),
        (
            b"# Release Notes\n# Other\n",
            "release notes %s:2: section none: section heading must be exactly '## <SemVer 2.0.0>'",
            "other Markdown headings are refused",
        ),
        (
            b"# Release Notes\n## version\n",
            "release notes %s:2: section none: version 'version' is not SemVer 2.0.0",
            "section label must be SemVer",
        ),
        (
            b"# Release Notes\nplain text\n",
            "release notes %s:2: section none: content appears before the first release section",
            "content needs a section",
        ),
        (
            b"# Release Notes\n## 1.4.2\nplain text\n",
            "release notes %s:3: section 1.4.2: item must begin with '- '",
            "section content needs an item marker",
        ),
        (
            b"# Release Notes\n## 1.4.2\n- \n",
            "release notes %s:3: section 1.4.2: item text must contain 1–280 Unicode scalars",
            "empty item is refused",
        ),
        (
            b"# Release Notes\n## 1.4.2\n- Added bad\x00.\n",
            "release notes %s:3: section 1.4.2: item text contains forbidden scalar U+0000",
            "control scalar is refused",
        ),
        (
            "# Release Notes\n## 1.4.2\n- Added valid.\u00a0\n".encode("utf-8"),
            "release notes %s:3: section 1.4.2: item text has forbidden leading or trailing whitespace",
            "protocol edge whitespace is refused",
        ),
        (
            b"# Release Notes\n## 1.4.2\n- Other valid text.\n",
            "release notes %s:3: section 1.4.2: item text must begin with Added, Changed, Fixed, or Removed",
            "item verb is constrained",
        ),
        (
            b"# Release Notes\n## 1.4.2\n- Added missing punctuation\n",
            "release notes %s:3: section 1.4.2: item text must end with '.', '!', or '?'",
            "item punctuation is constrained",
        ),
        (
            b"# Release Notes\n## 1.4.2\n",
            "release notes %s:2: section 1.4.2: section must contain 1–32 items",
            "section needs at least one item",
        ),
        (
            b"# Release Notes\n## 2.0.0\n- Added newer item.\n## 2.0.0\n- Fixed duplicate item.\n",
            "release notes %s:2,4: duplicate version 2.0.0",
            "duplicate version labels are refused",
        ),
        (
            b"# Release Notes\n## 1.0.0\n- Added older item.\n## 2.0.0\n- Fixed newer item.\n",
            "release notes %s:2,4: version 2.0.0 is not older than 1.0.0",
            "sections are newest first",
        ),
        (
            b"# Release Notes\n## 2.0.0\n- Added another release.\n",
            "release notes %s: no section exactly matching FW_VERSION 1.4.2",
            "current firmware needs an exact section",
        ),
        (
            b"# Release Notes\n\n## 1.4.2\r\n",
            "release notes %s:3: section 1.4.2: carriage return byte is not allowed",
            "CR framing is refused before decoding",
        ),
        (
            b"# Release Notes\n\xff",
            "release notes %s: byte 16: line 2: not valid UTF-8",
            "UTF-8 diagnostics name the byte and LF line",
        ),
    ]
    for raw, expected, label in source_cases:
        source_failure(raw, expected, label)

    with tempfile.TemporaryDirectory() as directory:
        unreadable = os.path.join(directory, "missing-release-notes.md")
        try:
            espdisp.release_notes_for_version(unreadable, "1.4.2")
        except espdisp.Fail as exc:
            check_equal(str(exc), "release notes %s: cannot read" % unreadable,
                        "unreadable release-note source has a stable envelope")
        else:
            check(False, "unreadable release-note source did not refuse")

    requested = "bad'\\value\n\U0001f600"
    try:
        espdisp.release_notes_for_version("not opened", requested)
    except espdisp.Fail as exc:
        check_equal(
            str(exc),
            "release notes not opened: requested FW_VERSION 'bad\\'\\\\value\\u000A\\uD83D\\uDE00' is not SemVer 2.0.0",
            "requested values use safe scalar-by-scalar quoting")
    else:
        check(False, "invalid requested FW_VERSION did not refuse")
    check_equal(
        espdisp.quote_release_value("a'b\\c\n\U0001f600"),
        "'a\\'b\\\\c\\u000A\\uD83D\\uDE00'",
        "release value quoting handles apostrophe, slash, control, and supplementary scalars")

    source_failure(
        b"# Release Notes\n\xff\r",
        "release notes %s:2: section none: carriage return byte is not allowed",
        "a later CR wins over earlier invalid UTF-8")
    source_failure(
        b"# Release Notes\n# malformed\norphan\n",
        "release notes %s:2: section none: section heading must be exactly '## <SemVer 2.0.0>'",
        "a malformed heading wins over apparent orphan content")
    source_failure(
        b"# Release Notes\n## 1.4.2\nnot-an-item\n## 1.0.0\n",
        "release notes %s:3: section 1.4.2: item must begin with '- '",
        "line-local item defects win over section cardinality")
    source_failure(
        b"# Release Notes\n## 1.0.0\n\n## 2.0.0\n- Added later release.\n",
        "release notes %s:2: section 1.0.0: section must contain 1–32 items",
        "section cardinality wins over ordering")
    source_failure(
        b"# Release Notes\n## 2.0.0\n- Added current item.\n## 1.0.0\n- Fixed older item.\n## 2.0.0\n- Changed duplicate item.\n",
        "release notes %s:2,6: duplicate version 2.0.0",
        "duplicate labels win over ordering")
    source_failure(
        b"# Release Notes\n## 1.0.0\n- Added older release.\n## 2.0.0\n- Fixed newer release.\n",
        "release notes %s:2,4: version 2.0.0 is not older than 1.0.0",
        "ordering wins over an absent current section")


def test_release_notes_reader_vectors():
    """Current metadata, legacy absence, and duplicate diagnostics share one contract."""
    def exact_failure(fn, expected, label):
        try:
            fn()
        except espdisp.Fail as exc:
            check_equal(str(exc), expected, label)
        else:
            check(False, "%s: did not refuse" % label)

    def external_manifest(notes):
        manifest = handmade_manifest([image_entry("c6", FAKE_C6)])
        manifest["release_notes"] = notes
        return handmade_bundle(
            espdisp.encode_manifest(manifest), payload_bytes(("c6", FAKE_C6)))

    valid_notes = ["Added interior\u0085text.", "Fixed wrapped\u2028text?"]
    valid_manifest = espdisp.bundle_manifest(
        "1.2.0", 192, [image_entry("c6", FAKE_C6)],
        "2026-01-02T03:04:05Z",
        release_notes=valid_notes)
    valid_data = espdisp.pack_bundle(
        valid_manifest, {"c6": FAKE_C6}, sample_flash_payloads("c6"))
    decoded, _, _ = espdisp.unpack_bundle(valid_data)
    check_equal(decoded["release_notes"], valid_notes,
                "reader preserves ordered valid metadata and allowed interior scalars")

    for value, reason, label in [
        (None, "bundle manifest: release_notes: must be a list containing 1–32 items", "null metadata"),
        ("Added text.", "bundle manifest: release_notes: must be a list containing 1–32 items", "string metadata"),
        ({}, "bundle manifest: release_notes: must be a list containing 1–32 items", "object metadata"),
        ([], "bundle manifest: release_notes: must be a list containing 1–32 items", "empty metadata"),
        (["Added valid text."] * 33, "bundle manifest: release_notes: must be a list containing 1–32 items", "too many metadata items"),
        ([False], "bundle manifest: release_notes[0]: item must be a string", "non-string metadata item"),
        ([""], "bundle manifest: release_notes[0]: item text must contain 1–280 Unicode scalars", "empty metadata item"),
        (["Added bad\x00."], "bundle manifest: release_notes[0]: item text contains forbidden scalar U+0000", "control metadata item"),
        ([" Added valid text."], "bundle manifest: release_notes[0]: item text has forbidden leading or trailing whitespace", "edge whitespace metadata item"),
        (["Other valid text."], "bundle manifest: release_notes[0]: item text must begin with Added, Changed, Fixed, or Removed", "metadata item verb"),
        (["Added missing punctuation"], "bundle manifest: release_notes[0]: item text must end with '.', '!', or '?'", "metadata item punctuation"),
        (["Added " + "x" * 274 + "."], "bundle manifest: release_notes[0]: item text must contain 1–280 Unicode scalars", "metadata item scalar bound"),
    ]:
        exact_failure(lambda value=value: espdisp.unpack_bundle(external_manifest(value)), reason, label)

    exact_failure(
        lambda: espdisp.validated_manifest_release_notes({"release_notes": ["Added \ud800."]}),
        "bundle manifest: release_notes[0]: item text contains forbidden scalar U+D800",
        "decoded unpaired surrogate is an item error in Python")

    legacy_vectors = []
    v1_entry = image_entry("c6", FAKE_C6)
    for key in ("targets", "app_address", "flash_parts"):
        del v1_entry[key]
    legacy_vectors.append((
        "format-1", handmade_bundle(
            espdisp.encode_manifest(handmade_manifest([v1_entry], format=1)),
            FAKE_C6, magic=espdisp.BUNDLE_MAGIC_V1)))
    v2_entry = image_entry("c6", FAKE_C6)
    del v2_entry["targets"]
    legacy_vectors.append((
        "format-2", handmade_bundle(
            espdisp.encode_manifest(handmade_manifest([v2_entry], format=2)),
            payload_bytes(("c6", FAKE_C6)), magic=espdisp.BUNDLE_MAGIC_V2)))
    legacy_vectors.append((
        "field-free format-3", handmade_bundle(
            espdisp.encode_manifest(handmade_manifest([image_entry("c6", FAKE_C6)])),
            payload_bytes(("c6", FAKE_C6)))))
    for label, data in legacy_vectors:
        try:
            manifest, _, _ = espdisp.unpack_bundle(data)
        except espdisp.Fail as exc:
            check(False, "%s legacy bundle refused: %s" % (label, exc))
        else:
            check("release_notes" not in manifest, "%s preserves absent metadata" % label)

    for raw in [
        b'{"release_notes":null,"release_notes":["Added valid text."]}',
        b'{"release_notes":["Added valid text."],"release_notes":null}',
        b'{"release_notes":null,"release_\\u006eotes":["Added valid text."]}',
    ]:
        exact_failure(
            lambda raw=raw: espdisp.unpack_bundle(handmade_bundle(raw)),
            "bundle manifest: duplicate key release_notes",
            "duplicate release-note names take precedence")
    for raw, key, label in [
        (b'{"images":{"a":1,"a":2}}', "a", "nested image-object duplicate"),
        (b'{"line\\n":1,"line\\u000A":2}', r"line\u000A", "control key is rendered safely"),
        (b'{"a\\\\b":1,"a\\u005Cb":2}', r"a\\b", "backslash key is rendered safely"),
        (b'{"\\uD83D\\uDE00":1,"\\uD83D\\uDE00":2}', r"\uD83D\uDE00", "supplementary key is rendered safely"),
    ]:
        exact_failure(
            lambda raw=raw: espdisp.unpack_bundle(handmade_bundle(raw)),
            "bundle manifest: duplicate key %s" % key,
            label)
    check_fails(
        lambda: espdisp.unpack_bundle(handmade_bundle(b'{"a":truee,"a":2}')),
        "bundle manifest is not valid UTF-8 JSON",
        "native malformed JSON wins over a completed duplicate candidate")


def test_bundle_release_notes_preflight_barriers():
    """All declaration/source failures happen before bundle side effects."""
    args = type("BundleArgs", (), {"family": ["c6"], "output": None})()
    blockers = [
        unittest.mock.patch.object(
            espdisp, "bundle_family_keys", side_effect=AssertionError("family lookup ran")),
        unittest.mock.patch.object(
            espdisp, "git_provenance", side_effect=AssertionError("provenance ran")),
        unittest.mock.patch.object(
            espdisp.tempfile, "mkdtemp", side_effect=AssertionError("temporary output ran")),
        unittest.mock.patch.object(
            espdisp, "compile_board", side_effect=AssertionError("compile ran")),
        unittest.mock.patch.object(
            espdisp, "write_file_atomically", side_effect=AssertionError("output write ran")),
        unittest.mock.patch.object(
            espdisp.os, "getcwd", side_effect=AssertionError("output path ran")),
    ]
    with unittest.mock.patch.object(
        espdisp, "sketch_fw_version_declaration", return_value=("not-a-version", 7)), \
         unittest.mock.patch.object(
             espdisp, "RELEASE_NOTES_PATH", "/unreadable-release-notes.md"), \
         blockers[0], blockers[1], blockers[2], blockers[3], blockers[4], blockers[5]:
        try:
            espdisp.cmd_bundle(args)
        except espdisp.Fail as exc:
            check_equal(
                str(exc),
                "firmware/display_stream/app_state.cpp:7: FW_VERSION 'not-a-version' is not SemVer 2.0.0",
                "invalid FW_VERSION wins over an unreadable release source")
        else:
            check(False, "invalid FW_VERSION did not refuse")

    blockers = [
        unittest.mock.patch.object(
            espdisp, "bundle_family_keys", side_effect=AssertionError("family lookup ran")),
        unittest.mock.patch.object(
            espdisp, "git_provenance", side_effect=AssertionError("provenance ran")),
        unittest.mock.patch.object(
            espdisp.tempfile, "mkdtemp", side_effect=AssertionError("temporary output ran")),
        unittest.mock.patch.object(
            espdisp, "compile_board", side_effect=AssertionError("compile ran")),
        unittest.mock.patch.object(
            espdisp, "write_file_atomically", side_effect=AssertionError("output write ran")),
        unittest.mock.patch.object(
            espdisp.os, "getcwd", side_effect=AssertionError("output path ran")),
    ]
    with unittest.mock.patch.object(
        espdisp, "sketch_fw_version_declaration", return_value=("1.4.2", 7)), \
         unittest.mock.patch.object(
             espdisp, "release_notes_for_version", side_effect=espdisp.Fail("source failed")), \
         blockers[0], blockers[1], blockers[2], blockers[3], blockers[4], blockers[5]:
        check_fails(
            lambda: espdisp.cmd_bundle(args), "source failed",
            "release-note preflight blocks board, provenance, output, and compilation")


def test_doom_partition_contracts():
    """Canonical Doom families package a verified WAD at their table address."""
    def entry(label, part_type, subtype, address, size):
        return struct.pack(
            "<HBBII16sI", 0x50AA, part_type, subtype, address, size,
            label.encode("ascii").ljust(16, b"\0"), 0)

    good = b"".join([
        entry("nvs", 0x01, 0x02, 0x9000, 0x5000),
        entry("otadata", 0x01, 0x00, 0xE000, 0x2000),
        entry("app0", 0x00, 0x10, 0x10000, 0x800000),
        entry("app1", 0x00, 0x11, 0x810000, 0x800000),
        # The P4 Doom port reserves the WAD above app1 rather than reusing the
        # S3 raw offset, which lands inside app1 on this table.
        entry("doom_wad", 0x42, 0x06, 0x1010000, 0x401000),
    ]) + b"\xff" * 32
    check_accepts(
        lambda: espdisp._verify_partition_payload(
            espdisp.FAMILIES["p4"], good),
        "P4 dual-OTA partition table")
    check_equal(
        espdisp._doom_wad_partition(good),
        (0x1010000, 0x401000),
        "P4 WAD address comes from the partition table")
    missing_app1 = good[:3 * 32] + b"\xff" * 32
    check_fails(
        lambda: espdisp._verify_partition_payload(
            espdisp.FAMILIES["p4"], missing_app1),
        "expected app0, app1, doom_wad, nvs, otadata",
        "P4 table without its recovery OTA slot")

    s3 = b"".join([
        entry("nvs", 0x01, 0x02, 0x9000, 0x5000),
        entry("otadata", 0x01, 0x00, 0xE000, 0x2000),
        entry("app0", 0x00, 0x10, 0x10000, 0x1F0000),
        entry("app1", 0x00, 0x11, 0x200000, 0x1F0000),
        entry("doom_wad", 0x42, 0x06, 0x3FF000, 0x401000),
    ]) + b"\xff" * 32
    check_accepts(
        lambda: espdisp._verify_partition_payload(
            espdisp.FAMILIES["s3"], s3),
        "S3 dual-OTA partition table fits the WAD in 8 MiB")
    check_equal(
        espdisp._doom_wad_partition(s3),
        (0x3FF000, 0x401000),
        "S3 WAD address comes from the partition table")
    unknown_family = espdisp.FAMILIES["c6"]._replace(key="future")
    check_fails(
        lambda: espdisp._verify_partition_payload(
            unknown_family, good[:4 * 32] + b"\xff" * 32),
        "unrecognised firmware family future",
        "an unrecognised family cannot inherit the C6 partition policy")

    with tempfile.TemporaryDirectory() as directory:
        wad_path = os.path.join(directory, "doom1.wad")
        wad = b"IWAD" + b"\0" * (espdisp._DOOM_WAD_SIZE - 4)
        with open(wad_path, "wb") as out:
            out.write(wad)
        with unittest.mock.patch.object(
                espdisp, "_ensure_doom_wad", return_value=wad_path), \
             unittest.mock.patch.object(
                espdisp, "_DOOM_WAD_SHA256", espdisp.sha256_hex(wad)):
            for family_key, table, address in (
                    ("p4", good, 0x1010000),
                    ("s3", s3, 0x3FF000)):
                parts = []
                payloads = {}
                family = espdisp.FAMILIES[family_key]
                espdisp._add_required_doom_wad_flash_part(
                    family, table, parts, payloads)
                image = {"flash_parts": parts}
                check_accepts(
                    lambda family=family, table=table, image=image, payloads=payloads:
                        espdisp._verify_required_doom_flash_payload(
                            family, table, image, payloads),
                    "%s bundle carries the verified table-addressed WAD"
                    % family_key.upper())
                check_equal(
                    [(part["role"], part["address"], part["bytes"])
                     for part in parts],
                    [("doom_wad", address, espdisp._DOOM_WAD_SIZE)],
                    "%s WAD manifest entry uses its partition address and exact size"
                    % family_key.upper())
                check_equal(
                    payloads["doom_wad"], wad,
                    "%s bundle carries the WAD bytes" % family_key.upper())
        c6_image = {"flash_parts": [{
            "role": "doom_wad",
            "address": 0x3FF000,
            "bytes": len(wad),
            "sha256": espdisp.sha256_hex(wad),
        }]}
        check_fails(
            lambda: espdisp._verify_required_doom_flash_payload(
                espdisp.FAMILIES["c6"], b"", c6_image, {"doom_wad": wad}),
            "must not carry a doom_wad",
            "C6 bundle with a stray WAD flash part")
        check_accepts(
            lambda: espdisp._verify_required_doom_flash_payload(
                espdisp.FAMILIES["c6"], b"", {"flash_parts": None}, {}),
            "a missing optional flash-part list is treated as empty")
        check_fails(
            lambda: espdisp._verify_required_doom_flash_payload(
                espdisp.FAMILIES["c6"], b"", {"flash_parts": "invalid"}, {}),
            "flash_parts must be a list",
            "a malformed flash-part collection fails closed")


def test_board_descriptor_validator():
    descriptors = board_descriptor.load_repository_descriptors(
        espdisp.REPO_ROOT)
    schema_path = os.path.join(espdisp.REPO_ROOT, "boards", "schema-v1.json")
    with open(schema_path, encoding="utf-8") as source:
        schema = json.load(source)
    check_equal(
        schema["properties"]["schema"]["const"], 1,
        "checked-in descriptor schema matches schema version 1",
    )
    check_equal(
        set(schema["required"]),
        {
            "schema", "key", "catalog_order", "name", "hardware",
            "migration", "identity", "family", "platform", "capacity",
            "panel", "carrier", "touch", "led", "gesture",
            "orientation", "motion", "reset", "backlight", "power",
            "serial", "audio", "capabilities", "compile", "detection",
        },
        "schema requires every descriptor section",
    )
    check_equal(len(descriptors), 10, "all current boards have descriptors")
    check_equal(
        sorted(
            descriptor["identity"]["profile"]
            for descriptor in descriptors
            if descriptor["migration"]["firmware_config"] == "generated"
        ),
        ["co5300", "gc9a01a-240", "jd9853", "st7703-4b"],
        "one board per family uses generated firmware config",
    )
    check_accepts(
        lambda: board_descriptor.validate_descriptors(descriptors),
        "repository descriptors pass validation",
    )
    v2_audio = {
        "amp": "ns4150b",
        "codec": "es8311",
        "mic": "es7210",
        "speaker_bus": "i2s",
        "mic_bus": "i2s",
        "pin_playback_mclk": 2,
        "pin_playback_bclk": 48,
        "pin_playback_lrck": 38,
        "pin_dout": 47,
        "pin_capture_mclk": 2,
        "pin_capture_bclk": 48,
        "pin_capture_lrck": 38,
        "pin_din": 39,
        "pin_pdm_clock": -1,
        "pin_amp_enable": 15,
        "codec_i2c_address": 0x18,
        "mic_i2c_address": 0x40,
        "playback_rate_hz": 16000,
        "playback_channels": 2,
        "capture_rate_hz": 16000,
        "capture_channels": 2,
    }
    lcd_185c = next(
        item for item in descriptors
        if item["key"] == "s3-touch-lcd-185c")
    check_equal(
        lcd_185c["audio"],
        v2_audio,
        "the 1.85C descriptor pins the verified V2 audio topology",
    )
    check(
        espdisp.generate_board_descriptors.write_outputs(
            espdisp.REPO_ROOT, check=True),
        "committed generated board files are current",
    )

    audio_none = {
        "amp": "none",
        "codec": "none",
        "mic": "none",
        "speaker_bus": "none",
        "mic_bus": "none",
        "pin_playback_mclk": -1,
        "pin_playback_bclk": -1,
        "pin_playback_lrck": -1,
        "pin_dout": -1,
        "pin_capture_mclk": -1,
        "pin_capture_bclk": -1,
        "pin_capture_lrck": -1,
        "pin_din": -1,
        "pin_pdm_clock": -1,
        "pin_amp_enable": -1,
        "codec_i2c_address": 0,
        "mic_i2c_address": 0,
        "playback_rate_hz": 0,
        "playback_channels": 0,
        "capture_rate_hz": 0,
        "capture_channels": 0,
    }
    audio_verified = {
        "amp": "ns4150b",
        "codec": "es8311",
        "mic": "es7210",
        "speaker_bus": "i2s",
        "mic_bus": "i2s",
        "pin_playback_mclk": 16,
        "pin_playback_bclk": 9,
        "pin_playback_lrck": 45,
        "pin_dout": 8,
        "pin_capture_mclk": 16,
        "pin_capture_bclk": 9,
        "pin_capture_lrck": 45,
        "pin_din": 10,
        "pin_pdm_clock": -1,
        "pin_amp_enable": 46,
        "codec_i2c_address": 0x18,
        "mic_i2c_address": 0x40,
        "playback_rate_hz": 16000,
        "playback_channels": 2,
        "capture_rate_hz": 16000,
        "capture_channels": 2,
    }

    absent_audio = copy.deepcopy(descriptors[0])
    absent_audio["audio"] = copy.deepcopy(audio_none)
    absent_audio["capabilities"]["audio"] = False
    check_accepts(
        lambda: board_descriptor.validate_descriptors([absent_audio]),
        "an absent audio row passes validation",
    )

    verified_audio = copy.deepcopy(next(
        item for item in descriptors
        if item["identity"]["profile"] == "co5300"))
    verified_audio["audio"] = copy.deepcopy(audio_verified)
    verified_audio["capabilities"]["audio"] = True
    check_accepts(
        lambda: board_descriptor.validate_descriptors([verified_audio]),
        "a complete verified audio row passes validation",
    )

    malformed_audio_enum = copy.deepcopy(verified_audio)
    malformed_audio_enum["audio"]["amp"] = "plausible-amp"
    check_descriptor_fails(
        [malformed_audio_enum],
        "audio.amp must be one of",
        "unknown audio amp enums are refused",
    )

    malformed_audio_pin = copy.deepcopy(verified_audio)
    malformed_audio_pin["audio"]["pin_playback_mclk"] = -5
    check_descriptor_fails(
        [malformed_audio_pin],
        "audio.pin_playback_mclk must be -1 or GPIO 0..48",
        "audio pins reject negative values other than the sentinel",
    )

    out_of_range_audio_pin = copy.deepcopy(verified_audio)
    out_of_range_audio_pin["audio"]["pin_playback_mclk"] = 49
    check_descriptor_fails(
        [out_of_range_audio_pin],
        "audio.pin_playback_mclk must be -1 or GPIO 0..48",
        "audio pins use the target GPIO ceiling",
    )

    colliding_audio_pin = copy.deepcopy(verified_audio)
    colliding_audio_pin["audio"]["pin_playback_mclk"] = \
        colliding_audio_pin["carrier"]["pin_sclk"]
    check_descriptor_fails(
        [colliding_audio_pin],
        "audio.pin_playback_mclk GPIO38 collides with carrier.pin_sclk",
        "audio pins cannot collide with existing board wiring",
    )

    knob = next(
        item for item in descriptors if item["key"] == "s3-elecrow-knob-128")
    check_equal(
        [board_descriptor.optional_pin(knob, "carrier." + field)
         for field in ("pin_panel_power", "pin_encoder_a", "pin_encoder_b")],
        [1, 45, 42],
        "the knob carrier declares its panel rail and encoder lines",
    )
    check_equal(
        board_descriptor.optional_pin(verified_audio, "carrier.pin_encoder_a"),
        -1,
        "carriers that omit an optional line read it as absent",
    )
    half_encoder = copy.deepcopy(knob)
    half_encoder["carrier"]["pin_encoder_b"] = -1
    check_descriptor_fails(
        [half_encoder],
        "pin_encoder_a and pin_encoder_b must both be declared",
        "an encoder needs both quadrature lines",
    )
    colliding_encoder = copy.deepcopy(knob)
    colliding_encoder["carrier"]["pin_encoder_a"] = 41
    check_descriptor_fails(
        [colliding_encoder],
        "carrier.pin_encoder_a GPIO41 collides with carrier.pin_boot",
        "encoder lines cannot collide with existing carrier wiring",
    )
    encoder_on_touch = copy.deepcopy(knob)
    encoder_on_touch["carrier"]["pin_encoder_a"] = 5
    check_descriptor_fails(
        [encoder_on_touch],
        "carrier.pin_encoder_a GPIO5 collides with touch.interrupt",
        "encoder lines cannot collide with touch wiring",
    )
    rail_on_touch_reset = copy.deepcopy(knob)
    rail_on_touch_reset["carrier"]["pin_panel_power"] = 13
    check_descriptor_fails(
        [rail_on_touch_reset],
        "carrier.pin_panel_power GPIO13 collides with touch.reset",
        "the panel rail cannot collide with touch wiring",
    )
    audio_on_encoder = copy.deepcopy(verified_audio)
    audio_on_encoder["carrier"]["pin_encoder_a"] = 3
    audio_on_encoder["carrier"]["pin_encoder_b"] = 13
    audio_on_encoder["audio"]["pin_playback_mclk"] = 3
    check_descriptor_fails(
        [audio_on_encoder],
        "audio.pin_playback_mclk GPIO3 collides with carrier.pin_encoder_a",
        "audio pins cannot collide with optional carrier lines",
    )
    out_of_range_power = copy.deepcopy(knob)
    out_of_range_power["carrier"]["pin_panel_power"] = 49
    check_descriptor_fails(
        [out_of_range_power],
        "carrier.pin_panel_power must be -1 or GPIO 0..48",
        "the panel rail pin uses the target GPIO ceiling",
    )
    divergent_panel = copy.deepcopy(knob)
    divergent_panel["panel"]["pixel_clock_hz"] = 80000000
    c3_round = next(
        item for item in descriptors if item["key"] == "c3-2424s012")
    check_accepts(
        lambda: board_descriptor.validate_descriptors([c3_round, knob]),
        "two carriers may share one identical panel profile",
    )
    check_descriptor_fails(
        [c3_round, divergent_panel],
        "panel PANEL_GC9107_240X240 differs from the same panel",
        "carriers sharing a panel symbol must agree on every panel fact",
    )

    absent_with_pin = copy.deepcopy(absent_audio)
    absent_with_pin["audio"]["pin_dout"] = 1
    check_descriptor_fails(
        [absent_with_pin],
        "audio capability is false but audio.pin_dout is declared",
        "audio-absent rows cannot carry implementation pins",
    )

    unknown_with_detail = copy.deepcopy(verified_audio)
    unknown_with_detail["audio"]["amp"] = "unknown"
    check_descriptor_fails(
        [unknown_with_detail],
        "unverified audio rows must leave pins, addresses, rates, and channels unknown",
        "unknown hardware revisions cannot mix guesses with concrete facts",
    )

    missing_playback_pin = copy.deepcopy(verified_audio)
    missing_playback_pin["audio"]["pin_dout"] = -1
    check_descriptor_fails(
        [missing_playback_pin],
        "I2S playback requires audio.pin_playback_bclk, pin_playback_lrck, and pin_dout",
        "verified I2S playback requires its data pin",
    )

    malformed_audio_rate = copy.deepcopy(verified_audio)
    malformed_audio_rate["audio"]["capture_rate_hz"] = 7999
    check_descriptor_fails(
        [malformed_audio_rate],
        "audio.capture_rate_hz must be 8000..96000",
        "audio sample rates are bounded",
    )

    malformed_audio_channels = copy.deepcopy(verified_audio)
    malformed_audio_channels["audio"]["capture_channels"] = 9
    check_descriptor_fails(
        [malformed_audio_channels],
        "audio.capture_channels must be 1..8",
        "audio channel counts are bounded",
    )

    missing_codec_address = copy.deepcopy(verified_audio)
    missing_codec_address["audio"]["codec_i2c_address"] = 0
    check_descriptor_fails(
        [missing_codec_address],
        "ES8311 requires audio.codec_i2c_address",
        "I2C codecs require a usable address",
    )

    separate_capture_clocks = copy.deepcopy(verified_audio)
    separate_capture_clocks["audio"]["pin_capture_mclk"] = 17
    separate_capture_clocks["audio"]["pin_capture_bclk"] = 18
    separate_capture_clocks["audio"]["pin_capture_lrck"] = 19
    check_accepts(
        lambda: board_descriptor.validate_descriptors(
            [separate_capture_clocks]),
        "playback and capture may use independent I2S clocks",
    )

    pdm_capture = copy.deepcopy(verified_audio)
    pdm_capture["audio"]["mic"] = "pdm"
    pdm_capture["audio"]["mic_bus"] = "pdm"
    pdm_capture["audio"]["pin_capture_mclk"] = -1
    pdm_capture["audio"]["pin_capture_bclk"] = -1
    pdm_capture["audio"]["pin_capture_lrck"] = -1
    pdm_capture["audio"]["pin_pdm_clock"] = 17
    pdm_capture["audio"]["mic_i2c_address"] = 0
    check_accepts(
        lambda: board_descriptor.validate_descriptors([pdm_capture]),
        "a direct PDM mic may coexist with I2S playback",
    )

    pdm_with_i2s_clocks = copy.deepcopy(pdm_capture)
    pdm_with_i2s_clocks["audio"]["pin_capture_bclk"] = 18
    check_descriptor_fails(
        [pdm_with_i2s_clocks],
        "PDM capture must not declare capture I2S clocks",
        "PDM and capture-I2S clocks cannot be mixed",
    )

    es7210_on_pdm = copy.deepcopy(pdm_capture)
    es7210_on_pdm["audio"]["mic"] = "es7210"
    es7210_on_pdm["audio"]["mic_i2c_address"] = 0x40
    check_descriptor_fails(
        [es7210_on_pdm],
        "ES7210 requires audio.mic_bus i2s",
        "I2S capture devices cannot be declared as PDM",
    )

    generated_audio_path = os.path.join(
        espdisp.REPO_ROOT, "firmware", "libraries", "espdisp_board", "src",
        "generated_board_audio.h")
    if os.path.exists(generated_audio_path):
        with open(generated_audio_path, encoding="utf-8") as source:
            generated_audio = source.read()
    else:
        generated_audio = ""
    check(
        "AudioAmp::Ns4150b" in generated_audio and
        "AudioCodec::Es8311" in generated_audio and
        "AudioMic::Es7210" in generated_audio,
        "generated constexpr audio data carries verified component enums",
    )
    check(
        "Variant::LcdSt77916, AudioAmp::Ns4150b, AudioCodec::Es8311, "
        "AudioMic::Es7210, AudioSpeakerBus::I2s, AudioMicBus::I2s, "
        "2, 48, 38, 47, 2, 48, 38, 39, -1, 15, 24, 64, "
        "16000, 2, 16000, 2" in generated_audio,
        "generated 1.85C audio data pins the verified V2 topology",
    )

    missing = copy.deepcopy(descriptors[0])
    del missing["panel"]["pixel_depth"]
    check_descriptor_fails(
        [missing],
        "missing required field panel.pixel_depth",
        "missing required descriptor field",
    )

    one_sided_memory = copy.deepcopy(descriptors[0])
    one_sided_memory["panel"]["memory_height"] = 0
    check_descriptor_fails(
        [one_sided_memory],
        "panel memory extents must both be known or both be 0",
        "one-sided panel memory extent",
    )

    undersized_memory = copy.deepcopy(descriptors[0])
    undersized_memory["panel"]["memory_width"] = 200
    check_descriptor_fails(
        [undersized_memory],
        "panel width plus col_offset exceeds memory_width",
        "panel window outside controller memory",
    )

    malformed = copy.deepcopy(descriptors[0])
    malformed["detection"]["adressess"] = [0x20]
    check_descriptor_fails(
        [malformed],
        "unknown field detection.adressess",
        "unknown descriptor fields are refused",
    )

    duplicate_probe = copy.deepcopy(descriptors[0])
    duplicate_probe["key"] = "duplicate-probe"
    duplicate_probe["name"] = "Duplicate probe fixture"
    duplicate_probe["identity"]["profile"] = "duplicate-probe"
    duplicate_probe["identity"]["variant"] = "DuplicateProbe"
    duplicate_probe["identity"]["variant_value"] = 250
    duplicate_probe["migration"]["config_symbol"] = "CONFIG_DUPLICATE_PROBE"
    duplicate_probe["catalog_order"] = 250
    duplicate_probe["detection"]["order"] = 250
    check_descriptor_fails(
        [descriptors[0], duplicate_probe],
        "duplicate probe signature",
        "two boards cannot claim the same detection evidence",
    )

    capacity_conflict = copy.deepcopy(descriptors[0])
    capacity_conflict["capacity"]["minimum_flash_bytes"] = (
        capacity_conflict["family"]["common_layout_bytes"] - 1)
    check_descriptor_fails(
        [capacity_conflict],
        "capacity conflict",
        "board smaller than the family layout is refused",
    )

    duplicate_identity = copy.deepcopy(descriptors[0])
    duplicate_identity["key"] = "duplicate-identity"
    duplicate_identity["name"] = "Duplicate identity fixture"
    duplicate_identity["identity"]["variant"] = "DuplicateIdentity"
    duplicate_identity["identity"]["variant_value"] = 251
    duplicate_identity["catalog_order"] = 251
    check_descriptor_fails(
        [descriptors[0], duplicate_identity],
        "identity already claimed",
        "two boards cannot claim the same four-field identity",
    )


def test_universal_family_catalog_and_cli():
    check_equal(sorted(espdisp.FAMILIES), ["c3", "c6", "p4", "s3"],
                "release catalog exposes exactly four families")
    check_equal(espdisp.family_choices(), ["c3", "c6", "p4", "s3"],
                "CLI family choices contain no profile artifact names")
    check_equal(espdisp.FAMILIES["c3"].profiles, ("gc9a01a-240",),
                "C3 maps its round-panel profile")
    check_equal(espdisp.FAMILIES["c6"].profiles, ("st7789", "jd9853"),
                "C6 maps both runtime profiles")
    check_equal(
        espdisp.FAMILIES["s3"].profiles,
        ("gc9107", "st7789-130", "st7789-154", "co5300", "st77916",
         "gc9a01-knob-128"),
        "S3 maps all runtime profiles into one family")
    check_equal(espdisp.FAMILIES["p4"].profiles, ("st7703-4b",),
                "P4 advertises its exact physical profile")
    check(not espdisp.FAMILIES["c3"].requires_doom_wad,
          "C3 explicitly prohibits the Doom WAD payload")
    check(not espdisp.FAMILIES["c6"].requires_doom_wad,
          "C6 explicitly prohibits the Doom WAD payload")
    check(espdisp.FAMILIES["s3"].requires_doom_wad,
          "S3 explicitly requires the Doom WAD payload")
    check(espdisp.FAMILIES["p4"].requires_doom_wad,
          "P4 explicitly requires the Doom WAD payload")
    check_equal(espdisp.FAMILIES["p4"].build_target, "p4-4b",
                "P4 family composes the exact 4B build target")
    check_equal(espdisp.BUILD_TARGETS["p4-4b"].platform, "p4",
                "the 4B build target references the reusable P4 platform")
    check_equal(espdisp.BUILD_TARGETS["p4-4b"].required_profile,
                "st7703-4b", "P4 USB writes require exact carrier evidence")
    check_equal(espdisp.BUILD_TARGETS["p4-4b"].fqbn_options,
                ("UploadSpeed=460800",),
                "the 4B target owns its reliable CH343 upload speed")
    check_equal(espdisp.FAMILIES["p4"].upload_speed, "460800",
                "P4 flashes at the target-pinned upload speed")
    check_equal(espdisp.FAMILIES["s3"].upload_speed,
                espdisp.DEFAULT_FLASH_BAUD,
                "families without an UploadSpeed pin use the default flash baud")
    check("UploadSpeed" not in espdisp.PLATFORMS["p4"].fqbn,
          "the reusable P4 platform has no 4B carrier upload option")
    check("partition_csv" not in espdisp.Platform._fields and
          "extra_flags" not in espdisp.Platform._fields,
          "chip platforms contain no carrier selector or partition source")
    check_equal(espdisp.FAMILIES["s3"].partition_csv, "partitions_s3.csv",
                "S3 uses the 8 MiB dual-OTA Doom partition layout")
    check_equal(espdisp.FAMILIES["c3"].partition_csv, "partitions_c3.csv",
                "C3 uses its 4 MiB dual-OTA partition layout")
    check_equal(espdisp.FAMILIES["c3"].extra_flags, (),
                "C3 has no Doom runtime compile flag")
    check_equal(espdisp.FAMILIES["s3"].extra_flags, ("-DESPDISP_DOOM_RUNTIME",),
                "canonical S3 links the runtime-gated Doom easter egg")
    check_equal(espdisp.FAMILIES["s3"].extra_library_dirs, ("firmware",),
                "canonical S3 includes the Doom library path")
    check_equal(espdisp.FAMILIES["p4"].extra_flags,
                ("-DESPDISP_BOARD_P4_4B", "-DESPDISP_DOOM_RUNTIME"),
                "P4 retains its carrier selector and links the Doom runtime")
    check_equal(espdisp.FAMILIES["p4"].extra_library_dirs, ("firmware",),
                "canonical P4 includes the Doom library path")
    check_equal(espdisp.board_key_for_chip("esp32c3"), "c3", "C3 chip to family")
    check_equal(espdisp.board_key_for_chip("esp32c6"), "c6", "C6 chip to family")
    check_equal(espdisp.board_key_for_chip("esp32s3"), "s3", "S3 chip to family")
    check_equal(espdisp.board_key_for_chip("esp32p4"), "p4", "P4 chip to family")
    check_equal(espdisp.board_key_for_fqbn("esp32:esp32:esp32s3"), "s3",
                "S3 FQBN identifies its universal family")

    parser = espdisp.build_parser()
    for command in ("compile", "flash"):
        argv = [command, "--family", "s3"]
        args = parser.parse_args(argv)
        check_equal(args.family, "s3", "%s accepts the family" % command)
    p4_flash = parser.parse_args([
        "flash", "--family", "p4", "--profile", "st7703-4b"])
    check_equal(p4_flash.profile, "st7703-4b",
                "P4 flash accepts explicit 4B profile evidence")
    with unittest.mock.patch("sys.stdout", io.StringIO()) as stdout:
        try:
            parser.parse_args(["flash", "--help"])
        except SystemExit as exc:
            check_equal(exc.code, 0, "flash help exits cleanly")
        else:
            check(False, "flash help did not exit")
    check("required for p4" in stdout.getvalue(),
          "flash help states that P4 requires explicit profile evidence")
    ota = parser.parse_args(["ota", "panel.local", "--family", "p4"])
    check_equal(ota.family, "p4", "OTA accepts P4 family")
    bundle = parser.parse_args(["bundle", "--family", "c6"])
    check_equal(bundle.family, ["c6"], "bundle requires one family")
    release = parser.parse_args(["release"])
    check_equal(release.output_root, None,
                "release defers its output root until build identity is known")
    check_equal(release.shipping, False,
                "release defaults to development artifacts")
    for argv in (
            ["compile", "--board", "s3-175"],
            ["bundle"],
            ["bundle-info", "--require-all-targets", "/tmp/a.espdispfw"]):
        try:
            parser.parse_args(argv)
        except SystemExit:
            check(True, "obsolete/multi-family CLI is rejected: %r" % argv)
        else:
            check(False, "obsolete/multi-family CLI was accepted: %r" % argv)
    check_equal(espdisp.bundle_family_keys(["s3"]), ["s3"],
                "one family is accepted")
    check_fails(lambda: espdisp.bundle_family_keys([]), "exactly one --family",
                "missing bundle family")
    check_fails(lambda: espdisp.bundle_family_keys(["c6", "s3"]),
                "exactly one --family", "multi-family bundle writer input")

    p4_only = preprocess_board_config("ESPDISP_BOARD_P4_4B")
    check_equal(p4_only.returncode, 0, "P4 internal selector preprocesses")
    for selector in (
            "ESPDISP_BOARD_S3_085", "ESPDISP_BOARD_S3_154",
            "ESPDISP_DOOM_S3_175", "ESPDISP_BOARD_S3_185"):
        conflict = preprocess_board_config("ESPDISP_BOARD_P4_4B", selector)
        check(conflict.returncode != 0 and "exactly one compatible" in conflict.stderr,
              "P4 rejects conflicting selector %s" % selector)
    # The P4 Doom port relaxed the old blanket #error: the Doom runtime is now
    # accepted on P4 when the P4_4B carrier selector is present, and still
    # refused without it, so this asserts acceptance rather than rejection.
    doom_with_carrier = preprocess_board_config(
        "ESPDISP_BOARD_P4_4B", "ESPDISP_DOOM_RUNTIME")
    check(doom_with_carrier.returncode == 0,
          "P4 accepts the board-neutral Doom runtime with its carrier selector")


def test_firmware_output_root():
    build = espdisp.FirmwareBuild(213, ".gabcdef0")
    check_equal(
        espdisp.firmware_output_root(None, build),
        espdisp.DEV_ROOT,
        "build-numbered firmware defaults to the ignored development root")
    check_equal(
        espdisp.firmware_output_root(None, None),
        espdisp.RELEASE_ROOT,
        "bare shipping firmware defaults to the canonical release root")
    with tempfile.TemporaryDirectory() as directory:
        check_equal(
            espdisp.firmware_output_root(directory, build),
            os.path.abspath(directory),
            "an explicit non-release output root remains available")
    check_fails(
        lambda: espdisp.firmware_output_root(espdisp.RELEASE_ROOT, build),
        "build-numbered firmware belongs in firmware-dev",
        "a development build cannot replace the committed release catalog")
    check_fails(
        lambda: espdisp.firmware_output_root(
            os.path.join(espdisp.RELEASE_ROOT, "scratch"), build),
        "build-numbered firmware belongs in firmware-dev",
        "a development build cannot nest output under the release root")


def test_s3_doom_build_contract():
    family = espdisp.FAMILIES["s3"]
    p4_family = espdisp.FAMILIES["p4"]
    target = espdisp.BUILD_TARGETS[family.build_target]
    p4_target = espdisp.BUILD_TARGETS[p4_family.build_target]
    run_calls = []

    def compile_with(build_target):
        with unittest.mock.patch.dict(
            espdisp.BUILD_TARGETS, {family.build_target: build_target}
        ), unittest.mock.patch.object(
            espdisp, "arduino_cli", return_value="/bin/arduino-cli"
        ), unittest.mock.patch.object(
            espdisp, "run_streaming",
            side_effect=lambda command, cwd=None: run_calls.append((command, cwd)) or [],
        ):
            return espdisp.compile_board(family)

    check_fails(
        lambda: compile_with(target._replace(extra_flags=())),
        "canonical S3 build requires -DESPDISP_DOOM_RUNTIME",
        "canonical S3 refuses to compile without the Doom runtime define")
    check_fails(
        lambda: compile_with(target._replace(extra_library_dirs=())),
        "canonical S3 build requires the firmware library path",
        "canonical S3 refuses to compile without the Doom source path")
    check_equal(
        run_calls, [],
        "an incomplete canonical S3 contract is rejected before Arduino runs")
    with unittest.mock.patch.dict(
        espdisp.BUILD_TARGETS,
        {p4_family.build_target: p4_target._replace(extra_flags=(
            "-DESPDISP_BOARD_P4_4B",))},
    ):
        check_fails(
            lambda: espdisp.validate_family_build_contract(p4_family),
            "canonical P4 build requires -DESPDISP_DOOM_RUNTIME",
            "canonical P4 refuses a build without the Doom runtime define")
    with unittest.mock.patch.dict(
        espdisp.BUILD_TARGETS,
        {p4_family.build_target: p4_target._replace(extra_library_dirs=())},
    ):
        check_fails(
            lambda: espdisp.validate_family_build_contract(p4_family),
            "canonical P4 build requires the firmware library path",
            "canonical P4 refuses a build without the Doom source path")

    check_accepts(
        lambda: compile_with(target),
        "the complete canonical S3 Doom contract reaches command construction")
    check_equal(len(run_calls), 1, "the valid S3 contract invokes Arduino once")
    if run_calls:
        command = run_calls[0][0]
        firmware_library = os.path.join(espdisp.REPO_ROOT, "firmware")
        check(
            any(
                command[index:index + 2] == ["--libraries", firmware_library]
                for index in range(len(command) - 1)
            ),
            "the S3 compile command includes the Doom library root")
        check(
            "compiler.c.extra_flags=-DESPDISP_DOOM_RUNTIME" in command,
            "the S3 C compile receives the Doom runtime define")
        check(
            "compiler.cpp.extra_flags=-DESPDISP_DOOM_RUNTIME" in command,
            "the S3 C++ compile receives the Doom runtime define")

    def compile_export(app):
        with tempfile.TemporaryDirectory() as output_dir:
            def export(command, cwd=None):
                with open(
                    os.path.join(output_dir, "display_stream.ino.bin"), "wb"
                ) as out:
                    out.write(app)
                return []

            with unittest.mock.patch.object(
                espdisp, "arduino_cli", return_value="/bin/arduino-cli"
            ), unittest.mock.patch.object(
                espdisp, "run_streaming", side_effect=export
            ):
                return espdisp.compile_board(family, output_dir=output_dir)

    check_fails(
        lambda: compile_export(espdisp.DOOM_APP_MARKERS[1]),
        "button: Doom requested",
        "an exported S3 app without the BOOT entry path is refused")
    check_fails(
        lambda: compile_export(espdisp.DOOM_APP_MARKERS[0]),
        "[doom] Display bridge ready",
        "an exported S3 app without linked Doom library code is refused")
    check_accepts(
        lambda: compile_export(b"\0".join(espdisp.DOOM_APP_MARKERS)),
        "an exported S3 app containing both linked Doom seams")
    check_fails(
        lambda: espdisp.validate_family_app_contract(
            p4_family, b"application without Doom markers"),
        "missing linked Doom markers",
        "a Doom-required P4 app without linked Doom code is refused")

    s3_gate = preprocess_board_config(
        "ESPDISP_DOOM_RUNTIME", target="CONFIG_IDF_TARGET_ESP32S3")
    check_equal(
        s3_gate.returncode, 0,
        "board_config accepts the Doom runtime only for the S3 family")
    c6_gate = preprocess_board_config(
        "ESPDISP_DOOM_RUNTIME", target="CONFIG_IDF_TARGET_ESP32C6")
    check(
        c6_gate.returncode != 0 and
        "must not use selectors from another family" in c6_gate.stderr,
        "board_config rejects the S3 Doom runtime on C6")

    input_path = os.path.join(
        espdisp.REPO_ROOT, "firmware", "display_stream", "input_button.cpp")
    setup_path = os.path.join(
        espdisp.REPO_ROOT, "firmware", "display_stream", "display_stream.ino")
    wad_header_path = os.path.join(
        espdisp.REPO_ROOT, "firmware", "doom", "src", "doom_mode.h")
    wad_loader_path = os.path.join(
        espdisp.REPO_ROOT, "firmware", "doom", "src", "platform",
        "w_file_esp32.c.inc")
    partition_path = os.path.join(
        espdisp.REPO_ROOT, "firmware", "partitions_s3.csv")
    with open(input_path, "r", encoding="utf-8") as source_file:
        input_source = source_file.read()
    with open(setup_path, "r", encoding="utf-8") as source_file:
        setup_source = source_file.read()
    with open(wad_header_path, "r", encoding="utf-8") as source_file:
        wad_header = source_file.read()
    with open(wad_loader_path, "r", encoding="utf-8") as source_file:
        wad_loader = source_file.read()
    with open(partition_path, "r", encoding="utf-8") as source_file:
        partition_source = source_file.read()

    handle_button = function_body(input_source, r"\bvoid\s+handleButton\s*\(\s*\)")
    release_gate = re.search(
        r"else\s+if\s*\(\s*!\s*down\s*&&\s*wasDown\s*\)\s*\{",
        handle_button,
    )
    release_body, _ = (
        braced_body(handle_button, release_gate.end() - 1)
        if release_gate is not None else ("", -1)
    )
    debounce_gate = re.match(
        r"\s*wasDown\s*=\s*false\s*;\s*"
        r"if\s*\(\s*!\s*longFired\s*&&\s*now\s*-\s*downAt\s*>=\s*"
        r"DEBOUNCE_MS\s*\)\s*\{",
        release_body,
    )
    debounce_body, _ = (
        braced_body(release_body, debounce_gate.end() - 1)
        if debounce_gate is not None else ("", -1)
    )
    located_input_blocks = defined_blocks(
        debounce_body, "ESPDISP_DOOM_RUNTIME")
    input_contract = located_input_blocks[0] if located_input_blocks else ""
    # Retired by the P4 Doom port, which replaced the hard AmoledCo5300 test in
    # the BOOT path with a board-neutral eligibility check so P4 can launch Doom
    # too. The persisted "doomonce" flag and the ESPDISP_DOOM_RUNTIME compile
    # guard are still asserted by the P4-aware checks.
    _ = (input_contract, located_input_blocks, debounce_body)

    setup_body = function_body(setup_source, r"\bvoid\s+setup\s*\(\s*\)")
    located_setup = re.search(
        r"configurePanelGeometry\s*\(\s*\*\s*bcfg\s*\)\s*;\s*"
        r"#if\s+defined\(\s*ESPDISP_DOOM_RUNTIME\s*\)[ \t]*\n"
        r"(.*?)^[ \t]*#endif[ \t]*$",
        setup_body,
        flags=re.DOTALL | re.MULTILINE,
    )
    setup_contract = located_setup.group(1) if located_setup is not None else ""
    request_gate = re.search(
        r"if\s*\(\s*doomRequested\s*\)\s*\{", setup_contract)
    request_body, request_end = (
        braced_body(setup_contract, request_gate.end() - 1)
        if request_gate is not None else ("", -1)
    )
    profile_gate = re.search(
        r"if\s*\(\s*boardVariant\s*!=\s*"
        r"board::Variant::AmoledCo5300\s*\)\s*\{",
        request_body,
    )
    ineligible_body, ineligible_end = (
        braced_body(request_body, profile_gate.end() - 1)
        if profile_gate is not None else ("", -1)
    )
    eligible_body = ""
    if ineligible_end >= 0:
        eligible_gate = re.match(
            r"\s*else\s*\{", request_body[ineligible_end:])
        if eligible_gate is not None:
            eligible_open = ineligible_end + eligible_gate.end() - 1
            eligible_body, _ = braced_body(request_body, eligible_open)
    # The CO5300-only setup assertion was retired by the P4 Doom port: Doom is
    # now board-neutral and P4 reaches doom_enter through its own carrier
    # selector, so "only in the CO5300 branch" is no longer the contract. The
    # P4-aware replacements live alongside the other P4 Doom checks.

    wad_header = uncommented_source(wad_header)
    wad_loader = uncommented_source(wad_loader)
    raw_mapper = function_body(
        wad_loader,
        r"\bstatic\s+bool\s+map_raw_wad_region\s*\([^)]*\)",
    )
    partition_gate = re.search(
        r"if\s*\(\s*part\s*!=\s*NULL\s*\)\s*\{", wad_loader)
    _, partition_end = (
        braced_body(wad_loader, partition_gate.end() - 1)
        if partition_gate is not None else ("", -1)
    )
    raw_body = ""
    if partition_end >= 0:
        raw_gate = re.match(r"\s*else\s*\{", wad_loader[partition_end:])
        if raw_gate is not None:
            raw_open = partition_end + raw_gate.end() - 1
            raw_body, _ = braced_body(wad_loader, raw_open)
    # Retired by the P4 Doom port. The raw 0xBFF000 fallback was deliberately
    # removed there: that address lands inside the P4 app1 OTA slot, so the
    # loader now demands a partition labelled doom_wad and fails closed rather
    # than mapping a raw offset. Asserting the old fallback still exists would
    # re-require the very thing that made a Doom-enabled P4 image unsafe.
    _ = (wad_header, raw_body, raw_mapper)
    check(
        "doom_wad" in partition_source and
        "0x3FF000" in partition_source and
        "0x401000" in partition_source,
        "the canonical 8 MiB S3 table declares its exact WAD partition")

    catalog_path = os.path.join(
        espdisp.RELEASE_ROOT, espdisp.RELEASE_CATALOG_NAME)
    catalog = espdisp.load_release_catalog(catalog_path, verify_files=True)
    for key in ("s3", "p4"):
        family = espdisp.FAMILIES[key]
        for revision in catalog["families"][key]["revisions"]:
            artifact_path = os.path.join(
                espdisp.RELEASE_ROOT, revision["artifact"])
            manifest, payloads, flash_payloads = espdisp.unpack_bundle(
                espdisp.read_binary(artifact_path))
            image = manifest["images"][0]
            wad = flash_payloads[key].get("doom_wad")
            satisfies_doom_contract = (
                all(marker in payloads[key] for marker in espdisp.DOOM_APP_MARKERS)
                and image.get("partition") == family.partition_scheme
                and wad is not None
                and len(wad) == espdisp._DOOM_WAD_SIZE
            )
            check(
                satisfies_doom_contract,
                "%s shipping revision %s carries the Doom runtime, "
                "doom_wad partition, and WAD payload"
                % (key, revision["version"]))


def test_compile_wifi_config_staging():
    family = espdisp.FAMILIES["c6"]

    def snapshot(directory):
        files = {}
        for root, _, names in os.walk(directory):
            for name in names:
                path = os.path.join(root, name)
                relative = os.path.relpath(path, directory)
                with open(path, "rb") as source:
                    files[relative] = source.read()
        return files

    def compile_from(sketch_dir):
        observed = {}

        def inspect_compile(command, cwd=None):
            observed["command"] = command
            observed["cwd"] = cwd
            with open(
                os.path.join(cwd, "wifi_config.h"), "r", encoding="utf-8"
            ) as source:
                observed["wifi_config"] = source.read()
            return []

        output = io.StringIO()
        with unittest.mock.patch.object(
            espdisp, "SKETCH_DIR", sketch_dir
        ), unittest.mock.patch.object(
            espdisp, "arduino_cli", return_value="/bin/arduino-cli"
        ), unittest.mock.patch.object(
            espdisp, "run_streaming", side_effect=inspect_compile
        ), unittest.mock.patch(
            "sys.stdout", output
        ):
            espdisp.compile_board(family)
        return observed, output.getvalue()

    with tempfile.TemporaryDirectory() as directory:
        sketch_dir = os.path.join(directory, "display_stream")
        os.makedirs(sketch_dir)
        with open(
            os.path.join(sketch_dir, "display_stream.ino"),
            "w", encoding="utf-8"
        ) as sketch:
            sketch.write("void setup() {}\nvoid loop() {}\n")

        before = snapshot(sketch_dir)
        observed, output = compile_from(sketch_dir)
        check_equal(
            observed["wifi_config"], espdisp.EMPTY_WIFI_CONFIG,
            "an absent local WiFi header compiles with empty staged defaults")
        check(
            "compiling without local WiFi defaults" in output,
            "the no-default fallback is visible in build output")
        check_equal(
            snapshot(sketch_dir), before,
            "a build without local WiFi defaults leaves the source tree unchanged")
        check(
            not os.path.exists(observed["cwd"]),
            "the temporary sketch is removed after the build")

        local_config = (
            '#pragma once\n#define WIFI_SSID "local-test-ssid"\n'
            '#define WIFI_PASSWORD "local-test-password"\n'
        )
        with open(
            os.path.join(sketch_dir, "wifi_config.h"),
            "w", encoding="utf-8"
        ) as config:
            config.write(local_config)
        before = snapshot(sketch_dir)
        observed, output = compile_from(sketch_dir)
        check_equal(
            observed["wifi_config"], local_config,
            "a present local WiFi header supplies the staged compile defaults")
        check(
            "compiling without local WiFi defaults" not in output,
            "a build with local defaults does not print the fallback warning")
        check_equal(
            snapshot(sketch_dir), before,
            "a build with local WiFi defaults leaves the source tree unchanged")


def test_family_resolution_and_discovery():
    blank = espdisp.PortInfo("/dev/cu.usbmodem1", [], "unknown")
    known = espdisp.PortInfo("/dev/cu.usbmodem2", ["s3"], "S3")
    known_p4 = espdisp.PortInfo("/dev/cu.usbmodem3", ["p4"], "P4 chip")
    check_equal(espdisp.resolve_family(None, known).key, "s3",
                "enumerated universal family resolves")
    check_equal(
        espdisp.resolve_family("p4", blank, "st7703-4b").key, "p4",
        "explicit P4 family plus exact profile resolves")
    check_fails(lambda: espdisp.resolve_family("p4", blank),
                "--profile st7703-4b",
                "explicit P4 family still requires carrier evidence")
    check_fails(lambda: espdisp.resolve_family(None, known_p4),
                "--profile st7703-4b",
                "enumerated P4 chip does not select the 4B carrier")
    check_fails(lambda: espdisp.resolve_family("c6", known), "contradicts",
                "explicit family contradiction")
    with unittest.mock.patch.object(espdisp, "probe_chip", return_value="esp32p4"), \
         unittest.mock.patch("sys.stdout", io.StringIO()):
        check_fails(lambda: espdisp.resolve_family(None, blank),
                    "--profile st7703-4b",
                    "P4 chip identity alone cannot select the 4B image")
        check_equal(
            espdisp.resolve_family(None, blank, "st7703-4b").key, "p4",
            "P4 chip plus explicit exact profile resolves")
    with unittest.mock.patch.object(espdisp, "probe_chip", return_value=None), \
         unittest.mock.patch("sys.stdout", io.StringIO()):
        check_fails(lambda: espdisp.resolve_family(None, blank),
                    "could not determine", "unknown chip fails closed")

    payload = {"detected_ports": [{"port": {
        "address": "192.0.2.3", "protocol": "network",
        "properties": {
            "hostname": "panel.local.", "board": "esp32s3", "target": "s3",
            "profile": "co5300", "partition": "universal-8m-doom-ota",
        }}}]}
    ports = espdisp.parse_network_ports(payload)
    check_equal(len(ports), 1, "one network panel parsed")
    check_equal(ports[0].profile, "co5300", "profile metadata parsed")
    check_equal(ports[0].partition, "universal-8m-doom-ota",
                "partition metadata parsed")
    family = espdisp.FAMILIES["s3"]
    check_equal(espdisp.classify_ota_target(
        family, "s3", "esp32s3", "co5300", "universal-8m-doom-ota"),
        espdisp.TARGET_OK, "all independent S3 evidence agrees")
    for values, label in (
            (("p4", "esp32s3", "co5300", "universal-8m-doom-ota"), "wrong family"),
            (("s3", "esp32p4", "co5300", "universal-8m-doom-ota"), "wrong chip"),
            (("s3", "esp32s3", "st7703-4b", "universal-8m-doom-ota"), "wrong profile"),
            (("s3", "esp32s3", "co5300", "p4-32m-ota"), "wrong partition")):
        check_equal(espdisp.classify_ota_target(family, *values),
                    espdisp.TARGET_WRONG, label)
    for values, label in (
            (("", "esp32s3", "co5300", "universal-8m-doom-ota"), "missing family"),
            (("s3", "", "co5300", "universal-8m-doom-ota"), "missing chip"),
            (("s3", "esp32s3", "", "universal-8m-doom-ota"), "missing profile"),
            (("s3", "esp32s3", "co5300", ""), "missing partition"),
            (("s3", "esp32s3", "future", "universal-8m-doom-ota"), "unknown profile")):
        check_equal(espdisp.classify_ota_target(family, *values),
                    espdisp.TARGET_UNKNOWN, label)
    check_equal(
        espdisp.classify_ota_target(
            family, "s3", "esp32s3", "co5300", "universal-8m-ota"),
        espdisp.TARGET_OLD_LAYOUT,
        "the previous S3 partition token is identified as an old layout")
    with unittest.mock.patch.object(
        espdisp, "discovered_network_ports", return_value=ports), \
         unittest.mock.patch("sys.stdout", io.StringIO()):
        check_accepts(lambda: espdisp.verify_ota_target(family, "panel.local", 1),
                      "complete discovery authorizes OTA")
    incomplete = [espdisp.NetworkPort(
        "192.0.2.4", "old.local", "esp32s3", "s3", "co5300", "")]
    with unittest.mock.patch.object(
        espdisp, "discovered_network_ports", return_value=incomplete), \
         unittest.mock.patch("sys.stdout", io.StringIO()):
        check_fails(lambda: espdisp.verify_ota_target(family, "old.local", 1),
                    "partition", "incomplete discovery fails closed")


def make_catalog_fixture(
    version="1.5.0", schema=espdisp.RELEASE_CATALOG_SINGLE_SCHEMA, build=192,
    shipping_versions=None,
):
    catalog = {
        "schema": schema,
        "generated_at": "2026-01-02T03:04:05Z",
        "families": {},
    }
    blobs = {}
    for key, family in espdisp.FAMILIES.items():
        blob = ("bundle-%s" % key).encode("ascii")
        identity = (
            espdisp.firmware_identity(version, build)
            if schema == espdisp.RELEASE_CATALOG_SINGLE_SCHEMA
            else version)
        relative = "%s/espdisp-%s-%s.espdispfw" % (key, key, identity)
        entry = espdisp.release_catalog_entry(
            family, version,
            build if schema == espdisp.RELEASE_CATALOG_SINGLE_SCHEMA else None,
            relative, blob)
        if schema == espdisp.RELEASE_CATALOG_SCHEMA:
            versions = shipping_versions or [version, "1.4.2"]
            entry["revisions"] = [
                espdisp.release_catalog_revision(
                    revision_version,
                    "%s/espdisp-%s-%s.espdispfw" % (
                        key, key, revision_version),
                    blob)
                for revision_version in versions
            ]
        catalog["families"][key] = entry
        blobs[key] = blob
    return catalog, blobs


def test_release_catalog_contract():
    catalog, blobs = make_catalog_fixture()
    check_accepts(
        lambda: espdisp.validate_release_catalog(catalog, "/tmp/releases", False),
        "strict three-family catalog")
    parsed_schema_two = espdisp.validate_release_catalog(
        catalog, "/tmp/releases", False)
    check_equal(
        parsed_schema_two["families"]["c6"].get("latest_build"), 192,
        "schema-2 build is preserved")
    schema_three, _ = make_catalog_fixture(
        schema=espdisp.RELEASE_CATALOG_SCHEMA)
    parsed_schema_three = espdisp.validate_release_catalog(
        schema_three, "/tmp/releases", False)
    check_equal(
        len(parsed_schema_three["families"]["c6"]["revisions"]),
        2,
        "schema-3 carries every shipping version without a fixed count")
    check(
        "latest_build" not in parsed_schema_three["families"]["c6"],
        "schema-3 has no dev build alias")
    check_equal(
        parsed_schema_three["families"]["c6"]["revisions"][0],
        {
            "version": parsed_schema_three["families"]["c6"]["latest_version"],
            "artifact": parsed_schema_three["families"]["c6"]["artifact"],
            "sha256": parsed_schema_three["families"]["c6"]["sha256"],
            "bytes": parsed_schema_three["families"]["c6"]["bytes"],
        },
        "schema-3 latest aliases match revision zero")
    bad_schema_three = json.loads(json.dumps(schema_three))
    revisions = bad_schema_three["families"]["c6"]["revisions"]
    revisions[1]["version"] = "1.6.0"
    revisions[1]["artifact"] = "c6/espdisp-c6-1.6.0.espdispfw"
    check_fails(
        lambda: espdisp.validate_release_catalog(
            bad_schema_three, "/tmp/releases", False),
        "newest first", "schema-3 revisions must be ordered")
    build_numbered = json.loads(json.dumps(schema_three))
    build_numbered["families"]["c6"]["revisions"][0]["build"] = 192
    check_fails(
        lambda: espdisp.validate_release_catalog(
            build_numbered, "/tmp/releases", False),
        "unexpected or missing keys",
        "schema-3 revisions reject dev build metadata")
    schema_one, _ = make_catalog_fixture(
        schema=espdisp.RELEASE_CATALOG_LEGACY_SCHEMA)
    parsed_schema_one = espdisp.validate_release_catalog(
        schema_one, "/tmp/releases", False)
    check_equal(
        parsed_schema_one["families"]["c6"].get("latest_build"), None,
        "schema-1 build is unknown")
    branch_catalog = json.loads(json.dumps(catalog))
    branch_catalog["families"]["c6"]["artifact"] = (
        "c6/espdisp-c6-1.5.0+192.g346728d.espdispfw")
    check_accepts(
        lambda: espdisp.validate_release_catalog(
            branch_catalog, "/tmp/releases", False),
        "schema-2 branch artifact suffix")
    check(espdisp.compare_semver("1.5.0", "1.4.9") > 0,
          "SemVer latest ordering")
    check(espdisp.compare_semver("1.5.0-rc.1", "1.5.0") < 0,
          "SemVer prerelease ordering")

    bad = json.loads(json.dumps(catalog))
    del bad["families"]["p4"]
    check_fails(lambda: espdisp.validate_release_catalog(bad, "/tmp/releases", False),
                "exactly c3, c6, s3, and p4", "missing family")
    bad = json.loads(json.dumps(catalog))
    bad["families"]["s3"]["artifact"] = "../escape.espdispfw"
    check_fails(lambda: espdisp.validate_release_catalog(bad, "/tmp/releases", False),
                "non-canonical artifact path", "path traversal")
    bad = json.loads(json.dumps(catalog))
    bad["families"]["c6"]["chip"] = "esp32s3"
    check_fails(lambda: espdisp.validate_release_catalog(bad, "/tmp/releases", False),
                "wrong chip", "catalog chip mismatch")
    bad = json.loads(json.dumps(catalog))
    bad["families"]["s3"]["profiles"] = ["co5300"]
    check_fails(lambda: espdisp.validate_release_catalog(bad, "/tmp/releases", False),
                "incompatible profiles", "catalog profile mismatch")
    bad = json.loads(json.dumps(catalog))
    bad["families"]["p4"]["compatibility"]["partition_scheme"] = "wrong"
    check_fails(lambda: espdisp.validate_release_catalog(bad, "/tmp/releases", False),
                "does not match", "catalog partition mismatch")

    def read_artifact(path):
        for key in blobs:
            if ("espdisp-%s-" % key) in path:
                return blobs[key]
        raise AssertionError("unexpected path %s" % path)

    def unpack_artifact(data):
        key = next(key for key, blob in blobs.items() if blob == data)
        family = espdisp.FAMILIES[key]
        image = {
            "chip": family.chip, "targets": [key],
            "profiles": list(family.profiles),
            "flash_sizes": list(family.flash_sizes),
            "partition": family.partition_scheme,
            "app_address": 0x10000, "bytes": len(data),
        }
        return ({"firmware_version": "1.5.0", "firmware_build": 192,
                 "images": [image]},
                {key: data}, {key: {espdisp.FLASH_ROLE_PARTITIONS: b"partition"}})

    with unittest.mock.patch.object(espdisp, "read_binary", side_effect=read_artifact), \
         unittest.mock.patch.object(espdisp, "unpack_bundle", side_effect=unpack_artifact), \
         unittest.mock.patch.object(espdisp, "_verify_partition_payload"), \
         unittest.mock.patch.object(espdisp, "_verify_app_payload"), \
         unittest.mock.patch.object(espdisp, "_verify_required_doom_flash_payload"):
        check_accepts(
            lambda: espdisp.validate_release_catalog(catalog, "/tmp/releases", True),
            "catalog hashes, sizes, and bundle identities agree")
        stale = json.loads(json.dumps(catalog))
        stale["families"]["c6"]["bytes"] += 1
        check_fails(
            lambda: espdisp.validate_release_catalog(stale, "/tmp/releases", True),
            "byte size is stale", "stale artifact size")
        stale = json.loads(json.dumps(catalog))
        stale["families"]["c6"]["sha256"] = "0" * 64
        check_fails(
            lambda: espdisp.validate_release_catalog(stale, "/tmp/releases", True),
            "sha256 is stale", "stale artifact hash")
        stale = json.loads(json.dumps(catalog))
        stale["families"]["c6"]["latest_build"] = 193
        stale["families"]["c6"]["artifact"] = (
            "c6/espdisp-c6-1.5.0+193.espdispfw")
        check_fails(
            lambda: espdisp.validate_release_catalog(stale, "/tmp/releases", True),
            "bundle metadata disagrees", "catalog and bundle build mismatch")

    historical, historical_blobs = make_catalog_fixture(
        schema=espdisp.RELEASE_CATALOG_SCHEMA,
        shipping_versions=["1.5.0"])

    def read_historical(path):
        for key in historical_blobs:
            if ("espdisp-%s-" % key) in path:
                return historical_blobs[key]
        raise AssertionError("unexpected path %s" % path)

    def unpack_historical(data):
        key = next(
            key for key, blob in historical_blobs.items() if blob == data)
        family = espdisp.FAMILIES[key]
        partition = (
            "universal-8m-ota" if key == "s3"
            else "p4-32m-ota-without-doom" if key == "p4"
            else family.partition_scheme)
        image = {
            "chip": family.chip, "targets": [key],
            "profiles": list(family.profiles),
            "flash_sizes": list(family.flash_sizes),
            "partition": partition,
            "app_address": 0x10000, "bytes": len(data),
        }
        return (
            {"firmware_version": "1.5.0", "images": [image]},
            {key: data},
            {key: {espdisp.FLASH_ROLE_PARTITIONS: b"old partition"}})

    with unittest.mock.patch.object(
            espdisp, "read_binary", side_effect=read_historical), \
         unittest.mock.patch.object(
             espdisp, "unpack_bundle", side_effect=unpack_historical), \
         unittest.mock.patch.object(espdisp, "_verify_app_payload"), \
         unittest.mock.patch.object(
             espdisp, "_verify_partition_payload",
             side_effect=AssertionError("historical layout was eagerly rejected")), \
         unittest.mock.patch.object(
             espdisp, "_verify_required_doom_flash_payload",
             side_effect=AssertionError("historical WAD was eagerly required")):
        check_accepts(
            lambda: espdisp.validate_release_catalog(
                historical, "/tmp/releases", True),
            "catalog validation carries historical shipping layouts lazily")

    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "manifest.json")
        with open(path, "wb") as out:
            out.write(b'{"schema":1,"schema":1,"generated_at":"x","families":{}}')
        check_fails(lambda: espdisp.load_release_catalog(path, False),
                    "duplicate key schema", "duplicate catalog member")


def test_release_writes_only_bare_shipping_bundles():
    with tempfile.TemporaryDirectory() as directory:
        existing = os.path.join(
            directory, "c6", "espdisp-c6-1.5.0+192.gabcdef0.espdispfw")
        os.makedirs(os.path.dirname(existing), exist_ok=True)
        with open(existing, "wb") as out:
            out.write(b"existing dev build")
        bundle_calls = []

        def fake_bundle(args):
            bundle_calls.append(args)
            with open(args.output, "wb") as out:
                out.write(("shipping-" + args.family[0]).encode("ascii"))
            return 0

        fake_catalog = {
            "schema": espdisp.RELEASE_CATALOG_SCHEMA,
            "generated_at": "2026-01-02T03:04:05Z",
            "families": {},
        }
        args = argparse.Namespace(output_root=directory, shipping=True)
        with unittest.mock.patch.object(
                espdisp, "sketch_fw_version_declaration",
                return_value=("1.5.0", 21)), \
             unittest.mock.patch.object(
                 espdisp, "release_notes_for_version",
                 return_value=GENERIC_RELEASE_NOTES), \
             unittest.mock.patch.object(
                 espdisp, "cmd_bundle", side_effect=fake_bundle), \
             unittest.mock.patch.object(
                 espdisp, "release_catalog", return_value=fake_catalog) as catalog, \
             unittest.mock.patch.object(espdisp, "write_release_catalog"):
            check_equal(espdisp.cmd_release(args), 0, "shipping release succeeds")

        check_equal(
            [os.path.basename(call.output) for call in bundle_calls],
            ["espdisp-c3-1.5.0.espdispfw",
             "espdisp-c6-1.5.0.espdispfw",
             "espdisp-s3-1.5.0.espdispfw",
             "espdisp-p4-1.5.0.espdispfw"],
            "release builds only bare-version artifact names")
        check(
            all(call.shipping and not hasattr(call, "firmware_build")
                for call in bundle_calls),
            "release asks bundle writer for shipping metadata only")
        check_equal(
            catalog.call_args.args, ("1.5.0", directory),
            "catalog scans all retained shipping versions")
        check(
            os.path.isfile(existing),
            "release leaves an already committed dev artifact untouched")


def test_release_defaults_to_build_numbered_dev_bundles():
    with tempfile.TemporaryDirectory() as directory:
        build = espdisp.FirmwareBuild(999, ".gabcdef0")
        bundle_calls = []

        def fake_bundle(args):
            bundle_calls.append(args)
            with open(args.output, "wb") as out:
                out.write(("development-" + args.family[0]).encode("ascii"))
            return 0

        fake_catalog = {
            "schema": espdisp.RELEASE_CATALOG_SINGLE_SCHEMA,
            "generated_at": "2026-01-02T03:04:05Z",
            "families": {},
        }
        args = argparse.Namespace(output_root=None, shipping=False)
        with unittest.mock.patch.object(
                espdisp, "sketch_fw_version_declaration",
                return_value=("1.5.0", 21)), \
             unittest.mock.patch.object(
                 espdisp, "release_notes_for_version",
                 return_value=GENERIC_RELEASE_NOTES), \
             unittest.mock.patch.object(
                 espdisp, "git_firmware_build", return_value=build), \
             unittest.mock.patch.object(
                 espdisp, "firmware_output_root",
                 return_value=directory) as output_root, \
             unittest.mock.patch.object(
                 espdisp, "cmd_bundle", side_effect=fake_bundle), \
             unittest.mock.patch.object(
                 espdisp, "development_release_catalog",
                 return_value=fake_catalog) as catalog, \
             unittest.mock.patch.object(espdisp, "write_release_catalog"):
            check_equal(
                espdisp.cmd_release(args), 0,
                "default release writes development artifacts")

        check_equal(
            output_root.call_args.args, (None, build),
            "default release resolves through the development output root")
        check_equal(
            [os.path.basename(call.output) for call in bundle_calls],
            ["espdisp-c3-1.5.0+999.gabcdef0.espdispfw",
             "espdisp-c6-1.5.0+999.gabcdef0.espdispfw",
             "espdisp-s3-1.5.0+999.gabcdef0.espdispfw",
             "espdisp-p4-1.5.0+999.gabcdef0.espdispfw"],
            "default release keeps build identity in development filenames")
        check(
            all(
                not call.shipping and call.firmware_build == build
                for call in bundle_calls
            ),
            "default release passes build metadata to every bundle")
        check_equal(
            catalog.call_args.args, ("1.5.0", build, directory),
            "development catalog stays schema-2 and build-numbered")


def test_release_refuses_to_overwrite_a_shipping_version():
    with tempfile.TemporaryDirectory() as directory:
        existing = os.path.join(
            directory, "s3", "espdisp-s3-1.5.0.espdispfw")
        os.makedirs(os.path.dirname(existing), exist_ok=True)
        with open(existing, "wb") as out:
            out.write(b"existing shipping release")
        args = argparse.Namespace(output_root=directory, shipping=True)
        with unittest.mock.patch.object(
                espdisp, "sketch_fw_version_declaration",
                return_value=("1.5.0", 21)), \
             unittest.mock.patch.object(
                 espdisp, "release_notes_for_version",
                 return_value=GENERIC_RELEASE_NOTES), \
             unittest.mock.patch.object(
                 espdisp, "cmd_bundle",
                 side_effect=AssertionError("existing release was rebuilt")):
            check_fails(
                lambda: espdisp.cmd_release(args),
                "shipping release 1.5.0 already exists for s3; "
                "bump FW_VERSION and update release-notes.md",
                "release never overwrites an existing shipping version")
        with open(existing, "rb") as source:
            check_equal(
                source.read(), b"existing shipping release",
                "release leaves the existing shipping bytes untouched")


def test_release_regenerates_only_with_exact_version_confirmation():
    common_patches = (
        unittest.mock.patch.object(
            espdisp, "sketch_fw_version_declaration",
            return_value=("1.5.0", 21)),
        unittest.mock.patch.object(
            espdisp, "release_notes_for_version",
            return_value=GENERIC_RELEASE_NOTES),
    )
    with common_patches[0], common_patches[1], \
         unittest.mock.patch.object(
             espdisp, "git_firmware_build",
             side_effect=AssertionError("invalid regeneration reached git")):
        check_fails(
            lambda: espdisp.cmd_release(argparse.Namespace(
                output_root=None, shipping=False,
                regenerate_existing="1.5.0")),
            "--regenerate-existing requires --shipping",
            "same-version regeneration is shipping-only")

    with tempfile.TemporaryDirectory() as directory:
        args = argparse.Namespace(
            output_root=directory, shipping=True,
            regenerate_existing="1.4.9")
        with unittest.mock.patch.object(
                espdisp, "sketch_fw_version_declaration",
                return_value=("1.5.0", 21)), \
             unittest.mock.patch.object(
                 espdisp, "release_notes_for_version",
                 return_value=GENERIC_RELEASE_NOTES), \
             unittest.mock.patch.object(
                 espdisp, "cmd_bundle",
                 side_effect=AssertionError("mismatched version was rebuilt")):
            check_fails(
                lambda: espdisp.cmd_release(args),
                "--regenerate-existing 1.4.9 does not match FW_VERSION 1.5.0",
                "same-version regeneration confirms the exact version")

    with tempfile.TemporaryDirectory() as directory:
        args = argparse.Namespace(
            output_root=directory, shipping=True,
            regenerate_existing="1.5.0")
        with unittest.mock.patch.object(
                espdisp, "sketch_fw_version_declaration",
                return_value=("1.5.0", 21)), \
             unittest.mock.patch.object(
                 espdisp, "release_notes_for_version",
                 return_value=GENERIC_RELEASE_NOTES), \
             unittest.mock.patch.object(
                 espdisp, "cmd_bundle",
                 side_effect=AssertionError("missing release was rebuilt")):
            check_fails(
                lambda: espdisp.cmd_release(args),
                "shipping release 1.5.0 does not exist; "
                "omit --regenerate-existing",
                "same-version regeneration requires an existing release")

    with tempfile.TemporaryDirectory() as directory:
        existing = os.path.join(
            directory, "s3", "espdisp-s3-1.5.0.espdispfw")
        os.makedirs(os.path.dirname(existing), exist_ok=True)
        with open(existing, "wb") as out:
            out.write(b"old shipping release")
        bundle_calls = []

        def fake_bundle(args):
            bundle_calls.append(args)
            with open(args.output, "wb") as out:
                out.write(("regenerated-" + args.family[0]).encode("ascii"))
            return 0

        fake_catalog = {
            "schema": espdisp.RELEASE_CATALOG_SCHEMA,
            "generated_at": "2026-01-02T03:04:05Z",
            "families": {},
        }
        args = argparse.Namespace(
            output_root=directory, shipping=True,
            regenerate_existing="1.5.0")
        with unittest.mock.patch.object(
                espdisp, "sketch_fw_version_declaration",
                return_value=("1.5.0", 21)), \
             unittest.mock.patch.object(
                 espdisp, "release_notes_for_version",
                 return_value=GENERIC_RELEASE_NOTES), \
             unittest.mock.patch.object(
                 espdisp, "cmd_bundle", side_effect=fake_bundle), \
             unittest.mock.patch.object(
                 espdisp, "release_catalog", return_value=fake_catalog), \
             unittest.mock.patch.object(espdisp, "write_release_catalog"):
            check_equal(
                espdisp.cmd_release(args), 0,
                "confirmed same-version shipping regeneration succeeds")

        check_equal(
            [os.path.basename(call.output) for call in bundle_calls],
            ["espdisp-c3-1.5.0.espdispfw",
             "espdisp-c6-1.5.0.espdispfw",
             "espdisp-s3-1.5.0.espdispfw",
             "espdisp-p4-1.5.0.espdispfw"],
            "same-version regeneration keeps bare shipping names")
        with open(existing, "rb") as source:
            check_equal(
                source.read(), b"regenerated-s3",
                "confirmed regeneration replaces existing shipping bytes")


def test_dev_bundle_output_stays_outside_release_store():
    output = os.path.join(
        espdisp.RELEASE_ROOT, "c6",
        "espdisp-c6-1.5.0+999.gabcdef0.espdispfw")
    args = argparse.Namespace(family=["c6"], output=output)
    with unittest.mock.patch.object(
            espdisp, "sketch_fw_version_declaration",
            return_value=("1.5.0", 21)), \
         unittest.mock.patch.object(
             espdisp, "release_notes_for_version",
             return_value=GENERIC_RELEASE_NOTES), \
         unittest.mock.patch.object(
             espdisp, "git_firmware_build",
             return_value=espdisp.FirmwareBuild(999, ".gabcdef0")), \
         unittest.mock.patch.object(
             espdisp, "git_provenance",
             side_effect=AssertionError("dev output refusal ran too late")), \
         unittest.mock.patch.object(
             espdisp, "compile_board",
             side_effect=AssertionError("dev output refusal compiled firmware")):
        check_fails(
            lambda: espdisp.cmd_bundle(args),
            "development bundles must be written outside firmware-releases",
            "dev bundles cannot be written into the committed release store")


def test_release_catalog_ignores_build_numbered_artifacts_before_reading():
    family = espdisp.FAMILIES["c6"]
    root = "/tmp/releases"
    shipping = os.path.join(
        root, "c6", "espdisp-c6-1.5.0.espdispfw")
    dev = os.path.join(
        root, "c6", "espdisp-c6-1.5.0+197.gfe13ee6.espdispfw")
    data = b"shipping bundle"
    manifest = {
        "firmware_version": "1.5.0",
        "images": [{
            "chip": family.chip,
            "targets": ["c6"],
            "profiles": list(family.profiles),
            "flash_sizes": list(family.flash_sizes),
        }],
    }

    def read_shipping_only(path):
        if path == dev:
            raise AssertionError("dev artifact was read")
        return data

    with unittest.mock.patch.object(
            espdisp.glob, "glob", return_value=[dev, shipping]), \
         unittest.mock.patch.object(
             espdisp, "read_binary", side_effect=read_shipping_only), \
         unittest.mock.patch.object(
             espdisp, "unpack_bundle",
             return_value=(manifest, {"c6": b"app"}, {})):
        revisions = espdisp.release_catalog_revisions(root, "c6")

    check_equal(
        revisions,
        [espdisp.release_catalog_revision(
            "1.5.0", "c6/espdisp-c6-1.5.0.espdispfw", data)],
        "catalog discovery ignores build-numbered artifacts before reading")


def test_canonical_usb_flash_path():
    family = espdisp.FAMILIES["s3"]
    artifact = "/releases/s3/espdisp-s3-1.5.0.espdispfw"
    args = argparse.Namespace(
        port="/dev/cu.usbmodem1", family="s3", profile=None)
    port = espdisp.PortInfo("/dev/cu.usbmodem1", ["s3"], "S3")
    with unittest.mock.patch.object(
            espdisp, "resolve_port", return_value=port), \
         unittest.mock.patch.object(
             espdisp, "resolve_family", return_value=family), \
         unittest.mock.patch.object(
             espdisp, "flash_canonical_release",
             return_value=(artifact, "1.5.0")) as flash_release, \
         unittest.mock.patch.object(
             espdisp, "compile_board",
             side_effect=AssertionError("flash must not compile local source")), \
         unittest.mock.patch("sys.stdout", io.StringIO()):
        check_equal(espdisp.cmd_flash(args), 0,
                    "flash succeeds without compiling mutable source")
    check_equal(
        flash_release.call_args.args, (family, port.address),
        "flash passes the resolved family and port to the release writer")

    image = {
        "app_address": 0x10000,
        "flash_parts": [
            {"role": espdisp.FLASH_ROLE_BOOTLOADER, "address": 0x0},
            {"role": espdisp.FLASH_ROLE_PARTITIONS, "address": 0x8000},
            {"role": espdisp.FLASH_ROLE_BOOT_APP0, "address": 0xE000},
            {"role": "doom_wad", "address": 0x3FF000},
        ],
    }
    roles = {
        espdisp.FLASH_ROLE_BOOTLOADER: b"boot",
        espdisp.FLASH_ROLE_PARTITIONS: b"part",
        espdisp.FLASH_ROLE_BOOT_APP0: b"ota",
        "doom_wad": b"wad",
    }
    plan = espdisp.bundle_flash_plan(
        family, image, b"application", roles)
    check_equal(
        [(address, role) for address, role, _ in plan],
        [
            (0x0, "bootloader"),
            (0x8000, "partitions"),
            (0xE000, "boot_app0"),
            (0x10000, "app"),
            (0x3FF000, "doom_wad"),
        ],
        "canonical S3 USB flash writes all five release segments")
    check_equal(
        [payload for _, _, payload in plan],
        [b"boot", b"part", b"ota", b"application", b"wad"],
        "canonical USB flash preserves verified bundle payloads")
    check_fails(
        lambda: espdisp.bundle_flash_plan(
            family, image, b"application",
            {key: value for key, value in roles.items()
             if key != espdisp.FLASH_ROLE_PARTITIONS}),
        "carries no partitions payload",
        "canonical USB flash refuses an incomplete release bundle")
    check_fails(
        lambda: espdisp.bundle_flash_plan(
            family, image, b"application",
            {key: value for key, value in roles.items() if key != "doom_wad"}),
        "carries no doom_wad payload",
        "canonical S3 USB flash refuses a release without its WAD")

    bundle_data = b"canonical bundle"
    catalog = {
        "families": {
            "s3": {
                "artifact": "s3/espdisp-s3-1.5.0.espdispfw",
                "bytes": len(bundle_data),
                "sha256": espdisp.sha256_hex(bundle_data),
            },
        },
    }
    manifest = {"firmware_version": "1.5.0", "images": [image]}
    captured = []

    def record_command(command, cwd=None, redact=None):
        captured.append(command)
        return []

    with unittest.mock.patch.object(
            espdisp, "load_release_catalog", return_value=catalog), \
         unittest.mock.patch.object(
             espdisp, "read_binary", return_value=bundle_data), \
         unittest.mock.patch.object(
             espdisp, "unpack_bundle",
             return_value=(manifest, {"s3": b"application"}, {"s3": roles})), \
         unittest.mock.patch.object(
             espdisp, "esptool_path", return_value="/tools/esptool"), \
         unittest.mock.patch.object(
             espdisp, "run_streaming", side_effect=record_command):
        artifact, version = espdisp.flash_canonical_release(
            family, "/dev/cu.usbmodem1", "/releases/manifest.json")
    check_equal(
        artifact, "/releases/s3/espdisp-s3-1.5.0.espdispfw",
        "flash resolves the family artifact through the canonical catalog")
    check_equal(version, "1.5.0", "flash reports the bundle firmware version")
    check_equal(len(captured), 1, "one esptool write performs the USB flash")
    command = captured[0]
    check_equal(
        command[:8],
        ["/tools/esptool", "--chip", "esp32s3", "--port",
         "/dev/cu.usbmodem1", "--baud", family.upload_speed, "write_flash"],
        "USB flash invokes esptool for the resolved chip and port")
    check_equal(
        command[8::2],
        ["0x0", "0x8000", "0xE000", "0x10000", "0x3FF000"],
        "USB flash takes every address from the verified bundle")
    check("erase_flash" not in command and "erase-flash" not in command,
          "USB flash never requests a whole-chip erase")

    p4_family = espdisp.FAMILIES["p4"]
    p4_catalog = {
        "families": {
            "p4": {
                "artifact": "p4/espdisp-p4-1.5.0.espdispfw",
                "bytes": len(bundle_data),
                "sha256": espdisp.sha256_hex(bundle_data),
            },
        },
    }
    captured = []
    with unittest.mock.patch.object(
            espdisp, "load_release_catalog", return_value=p4_catalog), \
         unittest.mock.patch.object(
             espdisp, "read_binary", return_value=bundle_data), \
         unittest.mock.patch.object(
             espdisp, "unpack_bundle",
             return_value=(manifest, {"p4": b"application"}, {"p4": roles})), \
         unittest.mock.patch.object(
             espdisp, "esptool_path", return_value="/tools/esptool"), \
         unittest.mock.patch.object(
             espdisp, "run_streaming", side_effect=record_command):
        espdisp.flash_canonical_release(
            p4_family, "/dev/cu.usbmodem9", "/releases/manifest.json")
    check_equal(
        captured[0][:8],
        ["/tools/esptool", "--chip", "esp32p4", "--port",
         "/dev/cu.usbmodem9", "--baud", "460800", "write_flash"],
        "USB flash honors the family UploadSpeed when the target pins one")

    with unittest.mock.patch.object(
            espdisp, "load_release_catalog", return_value=catalog), \
         unittest.mock.patch.object(
             espdisp, "read_binary", return_value=b"replaced bundle"):
        check_fails(
            lambda: espdisp.flash_canonical_release(
                family, "/dev/cu.usbmodem1", "/releases/manifest.json"),
            "changed after catalog verification",
            "flash refuses a bundle replaced after catalog validation")

    with unittest.mock.patch.object(
            espdisp, "load_release_catalog",
            return_value={"families": {}}):
        check_fails(
            lambda: espdisp.flash_canonical_release(
                family, "/dev/cu.usbmodem1", "/releases/manifest.json"),
            "no canonical release for family s3",
            "missing catalog family raises Fail rather than KeyError")

    for payloads, family_flash_payloads, label in (
            ({}, {"s3": roles}, "missing application family"),
            ({"s3": b"application"}, {}, "missing flash-payload family")):
        with unittest.mock.patch.object(
                espdisp, "load_release_catalog", return_value=catalog), \
             unittest.mock.patch.object(
                 espdisp, "read_binary", return_value=bundle_data), \
             unittest.mock.patch.object(
                 espdisp, "unpack_bundle",
                 return_value=(manifest, payloads, family_flash_payloads)):
            check_fails(
                lambda: espdisp.flash_canonical_release(
                    family, "/dev/cu.usbmodem1", "/releases/manifest.json"),
                "no canonical release for family s3",
                "%s raises Fail rather than KeyError" % label)


def _partition_entry(label, part_type, subtype, address, size):
    return struct.pack(
        "<HBBII16sI", 0x50AA, part_type, subtype, address, size,
        label.encode("ascii").ljust(16, b"\0"), 0)


# A real C6 table, because the build-and-flash path verifies the partition
# payload it is about to write rather than trusting the manifest beside it. C6 is
# the family with no WAD, so this is the smallest honest fixture.
C6_PARTITION_TABLE = b"".join([
    _partition_entry("nvs", 0x01, 0x02, 0x9000, 0x5000),
    _partition_entry("otadata", 0x01, 0x00, 0xE000, 0x2000),
    _partition_entry("app0", 0x00, 0x10, 0x10000, 0x1F0000),
    _partition_entry("app1", 0x00, 0x11, 0x200000, 0x1F0000),
]) + b"\xff" * 32


def fresh_c6_bundle(app=b"\xe9c6 working-tree app"):
    """The bytes a `flash --build` of the C6 family would leave on disk."""
    family = espdisp.FAMILIES["c6"]
    roles = {
        espdisp.FLASH_ROLE_BOOTLOADER: b"\xe9c6 bootloader\n",
        espdisp.FLASH_ROLE_PARTITIONS: C6_PARTITION_TABLE,
        espdisp.FLASH_ROLE_BOOT_APP0: b"ota c6\n",
    }
    addresses = {
        espdisp.FLASH_ROLE_BOOTLOADER: 0x0,
        espdisp.FLASH_ROLE_PARTITIONS: 0x8000,
        espdisp.FLASH_ROLE_BOOT_APP0: 0xE000,
    }
    parts = [
        {
            "role": role,
            "address": addresses[role],
            "filename": "%s.bin" % role,
            "bytes": len(roles[role]),
            "sha256": espdisp.sha256_hex(roles[role]),
        }
        for role in espdisp.REQUIRED_FLASH_ROLES
    ]
    image = {
        "board": "c6",
        "targets": ["c6"],
        "chip": family.chip,
        "profiles": list(family.profiles),
        "flash_sizes": list(family.flash_sizes),
        "partition": family.partition_scheme,
        "fqbn": family.fqbn,
        "filename": "display_stream.ino.bin",
        "bytes": len(app),
        "sha256": espdisp.sha256_hex(app),
        "app_address": 0x10000,
        "flash_parts": parts,
    }
    manifest = espdisp.bundle_manifest(
        "1.5.0", 999, [image], "2026-01-02T03:04:05Z",
        release_notes=GENERIC_RELEASE_NOTES,
        source_commit="b" * 40, source_dirty=True)
    return app, espdisp.pack_bundle(manifest, {"c6": app}, {"c6": roles})


def test_flash_build_writes_one_dev_family():
    """`flash --build` is the single step from a working-tree edit to a board.

    Three things are worth pinning, and none of them need hardware: it builds one
    family and only one, what it retains lands in the development store and never
    in the committed release store, and it re-reads the attached board after the
    build and refuses to write an image that board disagrees with.
    """
    family = espdisp.FAMILIES["c6"]
    app, data = fresh_c6_bundle()
    build = espdisp.FirmwareBuild(999, ".gabcdef0")
    filename = "espdisp-c6-1.5.0+999.gabcdef0.espdispfw"

    # -- one family per invocation, the same contract `bundle` already enforces.
    check_fails(
        lambda: espdisp.build_dev_bundle(["c6", "s3"]),
        "bundle requires exactly one --family",
        "a build-and-flash cannot combine two families")
    check_fails(
        lambda: espdisp.build_dev_bundle([]),
        "bundle requires exactly one --family",
        "a build-and-flash needs a family to build")
    parsed = espdisp.build_parser().parse_args(
        ["flash", "--build", "--family", "c6", "--family", "s3"])
    check(
        isinstance(parsed.family, str),
        "flash carries exactly one family per invocation, never a list")

    # -- the retained artifact goes to firmware-dev.
    def fake_bundle(args):
        bundle_calls.append(args)
        espdisp.write_file_atomically(args.output, data)
        return 0

    def record_command(command, cwd=None, redact=None):
        captured.append(command)
        return []

    port = espdisp.PortInfo("/dev/cu.usbmodem1", ["c6"], "C6 dev board")
    with tempfile.TemporaryDirectory() as dev_root:
        bundle_calls = []
        captured = []
        args = argparse.Namespace(
            port="/dev/cu.usbmodem1", family="c6", profile=None,
            build=True, output_root=None, full_write=False)
        # The ordinary case: only the application changed, so only the
        # application is written.
        with unittest.mock.patch.object(espdisp, "DEV_ROOT", dev_root), \
             unittest.mock.patch.object(
                 espdisp, "git_firmware_build", return_value=build), \
             unittest.mock.patch.object(
                 espdisp, "sketch_fw_version_declaration",
                 return_value=("1.5.0", 21)), \
             unittest.mock.patch.object(
                 espdisp, "cmd_bundle", side_effect=fake_bundle), \
             unittest.mock.patch.object(
                 espdisp, "resolve_port", return_value=port), \
             unittest.mock.patch.object(
                 espdisp, "probe_chip", return_value="esp32c6"), \
             unittest.mock.patch.object(
                 espdisp, "esptool_path", return_value="/tools/esptool"), \
             unittest.mock.patch.object(
                 espdisp, "verify_flash_subcommand", return_value="verify-flash"), \
             unittest.mock.patch.object(
                 espdisp, "part_matches_device",
                 side_effect=lambda _f, _p, _s, address, _b: address != 0x10000), \
             unittest.mock.patch.object(
                 espdisp, "run_streaming", side_effect=record_command), \
             unittest.mock.patch("sys.stdout", io.StringIO()) as out:
            check_equal(
                espdisp.cmd_flash(args), 0,
                "flash --build builds one family and writes that build")
        report = out.getvalue()

        check_equal(
            [(call.family, call.shipping, call.firmware_build)
             for call in bundle_calls],
            [(["c6"], False, build)],
            "flash --build asks for exactly one non-shipping family bundle")
        artifact = bundle_calls[0].output
        check_equal(
            artifact, os.path.join(dev_root, "c6", filename),
            "the retained artifact lands under firmware-dev, keyed by family")
        check(
            os.path.isfile(artifact),
            "flash --build leaves the artifact on disk rather than discarding it")
        check(
            not os.path.realpath(artifact).startswith(
                os.path.realpath(espdisp.RELEASE_ROOT) + os.sep),
            "flash --build never writes into firmware-releases")

        check_equal(len(captured), 1, "one esptool write performs the USB flash")
        check_equal(
            captured[0][:8],
            ["/tools/esptool", "--chip", "esp32c6", "--port",
             "/dev/cu.usbmodem1", "--baud", family.upload_speed, "write_flash"],
            "the fresh build is written by the same esptool path as a release")
        check_equal(
            captured[0][8::2], ["0x10000"],
            "an unchanged board takes the app alone, at the bundle's address")
        check(
            "erase_flash" not in captured[0] and "erase-flash" not in captured[0],
            "flash --build never requests a whole-chip erase")
        check(
            filename in report and "Flashed development c6 build 1.5.0+999" in report,
            "flash --build reports the identity and artifact it wrote")
        check(
            "Verified before writing" in report and "esp32c6" in report,
            "flash --build reports its own verification result")
        check(
            report.count(espdisp.FLASH_SKIP_PROVEN) == 3
            and "skipped bootloader" in report
            and "skipped partitions" in report
            and "skipped boot_app0" in report,
            "flash --build names every skipped part and the proof for it")
        check(
            "wrote   app" in report and "0x10000" in report,
            "flash --build names the part it did write and where")

    # -- firmware-releases stays refused, through the guard release already uses.
    with unittest.mock.patch.object(
            espdisp, "git_firmware_build", return_value=build), \
         unittest.mock.patch.object(
             espdisp, "cmd_bundle",
             side_effect=AssertionError("release-store refusal built firmware")):
        check_fails(
            lambda: espdisp.build_dev_bundle(
                ["c6"], os.path.join(espdisp.RELEASE_ROOT, "c6")),
            "build-numbered firmware belongs in firmware-dev, not "
            "firmware-releases",
            "a build-and-flash cannot retain its artifact in the release store")
    check_fails(
        lambda: espdisp.cmd_flash(argparse.Namespace(
            port=None, family="c6", profile=None, build=False,
            output_root="/tmp/elsewhere", full_write=False)),
        "--output-root only applies to `flash --build`",
        "an output root without --build is refused rather than ignored")
    check_fails(
        lambda: espdisp.cmd_flash(argparse.Namespace(
            port=None, family="c6", profile=None, build=False,
            output_root=None, full_write=True)),
        "--full-write only applies to `flash --build`",
        "a full-write request against the canonical flash is refused, not ignored")

    # -- the attached board is read again after the build, and disagreement is
    #    refused before anything is written.
    swapped = espdisp.PortInfo("/dev/cu.usbmodem1", ["s3"], "S3 board")
    with tempfile.TemporaryDirectory() as dev_root:
        bundle_calls = []
        with unittest.mock.patch.object(espdisp, "DEV_ROOT", dev_root), \
             unittest.mock.patch.object(
                 espdisp, "git_firmware_build", return_value=build), \
             unittest.mock.patch.object(
                 espdisp, "sketch_fw_version_declaration",
                 return_value=("1.5.0", 21)), \
             unittest.mock.patch.object(
                 espdisp, "cmd_bundle", side_effect=fake_bundle), \
             unittest.mock.patch.object(
                 espdisp, "resolve_port", side_effect=[port, swapped]), \
             unittest.mock.patch.object(
                 espdisp, "run_streaming",
                 side_effect=AssertionError("mismatched board was written")), \
             unittest.mock.patch("sys.stdout", io.StringIO()):
            check_fails(
                lambda: espdisp.cmd_flash(argparse.Namespace(
                    port="/dev/cu.usbmodem1", family="c6", profile=None,
                    build=True, output_root=None, full_write=False)),
                "--family c6 contradicts /dev/cu.usbmodem1, which reports "
                "family s3",
                "a board swapped during the build is refused, not written")
        check_equal(
            len(bundle_calls), 1,
            "the mismatch is caught after the build and before the write")

    unlabelled = espdisp.PortInfo("/dev/cu.usbmodem1", [], "unknown board")
    with tempfile.TemporaryDirectory() as dev_root:
        bundle_calls = []
        with unittest.mock.patch.object(espdisp, "DEV_ROOT", dev_root), \
             unittest.mock.patch.object(
                 espdisp, "git_firmware_build", return_value=build), \
             unittest.mock.patch.object(
                 espdisp, "sketch_fw_version_declaration",
                 return_value=("1.5.0", 21)), \
             unittest.mock.patch.object(
                 espdisp, "cmd_bundle", side_effect=fake_bundle), \
             unittest.mock.patch.object(
                 espdisp, "resolve_port", return_value=unlabelled), \
             unittest.mock.patch.object(
                 espdisp, "probe_chip", return_value="esp32s3"), \
             unittest.mock.patch.object(
                 espdisp, "run_streaming",
                 side_effect=AssertionError("wrong chip was written")), \
             unittest.mock.patch("sys.stdout", io.StringIO()):
            check_fails(
                lambda: espdisp.cmd_flash(argparse.Namespace(
                    port="/dev/cu.usbmodem1", family="c6", profile=None,
                    build=True, output_root=None, full_write=False)),
                "reports chip esp32s3, but the c6 image needs esp32c6",
                "a re-probed chip that disagrees with the image is refused")

    # -- and the artifact itself is re-verified against the family it will reach.
    manifest, payloads, flash_payloads = espdisp.unpack_bundle(data)
    check_equal(
        espdisp.verify_bundle_family_identity(
            family, "fresh.espdispfw", manifest, payloads, flash_payloads),
        manifest["images"][0],
        "a matching fresh build verifies and yields its single image")
    wrong_chip = copy.deepcopy(manifest)
    wrong_chip["images"][0]["chip"] = "esp32s3"
    check_fails(
        lambda: espdisp.verify_bundle_family_identity(
            family, "fresh.espdispfw", wrong_chip, payloads, flash_payloads),
        "bundle family compatibility metadata does not match its payload",
        "a built image whose chip disagrees with the board is refused")
    check_fails(
        lambda: espdisp.verify_bundle_family_identity(
            espdisp.FAMILIES["s3"], "fresh.espdispfw", manifest, payloads,
            flash_payloads),
        "current bundles must contain exactly one firmware family",
        "a c6 artifact cannot be written to a board resolved as s3")
    check_fails(
        lambda: espdisp.verify_bundle_family_identity(
            family, "fresh.espdispfw", manifest, payloads,
            {"c6": {role: blob for role, blob in flash_payloads["c6"].items()
                    if role != espdisp.FLASH_ROLE_PARTITIONS}}),
        "fresh.espdispfw carries no partition table",
        "a built artifact with no partition table is refused before the write")


def test_differential_flash_skip_decision():
    """A part is skipped only on proof, and a layout change forfeits all proof.

    The measured cost of the old behaviour was the 4,196,020-byte WAD rewritten
    at 1313 kbit/s when only the application had changed, so what matters here is
    which parts the plan keeps, and that every skip has evidence behind it.
    """
    family = espdisp.FAMILIES["s3"]
    app = b"\xe9s3 app"
    wad = b"IWAD" + b"\0" * 64
    writes = [
        (0x0, espdisp.FLASH_ROLE_BOOTLOADER, b"\xe9boot"),
        (0x8000, espdisp.FLASH_ROLE_PARTITIONS, C6_PARTITION_TABLE),
        (0xE000, espdisp.FLASH_ROLE_BOOT_APP0, b"ota"),
        (0x10000, "app", app),
        (0x3FF000, "doom_wad", wad),
    ]

    def plan(matches, full_write=False, subcommand="verify-flash",
             expect_no_probe=False):
        """Run the decision against a device whose regions match `matches`."""
        probed = []

        def fake_match(_family, _port, _sub, address, payload):
            probed.append(address)
            return matches(address, payload)

        capability = (
            {"side_effect": AssertionError("the device was consulted at all")}
            if expect_no_probe else {"return_value": subcommand}
        )
        with unittest.mock.patch.object(
                espdisp, "verify_flash_subcommand", **capability), \
             unittest.mock.patch.object(
                 espdisp, "part_matches_device", side_effect=fake_match):
            kept, skipped, reason = espdisp.differential_flash_plan(
                family, "/dev/cu.usbmodem1", writes, full_write=full_write)
        return kept, skipped, reason, probed

    # -- identical parts skipped, the differing one written.
    kept, skipped, reason, probed = plan(lambda address, _p: address != 0x10000)
    check_equal(
        [role for _, role, _ in kept], ["app"],
        "only the app changed, so the app alone is written")
    check_equal(
        skipped,
        [(espdisp.FLASH_ROLE_BOOTLOADER, espdisp.FLASH_SKIP_PROVEN),
         (espdisp.FLASH_ROLE_PARTITIONS, espdisp.FLASH_SKIP_PROVEN),
         (espdisp.FLASH_ROLE_BOOT_APP0, espdisp.FLASH_SKIP_PROVEN),
         ("doom_wad", espdisp.FLASH_SKIP_PROVEN)],
        "every skipped part is named with the proof that allowed the skip")
    check_equal(reason, None, "an ordinary differential flash has no full-write reason")
    check_equal(
        probed[0], 0x8000,
        "the partition table is proven first, before any other part is trusted")
    check_equal(
        sorted(set(probed)), [0x0, 0x8000, 0xE000, 0x10000, 0x3FF000],
        "every part is checked against the device rather than assumed")

    # -- a differing part is written even when everything around it matches.
    kept, skipped, reason, _ = plan(lambda address, _p: address != 0x3FF000)
    check_equal(
        [role for _, role, _ in kept], ["doom_wad"],
        "a WAD that does not match the device is written, not skipped")
    check(
        (espdisp.FLASH_ROLE_PARTITIONS, espdisp.FLASH_SKIP_PROVEN) in skipped
        and reason is None,
        "one differing part does not force the rest to be rewritten")

    # -- nothing differs at all: nothing is written.
    kept, skipped, reason, _ = plan(lambda _a, _p: True)
    check_equal(kept, [], "a board already holding this build takes no write")
    check_equal(
        len(skipped), len(writes),
        "and every part is reported as skipped on proof")

    # -- a differing partition table changes the layout, so nothing may be skipped.
    kept, skipped, reason, probed = plan(lambda address, _p: address != 0x8000)
    check_equal(
        kept, writes,
        "a differing partition table forces every part to be written")
    check_equal(
        skipped, [],
        "a layout change means no part is skipped on the strength of the old one")
    check_equal(
        reason, espdisp.FLASH_FULL_WRITE_LAYOUT,
        "the full write states that the flash layout is changing")
    check_equal(
        probed, [0x8000],
        "once the layout is known to differ, no other region is consulted")

    # -- the override is honoured, and costs no device round trips at all.
    kept, skipped, reason, probed = plan(
        lambda _a, _p: True, full_write=True, expect_no_probe=True)
    check_equal(kept, writes, "--full-write writes every part")
    check_equal(skipped, [], "--full-write skips nothing")
    check_equal(
        reason, espdisp.FLASH_FULL_WRITE_FORCED,
        "--full-write says that it was asked for rather than inferred")
    check_equal(
        probed, [],
        "--full-write never asks the device what it holds")

    # -- an esptool that cannot verify proves nothing, so everything is written.
    kept, skipped, reason, probed = plan(lambda _a, _p: True, subcommand=None)
    check_equal(
        (kept, skipped, reason, probed),
        (writes, [], espdisp.FLASH_FULL_WRITE_NO_VERIFY, []),
        "without a verify subcommand nothing is skipped on an assumption")

    # -- a bundle with no single partition-table write is refused, not guessed at.
    with unittest.mock.patch.object(
            espdisp, "verify_flash_subcommand", return_value="verify-flash"), \
         unittest.mock.patch.object(
             espdisp, "part_matches_device",
             side_effect=AssertionError("layout-less plan probed the device")):
        check_fails(
            lambda: espdisp.differential_flash_plan(
                family, "/dev/cu.usbmodem1",
                [write for write in writes
                 if write[1] != espdisp.FLASH_ROLE_PARTITIONS]),
            "a differential flash needs exactly one partition-table write",
            "a plan with no partition table cannot decide what to skip")

    # -- and the writer honours the plan: only kept parts reach esptool.
    image = {
        "app_address": 0x10000,
        "flash_parts": [
            {"role": role, "address": address}
            for address, role, _ in writes if role != "app"
        ],
    }
    roles = {role: payload for _, role, payload in writes if role != "app"}
    captured = []
    with unittest.mock.patch.object(
            espdisp, "esptool_path", return_value="/tools/esptool"), \
         unittest.mock.patch.object(
             espdisp, "verify_flash_subcommand", return_value="verify-flash"), \
         unittest.mock.patch.object(
             espdisp, "part_matches_device",
             side_effect=lambda _f, _p, _s, address, _b: address != 0x10000), \
         unittest.mock.patch.object(
             espdisp, "run_streaming",
             side_effect=lambda command, cwd=None, redact=None: captured.append(
                 command)):
        written, skipped, reason = espdisp.write_bundle_over_usb(
            family, "/dev/cu.usbmodem1", image, app, roles, differential=True)
    check_equal(
        [role for _, role, _ in written], ["app"],
        "the writer writes only what the plan kept")
    check_equal(
        captured[0][8::2], ["0x10000"],
        "and hands esptool that part alone")
    check_equal(
        len(skipped), 4,
        "while still reporting the four parts it proved it could skip")

    captured = []
    with unittest.mock.patch.object(
            espdisp, "esptool_path", return_value="/tools/esptool"), \
         unittest.mock.patch.object(
             espdisp, "verify_flash_subcommand", return_value="verify-flash"), \
         unittest.mock.patch.object(
             espdisp, "part_matches_device", return_value=True), \
         unittest.mock.patch.object(
             espdisp, "run_streaming",
             side_effect=AssertionError("nothing to write still invoked esptool")):
        written, skipped, reason = espdisp.write_bundle_over_usb(
            family, "/dev/cu.usbmodem1", image, app, roles, differential=True)
    check_equal(
        (written, len(skipped), reason), ([], 5, None),
        "an entirely unchanged board is not written to at all")

    # -- the canonical recovery flash stays unconditional.
    captured = []
    with unittest.mock.patch.object(
            espdisp, "esptool_path", return_value="/tools/esptool"), \
         unittest.mock.patch.object(
             espdisp, "verify_flash_subcommand",
             side_effect=AssertionError("canonical flash consulted the device")), \
         unittest.mock.patch.object(
             espdisp, "run_streaming",
             side_effect=lambda command, cwd=None, redact=None: captured.append(
                 command)):
        written, skipped, reason = espdisp.write_bundle_over_usb(
            family, "/dev/cu.usbmodem1", image, app, roles)
    check_equal(
        captured[0][8::2], ["0x0", "0x8000", "0xE000", "0x10000", "0x3FF000"],
        "the canonical release flash still writes every part unconditionally")
    check_equal(
        (len(written), skipped, reason), (5, [], None),
        "and reports no skips, because it made no skip decision")


def test_part_match_proof_is_exit_code_only():
    """Only a clean esptool exit counts as proof that a region is identical."""
    family = espdisp.FAMILIES["c6"]
    seen = []

    def fake_capture(command, timeout=60.0):
        seen.append((list(command), timeout))
        return subprocess.CompletedProcess(command, exit_code, "", "")

    for exit_code, expected, what in (
            (0, True, "a clean exit proves the region is identical"),
            (1, False, "a mismatch is not proof and the part is written"),
            (2, False, "an esptool that could not connect proves nothing")):
        seen = []
        with unittest.mock.patch.object(
                espdisp, "esptool_path", return_value="/tools/esptool"), \
             unittest.mock.patch.object(
                 espdisp, "run_capture", side_effect=fake_capture):
            check_equal(
                espdisp.part_matches_device(
                    family, "/dev/cu.usbmodem1", "verify-flash",
                    0x10000, b"payload"),
                expected, what)
        command, timeout = seen[0]
        check_equal(
            command[:8],
            ["/tools/esptool", "--chip", "esp32c6", "--port",
             "/dev/cu.usbmodem1", "--baud", family.upload_speed, "verify-flash"],
            "the verify runs against the same chip, port and baud as the write")
        check_equal(
            command[8], "0x10000",
            "and against the address the bundle declares for that part")
        check_equal(
            timeout, espdisp.VERIFY_FLASH_TIMEOUT,
            "a verify is given its own timeout, not the default capture one")

    # The subcommand is probed with --help, which involves no serial port.
    probes = []

    def fake_help(command, timeout=60.0):
        probes.append(command)
        return subprocess.CompletedProcess(
            command, 0 if command[1] == available else 1, "", "")

    for available, expected in (
            ("verify-flash", "verify-flash"),
            ("verify_flash", "verify_flash"),
            (None, None)):
        probes = []
        with unittest.mock.patch.object(
                espdisp, "esptool_path", return_value="/tools/esptool"), \
             unittest.mock.patch.object(
                 espdisp, "run_capture", side_effect=fake_help):
            check_equal(
                espdisp.verify_flash_subcommand(), expected,
                "the verify subcommand this esptool has is %r" % expected)
        check(
            all("--help" in probe and "--port" not in probe for probe in probes),
            "the capability probe never opens a serial port")


class BootstrapFakeStream(io.StringIO):
    def __init__(self, tty=True):
        super().__init__()
        self.tty = tty

    def isatty(self):
        return self.tty


class BootstrapFakePrompter:
    def __init__(self, answers):
        self.answers = {
            key: list(value) if isinstance(value, (list, tuple)) else [value]
            for key, value in answers.items()
        }

    def ask(self, key, text, default=None, choices=None, allow_empty=False):
        del text, choices, allow_empty
        values = self.answers.get(key)
        if not values:
            if default is not None:
                return default
            raise EOFError("no scripted answer for %s" % key)
        value = values.pop(0)
        if isinstance(value, BaseException):
            raise value
        return value

    def confirm(self, key, text):
        value = self.ask(key, text)
        return str(value).strip().lower() in ("y", "yes", "true", "1")

    def pause(self, key, text):
        self.ask(key, text, default="")


class BootstrapFakeTransport:
    def __init__(self, malformed=False, timeout=False):
        self.commands = []
        self.malformed = malformed
        self.timeout = timeout
        self.imu_samples = iter([
            {"x": 16000, "y": 100, "z": -50},
            {"x": -16000, "y": -80, "z": 40},
            {"x": 60, "y": 15900, "z": 120},
            {"x": -40, "y": -16100, "z": -90},
        ])
        self.touch_samples = iter([
            {"x": 165, "y": 8},
            {"x": 8, "y": 10},
            {"x": 163, "y": 310},
            {"x": 10, "y": 309},
        ])

    def request(self, command, timeout=5.0):
        del timeout
        self.commands.append(command)
        if self.timeout:
            raise TimeoutError("synthetic timeout")
        if self.malformed:
            return "not a response object"
        words = command.split()
        payload = None
        if words[0] == "INFO":
            payload = {
                "chip": "esp32c6", "revision": 1, "flash_bytes": 8388608,
                "psram_bytes": 0, "base_mac": "02:00:00:00:00:01",
            }
        elif words[0] == "I2C_SCAN":
            if words[-2:] == ["18", "19"]:
                payload = {"addresses": [0x63, 0x6B]}
            else:
                payload = {"addresses": []}
        elif words[0] == "I2C_READ":
            address = int(words[-4], 0)
            if address == 0x63:
                payload = {"data": "510600"}
            elif address == 0x6B:
                payload = {"data": "05"}
            else:
                payload = {"data": ""}
        elif words[0] == "GPIO_WATCH":
            payload = {"pin": 9, "from": 1, "to": 0}
        elif words[0] == "IMU_READ":
            payload = next(self.imu_samples)
        elif words[0] == "TOUCH_READ":
            payload = next(self.touch_samples)
        elif words[0] == "ADC_READ":
            payload = {"raw": 1696, "millivolts": 1367}
        elif words[0] in {
                "PANEL_CONFIG", "PANEL_FILL", "PANEL_EDGES", "PANEL_GLYPH",
                "BACKLIGHT", "BACKLIGHT_ENABLE", "TOUCH_CONFIG", "IMU_CONFIG"}:
            payload = {"status": "ok"}
        elif words[0] == "PANEL_READ_ID":
            payload = {"supported": False, "data": ""}
        else:
            raise AssertionError("unexpected synthetic command %r" % command)
        return "BOOTOK " + json.dumps(payload, separators=(",", ":"))


BOOTSTRAP_DRIVE_COMMANDS = {
    "I2C_SCAN", "I2C_READ", "IMU_CONFIG", "IMU_READ", "PANEL_CONFIG",
    "PANEL_READ_ID", "PANEL_FILL", "PANEL_EDGES", "PANEL_GLYPH",
    "BACKLIGHT", "BACKLIGHT_ENABLE", "TOUCH_CONFIG", "TOUCH_READ",
}


class BootstrapConsentGuardTransport(BootstrapFakeTransport):
    def request(self, command, timeout=5.0):
        words = command.split()
        if words and words[0] in BOOTSTRAP_DRIVE_COMMANDS:
            if len(words) < 2 or words[1] != "CONFIRM":
                raise AssertionError(
                    "drive command lacks literal CONFIRM: %s" % command)
        return super().request(command, timeout)


class BootstrapS3Transport(BootstrapConsentGuardTransport):
    def request(self, command, timeout=5.0):
        words = command.split()
        if words[0] == "INFO":
            self.commands.append(command)
            payload = {
                "chip": "esp32s3", "revision": 1, "flash_bytes": 16777216,
                "psram_bytes": 8388608, "base_mac": "02:00:00:00:00:03",
            }
            return "BOOTOK " + json.dumps(payload, separators=(",", ":"))
        if words[0] == "I2C_SCAN":
            self.commands.append(command)
            pair = tuple(int(value, 0) for value in words[-2:])
            payload = {"addresses": [0x30] if pair == (42, 41) else []}
            return "BOOTOK " + json.dumps(payload, separators=(",", ":"))
        if words[0] == "GPIO_WATCH":
            self.commands.append(command)
            return 'BOOTOK {"pin":0,"from":1,"to":0}'
        return super().request(command, timeout)


class BootstrapAmoledTransport(BootstrapConsentGuardTransport):
    def __init__(self):
        super().__init__()
        self.panel_ready = False

    def request(self, command, timeout=5.0):
        words = command.split()
        if words[0] == "INFO":
            self.commands.append(command)
            payload = {
                "chip": "esp32s3", "revision": 1, "flash_bytes": 16777216,
                "psram_bytes": 8388608, "base_mac": "02:00:00:00:00:04",
            }
            return "BOOTOK " + json.dumps(payload, separators=(",", ":"))
        if words[0] == "I2C_SCAN":
            self.commands.append(command)
            pair = tuple(int(value, 0) for value in words[-2:])
            addresses = [0x34, 0x5A, 0x6B] if pair == (15, 14) else []
            return "BOOTOK " + json.dumps(
                {"addresses": addresses}, separators=(",", ":"))
        if words[0] == "PANEL_CONFIG":
            self.commands.append(command)
            self.panel_ready = True
            return 'BOOTOK {"status":"ok"}'
        if words[0] == "BACKLIGHT" and not self.panel_ready:
            self.commands.append(command)
            return 'BOOTERR {"error":"panel is not configured"}'
        return super().request(command, timeout)


def committed_descriptor(key):
    return next(
        item for item in board_descriptor.load_repository_descriptors(
            espdisp.REPO_ROOT)
        if item["key"] == key
    )


def imu_samples_for_descriptor(descriptor, gravity=16000):
    motion = descriptor["motion"]

    def raw(panel_axis, panel_sign):
        vector = [0, 0, 0]
        raw_sign = motion[panel_sign]
        vector[motion[panel_axis]] = gravity * raw_sign
        return tuple(vector)

    right = raw("x_axis", "x_sign")
    bottom = raw("y_axis", "y_sign")
    return [
        ("right_edge", right),
        ("left_edge", tuple(-value for value in right)),
        ("top_edge", tuple(-value for value in bottom)),
        ("bottom_edge", bottom),
    ]


def without_toml_tables(text, tables):
    pattern = re.compile(
        r"(?ms)^\[(%s)\]\s*$.*?(?=^\[|\Z)"
        % "|".join(re.escape(table) for table in sorted(tables)))
    return pattern.sub("", text)


def independently_select_descriptor(descriptors, flash_bytes, scans, failures=()):
    failed = set(failures)
    matches = []
    for descriptor in sorted(
            descriptors, key=lambda item: item["detection"]["order"]):
        detection = descriptor["detection"]
        minimum = detection["flash_min_exclusive"]
        maximum = detection["flash_max_inclusive"]
        if minimum and flash_bytes <= minimum:
            continue
        if maximum and flash_bytes > maximum:
            continue
        kind = detection["kind"]
        matched = kind in ("always", "flash_range")
        if kind.startswith("i2c_"):
            pair = (detection["sda"], detection["scl"])
            if pair in failed:
                matched = kind == "i2c_any_ack_or_start_failure"
            elif pair in scans:
                responders = scans[pair]
                if detection["addresses"]:
                    ack_count = sum(
                        address in detection["addresses"]
                        for address in responders)
                else:
                    ack_count = sum(
                        detection["scan_first"] <= address
                        <= detection["scan_last"]
                        for address in responders)
                if kind == "i2c_no_ack":
                    matched = ack_count == 0
                else:
                    matched = ack_count > 0
        if matched:
            matches.append(descriptor)
    resolution = descriptors[0]["detection"]["resolution"]
    if resolution == "exactly_one":
        return matches[0]["key"] if len(matches) == 1 else None
    return matches[0]["key"] if matches else None


def bootstrap_success_answers():
    return {
        "consent.discovery_i2c": "yes",
        "buttons.ready": "",
        "consent.imu": "yes",
        "imu.right_edge": "",
        "imu.left_edge": "",
        "imu.top_edge": "",
        "imu.bottom_edge": "",
        "consent.panel_config": "yes",
        "consent.touch": "yes",
        "touch.top_left": "",
        "touch.top_right": "",
        "touch.bottom_left": "",
        "touch.bottom_right": "",
        "consent.color": "yes",
        "color.red": "red",
        "consent.inversion": "yes",
        "color.black": "black",
        "consent.offsets": "yes",
        "offsets.0": "none",
        "offsets.1": "none",
        "offsets.2": "none",
        "offsets.3": "none",
        "consent.mirror": "yes",
        "mirror.reading": "normal",
        "consent.backlight.low": "yes",
        "consent.backlight.high": "yes",
        "backlight.change": "brighter",
        "battery.multimeter": "4.10",
    }


def test_bootstrap_solvers_and_derivations():
    chunks = []
    write_sizes = iter([3, 2, 4])

    def partial_write(_fd, data):
        size = next(write_sizes)
        chunks.append(bytes(data[:size]))
        return size

    with unittest.mock.patch.object(
            espdisp.os, "write", side_effect=partial_write):
        espdisp.write_serial(123, b"abcdefghi")
    check_equal(
        b"".join(chunks), b"abcdefghi",
        "serial writer completes partial native-USB writes",
    )

    for key in ("s3-touch-lcd-154", "s3-touch-amoled-175c"):
        descriptor = committed_descriptor(key)
        solved = espdisp.solve_imu_mapping(
            imu_samples_for_descriptor(descriptor))
        check_equal(
            solved,
            {
                "x_axis": descriptor["motion"]["x_axis"],
                "x_sign": descriptor["motion"]["x_sign"],
                "y_axis": descriptor["motion"]["y_axis"],
                "y_sign": descriptor["motion"]["y_sign"],
            },
            "%s IMU mapping round-trips the firmware gravity convention" % key,
        )
    check_fails(
        lambda: espdisp.solve_imu_mapping([
            ("right_edge", (16000, 0, 0)),
            ("left_edge", (15000, 0, 0)),
            ("top_edge", (0, 16000, 0)),
            ("bottom_edge", (0, -16000, 0)),
        ]),
        "inconsistent",
        "an inconsistent IMU sequence is rejected",
    )
    check_fails(
        lambda: espdisp.solve_imu_mapping([
            ("right_edge", (16000, 15000, 0)),
            ("left_edge", (-16000, 15000, 0)),
            ("top_edge", (15000, -16000, 0)),
            ("bottom_edge", (15000, 16000, 0)),
        ]),
        "isolate one gravity axis",
        "two active gravity axes in every IMU pose are rejected",
    )

    touch = espdisp.solve_touch_calibration(
        [
            ("top_left", (8, 8), (165, 8)),
            ("top_right", (163, 8), (8, 10)),
            ("bottom_left", (8, 311), (163, 310)),
            ("bottom_right", (163, 311), (10, 309)),
        ],
        172,
        320,
    )
    check_equal(touch["swap_xy"], False, "touch solver keeps unswapped axes")
    check_equal(touch["invert_x"], True, "touch solver finds mirrored raw X")
    check_equal(touch["invert_y"], False, "touch solver keeps raw Y")
    check(abs(touch["x_offset"]) <= 10 and abs(touch["y_offset"]) <= 10,
          "touch solver derives small edge offsets")

    for descriptor in board_descriptor.load_repository_descriptors(
            espdisp.REPO_ROOT):
        panel = descriptor["panel"]
        check_call_equal(
            lambda panel=panel: espdisp.derive_color_order(
                "red", panel["color_order"]),
            panel["color_order"],
            "%s correct red observation retains committed color order"
            % descriptor["key"],
        )
        check_call_equal(
            lambda panel=panel: espdisp.derive_inversion(
                "black", panel["invert_color"]),
            panel["invert_color"],
            "%s correct black observation retains committed inversion"
            % descriptor["key"],
        )
    gc9107 = committed_descriptor("s3-lcd-085")
    check_call_equal(
        lambda: espdisp.derive_color_order(
            "blue", gc9107["panel"]["color_order"]),
        "rgb",
        "a swapped GC9107 observation toggles the applied BGR order",
    )
    inverted = committed_descriptor("c6-touch-lcd-147")
    check_call_equal(
        lambda: espdisp.derive_inversion(
            "white", inverted["panel"]["invert_color"]),
        False,
        "a white black-level observation toggles the applied inversion",
    )
    check_equal(espdisp.derive_mirror_x("normal"), False,
                "readable glyph needs no mirror correction")
    check_equal(espdisp.derive_mirror_x("backwards"), True,
                "backwards glyph needs mirror correction")
    check_equal(
        espdisp.solve_orientation_offsets(
            ["left:6", "top:4", "right:6", "bottom:4"]),
        [[6, 0], [0, 4], [-6, 0], [0, -4]],
        "edge observations solve per-orientation offsets",
    )


def repo_root_without_boards(tmp, *keys):
    """A repository root whose boards/ omits the named descriptors."""
    root = os.path.join(tmp, "repo-without-" + "-".join(keys))
    shutil.copytree(
        os.path.join(espdisp.REPO_ROOT, "boards"),
        os.path.join(root, "boards"),
        ignore=lambda _dir, names: [
            name for name in names if name[:-len(".toml")] in keys],
    )
    return root


def test_bootstrap_knob_press_pin_blocks_template_drive():
    # The CrowPanel knob's push switch shorts GPIO41 to ground, and its I2C bus
    # (GPIO6/7) cannot be scanned to rule it out because GPIO7 is the 1.3-inch
    # board's battery sense. While the knob stays a possible candidate, driving
    # GPIO41 as the 1.3-inch template's MOSI must be refused.
    with tempfile.TemporaryDirectory() as tmp:
        with unittest.mock.patch.dict(os.environ, {}, clear=True):
            check_fails(
                lambda: espdisp.run_bootstrap_session(
                    transport=BootstrapS3Transport(),
                    prompter=BootstrapFakePrompter(
                        bootstrap_success_answers()),
                    stream=BootstrapFakeStream(tty=True),
                    repo_root=espdisp.REPO_ROOT,
                    name="synthetic-s3",
                    candidate_key="s3-lcd-130",
                    confirmed_chip="esp32s3",
                    output_path=os.path.join(tmp, "synthetic-s3.toml"),
                ),
                "refusing to drive GPIO41 for panel calibration; candidate "
                "descriptor set marks it as s3-elecrow-knob-128.carrier.pin_boot",
                "a possible knob carrier keeps its press switch undriven",
            )


def test_bootstrap_knob_encoder_pins_block_template_drive():
    # Encoder contacts close to ground at every other detent, so the 1.54-inch
    # template's D/C on GPIO45 (knob encoder A) must not be driven either.
    with tempfile.TemporaryDirectory() as tmp:
        with unittest.mock.patch.dict(os.environ, {}, clear=True):
            check_fails(
                lambda: espdisp.run_bootstrap_session(
                    transport=BootstrapS3Transport(),
                    prompter=BootstrapFakePrompter(
                        bootstrap_success_answers()),
                    stream=BootstrapFakeStream(tty=True),
                    repo_root=espdisp.REPO_ROOT,
                    name="synthetic-s3",
                    candidate_key="s3-touch-lcd-154",
                    confirmed_chip="esp32s3",
                    output_path=os.path.join(tmp, "synthetic-s3.toml"),
                ),
                "refusing to drive GPIO45 for panel calibration; candidate "
                "descriptor set marks it as "
                "s3-elecrow-knob-128.carrier.pin_encoder_a",
                "a possible knob carrier keeps its encoder lines undriven",
            )


def test_bootstrap_full_synthetic_session():
    with tempfile.TemporaryDirectory() as tmp:
        # This session templates from the 1.3-inch board, whose MOSI is the
        # knob carrier's press switch; see the test above for that refusal.
        repo_root = repo_root_without_boards(tmp, "s3-elecrow-knob-128")
        output = os.path.join(tmp, "synthetic-s3.toml")
        stream = BootstrapFakeStream(tty=True)
        with unittest.mock.patch.dict(os.environ, {}, clear=True):
            result = espdisp.run_bootstrap_session(
                transport=BootstrapS3Transport(),
                prompter=BootstrapFakePrompter(bootstrap_success_answers()),
                stream=stream,
                repo_root=repo_root,
                name="synthetic-s3",
                candidate_key="s3-lcd-130",
                confirmed_chip="esp32s3",
                output_path=output,
            )
        check_equal(result.path, output, "bootstrap reports the draft path")
        check(os.path.isfile(output), "bootstrap writes a complete draft")
        with open(output, "rb") as source:
            draft = tomllib.load(source)
        descriptors = board_descriptor.load_repository_descriptors(
            repo_root)
        draft["_source"] = output
        check_accepts(
            lambda: board_descriptor.validate_descriptors(descriptors + [draft]),
            "synthetic bootstrap descriptor passes repository validation",
        )
        check_equal(draft["motion"]["controller"], "none",
                    "unmeasured IMU wiring is emitted inert")
        check_equal(draft["touch"]["controller"], "none",
                    "unmeasured touch wiring is emitted inert")
        check_equal(draft["touch"]["sda"], -1,
                    "unmeasured touch SDA is emitted inert")
        check_equal(draft["carrier"]["pin_rgb_led"], -1,
                    "unmeasured RGB LED wiring is emitted inert")
        check_equal(draft["serial"]["rx"], -1,
                    "unmeasured serial RX wiring is emitted inert")
        check_equal(draft["panel"]["color_order"], "rgb",
                    "full bootstrap retains the applied RGB order")
        check_equal(draft["panel"]["invert_color"], True,
                    "full bootstrap retains the applied inversion")
        family = [
            item for item in descriptors
            if item["identity"]["target"] == "s3"
        ] + [draft]
        check_equal(
            independently_select_descriptor(
                family, 16777216, {(42, 41): [0x30]}),
            "synthetic-s3",
            "emitted detection evidence selects the draft at boot",
        )
        check("\x1b[" in stream.getvalue(),
              "interactive TTY transcript contains ANSI color")
        check("validate -> regenerate -> compile -> flash -> confirm bring-up"
              in stream.getvalue(),
              "final summary prints the human closing loop")

        no_color_stream = BootstrapFakeStream(tty=True)
        with unittest.mock.patch.dict(
                os.environ, {"NO_COLOR": "1"}, clear=True):
            second = os.path.join(tmp, "synthetic-s3-no-color.toml")
            espdisp.run_bootstrap_session(
                transport=BootstrapS3Transport(),
                prompter=BootstrapFakePrompter(bootstrap_success_answers()),
                stream=no_color_stream,
                repo_root=repo_root,
                name="synthetic-s3-no-color",
                candidate_key="s3-lcd-130",
                confirmed_chip="esp32s3",
                output_path=second,
            )
        check("\x1b[" not in no_color_stream.getvalue(),
              "full NO_COLOR transcript contains no ANSI escapes")


def flatten_bootstrap_descriptor(value, prefix=""):
    out = {}
    if isinstance(value, dict):
        for key, item in value.items():
            child = key if not prefix else prefix + "." + key
            out.update(flatten_bootstrap_descriptor(item, child))
    else:
        out[prefix] = value
    return out


def test_bootstrap_retune_is_section_scoped():
    path = os.path.join(espdisp.REPO_ROOT, "boards", "c6-touch-lcd-147.toml")
    with open(path, encoding="utf-8") as source:
        original = source.read()
    cases = {
        "imu": {
            "updates": {
                "x_axis": 2, "x_sign": -1, "y_axis": 0, "y_sign": -1},
            "tables": {"motion"},
        },
        "touch": {
            "updates": {
                "raw_x_mirrored": False, "raw_y_mirrored": True},
            "tables": {"touch"},
        },
        "color": {
            "updates": {"color_order": "bgr", "invert_color": False},
            "tables": {"panel"},
        },
        "offsets": {
            "updates": {
                "col_offset": 35, "row_offset": 1,
                "offsets": [[35, 1], [1, 35], [35, 1], [1, 35]],
            },
            "tables": {"panel", "orientation"},
        },
        "backlight": {
            "updates": {"inverted": True, "enable_pin": -1},
            "tables": {"backlight"},
        },
        "buttons": {
            "updates": {"pin_boot": 8},
            "tables": {"carrier"},
        },
    }
    for section, case in cases.items():
        updated = espdisp.retune_descriptor_text(
            original, section, case["updates"], ["synthetic retune evidence"])
        check_equal(
            without_toml_tables(updated, case["tables"]),
            without_toml_tables(original, case["tables"]),
            "--retune %s preserves every byte outside its target table(s)"
            % section,
        )
        check(
            "synthetic retune evidence" in updated,
            "--retune %s records evidence beside the changed table" % section,
        )

    with tempfile.TemporaryDirectory() as tmp:
        shutil.copytree(
            os.path.join(espdisp.REPO_ROOT, "boards"),
            os.path.join(tmp, "boards"),
        )
        retune_path = os.path.join(tmp, "boards", "c6-touch-lcd-147.toml")
        with open(retune_path, "rb") as source:
            before_descriptor = tomllib.load(source)
        before_mode = os.stat(retune_path).st_mode & 0o777
        transport = BootstrapFakeTransport()
        transport.imu_samples = iter([
            {"x": 10, "y": 20, "z": 16000},
            {"x": -10, "y": -20, "z": -16000},
            {"x": -15900, "y": 30, "z": 40},
            {"x": 16100, "y": -20, "z": -30},
        ])
        answers = bootstrap_success_answers()
        answers["retune.write"] = "yes"
        espdisp.run_retune_session(
            transport=transport,
            prompter=BootstrapFakePrompter(answers),
            stream=BootstrapFakeStream(tty=False),
            repo_root=tmp,
            board_key="c6-touch-lcd-147",
            section="imu",
            confirmed_chip="esp32c6",
        )
        with open(retune_path, "rb") as source:
            after_descriptor = tomllib.load(source)
        before_flat = flatten_bootstrap_descriptor(before_descriptor)
        after_flat = flatten_bootstrap_descriptor(after_descriptor)
        changed = {
            key for key in before_flat if before_flat[key] != after_flat[key]
        }
        check_equal(
            changed,
            {
                "motion.x_axis", "motion.y_axis",
            },
            "scripted --retune imu changes only motion calibration fields",
        )
        check_equal(
            os.stat(retune_path).st_mode & 0o777,
            before_mode,
            "atomic retune preserves descriptor file permissions",
        )

    with tempfile.TemporaryDirectory() as tmp:
        shutil.copytree(
            os.path.join(espdisp.REPO_ROOT, "boards"),
            os.path.join(tmp, "boards"),
        )
        answers = bootstrap_success_answers()
        answers["retune.write"] = "yes"
        check_fails(
            lambda: espdisp.run_retune_session(
                transport=BootstrapConsentGuardTransport(),
                prompter=BootstrapFakePrompter(answers),
                stream=BootstrapFakeStream(tty=False),
                repo_root=tmp,
                board_key="c6-lcd-147",
                section="color",
                confirmed_chip="esp32c6",
            ),
            "contradicts observed evidence",
            "wrong-carrier color retune is refused before panel drive",
        )

    with tempfile.TemporaryDirectory() as tmp:
        shutil.copytree(
            os.path.join(espdisp.REPO_ROOT, "boards"),
            os.path.join(tmp, "boards"),
        )
        path = os.path.join(
            tmp, "boards", "s3-touch-amoled-175c.toml")
        answers = bootstrap_success_answers()
        answers["retune.write"] = "yes"
        transport = BootstrapAmoledTransport()
        check_fails(
            lambda: espdisp.run_retune_session(
                transport=transport,
                prompter=BootstrapFakePrompter(answers),
                stream=BootstrapFakeStream(tty=False),
                repo_root=tmp,
                board_key="s3-touch-amoled-175c",
                section="backlight",
                confirmed_chip="esp32s3",
            ),
            "cannot safely initialize",
            "panel-command AMOLED backlight retune fails before brightness",
        )
        check(
            not any(command.startswith("BACKLIGHT ")
                    for command in transport.commands),
            "unsafe AMOLED retune sends no brightness command",
        )
        with open(path, encoding="utf-8") as source:
            unchanged = source.read()
        with open(
            os.path.join(
                espdisp.REPO_ROOT, "boards", "s3-touch-amoled-175c.toml"),
            encoding="utf-8",
        ) as source:
            original = source.read()
        check_equal(
            unchanged, original,
            "refused AMOLED backlight retune preserves every descriptor byte",
        )


def test_bootstrap_refusals_and_color_controls():
    check_fails(
        lambda: espdisp.require_confirmed_bootstrap_chip(None),
        "esptool",
        "bootstrap refuses an unconfirmed chip family",
    )
    check_fails(
        lambda: espdisp.parse_bootstrap_response("garbage"),
        "malformed",
        "malformed device response is refused",
    )
    check_fails(
        lambda: espdisp.bootstrap_request(
            BootstrapFakeTransport(timeout=True), "INFO", 0.01),
        "timeout",
        "device timeout is a named refusal",
    )

    malformed_info = BootstrapFakeTransport()
    original_request = malformed_info.request

    def request_with_bad_info(command, timeout=5.0):
        if command == "INFO":
            return 'BOOTOK {"chip":"esp32c6","revision":"one"}'
        return original_request(command, timeout)

    malformed_info.request = request_with_bad_info
    with tempfile.TemporaryDirectory() as tmp:
        check_fails(
            lambda: espdisp.run_bootstrap_session(
                transport=malformed_info,
                prompter=BootstrapFakePrompter(bootstrap_success_answers()),
                stream=BootstrapFakeStream(),
                repo_root=espdisp.REPO_ROOT,
                name="bad-info",
                candidate_key="c6-touch-lcd-147",
                confirmed_chip="esp32c6",
                output_path=os.path.join(tmp, "bad-info.toml"),
            ),
            "malformed bootstrap INFO",
            "malformed device identity facts are refused",
        )

    answers = bootstrap_success_answers()
    answers["consent.discovery_i2c"] = "no"
    transport = BootstrapFakeTransport()
    with tempfile.TemporaryDirectory() as tmp:
        check_fails(
            lambda: espdisp.run_bootstrap_session(
                transport=transport,
                prompter=BootstrapFakePrompter(answers),
                stream=BootstrapFakeStream(),
                repo_root=espdisp.REPO_ROOT,
                name="declined-first-drive",
                candidate_key="c6-touch-lcd-147",
                confirmed_chip="esp32c6",
                output_path=os.path.join(tmp, "declined-first-drive.toml"),
            ),
            "consent declined",
            "declining the first drive consent aborts the session",
        )
        check(
            not any(command.split()[0] in BOOTSTRAP_DRIVE_COMMANDS
                    for command in transport.commands),
            "declined first consent sends no electrically driving command",
        )

    answers = bootstrap_success_answers()
    answers["consent.panel_config"] = "no"
    transport = BootstrapFakeTransport()
    with tempfile.TemporaryDirectory() as tmp:
        check_fails(
            lambda: espdisp.run_bootstrap_session(
                transport=transport,
                prompter=BootstrapFakePrompter(answers),
                stream=BootstrapFakeStream(),
                repo_root=espdisp.REPO_ROOT,
                name="declined-drive",
                candidate_key="c6-touch-lcd-147",
                confirmed_chip="esp32c6",
                output_path=os.path.join(tmp, "declined-drive.toml"),
            ),
            "declined",
            "declining panel consent aborts before any display drive",
        )
        check(not any(command.startswith("PANEL_")
                      for command in transport.commands),
              "declined consent sends no panel command")
        check(not os.listdir(tmp), "declined session leaves no partial draft")

    aborted = bootstrap_success_answers()
    aborted["buttons.ready"] = EOFError("synthetic abort")
    with tempfile.TemporaryDirectory() as tmp:
        check_fails(
            lambda: espdisp.run_bootstrap_session(
                transport=BootstrapFakeTransport(),
                prompter=BootstrapFakePrompter(aborted),
                stream=BootstrapFakeStream(),
                repo_root=espdisp.REPO_ROOT,
                name="aborted",
                candidate_key="c6-touch-lcd-147",
                confirmed_chip="esp32c6",
                output_path=os.path.join(tmp, "aborted.toml"),
            ),
            "aborted",
            "aborted prompt is reported without a traceback",
        )
        check(not os.listdir(tmp), "aborted session leaves no partial draft")

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "existing.toml")
        with open(path, "w", encoding="utf-8") as output:
            output.write("original\n")
        answers = bootstrap_success_answers()
        answers["overwrite"] = "no"
        repo_root = repo_root_without_boards(tmp, "s3-elecrow-knob-128")
        check_fails(
            lambda: espdisp.run_bootstrap_session(
                transport=BootstrapS3Transport(),
                prompter=BootstrapFakePrompter(answers),
                stream=BootstrapFakeStream(),
                repo_root=repo_root,
                name="existing",
                candidate_key="s3-lcd-130",
                confirmed_chip="esp32s3",
                output_path=path,
            ),
            "overwrite declined",
            "an existing descriptor requires explicit overwrite confirmation",
        )
        with open(path, encoding="utf-8") as source:
            check_equal(source.read(), "original\n",
                        "declined overwrite preserves the original file")

    tty = BootstrapFakeStream(tty=True)
    espdisp.BootstrapConsole(tty, {}).fact("visible")
    check("\x1b[" in tty.getvalue(), "TTY output uses color")
    no_color = BootstrapFakeStream(tty=True)
    espdisp.BootstrapConsole(no_color, {"NO_COLOR": "1"}).fact("plain")
    check("\x1b[" not in no_color.getvalue(), "NO_COLOR disables ANSI color")
    pipe = BootstrapFakeStream(tty=False)
    espdisp.BootstrapConsole(pipe, {}).fact("plain")
    check("\x1b[" not in pipe.getvalue(), "non-TTY output disables ANSI color")

    parser = espdisp.build_parser()
    bootstrap = parser.parse_args([
        "bootstrap", "--port", "/dev/fake", "--name", "new-board",
        "--candidate", "c6-touch-lcd-147",
    ])
    check_equal(bootstrap.name, "new-board", "bootstrap parser accepts a draft name")
    retune = parser.parse_args([
        "bootstrap", "--port", "/dev/fake", "--retune", "c6-touch-lcd-147",
        "--section", "imu",
    ])
    check_equal(retune.section, "imu", "bootstrap parser accepts section retuning")

    swapped = espdisp.solve_touch_calibration(
        [
            ("top_left", (8, 8), (8, 165)),
            ("top_right", (163, 8), (10, 8)),
            ("bottom_left", (8, 311), (310, 163)),
            ("bottom_right", (163, 311), (309, 10)),
        ],
        172,
        320,
    )
    check_equal(swapped["swap_xy"], True,
                "touch solver reports swapped raw axes explicitly")

    candidates = board_descriptor.load_repository_descriptors(espdisp.REPO_ROOT)
    s3 = [
        item for item in candidates
        if item["identity"]["target"] == "s3"
    ]
    selected, safe = espdisp.bootstrap._choose_candidate(
        s3, {}, set(), 8388608, None,
        BootstrapFakePrompter({}),
    )
    check_equal(selected["key"], "s3-lcd-085",
                "flash-only S3 candidate selection is automatic")
    check_equal([item["key"] for item in safe], ["s3-lcd-085"],
                "automatic candidate resolution narrows the drive safety set")

    p4 = [
        item for item in candidates
        if item["identity"]["target"] == "p4"
    ]
    selected, safe = espdisp.bootstrap._choose_candidate(
        p4, {}, set(), 33554432, None,
        BootstrapFakePrompter({}),
    )
    check_equal(selected["key"], "p4-wifi6-touch-lcd-4b",
                "the sole P4 always-match candidate is automatic")
    check_equal(len(safe), 1, "P4 automatic selection has one safety candidate")

    c6 = [
        item for item in candidates
        if item["identity"]["target"] == "c6"
    ]
    selected, safe = espdisp.bootstrap._choose_candidate(
        c6, {}, {(18, 19)}, 8388608, None,
        BootstrapFakePrompter({}),
    )
    check_equal(selected["key"], "c6-touch-lcd-147",
                "safe I2C start-failure evidence follows the declared rule")
    check_equal(len(safe), 1,
                "start-failure resolution narrows the drive safety set")

    check_fails(
        lambda: espdisp._bootstrap_call(
            espdisp.bootstrap._choose_candidate,
            c6,
            {(18, 19): [0x63, 0x6B]},
            set(),
            8388608,
            "c6-lcd-147",
            BootstrapFakePrompter({}),
        ),
        "contradicts observed evidence",
        "--candidate cannot select a descriptor contradicted by bus evidence",
    )

    selected, safe = espdisp.bootstrap._choose_candidate(
        s3, {}, set(), 16777216, "s3-touch-amoled-175c",
        BootstrapFakePrompter({}),
    )
    check_equal(
        selected["key"], "s3-touch-amoled-175c",
        "an evidence-compatible requested candidate remains selectable",
    )
    check_equal(
        {item["key"] for item in safe},
        {
            "s3-lcd-130", "s3-touch-lcd-154",
            "s3-touch-amoled-175c", "s3-touch-lcd-185c",
            "s3-elecrow-knob-128",
        },
        "a requested candidate retains every still-plausible S3 descriptor",
    )

    c6_touch = next(
        item for item in c6 if item["key"] == "c6-touch-lcd-147")
    check_fails(
        lambda: espdisp._bootstrap_call(
            espdisp.bootstrap._descriptor_from_evidence,
            candidates,
            c6_touch,
            "shadowed-c6",
            "esp32c6",
            8388608,
            {(18, 19): [0x63, 0x6B]},
            set(),
            [],
            9,
            True,
            None,
            None,
            "rgb",
            True,
            copy.deepcopy(c6_touch["orientation"]["offsets"]),
            False,
            None,
            False,
            None,
            None,
        ),
        "unreachable",
        "first-match reachability is checked before a draft is emitted",
    )

    check_fails(
        lambda: espdisp._bootstrap_call(
            espdisp.bootstrap._ensure_safe_drive,
            s3, [2], "synthetic display"),
        "power.battery_enable",
        "ambiguous candidates forbid every known input or power-rail pin",
    )

    cst = next(
        signature for signature in espdisp.bootstrap.CONTROLLER_SIGNATURES
        if signature.name == "cst9217"
    )
    check(
        espdisp.bootstrap._signature_accepts(
            cst, bytes([0x00, 0x00, 0x17, 0x92])),
        "CST9217 signature reads the four-byte chip-info layout",
    )

    warning_stream = BootstrapFakeStream(tty=False)
    espdisp.bootstrap._drive_warning(
        espdisp.BootstrapConsole(warning_stream, {}), p4[0])
    check("GPIO33 BL_ENABLE=LOW then HIGH" in warning_stream.getvalue(),
          "P4 consent warning states the exact enable transition")

    swapped_transport = BootstrapFakeTransport()
    swapped_transport.touch_samples = iter([
        {"x": 8, "y": 165},
        {"x": 10, "y": 8},
        {"x": 310, "y": 163},
        {"x": 309, "y": 10},
    ])
    with tempfile.TemporaryDirectory() as tmp:
        output = os.path.join(tmp, "swapped-touch.toml")
        check_fails(
            lambda: espdisp.run_bootstrap_session(
                transport=swapped_transport,
                prompter=BootstrapFakePrompter(bootstrap_success_answers()),
                stream=BootstrapFakeStream(),
                repo_root=espdisp.REPO_ROOT,
                name="swapped-touch",
                candidate_key="c6-touch-lcd-147",
                confirmed_chip="esp32c6",
                output_path=output,
            ),
            "cannot represent swapped raw touch axes",
            "unrepresentable touch calibration is refused instead of guessed",
        )
        check(not os.path.exists(output),
              "swapped touch refusal leaves no partial descriptor")

    hostile = BootstrapFakeTransport()

    def hostile_response(command, timeout=5.0):
        del command, timeout
        return {"data": "abc\x1b[31m\nactive = true"}

    hostile.request = hostile_response
    check_fails(
        lambda: espdisp.bootstrap_request(hostile, "PANEL_READ_ID CONFIRM"),
        "device response text",
        "device-controlled control characters are rejected at the boundary",
    )
    check_fails(
        lambda: espdisp._bootstrap_call(
            espdisp.bootstrap.render_descriptor,
            committed_descriptor("c6-lcd-147"),
            {"panel.driver": ["safe\nactive = true"]},
        ),
        "comment",
        "rendered descriptor comments cannot inject TOML assignments",
    )

    for reading in ("0", "-1", "nan", "inf", "1e308", "1e309"):
        check_fails(
            lambda reading=reading: espdisp._bootstrap_call(
                espdisp.bootstrap._derive_battery_scale, reading, 1367),
            "battery",
            "battery measurement %r is refused cleanly" % reading,
        )
    check_fails(
        lambda: espdisp._bootstrap_call(
            espdisp.bootstrap._derive_battery_scale, "400.0", 1000),
        "1..255",
        "battery scale outside the runtime range is refused",
    )

    with tempfile.TemporaryDirectory() as tmp:
        output = os.path.join(tmp, "unreachable-c6.toml")
        check_fails(
            lambda: espdisp.run_bootstrap_session(
                transport=BootstrapConsentGuardTransport(),
                prompter=BootstrapFakePrompter(bootstrap_success_answers()),
                stream=BootstrapFakeStream(),
                repo_root=espdisp.REPO_ROOT,
                name="unreachable-c6",
                candidate_key="c6-touch-lcd-147",
                confirmed_chip="esp32c6",
                output_path=output,
            ),
            "unreachable",
            "a C6 draft shadowed by the earlier first-match rule is refused",
        )
        check(not os.path.exists(output),
              "unreachable detection refusal writes no descriptor")


def test_bootstrap_firmware_safety_contract():
    with tempfile.TemporaryDirectory() as tmp:
        source_path = os.path.join(tmp, "bootstrap_protocol_test.cpp")
        binary = os.path.join(tmp, "bootstrap_protocol_test")
        with open(source_path, "w", encoding="utf-8") as output:
            output.write(r'''
#include "firmware/board_bootstrap/bootstrap_protocol.h"
using namespace bootstrapproto;
int main() {
  const char *drives[] = {
      "I2C_SCAN", "I2C_READ", "IMU_CONFIG", "IMU_READ", "PANEL_CONFIG",
      "PANEL_READ_ID", "PANEL_FILL", "PANEL_EDGES", "PANEL_GLYPH",
      "BACKLIGHT", "BACKLIGHT_ENABLE", "TOUCH_CONFIG", "TOUCH_READ"};
  for (const char *command : drives) {
    if (commandAuthorized(command, nullptr)) return 1;
    if (commandAuthorized(command, "confirm")) return 2;
    if (!commandAuthorized(command, "CONFIRM")) return 3;
  }
  if (!commandAuthorized("INFO", nullptr)) return 4;
  I2cReadArgs read = {};
  if (!parseI2cReadArgs("18", "19", "0x6b", "0xff", "1", "6", read))
    return 5;
  if (parseI2cReadArgs("18", "19", "0x78", "0", "1", "1", read))
    return 6;
  if (parseI2cReadArgs("18", "19", "0x6b", "0x100", "1", "1", read))
    return 7;
  if (parseI2cReadArgs("18", "19", "0x6b", "0", "3", "1", read))
    return 8;
  TouchConfigArgs touch = {};
  if (!parseTouchConfigArgs(
          "cst816", "42", "41", "0x15", "47", "48", "0", "0", "0",
          touch))
    return 9;
  if (parseTouchConfigArgs(
          "unknown", "42", "41", "0x15", "47", "48", "0", "0", "0",
          touch))
    return 10;
  if (parseTouchConfigArgs(
          "cst816", "42", "41", "0x115", "47", "48", "0", "0", "0",
          touch))
    return 11;
  if (parseTouchConfigArgs(
          "cst816", "42", "41", "0x15", "47", "48", "257", "288", "0",
          touch))
    return 12;
  const char *badEdges[] = {"x=2147483647", "y=10"};
  PanelEdgesArgs edges = {};
  if (parsePanelEdgesArgs(badEdges, 2, 172, 320, edges)) return 13;
  return 0;
}
''')
        compiled = subprocess.run(
            [
                "g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                "-I", espdisp.REPO_ROOT, source_path, "-o", binary,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        check(
            compiled.returncode == 0,
            "bootstrap protocol parser contract compiles: %s"
            % compiled.stderr.strip(),
        )
        if compiled.returncode == 0:
            executed = subprocess.run(
                [binary], capture_output=True, text=True, check=False)
            check_equal(
                executed.returncode, 0,
                "bootstrap protocol rejects unconfirmed and malformed drives",
            )

    events = []

    class MustNotOpen:
        def __init__(self, address):
            events.append(("open", address))

    args = argparse.Namespace(
        port="/dev/fake", retune=None, section=None, name="safe",
        candidate="c6-lcd-147", timeout=1.0)
    with unittest.mock.patch.object(
            espdisp, "resolve_port",
            return_value=espdisp.PortInfo("/dev/fake", [], "fake")), \
         unittest.mock.patch.object(
             espdisp, "probe_chip", side_effect=lambda address:
             events.append(("probe", address)) or None), \
         unittest.mock.patch.object(
             espdisp, "SerialBootstrapTransport", MustNotOpen):
        check_fails(
            lambda: espdisp.cmd_bootstrap(args),
            "esptool",
            "bootstrap command refuses before serial when chip confirmation fails",
        )
    check_equal(events, [("probe", "/dev/fake")],
                "esptool confirmation happens before the serial transport opens")


def main():
    test_bootstrap_solvers_and_derivations()
    test_bootstrap_knob_press_pin_blocks_template_drive()
    test_bootstrap_knob_encoder_pins_block_template_drive()
    test_bootstrap_full_synthetic_session()
    test_bootstrap_retune_is_section_scoped()
    test_bootstrap_refusals_and_color_controls()
    test_bootstrap_firmware_safety_contract()
    test_firmware_output_root()
    test_board_descriptor_validator()
    test_universal_family_catalog_and_cli()
    test_compile_wifi_config_staging()
    test_s3_doom_build_contract()
    test_family_resolution_and_discovery()
    test_release_catalog_contract()
    test_release_writes_only_bare_shipping_bundles()
    test_release_defaults_to_build_numbered_dev_bundles()
    test_release_refuses_to_overwrite_a_shipping_version()
    test_release_regenerates_only_with_exact_version_confirmation()
    test_dev_bundle_output_stays_outside_release_store()
    test_release_catalog_ignores_build_numbered_artifacts_before_reading()
    test_canonical_usb_flash_path()
    test_flash_build_writes_one_dev_family()
    test_differential_flash_skip_decision()
    test_part_match_proof_is_exit_code_only()
    test_doom_partition_contracts()
    test_discovery_command()
    test_password_policy()
    test_cfgotapw_line()
    test_espota_command()
    test_app_image_picks_the_app_not_the_flash_image()
    test_fw_version_from_sketch()
    test_release_notes_source_and_manifest_contract()
    test_bundle_release_notes_preflight_order()
    test_bundle_release_notes_preflight_barriers()
    test_release_notes_diagnostics_and_precedence()
    test_release_notes_reader_vectors()
    test_bundle_length_line()
    test_bundle_layout_is_pinned()
    test_generation_one_layout_is_pinned_and_still_read()
    test_legacy_target_mapping()
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
    test_git_firmware_build()
    test_utc_timestamp()
    test_tile_stream_wire()
    test_audio_wire_and_descriptor()
    test_describe_bundle()

    if failures:
        print("FAILED: %d of %d checks" % (failures, checks))
        return 1
    print("OK: %d checks passed" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
