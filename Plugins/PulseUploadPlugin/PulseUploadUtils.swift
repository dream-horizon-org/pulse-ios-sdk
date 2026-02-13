import Foundation

// MARK: - Utility Functions

enum PulseUploadUtils {
    /// Format file size in human-readable format
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
        
        // Remove existing zip if present
        try? FileManager.default.removeItem(at: zipURL)
        
        // Use Process to call zip command (more reliable than Foundation's zip)
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
    
    /// Auto-detect file type from file extension
    static func detectFileType(from fileURL: URL, defaultType: String) -> String {
        let fileExtension = fileURL.pathExtension.lowercased()
        let fileNameLower = fileURL.lastPathComponent.lowercased()
        
        if fileNameLower.hasSuffix(".dsym") || fileExtension == "dsym" {
            return "DSYM"
        } else if fileExtension == "map" || fileNameLower.contains(".map") {
            return "JS"
        }
        
        return defaultType
    }
    
    /// Normalize localhost URL to 127.0.0.1 for DNS resolution
    static func normalizeURL(_ url: String) -> String {
        return url.replacingOccurrences(of: "localhost", with: "127.0.0.1")
    }
    
    /// Print usage information
    static func printUsage() {
        print("""
        Pulse Upload Plugin
        
        Usage:
          swift package plugin upload-symbols \\
            --api-url=<url> \\
            --file-path=<path> \\
            --app-version=<version> \\
            --version-code=<code> \\
            [--type=<type>] \\
            [--bundle-id=<id>]
        
        Arguments:
          --api-url=<url>        API URL for uploading files (required)
          --file-path=<path>     Path to file or directory to upload (required)
          --app-version=<version> App version (e.g., 1.0.0) (required)
          --version-code=<code>   Version code (positive integer, e.g., 1) (required)
          --type=<type>          File type (default: "JS", options: "JS", "MAPPING", "DSYM", etc. - auto-uppercased)
          --bundle-id=<id>       Bundle ID (optional, e.g., com.example.app)
          --help, -h             Show this help message
        
        Legacy Arguments (still supported):
          --dsym-path=<path>     Alias for --file-path (for backward compatibility)
        
        Examples:
          # Upload a JS source map file (default type)
          swift package plugin upload-symbols \\
            --api-url=http://localhost:8080/v1/symbolicate/file/upload \\
            --file-path=/path/to/index.js.map \\
            --app-version=1.0.0 \\
            --version-code=1 \\
            --type=JS
          
          # Upload a dSYM file
          swift package plugin upload-symbols \\
            --api-url=http://localhost:8080/v1/symbolicate/file/upload \\
            --file-path=/path/to/App.dSYM \\
            --app-version=1.0.0 \\
            --version-code=1 \\
            --type=DSYM
        
          # Upload with bundle ID
          swift package plugin upload-symbols \\
            --api-url=http://localhost:8080/v1/symbolicate/file/upload \\
            --file-path=./build/App.dSYM \\
            --app-version=1.0.0 \\
            --version-code=1 \\
            --bundle-id=com.example.app
        
        Note: The file path can be absolute or relative to the package directory.
              Directories (like dSYM bundles) will be automatically zipped.
        """)
    }
}
