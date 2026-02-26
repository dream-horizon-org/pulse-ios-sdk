import Foundation
#if canImport(Location)
import Location
#endif

/// Configuration for location instrumentation
public struct LocationInstrumentationConfig {
    public private(set) var enabled: Bool = false

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public mutating func enabled(_ value: Bool) {
        self.enabled = value
    }
}

extension LocationInstrumentationConfig: InstrumentationLifecycle {
    internal func initialize(ctx: InstallationContext) {
        guard enabled else { return }
        #if canImport(Location)
        LocationInstrumentation.install()
        #endif
    }

    internal func uninstall() {
        guard enabled else { return }
        #if canImport(Location)
        LocationInstrumentation.uninstall()
        UserDefaults.standard.removeObject(forKey: "location_cache")
        #endif
    }
}
