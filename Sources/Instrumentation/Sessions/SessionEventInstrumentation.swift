/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi

/// Enum to specify the type of session event
public enum SessionEventType {
  case start
  case end
}

/// Represents a session event with its associated session, event type, and event name
public struct SessionEvent {
  public let session: Session
  public let eventType: SessionEventType
  public let eventName: String  // "session.start" or "metered.session.start"
  /// Optional timestamp for session.end events (used for background expiration)
  /// When provided, this timestamp is used as the observed timestamp for the log record
  /// instead of the current time. This ensures session.end timestamp = backgroundStartTime
  /// when session expired in background (matches Android behavior)
  public let endTimestamp: Date?
  
  public init(session: Session, eventType: SessionEventType, eventName: String, endTimestamp: Date? = nil) {
    self.session = session
    self.eventType = eventType
    self.eventName = eventName
    self.endTimestamp = endTimestamp
  }
}

/// Instrumentation for tracking and logging session lifecycle events.
///
/// This class is responsible for creating OpenTelemetry log records for session start and end events.
/// It handles sessions that are created both before and after the instrumentation is initialized by
/// using a queue mechanism and notification system.
///
/// The instrumentation follows these key patterns:
/// - Sessions created before instrumentation is applied are stored in a static queue
/// - Sessions created after instrumentation is applied trigger notifications
/// - All session events are converted to OpenTelemetry log records with appropriate attributes
/// - Session end events include duration and end time attributes
public class SessionEventInstrumentation {
  private let logger: Logger

  /// Queue for storing session events that were created before instrumentation was initialized.
  /// This allows capturing session events that occur during application startup before
  /// the OpenTelemetry SDK is fully initialized.
  /// Limited to 20 items to prevent memory issues.
  static var queue: [SessionEvent] = []

  /// Maximum number of sessions that can be queued before instrumentation is applied
  static let maxQueueSize: UInt8 = 32

  /// Notification name for new session events.
  /// Used to broadcast session creation and expiration events after instrumentation is applied.
  static let sessionEventNotification = Notification.Name(SessionConstants.sessionEventNotification)

  static let instrumentationKey = "io.opentelemetry.sessions"

  /// Flag to track if the instrumentation has been applied.
  /// Controls whether new sessions are queued or immediately processed via notifications.
  static var isApplied = false

  public init() {
    logger = OpenTelemetry.instance.loggerProvider.get(instrumentationScopeName: SessionEventInstrumentation.instrumentationKey)
    guard !SessionEventInstrumentation.isApplied else {
      return
    }

    SessionEventInstrumentation.isApplied = true
    // Process any queued sessions
    processQueuedSessions()

    // Start observing for new session notifications
    NotificationCenter.default.addObserver(
      forName: SessionEventInstrumentation.sessionEventNotification,
      object: nil,
      queue: nil
    ) { notification in
      if let sessionEvent = notification.object as? SessionEvent {
        self.createSessionEvent(
          session: sessionEvent.session,
          eventType: sessionEvent.eventType,
          eventName: sessionEvent.eventName,
          endTimestamp: sessionEvent.endTimestamp
        )
      }
    }
  }

  /// Process any sessions that were queued before instrumentation was applied.
  ///
  /// This method is called during the `apply()` process to handle any sessions that
  /// were created before the instrumentation was initialized. It creates log records
  /// for all queued sessions and then clears the queue.
  private func processQueuedSessions() {
    let sessionEvents = SessionEventInstrumentation.queue

    if sessionEvents.isEmpty {
      return
    }

    for sessionEvent in sessionEvents {
      createSessionEvent(
        session: sessionEvent.session,
        eventType: sessionEvent.eventType,
        eventName: sessionEvent.eventName,
        endTimestamp: sessionEvent.endTimestamp
      )
    }

    SessionEventInstrumentation.queue.removeAll()
  }

  /// Create session start or end log record based on the specified event type.
  ///
  /// - Parameters:
  ///   - session: The session to create an event for
  ///   - eventType: The type of event to create (start or end)
  ///   - eventName: The event name ("session.start" or "metered.session.start")
  ///   - endTimestamp: Optional timestamp for session.end events (used for background expiration)
  private func createSessionEvent(session: Session, eventType: SessionEventType, eventName: String, endTimestamp: Date? = nil) {
    switch eventType {
    case .start:
      createSessionStartEvent(session: session, eventName: eventName)
    case .end:
      createSessionEndEvent(session: session, eventName: eventName, endTimestamp: endTimestamp)
    }
  }

