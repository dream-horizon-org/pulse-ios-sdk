/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
import OpenTelemetryApi

/// Span processor that appends global attributes to every span.
/// 
/// Note: Currently, only user properties (userId and userProperties) can be updated
/// after initialization. Static global attributes set during initialization cannot
/// be modified after init (they are set in Resource, which is immutable).
internal class GlobalAttributesSpanProcessor: SpanProcessor {
    var isStartRequired: Bool = true
    var isEndRequired: Bool = false
    
    private weak var pulseKit: PulseKit?

    init(pulseKit: PulseKit) {
        self.pulseKit = pulseKit
    }
    
    func onStart(parentContext: SpanContext?, span: ReadableSpan) {
        guard let pulseKit = pulseKit else { return }
        
        pulseKit.userPropertiesQueue.sync {
            if let userId = pulseKit._userId {
                span.setAttribute(key: "user.id", value: AttributeValue.string(userId))
            }
            
            for (key, value) in pulseKit._userProperties {
                if let attrValue = pulseKit.attributeValue(from: value) {
                    span.setAttribute(key: "pulse.user.\(key)", value: attrValue)
                }
            }
        }
    }
    
    func onEnd(span: any OpenTelemetrySdk.ReadableSpan) {
    }
    
    func shutdown(explicitTimeout: TimeInterval?) {
    }
    
    func forceFlush(timeout: TimeInterval?) {
    }
}

