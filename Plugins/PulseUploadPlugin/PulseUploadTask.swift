import Foundation

// MARK: - Upload Task

enum PulseUploadTask {
    /// Upload a file to the Pulse backend
    static func upload(
        apiUrl: String,
        fileURL: URL,
        appVersion: String,
        versionCode: Int,
        fileType: String,
        fileName: String,
        debugMode: Bool = false
    ) async throws {
        // Replace localhost with 127.0.0.1 for fixing localhost DNS resolution issue on macOS
        let normalizedUrl = PulseUploadUtils.normalizeURL(apiUrl)
        
        // Additional URL validation
        guard let url = URL(string: normalizedUrl), url.scheme != nil, url.host != nil else {
            throw PulseUploadError.invalidURL("Invalid API URL format: \(apiUrl). URL must be a valid HTTP/HTTPS URL.")
        }
        
        let platform = "ios"
        let type = fileType
        
        // Build metadata JSON
        let metadataDict: [String: Any] = [
            "type": type,
            "appVersion": appVersion,
            "versionCode": String(versionCode),
            "platform": platform,
            "fileName": fileName
        ]
        let metadataArray = [metadataDict]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadataArray)
        
        // Create multipart form data
        let boundary = "----WebKitFormBoundary\(Int(Date().timeIntervalSince1970 * 1000))"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60.0
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        // Build multipart body
        var body = Data()
        
        // Add metadata field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"metadata\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(metadataJSON)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"fileContent\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        
        // Read and append file data
        let fileData = try Data(contentsOf: fileURL)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        
        // Use URLSession.shared which has proper network permissions in SPM plugins
        // Perform upload - use async/await with proper error handling
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PulseUploadError.uploadFailed("Invalid response type")
            }
            
            let statusCode = httpResponse.statusCode
            if statusCode < 200 || statusCode >= 300 {
                let errorMessage = String(data: data, encoding: .utf8) ?? "No error message available"
                print("   HTTP Status: \(statusCode)")
                print("   Response: \(errorMessage)")
                throw PulseUploadError.uploadFailed("Upload failed with HTTP \(statusCode): \(errorMessage)")
            }
            
            if debugMode {
                print("\nBackend Response:")
                print("   Status: \(statusCode)")
                if let responseString = String(data: data, encoding: .utf8), !responseString.isEmpty {
                    print("   Response: \(responseString)")
                }
            }
        } catch let error as URLError {
            // Provide better error messages for common network issues
            if error.code == .notConnectedToInternet {
                throw PulseUploadError.uploadFailed("No internet connection available")
            } else if error.code == .cannotFindHost || error.code == .cannotConnectToHost {
                throw PulseUploadError.uploadFailed("Cannot connect to server at \(normalizedUrl). Make sure the server is running.")
            } else if error.code == .timedOut {
                throw PulseUploadError.uploadFailed("Request timed out. The server may be slow or unreachable.")
            } else {
                throw PulseUploadError.uploadFailed("Network error: \(error.localizedDescription)")
            }
        } catch {
            throw error
        }
    }
}
