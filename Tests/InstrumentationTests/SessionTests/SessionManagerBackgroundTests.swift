import XCTest
@testable import Sessions
#if canImport(UIKit)
import UIKit
#endif

/// Tests for background inactivity timeout behavior
/// These tests verify that sessions expire correctly when app goes to background
final class SessionManagerBackgroundTests: XCTestCase {
  var sessionManager: SessionManager!
  var config: SessionConfig!

  override func setUp() {
    super.setUp()
    SessionStore.teardown()
    
    // Use short timeout for testing (3 seconds)
    config = SessionConfig(
      backgroundInactivityTimeout: 1,
      maxLifetime: 4 * 60 * 60, // 4 hours
      shouldPersist: false
    )
    sessionManager = SessionManager(configuration: config)
  }

  override func tearDown() {
    SessionStore.teardown()
    super.tearDown()
  }

  // MARK: - Background Timeout Tests

  func testBackgroundTimeoutNotSetWhenNil() {
    let configWithoutTimeout = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 4 * 60 * 60,
      shouldPersist: false
    )
    let manager = SessionManager(configuration: configWithoutTimeout)
    
    // Should not crash and should work normally
    let session = manager.getSession()
    XCTAssertNotNil(session)
  }

  func testSessionDoesNotExpireInForeground() {
    let session = sessionManager.getSession()
    let sessionId = session.id
    
    // Wait longer than background timeout, but stay in foreground
      Thread.sleep(forTimeInterval: 1.5)
    
    let newSession = sessionManager.getSession()
    
    // Session should still be the same (no expiration in foreground)
    XCTAssertEqual(sessionId, newSession.id)
  }

  #if canImport(UIKit)
  func testBackgroundTimeoutExpiration() {
    let expectation = XCTestExpectation(description: "Session expired in background")
    expectation.isInverted = true // Should not be fulfilled immediately
    
    let session = sessionManager.getSession()
    let sessionId = session.id
    
    // Simulate app going to background
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    // Wait longer than background timeout
      Thread.sleep(forTimeInterval: 1.1)
    
    // Simulate app returning to foreground
    NotificationCenter.default.post(
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    // Wait a bit for processing
    Thread.sleep(forTimeInterval: 0.1)
    
    let newSession = sessionManager.getSession()
    
    // Session should have expired and new one created
    XCTAssertNotEqual(sessionId, newSession.id)
    XCTAssertEqual(newSession.previousId, sessionId)
  }

  func testBackgroundTimeoutNotExpiredIfWithinTimeout() {
    let session = sessionManager.getSession()
    let sessionId = session.id
    
    // Simulate app going to background
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    // Wait less than background timeout
      Thread.sleep(forTimeInterval: 0.9)
    
    // Simulate app returning to foreground
    NotificationCenter.default.post(
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    Thread.sleep(forTimeInterval: 1)
    
    let newSession = sessionManager.getSession()
    
    // Session should still be the same (not expired)
    XCTAssertEqual(sessionId, newSession.id)
  }

  func testBackgroundStartTimeCaptured() {
    SessionEventInstrumentation.queue = []
    SessionEventInstrumentation.isApplied = false
    
    let session = sessionManager.getSession()
    let sessionId = session.id
    
    // Capture background time BEFORE posting notification
    // Note: There will be a small delay between this and when the handler executes
    let backgroundTimeBeforeNotification = Date()
    
    // Simulate app going to background
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    // Small delay to allow notification handler to execute and set backgroundStartTime
    Thread.sleep(forTimeInterval: 0.05)
    
    // Wait for background timeout to expire
    Thread.sleep(forTimeInterval: 1.1)
    
    // Return to foreground
    NotificationCenter.default.post(
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    Thread.sleep(forTimeInterval: 0.1)
    
    let newSession = sessionManager.getSession()
    
    // Session should have expired
    XCTAssertNotEqual(session.id, newSession.id)
    XCTAssertEqual(newSession.previousId, sessionId)
    
    // Verify session.end event has background timestamp
    let endEvents = SessionEventInstrumentation.queue.filter {
      $0.eventType == .end && $0.session.id == sessionId
    }
    
    XCTAssertGreaterThanOrEqual(endEvents.count, 1, "Should have at least one session.end event")
    
    if let endEvent = endEvents.first {
      XCTAssertNotNil(endEvent.endTimestamp, "End timestamp should be set for background expiration")
      
      if let endTimestamp = endEvent.endTimestamp {
        // End timestamp should be close to background time (within reasonable tolerance)
        // We use diff because:
        // 1. backgroundTimeBeforeNotification is captured BEFORE the notification handler runs
        // 2. The actual backgroundStartTime is set INSIDE the notification handler (line 54 in SessionManager)
        // 3. There's a small delay between notification posting and handler execution
        let timeDiff = abs(endTimestamp.timeIntervalSince(backgroundTimeBeforeNotification))
        XCTAssertLessThan(timeDiff, 0.1, "End timestamp should be close to background start time (within 100ms)")
        
        // Verify endTimestamp is BEFORE current time (it's the background start time, not foreground return time)
        XCTAssertLessThan(endTimestamp, Date(), "End timestamp should be in the past (background start time)")
      }
    }
  }
  #endif

  // MARK: - Background + MaxLifetime Tests

  #if canImport(UIKit)
  func testSessionExpiresByMaxLifetimeInBackground() {
    SessionEventInstrumentation.queue = []
    SessionEventInstrumentation.isApplied = false
    
    // Use short maxLifetime for testing
    // maxLifetime: 1 second, backgroundInactivityTimeout: 3 seconds
    // Session should expire by maxLifetime while in background
    let config = SessionConfig(
      backgroundInactivityTimeout: 3,
      maxLifetime: 1, // 1 second
      shouldPersist: false,
      startEventName: SessionConstants.sessionStartEvent,
      endEventName: SessionConstants.sessionEndEvent
    )
    sessionManager = SessionManager(configuration: config)
    
    let session = sessionManager.getSession()
    let sessionId = session.id
    let sessionStartTime = session.startTime
    
    // Capture background time BEFORE going to background
    let backgroundTimeBeforeNotification = Date()
    
    // Go to background BEFORE maxLifetime expires
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    // Small delay to allow notification handler to execute
    Thread.sleep(forTimeInterval: 0.05)
    
    // Wait for maxLifetime to expire while in background
    // maxLifetime is 1 second, so wait 1.1 seconds
    Thread.sleep(forTimeInterval: 1.1)
    
    // Verify session would have expired by maxLifetime
    // (startTime + maxLifetime should be <= backgroundStart + wait time)
    let expectedExpirationTime = sessionStartTime.addingTimeInterval(1.0) // maxLifetime
    XCTAssertLessThanOrEqual(expectedExpirationTime, Date(), "Session should have expired by maxLifetime")
    
    // Return to foreground
    NotificationCenter.default.post(
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    Thread.sleep(forTimeInterval: 0.1)
    
    // Get new session - should trigger expiration check
    let newSession = sessionManager.getSession()
    
    // Session should have expired by maxLifetime (not background timeout)
    XCTAssertNotEqual(sessionId, newSession.id, "Session should expire by maxLifetime in background")
    XCTAssertEqual(newSession.previousId, sessionId, "New session should have previous session ID")
    
    // Verify session.end event was emitted with background start timestamp
    let endEvents = SessionEventInstrumentation.queue.filter {
      $0.eventType == .end && $0.session.id == sessionId
    }
    
    XCTAssertGreaterThanOrEqual(endEvents.count, 1, "Should have session.end event for maxLifetime expiration in background")
    
    if let endEvent = endEvents.first {
      XCTAssertNotNil(endEvent.endTimestamp, "End timestamp should be set when session expires by maxLifetime in background")
      
      if let endTimestamp = endEvent.endTimestamp {
        // End timestamp should be background start time (not session start + maxLifetime)
        // This is because when maxLifetime expires in background, we use backgroundStart as the end timestamp
        let timeDiff = abs(endTimestamp.timeIntervalSince(backgroundTimeBeforeNotification))
        XCTAssertLessThan(timeDiff, 0.1, "End timestamp should be background start time (within 100ms)")
        
        // Verify it's the background start time, not the maxLifetime expiration time
        let maxLifetimeExpirationTime = sessionStartTime.addingTimeInterval(1.0)
        XCTAssertNotEqual(endTimestamp, maxLifetimeExpirationTime, "End timestamp should be background start, not maxLifetime expiration")
      }
    }
  }

  func testSessionExpiresByBackgroundTimeoutBeforeMaxLifetime() {
    // Background timeout shorter than maxLifetime
    let config = SessionConfig(
      backgroundInactivityTimeout: 1, // 1 second
      maxLifetime: 2,
      shouldPersist: false
    )
    sessionManager = SessionManager(configuration: config)
    
    let session = sessionManager.getSession()
    let sessionId = session.id
    
    // Go to background
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    // Wait for background timeout (but less than maxLifetime)
    Thread.sleep(forTimeInterval: 1.1)
    
    // Return to foreground
    NotificationCenter.default.post(
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    Thread.sleep(forTimeInterval: 0.1)
    
    let newSession = sessionManager.getSession()
    
    // Session should have expired by background timeout
    XCTAssertNotEqual(sessionId, newSession.id)
    XCTAssertEqual(newSession.previousId, sessionId)
  }
  #endif

  // MARK: - Event Timestamp Tests

  #if canImport(UIKit)
  func testSessionEndEventHasBackgroundTimestamp() {
    SessionEventInstrumentation.queue = []
    SessionEventInstrumentation.isApplied = false
    
    let session = sessionManager.getSession()
    let sessionId = session.id
    
    // Capture background time BEFORE posting notification
    // Note: We use diff instead of exact match because:
    // 1. backgroundTime is captured BEFORE the notification handler executes
    // 2. The actual backgroundStartTime is set INSIDE the notification handler (SessionManager line 54)
    // 3. There's a small delay (typically < 10ms) between posting notification and handler execution
    // 4. The endTimestamp is set to backgroundStartTime (SessionManager line 85), not the captured time
    let backgroundTimeBeforeNotification = Date()
    
    // Go to background
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    // Small delay to allow notification handler to execute and set backgroundStartTime
    Thread.sleep(forTimeInterval: 0.05)
    
    // Wait for background timeout to expire
    Thread.sleep(forTimeInterval: 1.1)
    
    // Return to foreground
    NotificationCenter.default.post(
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    Thread.sleep(forTimeInterval: 0.1)
    
    // Get new session to trigger event processing
    _ = sessionManager.getSession()
    
    // Find the session.end event
    let endEvents = SessionEventInstrumentation.queue.filter {
      $0.eventType == .end && $0.session.id == sessionId
    }
    
    XCTAssertGreaterThanOrEqual(endEvents.count, 1, "Should have at least one session.end event")
    
    // Verify endTimestamp is set (should be background start time)
    if let endEvent = endEvents.first {
      XCTAssertNotNil(endEvent.endTimestamp, "End timestamp should be set for background expiration")
      
      if let endTimestamp = endEvent.endTimestamp {
        // End timestamp should be close to background time (within 100ms tolerance)
        // We use diff because of the timing difference explained above
        let timeDiff = abs(endTimestamp.timeIntervalSince(backgroundTimeBeforeNotification))
        XCTAssertLessThan(timeDiff, 0.1, "End timestamp should be close to background start time (within 100ms)")
        
        // Verify endTimestamp is BEFORE current time (it's the background start time, not foreground return time)
        let currentTime = Date()
        XCTAssertLessThan(endTimestamp, currentTime, "End timestamp should be in the past (background start time)")
        
        // Verify endTimestamp is AFTER session start time
        XCTAssertGreaterThan(endTimestamp, session.startTime, "End timestamp should be after session start")
      }
    }
  }
  #endif
}
