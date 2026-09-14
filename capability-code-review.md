# Adversarial Self-Review

This is a self-review of the capability fix. An independent review of this
change is still separate.

## Verdict

No blocking code finding remains.

## Checks

- Searched every `formatShowExtension` caller after changing its signature.
- Confirmed `deviceCapabilities()` remains the shared producer for network and
  USB bitsets.
- Confirmed no new capability bit or firmware-version gate was introduced.
- Confirmed old CFGSHOW replies omit `caps` cleanly and the new parser returns
  nil.
- Confirmed malformed, short, and over-wide values return nil rather than
  truncating or guessing.
- Confirmed capability parsing consumes the exact `ssid64` value before reading
  the extension, so an old-firmware SSID token cannot spoof support.
- Confirmed existing CFGSHOW consumers read named fields or only the `CFGINFO`
  prefix; none require an exact token count.
- Confirmed USB requires status evidence, `CAP_ROTATE`, and the existing
  known-square board allowlist.
- Confirmed network requires `CAP_ROTATE` and known square geometry.
- Confirmed rectangular and unknown identities remain 0/180 even under a bad
  capability report.
- Confirmed no orientation classifier, IMU, persistence, region migration,
  DSI linkage mutant coverage, or release manifest behavior was changed.

## Residual Risk

- The reserved CFGSHOW surface needs the human's merge-time sign-off.
- Physical P4 quarter turns and the old-firmware P4 UI state were not observed
  because the bench is empty.
- Full tool and Swift suites still stop on the pre-existing missing build-212
  release files; focused tests and all firmware compile lanes pass.
- AutoSDE session `ses-162d7ca54a7d` returned `permission_denied` with zero
  findings, so an independent pass over this change remains necessary.
