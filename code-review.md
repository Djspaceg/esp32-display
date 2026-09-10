# Adversarial Review

## Scope

Reviewed the complete change from `e7f0928` through the generated release
artifacts. The review covered S3 partition arithmetic, bundle generation and
catalog validation, Swift target policy, canonical USB flash planning, migration
behavior, tests, and app resource embedding. The `/code-review` skill was not
available in this harness, so this review was performed manually.

## Confirmed findings

### Fixed: canonical USB flash omitted the required WAD

`flash_canonical_release` validated the release catalog and then delegated to
`bundle_flash_plan`, but that function originally returned only bootloader,
partitions, `boot_app0`, and app. A generated S3 or P4 bundle could therefore be
valid while the Python USB path left its `doom_wad` partition empty.

Resolution: `bundle_flash_plan` now accepts the resolved `Family`, requires
`doom_wad` for Doom-capable families, and returns all writes in ascending flash
address order. `test_canonical_usb_flash_path` verifies the five-part S3 plan and
refuses a missing WAD.

### Fixed: the Python reader did not prohibit a C6 WAD flash part

The partition-table validator rejected a C6 `doom_wad` partition, but
`_verify_required_doom_flash_payload` returned immediately for C6. A hand-built
bundle could therefore carry a stray WAD role without a matching partition and
pass this layer of the Python catalog reader.

Resolution: non-Doom families now reject either WAD metadata or WAD payload
bytes. Python and Swift tests both cover a C6 bundle with a stray WAD.

## Checks and answers

* S3 arithmetic is exact: app0 is `0x10000 + 0x1F0000`, app1 is
  `0x200000 + 0x1F0000`, `doom_wad` is `0x3FF000 + 0x401000`, and the final byte
  boundary is `0x800000`.
* The generated S3 app is 1,391,200 bytes, leaving 640,416 bytes in either
  2,031,616-byte OTA slot.
* P4 keeps both `0x800000` app slots. Its WAD write address is read from the
  partition entry and is `0x1010000` in the canonical artifact.
* Swift uses explicit target policy: C6 must not carry a WAD; canonical S3/P4
  and every known historical S3/P4 exact target require one. An unknown newly
  added known target fails closed until its policy and partition layout are
  declared.
* The former S3 partition token is rejected. Existing S3 installations require
  one USB reflash; application-only OTA cannot install the new partition table
  or WAD.
* Catalog byte counts and SHA-256 values were recomputed independently for all
  three generated artifacts and matched.
* The signed Release app was built inside the worktree and embeds the exact
  manifest-referenced artifacts.

No unresolved code finding remains.

## Residual risk

No board was attached. Hardware flash, boot, OTA rollback, Doom launch, and WAD
mapping falsifiers could not run. The software-side flash plans, partition
parser, firmware compiles, host tests, Python tests, Swift tests, catalog
cross-read, app build, and code-sign verification all ran successfully.
