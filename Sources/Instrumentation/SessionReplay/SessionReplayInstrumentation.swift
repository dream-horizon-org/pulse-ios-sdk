/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import Sessions
#if os(iOS) || os(tvOS)
import UIKit
#endif

public class SessionReplayInstrumentation {
    private static var sharedInstance: SessionReplayInstrumentation?
    
    public static func getInstance() -> SessionReplayInstrumentation? {
        return sharedInstance
    }
    
    private var recorder: SessionReplayRecorder?
    private let config: SessionReplayConfig
    private let exporter: SessionReplayExporter?
    
    public init(config: SessionReplayConfig, exporter: SessionReplayExporter? = nil) {
        self.config = config
        self.exporter = exporter
        SessionReplayInstrumentation.sharedInstance = self
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
    }
    
    public var recorderInstance: SessionReplayRecorder? {
        return recorder
    }
}
