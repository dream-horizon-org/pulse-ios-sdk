import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Crashes
import InteractionInstrumentation
import OpenTelemetryProtocolExporterHttp
import ResourceExtension
import Sessions
import URLSessionInstrumentation
#if canImport(Location)
import Location
#endif

// MARK: - SDK Constants
internal enum PulseKitConstants {
    static let instrumentationScopeName = "com.pulse.ios.sdk"
    static let instrumentationVersion = "1.0.0"
}

public class PulseKit {
    public static let shared = PulseKit()

    // Thread-safe initialization
    private let initializationQueue = DispatchQueue(label: "com.pulse.ios.sdk.initialization")
    private var _isInitialized = false
    private var _isShutdown = false

    private var isInitialized: Bool {
        initializationQueue.sync { _isInitialized }
    }

    public var isShutdown: Bool {
        initializationQueue.sync { _isShutdown }
    }

    /// `true` when the SDK is initialized **and** has not been shut down.
    /// Used to guard every public API entry point.
    private var isActive: Bool {
        initializationQueue.sync { _isInitialized && !_isShutdown }
    }

    private var openTelemetry: OpenTelemetry?
    private var batchSpanProcessor: BatchSpanProcessor?
    private var batchLogProcessor: BatchLogRecordProcessor?
    
    // User session emitter
    internal lazy var userSessionEmitter: PulseUserSessionEmitter = {
        PulseUserSessionEmitter(
            loggerProvider: { [weak self] in
                guard let self = self, let otel = self.openTelemetry else {
                    fatalError("Pulse SDK is not initialized")
                }
                return otel.loggerProvider.get(instrumentationScopeName: PulseKitConstants.instrumentationScopeName)
            }
        )
    }()
    
    internal lazy var installationIdManager: PulseInstallationIdManager = {
        PulseInstallationIdManager(
            loggerProvider: { [weak self] in
                guard let self = self, let otel = self.openTelemetry else {
                    fatalError("Pulse SDK is not initialized")
                }
                return otel.loggerProvider.get(instrumentationScopeName: PulseKitConstants.instrumentationScopeName)
            }
        )
    }()
    
    internal var _globalAttributes: [String: AttributeValue]? = nil
    internal var _configuration: PulseKitConfiguration = PulseKitConfiguration()

    private lazy var logger: Logger = {
        guard let otel = openTelemetry else {
            fatalError("Pulse SDK is not initialized. Please call PulseKit.initialize")
        }
        return otel.loggerProvider.get(instrumentationScopeName: PulseKitConstants.instrumentationScopeName)
    }()

    private lazy var tracer: Tracer = {
        guard let otel = openTelemetry else {
            fatalError("Pulse SDK is not initialized. Please call PulseKit.initialize")
        }
        return otel.tracerProvider.get(instrumentationName: PulseKitConstants.instrumentationScopeName, instrumentationVersion: PulseKitConstants.instrumentationVersion)
    }()

    private init() {}

    public func initialize(
        endpointBaseUrl: String,
        projectId: String,
        endpointHeaders: [String: String]? = nil,
        globalAttributes: [String: AttributeValue]? = nil,
        resource: ((inout [String: AttributeValue]) -> Void)? = nil,
        configuration: ((inout PulseKitConfiguration) -> Void)? = nil,
        instrumentations: ((inout InstrumentationConfiguration) -> Void)? = nil,
        tracerProviderCustomizer: ((TracerProviderBuilder) -> TracerProviderBuilder)? = nil,
        loggerProviderCustomizer: (([LogRecordProcessor]) -> [LogRecordProcessor])? = nil
    ) {
        initializationQueue.sync {
            guard !_isShutdown else { return }
            guard !_isInitialized else { return }

            _globalAttributes = globalAttributes
            var pulseKitConfig = PulseKitConfiguration()
            configuration?(&pulseKitConfig)
            _configuration = pulseKitConfig
            
            var config = InstrumentationConfiguration()
            instrumentations?(&config)

            let projectIdHeader = [PulseAttributes.projectIdHeaderKey: projectId]
            let endpointHeadersWithProjectID = (endpointHeaders ?? [:]).merging(projectIdHeader) { _, new in new }

            let resource = buildResource(projectId: projectId, resource: resource)

            let (tracerProvider, loggerProvider, openTelemetry) = buildOpenTelemetrySDK(
                endpointBaseUrl: endpointBaseUrl,
                endpointHeaders: endpointHeadersWithProjectID,
                resource: resource,
                config: config,
                tracerProviderCustomizer: tracerProviderCustomizer,
                loggerProviderCustomizer: loggerProviderCustomizer
            )

            let installationContext = InstallationContext(
                tracerProvider: tracerProvider,
                loggerProvider: loggerProvider,
                openTelemetry: openTelemetry,
                endpointBaseUrl: endpointBaseUrl,
                flushLogProcessor: { [weak self] in
                    self?.batchLogProcessor?.forceFlush()
                }
            )
            installInstrumentations(config: config, ctx: installationContext)
            
            #if os(iOS) || os(tvOS)
            if _configuration.includeScreenAttributes {
                AppStartupTimer.shared.start(
                    tracer: tracerProvider.get(
                        instrumentationName: PulseKitConstants.instrumentationScopeName,
                        instrumentationVersion: PulseKitConstants.instrumentationVersion
                    )
                )
                
                UIViewControllerSwizzler.swizzle()
            }
            #endif

            self.openTelemetry = openTelemetry
            _isInitialized = true
        }
    }

