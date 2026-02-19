/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Fetches PulseSdkConfig from the config API (GET). Intended to be called on a background queue.
 * API contract matches Android: GET, JSON body decodes directly to PulseSdkConfig (no wrapper).
 * Validation: required fields must be present (decode fails otherwise), same as Retrofit + kotlinx.serialization.
 *
 * Caching (TTL): Uses URLSession with disk URLCache (10MB); requestCachePolicy = .useProtocolCachePolicy
 * so server Cache-Control (e.g. max-age) is respected. TTL is server-driven, same as Android OkHttp Cache.
 *
 * Retry: No application-level retry. One attempt per background fetch; on failure returns nil and does not persist.
 * Next fetch happens on next app launch (when init runs again). Android behaves the same (one provide() call per launch).
 */

import Foundation

/// Size of the config API response cache in bytes (matches Android OkHttp Cache 10MB).
private let configCacheSizeBytes: Int = 10 * 1024 * 1024

/// Creates a URLSession that uses a disk-backed URLCache for the config API (matches Android OkHttp Cache).
/// Respects server Cache-Control / max-age (TTL is server-driven; no extra client TTL).
func makeConfigURLSession(cacheDirectory: URL) -> URLSession {
    let cache = URLCache(
        memoryCapacity: 0,
        diskCapacity: configCacheSizeBytes,
        directory: cacheDirectory
    )
    let config = URLSessionConfiguration.default
    config.urlCache = cache
    config.requestCachePolicy = .useProtocolCachePolicy
    return URLSession(configuration: config)
}

/// Fetches SDK config from the remote config endpoint. Thread-safe; call from background.
public final class PulseSdkConfigRestProvider {
    private let urlProvider: () -> URL?
    private let urlSession: URLSession
    private let headers: [String: String]

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    /// - Parameters:
    ///   - urlProvider: Returns the config URL (e.g. `{base}/v1/configs/active/`). Return nil to skip fetch.
    ///   - urlSession: Session for the request. Use a session with disk URLCache (e.g. from makeConfigURLSession) to match Android OkHttp cache and server TTL.
    ///   - headers: Optional headers (e.g. tenant, auth) to send with the request.
    public init(
        urlProvider: @escaping () -> URL?,
        urlSession: URLSession = .shared,
        headers: [String: String] = [:]
    ) {
        self.urlProvider = urlProvider
        self.urlSession = urlSession
        self.headers = headers
    }

    /// Performs GET and decodes response body directly as PulseSdkConfig (matches Android: no wrapper).
    /// Call from a background queue (do not block main thread).
    /// - Returns: Decoded config if HTTP 2xx and decode succeeds; nil on network error, non-2xx, or decode failure.
    public func provide() async -> PulseSdkConfig? {
        guard let url = urlProvider() else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            PulseSdkConfigLogger.logNetworkError(error)
            return nil
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            PulseSdkConfigLogger.logApiError(code: "http_\(httpResponse.statusCode)", message: "HTTP \(httpResponse.statusCode)")
            return nil
        }

        do {
            return try PulseSdkConfigRestProvider.decoder.decode(PulseSdkConfig.self, from: data)
        } catch {
            PulseSdkConfigLogger.logDecodeFailure()
            return nil
        }
    }
}
