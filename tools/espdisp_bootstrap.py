#!/usr/bin/env python3
"""Safe, interactive board discovery support for tools/espdisp.py."""

from __future__ import annotations

import copy
import json
import math
import os
import re
import tempfile
import tomllib
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

import board_descriptor


class BootstrapFailure(ValueError):
    """A safe bootstrap refusal with a user-actionable explanation."""


class BootstrapDeviceRefusal(BootstrapFailure):
    """The firmware safely refused one syntactically valid request."""


CHIP_FAMILIES = {
    "esp32c3": "c3",
    "esp32c6": "c6",
    "esp32s3": "s3",
    "esp32p4": "p4",
}

RETUNE_SECTIONS = ("imu", "touch", "color", "offsets", "backlight", "buttons")


class BootstrapConsole:
    COLORS = {
        "prompt": "\x1b[1;36m",
        "fact": "\x1b[1;32m",
        "warning": "\x1b[1;33m",
        "error": "\x1b[1;31m",
        "summary": "\x1b[1;35m",
    }
    RESET = "\x1b[0m"

    def __init__(self, stream, environ: Optional[Mapping[str, str]] = None):
        env = os.environ if environ is None else environ
        self.stream = stream
        self.color = bool(
            hasattr(stream, "isatty") and stream.isatty() and "NO_COLOR" not in env
        )

    def _write(self, kind: str, text: str) -> None:
        prefix = self.COLORS[kind] if self.color else ""
        suffix = self.RESET if self.color else ""
        print(prefix + text + suffix, file=self.stream)

    def prompt(self, text: str) -> None:
        self._write("prompt", "? " + text)

    def fact(self, text: str) -> None:
        self._write("fact", "+ " + text)

    def warning(self, text: str) -> None:
        self._write("warning", "! " + text)

    def error(self, text: str) -> None:
        self._write("error", "REFUSED: " + text)

    def summary(self, text: str) -> None:
        self._write("summary", text)


def _validate_device_value(value: Any, path: str = "response") -> None:
    if isinstance(value, str):
        if len(value) > 4096 or any(
                ord(character) < 0x20 or ord(character) > 0x7E
                for character in value):
            raise BootstrapFailure(
                "unsafe device response text in %s" % path)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise BootstrapFailure(
                    "malformed device response key in %s" % path)
            _validate_device_value(key, path + ".key")
            _validate_device_value(item, path + "." + key)
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_device_value(item, "%s[%d]" % (path, index))
        return
    if value is None or isinstance(value, (bool, int, float)):
        return
    raise BootstrapFailure("malformed device response value in %s" % path)


def parse_bootstrap_response(line: str) -> Dict[str, Any]:
    if not isinstance(line, str):
        raise BootstrapFailure("malformed bootstrap device response")
    prefix, separator, payload = line.strip().partition(" ")
    if not separator or prefix not in ("BOOTOK", "BOOTERR"):
        raise BootstrapFailure("malformed bootstrap device response: %r" % line)
    try:
        decoded = json.loads(payload)
    except (TypeError, ValueError) as exc:
        raise BootstrapFailure(
            "malformed bootstrap device response JSON: %s" % exc
        ) from exc
    if not isinstance(decoded, dict):
        raise BootstrapFailure("malformed bootstrap response payload")
    _validate_device_value(decoded)
    if prefix == "BOOTERR":
        raise BootstrapDeviceRefusal(
            "bootstrap firmware refused: %s"
            % decoded.get("error", decoded.get("message", "unknown error"))
        )
    return decoded


def bootstrap_request(transport, command: str, timeout: float = 5.0) -> Dict[str, Any]:
    try:
        reply = transport.request(command, timeout=timeout)
    except TimeoutError as exc:
        raise BootstrapFailure(
            "bootstrap device timeout while running %s" % command.split()[0]
        ) from exc
    except BootstrapFailure:
        raise
    except Exception as exc:
        raise BootstrapFailure(
            "bootstrap transport failed during %s: %s"
            % (command.split()[0], exc)
        ) from exc
    if isinstance(reply, str):
        return parse_bootstrap_response(reply)
    if not isinstance(reply, dict):
        raise BootstrapFailure("malformed bootstrap device response object")
    _validate_device_value(reply)
    return reply


def require_confirmed_bootstrap_chip(chip: Optional[str]) -> str:
    normalized = re.sub(r"[^a-z0-9]", "", (chip or "").lower())
    if normalized not in CHIP_FAMILIES:
        raise BootstrapFailure(
            "esptool did not confirm a supported chip family; bootstrap refuses "
            "to open the discovery transport"
        )
    return normalized


def _dominant_axis(
    positive: Sequence[int], negative: Sequence[int], label: str
) -> Tuple[int, int]:
    if len(positive) != 3 or len(negative) != 3:
        raise BootstrapFailure("inconsistent IMU %s sample shape" % label)
    delta = [int(positive[i]) - int(negative[i]) for i in range(3)]
    axis = max(range(3), key=lambda index: abs(delta[index]))
    ordered = sorted((abs(value) for value in delta), reverse=True)
    if ordered[0] < 4000 or (ordered[1] and ordered[0] < ordered[1] * 2):
        raise BootstrapFailure(
            "inconsistent IMU sequence: %s does not isolate one axis" % label
        )
    if int(positive[axis]) * int(negative[axis]) >= 0:
        raise BootstrapFailure(
            "inconsistent IMU sequence: %s samples do not oppose" % label
        )
    sign = 1 if int(positive[axis]) > int(negative[axis]) else -1
    return axis, sign


def _validate_imu_pose(vector: Sequence[int], label: str) -> None:
    if len(vector) != 3:
        raise BootstrapFailure("inconsistent IMU %s sample shape" % label)
    ordered = sorted((abs(int(value)) for value in vector), reverse=True)
    if ordered[0] < 4000 or ordered[1] > ordered[0] // 2:
        raise BootstrapFailure(
            "inconsistent IMU sequence: %s does not isolate one gravity axis"
            % label
        )


def solve_imu_mapping(
    samples: Sequence[Tuple[str, Sequence[int]]],
) -> Dict[str, int]:
    by_name = {name: tuple(int(value) for value in vector)
               for name, vector in samples}
    required = ("right_edge", "left_edge", "top_edge", "bottom_edge")
    if any(name not in by_name for name in required):
        raise BootstrapFailure(
            "inconsistent IMU sequence: all four defined edge-down samples are required"
        )
    for name in required:
        _validate_imu_pose(by_name[name], name)
    x_axis, x_sign = _dominant_axis(
        by_name["right_edge"], by_name["left_edge"], "right/left"
    )
    y_axis, y_sign = _dominant_axis(
        by_name["bottom_edge"], by_name["top_edge"], "bottom/top"
    )
    if x_axis == y_axis:
        raise BootstrapFailure(
            "inconsistent IMU sequence: horizontal and vertical use the same axis"
        )
    return {
        "x_axis": x_axis,
        "x_sign": x_sign,
        "y_axis": y_axis,
        "y_sign": y_sign,
    }


