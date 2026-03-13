import UIKit
import PulseKit
import OpenTelemetryApi

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let globalAttributes: [String: AttributeValue] = [
            "global.version": AttributeValue.string("1.0.0"),
            "global.environment": AttributeValue.string("development"),
            "global.build": AttributeValue.int(123),
            "global.is_debug": AttributeValue.bool(true),
            "global.version_code": AttributeValue.double(1.0),
            "global.features": AttributeValue.array(AttributeArray(values: [
                AttributeValue.string("feature1"),
                AttributeValue.string("feature2")
            ]))
        ]
        
        Pulse.shared.initialize(
            endpointBaseUrl: "http://127.0.0.1:4318",
            apiKey: "default",
            endpointHeaders: nil,
            globalAttributes: globalAttributes,
            instrumentations: { config in
                // Enable Session Replay
                config.sessionReplay { replayConfig in
                    replayConfig.enabled(true)
                    replayConfig.configure { localConfig in
                        localConfig.textAndInputPrivacy = .maskSensitiveInputs
                        localConfig.imagePrivacy = .maskAll
                        localConfig.captureIntervalMs = 1000
                        localConfig.screenshotScale = 1.0
                        
                        // Register custom classes for class-level overrides
                        localConfig.maskViewClasses = Set([
                            "PulseIOSExample.PrivateSecureView",
                            "PulseIOSExample.PrivateDataLabel",
                            "PulseIOSExample.PublicInfoView",
                            "PulseIOSExample.SafePublicLabel"
                        ])
                        localConfig.replayEndpointBaseUrl = "http://127.0.0.1:3400"
                    }
                }
            }
        )
        
        // Set user ID so the session capture service accepts the payload
        PulseKit.shared.setUserId("test-user-ios-simulator")
        
        // Create window and root view controller
        window = UIWindow(frame: UIScreen.main.bounds)
        let mainViewController = MainViewController()
        window?.rootViewController = UINavigationController(rootViewController: mainViewController)
        window?.makeKeyAndVisible()
        print("SDK Initialised")
        return true
    }
}
