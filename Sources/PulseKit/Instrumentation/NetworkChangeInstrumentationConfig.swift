/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
#if os(iOS) && !targetEnvironment(macCatalyst)
import NetworkStatus
#endif

/// Configuration for network-change instrumentation. When enabled, activates the reporter
/// in NetworkStatus (which owns monitor + log emission); config only turns the feature on/off.
public struct NetworkChangeInstrumentationConfig {
    public private(set) var enabled: Bool = true

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public mutating func enabled(_ value: Bool) {
        self.enabled = value
    }
}

extension NetworkChangeInstrumentationConfig: InstrumentationInitializer {
    internal func initialize(ctx: InstallationContext) {
        guard self.enabled else { return }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let logger = ctx.loggerProvider.get(
            instrumentationScopeName: "io.opentelemetry.network"
        )
        NetworkChangeReporter.start(logger: logger)
        #endif
    }
}
