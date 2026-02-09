/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import Location

/// Configuration for location instrumentation (feature flag and behavior).
/// When enabled, geo attributes are added to spans and log records; mirrors Android location feature flag.
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
        LocationInstrumentation.install()
    }
}
