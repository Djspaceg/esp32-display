#!/usr/bin/env python3
"""Load and validate the authoritative per-board TOML descriptors."""

from __future__ import annotations

import hashlib
import os
import pathlib
import re
import tomllib
from typing import Any, Dict, Iterable, List, Sequence, Tuple


class DescriptorError(ValueError):
    """A descriptor cannot safely participate in a family artifact."""


REQUIRED_FIELDS = (
    "schema",
    "key",
    "catalog_order",
    "name",
    "hardware",
    "migration.firmware_config",
    "migration.config_symbol",
    "identity.target",
    "identity.chip",
    "identity.profile",
    "identity.partition",
    "identity.variant",
    "identity.variant_value",
    "identity.legacy_targets",
    "family.platform_key",
    "family.build_target",
    "family.fqbn",
    "family.partition_csv",
    "family.extra_flags",
    "family.extra_library_dirs",
    "family.fqbn_options",
    "family.flash_bytes",
    "family.common_layout_bytes",
    "family.requires_doom_wad",
    "family.bootloader_address",
    "family.partitions_address",
    "family.boot_app0_address",
    "family.app_address",
    "family.blurb",
    "platform.use_psram_frame_buffers",
    "platform.use_raw_lwip_receive_task",
    "platform.wifi",
    "platform.identity_source",
    "platform.serial",
    "capacity.minimum_flash_bytes",
    "panel.symbol",
    "panel.profile",
    "panel.driver",
    "panel.bus",
    "panel.width",
    "panel.height",
    "panel.memory_width",
    "panel.memory_height",
    "panel.pixel_clock_hz",
    "panel.spi_mode",
    "panel.col_offset",
    "panel.row_offset",
    "panel.orientation_offset",
    "panel.invert_color",
    "panel.round_display",
    "panel.supports_command_rotation",
    "panel.color_order",
    "panel.data_endian",
    "panel.pixel_depth",
    "panel.dsi_data_lanes",
    "panel.dsi_lane_mbps",
    "panel.hsync_back_porch",
    "panel.hsync_pulse_width",
    "panel.hsync_front_porch",
    "panel.vsync_back_porch",
    "panel.vsync_pulse_width",
    "panel.vsync_front_porch",
    "carrier.pin_sclk",
    "carrier.pin_mosi",
    "carrier.pin_data1",
    "carrier.pin_data2",
    "carrier.pin_data3",
    "carrier.pin_cs",
    "carrier.pin_dc",
    "carrier.pin_rst",
    "carrier.pin_bl",
    "carrier.pin_boot",
    "carrier.pin_rgb_led",
    "touch.controller",
    "touch.sda",
    "touch.scl",
    "touch.reset",
    "touch.interrupt",
    "touch.addresses",
    "touch.panel_short",
    "touch.panel_long",
    "touch.raw_x_mirrored",
    "touch.raw_y_mirrored",
    "touch.rotate_clockwise",
    "led.channel_order",
    "led.pixel_count",
    "gesture.swipe_min_px",
    "gesture.tap_max_move_px",
    "gesture.tap_max_ms",
    "gesture.long_press_ms",
    "gesture.press_max_ms",
    "orientation.offsets",
    "orientation.mirror_x_supported",
    "orientation.quarter_turns",
    "motion.controller",
    "motion.address",
    "motion.x_axis",
    "motion.x_sign",
    "motion.y_axis",
    "motion.y_sign",
    "reset.expander",
    "reset.expander_address",
    "reset.panel_output",
    "reset.touch_output",
    "backlight.kind",
    "backlight.enable_pin",
    "backlight.inverted",
    "power.controller",
    "power.battery_adc",
    "power.battery_adc_scale",
    "power.battery_enable",
    "power.charge_status",
    "power.axp_address",
    "serial.transport",
    "serial.bridge",
    "serial.rx",
    "serial.tx",
    "audio.amp",
    "audio.codec",
    "audio.mic",
    "audio.speaker_bus",
    "audio.mic_bus",
    "audio.pin_playback_mclk",
    "audio.pin_playback_bclk",
    "audio.pin_playback_lrck",
    "audio.pin_dout",
    "audio.pin_capture_mclk",
    "audio.pin_capture_bclk",
    "audio.pin_capture_lrck",
    "audio.pin_din",
    "audio.pin_pdm_clock",
    "audio.pin_amp_enable",
    "audio.codec_i2c_address",
    "audio.mic_i2c_address",
    "audio.playback_rate_hz",
    "audio.playback_channels",
    "audio.capture_rate_hz",
    "audio.capture_channels",
    "capabilities.doom",
    "capabilities.audio",
    "compile.selector",
    "compile.macros",
    "detection.order",
    "detection.resolution",
    "detection.no_match",
    "detection.kind",
    "detection.flash_min_exclusive",
    "detection.flash_max_inclusive",
    "detection.sda",
    "detection.scl",
    "detection.frequency_hz",
    "detection.scan_first",
    "detection.scan_last",
    "detection.addresses",
    "detection.reset_pin",
    "detection.reset_low_ms",
    "detection.reset_release_wait_ms",
    "detection.release",
)