def _fit_touch_axis(
    raw_values: Sequence[int], target_values: Sequence[int], span: int, invert: bool
) -> Tuple[float, int]:
    low = min(raw_values)
    high = max(raw_values)
    if high - low < max(8, span // 4):
        return float("inf"), 0
    error = 0.0
    for raw, target in zip(raw_values, target_values):
        ratio = (high - raw if invert else raw - low) / float(high - low)
        predicted = ratio * (span - 1)
        error += abs(predicted - target) / max(1, span - 1)
    return error / len(raw_values), low


def solve_touch_calibration(
    taps: Sequence[Tuple[str, Sequence[int], Sequence[int]]],
    width: int,
    height: int,
) -> Dict[str, Any]:
    if width <= 1 or height <= 1 or len(taps) < 4:
        raise BootstrapFailure("inconsistent touch calibration geometry")
    targets = [(int(target[0]), int(target[1])) for _, target, _ in taps]
    raw = [(int(point[0]), int(point[1])) for _, _, point in taps]
    best = None
    for swap in (False, True):
        source_x = [point[1] if swap else point[0] for point in raw]
        source_y = [point[0] if swap else point[1] for point in raw]
        for invert_x in (False, True):
            x_error, x_offset = _fit_touch_axis(
                source_x, [point[0] for point in targets], width, invert_x
            )
            for invert_y in (False, True):
                y_error, y_offset = _fit_touch_axis(
                    source_y, [point[1] for point in targets], height, invert_y
                )
                score = x_error + y_error
                candidate = (
                    score,
                    {
                        "swap_xy": swap,
                        "invert_x": invert_x,
                        "invert_y": invert_y,
                        "x_offset": x_offset,
                        "y_offset": y_offset,
                        "normalized_error": score,
                    },
                )
                if best is None or candidate[0] < best[0]:
                    best = candidate
    assert best is not None
    if not math.isfinite(best[0]) or best[0] > 0.20:
        raise BootstrapFailure(
            "inconsistent touch taps: no swap/invert transform fits the markers"
        )
    return best[1]


def derive_color_order(answer: str, applied: str) -> str:
    if applied not in ("rgb", "bgr"):
        raise BootstrapFailure("applied color order must be rgb or bgr")
    value = answer.strip().lower()
    if value == "red":
        return applied
    if value == "blue":
        return "bgr" if applied == "rgb" else "rgb"
    raise BootstrapFailure("color answer must be red or blue")


def derive_inversion(answer: str, applied: bool) -> bool:
    value = answer.strip().lower()
    if value == "black":
        return bool(applied)
    if value == "white":
        return not bool(applied)
    raise BootstrapFailure("inversion answer must be black or white")


def derive_mirror_x(answer: str) -> bool:
    value = answer.strip().lower()
    if value in ("normal", "right", "readable"):
        return False
    if value in ("backwards", "left", "mirrored"):
        return True
    raise BootstrapFailure("mirror answer must be normal or backwards")


def _edge_offset(answer: str) -> List[int]:
    value = answer.strip().lower()
    if value in ("", "none", "ok"):
        return [0, 0]
    match = re.fullmatch(
        r"(left|right|top|bottom)(?::|=)(\d+)(?:\s+(?:clipped|wrapped))?",
        value,
    )
    if match is None:
        raise BootstrapFailure(
            "offset answer must be none or edge:pixels, for example left:6"
        )
    edge, amount_text = match.groups()
    amount = int(amount_text)
    if amount > 255:
        raise BootstrapFailure("offset amount must be 0..255")
    direction = 1 if edge in ("left", "top") else -1
    return [direction * amount, 0] if edge in ("left", "right") else [
        0, direction * amount
    ]


def solve_orientation_offsets(answers: Sequence[str]) -> List[List[int]]:
    if len(answers) != 4:
        raise BootstrapFailure("offset calibration requires four orientations")
    return [_edge_offset(answer) for answer in answers]


@dataclass
class BootstrapResult:
    path: str
    descriptor: Dict[str, Any]
    evidence: List[str]


@dataclass(frozen=True)
class ControllerSignature:
    name: str
    addresses: Tuple[int, ...]
    register: int
    register_width: int
    length: int


CONTROLLER_SIGNATURES = (
    ControllerSignature("tca9554", (0x20,), 0x03, 1, 1),
    ControllerSignature("axp2101", (0x34,), 0x03, 1, 1),
    ControllerSignature("gt911", (0x14, 0x5D), 0x8140, 2, 4),
    ControllerSignature("axs5106l", (0x51, 0x63), 0x08, 1, 3),
    ControllerSignature("cst816", (0x15,), 0xA7, 1, 3),
    ControllerSignature("cst9217", (0x5A,), 0xD204, 2, 4),
    ControllerSignature("qmi8658", (0x6A, 0x6B), 0x00, 1, 1),
)


def _signature_accepts(signature: ControllerSignature, data: bytes) -> bool:
    if len(data) != signature.length:
        return False
    if signature.name == "tca9554":
        return True
    if signature.name == "qmi8658":
        return data == b"\x05"
    if signature.name == "gt911":
        return all(0x20 <= value <= 0x7E for value in data)
    if signature.name == "axs5106l":
        return data[:2] == b"\x51\x06"
    if signature.name == "cst9217":
        return data[2:4] in (b"\x17\x92", b"\x20\x92")
    return any(data)


def _hex_bytes(value: Any) -> bytes:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-fA-F]*", value) is None:
        raise BootstrapFailure("malformed I2C register data %r" % value)
    try:
        return bytes.fromhex(value)
    except ValueError as exc:
        raise BootstrapFailure("malformed I2C register data %r" % value) from exc


def _pin_pairs(descriptors: Sequence[Dict[str, Any]]) -> List[Tuple[int, int]]:
    pairs = set()
    for descriptor in descriptors:
        for sda, scl in (
            (descriptor["detection"]["sda"], descriptor["detection"]["scl"]),
            (descriptor["touch"]["sda"], descriptor["touch"]["scl"]),
        ):
            if sda >= 0 and scl >= 0 and sda != scl:
                pairs.add((sda, scl))
    return sorted(pairs)


def _flash_matches(detection: Dict[str, Any], flash_bytes: int) -> bool:
    minimum = detection["flash_min_exclusive"]
    maximum = detection["flash_max_inclusive"]
    if minimum and flash_bytes <= minimum:
        return False
    if maximum and flash_bytes > maximum:
        return False
    return flash_bytes > 0 or (minimum == 0 and maximum == 0)


def _candidate_ack_count(
    candidate: Dict[str, Any],
    scans: Mapping[Tuple[int, int], Sequence[int]],
) -> Optional[int]:
    detection = candidate["detection"]
    pair = (detection["sda"], detection["scl"])
    if pair not in scans:
        return None
    responders = scans[pair]
    if detection["addresses"]:
        expected = set(detection["addresses"])
        return sum(address in expected for address in responders)
    return sum(
        detection["scan_first"] <= address <= detection["scan_last"]
        for address in responders
    )


def _candidate_matches_evidence(
    candidate: Dict[str, Any],
    scans: Mapping[Tuple[int, int], Sequence[int]],
    scan_failures: set[Tuple[int, int]],
    flash_bytes: int,
) -> bool:
    return _candidate_evidence_state(
        candidate, scans, scan_failures, flash_bytes) == "match"


def _candidate_evidence_state(
    candidate: Dict[str, Any],
    scans: Mapping[Tuple[int, int], Sequence[int]],
    scan_failures: set[Tuple[int, int]],
    flash_bytes: int,
) -> str:
    detection = candidate["detection"]
    if not _flash_matches(detection, flash_bytes):
        return "contradicted"
    kind = detection["kind"]
    if kind in ("always", "flash_range"):
        return "match"
    pair = (detection["sda"], detection["scl"])
    if pair in scan_failures:
        return (
            "match"
            if kind == "i2c_any_ack_or_start_failure"
            else "contradicted"
        )
    ack_count = _candidate_ack_count(candidate, scans)
    if ack_count is None:
        return "unknown"
    if kind == "i2c_no_ack":
        return "match" if ack_count == 0 else "contradicted"
    if kind in ("i2c_any_ack", "i2c_any_ack_or_start_failure"):
        return "match" if ack_count > 0 else "contradicted"
    return "contradicted"


def _validated_device_info(
    info: Mapping[str, Any], confirmed_chip: str
) -> Dict[str, Any]:
    reported_chip = re.sub(
        r"[^a-z0-9]", "", str(info.get("chip", "")).lower()
    )
    if reported_chip != confirmed_chip:
        raise BootstrapFailure(
            "esptool confirmed %s but bootstrap firmware reports %s"
            % (confirmed_chip, reported_chip or "unknown")
        )
    values: Dict[str, Any] = {"chip": reported_chip}
    for field, minimum in (
        ("revision", 0),
        ("flash_bytes", 1),
        ("psram_bytes", 0),
    ):
        value = info.get(field)
        if (
            not isinstance(value, int)
            or isinstance(value, bool)
            or value < minimum
        ):
            raise BootstrapFailure(
                "malformed bootstrap INFO field %s" % field
            )
        values[field] = value
    mac = info.get("base_mac")
    if (
        not isinstance(mac, str)
        or re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", mac)
        is None
    ):
        raise BootstrapFailure("malformed bootstrap INFO field base_mac")
    values["base_mac"] = mac.lower()
    return values


def _validated_panel_id(reply: Mapping[str, Any]) -> Optional[str]:
    if not reply.get("supported"):
        return None
    value = reply.get("data")
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-fA-F]{6}", value) is None:
        raise BootstrapFailure(
            "malformed panel read-ID; expected exactly six hex digits")
    return value.lower()


def _derive_battery_scale(reading: str, pin_mv: int) -> int:
    try:
        pack_volts = float(reading)
    except (TypeError, ValueError) as exc:
        raise BootstrapFailure(
            "battery voltage must be a finite positive number") from exc
    if not math.isfinite(pack_volts) or pack_volts <= 0:
        raise BootstrapFailure(
            "battery voltage must be a finite positive number")
    if not isinstance(pin_mv, int) or isinstance(pin_mv, bool) or pin_mv <= 0:
        raise BootstrapFailure("ADC voltage is zero; divider scale is unknown")
    pack_mv = pack_volts * 1000.0
    ratio = pack_mv / pin_mv
    if not math.isfinite(pack_mv) or not math.isfinite(ratio):
        raise BootstrapFailure(
            "battery divider scale must be in schema/runtime range 1..255")
    scale = int(round(ratio))
    if not 1 <= scale <= 255:
        raise BootstrapFailure(
            "battery divider scale must be in schema/runtime range 1..255")
    return scale


def _apply_orientation_adjustments(
    candidate: Dict[str, Any], adjustments: Sequence[Sequence[int]]
) -> List[List[int]]:
    offsets: List[List[int]] = []
    for index, adjustment in enumerate(adjustments):
        base = candidate["orientation"]["offsets"][index]
        updated = [
            int(base[0]) + int(adjustment[0]),
            int(base[1]) + int(adjustment[1]),
        ]
        if any(value < 0 or value > 255 for value in updated):
            raise BootstrapFailure(
                "edge observations require an offset outside schema range "
                "0..255; no offset was guessed"
            )
        offsets.append(updated)
    return offsets


def _choose_candidate(
    candidates: Sequence[Dict[str, Any]],
    scans: Mapping[Tuple[int, int], Sequence[int]],
    scan_failures: set[Tuple[int, int]],
    flash_bytes: int,
    requested: Optional[str],
    prompter,
) -> Tuple[Dict[str, Any], Sequence[Dict[str, Any]]]:
    by_key = {item["key"]: item for item in candidates}
    states = {
        candidate["key"]: _candidate_evidence_state(
            candidate, scans, scan_failures, flash_bytes)
        for candidate in candidates
    }
    plausible = [
        candidate for candidate in candidates
        if states[candidate["key"]] != "contradicted"
    ]
    if requested:
        if requested not in by_key:
            raise BootstrapFailure(
                "candidate descriptor %s is not compatible with the confirmed chip"
                % requested
            )
        if states[requested] == "contradicted":
            raise BootstrapFailure(
                "candidate descriptor %s contradicts observed evidence"
                % requested
            )
        return by_key[requested], plausible
    matches = [
        candidate
        for candidate in sorted(
            candidates, key=lambda item: item["detection"]["order"]
        )
        if states[candidate["key"]] == "match"
    ]
    resolution = candidates[0]["detection"]["resolution"]
    if matches and (
        resolution == "first_match" or len(matches) == 1
    ):
        return matches[0], plausible
    possible = matches or plausible or list(candidates)
    choices = ", ".join(item["key"] for item in possible)
    try:
        selected = prompter.ask(
            "candidate.choice",
            "Automatic evidence is inconclusive. Candidate descriptor (%s):" % choices,
        )
    except (EOFError, KeyboardInterrupt) as exc:
        raise BootstrapFailure("bootstrap aborted while choosing a candidate") from exc
    possible_by_key = {item["key"]: item for item in possible}
    if selected not in possible_by_key:
        raise BootstrapFailure("unknown candidate descriptor %r" % selected)
    return possible_by_key[selected], plausible or possible


