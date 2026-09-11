import Testing
import Foundation
import Synchronization
@testable import AgentChatDemo

/// Focused coverage of streaming + the Swift Concurrency edges around it:
/// the coalescing timer, the flush-vs-finish race, cancellation timing, and
/// `AsyncThrowingStream` mechanics. Drives the store with `ScriptedAIService`
/// so every snapshot boundary is deterministic.
@MainActor
@Suite("Streaming")
struct StreamingTests {

    private func makeStore(
        ai: AIService,
        coalesceInterval: Duration = .milliseconds(1)
    ) -> ConversationStore {
        ConversationStore(
            repository: InMemoryMessageRepository(seed: []),
            ai: ai,
            coalesceInterval: coalesceInterval
        )
    }

    // 1
    @Test("the store assigns each snapshot, it never concatenates them")
    func assignsSnapshotsNeverConcatenates() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        store.send("hi")
        try await waitUntil("stream opened") { ai.callCount == 1 }

        ai.emit("H")
        ai.emit("He")
        ai.emit("Hello")
        ai.finishCall()

        try await waitUntil("completed") { store.messages.last?.status == .completed }
        #expect(store.messages.last?.content == "Hello")
        #expect(store.messages.filter { $0.role == .assistant }.count == 1)
    }

    // 2
    @Test("a burst of snapshots is held, then flushed to the latest value")
    func coalescingHoldsBurstThenFlushesLatest() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai, coalesceInterval: .milliseconds(150))

        store.send("hi")
        try await waitUntil("stream opened") { ai.callCount == 1 }

        ai.emit("a")
        try await Task.sleep(for: .milliseconds(30))
        // Well inside the 150ms window: the update is pending, not yet applied.
        #expect(store.messages.last?.content == "")

        ai.emit("b")
        ai.emit("c")

        try await waitUntil("flushed to latest") { store.messages.last?.content == "c" }
    }

    // 3
    @Test("the coalescer re-arms after each flush")
    func coalescerReArmsAfterFlush() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai, coalesceInterval: .milliseconds(120))

        store.send("hi")
        try await waitUntil("stream opened") { ai.callCount == 1 }

        ai.emit("first")
        try await waitUntil("first flush") { store.messages.last?.content == "first" }

        ai.emit("second")
        try await waitUntil("second flush") { store.messages.last?.content == "second" }
    }

    // 4
    @Test("an empty stream completes cleanly")
    func emptyStreamCompletes() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        store.send("hi")
        try await waitUntil("stream opened") { ai.callCount == 1 }
        ai.finishCall()

        try await waitUntil("completed") { store.messages.last?.status == .completed }
        #expect(store.messages.last?.content == "")
        #expect(!store.isGenerating)
        #expect(store.activeRequestID == nil)
    }

    // 5
    @Test("a failure after partial output keeps the partial text")
    func failureAfterPartialKeepsText() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        store.send("hi")
        try await waitUntil("stream opened") { ai.callCount == 1 }

        ai.emit("partway")
        try await waitUntil("partial applied") { store.messages.last?.content == "partway" }
        ai.failCall(error: SampleError("boom"))

        try await waitUntil("failed") {
            if case .failed = store.messages.last?.status { return true }
            return false
        }
        #expect(store.messages.last?.status == .failed("boom"))
        #expect(store.messages.last?.content == "partway")
        #expect(!store.isGenerating)
    }

    // 6
    @Test("cancelling before the first snapshot yields .cancelled with empty text")
    func cancelBeforeFirstSnapshot() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        store.send("hi")
        #expect(store.isGenerating)
        store.stopGeneration()

        try await waitUntil("cancelled") { store.messages.last?.status == .cancelled }
        #expect(store.messages.last?.content == "")
        #expect(!store.isGenerating)
        #expect(store.activeRequestID == nil)
    }

    // 7
    @Test("a pending flush cannot overwrite a message that already finished")
    func lateFlushCannotOverwriteFinished() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai, coalesceInterval: .milliseconds(120))

        store.send("hi")
        try await waitUntil("stream opened") { ai.callCount == 1 }

        ai.emit("early")     // schedules a flush ~120ms out
        ai.finishCall()      // finish() runs first and cancels that flush

        try await waitUntil("completed") { store.messages.last?.status == .completed }
        // Give the (cancelled) flush its full window to prove it never lands.
        try await Task.sleep(for: .milliseconds(200))

        #expect(store.messages.last?.content == "early")
        #expect(store.messages.last?.status == .completed)
        #expect(!store.isGenerating)
    }

    // 8
    @Test("stopGeneration is safe when idle and when called twice")
    func stopGenerationIsSafe() async throws {
        // Idle: no-op, no crash, no state change.
        let idleStore = makeStore(ai: ScriptedAIService())
        idleStore.stopGeneration()
        #expect(!idleStore.isGenerating)
        #expect(idleStore.messages.isEmpty)

        // Double-stop during generation: still exactly one .cancelled, clean idle.
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)
        store.send("hi")
        try await waitUntil("stream opened") { ai.callCount == 1 }
        ai.emit("half")
        try await waitUntil("partial applied") { store.messages.last?.content == "half" }

        store.stopGeneration()
        store.stopGeneration()

        try await waitUntil("cancelled") { store.messages.last?.status == .cancelled }
        #expect(store.messages.last?.content == "half")
        #expect(!store.isGenerating)
        #expect(store.activeRequestID == nil)
        #expect(store.messages.filter { $0.role == .assistant }.count == 1)
    }

    // 9
    @Test("a stale continuation from a retried request is ignored")
    func staleContinuationOnRetryIsIgnored() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        store.send("q")
        try await waitUntil("first stream") { ai.callCount == 1 }
        ai.emit("x")
        ai.failCall(error: SampleError("boom"))
        try await waitUntil("failed") {
            if case .failed = store.messages.last?.status { return true }
            return false
        }

        store.retry()
        try await waitUntil("retry stream") { ai.callCount == 2 }
        #expect(store.isGenerating)

        // Late output on the first (dead, superseded) channel must not land.
        ai.emit("STALE", call: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.messages.last?.content != "STALE")

        ai.emit("fresh", call: 1)
        ai.finishCall(1)
        try await waitUntil("retry completed") { store.messages.last?.status == .completed }
        #expect(store.messages.last?.content == "fresh")
    }

    // 10
    @Test("MockAIService cancels its producer when the consumer task is cancelled")
    func mockCancelsProducerFromDetachedConsumer() async throws {
        let service = MockAIService(
            reply: "one two three four five six",
            chunkDelayMilliseconds: 40
        )
        let collected = Mutex<[String]>([])

        // Detached: no inherited isolation — also exercises stream Sendability.
        let consumer = Task.detached {
            do {
                for try await snapshot in service.streamResponse(to: "hi") {
                    collected.withLock { $0.append(snapshot) }
                }
            } catch {
                // CancellationError expected.
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        await consumer.value

        let count = collected.withLock { $0.count }
        #expect(count >= 1)
        #expect(count < 6, "producer should stop before the full reply is emitted")
    }
}
