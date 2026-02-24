/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
import OpenTelemetryApi

/// OpenTelemetry span processor that automatically adds metered session ID to all spans
/// This processor adds "pulse.metering.session.id" to all spans for billing/metering purposes
public class MeteredSessionSpanProcessor: SpanProcessor {
  /// Indicates that this processor needs to be called when spans start
  public var isStartRequired = true
  /// Indicates that this processor doesn't need to be called when spans end
  public var isEndRequired: Bool = false
  /// Reference to the metered session manager
  private var meteredManager: SessionManager

  /// Initializes the metered session span processor
  /// - Parameter meteredManager: The metered session manager
  public init(meteredManager: SessionManager) {
    self.meteredManager = meteredManager
  }

  /// Called when a span starts - adds the metered session ID as an attribute
  /// - Parameters:
  ///   - parentContext: The parent span context (unused)
  ///   - span: The span being started
  public func onStart(parentContext: SpanContext?, span: ReadableSpan) {
    let session = meteredManager.getSession()
    span.setAttribute(key: SessionConstants.meteredId, value: session.id)
  }

  /// Called when a span ends - no action needed for session tracking
  /// - Parameter span: The span being ended
  public func onEnd(span: any OpenTelemetrySdk.ReadableSpan) {
    // No action needed
  }

  /// Shuts down the processor - no cleanup needed
  /// - Parameter explicitTimeout: Timeout for shutdown (unused)
  public func shutdown(explicitTimeout: TimeInterval?) {
    // No cleanup needed
  }

  /// Forces a flush of any pending data - no action needed
  /// - Parameter timeout: Timeout for flush (unused)
  public func forceFlush(timeout: TimeInterval?) {
    // No action needed
  }
}
