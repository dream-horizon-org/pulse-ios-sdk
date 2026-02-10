/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

public struct InstrumentationConfiguration {
    private var _urlSession: URLSessionInstrumentationConfig = URLSessionInstrumentationConfig()
    private var _sessions: SessionsInstrumentationConfig = SessionsInstrumentationConfig()
    private var _signPost: SignPostInstrumentationConfig = SignPostInstrumentationConfig()
    private var _interaction: InteractionInstrumentationConfig = InteractionInstrumentationConfig()
    private var _networkChange: NetworkChangeInstrumentationConfig = NetworkChangeInstrumentationConfig()

    public init() {}

    public mutating func urlSession(_ configure: (inout URLSessionInstrumentationConfig) -> Void) {
        configure(&_urlSession)
    }

    public mutating func sessions(_ configure: (inout SessionsInstrumentationConfig) -> Void) {
        configure(&_sessions)
    }

    public mutating func signPost(_ configure: (inout SignPostInstrumentationConfig) -> Void) {
        configure(&_signPost)
    }

    public mutating func interaction(_ configure: (inout InteractionInstrumentationConfig) -> Void) {
        configure(&_interaction)
    }

    public mutating func networkChange(_ configure: (inout NetworkChangeInstrumentationConfig) -> Void) {
        configure(&_networkChange)
    }

    internal var urlSession: URLSessionInstrumentationConfig { _urlSession }
    internal var sessions: SessionsInstrumentationConfig { _sessions }
    internal var signPost: SignPostInstrumentationConfig { _signPost }
    internal var interaction: InteractionInstrumentationConfig { _interaction }
    internal var networkChange: NetworkChangeInstrumentationConfig { _networkChange }

    internal var initializers: [InstrumentationInitializer] {
        [
            _urlSession,
            _sessions,
            _signPost,
            _interaction,
            _networkChange
        ]
    }
}
