/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
#if canImport(Sessions)
import Sessions
#endif
#if os(iOS) || os(tvOS)
import UIKit
import QuartzCore
public class SessionReplayRecorder {
    private let config: SessionReplayConfig
    private let capturer: SessionReplayCapturer
    private var _isRecording: Bool = false
    private let recordingStateLock = NSLock()  // Protects recording state without blocking
    private let queue = DispatchQueue(label: "com.pulse.ios.sdk.sessionreplay", qos: .utility)
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var onDrawFlag: Bool = false
    private var displayLink: CADisplayLink?
    private let drawFlagLock = NSLock()
    private var _throttler: SessionReplayThrottler?
    private let throttlerLock = NSLock()  // Synchronizes throttler access across threads
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
                flushIntervalSeconds: config.effectiveFlushIntervalSeconds,
                flushAt: config.effectiveFlushAt,
                maxBatchSize: config.effectiveMaxBatchSize
            )
            self.persistingEmitter?.sendCachedEvents()
        }

        setupLifecycleObservers()
    }
    
    deinit {
        stopDisplayLink()
        removeLifecycleObservers()
    }
    
    // MARK: - Recording State (Non-blocking Access)
    
    /// Returns recording state without blocking. Uses lock instead of queue.sync to prevent deadlock.
    public var isRecording: Bool {
        recordingStateLock.lock()
        defer { recordingStateLock.unlock() }
        return _isRecording
    }
    
    /// Thread-safe throttler access to prevent data races between main thread and recorder queue.
    private var throttler: SessionReplayThrottler? {
        get {
            throttlerLock.lock()
            defer { throttlerLock.unlock() }
            return _throttler
        }
        set {
            throttlerLock.lock()
            defer { throttlerLock.unlock() }
            _throttler = newValue
        }
    }
    
    // MARK: - User ID Resolution
    
    private func resolvedUserId() -> String {
        userIdProvider?() ?? "anonymous"
    }
    
    public func start(resetState: Bool = true) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Update recording state safely
            self.recordingStateLock.lock()
            guard !self._isRecording else {
                self.recordingStateLock.unlock()
                return
            }
            self._isRecording = true
            self.recordingStateLock.unlock()
            
            if resetState {
                self.transformer.reset()
                self.resetWindowStatuses()
                self.currentSessionId = nil
            }
            
            // Set throttler safely
            self.throttler = SessionReplayThrottler(throttleDelayMs: self.config.effectiveCaptureIntervalMs, queue: self.queue)
            self.resetDrawOccurredFlag()
            self.startDisplayLink()
        }
    }
    
    public func resume() {
        start(resetState: false)
    }
    
    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Update recording state safely
            self.recordingStateLock.lock()
            self._isRecording = false
            self.recordingStateLock.unlock()
            
            self.throttler?.cancel()
            self.throttler = nil
            self.stopDisplayLink()
            self.persistingEmitter?.shutdown()
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
        
        if self.currentSessionId != frameSessionId {
            self.currentSessionId = frameSessionId
        }
        
        let dispatchGroup = DispatchGroup()
        var capturedFrames: [SessionReplayFrame] = []
        var allEvents: [SessionReplayEvent] = []
        let framesLock = NSLock()
        let eventsLock = NSLock()
        
        for window in windowsToCapture {
            dispatchGroup.enter()
            
            capturer.capture(window: window, scale: config.effectiveScreenshotScale) { [weak self] capturedImage in
                defer { dispatchGroup.leave() }
                
                guard let self = self, let capturedImage = capturedImage else {
                    return
                }
                
                guard let compressed = SessionReplayCompressor.compress(
                    image: capturedImage,
                    quality: self.config.effectiveCompressionQuality
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
                
                if self.persistingEmitter != nil, let pid = self.projectId {
                    var windowStatus = self.getWindowStatus(window: window)
                    let events = self.transformer.transformFrame(
                        frame: frame,
                        windowStatus: &windowStatus,
                        projectId: pid,
                        userId: self.resolvedUserId()
                    )
                    self.updateWindowStatus(window: window, status: windowStatus)
                    
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
                let payload = SessionReplayPayload(
                    projectId: pid,
                    userId: self.resolvedUserId(),
                    properties: SessionReplayProperties(
                        sessionId: sessionId,
                        snapshotSource: "ios",
                        snapshotData: allEvents
                    )
                )
                
                if let jsonData = try? JSONEncoder().encode(payload),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    emitter.emit(payloadJson: jsonString)
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
        
        let willResignActive = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.persistingEmitter?.flush()
        }
        lifecycleObservers.append(willResignActive)
        
        let didEnterBackground = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.persistingEmitter?.flush()
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
        // Synchronous invalidation on main thread to close the post-stop firing window
        DispatchQueue.main.sync { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
        }
        #endif
    }
    
    @objc private func displayLinkFired() {
        // Early guard: don't process if we've stopped recording
        // This closes the race window between stop() and display link invalidation
        guard isRecording else { return }
        
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
                self.captureFrame { _ in }
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
