/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Pulse sampling config models. JSON keys match API compatibility.
 * Validation: required fields are non-optional so decoding fails when the API payload is missing
 * them. Optional lists use (try? decode) ?? [].
 */

import Foundation

// MARK: - Supported config version

public enum PulseSdkConfigConstants {
    public static let currentSupportedConfigVersion = 1
}

// MARK: - API response wrapper

/// Wrapper for config API responses. When `error` is non-nil, treat as failure and ignore `data`.
public struct PulseApiResponse<T: Decodable>: Decodable {
    public let data: T?
    public let error: PulseApiError?

    enum CodingKeys: String, CodingKey {
        case data
        case error
    }
}

public struct PulseApiError: Decodable {
    public let code: String
    public let message: String
}

// MARK: - Root config

public struct PulseSdkConfig: Codable, Equatable {
    public let version: Int
    public let description: String
    public let sampling: PulseSamplingConfig
    public let signals: PulseSignalConfig
    public let interaction: PulseInteractionConfig
    public let features: [PulseFeatureConfig]

    public init(
        version: Int,
        description: String,
        sampling: PulseSamplingConfig,
        signals: PulseSignalConfig,
        interaction: PulseInteractionConfig,
        features: [PulseFeatureConfig]
    ) {
        self.version = version
        self.description = description
        self.sampling = sampling
        self.signals = signals
        self.interaction = interaction
        self.features = features
    }
}

// MARK: - Sampling

public struct PulseSamplingConfig: Codable, Equatable {
    public let `default`: PulseDefaultSamplingConfig
    public let rules: [PulseSessionSamplingRule]
    public let criticalEventPolicies: PulseCriticalEventPolicies?
    public let criticalSessionPolicies: PulseCriticalEventPolicies?

    enum CodingKeys: String, CodingKey {
        case `default` = "default"
        case rules
        case criticalEventPolicies
        case criticalSessionPolicies
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        `default` = try c.decode(PulseDefaultSamplingConfig.self, forKey: .default)
        rules = (try? c.decode([PulseSessionSamplingRule].self, forKey: .rules)) ?? []
        criticalEventPolicies = try? c.decodeIfPresent(PulseCriticalEventPolicies.self, forKey: .criticalEventPolicies)
        criticalSessionPolicies = try? c.decodeIfPresent(PulseCriticalEventPolicies.self, forKey: .criticalSessionPolicies)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`default`, forKey: .default)
        try c.encode(rules, forKey: .rules)
        try c.encodeIfPresent(criticalEventPolicies, forKey: .criticalEventPolicies)
        try c.encodeIfPresent(criticalSessionPolicies, forKey: .criticalSessionPolicies)
    }

    public init(default: PulseDefaultSamplingConfig, rules: [PulseSessionSamplingRule], criticalEventPolicies: PulseCriticalEventPolicies?, criticalSessionPolicies: PulseCriticalEventPolicies?) {
        self.default = `default`
        self.rules = rules
        self.criticalEventPolicies = criticalEventPolicies
        self.criticalSessionPolicies = criticalSessionPolicies
    }
}

public struct PulseDefaultSamplingConfig: Codable, Equatable {
    public let sessionSampleRate: Float

    public init(sessionSampleRate: Float) {
        self.sessionSampleRate = sessionSampleRate
    }
}

public struct PulseSessionSamplingRule: Codable, Equatable {
    public let name: PulseDeviceAttributeName
    public let value: String
    public let sdks: [PulseSdkName]
    public let sessionSampleRate: Float

    public init(name: PulseDeviceAttributeName, value: String, sdks: [PulseSdkName], sessionSampleRate: Float) {
        self.name = name
        self.value = value
        self.sdks = sdks
        self.sessionSampleRate = sessionSampleRate
    }
}

public struct PulseCriticalEventPolicies: Codable, Equatable {
    public let alwaysSend: [PulseSignalMatchCondition]

    public init(alwaysSend: [PulseSignalMatchCondition]) {
        self.alwaysSend = alwaysSend
    }
}

// MARK: - Signals

public struct PulseSignalConfig: Codable, Equatable {
    public let scheduleDurationMs: Int64
    public let logsCollectorUrl: String
    public let metricCollectorUrl: String
    public let spanCollectorUrl: String
    public let customEventCollectorUrl: String
    public let attributesToDrop: [PulseAttributesToDropEntry]
    public let attributesToAdd: [PulseAttributesToAddEntry]
    public let filters: PulseSignalFilter

    enum CodingKeys: String, CodingKey {
        case scheduleDurationMs
        case logsCollectorUrl
        case metricCollectorUrl
        case spanCollectorUrl
        case customEventCollectorUrl
        case attributesToDrop
        case attributesToAdd
        case filters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheduleDurationMs = try c.decode(Int64.self, forKey: .scheduleDurationMs)
        logsCollectorUrl = try c.decode(String.self, forKey: .logsCollectorUrl)
        metricCollectorUrl = try c.decode(String.self, forKey: .metricCollectorUrl)
        spanCollectorUrl = try c.decode(String.self, forKey: .spanCollectorUrl)
        customEventCollectorUrl = try c.decode(String.self, forKey: .customEventCollectorUrl)
        attributesToDrop = (try? c.decode([PulseAttributesToDropEntry].self, forKey: .attributesToDrop)) ?? []
        attributesToAdd = (try? c.decode([PulseAttributesToAddEntry].self, forKey: .attributesToAdd)) ?? []
        filters = try c.decode(PulseSignalFilter.self, forKey: .filters)
    }

