/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Unit tests for PulseMetricsToAddModels (decode/encode for metricsToAdd, target, type).
 */

import XCTest
@testable import PulseKit

final class PulseMetricsToAddModelsTests: XCTestCase {

    // MARK: - PulseMetricsData

    func testDecodeCounterMetricsData() throws {
        let json = """
        {"counter":{"isMonotonic":true,"isFraction":false}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsData.self, from: data)
        if case .counter(let isMonotonic, let isFraction) = decoded {
            XCTAssertTrue(isMonotonic)
            XCTAssertFalse(isFraction)
        } else {
            XCTFail("Expected counter, got \(decoded)")
        }
    }

    func testDecodeGaugeMetricsData() throws {
        let json = """
        {"gauge":{"isFraction":true}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsData.self, from: data)
        if case .gauge(let isFraction) = decoded {
            XCTAssertTrue(isFraction)
        } else {
            XCTFail("Expected gauge, got \(decoded)")
        }
    }

    func testDecodeHistogramMetricsDataWithBuckets() throws {
        let json = """
        {"histogram":{"bucket":[50,100,250,500,1000],"isFraction":true}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsData.self, from: data)
        if case .histogram(let bucket, let isFraction) = decoded {
            XCTAssertEqual(bucket, [50, 100, 250, 500, 1000])
            XCTAssertTrue(isFraction)
        } else {
            XCTFail("Expected histogram, got \(decoded)")
        }
    }

    func testDecodeHistogramMetricsDataNoBuckets() throws {
        let json = """
        {"histogram":{"bucket":null,"isFraction":false}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsData.self, from: data)
        if case .histogram(let bucket, let isFraction) = decoded {
            XCTAssertNil(bucket)
            XCTAssertFalse(isFraction)
        } else {
            XCTFail("Expected histogram, got \(decoded)")
        }
    }

    func testDecodeSumMetricsData() throws {
        let json = """
        {"sum":{"isFraction":false}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsData.self, from: data)
        if case .sum(let isFraction) = decoded {
            XCTAssertFalse(isFraction)
        } else {
            XCTFail("Expected sum, got \(decoded)")
        }
    }

    // MARK: - PulseMetricsToAddTarget

    func testDecodeMetricsToAddTargetName() throws {
        let json = """
        "name"
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsToAddTarget.self, from: data)
        if case .name = decoded {
            // OK
        } else {
            XCTFail("Expected .name, got \(decoded)")
        }
    }

    func testDecodeMetricsToAddTargetAttribute() throws {
        let json = """
        {"attribute":{"condition":{"name":".*","props":[],"scopes":["traces"],"sdks":["pulse_ios_swift"]},"addPropNameAsSuffix":true}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsToAddTarget.self, from: data)
        if case .attribute(let condition, let addPropNameAsSuffix) = decoded {
            XCTAssertEqual(condition.name, ".*")
            XCTAssertTrue(addPropNameAsSuffix)
        } else {
            XCTFail("Expected .attribute, got \(decoded)")
        }
    }

    func testDecodeMetricsToAddTargetAttributeAddPropNameAsSuffixDefaultsFalse() throws {
        let json = """
        {"attribute":{"condition":{"name":"attr_key","props":[],"scopes":["traces"],"sdks":["pulse_ios_swift"]}}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsToAddTarget.self, from: data)
        if case .attribute(_, let addPropNameAsSuffix) = decoded {
            XCTAssertFalse(addPropNameAsSuffix)
        } else {
            XCTFail("Expected .attribute, got \(decoded)")
        }
    }

    // MARK: - PulseMetricsToAddEntry

    func testDecodeFullMetricsToAddEntry() throws {
        let json = """
        {
            "name":"my_metric",
            "target":"name",
            "condition":{"name":"Created","props":[],"scopes":["traces"],"sdks":["pulse_ios_swift"]},
            "type":{"counter":{"isMonotonic":true,"isFraction":false}}
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsToAddEntry.self, from: data)
        XCTAssertEqual(decoded.name, "my_metric")
        if case .name = decoded.target { } else { XCTFail("Expected target .name") }
        XCTAssertEqual(decoded.condition.name, "Created")
        if case .counter = decoded.data { } else { XCTFail("Expected data .counter") }
        XCTAssertTrue(decoded.attributesToPick.isEmpty)
    }

    func testDecodeMetricsToAddEntryWithAttributesToPick() throws {
        let json = """
        {
            "name":"my_metric",
            "target":"name",
            "condition":{"name":".*","props":[],"scopes":["traces"],"sdks":["pulse_ios_swift"]},
            "type":{"counter":{"isMonotonic":true,"isFraction":false}},
            "attributesToPick":[{"name":"http.method","props":[],"scopes":["traces"],"sdks":["pulse_ios_swift"]}]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseMetricsToAddEntry.self, from: data)
        XCTAssertEqual(decoded.attributesToPick.count, 1)
        XCTAssertEqual(decoded.attributesToPick[0].name, "http.method")
    }

    // MARK: - PulseSignalConfig

    func testDecodeSignalConfigWithMetricsToAdd() throws {
        let json = """
        {
            "scheduleDurationMs":60000,
            "logsCollectorUrl":"https://logs",
            "metricCollectorUrl":"https://metrics",
            "spanCollectorUrl":"https://spans",
            "customEventCollectorUrl":"https://custom",
            "attributesToDrop":[],
            "attributesToAdd":[],
            "metricsToAdd":[{"name":"test_counter","target":"name","condition":{"name":".*","props":[],"scopes":["traces"],"sdks":["pulse_ios_swift"]},"type":{"counter":{"isMonotonic":true,"isFraction":false}}}],
            "filters":{"mode":"blacklist","values":[]}
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseSignalConfig.self, from: data)
        XCTAssertEqual(decoded.metricsToAdd.count, 1)
        XCTAssertEqual(decoded.metricsToAdd[0].name, "test_counter")
    }

    func testDecodeSignalConfigWithoutMetricsToAddDefaultsToEmpty() throws {
        let json = """
        {
            "scheduleDurationMs":60000,
            "logsCollectorUrl":"https://logs",
            "metricCollectorUrl":"https://metrics",
            "spanCollectorUrl":"https://spans",
            "customEventCollectorUrl":"https://custom",
            "attributesToDrop":[],
            "attributesToAdd":[],
            "filters":{"mode":"blacklist","values":[]}
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PulseSignalConfig.self, from: data)
        XCTAssertTrue(decoded.metricsToAdd.isEmpty)
    }

    // MARK: - Encode round-trip

    func testEncodeDecodeRoundTrip() throws {
        let entry = PulseMetricsToAddEntry(
            name: "roundtrip_metric",
            target: .attribute(
                condition: PulseSignalMatchCondition(
                    name: ".*",
                    props: [PulseProp(name: "attr", value: ".*")],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                ),
                addPropNameAsSuffix: true
            ),
            condition: PulseSignalMatchCondition(
                name: "HTTP.*",
                props: [],
                scopes: [.traces],
                sdks: [.pulse_ios_swift]
            ),
            data: .histogram(bucket: [50, 100, 250], isFraction: true),
            attributesToPick: [
                PulseSignalMatchCondition(
                    name: "http.method",
                    props: [],
                    scopes: [.traces],
                    sdks: [.pulse_ios_swift]
                )
            ]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        let decoded = try JSONDecoder().decode(PulseMetricsToAddEntry.self, from: data)
        XCTAssertEqual(decoded.name, entry.name)
        XCTAssertEqual(decoded.attributesToPick.count, entry.attributesToPick.count)
    }
}
