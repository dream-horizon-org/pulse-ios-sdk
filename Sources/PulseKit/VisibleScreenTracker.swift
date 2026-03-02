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
    func viewControllerWillAppear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))
        let capturedTracer: Tracer? = queue.sync { tracer }
        emitLifecycleSpan(spanName: "ViewWillAppear", screenName: screenName, tracer: capturedTracer)
    }

    func viewControllerDidAppear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))

        var previousScreen: String? = nil
        var capturedTracer: Tracer? = nil
        queue.sync { [weak self] in
            guard let self = self else { return }
            if let current = self.currentViewController, current != screenName {
                self._previouslyVisibleScreen = current
                previousScreen = current
            }
            self.currentViewController = screenName

            if self.isFirstScreen {
                self.isFirstScreen = false
            }
            capturedTracer = self.tracer
        }

        endSessionSpan()
        startSessionSpan(screenName: screenName, tracer: capturedTracer)
        emitScreenLoadSpan(screenName: screenName, tracer: capturedTracer)

        AppStartupTimer.shared.end()
    }

    func viewControllerWillDisappear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))
        let capturedTracer: Tracer? = queue.sync { tracer }
        emitLifecycleSpan(spanName: "ViewWillDisappear", screenName: screenName, tracer: capturedTracer)

        let current = currentlyVisibleScreen
        guard screenName == current else { return }
        endSessionSpan()
    }

    func viewControllerDidDisappear(_ viewController: UIViewController) {
        let screenName = String(describing: type(of: viewController))
        let capturedTracer: Tracer? = queue.sync { tracer }
        emitLifecycleSpan(spanName: "ViewDidDisappear", screenName: screenName, tracer: capturedTracer)
    }
    #endif

    // MARK: - Screen Load Span

    private func emitScreenLoadSpan(screenName: String, tracer: Tracer?) {
        guard let tracer = tracer else { return }
        let span = tracer.spanBuilder(spanName: "ViewDidAppear")
            .setAttribute(key: PulseAttributes.viewControllerName, value: screenName)
            .setAttribute(key: PulseAttributes.screenName, value: screenName)
            .setNoParent()
            .startSpan()
        span.end()
    }

    // MARK: - Screen Session Span

    private func startSessionSpan(screenName: String, tracer: Tracer?) {
        guard let tracer = tracer else { return }
        let span = tracer.spanBuilder(spanName: "ViewControllerSession")
            .setAttribute(key: PulseAttributes.viewControllerName, value: screenName)
            .setAttribute(key: PulseAttributes.screenName, value: screenName)
            .setNoParent()
            .startSpan()

        queue.sync { sessionSpan = span }
    }

    // MARK: - Lifecycle Spans

    private func emitLifecycleSpan(spanName: String, screenName: String, tracer: Tracer?) {
        guard let tracer = tracer else { return }
        let span = tracer.spanBuilder(spanName: spanName)
            .setAttribute(key: PulseAttributes.viewControllerName, value: screenName)
            .setAttribute(key: PulseAttributes.screenName, value: screenName)
            .setNoParent()
            .startSpan()
        span.end()
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

