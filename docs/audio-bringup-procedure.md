# 1.75C local speaker bring-up

This procedure exercises only the ESP32-S3-Touch-AMOLED-1.75C speaker path.
It does not require WiFi or the Mac sender, and it must not be used to infer
that the microphone or network audio paths work.

The safe power-up order implemented by `CodecSerialAudioBackend` is:

1. Drive the descriptor's NS4150B enable pin low.
2. Start I2S clocks from the descriptor's MCLK, BCLK, LRCK, DOUT, DIN, rate,
   and slot count.
3. Queue zero samples before any analog output can be enabled.
4. Initialize the descriptor's ES8311 and ES7210 over the board I2C bus, with
   the ES8311 muted.
5. Set a conservative startup codec gain.
6. Unmute the ES8311 after its clocks and zero stream are stable.
7. Enable the NS4150B last.

Every initialization failure and every normal stop disables the amplifier
before muting the codec and stopping I2S.

## Procedure

1. Build and flash the S3 family sketch from this branch:

   ```sh
   python3 tools/espdisp.py compile --family s3
   python3 tools/espdisp.py flash --family s3
   ```

   Flashing is intentionally a human step; this change was developed without
   attached hardware.

2. Open the board's configuration serial port at 115200 baud and wait for:

   ```text
   board: ESP32-S3-Touch-AMOLED-1.75C
   ```

   If another profile is reported, stop. `CFGAUDIOTEST` is allowed only for
   the uniquely identified 1.75C profile. The 1.85C profile remains disabled
   because firmware cannot distinguish incompatible V1 from V2 hardware.

3. Keep the speaker clear of your ear and send:

   ```text
   CFGAUDIOTEST 1000
   ```

4. Confirm the immediate reply:

   ```text
   CFGOK audio test started for 1000ms; send CFGAUDIOTEST stop to abort
   ```

   The following diagnostic line must name values from the generated
   descriptor: rate 16000, channels 2, MCLK 16, BCLK 9, LRCK 45, DOUT 8, and
   amp 46.

5. Listen for a steady 440 Hz tone lasting one second. At completion, confirm:

   ```text
   audio: tone complete; amp disabled, codec muted
   ```

6. To abort a longer test, send:

   ```text
   CFGAUDIOTEST stop
   ```

   Confirm both `audio: tone stopped; amp disabled, codec muted` and
   `CFGOK audio test stopped`.

## Failure meaning

1. `CFGERR board descriptor has no audio` means the detected profile is not
   the 1.75C audio descriptor.
2. `CFGERR audio disabled: board revision is not safely distinguishable`
   means the profile is 1.85C; do not override this guard.
3. `CFGERR codec/I2S initialization failed; amp remains disabled` means I2S
   allocation, the shared I2C bus, ES8311 at `0x18`, or ES7210 at `0x40`
   failed. The code cannot distinguish those without hardware traces.
4. `audio: ERROR tone write failed; amp disabled` means initialization
   completed but the I2S write path stopped accepting complete frame blocks.
5. Correct serial output with no tone points to the analog path: amplifier
   polarity, speaker connection, codec analog routing, gain, or a board
   revision mismatch. Do not increase gain until the GPIO and codec clocks
   have been measured.
6. A click/pop without the tone means the amp switched but valid serial audio
   did not reach the ES8311. Capture MCLK, BCLK, LRCK, and DOUT before changing
   the power sequence.
