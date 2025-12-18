/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#endif

internal class VisibleScreenTracker {
    static let shared = VisibleScreenTracker()
    
    private var currentViewController: String?
    private let queue = DispatchQueue(label: "com.pulse.ios.sdk.visiblescreen")
    
    private init() {}
    
    var currentlyVisibleScreen: String {
        return queue.sync { currentViewController ?? "unknown" }
    }
    
    #if os(iOS) || os(tvOS)
    func viewControllerDidAppear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))
        queue.sync { [weak self] in
            self?.currentViewController = screenName
        }
    }
    #endif
}

