Pod::Spec.new do |spec|
  spec.name = "Pulse-Swift-SignPostIntegration"
  spec.version = "0.0.1"
  spec.summary = "Swift OpenTelemetry SignPost Integration"
  
  spec.homepage = "https://github.com/dream-horizon-org/pulse-ios-sdk"
  spec.documentation_url = "https://pulse.dreamhorizon.org/docs/sdk/ios"
  spec.license = { :type => "Apache 2.0", :file => "LICENSE" }
  spec.authors = { "Pulse iOS SDK" => "support@dream-horizon.org" }
  
  spec.source = { 
    :git => "https://github.com/dream-horizon-org/pulse-ios-sdk.git", 
    :tag => spec.version.to_s 
  }
  spec.source_files = "Sources/Instrumentation/SignPostIntegration/*.swift"
  spec.exclude_files = "Sources/Instrumentation/SignPostIntegration/README.md"
  
  spec.swift_version = "5.10"
  spec.ios.deployment_target = "13.0"
  spec.tvos.deployment_target = "13.0"
  spec.watchos.deployment_target = "6.0"
  spec.visionos.deployment_target = "1.0"
  spec.module_name = "SignPostIntegration"
  
  spec.dependency 'OpenTelemetry-Swift-Sdk', '~> 2.2'
  spec.pod_target_xcconfig = { "OTHER_SWIFT_FLAGS" => "-module-name SignPostIntegration -package-name pulse_swift_signpost_integration" }
end
