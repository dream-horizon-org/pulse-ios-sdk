/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

public class DeviceResourceProvider: ResourceProvider {
  let deviceSource: IDeviceDataSource

  public init(source: IDeviceDataSource) {
    deviceSource = source
  }

  override public var attributes: [String: AttributeValue] {
    var attributes = [String: AttributeValue]()

    if let deviceModel = deviceSource.model {
      attributes[ResourceAttributes.deviceModelIdentifier.rawValue] = AttributeValue.string(deviceModel)
    }

    if let deviceId = deviceSource.identifier {
      attributes[ResourceAttributes.deviceId.rawValue] = AttributeValue.string(deviceId)
    }
    
    // device.manufacturer (official ResourceAttributes - iOS apps SHOULD hardcode "Apple")
    // OpenTelemetry spec: https://opentelemetry.io/docs/specs/semconv/resource/device/#manufacturer
    #if os(iOS) || os(tvOS) || os(watchOS) || os(macOS)
    attributes[ResourceAttributes.deviceManufacturer.rawValue] = AttributeValue.string("Apple")
    #endif
    
    // device.model.name (official ResourceAttributes - user-friendly model name)
    // UIDevice.model: https://developer.apple.com/documentation/uikit/uidevice
    #if os(iOS) || os(tvOS)
    attributes[ResourceAttributes.deviceModelName.rawValue] = AttributeValue.string(UIDevice.current.model)
    #elseif os(watchOS)
    // WKInterfaceDevice.model: https://developer.apple.com/documentation/watchkit/wkinterfacedevice
    attributes[ResourceAttributes.deviceModelName.rawValue] = AttributeValue.string(WKInterfaceDevice.current().model)
    #endif

    return attributes
  }
}
