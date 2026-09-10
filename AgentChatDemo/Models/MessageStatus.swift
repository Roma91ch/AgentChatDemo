import Foundation

/// Lifecycle of a single message.
///
/// `.failed` carries a short, user-presentable reason string so the UI can render
/// it without needing to hold on to the original `Error`.
enum MessageStatus: Sendable, Equatable {
    case sending
    case streaming
    case completed
    case cancelled
    case failed(String)
}

extension MessageStatus {
    /// True while the message is still expected to change.
    var isTerminal: Bool {
        switch self {
        case .sending, .streaming: false
        case .completed, .cancelled, .failed: true
        }
    }
}