    // MARK: - Private Helper Methods

    private func buildResource(projectId: String, resource: ((inout [String: AttributeValue]) -> Void)?) -> Resource {
        let defaultResource = DefaultResources().get()
        
        var attributes = defaultResource.attributes
        
        attributes[ResourceAttributes.telemetrySdkName.rawValue] = AttributeValue.string(PulseAttributes.PulseSdkNames.iosSwift)
        attributes[PulseAttributes.projectId] = AttributeValue.string(projectId)
        
        if let resourceCustomizer = resource {
            resourceCustomizer(&attributes)
        }
        
        return Resource(attributes: attributes)
    }

    private func buildOpenTelemetrySDK(
        endpointBaseUrl: String,
        endpointHeaders: [String: String]?,
        resource: Resource,
        config: InstrumentationConfiguration,
        tracerProviderCustomizer: ((TracerProviderBuilder) -> TracerProviderBuilder)?,
        loggerProviderCustomizer: (([LogRecordProcessor]) -> [LogRecordProcessor])?
    ) -> (tracerProvider: TracerProvider, loggerProvider: LoggerProvider, openTelemetry: OpenTelemetry) {
        let envVarHeaders: [(String, String)]? = endpointHeaders?.map { ($0.key, $0.value) }

        let tracesEndpoint = URL(string: "\(endpointBaseUrl)/v1/traces")!
        let logsEndpoint = URL(string: "\(endpointBaseUrl)/v1/logs")!
        let otlpHttpTraceExporter = OtlpHttpTraceExporter(endpoint: tracesEndpoint, envVarHeaders: envVarHeaders)
        let otlpHttpLogExporter = OtlpHttpLogExporter(endpoint: logsEndpoint, envVarHeaders: envVarHeaders)
        let spanExporter = FilteringSpanExporter(delegate: otlpHttpTraceExporter)

        let (persistentSpanExporter, persistentLogExporter) = PersistenceUtils.createPersistentExporters(
            spanExporter: spanExporter,
            logExporter: otlpHttpLogExporter
        )

        let spanProcessor = BatchSpanProcessor(
            spanExporter: persistentSpanExporter,
            scheduleDelay: BatchProcessorDefaults.scheduleDelay,
            exportTimeout: BatchProcessorDefaults.exportTimeout,
            maxQueueSize: BatchProcessorDefaults.maxQueueSize,
            maxExportBatchSize: BatchProcessorDefaults.maxExportBatchSize
        )
        let baseLogProcessor = BatchLogRecordProcessor(
            logRecordExporter: persistentLogExporter,
            scheduleDelay: BatchProcessorDefaults.scheduleDelay,
            exportTimeout: BatchProcessorDefaults.exportTimeout,
            maxQueueSize: BatchProcessorDefaults.maxQueueSize,
            maxExportBatchSize: BatchProcessorDefaults.maxExportBatchSize
        )

        self.batchSpanProcessor = spanProcessor
        self.batchLogProcessor = baseLogProcessor

        let (spanProcessors, logProcessors) = buildProcessors(
            baseSpanProcessor: spanProcessor,
            baseLogProcessor: baseLogProcessor,
            config: config,
            loggerProviderCustomizer: loggerProviderCustomizer
        )

        var tracerProviderBuilder = TracerProviderBuilder()
            .with(resource: resource)

        for processor in spanProcessors {
            tracerProviderBuilder = tracerProviderBuilder.add(spanProcessor: processor)
        }
        
        if let customizer = tracerProviderCustomizer {
            tracerProviderBuilder = customizer(tracerProviderBuilder)
        }

        let tracerProvider = tracerProviderBuilder.build()

        let loggerProviderBuilder = LoggerProviderBuilder()
            .with(resource: resource)
            .with(processors: logProcessors)
        
        let loggerProvider = loggerProviderBuilder.build()

        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

        let openTelemetry = OpenTelemetry.instance

        return (tracerProvider, loggerProvider, openTelemetry)
    }

