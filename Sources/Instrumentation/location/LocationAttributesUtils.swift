/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi

/// OpenTelemetry Geo semantic convention attribute names (incubating).
/// See https://opentelemetry.io/docs/specs/semconv/registry/attributes/geo/
enum GeoAttributes {
    static let geoLocationLat = "geo.location.lat"
    static let geoLocationLon = "geo.location.lon"
    static let geoCountryIsoCode = "geo.country.iso_code"
    static let geoRegionIsoCode = "geo.region.iso_code"
    static let geoLocalityName = "geo.locality.name"
    static let geoPostalCode = "geo.postal_code"
}

/// Internal utility for reading location attributes from cache (mirrors Android LocationAttributesUtils).
enum LocationAttributesUtils {
    /// Retrieves location attributes from the cache in UserDefaults.
    /// Returns empty dictionary if cache is null or expired.
    static func getLocationAttributesFromCache(
        userDefaults: UserDefaults = .standard,
        cacheKey: String = LocationConstants.locationCacheKey,
        cacheInvalidationTime: TimeInterval = LocationConstants.defaultCacheInvalidationTime
    ) -> [String: AttributeValue] {
        guard let data = userDefaults.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(CachedLocation.self, from: data),
              !cached.isExpired(cacheInvalidationTime) else {
            return [:]
        }
        return buildLocationAttributes(cached)
    }

    private static func buildLocationAttributes(_ cached: CachedLocation) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [
            GeoAttributes.geoLocationLat: AttributeValue.double(cached.latitude),
            GeoAttributes.geoLocationLon: AttributeValue.double(cached.longitude)
        ]
        if let v = cached.countryIsoCode { attrs[GeoAttributes.geoCountryIsoCode] = .string(v) }
        if let v = cached.regionIsoCode { attrs[GeoAttributes.geoRegionIsoCode] = .string(v) }
        if let v = cached.localityName { attrs[GeoAttributes.geoLocalityName] = .string(v) }
        if let v = cached.postalCode { attrs[GeoAttributes.geoPostalCode] = .string(v) }
        return attrs
    }
}
