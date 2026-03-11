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
                // Enable Session Replay with default configuration
                config.sessionReplay { replayConfig in
                    replayConfig.enabled(true)
                    replayConfig.configure { config in
                        // Only set the endpoint - all other settings use defaults from SessionReplayConfig
                        // Defaults: captureIntervalMs=1000, compressionQuality=0.3, maskAllTextInputs=true,
                        // maskAllImages=true, screenshotScale=1.0, flushIntervalSeconds=60, flushAt=10, maxBatchSize=50
                        config.replayEndpointBaseUrl = "http://127.0.0.1:3400"
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


