import SwiftUI

/// The input row. Send turns into Stop while a reply is generating.
struct ChatComposer: View {
    @Binding var text: String
    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($isFocused)
                // Free-form prose: opt out of AutoFill so the system stops
                // trying to anchor an OTP/one-time-code popover to it (noisy on
                // Mac Catalyst, which has no software keyboard rect).
                .textContentType(nil)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                .onSubmit(submitIfPossible)

            if isGenerating {
                Button(role: .destructive, action: onStop) {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title)
                }
                .tint(.red)
            } else {
                Button(action: onSend) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func submitIfPossible() {
        if canSend { onSend() }
    }
}

#Preview {
    @Previewable @State var text = "Hello"
    VStack {
        Spacer()
        ChatComposer(text: $text, isGenerating: false, canSend: true, onSend: {}, onStop: {})
        ChatComposer(text: .constant(""), isGenerating: true, canSend: false, onSend: {}, onStop: {})
    }
}
