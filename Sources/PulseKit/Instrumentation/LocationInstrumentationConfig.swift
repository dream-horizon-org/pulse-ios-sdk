import Foundation
#if canImport(Location)
import Location
#endif

/// Configuration for location instrumentation (feature flag and behavior).
/// When enabled, geo attributes are added to spans and log records;
/// Requires the Location module to be linked (e.g. optional pod / SPM dependency); no-op if not present.
public struct LocationInstrumentationConfig {
    public private(set) var enabled: Bool = false

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public mutating func enabled(_ value: Bool) {
        self.enabled = value
    }
}

extension LocationInstrumentationConfig: InstrumentationInitializer {
    internal func initialize(ctx: InstallationContext) {
        guard enabled else { return }
        #if canImport(Location)
        LocationInstrumentation.install()
        #endif
    }
}
