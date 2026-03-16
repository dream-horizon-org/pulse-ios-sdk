/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import XCTest
@testable import OpenTelemetrySdk
import OpenTelemetryApi
@testable import PulseKit

final class ConsentSpanExporterTests: XCTestCase {

    func testAllowed_forwardsToDelegate() {
        let mock = MockSpanExporter()
        var state = PulseDataCollectionConsent.allowed
        let exporter = ConsentSpanExporter(delegate: mock, getState: { state })

        let span = createSpan(name: "s1")
        let result = exporter.export(spans: [span], explicitTimeout: nil)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(mock.exportedSpans.count, 1)
        XCTAssertEqual(mock.exportedSpans[0].name, "s1")
    }

    func testDenied_dropsAndReturnsSuccess() {
        let mock = MockSpanExporter()
        var state = PulseDataCollectionConsent.denied
        let exporter = ConsentSpanExporter(delegate: mock, getState: { state })

        let result = exporter.export(spans: [createSpan(name: "s1")], explicitTimeout: nil)

        XCTAssertEqual(result, .success)
        XCTAssertTrue(mock.exportedSpans.isEmpty)
    }

    func testPending_buffersDoesNotForward() {
        let mock = MockSpanExporter()
        var state = PulseDataCollectionConsent.pending
        let exporter = ConsentSpanExporter(delegate: mock, getState: { state })

        let result = exporter.export(spans: [createSpan(name: "s1")], explicitTimeout: nil)

        XCTAssertEqual(result, .success)
        XCTAssertTrue(mock.exportedSpans.isEmpty)
    }

    func testPending_thenFlushBuffer_forwardsBuffered() {
        let mock = MockSpanExporter()
        var state = PulseDataCollectionConsent.pending
        let exporter = ConsentSpanExporter(delegate: mock, getState: { state })

        _ = exporter.export(spans: [createSpan(name: "buffered")], explicitTimeout: nil)
        XCTAssertTrue(mock.exportedSpans.isEmpty)

        state = .allowed
        exporter.flushBuffer()

        XCTAssertEqual(mock.exportedSpans.count, 1)
        XCTAssertEqual(mock.exportedSpans[0].name, "buffered")
    }

    func testClearBuffer_clearsWithoutForwarding() {
        let mock = MockSpanExporter()
        var state = PulseDataCollectionConsent.pending
        let exporter = ConsentSpanExporter(delegate: mock, getState: { state })

        _ = exporter.export(spans: [createSpan(name: "s1")], explicitTimeout: nil)
        exporter.clearBuffer()
        state = .allowed
        exporter.flushBuffer()

        XCTAssertTrue(mock.exportedSpans.isEmpty)
    }

    func testFlush_whenAllowed_forwardsToDelegate() {
        let mock = MockSpanExporter()
        var state = PulseDataCollectionConsent.allowed
        let exporter = ConsentSpanExporter(delegate: mock, getState: { state })

        let result = exporter.flush(explicitTimeout: nil)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(mock.flushCallCount, 1)
    }

    func testFlush_whenPending_doesNotForward() {
        let mock = MockSpanExporter()
        var state = PulseDataCollectionConsent.pending
        let exporter = ConsentSpanExporter(delegate: mock, getState: { state })

        _ = exporter.flush(explicitTimeout: nil)

        XCTAssertEqual(mock.flushCallCount, 0)
    }

    func testFlushBuffer_emptyBuffer_noOp() {
        let mock = MockSpanExporter()
        let state = PulseDataCollectionConsent.allowed
        let exporter = ConsentSpanExporter(delegate: mock, getState: { state })

        exporter.flushBuffer()

        XCTAssertTrue(mock.exportedSpans.isEmpty)
    }

    // MARK: - Helpers

    private func createSpan(name: String) -> SpanData {
        var spanData = SpanData(
            traceId: TraceId.random(),
            spanId: SpanId.random(),
            name: name,
            kind: .internal,
            startTime: Date(),
            endTime: Date().addingTimeInterval(0.1)
        )
        spanData.settingHasEnded(true)
        spanData.settingTotalRecordedEvents(0)
        spanData.settingTotalRecordedLinks(0)
        spanData.settingLinks([])
        spanData.settingStatus(.ok)
        return spanData
    }
}

private class MockSpanExporter: SpanExporter {
    var exportedSpans: [SpanData] = []
    var flushCallCount = 0

    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        exportedSpans.append(contentsOf: spans)
        return .success
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        flushCallCount += 1
        return .success
    }

    func shutdown(explicitTimeout: TimeInterval?) {}
}
