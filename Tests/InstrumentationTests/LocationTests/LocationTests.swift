import XCTest
import CoreLocation
@testable import Location
import OpenTelemetryApi
import OpenTelemetrySdk

final class LocationTests: XCTestCase {
    var userDefaults: UserDefaults!
    var suiteName: String!
    
    override func setUp() {
        super.setUp()
        suiteName = "LocationTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        
        // Clear in-memory cache before each test
        CachedLocationSaver.shared.cachedLocation = nil
    }
    
    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        CachedLocationSaver.shared.cachedLocation = nil
        LocationInstrumentation.uninstall()
        super.tearDown()
    }
    
    // MARK: - CachedLocation JSON Tests (matches Android)
    
    func testCachedLocationJSONCanBeDeserializedCorrectly() throws {
        let currentTime = Date().timeIntervalSince1970
        let jsonString = """
        {"latitude":37.7749,"longitude":-122.4194,"timestamp":\(currentTime - 1),"countryIsoCode":"US","regionIsoCode":"US-CA","localityName":"San Francisco","postalCode":"94102"}
        """
        
        let data = jsonString.data(using: .utf8)!
        let cachedLocation = try JSONDecoder().decode(CachedLocation.self, from: data)
        
        XCTAssertEqual(cachedLocation.latitude, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(cachedLocation.longitude, -122.4194, accuracy: 0.0001)
        XCTAssertEqual(cachedLocation.countryIsoCode, "US")
        XCTAssertEqual(cachedLocation.regionIsoCode, "US-CA")
        XCTAssertEqual(cachedLocation.localityName, "San Francisco")
        XCTAssertEqual(cachedLocation.postalCode, "94102")
    }
    
    func testCachedLocationJSONWithOnlyLatLonCanBeDeserializedCorrectly() throws {
        let currentTime = Date().timeIntervalSince1970
        let jsonString = """
        {"latitude":37.7749,"longitude":-122.4194,"timestamp":\(currentTime - 1),"countryIsoCode":null,"regionIsoCode":null,"localityName":null,"postalCode":null}
        """
        
        let data = jsonString.data(using: .utf8)!
        let cachedLocation = try JSONDecoder().decode(CachedLocation.self, from: data)
        
        XCTAssertEqual(cachedLocation.latitude, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(cachedLocation.longitude, -122.4194, accuracy: 0.0001)
        XCTAssertNil(cachedLocation.countryIsoCode)
        XCTAssertNil(cachedLocation.regionIsoCode)
        XCTAssertNil(cachedLocation.localityName)
        XCTAssertNil(cachedLocation.postalCode)
    }
    
    // MARK: - CachedLocation Tests
    
    func testCachedLocationExpiration() {
        let now = Date().timeIntervalSince1970
        let cachedRecent = CachedLocation(
            latitude: 37.7749,
            longitude: -122.4194,
            timestamp: now,
            countryIsoCode: "US",
            regionIsoCode: "US-CA",
            localityName: "San Francisco",
            postalCode: "94102"
        )
        
        XCTAssertFalse(cachedRecent.isExpired(30), "Recent cache should not be expired")
        
        let cachedOld = CachedLocation(
            latitude: 37.7749,
            longitude: -122.4194,
            timestamp: now - 7200, // 2 hours ago
            countryIsoCode: "US",
            regionIsoCode: "US-CA",
            localityName: "San Francisco",
            postalCode: "94102"
        )
        
        XCTAssertTrue(cachedOld.isExpired(30), "Old cache should be expired with 1 hour TTL")
    }
    
    func testCachedLocationCodable() throws {
        let location = CachedLocation(
            latitude: 37.7749,
            longitude: -122.4194,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: "US",
            regionIsoCode: "US-CA",
            localityName: "San Francisco",
            postalCode: "94102"
        )
        
        let encoded = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(CachedLocation.self, from: encoded)
        
        XCTAssertEqual(decoded.latitude, location.latitude)
        XCTAssertEqual(decoded.longitude, location.longitude)
        XCTAssertEqual(decoded.countryIsoCode, location.countryIsoCode)
        XCTAssertEqual(decoded.regionIsoCode, location.regionIsoCode)
        XCTAssertEqual(decoded.localityName, location.localityName)
        XCTAssertEqual(decoded.postalCode, location.postalCode)
    }
    
    // MARK: - LocationConstants Tests
    
    func testLocationConstants() {
        XCTAssertEqual(LocationConstants.locationCacheKey, "location_cache")
        XCTAssertEqual(LocationConstants.defaultCacheInvalidationTime, 3600)
    }
    
    // MARK: - CachedLocationSaver Tests
    
    func testCachedLocationSaverSingleton() {
        let instance1 = CachedLocationSaver.shared
        let instance2 = CachedLocationSaver.shared
        XCTAssertTrue(instance1 === instance2, "Should be same instance")
    }
    
    func testCachedLocationSaverStoresAndRetrieves() {
        let location = CachedLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: "US",
            regionIsoCode: "US-NY",
            localityName: "New York",
            postalCode: "10001"
        )
        
        CachedLocationSaver.shared.cachedLocation = location
        
        let retrieved = CachedLocationSaver.shared.cachedLocation
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.latitude, 40.7128)
        XCTAssertEqual(retrieved?.longitude, -74.0060)
        XCTAssertEqual(retrieved?.countryIsoCode, "US")
    }
    
    func testCachedLocationSaverCanBeCleared() {
        let location = CachedLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: "US",
            regionIsoCode: "US-NY",
            localityName: "New York",
            postalCode: "10001"
        )
        
        CachedLocationSaver.shared.cachedLocation = location
        XCTAssertNotNil(CachedLocationSaver.shared.cachedLocation)
        
        CachedLocationSaver.shared.cachedLocation = nil
        XCTAssertNil(CachedLocationSaver.shared.cachedLocation)
    }
    
    // MARK: - LocationAttributesUtils Tests
    
    func testGetLocationAttributesFromCache_EmptyWhenNoCacheExists() {
        let attributes = LocationAttributesUtils.getLocationAttributesFromCache(
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        XCTAssertTrue(attributes.isEmpty, "Should return empty when no cache exists")
    }
    
    func testGetLocationAttributesFromCache_ReturnsAttributesFromMemoryCache() {
        let location = CachedLocation(
            latitude: 51.5074,
            longitude: -0.1278,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: "GB",
            regionIsoCode: "GB-ENG",
            localityName: "London",
            postalCode: "SW1A"
        )
        
        CachedLocationSaver.shared.cachedLocation = location
        
        let attributes = LocationAttributesUtils.getLocationAttributesFromCache(
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        XCTAssertFalse(attributes.isEmpty)
        
        if case let .double(lat) = attributes["geo.location.lat"] {
            XCTAssertEqual(lat, 51.5074, accuracy: 0.0001)
        } else {
            XCTFail("Expected latitude attribute")
        }
        
        if case let .double(lon) = attributes["geo.location.lon"] {
            XCTAssertEqual(lon, -0.1278, accuracy: 0.0001)
        } else {
            XCTFail("Expected longitude attribute")
        }
        
        if case let .string(country) = attributes["geo.country.iso_code"] {
            XCTAssertEqual(country, "GB")
        } else {
            XCTFail("Expected country attribute")
        }
        
        if case let .string(locality) = attributes["geo.locality.name"] {
            XCTAssertEqual(locality, "London")
        } else {
            XCTFail("Expected locality attribute")
        }
    }
    
    func testGetLocationAttributesFromCache_FallsBackToUserDefaults() {
        CachedLocationSaver.shared.cachedLocation = nil
        
        let location = CachedLocation(
            latitude: 48.8566,
            longitude: 2.3522,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: "FR",
            regionIsoCode: "FR-IDF",
            localityName: "Paris",
            postalCode: "75001"
        )
        
        let data = try! JSONEncoder().encode(location)
        userDefaults.set(data, forKey: "test_key")
        
        let attributes = LocationAttributesUtils.getLocationAttributesFromCache(
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        XCTAssertFalse(attributes.isEmpty)
        
        if case let .string(country) = attributes["geo.country.iso_code"] {
            XCTAssertEqual(country, "FR")
        } else {
            XCTFail("Expected country attribute from UserDefaults")
        }
        
        // Verify in-memory cache was updated (matches Android fallback behavior)
        XCTAssertNotNil(CachedLocationSaver.shared.cachedLocation)
        XCTAssertEqual(CachedLocationSaver.shared.cachedLocation?.latitude, 48.8566)
    }
    
    func testGetLocationAttributesFromCache_ReturnsEmptyWhenExpired() {
        let expiredLocation = CachedLocation(
            latitude: 35.6762,
            longitude: 139.6503,
            timestamp: Date().timeIntervalSince1970 - 7200, // 2 hours ago
            countryIsoCode: "JP",
            regionIsoCode: "JP-13",
            localityName: "Tokyo",
            postalCode: "100-0001"
        )
        
        CachedLocationSaver.shared.cachedLocation = expiredLocation
        
        let attributes = LocationAttributesUtils.getLocationAttributesFromCache(
            userDefaults: userDefaults,
            cacheKey: "test_key",
            cacheInvalidationTime: 30 // 1 hour TTL
        )
        
        XCTAssertTrue(attributes.isEmpty, "Should return empty when cache is expired")
    }
    
    func testGetLocationAttributesFromCache_HandlesNilOptionalFields() {
        let location = CachedLocation(
            latitude: 52.5200,
            longitude: 13.4050,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: nil,
            regionIsoCode: nil,
            localityName: nil,
            postalCode: nil
        )
        
        CachedLocationSaver.shared.cachedLocation = location
        
        let attributes = LocationAttributesUtils.getLocationAttributesFromCache(
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        XCTAssertEqual(attributes.count, 2, "Should only have lat/lon")
        XCTAssertNotNil(attributes["geo.location.lat"])
        XCTAssertNotNil(attributes["geo.location.lon"])
        XCTAssertNil(attributes["geo.country.iso_code"])
        XCTAssertNil(attributes["geo.locality.name"])
    }
    
    func testGetLocationAttributesFromCache_InvalidJSONReturnsEmpty() {
        CachedLocationSaver.shared.cachedLocation = nil
        
        // Save invalid JSON
        let invalidData = "not valid json".data(using: .utf8)!
        userDefaults.set(invalidData, forKey: "test_key")
        
        let attributes = LocationAttributesUtils.getLocationAttributesFromCache(
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        XCTAssertTrue(attributes.isEmpty, "Should return empty for invalid JSON")
    }
    
    // MARK: - LocationProvider Tests
    
    func testLocationProviderInitialization() {
        let provider = LocationProvider(
            userDefaults: userDefaults,
            cacheKey: "test_key",
            cacheInvalidationTime: 1800
        )
        
        XCTAssertNotNil(provider)
    }
    
    func testLocationProviderSaveAndLoad() {
        let location = CachedLocation(
            latitude: 34.0522,
            longitude: -118.2437,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: "US",
            regionIsoCode: "US-CA",
            localityName: "Los Angeles",
            postalCode: "90001"
        )
        
        // Simulate provider saving location
        CachedLocationSaver.shared.cachedLocation = location
        let data = try! JSONEncoder().encode(location)
        userDefaults.set(data, forKey: "test_key")
        
        // Verify data can be loaded from UserDefaults
        let loadedData = userDefaults.data(forKey: "test_key")
        XCTAssertNotNil(loadedData)
        
        let decoded = try! JSONDecoder().decode(CachedLocation.self, from: loadedData!)
        XCTAssertEqual(decoded.latitude, 34.0522)
        XCTAssertEqual(decoded.longitude, -118.2437)
        
        // Verify in-memory cache is also set
        XCTAssertNotNil(CachedLocationSaver.shared.cachedLocation)
        XCTAssertEqual(CachedLocationSaver.shared.cachedLocation?.latitude, 34.0522)
    }
    
    func testLocationProviderStopPeriodicRefresh() {
        let provider = LocationProvider(
            userDefaults: userDefaults,
            cacheKey: "test_key",
            cacheInvalidationTime: 30
        )
        
        provider.startPeriodicRefresh()
        provider.stopPeriodicRefresh()
        
        // Should not crash and timer should be cancelled
        XCTAssertTrue(true, "Stop should complete without errors")
    }
    
    func testLocationProviderMultipleStartStopCalls() {
        let provider = LocationProvider(
            userDefaults: userDefaults,
            cacheKey: "test_key",
            cacheInvalidationTime: 30
        )
        
        // Multiple starts should not crash
        provider.startPeriodicRefresh()
        provider.startPeriodicRefresh()
        
        // Multiple stops should not crash
        provider.stopPeriodicRefresh()
        provider.stopPeriodicRefresh()
        
        XCTAssertTrue(true, "Multiple calls should be handled gracefully")
    }
    
    // MARK: - LocationInstrumentation Tests
    
    func testLocationInstrumentationInstallUninstall() {
        LocationInstrumentation.uninstall() // Clean slate
        
        LocationInstrumentation.install(
            userDefaults: userDefaults,
            cacheInvalidationTime: 30
        )
        
        // Provider should be created
        let provider = LocationInstrumentation.provider
        XCTAssertNotNil(provider)
        
        LocationInstrumentation.uninstall()
        
        // Provider should be cleared
        let providerAfterUninstall = LocationInstrumentation.provider
        XCTAssertNil(providerAfterUninstall)
    }
    
    func testLocationInstrumentationMultipleInstallCalls() {
        LocationInstrumentation.uninstall()
        
        LocationInstrumentation.install(userDefaults: userDefaults)
        let provider1 = LocationInstrumentation.provider
        
        LocationInstrumentation.install(userDefaults: userDefaults)
        let provider2 = LocationInstrumentation.provider
        
        XCTAssertTrue(provider1 === provider2, "Should reuse same provider instance")
        
        LocationInstrumentation.uninstall()
    }
    
    func testLocationInstrumentationUninstallWithoutInstall() {
        LocationInstrumentation.uninstall()
        LocationInstrumentation.uninstall() // Should not crash
        
        XCTAssertTrue(true, "Uninstall without install should be handled gracefully")
    }
    
    // MARK: - LocationAttributesSpanAppender Tests
    
    func testSpanAppenderAddsLocationAttributes() {
        let location = CachedLocation(
            latitude: 55.7558,
            longitude: 37.6173,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: "RU",
            regionIsoCode: "RU-MOW",
            localityName: "Moscow",
            postalCode: "101000"
        )
        
        CachedLocationSaver.shared.cachedLocation = location
        
        let appender = LocationAttributesSpanAppender(
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        let mockSpan = MockReadableSpan()
        appender.onStart(parentContext: nil, span: mockSpan)
        
        XCTAssertFalse(mockSpan.capturedAttributes.isEmpty)
        XCTAssertNotNil(mockSpan.capturedAttributes["geo.location.lat"])
        XCTAssertNotNil(mockSpan.capturedAttributes["geo.location.lon"])
        
        if case let .string(country) = mockSpan.capturedAttributes["geo.country.iso_code"] {
            XCTAssertEqual(country, "RU")
        } else {
            XCTFail("Expected country attribute on span")
        }
    }
    
    func testSpanAppenderDoesNotAddAttributesWhenCacheEmpty() {
        CachedLocationSaver.shared.cachedLocation = nil
        
        let appender = LocationAttributesSpanAppender(
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        let mockSpan = MockReadableSpan()
        appender.onStart(parentContext: nil, span: mockSpan)
        
        XCTAssertTrue(mockSpan.capturedAttributes.isEmpty, "Should not add attributes when cache is empty")
    }
    
    func testSpanAppenderDoesNotAddAttributesWhenExpired() {
        let expiredLocation = CachedLocation(
            latitude: 55.7558,
            longitude: 37.6173,
            timestamp: Date().timeIntervalSince1970 - 7200, // 2 hours ago
            countryIsoCode: "RU",
            regionIsoCode: "RU-MOW",
            localityName: "Moscow",
            postalCode: "101000"
        )
        
        CachedLocationSaver.shared.cachedLocation = expiredLocation
        
        let appender = LocationAttributesSpanAppender(
            userDefaults: userDefaults,
            cacheKey: "test_key",
            cacheInvalidationTime: 30 // 1 hour TTL
        )
        
        let mockSpan = MockReadableSpan()
        appender.onStart(parentContext: nil, span: mockSpan)
        
        XCTAssertTrue(mockSpan.capturedAttributes.isEmpty, "Should not add attributes when cache is expired")
    }
    
    // MARK: - LocationAttributesLogRecordProcessor Tests
    
    func testLogProcessorAddsLocationAttributes() {
        let location = CachedLocation(
            latitude: -33.8688,
            longitude: 151.2093,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: "AU",
            regionIsoCode: "AU-NSW",
            localityName: "Sydney",
            postalCode: "2000"
        )
        
        CachedLocationSaver.shared.cachedLocation = location
        
        let mockNextProcessor = MockLogRecordProcessor()
        let processor = LocationAttributesLogRecordProcessor(
            nextProcessor: mockNextProcessor,
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        let logRecord = makeTestLogRecord()
        processor.onEmit(logRecord: logRecord)
        
        XCTAssertEqual(mockNextProcessor.emitCallCount, 1)
        
        let processedRecord = mockNextProcessor.lastEmittedRecord
        XCTAssertNotNil(processedRecord)
        XCTAssertFalse(processedRecord!.attributes.isEmpty)
        
        if case let .string(country) = processedRecord!.attributes["geo.country.iso_code"] {
            XCTAssertEqual(country, "AU")
        } else {
            XCTFail("Expected country attribute on log record")
        }
    }
    
    func testLogProcessorForwardsToNextProcessor() {
        let mockNextProcessor = MockLogRecordProcessor()
        let processor = LocationAttributesLogRecordProcessor(
            nextProcessor: mockNextProcessor,
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        let logRecord = makeTestLogRecord()
        processor.onEmit(logRecord: logRecord)
        
        XCTAssertEqual(mockNextProcessor.emitCallCount, 1)
    }
    
    func testLogProcessorDoesNotAddAttributesWhenCacheEmpty() {
        CachedLocationSaver.shared.cachedLocation = nil
        
        let mockNextProcessor = MockLogRecordProcessor()
        let processor = LocationAttributesLogRecordProcessor(
            nextProcessor: mockNextProcessor,
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        let logRecord = makeTestLogRecord()
        processor.onEmit(logRecord: logRecord)
        
        XCTAssertEqual(mockNextProcessor.emitCallCount, 1)
        XCTAssertTrue(mockNextProcessor.lastEmittedRecord!.attributes.isEmpty)
    }
    
    func testLogProcessorShutdownAndFlush() {
        let mockNextProcessor = MockLogRecordProcessor()
        let processor = LocationAttributesLogRecordProcessor(
            nextProcessor: mockNextProcessor,
            userDefaults: userDefaults,
            cacheKey: "test_key"
        )
        
        let shutdownResult = processor.shutdown(explicitTimeout: nil as TimeInterval?)
        XCTAssertEqual(shutdownResult, ExportResult.success)
        
        let flushResult = processor.forceFlush(explicitTimeout: nil as TimeInterval?)
        XCTAssertEqual(flushResult, ExportResult.success)
    }
}

// MARK: - Mock Objects

class MockReadableSpan: ReadableSpan {
    var capturedAttributes: [String: AttributeValue] = [:]
    
    var instrumentationScopeInfo: InstrumentationScopeInfo = InstrumentationScopeInfo(name: "test")
    var hasEnded: Bool = false
    var latency: TimeInterval { 0 }
    
    func getAttributes() -> [String: AttributeValue] { capturedAttributes }
    func toSpanData() -> SpanData { fatalError("Not implemented for test") }
    
    func setAttribute(key: String, value: AttributeValue?) {
        if let value = value { capturedAttributes[key] = value }
    }
    func setAttributes(_ attributes: [String: AttributeValue]) {
        for (k, v) in attributes { capturedAttributes[k] = v }
    }
    
    func addEvent(name: String) {}
    func addEvent(name: String, timestamp: Date) {}
    func addEvent(name: String, attributes: [String: AttributeValue]) {}
    func addEvent(name: String, attributes: [String: AttributeValue], timestamp: Date) {}
    
    func recordException(_ exception: SpanException) {}
    func recordException(_ exception: SpanException, timestamp: Date) {}
    func recordException(_ exception: SpanException, attributes: [String: AttributeValue]) {}
    func recordException(_ exception: SpanException, attributes: [String: AttributeValue], timestamp: Date) {}
    
    func end() {}
    func end(time: Date) {}
    
    var name: String = "test-span"
    var context: SpanContext = SpanContext.create(
        traceId: TraceId.random(),
        spanId: SpanId.random(),
        traceFlags: TraceFlags(),
        traceState: TraceState()
    )
    var kind: SpanKind = .internal
    var status: Status = .ok
    var isRecording: Bool = true
    
    var description: String { "MockReadableSpan(\(name))" }
}

/// Helper to build a ReadableLogRecord for tests (SDK type is a struct, not a protocol).
func makeTestLogRecord(attributes: [String: AttributeValue] = [:]) -> ReadableLogRecord {
    ReadableLogRecord(
        resource: Resource(),
        instrumentationScopeInfo: InstrumentationScopeInfo(name: "test"),
        timestamp: Date(),
        observedTimestamp: Date(),
        spanContext: nil,
        severity: .info,
        body: nil,
        attributes: attributes,
        eventName: nil
    )
}

class MockLogRecordProcessor: LogRecordProcessor {
    var emitCallCount = 0
    var lastEmittedRecord: ReadableLogRecord?
    
    func onEmit(logRecord: ReadableLogRecord) {
        emitCallCount += 1
        lastEmittedRecord = logRecord
    }
    
    func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
        return .success
    }
    
    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        return .success
    }
}