PLATFORM_ENUM = {
    "c6": "Esp32C6",
    "s3": "Esp32S3",
    "p4": "Esp32P4",
}

DETECTION_KINDS = {
    "always",
    "flash_range",
    "i2c_any_ack",
    "i2c_no_ack",
    "i2c_any_ack_or_start_failure",
}
DETECTION_RESOLUTIONS = {"first_match", "exactly_one"}
PROBE_RELEASES = {"never", "always", "on_success_no_ack"}
PANEL_BUSES = {"spi", "qspi", "mipi_dsi"}
TOUCH_CONTROLLERS = {"none", "axs5106l", "cst9217", "cst816", "gt911"}
POWER_CONTROLLERS = {"none", "axp2101", "battery_adc"}
MOTION_CONTROLLERS = {"none", "qmi8658"}
AUDIO_AMPS = {"none", "unknown", "ns4150b", "ns8002"}
AUDIO_CODECS = {"none", "unknown", "es8311", "pcm5101a"}
AUDIO_MICS = {"none", "unknown", "es7210", "ics43434", "pdm"}
AUDIO_SPEAKER_BUSES = {"none", "unknown", "i2s"}
AUDIO_MIC_BUSES = {"none", "unknown", "i2s", "pdm"}
GPIO_MAX_BY_TARGET = {"c6": 30, "s3": 48, "p4": 54}
WIFI_TOPOLOGIES = {"native", "hosted_coprocessor"}
IDENTITY_SOURCES = {"wifi_station_mac", "efuse_base_mac"}
SERIAL_TRANSPORTS = {"native_usb_cdc", "uart_bridge"}
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ALLOWED_TOP_LEVEL = {path.split(".", 1)[0] for path in REQUIRED_FIELDS}
ALLOWED_SECTION_FIELDS: Dict[str, set[str]] = {}
for required_path in REQUIRED_FIELDS:
    section, separator, field = required_path.partition(".")
    if separator:
        ALLOWED_SECTION_FIELDS.setdefault(section, set()).add(field)


def _field(descriptor: Dict[str, Any], path: str) -> Any:
    value: Any = descriptor
    for component in path.split("."):
        if not isinstance(value, dict) or component not in value:
            raise DescriptorError(
                "%s: missing required field %s"
                % (descriptor.get("key", "<unknown>"), path)
            )
        value = value[component]
    return value


def _source_name(descriptor: Dict[str, Any]) -> str:
    return str(descriptor.get("_source", descriptor.get("key", "<unknown>")))


def _expect_type(
    descriptor: Dict[str, Any], path: str, expected: type,
) -> Any:
    value = _field(descriptor, path)
    if expected is int:
        valid = isinstance(value, int) and not isinstance(value, bool)
    else:
        valid = isinstance(value, expected)
    if not valid:
        raise DescriptorError(
            "%s: %s must be %s"
            % (_source_name(descriptor), path, expected.__name__)
        )
    return value


def _expect_choice(
    descriptor: Dict[str, Any], path: str, choices: Iterable[str],
) -> str:
    value = _expect_type(descriptor, path, str)
    if value not in choices:
        raise DescriptorError(
            "%s: %s must be one of %s"
            % (_source_name(descriptor), path, ", ".join(sorted(choices)))
        )
    return value


def _expect_int_range(
    descriptor: Dict[str, Any], path: str, minimum: int, maximum: int,
) -> int:
    value = _expect_type(descriptor, path, int)
    if value < minimum or value > maximum:
        raise DescriptorError(
            "%s: %s must be %d..%d"
            % (_source_name(descriptor), path, minimum, maximum)
        )
    return value


