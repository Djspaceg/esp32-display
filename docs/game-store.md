# Game store

A Doom or Quake board keeps the game files you add in its game store: up to
eight extra Doom WADs, and Quake's paks, in one flash area with a directory
that names them. The boot menu lists each stored WAD as its own row. The Mac
app writes the store over USB, from the display's **Games data** row.

The shareware `doom1.wad` is not part of the store. Every S3 and P4 bundle
carries it and writes it to the board's own `doom_wad` partition; it is the
menu's **DOOM** row on every board, whatever the store holds.

## Where it is

The store is the board's game data area. The partition table is the
firmware's own; nothing extra is reserved.

| Board | Area | Size | Directory at | Usable for files |
| --- | --- | --- | --- | --- |
| P4 (4B, 4C, 3.4C) | `quake_pak` partition, 0xE00000 | 18,874,368 (18 MiB) | 0x1FFF000 | 18,870,272 |
| S3, 32 MiB flash | raw flash from 0x800000 | 18,874,368 (18 MiB) | 0x19FF000 | 18,870,272 |
| S3, 16 MiB flash | raw flash from 0x800000 | 8,388,608 (8 MiB) | 0xFFF000 | 8,384,512 |
| S3, 8 MiB flash | none | | | |

On an S3 the firmware registers the area at runtime, past the universal table's
8 MiB, as a partition labelled `quake_pak`: what the chip has beyond 8 MiB, up
to 18 MiB (`game_store_s3_area_bytes`).

Each file starts on a 4 KiB sector and takes whole sectors. On the 4B, the
shareware `pak0.pak` (18,689,235 bytes, 18,690,048 on flash) leaves 180,224
bytes. A registered `pak1.pak` (about 34 MB) fits no board. Two shareware-size
WADs (4,196,020 bytes each) fit beside each other, but not beside the shareware
`pak0.pak`.

## Directory

The area's last 4 KiB sector. Little-endian; the rest of the sector is erased
(0xFF).

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 8 | `ESPGAMES` |
| 8 | 2 | version, 1 |
| 10 | 2 | entry size, 64 |
| 12 | 2 | entry count, at most 16 |
| 14 | 2 | 0 |
| 16 | 4 | area size this directory was written for |
| 20 | 4 | generation, one more on every write |
| 24 | 4 | CRC-32 (zlib) of bytes 0 to 32 + 64 x count, with this field 0 |
| 28 | 4 | 0 |
| 32 | 64 x count | entries |

Each entry:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | kind: 1 Doom WAD, 2 Quake pak |
| 1 | 1 | slot: N of Quake's `id1/pakN.pak`, 0 to 9; 0 for a WAD |
| 2 | 2 | flags, 0 |
| 4 | 4 | offset in the area, a multiple of 4096 |
| 8 | 4 | length in bytes |
| 12 | 20 | file name, NUL padded |
| 32 | 32 | SHA-256 of the file |

The firmware refuses the whole directory, with a reason on serial, when any of
these fails: the magic, the version (a newer one says to update the firmware),
the entry size, the zero fields, the CRC, the area size, at most 16 entries and
8 WADs; and for every entry, a known kind, a slot in range, zero flags, a name of
5 to 20 of `a-z 0-9 . _ -` with NUL after it, a WAD name ending `.wad` and a pak
named exactly `pakN.pak` for its slot, a sector-aligned offset, a length of at
least 12 that ends before the directory, no overlap with another entry, and no
name or slot used twice.

