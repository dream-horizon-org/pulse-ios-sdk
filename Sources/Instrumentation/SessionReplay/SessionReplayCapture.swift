/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
#if os(iOS) || os(tvOS)
import Accelerate
import CoreGraphics
import UIKit
import WebKit
import ObjectiveC
#if canImport(phlibwebp)
    @_implementationOnly import phlibwebp
#endif

internal protocol SessionReplayCapturer {
    func capture(window: UIWindow, scale: CGFloat, completion: @escaping (UIImage?) -> Void)
}

internal class ScreenshotCapturer: SessionReplayCapturer {
    let masker: SessionReplayMasker

    init(config: SessionReplayConfig) {
        self.masker = SessionReplayMasker(config: config)
    }

    func capture(window: UIWindow, scale: CGFloat, completion: @escaping (UIImage?) -> Void) {
        masker.captureWithMaskingAsync(window: window, scale: scale, completion: completion)
    }
}

private struct ViewSnapshot {
    let viewId: ObjectIdentifier
    let className: String
    let frame: CGRect
    let windowFrame: CGRect?
    let isHidden: Bool
    let alpha: CGFloat
    let hasWindow: Bool
    let subviewIds: [ObjectIdentifier]
    let tag: Int?
    let accessibilityLabel: String?
    let accessibilityIdentifier: String?
    let privacyTagValue: String?  // Captured from associated object (pulseReplayMask/unmask)
    let placeholder: String?  // Placeholder text for UITextField (used for sensitive field detection)
    // Type-specific data
    let isTextField: Bool
    let isTextView: Bool
    let isLabel: Bool
    let isImageView: Bool
    let isPickerView: Bool
    let isWebView: Bool
    let isSecureTextEntry: Bool
    let textContentType: String?
    let keyboardType: UIKeyboardType?
    let hasText: Bool
    let hasImage: Bool
    // For coordinate conversion
    let superviewId: ObjectIdentifier?
}

internal class SessionReplayMasker {
    private let config: SessionReplayConfig
    private var drawFlagChecker: (() -> Bool)?
    private var lastTopViewController: UIViewController?
    private var lastViewControllerChangeTime: Date?
    
    init(config: SessionReplayConfig) {
        self.config = config
    }
    
    func setDrawFlagChecker(_ checker: @escaping () -> Bool) {
        self.drawFlagChecker = checker
    }

    func captureWithMaskingAsync(window: UIWindow, scale: CGFloat, completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            let currentTopVC = self.getTopViewController(in: window)
            let viewControllerChanged = currentTopVC !== self.lastTopViewController
            
            if viewControllerChanged {
                self.lastTopViewController = currentTopVC
                self.lastViewControllerChangeTime = Date()
            }
            
            if let changeTime = self.lastViewControllerChangeTime {
                let timeSinceChange = Date().timeIntervalSince(changeTime)
                let minStabilizationDelay: TimeInterval = 0.1
                if timeSinceChange < minStabilizationDelay {
                    completion(nil)
                    return
                }
            }
            
            let isStable = self.isViewStateStable(window: window)
            let isVisible = self.isViewHierarchyVisible(window: window)
            
            guard isStable && isVisible else {
                completion(nil)
                return
            }
            
            let windowBounds = window.bounds
            guard windowBounds.width > 0 && windowBounds.height > 0 else {
                completion(nil)
                return
            }
            
            guard window.rootViewController != nil || !window.subviews.isEmpty else {
                completion(nil)
                return
            }
            
            var scrollPositionAtSnapshot: CGFloat = 0
            if let scrollView = self.findScrollView(in: window) {
                scrollPositionAtSnapshot = scrollView.contentOffset.y
            }
            
            var snapshots: [ObjectIdentifier: ViewSnapshot] = [:]
            var visited: Set<ObjectIdentifier> = []
            
            window.layoutIfNeeded()
            if let rootVC = window.rootViewController {
                rootVC.view.layoutIfNeeded()
            }
            
            self.snapshotViewHierarchy(
                view: window,
                window: window,
                snapshots: &snapshots,
                visited: &visited
            )
            
            var visitedForMasking: Set<ObjectIdentifier> = []
            let viewsNeedingMask = self.findViewsNeedingMask(snapshots: snapshots, windowBounds: windowBounds)
            let viewsWithNilWindowFrame = viewsNeedingMask.filter { $0.windowFrame == nil }
            
            if !viewsWithNilWindowFrame.isEmpty {
                completion(nil)
                return
            }
            
            // Collect mask rects on main thread (fast - just coordinate calculations)
            var maskRects = self.processMaskingFromSnapshot(
                snapshots: snapshots,
                rootViewId: ObjectIdentifier(window),
                windowBounds: windowBounds,
                visited: &visitedForMasking
            )
            
            maskRects = self.mergeOverlappingRects(maskRects)
            
            let viewsNeedingMaskCount = viewsNeedingMask.count
            
            // FAST PATH: If no masking needed, skip to background immediately
            if maskRects.isEmpty && viewsNeedingMaskCount == 0 {
                // No masking required - move heavy operations to background
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else {
                        completion(nil)
                        return
                    }
                    
                    // Capture screenshot on background (but must be called from main thread)
                    DispatchQueue.main.async {
                        let screenshot = self.captureScreenshotSync(window: window, bounds: windowBounds)
                        
                        guard let screenshot = screenshot, screenshot.size.width > 0 && screenshot.size.height > 0 else {
                            completion(nil)
                            return
                        }
                        
                        // Process on background
                        DispatchQueue.global(qos: .userInitiated).async {
                            let clampedScale = max(0.01, min(1.0, scale))
                            if clampedScale < 1.0 {
                                let finalSize = CGSize(
                                    width: max(1, screenshot.size.width * clampedScale),
                                    height: max(1, screenshot.size.height * clampedScale)
                                )
                                let format = UIGraphicsImageRendererFormat(for: .init(displayScale: 1))
                                format.opaque = true
                                let renderer = UIGraphicsImageRenderer(size: finalSize, format: format)
                                let scaledImage = renderer.image { _ in
                                    screenshot.draw(in: CGRect(origin: .zero, size: finalSize))
                                }
                                completion(scaledImage)
                            } else {
                                completion(screenshot)
                            }
                        }
                    }
                }
                return
            }
            
            // MASKING PATH: Capture screenshot, then apply masks on background
            let screenshot = self.captureScreenshotSync(window: window, bounds: windowBounds)
            
            guard let screenshot = screenshot, screenshot.size.width > 0 && screenshot.size.height > 0 else {
                completion(nil)
                return
            }
            
