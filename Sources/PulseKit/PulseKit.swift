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
    internal var _userProperties: [String: AttributeValue] = [:]
    internal var _globalAttributes: [String: AttributeValue]? = nil
    internal var _configuration: PulseKitConfiguration = PulseKitConfiguration()

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
        globalAttributes: [String: AttributeValue]? = nil,
        configuration: ((inout PulseKitConfiguration) -> Void)? = nil,
        instrumentations: ((inout InstrumentationConfiguration) -> Void)? = nil
    ) {
        initializationQueue.sync {
            guard !_isInitialized else {
                return
            }

            _globalAttributes = globalAttributes
            // Apply user configured settings
            var pulseKitConfig = PulseKitConfiguration()
            configuration?(&pulseKitConfig)
            _configuration = pulseKitConfig
            
            var config = InstrumentationConfiguration()
            instrumentations?(&config)

            let resource = buildResource()

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
            
            #if os(iOS) || os(tvOS)
            if _configuration.includeScreenAttributes {
                UIViewControllerSwizzler.swizzle()
            }
            #endif

            self.openTelemetry = openTelemetry
            _isInitialized = true
        }
    }

    // MARK: - Private Helper Methods

    private func buildResource() -> Resource {
        return DefaultResources().get()
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
        var spanProcessors: [SpanProcessor] = []
        var logProcessor = baseLogProcessor
        
        if _configuration.includeGlobalAttributes {
            let globalAttributesSpanProcessor = GlobalAttributesSpanProcessor(pulseKit: self)
            let globalAttributesLogProcessor = GlobalAttributesLogRecordProcessor(
                pulseKit: self,
                nextProcessor: logProcessor
            )
            spanProcessors.append(globalAttributesSpanProcessor)
            logProcessor = globalAttributesLogProcessor
        }
        
        if _configuration.includeScreenAttributes {
            let screenAttributesSpanProcessor = ScreenAttributesSpanProcessor()
            let screenAttributesLogProcessor = ScreenAttributesLogRecordProcessor(nextProcessor: logProcessor)
            spanProcessors.append(screenAttributesSpanProcessor)
            logProcessor = screenAttributesLogProcessor
        }
        
        if _configuration.includeNetworkAttributes {
            let networkAttributesSpanProcessor = NetworkAttributesSpanProcessor()
            let networkAttributesLogProcessor = NetworkAttributesLogRecordProcessor(nextProcessor: logProcessor)
            spanProcessors.append(networkAttributesSpanProcessor)
            logProcessor = networkAttributesLogProcessor
        }
        
        let pulseSpanProcessor = pulseSignalProcessor.createSpanProcessor()
        spanProcessors.append(pulseSpanProcessor)
        spanProcessors.append(baseSpanProcessor)
        
        let pulseLogProcessor = pulseSignalProcessor.createLogProcessor(nextProcessor: logProcessor)
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
        params: [String: AttributeValue] = [:]
    ) {
        guard isInitialized else { return }

        var attributes: [String: AttributeValue] = [
            PulseAttributes.pulseType: AttributeValue.string(PulseAttributes.PulseTypeValues.customEvent)
        ]

        attributes.merge(params) { _, new in new }

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
        params: [String: AttributeValue] = [:]
    ) {
        guard isInitialized else { return }

        var attributes: [String: AttributeValue] = [
            PulseAttributes.pulseType: AttributeValue.string(PulseAttributes.PulseTypeValues.nonFatal)
        ]

        attributes.merge(params) { _, new in new }

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
        params: [String: AttributeValue] = [:]
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

        attributes.merge(params) { _, new in new }

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
        params: [String: AttributeValue] = [:],
        action: () throws -> T
    ) rethrows -> T {
        guard isInitialized else {
            return try action()
        }

        let span = tracer.spanBuilder(spanName: name).startSpan()
        defer { span.end() }

        span.setAttributes(params)

        return try action()
    }

    public func startSpan(
        name: String,
        params: [String: AttributeValue] = [:]
    ) -> Span {
        let span = tracer.spanBuilder(spanName: name).startSpan()
        span.setAttributes(params)

        return span
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
    
    public func setUserProperty(name: String, value: AttributeValue?) {
        userPropertiesQueue.sync {
            if let value = value {
                _userProperties[name] = value
            } else {
                _userProperties.removeValue(forKey: name)
            }
        }
    }
    
    public func setUserProperties(_ properties: [String: AttributeValue]) {
        userPropertiesQueue.sync {
            for (key, value) in properties {
                _userProperties[key] = value
            }
        }
    }
    
    public func setUserProperties(_ builderAction: (inout [String: AttributeValue]) -> Void) {
        var properties: [String: AttributeValue] = [:]
        builderAction(&properties)
        setUserProperties(properties)
    }
    
}
