# Session Instrumentation

Automatic session tracking for OpenTelemetry Swift applications. Creates unique session identifiers, tracks session lifecycle events, and automatically adds session context to all telemetry data.

## Features

- **Dual Session System** - Supports both observability sessions (OTEL) and metered sessions with independent configurations
- **Automatic Session Management** - Creates and manages session lifecycles with configurable timeouts
- **Session Events** - Emits OpenTelemetry log records for session start/end events
- **Span Attribution** - Automatically adds session IDs to all spans via span processor
- **Log Attribution** - Automatically adds session IDs to all log records via log processor
- **Configurable Persistence** - Sessions can be in-memory or persisted across app restarts
- **Background Inactivity Timeout** - Sessions can expire when app goes to background
- **Fixed Lifetime Expiration** - Sessions expire after a fixed duration from start time
- **Thread Safety** - All components are thread-safe for concurrent access

## Setup

**Basic Setup via PulseKit**:

```swift
import PulseKit

PulseKit.shared.initialize(
    endpointBaseUrl: "https://your-endpoint.com",
    projectId: "your-project-id",
    instrumentationConfiguration: { config in
        config.sessions { sessionsConfig in
            sessionsConfig.enabled(true)
        }
    }
)
```

**Custom Configuration**:

```swift
import Sessions
import OpenTelemetrySdk

let sessionConfig = SessionConfig(
    backgroundInactivityTimeout: 15 * 60,  // 15 minutes
    maxLifetime: 4 * 60 * 60,               // 4 hours
    shouldPersist: false,                   // In-memory
    startEventName: SessionConstants.sessionStartEvent,
    endEventName: SessionConstants.sessionEndEvent
)
let sessionManager = SessionManager(configuration: sessionConfig)

let sessionSpanProcessor = SessionSpanProcessor(sessionManager: sessionManager)
let sessionLogProcessor = SessionLogRecordProcessor(
    nextProcessor: baseLogProcessor,
    sessionManager: sessionManager
)
```

**Getting Session Information**:

```swift
let session = sessionManager.getSession() 
print("Session ID: \(session.id)")

if let session = sessionManager.peekSession() {
    print("Current session: \(session.id)")
}
```

## Components

### SessionManager

Manages session lifecycle with automatic expiration and renewal.

```swift
let manager = SessionManager(configuration: SessionConfig(
    maxLifetime: 4 * 60 * 60,
    shouldPersist: false
))
let session = manager.getSession() 
let session = manager.peekSession() 
```

### SessionSpanProcessor

Automatically adds session IDs to all spans.

```swift
let processor = SessionSpanProcessor(sessionManager: sessionManager)
// Adds session.id and session.previous_id attributes to spans
```

### SessionLogRecordProcessor

Automatically adds session IDs to all log records.

```swift
let processor = SessionLogRecordProcessor(
    nextProcessor: yourProcessor,
    sessionManager: sessionManager
)
// Adds session.id and session.previous_id attributes to log records
```

### SessionEventInstrumentation

Creates OpenTelemetry log records for session lifecycle events.

```swift
let instrumentation = SessionEventInstrumentation()
// Emits session.start and session.end log records
```

### Session Model

Represents a session with ID, timestamps, and expiration logic.

```swift
let session = Session(
    id: "unique-session-id",
    expireTime: Date(timeIntervalSinceNow: 14400),
    previousId: "previous-session-id",
    startTime: Date(),
    sessionTimeout: 14400
)

print("Expired: \(session.isExpired())")
print("Duration: \(session.duration ?? 0)")
```

## Configuration

### SessionConfig

| Field                        | Type            | Description                                                          | Default              | Required |
| ---------------------------- | --------------- | -------------------------------------------------------------------- | -------------------- | -------- |
| `maxLifetime`                | `TimeInterval?` | Fixed duration in seconds after which session expires from start time | `14400` (4 hours)   | No       |
| `backgroundInactivityTimeout` | `TimeInterval?` | Duration in seconds after which session expires when app is in background | `900` (15 min) | No       |
| `shouldPersist`              | `Bool`          | Whether session should persist across app restarts                    | `false` (in-memory)  | No       |
| `startEventName`             | `String?`       | Event name for session.start events                                  | `"session.start"`    | No       |
| `endEventName`               | `String?`       | Event name for session.end events                                    | `"session.end"`      | No       |

```swift
let config = SessionConfig(
    backgroundInactivityTimeout: 15 * 60,  // 15 minutes
    maxLifetime: 4 * 60 * 60,               // 4 hours
    shouldPersist: false,                   // In-memory
    startEventName: SessionConstants.sessionStartEvent,
    endEventName: SessionConstants.sessionEndEvent
)
```

## Dual Session System

The SDK supports two independent session systems:

### Observability Sessions (OTEL)

- **Purpose**: User session tracking for observability
- **Configuration**: User-configurable via `SessionsInstrumentationConfig`
- **Default Settings**:
  - `maxLifetime`: 4 hours
  - `backgroundInactivityTimeout`: 15 minutes
  - `shouldPersist`: false (in-memory)
  - Emits `session.start` and `session.end` events
- **Attribute Key**: `session.id`
- **Event Names**: `session.start`, `session.end`

### Metered Sessions