def _expect_identifier(descriptor: Dict[str, Any], path: str) -> str:
    value = _expect_type(descriptor, path, str)
    if IDENTIFIER.fullmatch(value) is None:
        raise DescriptorError(
            "%s: %s must be a C/C++ identifier"
            % (_source_name(descriptor), path)
        )
    return value


def _validate_shape(descriptor: Dict[str, Any]) -> None:
    source = _source_name(descriptor)
    extra_top_level = sorted(
        set(descriptor).difference(ALLOWED_TOP_LEVEL, {"_source"}))
    if extra_top_level:
        raise DescriptorError(
            "%s: unknown top-level field %s"
            % (source, extra_top_level[0])
        )
    for section, allowed in ALLOWED_SECTION_FIELDS.items():
        value = descriptor.get(section)
        if not isinstance(value, dict):
            continue
        extra = sorted(set(value).difference(allowed))
        if extra:
            raise DescriptorError(
                "%s: unknown field %s.%s"
                % (source, section, extra[0])
            )


def _validate_detection(descriptor: Dict[str, Any]) -> None:
    source = _source_name(descriptor)
    detection = descriptor["detection"]
    kind = _expect_choice(
        descriptor, "detection.kind", DETECTION_KINDS)
    _expect_choice(
        descriptor, "detection.resolution", DETECTION_RESOLUTIONS)
    _expect_choice(descriptor, "detection.release", PROBE_RELEASES)
    if _field(descriptor, "detection.no_match") != "unknown":
        raise DescriptorError(
            "%s: detection.no_match must be unknown (fail closed)" % source
        )

    order = _expect_type(descriptor, "detection.order", int)
    if order < 0:
        raise DescriptorError(
            "%s: detection.order must be non-negative" % source)
    flash_min = _expect_type(
        descriptor, "detection.flash_min_exclusive", int)
    flash_max = _expect_type(
        descriptor, "detection.flash_max_inclusive", int)
    if flash_min < 0 or flash_max < 0:
        raise DescriptorError(
            "%s: detection flash bounds must be non-negative" % source)
    if flash_max != 0 and flash_min >= flash_max:
        raise DescriptorError(
            "%s: detection flash range is empty" % source)

    addresses = _expect_type(descriptor, "detection.addresses", list)
    if len(addresses) > 4:
        raise DescriptorError(
            "%s: detection.addresses supports at most 4 entries" % source)
    for address in addresses:
        if (not isinstance(address, int) or isinstance(address, bool) or
                address < 0x08 or address > 0x77):
            raise DescriptorError(
                "%s: detection address must be in 0x08..0x77" % source)
    if len(set(addresses)) != len(addresses):
        raise DescriptorError(
            "%s: detection.addresses contains a duplicate" % source)

    is_i2c = kind.startswith("i2c_")
    if is_i2c:
        _expect_int_range(descriptor, "detection.sda", 0, 127)
        _expect_int_range(descriptor, "detection.scl", 0, 127)
        frequency = _expect_type(
            descriptor, "detection.frequency_hz", int)
        if frequency <= 0:
            raise DescriptorError(
                "%s: I2C detection frequency must be positive" % source)
        if not addresses:
            scan_first = _expect_int_range(
                descriptor, "detection.scan_first", 0x08, 0x77)
            scan_last = _expect_int_range(
                descriptor, "detection.scan_last", 0x08, 0x77)
            if scan_first > scan_last:
                raise DescriptorError(
                    "%s: detection scan range is empty" % source)
    elif detection["sda"] != -1 or detection["scl"] != -1:
        raise DescriptorError(
            "%s: non-I2C detection must not declare I2C pins" % source)


