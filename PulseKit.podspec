Pod::Spec.new do |spec|
  spec.name = "PulseKit"
  spec.version = "1.0.0"
  spec.summary = "Pulse iOS SDK - Simplified OpenTelemetry for iOS"
  spec.description = <<-DESC
    Pulse iOS SDK is a simplified, production-ready SDK for instrumenting iOS 
    applications with OpenTelemetry. Built on top of OpenTelemetry-Swift, 
    Pulse provides a unified API with sensible defaults for easy integration.
  DESC
  
  spec.homepage = "https://github.com/dream-horizon-org/pulse-ios-sdk"
  spec.license = { :type => "Apache 2.0", :file => "LICENSE" }
  spec.authors = { "Pulse iOS SDK" => "support@dream-horizon.org" }
  
  # For local development, this will be overridden by :path in Podfile
  spec.source = { 
    :git => "https://github.com/dream-horizon-org/pulse-ios-sdk.git", 
    :tag => spec.version.to_s 
  }
  spec.source_files = "Sources/PulseKit/**/*.swift"
  spec.exclude_files = "Sources/PulseKit/README.md"
  
  spec.swift_version = "5.10"
  spec.ios.deployment_target = "13.0"
  spec.tvos.deployment_target = "13.0"
  spec.watchos.deployment_target = "6.0"
  spec.visionos.deployment_target = "1.0"
  spec.module_name = "PulseKit"
  
  spec.dependency 'OpenTelemetry-Swift-Api', '~> 2.2'
  spec.dependency 'OpenTelemetry-Swift-Sdk', '~> 2.2'
  spec.dependency 'OpenTelemetry-Swift-StdoutExporter', '~> 2.2'
  spec.dependency 'OpenTelemetry-Swift-Protocol-Exporter-Http', '~> 2.2'
  spec.dependency 'OpenTelemetry-Swift-SdkResourceExtension', '~> 2.2'
  spec.dependency 'OpenTelemetry-Swift-Instrumentation-URLSession', '~> 2.2'
  spec.dependency 'OpenTelemetry-Swift-Instrumentation-NetworkStatus', '~> 2.2'
  spec.dependency 'Pulse-Swift-Instrumentation-Interaction', '2.2.1'
  spec.dependency 'Pulse-Swift-Sessions', '2.2.1'
  spec.dependency 'Pulse-Swift-SignPostIntegration', '2.2.1'
  spec.pod_target_xcconfig = { "OTHER_SWIFT_FLAGS" => "-module-name PulseKit -package-name pulse_kit" }
end

