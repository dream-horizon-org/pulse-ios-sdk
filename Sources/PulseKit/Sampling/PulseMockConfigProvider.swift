/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Provides hardcoded PulseSdkConfig for dev/testing. Use with PulseSdkConfigCoordinator(useLocalMockConfig: true).
 * Do NOT commit useLocalMockConfig = true in production code.
 */

import Foundation

/// Static factory for a complete PulseSdkConfig with realistic metricsToAdd entries for dev/testing.
public enum PulseMockConfigProvider {
    /// Returns a full PulseSdkConfig with metricsToAdd: counter for span names, histogram for http.duration, etc.
    /// Used when useLocalMockConfig is true in PulseSdkConfigCoordinator.
    public static func fullMockConfig() -> PulseSdkConfig {
        PulseSdkConfig(
            version: 999,
            description: "Local mock config for dev/testing",
            sampling: PulseSamplingConfig(
                default: PulseDefaultSamplingConfig(sessionSampleRate: 1.0),
                rules: [],
                criticalEventPolicies: nil,
                criticalSessionPolicies: nil
            ),
            signals: PulseSignalConfig(
                scheduleDurationMs: 60_000,
                logsCollectorUrl: "http://127.0.0.1:4318/v1/logs",
                metricCollectorUrl: "http://127.0.0.1:4318/v1/metrics",
                spanCollectorUrl: "http://127.0.0.1:4318/v1/traces",
                customEventCollectorUrl: "http://127.0.0.1:4318/v1/logs",
                attributesToDrop: [],
                attributesToAdd: [],
                metricsToAdd: makeMockMetricsToAdd(),
                filters: PulseSignalFilter(mode: .whitelist, values: [.allMatchLogCondition])
            ),
            interaction: PulseInteractionConfig(
                collectorUrl: "https://mock.example.com",
                configUrl: "http://127.0.0.1:8080/v1/interaction-configs/",
                beforeInitQueueSize: 100
            ),
            features: makeMockFeaturesAllEnabled()
        )
    }

    /// All features enabled (sessionSampleRate 1) for pulse_ios_swift and pulse_ios_rn.
    private static func makeMockFeaturesAllEnabled() -> [PulseFeatureConfig] {
        let sdks: [PulseSdkName] = [.pulse_ios_swift, .pulse_ios_rn]
        return PulseFeatureName.allCases
            .filter { $0 != .unknown }
            .map { PulseFeatureConfig(featureName: $0, sessionSampleRate: 1, sdks: sdks) }
    }

    private static func makeMockMetricsToAdd() -> [PulseMetricsToAddEntry] {
        [
            // Counter on span name - counts all spans matching .*
            PulseMetricsToAddEntry(
                name: "span_count",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift, .pulse_ios_rn]
                ),
                data: .counter
            ),
            // Histogram on http.duration attribute
            PulseMetricsToAddEntry(
                name: "http_duration",
                target: .attribute(
                    condition: PulseSignalMatchCondition(
                        name: ".*",
                        props: [PulseProp(name: "http.duration", value: ".*")],
                        scopes: [.traces],
                        sdks: [.pulse_ios_swift, .pulse_ios_rn]
                    ),
                    addPropNameAsSuffix: false
                ),
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift, .pulse_ios_rn]
                ),
                data: .histogram(bucket: [50, 100, 250, 500, 1000], isFraction: true)
            ),
            // Counter on log body - counts logs
            PulseMetricsToAddEntry(
                name: "log_count",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.logs],
                    sdks: [.pulse_ios_swift, .pulse_ios_rn]
                ),
                data: .counter
            ),
        ]
    }
}
