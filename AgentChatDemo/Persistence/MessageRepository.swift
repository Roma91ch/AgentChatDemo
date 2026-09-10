import Foundation

/// One page of transcript history, in chronological (oldest-first) order.
struct MessagePage: Sendable, Equatable {
    /// Messages, ascending by `createdAt`.
    var messages: [ChatMessage]
    /// True if there is still older history before `messages.first`.
    var hasMore: Bool

    static let empty = MessagePage(messages: [], hasMore: false)
}

/// Persistence boundary for the transcript.
///
/// This is deliberately tiny. Today it is backed by `InMemoryMessageRepository`;
/// swapping in SwiftData or SQLite later means writing one more conformer and
/// changing nothing in `ConversationStore`.
///
/// Note: this stores the *UI transcript*. It is a separate concern from the
/// model's conversational context, which `LanguageModelSession` owns. A
/// transcript of 10,000 messages does not mean 10,000 messages sent to the model.
protocol MessageRepository: Sendable {
    /// Most recent `limit` messages, ascending.
    func loadLatest(limit: Int) async -> MessagePage

    /// Up to `limit` messages immediately older than `messageID`, ascending.
    func loadBefore(messageID: UUID, limit: Int) async -> MessagePage

    /// Append a newly created message.
    func save(_ message: ChatMessage) async

    /// Persist an in-place change (streamed content, final status).
    func update(_ message: ChatMessage) async
}
