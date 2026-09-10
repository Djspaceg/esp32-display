# Blast Radius

## Shared firmware configuration

`firmware/libraries/espdisp_board/src/platform_config.h` changes the S3
partition identity from `universal-8m-ota` to `universal-8m-doom-ota`.
Its in-tree call sites are:

* `firmware/libraries/espdisp_board/src/board_config.h` includes the header and
  assigns `PLATFORM_ESP32_S3` to every S3 `BoardConfig`.
* `firmware/display_stream/chip_identity.h` includes the header and reads
  `COMPILED_PLATFORM` for hardware identity.
* `firmware/board_probe/board_probe.ino` includes the header for the standalone
  board probe build.
* `firmware/display_stream/display_stream.ino` reads `COMPILED_PLATFORM` for
  serial transport and platform validation.
* `firmware/display_stream/serial_config.cpp` validates the platform token and
  reports `partitionToken` in `CFGSHOW`.
* `firmware/display_stream/mdns_announce.cpp` publishes `partitionToken`.
* `firmware/display_stream/net_link.cpp` reads the receive-task platform flag.
* `firmware/display_stream/frame_pipeline.cpp` reads the PSRAM framebuffer flag.
* `firmware/test/test_band_protocol.cpp` compiles the shared board configuration
  in the host test lane.

The runtime effect is limited to S3 identity reporting and target matching. C6
continues to report `default-8m`; P4 continues to report `p4-32m-ota`.

## Bundle readers and writers

`mac/ESPDisplaySender/Sources/SenderProtocol/FirmwareBundle.swift` is the shared
bundle reader and blank-device flash-plan builder. Production call sites are:

* `FirmwareReleaseCatalog.bundle(for:data:)` validates each catalog artifact.
* `UsbOnboardingPlan.make` obtains the blank-device USB write plan.
* `PanelManager+UsbConfig.swift` obtains the exact-target USB write plan.
* `PanelManager+FirmwareUpdates.swift` obtains the update target plan.
* `FirmwareUpdateSheet.swift` checks availability, sizes, and write plans.
* `AddDeviceSheet.swift` and `FirmwareUpdateSheet.swift` read user-selected
  bundles.
* `BundledFirmware.swift` reads and validates all three embedded catalog
  families in one fail-closed operation.

`tools/espdisp.py` is both the release writer and the independent catalog reader.
The affected paths are `cmd_bundle`, `cmd_release`, `cmd_bundle_info`,
`validate_release_catalog`, `flash_canonical_release`, and
`bundle_flash_plan`. S3 and P4 generation now requires the verified shareware
WAD, catalog validation requires it at the partition-table address, and
canonical USB flash writes it. C6 generation and validation reject a WAD.

## Existing test and fixture impact

The base `e7f0928` Swift run failed these 15 tests because the embedded P4
artifact had a WAD partition but no WAD flash payload:

* `BundledFirmwareSelectionTests.testCompleteManifestIdentitySelectsEveryRuntimeProfileDirectly`
* `BundledFirmwareSelectionTests.testUpdatePreselectionAcceptsLegacyLiveS3AliasMatchedToCanonicalUSBFamily`
* `BundledFirmwareSelectionTests.testUpdatePreselectionCanonicalizesLegacyS3FamilyAliases`
* `BundledFirmwareSelectionTests.testUpdatePreselectionFallsBackFromAChipOnlyC6USBProbe`
* `BundledFirmwareSelectionTests.testUpdatePreselectionFallsBackFromAChipOnlyP4USBProbe`
* `BundledFirmwareSelectionTests.testUpdatePreselectionRejectsEveryCrossTransportConflict`
* `BundledFirmwareSelectionTests.testUpdatePreselectionStillRejectsGenuineCrossTransportFamilyConflicts`
* `BundledFirmwareSelectionTests.testUpdatePreselectionStillRejectsUnknownIdentity`
* `BundledFirmwareSelectionTests.testUpdatePreselectionUsesCompleteRuntimeIdentityFromMDNSOrMatchedUSB`
* `BundledFirmwareSelectionTests.testUpdatePreselectionUsesMatchedUSBChipWhenLiveChipIsUnknown`
* `GeneratedReleaseCrossReadTests.testCanonicalGeneratedFamiliesCrossReadInSwift`
* `UsbOnboardingAppTests.testALegacyS3ExactTargetStillFallsBackToTheUniversalBundledFamily`
* `UsbOnboardingAppTests.testAUniqueC6ChipResolvesTheBundledFamilyWithoutFullIdentity`
* `UsbOnboardingAppTests.testAUniqueP4ChipResolvesTheBundledFamilyWithoutFullIdentity`
* `UsbOnboardingAppTests.testContradictoryEvidenceStillFailsInsteadOfFallingBack`

Updated test fixtures are `FirmwareBundleTests.p4Spec`,
`FirmwareBundleTests.currentS3Spec`, `FirmwareBundleTests.syntheticDoomWad`,
and `EsptoolCommandTests.bundle`. Generated fixtures are all three
`firmware-releases/*/*.espdispfw` artifacts plus
`firmware-releases/manifest.json`; C6 is regenerated for one coherent release
identity but its payload policy is unchanged.

Canonical `s3` now has five USB writes and refuses the former partition token.
Historical S3 exact-target bundles remain readable, but a blank-device plan is
refused unless their target-specific WAD layout is complete. Canonical `p4` and
historical `p4-4b` both require the WAD; the P4 WAD address comes from partition
metadata. A malformed family makes the embedded catalog unreadable, preserving
the existing fail-closed behavior.
