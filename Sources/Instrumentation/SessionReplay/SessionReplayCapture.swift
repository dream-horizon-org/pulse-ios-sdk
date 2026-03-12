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
                #if DEBUG
                if let vc = currentTopVC {
                    NSLog("[SessionReplay] 🔄 View controller changed to: \(type(of: vc))")
                }
                #endif
            }
            
            if let changeTime = self.lastViewControllerChangeTime {
                let timeSinceChange = Date().timeIntervalSince(changeTime)
                let minStabilizationDelay: TimeInterval = 0.1 // 100ms
                if timeSinceChange < minStabilizationDelay {
                    #if DEBUG
                    NSLog("[SessionReplay] ⏸️ Skipping capture: View controller changed \(String(format: "%.0f", timeSinceChange * 1000))ms ago (waiting for \(Int(minStabilizationDelay * 1000))ms)")
                    #endif
                    completion(nil)
                    return
                }
            }
            
            let isStable = self.isViewStateStable(window: window)
            let isVisible = self.isViewHierarchyVisible(window: window)
            
            #if DEBUG
            if !isStable {
                NSLog("[SessionReplay] ❌ Capture failed: window state not stable")
            }
            if !isVisible {
                NSLog("[SessionReplay] ❌ Capture failed: view hierarchy not visible")
            }
            #endif
            
            guard isStable && isVisible else {
                completion(nil)
                return
            }
            
            let windowBounds = window.bounds
            guard windowBounds.width > 0 && windowBounds.height > 0 else {
                #if DEBUG
                NSLog("[SessionReplay] ❌ Invalid window bounds: \(windowBounds)")
                #endif
                completion(nil)
                return
            }
            
            guard window.rootViewController != nil || !window.subviews.isEmpty else {
                #if DEBUG
                NSLog("[SessionReplay] ❌ Window has no root view controller and no subviews")
                #endif
                completion(nil)
                return
            }
            
            var scrollPositionAtSnapshot: CGFloat = 0
            if let scrollView = self.findScrollView(in: window) {
                scrollPositionAtSnapshot = scrollView.contentOffset.y
            }
            
            var snapshots: [ObjectIdentifier: ViewSnapshot] = [:]
            var visited: Set<ObjectIdentifier> = []
            
            #if DEBUG
            NSLog("[SessionReplay] 🔍 Starting widget snapshot on window: \(windowBounds)")
            NSLog("[SessionReplay] 🔍 Config: textAndInputPrivacy=\(self.config.textAndInputPrivacy), imagePrivacy=\(self.config.imagePrivacy)")
            if let rootVC = window.rootViewController {
                NSLog("[SessionReplay] 🔍 Window root VC: \(type(of: rootVC)), view: \(rootVC.view != nil ? "exists" : "nil")")
            }
            #endif
            
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
            
            #if DEBUG
            NSLog("[SessionReplay] 🔍 Snapshot: captured \(snapshots.count) views")
            #endif
            
            let screenshot = self.captureScreenshotSync(window: window, bounds: windowBounds)
            
            guard let screenshot = screenshot, screenshot.size.width > 0 && screenshot.size.height > 0 else {
                #if DEBUG
                NSLog("[SessionReplay] ❌ Screenshot capture failed or returned invalid image")
                #endif
                completion(nil)
                return
            }
            
            var scrollPositionAtScreenshot: CGFloat = 0
            if let scrollView = self.findScrollView(in: window) {
                scrollPositionAtScreenshot = scrollView.contentOffset.y
            }
            let scrollDelta = scrollPositionAtScreenshot - scrollPositionAtSnapshot
            
            if abs(scrollDelta) > 5.0 {
                #if DEBUG
                NSLog("[SessionReplay] ⏸️ Skipping frame: significant scroll (\(String(format: "%.1f", scrollDelta))px) detected during capture gap")
                #endif
                completion(nil)
                return
            }
            
            // Now dispatch masking processing to background thread
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    completion(nil)
                    return
                }
                
                var visited: Set<ObjectIdentifier> = []
                
                // Check for views that should be masked but have nil windowFrame (security check)
                let viewsNeedingMask = self.findViewsNeedingMask(snapshots: snapshots, windowBounds: windowBounds)
                let viewsWithNilWindowFrame = viewsNeedingMask.filter { $0.windowFrame == nil }
                
                #if DEBUG
                if !viewsWithNilWindowFrame.isEmpty {
                    NSLog("[SessionReplay] ⚠️ SECURITY WARNING: Found \(viewsWithNilWindowFrame.count) view(s) that should be masked but have nil windowFrame:")
                    for viewInfo in viewsWithNilWindowFrame {
                        NSLog("[SessionReplay]   - \(viewInfo.className) (isTextField: \(viewInfo.isTextField), isTextView: \(viewInfo.isTextView), isLabel: \(viewInfo.isLabel))")
                    }
                }
                #endif
                
                let maskRects = self.processMaskingFromSnapshot(
                    snapshots: snapshots,
                    rootViewId: ObjectIdentifier(window),
                    windowBounds: windowBounds,
                    visited: &visited
                )
                
                #if DEBUG
                NSLog("[SessionReplay] 🔍 Processed masking: found \(maskRects.count) maskable regions")
                if !maskRects.isEmpty {
                    for (index, rect) in maskRects.enumerated() {
                        NSLog("[SessionReplay]   Mask[\(index)]: x=\(Int(rect.origin.x)), y=\(Int(rect.origin.y)), w=\(Int(rect.width)), h=\(Int(rect.height))")
                    }
                } else {
                    NSLog("[SessionReplay] ✅ No masking required (no maskable widgets found)")
                }
                #endif
                
                if !viewsWithNilWindowFrame.isEmpty {
                    #if DEBUG
                    NSLog("[SessionReplay] 🚫 SECURITY: Skipping capture - views need masking but have nil windowFrame. This prevents data leak.")
                    #endif
                    completion(nil)
                    return
                }
                
                let viewsNeedingMaskCount = viewsNeedingMask.count
                
                let capturedScreenshot = screenshot
                
                let maskedImage = self.drawMasksOnImage(
                    image: capturedScreenshot,
                    maskRects: maskRects
                )
                
                #if DEBUG
                if !maskRects.isEmpty {
                    NSLog("[SessionReplay] 🎨 Applied \(maskRects.count) mask(s) to screenshot")
                }
                #endif
                
                guard let maskedImage = maskedImage, maskedImage.size.width > 0 && maskedImage.size.height > 0 else {
                    if viewsNeedingMaskCount > 0 {
                        #if DEBUG
                        NSLog("[SessionReplay] 🚫 SECURITY: Masking failed but \(viewsNeedingMaskCount) view(s) need masking - skipping capture to prevent data leak")
                        #endif
                        completion(nil)
                        return
                    }
                    completion(capturedScreenshot)
                    return
                }
                
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
        parentId: ObjectIdentifier? = nil
    ) {
        let viewId = ObjectIdentifier(view)
        if visited.contains(viewId) { return }
        visited.insert(viewId)
        
        if let checker = drawFlagChecker, checker() {
            return
        }
        
        let className = String(describing: type(of: view))
        let frame = view.frame
        let windowFrame: CGRect?
        if view == window {
            windowFrame = window.bounds
        } else if let superview = view.superview {
            let convertedFrame = superview.convert(view.frame, to: window)
            if convertedFrame.width > 0 && convertedFrame.height > 0 &&
               convertedFrame.origin.x.isFinite && convertedFrame.origin.y.isFinite &&
               convertedFrame.width.isFinite && convertedFrame.height.isFinite {
                windowFrame = convertedFrame
            } else {
                windowFrame = view.convert(view.bounds, to: window)
            }
        } else if let viewWindow = view.window, viewWindow == window {
            windowFrame = view.convert(view.bounds, to: window)
        } else {
            if let viewWindow = view.window {
                windowFrame = view.convert(view.bounds, to: viewWindow)
            } else {
                windowFrame = nil
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
                parentId: viewId
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
    
    private func applyTypeSpecificMaskingFromSnapshot(snapshot: ViewSnapshot, windowBounds: CGRect) -> CGRect? {
        guard let windowFrame = snapshot.windowFrame else {
            #if DEBUG
            NSLog("[SessionReplay] ⚠️ Warning: windowFrame is nil for \(snapshot.className) - cannot mask. This may indicate views were captured before layout.")
            #endif
            return nil
        }
        
        if snapshot.isTextField {
            let shouldMask = shouldMaskTextFieldFromSnapshot(snapshot: snapshot)
            if shouldMask {
                let clamped = clampRectToBounds(rect: windowFrame, bounds: windowBounds)
                guard clamped.width > 0 && clamped.height > 0 else {
                    return nil
                }
                return clamped
            }
        } else if snapshot.isTextView {
            let shouldMask = shouldMaskTextViewFromSnapshot(snapshot: snapshot)
            if shouldMask {
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
        
        return CGRect(
            x: clampedX,
            y: clampedY,
            width: max(0, clampedWidth),
            height: max(0, clampedHeight)
        )
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
                #if DEBUG
                NSLog("[SessionReplay] ⏸️ Skipping capture: Navigation controller is being presented/dismissed")
                #endif
                return false
            }
            
            if let topVC = navController.topViewController {
                if topVC.isBeingPresented || topVC.isBeingDismissed || topVC.isMovingFromParent || topVC.isMovingToParent {
                    #if DEBUG
                    NSLog("[SessionReplay] ⏸️ Skipping capture: View controller is transitioning")
                    #endif
                    return false
                }
            }
            
            if let transitionCoordinator = navController.transitionCoordinator, transitionCoordinator.isAnimated {
                #if DEBUG
                NSLog("[SessionReplay] ⏸️ Skipping capture: Navigation transition in progress")
                #endif
                return false
            }
        }
        
        if let rootVC = window.rootViewController {
            if rootVC.isBeingPresented || rootVC.isBeingDismissed || rootVC.isMovingFromParent || rootVC.isMovingToParent {
                #if DEBUG
                NSLog("[SessionReplay] ⏸️ Skipping capture: Root view controller is transitioning")
                #endif
                return false
            }
            
            if let transitionCoordinator = rootVC.transitionCoordinator, transitionCoordinator.isAnimated {
                #if DEBUG
                NSLog("[SessionReplay] ⏸️ Skipping capture: View controller transition in progress")
                #endif
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
