# Click Instrumentation — Implementation Flow Guide

## Quick Overview

Flow: **UIWindow.sendEvent** → **UIWindowSwizzler** → **ClickEventBuffer** (rage detection) → **ClickEventEmitter** → **OTel Log Record**

---

## 1. Entry Point: UIWindowSwizzler (Tap Interception)

**File:** `Sources/Instrumentation/UIKitTap/UIWindowSwizzler.swift`

### Function: `swizzle()` - Initialization
Replaces UIWindow's sendEvent method to intercept all touch events. Creates and wires buffer + emitter components.

```swift
static func swizzle(logger: OpenTelemetryApi.Logger, captureContext: Bool, rageConfig: RageConfig) {
    swizzleLock.lock()
    defer { swizzleLock.unlock() }
    guard !swizzled else { return }
    
    Self.logger = logger
    Self.captureContext = captureContext
    Self.rageConfig = rageConfig
    
    // Create pipeline components
    emitter = ClickEventEmitter(logger: logger)
    buffer = ClickEventBuffer(
        rageConfig: rageConfig,
        onRage: { emitter?.emitRageClick($0) },           // Rage callback
        onEmit: { [weak emitter] click in                 // Individual emit callback
            if click.hasTarget {
                emitter?.emitGoodClick(click)
            } else {
                emitter?.emitDeadClick(click)
            }
        }
    )
    
    swizzleSendEvent()
    registerForAppLifecycle()
    swizzled = true
}
```

### Function: `sendEvent` block - Touch Interception
Called by UIKit for every touch event. Detects taps, hit-tests target, builds metadata, feeds to buffer. Always calls original sendEvent to preserve normal UI behavior.

**Data flowing in:** UIEvent with touches  
**Data flowing out:** PendingClick → buffer.record()

```swift
let block: @convention(block) (UIWindow, UIEvent) -> Void = { window, event in
    guard event.type == .touches, let touches = event.allTouches else {
        // Non-touch event, call original
        if let imp = originalIMP {
            let fn = unsafeBitCast(imp, to: (@convention(c) (UIWindow, Selector, UIEvent) -> Void).self)
            fn(window, #selector(UIWindow.sendEvent(_:)), event)
        }
        return
    }

    // Track touch start for scroll detection
    for touch in touches where touch.phase == .began {
        touchStartLocations[ObjectIdentifier(touch)] = touch.location(in: window)
    }
    
    // Clean up cancelled touches
    for touch in touches where touch.phase == .cancelled {
        touchStartLocations.removeValue(forKey: ObjectIdentifier(touch))
    }

    // Extract click data only on touch end
    let clickTarget: (view: UIView?, location: CGPoint)? = {
        guard let touch = touches.first(where: { $0.phase == .ended }) else { return nil }
        let endLocation = touch.location(in: window)
        let key = ObjectIdentifier(touch)
        defer { touchStartLocations.removeValue(forKey: key) }

        // Scroll detection: if moved > 10pt, treat as scroll
        if let startLocation = touchStartLocations[key] {
            let dx = endLocation.x - startLocation.x
            let dy = endLocation.y - startLocation.y
            let distSq = dx * dx + dy * dy
            guard distSq <= tapSlopDistance * tapSlopDistance else {
                return nil  // Scroll, not tap
            }
        }

        // Hit test to find target (or nil for dead click)
        let hitView = window.hitTest(endLocation, with: nil)
        let target = findClickTarget(in: window, at: endLocation)
        let hitName = hitView.map { String(describing: type(of: $0)) } ?? "nil"
        let targetName = target.map { String(describing: type(of: $0)) } ?? "nil"
        let dead = (target == nil)
        PulseLogger.log("[TAP_TARGET] point=(\(Int(endLocation.x)),\(Int(endLocation.y))) | hit=\(hitName) | target=\(targetName) | dead=\(dead)")
        return (target, endLocation)
    }()

    // Dispatch original event (must happen before emission)
    if let imp = originalIMP {
        let fn = unsafeBitCast(imp, to: (@convention(c) (UIWindow, Selector, UIEvent) -> Void).self)
        fn(window, #selector(UIWindow.sendEvent(_:)), event)
    }

    // Emit after dispatch (so UI state reflects tap)
    if let (target, location) = clickTarget {
        emitClickEvent(target: target, at: location, in: window)
    }
}
```

