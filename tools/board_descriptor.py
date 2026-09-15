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
    "capabilities.doom",
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
        _expect_choice(
            descriptor, "touch.controller", TOUCH_CONTROLLERS)
        _expect_choice(
            descriptor, "power.controller", POWER_CONTROLLERS)
        _expect_choice(
            descriptor, "motion.controller", MOTION_CONTROLLERS)

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
