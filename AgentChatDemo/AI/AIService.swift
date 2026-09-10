import Foundation

/// Whether a language model can service requests right now.
///
/// This is a UI-facing summary of the underlying framework's availability so
/// that `ConversationStore` and the views never import `FoundationModels`.
enum AIAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// Any other reason, with a short description for display/logging.
    case unavailable(String)

    var isAvailable: Bool { self == .available }

    /// A short sentence to show the user when generation is not possible.
    var userMessage: String? {
        switch self {
        case .available:
            nil
        case .deviceNotEligible:
            "This device doesn't support Apple Intelligence. Switch to the Mock AI from the debug menu."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to use the on-device model, or switch to the Mock AI."
        case .modelNotReady:
            "The on-device model is still downloading. Try again shortly or switch to the Mock AI."
        case .unavailable(let reason):
            "The on-device model is unavailable (\(reason)). Switch to the Mock AI from the debug menu."
        }
    }
}

/// Abstraction over "something that can stream an assistant reply".
///
/// ### Streaming contract
/// `streamResponse(to:)` yields **cumulative full-text snapshots**, not token
/// deltas. Each value is the complete assistant text generated so far; the last
/// value emitted before the stream finishes is the full response. Consumers
/// should *assign* the latest value, never concatenate.
///
/// ### Concurrency
/// Implementations are `Sendable` and free-threaded. They must not hop to the
/// main actor to do model work. Only one generation should be in flight per
/// service instance at a time; `ConversationStore` enforces this by disabling
/// send while `isGenerating` is true.
protocol AIService: Sendable {
    /// Current availability of the backing model.
    func availability() async -> AIAvailability

    /// Stream a reply to `prompt`. See the streaming contract above.
    ///
    /// Cancelling the consuming task (or the surrounding `Task`) stops the
    /// stream; implementations propagate cancellation to the model where the
    /// underlying framework allows it.
    nonisolated func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error>

    /// Drop any accumulated multi-turn context and start fresh.
    func resetConversation() async
}
