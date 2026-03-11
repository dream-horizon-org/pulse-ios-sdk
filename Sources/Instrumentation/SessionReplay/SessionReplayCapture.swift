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

// MARK: - Capturer Protocol & Implementation

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

// MARK: - View Hierarchy Snapshot

/// Lightweight snapshot of view hierarchy data for background thread processing
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
    // Type-specific data
    let isTextField: Bool
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

// MARK: - Privacy Masker

internal class SessionReplayMasker {
    private let config: SessionReplayConfig
    private var drawFlagChecker: (() -> Bool)?

    init(config: SessionReplayConfig) {
        self.config = config
    }
    
    func setDrawFlagChecker(_ checker: @escaping () -> Bool) {
        self.drawFlagChecker = checker
    }

    /// Async version of captureWithMasking - runs on background threads
    func captureWithMaskingAsync(window: UIWindow, scale: CGFloat, completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
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
            
            var snapshots: [ObjectIdentifier: ViewSnapshot] = [:]
            var visited: Set<ObjectIdentifier> = []
            
            #if DEBUG
            NSLog("[SessionReplay] 🔍 Starting widget snapshot on window: \(windowBounds)")
            NSLog("[SessionReplay] 🔍 Config: textAndInputPrivacy=\(self.config.textAndInputPrivacy), imagePrivacy=\(self.config.imagePrivacy)")
            if let rootVC = window.rootViewController {
                NSLog("[SessionReplay] 🔍 Window root VC: \(type(of: rootVC)), view: \(rootVC.view != nil ? "exists" : "nil")")
            }
            #endif
            
            self.snapshotViewHierarchy(
                view: window,
                window: window,
                snapshots: &snapshots,
                visited: &visited
            )
            
            #if DEBUG
            NSLog("[SessionReplay] 🔍 Snapshot: captured \(snapshots.count) views")
            #endif
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    completion(nil)
                    return
                }
                
                var visited: Set<ObjectIdentifier> = []
                
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
                
