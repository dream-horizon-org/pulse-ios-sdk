/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Config models for metricsToAdd: what metrics to derive from spans/logs.
 * JSON structure matches API/Confluence spec.
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
    /// JSON: `"target": "name"`
    case name

    /// A specific attribute value on the signal is used. The attribute is identified by the condition.
    /// When `addPropNameAsSuffix` is true, final metric name = `<name>.<key_name_of_the_prop_matched>`.
    /// JSON: `"target": { "attribute": { "condition": {...}, "addPropNameAsSuffix": true } }`
    case attribute(condition: PulseSignalMatchCondition, addPropNameAsSuffix: Bool)

    private enum AttributeCodingKeys: String, CodingKey {
        case attribute
    }

    private enum AttributeInnerKeys: String, CodingKey {
        case condition
        case addPropNameAsSuffix
    }

    public init(from decoder: Decoder) throws {
        // Can be string "name" or object { "attribute": { "condition": ..., "addPropNameAsSuffix": ... } }
        if let stringValue = try? decoder.singleValueContainer().decode(String.self) {
            if stringValue == "name" {
                self = .name
                return
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "target string must be \"name\", got \"\(stringValue)\"")
            )
        }

        let c = try decoder.container(keyedBy: AttributeCodingKeys.self)
        let inner = try c.nestedContainer(keyedBy: AttributeInnerKeys.self, forKey: .attribute)
        let condition = try inner.decode(PulseSignalMatchCondition.self, forKey: .condition)
        let addPropNameAsSuffix = (try? inner.decode(Bool.self, forKey: .addPropNameAsSuffix)) ?? false
        self = .attribute(condition: condition, addPropNameAsSuffix: addPropNameAsSuffix)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .name:
            var container = encoder.singleValueContainer()
            try container.encode("name")
        case .attribute(let condition, let addPropNameAsSuffix):
            var c = encoder.container(keyedBy: AttributeCodingKeys.self)
            var inner = c.nestedContainer(keyedBy: AttributeInnerKeys.self, forKey: .attribute)
            try inner.encode(condition, forKey: .condition)
            try inner.encode(addPropNameAsSuffix, forKey: .addPropNameAsSuffix)
        }
    }
}

// MARK: - Metrics Data (Instrument Type)

/// The kind of OTel instrument to create. Maps to Counter, Gauge, Histogram, Sum.
public enum PulseMetricsData: Codable, Equatable {
    case counter(isMonotonic: Bool, isFraction: Bool)
    case gauge(isFraction: Bool)
    case histogram(bucket: [Double]?, isFraction: Bool)
    case sum(isFraction: Bool)

    private enum CodingKeys: String, CodingKey {
        case counter
        case gauge
        case histogram
        case sum
    }

    private enum CounterKeys: String, CodingKey {
        case isMonotonic
        case isFraction
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
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let inner = try? c.nestedContainer(keyedBy: CounterKeys.self, forKey: .counter) {
            let isMonotonic = (try? inner.decode(Bool.self, forKey: .isMonotonic)) ?? true
            let isFraction = (try? inner.decode(Bool.self, forKey: .isFraction)) ?? false
            self = .counter(isMonotonic: isMonotonic, isFraction: isFraction)
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
            self = .sum(isFraction: isFraction)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "PulseMetricsData must have counter, gauge, histogram, or sum")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .counter(let isMonotonic, let isFraction):
            var inner = c.nestedContainer(keyedBy: CounterKeys.self, forKey: .counter)
            try inner.encode(isMonotonic, forKey: .isMonotonic)
            try inner.encode(isFraction, forKey: .isFraction)
        case .gauge(let isFraction):
            var inner = c.nestedContainer(keyedBy: GaugeKeys.self, forKey: .gauge)
            try inner.encode(isFraction, forKey: .isFraction)
        case .histogram(let bucket, let isFraction):
            var inner = c.nestedContainer(keyedBy: HistogramKeys.self, forKey: .histogram)
            try inner.encodeIfPresent(bucket, forKey: .bucket)
            try inner.encode(isFraction, forKey: .isFraction)
        case .sum(let isFraction):
            var inner = c.nestedContainer(keyedBy: SumKeys.self, forKey: .sum)
            try inner.encode(isFraction, forKey: .isFraction)
        }
    }
}