def _controller_matches(
    transport,
    scans: Mapping[Tuple[int, int], Sequence[int]],
    timeout: float,
) -> List[Dict[str, Any]]:
    matches = []
    for pair, addresses in scans.items():
        sda, scl = pair
        for address in addresses:
            for signature in CONTROLLER_SIGNATURES:
                if address not in signature.addresses:
                    continue
                try:
                    reply = bootstrap_request(
                        transport,
                        "I2C_READ CONFIRM bus%d_%d %d %d 0x%02X 0x%X %d %d"
                        % (
                            sda,
                            scl,
                            sda,
                            scl,
                            address,
                            signature.register,
                            signature.register_width,
                            signature.length,
                        ),
                        timeout,
                    )
                except BootstrapDeviceRefusal:
                    # A shared-address device that rejects this register is
                    # simply not this signature. Stay inconclusive and safe.
                    continue
                data = _hex_bytes(reply.get("data", ""))
                if _signature_accepts(signature, data):
                    matches.append(
                        {
                            "name": signature.name,
                            "address": address,
                            "sda": sda,
                            "scl": scl,
                            "data": data.hex(),
                        }
                    )
    return matches


def _matched_controller(
    matches: Sequence[Dict[str, Any]], name: str
) -> Optional[Dict[str, Any]]:
    return next((match for match in matches if match["name"] == name), None)


def _forbidden_drive_pins(
    candidates: Sequence[Dict[str, Any]],
) -> Dict[int, List[str]]:
    forbidden: Dict[int, List[str]] = {}
    for candidate in candidates:
        fields = (
            ("carrier.pin_boot", candidate["carrier"]["pin_boot"]),
            ("touch.interrupt", candidate["touch"]["interrupt"]),
            ("power.battery_adc", candidate["power"]["battery_adc"]),
            ("power.charge_status", candidate["power"]["charge_status"]),
            ("power.battery_enable", candidate["power"]["battery_enable"]),
            ("serial.rx", candidate["serial"]["rx"]),
        )
        for field, pin in fields:
            if pin >= 0:
                forbidden.setdefault(pin, []).append(
                    "%s.%s" % (candidate["key"], field)
                )
    return forbidden


def _ensure_safe_drive(
    candidates: Sequence[Dict[str, Any]], pins: Iterable[int], purpose: str
) -> None:
    forbidden = _forbidden_drive_pins(candidates)
    for pin in pins:
        if pin >= 0 and pin in forbidden:
            raise BootstrapFailure(
                "refusing to drive GPIO%d for %s; candidate descriptor set "
                "marks it as %s"
                % (pin, purpose, ", ".join(forbidden[pin]))
            )


def _collect_scan_evidence(
    transport,
    prompter,
    console: BootstrapConsole,
    candidates: Sequence[Dict[str, Any]],
    timeout: float,
    label: str,
) -> Tuple[Dict[Tuple[int, int], List[int]], set[Tuple[int, int]]]:
    safe_pairs: List[Tuple[int, int]] = []
    for sda, scl in _pin_pairs(candidates):
        try:
            _ensure_safe_drive(
                candidates, (sda, scl), "I2C discovery on %s" % label)
        except BootstrapFailure as exc:
            console.warning("Skipping unsafe I2C bus: %s" % exc)
            continue
        safe_pairs.append((sda, scl))
    if safe_pairs:
        console.warning(
            "I2C DISCOVERY DRIVE: each approved SDA/SCL pair will call "
            "Wire.begin(), scan addresses, read known signatures, then return "
            "both pins to INPUT: %s"
            % ", ".join(
                "SDA=%d SCL=%d" % pair for pair in safe_pairs)
        )
        if not _confirm(
            prompter,
            "consent.discovery_i2c",
            "Drive only these union-safe I2C buses for discovery?",
        ):
            raise BootstrapFailure("I2C discovery consent declined")

    scans: Dict[Tuple[int, int], List[int]] = {}
    failures: set[Tuple[int, int]] = set()
    for index, (sda, scl) in enumerate(safe_pairs):
        try:
            reply = bootstrap_request(
                transport,
                "I2C_SCAN CONFIRM %s%d %d %d"
                % (label, index, sda, scl),
                timeout,
            )
        except BootstrapDeviceRefusal:
            failures.add((sda, scl))
            console.warning(
                "I2C SDA=%d SCL=%d would not start; pins were returned to INPUT"
                % (sda, scl)
            )
            continue
        addresses = reply.get("addresses")
        if (
            not isinstance(addresses, list)
            or any(
                not isinstance(address, int)
                or isinstance(address, bool)
                or not 0x08 <= address <= 0x77
                for address in addresses
            )
        ):
            raise BootstrapFailure("malformed I2C scan response")
        scans[(sda, scl)] = sorted(set(addresses))
        console.fact(
            "I2C SDA=%d SCL=%d responders: %s"
            % (
                sda,
                scl,
                ", ".join(
                    "0x%02X" % address for address in scans[(sda, scl)])
                or "none",
            )
        )
    return scans, failures


def _panel_pins(candidate: Dict[str, Any]) -> List[int]:
    carrier = candidate["carrier"]
    pins = [
        carrier["pin_sclk"],
        carrier["pin_mosi"],
        carrier["pin_data1"],
        carrier["pin_data2"],
        carrier["pin_data3"],
        carrier["pin_cs"],
        carrier["pin_dc"],
        carrier["pin_rst"],
    ]
    if candidate["panel"]["bus"] == "mipi_dsi":
        pins.extend(
            [carrier["pin_bl"], candidate["backlight"]["enable_pin"]]
        )
    if (
        candidate["reset"]["expander"] == "tca9554"
        and candidate["reset"]["panel_output"] > 0
    ):
        pins.extend(
            [candidate["touch"]["sda"], candidate["touch"]["scl"]])
    return pins


def _drive_warning(console: BootstrapConsole, candidate: Dict[str, Any]) -> None:
    carrier = candidate["carrier"]
    panel = candidate["panel"]
    if panel["bus"] == "mipi_dsi":
        console.warning(
            "DISPLAY DRIVE: GPIO%d RESET=LOW then HIGH; GPIO%d BACKLIGHT "
            "PWM=0; GPIO%d BL_ENABLE=LOW then HIGH; MIPI DSI lanes toggle"
            % (
                carrier["pin_rst"],
                carrier["pin_bl"],
                candidate["backlight"]["enable_pin"],
            )
        )
    else:
        mode = panel["spi_mode"]
        actions = [
            "GPIO%d SCLK idle=%d then toggles LOW/HIGH"
            % (carrier["pin_sclk"], 1 if mode in (2, 3) else 0),
            "GPIO%d DATA0 toggles LOW/HIGH" % carrier["pin_mosi"],
        ]
        for label, field in (
            ("DATA1", "pin_data1"),
            ("DATA2", "pin_data2"),
            ("DATA3", "pin_data3"),
        ):
            if carrier[field] >= 0:
                actions.append(
                    "GPIO%d %s toggles LOW/HIGH" % (carrier[field], label)
                )
        actions.append(
            "GPIO%d CS=HIGH idle then toggles LOW/HIGH" % carrier["pin_cs"]
        )
        if carrier["pin_dc"] >= 0:
            actions.append(
                "GPIO%d DC toggles LOW/HIGH" % carrier["pin_dc"]
            )
        if carrier["pin_rst"] >= 0:
            actions.append(
                "GPIO%d RESET=LOW then HIGH" % carrier["pin_rst"]
            )
        console.warning("DISPLAY DRIVE: " + "; ".join(actions))
    if candidate["reset"]["expander"] == "tca9554":
        console.warning(
            "DISPLAY DRIVE: TCA9554 at 0x%02X on SDA=%d SCL=%d, EXIO%d "
            "RESET=LOW then HIGH"
            % (
                candidate["reset"]["expander_address"],
                candidate["touch"]["sda"],
                candidate["touch"]["scl"],
                candidate["reset"]["panel_output"],
            )
        )


def _panel_config_command(candidate: Dict[str, Any]) -> str:
    panel = candidate["panel"]
    carrier = candidate["carrier"]
    values = {
        "driver": panel["driver"].lower(),
        "bus": panel["bus"],
        "width": panel["width"],
        "height": panel["height"],
        "clock": panel["pixel_clock_hz"],
        "mode": panel["spi_mode"],
        "col": panel["col_offset"],
        "row": panel["row_offset"],
        "invert": int(panel["invert_color"]),
        "lanes": panel["dsi_data_lanes"],
        "lane_mbps": panel["dsi_lane_mbps"],
        "hbp": panel["hsync_back_porch"],
        "hpw": panel["hsync_pulse_width"],
        "hfp": panel["hsync_front_porch"],
        "vbp": panel["vsync_back_porch"],
        "vpw": panel["vsync_pulse_width"],
        "vfp": panel["vsync_front_porch"],
        "sclk": carrier["pin_sclk"],
        "mosi": carrier["pin_mosi"],
        "data1": carrier["pin_data1"],
        "data2": carrier["pin_data2"],
        "data3": carrier["pin_data3"],
        "cs": carrier["pin_cs"],
        "dc": carrier["pin_dc"],
        "rst": carrier["pin_rst"],
        "bl": carrier["pin_bl"],
        "bl_enable": candidate["backlight"]["enable_pin"],
        "bl_invert": int(candidate["backlight"]["inverted"]),
        "i2c_sda": candidate["touch"]["sda"],
        "i2c_scl": candidate["touch"]["scl"],
        "panel_exio": candidate["reset"]["panel_output"],
    }
    return "PANEL_CONFIG CONFIRM " + " ".join(
        "%s=%s" % item for item in values.items()
    )


