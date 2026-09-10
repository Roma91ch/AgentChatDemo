import Foundation

/// In-memory `MessageRepository`.
///
/// An `actor` because it holds mutable state (`messages`) that the store touches
/// from the main actor while generation tasks touch it from background tasks.
actor InMemoryMessageRepository: MessageRepository {
    /// Full history, ascending by `createdAt`.
    private var messages: [ChatMessage]

    init(seed: [ChatMessage] = []) {
        self.messages = seed.sorted { $0.createdAt < $1.createdAt }
    }

    func loadLatest(limit: Int) async -> MessagePage {
        let slice = messages.suffix(limit)
        return MessagePage(
            messages: Array(slice),
            hasMore: messages.count > slice.count
        )
    }

    func loadBefore(messageID: UUID, limit: Int) async -> MessagePage {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return .empty
        }
        let lowerBound = max(0, index - limit)
        return MessagePage(
            messages: Array(messages[lowerBound..<index]),
            hasMore: lowerBound > 0
        )
    }

    func save(_ message: ChatMessage) async {
        messages.append(message)
    }

    func update(_ message: ChatMessage) async {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index] = message
    }
}

extension InMemoryMessageRepository {
    /// A repository pre-populated with `messageCount` fake messages so that
    /// collection-view reuse and pagination can actually be exercised.
    ///
    /// Only the most recent page is ever loaded at startup — the rest sits here
    /// until the user scrolls back far enough.
    static func demoSeeded(messageCount: Int) -> InMemoryMessageRepository {
        guard messageCount > 0 else { return InMemoryMessageRepository() }

        let now = Date.now
        let prompts = [
            "What UI technology does this demo use for the chat timeline?",
            "Why not just use a SwiftUI List?",
            "How does streaming work here?",
            "What happens when I press Stop mid-answer?",
            "How is scroll position kept when older messages load?",
            "Tell me about the architecture.",
            "How does tool calling work?",
        ]
        let replies = [
            "The transcript is a UIKit UICollectionView with a diffable data source, so cells are reused and scrolling stays precise.",
            "A LazyVStack rebuilds and re-measures aggressively; a UICollectionView gives explicit reuse and layout control for a long, changing history.",
            "The service yields cumulative text snapshots; the store assigns the latest one to the same assistant message ID.",
            "The generation task is cancelled, the partial answer is kept, and the message is marked cancelled.",
            "Older pages are prepended and the content offset is adjusted by the height delta so nothing jumps.",
            "SwiftUI shell, UIKit timeline, a @MainActor @Observable ConversationStore as the source of truth, and an AIService abstraction.",
            "The model calls the LocalKnowledgeTool, gets fact lines back, then writes the final answer.",
        ]

        var seed: [ChatMessage] = []
        seed.reserveCapacity(messageCount)
        for i in 0..<messageCount {
            let isUser = i % 2 == 0
            // Oldest message is the furthest in the past.
            let createdAt = now.addingTimeInterval(TimeInterval(i - messageCount) * 30)
            if isUser {
                seed.append(
                    ChatMessage(
                        role: .user,
                        content: "\(prompts[(i / 2) % prompts.count]) (#\(i + 1))",
                        status: .completed,
                        createdAt: createdAt
                    )
                )
            } else {
                seed.append(
                    ChatMessage(
                        role: .assistant,
                        content: replies[(i / 2) % replies.count],
                        status: .completed,
                        createdAt: createdAt
                    )
                )
            }
        }
        return InMemoryMessageRepository(seed: seed)
    }
}
