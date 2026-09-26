# Reconciliation review record

This file preserves the independent review records that existed on each parent
before this branch reconciled onto `main`. It does not replace the independent
review required after this handoff.

## C3 compact framebuffer review

Independent review of the compact C3 circle framebuffer completed in three
passes.

### Findings and dispositions

1. High: entering the C3 survey or Wi-Fi selector state could suppress streamed
   frames while the corresponding full-frame UI was unavailable. Fixed by
   rejecting those entries before state changes on C3.
2. Medium: a stream-row DMA timeout could permit reuse of the one-row DMA
   staging buffer. Fixed by requeueing the band and stopping the row loop.
3. High: a boot-fill DMA timeout could permit reuse of the same staging buffer.
   Fixed by counting the error and stopping the fill loop.

The final independent re-review found all three issues resolved and no remaining
issue in circle mapping, protocol compatibility, span writes, bounds safety, or
non-C3 paths.

### Residual verification

The C3 booted from the canonical bundle with buffer allocation, C3 identity,
GC9107 placement, and CST816 touch in serial output. The board has no Wi-Fi
credentials, so no EINF packet or streamed-frame draw could be captured. Glass
appearance of the final network stream remains unverified.

## Main audio reconciliation review

Scope: local main at `7f64213` plus origin audio commit `2968684`, reconciled
on `trial-audio-cherrypick`.

An independent read-only reviewer inspected the final reconciliation diff. It
did not edit files, run tests, access hardware, or use any code-review service.

### Conflict-resolution checks

The reviewer verified all required unions in `AppMain.swift`:

1. `launchSession` retains local `source:` and incoming `audioDescriptor:`.
2. `DeviceSession` retains local `source ?? sourceFor(name)` and incoming
   audio session, descriptor, session factory, and `applyAudio`.
3. Discovery retains local `persistedSources()` and incoming `reconcileAudio`
   plus unavailable-audio clearing.
4. Discovered-device launch retains the local persisted source argument and
   the incoming audio descriptor.

The mDNS resolution retains local `restartMdnsService()` and incoming audio TXT
records plus `_espdisp-audio._udp`. The restart path calls `addMdnsService()`,
so reconnect re-advertises audio.

### Finding and disposition

High: `AudioUplinkReorderBuffer` could turn a hostile forward sample-counter
gap into an unbounded silence allocation.

Fixed: synthesized silence is capped at `(reorder window + 1) * maximum MTU
frames`. A larger gap starts a fresh timeline, records a discontinuity, and
keeps the received packet without allocating silence. `tools/test_espdisp.py`
adds regression checks for the bound, reset behavior, loss accounting, and
discontinuity accounting.

### Assessment

No unresolved review findings. `git diff --check` passed. The final source gate
passes for firmware tests, Python tests, C6/S3/P4 compiles, and Swift tests.
C3 is not a family in this branch and its requested compile command exits 2.
