import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import InteractionInstrumentation
import OpenTelemetryProtocolExporterHttp
import ResourceExtension
import Sessions
import URLSessionInstrumentation
import NetworkStatus

public class PulseKit {
    public static let shared = PulseKit()

    // Thread-safe initialization
    private let initializationQueue = DispatchQueue(label: "com.pulse.ios.sdk.initialization")
    private var _isInitialized = false
    private var isInitialized: Bool {
        initializationQueue.sync { _isInitialized }
    }

    private var openTelemetry: OpenTelemetry?
    
    internal let userPropertiesQueue = DispatchQueue(label: "com.pulse.ios.sdk.userProperties")
    internal var _userId: String?
    internal var _userProperties: [String: Any] = [:]

    private lazy var logger: Logger = {
        guard let otel = openTelemetry else {
            fatalError("Pulse SDK is not initialized. Please call PulseKit.initialize")
        }
        return otel.loggerProvider.get(instrumentationScopeName: "com.pulse.ios.sdk")
    }()

    private lazy var tracer: Tracer = {
        guard let otel = openTelemetry else {
            fatalError("Pulse SDK is not initialized. Please call PulseKit.initialize")
        }
        return otel.tracerProvider.get(instrumentationName: "com.pulse.ios.sdk", instrumentationVersion: "1.0.0")
    }()

    private init() {}

    public func initialize(
        endpointBaseUrl: String,
        endpointHeaders: [String: String]? = nil,
        globalAttributes: [String: String]? = nil,
        instrumentations: ((inout InstrumentationConfiguration) -> Void)? = nil
    ) {
        initializationQueue.sync {
            guard !_isInitialized else {
                return
            }

            // Apply user configured instrumentations
            var config = InstrumentationConfiguration()
            instrumentations?(&config)

            // Build resource
            let resource = buildResource(globalAttributes: globalAttributes)

            // Build OpenTelemetry SDK
            let (tracerProvider, loggerProvider, openTelemetry) = buildOpenTelemetrySDK(
                endpointBaseUrl: endpointBaseUrl,
                endpointHeaders: endpointHeaders,
                resource: resource,
                config: config
            )

            // Install instrumentations
            let installationContext = InstallationContext(
                tracerProvider: tracerProvider,
                loggerProvider: loggerProvider,
                openTelemetry: openTelemetry,
                endpointBaseUrl: endpointBaseUrl
            )
            installInstrumentations(config: config, ctx: installationContext)

            self.openTelemetry = openTelemetry
            _isInitialized = true
        }
    }

    // MARK: - Private Helper Methods

    private func buildResource(globalAttributes: [String: String]?) -> Resource {
        let resource = DefaultResources().get()
        var resourceAttributes = resource.attributes
        
        userPropertiesQueue.sync {
            if !_userProperties.isEmpty {
                for (key, value) in _userProperties {
                    let attributeKey = "pulse.user.\(key)"
                    resourceAttributes[attributeKey] = AttributeValue.string(String(describing: value))
                }
            }
            
            if let currentUserId = _userId {
                resourceAttributes["user.id"] = AttributeValue.string(currentUserId)
            }
        }
        
        if let globalAttributes = globalAttributes {
            for (key, value) in globalAttributes {
                resourceAttributes[key] = AttributeValue.string(value)
            }
        }
        return Resource(attributes: resourceAttributes)
    }