def _ask(prompter, key: str, text: str, **kwargs) -> str:
    try:
        return str(prompter.ask(key, text, **kwargs))
    except (EOFError, KeyboardInterrupt) as exc:
        raise BootstrapFailure("bootstrap aborted at prompt %s" % key) from exc


def _confirm(prompter, key: str, text: str) -> bool:
    try:
        return bool(prompter.confirm(key, text))
    except (EOFError, KeyboardInterrupt) as exc:
        raise BootstrapFailure("bootstrap aborted at prompt %s" % key) from exc


def _pause(prompter, key: str, text: str) -> None:
    try:
        prompter.pause(key, text)
    except (EOFError, KeyboardInterrupt) as exc:
        raise BootstrapFailure("bootstrap aborted at prompt %s" % key) from exc


def _toml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, list):
        return "[" + ", ".join(_toml_value(item) for item in value) + "]"
    raise BootstrapFailure("cannot render TOML value %r" % value)


def _safe_comment(note: Any) -> str:
    if not isinstance(note, str) or not note or any(
            ord(character) < 0x20 or ord(character) > 0x7E
            for character in note):
        raise BootstrapFailure("descriptor evidence comment is unsafe")
    return note


def _validate_rendered_descriptor_text(
    text: str, expected: Optional[Mapping[str, Any]] = None
) -> Dict[str, Any]:
    if any(
        character != "\n"
        and (ord(character) < 0x20 or ord(character) > 0x7E)
        for character in text
    ):
        raise BootstrapFailure(
            "rendered descriptor contains unsafe control characters")
    try:
        parsed = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise BootstrapFailure(
            "rendered descriptor is invalid TOML: %s" % exc) from exc
    if expected is not None:
        wanted = copy.deepcopy(dict(expected))
        wanted.pop("_source", None)
        if parsed != wanted:
            raise BootstrapFailure(
                "rendered descriptor does not match the validated draft")
    return parsed


def render_descriptor(
    descriptor: Dict[str, Any], comments: Optional[Mapping[str, Sequence[str]]] = None
) -> str:
    notes = comments or {}
    out: List[str] = []
    for key, value in descriptor.items():
        if key == "_source" or isinstance(value, dict):
            continue
        for note in notes.get(key, ()):
            out.append("# bootstrap evidence: %s" % _safe_comment(note))
        out.append("%s = %s" % (key, _toml_value(value)))
    for section, values in descriptor.items():
        if section == "_source" or not isinstance(values, dict):
            continue
        out.append("")
        out.append("[%s]" % section)
        for key, value in values.items():
            path = section + "." + key
            for note in notes.get(path, ()):
                out.append("# bootstrap evidence: %s" % _safe_comment(note))
            out.append("%s = %s" % (key, _toml_value(value)))
    rendered = "\n".join(out) + "\n"
    _validate_rendered_descriptor_text(rendered, descriptor)
    return rendered


def _identifier(value: str, upper: bool = False) -> str:
    words = re.findall(r"[A-Za-z0-9]+", value)
    if not words:
        return "BOOTSTRAP_BOARD"
    if upper:
        return "_".join(word.upper() for word in words)
    result = "".join(word[:1].upper() + word[1:] for word in words)
    return ("Board" + result) if result[0].isdigit() else result


def _next_unique_number(
    descriptors: Sequence[Dict[str, Any]], path: Tuple[str, ...], step: int = 1
) -> int:
    values = []
    for descriptor in descriptors:
        value: Any = descriptor
        for component in path:
            value = value[component]
        values.append(int(value))
    return max(values) + step


def _validate_detection_reachability(
    family_descriptors: Sequence[Dict[str, Any]],
    draft: Dict[str, Any],
    scans: Mapping[Tuple[int, int], Sequence[int]],
    scan_failures: set[Tuple[int, int]],
    flash_bytes: int,
) -> None:
    ordered = sorted(
        list(family_descriptors) + [draft],
        key=lambda item: item["detection"]["order"],
    )
    matches = [
        descriptor for descriptor in ordered
        if _candidate_matches_evidence(
            descriptor, scans, scan_failures, flash_bytes)
    ]
    resolution = draft["detection"]["resolution"]
    selected = (
        matches[0]
        if resolution == "first_match" and matches
        else matches[0]
        if resolution == "exactly_one" and len(matches) == 1
        else None
    )
    if selected is None or selected["key"] != draft["key"]:
        matched = ", ".join(item["key"] for item in matches) or "none"
        raise BootstrapFailure(
            "draft detection rule is unreachable under %s; captured evidence "
            "selects %s" % (resolution, matched)
        )


