# Board descriptors

Each `*.toml` file in this directory is the authoritative data record for one
physical board. Schema version 1 is documented by `schema-v1.json` and enforced
by `tools/board_descriptor.py`, including constraints that span multiple board
records.

Regenerate committed consumers with:

```sh
python3 tools/generate_board_descriptors.py
```

Check that committed generated files are current with:

```sh
python3 tools/generate_board_descriptors.py --check
```

The `migration.firmware_config` field records the staged firmware migration.
Exactly one board in each CPU family is currently `generated`; other boards
remain on their existing handwritten `Config` rows while their identity,
detection, build-tool, and Mac catalog data already come from these descriptors.

`carrier.pin_panel_power`, `carrier.pin_encoder_a`, and `carrier.pin_encoder_b`
are optional and default to `-1`. Declare them only on a carrier that switches
its panel supply from a GPIO or has a rotary encoder.
