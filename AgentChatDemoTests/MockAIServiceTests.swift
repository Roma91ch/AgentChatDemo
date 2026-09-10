import Testing
import Foundation
import Synchronization
@testable import AgentChatDemo

@Suite("MockAIService")
struct MockAIServiceTests {

    @Test("emits cumulative snapshots, not deltas")
    func emitsCumulativeSnapshots() async throws {
        let service = MockAIService(reply: "This is a streamed response.", chunkDelayMilliseconds: 5)

        var snapshots: [String] = []
        for try await snapshot in service.streamResponse(to: "hi") {
            snapshots.append(snapshot)
        }

        #expect(snapshots == [
            "This",
            "This is",
            "This is a",
            "This is a streamed",
            "This is a streamed response.",
        ])
    }

    @Test("respects cancellation and stops emitting")
    func respectsCancellation() async throws {
        let service = MockAIService(reply: "one two three four five six", chunkDelayMilliseconds: 40)

        let collected = Mutex<[String]>([])
        let task = Task {
            do {
                for try await snapshot in service.streamResponse(to: "hi") {
                    collected.withLock { $0.append(snapshot) }
                }
            } catch {
                // CancellationError is expected here.
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await task.value

        let count = collected.withLock { $0.count }
        #expect(count >= 1)
        #expect(count < 6, "cancellation should stop the stream before completion")
    }
}