AUDIO_PIN_FIELDS = (
    "pin_playback_mclk",
    "pin_playback_bclk",
    "pin_playback_lrck",
    "pin_dout",
    "pin_capture_mclk",
    "pin_capture_bclk",
    "pin_capture_lrck",
    "pin_din",
    "pin_pdm_clock",
    "pin_amp_enable",
)
AUDIO_DETAIL_FIELDS = AUDIO_PIN_FIELDS + (
    "codec_i2c_address",
    "mic_i2c_address",
    "playback_rate_hz",
    "playback_channels",
    "capture_rate_hz",
    "capture_channels",
)
EXISTING_PIN_PATHS = (
    "carrier.pin_sclk",
    "carrier.pin_mosi",
    "carrier.pin_data1",
    "carrier.pin_data2",
    "carrier.pin_data3",
    "carrier.pin_cs",
    "carrier.pin_dc",
    "carrier.pin_rst",
    "carrier.pin_bl",
    "carrier.pin_boot",
    "carrier.pin_rgb_led",
    "touch.sda",
    "touch.scl",
    "touch.reset",
    "touch.interrupt",
    "backlight.enable_pin",
    "power.battery_adc",
    "power.battery_enable",
    "power.charge_status",
    "serial.rx",
    "serial.tx",
    "detection.sda",
    "detection.scl",
    "detection.reset_pin",
)


def _validate_audio_pin(
    descriptor: Dict[str, Any], field: str, maximum: int,
) -> int:
    path = "audio." + field
    value = _expect_type(descriptor, path, int)
    if value != -1 and not 0 <= value <= maximum:
        raise DescriptorError(
            "%s: %s must be -1 or GPIO 0..%d"
            % (_source_name(descriptor), path, maximum)
        )
    return value


