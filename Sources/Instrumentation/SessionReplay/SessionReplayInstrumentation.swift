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
#endif

public class SessionReplayInstrumentation {
    private static let singletonLock: NSLock = NSLock()
    private static var sharedInstance: SessionReplayInstrumentation?
    
    public static func getInstance() -> SessionReplayInstrumentation? {
        singletonLock.lock()
        defer { singletonLock.unlock() }
        return sharedInstance
    }
    
    private var recorder: SessionReplayRecorder?
    private let config: SessionReplayConfig
    private let exporter: SessionReplayExporter?
    
    public init(config: SessionReplayConfig, exporter: SessionReplayExporter? = nil) {
        self.config = config
        self.exporter = exporter
        
        // Thread-safe singleton assignment
        SessionReplayInstrumentation.singletonLock.lock()
        SessionReplayInstrumentation.sharedInstance = self
        SessionReplayInstrumentation.singletonLock.unlock()
    }
    
    public func install() {
        guard recorder == nil else { return }
        
        let recorder = SessionReplayRecorder(config: config, exporter: exporter)
        self.recorder = recorder
        
        #if os(iOS) || os(tvOS)
        if UIApplication.shared.applicationState == .active {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.recorder?.start()
            }
        }
        #endif
    }
    
    public func uninstall() {
        recorder?.stop()
        recorder = nil
        
        // Thread-safe singleton cleanup
        SessionReplayInstrumentation.singletonLock.lock()
        SessionReplayInstrumentation.sharedInstance = nil
        SessionReplayInstrumentation.singletonLock.unlock()
    }
    
    public var recorderInstance: SessionReplayRecorder? {
        recorder
    }
}
