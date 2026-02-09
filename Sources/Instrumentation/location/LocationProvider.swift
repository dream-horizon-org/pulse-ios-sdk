/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import CoreLocation
import MapKit

/// Provides device location with caching and periodic refresh; mimics Android LocationProvider.kt.
/// Writes cached location to UserDefaults for use by LocationAttributesSpanAppender and LocationAttributesLogRecordProcessor.
public final class LocationProvider: NSObject {

    // MARK: - Core Services

    private let locationManager = CLLocationManager()
    private let userDefaults: UserDefaults
    private let cacheKey: String
    private let cacheInvalidationTime: TimeInterval

    // MARK: - Timer

    private var refreshTimer: DispatchSourceTimer?

    // MARK: - Init

    public init(
        userDefaults: UserDefaults = .standard,
        cacheKey: String = LocationConstants.locationCacheKey,
        cacheInvalidationTime: TimeInterval = LocationConstants.defaultCacheInvalidationTime
    ) {
        self.userDefaults = userDefaults
        self.cacheKey = cacheKey
        self.cacheInvalidationTime = cacheInvalidationTime
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: - Public API

    public func startPeriodicRefresh() {
        stopPeriodicRefresh()

        let cached = loadCachedLocation()
        let shouldFetchNow = cached == nil || cached!.isExpired(cacheInvalidationTime)

        if shouldFetchNow {
            requestLocation()
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now() + cacheInvalidationTime, repeating: cacheInvalidationTime)
        timer.setEventHandler { [weak self] in
            self?.requestLocation()
        }
        timer.resume()
        refreshTimer = timer
    }

    public func stopPeriodicRefresh() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    // MARK: - Location

    private func requestLocation() {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, macOS 11.0, *) {
            status = locationManager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }

        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return
        }

        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return
        }

        locationManager.requestLocation()
    }

    // MARK: - Caching

    private func saveLocation(_ cached: CachedLocation) {
        if let data = try? JSONEncoder().encode(cached) {
            userDefaults.set(data, forKey: cacheKey)
        }
    }

    private func loadCachedLocation() -> CachedLocation? {
        guard let data = userDefaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedLocation.self, from: data)
    }

    // MARK: - Reverse Geocoding (Apple-approved)

    private func resolveGeoAttributes(for location: CLLocation) {
        let request = MKLocalSearch.Request()
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 300,
            longitudinalMeters: 300
        )

        let search = MKLocalSearch(request: request)
        search.start { [weak self] response, error in
            guard
                error == nil,
                let item = response?.mapItems.first,
                let self = self
            else { return }

            let address = item.placemark

            let updated = CachedLocation(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                timestamp: Date().timeIntervalSince1970,
                countryIsoCode: address.isoCountryCode,
                regionIsoCode: self.formatRegion(
                    country: address.isoCountryCode,
                    region: address.administrativeArea
                ),
                localityName: address.locality,
                postalCode: address.postalCode
            )

            self.saveLocation(updated)
        }
    }

    private func formatRegion(country: String?, region: String?) -> String? {
        guard let c = country, let r = region else { return nil }
        return "\(c)-\(r.uppercased())"
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationProvider: CLLocationManagerDelegate {

    public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.first else { return }

        let cached = CachedLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: Date().timeIntervalSince1970,
            countryIsoCode: nil,
            regionIsoCode: nil,
            localityName: nil,
            postalCode: nil
        )

        saveLocation(cached)
        resolveGeoAttributes(for: location)
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // Log if needed
    }
}
