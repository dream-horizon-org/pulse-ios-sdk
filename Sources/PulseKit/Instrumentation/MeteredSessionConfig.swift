/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import Sessions
import OpenTelemetrySdk

/// Manages metered session processors independently from OTEL session instrumentation
public struct MeteredSessionConfig {
    public private(set) var enabled: Bool = true
    private var meteredManager: SessionManager?
    
    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
    
    public mutating func enabled(_ value: Bool) {
        self.enabled = value
    }
    
    /// Creates metered session manager with default internal config
    internal mutating func createMeteredManager() -> SessionManager {
        if let existing = meteredManager {
            return existing
        }
        
        let config = SessionConfig(
            backgroundInactivityTimeout: nil,
            maxLifetime: 30 * 60,
            shouldPersist: true,
            startEventName: nil,
            endEventName: nil
        )
        let manager = SessionManager(configuration: config)
        meteredManager = manager
        return manager
    }
    
    internal func createProcessors(
        baseLogProcessor: LogRecordProcessor,
        meteredManager: SessionManager
    ) -> (meteredSpanProcessor: SpanProcessor, meteredLogProcessor: LogRecordProcessor)? {
        guard self.enabled else { return nil }
        
        let meteredSpanProcessor = MeteredSessionSpanProcessor(meteredManager: meteredManager)
        let meteredLogProcessor = MeteredSessionLogProcessor(nextProcessor: baseLogProcessor, meteredManager: meteredManager)
        
        return (meteredSpanProcessor, meteredLogProcessor)
    }
    
    internal func addMeteredSessionHeader(to headers: [String: String]?, meteredManager: SessionManager) -> [String: String] {
        var updatedHeaders = headers ?? [:]
        let sessionId = meteredManager.getSession().id
        updatedHeaders[SessionConstants.meteredSessionIdHeader] = sessionId
        return updatedHeaders
    }
}
