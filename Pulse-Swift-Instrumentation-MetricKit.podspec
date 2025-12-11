Pod::Spec.new do |spec|
  spec.name = "Pulse-Swift-Instrumentation-MetricKit"
  spec.version = "0.0.1"
  spec.summary = "Swift OpenTelemetry MetricKit Instrumentation"

  spec.homepage = "https://github.com/dream-horizon-org/pulse-ios-sdk"
  spec.documentation_url = "https://pulse.dreamhorizon.org/docs/sdk/ios"
  spec.license = { :type => "Apache 2.0", :file => "LICENSE" }
  spec.authors = "Pulse iOS SDK Authors"

  spec.source = { :git => "https://github.com/dream-horizon-org/pulse-ios-sdk.git", :tag => spec.version.to_s }
  spec.source_files = "Sources/Instrumentation/MetricKit/*.swift"
  spec.exclude_files = "Sources/Instrumentation/MetricKit/README.md"

  spec.swift_version = "5.10"
  spec.ios.deployment_target = "13.0"
  spec.osx.deployment_target = "12.0"
  spec.watchos.deployment_target = "6.0"
  spec.visionos.deployment_target = "1.0"
  spec.module_name = "MetricKitInstrumentation"

  spec.dependency 'OpenTelemetry-Swift-Sdk', '~> 2.2'
  spec.pod_target_xcconfig = { "OTHER_SWIFT_FLAGS" => "-module-name MetricKitInstrumentation -package-name opentelemetry_swift_metrickit_instrumentation" }

end
