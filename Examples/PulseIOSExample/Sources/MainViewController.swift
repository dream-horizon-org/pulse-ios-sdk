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
        
        // Track Event Button
        let trackEventButton = createButton(
            title: "Track Custom Event",
            action: #selector(trackEventTapped)
        )
        stackView.addArrangedSubview(trackEventButton)
        
        // Track Non-Fatal Button
        let trackNonFatalButton = createButton(
            title: "Track Non-Fatal Error",
            action: #selector(trackNonFatalTapped)
        )
        stackView.addArrangedSubview(trackNonFatalButton)
        
        // Track Span Button
        let trackSpanButton = createButton(
            title: "Track Span (Closure)",
            action: #selector(trackSpanTapped)
        )
        stackView.addArrangedSubview(trackSpanButton)
        
        // Start Span Button
        let startSpanButton = createButton(
            title: "Start Span (Manual)",
            action: #selector(startSpanTapped)
        )
        stackView.addArrangedSubview(startSpanButton)
        
        // Network Request Button
        let networkButton = createButton(
            title: "Make Network Request",
            action: #selector(networkRequestTapped)
        )
        stackView.addArrangedSubview(networkButton)
        
        stackView.addArrangedSubview(createSeparator())
        
        // Interaction Testing Section
        let interactionHeaderLabel = UILabel()
        interactionHeaderLabel.text = "Interaction Testing"
        interactionHeaderLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        interactionHeaderLabel.textAlignment = .center
        stackView.addArrangedSubview(interactionHeaderLabel)
        
        // Event1 Button
        let event1Button = createButton(
            title: "Trigger Event1",
            action: #selector(event1Tapped)
        )
        event1Button.backgroundColor = .systemGreen
        stackView.addArrangedSubview(event1Button)
        
        // Event2 Button
        let event2Button = createButton(
            title: "Trigger Event2",
            action: #selector(event2Tapped)
        )
        event2Button.backgroundColor = .systemOrange
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
    
    private func createButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
    
    private func createSeparator() -> UIView {
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }
    
    @objc private func trackEventTapped() {
        print("trackEventTapped pressed")
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
        showAlert(title: "Event Tracked", message: "Custom event 'button_clicked' has been tracked")
    }
    
    @objc private func trackNonFatalTapped() {
        print("trackNonFatalTapped pressed")
        
        do {
            // Simulate an operation that throws an error
            let invalidJSON = "{ invalid json }"
            let data = invalidJSON.data(using: .utf8)!
            _ = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            // Track the caught error as a non-fatal error
            let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            PulseKit.shared.trackNonFatal(
                error: error,
                observedTimeStampInMs: timestamp,
                params: [
                    "error_source": AttributeValue.string("json_parsing"),
                    "screen": AttributeValue.string("main")
                ]
            )
            showAlert(title: "Non-Fatal Tracked", message: "Non-fatal error caught and tracked")
        }
    }
    
    @objc private func trackSpanTapped() {
        let result = PulseKit.shared.trackSpan(
            name: "track_span",
            params: [
                "action": AttributeValue.string("track_span"),
                "method": AttributeValue.string("closure_based")
            ]
        ) {
            // Simulate some work
            Thread.sleep(forTimeInterval: 0.5)
            return "Span completed"
        }
        showAlert(title: "Span Tracked", message: "Span completed: \(result)")
    }
    
    @objc private func startSpanTapped() {
        print("startSpanTapped")
        let span = PulseKit.shared.startSpan(
            name: "manual_created_span",
            params: [
                "action": AttributeValue.string("start_span_1"),
                "method": AttributeValue.string("manual")
            ]
        )
        span.end()
        
        // Simulate some work
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            span.end()
            print("startSpanTapped ended")
            DispatchQueue.main.async {
                self.showAlert(title: "Span Ended", message: "Manual span has been completed")
            }
        }
        
        showAlert(title: "Span Started", message: "Manual span has been started and will end in 1 second")
    }
    
    @objc private func networkRequestTapped() {
        guard let url = URL(string: "https://httpbin.org/get") else { return }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showAlert(title: "Network Error", message: error.localizedDescription)
                } else if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                        self.showAlert(title: "Network Success", message: "Request completed successfully (Status: \(httpResponse.statusCode))")
                    } else {
                        self.showAlert(title: "HTTP Error", message: "Request completed with error status: \(httpResponse.statusCode)")
                    }
                } else {
                    self.showAlert(title: "Network Success", message: "Request completed successfully")
                }
            }
        }
        task.resume()
    }
    
    @objc private func event1Tapped() {
        print("event1Tapped - Triggering event1")
        let timestamp = Date().timeIntervalSince1970 * 1000
        PulseKit.shared.trackEvent(
            name: "event1",
            observedTimeStampInMs: timestamp,
            params: [
                "source": AttributeValue.string("interaction_test"),
                "button": AttributeValue.string("event1_button")
            ]
        )
        showAlert(title: "Event1 Triggered", message: "Event 'event1' has been tracked. Trigger 'event2' to complete the interaction sequence.")
    }
    
    @objc private func event2Tapped() {
        print("event2Tapped - Triggering event2")
        let timestamp = Date().timeIntervalSince1970 * 1000
        PulseKit.shared.trackEvent(
            name: "event2",
            observedTimeStampInMs: timestamp,
            params: [
                "source": AttributeValue.string("interaction_test"),
                "button": AttributeValue.string("event2_button")
            ]
        )
        showAlert(title: "Event2 Triggered", message: "Event 'event2' has been tracked. If 'event1' was triggered first, the interaction sequence should be complete!")
    }
    
    private func showAlert(title: String, message: String) {
        print(title)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

