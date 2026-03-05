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
    private static let swizzleLock = NSLock()
    
    static func swizzle() {
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        
        guard !swizzled else { return }
        
        #if os(iOS) || os(tvOS)
        swizzleViewWillAppear()
        swizzleViewDidAppear()
        swizzleViewWillDisappear()
        swizzleViewDidDisappear()
        #endif
        
        swizzled = true
    }

    #if os(iOS) || os(tvOS)
    private static func swizzleViewWillAppear() {
        guard let method = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewWillAppear(_:))) else {
            return
        }

        var originalIMP: IMP?

        let block: @convention(block) (UIViewController, Bool) -> Void = { viewController, animated in
            VisibleScreenTracker.shared.viewControllerWillAppear(viewController)

            if let originalIMP = originalIMP {
                let castedIMP = unsafeBitCast(
                    originalIMP,
                    to: (@convention(c) (UIViewController, Selector, Bool) -> Void).self
                )
                castedIMP(viewController, #selector(UIViewController.viewWillAppear(_:)), animated)
            }
        }

        let swizzledIMP = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        originalIMP = method_setImplementation(method, swizzledIMP)
    }

    private static func swizzleViewDidAppear() {
        guard let method = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidAppear(_:))) else {
            return
        }
        
        var originalIMP: IMP?
        
        let block: @convention(block) (UIViewController, Bool) -> Void = { viewController, animated in
            VisibleScreenTracker.shared.viewControllerDidAppear(viewController)
            
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
    }

    private static func swizzleViewWillDisappear() {
        guard let method = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewWillDisappear(_:))) else {
            return
        }

        var originalIMP: IMP?

        let block: @convention(block) (UIViewController, Bool) -> Void = { viewController, animated in
            VisibleScreenTracker.shared.viewControllerWillDisappear(viewController)

            if let originalIMP = originalIMP {
                let castedIMP = unsafeBitCast(
                    originalIMP,
                    to: (@convention(c) (UIViewController, Selector, Bool) -> Void).self
                )
                castedIMP(viewController, #selector(UIViewController.viewWillDisappear(_:)), animated)
            }
        }

        let swizzledIMP = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        originalIMP = method_setImplementation(method, swizzledIMP)
    }

    private static func swizzleViewDidDisappear() {
        guard let method = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidDisappear(_:))) else {
            return
        }

        var originalIMP: IMP?

        let block: @convention(block) (UIViewController, Bool) -> Void = { viewController, animated in
            VisibleScreenTracker.shared.viewControllerDidDisappear(viewController)

            if let originalIMP = originalIMP {
                let castedIMP = unsafeBitCast(
                    originalIMP,
                    to: (@convention(c) (UIViewController, Selector, Bool) -> Void).self
                )
                castedIMP(viewController, #selector(UIViewController.viewDidDisappear(_:)), animated)
            }
        }

        let swizzledIMP = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        originalIMP = method_setImplementation(method, swizzledIMP)
    }
    #endif
}

