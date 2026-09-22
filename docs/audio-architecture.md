# ADR: Privileged audio streaming

- Status: Proposed
- Date: 2026-09-22

## Context

The repository has no audio subsystem today. There is no I2S or PDM setup,
codec driver, audio descriptor section, audio capability bit, audio datagram,
or Mac audio sender/receiver. Doom's `i_sound.h` and `i_cdmus.h` interfaces are
present, but `firmware/doom/src/platform/doom_esp32_stubs.c.inc` implements
no-op backends. `mac/ESPDisplaySender/Sources/SenderCore/MediaControl.swift`
sends macOS media keys and carries no audio samples.

The first product phase streams Mac audio down to the panel. Microphone audio
then streams up to the Mac for voice relay. Doom sound effects are a later
producer that must join the same hardware sink without changing its ownership
model. The non-negotiable scheduling rule is:

> Audio is the privileged stream. When radio, CPU, internal RAM, PSRAM, or
> panel bandwidth is over budget, video loses fidelity or update rate first.

This ADR defines the descriptor data and the future module boundaries. It does
not implement audio, allocate a wire-protocol bit, or change firmware behavior.

## Decision

### Verified board identity

The requested mapping agrees with the checked-in descriptors and Waveshare
identity:

- `silver-round` is `boards/s3-touch-amoled-175c.toml`: Waveshare
  ESP32-S3-Touch-AMOLED-1.75C, CO5300, 466x466.
- `black-round-185-tall` is `boards/s3-touch-lcd-185c.toml`: Waveshare
  ESP32-S3-Touch-LCD-1.85C / 1.85C-BOX, ST77916, 360x360. The BOX option is the
  same board family packaged with a battery and speaker enclosure.

Primary sources:

