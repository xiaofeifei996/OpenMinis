import Foundation

/// Minimal stand-in for the app error type while compiling the two real wire
/// files outside the Xcode target. Its message is intentionally not asserted:
/// the regression suite checks classification/control flow, never vendor text.
enum LLMError: LocalizedError {
    case providerError(message: String)

    var errorDescription: String? {
        switch self {
        case .providerError(let message): return message
        }
    }
}
