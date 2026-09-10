import Foundation
import Observation

/// The single source of truth for a conversation.
///
/// It owns the transcript, the generation `Task`, and all the state the UI
/// binds to. The SwiftUI views and the UIKit timeline are both pure renderers of
/// what lives here. Foundation Models is never touched directly by a view.
@MainActor
@Observable
final class ConversationStore {

    // MARK: Dependencies

    private let repository: MessageRepository
    private let ai: AIService
    private let initialPageSize: Int
    private let historyPageSize: Int
    /// How long streamed snapshots are batched before touching `messages`.
    /// Kept in the 30–60ms range so the collection view isn't asked to diff on
    /// every tiny model update. Injectable so tests can drop it to ~0.
    private let coalesceInterval: Duration

    // MARK: Observable state

    private(set) var messages: [ChatMessage] = []
    private(set) var availability: AIAvailability = .available
    private(set) var isGenerating = false
    private(set) var isLoadingOlderMessages = false
    private(set) var hasMoreHistory = true

    /// Identifies the generation currently allowed to mutate the transcript.
    /// Late output from a superseded request is discarded by comparing against
    /// this. `nil` when idle.
    private(set) var activeRequestID: UUID?

    /// Two-way bound by the composer.
    var draft: String = ""

    var canSend: Bool {
        !isGenerating
        && availability.isAvailable
        && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Generation internals

    private var generationTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingContent: String?
    private var pendingAssistantID: UUID?

    /// Tail of a chain that serializes every repository write in submission
    /// order, so a `save` can never land after the `update` that supersedes it.
    private var persistenceTail: Task<Void, Never>?

    // MARK: Init

    init(
        repository: MessageRepository,
        ai: AIService,
        initialPageSize: Int = 30,
        historyPageSize: Int = 30,
        coalesceInterval: Duration = .milliseconds(40)
    ) {
        self.repository = repository
        self.ai = ai
        self.initialPageSize = initialPageSize
        self.historyPageSize = historyPageSize
        self.coalesceInterval = coalesceInterval
    }

    // MARK: Lifecycle

    /// Load the newest page and probe model availability. Safe to call again.
    func bootstrap() async {
        availability = await ai.availability()
        let page = await repository.loadLatest(limit: initialPageSize)
        messages = page.messages
        hasMoreHistory = page.hasMore
    }

    // MARK: Sending

    func send() {
        send(draft)
    }

    /// 1. validate, 2. append user message, 3. append empty streaming assistant
    /// message, 4. mint a request ID, 5. start streaming into *that* message.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Contract: a second send while generating is ignored. The UI also
        // disables the button, this is the backstop.
        guard !isGenerating else { return }
        guard availability.isAvailable else { return }

        draft = ""

        let userMessage = ChatMessage(role: .user, content: trimmed, status: .completed)
        let assistantMessage = ChatMessage(role: .assistant, content: "", status: .streaming)
        messages.append(userMessage)
        messages.append(assistantMessage)

        enqueuePersistence { await $0.save(userMessage) }
        enqueuePersistence { await $0.save(assistantMessage) }

        startGeneration(prompt: trimmed, assistantID: assistantMessage.id)
    }

    /// Re-run the last turn when its assistant message failed or was cancelled.
    func retry() {
        guard !isGenerating, availability.isAvailable else { return }
        guard let assistantIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        switch messages[assistantIndex].status {
        case .failed, .cancelled:
            break
        default:
            return
        }
        guard assistantIndex > 0, messages[assistantIndex - 1].role == .user else { return }

        let prompt = messages[assistantIndex - 1].content
        messages[assistantIndex].content = ""
        messages[assistantIndex].status = .streaming
        startGeneration(prompt: prompt, assistantID: messages[assistantIndex].id)
    }

    private func startGeneration(prompt: String, assistantID: UUID) {
        let requestID = UUID()
        activeRequestID = requestID
        isGenerating = true

        generationTask = Task { [weak self] in
            await self?.runGeneration(requestID: requestID, assistantID: assistantID, prompt: prompt)
        }
    }

