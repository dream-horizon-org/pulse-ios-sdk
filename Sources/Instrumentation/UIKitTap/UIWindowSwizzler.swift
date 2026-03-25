/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
#if os(iOS) || os(tvOS)
import UIKit
import ObjectiveC
import OpenTelemetryApi

internal class UIWindowSwizzler {
    private static var swizzled = false
    private static let swizzleLock = NSLock()
    private static var logger: OpenTelemetryApi.Logger?
    private static var captureContext: Bool = true

    // Label extraction constants — matches Android values exactly
    private static let maxLabelSegments = 5
    private static let maxLabelLength = 200
    private static let labelDelimiter = " | "
    private static let maxLabelSearchDepth = 4

    // Scroll vs tap detection: if a touch moves more than this many points from
    // its start position, it is treated as a scroll/pan and NOT reported as a tap.
    // Mirrors Android's touchSlop mechanism.
    private static let tapSlopDistance: CGFloat = 10
    // Touch start positions keyed by UITouch identity — always accessed on main thread.
    private static var touchStartLocations: [ObjectIdentifier: CGPoint] = [:]

    static func swizzle(logger: OpenTelemetryApi.Logger, captureContext: Bool) {
        swizzleLock.lock()
        defer { swizzleLock.unlock() }
        guard !swizzled else { return }
        Self.logger = logger
        Self.captureContext = captureContext
        swizzleSendEvent()
        swizzled = true
    }