### Function: `emitClickEvent()` - Metadata Builder
Extracts widget name, ID, and label from target view. Creates PendingClick object with all tap metadata. Delegates to buffer for rage detection.

**Data flowing in:** UIView (target), CGPoint (location), UIWindow  
**Data flowing out:** PendingClick → buffer.record()

```swift
private static func emitClickEvent(target: UIView?, at point: CGPoint, in window: UIWindow) {
    let widgetName = target.map { String(describing: type(of: $0)) } ?? ""
    let widgetId = target?.accessibilityIdentifier ?? ""
    
    let label: String? = captureContext && target != nil ? extractLabel(from: target!) : nil
    let context = label.flatMap(PulseAttributes.AppClickContext.buildContext)
    
    // Create pending click with all metadata
    let pending = PendingClick(
        x: Float(point.x),
        y: Float(point.y),
        timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
        tapEpochMs: Int64(Date().timeIntervalSince1970 * 1000),
        hasTarget: target != nil,
        widgetName: widgetName.isEmpty ? nil : widgetName,
        widgetId: widgetId.isEmpty ? nil : widgetId,
        clickContext: context,
        viewportWidthPt: Int(window.bounds.width),
        viewportHeightPt: Int(window.bounds.height)
    )
    
    // Feed to buffer for rage detection
    buffer?.record(pending)
}
```

### Function: `registerForAppLifecycle()` - Flush Trigger
Subscribes to UIApplication.willResignActiveNotification. On app pause, calls buffer.flush() to emit pending clicks.

**Data flowing in:** Notification (willResignActiveNotification)  
**Data flowing out:** Queued OTel log records (via buffer.flush())

```swift
private static func registerForAppLifecycle() {
    NotificationCenter.default.addObserver(
        forName: UIApplication.willResignActiveNotification,
        object: nil,
        queue: .main
    ) { _ in
        buffer?.flush()  // Emit pending clicks on pause
    }
}
```

---

## 2. Data Models: What Flows Through

**File:** `Sources/Instrumentation/UIKitTap/ClickModels.swift`

```swift
internal struct PendingClick {
    let x: Float                          // Raw tap X
    let y: Float                          // Raw tap Y
    let timestampMs: Int64                // Monotonic timestamp
    let tapEpochMs: Int64                 // Wall-clock ms for OTel
    let hasTarget: Bool                   // true=good, false=dead
    let widgetName: String?               // Class name (UIButton, etc.)
    let widgetId: String?                 // accessibilityIdentifier
    let clickContext: String?             // "label=..." or nil
    let viewportWidthPt: Int              // Screen width in points
    let viewportHeightPt: Int             // Screen height in points
}

internal struct RageEvent {
    var count: Int                        // Total taps in cluster
    let hasTarget: Bool                   // true=good, false=dead
    let x: Float                          // Rage cluster X
    let y: Float                          // Rage cluster Y
    let tapEpochMs: Int64                 // First tap epoch
    let widgetName: String?
    let widgetId: String?
    let clickContext: String?
    let viewportWidthPt: Int
    let viewportHeightPt: Int
}
```

---

## 3. Rage Detection: ClickEventBuffer

**File:** `Sources/Instrumentation/UIKitTap/ClickEventBuffer.swift`

### Core Algorithm

