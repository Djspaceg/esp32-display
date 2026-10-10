# Local speaker bring-up (ES8311 + ES7210 boards)

This procedure exercises only a board's speaker path. It applies to every
board whose descriptor declares ES8311 + ES7210 + NS4150B: the 1.75C, the
1.85C V2, the S3-LCD-0.85, the S3-Touch-LCD-1.54, and the P4 4B, 4C and
3.4C. It
does not require WiFi or the Mac sender, and it must not be used to infer that
the microphone or network audio paths work.

At boot, before any audio starts, firmware reads both chips' ID registers
over the codec control bus (read-only; no audio GPIO or clock is touched).
Only a board where ES8311 reads `83 11` and ES7210 reads `72 10` enables
audio, and its amplifier-enable is driven low at that moment.

The safe power-up order implemented by `CodecSerialAudioBackend` is:

0. Check the boot-time chip-ID verdict; refuse before any pin write unless
   both parts were identified.
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

1. Build and flash the board's family from this branch (P4 USB writes need
   the carrier profile):

   ```sh
   python3 tools/espdisp.py flash --family s3 --build --port <port>
   python3 tools/espdisp.py flash --family p4 --build --profile jd9365-4c --port <port>
   ```

2. Open the board's configuration serial port at 115200 baud and wait for
   the identification line, the audio readiness line, and the UDP marker:

   ```text
   audio: codec 0x18 read id=8311, adc 0x40 read id=7210: ES8311+ES7210 identified, amp held off
   audio: UDP 5569 ready
   UDP listening on 5568
   ```

   If the identification line ends `not identified, audio pins untouched`,
   stop: audio is off by design on that unit (on the 1.85C, this is the V1
   revision). Do not send the command until `UDP listening on 5568` appears: setup continues
   servicing serial during its bounded WiFi wait, but tone samples are emitted
   only after setup reaches `loop()`. The UDP line is the readiness marker even
   when WiFi timed out and local tone testing is the only goal.

3. Keep the speaker clear of your ear and send:

   ```text
   CFGAUDIOTEST 1000
   ```

4. Confirm the immediate reply:

   ```text
   CFGOK audio test started for 1000ms; send CFGAUDIOTEST stop to abort
   ```

   The following diagnostic line must name the board's generated descriptor
   values, all at rate 16000 and channels 2:

   | Board | MCLK | BCLK | LRCK | DOUT | amp |
   | --- | ---: | ---: | ---: | ---: | ---: |
   | 1.75C | 16 | 9 | 45 | 8 | 46 |
   | 1.85C V2 | 2 | 48 | 38 | 47 | 15 |
   | 0.85, 1.54 | 8 | 9 | 10 | 12 | 7 |
   | P4 4B, 4C, 3.4C | 13 | 12 | 10 | 9 | 53 |

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

1. `CFGERR board descriptor has no audio` means the detected profile's
   vendor hardware has no speaker or microphone.
2. `CFGERR audio disabled: board revision is not safely distinguishable`
   means the ES8311 and ES7210 did not both answer with their chip IDs at
   boot. On the 1.85C this is the V1 revision; elsewhere it means the parts
   are absent or the control bus is faulty. Do not override this guard.
3. `CFGERR codec/I2S initialization failed; amp remains disabled` means I2S
   allocation, the shared I2C bus, ES8311 at `0x18`, or ES7210 at `0x40`
   failed after identification. The code cannot distinguish those without
   hardware traces.
4. `audio: ERROR tone write failed; amp disabled` means initialization
   completed but the I2S write path stopped accepting complete frame blocks.
5. Correct serial output with no tone does not isolate a failing component.
   First confirm the command was sent after the readiness marker, then capture
   MCLK, BCLK, LRCK, DOUT, GPIO46 polarity, and the speaker output before
   changing gain or the power sequence.
6. `CFGERR network audio did not pause; amp unchanged` means the audio
   engine task did not let go of the codec within 200 ms. A connected Mac
   sender no longer blocks the tone: its stream, silence included, is paused
   for the tone (`audio: network stream paused for the tone`) and resumes on
   its next packets.
7. The ESP32-P4-WIFI6-Touch-LCD-4B ships with no speaker, only an empty
   1.25 mm 2-pin AUDIO connector (8 ohm 2 W). Check one is plugged in before
   reading silence as a fault. Package content and speaker header:
   https://www.waveshare.com/esp32-p4-wifi6-touch-lcd-4b.htm and
   https://www.waveshare.com/wiki/ESP32-P4-WIFI6-Touch-LCD-4B
8. A click/pop without the tone is likewise insufficient to distinguish an
   I2S, codec-routing, amplifier, speaker, or revision problem. Preserve the
   serial log and clock/GPIO captures for diagnosis.
