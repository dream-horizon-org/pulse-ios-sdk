import UIKit
import PulseKit
import OpenTelemetryApi

class MainViewController: UIViewController {
    
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        title = "Pulse iOS SDK"
        view.backgroundColor = .systemBackground
        
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
        
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
        
        // Header
        let headerLabel = UILabel()
        headerLabel.text = "Pulse iOS SDK Demo"
        headerLabel.font = .systemFont(ofSize: 24, weight: .bold)
        headerLabel.textAlignment = .center
        stackView.addArrangedSubview(headerLabel)
        
        stackView.addArrangedSubview(createSeparator())
        
        // ── Telemetry Testing ──
        stackView.addArrangedSubview(createSectionHeader("Telemetry Testing"))
        
        stackView.addArrangedSubview(createButton(
            title: "Track Custom Event",
            action: #selector(trackEventTapped)
        ))
        stackView.addArrangedSubview(createButton(
            title: "Track Non-Fatal Error",
            action: #selector(trackNonFatalTapped)
        ))
        stackView.addArrangedSubview(createButton(
            title: "Track Span (Closure)",
            action: #selector(trackSpanTapped)
        ))
        stackView.addArrangedSubview(createButton(
            title: "Start Span (Manual)",
            action: #selector(startSpanTapped)
        ))
        stackView.addArrangedSubview(createButton(
            title: "Make Network Request",
            action: #selector(networkRequestTapped)
        ))
        
        stackView.addArrangedSubview(createSeparator())
        
        // ── OTel Direct API Testing ──
        stackView.addArrangedSubview(createSectionHeader("OTel Direct API"))
        
        stackView.addArrangedSubview(createButton(
            title: "Emit OTel Log (all severities)",
            action: #selector(emitOtelLogTapped),
            color: .systemTeal
        ))
        stackView.addArrangedSubview(createButton(
            title: "Span with Events + Attributes",
            action: #selector(spanWithEventsTapped),
            color: .systemTeal
        ))
        stackView.addArrangedSubview(createButton(
            title: "Nested Spans (parent-child)",
            action: #selector(nestedSpansTapped),
            color: .systemTeal
        ))
        stackView.addArrangedSubview(createButton(
            title: "Log with Thread Info",
            action: #selector(logWithThreadInfoTapped),
            color: .systemTeal
        ))
        
        stackView.addArrangedSubview(createSeparator())
        
        // ── Crash Testing ──
        stackView.addArrangedSubview(createSectionHeader("Crash Testing (will kill app!)"))
        
        let crashWarning = UILabel()
        crashWarning.text = "These buttons trigger REAL crashes. The crash report\nwill be sent as a device.crash OTel log on next launch."
        crashWarning.font = .systemFont(ofSize: 12)
        crashWarning.textColor = .secondaryLabel
        crashWarning.textAlignment = .center
        crashWarning.numberOfLines = 0
        stackView.addArrangedSubview(crashWarning)
        
        stackView.addArrangedSubview(createButton(
            title: "NSException (Obj-C)",
            action: #selector(crashNSExceptionTapped),
            color: .systemRed
        ))
        stackView.addArrangedSubview(createButton(
            title: "Fatal Error (Swift)",
            action: #selector(crashFatalErrorTapped),
            color: .systemRed
        ))
        stackView.addArrangedSubview(createButton(
            title: "Array Out of Bounds",
            action: #selector(crashArrayBoundsTapped),
            color: .systemRed
        ))
        stackView.addArrangedSubview(createButton(
            title: "Force Unwrap nil",
            action: #selector(crashForceUnwrapTapped),
            color: .systemRed
        ))
        stackView.addArrangedSubview(createButton(
            title: "Stack Overflow",
            action: #selector(crashStackOverflowTapped),
            color: .systemRed
        ))
        stackView.addArrangedSubview(createButton(
            title: "SIGABRT (abort())",
            action: #selector(crashAbortTapped),
            color: .systemRed
        ))
        stackView.addArrangedSubview(createButton(
            title: "Null Pointer Dereference (SIGSEGV)",
            action: #selector(crashNullPointerTapped),
            color: .systemRed
        ))
        stackView.addArrangedSubview(createButton(
            title: "Crash on Background Thread",
            action: #selector(crashBackgroundThreadTapped),
            color: .systemRed
        ))
        stackView.addArrangedSubview(createButton(
            title: "Crash on Named Thread",
            action: #selector(crashNamedThreadTapped),
            color: .systemRed
        ))
        
