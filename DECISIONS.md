# Orientation Decisions

1. Rectangular side gravity is ignored until up/down settles.

   A non-square panel keeps its last stable automatic correction, either 0 or 180, while gravity points toward either side. A side sample clears any pending candidate. Only a dominant up/down sample held for 500 ms can commit a new correction. This avoids an arbitrary nearest-side choice and prevents jitter near diagonals.

2. Manual orientation is the persisted base; automatic orientation is an additive correction.

   Effective rotation is `(manual + automatic) mod 4`. The app changes `panelRotation`; gravity changes only RAM-only `automaticRotation`. For example, a square panel set manually to 90 remains at effective 90 while upright; if the board is physically rotated so the classifier produces 270, the effective rotation becomes 0 while the saved manual choice remains 90. On a rectangular panel, a manual 180 plus an automatic 180 composes to effective 0.

3. App choices follow validated panel geometry.

   Square panels expose 0/90/180/270. Rectangular panels expose 0/180 because their quarter-turn framebuffer geometry is still intentionally unsupported. A device with no IMU still exposes the same manual choices; it simply keeps automatic correction at 0.

4. The rectangular 90-degree backlog gate is satisfied for automatic orientation.

   Flip-only defines the behavior explicitly: side gravity never applies an automatic 90 or 270 correction. Nothing remains ambiguous for the rectangular IMU profile (`jd9853`). This does not enable manual rectangular quarter turns.

5. The backlog's `st7703-4b` description is stale relative to code.

   `PANEL_ST7703_720X720` is square and `CONFIG_P4_4B` has no IMU, so rectangular flip-only policy does not apply to it. Its manual 90/270 behavior is defined by the repaired DSI quadrant path and is now enabled in firmware and the app. Hardware confirmation remains for the user because this task did not touch boards.

6. Calibration remains a separate hardware task.

   Only `co5300` has field-evidenced signs (X=+1, Y=-1). `jd9853`, `st7789-130`, and `st7789-154` retain identity assumptions until six-position calibration. The classifier's hysteresis and dwell make a bad sign wrong-but-stable, not oscillatory.