  /// Create a log record for a session start event.
  ///
  /// Creates an OpenTelemetry log record with session attributes including ID, start time,
  /// and previous session ID (if available).
  /// - Parameters:
  ///   - session: The session that has started
  ///   - eventName: The event name ("session.start" or "metered.session.start")
  private func createSessionStartEvent(session: Session, eventName: String) {
    var attributes: [String: AttributeValue] = [
      SessionConstants.id: AttributeValue.string(session.id),
      SessionConstants.startTime: AttributeValue.double(Double(session.startTime.timeIntervalSince1970.toNanoseconds))
    ]

    if let previousId = session.previousId {
      attributes[SessionConstants.previousId] = AttributeValue.string(previousId)
    }

    /// Create session start log record according to otel semantic convention
    /// https://opentelemetry.io/docs/specs/semconv/general/session/
    logger.logRecordBuilder()
      .setEventName(eventName)
      .setBody(AttributeValue.string(eventName))
      .setAttributes(attributes)
      .emit()
  }

  /// Create a log record for a session end event.
  ///
  /// Creates an OpenTelemetry log record with session attributes including ID, start time,
  /// end time, duration, and previous session ID (if available).
  /// - Parameters:
  ///   - session: The expired session
  ///   - eventName: The event name ("session.end" or "metered.session.end")
  ///   - endTimestamp: Optional timestamp to use for the log record's observed timestamp
  ///                   When provided (for background expiration), this is used instead of current time
  ///                   This ensures session.end timestamp = backgroundStartTime (matches Android behavior)
  private func createSessionEndEvent(session: Session, eventName: String, endTimestamp: Date? = nil) {
    guard let endTime = session.endTime,
          let duration = session.duration else {
      return
    }

    var attributes: [String: AttributeValue] = [
      SessionConstants.id: AttributeValue.string(session.id),
      SessionConstants.startTime: AttributeValue.double(Double(session.startTime.timeIntervalSince1970.toNanoseconds)),
      SessionConstants.endTime: AttributeValue.double(Double(endTime.timeIntervalSince1970.toNanoseconds)),
      SessionConstants.duration: AttributeValue.double(Double(duration.toNanoseconds))
    ]

    if let previousId = session.previousId {
      attributes[SessionConstants.previousId] = AttributeValue.string(previousId)
    }

    /// Create session end log record according to otel semantic convention
    /// https://opentelemetry.io/docs/specs/semconv/general/session/
    /// If endTimestamp is provided (background expiration), use it as the event timestamp
    /// This ensures the log record timestamp (timeUnixNano) matches when the session actually ended
    /// (background start time) rather than when the event is emitted (foreground return time)
    /// 
    /// OpenTelemetry has two timestamps:
    /// - timestamp (timeUnixNano): When the event occurred - this is what we set for background expiration
    /// - observedTimestamp (observedTimeUnixNano): When the event was observed - defaults to current time
    var logRecordBuilder = logger.logRecordBuilder()
      .setEventName(eventName)
      .setBody(AttributeValue.string(eventName))
      .setAttributes(attributes)
    
    // Set event timestamp to endTimestamp if provided (background expiration)
    // This sets timeUnixNano (the primary timestamp) to when the session actually ended
    // Otherwise, use default (current time when event is emitted)
    if let timestamp = endTimestamp {
      // Set timestamp (timeUnixNano) to background start time - this is the primary timestamp
      // This matches Android: session.end timestamp = backgroundStartTime when expired in background
      logRecordBuilder = logRecordBuilder.setTimestamp(timestamp)
    }
    
    logRecordBuilder.emit()
  }

  /// Add a session to the queue or send notification if instrumentation is already applied.
  ///
  /// This static method is the main entry point for handling new sessions. It either:
  /// - Adds the session to the static queue if instrumentation hasn't been applied yet (max 32 items)
  /// - Posts a notification with the session if instrumentation has been applied
  ///
  /// - Parameters:
  ///   - session: The session to process
  ///   - eventType: The type of event (start or end)
  ///   - eventName: The event name ("session.start" or "metered.session.start")
  ///   - endTimestamp: Optional timestamp for session.end events (used for background expiration)
  ///                   When provided, this timestamp is used as the observed timestamp for the log record
  static func addSession(session: Session, eventType: SessionEventType, eventName: String, endTimestamp: Date? = nil) {
    let sessionEvent = SessionEvent(session: session, eventType: eventType, eventName: eventName, endTimestamp: endTimestamp)
    if isApplied {
      NotificationCenter.default.post(
        name: sessionEventNotification,
        object: sessionEvent
      )
    } else {
      /// SessionManager creates sessions before SessionEventInstrumentation is applied,
      /// which the notification observer cannot see. So we need to keep the sessions in a queue.
      if queue.count >= maxQueueSize {
        return
      }
      queue.append(sessionEvent)
    }
  }
}