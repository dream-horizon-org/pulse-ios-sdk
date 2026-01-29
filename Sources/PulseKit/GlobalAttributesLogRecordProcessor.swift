/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
import OpenTelemetryApi

/// Log processor that appends global attributes to every log record.
/// 
/// Note: User properties (userId and userProperties) can be updated after initialization.
/// Static global attributes set during initialization are immutable after init.
internal class GlobalAttributesLogRecordProcessor: LogRecordProcessor {
    private weak var pulseKit: PulseKit?
    private let nextProcessor: LogRecordProcessor

    init(pulseKit: PulseKit, nextProcessor: LogRecordProcessor) {
        self.pulseKit = pulseKit
        self.nextProcessor = nextProcessor
    }
    
    func onEmit(logRecord: ReadableLogRecord) {
        guard let pulseKit = pulseKit else {
            nextProcessor.onEmit(logRecord: logRecord)
            return
        }
        
        var enhancedRecord = logRecord
        
        // Add static global attributes (set during initialization)
        if let globalAttributes = pulseKit._globalAttributes {
            for (key, value) in globalAttributes {
                enhancedRecord.setAttribute(key: key, value: value)
            }
        }
        
        // Add installation ID (persists across app launches until uninstall)
        enhancedRecord.setAttribute(
            key: PulseAttributes.appInstallationId,
            value: AttributeValue.string(pulseKit.installationIdManager.installationId)
        )
        
        // Add dynamic user properties (can be updated after initialization)
        if let userId = pulseKit.userSessionEmitter.userId {
            enhancedRecord.setAttribute(key: PulseAttributes.userId, value: AttributeValue.string(userId))
        }
        
        for (key, value) in pulseKit.userSessionEmitter.userProperties {
            enhancedRecord.setAttribute(key: PulseAttributes.pulseUserParameter(key), value: value)
        }
        
        nextProcessor.onEmit(logRecord: enhancedRecord)
    }
    
    func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
        return nextProcessor.shutdown(explicitTimeout: explicitTimeout)
    }
    
    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        return nextProcessor.forceFlush(explicitTimeout: explicitTimeout)
    }
}

