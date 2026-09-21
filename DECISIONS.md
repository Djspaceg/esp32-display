# Decisions

## Outcome

Missing network `res` data no longer becomes 172x320. A known USB `board`
identity now resolves through the generated board catalog, so `co5300` is
466x466; unknown identities remain unknown.

## Decisions to evaluate

D1 Resolve USB `board` tokens through generated board descriptors. Why: those descriptors are the firmware source of truth and the app already reads `board`. If overruled: maintain a separate app mapping.

## Open questions

none

## Gate facts

Publish settings: local commit only; no push, review, auto-publish, or auto-merge.
Call sites for packages/* symbols touched: none touched.
`bash firmware/test/run_tests.sh`: PASS, source-gate.log.
`python3 tools/test_espdisp.py`: PASS, source-gate.log.
`swift test`: PASS, source-gate.log.
macOS app build: PASS, source-gate.log.
Adversarial-review round count: not requested.

## Evidence

source-gate.log: red runtime proof, final source gate, and Debug app build.

## Residuals

None.
