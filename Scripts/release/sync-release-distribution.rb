#!/usr/bin/env ruby
# frozen_string_literal: true

# Syncs CocoaPods spec.dependency lines from the source PulseKit.podspec into the
# release repo podspec, and regenerates the release repo Package.swift with one
# .binaryTarget per xcframework at the repo root (PulseKit + peers from
# PulseKit.podspec via print-peer-xcframework-entries.rb).
#
# Usage (from CI or locally after copying *.xcframework into release-dir):
#   ruby Scripts/release/sync-release-distribution.rb \
#     --source-root /path/to/pulse-ios-sdk \
#     --release-dir /path/to/pulse-ios-checkout \
#     --version 0.0.1-beta.5
#
# Requires: peer xcframeworks already present under release-dir (names match
# PRODUCT_MODULE_NAME, e.g. OpenTelemetryApi.xcframework).

require "fileutils"
require "optparse"
require "open3"

options = { source_root: nil, release_dir: nil, version: nil }
OptionParser.new do |opts|
  opts.banner = "Usage: sync-release-distribution.rb [options]"
  opts.on("--source-root PATH", "pulse-ios-sdk repository root") { |p| options[:source_root] = p }
  opts.on("--release-dir PATH", "pulse-ios (release) repo root") { |p| options[:release_dir] = p }
  opts.on("--version VER", "spec.version value for podspec") { |v| options[:version] = v }
end.parse!

%i[source_root release_dir version].each do |k|
  abort("Missing --#{k.to_s.tr('_', '-')}") if options[k].to_s.strip.empty?
end

source_root = File.expand_path(options[:source_root])
release_dir = File.expand_path(options[:release_dir])
version = options[:version]

source_pod = File.join(source_root, "PulseKit.podspec")
release_pod = File.join(release_dir, "PulseKit.podspec")
release_pkg = File.join(release_dir, "Package.swift")
peer_script = File.join(source_root, "Scripts", "print-peer-xcframework-entries.rb")

abort("Missing #{source_pod}") unless File.file?(source_pod)
abort("Missing #{release_pod}") unless File.file?(release_pod)
abort("Missing #{peer_script}") unless File.file?(peer_script)

def extract_dependency_lines(podspec_text)
  podspec_text.lines.select { |l| l.match?(/^\s*spec\.dependency\s+/) }
end

def strip_dependency_lines(podspec_text)
  podspec_text.lines.reject { |l| l.match?(/^\s*spec\.dependency\s+/) }.join
end

# Remove stanzas that only apply to the source repo (paths like Sources/…, Scripts/…).
# The release repo ships xcframeworks at the root; leaving these makes `pod ipc spec` fail.
def strip_development_only_podspec_stanzas(podspec_text)
  lines = podspec_text.lines
  markers = [
    "spec.source_files",
    "spec.exclude_files",
    "spec.resources",
    "spec.preserve_paths"
  ]
  out = []
  i = 0
  while i < lines.length
    line = lines[i]
    marker_hit = markers.find { |m| line.strip.start_with?(m) }
    if marker_hit
      if line.include?("[")
        depth = line.count("[") - line.count("]")
        i += 1
        while i < lines.length && depth.positive?
          depth += lines[i].count("[") - lines[i].count("]")
          i += 1
        end
      else
        i += 1
      end
      next
    end

    out << line
    i += 1
  end
  out.join
end

def ensure_pulsekit_wrapper(release_dir)
  wrapper = File.join(release_dir, "Sources", "PulseKitWrapper", "Exports.swift")
  return if File.file?(wrapper)

  FileUtils.mkdir_p(File.dirname(wrapper))
  File.write(wrapper, <<~SWIFT)
    @_exported import PulseKit
  SWIFT
  puts "Created #{wrapper} (SPM wrapper for distribution)"
end

