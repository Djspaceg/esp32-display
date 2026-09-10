# Findings

Overall confidence: HIGH for source, generated bundle, catalog, and app-reader
behavior; MEDIUM for physical-device behavior because no hardware was attached.

## Universal S3 image

**LIVE, HIGH confidence:** The canonical S3 table has two 2,031,616-byte OTA
slots and a 4,198,400-byte `doom_wad` partition at `0x3FF000`, ending exactly at
8 MiB. Falsifier: parse the generated partition table and reject any different
entry or end address. Status: ran in the Python suite and release validation;
passed.

**LIVE, HIGH confidence:** The generated S3 application is 1,391,200 bytes and
fits either slot with 640,416 bytes free. Falsifier: compile S3 and run
`_verify_app_payload` against the generated partition table. Status: both ran;
passed.

**LIVE, MEDIUM confidence:** The generated S3 bundle is flashable as five
segments, including the WAD at `0x3FF000`. Falsifier: execute the verified
esptool plan against an S3 board and boot both OTA slots. Status: software plan
generation and tests ran and passed; physical flash and boot could not run
because no hardware was attached.

## P4 repair

**LIVE, HIGH confidence:** Canonical `p4` and historical `p4-4b` require the
WAD, and the Swift flash plan takes its address from P4 partition metadata
rather than the former S3 constant. Falsifier: provide a valid P4 table with a
different in-range WAD address, then provide missing and misaddressed payloads.
Status: all three Swift cases ran; the table-derived case passed and malformed
cases were refused.

**LIVE, HIGH confidence:** The regenerated P4 artifact contains the exact
4,196,020-byte shareware WAD at `0x1010000`. Falsifier: unpack the artifact and
compare role, address, length, magic, and SHA-256. Status: release validation and
the Python suite ran; passed.

**LIVE, HIGH confidence:** The 15 catalog-triggered Swift failures are gone.
Falsifier: rerun the full Swift package suite with the regenerated catalog.
Status: ran 895 tests; zero failures.

## Fail-closed policy

**LIVE, HIGH confidence:** S3 and P4 release generation fails when the verified
shareware WAD is unavailable or mismatched, while C6 rejects a WAD partition or
flash part. Falsifier: remove/mutate the required WAD for S3/P4 and inject one
into C6. Status: Python and Swift negative tests ran; malformed inputs were
refused.

**INFERRED, MEDIUM confidence:** A previously flashed S3 board cannot safely
receive this layout through application-only OTA because OTA does not rewrite
the partition table or install the WAD payload. The changed partition identity
causes the existing target checks to refuse the old layout. Falsifier: attempt
an old-layout OTA and observe an accepted partition migration. Status: software
identity-refusal tests ran and passed; a physical OTA attempt could not run
because no hardware was attached.

## Artifacts

**LIVE, HIGH confidence:** Manifest byte counts and SHA-256 values match the
generated C6, S3, and P4 artifacts. Falsifier: independently hash and count every
manifest-referenced file. Status: ran; all three matched.

**LIVE, HIGH confidence:** The worktree-local signed Release app embeds all
three current artifacts. Falsifier: build the Xcode scheme, inspect the embed
phase output, and verify the resulting signature. Status: ran; build and
`codesign --verify --deep --strict` passed.