    private func buildProcessors(
        baseSpanProcessor: SpanProcessor,
        baseLogProcessor: LogRecordProcessor,
        config: InstrumentationConfiguration,
        loggerProviderCustomizer: (([LogRecordProcessor]) -> [LogRecordProcessor])?
    ) -> (spanProcessors: [SpanProcessor], logProcessors: [LogRecordProcessor]) {
        let pulseSignalProcessor = PulseSignalProcessor()
        var spanProcessors: [SpanProcessor] = []
        var logProcessor = baseLogProcessor

        // Apply customizer first, right after baseLogProcessor
        if let customizer = loggerProviderCustomizer {
            let modified = customizer([logProcessor])
            if let firstModified = modified.first {
                logProcessor = firstModified
            }
        }

        // Build SDK processor chain
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

        #if canImport(Location)
        if config.location.enabled {
            let locationAttributesSpanProcessor = LocationAttributesSpanAppender()
            let locationAttributesLogProcessor = LocationAttributesLogRecordProcessor(nextProcessor: logProcessor)
            spanProcessors.append(locationAttributesSpanProcessor)
            logProcessor = locationAttributesLogProcessor
        }
        #endif

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

    // MARK: - Shutdown

    /// Permanently shuts down the SDK. Cannot be re-initialized in this process.
    public func shutdown() {
        initializationQueue.sync {
            guard _isInitialized, !_isShutdown else { return }

            let defaults = UserDefaults.standard

            CrashInstrumentation.uninstall()
            InteractionInstrumentation.getInstance()?.uninstall()
            defaults.removeObject(forKey: "pulse_installation_id")
            defaults.removeObject(forKey: "user_id")
            #if canImport(Location)
            LocationInstrumentation.uninstall()
            defaults.removeObject(forKey: "location_cache")
            #endif

            #if os(iOS) || os(tvOS)
            UIViewControllerSwizzler.shutdown()
            #endif

            batchSpanProcessor?.forceFlush()
            batchLogProcessor?.forceFlush()
            batchSpanProcessor?.shutdown()
            _ = batchLogProcessor?.shutdown()
            PersistenceUtils.clearStorage()
            
            batchSpanProcessor = nil
            batchLogProcessor = nil
            openTelemetry = nil
            _globalAttributes = nil
            _isShutdown = true
        }
    }

    public func trackEvent(
        name: String,
        observedTimeStampInMs: Double,
        params: [String: AttributeValue] = [:]
    ) {
        guard isActive else { return }

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
        guard isActive else { return }

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
        guard isActive else { return }

        var attributes: [String: AttributeValue] = [
            PulseAttributes.pulseType: AttributeValue.string(PulseAttributes.PulseTypeValues.nonFatal),
            PulseAttributes.exceptionMessage: AttributeValue.string(error.localizedDescription),
            PulseAttributes.exceptionType: AttributeValue.string(String(describing: type(of: error)))
        ]

        if let nsError = error as NSError? {
            attributes[PulseAttributes.exceptionStacktrace] = AttributeValue.string(nsError.description)
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
        guard isActive else {
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
        guard isActive else {
            return OpenTelemetry.instance.tracerProvider
                .get(instrumentationName: PulseKitConstants.instrumentationScopeName)
                .spanBuilder(spanName: name).startSpan()
        }
        let span = tracer.spanBuilder(spanName: name).startSpan()
        span.setAttributes(params)
        return span
    }

    public func getOpenTelemetry() -> OpenTelemetry? {
        guard !isShutdown else { return nil }
        return openTelemetry
    }
    
    public func getOtelOrNull() -> OpenTelemetry? {
        guard !isShutdown else { return nil }
        return openTelemetry
    }
    
    public func getOtelOrThrow() -> OpenTelemetry {
        if isShutdown {
            fatalError("Pulse SDK has been shut down. No further API calls are allowed.")
        }
        guard let otel = openTelemetry else {
            fatalError("Pulse SDK is not initialized. Please call PulseKit.initialize")
        }
        return otel
    }

    public func isSDKInitialized() -> Bool {
        return isInitialized
    }
    
    public func setUserId(_ id: String?) {
        guard isActive else { return }
        userSessionEmitter.userId = id
    }
    
    public func setUserProperty(name: String, value: AttributeValue?) {
        guard isActive else { return }
        userSessionEmitter.setUserProperty(name: name, value: value)
    }
    
    public func setUserProperties(_ properties: [String: AttributeValue?]) {
        guard isActive else { return }
        userSessionEmitter.setUserProperties(properties)
    }

    public func setUserProperties(_ builderAction: (inout [String: AttributeValue?]) -> Void) {
        guard isActive else { return }
        var properties: [String: AttributeValue?] = [:]
        builderAction(&properties)
        setUserProperties(properties)
    }
}

// MARK: - Batch Processor Constants

internal enum BatchProcessorDefaults {
    static let scheduleDelay: TimeInterval = 5
    static let maxQueueSize: Int = 2048
    static let maxExportBatchSize: Int = 512
    static let exportTimeout: TimeInterval = 30
}

