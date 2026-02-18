# Crash Instrumentation

The Crash instrumentation detects native crashes (signals, Mach exceptions, Objective-C exceptions) and reports them as OpenTelemetry log events.

## Attributes

When a crash is detected and the app relaunches, the following attributes are emitted on the `device.crash` log event:

| Attribute | Description |
|-----------|-------------|
| `exception.type` | Exception or signal name (e.g. `NSRangeException`, `SIGABRT`, `EXC_BAD_ACCESS`) |
| `exception.message` | Exception reason or crash diagnosis |
| `exception.stacktrace` | Full Apple-format crash report |
| `thread.id` | Index of the crashed thread |
| `thread.name` | Thread name or dispatch queue label |

These follow the [OpenTelemetry Exception semantic conventions](https://opentelemetry.io/docs/specs/semconv/registry/attributes/exception/) and [Thread semantic conventions](https://opentelemetry.io/docs/specs/semconv/registry/attributes/thread/).

## Behavior

- On `install()`, [KSCrash](https://github.com/kstenerud/KSCrash) registers low-level crash handlers (Mach exceptions, UNIX signals, NSException).
- When a crash occurs, KSCrash's async-signal-safe C handlers write a JSON report to `Library/Caches/KSCrash/`.
- On the next app launch, pending reports are read from KSCrash's report store, parsed, emitted as `device.crash` OTel log records, and deleted.
- If report processing fails, reports are left on disk for the next attempt (no crash-loop).
- The stacktrace is formatted using KSCrash's `CrashReportFilterAppleFmt` and capped at 25 KB.

## Advanced Guide

### Crash capture

Crash capture is handled by [KSCrash](https://github.com/kstenerud/KSCrash) (`Recording` + `Filters` modules). On `install()`, KSCrash registers three types of native crash handlers:

- **Mach exception handler** — catches `EXC_BAD_ACCESS`, `EXC_BREAKPOINT`, etc.
- **UNIX signal handler** — catches `SIGSEGV`, `SIGABRT`, `SIGTRAP`, `SIGBUS`, etc.
- **NSException handler** — catches uncaught Objective-C exceptions.

When any of these fire, KSCrash's C-level handler writes a full JSON report to disk synchronously using only async-signal-safe operations (no Obj-C, no Swift, no malloc). This ensures the report survives process death.

### Report processing

On the next app launch, `processStoredCrashes()` iterates over `KSCrash.shared.reportStore.reportIDs`, reads each report via `reportStore.report(for:)`, extracts the crash attributes using `CrashReportParser`, converts the raw JSON to an Apple-format stacktrace via `CrashReportFilterAppleFmt`, emits the result as a `device.crash` OTel log record, and deletes the report from disk.

### Storage

KSCrash stores crash reports as JSON files under:

```
{AppSandbox}/Library/Caches/KSCrash/{AppName}/Reports/
```

Additional state (launch count, last crash flag) is stored in:

```
{AppSandbox}/Library/Caches/KSCrash/{AppName}/Data/CrashState.json
```

### Testing crashes

KSCrash's signal and Mach handlers are intercepted by LLDB when the debugger is attached. To test crash capture:

1. Build & Run from Xcode (installs the app)
2. Stop the app in Xcode (⌘.)
3. Tap the app icon on the simulator/device to launch without the debugger
4. Trigger a crash
5. Tap the app icon again — the crash report will be processed and emitted

The example app (`PulseIOSExample`) includes buttons for triggering various crash types: NSException, fatalError, array out of bounds, force unwrap nil, stack overflow, abort, null pointer dereference, background thread crash, and named thread crash.