    public init(
        scheduleDurationMs: Int64,
        logsCollectorUrl: String,
        metricCollectorUrl: String,
        spanCollectorUrl: String,
        customEventCollectorUrl: String,
        attributesToDrop: [PulseAttributesToDropEntry],
        attributesToAdd: [PulseAttributesToAddEntry],
        filters: PulseSignalFilter
    ) {
        self.scheduleDurationMs = scheduleDurationMs
        self.logsCollectorUrl = logsCollectorUrl
        self.metricCollectorUrl = metricCollectorUrl
        self.spanCollectorUrl = spanCollectorUrl
        self.customEventCollectorUrl = customEventCollectorUrl
        self.attributesToDrop = attributesToDrop
        self.attributesToAdd = attributesToAdd
        self.filters = filters
    }
}

public struct PulseSignalFilter: Codable, Equatable {
    public let mode: PulseSignalFilterMode
    public let values: [PulseSignalMatchCondition]

    public init(mode: PulseSignalFilterMode, values: [PulseSignalMatchCondition]) {
        self.mode = mode
        self.values = values
    }
}

// MARK: - Signal match condition (matchers)

public struct PulseSignalMatchCondition: Codable, Equatable {
    public let name: String
    public let props: [PulseProp]
    public let scopes: [PulseSignalScope]
    public let sdks: [PulseSdkName]

    enum CodingKeys: String, CodingKey {
        case name
        case props
        case scopes
        case sdks
    }

    public init(name: String, props: [PulseProp], scopes: [PulseSignalScope], sdks: [PulseSdkName]) {
        self.name = name
        self.props = props
        self.scopes = scopes
        self.sdks = sdks
    }

    /// Condition that matches any signal (for "catch-all" routing). Used by Batch 5 SelectedLogExporter.
    public static let allMatchLogCondition = PulseSignalMatchCondition(
        name: ".*",
        props: [],
        scopes: PulseSignalScope.allCases.filter { $0 != .unknown },
        sdks: PulseSdkName.allCases.filter { $0 != .unknown }
    )

    /// Condition that matches custom events (pulse.type == custom_event). Used by Batch 5 SelectedLogExporter.
    public static func customEventLogCondition(pulseTypeKey: String = "pulse.type", customEventValue: String = "custom_event") -> PulseSignalMatchCondition {
        PulseSignalMatchCondition(
            name: ".*",
            props: [PulseProp(name: pulseTypeKey, value: customEventValue)],
            scopes: PulseSignalScope.allCases.filter { $0 != .unknown },
            sdks: PulseSdkName.allCases.filter { $0 != .unknown }
        )
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        props = (try? c.decode([PulseProp].self, forKey: .props)) ?? []
        scopes = (try? c.decode([PulseSignalScope].self, forKey: .scopes)) ?? []
        sdks = (try? c.decode([PulseSdkName].self, forKey: .sdks)) ?? []
    }
}

public struct PulseProp: Codable, Equatable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

public struct PulseAttributesToAddEntry: Codable, Equatable {
    public let values: [PulseAttributeValue]
    public let condition: PulseSignalMatchCondition
}

public struct PulseAttributesToDropEntry: Codable, Equatable {
    public let values: [String]
    public let condition: PulseSignalMatchCondition
}

public struct PulseAttributeValue: Codable, Equatable {
    public let name: String
    public let value: String
    public let type: PulseAttributeType
}

// MARK: - Interaction

public struct PulseInteractionConfig: Codable, Equatable {
    public let collectorUrl: String
    public let configUrl: String
    public let beforeInitQueueSize: Int
}

// MARK: - Features

public struct PulseFeatureConfig: Codable, Equatable {
    public let featureName: PulseFeatureName
    public let sessionSampleRate: Float
    public let sdks: [PulseSdkName]
}

// MARK: - Enums (JSON string values match API compatibility)

public enum PulseSignalScope: String, Codable, CaseIterable {
    case logs
    case traces
    case metrics
    case baggage
    case unknown
}

public enum PulseSdkName: String, Codable, CaseIterable {
    case pulse_android_java = "pulse_android_java"
    case pulse_android_rn = "pulse_android_rn"
    case pulse_ios_swift = "pulse_ios_swift"
    case pulse_ios_rn = "pulse_ios_rn"
    case unknown = "unknown"

    public static func from(telemetrySdkName: String?) -> PulseSdkName {
        switch telemetrySdkName?.lowercased() {
        case PulseSdkName.pulse_android_java.rawValue: return .pulse_android_java
        case PulseSdkName.pulse_android_rn.rawValue: return .pulse_android_rn
        case PulseSdkName.pulse_ios_swift.rawValue: return .pulse_ios_swift
        case PulseSdkName.pulse_ios_rn.rawValue: return .pulse_ios_rn
        default: return .unknown
        }
    }
}

public enum PulseFeatureName: String, Codable, CaseIterable {
    case java_crash
    case js_crash
    case cpp_crash
    case java_anr
    case cpp_anr
    case interaction
    case network_change
    case network_instrumentation
    case screen_session
    case custom_events
    case rn_screen_load
    case rn_screen_interactive
    case ios_crash
    case unknown
}

public enum PulseDeviceAttributeName: String, Codable, CaseIterable {
    case os_version
    case app_version
    case country
    case state
    case platform
    case unknown
}

public enum PulseSignalFilterMode: String, Codable {
    case blacklist
    case whitelist
}

public enum PulseAttributeType: String, Codable {
    case string
    case boolean
    case long
    case double
    case string_array
    case boolean_array
    case long_array
    case double_array
}

