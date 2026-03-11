/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

// MARK: - Persisting Replay Emitter

internal final class SessionReplayPersistingEmitter {

    private let storageDir: URL
    private let transport: SessionReplayTransport
    private let encryption: SessionReplayStorageEncryption
    private let flushIntervalSeconds: TimeInterval
    private let flushAt: Int
    private let maxBatchSize: Int

    private let queue = DispatchQueue(label: "com.pulse.ios.sdk.sessionreplay.persisting", qos: .utility)
    private var deque: [URL] = []
    private let dequeLock = NSLock()
    private var isFlushing = false
    private let flushLock = NSLock()
    private var flushTimer: DispatchSourceTimer?

    private static let fileExtension = "replay"

    init(
        storageDir: URL? = nil,
        transport: SessionReplayTransport,
        encryption: SessionReplayStorageEncryption? = nil,
        flushIntervalSeconds: TimeInterval = 60,
        flushAt: Int = 10,
        maxBatchSize: Int = 50
    ) {
        if let dir = storageDir {
            self.storageDir = dir
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.storageDir = caches.appendingPathComponent("pulse-replay", isDirectory: true)
        }

        self.transport = transport

        if let enc = encryption {
            self.encryption = enc
        } else {
            if #available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *) {
                self.encryption = DefaultSessionReplayEncryption()
            } else {
                self.encryption = NoOpSessionReplayEncryption()
            }
        }

        self.flushIntervalSeconds = flushIntervalSeconds
        self.flushAt = flushAt
        self.maxBatchSize = maxBatchSize

