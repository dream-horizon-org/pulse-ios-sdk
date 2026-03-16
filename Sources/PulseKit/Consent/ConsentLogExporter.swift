/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk

private let consentLogBufferLimit = 5000

/// Buffers or forwards log records based on data collection consent. Outermost exporter so PENDING never hits persistence.
internal final class ConsentLogExporter: LogRecordExporter {
    private let delegate: LogRecordExporter
    private let getState: () -> PulseDataCollectionConsent
    private var buffer: [ReadableLogRecord] = []
    private let queue = DispatchQueue(label: "com.pulse.consent.log")

    init(delegate: LogRecordExporter, getState: @escaping () -> PulseDataCollectionConsent) {
        self.delegate = delegate
        self.getState = getState
    }

    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
        queue.sync {
            let state = getState()
            switch state {
            case .denied:
                return .success
            case .pending:
                let available = consentLogBufferLimit - buffer.count
                if available > 0 {
                    buffer.append(contentsOf: logRecords.prefix(available))
                }
                return .success
            case .allowed:
                return delegate.export(logRecords: logRecords, explicitTimeout: explicitTimeout)
            }
        }
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        queue.sync {
            switch getState() {
            case .pending, .denied:
                return .success
            case .allowed:
                return delegate.forceFlush(explicitTimeout: explicitTimeout)
            }
        }
    }

    func shutdown(explicitTimeout: TimeInterval?) {
        queue.sync {
            delegate.shutdown(explicitTimeout: explicitTimeout)
        }
    }

    func flushBuffer() {
        queue.sync {
            guard !buffer.isEmpty else { return }
            let toFlush = buffer
            buffer.removeAll()
            _ = delegate.export(logRecords: toFlush, explicitTimeout: nil)
        }
    }

    func clearBuffer() {
        queue.sync {
            buffer.removeAll()
        }
    }
}
