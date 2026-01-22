/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
import OpenTelemetryApi

// PulseAttributes constants (copied here to avoid dependency on PulseKit)
// TODO: Ideally we should publish attributes as diffrence module like Android semconv module. 
internal enum PulseAttributes {
    static let pulseType = "pulse.type"
    static let pulseSpanId = "pulse.span.id"
    
    enum PulseTypeValues {
        static let network = "network"
        static let screenLoad = "screen_load"
        static let appStart = "app_start"
        static let screenSession = "screen_session"
        static func isNetworkType(_ pulseType: String) -> Bool {
            return pulseType == network || pulseType.hasPrefix("\(network).")
        }
    }
}

/// SpanProcessor that adds interaction attributes to spans and forwards span events to InteractionManager
internal class InteractionAttributesSpanAppender: SpanProcessor {
    /// Lazy access to interaction manager (accessed when onStart/onEnd is called, after install())
    private var interactionManager: InteractionManager? {
        guard let instrumentation = InteractionInstrumentation.getInstance() else {
            return nil
        }
        return instrumentation.managerInstance
    }
    
    var isStartRequired: Bool = true
    var isEndRequired: Bool = true
    
    /// Span pulse types that should be added as events to interactions
    /// Note: Network types are checked separately via isNetworkType() to handle "network.XXX" patterns
    private static let listOfSpanPulseTypeToAddInInteraction = [
        PulseAttributes.PulseTypeValues.screenLoad,
        PulseAttributes.PulseTypeValues.appStart,
        PulseAttributes.PulseTypeValues.screenSession
    ]
    
    init() {
        // Manager will be accessed lazily when onStart/onEnd is called
    }
    
    func onStart(parentContext: SpanContext?, span: ReadableSpan) {
        // Access manager lazily (will be available after install() is called)
        guard let manager = interactionManager else {
            return
        }
        
        // Add interaction attributes to span
        if let interactionAttrs = Self.createInteractionAttributes(manager) {
            interactionAttrs.forEach { key, value in
                span.setAttribute(key: key, value: value)
            }
        }
    }
    
    func onEnd(span: any OpenTelemetrySdk.ReadableSpan) {
        // Access manager lazily (will be available after install() is called)
        guard let manager = interactionManager else {
            return
        }
        
        // Get span data to access attributes and end time
        let spanData = span.toSpanData()
        
        // Check if span has a pulse type that should be added to interactions
        if let pulseTypeAttr = spanData.attributes[PulseAttributes.pulseType],
           case .string(let pulseTypeString) = pulseTypeAttr,
           Self.shouldAddToInteraction(pulseType: pulseTypeString) {
            
            var params: [String: Any?] = [:]
            // Add span ID (use span context directly)
            params[PulseAttributes.pulseSpanId] = span.context.spanId.hexString
            
            // Get span end time (convert from TimeInterval to nanoseconds)
            let endTimeNanos = Int64(spanData.endTime.timeIntervalSince1970 * 1_000_000_000)
            
            manager.addEvent(
                eventName: pulseTypeString,
                params: params,
                eventTimeInNano: endTimeNanos
            )
        }
    }
    
    /// Check if a pulse type should be added to interactions
    /// Handles exact matches and network types (including "network.XXX" patterns)
    private static func shouldAddToInteraction(pulseType: String) -> Bool {
        // Check if it's a network type (handles both "network" and "network.XXX")
        if PulseAttributes.PulseTypeValues.isNetworkType(pulseType) {
            return true
        }
        
        // Check exact matches for other types
        return listOfSpanPulseTypeToAddInInteraction.contains(pulseType)
    }
    
    func shutdown(explicitTimeout: TimeInterval?) {
        // No cleanup needed
    }
    
    func forceFlush(timeout: TimeInterval?) {
        // No cleanup needed
    }
    
    /// Create interaction attributes from current running interactions
    static func createInteractionAttributes(_ manager: InteractionManager) -> [String: AttributeValue]? {
        let states = manager.currentStates
        let runningIds = states.compactMap { state -> String? in
            if case .ongoingMatch(_, let id, _, _) = state {
                return id
            }
            return nil
        }
        let runningNames = states.compactMap { state -> String? in
            if case .ongoingMatch(_, _, let config, _) = state {
                return config.name
            }
            return nil
        }
        
        guard !runningIds.isEmpty else {
            return nil
        }
        
        // Create string array attributes
        let namesValues = runningNames.map { AttributeValue.string($0) }
        let idsValues = runningIds.map { AttributeValue.string($0) }
        
        return [
            "pulse.interaction.names": AttributeValue.array(AttributeArray(values: namesValues)),
            "pulse.interaction.ids": AttributeValue.array(AttributeArray(values: idsValues))
        ]
    }
}