        stackView.addArrangedSubview(createSeparator())
        
        // ── Interaction Testing ──
        stackView.addArrangedSubview(createSectionHeader("Interaction Testing"))
        
        let event1Button = createButton(
            title: "Trigger Event1",
            action: #selector(event1Tapped),
            color: .systemGreen
        )
        stackView.addArrangedSubview(event1Button)
        
        let event2Button = createButton(
            title: "Trigger Event2",
            action: #selector(event2Tapped),
            color: .systemOrange
        )
        stackView.addArrangedSubview(event2Button)
        
        stackView.addArrangedSubview(createSeparator())
        
        // Status Label
        let statusLabel = UILabel()
        statusLabel.text = "SDK Status: Initialized"
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .systemGreen
        statusLabel.textAlignment = .center
        stackView.addArrangedSubview(statusLabel)
    }
    
    // MARK: - UI Helpers
    
    private func createButton(title: String, action: Selector, color: UIColor = .systemBlue) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
    
    private func createSectionHeader(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textAlignment = .center
        return label
    }
    
    private func createSeparator() -> UIView {
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }
    
    // MARK: - Telemetry Testing
    
    @objc private func trackEventTapped() {
        print("━━━ trackEventTapped ━━━")
        let timestamp = Date().timeIntervalSince1970 * 1000
        PulseKit.shared.trackEvent(
            name: "tract_custom_event",
            observedTimeStampInMs: timestamp,
            params: [
                "button_name": AttributeValue.string("track_event"),
                "bool_attr": AttributeValue.bool(true),
                "int_attr": AttributeValue.int(123),
            ]
        )
        print("  Event: tract_custom_event")
        print("  Params: button_name=track_event, bool_attr=true, int_attr=123")
        showAlert(title: "Event Tracked", message: "Custom event 'button_clicked' has been tracked")
    }
    
    @objc private func trackNonFatalTapped() {
        print("━━━ trackNonFatalTapped ━━━")
        
        do {
            let invalidJSON = "{ invalid json }"
            let data = invalidJSON.data(using: .utf8)!
            _ = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            PulseKit.shared.trackNonFatal(
                error: error,
                observedTimeStampInMs: timestamp,
                params: [
                    "error_source": AttributeValue.string("json_parsing"),
                    "screen": AttributeValue.string("main")
                ]
            )
            print("  Error: \(error.localizedDescription)")
            print("  Type: \(type(of: error))")
            showAlert(title: "Non-Fatal Tracked", message: "Non-fatal error caught and tracked")
        }
    }
    
    @objc private func trackSpanTapped() {
        print("━━━ trackSpanTapped ━━━")
        let result = PulseKit.shared.trackSpan(
            name: "track_span",
            params: [
                "action": AttributeValue.string("track_span"),
                "method": AttributeValue.string("closure_based")
            ]
        ) {
            Thread.sleep(forTimeInterval: 0.5)
            return "Span completed"
        }
        print("  Span: track_span (closure)")
        print("  Result: \(result)")
        showAlert(title: "Span Tracked", message: "Span completed: \(result)")
    }
    
    @objc private func startSpanTapped() {
        print("━━━ startSpanTapped ━━━")
        let span = PulseKit.shared.startSpan(
            name: "manual_created_span",
            params: [
                "action": AttributeValue.string("start_span_1"),
                "method": AttributeValue.string("manual")
            ]
        )
        print("  Span started: manual_created_span")
        print("  SpanContext: traceId=\(span.context.traceId), spanId=\(span.context.spanId)")
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            span.end()
            print("  Span ended: manual_created_span")
            DispatchQueue.main.async {
                self.showAlert(title: "Span Ended", message: "Manual span has been completed")
            }
        }
        
        showAlert(title: "Span Started", message: "Manual span has been started and will end in 1 second")
    }
    
    @objc private func networkRequestTapped() {
        print("━━━ networkRequestTapped ━━━")
        guard let url = URL(string: "https://httpbin.org/get") else { return }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("  Network error: \(error.localizedDescription)")
                    self.showAlert(title: "Network Error", message: error.localizedDescription)
                } else if let httpResponse = response as? HTTPURLResponse {
                    print("  HTTP \(httpResponse.statusCode)")
                    if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                        self.showAlert(title: "Network Success", message: "Status: \(httpResponse.statusCode)")
                    } else {
                        self.showAlert(title: "HTTP Error", message: "Status: \(httpResponse.statusCode)")
                    }
                }
            }
        }
        task.resume()
    }
    
    // MARK: - OTel Direct API Testing
    
    @objc private func emitOtelLogTapped() {
        print("━━━ emitOtelLogTapped ━━━")
        guard let otel = PulseKit.shared.getOtelOrNull() else {
            print("  ERROR: OTel not initialized")
            return
        }
        
        let logger = otel.loggerProvider.get(instrumentationScopeName: "com.pulse.example.logs")
        
        let severities: [(Severity, String)] = [
            (.trace, "TRACE"), (.debug, "DEBUG"), (.info, "INFO"),
            (.warn, "WARN"), (.error, "ERROR"), (.fatal, "FATAL")
        ]
        
        for (severity, name) in severities {
            let thread = Thread.current
            let threadId = "\(pthread_mach_thread_np(pthread_self()))"
            let threadName = thread.name ?? (Thread.isMainThread ? "main" : "unknown")
            
            logger.logRecordBuilder()
                .setSeverity(severity)
                .setBody(.string("Test log at \(name) severity"))
                .setEventName("test.log.\(name.lowercased())")
                .setAttributes([
                    "log.severity": .string(name),
                    "thread.id": .string(threadId),
                    "thread.name": .string(threadName),
                    "test.timestamp": .string(ISO8601DateFormatter().string(from: Date()))
                ])
                .emit()
            
            print("  [\(name)] thread.id=\(threadId) thread.name=\(threadName)")
        }
        
        showAlert(title: "OTel Logs Emitted", message: "6 log records emitted (TRACE through FATAL)")
    }
    
    @objc private func spanWithEventsTapped() {
        print("━━━ spanWithEventsTapped ━━━")
        guard let otel = PulseKit.shared.getOtelOrNull() else {
            print("  ERROR: OTel not initialized")
            return
        }
        
        let tracer = otel.tracerProvider.get(
            instrumentationName: "com.pulse.example.traces",
            instrumentationVersion: "1.0.0"
        )
        
        let span = tracer.spanBuilder(spanName: "example.operation")
            .setSpanKind(spanKind: .client)
            .setAttribute(key: "http.method", value: "GET")
            .setAttribute(key: "http.url", value: "https://api.example.com/data")
            .setAttribute(key: "custom.user_id", value: "user-12345")
            .startSpan()
        
        print("  Span started: example.operation")
        print("  traceId: \(span.context.traceId)")
        print("  spanId: \(span.context.spanId)")
        print("  kind: CLIENT")
        
        span.addEvent(name: "request.started", attributes: [
            "http.request_content_length": .int(0)
        ])
        print("  Event added: request.started")
        
        Thread.sleep(forTimeInterval: 0.2)
        
        span.addEvent(name: "response.received", attributes: [
            "http.status_code": .int(200),
            "http.response_content_length": .int(4096)
        ])
        print("  Event added: response.received")
        
        span.setAttribute(key: "http.status_code", value: 200)
        span.end()
        print("  Span ended: example.operation")
        
        showAlert(title: "Span with Events", message: "Span 'example.operation' with 2 events emitted")
    }
    
    @objc private func nestedSpansTapped() {
        print("━━━ nestedSpansTapped ━━━")
        guard let otel = PulseKit.shared.getOtelOrNull() else {
            print("  ERROR: OTel not initialized")
            return
        }
        
        let tracer = otel.tracerProvider.get(
            instrumentationName: "com.pulse.example.traces"
        )
        
        let parentSpan = tracer.spanBuilder(spanName: "parent.operation")
            .setSpanKind(spanKind: .internal)
            .setAttribute(key: "operation.type", value: "batch")
            .startSpan()
        
        print("  Parent span: traceId=\(parentSpan.context.traceId) spanId=\(parentSpan.context.spanId)")
        
        let childSpan1 = tracer.spanBuilder(spanName: "child.db_query")
            .setParent(parentSpan)
            .setSpanKind(spanKind: .client)
            .setAttribute(key: "db.system", value: "sqlite")
            .setAttribute(key: "db.statement", value: "SELECT * FROM users")
            .startSpan()
        
        print("  Child span 1: spanId=\(childSpan1.context.spanId) parent=\(parentSpan.context.spanId)")
        Thread.sleep(forTimeInterval: 0.1)
        childSpan1.end()
        print("  Child span 1 ended: child.db_query")
        
        let childSpan2 = tracer.spanBuilder(spanName: "child.cache_write")
            .setParent(parentSpan)
            .setSpanKind(spanKind: .internal)
            .setAttribute(key: "cache.key", value: "users_list")
            .startSpan()
        
        print("  Child span 2: spanId=\(childSpan2.context.spanId) parent=\(parentSpan.context.spanId)")
        Thread.sleep(forTimeInterval: 0.05)
        childSpan2.end()
        print("  Child span 2 ended: child.cache_write")
        
        parentSpan.end()
        print("  Parent span ended: parent.operation")
        
        showAlert(title: "Nested Spans", message: "Parent + 2 child spans emitted (same traceId)")
    }
    
    @objc private func logWithThreadInfoTapped() {
        print("━━━ logWithThreadInfoTapped ━━━")
        guard let otel = PulseKit.shared.getOtelOrNull() else {
            print("  ERROR: OTel not initialized")
            return
        }
        
        let logger = otel.loggerProvider.get(instrumentationScopeName: "com.pulse.example.threads")
        
        func emitFromThread(label: String) {
            let thread = Thread.current
            let threadId = "\(pthread_mach_thread_np(pthread_self()))"
            let threadName = thread.name ?? (Thread.isMainThread ? "main" : label)
            
            logger.logRecordBuilder()
                .setSeverity(.info)
                .setBody(.string("Log from \(label)"))
                .setEventName("test.thread_log")
                .setAttributes([
                    "thread.id": .string(threadId),
                    "thread.name": .string(threadName),
                    "thread.is_main": .bool(Thread.isMainThread),
                    "thread.label": .string(label),
                    "thread.priority": .double(thread.threadPriority)
                ])
                .emit()
            
            print("  [\(label)] thread.id=\(threadId) thread.name=\(threadName) isMain=\(Thread.isMainThread)")
        }
        
        emitFromThread(label: "main-thread")
        
        DispatchQueue.global(qos: .userInitiated).async {
            emitFromThread(label: "global-userInitiated")
        }
        
        DispatchQueue.global(qos: .background).async {
            emitFromThread(label: "global-background")
        }
        
        let customQueue = DispatchQueue(label: "com.pulse.example.custom-queue")
        customQueue.async {
            emitFromThread(label: "custom-queue")
        }
        
        let namedThread = Thread {
            Thread.current.name = "PulseTestWorker"
            emitFromThread(label: "named-thread")
        }
        namedThread.name = "PulseTestWorker"
        namedThread.start()
        
        showAlert(title: "Thread Logs", message: "5 logs emitted from different threads (check console)")
    }
    
    // MARK: - Crash Testing
    
    @objc private func crashNSExceptionTapped() {
        confirmCrash(type: "NSException") {
            NSException(
                name: NSExceptionName("TestCrashException"),
                reason: "Test Obj-C exception from Pulse iOS SDK",
                userInfo: nil
            ).raise()
        }
    }
    
    @objc private func crashFatalErrorTapped() {
        confirmCrash(type: "Swift fatalError") {
            fatalError("Test fatal error from Pulse iOS SDK")
        }
    }
    
    @objc private func crashArrayBoundsTapped() {
        confirmCrash(type: "Array out of bounds") {
            let array = [1, 2, 3]
            let _ = array[10]
        }
    }
    
    @objc private func crashForceUnwrapTapped() {
        confirmCrash(type: "Force unwrap nil") {
            let value: String? = nil
            let _ = value!
        }
    }
    
    @objc private func crashStackOverflowTapped() {
        confirmCrash(type: "Stack overflow") {
            self.infiniteRecursion()
        }
    }
    
    @objc private func crashAbortTapped() {
        confirmCrash(type: "SIGABRT (abort)") {
            abort()
        }
    }
    
    @objc private func crashNullPointerTapped() {
        confirmCrash(type: "Null pointer (SIGSEGV)") {
            let ptr = UnsafeMutablePointer<Int>(bitPattern: 0)!
            ptr.pointee = 42
        }
    }
    
    @objc private func crashBackgroundThreadTapped() {
        confirmCrash(type: "Background thread crash") {
            DispatchQueue.global(qos: .background).async {
                NSException(
                    name: NSExceptionName("BackgroundCrashException"),
                    reason: "Test crash on background thread",
                    userInfo: nil
                ).raise()
            }
        }
    }
    
    @objc private func crashNamedThreadTapped() {
        confirmCrash(type: "Named thread crash") {
            let thread = Thread {
                NSException(
                    name: NSExceptionName("NamedThreadCrashException"),
                    reason: "Test crash on named thread 'PulseCrashTestThread'",
                    userInfo: nil
                ).raise()
            }
            thread.name = "PulseCrashTestThread"
            thread.start()
        }
    }
    
    // MARK: - Interaction Testing
    
    @objc private func event1Tapped() {
        print("━━━ event1Tapped ━━━")
        let timestamp = Date().timeIntervalSince1970 * 1000
        PulseKit.shared.trackEvent(
            name: "event1",
            observedTimeStampInMs: timestamp,
            params: [
                "source": AttributeValue.string("interaction_test"),
                "button": AttributeValue.string("event1_button")
            ]
        )
        showAlert(title: "Event1 Triggered", message: "Event 'event1' tracked. Trigger 'event2' to complete the interaction sequence.")
    }
    
    @objc private func event2Tapped() {
        print("━━━ event2Tapped ━━━")
        let timestamp = Date().timeIntervalSince1970 * 1000
        PulseKit.shared.trackEvent(
            name: "event2",
            observedTimeStampInMs: timestamp,
            params: [
                "source": AttributeValue.string("interaction_test"),
                "button": AttributeValue.string("event2_button")
            ]
        )
        showAlert(title: "Event2 Triggered", message: "Event 'event2' tracked. If 'event1' was triggered first, the interaction sequence should be complete!")
    }
    
    // MARK: - Helpers
    
    private func confirmCrash(type: String, action: @escaping () -> Void) {
        let alert = UIAlertController(
            title: "Trigger \(type)?",
            message: "This will crash the app. On next launch the crash report will be emitted as a device.crash log event.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Crash", style: .destructive) { _ in
            action()
        })
        present(alert, animated: true)
    }
    
    private func infiniteRecursion() {
        infiniteRecursion()
    }
    
    private func showAlert(title: String, message: String) {
        print("  -> \(title): \(message)")
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
