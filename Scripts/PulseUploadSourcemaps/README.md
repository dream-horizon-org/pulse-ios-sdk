# Upload dSYMs to Pulse

Upload your app’s **dSYM** with **`pulse-upload-dsym.sh`**. Use **`bash`**. You need **`bash`**, **`curl`**, **`/usr/bin/zip`** (for folder dSYMs), your **upload URL**, and **API key**.

Build your app in **Xcode at least once** so **`PulseKit.framework`** (with the **`.sh`** files inside) exists under Derived Data.

---

## Local terminal (macOS)

Replace **`YourApp`** with the **start of your Derived Data folder name**—usually the same as your Xcode project or main target (e.g. **`PulseIOSExample`**, **`PulseSPMExample`**).

**1. Find the script**

**CocoaPods** (intermediate copy):

```bash
find ~/Library/Developer/Xcode/DerivedData -path "*YourApp*/XCFrameworkIntermediates/PulseKit/PulseKit.framework/pulse-upload-dsym.sh" 2>/dev/null
```

**Swift Package Manager** (and as a fallback): PulseKit is also under **Build/Products**—either next to your **`.app`** or as a sibling **`PulseKit.framework`**:

```bash
find ~/Library/Developer/Xcode/DerivedData -path "*YourApp*/Build/Products/*/PulseKit.framework/pulse-upload-dsym.sh" 2>/dev/null
find ~/Library/Developer/Xcode/DerivedData -path "*YourApp*/Build/Products/*/*.app/Frameworks/PulseKit.framework/pulse-upload-dsym.sh" 2>/dev/null
```

If you see **several paths** (Debug vs Release, simulator vs device, index vs main build), pick the one under **`…/Build/Products/…`** that matches the build you care about.

**2. Run it** (paste the path from step 1, or use a variable)

```bash
SCRIPT="$(find ~/Library/Developer/Xcode/DerivedData -path "*YourApp*/Build/Products/*/PulseKit.framework/pulse-upload-dsym.sh" 2>/dev/null | grep -v '/Index.noindex/' | head -1)"
# CocoaPods-only if the line above is empty:
# SCRIPT="$(find ~/Library/Developer/Xcode/DerivedData -path "*YourApp*/XCFrameworkIntermediates/PulseKit/PulseKit.framework/pulse-upload-dsym.sh" 2>/dev/null | head -1)"
bash "${SCRIPT}" \
  --url="https://your-host/v1/symbolicate/file/upload" \
  --api-key="YOUR_API_KEY" \
  --dsym="/path/to/YourApp.app.dSYM" \
  --app-version="1.0" \
  --version-code="1" \
  --type=dsym
```

If **`SCRIPT`** is empty, run step 1 again after building, or fix **`YourApp`** in the pattern.

You can use **`PULSE_UPLOAD_API_URL`**, **`PULSE_UPLOAD_API_KEY`**, **`PULSE_UPLOAD_DSYM_PATH`** instead of **`--url`** / **`--api-key`** / **`--dsym`**. Flags override env when both are set.

```bash
bash "${SCRIPT}" --help
```

---

## Xcode Run Script

**Embedded framework** (typical for **SPM** and many app targets—run **after Embed Frameworks**):

```bash
bash "${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}/PulseKit.framework/pulse-upload-dsym.sh" \
  --url="https://your-host/v1/symbolicate/file/upload" \
  --api-key="${PULSE_API_KEY}" \
  --dsym="${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}" \
  --app-version="${MARKETING_VERSION}" \
  --version-code="${CURRENT_PROJECT_VERSION}" \
  --type=dsym
```

**CocoaPods** intermediate path (when **`PODS_XCFRAMEWORKS_BUILD_DIR`** is set):

```bash
bash "${PODS_XCFRAMEWORKS_BUILD_DIR}/PulseKit/PulseKit.framework/pulse-upload-dsym.sh" …
```

---

## Troubleshooting

| Issue | Try |
|-------|-----|
| **Nothing from `find`** | Build the app in Xcode; check **`YourApp`** matches Derived Data (`~/Library/Developer/Xcode/DerivedData`). |
| **Permission denied** | Use **`bash /path/to/pulse-upload-dsym.sh`**. |
| **Wrong shell** | Use **`bash`**, not **`sh`**. |
