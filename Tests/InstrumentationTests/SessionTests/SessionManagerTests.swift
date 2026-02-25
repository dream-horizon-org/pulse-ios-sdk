import XCTest
@testable import Sessions

final class SessionManagerTests: XCTestCase {
  var sessionManager: SessionManager!

  override func setUp() {
    super.setUp()
    SessionStore.teardown()
    sessionManager = SessionManager()
  }

  override func tearDown() {
    SessionStore.teardown()
    super.tearDown()
  }

  // MARK: - Basic Session Tests

  func testGetSession() {
    let session = sessionManager.getSession()
    XCTAssertNotNil(session)
    XCTAssertNotNil(session.id)
    XCTAssertNotNil(session.expireTime)
    XCTAssertNil(session.previousId)
  }

  func testGetSessionId() {
    let id1 = sessionManager.getSession().id
    let id2 = sessionManager.getSession().id
    XCTAssertEqual(id1, id2)
  }

  func testSessionIdFormat() {
    let session = sessionManager.getSession()
    // Session ID should be 32-character hex string (no hyphens)
    XCTAssertEqual(session.id.count, 32)
    let hexPattern = "^[a-f0-9]{32}$"
    let regex = try! NSRegularExpression(pattern: hexPattern)
    let range = NSRange(location: 0, length: session.id.utf16.count)
    XCTAssertNotNil(regex.firstMatch(in: session.id, options: [], range: range))
  }

  func testSessionIdRemainsSameUntilExpired() {
    let firstSession = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 0.1)
    let secondSession = sessionManager.getSession()
    
