import Foundation
import FoundationModels

/// A single deterministic `Tool` that lets the model look things up in a small,
/// immutable set of facts about this app.
///
/// Flow this demonstrates:
///
///     user question
///        -> language model decides it needs facts
///        -> model calls searchDemoKnowledge(query:)
///        -> this tool returns matching fact lines
///        -> model composes the final answer
///
/// The tool loop itself is handled by `LanguageModelSession`; there is no manual
/// agent loop.
struct LocalKnowledgeTool: Tool {
    let name = "searchDemoKnowledge"
    let description = """
    Search an internal knowledge base of facts about how the AgentChatDemo app \
    is built: its UI technology, architecture, streaming, cancellation, and \
    pagination. Returns the most relevant fact lines.
    """

    @Generable
    struct Arguments {
        @Guide(description: "A short natural-language description of what to look up about the app.")
        var query: String
    }

    /// Immutable knowledge base.
    static let facts: [String] = [
        "The chat timeline is rendered with a UIKit UICollectionView driven by a UICollectionViewDiffableDataSource, for explicit cell reuse and precise scrolling.",
        "The app shell, navigation stack, empty/error states, and the message composer are built in SwiftUI.",
        "A LazyVStack was intentionally not used for the transcript, because a large, continuously mutating history benefits from UICollectionView cell reuse and layout control.",
        "The on-device AI uses Apple's Foundation Models framework via SystemLanguageModel.default and a single LanguageModelSession per conversation.",
        "Streaming updates keep a stable per-message UUID; only the changed assistant cell is reconfigured, never a full reload.",
        "Generation can be stopped with the Stop button; the partial answer is kept and the message is marked cancelled.",
        "Stale-stream protection tags every generation with a unique request ID and ignores output whose request ID is not the active one.",
        "Older history is paged in from a repository 30 messages at a time, and the scroll position is preserved when messages are prepended.",
        "ConversationStore is the single source of truth; the collection view is only a renderer and owns no business state.",
    ]

    func call(arguments: Arguments) async throws -> String {
        let tokens = arguments.query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }

        let scored = Self.facts
            .map { fact -> (fact: String, score: Int) in
                let haystack = fact.lowercased()
                let score = tokens.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
                return (fact, score)
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        let hits = scored.isEmpty ? Array(Self.facts.prefix(3)) : scored.prefix(3).map(\.fact)
        return hits.joined(separator: "\n")
    }
}
