/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Logging for config load/fetch flow. Uses os_log so it does not depend on OTEL being ready.
 */

import Foundation
import os.log

enum PulseSdkConfigLogger {
    private static let log = OSLog(subsystem: "com.pulse.ios.sdk", category: "SamplingConfig")

    /// Call after loading config from persistence at init.
    static func logLoaded(currentVersion: Int?) {
        if let v = currentVersion {
            os_log("Pulse config: loaded from persistence version=%{public}d", log: log, type: .debug, v)
        } else {
            os_log("Pulse config: no persisted config (using Pulse.initialize defaults)", log: log, type: .debug)
        }
    }

    /// Call after background fetch with result and persist decision.
    static func logFetchResult(newVersion: Int?, currentVersion: Int?, shouldPersist: Bool) {
        let newStr = newVersion.map { "\($0)" } ?? "null"
        let curStr = currentVersion.map { "\($0)" } ?? "null"
        os_log(
            "Pulse config fetch: newConfigVersion=%@ currentConfigVersion=%@ shouldUpdate=%{public}s",
            log: log,
            type: .debug,
            newStr,
            curStr,
            shouldPersist ? "true" : "false"
        )
    }

    /// Call when API returns an error payload (response.error != nil).
    static func logApiError(code: String, message: String) {
        os_log("Pulse config fetch: API error code=%{public}@ message=%{public}@", log: log, type: .default, code, message)
    }

    /// Call when response body fails to decode (invalid or missing payload).
    static func logDecodeFailure() {
        os_log("Pulse config fetch: response decode failed (invalid or missing payload)", log: log, type: .default)
    }

    /// Call when loading from persistence fails to decode (corrupt or outdated stored JSON). We do not crash; caller uses defaults.
    static func logDecodeFailureOnLoad() {
        os_log("Pulse config: load from persistence decode failed (using defaults)", log: log, type: .default)
    }

    /// Call when network request fails.
    static func logNetworkError(_ error: Error) {
        os_log("Pulse config fetch: network error %{public}@", log: log, type: .default, String(describing: error))
    }

    /// Call when config endpoint URL string is invalid (URL(string:) returns nil). Skip fetch to match Android behavior.
    static func logInvalidConfigURL(_ urlString: String) {
        os_log("Pulse config fetch: invalid config URL (skipping fetch) %{public}@", log: log, type: .default, urlString)
    }

    /// Call when config version is unsupported.
    static func logUnsupportedVersion(_ version: Int) {
        os_log("Pulse config fetch: unsupported config version=%{public}d", log: log, type: .default, version)
    }
}
