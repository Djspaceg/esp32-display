# ESPDisplayAudio.driver

A CoreAudio HAL plug-in that gives each ESP device an output of its own in
Sound settings, named after the device. ESPDisplaySender's "Play sound on"
choice (in each device's Audio section; it applies to every device) has two
answers:

- **Follow the Mac's Sound setting** (the default, through this driver): a
  device plays only while its output is the one chosen in Sound settings, or is
  part of a Multi-Output device made in Audio MIDI Setup; otherwise it stays
  quiet. The app never changes the Mac's output and never copies its sound.
  Without the driver the devices stay quiet and the app points at its Install
  button.
- **Also copy the Mac's sound to the devices** (no driver): a process tap copies
  whatever the Mac plays, wherever it plays it, to every device. Needs the
  System Audio Recording permission.

Choices saved by earlier builds load as the nearest one: the old copy and
mirror choices as the copy, the old "only" choice as following the Mac.

## Installing from the app

The app carries a signed copy of the driver (built and signed into
`Contents/Library/Audio` by `embed-driver.sh`, an Xcode build phase). While the
driver is missing, each device's Audio section shows **Install Audio Driver…**;
once it is there, **Remove Audio Driver…**. The click runs one root command
through AppleScript's `do shell script ... with administrator privileges` in
`/usr/bin/osascript`, waited on off the main thread so the window keeps working
while the dialog is up. macOS shows its own administrator dialog (it names
osascript; its text says it is ESPDisplaySender asking, and why), and no
privileged helper is left behind. The command copies the driver into a
root-owned staging folder, checks that copy is Apple-signed by the app's own
team, moves it into `/Library/Audio/Plug-Ins/HAL` and restarts coreaudiod, all
under the same lock `install-driver.sh` takes. The row follows the driver
appearing on its own, and a cancelled prompt or a failure is shown as
selectable text. Quitting the app while the dialog is up ends it unanswered. The
lock is an empty root-only file, `.ESPDisplayAudio.lock`, left in the HAL folder;
it is not a driver and macOS ignores it.

## Build, install, remove (developers)

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

- `'ESrg'` on the plug-in object: the app sets the list of ESP devices it wants
  devices for, every two seconds. A list nobody repeats for ten seconds is
  dropped, so a quit or crashed app leaves no silent outputs.
- `'ESpc'` on each device: the app reads the frames mixed for that device since
  its last read, every 10 ms.

Each registration carries a per-launch secret token. The first live client to
list an ESP device owns its output, and `'ESpc'` answers only a read qualified with
the owner's token, so no other app can record the Mac's sound through the
driver or take frames from the app. A process that registers an ESP device's UID
before the app does would own that device instead (and the app gets silence);
that is the one gap left, and it needs a process already running as the user.

Custom properties are used rather than a mach service because coreaudiod runs
the plug-in in the system launchd domain, where a service an app vends in the
user's session cannot be looked up; that would need a second privileged install.

The device is 48 kHz stereo Float32, output only, with a volume and a mute
control applied to what the app reads, and reports the ESP device's downlink
buffer as its latency so video players delay their picture to match.
