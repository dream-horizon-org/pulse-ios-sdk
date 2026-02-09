/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Location instrumentation: holds and starts LocationProvider when enabled.

public final class LocationInstrumentation {
    private static let shared = LocationInstrumentation()
    private static let queue = DispatchQueue(label: "com.pulse.ios.location.instrumentation")
    
    private var _provider: LocationProvider?
    
    #if canImport(UIKit)
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif

    private init() {}

    /// Shared LocationProvider used when instrumentation is enabled. Started by install().
    /// **ASYNC** - Returns immediately, reads from queue in background.
    public static var provider: LocationProvider? {
        get async {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: shared._provider)
                }
            }
        }
    }

    /// Installs location instrumentation: creates LocationProvider and registers app lifecycle listeners.
    /// **BLOCKING** - matches Android's synchronous install() behavior.
    /// Call this when the SDK initializes and location instrumentation is enabled.
    ///
    /// Note: Unlike Android which starts on foreground, iOS starts immediately if already in foreground.
    public static func install(
        userDefaults: UserDefaults = .standard,
        cacheInvalidationTime: TimeInterval = LocationConstants.defaultCacheInvalidationTime
    ) {
        queue.sync {
            shared.installProviderSync(
                userDefaults: userDefaults,
                cacheInvalidationTime: cacheInvalidationTime
            )
        }
    }

    private func installProviderSync(
        userDefaults: UserDefaults,
        cacheInvalidationTime: TimeInterval
    ) {
        // Matches Android: just create provider and register listeners, don't start yet
        guard _provider == nil else { return }
        
        let p = LocationProvider(
            userDefaults: userDefaults,
            cacheInvalidationTime: cacheInvalidationTime
        )
        _provider = p
        
        // Register app lifecycle listeners (mirrors Android's ApplicationStateListener)
        #if canImport(UIKit)
        registerLifecycleListeners()
        
        // Start immediately if app is already in foreground (Android starts on first foreground)
        // This handles the case where install() is called after app is already active
        DispatchQueue.main.async {
            if UIApplication.shared.applicationState == .active {
                LocationInstrumentation.queue.async {
                    shared._provider?.startPeriodicRefresh()
                }
            }
        }
        #else
        // On non-UIKit platforms (macOS without UIKit), start immediately
        p.startPeriodicRefresh()
        #endif
    }
    
    #if canImport(UIKit)
    private func registerLifecycleListeners() {
        // Listen for app entering background - pause location refresh (battery saving)
        // Matches Android's onApplicationBackgrounded()
        let backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            LocationInstrumentation.queue.async {
                self?.onApplicationBackgrounded()
            }
        }
        
        // Listen for app entering foreground - resume location refresh
        // Matches Android's onApplicationForegrounded()
        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            LocationInstrumentation.queue.async {
                self?.onApplicationForegrounded()
            }
        }
        
        lifecycleObservers = [backgroundObserver, foregroundObserver]
    }
    
    private func onApplicationForegrounded() {
        // Matches Android: initializedLocationProvider?.startPeriodicRefresh()
        _provider?.startPeriodicRefresh()
    }
    
    private func onApplicationBackgrounded() {
        // Matches Android: initializedLocationProvider?.stopPeriodicRefresh()
        _provider?.stopPeriodicRefresh()
    }
    #endif

    /// Stops periodic refresh and clears the provider (e.g. for tests or shutdown).
    /// **BLOCKING** - matches Android's synchronous uninstall() behavior.
    public static func uninstall() {
        queue.sync {
            shared.uninstallProviderSync()
        }
    }

    private func uninstallProviderSync() {
        _provider?.stopPeriodicRefresh()
        _provider = nil
        
        #if canImport(UIKit)
        // Remove lifecycle observers
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        #endif
    }
}