def _descriptor_from_evidence(
    descriptors: Sequence[Dict[str, Any]],
    candidate: Dict[str, Any],
    name: str,
    chip: str,
    flash_bytes: int,
    scans: Mapping[Tuple[int, int], Sequence[int]],
    scan_failures: set[Tuple[int, int]],
    matches: Sequence[Dict[str, Any]],
    boot_pin: int,
    boot_observed: bool,
    imu: Optional[Dict[str, int]],
    touch: Optional[Dict[str, Any]],
    color_order: str,
    invert_color: bool,
    offsets: List[List[int]],
    mirror_x: bool,
    panel_id: Optional[str],
    backlight_inverted: bool,
    backlight_enable_active_high: Optional[bool],
    battery_scale: Optional[int],
) -> Tuple[Dict[str, Any], Dict[str, Sequence[str]]]:
    draft = copy.deepcopy(candidate)
    draft.pop("_source", None)
    family = CHIP_FAMILIES[chip]
    family_descriptors = [
        descriptor
        for descriptor in descriptors
        if descriptor["identity"]["target"] == family
    ]
    draft["key"] = name
    draft["catalog_order"] = _next_unique_number(
        family_descriptors, ("catalog_order",), 10
    )
    draft["name"] = name
    draft["hardware"] = [name]
    draft["migration"]["firmware_config"] = "legacy"
    draft["migration"]["config_symbol"] = "CONFIG_" + _identifier(name, upper=True)
    draft["identity"]["profile"] = name
    draft["identity"]["variant"] = _identifier(name)
    draft["identity"]["variant_value"] = _next_unique_number(
        descriptors, ("identity", "variant_value")
    )
    if draft["identity"]["variant_value"] > 255:
        raise BootstrapFailure("no descriptor variant values remain in schema v1")
    draft["identity"]["legacy_targets"] = []

    panel_expander = (
        candidate["reset"]["expander"] == "tca9554"
        and candidate["reset"]["panel_output"] > 0
    )
    draft["carrier"]["pin_boot"] = boot_pin if boot_observed else -1
    draft["carrier"]["pin_rgb_led"] = -1
    draft["led"]["pixel_count"] = 0
    draft["touch"].update(
        {
            "controller": "none",
            "sda": candidate["touch"]["sda"] if panel_expander else -1,
            "scl": candidate["touch"]["scl"] if panel_expander else -1,
            "reset": -1,
            "interrupt": -1,
            "addresses": [],
            "raw_x_mirrored": False,
            "raw_y_mirrored": False,
        }
    )
    draft["motion"].update(
        {
            "controller": "none",
            "address": 0,
            "x_axis": 0,
            "x_sign": 1,
            "y_axis": 1,
            "y_sign": 1,
        }
    )
    draft["reset"].update(
        {
            "expander": candidate["reset"]["expander"]
            if panel_expander else "none",
            "expander_address": candidate["reset"]["expander_address"]
            if panel_expander else 0,
            "panel_output": candidate["reset"]["panel_output"]
            if panel_expander else 0,
            "touch_output": 0,
        }
    )
    draft["backlight"]["enable_pin"] = (
        candidate["backlight"]["enable_pin"]
        if backlight_enable_active_high is not None
        else -1
    )
    draft["power"].update(
        {
            "controller": "none",
            "battery_adc": -1,
            "battery_adc_scale": 0,
            "battery_enable": -1,
            "charge_status": -1,
            "axp_address": 0,
        }
    )
    draft["serial"].update({"bridge": "none", "rx": -1, "tx": -1})

    draft["panel"]["color_order"] = color_order
    draft["panel"]["invert_color"] = invert_color
    draft["panel"]["col_offset"] = offsets[0][0]
    draft["panel"]["row_offset"] = offsets[0][1]
    draft["orientation"]["offsets"] = offsets
    if imu is not None:
        qmi = _matched_controller(matches, "qmi8658")
        draft["motion"].update({"controller": "qmi8658", **imu})
        draft["motion"]["address"] = qmi["address"] if qmi else 0
    if touch is not None:
        if touch["swap_xy"]:
            raise BootstrapFailure(
                "schema v1 cannot represent swapped raw touch axes; "
                "no descriptor was written"
            )
        draft["touch"].update(
            {
                "controller": candidate["touch"]["controller"],
                "sda": candidate["touch"]["sda"],
                "scl": candidate["touch"]["scl"],
                "reset": candidate["touch"]["reset"],
                "interrupt": candidate["touch"]["interrupt"],
                "addresses": list(candidate["touch"]["addresses"]),
            }
        )
        draft["touch"]["raw_x_mirrored"] = bool(touch["invert_x"])
        draft["touch"]["raw_y_mirrored"] = bool(touch["invert_y"])
    draft["backlight"]["inverted"] = backlight_inverted
    if battery_scale is not None:
        draft["power"].update(
            {
                "controller": "battery_adc",
                "battery_adc": candidate["power"]["battery_adc"],
                "battery_adc_scale": battery_scale,
            }
        )

    populated = [
        (pair, list(addresses)) for pair, addresses in scans.items() if addresses
    ]
    if not populated:
        raise BootstrapFailure(
            "no I2C responder evidence exists for a safe unique detection rule"
        )
    populated.sort(key=lambda item: (-len(item[1]), item[0]))
    (sda, scl), addresses = populated[0]
    draft["detection"].update(
        {
            "order": _next_unique_number(
                family_descriptors, ("detection", "order"), 10
            ),
            "kind": "i2c_any_ack",
            "flash_min_exclusive": 0,
            "flash_max_inclusive": 0,
            "sda": sda,
            "scl": scl,
            "frequency_hz": 100000,
            "scan_first": 0,
            "scan_last": 0,
            "addresses": list(addresses[:4]),
            "reset_pin": -1,
            "reset_low_ms": 0,
            "reset_release_wait_ms": 0,
            "release": "always",
        }
    )
    _validate_detection_reachability(
        family_descriptors, draft, scans, scan_failures, flash_bytes)

    comments: Dict[str, Sequence[str]] = {
        "schema": ["schema v1 required by boards/schema-v1.json"],
        "key": ["human-supplied draft key"],
        "catalog_order": ["allocated after existing %s descriptors" % family],
        "name": ["human-supplied draft name"],
        "hardware": ["drafted by an interactive synthetic/replayable session"],
        "migration.firmware_config": [
            "legacy until a human reviews generated firmware compatibility"
        ],
        "migration.config_symbol": ["derived uniquely from the draft key"],
        "identity.target": ["derived from esptool-confirmed chip %s" % chip],
        "identity.chip": ["confirmed independently by esptool and firmware INFO"],
        "identity.profile": ["derived from the draft key"],
        "identity.partition": [
            "family build contract inherited from candidate %s" % candidate["key"]
        ],
        "identity.variant": ["allocated uniquely from the draft key"],
        "identity.variant_value": ["allocated after all existing variants"],
        "identity.legacy_targets": ["new draft has no legacy CLI aliases"],
        "panel.symbol": [
            "candidate panel profile inherited from %s" % candidate["key"]
        ],
        "panel.profile": [
            "candidate panel profile inherited from %s" % candidate["key"]
        ],
        "panel.driver": [
            "candidate controller inherited from %s; panel read-ID %s"
            % (candidate["key"], panel_id or "was unavailable")
        ],
        "panel.color_order": [
            "red fill observation interpreted relative to applied %s order"
            % candidate["panel"]["color_order"]
        ],
        "panel.invert_color": [
            "black fill observation interpreted relative to applied invert=%s"
            % ("true" if candidate["panel"]["invert_color"] else "false")
        ],
        "orientation.offsets": [
            "edge-marker answers produced %s" % offsets
        ],
        "orientation.mirror_x_supported": [
            "asymmetric glyph read %s; schema v1 records support, not a default mirror"
            % ("backwards" if mirror_x else "normally")
        ],
        "carrier.pin_boot": [
            "level change observed during BOOT watch"
            if boot_observed
            else "BOOT watch was inconclusive; emitted inert as -1"
        ],
        "backlight.inverted": ["low/high brightness ramp observation"],
        "detection.order": ["allocated after existing %s detection rules" % family],
        "detection.kind": ["automatic scan produced one or more responders"],
        "detection.sda": ["automatic responder scan selected this bus"],
        "detection.scl": ["automatic responder scan selected this bus"],
        "detection.addresses": [
            "automatic scan found %s on SDA=%d SCL=%d"
            % (", ".join("0x%02X" % address for address in addresses), sda, scl)
        ],
        "detection.reset_pin": [
            "left disabled because discovery did not prove a safe reset output"
        ],
    }
    if touch is not None:
        comments["touch.controller"] = [
            "candidate %s plus matching controller signature" % candidate["key"]
        ]
        comments["touch.raw_x_mirrored"] = [
            "four marker taps solved swap=%s invert_x=%s raw offset=%d"
            % (touch["swap_xy"], touch["invert_x"], touch["x_offset"])
        ]
        comments["touch.raw_y_mirrored"] = [
            "four marker taps solved invert_y=%s raw offset=%d"
            % (touch["invert_y"], touch["y_offset"])
        ]
    if imu is not None:
        comments["motion.controller"] = ["QMI8658 WHOAMI returned 0x05"]
        comments["motion.address"] = ["QMI8658 WHOAMI address from automatic scan"]
        comments["motion.x_axis"] = [
            "four-position edge-down sequence solved X axis/sign"
        ]
        comments["motion.y_axis"] = [
            "four-position edge-down sequence solved Y axis/sign"
        ]
    if battery_scale is not None:
        comments["power.battery_adc_scale"] = [
            "multimeter voltage divided by measured ADC pin voltage"
        ]
    if backlight_enable_active_high is not None:
        comments["backlight.enable_pin"] = [
            "HIGH/LOW visibility test confirmed active-high enable"
        ]
    active_electrical = {
        "carrier.pin_sclk", "carrier.pin_mosi", "carrier.pin_data1",
        "carrier.pin_data2", "carrier.pin_data3", "carrier.pin_cs",
        "carrier.pin_dc", "carrier.pin_rst", "carrier.pin_bl",
        "backlight.kind", "backlight.inverted",
    }
    if boot_observed:
        active_electrical.add("carrier.pin_boot")
    if touch is not None:
        active_electrical.update(
            "touch." + field for field in (
                "controller", "sda", "scl", "reset", "interrupt", "addresses",
                "raw_x_mirrored", "raw_y_mirrored",
            )
        )
    elif panel_expander:
        active_electrical.update(("touch.sda", "touch.scl"))
    if imu is not None:
        active_electrical.update(
            "motion." + field for field in (
                "controller", "address", "x_axis", "x_sign",
                "y_axis", "y_sign",
            )
        )
    if panel_expander:
        active_electrical.update(
            "reset." + field for field in (
                "expander", "expander_address", "panel_output",
            )
        )
    if backlight_enable_active_high is not None:
        active_electrical.add("backlight.enable_pin")
    if battery_scale is not None:
        active_electrical.update(
            "power." + field for field in (
                "controller", "battery_adc", "battery_adc_scale",
            )
        )
    electrical_sections = {
        "carrier", "touch", "led", "motion", "reset",
        "backlight", "power", "serial",
    }
    for top_key, top_value in draft.items():
        if isinstance(top_value, dict):
            for field in top_value:
                path = top_key + "." + field
                if path not in comments:
                    if top_key == "panel" or path in active_electrical:
                        comments[path] = [
                            "candidate value exercised during bootstrap bring-up"
                        ]
                    elif top_key in electrical_sections:
                        comments[path] = [
                            "not measured; emitted inert or geometry-only by policy"
                        ]
                    else:
                        comments[path] = [
                            "non-electrical family value inherited from candidate %s"
                            % candidate["key"]
                        ]
        elif top_key not in comments:
            comments[top_key] = [
                "non-electrical family value inherited from candidate %s"
                % candidate["key"]
            ]
    return draft, comments


