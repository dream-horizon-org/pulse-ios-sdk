/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

#if canImport(KSCrashRecording)
  import KSCrashRecording
#elseif canImport(KSCrash)
  import KSCrash
#endif

#if canImport(KSCrashFilters)
  import KSCrashFilters
#endif

public enum CrashEventName {
    public static let deviceCrash = "device.crash"
}

/// Captures native crashes via KSCrash and emits them as `device.crash` OTel log events.
///
/// On install, KSCrash registers low-level handlers (Mach exceptions, UNIX signals,
/// NSException) that write a JSON report to disk at crash time. On the next app launch,
/// pending reports are parsed and emitted through the OTel log pipeline, then deleted.
public final class CrashInstrumentation {
    static let maxStackTraceBytes = 25 * 1024

    public private(set) static var isInstalled: Bool = false

    private static var logger: Logger?
    static let reporter = KSCrash.shared
    private static let queue = DispatchQueue(label: "com.pulse.ios.sdk.crash", qos: .utility)

    private let loggerProvider: LoggerProvider
    private let instrumentationScopeName: String
    private let instrumentationVersion: String

    public init(
        loggerProvider: LoggerProvider,
        instrumentationScopeName: String = "com.pulse.ios.sdk.crash",
        instrumentationVersion: String = "1.0.0"
    ) {
        self.loggerProvider = loggerProvider
        self.instrumentationScopeName = instrumentationScopeName
        self.instrumentationVersion = instrumentationVersion
    }

    public func install() {
        guard !CrashInstrumentation.isInstalled else { return }

        CrashInstrumentation.logger = loggerProvider.get(
            instrumentationScopeName: instrumentationScopeName
        )

        do {
            try CrashInstrumentation.reporter.install(with: KSCrashConfiguration())
            CrashInstrumentation.isInstalled = true
        } catch {
            return
        }

        CrashInstrumentation.queue.async {
            CrashInstrumentation.processStoredCrashes()
        }
    }

    // MARK: - Report Processing

    static func processStoredCrashes() {
        do {
            try processStoredCrashesUnsafe()
        } catch {
            // Swallow to prevent crash-loop; reports stay on disk for next attempt.
        }
    }

    private static func processStoredCrashesUnsafe() throws {
        guard let logger = logger,
              let reportStore = reporter.reportStore else { return }

        let reportIDs = reportStore.reportIDs
        guard !reportIDs.isEmpty else { return }

        for reportID in reportIDs {
            guard let id = reportID as? Int64,
                  let crashReport = reportStore.report(for: id) else { continue }

            reportCrash(crashReport: crashReport, logger: logger)
            reportStore.deleteReport(with: id)
        }
    }

    private static func reportCrash(crashReport: CrashReportDictionary, logger: Logger) {
        let rawCrash = crashReport.value
        let log: any LogRecordBuilder = logger.logRecordBuilder()
            .setEventName(CrashEventName.deviceCrash)

        var attributes: [String: AttributeValue] = [:]

        if let parsed = CrashReportParser.parse(dictionary: rawCrash) {
            attributes[CrashAttributes.exceptionType] = .string(parsed.exceptionType)
            attributes[CrashAttributes.exceptionMessage] = .string(parsed.exceptionMessage)
            attributes[CrashAttributes.threadId] = .string(parsed.threadId)
            attributes[CrashAttributes.threadName] = .string(parsed.threadName)
        } else {
            attributes[CrashAttributes.exceptionType] = .string("crash")
        }

        CrashReportFilterAppleFmt().filterReports([crashReport]) { reports, _ in
            var appleReport = (reports?.first as? CrashReportString)?.value
                ?? "Failed to format crash report"

            if appleReport.utf8.count > maxStackTraceBytes {
                appleReport = String(appleReport.utf8.prefix(maxStackTraceBytes)) ?? appleReport
            }

            attributes[CrashAttributes.exceptionStacktrace] = .string(appleReport)

            if attributes[CrashAttributes.exceptionMessage] == nil {
                attributes[CrashAttributes.exceptionMessage] = .string(
                    extractCrashMessage(from: appleReport)
                )
            }

            _ = log.setAttributes(attributes)
            log.emit()
        }
    }

    // MARK: - Helpers

    static func extractCrashMessage(from stackTrace: String) -> String {
        let lines = stackTrace.components(separatedBy: "\n")

        let exceptionType = lines.first(where: { $0.hasPrefix("Exception Type:") })?
            .replacingOccurrences(of: "Exception Type:", with: "")
            .trimmingCharacters(in: .whitespaces) ?? "Unknown exception"

        guard let crashedLine = lines.first(where: {
                  $0.range(of: #"Thread \d+ Crashed:"#, options: .regularExpression) != nil
              }),
              let threadMatch = crashedLine.range(
                  of: #"Thread (\d+) Crashed:"#, options: .regularExpression
              ),
              let crashedIndex = lines.firstIndex(of: crashedLine),
              let firstFrame = lines.dropFirst(crashedIndex + 1)
                  .first(where: { $0.hasPrefix("0   ") })
        else {
            return "\(exceptionType) detected at unknown location"
        }

        let threadNumber = String(crashedLine[threadMatch])
            .replacingOccurrences(
                of: #"Thread (\d+) Crashed:"#, with: "$1",
                options: .regularExpression
            )

        let frameComponents = firstFrame
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard frameComponents.count >= 4,
              let module = frameComponents.dropFirst().first,
              let offset = frameComponents.last
        else {
            return "\(exceptionType) detected on thread \(threadNumber) at unknown location"
        }

        return "\(exceptionType) detected on thread \(threadNumber) at \(module) + \(offset)"
    }
}

enum CrashAttributes {
    static let exceptionMessage = "exception.message"
    static let exceptionType = "exception.type"
    static let exceptionStacktrace = "exception.stacktrace"
    static let threadId = "thread.id"
    static let threadName = "thread.name"
}