The format lives in `firmware/doom/src/platform/game_store_model.h` (the
firmware's parser) and `mac/ESPDisplaySender/Sources/SenderProtocol/GameStore.swift`
(the app's encoder). Both are held to the shared fixture
`mac/ESPDisplaySender/Tests/SenderProtocolTests/Fixtures/game-store-v1.hex`,
by `firmware/test/test_game_store.cpp` and `GameStoreTests`.

## On the board

The boot menu's rows, in order:

1. **STREAMING**
2. **DOOM**, the bundled `doom1.wad`
3. One row per stored WAD the Doom boot would accept, labelled with its name
   without `.wad` in capitals (`freedoom1.wad` reads **FREEDOOM1**). A
   `doom.wad`, `quake.wad` or `streaming.wad` keeps its extension
   (**DOOM.WAD**), so no two rows read the same.
4. **QUAKE**, when the store holds a `pak0.pak` the Quake boot would accept

A stored WAD is checked over its own length: an `IWAD` or `PWAD` header, and a
directory and every lump inside the file. A row that fails is left out and its
reason logged (`boot menu: a stored WAD not offered (...)`).

Choosing a stored WAD saves its name in NVS (`doomwad`) beside Doom's one-shot
request and restarts; the Doom boot plays that file. It reads the WAD through
the flash API into the engine's zone as Doom needs each lump, without mapping
it, because the area crosses 16 MiB, past what the flash cache maps. The zone is
8 MB where PSRAM has room (a P4) and 4 MB otherwise. The engine tells Doom from
Doom II by the file's name (`doom2.wad`, `freedoom2.wad`, `plutonia.wad`,
`tnt.wad`), or for any other name by its maps (MAP01 or E1M1).

Quake is one row. It loads `id1/pak0.pak`, then `pak1.pak` and on, each from its
slot, up to the first slot missing; every pak it loads must pass the Quake
boot's check, or Quake is not offered.

## From the Mac

A P4 or S3 display's Firmware section has a **Games data** row; its
**Install Game Data…** button opens the sheet. Its **Game data** section has:

- A checkbox for Doom, and for Quake where the board runs it.
- Each game's files, each with a checkbox, whether it is in this Mac's cache,
  and whether it is on the board.
- **Choose…** for your own files. A WAD must be an IWAD with E1M1 or MAP01,
  named up to 20 of `a-z 0-9 . _ -` ending `.wad`, and must not be the bundled
  shareware WAD, a PWAD, or a Heretic, Hexen or Strife WAD. A pak must be a
  Quake pack of at most 2,048 files named `pakN.pak` for the pak it is. A file
  that fails is refused with a reason you can select and copy.
- **Download Shareware**: fetches Quake's shareware `pak0.pak` from the mirrors
  `tools/fetch_game_data.sh` uses, checks its size and SHA-256, and keeps it in
  `~/Library/Application Support/ESPDisplaySender/GameData/quake/`.
- **Check Board**: reads the board's store over USB, so each row says whether
  the board already holds that file. The board restarts while it is read.
- **Space**: what the selection takes against the board's usable bytes, and the
  cache's size against this Mac's free space. A selection that does not fit, or
  a Quake set with a gap (`pak1.pak` without `pak0.pak`), blocks the write and
  says why.

**Write over USB** writes the checked games' files:

1. Each file is read and checked again; those bytes are the ones written.
2. The board's hardware ID (CFGSHOW), chip and MAC are verified, as for a
   firmware update, and every read after that must name the same MAC.
3. Its partition table, flash size (S3) and store are read, and the write is
   planned. A file already on the board byte for byte stays where it is.
   `pak0.pak` goes at offset 0 when it can; the rest go first fit, largest
   first. A file on the board is removed only when its row is unchecked or a
   checked file of the same name replaces it; a game left unchecked keeps
   everything it has.
4. When a file moves or goes, a directory naming only the files that stay is
   written first, and the board is verified again.
5. The files, then the new directory, go out in one esptool run, which verifies
   each.
6. The partition table must read back unchanged and the directory exactly as
   written, and the board must answer CFGSHOW again.

Nothing is erased: the firmware, settings and bundled `doom1.wad` are not
touched.

## Over serial

`CFGGAME <label>` starts a boot-menu row by its label, any case, as choosing
it on the menu does, whether or not the menu is open:

```sh
python3 tools/espdisp.py config --port /dev/cu.usbmodemXXXX CFGGAME FREEDOOM1
```

A game restarts the board into it, so it sends no reply. Otherwise:
`CFGOK game=STREAMING`, `CFGERR the boot menu offers no <label>`, or
`CFGERR could not save the <label> request`.
