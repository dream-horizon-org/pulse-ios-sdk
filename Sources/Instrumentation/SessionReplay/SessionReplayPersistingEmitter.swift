/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

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
                    return
                }

                guard let encrypted = self.encryption.encrypt(jsonData) else {
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
                if currentCount >= self.flushAt {
                    self.flushIfNeeded()
                }
            } catch {
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

                let maxUncompressedSizeBytes = 1 * 1024 * 1024
                let maxBatchesPerChunk = 5
                
                var remainingFiles = files
                var chunkNumber = 0
                
                while !remainingFiles.isEmpty {
                    chunkNumber += 1
                    var fileToContent: [(URL, String)] = []
                    var filesToRemove: [URL] = []
                    
                    for file in remainingFiles {
                        do {
                            let content = try self.readFileContent(file)
                            let testContent = fileToContent.map { $0.1 } + [content]
                            let testPayload: String
                            if testContent.count == 1 {
                                testPayload = testContent[0]
                            } else {
                                testPayload = "[" + testContent.joined(separator: ",") + "]"
                            }
                            let testPayloadSize = testPayload.data(using: .utf8)?.count ?? 0
                            if testPayloadSize > maxUncompressedSizeBytes && !fileToContent.isEmpty {
                                break
                            }
                            fileToContent.append((file, content))
                            filesToRemove.append(file)
                            if fileToContent.count >= maxBatchesPerChunk {
                                break
                            }
                        } catch {
                            try? fm.removeItem(at: file)
                            filesToRemove.append(file)
                        }
                    }
                    
                    for file in filesToRemove {
                        if let index = remainingFiles.firstIndex(of: file) {
                            remainingFiles.remove(at: index)
                        }
                    }

                    guard !fileToContent.isEmpty else { continue }

                    let contents = fileToContent.map { $0.1 }
                    let payload: String
                    if contents.count == 1 {
                        payload = contents[0]
                    } else {
                        payload = "[" + contents.joined(separator: ",") + "]"
                    }

                    let semaphore = DispatchSemaphore(value: 0)
                    var sendSuccess = false
                    
                    self.transport.sendRaw(jsonString: payload) { success in
                        sendSuccess = success
                        semaphore.signal()
                    }
                    
                    let timeout = semaphore.wait(timeout: .now() + 30)
                    
                    if timeout == .timedOut {
                        break
                    }
                    
                    if sendSuccess {
                        self.dequeLock.lock()
                        for (file, _) in fileToContent {
                            try? fm.removeItem(at: file)
                        }
                        self.dequeLock.unlock()
                    } else {
                        break
                    }
                }
            } catch {
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

        transport.sendRaw(jsonString: payload) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.dequeLock.lock()
                for (file, _) in fileToContent {
                    try? fm.removeItem(at: file)
                }
                self.dequeLock.unlock()
            } else {
                self.dequeLock.lock()
                for (file, _) in fileToContent.reversed() {
                    self.deque.insert(file, at: 0)
                }
                self.dequeLock.unlock()
            }
        }
    }

    private func scheduleFlushTimer() {
        flushTimer?.cancel()
        
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + flushIntervalSeconds,
            repeating: flushIntervalSeconds,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.dequeLock.lock()
            let queueSize = self.deque.count
            self.dequeLock.unlock()
            if queueSize > 0 {
                self.flushIfNeeded()
            }
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
    
}
