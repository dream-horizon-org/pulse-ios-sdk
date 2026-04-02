# PulseKit Release Pipeline

End-to-end pipeline from source code change to published SDK.

---

## Overview

```
pulse-ios-sdk (source)                          pulse-ios (release)
════════════════════                             ═══════════════════

  PR to main
      │
      ▼
┌─────────────────────┐
│  BuildAndTest.yml   │
│  • SwiftLint        │
│  • Unit tests       │
│  • iOS build & test │
│  • Example app      │
│  • XCFramework      │
└────────┬────────────┘
         │ (Manual trigger)
         ▼
┌─────────────────────┐
│  release.yml        │
│  • Read version     │
│  • Build XCFramework│
│  • Zip PulseKit +   │                     ┌─────────────────────────┐
│    checksum; copy   │                     │  validate-pr.yml        │
│    PulseKit + peers │                     │  • Version consistency  │
│    (from podspec)   │                     │  • SPM build (sim+dev)  │
│  • Push release/*   │ ──── creates PR ──► │  • Example app build    │
│  • Create PR        │     in release repo │  • CocoaPods lint       │
└─────────────────────┘                     └────────────┬────────────┘
                                                         │ On merge
                                                         ▼
                                            ┌─────────────────────────┐
                                            │  publish.yml            │
                                            │  • Create git tag       │
                                            │  • GitHub Release + zip │
                                            │  • CocoaPods trunk push │
                                            └─────────────────────────┘
```

---

## Stage 1: PR Validation (source repo)

**Workflow:** `BuildAndTest.yml`
**Trigger:** PR opened/updated against `main`

| Job | What it does |
|-----|-------------|
| SwiftLint | Lints only changed files |
| UnitTests | `swift test` |
| iOS | Build & test on iOS Simulator |
| ExampleApp | `pod install` + build `PulseIOSExample` via CocoaPods |
| XCFramework | Full xcframework build to verify it produces a valid artifact |

All jobs must pass before merge is allowed.

---

## Stage 2: Release (source repo → release repo)

**Workflow:** `release.yml`
**Trigger:** Manual dispatch

Peer frameworks are derived from **`PulseKit.podspec`** `spec.dependency` lines; **`Scripts/print-peer-xcframework-entries.rb`** resolves each pod’s **Xcode scheme** and **`PRODUCT_MODULE_NAME`** via `xcodebuild -showBuildSettings` (after **`pod install`**). The same script feeds `build-xcframework.sh` and the release job (which copies every built peer into the release repo).

Steps:
1. Read version from `PulseKit.podspec`
2. Verify version doesn't already exist in the release repo (no duplicate tags)
3. `pod install` in `Examples/PulseIOSExample/`
4. Run `Scripts/build-xcframework.sh` — builds PulseKit + all peers under `build/`
5. Zip **PulseKit** only and compute Swift Package Manager checksum (CocoaPods / release asset)
6. Checkout the release repo (`dream-horizon-org/pulse-ios`)
7. Create a `release/{version}` branch
8. Copy **`PulseKit.xcframework`**, **`PulseKit.xcframework.zip`**, and **every peer** `*.xcframework` produced by the build (same list as `print-peer-xcframework-entries.rb`)
9. Set **`spec.version`** in the release repo **`PulseKit.podspec`** only ( **`sed`** to match the source podspec version). **`Package.swift`** and **`spec.dependency`** are **not** rewritten by automation—update them on the release PR when peers or CocoaPods dependencies change.
10. Push branch and create a PR in the release repo (PR body reminds reviewers to verify **`Package.swift`** binary targets and **`spec.dependency`** when needed)

---

## Stage 3: Release PR Validation (release repo)

**Workflow:** `validate-pr.yml`
**Trigger:** PR from `release/*` branch against `main`

| Check | What it validates |
|-------|-------------------|
| Version consistency | `PulseKit.podspec` `spec.version` matches the release branch; optional `let version` in `Package.swift` if you keep it—maintain manually when automation does not touch SPM |
| Example app (Simulator) | Framework links, compiles, and public API is intact (SPM) |
| Example app (Device) | Same validation for arm64 device architecture |
| CocoaPods lint | `pod lib lint` — podspec is valid and publishable |

**How the SPM build works:**
- `Package.swift` in the release repo must list **path** `.binaryTarget` entries for every `*.xcframework` at repo root (maintainers update when peers change).
- Validate-pr patches or validates as needed (e.g. local `PulseKit.xcframework`, injected `PulseKitValidation` target in `Example/Sources/`) so CI can import PulseKit and exercise the public API.

---

## Stage 4: Publish (release repo)

**Workflow:** `publish.yml`
**Trigger:** `release/*` PR merged to `main`, or manual dispatch

Steps:
1. Extract version from podspec
2. Create git tag `{version}`
3. Create GitHub Release with `PulseKit.xcframework.zip` attached
4. Publish to CocoaPods trunk via `pod trunk push`

Idempotent — skips steps if tag/release already exist.

---

## Key Files

### Source repo (`pulse-ios-sdk`)

| File | Purpose |
|------|---------|
| `PulseKit.podspec` | Source of truth for version |
| `Scripts/build-xcframework.sh` | Builds xcframework from CocoaPods workspace |
| `Examples/PulseIOSExample/` | Example app used during xcframework build |
| `.github/workflows/BuildAndTest.yml` | PR validation |
| `.github/workflows/release.yml` | Build + push to release repo |

### Release repo (`pulse-ios`)

| File | Purpose |
|------|---------|
| `PulseKit.xcframework/` | Prebuilt binary framework |
| `PulseKit.xcframework.zip` | Zip for SPM binary target download |
| `Package.swift` | SPM manifest (binary target + wrapper) |
| `PulseKit.podspec` | CocoaPods spec (vendored framework) |
| `Sources/PulseKitWrapper/Exports.swift` | `@_exported import PulseKit` |
| `Example/Sources/PulseKitValidation.swift` | CI validation target |
| `.github/workflows/validate-pr.yml` | Release PR validation |
| `.github/workflows/publish.yml` | Tag + release + CocoaPods publish |

---

## Important Notes

### `@_implementationOnly import` for KSCrash

The xcframework is built with CocoaPods, where KSCrash exposes a single `KSCrash` module. In SPM, KSCrash exposes separate modules (`KSCrashRecording`, `KSCrashFilters`). To keep the xcframework compatible with both:

```swift
#if canImport(KSCrashRecording)
  @_implementationOnly import KSCrashRecording
#elseif canImport(KSCrash)
  @_implementationOnly import KSCrash
#endif
```

`@_implementationOnly` prevents the import from appearing in the `.swiftinterface`, so consumers don't need to resolve the KSCrash module regardless of which package manager they use.

### Secrets Required

| Secret | Repo | Purpose |
|--------|------|---------|
| `RELEASE_REPO_TOKEN` | Source | Push branches + create PRs in release repo |
| `COCOAPODS_TRUNK_EMAIL` | Release | CocoaPods trunk auth |
| `COCOAPODS_TRUNK_TOKEN` | Release | CocoaPods trunk auth |
