/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import Sessions
#if os(iOS) || os(tvOS)
import UIKit
import QuartzCore
public class SessionReplayRecorder {
    private let config: SessionReplayConfig
    private let capturer: SessionReplayCapturer
    private var _isRecording: Bool = false
    private let queue = DispatchQueue(label: "com.pulse.ios.sdk.sessionreplay", qos: .utility)
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var onDrawFlag: Bool = false
    private var displayLink: CADisplayLink?
    private let drawFlagLock = NSLock()
    private var throttler: SessionReplayThrottler?
    private var drawOccurredSinceLastCapture: Bool = false
    private let drawOccurredLock = NSLock()
    private var windowStatuses: [UIWindow: WindowSnapshotStatus] = [:]
    private let windowStatusLock = NSLock()
    private var persistingEmitter: SessionReplayPersistingEmitter?
    private let transformer = SessionReplayEventTransformer()
    private let projectId: String?
    private let userIdProvider: (() -> String?)?
    private var currentSessionId: String?

    public init(config: SessionReplayConfig, exporter: SessionReplayExporter? = nil) {
        self.config = config
        self.capturer = ScreenshotCapturer(config: config)
        self.projectId = exporter?.projectId
        self.userIdProvider = exporter?.userIdProvider

        if let exporter = exporter {
            self.persistingEmitter = SessionReplayPersistingEmitter(
                transport: exporter.transport,
                flushIntervalSeconds: config.flushIntervalSeconds,
                flushAt: config.flushAt,
                maxBatchSize: config.maxBatchSize
            )
            self.persistingEmitter?.sendCachedEvents()
        }

        setupLifecycleObservers()
    }
    
    deinit {
        stopDisplayLink()
        removeLifecycleObservers()
    }
    
    public func start(resetState: Bool = true) {
        queue.async { [weak self] in
            guard let self = self, !self._isRecording else { return }
            if resetState {
                self.transformer.reset()
                self.resetWindowStatuses()
                self.currentSessionId = nil
            }
            self._isRecording = true
            self.throttler = SessionReplayThrottler(throttleDelayMs: self.config.captureIntervalMs, queue: self.queue)
            self.resetDrawOccurredFlag()
            self.startDisplayLink()
            NSLog("[SessionReplay] ✅ Recording started (resetState: \(resetState), interval: \(self.config.captureIntervalMs)ms)")
        }
    }
    
