/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Configuration for UIKit tap auto-instrumentation.
/// When enabled, automatically intercepts all user taps (UIControl, gesture-recognized views,
/// table/collection cells) and emits `app.widget.click` log events with rich context:
/// touch coordinates, label, element type, and accessibility identifiers.
public struct UIKitTapInstrumentationConfig {
    public private(set) var enabled: Bool = true

    /// When true (default), extracts rich label context from the tapped view — including
    /// recursive subview text scan for container views (cards, cells, stacks).
    /// Disable for performance-sensitive apps where view hierarchies are large and deep.
    public private(set) var captureContext: Bool = true

    public init(enabled: Bool = true, captureContext: Bool = true) {
        self.enabled = enabled
        self.captureContext = captureContext
    }

    public mutating func enabled(_ value: Bool) {
        self.enabled = value
    }

    public mutating func captureContext(_ value: Bool) {
        self.captureContext = value
    }
}

extension UIKitTapInstrumentationConfig: InstrumentationLifecycle {
    internal func initialize(ctx: InstallationContext) {
        guard self.enabled else { return }
        #if os(iOS) || os(tvOS)
        let logger = ctx.loggerProvider.get(
            instrumentationScopeName: PulseKitConstants.instrumentationScopeName
        )
        UIWindowSwizzler.swizzle(logger: logger, captureContext: captureContext)
        #endif
    }

    internal func uninstall() {}
}
