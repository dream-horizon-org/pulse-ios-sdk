import Foundation

// MARK: - Metadata Model

struct PulseUploadMetadata: Codable {
    let type: String
    let appVersion: String
    let versionCode: String
    let platform: String
    let fileName: String
}