```swift
internal class ClickEventBuffer {
    private let rageConfig: RageConfig              // Config: timeWindowMs, rageThreshold, radiusPt
    private let onRage: (RageEvent) -> Void        // Callback: emitRageClick
    private let onEmit: (PendingClick) -> Void     // Callback: emitGoodClick or emitDeadClick
    
    private var buffer: [PendingClick] = []        // Pending clicks in current window
    private var isRageActive = false               // Flag: are we in rage mode?
    private var lastRageTimeMs: Int64 = 0          // Last tap timestamp during rage
    private var pendingRage: RageEvent?            // Accumulated rage event (to be emitted)
    private var emitTimer: DispatchSourceTimer?    // Timeout timer for rage
    
    private let radiusPxSquared: Float             // Pre-squared radius for distance check
    
    init(rageConfig: RageConfig, onRage: @escaping (RageEvent) -> Void, onEmit: @escaping (PendingClick) -> Void, ...) {
        self.rageConfig = rageConfig
        self.onRage = onRage
        self.onEmit = onEmit
        self.radiusPxSquared = rageConfig.radiusPt * rageConfig.radiusPt
    }
    
    /// Main entry: called from swizzler on every tap.
    /// Decides: emit individually, buffer, or trigger rage mode.
    func record(_ click: PendingClick) {
        dispatchPrecondition(condition: .onQueue(.main))  // Assert main thread
        
    /// Check if already in rage mode. If yes, extend window or emit completed rage.
    /// If no, call processNormal() to check if this tap triggers rage.
    ///
    /// Data flow: PendingClick → [isRageActive check] → processNormal() or rage extension
        if isRageActive {
            if click.timestampMs - lastRageTimeMs <= Int64(rageConfig.timeWindowMs) {
                // Within window: extend suppression
                lastRageTimeMs = click.timestampMs
                if var rage = pendingRage {
                    rage.count += 1
                    pendingRage = rage
                }
                cancelDelayedEmit()
                scheduleDelayedEmit()  // Reschedule timer
            } else {
                // Outside window: rage ended, emit and process normally
                cancelDelayedEmit()
                isRageActive = false
                if let completed = pendingRage {
                    onRage(completed)  // Emit rage
                }
                pendingRage = nil
                processNormal(click)
            }
            return
        }
        
        // Normal mode: check if this tap triggers rage
        processNormal(click)
    }
    
    /// Check if rage threshold is reached. If yes, suppress buffer + start rage mode.
    /// If no, store click in buffer for later emission or on flush.
    ///
    /// Data flow: PendingClick → evict old → count nearby → [threshold check]
    ///           ├─ Threshold reached: RageEvent → onRage callback
    ///           └─ Below threshold: buffer → onEmit on flush or timeout
    private func processNormal(_ click: PendingClick) {
        dispatchPrecondition(condition: .onQueue(.main))
        
        // Remove taps older than timeWindowMs
        evictStale(click.timestampMs)
        buffer.append(click)
        
        // Count taps within radius
        let nearbyCount = buffer.filter { withinRadius($0.x, $0.y, click.x, click.y) }.count
        
        // Rage threshold reached?
        if nearbyCount >= rageConfig.rageThreshold {
            // Suppress all buffered taps + start rage suppression
            pendingRage = RageEvent(
                count: buffer.count,
                hasTarget: click.hasTarget,
                x: click.x,
                y: click.y,
                tapEpochMs: click.tapEpochMs,
                widgetName: click.widgetName,
                widgetId: click.widgetId,
                clickContext: click.clickContext,
                viewportWidthPt: click.viewportWidthPt,
                viewportHeightPt: click.viewportHeightPt
            )
            buffer.removeAll()
            isRageActive = true
            lastRageTimeMs = click.timestampMs
            scheduleDelayedEmit()  // Schedule timeout
        }
    }
    
    /// Remove clicks older than timeWindowMs from buffer.
    /// Each evicted click is emitted individually via onEmit callback.
    ///
    /// Data flow: buffer[stale entries] → onEmit(PendingClick) → ClickEventEmitter
    private func evictStale(_ nowMs: Int64) {
        dispatchPrecondition(condition: .onQueue(.main))
        
        let cutoff = nowMs - Int64(rageConfig.timeWindowMs)
        while !buffer.isEmpty && buffer.first!.timestampMs < cutoff {
            onEmit(buffer.removeFirst())  // Emit individual click
        }
    }
    
    /// Distance check: squared distance from (x1,y1) to (x2,y2) against radiusPxSquared.
    /// True if taps are within rage radius.
    private func withinRadius(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) -> Bool {
        let dx = x1 - x2
        let dy = y1 - y2
        return dx * dx + dy * dy <= radiusPxSquared
    }
    
    /// Schedule delayed emission: after timeWindowMs of inactivity, emit rage.
    /// Uses DispatchSourceTimer on main queue.
    private func scheduleDelayedEmit() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        emitTimer = DispatchSource.makeTimerSource(queue: .main)
        emitTimer?.schedule(deadline: .now() + .milliseconds(rageConfig.timeWindowMs))
        emitTimer?.setEventHandler { [weak self] in
            self?.emitPending()
        }
        emitTimer?.resume()
    }
    
    /// Cancel any pending delayed emit timer.
    private func cancelDelayedEmit() {
        emitTimer?.cancel()
        emitTimer = nil
    }
    
    /// Timer callback: emit pending rage after timeWindowMs timeout.
    /// Resets rage mode state.
    private func emitPending() {
        if let rage = pendingRage {
            onRage(rage)  // Emit rage after timeout
            pendingRage = nil
        }
        isRageActive = false
        emitTimer = nil
    }
    
    /// On app pause: emit any pending rage, drain buffer of individual clicks.
    /// Ensures no clicks are lost when app goes to background.
    ///
    /// Data flow: [app pause] → flush() → emit pending rage, then emit all buffered clicks
    func flush() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        cancelDelayedEmit()
        if let rage = pendingRage {
            onRage(rage)  // Emit any pending rage
        }
        pendingRage = nil
        isRageActive = false
        
        // Drain buffer: emit remaining individual clicks
        while !buffer.isEmpty {
            onEmit(buffer.removeFirst())
        }
    }
}
```

