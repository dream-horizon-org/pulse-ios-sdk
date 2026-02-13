import Foundation
import PackagePlugin

// MARK: - Utility Functions

enum PulseUploadUtils {
    private enum ANSIColor {
        static let yellow = "\u{001B}[33m"
        static let reset = "\u{001B}[0m"
    }
    
    static func warn(_ message: String) {
        fputs("\(ANSIColor.yellow)warning: \(message)\(ANSIColor.reset)\n", stderr)
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        
        if mb >= 1.0 {
            return String(format: "%.2f MB", mb)
        } else if kb >= 1.0 {
            return String(format: "%.2f KB", kb)
        } else {
            return "\(bytes) bytes"
        }
    }
    
    /// Create a zip archive from a directory
    static func createZipArchive(from directory: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let zipName = "\(directory.lastPathComponent).zip"
        let zipURL = tempDir.appendingPathComponent(zipName)
        
        try? FileManager.default.removeItem(at: zipURL)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", zipURL.path, directory.lastPathComponent]
        process.currentDirectoryPath = directory.deletingLastPathComponent().path
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw PulseUploadError.uploadFailed("Failed to create zip archive: zip command exited with status \(process.terminationStatus)")
        }
        
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw PulseUploadError.uploadFailed("Zip archive was not created")
        }
        
        return zipURL
    }
    
    static func detectFileType(from fileURL: URL) -> String {
        let fileExtension = fileURL.pathExtension.lowercased()
        let fileNameLower = fileURL.lastPathComponent.lowercased()
        
        if fileNameLower.hasSuffix(".dsym") || fileExtension == "dsym" {
            return "dsym"
        }
        
        return "unknown"
    }
    
    static func normalizeURL(_ url: String) -> String {
        return url.replacingOccurrences(of: "localhost", with: "127.0.0.1")
    }
    
    static func resolveFilePath(_ path: String, packageDirectory: Path) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        let packagePath = packageDirectory.appending(path)
        return URL(fileURLWithPath: packagePath.string)
    }
    
    static func validateFileType(_ fileType: String, fileURL: URL) throws -> String {
        if fileType == "dsym" {
            return "dsym"
        } else if fileType == "unknown" {
            let detected = detectFileType(from: fileURL)
            if detected == "dsym" {
                return "dsym"
            } else {
                warn("File type detected as 'unknown' for: \(fileURL.lastPathComponent)")
                warn("   Expected: dSYM file (.dSYM extension or directory)")
                warn("   Upload will proceed but may be rejected by backend.")
                warn("   Fix: Use a dSYM file or set --type=dsym if this is a dSYM file.")
                return "unknown"
            }
        } else {
            throw PulseUploadError.invalidArgument("Only 'dsym' type is currently supported. Got: \(fileType). Use --help for usage.")
        }
    }
    
    static func prepareFileForUpload(_ fileURL: URL, fileType: String) throws -> (uploadURL: URL, fileName: String, fileSize: Int64, isTemporary: Bool) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw PulseUploadError.fileNotFound("File or directory not found at: \(fileURL.path)")
        }
        
        if isDirectory.boolValue {
            let zipURL = try createZipArchive(from: fileURL)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
            guard let size = fileAttributes[.size] as? Int64, size > 0 else {
                throw PulseUploadError.invalidFile("Zip archive is empty: \(zipURL.path)")
            }
            return (zipURL, "\(fileURL.lastPathComponent).zip", size, true)
        } else {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = fileAttributes[.size] as? Int64, size > 0 else {
                throw PulseUploadError.invalidFile("File is empty: \(fileURL.path)")
            }
            return (fileURL, fileURL.lastPathComponent, size, false)
        }
    }
    
    static func printUsage() {
        print("""
        Pulse Upload Plugin
        
        Usage:
          swift package plugin uploadSourceMaps \\
            -u <url> | --api-url=<url> \\
            -p <path> | --dsym-path=<path> \\
            -v <version> | --app-version=<version> \\
            -c <code> | --version-code=<code> \\
            [-t dsym | --type=dsym] \\
            [-d | --debug]
        
        Required Arguments:
          -u, --api-url=<url>           API URL for uploading files
          -p, --dsym-path=<path>       Path to dSYM file or directory to upload
          -v, --app-version=<version>  App version (e.g., 1.0.0)
          -c, --version-code=<code>    Version code (positive integer, e.g., 1)
        
        Optional Arguments:
          -t, --type=dsym              File type (default: unknown, auto-detected if dSYM)
          -d, --debug                  Show debug information including metadata
          -h, --help                   Show this help message
        
        Example:
          swift package plugin uploadSourceMaps \\
            -u http://localhost:8080/v1/symbolicate/file/upload \\
            -p ~/Library/Developer/Xcode/DerivedData/YourApp-*/Build/Products/Release-iphoneos/YourApp.app.dSYM \\
            -v 1.0.0 \\
            -c 1 \\
            -d
        
        Note: The file path can be absolute or relative to the package directory.
              Directories (like dSYM bundles) will be automatically zipped.
              Currently only "dsym" file type is supported; other types default to "unknown".
        """)
    }
}
