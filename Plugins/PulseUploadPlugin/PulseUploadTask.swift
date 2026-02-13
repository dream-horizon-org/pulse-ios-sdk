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
        let normalizedUrl = PulseUploadUtils.normalizeURL(apiUrl)
        
        guard let url = URL(string: normalizedUrl),
              let scheme = url.scheme,
              url.host != nil,
              (scheme == "http" || scheme == "https") else {
            throw PulseUploadError.invalidURL("Invalid API URL: \(apiUrl)")
        }
        
        let boundary = "----WebKitFormBoundary\(Int(Date().timeIntervalSince1970 * 1000))"
        
        let metadata: [String: Any] = [
            "type": fileType,
            "appVersion": appVersion,
            "versionCode": String(versionCode),
            "platform": "ios",
            "fileName": fileName
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: [metadata])
        
        let bodyFileURL = try createMultipartBodyFile(
            boundary: boundary,
            metadataJSON: metadataJSON,
            fileURL: fileURL,
            fileName: fileName
        )
        
        defer {
            try? FileManager.default.removeItem(at: bodyFileURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300.0
        
        let (data, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = URLSession.shared.uploadTask(with: request, fromFile: bodyFileURL) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = data, let response = response else {
                    continuation.resume(throwing: PulseUploadError.uploadFailed("No data or response received"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PulseUploadError.uploadFailed("Invalid response type")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "No error message"
            print("   HTTP Status: \(httpResponse.statusCode)")
            print("   Response: \(errorMessage)")
            throw PulseUploadError.uploadFailed("Upload failed with HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        
        if debugMode {
            print("\nBackend Response:")
            print("   Status: \(httpResponse.statusCode)")
            if let responseString = String(data: data, encoding: .utf8), !responseString.isEmpty {
                print("   Response: \(responseString)")
            }
        }
    }
    
    /// Create multipart body file by streaming data (memory-efficient for large files)
    private static func createMultipartBodyFile(
        boundary: String,
        metadataJSON: Data,
        fileURL: URL,
        fileName: String
    ) throws -> URL {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).tmp")
        
        guard let outputStream = OutputStream(url: tempFile, append: false) else {
            throw PulseUploadError.uploadFailed("Failed to create temporary file")
        }
        
        outputStream.open()
        defer { outputStream.close() }
        
        func write(_ string: String) throws {
            guard let data = string.data(using: .utf8) else {
                throw PulseUploadError.uploadFailed("Failed to encode string")
            }
            try write(data)
        }
        
        func write(_ data: Data) throws {
            let written = data.withUnsafeBytes {
                outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
            }
            guard written == data.count else {
                throw PulseUploadError.uploadFailed("Failed to write data")
            }
        }
        
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"metadata\"\r\n")
        try write("Content-Type: application/json\r\n\r\n")
        try write(metadataJSON)
        try write("\r\n")
        
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"fileContent\"; filename=\"\(fileName)\"\r\n")
        try write("Content-Type: application/octet-stream\r\n\r\n")
        
        guard let inputStream = InputStream(url: fileURL) else {
            throw PulseUploadError.uploadFailed("Failed to open file")
        }
        
        inputStream.open()
        defer { inputStream.close() }
        
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { buffer.deallocate() }
        
        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(buffer, maxLength: 65536)
            if bytesRead < 0 {
                if let error = inputStream.streamError {
                    throw PulseUploadError.uploadFailed("Error reading file: \(error.localizedDescription)")
                }
                throw PulseUploadError.uploadFailed("Error reading file")
            }
            if bytesRead == 0 { break }
            try write(Data(bytes: buffer, count: bytesRead))
        }
        
        try write("\r\n--\(boundary)--\r\n")
        
        return tempFile
    }
}