### Rage Config

```swift
public struct RageConfig {
    public var timeWindowMs: Int = 2000      // 2 second window
    public var rageThreshold: Int = 3        // Threshold: 3+ taps
    public var radiusPt: Float = 50.0        // Radius: 50 points
}
```

---

## 4. Emission: ClickEventEmitter

**File:** `Sources/Instrumentation/UIKitTap/ClickEventEmitter.swift`

### Function: `emitGoodClick()`
Builds OTel attributes for successful tap on interactive element. Includes widget metadata and label context. Emits log record with wall-clock timestamp.

**Data flowing in:** PendingClick (hasTarget=true)  
**Data flowing out:** OTel log record: app.widget.click event with good attributes

### Good Click (Target Found)

```swift
func emitGoodClick(_ click: PendingClick) {
    var attrs: [String: AttributeValue] = [
        PulseAttributes.clickType: .string(PulseAttributes.ClickTypeValues.good),
        "app.widget.name": .string(click.widgetName ?? ""),
        "app.widget.id": .string(click.widgetId ?? ""),
        "app.screen.coordinate.x": .int(Int(click.x)),
        "app.screen.coordinate.y": .int(Int(click.y)),
    ]
    
    if let context = click.clickContext {
        attrs["app.click.context"] = .string(context)
    }
    
    applyViewportAttrs(&attrs, click.viewportWidthPt, click.viewportHeightPt, click.x, click.y)
    
    let timestamp = Date(timeIntervalSince1970: TimeInterval(click.tapEpochMs) / 1000.0)
    let record = logger.logRecordBuilder()
        .setEventName("app.widget.click")
        .setTimestamp(timestamp)
        .setAttributes(attrs)
    record.emit()
}
```

**Output:**
```
Event: app.widget.click
Attributes:
  click.type = "good"
  app.widget.name = "UIButton"
  app.widget.id = "checkout_btn"
  app.click.context = "label=Add to Cart"
  app.screen.coordinate.x = 142
  app.screen.coordinate.y = 380
  device.screen.width = 375
  device.screen.height = 812
  app.screen.coordinate.nx = 0.378  (142/375)
  app.screen.coordinate.ny = 0.468  (380/812)
```

### Function: `emitDeadClick()`
Builds OTel attributes for tap on non-interactive area. Omits widget fields (no target). Includes tap coordinates only.

**Data flowing in:** PendingClick (hasTarget=false)  
**Data flowing out:** OTel log record: app.widget.click event with dead attributes

### Dead Click (No Target)

```swift
func emitDeadClick(_ click: PendingClick) {
    var attrs: [String: AttributeValue] = [
        PulseAttributes.clickType: .string(PulseAttributes.ClickTypeValues.dead),
        "app.screen.coordinate.x": .int(Int(click.x)),
        "app.screen.coordinate.y": .int(Int(click.y)),
    ]
    
    applyViewportAttrs(&attrs, click.viewportWidthPt, click.viewportHeightPt, click.x, click.y)
    
    let timestamp = Date(timeIntervalSince1970: TimeInterval(click.tapEpochMs) / 1000.0)
    let record = logger.logRecordBuilder()
        .setEventName("app.widget.click")
        .setTimestamp(timestamp)
        .setAttributes(attrs)
    record.emit()
}
```

**Output:**
```
Event: app.widget.click
Attributes:
  click.type = "dead"
  app.screen.coordinate.x = 50
  app.screen.coordinate.y = 100
  device.screen.width = 375
  device.screen.height = 812
  app.screen.coordinate.nx = 0.133
  app.screen.coordinate.ny = 0.123
```

