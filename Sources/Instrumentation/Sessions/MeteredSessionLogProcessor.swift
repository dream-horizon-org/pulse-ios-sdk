/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
import OpenTelemetryApi

/// OpenTelemetry log record processor that adds metered session attributes to all log records
/// This processor adds "pulse.metering.session.id" to all telemetry for billing/metering purposes
public class MeteredSessionLogProcessor: LogRecordProcessor {
  /// Reference to the metered session manager
  private var meteredManager: SessionManager
  /// The next processor in the chain
  private var nextProcessor: LogRecordProcessor

  /// Initializes the metered session log processor
  /// - Parameters:
  ///   - nextProcessor: The next processor in the chain
  ///   - meteredManager: The metered session manager
  public init(nextProcessor: LogRecordProcessor, meteredManager: SessionManager) {
    self.nextProcessor = nextProcessor
    self.meteredManager = meteredManager
  }

  /// Called when a log record is emitted - adds metered session ID attribute
  public func onEmit(logRecord: ReadableLogRecord) {
    var enhancedRecord = logRecord

    // Skip if metered session ID already exists
    let hasMeteredSessionId = logRecord.attributes[SessionConstants.meteredId] != nil
    
    if !hasMeteredSessionId {
      // Add metered session ID
      let session = meteredManager.getSession()
      enhancedRecord.setAttribute(
        key: SessionConstants.meteredId,  // "pulse.metering.session.id"
        value: AttributeValue.string(session.id)
      )
    }

    // Forward to next processor
    nextProcessor.onEmit(logRecord: enhancedRecord)
  }

  /// Shuts down the processor - no cleanup needed
  public func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    return .success
  }

  /// Forces a flush of any pending data - no action needed
  public func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    return .success
  }
}