def _validate_audio(descriptor: Dict[str, Any]) -> None:
    source = _source_name(descriptor)
    audio = descriptor["audio"]
    amp = _expect_choice(descriptor, "audio.amp", AUDIO_AMPS)
    codec = _expect_choice(descriptor, "audio.codec", AUDIO_CODECS)
    mic = _expect_choice(descriptor, "audio.mic", AUDIO_MICS)
    speaker_bus = _expect_choice(
        descriptor, "audio.speaker_bus", AUDIO_SPEAKER_BUSES)
    mic_bus = _expect_choice(
        descriptor, "audio.mic_bus", AUDIO_MIC_BUSES)
    capability = _expect_type(descriptor, "capabilities.audio", bool)
    maximum = GPIO_MAX_BY_TARGET[descriptor["identity"]["target"]]
    pins = {
        field: _validate_audio_pin(descriptor, field, maximum)
        for field in AUDIO_PIN_FIELDS
    }
    details = {
        field: _expect_type(descriptor, "audio." + field, int)
        for field in AUDIO_DETAIL_FIELDS if field not in AUDIO_PIN_FIELDS
    }
    for field in ("codec_i2c_address", "mic_i2c_address"):
        if not 0 <= details[field] <= 127:
            raise DescriptorError(
                "%s: audio.%s must be 0..127" % (source, field))

    if not capability:
        for field, value in pins.items():
            if value != -1:
                raise DescriptorError(
                    "%s: audio capability is false but audio.%s is declared"
                    % (source, field)
                )
        if any(details.values()) or any(
                value != "none"
                for value in (amp, codec, mic, speaker_bus, mic_bus)):
            raise DescriptorError(
                "%s: audio capability is false but audio hardware is declared"
                % source
            )
        return

    enum_values = (amp, codec, mic, speaker_bus, mic_bus)
    if "unknown" in enum_values:
        if any(value != "unknown" for value in enum_values) or \
                any(value != -1 for value in pins.values()) or \
                any(details.values()):
            raise DescriptorError(
                "%s: unverified audio rows must leave pins, addresses, rates, "
                "and channels unknown" % source
            )
        return

    if speaker_bus == "none" and mic_bus == "none":
        raise DescriptorError(
            "%s: audio capability requires playback or capture" % source)
    if speaker_bus == "none":
        if amp != "none" or codec != "none":
            raise DescriptorError(
                "%s: audio without playback must not declare amp or codec"
                % source
            )
        if details["playback_rate_hz"] != 0 or \
                details["playback_channels"] != 0:
            raise DescriptorError(
                "%s: audio without playback must use zero playback bounds"
                % source
            )
    else:
        if amp == "none":
            raise DescriptorError(
                "%s: I2S speaker output requires audio.amp" % source)
        for field in ("pin_playback_bclk", "pin_playback_lrck", "pin_dout"):
            if pins[field] == -1:
                raise DescriptorError(
                    "%s: I2S playback requires audio.pin_playback_bclk, "
                    "pin_playback_lrck, and pin_dout" % source
                )
        _expect_int_range(
            descriptor, "audio.playback_rate_hz", 8000, 96000)
        _expect_int_range(
            descriptor, "audio.playback_channels", 1, 8)

    if mic_bus == "none":
        if mic != "none":
            raise DescriptorError(
                "%s: audio without capture must not declare a mic" % source)
        if details["capture_rate_hz"] != 0 or \
                details["capture_channels"] != 0:
            raise DescriptorError(
                "%s: audio without capture must use zero capture bounds"
                % source
            )
    else:
        if mic == "none":
            raise DescriptorError(
                "%s: audio capture requires audio.mic" % source)
        if pins["pin_din"] == -1:
            raise DescriptorError(
                "%s: audio capture requires audio.pin_din" % source)
        if mic_bus == "i2s" and (
                pins["pin_capture_bclk"] == -1 or
                pins["pin_capture_lrck"] == -1):
            raise DescriptorError(
                "%s: I2S capture requires audio.pin_capture_bclk and "
                "pin_capture_lrck" % source
            )
        if mic_bus == "pdm" and pins["pin_pdm_clock"] == -1:
            raise DescriptorError(
                "%s: PDM capture requires audio.pin_pdm_clock" % source)
        if mic_bus == "pdm" and any(
                pins[field] != -1 for field in (
                    "pin_capture_mclk",
                    "pin_capture_bclk",
                    "pin_capture_lrck",
                )):
            raise DescriptorError(
                "%s: PDM capture must not declare capture I2S clocks" % source)
        _expect_int_range(
            descriptor, "audio.capture_rate_hz", 8000, 96000)
        _expect_int_range(
            descriptor, "audio.capture_channels", 1, 8)

    if mic_bus != "pdm" and pins["pin_pdm_clock"] != -1:
        raise DescriptorError(
            "%s: audio.pin_pdm_clock is only valid for PDM capture" % source)
    if codec == "es8311":
        if not 0x08 <= details["codec_i2c_address"] <= 0x77:
            raise DescriptorError(
                "%s: ES8311 requires audio.codec_i2c_address" % source)
        if pins["pin_playback_mclk"] == -1:
            raise DescriptorError(
                "%s: ES8311 requires audio.pin_playback_mclk" % source)
    elif details["codec_i2c_address"] != 0:
        raise DescriptorError(
            "%s: non-I2C audio codec must use address 0" % source)
    if mic == "es7210":
        if mic_bus != "i2s":
            raise DescriptorError(
                "%s: ES7210 requires audio.mic_bus i2s" % source)
        if not 0x08 <= details["mic_i2c_address"] <= 0x77:
            raise DescriptorError(
                "%s: ES7210 requires audio.mic_i2c_address" % source)
        if pins["pin_capture_mclk"] == -1:
            raise DescriptorError(
                "%s: ES7210 requires audio.pin_capture_mclk" % source)
    elif details["mic_i2c_address"] != 0:
        raise DescriptorError(
            "%s: non-I2C audio mic must use address 0" % source)
    if mic == "ics43434" and mic_bus != "i2s":
        raise DescriptorError(
            "%s: ICS-43434 requires audio.mic_bus i2s" % source)
    if mic == "pdm" and mic_bus != "pdm":
        raise DescriptorError(
            "%s: PDM mic requires audio.mic_bus pdm" % source)
    if amp == "ns4150b" and pins["pin_amp_enable"] == -1:
        raise DescriptorError(
            "%s: NS4150B requires audio.pin_amp_enable" % source)

    existing_pins: Dict[int, str] = {}
    for path in EXISTING_PIN_PATHS:
        value = _field(descriptor, path)
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            existing_pins.setdefault(value, path)
    for field, value in pins.items():
        if value in existing_pins:
            raise DescriptorError(
                "%s: audio.%s GPIO%d collides with %s"
                % (source, field, value, existing_pins[value])
            )


def load_repository_descriptors(repo_root: str) -> List[Dict[str, Any]]:
    board_dir = pathlib.Path(repo_root) / "boards"
    paths = sorted(board_dir.glob("*.toml"))
    if not paths:
        raise DescriptorError("no board descriptors found in %s" % board_dir)
    descriptors = []
    for path in paths:
        try:
            with path.open("rb") as source:
                descriptor = tomllib.load(source)
        except (OSError, tomllib.TOMLDecodeError) as exc:
            raise DescriptorError("%s: %s" % (path, exc)) from exc
        descriptor["_source"] = os.path.relpath(path, repo_root)
        descriptors.append(descriptor)
    return descriptors


