/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

internal struct InstallationContext {
    let tracerProvider: TracerProvider

    let loggerProvider: LoggerProvider

    let openTelemetry: OpenTelemetry

    let endpointBaseUrl: String

    /// Headers (including projectId) for config fetch, OTLP, and interaction-config requests
    let endpointHeaders: [String: String]
}
