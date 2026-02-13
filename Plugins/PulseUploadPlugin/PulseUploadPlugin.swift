import Foundation
import PackagePlugin

// MARK: - Pulse Upload Plugin

@main
struct PulseUploadPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        // Parse arguments
        var apiUrl: String?
        var filePath: String?
        var appVersion: String?
        var versionCode: Int?
        var fileType: String = "UNKNOWN"
        var bundleId: String? = nil // Optional bundle ID
        
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--api-url":
                apiUrl = iterator.next()
            case "--file-path":
                filePath = iterator.next()
            case "--dsym-path":
                // Legacy support for --dsym-path
                filePath = iterator.next()
            case "--app-version":
                appVersion = iterator.next()
            case "--version-code":
                if let codeString = iterator.next() {
                    versionCode = Int(codeString)
                }
            case "--type":
                if let next = iterator.next() {
                    fileType = next.trimmingCharacters(in: .whitespaces).uppercased()
                } else {
                    fileType = "JS"
                }
            case "--bundle-id":
                bundleId = iterator.next()
            default:
                if arg.hasPrefix("--api-url=") {
                    let value = String(arg.dropFirst("--api-url=".count))
                    // Reject double equals
                    if value.hasPrefix("=") {
                        throw PulseUploadError.invalidArgument("Invalid argument format: \(arg). Use --api-url=<url> with a single equals sign, not ==.")
                    }
                    apiUrl = value
                } else if arg.hasPrefix("--file-path=") {
                    let value = String(arg.dropFirst("--file-path=".count))
                    if value.hasPrefix("=") {
                        throw PulseUploadError.invalidArgument("Invalid argument format: \(arg). Use --file-path=<path> with a single equals sign, not ==.")
                    }
                    filePath = value
                } else if arg.hasPrefix("--dsym-path=") {
                    // Legacy support
                    let value = String(arg.dropFirst("--dsym-path=".count))
                    if value.hasPrefix("=") {
                        throw PulseUploadError.invalidArgument("Invalid argument format: \(arg). Use --file-path=<path> with a single equals sign, not ==.")
                    }
                    filePath = value
                } else if arg.hasPrefix("--app-version=") {
                    let value = String(arg.dropFirst("--app-version=".count))
                    if value.hasPrefix("=") {
                        throw PulseUploadError.invalidArgument("Invalid argument format: \(arg). Use --app-version=<version> with a single equals sign, not ==.")
                    }
                    appVersion = value
                } else if arg.hasPrefix("--version-code=") {
                    let value = String(arg.dropFirst("--version-code=".count))
                    if value.hasPrefix("=") {
                        throw PulseUploadError.invalidArgument("Invalid argument format: \(arg). Use --version-code=<code> with a single equals sign, not ==.")
                    }
                    versionCode = Int(value)
                } else if arg.hasPrefix("--bundle-id=") {
                    let value = String(arg.dropFirst("--bundle-id=".count))
                    if value.hasPrefix("=") {
                        throw PulseUploadError.invalidArgument("Invalid argument format: \(arg). Use --bundle-id=<id> with a single equals sign, not ==.")
                    }
                    bundleId = value.trimmingCharacters(in: .whitespaces)
                } else if arg.hasPrefix("--type=") {
                    let value = String(arg.dropFirst("--type=".count))
                    if value.hasPrefix("=") {
                        throw PulseUploadError.invalidArgument("Invalid argument format: \(arg). Use --type=<type> with a single equals sign, not ==.")
                    }
                    fileType = value.trimmingCharacters(in: .whitespaces).uppercased()
                } else if arg.trimmingCharacters(in: .whitespaces).hasPrefix("--type=") {
                    // Handle cases with leading whitespace (e.g., from line continuation with backslash)
                    let trimmed = arg.trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed.dropFirst("--type=".count))
                    fileType = value.trimmingCharacters(in: .whitespaces).uppercased()
                } else if arg == "--help" || arg == "-h" {
                    PulseUploadUtils.printUsage()
                    return
                } else {
                    // Trim whitespace and check if it's a valid argument
                    let trimmed = arg.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        // Skip empty arguments (can happen with line continuations)
                        continue
                    } else if trimmed.hasPrefix("--type=") {
                        // Handle type argument with leading space (from backslash continuation)
                        let value = String(trimmed.dropFirst("--type=".count))
                        fileType = value.trimmingCharacters(in: .whitespaces).uppercased()
                    } else if trimmed.hasPrefix("--bundle-id=") {
                        // Handle bundle-id argument with leading space (from backslash continuation)
                        let value = String(trimmed.dropFirst("--bundle-id=".count))
                        bundleId = value.trimmingCharacters(in: .whitespaces)
                    } else if trimmed.hasPrefix("--") {
                        throw PulseUploadError.invalidArgument("Unknown argument: \(trimmed). Use --help for usage.")
                    } else {
                        // Might be a value from previous argument, skip it
                        continue
                    }
                }
            }
        }
        
        // Validate required arguments
        guard let apiUrlValue = apiUrl, !apiUrlValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PulseUploadError.missingArgument("--api-url is required. Use --api-url=<url>")
        }
        
        let apiUrlFinal = apiUrlValue.trimmingCharacters(in: .whitespaces)
        
        // Validate URL format early
        guard apiUrlFinal.hasPrefix("http://") || apiUrlFinal.hasPrefix("https://") else {
            throw PulseUploadError.invalidURL("API URL must start with http:// or https://. Got: \(apiUrlFinal)")
        }
        
        guard let filePathValue = filePath, !filePathValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PulseUploadError.missingArgument("--file-path is required. Use --file-path=<path> (or --dsym-path=<path> for legacy)")
        }
        
        let filePathFinal = filePathValue.trimmingCharacters(in: .whitespaces)
        
        guard let appVersion = appVersion, !appVersion.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PulseUploadError.missingArgument("--app-version is required. Use --app-version=<version>")
        }
        
        guard let versionCode = versionCode, versionCode > 0 else {
            throw PulseUploadError.missingArgument("--version-code is required and must be a positive integer. Use --version-code=<code>")
        }
        
        // Resolve and validate file path
        let fileURL: URL
        if filePathFinal.hasPrefix("/") {
            // Absolute path
            fileURL = URL(fileURLWithPath: filePathFinal)
        } else {
            // Relative to package directory
            let packagePath = context.package.directory.appending(filePathFinal)
            // Convert Path to URL using string representation
            fileURL = URL(fileURLWithPath: packagePath.string)
        }
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PulseUploadError.fileNotFound("File or directory not found at: \(fileURL.path)")
        }
        
        // Auto-detect file type from extension if not explicitly set and using default
        var finalFileType = fileType
        if fileType == "JS" { // Only auto-detect if using default
            finalFileType = PulseUploadUtils.detectFileType(from: fileURL, defaultType: fileType)
            if finalFileType != fileType {
                print("   Auto-detected file type: \(finalFileType) (from file extension)")
            }
        }
        
        // Handle dSYM bundle (directory) or file
        let (uploadURL, fileName, fileSize): (URL, String, Int64)
        var isTemporaryZip = false
        
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) && isDirectory.boolValue {
            // It's a directory (e.g., dSYM bundle), zip it
            if finalFileType.uppercased() == "DSYM" {
                print("   Detected dSYM bundle, creating zip archive...")
            } else {
                print("   Detected directory, creating zip archive...")
            }
            let zipURL = try PulseUploadUtils.createZipArchive(from: fileURL)
            isTemporaryZip = true
            uploadURL = zipURL
            fileName = "\(fileURL.lastPathComponent).zip"
            
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
            fileSize = (fileAttributes[.size] as? Int64) ?? 0
        } else {
            // It's a file (could be already zipped or a single file)
            uploadURL = fileURL
            fileName = fileURL.lastPathComponent
            
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = fileAttributes[.size] as? Int64, size > 0 else {
                throw PulseUploadError.invalidFile("File is empty: \(fileURL.path)")
            }
            fileSize = size
        }
        
        guard fileSize > 0 else {
            throw PulseUploadError.invalidFile("File is empty: \(uploadURL.path)")
        }
        
        defer {
            // Clean up temporary zip file if created
            if isTemporaryZip {
                try? FileManager.default.removeItem(at: uploadURL)
            }
        }
        
        // Log upload info
        print("\n📤 Uploading to Pulse backend...")
        print("   File: \(fileName) (\(PulseUploadUtils.formatFileSize(fileSize)))")
        print("   Version: \(appVersion) (code: \(versionCode))")
        if let bundleId = bundleId {
            print("   Bundle ID: \(bundleId)")
        }
        // Show original URL in logs, but use normalized URL for actual request
        let normalizedUrlForLog = PulseUploadUtils.normalizeURL(apiUrlFinal)
        if normalizedUrlForLog != apiUrlFinal {
            print("   API URL: \(apiUrlFinal) (normalized to \(normalizedUrlForLog) for localhost)")
        } else {
            print("   API URL: \(apiUrlFinal)")
        }
        
        // Upload the file
        do {
            try await PulseUploadTask.upload(
                apiUrl: apiUrlFinal,
                fileURL: uploadURL,
                appVersion: appVersion,
                versionCode: versionCode,
                fileType: finalFileType,
                fileName: fileName,
                bundleId: bundleId
            )
            print("✓ Upload successful")
        } catch {
            print("✗ Upload failed: \(error.localizedDescription)")
            throw error
        }
    }
}
