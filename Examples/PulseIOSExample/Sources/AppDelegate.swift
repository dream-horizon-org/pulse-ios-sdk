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
        
        PulseKit.shared.initialize(
            endpointBaseUrl: "http://127.0.0.1:4318",
            tenantId: "your-tenant-id",
            endpointHeaders: nil,
            globalAttributes: globalAttributes
        )
        
        // Create window and root view controller
        window = UIWindow(frame: UIScreen.main.bounds)
        let mainViewController = MainViewController()
        window?.rootViewController = UINavigationController(rootViewController: mainViewController)
        window?.makeKeyAndVisible()
        return true
    }
}


