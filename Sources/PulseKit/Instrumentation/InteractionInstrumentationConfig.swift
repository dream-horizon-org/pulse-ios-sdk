/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import InteractionInstrumentation
import OpenTelemetrySdk

/// Configuration for Interaction Instrumentation in PulseKit DSL
public struct InteractionInstrumentationConfig {
    public private(set) var enabled: Bool = true
    public private(set) var configUrlProvider: (() -> String)?

    public init(enabled: Bool = true, configUrlProvider: (() -> String)? = nil) {
        self.enabled = enabled
        self.configUrlProvider = configUrlProvider
    }

    public mutating func enabled(_ value: Bool) {
        self.enabled = value
    }

    public mutating func setConfigUrl(_ provider: @escaping () -> String) {
        self.configUrlProvider = provider
    }
    
    internal func createLogProcessor(baseLogProcessor: LogRecordProcessor) -> LogRecordProcessor? {
        guard self.enabled else {
            return nil
        }
        return InteractionLogListener(nextProcessor: baseLogProcessor)
    }
}

extension InteractionInstrumentationConfig: InstrumentationInitializer {
    internal func initialize(ctx: InstallationContext) {
        guard self.enabled else { return }

        let configUrlProvider = self.configUrlProvider ?? {
            "http://127.0.0.1:8080/v1/interactions/all-active-interactions"
        }
        let interactionConfig = InteractionInstrumentationConfiguration(
            configUrlProvider: configUrlProvider,
            attributeExtractor: nil
        )
        let instrumentation = InteractionInstrumentation(configuration: interactionConfig)
        instrumentation.install()
    }
}