### Function: `emitRageClick()`
Builds OTel attributes for rage cluster (3+ taps within timeWindowMs + radiusPt).
Sets click.is_rage=true and click.rageCount. Click type determined by hasTarget.

**Data flowing in:** RageEvent (accumulated taps)  
**Data flowing out:** OTel log record: app.widget.click event with rage attributes (count, is_rage flags)

### Rage Click (3+ taps within 2s + 50pt radius)

```swift
func emitRageClick(_ rage: RageEvent) {
    let clickType = rage.hasTarget ? PulseAttributes.ClickTypeValues.good : PulseAttributes.ClickTypeValues.dead
    var attrs: [String: AttributeValue] = [
        PulseAttributes.clickType: .string(clickType),
        PulseAttributes.clickIsRage: .bool(true),
        PulseAttributes.clickRageCount: .int(rage.count),
        "app.screen.coordinate.x": .int(Int(rage.x)),
        "app.screen.coordinate.y": .int(Int(rage.y)),
    ]
    
    if let name = rage.widgetName {
        attrs["app.widget.name"] = .string(name)
    }
    if let id = rage.widgetId {
        attrs["app.widget.id"] = .string(id)
    }
    if let context = rage.clickContext {
        attrs["app.click.context"] = .string(context)
    }
    
    applyViewportAttrs(&attrs, rage.viewportWidthPt, rage.viewportHeightPt, rage.x, rage.y)
    
    let timestamp = Date(timeIntervalSince1970: TimeInterval(rage.tapEpochMs) / 1000.0)
    let record = logger.logRecordBuilder()
        .setEventName("app.widget.click")
        .setTimestamp(timestamp)
        .setAttributes(attrs)
    record.emit()
}
```

**Output:**
```
Event: app.widget.click
Attributes:
  click.type = "good"
  click.is_rage = true
  click.rageCount = 5
  app.widget.name = "UIButton"
  app.widget.id = "submit_btn"
  app.click.context = "label=Submit"
  app.screen.coordinate.x = 145
  app.screen.coordinate.y = 380
  device.screen.width = 375
  device.screen.height = 812
  app.screen.coordinate.nx = 0.387
  app.screen.coordinate.ny = 0.468
```

### Function: `applyViewportAttrs()`
Normalizes tap coordinates against screen dimensions (0.0–1.0). Adds device screen width/height for cross-device analytics.

**Data flowing in:** PendingClick.x/y and viewport dimensions  
**Data flowing out:** Four attributes: deviceScreenWidth, deviceScreenHeight, appScreenCoordinateNx/Ny

### Viewport Normalization

```swift
private func applyViewportAttrs(_ attrs: inout [String: AttributeValue], _ widthPt: Int, _ heightPt: Int, _ x: Float, _ y: Float) {
    if widthPt > 0 && heightPt > 0 {
        attrs[PulseAttributes.deviceScreenWidth] = .int(widthPt)
        attrs[PulseAttributes.deviceScreenHeight] = .int(heightPt)
        // Normalized coordinates: 0.0 to 1.0
        attrs[PulseAttributes.appScreenCoordinateNx] = .double(Double(x) / Double(widthPt))
        attrs[PulseAttributes.appScreenCoordinateNy] = .double(Double(y) / Double(heightPt))
    }
}
```

---

## 5. Configuration: Backend Parsing

**File:** `Sources/PulseKit/Sampling/ClickFeatureRemoteConfig.swift`

### Function: `from()`
Parses backend feature config JSON (via AnyCodable) into typed RageConfig struct. Handles malformed JSON gracefully (silent fallback to defaults).

**Data flowing in:** PulseFeatureConfig with config: [String: AnyCodable]?  
**Data flowing out:** ClickFeatureRemoteConfig? (nil if parse fails)

```swift
internal struct ClickFeatureRemoteConfig: Decodable {
    let rage: RageConfig?
    
    struct RageConfig: Decodable {
        let timeWindowMs: Int?
        let rageThreshold: Int?
        let radius: Float?
    }
    
    // Parse backend config JSON
    static func from(featureConfig: PulseFeatureConfig) -> ClickFeatureRemoteConfig? {
        guard let configDict = featureConfig.config else {
            return nil
        }
        
        // Convert [String: AnyCodable] to [String: Any]
        let anyDict = configDict.mapValues { codable -> Any in
            let value = codable.value
            if value is NSNull {
                return NSNull()
            }
            return value
        }
        
        // Encode to JSON, then decode as typed struct
        guard JSONSerialization.isValidJSONObject(anyDict),
              let jsonData = try? JSONSerialization.data(withJSONObject: anyDict),
              let decoded = try? JSONDecoder().decode(ClickFeatureRemoteConfig.self, from: jsonData) else {
            PulseLogger.log("Failed to parse click feature config from backend; using SDK defaults")
            return nil  // Fallback to defaults
        }
        
        return decoded
    }
}
```

