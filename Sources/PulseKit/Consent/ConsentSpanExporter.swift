/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
import OpenTelemetryApi

private let consentBufferLimit = 5000

/// Buffers or forwards spans based on data collection consent. Outermost exporter so PENDING never hits persistence.
internal final class ConsentSpanExporter: SpanExporter {
    private let delegate: SpanExporter
    private let getState: () -> PulseDataCollectionConsent
    private var buffer: [SpanData] = []
    private let queue = DispatchQueue(label: "com.pulse.consent.span")

    init(delegate: SpanExporter, getState: @escaping () -> PulseDataCollectionConsent) {
        self.delegate = delegate
        self.getState = getState
    }

    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        queue.sync {
            let state = getState()
            switch state {
            case .denied:
                return .success
            case .pending:
                let available = consentBufferLimit - buffer.count
                if available > 0 {
                    buffer.append(contentsOf: spans.prefix(available))
                }
                return .success
            case .allowed:
                return delegate.export(spans: spans, explicitTimeout: explicitTimeout)
            }
        }
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        queue.sync {
            switch getState() {
            case .pending, .denied:
                return .success
            case .allowed:
                return delegate.flush(explicitTimeout: explicitTimeout)
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
            _ = delegate.export(spans: toFlush, explicitTimeout: nil)
        }
    }

    func clearBuffer() {
        queue.sync {
            buffer.removeAll()
        }
    }
}
