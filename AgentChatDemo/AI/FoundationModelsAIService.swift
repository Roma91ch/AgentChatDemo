import Foundation
import FoundationModels

/// `AIService` backed by Apple's on-device model via `FoundationModels`.
///
/// This is the only file that imports `FoundationModels`. Everything above it
/// (the store, the views) works purely against `AIService` / `AIAvailability`.
///
/// It is an `actor` so that:
///  * the `LanguageModelSession` (a reference type used across turns for
///    multi-turn context) never escapes to another isolation domain, and
///  * generations are naturally serialized — `LanguageModelSession` only
///    supports one active request at a time, and the actor makes that a
///    structural guarantee rather than a convention.
actor FoundationModelsAIService: AIService {
    private let instructions: String
    private var session: LanguageModelSession

    init(instructions: String = FoundationModelsAIService.defaultInstructions) {
        self.instructions = instructions
        self.session = LanguageModelSession(
            tools: [LocalKnowledgeTool()],
            instructions: instructions
        )
    }

    static let defaultInstructions = """
    You are the assistant inside "AgentChatDemo", a sample iOS app that shows \
    how to build a streaming chat experience. Keep answers short and concrete. \
    When the user asks how this app is built — its UI, architecture, streaming, \
    cancellation, or pagination — call the searchDemoKnowledge tool and answer \
    from what it returns.
    """

    func availability() async -> AIAvailability {
        Self.map(SystemLanguageModel.default.availability)
    }

    func resetConversation() async {
        session = LanguageModelSession(tools: [LocalKnowledgeTool()], instructions: instructions)
    }

    nonisolated func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(prompt: prompt, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Actor-isolated: touches `session`. Bridges the framework's snapshot
    /// stream onto our cumulative-snapshot `AsyncThrowingStream<String, Error>`.
    private func runStream(
        prompt: String,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let responseStream = session.streamResponse(to: prompt)
        for try await snapshot in responseStream {
            try Task.checkCancellation()
            // Each snapshot is the full text generated so far.
            continuation.yield(snapshot.content)
        }
    }

    private static func map(_ availability: SystemLanguageModel.Availability) -> AIAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .unavailable(String(describing: reason))
            }
        @unknown default:
            return .unavailable("unknown")
        }
    }
}