def descriptor_source_digest(repo_root: str) -> str:
    digest = hashlib.sha256()
    board_dir = pathlib.Path(repo_root) / "boards"
    for path in sorted(board_dir.glob("*.toml")):
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def _detection_signature(descriptor: Dict[str, Any]) -> Tuple[Any, ...]:
    detection = descriptor["detection"]
    return (
        descriptor["identity"]["target"],
        detection["kind"],
        detection["flash_min_exclusive"],
        detection["flash_max_inclusive"],
        detection["sda"],
        detection["scl"],
        detection["frequency_hz"],
        detection["scan_first"],
        detection["scan_last"],
        tuple(detection["addresses"]),
    )


def _family_contract(descriptor: Dict[str, Any]) -> Tuple[Any, ...]:
    family = descriptor["family"]
    platform = descriptor["platform"]
    identity = descriptor["identity"]
    return (
        identity["chip"],
        identity["partition"],
        family["platform_key"],
        family["build_target"],
        family["fqbn"],
        family["partition_csv"],
        tuple(family["extra_flags"]),
        tuple(family["extra_library_dirs"]),
        tuple(family["fqbn_options"]),
        tuple(family["flash_bytes"]),
        family["common_layout_bytes"],
        family["requires_doom_wad"],
        family["bootloader_address"],
        family["partitions_address"],
        family["boot_app0_address"],
        family["app_address"],
        family["blurb"],
        platform["use_psram_frame_buffers"],
        platform["use_raw_lwip_receive_task"],
        platform["wifi"],
        platform["identity_source"],
        platform["serial"],
    )


