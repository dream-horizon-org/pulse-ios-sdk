# PulseIOSExample

Example iOS app demonstrating PulseKit integration. Can be built against **source** (default) or a **pre-built XCFramework**.

## Prerequisites

- Xcode 16.4+
- CocoaPods (`gem install cocoapods`)
- All commands below run from the **repo root** (`pulse-ios-sdk/`)

## Option 1: Build from Source (default)

Uses the podspec at the repo root, compiling PulseKit from source files.

```bash
# 1. Install pods
cd Examples/PulseIOSExample
pod install

# 2. Open workspace
open PulseIOSExample.xcworkspace

# 3. Build & run (Cmd+R) on any iOS 15.1+ simulator
```

## Option 2: Build with XCFramework

Tests the pre-built binary framework — the same artifact shipped to consumers.

### Step 1: Build the XCFramework

```bash
# From repo root — pod install is required first (provides the workspace)
cd Examples/PulseIOSExample && pod install && cd ../..

# Build the framework
./scripts/build-xcframework.sh
```

This creates `build/PulseKit.xcframework`.

### Step 2: Switch podspec to use the framework

Edit `PulseKit.podspec` at the repo root:

1. Comment out `spec.source_files`, `spec.exclude_files`, and `spec.pod_target_xcconfig`
2. Add `spec.vendored_frameworks = "build/PulseKit.xcframework"`

### Step 3: Reinstall pods and build

```bash
cd Examples/PulseIOSExample
pod install
open PulseIOSExample.xcworkspace
# Build & run (Cmd+R)
```

## App Features

- SDK Initialization
- Custom Events
- Non-Fatal Errors
- Closure-based Spans
- Manual Start/End Spans
- Network Request Instrumentation

## Configuration

The app sends telemetry to `http://127.0.0.1:4318` by default. Update the endpoint in `AppDelegate.swift` if needed.
