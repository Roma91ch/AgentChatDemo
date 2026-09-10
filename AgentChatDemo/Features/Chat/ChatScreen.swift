import SwiftUI

/// Composition root for the chat feature: navigation shell + availability
/// banner + UIKit timeline + composer + "jump to bottom" overlay.
struct ChatScreen: View {
    @Bindable var dependencies: AppDependencies

    @State private var scrollToBottomToken = 0
    @State private var isNearBottom = true

    private var store: ConversationStore { dependencies.store }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                timeline
                jumpToBottomButton
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposer(
                    text: Bindable(store).draft,
                    isGenerating: store.isGenerating,
                    canSend: store.canSend,
                    onSend: send,
                    onStop: store.stopGeneration
                )
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let message = store.availability.userMessage {
                    AvailabilityBanner(text: message)
                }
            }
            .navigationTitle("Agent Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { debugMenu }
        }
        .task(id: ObjectIdentifier(store)) {
            await store.bootstrap()
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var timeline: some View {
        if store.messages.isEmpty {
            ContentUnavailableView(
                "Start the conversation",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Ask about how this demo app is built.")
            )
        } else {
            ChatTimelineView(
                messages: store.messages,
                scrollToBottomToken: scrollToBottomToken,
                onReachedTop: store.loadOlderMessages,
                onBottomStateChanged: { near in
                    withAnimation(.snappy) { isNearBottom = near }
                }
            )
        }
    }

    @ViewBuilder
    private var jumpToBottomButton: some View {
        if !isNearBottom {
            Button {
                scrollToBottomToken &+= 1
                withAnimation(.snappy) { isNearBottom = true }
            } label: {
                Label("Jump to bottom", systemImage: "arrow.down")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .overlay(Capsule().strokeBorder(.separator))
            }
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private var debugMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu("Debug", systemImage: "ladybug") {
                Picker("AI source", selection: Binding(
                    get: { dependencies.mode },
                    set: { dependencies.switchTo($0) }
                )) {
                    Text("Use Mock AI").tag(AppDependencies.Mode.mock)
                    Text("Use Real Foundation Model").tag(AppDependencies.Mode.foundationModels)
                }
                Divider()
                Button("Seed 1,000 messages") { dependencies.seed(1_000) }
                Button("Clear conversation", role: .destructive) { dependencies.clearConversation() }
            }
        }
    }

    private func send() {
        store.send()
        scrollToBottomToken &+= 1
    }
}

private struct AvailabilityBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.yellow.opacity(0.18))
        .foregroundStyle(.secondary)
    }
}

#Preview {
    ChatScreen(dependencies: AppDependencies())
}
