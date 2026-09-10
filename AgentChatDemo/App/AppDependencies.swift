import Foundation
import Observation

/// Owns the object graph and rebuilds it when the debug menu changes something
/// structural (AI source, seed size). This is the whole of our "DI" — no
/// framework, just a factory that hands `ChatScreen` a `ConversationStore`.
@MainActor
@Observable
final class AppDependencies {
    enum Mode: Hashable {
        case mock
        case foundationModels
    }

    private(set) var store: ConversationStore
    private(set) var mode: Mode
    private var seedCount: Int

    init(mode: Mode = .mock, seedCount: Int = 300) {
        self.mode = mode
        self.seedCount = seedCount
        self.store = AppDependencies.makeStore(mode: mode, seedCount: seedCount)
    }

    func switchTo(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        rebuild()
    }

    func seed(_ count: Int) {
        seedCount = count
        rebuild()
    }

    func clearConversation() {
        seedCount = 0
        rebuild()
    }

    private func rebuild() {
        // Swapping the instance is enough: `ChatScreen`'s `.task(id:)` keys on
        // the store's identity and re-bootstraps the new one.
        store = AppDependencies.makeStore(mode: mode, seedCount: seedCount)
    }

    private static func makeStore(mode: Mode, seedCount: Int) -> ConversationStore {
        let repository = InMemoryMessageRepository.demoSeeded(messageCount: seedCount)
        let ai: AIService = switch mode {
        case .mock: MockAIService()
        case .foundationModels: FoundationModelsAIService()
        }
        return ConversationStore(repository: repository, ai: ai)
    }
}
