/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Cached location model used by LocationProvider and location attribute processors.
/// Mirrors Android's CachedLocation (timestamp in seconds for iOS).
struct CachedLocation: Codable {
    let latitude: Double
    let longitude: Double
    let timestamp: TimeInterval
    let countryIsoCode: String?
    let regionIsoCode: String?
    let localityName: String?
    let postalCode: String?

    /// Checks if the cached location has expired based on the cache invalidation time.
    /// - Parameter ttl: The cache invalidation time in seconds
    /// - Returns: true if the cache is expired, false otherwise
    func isExpired(_ ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince1970 - timestamp > ttl
    }
}
