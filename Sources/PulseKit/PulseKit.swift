import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
#if canImport(OpenTelemetryProtocolExporterHttp)
import OpenTelemetryProtocolExporterHttp
#endif
#if canImport(SessionReplay)
import SessionReplay
#endif

// MARK: - SDK Constants
internal enum PulseKitConstants {
    static let instrumentationScopeName = "com.pulse.ios.sdk"
    static let instrumentationVersion = "1.0.0"
}

public class Pulse {
    public static let shared = Pulse()

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
    private var instrumentationConfig: InstrumentationConfiguration?
    
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

    /// Config loaded from persistence at init; used for this launch. Nil when none persisted or decode failed.
    /// New config from API is persisted for next launch only (see LLD §2).
    private var _currentSdkConfig: PulseSdkConfig?
    private let configStorageQueue = DispatchQueue(label: "com.pulse.ios.sdk.sampling.config", qos: .utility)

    /// Current SDK config for this launch (from persistence at init). Nil if none available; then use Pulse.initialize defaults.
    internal var currentSdkConfig: PulseSdkConfig? {
        configStorageQueue.sync { _currentSdkConfig }
    }

    /// When false, trackEvent/trackNonFatal are no-ops. Set from getEnabledFeatures() when config present.
    private var _customEventsEnabled: Bool = true

    /// Keeps PulseSamplingSignalProcessors alive so SampledSpanExporter/SampledLogExporter weak parent ref stays valid.
    private var _samplingSignalProcessors: PulseSamplingSignalProcessors?

    private lazy var logger: Logger = {
        guard let otel = openTelemetry else {
            fatalError("Pulse SDK is not initialized. Please call Pulse.initialize")
        }
        return otel.loggerProvider.get(instrumentationScopeName: PulseKitConstants.instrumentationScopeName)
    }()

    private lazy var tracer: Tracer = {
        guard let otel = openTelemetry else {
            fatalError("Pulse SDK is not initialized. Please call Pulse.initialize")
        }
        return otel.tracerProvider.get(instrumentationName: PulseKitConstants.instrumentationScopeName, instrumentationVersion: PulseKitConstants.instrumentationVersion)
    }()

    private init() {}