def write_text_atomically(
    path: str, text: str, overwrite: bool = False
) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    if os.path.exists(path) and not overwrite:
        raise BootstrapFailure("refusing to overwrite existing descriptor %s" % path)
    mode = 0o644
    if os.path.exists(path):
        mode = os.stat(path).st_mode & 0o777
    fd, temporary = tempfile.mkstemp(
        dir=directory, prefix=os.path.basename(path) + ".", suffix=".partial"
    )
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _touch_targets(width: int, height: int) -> List[Tuple[str, Tuple[int, int]]]:
    margin_x = max(8, width // 20)
    margin_y = max(8, height // 40)
    return [
        ("top_left", (margin_x, margin_y)),
        ("top_right", (width - 1 - margin_x, margin_y)),
        ("bottom_left", (margin_x, height - 1 - margin_y)),
        ("bottom_right", (width - 1 - margin_x, height - 1 - margin_y)),
    ]


def _selected_touch_controller(
    candidate: Dict[str, Any], matches: Sequence[Dict[str, Any]]
) -> Optional[Dict[str, Any]]:
    wanted = candidate["touch"]["controller"]
    if wanted == "none":
        return None
    return _matched_controller(matches, wanted)


def _read_imu_sequence(
    transport,
    prompter,
    console: BootstrapConsole,
    match: Dict[str, Any],
    timeout: float,
) -> Dict[str, int]:
    console.warning(
        "IMU CONFIG DRIVE: I2C SDA=%d SCL=%d address=0x%02X; write QMI8658 "
        "RESET/CTRL1/CTRL2/CTRL7 before raw reads"
        % (match["sda"], match["scl"], match["address"])
    )
    if not _confirm(
        prompter,
        "consent.imu",
        "Configure only this WHOAMI-confirmed QMI8658 for acceleration reads?",
    ):
        raise BootstrapFailure("IMU configuration consent declined")
    bootstrap_request(
        transport,
        "IMU_CONFIG CONFIRM %d %d 0x%02X"
        % (match["sda"], match["scl"], match["address"]),
        timeout,
    )
    instructions = (
        ("right_edge", "Place the board with its RIGHT edge down, then press Enter."),
        ("left_edge", "Place the board with its LEFT edge down, then press Enter."),
        ("top_edge", "Place the board with its TOP edge down, then press Enter."),
        ("bottom_edge", "Place the board with its BOTTOM edge down, then press Enter."),
    )
    for attempt in range(2):
        samples = []
        for name, text in instructions:
            _pause(prompter, "imu." + name, text)
            reply = bootstrap_request(
                transport,
                "IMU_READ CONFIRM %d %d 0x%02X"
                % (match["sda"], match["scl"], match["address"]),
                timeout,
            )
            try:
                vector = (int(reply["x"]), int(reply["y"]), int(reply["z"]))
            except (KeyError, TypeError, ValueError) as exc:
                raise BootstrapFailure("malformed IMU vector response") from exc
            console.fact("%s acceleration = %s" % (name, vector))
            samples.append((name, vector))
        try:
            return solve_imu_mapping(samples)
        except BootstrapFailure:
            if attempt == 0:
                console.warning(
                    "The edge-down sequence was inconsistent; no mapping was guessed. "
                    "Repeat all four positions."
                )
                continue
            raise
    raise BootstrapFailure("inconsistent IMU sequence")


def _read_touch_calibration(
    transport,
    prompter,
    console: BootstrapConsole,
    candidate: Dict[str, Any],
    safety_candidates: Sequence[Dict[str, Any]],
    controller: Dict[str, Any],
    timeout: float,
) -> Dict[str, Any]:
    touch = candidate["touch"]
    _ensure_safe_drive(
        safety_candidates, [touch["reset"]], "touch calibration"
    )
    if touch["reset"] >= 0 and touch["reset"] != candidate["carrier"]["pin_rst"]:
        console.warning(
            "TOUCH DRIVE: GPIO%d RESET=LOW then HIGH; GPIO%d remains INPUT"
            % (touch["reset"], touch["interrupt"])
        )
    elif candidate["reset"]["touch_output"]:
        console.warning(
            "TOUCH DRIVE: TCA9554 at 0x%02X EXIO%d RESET=LOW then HIGH; "
            "GPIO%d remains INPUT"
            % (
                candidate["reset"]["expander_address"],
                candidate["reset"]["touch_output"],
                touch["interrupt"],
            )
        )
    if not _confirm(
        prompter,
        "consent.touch",
        "Drive the display markers and read the touch controller?",
    ):
        raise BootstrapFailure("display/touch drive consent declined")
    bootstrap_request(
        transport,
        "TOUCH_CONFIG CONFIRM %s %d %d 0x%02X %d %d %d 0x%02X %d"
        % (
            controller["name"],
            controller["sda"],
            controller["scl"],
            controller["address"],
            touch["reset"],
            touch["interrupt"],
            candidate["reset"]["touch_output"],
            candidate["reset"]["expander_address"],
            int(touch["reset"] == candidate["carrier"]["pin_rst"]),
        ),
        timeout,
    )
    width = candidate["panel"]["width"]
    height = candidate["panel"]["height"]
    taps = []
    for name, target in _touch_targets(width, height):
        bootstrap_request(
            transport,
            "PANEL_EDGES CONFIRM marker=%s x=%d y=%d"
            % (name, target[0], target[1]),
            timeout,
        )
        _pause(
            prompter,
            "touch." + name,
            "Tap the %s marker once, then press Enter."
            % name.replace("_", " "),
        )
        reply = bootstrap_request(
            transport,
            "TOUCH_READ CONFIRM %s %d %d 0x%02X"
            % (
                controller["name"],
                controller["sda"],
                controller["scl"],
                controller["address"],
            ),
            timeout,
        )
        try:
            raw = (int(reply["x"]), int(reply["y"]))
        except (KeyError, TypeError, ValueError) as exc:
            raise BootstrapFailure("malformed touch sample response") from exc
        console.fact("%s raw touch = %s" % (name, raw))
        taps.append((name, target, raw))
    return solve_touch_calibration(taps, width, height)


def _derive_backlight(
    transport,
    prompter,
    console: BootstrapConsole,
    candidate: Dict[str, Any],
    safety_candidates: Sequence[Dict[str, Any]],
    timeout: float,
) -> Dict[str, Optional[bool]]:
    pin = candidate["carrier"]["pin_bl"]
    if pin < 0 and candidate["backlight"]["kind"] == "none":
        return {
            "inverted": candidate["backlight"]["inverted"],
            "enable_active_high": None,
        }
    if pin >= 0:
        _ensure_safe_drive(
            safety_candidates, [pin], "backlight calibration"
        )
    for key, level in (("low", 32), ("high", 224)):
        if pin >= 0:
            console.warning("BACKLIGHT DRIVE: GPIO%d PWM level=%d" % (pin, level))
        else:
            console.warning(
                "BACKLIGHT DRIVE: panel brightness command level=%d (no GPIO)" % level
            )
        if not _confirm(
            prompter,
            "consent.backlight." + key,
            (
                "Drive GPIO%d to PWM level %d?" % (pin, level)
                if pin >= 0
                else "Send panel brightness command level %d?" % level
            ),
        ):
            raise BootstrapFailure("backlight drive consent declined")
        bootstrap_request(
            transport, "BACKLIGHT CONFIRM %d %d" % (pin, level), timeout
        )
    answer = _ask(
        prompter,
        "backlight.change",
        "Did the second level make the panel brighter or dimmer?",
    ).strip().lower()
    if answer == "brighter":
        inverted = False
    elif answer == "dimmer":
        inverted = True
    else:
        raise BootstrapFailure("backlight answer must be brighter or dimmer")

    enable_pin = candidate["backlight"]["enable_pin"]
    enable_active_high = None
    if enable_pin >= 0:
        _ensure_safe_drive(
            safety_candidates, [enable_pin], "backlight enable calibration"
        )
        observations = {}
        for label, level in (("high", 1), ("low", 0)):
            console.warning(
                "BACKLIGHT ENABLE DRIVE: GPIO%d level=%s"
                % (enable_pin, label.upper())
            )
            if not _confirm(
                prompter,
                "consent.backlight.enable." + label,
                "Drive GPIO%d to %s?" % (enable_pin, label.upper()),
            ):
                raise BootstrapFailure("backlight enable drive consent declined")
            bootstrap_request(
                transport,
                "BACKLIGHT_ENABLE CONFIRM %d %d" % (enable_pin, level),
                timeout,
            )
            observations[label] = _ask(
                prompter,
                "backlight.enable." + label,
                "With enable %s, is the panel on or off?" % label.upper(),
            ).strip().lower()
        if observations == {"high": "on", "low": "off"}:
            enable_active_high = True
        elif observations == {"high": "off", "low": "on"}:
            raise BootstrapFailure(
                "schema v1 cannot represent an active-low backlight enable; "
                "no descriptor was written"
            )
        else:
            raise BootstrapFailure(
                "backlight enable observations are inconsistent; no sense was guessed"
            )
    return {
        "inverted": inverted,
        "enable_active_high": enable_active_high,
    }


def run_bootstrap_session(
    *,
    transport,
    prompter,
    stream,
    repo_root: str,
    name: str,
    candidate_key: Optional[str],
    confirmed_chip: Optional[str],
    output_path: Optional[str] = None,
    timeout: float = 5.0,
) -> BootstrapResult:
    console = BootstrapConsole(stream)
    if re.fullmatch(r"[a-z0-9][a-z0-9-]*", name) is None:
        raise BootstrapFailure(
            "descriptor key must use lowercase letters, digits, and hyphens"
        )
    chip = require_confirmed_bootstrap_chip(confirmed_chip)
    family = CHIP_FAMILIES[chip]
    descriptors = list(board_descriptor.load_repository_descriptors(repo_root))
    candidates = [
        descriptor
        for descriptor in descriptors
        if descriptor["identity"]["target"] == family
    ]
    if not candidates:
        raise BootstrapFailure("no descriptor candidates exist for family %s" % family)

    info = _validated_device_info(
        bootstrap_request(transport, "INFO", timeout), chip
    )
    console.fact(
        "chip=%s revision=%s flash=%s PSRAM=%s MAC=%s"
        % (
            chip,
            info["revision"],
            info["flash_bytes"],
            info["psram_bytes"],
            info["base_mac"],
        )
    )

    scans, scan_failures = _collect_scan_evidence(
        transport, prompter, console, candidates, timeout, "bus")
    matches = _controller_matches(transport, scans, timeout)
    for match in matches:
        console.fact(
            "%s signature at 0x%02X on SDA=%d SCL=%d (WHOAMI %s)"
            % (
                match["name"],
                match["address"],
                match["sda"],
                match["scl"],
                match["data"],
            )
        )
    candidate, safety_candidates = _choose_candidate(
        candidates,
        scans,
        scan_failures,
        info["flash_bytes"],
        candidate_key,
        prompter,
    )
    console.fact("candidate panel/carrier template: %s" % candidate["key"])
    if len(safety_candidates) > 1:
        console.warning(
            "Drive safety remains constrained by all possible candidates: %s"
            % ", ".join(item["key"] for item in safety_candidates)
        )

    button_pins = sorted(
        {
            descriptor["carrier"]["pin_boot"]
            for descriptor in candidates
            if descriptor["carrier"]["pin_boot"] >= 0
        }
    )
    boot_pin = candidate["carrier"]["pin_boot"]
    boot_observed = False
    if button_pins:
        _pause(
            prompter,
            "buttons.ready",
            "Press Enter, then press and release BOOT during the watch window.",
        )
        try:
            button_reply = bootstrap_request(
                transport,
                "GPIO_WATCH 5000 " + ",".join(str(pin) for pin in button_pins),
                timeout + 5.0,
            )
        except BootstrapDeviceRefusal:
            console.warning(
                "BOOT watch was inconclusive; the candidate value is retained "
                "and explicitly marked unverified"
            )
        else:
            try:
                boot_pin = int(button_reply["pin"])
            except (KeyError, TypeError, ValueError) as exc:
                raise BootstrapFailure(
                    "malformed BOOT pin watch response"
                ) from exc
            if boot_pin not in button_pins:
                raise BootstrapFailure(
                    "BOOT pin watch returned a non-candidate GPIO"
                )
            boot_observed = True
            console.fact("BOOT level change observed on GPIO%d" % boot_pin)
    else:
        console.fact("candidate set declares no BOOT GPIO to watch")

    qmi = _matched_controller(matches, "qmi8658")
    imu = _read_imu_sequence(
        transport, prompter, console, qmi, timeout
    ) if qmi else None
    if imu:
        console.fact(
            "IMU mapping: X=axis%d sign=%+d, Y=axis%d sign=%+d"
            % (imu["x_axis"], imu["x_sign"], imu["y_axis"], imu["y_sign"])
        )

    _ensure_safe_drive(
        safety_candidates, _panel_pins(candidate), "panel calibration"
    )
    _drive_warning(console, candidate)
    if not _confirm(
        prompter,
        "consent.panel_config",
        "Initialize exactly this candidate display bus and pin set, then "
        "attempt a controller read-ID on the same bus?",
    ):
        raise BootstrapFailure("panel drive consent declined")
    bootstrap_request(transport, _panel_config_command(candidate), timeout + 5.0)
    panel_id_reply = bootstrap_request(
        transport, "PANEL_READ_ID CONFIRM", timeout
    )
    panel_id = _validated_panel_id(panel_id_reply)
    if panel_id:
        console.fact("panel read-ID = %s" % panel_id)
    else:
        console.fact("panel read-ID is unavailable on this candidate bus")

    touch_controller = _selected_touch_controller(candidate, matches)
    touch = (
        _read_touch_calibration(
            transport,
            prompter,
            console,
            candidate,
            safety_candidates,
            touch_controller,
            timeout,
        )
        if touch_controller
        else None
    )

    console.warning("DISPLAY DRIVE: fill entire candidate panel with RGB565 red")
    if not _confirm(prompter, "consent.color", "Drive the panel with a red fill?"):
        raise BootstrapFailure("color-test drive consent declined")
    bootstrap_request(transport, "PANEL_FILL CONFIRM red", timeout)
    color_order = derive_color_order(
        _ask(prompter, "color.red", "Does the panel look red or blue?"),
        candidate["panel"]["color_order"],
    )

    console.warning("DISPLAY DRIVE: fill entire candidate panel with RGB565 black")
    if not _confirm(
        prompter, "consent.inversion", "Drive the panel with a black fill?"
    ):
        raise BootstrapFailure("inversion-test drive consent declined")
    bootstrap_request(transport, "PANEL_FILL CONFIRM black", timeout)
    invert_color = derive_inversion(
        _ask(prompter, "color.black", "Does the panel look black or white?"),
        candidate["panel"]["invert_color"],
    )

    console.warning(
        "DISPLAY DRIVE: draw four orientation edge cards using the candidate bus"
    )
    if not _confirm(
        prompter, "consent.offsets", "Drive the four edge-marker patterns?"
    ):
        raise BootstrapFailure("offset-test drive consent declined")
    offset_answers = []
    for orientation in range(4):
        bootstrap_request(
            transport, "PANEL_EDGES CONFIRM orientation=%d" % orientation, timeout
        )
        offset_answers.append(
            _ask(
                prompter,
                "offsets.%d" % orientation,
                "Orientation %d: none, or clipped/wrapped edge:pixels?" % orientation,
                default="none",
            )
        )
    adjustments = solve_orientation_offsets(offset_answers)
    offsets = _apply_orientation_adjustments(candidate, adjustments)

    console.warning("DISPLAY DRIVE: draw an asymmetric right-reading glyph")
    if not _confirm(
        prompter, "consent.mirror", "Drive the asymmetric mirror-test glyph?"
    ):
        raise BootstrapFailure("mirror-test drive consent declined")
    bootstrap_request(transport, "PANEL_GLYPH CONFIRM", timeout)
    mirror_x = derive_mirror_x(
        _ask(
            prompter,
            "mirror.reading",
            "Does the glyph read normally or backwards?",
        )
    )

    backlight = _derive_backlight(
        transport, prompter, console, candidate, safety_candidates, timeout
    )

    battery_scale = None
    adc_pin = candidate["power"]["battery_adc"]
    if adc_pin >= 0 and candidate["power"]["battery_enable"] < 0:
        reading = _ask(
            prompter,
            "battery.multimeter",
            "Battery pack voltage from a multimeter in volts (blank to skip):",
            default="",
            allow_empty=True,
        ).strip()
        if reading:
            adc = bootstrap_request(
                transport, "ADC_READ %d" % adc_pin, timeout
            )
            try:
                pin_mv = int(adc["millivolts"])
            except (KeyError, TypeError, ValueError) as exc:
                raise BootstrapFailure("malformed ADC response") from exc
            battery_scale = _derive_battery_scale(reading, pin_mv)
            pack_mv = float(reading) * 1000.0
            console.fact(
                "battery divider scale=%d from %.0fmV / %dmV"
                % (battery_scale, pack_mv, pin_mv)
            )

    draft, comments = _descriptor_from_evidence(
        descriptors,
        candidate,
        name,
        chip,
        info["flash_bytes"],
        scans,
        scan_failures,
        matches,
        boot_pin,
        boot_observed,
        imu,
        touch,
        color_order,
        invert_color,
        offsets,
        mirror_x,
        panel_id,
        bool(backlight["inverted"]),
        backlight["enable_active_high"],
        battery_scale,
    )
    draft["_source"] = "boards/%s.toml" % name
    board_descriptor.validate_descriptors(descriptors + [draft])
    draft.pop("_source", None)
    path = output_path or os.path.join(repo_root, "boards", name + ".toml")
    overwrite = False
    if os.path.exists(path):
        console.warning("Descriptor already exists: %s" % path)
        overwrite = _confirm(
            prompter, "overwrite", "Explicitly overwrite this existing descriptor?"
        )
        if not overwrite:
            raise BootstrapFailure("existing descriptor overwrite declined")
    rendered = render_descriptor(draft, comments)
    _validate_rendered_descriptor_text(rendered, draft)
    write_text_atomically(path, rendered, overwrite)
    evidence = [
        "chip %s confirmed independently by esptool and firmware" % chip,
        "%d I2C controller signatures matched" % len(matches),
        "BOOT observed on GPIO%d" % boot_pin,
    ]
    console.summary("Draft descriptor: %s" % path)
    console.summary(
        "Closing loop: validate -> regenerate -> compile -> flash -> confirm bring-up"
    )
    return BootstrapResult(path, draft, evidence)


RETUNE_FIELD_MAP = {
    "imu": {
        "x_axis": ("motion", "x_axis"),
        "x_sign": ("motion", "x_sign"),
        "y_axis": ("motion", "y_axis"),
        "y_sign": ("motion", "y_sign"),
    },
    "touch": {
        "raw_x_mirrored": ("touch", "raw_x_mirrored"),
        "raw_y_mirrored": ("touch", "raw_y_mirrored"),
        "rotate_clockwise": ("touch", "rotate_clockwise"),
    },
    "color": {
        "color_order": ("panel", "color_order"),
        "invert_color": ("panel", "invert_color"),
    },
    "offsets": {
        "col_offset": ("panel", "col_offset"),
        "row_offset": ("panel", "row_offset"),
        "offsets": ("orientation", "offsets"),
    },
    "backlight": {
        "inverted": ("backlight", "inverted"),
        "enable_pin": ("backlight", "enable_pin"),
    },
    "buttons": {
        "pin_boot": ("carrier", "pin_boot"),
    },
}


def retune_descriptor_text(
    text: str,
    section: str,
    updates: Mapping[str, Any],
    evidence: Sequence[str],
) -> str:
    if section not in RETUNE_FIELD_MAP:
        raise BootstrapFailure("unknown retune section %r" % section)
    paths = RETUNE_FIELD_MAP[section]
    unknown = sorted(set(updates).difference(paths))
    if unknown:
        raise BootstrapFailure(
            "retune %s does not accept field %s" % (section, unknown[0])
        )
    result = text
    touched_sections = set()
    for key, value in updates.items():
        table, field = paths[key]
        table_match = re.search(
            r"(?m)^\[%s\]\s*$" % re.escape(table), result
        )
        if table_match is None:
            raise BootstrapFailure("descriptor has no [%s] section" % table)
        next_table = re.search(r"(?m)^\[", result[table_match.end():])
        end = (
            table_match.end() + next_table.start()
            if next_table is not None
            else len(result)
        )
        body = result[table_match.end():end]
        pattern = re.compile(r"(?m)^%s\s*=.*$" % re.escape(field))
        if pattern.search(body) is None:
            raise BootstrapFailure(
                "descriptor has no %s.%s field" % (table, field)
            )
        body = pattern.sub("%s = %s" % (field, _toml_value(value)), body, count=1)
        result = result[:table_match.end()] + body + result[end:]
        touched_sections.add(table)
    for table in sorted(touched_sections):
        marker = "[%s]" % table
        comment = "\n".join(
            "# bootstrap retune evidence: %s" % _safe_comment(note)
            for note in evidence
        )
        result = result.replace(marker, marker + "\n" + comment, 1)
    _validate_rendered_descriptor_text(result)
    return result


def run_retune_session(
    *,
    transport,
    prompter,
    stream,
    repo_root: str,
    board_key: str,
    section: str,
    confirmed_chip: Optional[str],
    timeout: float = 5.0,
) -> BootstrapResult:
    if section not in RETUNE_SECTIONS:
        raise BootstrapFailure("retune requires one of %s" % ", ".join(RETUNE_SECTIONS))
    chip = require_confirmed_bootstrap_chip(confirmed_chip)
    descriptors = list(board_descriptor.load_repository_descriptors(repo_root))
    normalized_key = os.path.basename(board_key)
    if normalized_key.endswith(".toml"):
        normalized_key = normalized_key[:-5]
    candidate = next(
        (item for item in descriptors if item["key"] == normalized_key), None
    )
    if candidate is None:
        raise BootstrapFailure("unknown board descriptor %r" % board_key)
    if candidate["identity"]["chip"] != chip:
        raise BootstrapFailure(
            "esptool confirmed %s but %s describes %s"
            % (chip, normalized_key, candidate["identity"]["chip"])
        )
    console = BootstrapConsole(stream)
    info = _validated_device_info(
        bootstrap_request(transport, "INFO", timeout), chip
    )
    console.fact("retuning %s section %s" % (normalized_key, section))

    family_candidates = [
        item for item in descriptors
        if item["identity"]["target"] == candidate["identity"]["target"]
    ]
    scans, scan_failures = _collect_scan_evidence(
        transport, prompter, console, family_candidates, timeout, "retune")
    candidate, safety_candidates = _choose_candidate(
        family_candidates,
        scans,
        scan_failures,
        info["flash_bytes"],
        normalized_key,
        prompter,
    )
    matches: List[Dict[str, Any]] = []
    if section in ("imu", "touch"):
        matches = _controller_matches(transport, scans, timeout)

    updates: Dict[str, Any]
    evidence: List[str]
    if section == "imu":
        qmi = _matched_controller(matches, "qmi8658")
        if qmi is None:
            raise BootstrapFailure("retune imu found no QMI8658 WHOAMI signature")
        updates = _read_imu_sequence(
            transport, prompter, console, qmi, timeout
        )
        evidence = ["edge-down sequence solved axes and signs"]
    elif section == "touch":
        controller = _selected_touch_controller(candidate, matches)
        if controller is None:
            raise BootstrapFailure(
                "retune touch found no matching controller WHOAMI signature"
            )
        _ensure_safe_drive(
            safety_candidates, _panel_pins(candidate), "touch retune"
        )
        _drive_warning(console, candidate)
        if not _confirm(
            prompter,
            "consent.panel_config",
            "Initialize this descriptor's panel for touch markers, then "
            "attempt a controller read-ID on the same bus?",
        ):
            raise BootstrapFailure("panel drive consent declined")
        bootstrap_request(transport, _panel_config_command(candidate), timeout + 5.0)
        panel_id_reply = bootstrap_request(
            transport, "PANEL_READ_ID CONFIRM", timeout
        )
        panel_id = _validated_panel_id(panel_id_reply)
        if panel_id:
            console.fact("panel read-ID = %s" % panel_id)
        touch = _read_touch_calibration(
            transport,
            prompter,
            console,
            candidate,
            safety_candidates,
            controller,
            timeout,
        )
        if touch["swap_xy"]:
            raise BootstrapFailure(
                "schema v1 cannot represent swapped raw touch axes; "
                "the descriptor was not changed"
            )
        updates = {
            "raw_x_mirrored": bool(touch["invert_x"]),
            "raw_y_mirrored": bool(touch["invert_y"]),
        }
        evidence = [
            "four marker taps solved swap=%s invert_x=%s invert_y=%s"
            % (touch["swap_xy"], touch["invert_x"], touch["invert_y"])
        ]
    elif section in ("color", "offsets"):
        _ensure_safe_drive(
            safety_candidates, _panel_pins(candidate), section + " retune"
        )
        _drive_warning(console, candidate)
        if not _confirm(
            prompter,
            "consent.panel_config",
            "Initialize this descriptor's panel for %s retuning?" % section,
        ):
            raise BootstrapFailure("panel drive consent declined")
        bootstrap_request(transport, _panel_config_command(candidate), timeout + 5.0)
        if section == "color":
            console.warning("DISPLAY DRIVE: RGB565 red fill")
            if not _confirm(prompter, "consent.color", "Drive a red fill?"):
                raise BootstrapFailure("color-test drive consent declined")
            bootstrap_request(transport, "PANEL_FILL CONFIRM red", timeout)
            order = derive_color_order(
                _ask(prompter, "color.red", "Does the panel look red or blue?"),
                candidate["panel"]["color_order"],
            )
            console.warning("DISPLAY DRIVE: RGB565 black fill")
            if not _confirm(
                prompter, "consent.inversion", "Drive a black fill?"
            ):
                raise BootstrapFailure("inversion-test drive consent declined")
            bootstrap_request(transport, "PANEL_FILL CONFIRM black", timeout)
            inverted = derive_inversion(
                _ask(prompter, "color.black", "Does it look black or white?"),
                candidate["panel"]["invert_color"],
            )
            updates = {"color_order": order, "invert_color": inverted}
            evidence = ["red/blue and black/white observations"]
        else:
            console.warning("DISPLAY DRIVE: four orientation edge cards")
            if not _confirm(
                prompter, "consent.offsets", "Drive the edge-marker patterns?"
            ):
                raise BootstrapFailure("offset-test drive consent declined")
            answers = []
            for orientation in range(4):
                bootstrap_request(
                    transport,
                    "PANEL_EDGES CONFIRM orientation=%d" % orientation,
                    timeout,
                )
                answers.append(
                    _ask(
                        prompter,
                        "offsets.%d" % orientation,
                        "Orientation %d: none or edge:pixels?" % orientation,
                        default="none",
                    )
                )
            adjustments = solve_orientation_offsets(answers)
            offsets = _apply_orientation_adjustments(candidate, adjustments)
            updates = {
                "col_offset": offsets[0][0],
                "row_offset": offsets[0][1],
                "offsets": offsets,
            }
            evidence = ["four edge-marker observations produced %s" % offsets]
            console.warning("DISPLAY DRIVE: asymmetric mirror-test glyph")
            if not _confirm(
                prompter, "consent.mirror", "Drive the mirror-test glyph?"
            ):
                raise BootstrapFailure("mirror-test drive consent declined")
            bootstrap_request(transport, "PANEL_GLYPH CONFIRM", timeout)
            mirror = derive_mirror_x(
                _ask(
                    prompter,
                    "mirror.reading",
                    "Does the glyph read normally or backwards?",
                )
            )
            evidence.append(
                "glyph read %s; schema v1 has no default mirror field"
                % ("backwards" if mirror else "normally")
            )
    elif section == "backlight":
        if (
            candidate["carrier"]["pin_bl"] < 0
            and candidate["backlight"]["kind"] == "panel_command"
        ):
            try:
                _ensure_safe_drive(
                    safety_candidates,
                    _panel_pins(candidate),
                    "backlight retune",
                )
            except BootstrapFailure as exc:
                raise BootstrapFailure(
                    "panel-command backlight retune cannot safely initialize "
                    "the panel: %s" % exc
                ) from exc
            _drive_warning(console, candidate)
            if not _confirm(
                prompter,
                "consent.panel_config",
                "Initialize this descriptor's panel for command brightness?",
            ):
                raise BootstrapFailure("panel drive consent declined")
            bootstrap_request(
                transport, _panel_config_command(candidate), timeout + 5.0)
        backlight = _derive_backlight(
            transport, prompter, console, candidate, safety_candidates, timeout
        )
        updates = {
            "inverted": bool(backlight["inverted"]),
            "enable_pin": candidate["backlight"]["enable_pin"],
        }
        evidence = ["low/high ramp observed as %s polarity"
                    % ("inverted" if backlight["inverted"] else "normal")]
        if backlight["enable_active_high"] is not None:
            evidence.append("enable HIGH=on and LOW=off")
    else:
        pins = sorted(
            {
                descriptor["carrier"]["pin_boot"]
                for descriptor in descriptors
                if descriptor["identity"]["target"]
                == candidate["identity"]["target"]
                and descriptor["carrier"]["pin_boot"] >= 0
            }
        )
        _pause(
            prompter,
            "buttons.ready",
            "Press Enter, then press and release BOOT during the watch window.",
        )
        reply = bootstrap_request(
            transport,
            "GPIO_WATCH 5000 " + ",".join(str(pin) for pin in pins),
            timeout + 5.0,
        )
        try:
            pin = int(reply["pin"])
        except (KeyError, TypeError, ValueError) as exc:
            raise BootstrapFailure("BOOT pin watch was inconclusive") from exc
        if pin not in pins:
            raise BootstrapFailure("BOOT pin watch returned a non-candidate GPIO")
        updates = {"pin_boot": pin}
        evidence = ["level change observed on GPIO%d" % pin]

    path = os.path.join(repo_root, "boards", normalized_key + ".toml")
    try:
        with open(path, encoding="utf-8") as source:
            original = source.read()
    except OSError as exc:
        raise BootstrapFailure("cannot read %s: %s" % (path, exc)) from exc
    updated = retune_descriptor_text(original, section, updates, evidence)
    try:
        parsed = tomllib.loads(updated)
    except tomllib.TOMLDecodeError as exc:
        raise BootstrapFailure("retune produced invalid TOML: %s" % exc) from exc
    parsed["_source"] = os.path.relpath(path, repo_root)
    others = [item for item in descriptors if item["key"] != normalized_key]
    board_descriptor.validate_descriptors(others + [parsed])
    console.warning("DESCRIPTOR WRITE: replace existing %s atomically" % path)
    if not _confirm(
        prompter,
        "retune.write",
        "Apply only the %s retune to %s?" % (section, normalized_key),
    ):
        raise BootstrapFailure("retune descriptor write declined")
    write_text_atomically(path, updated, overwrite=True)
    console.summary("Retuned %s section %s" % (normalized_key, section))
    console.summary(
        "Closing loop: validate -> regenerate -> compile -> flash -> confirm bring-up"
    )
    parsed.pop("_source", None)
    return BootstrapResult(path, parsed, evidence)
