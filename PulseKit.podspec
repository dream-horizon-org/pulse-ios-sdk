Pod::Spec.new do |spec|
  spec.name = "PulseKit"
  spec.version = "0.0.1"
  spec.summary = "Pulse iOS SDK - Simplified OpenTelemetry for iOS"
  spec.description = <<-DESC
    Pulse iOS SDK is a simplified, production-ready SDK for instrumenting iOS 
    applications with OpenTelemetry. Built on top of OpenTelemetry-Swift, 
    Pulse provides a unified API with sensible defaults for easy integration.
  DESC
  
  spec.homepage = "https://github.com/dream-horizon-org/pulse-ios-sdk"
  spec.documentation_url = "https://pulse.dreamhorizon.org/docs/sdk/ios"
  spec.license = { :type => "Apache 2.0", :file => "LICENSE" }
  spec.authors = { "Pulse iOS SDK" => "support@dream-horizon.org" }
  
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
  spec.dependency 'Pulse-Swift-Protocol-Exporter-Http', spec.version.to_s
  spec.dependency 'Pulse-Swift-SdkResourceExtension', spec.version.to_s
  spec.dependency 'Pulse-Swift-Instrumentation-URLSession', spec.version.to_s
  spec.dependency 'Pulse-Swift-Instrumentation-NetworkStatus', spec.version.to_s
  spec.dependency 'Pulse-Swift-Instrumentation-Interaction', spec.version.to_s
  spec.dependency 'Pulse-Swift-Sessions', spec.version.to_s
  spec.dependency 'Pulse-Swift-SignPostIntegration', spec.version.to_s
  spec.dependency 'Pulse-Swift-Instrumentation-Crashes', spec.version.to_s
  spec.pod_target_xcconfig = { "OTHER_SWIFT_FLAGS" => "-module-name PulseKit -package-name pulse_kit" }
end

