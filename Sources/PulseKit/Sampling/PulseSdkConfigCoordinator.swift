/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Coordinates config load from persistence and background fetch/persist.
 * Keeps all sampling config logic out of PulseKit; PulseKit only creates the coordinator and calls it.
 */

import Foundation

/// Coordinates loading current SDK config from storage and starting a background config fetch.
/// Receives the final config URL from PulseKit (PulseKit applies Android-style default when app passes nil).
public final class PulseSdkConfigCoordinator {
    private let storage: PulseSdkConfigStorage

    public init(storage: PulseSdkConfigStorage = PulseSdkConfigStorage()) {
        self.storage = storage
    }

    /// Loads and returns the current config from persistence (sync). Returns nil if none stored or decode failed.
    /// On decode failure we do not crash; we return nil and log, then the app uses Pulse.initialize defaults.
    public func loadCurrentConfig() -> PulseSdkConfig? {
        storage.load()
    }

    /// Starts a background fetch for config and persists only when version changed (apply on next launch).
    /// Matches Android: Dispatchers.IO, fetch via PulseSdkConfigRestProvider, persist only if newConfig != null && newConfig.version != currentVersion.
    /// - Parameters:
    ///   - configEndpointUrl: Final config URL (already resolved by PulseKit from endpointBaseUrl when nil; e.g. `{base:8080}/v1/configs/active/`).
    ///   - endpointHeaders: Headers sent with the GET request (e.g. X-API-KEY / project id).
    ///   - currentConfigVersion: Version of the config already loaded at init (avoids loading from storage again).
    public func startBackgroundFetch(
        configEndpointUrl: String,
        endpointHeaders: [String: String],
        currentConfigVersion: Int?
    ) {
        let currentVersion = currentConfigVersion
        let configEndpointUrlFinal = configEndpointUrl
        let endpointHeadersForConfig = endpointHeaders
        let storageRef = storage

        // Async, non-blocking: work runs on a background thread (QoS .utility ≈ Android Dispatchers.IO).
        Task.detached(priority: .utility) {
            guard let url = URL(string: configEndpointUrlFinal) else {
                PulseSdkConfigLogger.logInvalidConfigURL(configEndpointUrlFinal)
                return
            }
            let session = Self.makeSessionForConfigAPI()
            let provider = PulseSdkConfigRestProvider(
                urlProvider: { Optional(url) },
                urlSession: session,
                headers: endpointHeadersForConfig
            )
            let newConfig = await provider.provide()
            let shouldPersist = newConfig != nil && newConfig?.version != currentVersion
            PulseSdkConfigLogger.logFetchResult(
                newVersion: newConfig?.version,
                currentVersion: currentVersion,
                shouldPersist: shouldPersist
            )
            if shouldPersist, let config = newConfig {
                storageRef.saveSync(config)
            }
        }
    }

    // MARK: - Private

    private static func configApiCacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("pulse", isDirectory: true)
            .appendingPathComponent("apiCache", isDirectory: true)
    }

    private static func makeSessionForConfigAPI() -> URLSession {
        guard let cacheDir = configApiCacheDirectory() else {
            return .shared
        }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return makeConfigURLSession(cacheDirectory: cacheDir)
    }
}
