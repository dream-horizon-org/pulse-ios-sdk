/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Pulse sampling config models. JSON keys match Android @SerialName for API compatibility.
 * Validation: required fields are non-optional so decoding fails when the API payload is missing
 * them (same behaviour as Android Retrofit + kotlinx.serialization). Optional lists use (try? decode) ?? [].
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
}

public struct PulseSessionSamplingRule: Codable, Equatable {
    public let name: PulseDeviceAttributeName
    public let value: String
    public let sdks: [PulseSdkName]
    public let sessionSampleRate: Float
}

public struct PulseCriticalEventPolicies: Codable, Equatable {
    public let alwaysSend: [PulseSignalMatchCondition]
}

// MARK: - Signals

public struct PulseSignalConfig: Codable, Equatable {
    public let scheduleDurationMs: Int64
    public let logsCollectorUrl: String
    public let metricCollectorUrl: String
    public let spanCollectorUrl: String
    public let customEventCollectorUrl: String
    public let attributesToDrop: [PulseSignalMatchCondition]
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
        attributesToDrop = (try? c.decode([PulseSignalMatchCondition].self, forKey: .attributesToDrop)) ?? []
        attributesToAdd = (try? c.decode([PulseAttributesToAddEntry].self, forKey: .attributesToAdd)) ?? []
        filters = try c.decode(PulseSignalFilter.self, forKey: .filters)
    }
}

public struct PulseSignalFilter: Codable, Equatable {
    public let mode: PulseSignalFilterMode
    public let values: [PulseSignalMatchCondition]
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
}

public struct PulseAttributesToAddEntry: Codable, Equatable {
    public let values: [PulseAttributeValue]
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

// MARK: - Enums (JSON string values match Android)

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

