import Foundation
import OpenTelemetryApi

public enum PulseAttributes {
    public static let pulseType = "pulse.type"
    public static let pulseName = "pulse.name"
    public static let pulseSpanId = "pulse.span.id"
    public static let screenName = "screen.name"
    public static let userId = "user.id"
    public static let pulseUserPrefix = "pulse.user"
    public static let startType = "start.type"
    
    public static let exceptionMessage = "exception.message"
    public static let exceptionType = "exception.type"
    public static let exceptionStacktrace = "exception.stacktrace"
    
    public static func pulseUserParameter(_ key: String) -> String {
        return "\(pulseUserPrefix).\(key)"
    }

    public enum PulseTypeValues {
        // Custom events
        public static let customEvent = "custom_event"
        public static let nonFatal = "non_fatal"
        
        // Span types
        public static let network = "network"
        public static let screenLoad = "screen_load"
        public static let appStart = "app_start"
        public static let screenSession = "screen_session"
        
        // Log types
        public static let crash = "crash"
        public static let anr = "anr"
        public static let frozen = "frozen"
        public static let slow = "slow"
        public static let touch = "touch"
        public static let networkChange = "network_change"
    }
}
