/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tests for Phase 3: sanitizeMetricName, createMeter, getMetricsToAddConfig.
 */

import XCTest
import OpenTelemetryApi
@testable import OpenTelemetrySdk
@testable import PulseKit

final class PulseMetricCreationTests: XCTestCase {

    // MARK: - sanitizeMetricName

    func testSanitizeMetricNameAllowsValidChars() {
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: "my_metric.name-1/2"), "my_metric.name-1/2")
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: "valid"), "valid")
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: "a"), "a")
    }

    func testSanitizeMetricNameStripsInvalidChars() {
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: "my metric"), "my_metric")
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: "a@b#c"), "a_b_c")
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: "space and-dot.ok"), "space_and-dot.ok")
    }

    func testSanitizeMetricNameMustStartWithLetter() {
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: "123"), "m123")
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: "_leading"), "m_leading")
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: ".leading"), "m.leading")
    }

    func testSanitizeMetricNameTruncatesAt255() {
        let long = String(repeating: "a", count: 300)
        let result = PulseOtelUtils.sanitizeMetricName(name: long)
        XCTAssertEqual(result.count, 255)
        XCTAssertEqual(result, String(repeating: "a", count: 255))
    }

    func testSanitizeMetricNameEmptyAndSingleChar() {
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: ""), "m")
        XCTAssertEqual(PulseOtelUtils.sanitizeMetricName(name: "x"), "x")
    }

    // MARK: - getMetricsToAddConfig filtering

    func testGetMetricsToAddConfigFiltersByScopeAndSdk() {
        let entry = PulseMetricsToAddEntry(
            name: "test_counter",
            target: .name,
            condition: PulseSignalMatchCondition(
                name: ".*",
                props: [],
                scopes: [.traces],
                sdks: [.pulse_ios_swift]
            ),
            data: .counter(isMonotonic: true, isFraction: false),
            attributesToPick: []
        )
        let config = makeSdkConfig(metricsToAdd: [entry])
        let processors = PulseSamplingSignalProcessors(
            sdkConfig: config,
            currentSdkName: .pulse_ios_swift,
            sessionParser: AlwaysOnSessionParser(),
            randomGenerator: { 0 }
        )
        let tracesConfig = processors.getMetricsToAddConfig(scope: .traces)
        let logsConfig = processors.getMetricsToAddConfig(scope: .logs)
        XCTAssertEqual(tracesConfig.count, 1)
        XCTAssertEqual(logsConfig.count, 0)
    }

    func testGetMetricsToAddConfigExcludesOtherSdks() {
        let entry = PulseMetricsToAddEntry(
            name: "android_only",
            target: .name,
            condition: PulseSignalMatchCondition(
                name: ".*",
                props: [],
                scopes: [.traces],
                sdks: [.pulse_android_java]
            ),
            data: .counter(isMonotonic: true, isFraction: false),
            attributesToPick: []
        )
        let config = makeSdkConfig(metricsToAdd: [entry])
        let processors = PulseSamplingSignalProcessors(
            sdkConfig: config,
            currentSdkName: .pulse_ios_swift,
            sessionParser: AlwaysOnSessionParser(),
            randomGenerator: { 0 }
        )
        let tracesConfig = processors.getMetricsToAddConfig(scope: .traces)
        XCTAssertEqual(tracesConfig.count, 0)
    }

    // MARK: - createMeter with MetricExporterMock

    func testCreateMeterCounterMonotonicLong() {
        let (processors, mock, provider) = makeProcessorsWithMockExporter(metricsToAdd: [
            PulseMetricsToAddEntry(
                name: "span_count",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                ),
                data: .counter(isMonotonic: true, isFraction: false),
                attributesToPick: []
            ),
        ])
        let config = processors.getMetricsToAddConfig(scope: .traces)
        XCTAssertEqual(config.count, 1)
        let (_, recorder) = config[0]
        recorder("ignored_name")
        recorder(nil as String?)
        _ = provider.forceFlush()
        let metrics = mock.exportedMetrics
        let counterMetric = metrics.first { $0.name == "span_count" }
        XCTAssertNotNil(counterMetric)
        if let sumData = counterMetric?.data as? SumData,
           let point = sumData.points.first as? LongPointData {
            XCTAssertEqual(sumData.points.count, 1)
            XCTAssertEqual(point.value, 2)
        } else {
            XCTFail("Expected SumData with LongPointData for counter")
        }
    }

    func testCreateMeterCounterMonotonicDouble() {
        let (processors, mock, provider) = makeProcessorsWithMockExporter(metricsToAdd: [
            PulseMetricsToAddEntry(
                name: "span_count_d",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                ),
                data: .counter(isMonotonic: true, isFraction: true),
                attributesToPick: []
            ),
        ])
        let config = processors.getMetricsToAddConfig(scope: .traces)
        let (_, recorder) = config[0]
        recorder("name")
        _ = provider.forceFlush()
        let metrics = mock.exportedMetrics
        let m = metrics.first { $0.name == "span_count_d" }
        XCTAssertNotNil(m)
        if let sumData = m?.data as? SumData,
           let point = sumData.points.first as? DoublePointData {
            XCTAssertEqual(sumData.points.count, 1)
            XCTAssertEqual(point.value, 1.0)
        }
    }

    func testCreateMeterUpDownCounter() {
        let (processors, mock, provider) = makeProcessorsWithMockExporter(metricsToAdd: [
            PulseMetricsToAddEntry(
                name: "up_down",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                ),
                data: .counter(isMonotonic: false, isFraction: false),
                attributesToPick: []
            ),
        ])
        let config = processors.getMetricsToAddConfig(scope: .traces)
        let (_, recorder) = config[0]
        recorder("event")
        _ = provider.forceFlush()
        let metrics = mock.exportedMetrics
        XCTAssertTrue(metrics.contains { $0.name == "up_down" })
    }

    func testCreateMeterGaugeDouble() {
        let (processors, mock, provider) = makeProcessorsWithMockExporter(metricsToAdd: [
            PulseMetricsToAddEntry(
                name: "gauge_val",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                ),
                data: .gauge(isFraction: true),
                attributesToPick: []
            ),
        ])
        let config = processors.getMetricsToAddConfig(scope: .traces)
        let (_, recorder) = config[0]
        recorder("42.5")
        _ = provider.forceFlush()
        let metrics = mock.exportedMetrics
        let m = metrics.first { $0.name == "gauge_val" }
        XCTAssertNotNil(m)
        if let gaugeData = m?.data as? GaugeData,
           let point = gaugeData.points.first as? DoublePointData {
            XCTAssertEqual(gaugeData.points.count, 1)
            XCTAssertEqual(point.value, 42.5)
        }
    }

    func testCreateMeterGaugeLong() {
        let (processors, mock, provider) = makeProcessorsWithMockExporter(metricsToAdd: [
            PulseMetricsToAddEntry(
                name: "gauge_long",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                ),
                data: .gauge(isFraction: false),
                attributesToPick: []
            ),
        ])
        let config = processors.getMetricsToAddConfig(scope: .traces)
        let (_, recorder) = config[0]
        recorder("100")
        _ = provider.forceFlush()
        let metrics = mock.exportedMetrics
        let m = metrics.first { $0.name == "gauge_long" }
        XCTAssertNotNil(m)
        if let gaugeData = m?.data as? GaugeData,
           let point = gaugeData.points.first as? LongPointData {
            XCTAssertEqual(gaugeData.points.count, 1)
            XCTAssertEqual(point.value, 100)
        }
    }

    func testCreateMeterHistogramWithBuckets() {
        let (processors, mock, provider) = makeProcessorsWithMockExporter(metricsToAdd: [
            PulseMetricsToAddEntry(
                name: "hist_buckets",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                ),
                data: .histogram(bucket: [1.0, 5.0, 10.0], isFraction: true),
                attributesToPick: []
            ),
        ])
        let config = processors.getMetricsToAddConfig(scope: .traces)
        let (_, recorder) = config[0]
        recorder("3.5")
        _ = provider.forceFlush()
        let metrics = mock.exportedMetrics
        XCTAssertTrue(metrics.contains { $0.name == "hist_buckets" })
    }

    func testCreateMeterHistogramNoBuckets() {
        let (processors, mock, provider) = makeProcessorsWithMockExporter(metricsToAdd: [
            PulseMetricsToAddEntry(
                name: "hist_no_buckets",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                ),
                data: .histogram(bucket: nil, isFraction: true),
                attributesToPick: []
            ),
        ])
        let config = processors.getMetricsToAddConfig(scope: .traces)
        let (_, recorder) = config[0]
        recorder("7.0")
        _ = provider.forceFlush()
        let metrics = mock.exportedMetrics
        XCTAssertTrue(metrics.contains { $0.name == "hist_no_buckets" })
    }

    func testCreateMeterSum() {
        let (processors, mock, provider) = makeProcessorsWithMockExporter(metricsToAdd: [
            PulseMetricsToAddEntry(
                name: "sum_val",
                target: .name,
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                ),
                data: .sum(isFraction: true),
                attributesToPick: []
            ),
        ])
        let config = processors.getMetricsToAddConfig(scope: .traces)
        let (_, recorder) = config[0]
        recorder("12.5")
        _ = provider.forceFlush()
        let metrics = mock.exportedMetrics
        let m = metrics.first { $0.name == "sum_val" }
        XCTAssertNotNil(m)
        if let sumData = m?.data as? SumData,
           let point = sumData.points.first as? DoublePointData {
            XCTAssertEqual(sumData.points.count, 1)
            XCTAssertEqual(point.value, 12.5)
        }
    }

    // MARK: - Helpers

    private func makeSdkConfig(metricsToAdd: [PulseMetricsToAddEntry] = []) -> PulseSdkConfig {
        PulseSdkConfig(
            version: 1,
            description: "test",
            sampling: PulseSamplingConfig(
                default: PulseDefaultSamplingConfig(sessionSampleRate: 0.5),
                rules: [],
                criticalEventPolicies: nil,
                criticalSessionPolicies: nil
            ),
            signals: PulseSignalConfig(
                scheduleDurationMs: 60_000,
                logsCollectorUrl: "https://logs",
                metricCollectorUrl: "https://metrics",
                spanCollectorUrl: "https://spans",
                customEventCollectorUrl: "https://custom",
                attributesToDrop: [],
                attributesToAdd: [],
                metricsToAdd: metricsToAdd,
                filters: PulseSignalFilter(mode: .blacklist, values: [])
            ),
            interaction: PulseInteractionConfig(
                collectorUrl: "https://interaction",
                configUrl: "https://config",
                beforeInitQueueSize: 100
            ),
            features: []
        )
    }

    private func makeProcessorsWithMockExporter(
        metricsToAdd: [PulseMetricsToAddEntry]
    ) -> (PulseSamplingSignalProcessors, MetricExporterMock, MeterProviderSdk) {
        let mock = MetricExporterMock()
        let provider = MeterProviderSdk.builder()
            .registerMetricReader(
                reader: PeriodicMetricReaderBuilder(exporter: mock)
                    .setInterval(timeInterval: 1)
                    .build()
            )
            .registerView(
                selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
                view: View.builder().build()
            )
            .build()
        let config = makeSdkConfig(metricsToAdd: metricsToAdd)
        let processors = PulseSamplingSignalProcessors(
            sdkConfig: config,
            currentSdkName: .pulse_ios_swift,
            sessionParser: AlwaysOnSessionParser(),
            randomGenerator: { 0 },
            meterProviderForMetricsToAdd: provider
        )
        return (processors, mock, provider)
    }

}

// MARK: - MetricExporterMock

private final class MetricExporterMock: MetricExporter {
    var exportedMetrics: [MetricData] = []

    func export(metrics: [MetricData]) -> ExportResult {
        exportedMetrics.append(contentsOf: metrics)
        return .success
    }

    func flush() -> ExportResult { .success }
    func shutdown() -> ExportResult { .success }
    func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { .cumulative }
    func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation { SumAggregation() }
}
