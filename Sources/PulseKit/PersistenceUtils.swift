/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import NetworkStatus
import OpenTelemetrySdk
import PersistenceExporter

internal class PersistenceUtils {
    /// Creates persistence-backed span and log exporters. On failure, returns the original exporters.
    /// Export from disk is gated by network availability on non-watchOS.
    static func createPersistentExporters(
        spanExporter: SpanExporter,
        logExporter: LogRecordExporter
    ) -> (spanExporter: SpanExporter, logExporter: LogRecordExporter) {
        let persistenceStorageBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.pulse.persistence", isDirectory: true)

        #if !os(watchOS)
        let monitor: NetworkMonitorProtocol? = try? NetworkMonitor()
        #else
        let monitor: NetworkMonitorProtocol? = nil
        #endif

        let exportCondition: () -> Bool = {
            guard let monitor = monitor else { return true }
            return monitor.getConnection() != .unavailable
        }

        do {
            let persistentSpan = try PersistenceSpanExporterDecorator(
                spanExporter: spanExporter,
                storageURL: persistenceStorageBase.appendingPathComponent("traces", isDirectory: true),
                exportCondition: exportCondition,
                performancePreset: .lowRuntimeImpact
            )
            let persistentLog = try PersistenceLogExporterDecorator(
                logRecordExporter: logExporter,
                storageURL: persistenceStorageBase.appendingPathComponent("logs", isDirectory: true),
                exportCondition: exportCondition,
                performancePreset: .lowRuntimeImpact
            )
            return (persistentSpan, persistentLog)
        } catch {
            return (spanExporter, logExporter)
        }
    }
}
