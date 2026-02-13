import Foundation
import PackagePlugin

// MARK: - Pulse Upload Plugin

@main
struct PulseUploadPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var apiUrl: String?
        var filePath: String?
        var appVersion: String?
        var versionCode: Int?
        var fileType: String = "unknown"
        var debugMode: Bool = false
        
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            // Handle --help first
            if arg == "--help" || arg == "-h" {
                PulseUploadUtils.printUsage()
                return
            }
            
            // Parse arguments - handle both --key=value and --key value formats
            if arg.contains("=") {
                let parts = arg.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else {
                    PulseUploadUtils.printUsage()
                    throw PulseUploadError.invalidArgument("Invalid argument format: \(arg). Use --key=value")
                }
                let key = String(parts[0])
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                
                switch key {
                case "--api-url", "-u": apiUrl = value
                case "--dsym-path", "-p": filePath = value
                case "--app-version", "-v": appVersion = value
                case "--version-code", "-c": versionCode = Int(value)
                case "--type", "-t": fileType = value.lowercased()
                case "--debug", "-d": debugMode = true
                default:
                    PulseUploadUtils.printUsage()
                    throw PulseUploadError.invalidArgument("Unknown argument: \(key). Use --help for usage.")
                }
            } else {
                // Parse arguments without = (e.g., --api-url value)
                switch arg {
                case "--api-url", "-u": apiUrl = iterator.next()
                case "--dsym-path", "-p": filePath = iterator.next()
                case "--app-version", "-v": appVersion = iterator.next()
                case "--version-code", "-c": versionCode = Int(iterator.next() ?? "")
                case "--type", "-t": fileType = (iterator.next() ?? "unknown").trimmingCharacters(in: .whitespaces).lowercased()
                case "--debug", "-d": debugMode = true
                default:
                    let trimmed = arg.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        continue
                    } else if trimmed.hasPrefix("--") {
                        PulseUploadUtils.printUsage()
                        throw PulseUploadError.invalidArgument("Unknown argument: \(trimmed). Use --help for usage.")
                    }
                    continue
                }
            }
        }
        
        // Validate required arguments (show help on error)
        guard let apiUrlValue = apiUrl, !apiUrlValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            PulseUploadUtils.printUsage()
            throw PulseUploadError.missingArgument("--api-url is required")
        }
        
        let apiUrlFinal = apiUrlValue.trimmingCharacters(in: .whitespaces)
        
        guard let testURL = URL(string: apiUrlFinal),
              let scheme = testURL.scheme,
              (scheme == "http" || scheme == "https") else {
            PulseUploadUtils.printUsage()
            throw PulseUploadError.invalidURL("API URL must be a valid HTTP or HTTPS URL")
        }
        
        guard let filePathValue = filePath, !filePathValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            PulseUploadUtils.printUsage()
            throw PulseUploadError.missingArgument("--dsym-path is required")
        }
        
        let filePathFinal = filePathValue.trimmingCharacters(in: .whitespaces)
        
        guard let appVersion = appVersion, !appVersion.trimmingCharacters(in: .whitespaces).isEmpty else {
            PulseUploadUtils.printUsage()
            throw PulseUploadError.missingArgument("--app-version is required")
        }
        
        guard let versionCode = versionCode, versionCode > 0 else {
            PulseUploadUtils.printUsage()
            throw PulseUploadError.missingArgument("--version-code is required and must be a positive integer")
        }
        
        let fileURL = PulseUploadUtils.resolveFilePath(filePathFinal, packageDirectory: context.package.directory)
        
        let finalFileType: String
        do {
            finalFileType = try PulseUploadUtils.validateFileType(fileType, fileURL: fileURL)
        } catch {
            PulseUploadUtils.printUsage()
            throw error
        }
        
        let (uploadURL, fileName, fileSize, isTemporaryZip) = try PulseUploadUtils.prepareFileForUpload(fileURL, fileType: finalFileType)
        
        defer {
            if isTemporaryZip {
                try? FileManager.default.removeItem(at: uploadURL)
            }
        }
        
        print("\nUploading to Pulse backend...")
        print("   File: \(fileName) (\(PulseUploadUtils.formatFileSize(fileSize)))")
        print("   Version: \(appVersion) (code: \(versionCode))")
        
        if debugMode {
            print("\nDebug Info:")
            print("   API URL: \(apiUrlFinal)")
            print("   File Path: \(fileURL.path)")
            print("   Platform: ios, Type: \(finalFileType)")
        }
        
        do {
            try await PulseUploadTask.upload(
                apiUrl: apiUrlFinal,
                fileURL: uploadURL,
                appVersion: appVersion,
                versionCode: versionCode,
                fileType: finalFileType,
                fileName: fileName,
                debugMode: debugMode
            )
            print("Upload successful")
        } catch {
            print("Upload failed: \(error.localizedDescription)")
            if debugMode {
                print("   Exception: \(type(of: error))")
            }
            throw error
        }
    }
}
