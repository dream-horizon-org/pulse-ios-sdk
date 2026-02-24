/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi

/// Manages OpenTelemetry sessions with automatic expiration and persistence.
/// Provides thread-safe access to session information and handles session lifecycle.
/// Sessions are automatically extended on access and persisted to UserDefaults.
public class SessionManager {
  private var configuration: SessionConfig
  private var session: Session?
  private var lock = NSLock()
  private var sessionStorage: SessionStorage
  private var defaultMaxlifetime: TimeInterval = 15  // 15 seconds for testing
  /// Initializes the session manager and restores any previous session from disk
  /// - Parameter configuration: Session configuration settings
  public init(configuration: SessionConfig = .default) {
    self.configuration = configuration
    if configuration.shouldPersist {
      self.sessionStorage = PersistentSessionStorage()
    } else {
      self.sessionStorage = InMemorySessionStorage()
    }
    restoreSessionFromDisk()
  }

  /// This method is thread-safe 
  /// - Returns: The current active session
  @discardableResult
  public func getSession() -> Session {
    // We only lock once when fetching the current session to expire with thread safety
    return lock.withLock {
      refreshSession()
      return session!
    }
  }

  /// Gets the current session without extending its expireTime time
  /// - Returns: The current session if one exists, nil otherwise
  public func peekSession() -> Session? {
    return session
  }

  /// Creates a new session with a unique identifier
  /// **Session ID Format:** Matches Android TraceId format - 32-character hex string (no hyphens)
  /// Example: "3e041e0beaa74bc8d9e7b58c53efe646"

  private func startSession() {
    let now = Date()
    let previousId = session?.id
    /// **Implementation:** Uses OpenTelemetry's TraceId.random() to generate session ID
    /// This matches Android's approach: TraceId.fromLongs(random.nextLong(), random.nextLong())
    let newId = TraceId.random().hexString

    /// Queue the previous session for a session.end event
    if session != nil, let endEventName = configuration.endEventName {
      SessionEventInstrumentation.addSession(session: session!, eventType: .end, eventName: endEventName)
    }

    session = Session(
      id: newId,
      expireTime: now.addingTimeInterval(
        Double(
            configuration.maxLifetime ?? defaultMaxlifetime
        )
      ),
      previousId: previousId,
      startTime: now,
      sessionTimeout: configuration.maxLifetime ?? defaultMaxlifetime
    )

    // Queue the new session for a session.start event
    if let startEventName = configuration.startEventName {
      SessionEventInstrumentation.addSession(session: session!, eventType: .start, eventName: startEventName)
    }
  }

  /// Refreshes the current session, creating new one if expired\
  private func refreshSession() {
    if session == nil || session!.isExpired() {
      // Start new session if none exists or expired
      startSession()
    } else {
      // Otherwise, use existing session
      session = Session(
        id: session!.id,
        expireTime: session!.expireTime,
        previousId: session!.previousId,
        startTime: session!.startTime,
        sessionTimeout: TimeInterval(configuration.maxLifetime ?? defaultMaxlifetime)
      )
    }
    saveSessionToDisk()
  }

  /// Schedules the current session to be persisted to UserDefaults
  private func saveSessionToDisk() {
    if let currentSession = session {
      sessionStorage.save(currentSession)
    }
  }

  /// Restores a previously saved session from UserDefaults
  private func restoreSessionFromDisk() {
      session = sessionStorage.get()
  }
}
