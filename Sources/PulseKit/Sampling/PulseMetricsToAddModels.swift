/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Config models for metricsToAdd: what metrics to derive from spans/logs.
 * JSON structure matches API/Confluence spec.
 * Includes Confluence additions: attributesToPick, addPropNameAsSuffix.
 */

import Foundation

// MARK: - Metrics To Add Entry

/// Defines a metric to derive from signals (spans/logs) that match the condition.
/// When a signal matches, the target value is recorded into the metric instrument.
public struct PulseMetricsToAddEntry: Codable, Equatable {
    /// Name of the OTel metric to emit. Will be sanitized automatically.
    public let name: String
    /// What value from the signal is used as the data point (name or attribute).
    public let target: PulseMetricsToAddTarget
    /// When to apply this metric — which signal name, attributes, scopes, and SDKs to match.
    public let condition: PulseSignalMatchCondition
    /// The kind of OTel instrument to create (Counter, Gauge, Histogram, Sum).
    public let data: PulseMetricsData
    /// Optional list of conditions specifying which signal attributes to attach to the emitted metric data point.
    public let attributesToPick: [PulseSignalMatchCondition]

    enum CodingKeys: String, CodingKey {
        case name
        case target
        case condition
        case type
        case attributesToPick
    }

    public init(
        name: String,
        target: PulseMetricsToAddTarget,
        condition: PulseSignalMatchCondition,
        data: PulseMetricsData,
        attributesToPick: [PulseSignalMatchCondition] = []
    ) {
        self.name = name
        self.target = target
        self.condition = condition
        self.data = data
        self.attributesToPick = attributesToPick
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        target = try c.decode(PulseMetricsToAddTarget.self, forKey: .target)
        condition = try c.decode(PulseSignalMatchCondition.self, forKey: .condition)
        data = try c.decode(PulseMetricsData.self, forKey: .type)
        attributesToPick = (try? c.decode([PulseSignalMatchCondition].self, forKey: .attributesToPick)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(target, forKey: .target)
        try c.encode(condition, forKey: .condition)
        try c.encode(data, forKey: .type)
        if !attributesToPick.isEmpty {
            try c.encode(attributesToPick, forKey: .attributesToPick)
        }
    }
}

// MARK: - Metrics To Add Target

/// Controls what value is fed into the metric instrument when a signal matches.
public enum PulseMetricsToAddTarget: Codable, Equatable {
    /// The name of the signal (span name or log body) is used as the data point.
    /// JSON: `"target": "name"` or `"target": { "type": "name" }`
    case name

    /// A specific attribute value on the signal is used. The attribute is identified by the condition.
    /// When true, different metrics are emitted per matched attribute key; final metric name = `<name>.<key_name_of_the_prop_matched>`.
    /// When false, all matching values are aggregated into one metric.
    /// JSON: `"target": { "attribute": {...} }` — canonical key is `shouldAddPropNameAsSuffix`; `addPropNameAsSuffix` accepted for backwards compatibility.
    case attribute(condition: PulseSignalMatchCondition, addPropNameAsSuffix: Bool)

    private enum TargetObjectKeys: String, CodingKey {
        case type
        case attribute
    }

    private enum AttributeInnerKeys: String, CodingKey {
        case condition
        case addPropNameAsSuffix
        case shouldAddPropNameAsSuffix
    }

    public init(from decoder: Decoder) throws {
        // Legacy: string "name"
        if let stringValue = try? decoder.singleValueContainer().decode(String.self) {
            if stringValue == "name" {
                self = .name
                return
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "target string must be \"name\", got \"\(stringValue)\"")
            )
        }

        // Object: { "type": "name" } or { "type": "attribute", "attribute": {...} } or { "attribute": {...} }
        let c = try decoder.container(keyedBy: TargetObjectKeys.self)
        if let typeStr = try? c.decode(String.self, forKey: .type) {
            if typeStr == "name" {
                self = .name
                return
            }
            if typeStr == "attribute" {
                let inner = try c.nestedContainer(keyedBy: AttributeInnerKeys.self, forKey: .attribute)
                let condition = try inner.decode(PulseSignalMatchCondition.self, forKey: .condition)
                // Canonical: shouldAddPropNameAsSuffix; addPropNameAsSuffix supported for backwards compatibility
                let addPropNameAsSuffix = (try? inner.decode(Bool.self, forKey: .shouldAddPropNameAsSuffix))
                    ?? (try? inner.decode(Bool.self, forKey: .addPropNameAsSuffix))
                    ?? false
                self = .attribute(condition: condition, addPropNameAsSuffix: addPropNameAsSuffix)
                return
            }
        }

