# iOS Click Instrumentation — Android Parity (Living Doc)

**Original spec:** `click_new.md` (Android PR `feat/click-types`, repo `dream-horizon-org/pulse-ios-sdk`).

This document replaces the baseline checklist with **current implementation status** as of the `feat/ios-click` work. File pointers refer to this repo.

---

## Executive summary

| Area | Status |
|------|--------|
| Good taps → `app.widget.click` with `click.type=good` | Done |
| Dead taps → `click.type=dead` | Done |
| Rage detection (`click.is_rage`, `click.rageCount`) | **Partial** — implemented with a **simpler** algorithm than Android §2.3 |
| Viewport + normalized coords (`device.screen.width/height`, `nx`/`ny`) | Done |
| Global `device.screen.aspect_ratio` | Done (per log emit, key window) |
| `PulseFeatureName.click` + remote rage DTO + merge | Done |
| `UIKitTapInstrumentationConfig.rage` | Done |

**Conclusion:** Dead-click capture is now implemented. Remaining parity work is primarily **rage algorithm parity** with Android’s full multi-cluster model (active clusters, cap 5, selective buffer eviction, nearest-wins, monotonic timing).

---

## 1. Click type (`good` / `dead`)

### Implemented

- `ClickEventEmitter` emits `click.type` and the attribute sets described in the spec for good vs dead paths (`ClickEventEmitter.swift`).
- `findClickTarget` / `isClickTarget` implement interactive-target detection (`UIWindowSwizzler.swift`).
- `UIWindowSwizzler` now always builds a click candidate for slop-valid `.ended` touches; if `findClickTarget` returns `nil`, the event still flows as `PendingClick(hasTarget: false, ...)` and is emitted as dead click.
- `isClickTarget` explicitly rejects `UIWindow` to avoid false-good clicks when hit-testing falls back to the window itself.

### Remaining gap

1. **Good-click attributes:** `emitGoodClick` always sets `app.widget.name` and `app.widget.id` to strings (including `""` when nil). The spec prefers omitting keys when empty.

---

## 2. Rage click detection

### Implemented

- `ClickEventBuffer` + `ClickEventEmitter.emitRageClick` (`ClickEventBuffer.swift`, `ClickEventEmitter.swift`).
- Circular radius, threshold, time window, suppression extension while taps continue, delayed emit after window, `flush()` on `UIApplication.willResignActiveNotification`.
- `RageEvent.count` increments while rage is active.

### Android §2.3 parity status

The iOS buffer now implements the previously missing cluster behaviors:

| Rule (spec) | Current iOS |
|-------------|-------------|
| **Multiple active clusters** with **max 5** | Implemented (`ClickEventBuffer.maxActiveClusters = 5`) |
| **Nearest-wins** when tap is within radius of 2+ clusters | Implemented (nearest cluster by distance squared) |
| **Selective buffer eviction** — on cluster formation remove **only** taps within radius; keep taps elsewhere | Implemented (nearby buffered taps removed, non-nearby retained) |
| **Initial `rage.count`** = number of taps in cluster (nearby count) | Implemented (`nearbyCount = nearbyBuffered + currentTap`) |
| **`emitExpiredClusters` on each `record`** — expire stale clusters before matching | Implemented |
| **Monotonic `timestampMs`** (`CACurrentMediaTime * 1000`) for buffer timing | Implemented in `UIWindowSwizzler.emitClickEvent` |

**Files:** `ClickEventBuffer.swift`, `UIWindowSwizzler.swift`, `ClickModels.swift`.

---

## 3. Click attributes (viewport, normalized, aspect ratio)

### Implemented

- Per-event: `device.screen.width`, `device.screen.height`, `app.screen.coordinate.x/y`, `app.screen.coordinate.nx/ny` via `applyViewportAttrs` in `ClickEventEmitter.swift`.
- Viewport at tap time: `window.bounds` width/height in points (`UIWindowSwizzler.emitClickEvent`).
- `device.screen.aspect_ratio`: `GlobalAttributesLogRecordProcessor` adds `pulse.currentViewportAspectRatio()` on every log (`GlobalAttributesLogRecordProcessor.swift`, `PulseKit.swift` — GCD-reduced ratio from key window).

