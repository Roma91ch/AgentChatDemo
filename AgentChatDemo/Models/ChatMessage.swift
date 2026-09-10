import Foundation

/// Who authored a message.
enum Role: Sendable, Equatable {
    case user
    case assistant
}

/// A single entry in the transcript.
///
/// The `id` is stable for the lifetime of the message and is the *only* thing
/// used to identify a row in the collection view. `content` and `status` are
/// mutated in place while an assistant message streams, but the `id` never
/// changes, which lets the diffable data source `reconfigure` a single cell
/// instead of reloading.
struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: Role
    var content: String
    var status: MessageStatus
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        status: MessageStatus,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.status = status
        self.createdAt = createdAt
    }
}

extension ChatMessage {
    static func user(_ text: String, createdAt: Date = .now) -> ChatMessage {
        ChatMessage(role: .user, content: text, status: .completed, createdAt: createdAt)
    }

    static func assistant(_ text: String, status: MessageStatus, createdAt: Date = .now) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, status: status, createdAt: createdAt)
    }
}
