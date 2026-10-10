# Vendored engine

quakegeneric, https://github.com/erysdren/quakegeneric, at commit
`13052102577c629650cf07a46151a4b6e1b19c3c` ("source/makefile: overhaul",
2025-01-27). id Software's GPL WinQuake software renderer cut down to a few
platform callbacks, as doomgeneric is for Doom. GPL-2.0-or-later; the licence
text is `../../LICENSE-GPL2`, upstream's own `LICENSE`.

Every `.c` from upstream's makefile is here as `<name>.c.inc`, except the ones
this port replaces; the few edits are listed below:

| Upstream | Replaced by |
| --- | --- |
| `sys_null.c` | `../platform/quake_sys_esp32.c` (files, time, errors, console) |
| `vid_null.c` | `../platform/quake_sys_esp32.c` (buffers allocated, RGB565 palette) |
| `quakegeneric.c` | `../platform/quake_sys_esp32.c` (`quake_engine_start`) |
| `quakegeneric_*.c` | `../platform/quake_hw_bridge.cpp` |
| `snd_null.c` | `snd_dma.c`, `snd_mix.c`, `snd_mem.c` (below), and `../platform/quake_snd_esp32.c` as the sound device |

The three sound sources are not in quakegeneric, which builds silent: they are
id's own, from [id-Software/Quake](https://github.com/id-Software/Quake)
`WinQuake/` at commit `bf4ac424ce754894ac8f1dae6a3981954bc9852d` (GPL-2.0, the
same code quakegeneric's engine came from), with line endings made LF. Their
one edit is in the list below.

All headers are upstream's, unedited, bar `sound.h`'s one rename below. Most of what the port needs is done
from outside, in the prelude every engine unit includes first
(`../platform/quake_prelude.h`):

- `quake_statics.h` and the generated `quake_statics_lists.h` turn the
  zero-initialised file-scope globals of 20 bytes or more (bar a few listed in
  `update_statics.py`) into pointers to
  storage allocated when a Quake boot starts (internal RAM for the renderer's,
  PSRAM for the rest). The P4 image carries the engine on every boot, and
  Arduino's prebuilt IDF cannot put .bss in PSRAM, so upstream's ~680 KB of
  .bss would otherwise come out of the internal RAM streaming needs (about
  430 KB of it is relocated this way; the 230 KB frame and depth buffers of
  the replaced `vid_null.c` are allocated by the platform layer instead).
- `quake_renames.h` renames the globals Doom's engine also defines.

The engine sources carry five kinds of small edit, each marked `espdisp:`,
all but the sound guard for the same reason (internal RAM in the streaming
firmware):

- Nine function-local static buffers moved to file scope under their own
  names, so the relocation above can reach them: `Con_DebugLog`,
  `MSG_ReadString`, `va`, `Mod_DecompressVis`, `PF_VarString`,
  `PR_ValueString`, `PR_UglyValueString`, `PR_GlobalString`,
  `PR_GlobalStringNoContents`.
- `S_Init`'s "Sound sampling rate" line guarded by `if (shm)`: upstream reads
  through a NULL `shm` when the sound device fails to start, so a board without
  audio would crash instead of playing silent.
- The global `channels` array of `snd_dma.c` renamed `sound_channels`, in
  `sound.h`, `snd_dma.c` and `snd_mix.c`: `channels` is also a member of two
  sound structs, which the relocation would rename too.
- `Host_Please_f`'s local `cl` renamed `client` (it is compiled only with
  IDGODS, but the relocation renames every `cl`).
- Read-only tables made `const`, so they stay in flash: `r_avertexnormals`,
  `keynames`, `svc_strings`, `pop`, `pr_opnames`, `bindnames`, `quitMessage`,
  `levels`, `hipnoticlevels`, `roguelevels`, `episodes`, `hipnoticepisodes`,
  `rogueepisodes`, `ramp1`-`ramp3`, and the pointers that read them.

The engine headers have no include guards, so each source compiles as its own
unit through a wrapper in `../engine_units/`, written by
`../../update_engine_units.sh`.

To update: replace the `.c.inc` and `.h` files from a new upstream commit,
reapply the `espdisp:` edits, record the commit above, compile the engine
units with the P4 toolchain, run `../../update_statics.py <objects>` and
`../../update_engine_units.sh`, and run `firmware/test/run_tests.sh`
(test_quake_statics checks the relocation lists against the sources).
