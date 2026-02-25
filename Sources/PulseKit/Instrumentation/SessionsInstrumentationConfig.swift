/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import Sessions
import OpenTelemetrySdk

public struct SessionsInstrumentationConfig {
    public private(set) var enabled: Bool = true

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public mutating func enabled(_ value: Bool) {
        self.enabled = value
    }

    internal func createProcessors(baseLogProcessor: LogRecordProcessor) -> (
        otelSpanProcessor: SpanProcessor,
        otelLogProcessor: LogRecordProcessor
    )? {
        guard self.enabled else { return nil }
        
        let otelConfig = SessionConfig(
            backgroundInactivityTimeout: SessionConfigDefaults.backgroundInactivityTimeout,
            maxLifetime: SessionConfigDefaults.maxLifetime,
            shouldPersist: SessionConfigDefaults.shouldPersist,
            startEventName: SessionConstants.sessionStartEvent,
            endEventName: SessionConstants.sessionEndEvent
        )
        let otelManager = SessionManager(configuration: otelConfig)
        
        let otelSpanProcessor = SessionSpanProcessor(sessionManager: otelManager)
        let otelLogProcessor = SessionLogRecordProcessor(nextProcessor: baseLogProcessor, sessionManager: otelManager)
        
        return (otelSpanProcessor, otelLogProcessor)
    }
}

extension SessionsInstrumentationConfig: InstrumentationLifecycle {
    internal func initialize(ctx: InstallationContext) {
        guard self.enabled else { return }
        _ = SessionEventInstrumentation()
    }

    internal func uninstall() {}
}
