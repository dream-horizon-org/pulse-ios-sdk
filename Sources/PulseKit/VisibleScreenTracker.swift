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
    private var isFirstScreen: Bool = true
    private let queue = DispatchQueue(label: "com.pulse.ios.sdk.visiblescreen")
    
    private init() {}
    
    var currentlyVisibleScreen: String {
        return queue.sync { currentViewController ?? "unknown" }
    }
    
    #if os(iOS) || os(tvOS)
    func viewControllerDidAppear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))
        
        var shouldEndAppStart = false
        queue.sync { [weak self] in
            guard let self = self else { return }
            self.currentViewController = screenName
            
            // End app start span on first screen appearance
            if self.isFirstScreen {
                self.isFirstScreen = false
                shouldEndAppStart = true
            }
        }
        
        if shouldEndAppStart {
            AppStartupTimer.shared.end()
        }
    }
    #endif
}

