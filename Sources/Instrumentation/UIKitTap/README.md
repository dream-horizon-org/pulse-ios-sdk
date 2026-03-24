# UIKit Tap Auto-Instrumentation

Automatically intercepts every user tap across the entire UIKit view hierarchy and emits an `app.widget.click` log event with rich context — no per-view instrumentation required.

## How it works

`UIWindowSwizzler` swizzles `UIWindow.sendEvent(_:)` at the class level on first SDK initialization. Every touch event passes through this single interception point:

1. **Touch start (`.began`)** — records the start position.
2. **Touch end (`.ended`)** — checks the slop distance. If the finger moved more than 10 pt from the start it is treated as a scroll and no event is emitted (mirrors Android's `touchSlop` mechanism).
3. **Hit test** — calls `UIWindow.hitTest(_:with:)` to find the deepest view under the finger, then walks up the hierarchy to find the nearest meaningful tap target.
4. **Original dispatch** — the original `sendEvent` is called so touch handling is unaffected.
5. **Event emission** — `app.widget.click` is emitted after dispatch, so `UISegmentedControl.selectedSegmentIndex` and similar state already reflect the tap.

## Tap target detection

A view is considered a tap target if it is:

| Condition | Examples |
|---|---|
| `UIControl` subclass | `UIButton`, `UISwitch`, `UISegmentedControl`, `UIStepper`, `UISlider` |
| `UITableViewCell` or `UICollectionViewCell` | Any cell — tap gesture lives on the parent scroll view, not the cell |
| Has a `UITapGestureRecognizer` | Custom tappable cards, image views, container views |

SwiftUI hosting views (`_UIHostingView`) are excluded — SwiftUI instrumentation is handled separately.

## Label extraction

When `captureContext` is enabled (default), the SDK extracts a human-readable label from the tapped view using the following priority:

```
UISegmentedControl.titleForSegment(at: selectedSegmentIndex)   ← selected segment only
  ↓ (not a segmented control)
UILabel.text (if view is a UILabel)
  ↓
Direct UILabel subview .text  (e.g. UIButton.titleLabel)
  ↓
.accessibilityLabel
  ↓
Recursive UILabel scan: max depth 4, max 5 segments, " | " joined, ≤ 200 chars
```

### PII safety

Text input controls (`UITextField`, `UITextView`, `UISearchBar`) never have their typed text captured.

## Emitted event

### Event name: `app.widget.click`

| Attribute | Type | Example | Notes |
|---|---|---|---|
| `app.widget.name` | String | `"UIButton"` | Runtime class name — consistent type identifier |
| `app.click.context` | String | `"label=Add to Cart"` | Present only when a label is found and `captureContext` is true |
| `app.screen.coordinate.x` | Int | `142` | Touch X in window coordinates |
| `app.screen.coordinate.y` | Int | `380` | Touch Y in window coordinates |
| `pulse.type` | String | `"app.click"` | Set automatically by the log processor chain |

Additional attributes are automatically enriched by the processor chain: `screen.name`, `session.id`, network status, etc.

> **No `app.widget.id`:** Android emits a numeric resource ID here. iOS has no equivalent auto-generated identifier.

## Coverage

| Scenario | Captured | Label source |
|---|---|---|
| `UIButton` with title | ✅ | `titleLabel.text` |
| `UIButton` icon-only | ✅ | `accessibilityLabel` if set, else class name |
| `UISegmentedControl` | ✅ | Selected segment title only |
| `UISwitch`, `UIStepper`, `UISlider` | ✅ | `accessibilityLabel` if set |
| `UIView` + `UITapGestureRecognizer` | ✅ | Recursive label scan |
| `UITableViewCell` | ✅ | Recursive label scan of cell subviews |
| `UICollectionViewCell` | ✅ | Recursive label scan of cell subviews |
| `UITextField` tap | ✅ | `accessibilityLabel` only — typed text never captured |

## Configuration

```swift
Pulse.shared.initialize(
    endpointBaseUrl: "...",
    projectId: "...",
    instrumentations: { config in
        config.uiKitTap { tap in
            tap.enabled(true)          // default: true
            tap.captureContext(true)   // default: true — set false to skip label extraction
        }
    }
)
```

### `captureContext: false`

Skips all view traversal (no recursive label scan, no `UILabel` inspection). Only `app.widget.name` (class name) and coordinates are emitted. Useful for apps with very large or deeply nested view hierarchies where the label scan has measurable overhead.