        // Legacy: { "attribute": { "condition": ..., "shouldAddPropNameAsSuffix" / "addPropNameAsSuffix": ... } } without top-level type
        if c.contains(.attribute) {
            let inner = try c.nestedContainer(keyedBy: AttributeInnerKeys.self, forKey: .attribute)
            let condition = try inner.decode(PulseSignalMatchCondition.self, forKey: .condition)
            let addPropNameAsSuffix = (try? inner.decode(Bool.self, forKey: .shouldAddPropNameAsSuffix))
                ?? (try? inner.decode(Bool.self, forKey: .addPropNameAsSuffix))
                ?? false
            self = .attribute(condition: condition, addPropNameAsSuffix: addPropNameAsSuffix)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "target must be \"name\", { \"type\": \"name\" }, or { \"attribute\": {...} }")
        )
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .name:
            var container = encoder.singleValueContainer()
            try container.encode("name")
        case .attribute(let condition, let addPropNameAsSuffix):
            var c = encoder.container(keyedBy: TargetObjectKeys.self)
            var inner = c.nestedContainer(keyedBy: AttributeInnerKeys.self, forKey: .attribute)
            try inner.encode(condition, forKey: .condition)
            try inner.encode(addPropNameAsSuffix, forKey: .shouldAddPropNameAsSuffix)
        }
    }
}

// MARK: - Metrics Data (Instrument Type)

/// The kind of OTel instrument to create. Maps to Counter, Gauge, Histogram, Sum.
/// Counter always counts occurrences (add 1 per match); no isMonotonic/isFraction in payload.
public enum PulseMetricsData: Codable, Equatable {
    case counter
    case gauge(isFraction: Bool)
    case histogram(bucket: [Double]?, isFraction: Bool)
    case sum(isFraction: Bool, isMonotonic: Bool)

    private enum CodingKeys: String, CodingKey {
        case counter
        case gauge
        case histogram
        case sum
    }

    private enum CounterKeys: String, CodingKey {
        case type
    }

    private enum GaugeKeys: String, CodingKey {
        case isFraction
    }

    private enum HistogramKeys: String, CodingKey {
        case bucket
        case isFraction
    }

    private enum SumKeys: String, CodingKey {
        case isFraction
        case isMonotonic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if (try? c.nestedContainer(keyedBy: CounterKeys.self, forKey: .counter)) != nil {
            self = .counter
            return
        }

        if let inner = try? c.nestedContainer(keyedBy: GaugeKeys.self, forKey: .gauge) {
            let isFraction = (try? inner.decode(Bool.self, forKey: .isFraction)) ?? false
            self = .gauge(isFraction: isFraction)
            return
        }

        if let inner = try? c.nestedContainer(keyedBy: HistogramKeys.self, forKey: .histogram) {
            let bucket = try? inner.decode([Double].self, forKey: .bucket)
            let isFraction = (try? inner.decode(Bool.self, forKey: .isFraction)) ?? false
            self = .histogram(bucket: bucket, isFraction: isFraction)
            return
        }

        if let inner = try? c.nestedContainer(keyedBy: SumKeys.self, forKey: .sum) {
            let isFraction = (try? inner.decode(Bool.self, forKey: .isFraction)) ?? false
            let isMonotonic = (try? inner.decode(Bool.self, forKey: .isMonotonic)) ?? true
            self = .sum(isFraction: isFraction, isMonotonic: isMonotonic)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "PulseMetricsData must have counter, gauge, histogram, or sum")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .counter:
            _ = c.nestedContainer(keyedBy: CounterKeys.self, forKey: .counter)
        case .gauge(let isFraction):
            var inner = c.nestedContainer(keyedBy: GaugeKeys.self, forKey: .gauge)
            try inner.encode(isFraction, forKey: .isFraction)
        case .histogram(let bucket, let isFraction):
            var inner = c.nestedContainer(keyedBy: HistogramKeys.self, forKey: .histogram)
            try inner.encodeIfPresent(bucket, forKey: .bucket)
            try inner.encode(isFraction, forKey: .isFraction)
        case .sum(let isFraction, let isMonotonic):
            var inner = c.nestedContainer(keyedBy: SumKeys.self, forKey: .sum)
            try inner.encode(isFraction, forKey: .isFraction)
            try inner.encode(isMonotonic, forKey: .isMonotonic)
        }
    }
}
