/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Signal matching for filters, critical events, attribute drop/add (Batch 3, LLD §7).
 * Decides if a signal (span/log/metric) matches a PulseSignalMatchCondition.
 */

import Foundation

// MARK: - PulseSignalMatcher protocol

/// Returns true iff the signal matches the given condition.
/// Matches Android PulseSignalMatcher (pulse-sampling-core).
public protocol PulseSignalMatcher {
    /// - Parameters:
    ///   - scope: Signal type (traces, logs, metrics, baggage)
    ///   - name: Signal name (span name, log body/event name, metric name)
    ///   - props: Signal attributes as [key: value]; values can be Any? (optional)
    ///   - condition: The match condition from config
    ///   - sdkName: Current SDK (e.g. .pulse_ios_swift)
    func matches(
        scope: PulseSignalScope,
        name: String?,
        props: [String: Any?],
        condition: PulseSignalMatchCondition,
        sdkName: PulseSdkName
    ) -> Bool
}

// MARK: - PulseSignalsAttrMatcher (default implementation)

/// Default matcher: name regex, scope, sdk, props matching (LLD §7.2).
public struct PulseSignalsAttrMatcher: PulseSignalMatcher {
    private let regexCache = RegexCache()

    public init() {}

    public func matches(
        scope: PulseSignalScope,
        name: String?,
        props: [String: Any?],
        condition: PulseSignalMatchCondition,
        sdkName: PulseSdkName
    ) -> Bool {
        guard condition.sdks.contains(sdkName) else { return false }
        guard condition.scopes.contains(scope) else { return false }
        guard regexCache.matches(string: name ?? "", pattern: condition.name) else { return false }

        let configPropsMap = Dictionary(uniqueKeysWithValues: condition.props.map { ($0.name, $0.value) })
        let signalPropsFiltered = props.filter { configPropsMap.keys.contains($0.key) }

        guard configPropsMap.count == signalPropsFiltered.count else { return false }

        for (key, signalValue) in signalPropsFiltered {
            guard let configPropValueOpt = configPropsMap[key] else { return false }
            if configPropValueOpt == nil || signalValue == nil {
                if (signalValue == nil) != (configPropValueOpt == nil) { return false }
                continue
            }
            if !regexCache.matches(string: stringFromAny(signalValue), pattern: configPropValueOpt!) {
                return false
            }
        }
        return true
    }

    private func stringFromAny(_ value: Any?) -> String {
        guard let value = value else { return "" }
        return String(describing: value)
    }
}

// MARK: - Regex cache (thread-safe)

/// Normalizes UI-generated "contains" patterns. Same as PulseSamplingSignalProcessors.
private func normalizedSignalNamePattern(_ pattern: String) -> String {
    let prefix = "^\\.\\*"
    let suffix = "\\*\\.$"
    guard pattern.hasPrefix(prefix), pattern.hasSuffix(suffix), pattern.count > prefix.count + suffix.count else {
        return pattern
    }
    let startIdx = pattern.index(pattern.startIndex, offsetBy: prefix.count)
    let endIdx = pattern.index(pattern.endIndex, offsetBy: -suffix.count)
    let content = String(pattern[startIdx..<endIdx])
    return ".*" + NSRegularExpression.escapedPattern(for: content) + ".*"
}

/// Thread-safe regex cache for full-string matching.
/// Matches Android matchesFromRegexCache semantics (Kotlin String.matches(Regex)).
private final class RegexCache {
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func matches(string: String, pattern: String) -> Bool {
        let effectivePattern = normalizedSignalNamePattern(pattern)
        let regex: NSRegularExpression? = lock.withLock {
            if let cached = cache[effectivePattern] { return cached }
            guard let re = try? NSRegularExpression(pattern: effectivePattern) else { return nil }
            cache[effectivePattern] = re
            return re
        }
        guard let regex = regex else { return false }
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: string, options: [], range: fullRange) else {
            return false
        }
        return match.range == fullRange
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
