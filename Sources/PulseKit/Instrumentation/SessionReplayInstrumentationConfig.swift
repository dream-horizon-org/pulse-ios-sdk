/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
#if canImport(SessionReplay)
import SessionReplay
#endif
#if os(iOS) || os(tvOS)
import UIKit
#endif

public struct SessionReplayInstrumentationConfig {
    public private(set) var enabled: Bool = true
    public private(set) var config: SessionReplayConfig = SessionReplayConfig()
    
    public init(enabled: Bool = true, config: SessionReplayConfig = SessionReplayConfig()) {
        self.enabled = enabled
        self.config = config
    }
    
    public mutating func enabled(_ value: Bool) {
        self.enabled = value
    }
    
    public mutating func configure(_ configure: (inout SessionReplayConfig) -> Void) {
        configure(&self.config)
    }
}

extension SessionReplayInstrumentationConfig: InstrumentationLifecycle {
    internal func initialize(ctx: InstallationContext) {
        guard self.enabled else { return }
        
        let replayEndpoint = self.config.replayEndpointBaseUrl ?? ctx.endpointBaseUrl
        let exporter = SessionReplayExporter(
            endpointBaseUrl: replayEndpoint,
            headers: ctx.endpointHeaders,
            projectId: ctx.projectId,
            userIdProvider: ctx.userIdProvider
        )

        let instrumentation = SessionReplayInstrumentation(
            config: self.config,
            exporter: exporter
        )
        instrumentation.install()
    }
    internal func uninstall() {
        SessionReplayInstrumentation.getInstance()?.uninstall()
    }
}
