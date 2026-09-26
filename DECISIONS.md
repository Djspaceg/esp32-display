# Outcome

The ESP32-S3-LCD-1.9 and both C6 1.47-inch panels now accept 90 and 270 degrees through the existing `rot=`, CFGROT, Rotate and CAP_ROTATE. Picking either in the app turns the capture region on its side (320x170 on the 1.9). No wire-protocol or CFG command changed. Not yet checked on the glass.

# Decisions to evaluate

D1 On rectangular glass the frame's shape decides the MADCTL axis swap, and only rotation's half turn reaches the quadrant (`panelorient::addressedRotation`). Why: this never draws a frame of the wrong shape, and 0/180 stay byte-identical. If overruled: firmware would need a new frame format to turn portrait frames.
D2 Rotation 1 with landscape frames is q=1, and 3 is q=3, the same as square glass. The 1.9's 35-column gap moves to the row axis. Why: it matches the square and old landscape conventions. If overruled: swap them in `addressedRotation`.
D3 A frame of the wrong shape for the rotation (old app, CLI CFGROT mid-stream) draws in its own shape and lies sideways. Why: the sender owns the frame shape. If overruled: the firmware letterboxes or refuses it.
D4 A parity change on rectangular glass sets the region's shape (landscape at 90/270, portrait at 0/180) instead of toggling it. Why: a region already dragged landscape at 0 stays landscape at 90. If overruled: toggle, as on square glass.
D5 Automatic correction stays a 180 flip. In a landscape mount it reads the flip across the other axis (`motionorient::forMounting`) and resets on a parity change. Why: sideways gravity would otherwise never correct. If overruled: flip-only reads the portrait axis in every mount.
D6 With no stream, the on-device screens (boot fills, idle, survey, WiFi selector) go landscape at 90/270, and a mount change clears bufA to the new shape. Why: they already lay out for either shape. If overruled: they stay portrait.
D7 Doom is unchanged: it forces rotation 0 and draws portrait, letterboxed. Why: its controls are laid out for that orientation. If overruled: a separate landscape Doom task.
D8 Picking 90/270 turns only a region source. Display and window sources keep their own shape. Why: they have no region to turn. If overruled: letterbox them into the rotation's shape.
D9 A rotation set outside the app (serial, another Mac) also re-shapes the region, except within 3 s of the app's own command. A change reported before the geometry is known waits for it. The status tick no longer replays a stale EINF rotation. Why: stale reports would turn the region back. If overruled: only the app's picker turns it.

# Open questions

- Which physical way round 90 is: the default is D2, and the user confirms on the glass.
- The landscape-mount flip direction on the 1.9 and C6 Touch IMUs: the default is D5's derivation, which is unmeasured.

# Gate facts

Publish settings: local branch `rect-panel-landscape`. No push, PR, CR or AutoSDE, because this is a personal GitHub repo and the brief says no push. The user merges.
Call sites, packages/*: none touched.
Adversarial-review rounds: 2 (code-review.md). They changed D6 and D9 and added the validator rule.
Lanes, all passing, ran on `68175cb` (the commits after it touch docs only):
- `gate-firmware-tests.log`
- `gate-test-espdisp.log`
- `gate-compile-s3.log`
- `gate-compile-c6.log`
- `gate-swift-test.log`
- `gate-descriptor-check.log`
- `release-shipping.log`: bundles from clean `aa00127`, with no FW_VERSION bump
- `app-build.log`: Release build into `esp32-display-rect-landscape-appbuild`, not installed or launched

# Evidence

- `code-review.md`: the findings and what became of each.
- The `gate-*.log`, `release-shipping.log` and `app-build.log` files: the lanes above.

# Residuals

- No hardware check yet; it waits on the user's serial window.
- The C6 boards are not attached.
- There are no host tests for the adopt/parity firmware state or for Choose Region.
