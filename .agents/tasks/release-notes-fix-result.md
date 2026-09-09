# Release-notes fix result

## Commit

- Commit: `e47b7b2a5838b726c9770389683ad2d02e494c74`
- Staged paths before commit: `release-notes.md` (only)

## Validation

- `python3 tools/test_espdisp.py`: PASS — 1,292 checks passed.
- C6 format-3 bundle generation: PASS — `/tmp/espdisp-1.4.2-c6.espdispfw`.
- `python3 tools/espdisp.py bundle-info /tmp/espdisp-1.4.2-c6.espdispfw`: PASS.

Bundle-info output:

```text
/tmp/espdisp-1.4.2-c6.espdispfw
  size:     1227053 bytes (1.2 MiB)
  version:  1.4.2
  built at: 2026-09-04T00:36:11Z
  source:   f5257e37612f1b3e3f7afd81fbede462469ff29e (dirty)
  tool:     espdisp.py bundle (format 3)
  release notes: 2 item(s)
  image:    targets=c6                chip=esp32c6   1193840 bytes  sha256 9ceed755b8aa80cdcb14838a55a812c4615c7f0435d6c54a9ebcd0c2ef702d05
            display_stream.ino.bin from esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M
            app        -> 0x010000
            bootloader -> 0x000000    20720 bytes  sha256 d036ad5d5ba0b5be7ba97b3f2fae0fa44878e6eaf583ea9264ca7213e854f5c3
                          display_stream.ino.bootloader.bin
            partitions -> 0x008000     3072 bytes  sha256 148b959cbff1c38aa8e1d5c0ba9d612c54997b945e56a63f41223eef650653a1
                          display_stream.ino.partitions.bin
            boot_app0  -> 0x00e000     8192 bytes  sha256 f94c5d786a7a8fab06ac5d10e33bf37711a6697636dc037559ea19cc410a17f0
                          boot_app0.bin

Verified: 1 image covering 1 exact target plus 3 flash parts, contiguous, every sha256 matches.
Can bring up a board that has never been flashed: carries the bootloader, partition table and boot_app0 for c6.
Carries exact targets c6; missing s3-085, s3-154, s3-175, s3-185. Other targets find nothing to install.
```

## Final `1.4.2` section

```markdown
## 1.4.2

- Added support for the Waveshare ESP32-S3-LCD-0.85 with its GC9107 display profile.
- Added canonical firmware release notes displayed in the Update firmware screen.
```
