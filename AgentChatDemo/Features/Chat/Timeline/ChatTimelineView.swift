import SwiftUI

/// SwiftUI -> UIKit bridge for the transcript.
///
/// The only thing that crosses the boundary is a value-type `[ChatMessage]`
/// plus a handful of closures. UIKit never reaches back into SwiftUI state
/// except through these callbacks.
struct ChatTimelineView: UIViewControllerRepresentable {
    let messages: [ChatMessage]
    /// Bump to command an explicit scroll-to-bottom (e.g. right after send).
    var scrollToBottomToken: Int
    var onReachedTop: () -> Void
    /// `true` when the user is near the bottom.
    var onBottomStateChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> ChatTimelineViewController {
        let controller = ChatTimelineViewController()
        controller.onReachedTop = onReachedTop
        controller.onBottomStateChanged = onBottomStateChanged
        context.coordinator.lastScrollToken = scrollToBottomToken
        return controller
    }

    func updateUIViewController(_ controller: ChatTimelineViewController, context: Context) {
        // Closures are recreated each SwiftUI update; keep the controller's copy
        // fresh. Mutable state (the messages) is pushed here, never in `make`.
        controller.onReachedTop = onReachedTop
        controller.onBottomStateChanged = onBottomStateChanged

        controller.render(messages: messages)

        if context.coordinator.lastScrollToken != scrollToBottomToken {
            context.coordinator.lastScrollToken = scrollToBottomToken
            controller.scrollToBottom(animated: true)
        }
    }

    final class Coordinator {
        var lastScrollToken = 0
    }
}
