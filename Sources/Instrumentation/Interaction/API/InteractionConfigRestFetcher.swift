/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// REST API implementation of InteractionConfigFetcher
/// Fetches interaction configurations from a remote server using URLSession
public class InteractionConfigRestFetcher: InteractionConfigFetcher {
    private let urlProvider: () -> String
    private let urlSession: URLSession

    public init(
        urlProvider: @escaping () -> String,
        urlSession: URLSession = .shared
    ) {
        self.urlProvider = urlProvider
        self.urlSession = urlSession
    }

    public func getConfigs() async throws -> [InteractionConfig]? {
        let urlString = urlProvider()
        guard let url = URL(string: urlString) else {
            return nil
        }

        let (data, response) = try await urlSession.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        // Check HTTP status code
        guard (200...299).contains(httpResponse.statusCode) else {
            // HTTP error - return nil (will be logged by InteractionManager)
            return nil
        }

        // Check Content-Type header to ensure it's JSON
        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           !contentType.contains("application/json") && !contentType.contains("text/json") {
            // Server returned non-JSON response (likely HTML error page or wrong endpoint)
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Expected JSON response but got Content-Type: \(contentType). URL might be incorrect or server returned error page."
                )
            )
        }

        // Try to decode JSON
        do {
            let apiResponse = try JSONDecoder().decode(
                ApiResponse<[InteractionConfig]>.self,
                from: data
            )

            // Return data only if there's no error
            if apiResponse.error == nil {
                return apiResponse.data
            } else {
                return nil
            }
        } catch {
            // Provide more context for JSON parsing errors
            let responsePreview = String(data: data.prefix(200), encoding: .utf8) ?? "<unable to decode>"
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Failed to decode JSON response. Response preview: \(responsePreview). Original error: \(error.localizedDescription). This might indicate the endpoint URL is incorrect or the server returned an error page."
                )
            )
        }
    }
}