            // Check for scroll changes between snapshot and screenshot
            var scrollPositionAtScreenshot: CGFloat = 0
            if let scrollView = self.findScrollView(in: window) {
                scrollPositionAtScreenshot = scrollView.contentOffset.y
            }
            let scrollDelta = scrollPositionAtScreenshot - scrollPositionAtSnapshot
            
            if abs(scrollDelta) > 5.0 {
                completion(nil)
                return
            }
            
            // Move heavy operations (mask rendering, encoding) to background thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    completion(nil)
                    return
                }
                
                let capturedScreenshot = screenshot
                
                // CRITICAL: Verify screenshot size matches window bounds (coordinate space validation)
                
                // Phase 5: Validate mask rects before rendering (use screenshot size, not window bounds)
                let validatedRects = self.validateMaskRects(maskRects, imageSize: capturedScreenshot.size)
               
                
                let maskedImage = self.drawMasksOnImage(
                    image: capturedScreenshot,
                    maskRects: validatedRects
                )
                
                guard let maskedImage = maskedImage, maskedImage.size.width > 0 && maskedImage.size.height > 0 else {
                    if viewsNeedingMaskCount > 0 {
                        completion(nil)
                        return
                    }
                    completion(capturedScreenshot)
                    return
                }
                
                // Scale if needed
                let clampedScale = max(0.01, min(1.0, scale))
                if clampedScale < 1.0 {
                    let finalSize = CGSize(
                        width: max(1, maskedImage.size.width * clampedScale),
                        height: max(1, maskedImage.size.height * clampedScale)
                    )
                    let format = UIGraphicsImageRendererFormat(for: .init(displayScale: 1))
                    format.opaque = true
                    let renderer = UIGraphicsImageRenderer(size: finalSize, format: format)
                    let scaledImage = renderer.image { _ in
                        maskedImage.draw(in: CGRect(origin: .zero, size: finalSize))
                    }
                    completion(scaledImage)
                } else {
                    completion(maskedImage)
                }
            }
        }
    }

    
    
    private func getTopViewController(in window: UIWindow) -> UIViewController? {
        guard let rootVC = window.rootViewController else { return nil }
        return getTopViewController(from: rootVC)
    }
    
    private func getTopViewController(from viewController: UIViewController) -> UIViewController {
        if let presented = viewController.presentedViewController {
            return getTopViewController(from: presented)
        }
        
        if let navController = viewController as? UINavigationController {
            if let topVC = navController.topViewController {
                return getTopViewController(from: topVC)
            }
        }
        
        if let tabController = viewController as? UITabBarController {
            if let selected = tabController.selectedViewController {
                return getTopViewController(from: selected)
            }
        }
        
        return viewController
    }
    
    private func isViewStateStable(view: UIView) -> Bool {
        if let animationKeys = view.layer.animationKeys(), !animationKeys.isEmpty {
            return false
        }
        return true
    }
    
    private func shouldMaskImage(_ imageView: UIImageView) -> Bool {
        return config.imagePrivacy == .maskAll && imageView.image != nil
    }
    
    private func shouldMaskWebView() -> Bool {
        return config.textAndInputPrivacy != .maskSensitiveInputs || config.imagePrivacy == .maskAll
    }
    
    private func shouldMaskTextField(_ textField: UITextField) -> Bool {
        if isPasswordField(textField) { return true }
        switch config.textAndInputPrivacy {
        case .maskAll: return true
        case .maskAllInputs: return true
        case .maskSensitiveInputs: return isSensitiveInputType(textField)
        }
    }
    
    private func shouldMaskTextView(_ textView: UITextView) -> Bool {
        if isPasswordTextView(textView) { return true }
        switch config.textAndInputPrivacy {
        case .maskAll: return true
        case .maskAllInputs: return true
        case .maskSensitiveInputs: return isSensitiveTextView(textView)
        }
    }
    
    private func shouldMaskLabel(_ label: UILabel) -> Bool {
        switch config.textAndInputPrivacy {
        case .maskAll: return true
        case .maskAllInputs: return false
        case .maskSensitiveInputs: return false
        }
    }
    
    private func shouldMaskSpinner() -> Bool {
        switch config.textAndInputPrivacy {
        case .maskAll: return true
        case .maskAllInputs: return true
        case .maskSensitiveInputs: return false
        }
    }
    
    private func isSensitiveInputType(_ textField: UITextField) -> Bool {
        if isPasswordField(textField) { return true }
        return isEmailField(textField) || isPhoneField(textField)
    }
    
    private func isSensitiveTextView(_ textView: UITextView) -> Bool {
        if isPasswordTextView(textView) { return true }
        return isEmailTextView(textView) || isPhoneTextView(textView)
    }
    
    private func isPasswordField(_ textField: UITextField) -> Bool {
        if textField.isSecureTextEntry {
            return true
        }
        
        if #available(iOS 10.0, *) {
            if textField.textContentType == .password || 
               textField.textContentType == .newPassword {
                return true
            }
        }
        
        if textField.keyboardType == .default {
            let placeholder = textField.placeholder?.lowercased() ?? ""
            let accessibilityLabel = textField.accessibilityLabel?.lowercased() ?? ""
            if placeholder.contains("password") || accessibilityLabel.contains("password") {
                return true
            }
        }
        
        return false
    }
    
    private func isEmailField(_ textField: UITextField) -> Bool {
        if textField.keyboardType == .emailAddress {
            return true
        }
        
        if #available(iOS 10.0, *) {
            if textField.textContentType == .emailAddress {
                return true
            }
        }
        
        // Heuristic: check placeholder or accessibility label
        let placeholder = textField.placeholder?.lowercased() ?? ""
        let accessibilityLabel = textField.accessibilityLabel?.lowercased() ?? ""
        if placeholder.contains("email") || accessibilityLabel.contains("email") {
            return true
        }
        
        return false
    }
    
    private func isPhoneField(_ textField: UITextField) -> Bool {
        if textField.keyboardType == .phonePad {
            return true
        }
        
        if #available(iOS 10.0, *) {
            if textField.textContentType == .telephoneNumber {
                return true
            }
        }
        
        let placeholder = textField.placeholder?.lowercased() ?? ""
        let accessibilityLabel = textField.accessibilityLabel?.lowercased() ?? ""
        if placeholder.contains("phone") || placeholder.contains("mobile") ||
           accessibilityLabel.contains("phone") || accessibilityLabel.contains("mobile") {
            return true
        }
        
        return false
    }
    
    private func isPasswordTextView(_ textView: UITextView) -> Bool {
        if textView.isSecureTextEntry {
            return true
        }
        
        if #available(iOS 10.0, *) {
            if textView.textContentType == .password || 
               textView.textContentType == .newPassword {
                return true
            }
        }
        
        let accessibilityLabel = textView.accessibilityLabel?.lowercased() ?? ""
        if accessibilityLabel.contains("password") {
            return true
        }
        
        return false
    }
    
    private func isEmailTextView(_ textView: UITextView) -> Bool {
        if textView.keyboardType == .emailAddress {
            return true
        }
        
        if #available(iOS 10.0, *) {
            if textView.textContentType == .emailAddress {
                return true
            }
        }
        
        let accessibilityLabel = textView.accessibilityLabel?.lowercased() ?? ""
        if accessibilityLabel.contains("email") {
            return true
        }
        
        return false
    }
    
    private func isPhoneTextView(_ textView: UITextView) -> Bool {
        if textView.keyboardType == .phonePad {
            return true
        }
        
        if #available(iOS 10.0, *) {
            if textView.textContentType == .telephoneNumber {
                return true
            }
        }
        
        let accessibilityLabel = textView.accessibilityLabel?.lowercased() ?? ""
        if accessibilityLabel.contains("phone") || accessibilityLabel.contains("mobile") {
            return true
        }
        
        return false
    }
    
    private enum MaskDecision {
        case mask
        case unmask
        case undecided
    }

    
    private func snapshotViewHierarchy(
        view: UIView,
        window: UIWindow,
        snapshots: inout [ObjectIdentifier: ViewSnapshot],
        visited: inout Set<ObjectIdentifier>,
        parentId: ObjectIdentifier? = nil,
        screenToWindowOffset: CGPoint? = nil
    ) {
        let viewId = ObjectIdentifier(view)
        if visited.contains(viewId) { return }
        visited.insert(viewId)
        
        if let checker = drawFlagChecker, checker() {
            return
        }
        
        let className = String(describing: type(of: view))
        let frame = view.frame
        
        // CRITICAL FIX: Use direct window coordinate conversion (not screen->window offset)
        // view.convert(view.bounds, to: window) gives us coordinates in window space,
        // which directly matches the screenshot bitmap coordinate space.
        // This is simpler and more accurate than screen->window offset conversion.
        var windowFrame: CGRect?
        if view == window {
            windowFrame = window.bounds
        } else {
            // Direct conversion to window coordinates - this matches screenshot bitmap space
            // Try multiple conversion methods for robustness
            if let superview = view.superview {
                // Method 1: Convert via superview (most accurate for views in hierarchy)
                let convertedFrame = superview.convert(view.frame, to: window)
                if convertedFrame.width > 0 && convertedFrame.height > 0 &&
                   convertedFrame.origin.x.isFinite && convertedFrame.origin.y.isFinite &&
                   convertedFrame.width.isFinite && convertedFrame.height.isFinite &&
                   convertedFrame.origin.x >= -1000 && convertedFrame.origin.y >= -1000 && // Reasonable bounds check
                   convertedFrame.origin.x < window.bounds.width + 1000 &&
                   convertedFrame.origin.y < window.bounds.height + 1000 {
                    windowFrame = convertedFrame
                } else {
                    // Method 2: Direct conversion (fallback)
                    windowFrame = view.convert(view.bounds, to: window)
                }
            } else if let viewWindow = view.window, viewWindow == window {
                // Method 3: Direct conversion when view is in target window
                windowFrame = view.convert(view.bounds, to: window)
            } else {
                // View is not in the target window - cannot convert
                windowFrame = nil
            }
            
            // Validate the converted frame
            if let frame = windowFrame {
                // Ensure frame is valid and within reasonable bounds
                if frame.width <= 0 || frame.height <= 0 ||
                   !frame.origin.x.isFinite || !frame.origin.y.isFinite ||
                   !frame.width.isFinite || !frame.height.isFinite {
                    windowFrame = nil
                } else {
                    // Additional validation: check if frame is way outside window bounds (likely wrong conversion)
                    let tolerance: CGFloat = 100 // Allow some tolerance for views slightly outside
                    if frame.origin.x < -tolerance || frame.origin.y < -tolerance ||
                       frame.origin.x > window.bounds.width + tolerance ||
                       frame.origin.y > window.bounds.height + tolerance {
                        // Still use it but it will be clamped later
                    }
                }
            }
        }
        
        let textField = view as? UITextField
        let textView = view as? UITextView
        let label = view as? UILabel
        let imageView = view as? UIImageView
        let isTextField = textField != nil
        let isTextView = textView != nil
        let isLabel = label != nil
        let isImageView = imageView != nil
        let isPickerView = view is UIPickerView
        let isWebView = view is WKWebView
        
        let isSecureTextEntry = (textField?.isSecureTextEntry ?? false) || (textView?.isSecureTextEntry ?? false)
        let textContentType: String?
        let keyboardType: UIKeyboardType?
        if #available(iOS 10.0, *) {
            textContentType = textField?.textContentType?.rawValue ?? textView?.textContentType?.rawValue
        } else {
            textContentType = nil
        }
        keyboardType = textField?.keyboardType ?? textView?.keyboardType
        
        let hasText: Bool
        let placeholder: String?
        if let textField = textField {
            hasText = !(textField.text?.isEmpty ?? true) || !(textField.placeholder?.isEmpty ?? true)
            placeholder = textField.placeholder
        } else if let textView = textView {
            hasText = !(textView.text?.isEmpty ?? true)
            placeholder = nil
        } else if let label = label {
            hasText = !(label.text?.isEmpty ?? true) || !(label.attributedText?.string.isEmpty ?? true)
            placeholder = nil
        } else {
            hasText = false
            placeholder = nil
        }
        
        let hasImage = imageView?.image != nil
        let subviewIds = view.subviews.map { ObjectIdentifier($0) }
        
        let privacyTagValue = view.getPrivacyTagValue()
        
        let snapshot = ViewSnapshot(
            viewId: viewId,
            className: className,
            frame: frame,
            windowFrame: windowFrame,
            isHidden: view.isHidden,
            alpha: view.alpha,
            hasWindow: view.window != nil,
            subviewIds: subviewIds,
            tag: view.tag,
            accessibilityLabel: view.accessibilityLabel,
            accessibilityIdentifier: view.accessibilityIdentifier,
            privacyTagValue: privacyTagValue,
            placeholder: placeholder,
            isTextField: isTextField,
            isTextView: isTextView,
            isLabel: isLabel,
            isImageView: isImageView,
            isPickerView: isPickerView,
            isWebView: isWebView,
            isSecureTextEntry: isSecureTextEntry,
            textContentType: textContentType,
            keyboardType: keyboardType,
            hasText: hasText,
            hasImage: hasImage,
            superviewId: parentId
        )
        
        snapshots[viewId] = snapshot
        
        for subview in view.subviews {
            snapshotViewHierarchy(
                view: subview,
                window: window,
                snapshots: &snapshots,
                visited: &visited,
                parentId: viewId,
                screenToWindowOffset: nil // Not needed with direct conversion
            )
        }
    }
    
    private func processMaskingFromSnapshot(
        snapshots: [ObjectIdentifier: ViewSnapshot],
        rootViewId: ObjectIdentifier,
        windowBounds: CGRect,
        visited: inout Set<ObjectIdentifier>,
        parentForcedMask: Bool = false
    ) -> [CGRect] {
        var maskableRects: [CGRect] = []
        
        
        guard let snapshot = snapshots[rootViewId] else {
            return maskableRects
        }
        
        if visited.contains(rootViewId) {
            return maskableRects
        }
        visited.insert(rootViewId)
        
        let isWindow = snapshot.className.contains("Window")
        let isVisible = !snapshot.isHidden && snapshot.alpha > 0 && (isWindow || snapshot.hasWindow)
        
        guard isVisible else {
            return maskableRects
        }
        
        // CRITICAL FIX: Never mask the window itself - it's just a container
        // Only process its children for masking. The window itself should never be masked
        // unless explicitly requested via pulseReplayMask() (which would be unusual).
        if isWindow {
            // For window, skip masking decision and just process children
            // The window itself should never be masked by default
            #if DEBUG
            let instanceDecision = resolveInstanceDecisionFromSnapshot(snapshot: snapshot)
            let classDecision = resolveClassDecisionFromSnapshot(snapshot: snapshot)
            #endif
            
            // Process children with parent's forced mask state
            for childId in snapshot.subviewIds {
                let childRects = processMaskingFromSnapshot(
                    snapshots: snapshots,
                    rootViewId: childId,
                    windowBounds: windowBounds,
                    visited: &visited,
                    parentForcedMask: parentForcedMask
                )
                maskableRects.append(contentsOf: childRects)
            }
            return maskableRects
        }
        
        let instanceDecision = resolveInstanceDecisionFromSnapshot(snapshot: snapshot)
        let classDecision = resolveClassDecisionFromSnapshot(snapshot: snapshot)
        
        let effectiveDecision: MaskDecision
        if instanceDecision != .undecided {
            effectiveDecision = instanceDecision
        } else {
            effectiveDecision = classDecision
        }
        
        var forceMaskChildren = parentForcedMask
        
        switch effectiveDecision {
        case .unmask:
            forceMaskChildren = false
            
        case .mask:
            if let rect = snapshot.windowFrame {
                let clampedRect = clampRectToBounds(rect: rect, bounds: windowBounds)
                if clampedRect.width > 0 && clampedRect.height > 0 {
                    maskableRects.append(clampedRect)
                }
            }
            forceMaskChildren = true
            
        case .undecided:
            if parentForcedMask {
                if let rect = snapshot.windowFrame {
                    let clampedRect = clampRectToBounds(rect: rect, bounds: windowBounds)
                    if clampedRect.width > 0 && clampedRect.height > 0 {
                        maskableRects.append(clampedRect)
                    }
                }
                forceMaskChildren = true
            } else {
                if let rect = applyTypeSpecificMaskingFromSnapshot(snapshot: snapshot, windowBounds: windowBounds) {
                    maskableRects.append(rect)
                }
            }
        }
        
        for childId in snapshot.subviewIds {
            let childRects = processMaskingFromSnapshot(
                snapshots: snapshots,
                rootViewId: childId,
                windowBounds: windowBounds,
                visited: &visited,
                parentForcedMask: forceMaskChildren
            )
            maskableRects.append(contentsOf: childRects)
        }
        
        return maskableRects
    }
    
    private func resolveInstanceDecisionFromSnapshot(snapshot: ViewSnapshot) -> MaskDecision {
        if let privacyTag = snapshot.privacyTagValue {
            if privacyTag == "pulse-unmask" {
                return .unmask
            }
            if privacyTag == "pulse-mask" {
                return .mask
            }
        }
        
        if let accessibilityLabel = snapshot.accessibilityLabel {
            let lowerLabel = accessibilityLabel.lowercased()
            if lowerLabel.contains("pulse-unmask") {
                return .unmask
            }
            if lowerLabel.contains("pulse-mask") {
                return .mask
            }
        }
        
        if let accessibilityId = snapshot.accessibilityIdentifier {
            let lowerId = accessibilityId.lowercased()
            if lowerId.contains("pulse-unmask") {
                return .unmask
            }
            if lowerId.contains("pulse-mask") {
                return .mask
            }
        }
        
        return .undecided
    }
    
    private func resolveClassDecisionFromSnapshot(snapshot: ViewSnapshot) -> MaskDecision {
        if !config.unmaskViewClasses.isEmpty && isInstanceOfRegistered(className: snapshot.className, classNames: config.unmaskViewClasses) {
            return .unmask
        }
        if !config.maskViewClasses.isEmpty && isInstanceOfRegistered(className: snapshot.className, classNames: config.maskViewClasses) {
            return .mask
        }
        return .undecided
    }
    
    private func isInstanceOfRegistered(className: String, classNames: Set<String>) -> Bool {
        if classNames.contains(className) {
            return true
        }
        
        let classNameWithoutModule: String
        if let lastDotIndex = className.lastIndex(of: ".") {
            let indexAfterDot = className.index(after: lastDotIndex)
            classNameWithoutModule = String(className[indexAfterDot...])
        } else {
            classNameWithoutModule = className
        }
        
        for registeredClassName in classNames {
            if registeredClassName == className {
                return true
            }
            
            let registeredNameWithoutModule: String
            if let lastDotIndex = registeredClassName.lastIndex(of: ".") {
                let indexAfterDot = registeredClassName.index(after: lastDotIndex)
                registeredNameWithoutModule = String(registeredClassName[indexAfterDot...])
            } else {
                registeredNameWithoutModule = registeredClassName
            }
            
            if classNameWithoutModule == registeredNameWithoutModule {
                return true
            }
        }
        
        var cls: AnyClass? = NSClassFromString(className)
        if cls == nil {
            cls = NSClassFromString(classNameWithoutModule)
        }
        
        guard let classObj = cls else {
            return false
        }
        
        var currentClass: AnyClass? = classObj
        while let current = currentClass {
            let currentClassName = String(describing: current)
            
            if classNames.contains(currentClassName) {
                return true
            }
            
            let currentNameWithoutModule: String
            if let lastDotIndex = currentClassName.lastIndex(of: ".") {
                let indexAfterDot = currentClassName.index(after: lastDotIndex)
                currentNameWithoutModule = String(currentClassName[indexAfterDot...])
            } else {
                currentNameWithoutModule = currentClassName
            }
            
            for registeredClassName in classNames {
                let registeredNameWithoutModule: String
                if let lastDotIndex = registeredClassName.lastIndex(of: ".") {
                    let indexAfterDot = registeredClassName.index(after: lastDotIndex)
                    registeredNameWithoutModule = String(registeredClassName[indexAfterDot...])
                } else {
                    registeredNameWithoutModule = registeredClassName
                }
                
                if currentNameWithoutModule == registeredNameWithoutModule {
                    return true
                }
            }
            
            currentClass = class_getSuperclass(current)
            if currentClassName == "NSObject" {
                break
            }
        }
        
        return false
    }
    
    private func findViewsNeedingMask(snapshots: [ObjectIdentifier: ViewSnapshot], windowBounds: CGRect) -> [ViewSnapshot] {
        var viewsNeedingMask: [ViewSnapshot] = []
        
        for (_, snapshot) in snapshots {
            let isWindow = snapshot.className.contains("Window")
            let isVisible = !snapshot.isHidden && snapshot.alpha > 0 && (isWindow || snapshot.hasWindow)
            
            guard isVisible else { continue }
            
            var shouldMask = false
            
            if snapshot.isTextField {
                shouldMask = shouldMaskTextFieldFromSnapshot(snapshot: snapshot)
            } else if snapshot.isTextView {
                shouldMask = shouldMaskTextViewFromSnapshot(snapshot: snapshot)
            } else if snapshot.isLabel {
                shouldMask = snapshot.hasText && shouldMaskLabelFromSnapshot(snapshot: snapshot)
            } else if snapshot.isPickerView {
                shouldMask = shouldMaskSpinner()
            } else if snapshot.isImageView {
                shouldMask = snapshot.hasImage && shouldMaskImageFromSnapshot(snapshot: snapshot)
            } else if snapshot.isWebView {
                shouldMask = shouldMaskWebView()
            }
            
            let instanceDecision = resolveInstanceDecisionFromSnapshot(snapshot: snapshot)
            if instanceDecision == .mask {
                shouldMask = true
            }
            
            let classDecision = resolveClassDecisionFromSnapshot(snapshot: snapshot)
            if classDecision == .mask {
                shouldMask = true
            }
            
            if shouldMask {
                viewsNeedingMask.append(snapshot)
            }
        }
        
        return viewsNeedingMask
    }
    
    /// Get text area window rect for text fields/views, accounting for padding.
    /// Similar to Android's getTextAreaWindowRect - masks only the text content area, not the full view frame.
    /// Note: This requires the actual view instance, which we don't have in snapshot-only processing.
    /// For now, we use full frame masking. This can be enhanced by storing padding info in ViewSnapshot.
    private func getTextAreaWindowRect(
        snapshot: ViewSnapshot,
        windowBounds: CGRect,
        view: UIView?
    ) -> CGRect? {
        guard let windowFrame = snapshot.windowFrame else {
            return nil
        }
        
        // For text fields and text views, adjust for padding/insets if we have the view
        if snapshot.isTextField, let textField = view as? UITextField {
            // UITextField padding: leftView, rightView, and border style affect content area
            var leftPadding: CGFloat = textField.leftView?.frame.width ?? 0
            var rightPadding: CGFloat = textField.rightView?.frame.width ?? 0
            var topPadding: CGFloat = 0
            var bottomPadding: CGFloat = 0
            
            // Account for border insets
            if textField.borderStyle != .none {
                leftPadding += 8 // Approximate border padding
                rightPadding += 8
                topPadding += 4
                bottomPadding += 4
            }
            
            // Calculate text area rect
            let textAreaRect = CGRect(
                x: windowFrame.origin.x + leftPadding,
                y: windowFrame.origin.y + topPadding,
                width: max(0, windowFrame.width - leftPadding - rightPadding),
                height: max(0, windowFrame.height - topPadding - bottomPadding)
            )
            
            // Ensure valid rect
            guard textAreaRect.width > 0 && textAreaRect.height > 0 else {
                // Fallback to full frame if text area is invalid
                return clampRectToBounds(rect: windowFrame, bounds: windowBounds)
            }
            
            return clampRectToBounds(rect: textAreaRect, bounds: windowBounds)
        } else if snapshot.isTextView, let textView = view as? UITextView {
            // UITextView: use text container insets
            let leftPadding = textView.textContainerInset.left
            let rightPadding = textView.textContainerInset.right
            let topPadding = textView.textContainerInset.top
            let bottomPadding = textView.textContainerInset.bottom
            
            // Calculate text area rect
            let textAreaRect = CGRect(
                x: windowFrame.origin.x + leftPadding,
                y: windowFrame.origin.y + topPadding,
                width: max(0, windowFrame.width - leftPadding - rightPadding),
                height: max(0, windowFrame.height - topPadding - bottomPadding)
            )
            
            // Ensure valid rect
            guard textAreaRect.width > 0 && textAreaRect.height > 0 else {
                // Fallback to full frame if text area is invalid
                return clampRectToBounds(rect: windowFrame, bounds: windowBounds)
            }
            
            return clampRectToBounds(rect: textAreaRect, bounds: windowBounds)
        }
        
        // For other view types or when view is not available, use full frame
        return clampRectToBounds(rect: windowFrame, bounds: windowBounds)
    }
    
    private func applyTypeSpecificMaskingFromSnapshot(snapshot: ViewSnapshot, windowBounds: CGRect) -> CGRect? {
        // Never mask the window itself via type-specific logic
        let isWindow = snapshot.className.contains("Window")
        guard !isWindow else {
            return nil
        }
        
        guard let windowFrame = snapshot.windowFrame else {
            return nil
        }
        
        if snapshot.isTextField {
            let shouldMask = shouldMaskTextFieldFromSnapshot(snapshot: snapshot)
            if shouldMask {
                // Note: We can't get the actual view here (snapshot only), so use full frame
                // In a future enhancement, we could store padding info in ViewSnapshot
                let clamped = clampRectToBounds(rect: windowFrame, bounds: windowBounds)
                guard clamped.width > 0 && clamped.height > 0 else {
                    return nil
                }
                return clamped
            }
        } else if snapshot.isTextView {
            let shouldMask = shouldMaskTextViewFromSnapshot(snapshot: snapshot)
            if shouldMask {
                // Note: We can't get the actual view here (snapshot only), so use full frame
                let clamped = clampRectToBounds(rect: windowFrame, bounds: windowBounds)
                guard clamped.width > 0 && clamped.height > 0 else {
                    return nil
                }
                return clamped
            }
        } else if snapshot.isLabel {
            let shouldMask = snapshot.hasText && shouldMaskLabelFromSnapshot(snapshot: snapshot)
            if shouldMask {
                let clamped = clampRectToBounds(rect: windowFrame, bounds: windowBounds)
                guard clamped.width > 0 && clamped.height > 0 else {
                    return nil
                }
                return clamped
            }
        } else if snapshot.isPickerView {
            if shouldMaskSpinner() {
                return clampRectToBounds(rect: windowFrame, bounds: windowBounds)
            }
        } else if snapshot.isImageView {
            let shouldMask = snapshot.hasImage && shouldMaskImageFromSnapshot(snapshot: snapshot)
            if shouldMask {
                let clamped = clampRectToBounds(rect: windowFrame, bounds: windowBounds)
                guard clamped.width > 0 && clamped.height > 0 else {
                    return nil
                }
                return clamped
            }
        } else if snapshot.isWebView {
            if shouldMaskWebView() {
                return clampRectToBounds(rect: windowFrame, bounds: windowBounds)
            }
        }
        
        return nil
    }
    
    private func shouldMaskTextFieldFromSnapshot(snapshot: ViewSnapshot) -> Bool {
        if snapshot.isSecureTextEntry { return true }
        switch config.textAndInputPrivacy {
        case .maskAll: return true
        case .maskAllInputs: return true
        case .maskSensitiveInputs: return isSensitiveInputTypeFromSnapshot(snapshot: snapshot)
        }
    }
    
    private func shouldMaskTextViewFromSnapshot(snapshot: ViewSnapshot) -> Bool {
        if snapshot.isSecureTextEntry { return true }
        switch config.textAndInputPrivacy {
        case .maskAll: return true
        case .maskAllInputs: return true
        case .maskSensitiveInputs: return isSensitiveInputTypeFromSnapshot(snapshot: snapshot)
        }
    }
    
    private func shouldMaskLabelFromSnapshot(snapshot: ViewSnapshot) -> Bool {
        switch config.textAndInputPrivacy {
        case .maskAll: return true
        case .maskAllInputs: return false
        case .maskSensitiveInputs: return false
        }
    }
    
    private func shouldMaskImageFromSnapshot(snapshot: ViewSnapshot) -> Bool {
        return config.imagePrivacy == .maskAll && snapshot.hasImage
    }
    
    private func isSensitiveInputTypeFromSnapshot(snapshot: ViewSnapshot) -> Bool {
        if snapshot.isSecureTextEntry { return true }
        
        // Check textContentType rawValue (works for UITextField, but UITextView doesn't have this property)
        // rawValue format: "emailAddress", "telephoneNumber", "password", "newPassword", etc.
        if let textContentType = snapshot.textContentType?.lowercased() {
            if textContentType.contains("password") {
                return true
            }
            if textContentType.contains("email") || textContentType == "emailaddress" {
                return true
            }
            if textContentType.contains("telephone") || textContentType == "telephonenumber" {
                return true
            }
        }
        
        // Check keyboardType (works for both UITextField and UITextView)
        if let keyboardType = snapshot.keyboardType {
            if keyboardType == .emailAddress || keyboardType == .phonePad {
                return true
            }
        }
        
        // Check placeholder text (for UITextField only)
        if let placeholder = snapshot.placeholder?.lowercased() {
            if placeholder.contains("password") || placeholder.contains("email") || 
               placeholder.contains("phone") || placeholder.contains("mobile") {
                return true
            }
        }
        
        // Check accessibility label (works for both UITextField and UITextView)
        if let label = snapshot.accessibilityLabel?.lowercased() {
            if label.contains("password") || label.contains("email") || label.contains("phone") {
                return true
            }
        }
        
        // Check accessibility identifier (works for both UITextField and UITextView)
        if let identifier = snapshot.accessibilityIdentifier?.lowercased() {
            if identifier.contains("password") || identifier.contains("email") || identifier.contains("phone") {
                return true
            }
        }
        
        return false
    }
    
    /// Compute the delta between screen coordinates and window coordinates.
    /// Similar to Android's computeScreenToWindowOffset - converts screen coords to window (bitmap) coordinates.
    private func computeScreenToWindowOffset(view: UIView, window: UIWindow) -> CGPoint {
        // Get location in screen coordinates
        let screenFrame = view.convert(view.bounds, to: nil)
        let screenOrigin = screenFrame.origin
        
        // Get location in window coordinates
        let windowFrame = view.convert(view.bounds, to: window)
        let windowOrigin = windowFrame.origin
        
        // Calculate offset: screen - window
        return CGPoint(
            x: screenOrigin.x - windowOrigin.x,
            y: screenOrigin.y - windowOrigin.y
        )
    }
    
    /// Returns the visible rect of this view in window coordinates (matching the screenshot bitmap's coordinate space).
    /// Similar to Android's windowVisibleRectSafe - validates view state and converts coordinates safely.
    private func windowVisibleRectSafe(
        view: UIView,
        window: UIWindow,
        offset: CGPoint,
        logger: ((String) -> Void)? = nil
    ) -> CGRect? {
        guard isViewStateStableForCoordinateConversion(view: view) else {
            logger?("[SessionReplay] View state not stable for coordinate conversion: \(type(of: view))")
            return nil
        }
        
        // Get global visible rect (screen coordinates)
        guard let screenRect = globalVisibleRect(view: view) else {
            return nil
        }
        
        // Convert to window coordinates by applying offset
        let windowRect = CGRect(
            x: screenRect.origin.x - offset.x,
            y: screenRect.origin.y - offset.y,
            width: screenRect.width,
            height: screenRect.height
        )
        
        return windowRect
    }
    
    /// Check if view state is stable for coordinate conversion operations.
    /// Similar to Android's isViewStateStableForMatrixOperations.
    private func isViewStateStableForCoordinateConversion(view: UIView) -> Bool {
        guard view.isHidden == false else { return false }
        guard view.alpha > 0 else { return false }
        guard view.window != nil else { return false }
        guard view.bounds.width > 0 && view.bounds.height > 0 else { return false }
        
        // Check for active animations
        if let animationKeys = view.layer.animationKeys(), !animationKeys.isEmpty {
            return false
        }
        
        return true
    }
    
    /// Get global visible rect (screen coordinates) for a view.
    /// Equivalent to Android's getGlobalVisibleRect.
    /// Uses convert(_:to:) with nil to get screen coordinates.
    private func globalVisibleRect(view: UIView) -> CGRect? {
        guard view.window != nil else { return nil }
        
        // Convert view bounds to screen coordinates (nil = screen coordinate space)
        let screenRect = view.convert(view.bounds, to: nil)
        
        // Ensure valid rect
        guard screenRect.width > 0 && screenRect.height > 0 else { return nil }
        guard screenRect.origin.x.isFinite && screenRect.origin.y.isFinite else { return nil }
        guard screenRect.width.isFinite && screenRect.height.isFinite else { return nil }
        
        return screenRect
    }
    
    private func clampRectToBounds(rect: CGRect, bounds: CGRect) -> CGRect {
        guard rect.width > 0 && rect.height > 0 else { return .zero }
        guard rect.origin.x.isFinite && rect.origin.y.isFinite else { return .zero }
        guard rect.width.isFinite && rect.height.isFinite else { return .zero }
        
        let clampedX = max(0, min(rect.origin.x, bounds.width))
        let clampedY = max(0, min(rect.origin.y, bounds.height))
        
        let availableWidth = bounds.width - clampedX
        let availableHeight = bounds.height - clampedY
        
        let clampedWidth = min(rect.width, availableWidth)
        let clampedHeight = min(rect.height, availableHeight)
        
        let clamped = CGRect(
            x: clampedX,
            y: clampedY,
            width: max(0, clampedWidth),
            height: max(0, clampedHeight)
        )
        
        
        return clamped
    }
    
    /// Merge overlapping mask rects to reduce rendering overhead.
    /// Similar to Android's approach - combines adjacent/overlapping rects.
    private func mergeOverlappingRects(_ rects: [CGRect]) -> [CGRect] {
        guard rects.count > 1 else { return rects }
        
        var merged: [CGRect] = []
        var remaining = rects.sorted { $0.origin.y < $1.origin.y || ($0.origin.y == $1.origin.y && $0.origin.x < $1.origin.x) }
        
        while !remaining.isEmpty {
            var current = remaining.removeFirst()
            var mergedAny = true
            
            // Try to merge with other rects
            while mergedAny {
                mergedAny = false
                var i = 0
                while i < remaining.count {
                    let other = remaining[i]
                    
                    // Check if rects overlap or are adjacent (within 2px)
                    let tolerance: CGFloat = 2.0
                    let overlaps = current.intersects(other) ||
                        (abs(current.maxX - other.minX) <= tolerance && abs(current.minY - other.minY) <= tolerance && abs(current.maxY - other.maxY) <= tolerance) ||
                        (abs(current.minX - other.maxX) <= tolerance && abs(current.minY - other.minY) <= tolerance && abs(current.maxY - other.maxY) <= tolerance) ||
                        (abs(current.maxY - other.minY) <= tolerance && abs(current.minX - other.minX) <= tolerance && abs(current.maxX - other.maxX) <= tolerance) ||
                        (abs(current.minY - other.maxY) <= tolerance && abs(current.minX - other.minX) <= tolerance && abs(current.maxX - other.maxX) <= tolerance)
                    
                    if overlaps {
                        // Merge rects
                        current = current.union(other)
                        remaining.remove(at: i)
                        mergedAny = true
                    } else {
                        i += 1
                    }
                }
            }
            
            merged.append(current)
        }
        
        
        return merged
    }
    
    /// Validate mask rects before rendering - ensure all are within image bounds and valid.
    private func validateMaskRects(_ rects: [CGRect], imageSize: CGSize) -> [CGRect] {
        var validRects: [CGRect] = []
        
        for rect in rects {
            guard rect.width > 0 && rect.height > 0 else {
                continue
            }
            
            guard rect.origin.x.isFinite && rect.origin.y.isFinite else {
                continue
            }
            
            guard rect.width.isFinite && rect.height.isFinite else {
                continue
            }
            
            // Clamp to image bounds
            let clamped = CGRect(
                x: max(0, min(rect.origin.x, imageSize.width)),
                y: max(0, min(rect.origin.y, imageSize.height)),
                width: min(rect.width, imageSize.width - max(0, rect.origin.x)),
                height: min(rect.height, imageSize.height - max(0, rect.origin.y))
            )
            
            guard clamped.width > 0 && clamped.height > 0 else {
                continue
            }
            
            validRects.append(clamped)
        }
        
        return validRects
    }
    
    private func captureScreenshotSync(
        window: UIWindow,
        bounds: CGRect
    ) -> UIImage? {
        assert(Thread.isMainThread, "captureScreenshotSync must be called on main thread")
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        
        let image = renderer.image { context in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        
        guard image.size.width > 0 && image.size.height > 0 else {
            return nil
        }
        
        return image
    }
    
    
    private func drawMasksOnImage(
        image: UIImage,
        maskRects: [CGRect]
    ) -> UIImage? {
        guard !maskRects.isEmpty else {
            return image
        }
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        
        
        let maskedImage = renderer.image { context in
            let cgContext = context.cgContext
            
            image.draw(at: .zero)
            
            cgContext.saveGState()
            
            cgContext.setFillColor(UIColor.black.cgColor)
            cgContext.setBlendMode(.normal)
            cgContext.setShouldAntialias(false)
            cgContext.setAlpha(1.0)
        
            for rect in maskRects {
                // Clamp rect to image bounds (screenshot coordinate space)
                let clampedRect = CGRect(
                    x: max(0, min(rect.origin.x, image.size.width)),
                    y: max(0, min(rect.origin.y, image.size.height)),
                    width: min(rect.width, image.size.width - max(0, rect.origin.x)),
                    height: min(rect.height, image.size.height - max(0, rect.origin.y))
                )
                
                guard clampedRect.width > 0 && clampedRect.height > 0 else {
                    continue
                }
                
                let path = UIBezierPath(roundedRect: clampedRect, cornerRadius: 10)
                cgContext.addPath(path.cgPath)
                cgContext.fillPath()
            }
            
            cgContext.restoreGState()
        }
        
        return maskedImage
    }
    
    private func machTimeToMilliseconds(_ machTime: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanoseconds = Double(machTime) * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / 1_000_000.0 // Convert to milliseconds
    }
    
    private func findScrollView(in window: UIWindow) -> UIScrollView? {
        guard let rootView = window.rootViewController?.view else { return nil }
        return findScrollView(in: rootView)
    }
    
    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
    
    private func isViewStateStable(window: UIWindow) -> Bool {
        guard window.windowScene != nil else { return false }
        guard window.bounds.width > 0 && window.bounds.height > 0 else { return false }
        if let animationKeys = window.layer.animationKeys(), !animationKeys.isEmpty {
            return false
        }
        
        if let rootView = window.rootViewController?.view {
            guard rootView.window != nil else { return false }
            guard !rootView.isHidden else { return false }
            guard rootView.bounds.width > 0 && rootView.bounds.height > 0 else { return false }
            if let rootAnimationKeys = rootView.layer.animationKeys(), !rootAnimationKeys.isEmpty {
                return false
            }
        }
        
        if let navController = findTopNavigationController(in: window) {
            if navController.isBeingPresented || navController.isBeingDismissed {
                return false
            }
            
            if let topVC = navController.topViewController {
                if topVC.isBeingPresented || topVC.isBeingDismissed || topVC.isMovingFromParent || topVC.isMovingToParent {
                    return false
                }
            }
            
            if let transitionCoordinator = navController.transitionCoordinator, transitionCoordinator.isAnimated {
                return false
            }
        }
        
        if let rootVC = window.rootViewController {
            if rootVC.isBeingPresented || rootVC.isBeingDismissed || rootVC.isMovingFromParent || rootVC.isMovingToParent {
                return false
            }
            
            if let transitionCoordinator = rootVC.transitionCoordinator, transitionCoordinator.isAnimated {
                return false
            }
        }
        
        return true
    }
    
    private func findTopNavigationController(in window: UIWindow) -> UINavigationController? {
        guard let rootVC = window.rootViewController else { return nil }
        
        if let navController = rootVC as? UINavigationController {
            return navController
        }
        
        return findNavigationController(in: rootVC)
    }
    
    private func findNavigationController(in viewController: UIViewController) -> UINavigationController? {
        if let navController = viewController as? UINavigationController {
            return navController
        }
        
        if let presented = viewController.presentedViewController {
            if let navController = findNavigationController(in: presented) {
                return navController
            }
        }
        
        for child in viewController.children {
            if let navController = findNavigationController(in: child) {
                return navController
            }
        }
        
        if let navController = viewController.navigationController {
            return navController
        }
        
        return nil
    }
    
    private func isViewHierarchyVisible(window: UIWindow) -> Bool {
        var current: UIView? = window
        while let view = current {
            guard !view.isHidden else { return false }
            guard view.alpha > 0 else { return false }
            if !(view is UIWindow) {
                guard view.window != nil else { return false }
            }
            current = view.superview
        }
        return true
    }
}

