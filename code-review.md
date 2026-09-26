# Adversarial review: 90/270 on rectangular panels

There were two rounds, both by an independent read-only reviewer agent, against the branch `rect-panel-landscape`. There was no CRUX CR and no AutoSDE run: the repo is a personal GitHub project, and the brief forbids pushing, so nothing was sent off-host.

## Round 1 (commit "Allow 90 and 270 degree rotation on rectangular panels")

It found no blocking defects.

1. should-fix: `adoptLocalFrameShape` ran on every MADCTL change, not only on a change of mount. A flip, mirror or auto toggle on an idle card that a landscape stream left at rotation 0 cleared it and stood it portrait. **Fixed**: it now re-shapes only when `localFrameLandscape()` changes.
2. should-fix: the app did not follow a rotation set outside it (serial CFGROT, another Mac), and Choose Region reused a portrait region at 90/270. **Fixed**: `followReportedRotation` follows EINF, ack and USB CFGSHOW reports, with a 3 s echo grace after the app's own command. Choose Region turns a reused portrait region landscape at 90/270.
3. should-fix (design): 90/270 does not turn display, window or automatic sources. **Deferred** as decision D8 in DECISIONS.md: those sources keep their own shape.
4. nit: a stale automatic flip was applied for up to one poll after a mount-parity change, giving a 180 flash. **Fixed**: `desiredPanelRotation` ignores the flip while the parity differs from the tracker's, and the reset now runs ahead of the rate limit.
5. nit: the bootstrap `PANEL_EDGES` odd orientations changed quadrant on rectangular candidates. **Fixed**: they pass `landscape = o & 1`, keeping the old quadrant. The portrait card in a swapped window predates this change and was left alone.
6. nit: `addressedRotation` would silently drop an odd `orientation_offset` on rectangular glass. **Fixed**: the descriptor validator refuses it, and a test covers it.
7. nit: stale comments. **Fixed** in `orientation.h`, `touch_map.h` and `TouchAction.swift`.
8. nit: missing tests. **Partly fixed**: there are now host tests for CAP_ROTATE on the rectangular configs and Swift tests for report following. The adopt/parity logic is hardware-bound and not host-tested. `chooseRegion` puts up the marquee window, so it is not unit-tested.
9. process: the 1.5.0 bundles predated the change. **Fixed**: they are regenerated from the clean final HEAD, with no FW_VERSION bump, per the brief.

## Round 2 (commit "Address review findings on rectangular landscape")

It found no blocking defects. Round-1 items 1, 4, 5, 6 and 7 were confirmed resolved.

1. should-fix: the session status tick replays the last cached EINF every few seconds. With report following, a stale `rotation` could turn the region back, or ping-pong against USB reprobes. **Fixed**: the tick no longer writes orientation (`includeOrientation: false`), because every fresh EINF already arrives as the `.info` event. This also removes a UI glitch that predates the change, where the picker briefly showed the old rotation after a command.
2. nit: following is change-triggered, so a report that lands before the geometry is known is not retried. Also, `setFlip` from an odd rotation did not stand the region up. **Fixed**:
   - `setFlip` now calls `applyRegionQuarterTurn`.
   - A parity change reported before the geometry is known is held in `rotationAwaitingGeometry` and followed when the mDNS or USB geometry arrives. A test covers this.
   - Reconciling on every mismatch was rejected, because it would override a landscape region the user deliberately dragged at 0/180.
3. nit: the `adopted` static in `adoptLocalFrameShape` went stale across a mount change made while streaming. **Fixed**: the shape is recorded on every MADCTL service and re-shapes bufA only when no stream owns it.
4. nit: pressing Escape after Choose Region at 90/270 restores the earlier portrait source. **No change needed**: Escape restores the previous source by design.

## Checked and found correct (by the reviewer)

- **MADCTL**: portrait frames reach only q in {0,2} and landscape frames only {1,3}, so the axis swap always matches the frame shape. The 35/34 gap moves to the row axis at q1/q3.
- **Auto-rotation**: it never yields a quarter turn. The `forMounting` axis and sign math is correct.
- **Touch**: it maps through the same quadrant as the pixels, and `TOUCH_FLAG_LANDSCAPE` agrees with the frame shape.
- **Other panels**: square, P4 and C3 are unaffected (`addressedRotation` is the identity there, and adopt is a no-op).
- **Old firmware**: it never advertised CAP_ROTATE on rectangular glass, so the new app shows those panels the flip toggle.
- **Drawn windows**: Doom, the OTA screen, `fillPanel`, the idle card, the survey screen and the info bar all size to the right shape.
