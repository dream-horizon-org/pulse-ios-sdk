/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Persistent session storage implementation using SessionStore (UserDefaults)
/// Matches Android's PersistentSessionStorage behavior
internal class PersistentSessionStorage: SessionStorage {
    func get() -> Session? {
        return SessionStore.load()
    }
    
    func save(_ newSession: Session) {
        SessionStore.scheduleSave(session: newSession)
    }
}
