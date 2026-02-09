/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Constants for location instrumentation (mirrors Android LocationConstants / LocationInstrumentationConstants).
public enum LocationConstants {
    /// UserDefaults / SharedPreferences key for cached location (matches Android LOCATION_CACHE_KEY).
    public static let locationCacheKey = "location_cache"

    /// Default cache invalidation time: 1 hour (matches Android DEFAULT_CACHE_INVALIDATION_TIME_MS when not DEBUG).
    public static let defaultCacheInvalidationTime: TimeInterval = 60 * 60
}
