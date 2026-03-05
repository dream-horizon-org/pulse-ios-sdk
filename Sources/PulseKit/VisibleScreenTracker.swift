/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi
#if os(iOS) || os(tvOS)
import UIKit
#endif

internal class VisibleScreenTracker {
    static let shared = VisibleScreenTracker()

    private var currentViewController: String?
    private var _previouslyVisibleScreen: String?
    private var isFirstScreen: Bool = true
    private let queue = DispatchQueue(label: "com.pulse.ios.sdk.visiblescreen")

    private var tracer: Tracer?

    /// Opened in viewWillAppear, closed in viewDidAppear.
    /// Measures transition-in animation duration. Gets pulse.type = screen_load.
    private var appearingSpan: Span?
    private var appearingScreenName: String?

    /// Opened in viewWillDisappear, closed in viewDidDisappear.
    /// Measures transition-out animation duration.
    private var disappearingSpan: Span?
    private var disappearingScreenName: String?

    /// Opened in viewDidAppear, closed in viewWillDisappear.
    /// Measures time user spent on screen. Gets pulse.type = screen_session.
    private var sessionSpan: Span?

    private init() {}

    /// Must be called once during SDK init to enable screen load / session spans.
    func start(tracer: Tracer) {
        queue.sync { self.tracer = tracer }
    }

    var currentlyVisibleScreen: String {
        return queue.sync { currentViewController ?? "unknown" }
    }

    var previouslyVisibleScreen: String? {
        return queue.sync { _previouslyVisibleScreen }
    }

    #if os(iOS) || os(tvOS)

    // MARK: - Swizzle Callbacks

    func viewControllerWillAppear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))
        let capturedTracer: Tracer? = queue.sync { tracer }

        // Safety: end any stale appearing span from a previous screen that never completed
        endAppearingSpan(screenName: nil)

        // Start the appearing span — will be closed in viewDidAppear.
        // This span represents screen_load: from pre-appearance to fully appeared.
        startAppearingSpan(screenName: screenName, tracer: capturedTracer)
    }

    func viewControllerDidAppear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))

        var capturedTracer: Tracer? = nil
        queue.sync { [weak self] in
            guard let self = self else { return }
            if let current = self.currentViewController, current != screenName {
                self._previouslyVisibleScreen = current
            }
            self.currentViewController = screenName
            if self.isFirstScreen {
                self.isFirstScreen = false
            }
            capturedTracer = self.tracer
        }

        // Close the appearing span — screen_load duration ends here
        endAppearingSpan(screenName: screenName)

        // End any previous session (e.g. tab switch where willDisappear never fired cleanly)
        endSessionSpan()

        // Start session — measures how long user stays on this screen
        startSessionSpan(screenName: screenName, tracer: capturedTracer)

        AppStartupTimer.shared.end()
    }

    func viewControllerWillDisappear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))
        let capturedTracer: Tracer? = queue.sync { tracer }

        // End the session span — user is leaving the screen
        let current = currentlyVisibleScreen
        if screenName == current {
            endSessionSpan()
        }

        // Safety: end any stale disappearing span
        endDisappearingSpan(screenName: nil)

        // Start the disappearing span — will be closed in viewDidDisappear
        startDisappearingSpan(screenName: screenName, tracer: capturedTracer)
    }

    func viewControllerDidDisappear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))

        // Close the disappearing span
        endDisappearingSpan(screenName: screenName)
    }

    #endif

    // MARK: - Appearing Span (ViewWillAppear → ViewDidAppear) = screen_load

    private func startAppearingSpan(screenName: String, tracer: Tracer?) {
        guard let tracer = tracer else { return }
        let span = tracer.spanBuilder(spanName: "ViewAppearing")
            .setAttribute(key: PulseAttributes.viewControllerName, value: screenName)
            .setAttribute(key: PulseAttributes.screenName, value: screenName)
            .setNoParent()
            .startSpan()
        span.addEvent(name: "ViewWillAppear")
        queue.sync {
            appearingSpan = span
            appearingScreenName = screenName
        }
    }

    /// Pass nil screenName to force-end regardless of screen (stale cleanup).
    private func endAppearingSpan(screenName: String?) {
        let span: Span? = queue.sync {
            guard let s = appearingSpan else { return nil }
            if let name = screenName, name != appearingScreenName { return nil }
            appearingSpan = nil
            appearingScreenName = nil
            return s
        }
        guard let span = span else { return }
        span.addEvent(name: "ViewDidAppear")
        span.end()
    }

    // MARK: - Disappearing Span (ViewWillDisappear → ViewDidDisappear)

    private func startDisappearingSpan(screenName: String, tracer: Tracer?) {
        guard let tracer = tracer else { return }
        let span = tracer.spanBuilder(spanName: "ViewDisappearing")
            .setAttribute(key: PulseAttributes.viewControllerName, value: screenName)
            .setAttribute(key: PulseAttributes.screenName, value: screenName)
            .setNoParent()
            .startSpan()
        span.addEvent(name: "ViewWillDisappear")
        queue.sync {
            disappearingSpan = span
            disappearingScreenName = screenName
        }
    }

    /// Pass nil screenName to force-end regardless of screen (stale cleanup).
    private func endDisappearingSpan(screenName: String?) {
        let span: Span? = queue.sync {
            guard let s = disappearingSpan else { return nil }
            if let name = screenName, name != disappearingScreenName { return nil }
            disappearingSpan = nil
            disappearingScreenName = nil
            return s
        }
        guard let span = span else { return }
        span.addEvent(name: "ViewDidDisappear")
        span.end()
    }

    // MARK: - Session Span (ViewDidAppear → ViewWillDisappear)

    private func startSessionSpan(screenName: String, tracer: Tracer?) {
        guard let tracer = tracer else { return }
        let span = tracer.spanBuilder(spanName: "ViewControllerSession")
            .setAttribute(key: PulseAttributes.viewControllerName, value: screenName)
            .setAttribute(key: PulseAttributes.screenName, value: screenName)
            .setNoParent()
            .startSpan()
        queue.sync { sessionSpan = span }
    }

    private func endSessionSpan() {
        let previous: Span? = queue.sync {
            let s = sessionSpan
            sessionSpan = nil
            return s
        }
        if let span = previous {
            span.end()
        }
    }
}

