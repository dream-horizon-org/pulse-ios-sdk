/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Protocol for session storage implementations (matches Android SessionStorage interface)
internal protocol SessionStorage {
    func get() -> Session?
    func save(_ session: Session)
}
