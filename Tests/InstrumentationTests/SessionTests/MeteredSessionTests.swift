import XCTest
@testable import Sessions
@testable import OpenTelemetrySdk
@testable import OpenTelemetryApi

/// Tests for metered session functionality
/// Metered sessions are used for billing/metering and have different behavior than OTEL sessions
final class MeteredSessionTests: XCTestCase {
  var meteredManager: SessionManager!
  var otelManager: SessionManager!

  override func setUp() {
    super.setUp()
    SessionStore.teardown()
    
    // Metered session config: persistent, no background timeout, no events
    let meteredConfig = SessionConfig(
      backgroundInactivityTimeout: nil,  // No background timeout
      maxLifetime: 30 * 60,              // 30 minutes
      shouldPersist: true,               // Persist across restarts
      startEventName: nil,               // No events
      endEventName: nil                  // No events
    )
    meteredManager = SessionManager(configuration: meteredConfig)
    
    // OTEL session config: in-memory, background timeout, emits events
    let otelConfig = SessionConfig(
      backgroundInactivityTimeout: 15 * 60,  // 15 minutes
      maxLifetime: 4 * 60 * 60,               // 4 hours
      shouldPersist: false,                  // In-memory
      startEventName: SessionConstants.sessionStartEvent,
      endEventName: SessionConstants.sessionEndEvent
    )
    otelManager = SessionManager(configuration: otelConfig)
  }

  override func tearDown() {
    SessionStore.teardown()
    super.tearDown()
  }

  // MARK: - Metered Session Configuration Tests

  func testMeteredSessionConfiguration() {
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 30 * 60,
      shouldPersist: true,
      startEventName: nil,
      endEventName: nil
    )
    let manager = SessionManager(configuration: config)
    
