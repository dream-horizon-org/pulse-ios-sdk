/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
#if os(iOS) || os(tvOS)
import UIKit
import ObjectiveC
#endif

internal class UIViewControllerSwizzler {
    private static var swizzled = false
    private static var _disabled = false
    private static let swizzleLock = NSLock()
    
    static func swizzle() {
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        
        guard !swizzled else { return }
        _disabled = false
        
        #if os(iOS) || os(tvOS)
        guard let method = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidAppear(_:))) else {
            return
        }
        
        var originalIMP: IMP?
        
        let block: @convention(block) (UIViewController, Bool) -> Void = { viewController, animated in
            if !UIViewControllerSwizzler._disabled {
                VisibleScreenTracker.shared.viewControllerDidAppear(viewController)
            }
            
            if let originalIMP = originalIMP {
                let castedIMP = unsafeBitCast(
                    originalIMP,
                    to: (@convention(c) (UIViewController, Selector, Bool) -> Void).self
                )
                castedIMP(viewController, #selector(UIViewController.viewDidAppear(_:)), animated)
            }
        }
        
        let swizzledIMP = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        originalIMP = method_setImplementation(method, swizzledIMP)
        #endif
        
        swizzled = true
    }

    /// Disables the swizzled tracking. The swizzle remains in place
    /// (cannot be undone at runtime) but the Pulse callback becomes a no-op.
    static func shutdown() {
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        _disabled = true
    }
}