    private func buildOpenTelemetrySDK(
        endpointBaseUrl: String,
        endpointHeaders: [String: String]?,
        resource: Resource,
        config: InstrumentationConfiguration
    ) -> (tracerProvider: TracerProvider, loggerProvider: LoggerProvider, openTelemetry: OpenTelemetry) {
        // Convert headers to exporter format [(String, String)]?
        let envVarHeaders: [(String, String)]? = endpointHeaders?.map { ($0.key, $0.value) }

        // Build exporters
        let tracesEndpoint = URL(string: "\(endpointBaseUrl)/v1/traces")!
        let logsEndpoint = URL(string: "\(endpointBaseUrl)/v1/logs")!
        let otlpHttpTraceExporter = OtlpHttpTraceExporter(endpoint: tracesEndpoint, envVarHeaders: envVarHeaders)
        let otlpHttpLogExporter = OtlpHttpLogExporter(endpoint: logsEndpoint, envVarHeaders: envVarHeaders)
        let spanExporter = otlpHttpTraceExporter

        // Build base processors
        let spanProcessor = SimpleSpanProcessor(spanExporter: spanExporter)
        let baseLogProcessor = SimpleLogRecordProcessor(logRecordExporter: otlpHttpLogExporter)

        // Build processors (including Sessions and Interaction if enabled)
        let (spanProcessors, logProcessors) = buildProcessors(
            baseSpanProcessor: spanProcessor,
            baseLogProcessor: baseLogProcessor,
            config: config
        )

        // Build providers
        var tracerProviderBuilder = TracerProviderBuilder()
            .with(resource: resource)

        for processor in spanProcessors {
            tracerProviderBuilder = tracerProviderBuilder.add(spanProcessor: processor)
        }

        let tracerProvider = tracerProviderBuilder.build()

        let loggerProvider = LoggerProviderBuilder()
            .with(resource: resource)
            .with(processors: logProcessors)
            .build()

        // Register providers
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

        let openTelemetry = OpenTelemetry.instance

        return (tracerProvider, loggerProvider, openTelemetry)
    }

    private func buildProcessors(
        baseSpanProcessor: SpanProcessor,
        baseLogProcessor: LogRecordProcessor,
        config: InstrumentationConfiguration
    ) -> (spanProcessors: [SpanProcessor], logProcessors: [LogRecordProcessor]) {
        let pulseSignalProcessor = PulseSignalProcessor()
        
        let globalAttributesSpanProcessor = GlobalAttributesSpanProcessor(pulseKit: self)
        let globalAttributesLogProcessor = GlobalAttributesLogRecordProcessor(
            pulseKit: self,
            nextProcessor: baseLogProcessor
        )
        
        let pulseSpanProcessor = pulseSignalProcessor.createSpanProcessor()
        var spanProcessors: [SpanProcessor] = [globalAttributesSpanProcessor, pulseSpanProcessor, baseSpanProcessor]
        
        let pulseLogProcessor = pulseSignalProcessor.createLogProcessor(nextProcessor: globalAttributesLogProcessor)
        var logProcessors: [LogRecordProcessor] = [pulseLogProcessor]

        if let sessionsProcessors = config.sessions.createProcessors(baseLogProcessor: pulseLogProcessor) {
            spanProcessors.append(sessionsProcessors.spanProcessor)
            logProcessors = [sessionsProcessors.logProcessor]
        }
        
        if config.interaction.enabled,
           let interactionLogProcessor = config.interaction.createLogProcessor(baseLogProcessor: logProcessors.last ?? pulseLogProcessor) {
            logProcessors = logProcessors.dropLast() + [interactionLogProcessor]
        }

        return (spanProcessors, logProcessors)
    }

    private func installInstrumentations(
        config: InstrumentationConfiguration,
        ctx: InstallationContext
    ) {
        for initializer in config.initializers {
            initializer.initialize(ctx: ctx)
        }
    }

    public func trackEvent(
        name: String,
        observedTimeStampInMs: Double,
        params: [String: Any?] = [:]
    ) {
        guard isInitialized else { return }

        var attributes: [String: AttributeValue] = [
            PulseAttributes.pulseType: AttributeValue.string(PulseAttributes.PulseTypeValues.customEvent)
        ]

        for (key, value) in params {
            attributes[key] = attributeValue(from: value)
        }

        let observedDate = Date(timeIntervalSince1970: observedTimeStampInMs / 1000.0)
        logger.logRecordBuilder()
            .setObservedTimestamp(observedDate)
            .setBody(AttributeValue.string(name))
            .setEventName("pulse.custom_event")
            .setAttributes(attributes)
            .emit()
    }

    public func trackNonFatal(
        name: String,
        observedTimeStampInMs: Int64,
        params: [String: Any?] = [:]
    ) {
        guard isInitialized else { return }

        var attributes: [String: AttributeValue] = [
            PulseAttributes.pulseType: AttributeValue.string(PulseAttributes.PulseTypeValues.nonFatal)
        ]

        for (key, value) in params {
            attributes[key] = attributeValue(from: value)
        }

        let observedDate = Date(timeIntervalSince1970: Double(observedTimeStampInMs) / 1000.0)
        logger.logRecordBuilder()
            .setObservedTimestamp(observedDate)
            .setBody(AttributeValue.string(name))
            .setEventName("pulse.custom_non_fatal")
            .setAttributes(attributes)
            .emit()
    }