def insert_dependencies_after_anchor(podspec_without_deps, dep_lines)
  anchor = podspec_without_deps.match(/(^\s*spec\.module_name\s*=.*\n)/m)
  if anchor
    return podspec_without_deps.sub(anchor[1], anchor[1] + dep_lines.join)
  end

  anchor = podspec_without_deps.match(/(^\s*spec\.ios\.deployment_target\s*=.*\n)/m)
  if anchor
    return podspec_without_deps.sub(anchor[1], anchor[1] + dep_lines.join)
  end

  anchor = podspec_without_deps.match(/(^\s*spec\.vendored_frameworks\b.*\n)/m)
  return podspec_without_deps.sub(anchor[1], dep_lines.join + anchor[1]) if anchor

  podspec_without_deps + dep_lines.join
end

source_text = File.read(source_pod)
dep_lines = extract_dependency_lines(source_text)
if dep_lines.empty?
  warn "warning: no spec.dependency lines in source PulseKit.podspec"
else
  puts "Syncing #{dep_lines.size} spec.dependency line(s) from source podspec"
end

release_text = File.read(release_pod)
release_text = strip_development_only_podspec_stanzas(release_text)
stripped = strip_dependency_lines(release_text)
merged = insert_dependencies_after_anchor(stripped, dep_lines)

unless merged.match?(/spec\.version\s*=\s*["']#{Regexp.escape(version)}["']/)
  merged = merged.sub(/spec\.version\s*=.*$/) { "spec.version      = \"#{version}\"" }
end

File.write(release_pod, merged)
puts "Wrote #{release_pod}"

ensure_pulsekit_wrapper(release_dir)

# --- Package.swift (path-based binary targets at release repo root) ---

stdout, stderr, st = Open3.capture3("ruby", peer_script, source_root)
unless st.success?
  warn stderr
  abort("print-peer-xcframework-entries.rb failed:\n#{stdout}\n#{stderr}")
end

peer_modules = []
stdout.each_line do |line|
  line.strip!
  next if line.empty?
  # Only scheme:module lines from the script (ignore any stray stderr noise).
  next unless line.match?(/\A[\w.-]+:[\w.]+\z/)

  _scheme, mod = line.split(":", 2)
  peer_modules << mod
end

# PulseKit first, then peers (same order as build / CocoaPods link order expectation).
binary_order = ["PulseKit"] + peer_modules
binary_order.uniq!

binary_order.each do |mod|
  xcf = File.join(release_dir, "#{mod}.xcframework")
  abort("Missing #{xcf} — build and copy xcframeworks before running this script") unless File.directory?(xcf)
end

def swift_binary_target_name(module_basename)
  "#{module_basename}Binary"
end

binary_targets = binary_order.map do |mod|
  name = swift_binary_target_name(mod)
  <<~SWIFT.chomp
        .binaryTarget(
            name: "#{name}",
            path: "#{mod}.xcframework"
        )
  SWIFT
end

wrapper_deps = binary_order.map { |m| "\"#{swift_binary_target_name(m)}\"" }.join(",\n                ")

package_swift = <<~SWIFT
  // swift-tools-version: 5.9
  //
  // Generated by pulse-ios-sdk release workflow (Scripts/release/sync-release-distribution.rb).
  // Binary targets match PulseKit.podspec peers + PulseKit; paths are repo-root xcframeworks.

  import PackageDescription

  let package = Package(
      name: "PulseKitDistribution",
      platforms: [
          .iOS(.v15),
      ],
      products: [
          .library(name: "PulseKit", targets: ["PulseKitWrapper"]),
      ],
      dependencies: [],
      targets: [
  #{binary_targets.join(",\n")},
          .target(
              name: "PulseKitWrapper",
              dependencies: [
                  #{wrapper_deps},
              ],
              path: "Sources/PulseKitWrapper"
          ),
      ]
  )
SWIFT

File.write(release_pkg, package_swift)
puts "Wrote #{release_pkg} (#{binary_order.size} binary targets)"
