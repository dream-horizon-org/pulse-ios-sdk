import Foundation

// MARK: - Error Types

enum PulseUploadError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case fileNotFound(String)
    case invalidFile(String)
    case invalidURL(String)
    case uploadFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .missingArgument(let message):
            return message
        case .invalidArgument(let message):
            return message
        case .fileNotFound(let message):
            return message
        case .invalidFile(let message):
            return message
        case .invalidURL(let message):
            return message
        case .uploadFailed(let message):
            return message
        }
    }
}
