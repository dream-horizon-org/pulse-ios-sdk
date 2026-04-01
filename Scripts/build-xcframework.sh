#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Build PulseKit.xcframework and peer dependency xcframeworks from the
# CocoaPods example workspace.
#
# Requires: pod install in Examples/PulseIOSExample/
#
# Outputs (under build/):
#   - PulseKit.xcframework
#   - KSCrash, OpenTelemetryApi, OpenTelemetrySdk, SwiftProtobuf (see EXTRA_XCFRAMEWORKS)
#
# Usage (from repo root):
#   ./Scripts/build-xcframework.sh
# ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

WORKSPACE="Examples/PulseIOSExample/PulseIOSExample.xcworkspace"

OUT_DIR="build"
ARC_DIR="$OUT_DIR/archives"

# scheme:FrameworkBasename — basename is the folder under .../Frameworks/*.framework
EXTRA_XCFRAMEWORKS=(
  "KSCrash:KSCrash"
  "OpenTelemetry-Swift-Api:OpenTelemetryApi"
  "OpenTelemetry-Swift-Sdk:OpenTelemetrySdk"
  "SwiftProtobuf:SwiftProtobuf"
)

# ------------------------------------------------------------------
# Archive + create-xcframework for one Pods scheme.
# Args: $1 = xcode scheme, $2 = framework folder name (without .framework)
# ------------------------------------------------------------------
build_xcframework_for_scheme() {
  local scheme="$1"
  local fw_name="${2:-$scheme}"

  local ios_arc="${ARC_DIR}/${scheme}-iOS.xcarchive"
  local sim_arc="${ARC_DIR}/${scheme}-Sim.xcarchive"
  local dst="${OUT_DIR}/${fw_name}.xcframework"

  local ios_fw="${ios_arc}/Products/Library/Frameworks/${fw_name}.framework"
  local sim_fw="${sim_arc}/Products/Library/Frameworks/${fw_name}.framework"
  local ios_dsym="${ios_arc}/dSYMs/${fw_name}.framework.dSYM"

  local common_flags=(
    -workspace "$WORKSPACE"
    -scheme "$scheme"
    -configuration Release
    SKIP_INSTALL=NO
    DEBUG_INFORMATION_FORMAT=dwarf-with-dsym
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES
    MACH_O_TYPE=mh_dylib
  )

  echo ""
  echo "============================================================"
  echo "  Building xcframework: ${fw_name} (scheme: ${scheme})"
  echo "============================================================"

  echo ""
  echo "==> Archive ${scheme} (iOS device)..."
  xcodebuild archive \
    "${common_flags[@]}" \
    -archivePath "$ios_arc" \
    -sdk iphoneos

  echo ""
  echo "==> Archive ${scheme} (iOS Simulator)..."
  xcodebuild archive \
    "${common_flags[@]}" \
    -archivePath "$sim_arc" \
    -sdk iphonesimulator \
    -arch arm64 -arch x86_64

  if [[ ! -d "$ios_fw" || ! -d "$sim_fw" ]]; then
    echo "error: missing framework in archive (expected ${fw_name}.framework)" >&2
    echo "  ios:  $ios_fw" >&2
    echo "  sim:  $sim_fw" >&2
    exit 1
  fi

  echo ""
  echo "==> Create ${fw_name}.xcframework..."
  rm -rf "$dst"
  xcodebuild -create-xcframework \
    -framework "$ios_fw" \
    -framework "$sim_fw" \
    -output "$dst"

  if [[ -d "$ios_dsym" ]]; then
    echo "==> Copying dSYM for ${fw_name}..."
    cp -R "$ios_dsym" "$dst/"
  fi

  echo "==> ${dst} ($(du -sh "$dst" | cut -f1))"
}

# ---- Clean ----
rm -rf "$OUT_DIR"
mkdir -p "$ARC_DIR"

# ---- PulseKit ----
build_xcframework_for_scheme "PulseKit" "PulseKit"

# ---- Extra dependencies ----
for entry in "${EXTRA_XCFRAMEWORKS[@]}"; do
  scheme="${entry%%:*}"
  fw_name="${entry#*:}"
  build_xcframework_for_scheme "$scheme" "$fw_name"
done

# ---- Done ----
echo ""
echo "============================================================"
echo "  BUILD COMPLETE"
echo "============================================================"
echo ""
echo "  Artifacts:"
echo "    ${OUT_DIR}/PulseKit.xcframework"
for entry in "${EXTRA_XCFRAMEWORKS[@]}"; do
  echo "    ${OUT_DIR}/${entry#*:}.xcframework"
done
echo "============================================================"