    public func trackNonFatal(
        error: Error,
        observedTimeStampInMs: Int64,
        params: [String: Any?] = [:]
    ) {
        guard isInitialized else { return }

        var attributes: [String: AttributeValue] = [
            PulseAttributes.pulseType: AttributeValue.string(PulseAttributes.PulseTypeValues.nonFatal),
            "exception.message": AttributeValue.string(error.localizedDescription),
            "exception.type": AttributeValue.string(String(describing: type(of: error)))
        ]

        if let nsError = error as NSError? {
            attributes["exception.stacktrace"] = AttributeValue.string(nsError.description)
        }

        for (key, value) in params {
            attributes[key] = attributeValue(from: value)
        }

        let body = error.localizedDescription.isEmpty ? "Non fatal error of type \(String(describing: type(of: error)))" : error.localizedDescription

        let observedDate = Date(timeIntervalSince1970: Double(observedTimeStampInMs) / 1000.0)
        logger.logRecordBuilder()
            .setObservedTimestamp(observedDate)
            .setBody(AttributeValue.string(body))
            .setEventName("pulse.custom_non_fatal")
            .setAttributes(attributes)
            .emit()
    }

    public func trackSpan<T>(
        name: String,
        params: [String: Any?] = [:],
        action: () throws -> T
    ) rethrows -> T {
        guard isInitialized else {
            return try action()
        }

        let span = tracer.spanBuilder(spanName: name).startSpan()
        defer { span.end() }

        for (key, value) in params {
            if let attrValue = attributeValue(from: value) {
                span.setAttribute(key: key, value: attrValue)
            }
        }

        return try action()
    }

    public func startSpan(
        name: String,
        params: [String: Any?] = [:]
    ) -> Span {
        let span = tracer.spanBuilder(spanName: name).startSpan()
        for (key, value) in params {
            if let attrValue = attributeValue(from: value) {
                span.setAttribute(key: key, value: attrValue)
            }
        }

        return span
    }

    internal func attributeValue(from value: Any?) -> AttributeValue? {
        guard let value = value else { return nil }

        if let string = value as? String {
            return AttributeValue.string(string)
        } else if let int = value as? Int {
            return AttributeValue.int(int)
        } else if let int64 = value as? Int64 {
            return AttributeValue.int(Int(int64))
        } else if let double = value as? Double {
            return AttributeValue.double(double)
        } else if let bool = value as? Bool {
            return AttributeValue.bool(bool)
        } else {
            return AttributeValue.string(String(describing: value))
        }
    }

    public func getOpenTelemetry() -> OpenTelemetry? {
        return openTelemetry
    }
    
    public func getOtelOrNull() -> OpenTelemetry? {
        return openTelemetry
    }
    
    public func getOtelOrThrow() -> OpenTelemetry {
        guard let otel = openTelemetry else {
            fatalError("Pulse SDK is not initialized. Please call PulseKit.initialize")
        }
        return otel
    }

    public func isSDKInitialized() -> Bool {
        return isInitialized
    }
    
    // MARK: - User Properties
    
    /// Set the user ID for all telemetry data
    /// - Parameter id: The user ID (set to `nil` to clear)
    public func setUserId(_ id: String?) {
        userPropertiesQueue.sync {
            _userId = id
        }
    }
    
    public func setUserProperty(name: String, value: Any?) {
        userPropertiesQueue.sync {
            if let value = value {
                _userProperties[name] = value
            } else {
                _userProperties.removeValue(forKey: name)
            }
        }
    }
    
    public func setUserProperties(_ properties: [String: Any]) {
        userPropertiesQueue.sync {
            for (key, value) in properties {
                _userProperties[key] = value
            }
        }
    }
    
    public func setUserProperties(_ builderAction: (inout [String: Any]) -> Void) {
        var properties: [String: Any] = [:]
        builderAction(&properties)
        setUserProperties(properties)
    }
    
}