                self.captureScreenshotAsync(window: window, bounds: windowBounds) { screenshot in
                    guard let screenshot = screenshot else {
                        completion(nil)
                        return
                    }
                    
                let maskedImage = self.drawMasksOnImage(
                    image: screenshot,
                    maskRects: maskRects
                )
                    
                    #if DEBUG
                    if !maskRects.isEmpty {
                        NSLog("[SessionReplay] 🎨 Applied \(maskRects.count) mask(s) to screenshot")
                    }
                    #endif
                    
                    guard let maskedImage = maskedImage, maskedImage.size.width > 0 && maskedImage.size.height > 0 else {
                        // Fallback: return original screenshot if masking fails
                        completion(screenshot)
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
    }

    
    private func resolveInstanceDecision(view: UIView) -> MaskDecision {
        if view.hasPulseReplayUnmaskTag {
            return .unmask
        }
        if view.hasPulseReplayMaskTag {
            return .mask
        }
        
        if let accessibilityLabel = view.accessibilityLabel {
            let lowerLabel = accessibilityLabel.lowercased()
            if lowerLabel.contains("pulse-unmask") {
                return .unmask
            }
            if lowerLabel.contains("pulse-mask") {
                return .mask
            }
        }
        
        return .undecided
    }
    
    private func resolveClassDecision(view: UIView) -> MaskDecision {
        if !config.unmaskViewClasses.isEmpty && isInstanceOfRegistered(view: view, classNames: config.unmaskViewClasses) {
            return .unmask
        }
        if !config.maskViewClasses.isEmpty && isInstanceOfRegistered(view: view, classNames: config.maskViewClasses) {
            return .mask
        }
        return .undecided
    }
    
    private func isInstanceOfRegistered(view: UIView, classNames: Set<String>) -> Bool {
        var currentClass: AnyClass? = type(of: view)
        while let cls = currentClass {
            let className = String(describing: cls)
            if classNames.contains(className) {
            return true
            }
            currentClass = class_getSuperclass(cls)
            if className == "NSObject" {
                break
            }
        }
        return false
    }

    private func applyTypeSpecificMasking(view: UIView) -> CGRect? {
        if let textField = view as? UITextField {
            let shouldMask = shouldMaskTextField(textField)
            if shouldMask {
                let rect = getTextAreaWindowRect(view: textField)
                if rect != nil {
                    NSLog("[SessionReplay] 🎭 Type-specific: UITextField (textAndInputPrivacy=\(config.textAndInputPrivacy))")
                }
                return rect
            }
        } else if let label = view as? UILabel {
            let hasContent = !(label.text?.isEmpty ?? true) || !(label.attributedText?.string.isEmpty ?? true)
            let shouldMask = hasContent && shouldMaskLabel(label)
            if shouldMask {
                let rect = getTextAreaWindowRect(view: label)
                if rect != nil {
                    NSLog("[SessionReplay] 🎭 Type-specific: UILabel (textAndInputPrivacy=\(config.textAndInputPrivacy))")
                }
                return rect
            }
        } else if view is UIPickerView {
            if shouldMaskSpinner() {
                NSLog("[SessionReplay] 🎭 Type-specific: UIPickerView (textAndInputPrivacy=\(config.textAndInputPrivacy))")
                return getWindowVisibleRect(view: view, in: view.window)
            }
        } else if let imageView = view as? UIImageView {
            let shouldMask = shouldMaskImage(imageView)
            if shouldMask {
                let rect = getWindowVisibleRect(view: view, in: view.window)
                if rect != nil {
                    NSLog("[SessionReplay] 🎭 Type-specific: UIImageView (imagePrivacy=\(config.imagePrivacy))")
                }
                return rect
            }
        } else if view is WKWebView {
            if shouldMaskWebView() {
                NSLog("[SessionReplay] 🎭 Type-specific: WKWebView")
                return getWindowVisibleRect(view: view, in: view.window)
            }
        }
        return nil
    }
    
    private func getWindowVisibleRect(view: UIView, in window: UIWindow?) -> CGRect? {
        guard let window = window, let superview = view.superview else { return nil }
        guard isViewStateStable(view: view) else { return nil }
        
        let frameInWindow = superview.convert(view.frame, to: window)
        
        guard frameInWindow.width > 0 && frameInWindow.height > 0 else { return nil }
        guard frameInWindow.origin.x.isFinite && frameInWindow.origin.y.isFinite else { return nil }
        guard frameInWindow.width.isFinite && frameInWindow.height.isFinite else { return nil }
        
        let windowBounds = window.bounds
        let visibleRect = frameInWindow.intersection(windowBounds)
        guard visibleRect.width > 0 && visibleRect.height > 0 else {
            return nil
        }
        
        return CGRect(
            x: max(0, min(visibleRect.origin.x, windowBounds.width)),
            y: max(0, min(visibleRect.origin.y, windowBounds.height)),
            width: min(visibleRect.width, windowBounds.width - max(0, visibleRect.origin.x)),
            height: min(visibleRect.height, windowBounds.height - max(0, visibleRect.origin.y))
        )
    }
    
    private func getTextAreaWindowRect(view: UIView) -> CGRect? {
        guard let window = view.window else { return nil }
        
        let fullRect = getWindowVisibleRect(view: view, in: window)
        guard let fullRect = fullRect else { return nil }
        
        if let textField = view as? UITextField {
            let textRect = textField.textRect(forBounds: textField.bounds)
            let textAreaInWindow = CGRect(
                x: fullRect.origin.x + textRect.origin.x,
                y: fullRect.origin.y + textRect.origin.y,
                width: textRect.width,
                height: textRect.height
            )
            return (textAreaInWindow.width > 0 && textAreaInWindow.height > 0) ? textAreaInWindow : fullRect
        }
        
        return fullRect
    }
    
    private func isViewVisible(_ view: UIView) -> Bool {
        guard !view.isHidden else { return false }
        guard view.alpha > 0 else { return false }
        if view is UIWindow {
            return true
        }
        guard view.window != nil else { return false }
        return true
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
    
    /// Check if input is sensitive type (matches Android's isSensitiveInputType)
    private func isSensitiveInputType(_ textField: UITextField) -> Bool {
        if isPasswordField(textField) { return true }
        return isEmailField(textField) || isPhoneField(textField)
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
        
        // Heuristic: check placeholder or accessibility label
        let placeholder = textField.placeholder?.lowercased() ?? ""
        let accessibilityLabel = textField.accessibilityLabel?.lowercased() ?? ""
        if placeholder.contains("phone") || placeholder.contains("mobile") ||
           accessibilityLabel.contains("phone") || accessibilityLabel.contains("mobile") {
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
        if let superview = view.superview {
            windowFrame = superview.convert(view.frame, to: window)
        } else {
            windowFrame = nil
        }
        
        let textField = view as? UITextField
        let label = view as? UILabel
        let imageView = view as? UIImageView
        let isTextField = textField != nil
        let isLabel = label != nil
        let isImageView = imageView != nil
        let isPickerView = view is UIPickerView
        let isWebView = view is WKWebView
        
        
        // Text field specific
        let isSecureTextEntry = textField?.isSecureTextEntry ?? false
        let textContentType: String?
        let keyboardType: UIKeyboardType?
        if #available(iOS 10.0, *) {
            textContentType = textField?.textContentType?.rawValue
        } else {
            textContentType = nil
        }
        keyboardType = textField?.keyboardType
        
        let hasText: Bool
        if let textField = textField {
            hasText = !(textField.text?.isEmpty ?? true) || !(textField.placeholder?.isEmpty ?? true)
        } else if let label = label {
            hasText = !(label.text?.isEmpty ?? true) || !(label.attributedText?.string.isEmpty ?? true)
        } else {
            hasText = false
        }
        
        let hasImage = imageView?.image != nil
        let subviewIds = view.subviews.map { ObjectIdentifier($0) }
        
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
            isTextField: isTextField,
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
        return classNames.contains(className)
    }
    
    private func applyTypeSpecificMaskingFromSnapshot(snapshot: ViewSnapshot, windowBounds: CGRect) -> CGRect? {
        guard let windowFrame = snapshot.windowFrame else {
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
        
        if let textContentType = snapshot.textContentType {
            if textContentType.contains("password") {
                return true
            }
            if textContentType.contains("email") {
                return true
            }
            if textContentType.contains("telephone") {
                return true
            }
        }
        
        if let keyboardType = snapshot.keyboardType {
            if keyboardType == .emailAddress || keyboardType == .phonePad {
                return true
            }
        }
        
        if let label = snapshot.accessibilityLabel?.lowercased() {
            if label.contains("password") || label.contains("email") || label.contains("phone") {
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
    
    private func captureScreenshotAsync(
        window: UIWindow,
        bounds: CGRect,
        completion: @escaping (UIImage?) -> Void
    ) {
        // Dispatch to main thread to access window.screen safely
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
            
            let image = renderer.image { context in
                window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                guard image.size.width > 0 && image.size.height > 0 else {
                    completion(nil)
                    return
                }
                
                completion(image)
            }
        }
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
        
        return true
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

// MARK: - Image Compressor

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

// MARK: - Non-iOS Stubs

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