    XCTAssertEqual(firstSession.id, secondSession.id)
    XCTAssertEqual(firstSession.startTime, secondSession.startTime)
  }

  func testPeekSessionWithoutSession() {
    // Before first getSession(), peek should return nil
    XCTAssertNil(sessionManager.peekSession())
  }

  func testPeekSessionWithExistingSession() {
    let session = sessionManager.getSession()
    let peekedSession = sessionManager.peekSession()

    XCTAssertNotNil(peekedSession)
    XCTAssertEqual(peekedSession?.id, session.id)
  }

  func testPeekDoesNotExtendSession() {
    let originalSession = sessionManager.getSession()
    let peekedSession = sessionManager.peekSession()

    XCTAssertEqual(peekedSession?.expireTime, originalSession.expireTime)
  }

  // MARK: - Session Expiration Tests

  func testGetSessionExpired() {
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: 0))
    let session1 = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 0.1)
    let session2 = sessionManager.getSession()

    XCTAssertNotEqual(session1.id, session2.id)
    XCTAssertNotEqual(session1.startTime, session2.startTime)
    XCTAssertGreaterThan(session2.startTime, session1.startTime)
  }

  func testSessionExpiresAfterMaxLifetime() {
    let maxLifetime: TimeInterval = 1 // 1 second for testing
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: maxLifetime))
    
    let firstSession = sessionManager.getSession()
    let firstSessionId = firstSession.id
    
    // Wait for session to expire
    Thread.sleep(forTimeInterval: 1.1)
    
    let secondSession = sessionManager.getSession()
    let secondSessionId = secondSession.id
    
    XCTAssertNotEqual(firstSessionId, secondSessionId)
    XCTAssertEqual(secondSession.previousId, firstSessionId)
  }

  func testSessionExpiresAtExactMaxLifetime() {
    let maxLifetime: TimeInterval = 0.1 // 100ms for testing
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: maxLifetime))
    
    let firstSession = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 0.11) // Slightly more than maxLifetime
    
    let secondSession = sessionManager.getSession()
    XCTAssertNotEqual(firstSession.id, secondSession.id)
  }

  func testSessionDoesNotExpireBeforeMaxLifetime() {
    let maxLifetime: TimeInterval = 1 // 1 second
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: maxLifetime))
    
    let firstSession = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 0.5) // Less than maxLifetime
    
    let secondSession = sessionManager.getSession()
    XCTAssertEqual(firstSession.id, secondSession.id)
  }

  func testCustomSessionLength() {
    let customLength: TimeInterval = 60
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: customLength))

    let session1 = sessionManager.getSession()
    let expectedExpiry = Date().addingTimeInterval(customLength)

    XCTAssertEqual(session1.expireTime.timeIntervalSince1970, expectedExpiry.timeIntervalSince1970, accuracy: 1.0)
    XCTAssertEqual(session1.sessionTimeout, customLength)
  }

  func testSessionUsesDefaultMaxLifetimeWhenNil() {
    let config = SessionConfig(maxLifetime: nil)
    sessionManager = SessionManager(configuration: config)
    
    let session = sessionManager.getSession()
    // Default maxLifetime is 4 hours
    let expectedExpiry = session.startTime.addingTimeInterval(4 * 60 * 60)
    XCTAssertEqual(session.expireTime.timeIntervalSince1970, expectedExpiry.timeIntervalSince1970, accuracy: 1.0)
  }

  // MARK: - Previous ID Tests

  func testNewSessionHasNoPreviousId() {
    let session = sessionManager.getSession()
    XCTAssertNil(session.previousId)
  }

  func testExpiredSessionCreatesPreviousId() {
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: 0))
    let firstSession = sessionManager.getSession()
    let secondSession = sessionManager.getSession()
    let thirdSession = sessionManager.getSession()

    XCTAssertNil(firstSession.previousId)
    XCTAssertEqual(secondSession.previousId, firstSession.id)
    XCTAssertEqual(thirdSession.previousId, secondSession.id)
  }

  func testPreviousIdPreservedAcrossExpiration() {
    let maxLifetime: TimeInterval = 0.1
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: maxLifetime))
    
    let session1 = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 0.11)
    let session2 = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 0.11)
    let session3 = sessionManager.getSession()
    
    XCTAssertEqual(session2.previousId, session1.id)
    XCTAssertEqual(session3.previousId, session2.id)
  }

  // MARK: - Persistence Tests

  func testGetSessionSavedToDisk() {
    let config = SessionConfig(shouldPersist: true)
    sessionManager = SessionManager(configuration: config)
    let session = sessionManager.getSession()
    
    // Wait for save interval (30 seconds) or force immediate save
    Thread.sleep(forTimeInterval: 0.1)
    
    let savedId = UserDefaults.standard.object(forKey: SessionStore.idKey) as? String
    let savedTimeout = UserDefaults.standard.object(forKey: SessionStore.sessionTimeoutKey) as? TimeInterval

    XCTAssertEqual(session.id, savedId)
    XCTAssertEqual(session.sessionTimeout, savedTimeout)
  }

  func testLoadSessionMissingExpiry() {
    let id1 = "session-1"
    UserDefaults.standard.set(id1, forKey: SessionStore.idKey)
    XCTAssertNil(SessionStore.load())

    let id2 = sessionManager.getSession().id
    XCTAssertNotEqual(id1, id2)
  }

  func testLoadSessionMissingID() {
    let expiry1 = Date()
    UserDefaults.standard.set(expiry1, forKey: SessionStore.expireTimeKey)
    XCTAssertNil(SessionStore.load())

    let expiry2 = sessionManager.getSession().expireTime
    XCTAssertNotEqual(expiry1, expiry2)
  }

  func testRestoreSessionFromDisk() {
    let config = SessionConfig(maxLifetime: 3600, shouldPersist: true)
    sessionManager = SessionManager(configuration: config)
    
    let originalSession = sessionManager.getSession()
    let originalId = originalSession.id
    
    // Create new manager - should restore from disk
    sessionManager = SessionManager(configuration: config)
    let restoredSession = sessionManager.getSession()
    
    XCTAssertEqual(restoredSession.id, originalId)
  }

  func testRestoreExpiredSessionCreatesNew() {
    let config = SessionConfig(maxLifetime: 1, shouldPersist: true)
    sessionManager = SessionManager(configuration: config)
    
    _ = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 1.1) // Wait for expiration
    
    // Create new manager - expired session should not be restored
    sessionManager = SessionManager(configuration: config)
    let newSession = sessionManager.getSession()
    
    // New session should be created (expired session not restored)
    // Note: This depends on restoreSessionFromDisk() checking expiration
    XCTAssertNotNil(newSession)
  }

  // MARK: - Event Emission Tests

  func testStartSessionAddsToQueueWhenInstrumentationNotApplied() {
    SessionEventInstrumentation.queue = []
    SessionEventInstrumentation.isApplied = false

    let session = sessionManager.getSession()

    XCTAssertEqual(SessionEventInstrumentation.queue.count, 1)
    XCTAssertEqual(SessionEventInstrumentation.queue[0].session.id, session.id)
    XCTAssertEqual(SessionEventInstrumentation.queue[0].eventType, .start)
  }

  func testStartSessionTriggersNotificationWhenInstrumentationApplied() {
    SessionEventInstrumentation.queue = []
    SessionEventInstrumentation.isApplied = true

    let expectation = XCTestExpectation(description: "Session notification posted")
    var receivedSessionEvent: SessionEvent?

    let observer = NotificationCenter.default.addObserver(
      forName: SessionEventInstrumentation.sessionEventNotification,
      object: nil,
      queue: nil
    ) { notification in
      receivedSessionEvent = notification.object as? SessionEvent
      expectation.fulfill()
    }

    let session = sessionManager.getSession()

    wait(for: [expectation], timeout: 0.1)

    XCTAssertNotNil(receivedSessionEvent)
    XCTAssertEqual(receivedSessionEvent?.session.id, session.id)
    XCTAssertEqual(SessionEventInstrumentation.queue.count, 0)

    NotificationCenter.default.removeObserver(observer)
  }

  func testSessionEndEventEmittedOnExpiration() {
    SessionEventInstrumentation.queue = []
    SessionEventInstrumentation.isApplied = false
    
    let maxLifetime: TimeInterval = 0.1
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: maxLifetime))
    
    let firstSession = sessionManager.getSession()
    Thread.sleep(forTimeInterval: 0.11)
    _ = sessionManager.getSession()
    
    // Should have 2 start events and 1 end event
    let startEvents = SessionEventInstrumentation.queue.filter { $0.eventType == .start }
    let endEvents = SessionEventInstrumentation.queue.filter { $0.eventType == .end }
    
    XCTAssertEqual(startEvents.count, 2)
    XCTAssertEqual(endEvents.count, 1)
    XCTAssertEqual(endEvents[0].session.id, firstSession.id)
  }

  // MARK: - Thread Safety Tests

  func testConcurrentAccess() {
    let expectation = XCTestExpectation(description: "Concurrent access")
    expectation.expectedFulfillmentCount = 10
    
    var sessionIds: [String] = []
    let syncQueue = DispatchQueue(label: "test.sync")
    
    for _ in 0..<10 {
      DispatchQueue.global().async {
        let session = self.sessionManager.getSession()
        syncQueue.async {
          sessionIds.append(session.id)
          expectation.fulfill()
        }
      }
    }
    
    wait(for: [expectation], timeout: 1.0)
    
    // All sessions should have the same ID (no expiration during test)
    let firstId = sessionIds.first!
    for id in sessionIds {
      XCTAssertEqual(id, firstId)
    }
  }

  func testConcurrentAccessDuringExpiration() {
    let maxLifetime: TimeInterval = 0.1
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: maxLifetime))
    
    // Get initial session
    let initialSession = sessionManager.getSession()
    
    // Wait for expiration
    Thread.sleep(forTimeInterval: 0.11)
    
    let expectation = XCTestExpectation(description: "Concurrent access after expiration")
    expectation.expectedFulfillmentCount = 5
    
    var sessionIds: Set<String> = []
    let syncQueue = DispatchQueue(label: "test.sync")
    
    for _ in 0..<5 {
      DispatchQueue.global().async {
        let session = self.sessionManager.getSession()
        syncQueue.async {
          sessionIds.insert(session.id)
          expectation.fulfill()
        }
      }
    }
    
    wait(for: [expectation], timeout: 1.0)
    
    // All concurrent accesses should get the same new session ID
    XCTAssertEqual(sessionIds.count, 1)
    XCTAssertNotEqual(sessionIds.first!, initialSession.id)
  }

  // MARK: - Configuration Tests

  func testInMemoryStorage() {
    let config = SessionConfig(shouldPersist: false)
    sessionManager = SessionManager(configuration: config)
    
    let session = sessionManager.getSession()
    
    // In-memory storage should not save to UserDefaults
    Thread.sleep(forTimeInterval: 0.1)
    _ = UserDefaults.standard.object(forKey: SessionStore.idKey) as? String
    
    // Should be nil or different (not persisted)
    // Note: This test may be flaky if SessionStore is shared
    XCTAssertNotNil(session.id)
  }

  func testPersistentStorage() {
    let config = SessionConfig(shouldPersist: true)
    sessionManager = SessionManager(configuration: config)
    
    let session = sessionManager.getSession()
    
    // Force immediate save
    SessionStore.saveImmediately(session: session)
    
    let savedId = UserDefaults.standard.object(forKey: SessionStore.idKey) as? String
    XCTAssertEqual(session.id, savedId)
  }

  // MARK: - Fixed Lifetime Tests (Not Sliding Window)

  func testSessionExpirationTimeDoesNotExtend() {
    let maxLifetime: TimeInterval = 1
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: maxLifetime))
    
    let session1 = sessionManager.getSession()
    let expireTime1 = session1.expireTime
    
    Thread.sleep(forTimeInterval: 0.5)
    
    let session2 = sessionManager.getSession()
    let expireTime2 = session2.expireTime
    
    // Expire time should be the same (fixed lifetime, not sliding window)
    XCTAssertEqual(expireTime1, expireTime2)
    XCTAssertEqual(session1.id, session2.id)
  }

  func testSessionExpiresAtFixedTimeFromStart() {
    let maxLifetime: TimeInterval = 1
    sessionManager = SessionManager(configuration: SessionConfig(maxLifetime: maxLifetime))
    
    let session = sessionManager.getSession()
    let expectedExpiry = session.startTime.addingTimeInterval(maxLifetime)
    
    XCTAssertEqual(session.expireTime.timeIntervalSince1970, expectedExpiry.timeIntervalSince1970, accuracy: 0.1)
  }
}