- **Purpose**: Session tracking for metering
- **Configuration**: Internal, always active
- **Default Settings**:
  - `maxLifetime`: 30 minutes
  - `backgroundInactivityTimeout`: nil (no background timeout)
  - `shouldPersist`: true (persisted)
  - Does not emit events
- **Attribute Key**: `pulse.metering.session.id`
- **HTTP Header**: `X-Pulse-Metering-Session-ID`

Both session systems operate independently with separate session managers and processors.

## Session Events

Emits OpenTelemetry log records following semantic conventions:

### Session Start

A `session.start` log record is created when a new session begins.

**Example session.start Event**:

```json
{
  "body": "session.start",
  "attributes": {
    "session.id": "550e8400e29b41d4a716446655440000",
    "session.start_time": 1692123456789000000,
    "session.previous_id": "71260acc5286455f99555da8c5109a07"
  }
}
```

**Session Start Attributes**:

| Attribute             | Type   | Description                                   | Example                                  |
| --------------------- | ------ | --------------------------------------------- | ---------------------------------------- |
| `session.id`          | string | Unique identifier for the current session     | `"550e8400e29b41d4a716446655440000"`     |
| `session.start_time`  | double | Session start time in nanoseconds since epoch | `1692123456789000000`                    |
| `session.previous_id` | string | Identifier of the previous session (if any)   | `"71260acc5286455f99555da8c5109a07"`     |

### Session End

A `session.end` log record is created when a session expires.

**Example session.end Event**:

```json
{
  "body": "session.end",
  "attributes": {
    "session.id": "550e8400e29b41d4a716446655440000",
    "session.start_time": 1692123456789000000,
    "session.end_time": 1692125256789000000,
    "session.duration": 1800000000000,
    "session.previous_id": "71260acc5286455f99555da8c5109a07"
  }
}
```

**Session End Attributes**:

| Attribute             | Type   | Description                                   | Example                                  |
| --------------------- | ------ | --------------------------------------------- | ---------------------------------------- |
| `session.id`          | string | Unique identifier for the ended session       | `"550e8400e29b41d4a716446655440000"`     |
| `session.start_time`  | double | Session start time in nanoseconds since epoch | `1692123456789000000`                    |
| `session.end_time`    | double | Session end time in nanoseconds since epoch   | `1692125256789000000`                    |
| `session.duration`    | double | Session duration in nanoseconds               | `1800000000000` (30 minutes)             |
| `session.previous_id` | string | Identifier of the previous session (if any)   | `"71260acc5286455f99555da8c5109a07"`     |

**Background Expiration**: When a session expires in the background, the `session.end` event timestamp is set to the background start time (when app went to background), not the foreground return time.

## Span and Log Attribution

`SessionSpanProcessor` and `SessionLogRecordProcessor` automatically add session attributes to all spans and log records:

| Attribute             | Type   | Description                                  | Example                                  |
| --------------------- | ------ | -------------------------------------------- | ---------------------------------------- |
| `session.id`          | string | Current active session identifier            | `"550e8400e29b41d4a716446655440000"`     |
| `session.previous_id` | string | Previous session identifier (when available) | `"71260acc5286455f99555da8c5109a07"`     |

**Special Handling**: For `session.start` and `session.end` log records, the processors preserve the existing session attributes rather than overriding them with current session data, ensuring historical accuracy of session events.

## Thread Safety

All components are designed for concurrent access:

- `SessionManager` uses locks for thread-safe session access
- `SessionStore` handles concurrent persistence operations safely
- Processors are thread-safe and can be called from any thread

---

## iOS Session Behavior

Summary of how iOS sessions behave compared to common expectations:

- **When do session events fire?** Session events are emitted only when `getSession()` is called (by the first span or log) and the SDK creates or replaces a session. They are **not** fired on every app launch.

- **First launch:** No session in memory/disk → first activity triggers `getSession()` → new session → only **session.start** (no **session.end**).

- **Expiry:** A session is expired when **current time ≥ session's `expireTime`**. `expireTime` is set when the session is created (`now + maxLifetime`) and is **fixed** (not extended on activity). Sessions can also expire when app is in background for longer than `backgroundInactivityTimeout`. When background expiration occurs, the `session.end` timestamp is set to the background start time.

- **Kill + relaunch:** Session can be restored from disk (if `shouldPersist: true`). On first activity, `refreshSession()` checks if the restored session is expired. If **expired** → **session.end** (old) + **session.start** (new). If **not expired** → same session continues; no events.

- **Persistence:** Sessions are stored in UserDefaults (when `shouldPersist: true`) and restored on launch. Session data is saved periodically (every 30 seconds) to minimize disk I/O. Expired sessions are not restored; new sessions are created with proper `previous_id` linking.

- **Fixed lifetime:** iOS uses a fixed lifetime expiration (`maxLifetime` from start time, not sliding window). Sessions can also expire due to `backgroundInactivityTimeout` when app goes to background. As long as the session hasn't expired by either condition, it remains active.

- **Dual sessions:** Two independent session systems (OTEL and metered) operate simultaneously with separate configurations, storage, and expiration behavior.

- **Session ID Format**: 32-character hexadecimal string (TraceId format, no hyphens)

- **Pulse integration:** Session logs set **event name** and **pulse.type** (`session.start` / `session.end`).