- [AMOLED product documentation](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75C)
- [AMOLED schematic](https://files.waveshare.com/wiki/ESP32-S3-Touch-AMOLED-1.75C/ESP32-S3-Touch-AMOLED-1.75C-schematic.pdf)
- [1.85C product documentation](https://docs.waveshare.com/ESP32-S3-Touch-LCD-1.85C)
- [1.85C V1 schematic](https://files.waveshare.com/wiki/ESP32-S3-Touch-LCD-1.85C/ESP32-S3-Touch-LCD-1.85C-Schematic.pdf)
- [1.85C V2 schematic](https://files.waveshare.com/wiki/ESP32-S3-Touch-LCD-1.85C/ESP32-S3-Touch-LCD-1.85C_V2.pdf)

### Verified hardware: 1.75C AMOLED

The schematic shows one mono speaker path and two microphone capsules:

| Item | Verified fact | Source |
| --- | --- | --- |
| Output codec | ES8311 at I2C address `0x18` | schematic; [ES8311 demo](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75C/blob/6d19f7e16fb9a3be219e9eed43ca9eb56c88d01c/examples/arduino/examples/07_ES8311/15_ES8311.ino) |
| Speaker amp | NS4150B, differential mono, `CTRL` on GPIO46 | schematic; [pin header](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75C/blob/6d19f7e16fb9a3be219e9eed43ca9eb56c88d01c/examples/arduino/libraries/Mylibrary/pin_config.h) |
| Amp rail | `VCC3V3` | schematic, `PA&SPEAKER&MIC` block |
| Speaker | 8 ohm, 1 W enclosure speaker | schematic, H3 annotation |
| Capture ADC | ES7210 at I2C address `0x40` | schematic; [ES7210 demo](https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75C/blob/6d19f7e16fb9a3be219e9eed43ca9eb56c88d01c/examples/arduino/examples/06_ES7210/08_ES7210.ino) |
| Microphones | two analog microphone capsules into ES7210 differential inputs | schematic, MIC1/MIC2 and ADC block |
| Serial audio | MCLK GPIO16, BCLK GPIO9, LRCK GPIO45, ESP-to-codec GPIO8, ADC-to-ESP GPIO10 | schematic; pin header; both demos |
| Demonstrated format | 16 kHz, 16-bit; output uses two I2S slots and capture enables TDM channels 0/1 | both demos |
| Control bus | existing descriptor I2C GPIO15 SDA / GPIO14 SCL | pin header; both demos |

Unknown on this board:

- microphone capsule manufacturer and part number;
- speaker acoustic response and safe software gain limit;
- oscillator tolerance and long-run sample-clock drift;
- whether every shipped PCB revision is electrically identical to the fetched
  schematic.

The descriptor therefore names ES7210 as the capture device, not as the
microphone capsule.

### Verified hardware: 1.85C / 1.85C-BOX

Waveshare marks V1 discontinued and V2 as its replacement. Both revisions have
a speaker and microphone, but they are not software-compatible audio variants.

| Item | V1 | V2 |
| --- | --- | --- |
| Output converter | PCM5101APWR, no I2C control | ES8311, I2C `0x18` |
| Speaker amp | NS8002 | NS4150B |
| Amp enable | no GPIO enable documented | GPIO15 `PA_CTRL` |
| Amp rail | schematic net `5V_PCM`; upstream voltage not conclusively named | schematic net `VCC`; upstream voltage not conclusively named |
| Microphone path | one ICS-43434 digital I2S microphone | two analog capsules into ES7210 |
| Capture control | no I2C capture device | ES7210 on the existing GPIO11/10 I2C bus |
| Common output pins | BCLK GPIO48, LRCK GPIO38, ESP data out GPIO47 | same |
| Capture pins | SCK GPIO15, WS GPIO2, data GPIO39 | shared BCLK GPIO48, LRCK GPIO38, data GPIO39, MCLK GPIO2 |
| Demonstrated V2 format | not applicable to the V1 sources fetched | 16 kHz in the current Arduino and ESP-IDF examples |

Sources are the two schematics above, the product page's V1/V2 pin table, and
the current V2 [Arduino output demo](https://github.com/waveshareteam/ESP32-S3-Touch-LCD-1.85C/blob/8ead4a96bf3a278fc4ebd8ef4768657e17fa2880/Arduino/examples/05_audio_out_tf/05_audio_out_tf.ino)
and [ESP-IDF board header](https://github.com/waveshareteam/ESP32-S3-Touch-LCD-1.85C/blob/8ead4a96bf3a278fc4ebd8ef4768657e17fa2880/ESP-IDF/ESP32-S3-Touch-LCD-1.85C-Test/components/auido_borad/boards/include/ESP32_S3_AUDIO_Board.h).
Waveshare specifies the BOX speaker as 4 ohm, 5 W on the product page.

Unknown until an attached 1.85C is inspected:

- whether its PCB is V1 or V2;
- consequently, every audio part and every revision-dependent audio GPIO;
- V1 sample rate and channel format used by Waveshare's original firmware;
- exact voltage feeding the `5V_PCM`/`VCC` amplifier rail under USB and battery;
- V1 shutdown-pin treatment and V2 safe gain;
- microphone and speaker acoustic performance.

The descriptor cannot select V2 merely because V2 is current. It advertises
physical audio, but every implementation-specific field remains unknown.

### Pin collision audit

All documented audio pins were compared with panel, touch, IMU, backlight,
battery, LED, serial, expander/detection, and reset declarations.

| Board/revision | Audio GPIOs checked | Result |
| --- | --- | --- |
| 1.75C | 8, 9, 10, 16, 45, 46 | no collision |
| 1.85C V1 | 2, 15, 38, 39, 47, 48 | no collision |
| 1.85C V2 | 2, 15, 38, 39, 47, 48 | no collision |

The codec-control buses intentionally reuse each board's existing touch and
detection I2C bus. The audio descriptor records only device addresses for that
reason; duplicating SDA/SCL as audio pins would turn intended bus sharing into
two sources of truth.

### Descriptor schema

Every descriptor now has `[audio]`, and `[capabilities].audio` is data only.
No firmware protocol bit consumes it.

| Field | Purpose |
| --- | --- |
| `amp` | Selects amp-specific enable and power sequencing. |
| `codec` | Selects output conversion and any I2C register initialization. |
| `mic` | Selects the capture ADC or direct digital microphone. |
| `speaker_bus` | Distinguishes absent, unknown, and I2S playback. |
| `mic_bus` | Distinguishes absent, unknown, I2S, and future PDM capture. |
| `pin_playback_mclk`, `pin_playback_bclk`, `pin_playback_lrck` | Playback clocks, including register-controlled codec MCLK. |
| `pin_capture_mclk`, `pin_capture_bclk`, `pin_capture_lrck` | Independent capture clocks; values may equal playback clocks on a shared bus. |
| `pin_dout`, `pin_din` | MCU-perspective playback and capture data. |
| `pin_pdm_clock` | PDM clock when capture does not use I2S clocks. |
| `pin_amp_enable` | Explicit shutdown/enable control; never inferred. |
| `codec_i2c_address`, `mic_i2c_address` | Register-control endpoints on the already-declared board I2C bus. |
| rate/channel fields | A verified hardware/demo operating point and buffer-sizing input. Zero means absent or unverified. |

The validator enforces enums, 8-96 kHz rates, 1-8 channels, I2C address
presence, topology-specific pins, and target GPIO ceilings (C6 30, S3 48, P4
54). Unlike existing generic descriptor pins, `-5` cannot pass: an audio pin
is exactly `-1` or a target-valid non-negative GPIO.

An audio-absent row must be all `none`, `-1`, and zero. A revision-unknown row
must be wholly `unknown` with no concrete pins, addresses, rates, or channels.
A verified row must be complete. Each concrete audio GPIO is also compared
against every existing pin-bearing section and validation refuses the first
collision.

`tools/generate_board_descriptors.py` emits `generated_board_audio.h` as
constexpr data plus `supportsAudio(Variant)`. `audio_config.h` defines only the
data model. Neither file initializes hardware.

### Firmware module boundary

The future ownership graph is:

```text
audio_transport  ->  audio_engine  ->  audio_backend
   UDP RX/TX          jitter/mix        I2S + control I2C
        |                 |
        |                 +-- DoomSfxSource (phase 2)
        |
net_link -> frame_pipeline -> panel_transfer -> panel DMA
                         \-> dma_gate ownership barrier
```

`audio_transport` owns separate audio sockets, sequence validation, and mic
uplink framing. It does not feed `frame_pipeline`; video packet parsing remains
unchanged. `audio_engine` owns clock-domain conversion, jitter fill, the mixer,
gain, underrun state, and fixed-size internal buffers. `audio_backend` owns I2S
and control-register sequencing.

Backends split by electrical topology, not CPU family:

- `DirectSerialAudioBackend`: a register-free I2S DAC/amp and direct I2S or PDM
  microphone. This covers the 1.85C V1 shape and future dumb-I2S/PDM carriers.
- `CodecSerialAudioBackend`: ES8311-class output plus ES7210-class capture,
  initialized over the board's existing I2C bus. This covers the 1.75C and
  1.85C V2 shape. A future P4 carrier supplies its resolved descriptor I2C bus
  to the same backend; the backend does not own board detection.

The facade exposes `start`, `writeFrames`, `readFrames`, `setGain`, and
`stop`; it does not expose ES8311 registers to `audio_engine`. This avoids
forcing direct hardware through fake codec operations or making a future P4
codec look like an S3 special case.

`dma_gate` continues to protect panel-transfer source ownership and the
flash-write exclusion. Audio must never hold it for playout: a continuous I2S
clock cannot wait for panel DMA. Conversely, panel code may not borrow audio
DMA storage. The two DMA engines have disjoint, fixed internal-RAM pools.

### Contention and memory budget

Current repository facts constrain the design:

- `panel_transfer_plan.h` caps one S3 staging slot at 15,360 bytes and owns two
  slots: 30,720 bytes of internal DMA-capable RAM.
- `panel_transfer.cpp` copies PSRAM pixels into those slots so panel DMA does
  not consume PSRAM bandwidth. `dma_gate` prevents source reuse and is drained
  around panel/flash transitions.
- `net_link.cpp` runs the S3 receive task at priority 9, default-pinned to core
  1; `CFGRXCORE` already provides a measured precedent for affinity changes.
- `docs/tile-stream-plan.md` sections 17.3-17.4 record useful operation around
  296-300 datagrams/s, degradation by 427/s, and collapse around 575/s while
  the 466 panel paints. The useful payload rate is about 0.44 MB/s.
- Two 466x466 RGB565 framebuffers occupy 868,624 bytes of PSRAM.
- Each S3 app slot is 2,031,616 bytes. The supported compile lane reports the
  post-change sketch at 1,435,082 bytes, leaving 596,534 bytes of app-slot
  headroom.

The proposed full-duplex audio reserve is about 16 KB of internal RAM:

- 5,760 bytes: maximum 180 ms downlink jitter at 16 kHz, mono PCM16;
- 5,120 bytes: eight 10 ms stereo-slot I2S DMA buffers;
- 2,560 bytes: four 20 ms mono capture blocks;
- about 2,560 bytes: mixer, resampler, crossfade, and framing scratch.

No real-time audio sample buffer lives in PSRAM. That costs video 16 KB of
internal headroom and may require reducing tile decode scratch concurrency,
socket burst buffering, or draw queue depth after measurement. It does not
shrink or alias the existing 30,720-byte panel staging pool. PSRAM remains for
the two framebuffers and non-deadline state.

### Clock domain, jitter, and underrun

The network proposal uses 16 kHz, signed PCM16, mono, in 20 ms packets: 320
samples and 640 payload bytes, or 50 datagrams/s and 32 KB/s per direction.
The rate is demonstrated by the target-board vendor examples. The backend
duplicates mono into the two I2S output slots where hardware expects stereo.

UDP arrives in bursts, but I2S cannot. The panel I2S peripheral is the playout
clock master. Playout starts only after 120 ms is buffered. The operating range
is 80-180 ms:

- above 120 ms, slightly speed the asynchronous resampler;
- below 120 ms, slightly slow it;
- constrain normal correction to a small measured range, initially +/-1000
  ppm, so clock drift is removed without pitch steps;
- outside 80-180 ms, make one crossfaded 10 ms hard correction and count it.

Per-sample drop/insert is rejected as the normal drift policy because periodic
discontinuities contradict the unbroken-audio bar. A low-cost fractional linear
resampler at 16 kHz mono is the default; quality can be raised later without
changing transport or backend ownership.

An underrun cannot honestly be called unbroken sound. The recovery behavior
minimizes damage but records a failure:

1. Never stop the I2S peripheral or sample clock.
2. Fade the final 5 ms to zero and emit zero samples.
3. Stop all video transmission immediately.
4. Refill to 120 ms while the clock continues.
5. Fade audio back in and report underrun count, duration, and minimum fill.

This avoids a click and avoids an I2S restart gap, but audible silence remains.
Acceptance therefore requires zero underruns in the target stress run; the
concealment path is not the success criterion.

### Privileged-stream mechanism

Audio wins through mechanisms, not intent:

- I2S service task: core 1, priority 12, above video receive priority 9 and
  loop/draw priority 1, below WiFi/lwIP system tasks.
- Audio transport: a separate UDP port and socket/task, so video parsing and
  video mailbox bursts cannot head-of-line block audio. The human must assign
  the port before implementation.
- Sender pacing: audio packets are deadline-scheduled first. Video receives
  only tokens left after the 50 datagrams/s audio reservation and safety
  margin.
- Low watermark: below 80 ms fill, video sends nothing. Between 80 and 120 ms,
  it sends only already-prepared high-value dirty tiles. Above 120 ms, it may
  spend the measured residual budget.
- Video degradation order: postpone keyframes, lower dirty-tile rate, drop
  least-recent/non-visible bands, then skip whole video frames. Never evict an
  audio packet to preserve a frame.
- Uplink accounting: microphone packets consume radio airtime even though they
  do not enter the downlink receive queue. Sender pacing subtracts observed
  uplink airtime/loss from the video budget.

Named failure modes are audio socket/mailbox overflow, I2S DMA starvation,
priority inversion on an I2C or logging lock, sender burst bunching, WiFi
retries consuming the margin, clock drift exceeding the resampler bound, and
video work already in a non-preemptible critical section. Each requires a
counter and minimum jitter-fill telemetry; "video looked slow" is insufficient
diagnosis.

### Microphone uplink

The backend captures at the descriptor's verified format, selects or mixes the
physical channels to 16 kHz mono PCM16, and hands 20 ms blocks to
`audio_transport`. Each proposed uplink datagram carries stream version,
sequence, sample counter, capture timestamp, flags, and 640 bytes of PCM.

The Mac maintains a short receive jitter queue, converts the stream into its
CoreAudio processing format, and exposes it to a relay component. The eventual
relay target (virtual input device, app-specific voice transport, or another
network endpoint) is a Mac product decision and is not present today.

Downlink and uplink share one ESP32 radio. At the baseline format they total
100 audio datagrams/s and 64 KB/s of payload before UDP/IP and retry overhead.
That is below the measured payload ceiling but consumes one third of the
documented 300-datagram/s operating point before video. Full-duplex stress,
not separate one-way tests, is the acceptance lane.

### Proposed protocol changes, not approved or implemented

Wire protocol and capability allocation remain reserved for human approval.
This change proposes names and behavior only:

- capabilities `audioDownlink` and `audioUplink`, with bit positions unassigned;
- versioned datagram kinds `audioPcmDownlinkV1` and `audioPcmUplinkV1`, with
  numeric values unassigned;
- a dedicated audio UDP port, numeric value unassigned;
- sequence, stream generation, sample counter, timestamp, format flags, and
  payload length in every datagram;
- an audio status message carrying fill, underruns, late/lost packets, hard
  corrections, and capture overruns.

Compatibility is fail-closed:

- new app + old panel: no audio capability, so the app sends video only;
- old app + new panel: no audio datagrams arrive, so the panel remains muted;
- new peers with different audio versions: no audio starts;
- unknown audio datagrams never enter the existing video parser because the
  proposed port is separate;
- descriptor `capabilities.audio` must not be serialized as a protocol bit
  until the human allocates and approves it.

### Doom phase 2

Doom's current `DG_StartSound` no-op is replaced by a `DoomSfxSource` that
feeds the same `audio_engine` mixer used by streamed audio:

```text
I_StartSound -> DG_StartSound -> DoomSfxSource
             -> 8-channel mixer -> resampler -> audio_backend
```

WAD sound effects are 11,025 Hz, unsigned 8-bit mono. The existing Doom
default is eight channels (`snd_channels = 8`), so the mixer can accumulate
eight voices in a wider integer, apply Doom volume/separation, clamp once, and
resample to the backend rate.

This phase needs no network transport, jitter buffer, packet timestamps, or
audio/video synchronization. MUS/OPL music is a separate producer and remains
deferred; implementing SFX must not pull a synthesizer into the first audio
driver.

### Phased plan

1. Land descriptor schema, validation, constexpr data, and this ADR only.
2. On an attached 1.75C, implement backend bring-up and a continuous generated
   tone/silence test with panel streaming disabled.
3. Add local jitter/resampler tests and soak I2S while the 466 panel paints;
   reserve internal buffers only after heap/DMA measurements.
4. Obtain protocol allocation, then add downlink transport and Mac pacing.
5. Prove zero underruns under video overload; tune video degradation before
   increasing audio complexity.
6. Add full-duplex microphone uplink and Mac relay integration; repeat the
   overload test on one radio.
7. Identify attached 1.85C revision, add revision-safe descriptor/detection,
   and implement the matching backend.
8. Replace Doom SFX stubs with the eight-channel local mixer. Defer MUS/OPL.

## Consequences

The descriptor can now represent absent, fully verified, and honestly unknown
audio hardware without changing runtime behavior. The hardware facade supports
direct serial audio and register-controlled codecs without CPU-family
conditionals.

The design spends internal RAM and video throughput to protect continuous
audio. A video frame may become stale or incomplete; an audio packet may not be
dropped merely to preserve it.

## Cannot be known without an attached board

- the 1.85C BOX PCB revision and therefore its usable audio row;
- whether either fetched schematic exactly matches the shipped unit;
- real I2C ACKs for ES8311/ES7210 and safe initialization ordering;
- I2S clock accuracy, drift sign/rate, and the resampler correction bound;
- click/pop behavior, amp shutdown polarity in practice, safe gain, and noise;
- speaker impedance on the actual assembly if it differs from the listed SKU;
- microphone channel order, polarity, sensitivity, echo-reference behavior,
  and acoustic coupling;
- free internal DMA heap after WiFi, panel, touch, and audio drivers coexist;
- sustainable full-duplex packet rate, retry airtime, jitter distribution, and
  the no-underrun video budget;
- whether core 1 remains the best audio affinity under simultaneous radio,
  decode, draw, capture, and playout load;
- end-to-end Mac relay latency and which relay integration the product needs.
