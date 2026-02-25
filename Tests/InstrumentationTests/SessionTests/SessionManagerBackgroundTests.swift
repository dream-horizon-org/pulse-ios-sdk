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
      backgroundInactivityTimeout: 3,
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
    Thread.sleep(forTimeInterval: 4)
    
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
    Thread.sleep(forTimeInterval: 4)
    
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
    Thread.sleep(forTimeInterval: 1)
    
    // Simulate app returning to foreground
    NotificationCenter.default.post(
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    Thread.sleep(forTimeInterval: 0.1)
    
    let newSession = sessionManager.getSession()
    
    // Session should still be the same (not expired)
    XCTAssertEqual(sessionId, newSession.id)
  }

  func testBackgroundStartTimeCaptured() {
    let session = sessionManager.getSession()
    
    // Simulate app going to background
    let backgroundTime = Date()
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    // Background time should be captured (we can't directly verify, but session should expire correctly)
    Thread.sleep(forTimeInterval: 4)
    
    NotificationCenter.default.post(
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    Thread.sleep(forTimeInterval: 0.1)
    
    let newSession = sessionManager.getSession()
    
    // Session should have expired
    XCTAssertNotEqual(session.id, newSession.id)
  }
  #endif

  // MARK: - Background + MaxLifetime Tests

  #if canImport(UIKit)
  func testSessionExpiresByMaxLifetimeInBackground() {
    // Use short maxLifetime for testing
    let config = SessionConfig(
      backgroundInactivityTimeout: 10, // 10 seconds
      maxLifetime: 1, // 1 second
      shouldPersist: false
    )
    sessionManager = SessionManager(configuration: config)
    
    let session = sessionManager.getSession()
    let sessionId = session.id
    
    // Wait for maxLifetime to expire
    Thread.sleep(forTimeInterval: 1.1)
    
    // Even in foreground, session should expire by maxLifetime
    let newSession = sessionManager.getSession()
    
    XCTAssertNotEqual(sessionId, newSession.id)
    XCTAssertEqual(newSession.previousId, sessionId)
  }

  func testSessionExpiresByBackgroundTimeoutBeforeMaxLifetime() {
    // Background timeout shorter than maxLifetime
    let config = SessionConfig(
      backgroundInactivityTimeout: 1, // 1 second
      maxLifetime: 10, // 10 seconds
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
    
    // Capture background time
    let backgroundTime = Date()
    
    // Go to background
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    // Wait for timeout
    Thread.sleep(forTimeInterval: 4)
    
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
    
    XCTAssertGreaterThanOrEqual(endEvents.count, 1)
    
    // Verify endTimestamp is set (should be background start time)
    if let endEvent = endEvents.first {
      XCTAssertNotNil(endEvent.endTimestamp)
      // End timestamp should be close to background time (within 1 second)
      if let endTimestamp = endEvent.endTimestamp {
        let timeDiff = abs(endTimestamp.timeIntervalSince(backgroundTime))
        XCTAssertLessThan(timeDiff, 1.0, "End timestamp should be close to background start time")
      }
    }
  }
  #endif
}