### Backend Config Resolution in PulseKit

**File:** `Sources/PulseKit/PulseKit.swift` (line ~220)

**Function:** Config merge logic  
Fetches click feature from backend, parses remote config, and merges with local defaults (backend overrides, missing fields use SDK defaults).

**Data flowing in:** PulseSdkConfig.features[]  
**Data flowing out:** Merged RageConfig → UIKitTapInstrumentationConfig.rage

```swift
let clickFeature = sdkConfig.features.first { feature in
    feature.featureName == .click &&
    feature.sdks.contains(currentSdkName) &&
    feature.sessionSampleRate > 0
}

if let feature = clickFeature {
    let remoteConfig = ClickFeatureRemoteConfig.from(featureConfig: feature)
    var resolvedRage = config.uiKitTap.rage
    
    // Merge: backend fields override, missing fields use defaults
    if let remote = remoteConfig?.rage {
        resolvedRage.timeWindowMs = remote.timeWindowMs ?? resolvedRage.timeWindowMs
        resolvedRage.rageThreshold = remote.rageThreshold ?? resolvedRage.rageThreshold
        resolvedRage.radiusPt = remote.radius ?? resolvedRage.radiusPt
    }
    config.uiKitTap { $0.rage { r in r = resolvedRage } }
}
```

### Function: Feature flag suppression  
In `applyDisabledFeatures()`: if backend omits click feature or sets sessionSampleRate=0, disables UIKit tap instrumentation.

**Data flowing in:** Backend enabledFeatures list  
**Data flowing out:** config.uiKitTap.enabled = false

### Feature Flag Suppression

**File:** `Sources/PulseKit/PulseKit.swift` (applyDisabledFeatures)

```swift
case .click:
    config.uiKitTap { $0.enabled(false) }
```

---

## 6. Initialization Flow

**File:** `Sources/PulseKit/Instrumentation/UIKitTapInstrumentationConfig.swift`

### Function: `initialize()`
Wires up the swizzler with resolved rage config (merged from backend + local defaults).

**Data flowing in:** InstallationContext (provides logger)  
**Data flowing out:** UIWindowSwizzler.swizzle() called with resolved RageConfig

```swift
extension UIKitTapInstrumentationConfig: InstrumentationLifecycle {
    internal func initialize(ctx: InstallationContext) {
        guard self.enabled else { return }
        #if os(iOS) || os(tvOS)
        let logger = ctx.loggerProvider.get(
            instrumentationScopeName: PulseKitConstants.instrumentationScopeName
        )
        // Pass resolved rage config to swizzler
        UIWindowSwizzler.swizzle(logger: logger, captureContext: captureContext, rageConfig: rage)
        #endif
    }

    internal func uninstall() {}
}
```

---

## 7. Complete Flow Diagram

```
USER TAP
   ↓
UIWindow.sendEvent(_:)  [UIKit calls on main thread]
   ↓
UIWindowSwizzler.swizzle block
   ├─ Track touch.phase == .began (record start position)
   ├─ On touch.phase == .ended:
   │  ├─ Check scroll (distance from start > 10pt?)
   │  ├─ Hit test to find target view
   │  └─ Build PendingClick(hasTarget: target != nil, ...)
   │
   ├─ Call original UIWindow.sendEvent (preserve normal behavior)
   │
   └─ Call buffer.record(pending)
        ↓
   ClickEventBuffer
   ├─ evictStale()  [remove clicks > timeWindowMs old]
   ├─ Count nearby taps within radiusPt
   │
   ├─ If count < rageThreshold:
   │  └─ Store click in buffer (call onEmit callback later or on flush)
   │
   └─ If count >= rageThreshold:
      ├─ Create RageEvent(count: all_buffered)
      ├─ Clear buffer
      ├─ Set isRageActive = true
      ├─ Schedule delayed emit after timeWindowMs
      └─ Call onRage(rageEvent) [triggers emitRageClick]
           ↓
        ClickEventEmitter
        ├─ Build attributes dict
        ├─ Apply viewport normalization
        └─ logger.logRecordBuilder().setEventName("app.widget.click").setAttributes(attrs).emit()
            ↓
        OTel Log Record
        └─ Sent to backend


TIMEOUT or NEW TAP OUTSIDE WINDOW:
   └─ Rage emission fires, isRageActive = false


APP PAUSE (willResignActiveNotification):
   ↓
   buffer.flush()
   ├─ Cancel delayed emit
   ├─ Emit pending rage (if any)
   └─ Drain buffer: emit all remaining clicks
        ↓
     ClickEventEmitter (emitGoodClick or emitDeadClick per click)
```

