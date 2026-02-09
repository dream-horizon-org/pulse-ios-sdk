/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Interaction Instrumentation for tracking user flows across multiple events
/// 
/// This instrumentation listens to events tracked via PulseKit.trackEvent() and matches them
/// against server-configured interaction sequences. When a sequence completes, it creates
/// an OpenTelemetry span with timing and event data.
public class InteractionInstrumentation {
    // Static storage for instrumentation instance (for processor access)
    // Similar to Android's AndroidInstrumentationLoader
    private static var sharedInstance: InteractionInstrumentation?
    
    public static func getInstance() -> InteractionInstrumentation? {
        return sharedInstance
    }
    private var _configuration: InteractionInstrumentationConfiguration
    public var configuration: InteractionInstrumentationConfiguration {
        get {
            configurationQueue.sync { _configuration }
        }
        set {
            configurationQueue.sync { _configuration = newValue }
        }
    }

    private let configurationQueue = DispatchQueue(
        label: "io.opentelemetry.interaction.configuration")
    
    private lazy var interactionManager: InteractionManager = {
        let configFetcher: InteractionConfigFetcher = configuration.useMockFetcher
            ? InteractionConfigMockFetcher()
            : InteractionConfigRestFetcher(urlProvider: configuration.configUrlProvider)
        return InteractionManager(interactionFetcher: configFetcher)
    }()
    
    private var stateObservationTask: Task<Void, Never>?
    
    /// Attribute extractors for adding custom attributes to interaction spans
    /// Matches Android's additionalAttributeExtractors pattern
    private var attributeExtractors: [(Interaction) -> [String: AttributeValue]] = []

    public init(configuration: InteractionInstrumentationConfiguration) {
        self._configuration = configuration
        // Store instance for processor access (like Android's loader)
        InteractionInstrumentation.sharedInstance = self
    }
    
    // Expose manager for processor access (same instance)
    public var managerInstance: InteractionManager {
        return interactionManager
    }

    public func install() {
        attributeExtractors.append(defaultAttributeExtractor)
        registerSpanProcessor()
        Task {
            await interactionManager.initialize()
            stateObservationTask = Task {
                for await states in interactionManager.interactionTrackerStatesStream {
                    handleInteractionStates(states)
                }
            }
        }
    }
    
    /// Handle interaction state changes and create spans
    private func handleInteractionStates(_ states: [InteractionRunningStatus]) {
        for state in states {
            if case .ongoingMatch(_, _, let config, let interaction) = state,
               let interaction = interaction {
                // Interaction completed (success or error)
                createInteractionSpan(interaction: interaction, config: config)
            }
        }
    }
    
    /// Register SpanProcessor to add interaction attributes to spans
    /// Note: LogRecordProcessor is already registered during SDK initialization
    private func registerSpanProcessor() {
        let openTelemetry = OpenTelemetry.instance
        
        if let tracerProviderSdk = openTelemetry.tracerProvider as? TracerProviderSdk {
            let spanProcessor = InteractionAttributesSpanAppender()
            tracerProviderSdk.addSpanProcessor(spanProcessor)
        }
    }
    
    /// Default attribute extractor (matches Android's InteractionDefaultAttributesExtractor)
    private func defaultAttributeExtractor(interaction: Interaction) -> [String: AttributeValue] {
        var attributes = putAttributesFrom(interaction.props)
        
        // Add default interaction attributes (overrides props if present)
        attributes[InteractionAttributes.name] = AttributeValue.string(interaction.name)
        attributes[InteractionAttributes.id] = AttributeValue.string(interaction.id)
        attributes[InteractionAttributes.pulseType] = AttributeValue.string(InteractionAttributes.pulseTypeInteraction)
        
        return attributes
    }
    
    /// Create OpenTelemetry span for completed interaction
    private func createInteractionSpan(interaction: Interaction, config: InteractionConfig) {
        guard let timeSpan = interaction.timeSpanInNanos else {
            return
        }
        
        let openTelemetry = OpenTelemetry.instance
        let tracer = openTelemetry.tracerProvider.get(
            instrumentationName: "pulse.otel.interaction",
            instrumentationVersion: nil
        )
        
        // Create span builder
        let spanBuilder = tracer.spanBuilder(spanName: interaction.name)
            .setNoParent()
            .setStartTime(time: Date(timeIntervalSince1970: Double(timeSpan.start) / 1_000_000_000))
        
        // Apply all attribute extractors (matches Android's pattern)
        // Default extractor is added in install(), custom extractor from configuration
        // Note: configId is already in interaction.props, so it's included via default extractor
        var attributes: [String: AttributeValue] = [:]
        
        // Apply all extractors (default + custom)
        for extractor in attributeExtractors {
            let extractedAttrs = extractor(interaction)
            attributes.merge(extractedAttrs) { _, new in new }
        }
        
        // Apply custom extractor from configuration (if provided)
        if let attributeExtractor = configuration.attributeExtractor {
            let customAttrs = attributeExtractor(interaction)
            attributes.merge(customAttrs) { _, new in new }
        }
        
        // Start span
        let span = spanBuilder.startSpan()
        
        // Set attributes on the span
        for (key, value) in attributes {
            span.setAttribute(key: key, value: value)
        }
        
        // Add events as span events
        for event in interaction.events {
            let eventAttrs = event.props?.mapValues { AttributeValue.string($0) } ?? [:]
            span.addEvent(
                name: event.name,
                attributes: eventAttrs,
                timestamp: Date(timeIntervalSince1970: Double(event.timeInNano) / 1_000_000_000)
            )
        }
        
        // Add marker events
        for marker in interaction.markerEvents {
            let markerAttrs = marker.props?.mapValues { AttributeValue.string($0) } ?? [:]
            span.addEvent(
                name: marker.name,
                attributes: markerAttrs,
                timestamp: Date(timeIntervalSince1970: Double(marker.timeInNano) / 1_000_000_000)
            )
        }
        
        // Set span status
        if interaction.isErrored {
            span.status = Status.error(description: "Interaction timed out or was interrupted")
        }
        
        // End span
        span.end(time: Date(timeIntervalSince1970: Double(timeSpan.end) / 1_000_000_000))
    }
    
    /// Convert [String: Any?] to [String: AttributeValue]
    /// Matches Android's putAttributesFrom utility
    private func putAttributesFrom(_ map: [String: Any?]) -> [String: AttributeValue] {
        var attributes: [String: AttributeValue] = [:]
        
        for (key, value) in map {
            // Skip internal properties that shouldn't be added as attributes
            if key == InteractionAttributes.localEvents || 
               key == InteractionAttributes.markerEvents {
                continue
            }
            
            // Convert value to AttributeValue
            if let stringValue = value as? String {
                attributes[key] = AttributeValue.string(stringValue)
            } else if let intValue = value as? Int {
                attributes[key] = AttributeValue.int(intValue)
            } else if let int64Value = value as? Int64 {
                attributes[key] = AttributeValue.int(Int(int64Value))
            } else if let doubleValue = value as? Double {
                attributes[key] = AttributeValue.double(doubleValue)
            } else if let boolValue = value as? Bool {
                attributes[key] = AttributeValue.bool(boolValue)
            } else if value == nil {
                // Skip nil values
                continue
            } else {
                // Convert to string for other types
                attributes[key] = AttributeValue.string(String(describing: value))
            }
        }
        
        return attributes
    }
    
    deinit {
        stateObservationTask?.cancel()
    }
}

