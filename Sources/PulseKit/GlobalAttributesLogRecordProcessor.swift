/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
import OpenTelemetryApi

/// Log processor that appends global attributes to every log record.
/// 
/// Note: Currently, only user properties (userId and userProperties) can be updated
/// after initialization. Static global attributes set during initialization cannot
/// be modified after init (they are set in Resource, which is immutable).
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
        
        pulseKit.userPropertiesQueue.sync {
            if let userId = pulseKit._userId {
                enhancedRecord.setAttribute(key: "user.id", value: AttributeValue.string(userId))
            }
            
            for (key, value) in pulseKit._userProperties {
                if let attrValue = pulseKit.attributeValue(from: value) {
                    enhancedRecord.setAttribute(key: "pulse.user.\(key)", value: attrValue)
                }
            }
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