### Notes

- Spec mentioned `UIScreen.main.bounds`; implementation uses **key window** bounds for aspect ratio and tap viewport — aligned with multi-window iOS and closer to Android `decorView` semantics.

---

## 4. Backend config

### Implemented

- `PulseFeatureName.click` in `PulseSdkConfigModels.swift`.
- `ClickFeatureRemoteConfig` decodes `rage.timeWindowMs`, `rageThreshold`, `radius` (`ClickFeatureRemoteConfig.swift`).
- Field-level merge into local `RageConfig` when initializing with a persisted SDK config (`PulseKit.swift` — click feature branch).
- `applyDisabledFeatures` disables `uiKitTap` when `.click` is not in the enabled feature list (`PulseKit.swift`).

### Nuance vs spec §4.4

- `getEnabledFeatures()` only includes features with **`sessionSampleRate == 1`** (`PulseSamplingSignalProcessors.swift`). So any click feature with `0 < rate < 1` is **not** “enabled” for this list and **UIKit tap instrumentation is turned off** by `applyDisabledFeatures`, while rage merge uses **`sessionSampleRate > 0`**. That is stricter than “suppress only when rate == 0”.

---

## 5. `UIKitTapInstrumentationConfig`

### Implemented

- `enabled`, `captureContext`, `rage: RageConfig` with builder-style `rage { }` (`UIKitTapInstrumentationConfig.swift`).
- `initialize` installs `UIWindowSwizzler` when enabled.

---

## 6. Integration (`UIWindowSwizzler`)

### Implemented

- Swizzle `UIWindow.sendEvent`, tap slop, touch lifecycle maps, `buffer?.record(pending)`, `buffer?.flush()` on resign active.
- Label / `app.click.context` pipeline unchanged; PII rules for text fields preserved.

### Gaps

- No dead-click integration gap remains in swizzler: qualifying taps (ended + slop) now flow to `emitClickEvent` even when `target == nil`.
- Remaining parity concern is rage-cluster model depth (see §2).

---

## 7. Tests

- `Tests/InstrumentationTests/UIKitTapTests/UIKitTapInstrumentationTests.swift` covers emitter attributes and basic buffer/rage behavior.
- After fixing dead-click capture and (if required) full cluster parity, extend tests to match spec §7 (multi-location clusters, cap 5, selective eviction, backend `timeWindowMs`).

---

## 8. File map (actual layout)

| Role | File |
|------|------|
| Swizzle + hit test + pending click construction | `UIWindowSwizzler.swift` |
| Rage buffer | `ClickEventBuffer.swift` |
| OTel log emission | `ClickEventEmitter.swift` |
| `PendingClick` / `RageEvent` | `ClickModels.swift` |
| Local rage defaults + lifecycle | `UIKitTapInstrumentationConfig.swift` |
| Remote parsing | `Sources/PulseKit/Sampling/ClickFeatureRemoteConfig.swift` |
| Merge + feature disable | `Sources/PulseKit/PulseKit.swift` |
| Aspect ratio on logs | `GlobalAttributesLogRecordProcessor.swift` |

*(Original spec named `TapEventBuffer.swift` / `RageConfig.swift` / `ClickFeatureConfig.swift`; this repo uses the names above.)*

---

## 9. Suggested order of work

1. **Rage parity (if product requires Android-identical analytics):** Replace `ClickEventBuffer` with the multi-cluster algorithm from the original §2.3 (including `maxActiveClusters`, selective removal, nearest-wins, monotonic clock).
2. **Optional polish:** Omit empty `app.widget.*` on good clicks; align feature gating with spec if partial sample rates should still record clicks.
