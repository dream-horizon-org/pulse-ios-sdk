Pod::Spec.new do |spec|
  spec.name = "Pulse-Swift-Protocol-Exporter-Http"
  spec.version = "0.0.1"
  spec.summary = "Swift OpenTelemetry Protocol Exporter Common"

  spec.homepage = "https://github.com/dream-horizon-org/pulse-ios-sdk"
  spec.documentation_url = "https://pulse.dreamhorizon.org/docs/sdk/ios"
  spec.license = { :type => "Apache 2.0", :file => "LICENSE" }
  spec.authors = "Pulse iOS SDK Authors"

  spec.source = { :git => "https://github.com/dream-horizon-org/pulse-ios-sdk.git", :tag => spec.version.to_s }
  spec.source_files = "Sources/Exporters/OpenTelemetryProtocolHttp/**/*.swift"

  spec.swift_version = "5.10"
  spec.ios.deployment_target = "13.0"
  spec.tvos.deployment_target = "13.0"
  spec.watchos.deployment_target = "6.0"
  spec.visionos.deployment_target = "1.0"
  spec.module_name = "OpenTelemetryProtocolExporterHttp"

  spec.dependency 'OpenTelemetry-Swift-Api', '~> 2.2'
  spec.dependency 'OpenTelemetry-Swift-Sdk', '~> 2.2'
  spec.dependency 'Pulse-Swift-Protocol-Exporter-Common', spec.version.to_s
  spec.dependency 'SwiftProtobuf', '~> 1.28'
  spec.pod_target_xcconfig = { "OTHER_SWIFT_FLAGS" => "-module-name OpenTelemetryProtocolExporterHttp -package-name opentelemetry_swift_exporter_http" }

end
