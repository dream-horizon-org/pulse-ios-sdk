/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Unit tests for Pulse SDK config models (decoding, attributesToDrop schema).
 */

import XCTest
@testable import PulseKit

final class PulseSdkConfigModelsTests: XCTestCase {

    func testDecodeMinimalConfig() throws {
        let json = """
        {
            "version": 1,
            "description": "test",
            "sampling": { "default": { "sessionSampleRate": 0.5 }, "rules": [] },
            "signals": {
                "scheduleDurationMs": 60000,
                "logsCollectorUrl": "https://logs",
                "metricCollectorUrl": "https://metrics",
                "spanCollectorUrl": "https://spans",
                "customEventCollectorUrl": "https://custom",
                "attributesToDrop": [],
                "attributesToAdd": [],
                "filters": { "mode": "blacklist", "values": [] }
            },
            "interaction": {
                "collectorUrl": "https://coll",
                "configUrl": "https://config",
                "beforeInitQueueSize": 100
            },
            "features": []
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(PulseSdkConfig.self, from: data)
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.signals.attributesToDrop.count, 0)
        XCTAssertEqual(config.signals.attributesToAdd.count, 0)
    }

    func testDecodeAttributesToDropWithStringValues() throws {
        let json = """
        {
            "version": 1,
            "description": "test",
            "sampling": { "default": { "sessionSampleRate": 0.5 }, "rules": [] },
            "signals": {
                "scheduleDurationMs": 60000,
                "logsCollectorUrl": "https://logs",
                "metricCollectorUrl": "https://metrics",
                "spanCollectorUrl": "https://spans",
                "customEventCollectorUrl": "https://custom",
                "attributesToDrop": [
                    {
                        "values": ["secret", "internal.id"],
                        "condition": {
                            "name": ".*",
                            "props": [],
                            "scopes": ["traces"],
                            "sdks": ["pulse_ios_swift"]
                        }
                    }
                ],
                "attributesToAdd": [],
                "filters": { "mode": "blacklist", "values": [] }
            },
            "interaction": {
                "collectorUrl": "https://coll",
                "configUrl": "https://config",
                "beforeInitQueueSize": 100
            },
            "features": []
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(PulseSdkConfig.self, from: data)
        XCTAssertEqual(config.signals.attributesToDrop.count, 1)
        let entry = config.signals.attributesToDrop[0]
        XCTAssertEqual(entry.values, ["secret", "internal.id"])
        XCTAssertEqual(entry.condition.name, ".*")
        XCTAssertEqual(entry.condition.scopes, [.traces])
        XCTAssertEqual(entry.condition.sdks, [.pulse_ios_swift])
    }

    func testDecodeSignalConfigWithoutMetricsToAddDefaultsToEmpty() throws {
        let json = """
        {
            "version": 1,
            "description": "test",
            "sampling": { "default": { "sessionSampleRate": 0.5 }, "rules": [] },
            "signals": {
                "scheduleDurationMs": 60000,
                "logsCollectorUrl": "https://logs",
                "metricCollectorUrl": "https://metrics",
                "spanCollectorUrl": "https://spans",
                "customEventCollectorUrl": "https://custom",
                "attributesToDrop": [],
                "attributesToAdd": [],
                "filters": { "mode": "blacklist", "values": [] }
            },
            "interaction": {
                "collectorUrl": "https://coll",
                "configUrl": "https://config",
                "beforeInitQueueSize": 100
            },
            "features": []
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(PulseSdkConfig.self, from: data)
        XCTAssertTrue(config.signals.metricsToAdd.isEmpty)
    }

    func testDecodeSignalConfigWithMetricsToAdd() throws {
        let json = """
        {
            "version": 1,
            "description": "test",
            "sampling": { "default": { "sessionSampleRate": 0.5 }, "rules": [] },
            "signals": {
                "scheduleDurationMs": 60000,
                "logsCollectorUrl": "https://logs",
                "metricCollectorUrl": "https://metrics",
                "spanCollectorUrl": "https://spans",
                "customEventCollectorUrl": "https://custom",
                "attributesToDrop": [],
                "attributesToAdd": [],
                "metricsToAdd": [
                    {
                        "name": "pulse.screen.load.count",
                        "target": "name",
                        "condition": {
                            "name": "Created",
                            "props": [],
                            "scopes": ["traces"],
                            "sdks": ["pulse_ios_swift", "pulse_ios_rn"]
                        },
                        "type": {
                            "counter": {}
                        }
                    }
                ],
                "filters": { "mode": "blacklist", "values": [] }
            },
            "interaction": {
                "collectorUrl": "https://coll",
                "configUrl": "https://config",
                "beforeInitQueueSize": 100
            },
            "features": []
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(PulseSdkConfig.self, from: data)
        XCTAssertEqual(config.signals.metricsToAdd.count, 1)
        let entry = config.signals.metricsToAdd[0]
        XCTAssertEqual(entry.name, "pulse.screen.load.count")
        if case .name = entry.target { } else { XCTFail("Expected target .name") }
        XCTAssertEqual(entry.condition.name, "Created")
        if case .counter = entry.data {
            // OK - Counter has no params
        } else { XCTFail("Expected .counter") }
    }
}
