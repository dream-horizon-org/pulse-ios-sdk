# Location Instrumentation

The Location instrumentation adds geo attributes to spans and log records using the device’s location. It is **optional**: PulseKit does not depend on it. If you want location attributes, add the Location module (SPM) or pod (CocoaPods) and enable it in PulseKit’s instrumentation configuration (it is **off** by default).

## Attributes

When location is available and permission is granted, the following attributes are added to spans and log records:

| Attribute | Description |
|-----------|-------------|
| `geo.location.lat` | Latitude (WGS84) |
| `geo.location.lon` | Longitude (WGS84) |
| `geo.country.iso_code` | ISO 3166-1 alpha-2 country code |
| `geo.region.iso_code` | ISO 3166-2 region code |
| `geo.locality.name` | Locality (e.g. city, town) |
| `geo.postal_code` | Postal code |

These follow the [OpenTelemetry Geo semantic conventions](https://opentelemetry.io/docs/specs/semconv/registry/attributes/geo/).

## Behavior

- If location permission is not granted or location is unavailable, no geo attributes are added.
- Location is cached (default: 1 hour) to limit geocoder and location requests.
- On iOS/tvOS, when the app is in the foreground a periodic refresh updates the cache; when the app goes to the background, refresh is paused to save battery. Span and log processors read from this cache.
- On macOS (without UIKit), the provider starts immediately; lifecycle-based pause is not applied.

## Enabling location

1. **Add the Location dependency** (see Installation below). PulseKit does not include Location by default; the app must link the Location module or pod.
2. **Enable it in PulseKit** (location is **off** by default):

```swift
PulseKit.shared.initialize(
    endpointBaseUrl: "https://your-backend.com",
    instrumentations: { config in
        config.location { location in
            location.enabled(true)
        }
    }
)
```

If the Location module is not linked, this block has no effect and PulseKit runs without location attributes.

## Installation

Location is an **optional** dependency. Add it only if you want geo attributes; PulseKit builds and runs without it.

### Swift Package Manager (SPM)

Add both **PulseKit** and **Location** to your target when you want location:

```swift
dependencies: [
    .package(url: "https://github.com/dream-horizon-org/pulse-ios-sdk.git", from: "0.0.1")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "PulseKit", package: "pulse-ios-sdk"),
            .product(name: "Location", package: "pulse-ios-sdk")  // optional: only if you want location
        ]
    )
]
```

- **Without** the `Location` product: PulseKit works as usual; location config is ignored.
- **With** the `Location` product: enable location in config (see above) to add geo attributes.

To use the Location module alone (e.g. custom pipeline without PulseKit):

```swift
.product(name: "Location", package: "pulse-ios-sdk")
```

### CocoaPods

Add the Location pod only if you want location; PulseKit does not require it.

```ruby
pod 'PulseKit', '~> 0.0.1'
# Optional: add only if you want location attributes
pod 'Pulse-Swift-Instrumentation-Location', '~> 0.0.1'
```

Then run:

```bash
pod install
```

The Location pod depends on:

- `OpenTelemetry-Swift-Api` (~> 2.2)
- `OpenTelemetry-Swift-Sdk` (~> 2.2)

**Supported platforms (CocoaPods):** iOS 13.0+, tvOS 13.0+, watchOS 6.0+, visionOS 1.0+, macOS 12.0+.

## Requirements

- **iOS**: Add a location usage description to your app’s `Info.plist`, for example:
  - `NSLocationWhenInUseUsageDescription`
  - Optionally: `NSLocationAlwaysAndWhenInUseUsageDescription` if you need background location.

## Module layout

| Component | Role |
|-----------|------|
| `LocationInstrumentation` | Static install/uninstall API; creates the provider and (on UIKit) registers app lifecycle observers. |
| `LocationProvider` | Fetches device location, caches it (in-memory and UserDefaults), and runs reverse geocoding. |
| `LocationAttributesSpanAppender` | `SpanProcessor` that adds geo attributes when a span starts. |
| `LocationAttributesLogRecordProcessor` | `LogRecordProcessor` that adds geo attributes to log records before passing them to the next processor. |
| `LocationConstants` | Cache key and default cache invalidation interval (1 hour). |
| `LocationReverseGeocoding` | Reverse geocoding (coordinates → placemark) for country, region, locality, and postal code. |
| `CachedLocation` | Codable model for cached location (lat/lon, timestamp, optional geo fields). |
