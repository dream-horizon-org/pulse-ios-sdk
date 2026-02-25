/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Configuration for session management (matches Android SessionConfig)
/// 
/// **Two ways to create:**
/// 1. Direct init: `SessionConfig(maxLifetime: 3600)`
/// 2. Builder pattern: `SessionConfig.builder().with(maxLifetime: 3600).build()`
/// Both are equivalent - builder is just for fluent API convenience
public struct SessionConfig {
  /// Background inactivity timeout in seconds (optional)
  /// Session expires if app stays in background longer than this
  public let backgroundInactivityTimeout: TimeInterval?
  
  /// Maximum session lifetime in seconds (optional)
  /// Session expires after this duration from start time
  public let maxLifetime: TimeInterval?
  
  /// Whether session should persist across app restarts
  public let shouldPersist: Bool
  
  /// Event name for session start (e.g., "session.start" or "metered.session.start")
  public let startEventName: String?
  
  /// Event name for session end (e.g., "session.end" or "metered.session.end")
  public let endEventName: String?
  
  /// Creates session configuration
  /// - Parameters:
  ///   - backgroundInactivityTimeout: Background timeout in seconds (default: 15 minutes)
  ///   - maxLifetime: Max session duration in seconds (default: 15 seconds for testing, 4 hours for production)
  ///   - shouldPersist: Enable persistence (default: false)
  ///   - startEventName: Event name for session start (default: "session.start")
  ///   - endEventName: Event name for session end (default: "session.end")
  public init(
    backgroundInactivityTimeout: TimeInterval? = 15 * 60,
    maxLifetime: TimeInterval? = 4 * 60 * 60,
    shouldPersist: Bool = false,
    startEventName: String? = SessionConstants.sessionStartEvent,
    endEventName: String? = SessionConstants.sessionEndEvent
  ) {
    self.backgroundInactivityTimeout = backgroundInactivityTimeout
    self.maxLifetime = maxLifetime
    self.shouldPersist = shouldPersist
    self.startEventName = startEventName
    self.endEventName = endEventName
  }
  
  /// Default configuration (matches Android defaults)
  public static let `default` = SessionConfig()
}

/// Builder for SessionConfig with fluent API
public class SessionConfigBuilder {
  public private(set) var backgroundInactivityTimeout: TimeInterval? = 15 * 60
  public private(set) var maxLifetime: TimeInterval? = 4 * 60 * 60
  public private(set) var shouldPersist: Bool = false
  
  public init() {}
  
  public func with(backgroundInactivityTimeout: TimeInterval?) -> Self {
    self.backgroundInactivityTimeout = backgroundInactivityTimeout
    return self
  }
  
  public func with(maxLifetime: TimeInterval?) -> Self {
    self.maxLifetime = maxLifetime
    return self
  }
  
  public func with(shouldPersist: Bool) -> Self {
    self.shouldPersist = shouldPersist
    return self
  }
  
  public func build() -> SessionConfig {
    return SessionConfig(
      backgroundInactivityTimeout: backgroundInactivityTimeout,
      maxLifetime: maxLifetime,
      shouldPersist: shouldPersist
    )
  }
}

/// Extension to SessionConfig for builder pattern support
extension SessionConfig {
  /// Creates a new SessionConfigBuilder instance
  /// - Returns: A new builder for creating SessionConfig
  public static func builder() -> SessionConfigBuilder {
    return SessionConfigBuilder()
  }
}
