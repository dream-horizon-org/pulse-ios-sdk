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

    /// Opened at viewDidLoad (first load) or viewWillAppear (subsequent appearances).
    /// Closed at viewDidAppear. Span name: "Created".
    /// Events: ViewDidLoad → ViewWillAppear → ViewIsAppearing → ViewDidAppear.
    /// Gets pulse.type = screen_load.
    private var appearingSpan: Span?
    private var appearingScreenName: String?

    /// Opened in viewWillDisappear, closed in viewDidDisappear. Span name: "Stopped".
    /// Events: ViewWillDisappear → ViewDidDisappear.
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

    func viewControllerDidLoad(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))
        let capturedTracer: Tracer? = queue.sync { tracer }

        // viewDidLoad fires only on first load, before viewWillAppear.
        // Start the appearing span here so ViewDidLoad is the first event.
        // Force-close any stale span without adding a closing event.
        forceEndStaleAppearingSpan()
        startAppearingSpan(spanName: "Created", screenName: screenName, tracer: capturedTracer, firstEvent: "ViewDidLoad")
    }

    func viewControllerWillAppear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))

        // Read tracer and check span existence atomically in one queue.sync
        // to avoid a race between the check and the addEvent.
        var capturedTracer: Tracer? = nil
        var spanAlreadyExists = false
        queue.sync {
            capturedTracer = self.tracer
            if self.appearingSpan != nil && self.appearingScreenName == screenName {
                // Span was started in viewDidLoad — just add the event
                self.appearingSpan?.addEvent(name: "ViewWillAppear")
                spanAlreadyExists = true
            }
        }

        if !spanAlreadyExists {
            // Re-appearance — viewDidLoad didn't fire (VC still in memory), use "Restarted"
            forceEndStaleAppearingSpan()
            startAppearingSpan(spanName: "Restarted", screenName: screenName, tracer: capturedTracer, firstEvent: "ViewWillAppear")
        }
    }

    func viewControllerIsAppearing(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))
        queue.sync {
            guard let span = appearingSpan, appearingScreenName == screenName else { return }
            span.addEvent(name: "ViewIsAppearing")
        }
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

        // Normal close — adds ViewDidAppear event and ends the span
        normalEndAppearingSpan(screenName: screenName)

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

        // Force-close any stale disappearing span without adding a closing event,
        // so it doesn't produce a duplicate complete-looking span in the backend.
        forceEndStaleDisappearingSpan()

        // Start the disappearing span — will be closed normally in viewDidDisappear
        startDisappearingSpan(screenName: screenName, tracer: capturedTracer)
    }

    func viewControllerDidDisappear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))

        // Normal close — adds ViewDidDisappear event and ends the span
        normalEndDisappearingSpan(screenName: screenName)
    }

    #endif

    // MARK: - Created / Restarted Span → viewDidAppear = screen_load

    private func startAppearingSpan(spanName: String, screenName: String, tracer: Tracer?, firstEvent: String) {
        guard let tracer = tracer else { return }
        let span = tracer.spanBuilder(spanName: spanName)
            .setAttribute(key: PulseAttributes.viewControllerName, value: screenName)
            .setAttribute(key: PulseAttributes.screenName, value: screenName)
            .setNoParent()
            .startSpan()
        span.addEvent(name: firstEvent)
        queue.sync {
            appearingSpan = span
            appearingScreenName = screenName
        }
    }

    /// Normal close: called from viewDidAppear. Adds ViewDidAppear event then ends.
    private func normalEndAppearingSpan(screenName: String) {
        let span: Span? = queue.sync {
            guard let s = appearingSpan, appearingScreenName == screenName else { return nil }
            appearingSpan = nil
            appearingScreenName = nil
            return s
        }
        guard let span = span else { return }
        span.addEvent(name: "ViewDidAppear")
        span.end()
    }

    /// Stale cleanup: called before starting a new appearing span.
    /// Ends without adding any event so it doesn't produce a misleading complete span.
    private func forceEndStaleAppearingSpan() {
        let span: Span? = queue.sync {
            guard let s = appearingSpan else { return nil }
            appearingSpan = nil
            appearingScreenName = nil
            return s
        }
        span?.end()
    }

    // MARK: - Stopped Span (viewWillDisappear → viewDidDisappear)

    private func startDisappearingSpan(screenName: String, tracer: Tracer?) {
        guard let tracer = tracer else { return }
        let span = tracer.spanBuilder(spanName: "Stopped")
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

    /// Normal close: called from viewDidDisappear. Adds ViewDidDisappear event then ends.
    private func normalEndDisappearingSpan(screenName: String) {
        let span: Span? = queue.sync {
            guard let s = disappearingSpan, disappearingScreenName == screenName else { return nil }
            disappearingSpan = nil
            disappearingScreenName = nil
            return s
        }
        guard let span = span else { return }
        span.addEvent(name: "ViewDidDisappear")
        span.end()
    }

    /// Stale cleanup: called before starting a new disappearing span.
    /// Ends without adding any event so it doesn't produce a misleading complete span.
    private func forceEndStaleDisappearingSpan() {
        let span: Span? = queue.sync {
            guard let s = disappearingSpan else { return nil }
            disappearingSpan = nil
            disappearingScreenName = nil
            return s
        }
        span?.end()
    }

    // MARK: - Session Span (viewDidAppear → viewWillDisappear)

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

