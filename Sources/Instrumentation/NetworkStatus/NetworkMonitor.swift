/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

#if !os(watchOS)

  import Foundation

  import Network

  public class NetworkMonitor: NetworkMonitorProtocol {
    let monitor = NWPathMonitor()
    var connection: Connection = .unavailable
    let monitorQueue = DispatchQueue(label: "OTel-Network-Monitor")
    let lock = NSLock()
    private let callbackLock = NSLock()
    private var _onConnectionChange: ((Connection) -> Void)?

    /// Optional callback invoked when the network path changes (e.g. wifi ↔ cellular ↔ unavailable).
    /// Set by instrumentations that emit `network.change` events. Called on the monitor queue.
    public var onConnectionChange: ((Connection) -> Void)? {
      get {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return _onConnectionChange
      }
      set {
        callbackLock.lock()
        _onConnectionChange = newValue
        callbackLock.unlock()
      }
    }

    deinit {
      monitor.cancel()
    }

    public init() throws {
      let pathHandler = { (path: NWPath) in
        let availableInterfaces = path.availableInterfaces
        let wifiInterface = self.getWifiInterface(interfaces: availableInterfaces)
        let cellInterface = self.getCellInterface(interfaces: availableInterfaces)
        var availableInterface: Connection = .unavailable
        if cellInterface != nil {
          availableInterface = .cellular
        }
        if wifiInterface != nil {
          availableInterface = .wifi
        }
        self.lock.lock()
        switch path.status {
        case .requiresConnection, .satisfied:
          self.connection = availableInterface
        case .unsatisfied:
          self.connection = .unavailable
        @unknown default:
          fatalError()
        }
        self.lock.unlock()
        self.callbackLock.lock()
        let callback = self._onConnectionChange
        self.callbackLock.unlock()
        if let callback = callback {
          callback(self.connection)
        }
      }
      monitor.pathUpdateHandler = pathHandler
      monitor.start(queue: monitorQueue)
    }

    public func getConnection() -> Connection {
      lock.lock()
      defer {
        lock.unlock()
      }
      return connection
    }

    func getCellInterface(interfaces: [NWInterface]) -> NWInterface? {
      var foundInterface: NWInterface?
      interfaces.forEach { interface in
        if interface.type == .cellular {
          foundInterface = interface
        }
      }
      return foundInterface
    }

    func getWifiInterface(interfaces: [NWInterface]) -> NWInterface? {
      var foundInterface: NWInterface?
      interfaces.forEach { interface in
        if interface.type == .wifi {
          foundInterface = interface
        }
      }
      return foundInterface
    }
  }

#endif
