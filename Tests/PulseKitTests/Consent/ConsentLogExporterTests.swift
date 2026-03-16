/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import XCTest
@testable import OpenTelemetrySdk
import OpenTelemetryApi
@testable import PulseKit

final class ConsentLogExporterTests: XCTestCase {

    func testAllowed_forwardsToDelegate() {
        let mock = MockLogExporter()
        var state = PulseDataCollectionConsent.allowed
        let exporter = ConsentLogExporter(delegate: mock, getState: { state })

        let log = createLog(eventName: "e1")
        let result = exporter.export(logRecords: [log], explicitTimeout: nil)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(mock.exportedLogs.count, 1)
        XCTAssertEqual(mock.exportedLogs[0].eventName, "e1")
    }

    func testDenied_dropsAndReturnsSuccess() {
        let mock = MockLogExporter()
        var state = PulseDataCollectionConsent.denied
        let exporter = ConsentLogExporter(delegate: mock, getState: { state })

        let result = exporter.export(logRecords: [createLog(eventName: "e1")], explicitTimeout: nil)

        XCTAssertEqual(result, .success)
        XCTAssertTrue(mock.exportedLogs.isEmpty)
    }

    func testPending_buffersDoesNotForward() {
        let mock = MockLogExporter()
        var state = PulseDataCollectionConsent.pending
        let exporter = ConsentLogExporter(delegate: mock, getState: { state })

        let result = exporter.export(logRecords: [createLog(eventName: "e1")], explicitTimeout: nil)

        XCTAssertEqual(result, .success)
        XCTAssertTrue(mock.exportedLogs.isEmpty)
    }

    func testPending_thenFlushBuffer_forwardsBuffered() {
        let mock = MockLogExporter()
        var state = PulseDataCollectionConsent.pending
        let exporter = ConsentLogExporter(delegate: mock, getState: { state })

        _ = exporter.export(logRecords: [createLog(eventName: "buffered")], explicitTimeout: nil)
        XCTAssertTrue(mock.exportedLogs.isEmpty)

        state = .allowed
        exporter.flushBuffer()

        XCTAssertEqual(mock.exportedLogs.count, 1)
        XCTAssertEqual(mock.exportedLogs[0].eventName, "buffered")
    }

    func testClearBuffer_clearsWithoutForwarding() {
        let mock = MockLogExporter()
        var state = PulseDataCollectionConsent.pending
        let exporter = ConsentLogExporter(delegate: mock, getState: { state })

        _ = exporter.export(logRecords: [createLog(eventName: "e1")], explicitTimeout: nil)
        exporter.clearBuffer()
        state = .allowed
        exporter.flushBuffer()

        XCTAssertTrue(mock.exportedLogs.isEmpty)
    }

    func testForceFlush_whenAllowed_forwardsToDelegate() {
        let mock = MockLogExporter()
        var state = PulseDataCollectionConsent.allowed
        let exporter = ConsentLogExporter(delegate: mock, getState: { state })

        _ = exporter.forceFlush(explicitTimeout: nil)

        XCTAssertEqual(mock.forceFlushCallCount, 1)
    }

    func testForceFlush_whenPending_doesNotForward() {
        let mock = MockLogExporter()
        var state = PulseDataCollectionConsent.pending
        let exporter = ConsentLogExporter(delegate: mock, getState: { state })

        _ = exporter.forceFlush(explicitTimeout: nil)

        XCTAssertEqual(mock.forceFlushCallCount, 0)
    }

    func testFlushBuffer_emptyBuffer_noOp() {
        let mock = MockLogExporter()
        let state = PulseDataCollectionConsent.allowed
        let exporter = ConsentLogExporter(delegate: mock, getState: { state })

        exporter.flushBuffer()

        XCTAssertTrue(mock.exportedLogs.isEmpty)
    }

    // MARK: - Helpers

    private func createLog(eventName: String) -> ReadableLogRecord {
        ReadableLogRecord(
            resource: Resource(),
            instrumentationScopeInfo: InstrumentationScopeInfo(name: "test"),
            timestamp: Date(),
            severity: .info,
            body: .string("body"),
            attributes: [:],
            eventName: eventName
        )
    }
}

private class MockLogExporter: LogRecordExporter {
    var exportedLogs: [ReadableLogRecord] = []
    var forceFlushCallCount = 0

    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
        exportedLogs.append(contentsOf: logRecords)
        return .success
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        forceFlushCallCount += 1
        return .success
    }

    func shutdown(explicitTimeout: TimeInterval?) {}
}
