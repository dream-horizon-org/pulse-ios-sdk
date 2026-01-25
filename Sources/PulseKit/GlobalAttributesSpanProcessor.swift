/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
import OpenTelemetryApi

/// Span processor that appends global attributes to every span.
/// 
/// Note: User properties (userId and userProperties) can be updated after initialization.
/// Static global attributes set during initialization are immutable after init.
internal class GlobalAttributesSpanProcessor: SpanProcessor {
    var isStartRequired: Bool = true
    var isEndRequired: Bool = false
    
    private weak var pulseKit: PulseKit?

    init(pulseKit: PulseKit) {
        self.pulseKit = pulseKit
    }
    
    func onStart(parentContext: SpanContext?, span: ReadableSpan) {
        guard let pulseKit = pulseKit else { return }
        
        var allAttributes: [String: AttributeValue] = [:]
        
        // Add static global attributes (set during initialization)
        if let globalAttributes = pulseKit._globalAttributes {
            allAttributes.merge(globalAttributes) { _, new in new }
        }
        
        // Add dynamic user properties (can be updated after initialization)
        if let userId = pulseKit.userSessionEmitter.userId {
            allAttributes[PulseAttributes.userId] = AttributeValue.string(userId)
        }
        
        for (key, value) in pulseKit.userSessionEmitter.userProperties {
            allAttributes[PulseAttributes.pulseUserParameter(key)] = value
        }
        
        // Set all attributes at once (uses extension method)
        if !allAttributes.isEmpty {
            span.setAttributes(allAttributes)
        }
    }
    
    func onEnd(span: any OpenTelemetrySdk.ReadableSpan) {
    }
    
    func shutdown(explicitTimeout: TimeInterval?) {
    }
    
    func forceFlush(timeout: TimeInterval?) {
    }
}