---

## 8. Attributes Reference

### PendingClick → Emitted Attributes

| Attribute | Source | Type | Example | Emitted On |
|-----------|--------|------|---------|-----------|
| `click.type` | PulseAttributes | String | `"good"` / `"dead"` | Always |
| `click.is_rage` | PulseAttributes | Bool | `true` | Rage only |
| `click.rageCount` | PulseAttributes | Int | `5` | Rage only |
| `app.widget.name` | PendingClick.widgetName | String | `"UIButton"` | Good & Rage only |
| `app.widget.id` | PendingClick.widgetId | String | `"checkout_btn"` | Good & Rage only |
| `app.click.context` | PendingClick.clickContext | String | `"label=Add to Cart"` | Good & Rage only (if present) |
| `app.screen.coordinate.x` | PendingClick.x | Int | `142` | Always |
| `app.screen.coordinate.y` | PendingClick.y | Int | `380` | Always |
| `device.screen.width` | PendingClick.viewportWidthPt | Int | `375` | Always |
| `device.screen.height` | PendingClick.viewportHeightPt | Int | `812` | Always |
| `app.screen.coordinate.nx` | x / viewportWidthPt | Double | `0.378` | Always |
| `app.screen.coordinate.ny` | y / viewportHeightPt | Double | `0.468` | Always |

---

## 9. Key Thread Safety

```swift
// All buffer methods assert main thread
dispatchPrecondition(condition: .onQueue(.main))

// Entry points guaranteed on main:
//   - UIWindow.sendEvent(_:) → always main (UIKit guarantee)
//   - UIApplication.willResignActiveNotification → always main (NotificationCenter default)

// Timer callbacks (DispatchSourceTimer) → .main queue explicitly
emitTimer = DispatchSource.makeTimerSource(queue: .main)
```

---

## 10. Test Scenarios

**File:** `Tests/InstrumentationTests/UIKitTapTests/UIKitTapInstrumentationTests.swift`

```swift
// Scenario 1: Good click
testClickEventIncludesGoodClickType()

// Scenario 2: Dead click
testClickEventIncludesDeadClickType()

// Scenario 3: Viewport attributes
testClickEventIncludesViewportDimensions()
testClickEventIncludesNormalizedCoordinates()

// Scenario 4: Rage detection
testClickEventBufferDetectsRageAtThreshold()
testClickEventBufferEmitsIndividualClickBelowThreshold()
testClickEventBufferIgnoresClicksOutsideRadius()

// Scenario 5: Flush behavior
testClickEventBufferFlushEmitsPendingRage()
```

---

---

## Data Flow Summary

### 1. **Tap Capture Phase**
```
UIKit Touch Event (UIWindow.sendEvent)
    ↓
UIWindowSwizzler.sendEvent block
    ├─ Track touch.phase == .began
    ├─ On touch.phase == .ended:
    │  ├─ Check scroll (distance > 10pt?)
    │  ├─ Hit test (raw hitView + resolved findClickTarget)
    │  ├─ Target-resolve log: [TAP_TARGET] hit=<type> target=<type|nil> dead=<bool>
    │  ├─ Extract metadata (widgetName, id, label)
    │  └─ Build PendingClick
    │
    └─ emitClickEvent() → buffer.record(PendingClick)
```