    private static func swizzleSendEvent() {
        guard let method = class_getInstanceMethod(
            UIWindow.self,
            #selector(UIWindow.sendEvent(_:))
        ) else { return }

        var originalIMP: IMP?

        let block: @convention(block) (UIWindow, UIEvent) -> Void = { window, event in

            guard event.type == .touches, let touches = event.allTouches else {
                if let imp = originalIMP {
                    let fn = unsafeBitCast(imp, to: (@convention(c) (UIWindow, Selector, UIEvent) -> Void).self)
                    fn(window, #selector(UIWindow.sendEvent(_:)), event)
                }
                return
            }

            // Track touch start positions for scroll vs tap detection.
            for touch in touches where touch.phase == .began {
                touchStartLocations[ObjectIdentifier(touch)] = touch.location(in: window)
            }
            // Clean up cancelled touches (system interruption, incoming call, etc.)
            for touch in touches where touch.phase == .cancelled {
                touchStartLocations.removeValue(forKey: ObjectIdentifier(touch))
            }

            let clickTarget: (view: UIView, location: CGPoint)? = {
                guard let touch = touches.first(where: { $0.phase == .ended }) else { return nil }
                let endLocation = touch.location(in: window)
                let key = ObjectIdentifier(touch)
                defer { touchStartLocations.removeValue(forKey: key) }

                // Scroll vs tap guard
                if let startLocation = touchStartLocations[key] {
                    let dx = endLocation.x - startLocation.x
                    let dy = endLocation.y - startLocation.y
                    let distSq = dx * dx + dy * dy
                    guard distSq <= tapSlopDistance * tapSlopDistance else {
                        return nil
                    }
                }

                guard let target = findClickTarget(in: window, at: endLocation) else {
                    return nil
                }
                return (target, endLocation)
            }()

            // Dispatch the original touch event
            if let imp = originalIMP {
                let fn = unsafeBitCast(imp, to: (@convention(c) (UIWindow, Selector, UIEvent) -> Void).self)
                fn(window, #selector(UIWindow.sendEvent(_:)), event)
            }

            // Emit after dispatch so touch responsiveness is not affected
            if let (target, location) = clickTarget {
                emitClickEvent(for: target, at: location)
            }
        }

        let swizzledIMP = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        originalIMP = method_setImplementation(method, swizzledIMP)
    }

    // MARK: - Hit Testing

    private static func findClickTarget(in window: UIWindow, at point: CGPoint) -> UIView? {
        guard let hitView = window.hitTest(point, with: nil) else { return nil }
        // Phase 1: Skip SwiftUI hosting views (future SwiftUI instrumentation)
        if isSwiftUIHostingView(hitView) { return nil }
        // Walk up to find the most meaningful interactable ancestor
        var candidate: UIView? = hitView
        while let view = candidate {
            if isClickTarget(view) { return view }
            candidate = view.superview
        }
        return nil
    }

    internal static func isSwiftUIHostingView(_ view: UIView) -> Bool {
        let name = String(describing: type(of: view))
        return name.contains("HostingView") || name.hasPrefix("_UIHostingView")
    }

    /// A view counts as a tap target if it is:
    ///   - A UIControl (UIButton, UISwitch, UISegmentedControl, etc.)
    ///   - A UITableViewCell or UICollectionViewCell (their tap gesture lives on the
    ///     parent scroll view, not the cell — so we match the cell directly)
    ///   - Has a UITapGestureRecognizer (custom tappable cards, image views, etc.)
    ///
    internal static func isClickTarget(_ view: UIView) -> Bool {
        if view is UIControl { return true }
        if view is UITableViewCell || view is UICollectionViewCell { return true }
        if let recognizers = view.gestureRecognizers,
           recognizers.contains(where: { $0 is UITapGestureRecognizer }) { return true }
        return false
    }

    // MARK: - Event Emission

    private static func emitClickEvent(for view: UIView, at point: CGPoint) {
        guard let logger = logger else { return }
        emitClickEvent(for: view, at: point, logger: logger, captureContext: captureContext)
    }

    internal static func emitClickEvent(
        for view: UIView,
        at point: CGPoint,
        logger: OpenTelemetryApi.Logger,
        captureContext: Bool
    ) {
        // app.widget.name = class name (consistent type, like Android's "Button"/"Switch")
        let widgetName = String(describing: type(of: view))

        var attributes: [String: AttributeValue] = [
            "app.screen.coordinate.x": .int(Int(point.x)),
            "app.screen.coordinate.y": .int(Int(point.y)),
            "app.widget.name": .string(widgetName),
        ]
        // app.click.context = label text when available
        let label: String? = captureContext
            ? (extractLabel(from: view) ?? view.accessibilityLabel)
            : nil
        if let label = label {
            attributes["app.click.context"] = .string("label=\(label)")
        }

        logger.logRecordBuilder()
            .setEventName("app.widget.click")
            .setAttributes(attributes)
            .emit()

        let contextLog = label.map { " | context: \"label=\($0)\"" } ?? ""
        print("[Pulse] app.widget.click → name: \"\(widgetName)\"\(contextLog) | (\(Int(point.x)), \(Int(point.y)))")
    }

    // MARK: - Label Extraction

    /// Priority: UILabel.text → direct UILabel child → accessibilityLabel → recursive text scan.
    /// Matches Android: TextView.text → contentDescription → recursive ViewGroup label scan.
    /// Only runs when captureContext is true.
    internal static func extractLabel(from view: UIView) -> String? {
        // PII safety for text input controls: only use developer-set accessibilityLabel
        // (equivalent to Android's contentDescription on EditText). Skip UILabel scan and
        // recursive descent — their internal subviews may render placeholder/system text
        // that is NOT developer intent, and .text contains user-entered PII.
        if view is UITextField || view is UITextView || view is UISearchBar {
            let label = view.accessibilityLabel
            return (label?.isEmpty == false) ? label : nil
        }

        // 1. UISegmentedControl: read selected segment title (emitClickEvent fires after dispatch,
        //    so selectedSegmentIndex already reflects the tapped segment)
        if let seg = view as? UISegmentedControl {
            return seg.titleForSegment(at: seg.selectedSegmentIndex)
        }

        // 2. View is itself a UILabel
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            return text
        }
        // 2. Direct UILabel child (e.g. UIButton.titleLabel)
        if let label = view.subviews.first(where: { $0 is UILabel }) as? UILabel,
           let text = label.text, !text.isEmpty {
            return text
        }
        // 3. accessibilityLabel
        if let aLabel = view.accessibilityLabel, !aLabel.isEmpty {
            return aLabel
        }
        // 4. Recursive text collection from descendants (container views like cards, cells)
        //    Max depth 4, max 5 segments, joined by " | ", truncated to 200 chars
        let segments = collectTextSegments(from: view, depth: 0)
        guard !segments.isEmpty else { return nil }
        var result = segments.prefix(maxLabelSegments).joined(separator: labelDelimiter)
        if result.count > maxLabelLength {
            var truncated = Array(segments.prefix(maxLabelSegments))
            while truncated.count > 1 {
                truncated.removeLast()
                result = truncated.joined(separator: labelDelimiter)
                if result.count <= maxLabelLength { break }
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func collectTextSegments(from view: UIView, depth: Int) -> [String] {
        guard depth <= maxLabelSearchDepth else { return [] }
        var segments: [String] = []
        for subview in view.subviews {
            // PII safety: never descend into text input views
            if subview is UITextField || subview is UITextView || subview is UISearchBar { continue }
            if let label = subview as? UILabel, let text = label.text, !text.isEmpty {
                segments.append(text)
            } else {
                segments += collectTextSegments(from: subview, depth: depth + 1)
            }
            if segments.count >= maxLabelSegments { break }
        }
        return segments
    }

}
#endif