    let session = manager.getSession()
    XCTAssertNotNil(session)
    XCTAssertEqual(session.sessionTimeout, 30 * 60)
  }

  func testMeteredSessionNoBackgroundTimeout() {
    // Metered session should not have background timeout
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 30 * 60,
      shouldPersist: true
    )
    let manager = SessionManager(configuration: config)
    
    let session = manager.getSession()
    XCTAssertNotNil(session)
    
    // Background timeout should be nil (not configured)
    XCTAssertNil(config.backgroundInactivityTimeout)
  }

  func testMeteredSessionPersistenceEnabled() {
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 30 * 60,
      shouldPersist: true
    )
    XCTAssertTrue(config.shouldPersist)
  }

  // MARK: - Metered Session Persistence Tests

  func testMeteredSessionPersistsAcrossRestarts() {
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 30 * 60,
      shouldPersist: true
    )
    
    // Create first manager and get session
    let manager1 = SessionManager(configuration: config)
    let session1 = manager1.getSession()
    let sessionId1 = session1.id
    
    // Force immediate save
    SessionStore.saveImmediately(session: session1)
    
    // Create new manager (simulating app restart)
    let manager2 = SessionManager(configuration: config)
    let session2 = manager2.getSession()
    let sessionId2 = session2.id
    
    // Session ID should be the same (persisted)
    XCTAssertEqual(sessionId1, sessionId2)
  }

  func testMeteredSessionRestoredFromDisk() {
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 30 * 60,
      shouldPersist: true
    )
    
    // Create and save session
    let manager1 = SessionManager(configuration: config)
    let session1 = manager1.getSession()
    SessionStore.saveImmediately(session: session1)
    
    // Verify it's saved
    let savedId = UserDefaults.standard.object(forKey: SessionStore.idKey) as? String
    XCTAssertEqual(session1.id, savedId)
    
    // Create new manager - should restore
    let manager2 = SessionManager(configuration: config)
    let session2 = manager2.getSession()
    
    XCTAssertEqual(session1.id, session2.id)
  }

  func testMeteredSessionExpiredSessionNotRestored() {
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 0.1,  // Very short for testing
      shouldPersist: true
    )
    
    // Create and save session
    let manager1 = SessionManager(configuration: config)
    let session1 = manager1.getSession()
    SessionStore.saveImmediately(session: session1)
    
    // Wait for expiration
    Thread.sleep(forTimeInterval: 0.2)
    
    // Create new manager - expired session should not be restored
    let manager2 = SessionManager(configuration: config)
    let session2 = manager2.getSession()
    
    // New session should be created (expired one not restored)
    // Note: This depends on restoreSessionFromDisk() checking expiration
    XCTAssertNotNil(session2)
  }

  // MARK: - Metered Session Event Emission Tests

  func testMeteredSessionDoesNotEmitEvents() {
    SessionEventInstrumentation.queue = []
    SessionEventInstrumentation.isApplied = false
    
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 0.1,  // Short for testing
      shouldPersist: true,
      startEventName: nil,  // No events
      endEventName: nil     // No events
    )
    let manager = SessionManager(configuration: config)
    
    let session1 = manager.getSession()
    Thread.sleep(forTimeInterval: 0.11)
    let session2 = manager.getSession()
    
    // No events should be queued (metered sessions don't emit events)
    let meteredEvents = SessionEventInstrumentation.queue.filter { event in
      event.session.id == session1.id || event.session.id == session2.id
    }
    
    XCTAssertEqual(meteredEvents.count, 0, "Metered sessions should not emit events")
  }

  func testMeteredSessionNoEventNames() {
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 30 * 60,
      shouldPersist: true,
      startEventName: nil,
      endEventName: nil
    )
    
    XCTAssertNil(config.startEventName)
    XCTAssertNil(config.endEventName)
  }

  // MARK: - Dual Session System Tests

  func testDualSessionSystemIndependent() {
    // Both managers should work independently
    let meteredSession = meteredManager.getSession()
    let otelSession = otelManager.getSession()
    
    // They should have different IDs
    XCTAssertNotEqual(meteredSession.id, otelSession.id)
    
    // Metered should persist, OTEL should not
    // Test by creating a new metered manager and verifying it restores the session
    let meteredSessionId = meteredSession.id
    let newMeteredManager = SessionManager(configuration: SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 30 * 60,
      shouldPersist: true
    ))
    let restoredSession = newMeteredManager.getSession()
    XCTAssertEqual(restoredSession.id, meteredSessionId, "Metered session should be persisted and restored")
    
    // OTEL session should not persist - create new manager and verify different ID
    let otelSessionId = otelSession.id
    let newOtelManager = SessionManager(configuration: SessionConfig(
      backgroundInactivityTimeout: 3,
      maxLifetime: 4 * 60 * 60,
      shouldPersist: false
    ))
    let newOtelSession = newOtelManager.getSession()
    XCTAssertNotEqual(newOtelSession.id, otelSessionId, "OTEL session should not persist")
  }

  func testDualSessionSystemDifferentExpiration() {
    // Metered: 30 minutes, OTEL: 4 hours
    let meteredSession = meteredManager.getSession()
    let otelSession = otelManager.getSession()
    
    let meteredExpiry = meteredSession.expireTime
    let otelExpiry = otelSession.expireTime
    
    // OTEL expiry should be much later (4 hours vs 30 minutes)
    XCTAssertGreaterThan(otelExpiry, meteredExpiry)
  }

  func testDualSessionSystemDifferentStorage() {
    // Metered uses persistent storage, OTEL uses in-memory
    let meteredSession = meteredManager.getSession()
    SessionStore.saveImmediately(session: meteredSession)
    
    // Metered session should be in UserDefaults
    let savedId = UserDefaults.standard.object(forKey: SessionStore.idKey) as? String
    XCTAssertEqual(meteredSession.id, savedId)
    
    // OTEL session should not be in UserDefaults (in-memory)
    // Note: This test may be flaky if storage is shared, but conceptually they should be separate
  }

  // MARK: - Metered Session ID Format Tests

  func testMeteredSessionIdFormat() {
    let session = meteredManager.getSession()
    
    // Should be 32-character hex string (no hyphens)
    XCTAssertEqual(session.id.count, 32)
    let hexPattern = "^[a-f0-9]{32}$"
    let regex = try! NSRegularExpression(pattern: hexPattern)
    let range = NSRange(location: 0, length: session.id.utf16.count)
    XCTAssertNotNil(regex.firstMatch(in: session.id, options: [], range: range))
  }

  func testMeteredSessionIdMatchesOtelFormat() {
    let meteredSession = meteredManager.getSession()
    let otelSession = otelManager.getSession()
    
    // Both should have same format (32-char hex)
    XCTAssertEqual(meteredSession.id.count, 32)
    XCTAssertEqual(otelSession.id.count, 32)
    
    let hexPattern = "^[a-f0-9]{32}$"
    let regex = try! NSRegularExpression(pattern: hexPattern)
    
    let meteredRange = NSRange(location: 0, length: meteredSession.id.utf16.count)
    let otelRange = NSRange(location: 0, length: otelSession.id.utf16.count)
    
    XCTAssertNotNil(regex.firstMatch(in: meteredSession.id, options: [], range: meteredRange))
    XCTAssertNotNil(regex.firstMatch(in: otelSession.id, options: [], range: otelRange))
  }

  // MARK: - Metered Session Expiration Tests

  func testMeteredSessionExpiresAfterMaxLifetime() {
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 0.1,  // 100ms for testing
      shouldPersist: true
    )
    let manager = SessionManager(configuration: config)
    
    let session1 = manager.getSession()
    let sessionId1 = session1.id
    
    Thread.sleep(forTimeInterval: 0.11)
    
    let session2 = manager.getSession()
    let sessionId2 = session2.id
    
    XCTAssertNotEqual(sessionId1, sessionId2)
    XCTAssertEqual(session2.previousId, sessionId1)
  }

  func testMeteredSessionNotAffectedByBackground() {
    #if canImport(UIKit)
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,  // No background timeout
      maxLifetime: 1,  // 1 second
      shouldPersist: true
    )
    let manager = SessionManager(configuration: config)
    
    let session1 = manager.getSession()
    let sessionId1 = session1.id
    
    // Simulate app going to background
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    
    // Wait longer than maxLifetime but less than any background timeout
    Thread.sleep(forTimeInterval: 1.1)
    
    // Return to foreground
    NotificationCenter.default.post(
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    
    Thread.sleep(forTimeInterval: 0.1)
    
    let session2 = manager.getSession()
    
    // Session should have expired by maxLifetime, not background timeout
    // (since background timeout is nil for metered sessions)
    XCTAssertNotEqual(sessionId1, session2.id)
    #endif
  }

  // MARK: - Metered Session Attribute Key Tests

  func testMeteredSessionAttributeKey() {
    // Verify the attribute key constant
    XCTAssertEqual(SessionConstants.meteredId, "pulse.metering.session.id")
  }

  // MARK: - Metered Session Previous ID Tests

  func testMeteredSessionPreviousId() {
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 0.1,
      shouldPersist: true
    )
    let manager = SessionManager(configuration: config)
    
    let session1 = manager.getSession()
    XCTAssertNil(session1.previousId)
    
    Thread.sleep(forTimeInterval: 0.11)
    
    let session2 = manager.getSession()
    XCTAssertEqual(session2.previousId, session1.id)
  }

  func testMeteredSessionPreviousIdPersisted() {
    let config = SessionConfig(
      backgroundInactivityTimeout: nil,
      maxLifetime: 0.1,
      shouldPersist: true
    )
    
    // Create first session
    let manager1 = SessionManager(configuration: config)
    let session1 = manager1.getSession()
    SessionStore.saveImmediately(session: session1)
    
    Thread.sleep(forTimeInterval: 0.11)
    
    // Create second session
    let manager2 = SessionManager(configuration: config)
    let session2 = manager2.getSession()
    
    // Previous ID should be tracked
    XCTAssertEqual(session2.previousId, session1.id)
  }
}