    public func resume() {
        start(resetState: false)
    }
    
    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self._isRecording = false
            self.throttler?.cancel()
            self.throttler = nil
            self.stopDisplayLink()
            NSLog("[SessionReplay] ⏹️ Recording stopped, flushing remaining data...")
            self.persistingEmitter?.flush()
        }
    }
    
    private func resetDrawOccurredFlag() {
        drawOccurredLock.lock()
        drawOccurredSinceLastCapture = false
        drawOccurredLock.unlock()
    }
    
    private func captureFrame(completion: @escaping (SessionReplayFrame?) -> Void) {
        #if os(iOS) || os(tvOS)
        let windows = getAllVisibleWindows()
        
        guard !windows.isEmpty else {
            completion(nil)
            return
        }
        
        if Thread.isMainThread {
            resetDrawFlag()
        } else {
            DispatchQueue.main.sync {
                resetDrawFlag()
            }
        }
        
        if let masker = (capturer as? ScreenshotCapturer)?.masker {
            masker.setDrawFlagChecker { [weak self] in
                self?.checkDrawFlag() ?? false
            }
        }
        
        let windowsToCapture: [UIWindow]
        if Thread.isMainThread {
            let keyWindows = windows.filter { $0.isKeyWindow }
            windowsToCapture = keyWindows.isEmpty ? windows : keyWindows
        } else {
            var keyWindows: [UIWindow] = []
            var allWindows: [UIWindow] = []
            DispatchQueue.main.sync {
                keyWindows = windows.filter { $0.isKeyWindow }
                allWindows = windows
            }
            windowsToCapture = keyWindows.isEmpty ? allWindows : keyWindows
        }
        
        let session = SessionManagerProvider.getInstance().getSession()
        let frameSessionId = session.id
        
        if self.currentSessionId == nil {
            self.currentSessionId = frameSessionId
            NSLog("[SessionReplay] 🆕 New session started: \(frameSessionId)")
        } else if self.currentSessionId != frameSessionId {
            NSLog("[SessionReplay] 🔄 Session changed: \(self.currentSessionId?.prefix(8) ?? "nil")... → \(frameSessionId.prefix(8))...")
            self.currentSessionId = frameSessionId
        }
        
        let dispatchGroup = DispatchGroup()
        var capturedFrames: [SessionReplayFrame] = []
        var allEvents: [SessionReplayEvent] = []
        let framesLock = NSLock()
        let eventsLock = NSLock()
        
        for window in windowsToCapture {
            dispatchGroup.enter()
            
            capturer.capture(window: window, scale: config.screenshotScale) { [weak self] capturedImage in
                defer { dispatchGroup.leave() }
                
                guard let self = self, let capturedImage = capturedImage else {
                    return
                }
                
                guard let compressed = SessionReplayCompressor.compress(
                    image: capturedImage,
                    quality: self.config.compressionQuality
                ) else {
                    return
                }
                
                let imgW = Int(capturedImage.size.width)
                let imgH = Int(capturedImage.size.height)
                let screenName = self.getCurrentScreenName(from: window)
                
                let frame = SessionReplayFrame(
                    timestamp: Date(),
                    sessionId: frameSessionId,
                    screenName: screenName,
                    imageData: compressed.data,
                    format: compressed.format,
                    width: imgW,
                    height: imgH
                )
                
                framesLock.lock()
                capturedFrames.append(frame)
                framesLock.unlock()
                
                NSLog("[SessionReplay] 📸 Frame captured: \(imgW)×\(imgH), \(compressed.format.rawValue.uppercased()), \(compressed.data.count) bytes, screen: \(screenName), session: \(frame.sessionId.prefix(8))...")
                
                if let _ = self.persistingEmitter, let pid = self.projectId {
                    var windowStatus = self.getWindowStatus(window: window)
                    let events = self.transformer.transformFrame(
                        frame: frame,
                        windowStatus: &windowStatus,
                        projectId: pid,
                        userId: self.userIdProvider?()
                    )
                    self.updateWindowStatus(window: window, status: windowStatus)
                    
                    if events.count > 0 {
                        var eventTypes: [String] = []
                        for event in events {
                            switch event {
                            case .meta: eventTypes.append("Meta(4)")
                            case .fullSnapshot: eventTypes.append("FullSnapshot(2)")
                            case .incrementalSnapshot: eventTypes.append("Incremental(3)")
                            }
                        }
                        NSLog("[SessionReplay] 📦 Transformed frame into \(events.count) event(s): \(eventTypes.joined(separator: ", "))")
                    } else {
                        NSLog("[SessionReplay] ⏭️  Frame unchanged, no events generated")
                    }
                    
                    eventsLock.lock()
                    allEvents.append(contentsOf: events)
                    eventsLock.unlock()
                }
            }
        }
        
        dispatchGroup.notify(queue: queue) { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            guard !capturedFrames.isEmpty else {
                completion(nil)
                return
            }

            if let emitter = self.persistingEmitter, let pid = self.projectId, !allEvents.isEmpty, let sessionId = self.currentSessionId {
                // Log event type breakdown
                var metaCount = 0
                var fullSnapshotCount = 0
                var incrementalSnapshotCount = 0
                var eventDetails: [String] = []
                
                for event in allEvents {
                    switch event {
                    case .meta(let metaEvent):
                        metaCount += 1
                        eventDetails.append("Meta(type=4, ts=\(metaEvent.timestamp), width=\(metaEvent.data.width), height=\(metaEvent.data.height), href=\(metaEvent.data.href))")
                    case .fullSnapshot(let fullEvent):
                        fullSnapshotCount += 1
                        let wireframeCount = fullEvent.data.wireframes.count
                        let firstWireframe = fullEvent.data.wireframes.first
                        let wireframeInfo = firstWireframe.map { "id=\($0.id), type=\($0.type), size=\(Int($0.width))×\(Int($0.height)), base64Len=\($0.base64?.count ?? 0)" } ?? "none"
                        eventDetails.append("FullSnapshot(type=2, ts=\(fullEvent.timestamp), wireframes=\(wireframeCount), first: \(wireframeInfo))")
                    case .incrementalSnapshot(let incEvent):
                        incrementalSnapshotCount += 1
                        let updateCount = incEvent.data.updates?.count ?? 0
                        let firstUpdate = incEvent.data.updates?.first?.wireframe
                        let updateInfo = firstUpdate.map { "id=\($0.id), type=\($0.type), size=\(Int($0.width))×\(Int($0.height)), base64Len=\($0.base64?.count ?? 0)" } ?? "none"
                        eventDetails.append("Incremental(type=3, ts=\(incEvent.timestamp), source=\(incEvent.data.source), updates=\(updateCount), first: \(updateInfo))")
                    }
                }
                
                NSLog("[SessionReplay] 📊 Payload breakdown: Meta=\(metaCount), FullSnapshot=\(fullSnapshotCount), Incremental=\(incrementalSnapshotCount)")
                for (index, detail) in eventDetails.enumerated() {
                    NSLog("[SessionReplay]   Event[\(index)]: \(detail)")
                }
                
                let payload = SessionReplayPayload(
                    projectId: pid,
                    userId: self.userIdProvider?(),
                    properties: SessionReplayProperties(
                        sessionId: sessionId,
                        snapshotSource: "ios",
                        snapshotData: allEvents
                    )
                )
                
                if let jsonData = try? JSONEncoder().encode(payload),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    let payloadSize = jsonData.count
                    NSLog("[SessionReplay] 💾 Emitting payload: \(allEvents.count) events, \(payloadSize) bytes, session: \(sessionId.prefix(8))...")
                    
                    // Log payload structure (truncated JSON for readability)
                    let maxPreviewLength = 500
                    if jsonString.count > maxPreviewLength {
                        let preview = String(jsonString.prefix(maxPreviewLength))
                        NSLog("[SessionReplay] 📄 Payload preview (first \(maxPreviewLength) chars): \(preview)...")
                    } else {
                        NSLog("[SessionReplay] 📄 Payload JSON: \(jsonString)")
                    }
                    
                    // Log payload summary
                    let userId = self.userIdProvider?() ?? "nil"
                    NSLog("[SessionReplay] 📋 Payload summary: event=\(payload.event), projectId=\(pid), userId=\(userId), sessionId=\(sessionId), snapshotSource=ios, snapshotDataCount=\(allEvents.count)")
                    
                    emitter.emit(payloadJson: jsonString)
                } else {
                    NSLog("[SessionReplay] ❌ Failed to encode payload to JSON")
                }
            } else {
                if allEvents.isEmpty {
                    NSLog("[SessionReplay] ⚠️ No events to emit (empty frame)")
                } else if self.persistingEmitter == nil {
                    NSLog("[SessionReplay] ⚠️ No emitter configured, events not sent")
                } else if self.projectId == nil {
                    NSLog("[SessionReplay] ⚠️ No project ID, events not sent")
                }
            }

            completion(capturedFrames.first)
        }
        #else
        completion(nil)
        #endif
    }
    
    private func getAllVisibleWindows() -> [UIWindow] {
        #if os(iOS) || os(tvOS)
        guard Thread.isMainThread else {
            var windows: [UIWindow] = []
            DispatchQueue.main.sync {
                windows = getAllVisibleWindows()
            }
            return windows
        }
        
        var visibleWindows: [UIWindow] = []
        
        if #available(iOS 15.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let windowScene = scene as? UIWindowScene {
                    for window in windowScene.windows {
                        let windowClassName = String(describing: type(of: window))
                        if windowClassName.contains("RemoteKeyboardWindow") ||
                           windowClassName.contains("UITextEffectsWindow") ||
                           windowClassName.contains("UIRemoteKeyboardWindow") ||
                           windowClassName.contains("StatusBar") {
                            continue
                        }
                        
                        if window.isHidden == false && window.alpha > 0 && window.windowScene != nil {
                            let isKey = window.isKeyWindow
                            if window.rootViewController != nil || isKey {
                                visibleWindows.append(window)
                            }
                        }
                    }
                }
            }
        } else {
            for window in UIApplication.shared.windows {
                let windowClassName = String(describing: type(of: window))
                if windowClassName.contains("RemoteKeyboardWindow") ||
                   windowClassName.contains("UITextEffectsWindow") ||
                   windowClassName.contains("UIRemoteKeyboardWindow") ||
                   windowClassName.contains("StatusBar") {
                    continue
                }
                
                if window.isHidden == false && window.alpha > 0 {
                    let isKey = window.isKeyWindow
                    if window.rootViewController != nil || isKey {
                        visibleWindows.append(window)
                    }
                }
            }
        }
        
        visibleWindows.sort { first, second in
            let firstIsKey = first.isKeyWindow
            let secondIsKey = second.isKeyWindow
            if firstIsKey && !secondIsKey {
                return true
            }
            if !firstIsKey && secondIsKey {
                return false
            }
            return first.windowLevel.rawValue > second.windowLevel.rawValue
        }
        
        return visibleWindows
        #else
        return []
        #endif
    }
    
    private func getWindowStatus(window: UIWindow) -> WindowSnapshotStatus {
        windowStatusLock.lock()
        defer { windowStatusLock.unlock() }
        return windowStatuses[window] ?? WindowSnapshotStatus()
    }
    
    private func updateWindowStatus(window: UIWindow, status: WindowSnapshotStatus) {
        windowStatusLock.lock()
        defer { windowStatusLock.unlock() }
        windowStatuses[window] = status
    }
    
    private func resetWindowStatuses() {
        windowStatusLock.lock()
        defer { windowStatusLock.unlock() }
        for (window, _) in windowStatuses {
            windowStatuses[window] = WindowSnapshotStatus()
        }
    }
    
    #if os(iOS) || os(tvOS)
    private func getCurrentScreenName(from window: UIWindow) -> String {
        if Thread.isMainThread {
            if let rootViewController = window.rootViewController {
                return getTopViewControllerName(from: rootViewController)
            }
            return ""
        } else {
            var screenName = ""
            DispatchQueue.main.sync {
                if let rootViewController = window.rootViewController {
                    screenName = getTopViewControllerName(from: rootViewController)
                }
            }
            return screenName
        }
    }
    
    private func getTopViewControllerName(from viewController: UIViewController) -> String {
        if let presented = viewController.presentedViewController {
            return getTopViewControllerName(from: presented)
        }
        if let nav = viewController as? UINavigationController,
           let top = nav.topViewController {
            return getTopViewControllerName(from: top)
        }
        if let tab = viewController as? UITabBarController,
           let selected = tab.selectedViewController {
            return getTopViewControllerName(from: selected)
        }
        return viewController.title ?? String(describing: type(of: viewController))
    }
    
    #endif
    
    private func setupLifecycleObservers() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        
        let didBecomeActive = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.start()
        }
        lifecycleObservers.append(didBecomeActive)
        
        let didEnterBackground = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stop()
        }
        lifecycleObservers.append(didEnterBackground)
        #endif
    }
    
    private func removeLifecycleObservers() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }
    
    private func startDisplayLink() {
        #if os(iOS) || os(tvOS)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.displayLinkFired))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
        #endif
    }
    
    private func stopDisplayLink() {
        #if os(iOS) || os(tvOS)
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
        }
        #endif
    }
    
    @objc private func displayLinkFired() {
        drawFlagLock.lock()
        onDrawFlag = true
        drawFlagLock.unlock()
        
        drawOccurredLock.lock()
        drawOccurredSinceLastCapture = true
        drawOccurredLock.unlock()
        
        throttler?.throttle { [weak self] in
            guard let self = self else { return }
            
            self.drawOccurredLock.lock()
            let shouldCapture = self.drawOccurredSinceLastCapture
            if shouldCapture {
                self.drawOccurredSinceLastCapture = false
            }
            self.drawOccurredLock.unlock()
            
            if shouldCapture {
                self.captureFrame { _ in
                }
            }
        }
    }
    
    private func resetDrawFlag() {
        drawFlagLock.lock()
        onDrawFlag = false
        drawFlagLock.unlock()
    }
    
    private func checkDrawFlag() -> Bool {
        drawFlagLock.lock()
        let flag = onDrawFlag
        drawFlagLock.unlock()
        return flag
    }
    
    public var isRecording: Bool {
        return queue.sync { _isRecording }
    }
}
#else
public class SessionReplayRecorder {
    private let config: SessionReplayConfig
    
    public init(config: SessionReplayConfig, exporter: SessionReplayExporter? = nil) {
        self.config = config
    }
    
    public func start() {}
    public func stop() {}
    public var isRecording: Bool { return false }
}
#endif