    public func initialize(
        endpointBaseUrl: String,
        apiKey: String,
        configEndpointUrl: String? = nil,
        customEventCollectorUrl: String? = nil,
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
            guard !_isInitialized else {
                PulseLogger.log("Already initialized, skipping.")
                return
            }
            PulseLogger.log("Initializing...")

            _globalAttributes = globalAttributes
            var pulseKitConfig = PulseKitConfiguration()
            configuration?(&pulseKitConfig)
            _configuration = pulseKitConfig

            // Merge apiKey with endpointHeaders for all API calls (config endpoint—default or custom—and OTLP)
            let apiKeyHeader = [PulseAttributes.apiKeyHeaderKey: apiKey]
            let endpointHeadersWithProject = (endpointHeaders ?? [:]).merging(apiKeyHeader) { _, new in new }

            // Config: load from persistence (sync)
            let configCoordinator = PulseSdkConfigCoordinator()
            configStorageQueue.sync {
                _currentSdkConfig = configCoordinator.loadCurrentConfig()
            }
            if let v = _currentSdkConfig?.version {
                PulseLogger.log("Config loaded from persistence (version \(v)).")
            } else {
                PulseLogger.log("No persisted config, using defaults.")
            }

            let resolvedConfigEndpointUrl = configEndpointUrl ?? Self.defaultConfigEndpointUrl(from: endpointBaseUrl)
            configCoordinator.startBackgroundFetch(
                configEndpointUrl: resolvedConfigEndpointUrl,
                endpointHeaders: endpointHeadersWithProject,
                currentConfigVersion: _currentSdkConfig?.version
            )

            var config = InstrumentationConfiguration()
            instrumentations?(&config)

            let resource = buildResource(apiKey: apiKey, resource: resource)
            // 3. Read from built resource
            let telemetrySdkName: String? = {
                guard let av = resource.attributes[ResourceAttributes.telemetrySdkName.rawValue] else { return nil }
                if case .string(let s) = av { return s } else { return nil }
            }()
            let currentSdkName = PulseSdkName.from(telemetrySdkName: telemetrySdkName ?? PulseAttributes.PulseSdkNames.iosSwift)

            if let sdkConfig = configStorageQueue.sync(execute: { _currentSdkConfig }) {
                let interactionConfigUrl = sdkConfig.interaction.configUrl
                config.interaction { $0.setConfigUrl { interactionConfigUrl } }
                let processors = PulseSamplingSignalProcessors(sdkConfig: sdkConfig, currentSdkName: currentSdkName)
                _samplingSignalProcessors = processors
                let enabledFeatures = processors.getEnabledFeatures()
                applyDisabledFeatures(enabledFeatures: enabledFeatures, config: &config)
                
                // Extract and merge Session Replay config from backend
                #if canImport(SessionReplay)
                let sessionReplayFeature = sdkConfig.features.first { feature in
                    feature.featureName == .session_replay &&
                    feature.sdks.contains(currentSdkName) &&
                    feature.sessionSampleRate > 0
                }
                
                if let feature = sessionReplayFeature {
                    let remoteConfig = SessionReplayRemoteConfig.from(featureConfig: feature)
                    let localConfig = config.sessionReplay.config
                    let mergedConfig = SessionReplayConfig.merge(
                        remote: remoteConfig,
                        local: localConfig
                    )
                    // Update SessionReplayInstrumentationConfig with merged config
                    config.sessionReplay { replayConfig in
                        // Update all config properties from merged config
                        replayConfig.configure { config in
                            config.captureIntervalMs = mergedConfig.captureIntervalMs
                            config.compressionQuality = mergedConfig.compressionQuality
                            config.textAndInputPrivacy = mergedConfig.textAndInputPrivacy
                            config.imagePrivacy = mergedConfig.imagePrivacy
                            config.screenshotScale = mergedConfig.screenshotScale
                            config.flushIntervalSeconds = mergedConfig.flushIntervalSeconds
                            config.flushAt = mergedConfig.flushAt
                            config.maxBatchSize = mergedConfig.maxBatchSize
                            config.replayEndpointBaseUrl = mergedConfig.replayEndpointBaseUrl
                            // Preserve local-only settings (maskViewClasses, unmaskViewClasses)
                            // These are already in mergedConfig from the merge function
                            config.maskViewClasses = mergedConfig.maskViewClasses
                            config.unmaskViewClasses = mergedConfig.unmaskViewClasses
                        }
                    }
                }
                #endif
            }

            let (tracerProvider, loggerProvider, openTelemetry) = buildOpenTelemetrySDK(
                endpointBaseUrl: endpointBaseUrl,
                customEventCollectorUrl: customEventCollectorUrl,
                endpointHeaders: endpointHeadersWithProject,
                resource: resource,
                config: config,
                currentSdkConfig: configStorageQueue.sync { _currentSdkConfig },
                currentSdkName: currentSdkName,
                tracerProviderCustomizer: tracerProviderCustomizer,
                loggerProviderCustomizer: loggerProviderCustomizer
            )

            let installationContext = InstallationContext(
                tracerProvider: tracerProvider,
                loggerProvider: loggerProvider,
                openTelemetry: openTelemetry,
                endpointBaseUrl: endpointBaseUrl,
                endpointHeaders: endpointHeadersWithProject,
                flushLogProcessor: { [weak self] in
                    self?.batchLogProcessor?.forceFlush()
                },
                projectId: projectId,
                userIdProvider: { [weak self] in
                    self?.userSessionEmitter.userId
                }
            )
            self.instrumentationConfig = config
            installInstrumentations(config: config, ctx: installationContext)

            #if os(iOS) || os(tvOS)
            if _configuration.includeScreenAttributes {
                let screenTracer = tracerProvider.get(
                    instrumentationName: PulseKitConstants.instrumentationScopeName,
                    instrumentationVersion: PulseKitConstants.instrumentationVersion
                )
                VisibleScreenTracker.shared.start(tracer: screenTracer)
                UIViewControllerSwizzler.swizzle(includeLifecycleMethods: false)
            }
            #endif

            self.openTelemetry = openTelemetry
            _isInitialized = true
            let configVersion = configStorageQueue.sync { _currentSdkConfig?.version }
            if let v = configVersion {
                PulseLogger.log("Initialized with config v\(v).")
            } else {
                PulseLogger.log("Initialized (using defaults, no config).")
            }
        }
    }

    // MARK: - Private Helper Methods

    /// Disables features not in enabledFeatures.
    private func applyDisabledFeatures(enabledFeatures: [PulseFeatureName], config: inout InstrumentationConfiguration) {
        for feature in PulseFeatureName.allCases {
            guard !enabledFeatures.contains(feature) else { continue }
            switch feature {
            case .java_crash: break
            case .js_crash: break
            case .cpp_crash: break
            case .java_anr: break
            case .cpp_anr: break
            case .interaction:
                config.interaction { $0.enabled(false) }
            case .network_change:
                _configuration.disableNetworkAttributes()
            case .network_instrumentation:
                config.urlSession { $0.enabled(false) }
            case .screen_session:
                config.screenLifecycle { $0.enabled(false) }
            case .custom_events:
                _customEventsEnabled = false
            case .rn_screen_load: break
            case .rn_screen_interactive: break
            case .ios_crash:
                config.crash { $0.enabled(false) }
            case .session_replay:
                config.sessionReplay { $0.enabled(false) }
            case .unknown: break
            }
        }
    }

    /// Normalizes base URL by stripping trailing slashes (avoids double slashes when appending paths).
    private static func normalizedBaseUrl(_ base: String) -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    /// Default config endpoint URL when not provided
    private static func defaultConfigEndpointUrl(from endpointBaseUrl: String) -> String {
        let withPort = endpointBaseUrl.replacingOccurrences(of: ":4318", with: ":8080")
        return normalizedBaseUrl(withPort) + "/v1/configs/active/"
    }
    internal static func extractProjectID(from apiKey: String) -> String {
        if let lastUnderscoreIndex = apiKey.lastIndex(of: "_"), lastUnderscoreIndex > apiKey.startIndex {
            return String(apiKey[..<lastUnderscoreIndex])
        }
        return apiKey
    }

    /// Set default telemetry.sdk.name first, then resource callback (overrides if it sets the key)
    private func buildResource(apiKey: String, resource: ((inout [String: AttributeValue]) -> Void)?) -> Resource {
        let defaultResource = DefaultResources().get()
        var attributes = defaultResource.attributes

        // 1. Set default (native iOS = pulse_ios_swift)
        attributes[ResourceAttributes.telemetrySdkName.rawValue] = AttributeValue.string(PulseAttributes.PulseSdkNames.iosSwift)
        attributes[PulseAttributes.projectId] = AttributeValue.string(Self.extractProjectID(from: apiKey))

        // 2. Resource callback can override (e.g. RN bridge sets pulse_ios_rn)
        if let resourceCustomizer = resource {
            resourceCustomizer(&attributes)
        }

        return Resource(attributes: attributes)
    }

    private func buildOpenTelemetrySDK(
        endpointBaseUrl: String,
        customEventCollectorUrl: String?,
        endpointHeaders: [String: String]?,
        resource: Resource,
        config: InstrumentationConfiguration,
        currentSdkConfig: PulseSdkConfig?,
        currentSdkName: PulseSdkName,
        tracerProviderCustomizer: ((TracerProviderBuilder) -> TracerProviderBuilder)?,
        loggerProviderCustomizer: (([LogRecordProcessor]) -> [LogRecordProcessor])?
    ) -> (tracerProvider: TracerProvider, loggerProvider: LoggerProvider, openTelemetry: OpenTelemetry) {
        var meteredConfig = MeteredSessionConfig()
        let meteredManager = meteredConfig.createMeteredManager()
        let headers = meteredConfig.addMeteredSessionHeader(to: endpointHeaders, meteredManager: meteredManager)
        let envVarHeaders: [(String, String)]? = headers.map { ($0.key, $0.value) }

        // URL resolution (see expectations in PulseKit README):
        // Traces/Logs/Metrics: config present → use full path from config; else → baseUrl + /v1/{traces|logs|metrics}
        // customEventCollectorUrl: config present → from config; else user-provided; else baseUrl + /v1/logs
        let base = Self.normalizedBaseUrl(endpointBaseUrl)
        let tracesUrl = currentSdkConfig.map { URL(string: $0.signals.spanCollectorUrl)! }
            ?? URL(string: "\(base)/v1/traces")!
        let logsUrl = currentSdkConfig.map { URL(string: $0.signals.logsCollectorUrl)! }
            ?? URL(string: "\(base)/v1/logs")!
        let customEventUrl = currentSdkConfig.map { URL(string: $0.signals.customEventCollectorUrl)! }
            ?? (customEventCollectorUrl.flatMap { URL(string: $0) } ?? URL(string: "\(base)/v1/logs")!)
        let otlpSpanExporter = OtlpHttpTraceExporter(endpoint: tracesUrl, envVarHeaders: envVarHeaders)
        let filteredSpanExporter = FilteringSpanExporter(delegate: otlpSpanExporter)

        // Always use SelectedLogExporter: route custom events to customEventUrl, others to logsUrl.
        // When config is nil: customEventUrl = customEventCollectorUrl from init ?? logsUrl.
        let defaultLogsExporter = OtlpHttpLogExporter(endpoint: logsUrl, envVarHeaders: envVarHeaders)
        let customEventExporter = OtlpHttpLogExporter(endpoint: customEventUrl, envVarHeaders: envVarHeaders)
        let selectExporter = PulseSignalSelectExporter(currentSdkName: currentSdkName)
        let logMap: [(PulseSignalMatchCondition, LogRecordExporter)] = [
            (PulseSignalMatchCondition.allMatchLogCondition, defaultLogsExporter),
            (PulseSignalMatchCondition.customEventLogCondition(pulseTypeKey: PulseAttributes.pulseType, customEventValue: PulseAttributes.PulseTypeValues.customEvent), customEventExporter),
        ]
        let logsExporter = selectExporter.makeSelectedLogExporter(logMap: logMap)

        let finalSpanExporter: SpanExporter
        let finalLogExporter: LogRecordExporter
        if let processors = _samplingSignalProcessors {
            finalSpanExporter = processors.makeSampledSpanExporter(delegateExporter: filteredSpanExporter)
            finalLogExporter = processors.makeSampledLogExporter(delegateExporter: logsExporter)
        } else {
            finalSpanExporter = filteredSpanExporter
            finalLogExporter = logsExporter
        }

        let (persistentSpanExporter, persistentLogExporter) = PersistenceUtils.createPersistentExporters(
            spanExporter: finalSpanExporter,
            logExporter: finalLogExporter
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
            meteredConfig: meteredConfig,
            meteredManager: meteredManager,
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
        meteredConfig: MeteredSessionConfig,
        meteredManager: SessionManager,
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
            let globalAttributesSpanProcessor = GlobalAttributesSpanProcessor(pulse: self)
            let globalAttributesLogProcessor = GlobalAttributesLogRecordProcessor(
                pulse: self,
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

        if config.location.enabled {
            let locationAttributesSpanProcessor = LocationAttributesSpanAppender()
            let locationAttributesLogProcessor = LocationAttributesLogRecordProcessor(nextProcessor: logProcessor)
            spanProcessors.append(locationAttributesSpanProcessor)
            logProcessor = locationAttributesLogProcessor
        }

        let pulseSpanProcessor = pulseSignalProcessor.createSpanProcessor()
        spanProcessors.append(pulseSpanProcessor)
        spanProcessors.append(baseSpanProcessor)


        let pulseLogProcessor = pulseSignalProcessor.createLogProcessor(nextProcessor: logProcessor)
        var logProcessors: [LogRecordProcessor] = [pulseLogProcessor]

        if let otelProcessors = config.sessions.createProcessors(baseLogProcessor: pulseLogProcessor) {
            spanProcessors.append(otelProcessors.otelSpanProcessor)
            logProcessor = otelProcessors.otelLogProcessor
        }
        
        let meteredProcessors = meteredConfig.createProcessors(
            baseLogProcessor: logProcessor,
            meteredManager: meteredManager
        )
        spanProcessors.append(meteredProcessors.meteredSpanProcessor)
        logProcessors = [meteredProcessors.meteredLogProcessor]
        
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
        for instrumentation in config.instrumentations {
            instrumentation.initialize(ctx: ctx)
        }
    }

    private func uninstallInstrumentations() {
        guard let config = instrumentationConfig else { return }
        for instrumentation in config.instrumentations {
            instrumentation.uninstall()
        }
    }

    // MARK: - Shutdown

    /// Permanently shuts down the SDK. Cannot be re-initialized in this process.
    public func shutdown() {
        initializationQueue.sync {
            guard _isInitialized, !_isShutdown else { return }

            uninstallInstrumentations()

            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "pulse_installation_id")
            defaults.removeObject(forKey: "user_id")

            batchSpanProcessor?.shutdown()
            _ = batchLogProcessor?.shutdown()
            PersistenceUtils.clearStorage()

            openTelemetry = nil
            _isShutdown = true
        }
    }

    public func trackEvent(
        name: String,
        observedTimeStampInMs: Double,
        params: [String: AttributeValue] = [:]
    ) {
        guard isActive, _customEventsEnabled else { return }

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
        guard isActive, _customEventsEnabled else { return }

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
        guard isActive, _customEventsEnabled else { return }

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
            fatalError("Pulse SDK is not initialized. Please call Pulse.initialize")
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


