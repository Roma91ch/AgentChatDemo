import Foundation

/// Deterministic streaming AI used for previews, the Simulator, tests, and any
/// device where Foundation Models is unavailable.
///
/// It emits cumulative snapshots word-by-word with a small delay between each,
/// matching the `AIService` streaming contract, and honours cancellation.
nonisolated final class MockAIService: AIService {
    let reply: String
    let chunkDelay: Duration

    /// - Parameters:
    ///   - reply: the full text the mock will "generate".
    ///   - chunkDelayMilliseconds: delay between snapshots (50–150ms is realistic).
    init(
        reply: String = "This is a streamed response.",
        chunkDelayMilliseconds: Int = 90
    ) {
        self.reply = reply
        self.chunkDelay = .milliseconds(chunkDelayMilliseconds)
    }

    func availability() async -> AIAvailability { .available }

    func resetConversation() async {}

    nonisolated func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        let reply = self.reply
        let delay = self.chunkDelay

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var accumulated = ""
                    for word in reply.split(separator: " ") {
                        try Task.checkCancellation()
                        try await Task.sleep(for: delay)
                        accumulated += accumulated.isEmpty ? String(word) : " " + word
                        continuation.yield(accumulated)
                    }
                    continuation.finish()
                } catch {
                    // Cancellation lands here as CancellationError; forward it so
                    // the consumer's `for try await` throws and the store can
                    // mark the message `.cancelled`.
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
