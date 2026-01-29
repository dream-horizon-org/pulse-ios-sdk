/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

#if !os(watchOS)

  import Foundation
  import Network
  import OpenTelemetryApi
  import OpenTelemetrySdk

  /// Starts monitoring network path changes and emits `network.change` log events via the given logger.
  /// Keeps all log emission logic in NetworkStatus; caller (e.g. PulseKit config) only passes the logger.
  public enum NetworkChangeReporter {
    private static var monitor: NetworkMonitor?

    private static let networkStatusKey = "network.status"
    private static let networkConnectionTypeKey = "network.connection.type"

    /// Starts the reporter; emits a log record on the given logger when connection changes.
    public static func start(logger: Logger) {
      do {
        let m = try NetworkMonitor()
        NetworkChangeReporter.monitor = m
        m.onConnectionChange = { connection in
          let (status, connectionType) = attributesForConnection(connection)
          let attributes: [String: AttributeValue] = [
            networkStatusKey: AttributeValue.string(status),
            networkConnectionTypeKey: AttributeValue.string(connectionType)
          ]
          logger.logRecordBuilder()
            .setEventName("network.change")
            .setBody(AttributeValue.string("network.change"))
            .setAttributes(attributes)
            .emit()
        }
      } catch {
        // Monitor failed; no logs emitted
      }
    }

    private static func attributesForConnection(_ connection: Connection) -> (status: String, connectionType: String) {
      switch connection {
      case .unavailable:
        return ("lost", "unavailable")
      case .wifi:
        return ("available", "wifi")
      case .cellular:
        return ("available", "cell")
      }
    }
  }

#endif
