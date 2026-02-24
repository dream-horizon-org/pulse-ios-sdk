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

    /// Creates processors for both metered and OTEL sessions
    /// Returns a tuple with both span and log processors
    /// - Parameter meteredManager: Pre-created metered session manager (created in buildOpenTelemetrySDK for headers)
    internal func createProcessors(baseLogProcessor: LogRecordProcessor, meteredManager: SessionManager) -> (
        meteredSpanProcessor: SpanProcessor,
        meteredLogProcessor: LogRecordProcessor,
        otelSpanProcessor: SpanProcessor,
        otelLogProcessor: LogRecordProcessor
    )? {
        guard self.enabled else { return nil }
        
        // Create OTEL session manager (15 seconds for testing, in-memory, emits events)
        let otelConfig = SessionConfig(
            backgroundInactivityTimeout: 5,  // 5 seconds for testing (15 * 60 for production)
            maxLifetime: 15,  // 15 seconds for testing (4 * 60 * 60 for production)
            shouldPersist: false,  // In-memory
            startEventName: SessionConstants.sessionStartEvent,  // "session.start"
            endEventName: SessionConstants.sessionEndEvent  // "session.end"
        )
        let otelManager = SessionManager(configuration: otelConfig)
        
        // Create processors - OTEL wraps base, metered wraps OTEL
        let otelSpanProcessor = SessionSpanProcessor(sessionManager: otelManager)
        let otelLogProcessor = SessionLogRecordProcessor(nextProcessor: baseLogProcessor, sessionManager: otelManager)
        
        let meteredSpanProcessor = MeteredSessionSpanProcessor(meteredManager: meteredManager)
        let meteredLogProcessor = MeteredSessionLogProcessor(nextProcessor: otelLogProcessor, meteredManager: meteredManager)
        
        return (meteredSpanProcessor, meteredLogProcessor, otelSpanProcessor, otelLogProcessor)
    }
}

extension SessionsInstrumentationConfig: InstrumentationLifecycle {
    internal func initialize(ctx: InstallationContext) {
        guard self.enabled else { return }
        _ = SessionEventInstrumentation()
    }

    internal func uninstall() {}
}