def validate_descriptors(
    descriptors: Sequence[Dict[str, Any]],
) -> Sequence[Dict[str, Any]]:
    if not descriptors:
        raise DescriptorError("descriptor set is empty")

    keys: Dict[str, str] = {}
    identities: Dict[Tuple[str, str, str, str], str] = {}
    variants: Dict[str, str] = {}
    variant_values: Dict[int, str] = {}
    detection_signatures: Dict[Tuple[Any, ...], str] = {}
    family_contracts: Dict[str, Tuple[Any, ...]] = {}
    generated_by_family: Dict[str, List[str]] = {}
    detection_orders: Dict[Tuple[str, int], str] = {}
    config_symbols: Dict[str, str] = {}
    resolutions: Dict[str, str] = {}
    catalog_orders: Dict[Tuple[str, int], str] = {}

    for descriptor in descriptors:
        _validate_shape(descriptor)
        for path in REQUIRED_FIELDS:
            _field(descriptor, path)
        source = _source_name(descriptor)
        schema = _expect_type(descriptor, "schema", int)
        if schema != 1:
            raise DescriptorError("%s: unsupported schema %r" % (
                source, schema))
        key = descriptor["key"]
        if not isinstance(key, str) or not key:
            raise DescriptorError("%s: key must be a non-empty string" % source)
        name = _expect_type(descriptor, "name", str)
        if not name:
            raise DescriptorError("%s: name must not be empty" % source)
        hardware = _expect_type(descriptor, "hardware", list)
        if (not hardware or
                any(not isinstance(item, str) or not item for item in hardware)):
            raise DescriptorError(
                "%s: hardware must contain non-empty strings" % source)
        if key in keys:
            raise DescriptorError(
                "%s: duplicate board key %s (already in %s)"
                % (source, key, keys[key])
            )
        keys[key] = source

        identity = descriptor["identity"]
        for field in ("target", "chip", "profile", "partition"):
            value = _expect_type(descriptor, "identity." + field, str)
            if not value:
                raise DescriptorError(
                    "%s: identity.%s must not be empty" % (source, field)
                )
        _expect_identifier(descriptor, "identity.variant")
        identity_key = (
            identity["target"],
            identity["chip"],
            identity["profile"],
            identity["partition"],
        )
        if identity_key in identities:
            raise DescriptorError(
                "%s: identity already claimed by %s: %s"
                % (source, identities[identity_key], "/".join(identity_key))
            )
        identities[identity_key] = source
        if identity["variant"] in variants:
            raise DescriptorError(
                "%s: duplicate variant %s" % (source, identity["variant"])
            )
        variants[identity["variant"]] = source
        variant_value = identity["variant_value"]
        if (not isinstance(variant_value, int) or
                isinstance(variant_value, bool) or
                not 1 <= variant_value <= 255):
            raise DescriptorError(
                "%s: identity.variant_value must be 1..255" % source
            )
        if variant_value in variant_values:
            raise DescriptorError(
                "%s: duplicate variant value %d" % (source, variant_value)
            )
        variant_values[variant_value] = source

        config_symbol = _expect_identifier(
            descriptor, "migration.config_symbol")
        if config_symbol in config_symbols:
            raise DescriptorError(
                "%s: duplicate config symbol %s (already in %s)"
                % (source, config_symbol, config_symbols[config_symbol])
            )
        config_symbols[config_symbol] = source

        _validate_detection(descriptor)
        order_key = (identity["target"], descriptor["detection"]["order"])
        if order_key in detection_orders:
            raise DescriptorError(
                "%s: duplicate detection order %d for family %s"
                % (source, order_key[1], order_key[0])
            )
        detection_orders[order_key] = source

        signature = _detection_signature(descriptor)
        if signature in detection_signatures:
            raise DescriptorError(
                "%s: duplicate probe signature already claimed by %s"
                % (source, detection_signatures[signature])
            )
        detection_signatures[signature] = source

        capacity = descriptor["capacity"]["minimum_flash_bytes"]
        layout = descriptor["family"]["common_layout_bytes"]
        if capacity < layout:
            raise DescriptorError(
                "%s: capacity conflict: board minimum %d bytes is smaller "
                "than family %s common layout %d bytes"
                % (source, capacity, identity["target"], layout)
            )

        target = identity["target"]
        if target not in PLATFORM_ENUM:
            raise DescriptorError("%s: unknown target %s" % (source, target))
        catalog_order = _expect_type(descriptor, "catalog_order", int)
        if catalog_order < 0:
            raise DescriptorError(
                "%s: catalog_order must be non-negative" % source)
        catalog_key = (target, catalog_order)
        if catalog_key in catalog_orders:
            raise DescriptorError(
                "%s: duplicate catalog_order %d for family %s"
                % (source, catalog_order, target)
            )
        catalog_orders[catalog_key] = source
        if descriptor["family"]["platform_key"] != target:
            raise DescriptorError(
                "%s: family.platform_key must match identity.target" % source)

        _expect_choice(descriptor, "platform.wifi", WIFI_TOPOLOGIES)
        _expect_choice(
            descriptor, "platform.identity_source", IDENTITY_SOURCES)
        _expect_choice(descriptor, "platform.serial", SERIAL_TRANSPORTS)
        _expect_choice(descriptor, "panel.bus", PANEL_BUSES)
        _expect_identifier(descriptor, "panel.symbol")
        _expect_identifier(descriptor, "panel.profile")
        _expect_identifier(descriptor, "panel.driver")
        panel_width = _expect_int_range(
            descriptor, "panel.width", 1, 65535)
        panel_height = _expect_int_range(
            descriptor, "panel.height", 1, 65535)
        memory_width = _expect_int_range(
            descriptor, "panel.memory_width", 0, 65535)
        memory_height = _expect_int_range(
            descriptor, "panel.memory_height", 0, 65535)
        col_offset = _expect_int_range(
            descriptor, "panel.col_offset", 0, 255)
        row_offset = _expect_int_range(
            descriptor, "panel.row_offset", 0, 255)
        _expect_int_range(
            descriptor, "panel.orientation_offset", 0, 3)
        if (memory_width == 0) != (memory_height == 0):
            raise DescriptorError(
                "%s: panel memory extents must both be known or both be 0"
                % source
            )
        if memory_width != 0:
            if panel_width + col_offset > memory_width:
                raise DescriptorError(
                    "%s: panel width plus col_offset exceeds memory_width"
                    % source
                )
            if panel_height + row_offset > memory_height:
                raise DescriptorError(
                    "%s: panel height plus row_offset exceeds memory_height"
                    % source
                )
        _expect_choice(
            descriptor, "touch.controller", TOUCH_CONTROLLERS)
        _expect_choice(
            descriptor, "power.controller", POWER_CONTROLLERS)
        _expect_choice(
            descriptor, "motion.controller", MOTION_CONTROLLERS)
        _validate_audio(descriptor)

        flash_bytes = _expect_type(descriptor, "family.flash_bytes", list)
        if not flash_bytes:
            raise DescriptorError(
                "%s: family.flash_bytes must not be empty" % source)
        if any(not isinstance(value, int) or isinstance(value, bool) or value <= 0
               for value in flash_bytes):
            raise DescriptorError(
                "%s: family.flash_bytes must contain positive integers" % source)
        if len(set(flash_bytes)) != len(flash_bytes):
            raise DescriptorError(
                "%s: family.flash_bytes contains a duplicate" % source)
        layout = _expect_type(
            descriptor, "family.common_layout_bytes", int)
        if layout <= 0:
            raise DescriptorError(
                "%s: family.common_layout_bytes must be positive" % source)

        contract = _family_contract(descriptor)
        if target in family_contracts and family_contracts[target] != contract:
            raise DescriptorError(
                "%s: family %s build/platform facts conflict with another "
                "descriptor" % (source, target)
            )
        family_contracts[target] = contract
        resolution = descriptor["detection"]["resolution"]
        if target in resolutions and resolutions[target] != resolution:
            raise DescriptorError(
                "%s: family %s detection resolution conflicts with another "
                "descriptor" % (source, target)
            )
        resolutions[target] = resolution

        mode = descriptor["migration"]["firmware_config"]
        if mode not in ("generated", "legacy"):
            raise DescriptorError(
                "%s: migration.firmware_config must be generated or legacy"
                % source
            )
        if mode == "generated":
            generated_by_family.setdefault(target, []).append(key)

        selector = _expect_type(descriptor, "compile.selector", str)
        macros = _expect_type(descriptor, "compile.macros", list)
        for index, macro in enumerate(macros):
            if not isinstance(macro, str) or IDENTIFIER.fullmatch(macro) is None:
                raise DescriptorError(
                    "%s: compile.macros[%d] must be a C/C++ identifier"
                    % (source, index)
                )
        if target == "p4" and mode == "generated":
            if IDENTIFIER.fullmatch(selector) is None:
                raise DescriptorError(
                    "%s: generated P4 compile.selector must be a C/C++ "
                    "identifier" % source
                )
        elif selector or macros:
            raise DescriptorError(
                "%s: only generated P4 descriptors may declare compile "
                "selectors or macros" % source
            )

        if descriptor["panel"]["pixel_depth"] not in (16,):
            raise DescriptorError(
                "%s: panel.pixel_depth must currently be 16" % source
            )
        if descriptor["panel"]["color_order"] not in ("rgb", "bgr"):
            raise DescriptorError(
                "%s: panel.color_order must be rgb or bgr" % source
            )
        if descriptor["panel"]["data_endian"] not in ("big", "little"):
            raise DescriptorError(
                "%s: panel.data_endian must be big or little" % source
            )
        if (descriptor["panel"]["bus"] == "mipi_dsi" and
                descriptor["orientation"]["mirror_x_supported"]):
            raise DescriptorError(
                "%s: MIPI DSI descriptors must reject mirror X" % source
            )
        minimum_flash = _expect_type(
            descriptor, "capacity.minimum_flash_bytes", int)
        if minimum_flash not in flash_bytes:
            raise DescriptorError(
                "%s: capacity.minimum_flash_bytes must be one of the family "
                "flash_bytes values" % source
            )

    if len(descriptors) >= 3:
        for target in sorted(family_contracts):
            generated = generated_by_family.get(target, [])
            if len(generated) != 1:
                raise DescriptorError(
                    "family %s must have exactly one generated firmware-config "
                    "proof; found %d" % (target, len(generated))
                )
    return descriptors


def grouped_by_family(
    descriptors: Iterable[Dict[str, Any]],
) -> Dict[str, List[Dict[str, Any]]]:
    grouped: Dict[str, List[Dict[str, Any]]] = {}
    for descriptor in descriptors:
        grouped.setdefault(descriptor["identity"]["target"], []).append(descriptor)
    for family in grouped.values():
        family.sort(key=lambda item: item["catalog_order"])
    return grouped
