import Foundation
import Synchronization
@testable import AgentChatDemo

// MARK: - Async polling

enum WaitError: Error, CustomStringConvertible {
    case timedOut(String)
    var description: String {
        switch self { case .timedOut(let what): "Timed out waiting for: \(what)" }
    }
}

/// Poll `condition` on the main actor until it's true or `timeout` elapses.
/// Used instead of fixed sleeps so tests stay fast and non-flaky.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(8))
    }
    if condition() { return }
    throw WaitError.timedOut(description)
}

// MARK: - Scripted AI service

/// An `AIService` whose streams are driven entirely by the test. Each call to
/// `streamResponse(to:)` opens a new channel identified by its index.
nonisolated final class ScriptedAIService: AIService {
    private let continuations = Mutex<[AsyncThrowingStream<String, Error>.Continuation]>([])
    private let prompts = Mutex<[String]>([])
    private let availabilityValue: AIAvailability

    init(availability: AIAvailability = .available) {
        self.availabilityValue = availability
    }

    func availability() async -> AIAvailability { availabilityValue }
    func resetConversation() async {}

    nonisolated func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            prompts.withLock { $0.append(prompt) }
            continuations.withLock { $0.append(continuation) }
        }
    }

    var callCount: Int { continuations.withLock { $0.count } }
    func prompt(at index: Int) -> String { prompts.withLock { $0[index] } }

    func emit(_ text: String, call index: Int = 0) {
        continuations.withLock { $0[index] }.yield(text)
    }
    func finishCall(_ index: Int = 0) {
        continuations.withLock { $0[index] }.finish()
    }
    func failCall(_ index: Int = 0, error: Error) {
        continuations.withLock { $0[index] }.finish(throwing: error)
    }
}

// MARK: - Always-fails AI service

struct SampleError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}

nonisolated final class FailingAIService: AIService {
    let error: Error
    init(error: Error = SampleError("model exploded")) { self.error = error }

    func availability() async -> AIAvailability { .available }
    func resetConversation() async {}

    nonisolated func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        let error = self.error
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}
