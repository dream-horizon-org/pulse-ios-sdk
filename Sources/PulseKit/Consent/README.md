# Data Collection Consent

Control when telemetry is exported by setting consent state. Pipeline order: **Batch → Consent → Persistence → …** so in `pending` only the consent buffer is used (in memory); nothing hits disk until `.allowed` or flush.

## States

| State     | Behavior |
|----------|----------|
| `pending` | Buffer in memory (max 5000 per signal, drop newest). No export, no disk. |
| `allowed` | Flush buffer then export normally. |
| `denied`  | Clear buffer, shut down SDK (terminal in this process). |

## API

- **`initialize(..., dataCollectionState: .pending)`** — Start with buffering; no export until you call `setDataCollectionState(.allowed)`.
- **`setDataCollectionState(.allowed)`** — Flush buffered spans/logs, then export new ones.
- **`setDataCollectionState(.denied)`** — Clear buffer and shut down.
- Default is `.allowed`. `.denied` at init shuts down after setup. Calling `setDataCollectionState` before `initialize` has no lasting effect (state comes from `initialize`’s argument).

## Buffered data and beforeSend

When moving to `.allowed`, buffered data is flushed through the same chain (persistence, filtering, **beforeSend**). Buffered signals are not exempt from beforeSend.
