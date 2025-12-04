/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import URLSessionInstrumentation

public struct URLSessionInstrumentationConfig {
    public private(set) var enabled: Bool = true
    public private(set) var shouldInstrument: ((URLRequest) -> Bool)?

    public init(enabled: Bool = true, shouldInstrument: ((URLRequest) -> Bool)? = nil) {
        self.enabled = enabled
        self.shouldInstrument = shouldInstrument
    }

    public mutating func enabled(_ value: Bool) {
        self.enabled = value
    }

    public mutating func setShouldInstrument(_ handler: @escaping (URLRequest) -> Bool) {
        self.shouldInstrument = handler
    }
    
    public mutating func excludeOtlpEndpoints(baseUrl: String) {
        let userShouldInstrument = self.shouldInstrument
        self.shouldInstrument = Self.createOtlpExclusionHandler(
            baseUrl: baseUrl,
            userHandler: userShouldInstrument
        )
    }
    
    private static func createOtlpExclusionHandler(
        baseUrl: String,
        userHandler: ((URLRequest) -> Bool)?
    ) -> ((URLRequest) -> Bool) {
        // Normalize base URL (remove trailing slash for comparison)
        let normalizedBaseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        
        return { request in
            if let url = request.url {
                let urlString = url.absoluteString
                if (urlString.contains("/v1/traces") || urlString.contains("/v1/logs")) && 
                   urlString.hasPrefix(normalizedBaseUrl) {
                    return false
                }
            }
            
            return userHandler?(request) ?? true
        }
    }
}

extension URLSessionInstrumentationConfig: InstrumentationInitializer {
    internal func initialize(ctx: InstallationContext) {
        guard self.enabled else { return }

        let finalShouldInstrument = Self.createOtlpExclusionHandler(
            baseUrl: ctx.endpointBaseUrl,
            userHandler: self.shouldInstrument
        )

        let urlSessionConfig = URLSessionInstrumentationConfiguration(
            shouldInstrument: finalShouldInstrument
        )
        _ = URLSessionInstrumentation(configuration: urlSessionConfig)
    }
}