    // MARK: Stopping

    /// Cancel the active generation. The partial answer is preserved and the
    /// message ends up `.cancelled` (handled in `runGeneration`).
    func stopGeneration() {
        guard isGenerating else { return }
        generationTask?.cancel()
    }

    // MARK: Pagination

    /// Prepend the next older page. Guards against duplicate/concurrent loads.
    func loadOlderMessages() {
        guard !isLoadingOlderMessages, hasMoreHistory else { return }
        guard let oldest = messages.first else { return }
        isLoadingOlderMessages = true

        Task { [weak self] in
            guard let self else { return }
            let page = await repository.loadBefore(messageID: oldest.id, limit: historyPageSize)
            defer { isLoadingOlderMessages = false }

            let known = Set(messages.map(\.id))
            let fresh = page.messages.filter { !known.contains($0.id) }
            if !fresh.isEmpty {
                messages.insert(contentsOf: fresh, at: 0)
            }
            hasMoreHistory = page.hasMore
        }
    }

    // MARK: - Generation loop

    private func runGeneration(requestID: UUID, assistantID: UUID, prompt: String) async {
        var accumulated = ""
        do {
            for try await snapshot in ai.streamResponse(to: prompt) {
                // Stale-stream protection: a superseded request must not write.
                guard requestID == activeRequestID else { return }
                if Task.isCancelled { break }
                accumulated = snapshot
                scheduleFlush(assistantID: assistantID, content: snapshot, requestID: requestID)
            }

            guard requestID == activeRequestID else { return }
            if Task.isCancelled {
                finish(assistantID: assistantID, content: accumulated, status: .cancelled, requestID: requestID)
            } else {
                finish(assistantID: assistantID, content: accumulated, status: .completed, requestID: requestID)
            }
        } catch is CancellationError {
            guard requestID == activeRequestID else { return }
            finish(assistantID: assistantID, content: accumulated, status: .cancelled, requestID: requestID)
        } catch {
            guard requestID == activeRequestID else { return }
            finish(
                assistantID: assistantID,
                content: accumulated,
                status: .failed(Self.describe(error)),
                requestID: requestID
            )
        }
    }

    // MARK: Streamed-update coalescing

    /// Record the latest snapshot and make sure a flush is scheduled. Between
    /// the schedule and the flush, further snapshots just overwrite
    /// `pendingContent`, so a burst of updates costs one `messages` write.
    private func scheduleFlush(assistantID: UUID, content: String, requestID: UUID) {
        pendingContent = content
        pendingAssistantID = assistantID
        guard flushTask == nil else { return }

        flushTask = Task { [weak self, coalesceInterval] in
            try? await Task.sleep(for: coalesceInterval)
            guard !Task.isCancelled else { return }
            self?.flushPending(requestID: requestID)
        }
    }

    private func flushPending(requestID: UUID) {
        flushTask = nil
        guard requestID == activeRequestID,
              let id = pendingAssistantID,
              let content = pendingContent,
              let index = messages.firstIndex(where: { $0.id == id })
        else { return }

        messages[index].content = content
        pendingContent = nil
    }

    // MARK: Finishing

    private func finish(assistantID: UUID, content: String, status: MessageStatus, requestID: UUID) {
        flushTask?.cancel()
        flushTask = nil
        pendingContent = nil
        pendingAssistantID = nil

        guard requestID == activeRequestID else { return }

        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].content = content
            messages[index].status = status
            let finalMessage = messages[index]
            enqueuePersistence { await $0.update(finalMessage) }
        }

        isGenerating = false
        activeRequestID = nil
        generationTask = nil
    }

    // MARK: Persistence helpers

    /// Append a repository write to the serial chain. `repository` is `Sendable`;
    /// the closure runs off the main actor.
    private func enqueuePersistence(_ write: @escaping @Sendable (MessageRepository) async -> Void) {
        let previous = persistenceTail
        let repository = self.repository
        persistenceTail = Task {
            await previous?.value
            await write(repository)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
