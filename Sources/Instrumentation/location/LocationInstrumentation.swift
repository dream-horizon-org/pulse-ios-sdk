/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Location instrumentation: holds and starts LocationProvider when enabled.
/// Mirrors Android behavior where the location library starts the provider and the SDK adds span/log processors.
public enum LocationInstrumentation {
    private static let queue = DispatchQueue(label: "com.pulse.ios.location.instrumentation")
    private static var _provider: LocationProvider?

    /// Shared LocationProvider used when instrumentation is enabled. Started by install().
    public static var provider: LocationProvider? {
        queue.sync { _provider }
    }

    /// Installs location instrumentation: creates and starts the default LocationProvider.
    /// Call this when the SDK initializes and location instrumentation is enabled.
    public static func install(
        userDefaults: UserDefaults = .standard,
        cacheInvalidationTime: TimeInterval = LocationConstants.defaultCacheInvalidationTime
    ) {
        queue.sync {
            guard _provider == nil else { return }
            let p = LocationProvider(
                userDefaults: userDefaults,
                cacheInvalidationTime: cacheInvalidationTime
            )
            _provider = p
            p.startPeriodicRefresh()
        }
    }

    /// Stops periodic refresh and clears the provider (e.g. for tests or shutdown).
    public static func uninstall() {
        queue.sync {
            _provider?.stopPeriodicRefresh()
            _provider = nil
        }
    }
}
