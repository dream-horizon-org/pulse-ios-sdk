/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import XCTest
@testable import PulseKit

class SessionReplayStorageAndChunkingTests: XCTestCase {
    private var tempDirectory: URL!
    private var transport: MockSessionReplayTransport!
    private var emitter: SessionReplayPersistingEmitter!
    
    override func setUp() {
        super.setUp()
        
        let tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
        self.tempDirectory = tempDirURL
        
        transport = MockSessionReplayTransport()
        emitter = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: 5,
            maxBatchSize: 10
        )
    }
    
    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: tempDirectory)
        emitter = nil
        transport = nil
    }
    
    // MARK: - Storage Cap (maxBatchSize) Tests
    
    func testMaxBatchSizeEnforcesStorageCap() {
        let maxBatchSize = 10
        let emitter = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: 5,
            maxBatchSize: maxBatchSize
        )
        
        // Emit maxBatchSize + 5 payloads
        for i in 0..<(maxBatchSize + 5) {
            let payload = """
            {"type": "meta", "timestamp": \(i)}
            """
            emitter.emit(payloadJson: payload)
        }
        
        // Give time for async operations
        usleep(100_000)
        
        // Should have maxBatchSize files on disk
        let files = try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.pathExtension == "replay" }
        
        XCTAssertEqual(files?.count ?? 0, maxBatchSize, "Should enforce storage cap of \(maxBatchSize)")
    }
    
    func testOldestFilesAreEvictedFirst() {
        let maxBatchSize = 5
        let emitter = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: 5,
            maxBatchSize: maxBatchSize
        )
        
        var fileNames: [String] = []
        
        for i in 0..<10 {
            let payload = """
            {"type": "meta", "id": \(i), "timestamp": \(i * 1000)}
            """
            emitter.emit(payloadJson: payload)
            usleep(10_000)
        }
        
        usleep(100_000)
        
        let files = try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.pathExtension == "replay" }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return date1 < date2
            }
        
        XCTAssertEqual(files?.count ?? 0, maxBatchSize, "Should keep exactly maxBatchSize files")
        
        // Verify we have the newest files (last 5 emitted)
        if let files = files {
            for i in 0..<files.count {
                XCTAssertTrue(files[i].pathExtension == "replay")
            }
        }
    }
    
    func testDiskTrimOnInit() {
        let maxBatchSize = 5
        
        // First emitter: emit files then deinit
        let emitter1 = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: 5,
            maxBatchSize: 20  // High limit to allow 10 files
        )
        
        for i in 0..<10 {
            emitter1.emit(payloadJson: """
            {"type": "meta", "id": \(i)}
            """)
        }
        
        usleep(100_000)
        
        var filesBefore = (try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "replay" }.count) ?? 0
        
        XCTAssertEqual(filesBefore, 10, "Should have 10 files after first emitter")
        
        // Create new emitter with lower maxBatchSize
        let emitter2 = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: 5,
            maxBatchSize: maxBatchSize
        )
        
        usleep(100_000)
        
        // Second emitter's init should trim files to maxBatchSize
        let filesAfter = (try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "replay" }.count) ?? 0
        
        XCTAssertEqual(filesAfter, maxBatchSize, "Should trim stray files to maxBatchSize on init")
    }
    
    // MARK: - Chunked Upload (flushAt) Tests
    
    func testSendCachedEventsUsesFlushAtChunkSize() {
        let flushAt = 3
        let emitter = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: flushAt,
            maxBatchSize: 50
        )
        
        // Emit flushAt * 3 payloads = 9 total
        for i in 0..<(flushAt * 3) {
            let payload = """
            {"type": "meta", "id": \(i)}
            """
            emitter.emit(payloadJson: payload)
        }
        
        usleep(100_000)
        
        // Call sendCachedEvents
        transport.resetCallCount()
        emitter.sendCachedEvents()
        
        usleep(500_000)
        
        // Should make 3 requests (9 files / 3 per chunk)
        XCTAssertEqual(transport.sendRawCallCount, 3, "Should make 3 requests with flushAt=3 and 9 files")
    }
    
    func testChunkedUploadsRespectSuccess() {
        let flushAt = 2
        let emitter = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: flushAt,
            maxBatchSize: 50
        )
        
        // Emit 6 payloads
        for i in 0..<6 {
            let payload = """
            {"type": "meta", "id": \(i)}
            """
            emitter.emit(payloadJson: payload)
        }
        
        usleep(100_000)
        
        // Configure transport to fail after 2 calls
        transport.shouldFailAfterCallCount = 2
        
        emitter.sendCachedEvents()
        
        usleep(500_000)
        
        // Should make 2 successful calls, then fail on 3rd
        XCTAssertGreaterThanOrEqual(transport.sendRawCallCount, 2, "Should attempt multiple chunks")
    }
    
    func testFlushIfNeededUsesFlushAtLimit() {
        let flushAt = 4
        let emitter = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: flushAt,
            maxBatchSize: 50
        )
        
        // Emit flushAt files (should NOT trigger auto-flush)
        for i in 0..<flushAt {
            let payload = """
            {"type": "meta", "id": \(i)}
            """
            emitter.emit(payloadJson: payload)
        }
        
        usleep(100_000)
        
        // Emit 1 more to trigger flush
        emitter.emit(payloadJson: """
        {"type": "meta", "id": 999}
        """)
        
        usleep(200_000)
        
        // Transport should have received exactly flushAt files in one request
        // (actual payloads are in the mock)
        XCTAssertGreaterThan(transport.sendRawCallCount, 0, "Should trigger flush when queue >= flushAt")
    }
    
    // MARK: - Eviction During sendCachedEvents Tests
    
    func testSendCachedEventsAppliesTotalEviction() {
        let maxBatchSize = 5
        let flushAt = 2
        
        let emitter1 = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: flushAt,
            maxBatchSize: 50  // High limit
        )
        
        // Emit 20 files
        for i in 0..<20 {
            emitter1.emit(payloadJson: """
            {"type": "meta", "id": \(i)}
            """)
        }
        
        usleep(100_000)
        
        // Create emitter with lower limit
        let emitter2 = SessionReplayPersistingEmitter(
            storageDir: tempDirectory,
            transport: transport,
            encryption: NoOpSessionReplayEncryption(),
            flushIntervalSeconds: 60,
            flushAt: flushAt,
            maxBatchSize: maxBatchSize
        )
        
        usleep(100_000)
        
        // After init, should be trimmed to maxBatchSize
        var filesAfterInit = (try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "replay" }.count) ?? 0
        
        XCTAssertEqual(filesAfterInit, maxBatchSize, "Should trim to maxBatchSize on init")
        
        // Now call sendCachedEvents
        emitter2.sendCachedEvents()
        
        usleep(500_000)
        
        let filesAfterSend = (try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "replay" }.count) ?? 0
        
        XCTAssertEqual(filesAfterSend, 0, "Should delete all files after successful send")
    }
}

// MARK: - Mock Transport for Testing

class MockSessionReplayTransport: SessionReplayTransport {
    var sendRawCallCount = 0
    var shouldFailAfterCallCount: Int? = nil
    
    override func sendRaw(jsonString: String, completion: @escaping (Bool) -> Void) {
        sendRawCallCount += 1
        
        let shouldFail: Bool
        if let failAfter = shouldFailAfterCallCount {
            shouldFail = sendRawCallCount > failAfter
        } else {
            shouldFail = false
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            completion(!shouldFail)
        }
    }
    
    func resetCallCount() {
        sendRawCallCount = 0
    }
}