        try? FileManager.default.createDirectory(at: self.storageDir, withIntermediateDirectories: true)
        scheduleFlushTimer()
    }

    deinit {
        flushTimer?.cancel()
    }

    func emit(payloadJson: String) {
        queue.async { [weak self] in
            guard let self = self else {
                return
            }
            do {
                guard let jsonData = payloadJson.data(using: .utf8) else {
                    NSLog("[SessionReplay] Failed to encode payload to UTF-8")
                    return
                }

                guard let encrypted = self.encryption.encrypt(jsonData) else {
                    NSLog("[SessionReplay] Encryption failed, dropping batch")
                    return
                }

                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let uuid = UUID().uuidString
                let fileName = "\(timestamp)_\(uuid).\(Self.fileExtension)"
                let fileURL = self.storageDir.appendingPathComponent(fileName)

                try encrypted.write(to: fileURL, options: .atomic)

                self.dequeLock.lock()
                self.deque.append(fileURL)
                let currentCount = self.deque.count
                self.dequeLock.unlock()

                NSLog("[SessionReplay] 💾 Persisted batch: \(fileName) (\(encrypted.count) bytes), queue size: \(currentCount)/\(self.flushAt)")
                
                if currentCount >= self.flushAt {
                    NSLog("[SessionReplay] 📊 Flush threshold reached (\(currentCount) >= \(self.flushAt)), triggering flush...")
                    self.flushIfNeeded()
                }
            } catch {
                NSLog("[SessionReplay] Persist failed: %@", error.localizedDescription)
            }
        }
    }

    func sendCachedEvents() {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let fm = FileManager.default
                let files = try fm.contentsOfDirectory(at: self.storageDir, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { $0.pathExtension == Self.fileExtension }
                    .sorted { url1, url2 in
                        let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                        let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                        return date1 < date2
                    }

                guard !files.isEmpty else { return }

                NSLog("[SessionReplay] 🔄 Recovering \(files.count) cached batch(es) from previous run")

                var fileToContent: [(URL, String)] = []
                for file in files {
                    do {
                        let content = try self.readFileContent(file)
                        fileToContent.append((file, content))
                    } catch {
                        NSLog("[SessionReplay] Failed to read cached file %@: %@", file.lastPathComponent, error.localizedDescription)
                        try? fm.removeItem(at: file)
                    }
                }

                guard !fileToContent.isEmpty else { return }

                let contents = fileToContent.map { $0.1 }
                let payload: String
                if contents.count == 1 {
                    payload = contents[0]
                } else {
                    payload = "[" + contents.joined(separator: ",") + "]"
                }

                let sessionMetrics = self.parseSessionMetrics(from: payload)
                
                NSLog("[SessionReplay] 🔄 Sending \(fileToContent.count) cached batch(es)")
                if let metrics = sessionMetrics {
                    let durationSeconds = Double(metrics.durationMs) / 1000.0
                    NSLog("[SessionReplay] ⏱️  Session Duration: \(String(format: "%.2f", durationSeconds))s (\(metrics.durationMs)ms)")
                    NSLog("[SessionReplay] 📊 Total Events: \(metrics.totalEvents) | Total Wireframes: \(metrics.totalWireframes)")
                    NSLog("[SessionReplay] 📈 Event Breakdown: Meta=\(metrics.metaCount), FullSnapshot=\(metrics.fullSnapshotCount), Incremental=\(metrics.incrementalCount)")
                }

                self.transport.sendRaw(jsonString: payload) { success in
                    if success {
                        for (file, _) in fileToContent {
                            try? fm.removeItem(at: file)
                        }
                    } else {
                        NSLog("[SessionReplay] ⚠️ Failed to send cached events after retries, will retry on next launch")
                    }
                }
            } catch {
                NSLog("[SessionReplay] sendCachedEvents failed: %@", error.localizedDescription)
            }
        }
    }

    func flush() {
        queue.async { [weak self] in
            self?.flushIfNeeded()
        }
    }

    private func flushIfNeeded() {
        flushLock.lock()
        guard !isFlushing else {
            flushLock.unlock()
            return
        }
        isFlushing = true
        flushLock.unlock()

        defer {
            flushLock.lock()
            isFlushing = false
            flushLock.unlock()
        }

        dequeLock.lock()
        let n = min(maxBatchSize, deque.count)
        let toSend = Array(deque.prefix(n))
        deque.removeFirst(n)
        dequeLock.unlock()

        guard !toSend.isEmpty else { return }

        var fileToContent: [(URL, String)] = []
        let fm = FileManager.default

        for file in toSend {
            do {
                let content = try readFileContent(file)
                fileToContent.append((file, content))
            } catch {
                NSLog("[SessionReplay] Flush read failed for %@: %@", file.lastPathComponent, error.localizedDescription)
                try? fm.removeItem(at: file)
            }
        }

        guard !fileToContent.isEmpty else { return }

        let contents = fileToContent.map { $0.1 }
        let payload: String
        if contents.count == 1 {
            payload = contents[0]
        } else {
            payload = "[" + contents.joined(separator: ",") + "]"
        }

        let batchSize = fileToContent.count
        let totalSize = payload.data(using: .utf8)?.count ?? 0
        let sessionMetrics = parseSessionMetrics(from: payload)
        
        NSLog("[SessionReplay] 🚀 Flushing \(batchSize) batch(es), total payload: \(totalSize) bytes")
        if let metrics = sessionMetrics {
            let durationSeconds = Double(metrics.durationMs) / 1000.0
            NSLog("[SessionReplay] ⏱️  Session Duration: \(String(format: "%.2f", durationSeconds))s (\(metrics.durationMs)ms)")
            NSLog("[SessionReplay] 📊 Total Events: \(metrics.totalEvents) | Total Wireframes: \(metrics.totalWireframes)")
            NSLog("[SessionReplay] 📈 Event Breakdown: Meta=\(metrics.metaCount), FullSnapshot=\(metrics.fullSnapshotCount), Incremental=\(metrics.incrementalCount)")
        }
        
        transport.sendRaw(jsonString: payload) { [weak self] success in
            guard let self = self else { return }
            if success {
                NSLog("[SessionReplay] ✅ Successfully flushed \(batchSize) batch(es)")
                for (file, _) in fileToContent {
                    try? fm.removeItem(at: file)
                }
            } else {
                NSLog("[SessionReplay] ❌ Flush failed after retries, re-queuing \(batchSize) batch(es) for retry")
                self.dequeLock.lock()
                for (file, _) in fileToContent.reversed() {
                    self.deque.insert(file, at: 0)
                }
                self.dequeLock.unlock()
            }
        }
    }

    private func scheduleFlushTimer() {
        NSLog("[SessionReplay] ⏰ Scheduled flush timer: every \(flushIntervalSeconds) seconds")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + flushIntervalSeconds,
            repeating: flushIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            NSLog("[SessionReplay] ⏰ Flush timer fired")
            self?.flushIfNeeded()
        }
        timer.resume()
        self.flushTimer = timer
    }

    private func readFileContent(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file)

        if let decrypted = try? encryption.decrypt(data),
           let json = String(data: decrypted, encoding: .utf8) {
            return json
        }

        if let json = String(data: data, encoding: .utf8) {
            return json
        }

        throw NSError(
            domain: "com.pulse.sessionreplay",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to read replay file: \(file.lastPathComponent)"]
        )
    }
    
    // MARK: - Session Metrics
    
    private struct SessionMetrics {
        let durationMs: Int64
        let totalEvents: Int
        let totalWireframes: Int
        let metaCount: Int
        let fullSnapshotCount: Int
        let incrementalCount: Int
    }
    
    private func parseSessionMetrics(from jsonString: String) -> SessionMetrics? {
        guard let jsonData = jsonString.data(using: .utf8) else {
            return nil
        }
        
        if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return parseMetricsFromPayload(json)
        }
        
        if let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            return parseMetricsFromArray(jsonArray)
        }
        
        return nil
    }
    
    private func parseMetricsFromArray(_ payloads: [[String: Any]]) -> SessionMetrics? {
        var allEvents: [[String: Any]] = []
        var firstTimestamp: Int64?
        var lastTimestamp: Int64?
        var metaCount = 0
        var fullSnapshotCount = 0
        var incrementalCount = 0
        var totalWireframes = 0
        
        for payload in payloads {
            if let properties = payload["properties"] as? [String: Any],
               let snapshotData = properties["snapshot_data"] as? [[String: Any]] {
                allEvents.append(contentsOf: snapshotData)
                
                for event in snapshotData {
                    let eventType = event["type"] as? Int ?? 0
                    let timestamp = (event["timestamp"] as? NSNumber)?.int64Value ?? 0
                    
                    if firstTimestamp == nil || timestamp < firstTimestamp! {
                        firstTimestamp = timestamp
                    }
                    if lastTimestamp == nil || timestamp > lastTimestamp! {
                        lastTimestamp = timestamp
                    }
                    
                    switch eventType {
                    case 2:
                        fullSnapshotCount += 1
                        if let data = event["data"] as? [String: Any],
                           let wireframes = data["wireframes"] as? [[String: Any]] {
                            totalWireframes += wireframes.count
                        }
                    case 3:
                        incrementalCount += 1
                        if let data = event["data"] as? [String: Any],
                           let updates = data["updates"] as? [[String: Any]] {
                            totalWireframes += updates.count
                        }
                    case 4:
                        metaCount += 1
                    default:
                        break
                    }
                }
            }
        }
        
        guard let first = firstTimestamp, let last = lastTimestamp else {
            return nil
        }
        
        return SessionMetrics(
            durationMs: last - first,
            totalEvents: allEvents.count,
            totalWireframes: totalWireframes,
            metaCount: metaCount,
            fullSnapshotCount: fullSnapshotCount,
            incrementalCount: incrementalCount
        )
    }
    
    private func parseMetricsFromPayload(_ payload: [String: Any]) -> SessionMetrics? {
        guard let properties = payload["properties"] as? [String: Any],
              let snapshotData = properties["snapshot_data"] as? [[String: Any]] else {
            return nil
        }
        
        var firstTimestamp: Int64?
        var lastTimestamp: Int64?
        var metaCount = 0
        var fullSnapshotCount = 0
        var incrementalCount = 0
        var totalWireframes = 0
        
        for event in snapshotData {
            let eventType = event["type"] as? Int ?? 0
            let timestamp = (event["timestamp"] as? NSNumber)?.int64Value ?? 0
            
            if firstTimestamp == nil || timestamp < firstTimestamp! {
                firstTimestamp = timestamp
            }
            if lastTimestamp == nil || timestamp > lastTimestamp! {
                lastTimestamp = timestamp
            }
            
            switch eventType {
            case 2:
                fullSnapshotCount += 1
                if let data = event["data"] as? [String: Any],
                   let wireframes = data["wireframes"] as? [[String: Any]] {
                    totalWireframes += wireframes.count
                }
            case 3:
                incrementalCount += 1
                if let data = event["data"] as? [String: Any],
                   let updates = data["updates"] as? [[String: Any]] {
                    totalWireframes += updates.count
                }
            case 4:
                metaCount += 1
            default:
                break
            }
        }
        
        guard let first = firstTimestamp, let last = lastTimestamp else {
            return nil
        }
        
        return SessionMetrics(
            durationMs: last - first,
            totalEvents: snapshotData.count,
            totalWireframes: totalWireframes,
            metaCount: metaCount,
            fullSnapshotCount: fullSnapshotCount,
            incrementalCount: incrementalCount
        )
    }
}
