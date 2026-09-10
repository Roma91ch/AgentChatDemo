import Foundation

/// A conversation groups a transcript and scopes persistence.
///
/// The demo only ever shows one conversation at a time, but modelling it
/// explicitly keeps `MessageRepository` honest: it stores messages *for a
/// conversation*, which is what a real multi-conversation app would need.
struct Conversation: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date

    init(id: UUID = UUID(), title: String = "Agent Chat", createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }

    static let demo = Conversation(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000DE")!,
        title: "Agent Chat"
    )
}
