# ESPDisplayAudio.driver

A CoreAudio HAL plug-in that gives each ESPDisplay panel an output device of
its own in Sound settings. ESPDisplaySender uses it for two of its three "Mac
sound" routes (in each display's Audio section; the choice applies to every
display):

- **Copy this Mac's sound** (no driver): a process tap copies whatever the Mac
  plays to every display, and the Mac's own output is left alone. Needs the
  System Audio Recording permission.
- **Mirror to the displays**: the app builds a Multi-Output device of the Mac's
  own output plus every display and makes it the default output.
- **Displays only**: the display (or a Multi-Output device of all of them) is
  the Mac's only output, so the volume keys set its level.

Without the driver the two driver routes fall back to the copy and say so.

## Build, install, remove

```sh
mac/AudioDriver/build-driver.sh                    # build and sign; no admin rights
sudo mac/AudioDriver/install-driver.sh             # copy into /Library/Audio/Plug-Ins/HAL, restart coreaudiod
sudo mac/AudioDriver/install-driver.sh --uninstall # remove it, restart coreaudiod
swift mac/AudioDriver/check-driver.swift           # check the installed driver end to end
bash mac/AudioDriver/test/run_tests.sh             # host tests; nothing is installed
```

`build-driver.sh` signs with the Apple Development identity of the app's
`DEVELOPMENT_TEAM`, as `make-app.sh` does. Restarting coreaudiod stops all sound
for a second or two.

## How it works

The driver has no networking and no clock of its own beyond the host clock. The
app keeps the UDP transport, pacer and drift correction it already uses for the
tap. Two custom CoreAudio properties carry everything, defined in
`ESPDisplayAudioProtocol.h`:

- `'ESrg'` on the plug-in object: the app sets the list of displays it wants
  devices for, every two seconds. A list nobody repeats for ten seconds is
  dropped, so a quit or crashed app leaves no silent outputs.
- `'ESpc'` on each device: the app reads the frames mixed for that device since
  its last read, every 10 ms.

Custom properties are used rather than a mach service because coreaudiod runs
the plug-in in the system launchd domain, where a service an app vends in the
user's session cannot be looked up; that would need a second privileged install.

The device is 48 kHz stereo Float32, output only, with a volume and a mute
control applied to what the app reads, and reports the display's downlink
buffer as its latency so video players delay their picture to match.
