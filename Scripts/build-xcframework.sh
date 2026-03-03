#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Build PulseKit.xcframework
#
# Requires: pod install in Examples/PulseIOSExample/ first.
#
# Usage:
#   ./scripts/build-xcframework.sh
# ------------------------------------------------------------------

WORKSPACE="Examples/PulseIOSExample/PulseIOSExample.xcworkspace"
SCHEME="PulseKit"

OUT_DIR="build"
ARC_DIR="$OUT_DIR/archives"
DST_PATH="$OUT_DIR/${SCHEME}.xcframework"

IOS_ARCHIVE_PATH="${ARC_DIR}/${SCHEME}-iOS.xcarchive"
SIM_ARCHIVE_PATH="${ARC_DIR}/${SCHEME}-Sim.xcarchive"

# ---- Clean ----
rm -rf "$OUT_DIR"
mkdir -p "$ARC_DIR"

# ---- Common build flags ----
COMMON_FLAGS=(
  -workspace "$WORKSPACE"
  -scheme "$SCHEME"
  -configuration Release
  SKIP_INSTALL=NO
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  MACH_O_TYPE=mh_dylib
)

# ---- Step 1: Archive for iOS device ----
echo ""
echo "==> Step 1/3: Archive (iOS device)..."
xcodebuild archive \
  "${COMMON_FLAGS[@]}" \
  -archivePath "$IOS_ARCHIVE_PATH" \
  -sdk iphoneos

# ---- Step 2: Archive for iOS Simulator (arm64 + x86_64) ----
echo ""
echo "==> Step 2/3: Archive (iOS Simulator)..."
xcodebuild archive \
  "${COMMON_FLAGS[@]}" \
  -archivePath "$SIM_ARCHIVE_PATH" \
  -sdk iphonesimulator \
  -arch arm64 -arch x86_64

# ---- Step 3: Create XCFramework ----
echo ""
echo "==> Step 3/3: Create XCFramework..."

IOS_FRAMEWORK="${IOS_ARCHIVE_PATH}/Products/Library/Frameworks/${SCHEME}.framework"
SIM_FRAMEWORK="${SIM_ARCHIVE_PATH}/Products/Library/Frameworks/${SCHEME}.framework"
IOS_DSYM="${IOS_ARCHIVE_PATH}/dSYMs/${SCHEME}.framework.dSYM"

xcodebuild -create-xcframework \
  -framework "$IOS_FRAMEWORK" \
  -framework "$SIM_FRAMEWORK" \
  -output "$DST_PATH"

# Copy dSYM if available
if [ -d "$IOS_DSYM" ]; then
  echo "==> Copying debug symbols..."
  cp -R "$IOS_DSYM" "$DST_PATH/"
fi

# ---- Done ----
echo ""
echo "============================================================"
echo "  BUILD COMPLETE"
echo "============================================================"
echo ""
echo "  XCFramework: $DST_PATH"
echo "  Size:        $(du -sh "$DST_PATH" | cut -f1)"
if [ -d "$IOS_DSYM" ]; then
  echo "  dSYM:        Included"
fi
echo "============================================================"
