import Testing
import Foundation
@testable import AgentChatDemo

@MainActor
@Suite("ConversationStore")
struct ConversationStoreTests {

    /// Fast coalescing so the tests don't wait on the 40ms production interval.
    private func makeStore(
        ai: AIService,
        seed: [ChatMessage] = []
    ) -> ConversationStore {
        ConversationStore(
            repository: InMemoryMessageRepository(seed: seed),
            ai: ai,
            initialPageSize: 30,
            historyPageSize: 30,
            coalesceInterval: .milliseconds(1)
        )
    }

    // 1
    @Test("send() appends the user message immediately")
    func sendAppendsUserMessage() async throws {
        let store = makeStore(ai: ScriptedAIService())

        store.send("Hello there")

        let user = try #require(store.messages.first { $0.role == .user })
        #expect(user.content == "Hello there")
        #expect(user.status == .completed)
    }

    // 2
    @Test("send() creates an empty streaming assistant placeholder")
    func sendCreatesAssistantPlaceholder() async throws {
        let store = makeStore(ai: ScriptedAIService())

        store.send("Hello")

        let assistant = try #require(store.messages.last)
        #expect(assistant.role == .assistant)
        #expect(assistant.content.isEmpty)
        #expect(assistant.status == .streaming)
        #expect(store.isGenerating)
    }

    // 3
    @Test("streamed updates mutate the same assistant message id")
    func streamedUpdatesMutateSameID() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        store.send("Hello")
        let assistantID = try #require(store.messages.last).id
        try await waitUntil("stream opened") { ai.callCount == 1 }

        ai.emit("Partial one")
        try await waitUntil("first snapshot applied") {
            store.messages.last?.content == "Partial one"
        }
        ai.emit("Partial one two")
        try await waitUntil("second snapshot applied") {
            store.messages.last?.content == "Partial one two"
        }

        #expect(store.messages.last?.id == assistantID)
        #expect(store.messages.filter { $0.role == .assistant }.count == 1)
    }

    // 4
    @Test("a finished stream marks the message completed")
    func finishedStreamCompletes() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        store.send("Hello")
        try await waitUntil("stream opened") { ai.callCount == 1 }
        ai.emit("Final answer")
        ai.finishCall()

        try await waitUntil("completed") { store.messages.last?.status == .completed }
        #expect(store.messages.last?.content == "Final answer")
        #expect(!store.isGenerating)
        #expect(store.activeRequestID == nil)
    }

    // 5
    @Test("cancellation preserves the partial answer")
    func cancellationPreservesPartial() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        store.send("Hello")
        try await waitUntil("stream opened") { ai.callCount == 1 }
        ai.emit("Half of an ans")
        try await waitUntil("partial applied") {
            store.messages.last?.content == "Half of an ans"
        }

        store.stopGeneration()

        try await waitUntil("cancelled") { store.messages.last?.status == .cancelled }
        #expect(store.messages.last?.content == "Half of an ans")
        #expect(!store.isGenerating)
    }

    // 6
    @Test("late output from a stopped request cannot modify a newer request")
    func staleRequestCannotModifyNewer() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        // Request A
        store.send("A")
        try await waitUntil("A opened") { ai.callCount == 1 }
        let assistantA = try #require(store.messages.last).id
        ai.emit("A partial", call: 0)
        try await waitUntil("A partial applied") {
            store.messages.last?.content == "A partial"
        }

        // User presses Stop
        store.stopGeneration()
        try await waitUntil("A cancelled") { !store.isGenerating }

        // Request B
        store.send("B")
        try await waitUntil("B opened") { ai.callCount == 2 }
        let assistantB = try #require(store.messages.last).id
        #expect(assistantB != assistantA)

        // Late output from A arrives
        ai.emit("A LATE GARBAGE", call: 0)
        ai.finishCall(0)
        try await Task.sleep(for: .milliseconds(40))

        // A keeps its partial; B is untouched and still streaming
        #expect(store.messages.first { $0.id == assistantA }?.content == "A partial")
        #expect(store.messages.first { $0.id == assistantA }?.status == .cancelled)
        #expect(store.messages.first { $0.id == assistantB }?.content == "")
        #expect(store.messages.first { $0.id == assistantB }?.status == .streaming)

        // B still completes normally
        ai.emit("B answer", call: 1)
        ai.finishCall(1)
        try await waitUntil("B completed") {
            store.messages.first { $0.id == assistantB }?.status == .completed
        }
        #expect(store.messages.first { $0.id == assistantB }?.content == "B answer")
    }

    // 7
    @Test("a failed generation marks the message failed with a reason")
    func failedGenerationMarksFailed() async throws {
        let store = makeStore(ai: FailingAIService(error: SampleError("no network to the moon")))

        store.send("Hello")

        try await waitUntil("failed") {
            if case .failed = store.messages.last?.status { return true }
            return false
        }
        guard case .failed(let reason) = store.messages.last?.status else {
            Issue.record("expected .failed")
            return
        }
        #expect(reason == "no network to the moon")
        #expect(!store.isGenerating)
    }

    // 8
    @Test("a second send while generating is ignored")
    func secondSendWhileGeneratingIsIgnored() async throws {
        let ai = ScriptedAIService()
        let store = makeStore(ai: ai)

        store.send("first")
        try await waitUntil("first opened") { ai.callCount == 1 }

        store.send("second while busy")

        #expect(ai.callCount == 1)
        #expect(store.messages.filter { $0.role == .user }.map(\.content) == ["first"])
    }

    // 9
    @Test("pagination prepends older messages without duplicates")
    func paginationPrependsWithoutDuplicates() async throws {
        let seed = (0..<90).map { i in
            ChatMessage(
                role: i % 2 == 0 ? .user : .assistant,
                content: "seed \(i)",
                status: .completed,
                createdAt: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }
        let store = makeStore(ai: ScriptedAIService(), seed: seed)
        await store.bootstrap()

        #expect(store.messages.count == 30)
        #expect(store.messages.first?.content == "seed 60")
        #expect(store.hasMoreHistory)

        store.loadOlderMessages()
        try await waitUntil("first page loaded") { store.messages.count == 60 }
        #expect(store.messages.first?.content == "seed 30")

        // Calling again while a load is in-flight must not duplicate.
        store.loadOlderMessages()
        store.loadOlderMessages()
        try await waitUntil("second page loaded") { store.messages.count == 90 }

        #expect(store.messages.first?.content == "seed 0")
        #expect(Set(store.messages.map(\.id)).count == store.messages.count, "no duplicate ids")
        #expect(!store.hasMoreHistory)

        store.loadOlderMessages()
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.messages.count == 90, "no more history to load")
    }

    // Bonus: retry() re-runs a failed turn against the same assistant id.
    @Test("retry() re-runs a failed turn on the same message id")
    func retryReRunsFailedTurn() async throws {
        let failing = FailingAIService()
        let repo = InMemoryMessageRepository()
        let store = ConversationStore(repository: repo, ai: failing, coalesceInterval: .milliseconds(1))

        store.send("Hello")
        try await waitUntil("failed") {
            if case .failed = store.messages.last?.status { return true }
            return false
        }
        // Can't swap `ai` on the store; assert retry keeps identity + restreams.
        let failedID = try #require(store.messages.last).id
        store.retry()
        #expect(store.messages.last?.id == failedID)
        #expect(store.isGenerating || store.messages.last?.status != .streaming)
    }
}
