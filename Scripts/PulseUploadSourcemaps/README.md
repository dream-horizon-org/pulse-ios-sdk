# Pulse dSYM upload scripts

These scripts upload iOS **dSYM** bundles to the Pulse backend for crash symbolication. They pack directory dSYMs with **zip** when needed and send them with **curl** as `multipart/form-data`.

## Overview

The entry point is **`pulse-upload-dsym.sh`**. It loads three helpers in order: `pulse-upload-errors.sh`, `pulse-upload-utils.sh`, `pulse-upload-task.sh`.

## Prerequisites

The scripts call these tools directly:

- **bash** — the shebang is `#!/usr/bin/env bash`. Use `bash path/to/pulse-upload-dsym.sh` in Run Scripts and on Linux CI. On macOS, `sh` often delegates to a Bash-compatible shell, so `sh pulse-upload-dsym.sh --help` may work; portable use is still `bash`.
- **curl** — HTTP upload (`pulse-upload-task.sh`).
- **`/usr/bin/zip`** — required when the dSYM path is a **directory** (`pulse-upload-utils.sh`).
- **awk** — file size text in log output (`pulse-upload-utils.sh`).

## Scripts in this directory

- `pulse-upload-dsym.sh` — arguments, validation, zip if needed, upload.
- `pulse-upload-errors.sh` — non-zero exit on failure.
- `pulse-upload-utils.sh` — paths, URL normalization, usage text, zip preparation.
- `pulse-upload-task.sh` — builds the request and runs `curl`.

## Environment variables (optional)

Flags override environment when both are set.

**Read from the environment:**

- `PULSE_UPLOAD_API_URL` — same as `-u` / `--api-url` / `--url`
- `PULSE_UPLOAD_API_KEY` — same as `-k` / `--api-key`
- `PULSE_UPLOAD_DSYM_PATH` — same as `-p` / `--dsym-path` / `--dsym`

**Not read from the environment** (flags only): `--app-version`, `--version-code`, `--type`, `--debug`.

## Usage

### Example (environment + flags)

Set `REPO` to the directory that contains `Scripts/PulseUploadSourcemaps/` (for example your `pulse-ios-sdk` checkout). Use a real `.dSYM` path.

```bash
export PULSE_UPLOAD_API_URL='https://your-host/v1/symbolicate/file/upload'
export PULSE_UPLOAD_API_KEY='your-api-key'
export PULSE_UPLOAD_DSYM_PATH='/path/to/YourApp.app.dSYM'

bash "${REPO}/Scripts/PulseUploadSourcemaps/pulse-upload-dsym.sh" \
  --app-version='1.0' \
  --version-code=1 \
  --type=dsym
```

If nothing is listening at the URL, `curl` may exit with an error (for example exit code 7). On HTTP **2xx**, the script prints `Upload successful`.

### Xcode Run Script (CocoaPods)

After `pod install`, PulseKit includes these files under Pods (`preserve_paths` in `PulseKit.podspec`). Run the phase after the dSYM exists (for example late in the target’s build phases).

```bash
bash "${PODS_ROOT}/PulseKit/Scripts/PulseUploadSourcemaps/pulse-upload-dsym.sh" \
  --url="https://your-host/v1/symbolicate/file/upload" \
  --api-key="${PULSE_API_KEY}" \
  --dsym="${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}" \
  --app-version="${MARKETING_VERSION}" \
  --version-code="${CURRENT_PROJECT_VERSION}" \
  --type=dsym
```

You may set `PULSE_UPLOAD_API_URL` and `PULSE_UPLOAD_API_KEY` in the scheme instead of passing `--url` and `--api-key`.

Relative `--dsym` paths are resolved from the **current working directory** of the Run Script (often the project directory). Prefer `$DWARF_DSYM_FOLDER_PATH` / `$DWARF_DSYM_FILE_NAME` for absolute paths.

### Command-line reference

Aliases: `--url` → `--api-url`, `--dsym` → `--dsym-path`.

**Required (via flags and/or the three env vars above):** API URL, API key, dSYM path.

**Required (flags only):** `--app-version`, `--version-code` (positive integer string).

**Optional:** `--type`, `--debug`, `--help`.

## Upload format

- Method: `POST`, `Content-Type: multipart/form-data`.
- Parts: **`metadata`** (JSON array) and **`fileContent`** (octet stream).
- Header: **`X-API-KEY`** with your API key.
- `localhost` in the URL is replaced with `127.0.0.1` before the request.
- `curl` uses `--max-time 300`.

## Help

```bash
bash /path/to/pulse-upload-dsym.sh --help
```

## Choosing the SPM plugin vs these scripts

If you add the SDK with **Swift Package Manager**, use the command plugin in [Pulse Upload Plugin](../../Plugins/PulseUploadPlugin/README.md) and run `swift package uploadSourceMaps`.

If you add the SDK with **CocoaPods** or you want an upload step that runs **shell commands only** and does not call `swift`, use the scripts in this directory.