### 2. **Rage Detection Phase**
```
PendingClick in buffer.record()
    ├─ Check isRageActive flag
    │
    ├─ If NOT active:
    │  ├─ evictStale() [remove clicks > timeWindowMs old]
    │  ├─ Count nearby taps within radiusPt
    │  │
    │  ├─ If count >= rageThreshold:
    │  │  ├─ Create RageEvent(count: all_buffered)
    │  │  ├─ Clear buffer
    │  │  ├─ Set isRageActive = true
    │  │  ├─ scheduleDelayedEmit() [after timeWindowMs]
    │  │  └─ onRage(RageEvent) callback triggered
    │  │
    │  └─ Else:
    │     └─ Store click in buffer (await flush or eviction)
    │
    └─ If active:
       ├─ Check if within timeWindowMs of lastRageTimeMs
       │
       ├─ If within window:
       │  ├─ Increment pendingRage.count++
       │  ├─ rescheduleDelayedEmit()
       │  └─ Continue suppressing individual clicks
       │
       └─ Else (outside window):
          ├─ Emit completed rage: onRage(pendingRage)
          ├─ Reset isRageActive = false
          └─ Process this click as normal
```

### 3. **Emission Phase**
```
onRage(RageEvent) or onEmit(PendingClick) callbacks
    ↓
ClickEventEmitter
    ├─ emitRageClick(rage)
    │  ├─ clickType = rage.hasTarget ? "good" : "dead"
    │  ├─ Set click.is_rage = true, click.rageCount
    │  ├─ Build attributes dict
    │  ├─ applyViewportAttrs() [normalize coords]
    │  └─ logger.logRecordBuilder() → OTel log record
    │
    ├─ emitGoodClick(click)
    │  ├─ Set click.type = "good"
    │  ├─ Include widget.name, widget.id, click.context
    │  ├─ applyViewportAttrs()
    │  └─ logger.logRecordBuilder() → OTel log record
    │
    └─ emitDeadClick(click)
       ├─ Set click.type = "dead"
       ├─ Omit widget fields (no target)
       ├─ applyViewportAttrs()
       └─ logger.logRecordBuilder() → OTel log record
```

### 4. **App Lifecycle Phase**
```
UIApplication.willResignActiveNotification (app pause)
    ↓
registerForAppLifecycle() notification handler
    ↓
buffer.flush()
    ├─ Cancel delayedEmit timer
    ├─ Emit any pending rage: onRage(pendingRage)
    └─ Drain buffer: emit all remaining clicks via onEmit()
        ↓
    ClickEventEmitter (emitGoodClick or emitDeadClick per click)
        ↓
    OTel log records queued for transmission
```

### 5. **Configuration Phase (at SDK init)**
```
Backend SDK config fetch
    ↓
Find click feature in features[] (if present + sessionSampleRate > 0)
    ↓
Parse config.rage JSON via ClickFeatureRemoteConfig.from()
    ├─ Convert [String: AnyCodable] → JSON → typed struct
    └─ On parse fail: log warning, return nil (use defaults)
    ↓
Merge: resolved_rage = {
    timeWindowMs:  backend.timeWindowMs ?? local.timeWindowMs,
    rageThreshold: backend.rageThreshold ?? local.rageThreshold,
    radiusPt:      backend.radius ?? local.radiusPt,
}
    ↓
Apply feature flag suppression (if click absent/disabled in backend)
    ├─ config.uiKitTap.enabled(false)
    └─ OR pass resolved_rage to swizzler init
    ↓
UIWindowSwizzler.swizzle(rageConfig: resolved_rage)
    └─ Instrumentation active with backend-tuned rage config
```

---

## Summary: Key Data Transformations

1. **Tap happens** → UIWindow.sendEvent captured by swizzler
2. **Scroll check** → if < 10pt movement, continue; else skip
3. **Hit test** → find target or nil (dead)
4. **PendingClick** → create metadata object, feed to buffer
5. **Buffer logic** → 
   - Evict stale (> 2s old)
   - Count nearby within 50pt radius
   - If count ≥ 3 → rage mode (suppress individual, emit rage event)
   - Else → store, emit later or on flush
6. **Emit** → ClickEventEmitter creates OTel log record with normalized attributes
7. **Flush** → on app pause, drain all pending clicks

**Config:** Backend can override `timeWindowMs`, `rageThreshold`, `radiusPt` via feature config. Falls back to defaults if backend doesn't send or on parse failure.

### Target Resolution Rules (Current)

- `findClickTarget()` walks hitView → superview chain until a clickable ancestor is found.
- `isClickTarget(_:)` explicitly rejects:
  - `UIWindow`
  - `UIScrollView` (includes table/collection view containers)
- If no valid target is found, tap is treated as dead click (`hasTarget = false`, `click.type = "dead"`).

