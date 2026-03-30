# Pulse Upload Plugin

A Swift Package Manager command plugin for uploading dSYM (Debug Symbol) files to the Pulse backend for crash symbolication.

## Overview

The Pulse Upload Plugin automates the upload of iOS debug symbol files (dSYM) to your Pulse backend. It can be used both from the command line and integrated into Xcode build phases for automatic uploads after each build.

## Prerequisites

- Swift 5.9+ (for SPM command plugins)
- Xcode 15+ (for Xcode integration)
- Access to Pulse backend API
- Valid API key for authentication

## Setup

### 1. Add the Package Dependency

In your Xcode project or `Package.swift`, add the Pulse iOS SDK as a dependency:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/pulse-ios-sdk", from: "1.0.0")
]
```

### 2. Verify Plugin Availability

Check that the plugin is available:

```bash
cd /path/to/your/project
swift package plugin --list
```

You should see `uploadSourceMaps` in the list.

## Usage

### Command Line Usage

#### Basic Command

```bash
cd /path/to/pulse-ios-sdk
swift package \
  --allow-network-connections all \
  uploadSourceMaps \
  --api-url=http://localhost:8080/v1/symbolicate/file/upload \
  --api-key=your-api-key \
  --dsym-path=/path/to/YourApp.app.dSYM \
  --app-version=1.0.0 \
  --version-code=1 \
  --type=dsym \
  -d
```

#### Command Options

**Required Arguments:**
- `-u, --api-url=<url>` - API URL for uploading files
- `-k, --api-key=<key>` - API key for authenticating API requests 
- `-p, --dsym-path=<path>` - Path to dSYM file or directory to upload
- `-v, --app-version=<version>` - App version (e.g., 1.0.0)
- `-c, --version-code=<code>` - Version code (positive integer, e.g., 1)

**Optional Arguments:**
- `-t, --type=dsym` - File type (default: unknown, auto-detected if dSYM)
- `-d, --debug` - Show debug information including metadata
- `-h, --help` - Show help message

### Xcode Integration

#### Step 1: Add Run Script Phase

1. Open your Xcode project
2. Select your target
3. Go to **Build Phases** tab
4. Click **+** and select **New Run Script Phase**
5. Drag the script phase to run **after** "Copy Bundle Resources" or "Code Sign" (so dSYM exists)

#### Step 2: Configure the Run Script

Add the following script to the Run Script phase:

```bash
#!/bin/bash

echo "Starting Pulse dSYM upload..."

# Unset Xcode build environment variables that confuse Swift Package Manager
# These variables are set by Xcode during build and can cause SPM to use the wrong SDK
unset SDKROOT
unset PLATFORM_NAME
unset EFFECTIVE_PLATFORM_NAME

# Navigate to the Swift package directory
cd "/path/to/pulse-ios-sdk"

# Run the upload plugin
swift package \
  --allow-network-connections all \
  uploadSourceMaps \
  --api-url=http://localhost:8080/v1/symbolicate/file/upload \
  --api-key=your-api-key \
  --dsym-path="$DWARF_DSYM_FOLDER_PATH/$DWARF_DSYM_FILE_NAME" \
  --app-version="$MARKETING_VERSION" \
  --version-code="$CURRENT_PROJECT_VERSION" \
  --type=dsym \
  -d

echo "Pulse dSYM upload finished"
```

#### Step 3: Using Xcode Build Variables (Recommended)

The script above uses Xcode build variables:
- `$DWARF_DSYM_FOLDER_PATH` - Folder containing the dSYM
- `$DWARF_DSYM_FILE_NAME` - Name of the dSYM bundle
- `$MARKETING_VERSION` - App version from Info.plist
- `$CURRENT_PROJECT_VERSION` - Build number

### Building from Command Line

You can also build your project from the command line, and the Run Script will execute automatically:

```bash
cd /path/to/your/ios/project

xcodebuild \
  -workspace YourApp.xcworkspace \
  -scheme YourApp \
  -configuration Release \
  -sdk iphonesimulator \
  build
```

This will:
1. Build your app
2. Generate the dSYM file
3. Automatically run your Run Script phase
4. Upload the dSYM to your backend

## Troubleshooting

### Plugin Not Found

If you get "plugin not found" error:
- Ensure you're in the correct directory (where `Package.swift` exists)
- Verify the package dependency is properly resolved
- Try: `swift package resolve`

### dSYM File Not Found

- Ensure you're building in **Release** configuration (dSYM files are generated for Release builds)
- Check that the path in your Run Script matches your DerivedData location
- Verify the dSYM exists: `ls -la "$DWARF_DSYM_FOLDER_PATH/$DWARF_DSYM_FILE_NAME"`

### Network Permission Error

The plugin requires network access. Always include `--allow-network-connections all` when running the command.

### Upload Fails

- Check your API URL is correct and accessible
- Verify your API key is valid
- Use `-d` flag for debug output
- Check backend logs for detailed error messages

## Supported File Types

Currently, the plugin supports:
- **dSYM files** - iOS debug symbol files (automatically detected and zipped if directory)

Other file types default to `"unknown"` and may be rejected by the backend.

## CocoaPods

If the SDK is integrated with **CocoaPods** instead of SPM, use the shell upload scripts in [`Scripts/PulseUploadSourcemaps/README.md`](../../Scripts/PulseUploadSourcemaps/README.md). Those run without invoking Swift.

If you use **Swift Package Manager** for the SDK, this command plugin is the usual choice: run `swift package uploadSourceMaps` from the package that contains the dependency.