public final class SessionReplayCompressor {
    private init() {}
    
    #if canImport(phlibwebp)
    private static let WEBP_MAX_DIMENSION = 16383
    #endif

    public static func compress(
        image: UIImage,
        quality: CGFloat
    ) -> (data: Data, format: SessionReplayFrame.ImageFormat)? {
        if let webpData = encodeWebP(image: image, quality: quality) {
            return (webpData, .webp)
        }
        if let jpegData = image.jpegData(compressionQuality: quality) {
            return (jpegData, .jpeg)
        }
        return nil
    }

    private static func encodeWebP(image: UIImage, quality: CGFloat) -> Data? {
        #if canImport(phlibwebp)
        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        guard width > 0, width <= WEBP_MAX_DIMENSION,
              height > 0, height <= WEBP_MAX_DIMENSION else {
            return nil
        }

        let bitmapInfo = cgImage.bitmapInfo
        let alphaInfo = CGImageAlphaInfo(
            rawValue: bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue
        )
        let hasAlpha = !(
            alphaInfo == CGImageAlphaInfo.none ||
            alphaInfo == .noneSkipFirst ||
            alphaInfo == .noneSkipLast
        )

        let colorSpace: CGColorSpace = cgImage.colorSpace?.model == .rgb
            ? cgImage.colorSpace!
            : CGColorSpace(name: CGColorSpace.linearSRGB)!
        let renderingIntent = cgImage.renderingIntent

        guard let destFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: hasAlpha ? 32 : 24,
            colorSpace: colorSpace,
            bitmapInfo: hasAlpha
                ? CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrderDefault.rawValue)
                : CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrderDefault.rawValue),
            renderingIntent: renderingIntent
        ) else {
            return nil
        }

        guard let dest = try? vImage_Buffer(cgImage: cgImage, format: destFormat, flags: .noFlags) else {
            return nil
        }
        defer { dest.data?.deallocate() }

        guard let rgba = dest.data else {
            return nil
        }
        let bytesPerRow = dest.rowBytes
        let webpQuality = Float(quality * 100)

        var config = WebPConfig()
        var picture = WebPPicture()
        var writer = WebPMemoryWriter()

        guard WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, webpQuality) != 0,
              WebPPictureInit(&picture) != 0 else {
            return nil
        }

        withUnsafeMutablePointer(to: &writer) { writerPointer in
            picture.use_argb = 1
            picture.width = Int32(width)
            picture.height = Int32(height)
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
        }

        WebPMemoryWriterInit(&writer)

        defer {
            WebPMemoryWriterClear(&writer)
            WebPPictureFree(&picture)
        }

        let importResult: Int32
        if hasAlpha {
            importResult = WebPPictureImportRGBA(
                &picture,
                rgba.bindMemory(to: UInt8.self, capacity: 4),
                Int32(bytesPerRow)
            )
        } else {
            importResult = WebPPictureImportRGB(
                &picture,
                rgba.bindMemory(to: UInt8.self, capacity: 3),
                Int32(bytesPerRow)
            )
        }

        guard importResult != 0 else { return nil }

        guard WebPEncode(&config, &picture) != 0 else { return nil }

        return Data(bytes: writer.mem, count: writer.size)
        #else
        return nil
        #endif
    }
}

#else

internal protocol SessionReplayCapturer {
    func capture(window: Any, scale: CGFloat, completion: @escaping (Any?) -> Void)
}

internal class ScreenshotCapturer: SessionReplayCapturer {
    init(config: SessionReplayConfig) {}
    func capture(window: Any, scale: CGFloat, completion: @escaping (Any?) -> Void) {
        completion(nil)
    }
}

internal class SessionReplayMasker {
    private let config: SessionReplayConfig
    init(config: SessionReplayConfig) { self.config = config }
    func captureWithMasking(window: Any) -> Any? { return nil }
}

public final class SessionReplayCompressor {
    private init() {}
    
    public static func compress(image: Any, quality: CGFloat) -> (data: Data, format: SessionReplayFrame.ImageFormat)? {
        return nil
    }
}

#endif
