import UIKit

/// Pure-UIKit self-sizing chat bubble. No `UIHostingConfiguration` — this cell
/// is the thing being reused thousands of times, so it stays cheap.
final class ChatMessageCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatMessageCell"

    private let bubble = UIView()
    private let messageLabel = UILabel()
    private let footnoteLabel = UILabel()
    private let stack = UIStackView()

    /// Exactly one of these is active at a time (left for assistant, right for
    /// user). Priority 999, not required: if a reuse ever activates both for an
    /// instant, the engine drops one silently instead of logging an
    /// unsatisfiable-constraints break during the self-sizing pass.
    private var leadingPin: NSLayoutConstraint!
    private var trailingPin: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    private func setUpViews() {
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 16
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 3
        bubble.addSubview(stack)

        messageLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true

        footnoteLabel.numberOfLines = 0
        footnoteLabel.font = .preferredFont(forTextStyle: .caption2)
        footnoteLabel.adjustsFontForContentSizeCategory = true
        footnoteLabel.isHidden = true

        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(footnoteLabel)

        leadingPin = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailingPin = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        leadingPin.priority = .init(999)
        trailingPin.priority = .init(999)

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            // Always-on guards: the bubble stays inside the cell and never wider
            // than 78%, regardless of which pin is active.
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),

            stack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ])
    }

    func configure(with message: ChatMessage) {
        let isUser = message.role == .user

        if message.content.isEmpty, message.status == .streaming {
            messageLabel.text = "…"
        } else {
            messageLabel.text = message.content
        }

        bubble.backgroundColor = isUser ? .tintColor : .secondarySystemBackground
        messageLabel.textColor = isUser ? .white : .label

        // Deactivate the unwanted pin *before* activating the wanted one so the
        // two are never both active, even for an instant mid-reuse.
        if isUser {
            leadingPin.isActive = false
            trailingPin.isActive = true
        } else {
            trailingPin.isActive = false
            leadingPin.isActive = true
        }

        var footnote: String?
        switch message.status {
        case .failed(let reason):
            footnote = "Failed — \(reason)"
            footnoteLabel.textColor = .systemRed
        case .cancelled:
            footnote = "Stopped"
            footnoteLabel.textColor = isUser ? .white.withAlphaComponent(0.8) : .secondaryLabel
        case .sending, .streaming, .completed:
            footnote = nil
        }
        footnoteLabel.text = footnote
        footnoteLabel.isHidden = footnote == nil

        isAccessibilityElement = true
        accessibilityLabel = [
            isUser ? "You said" : "Assistant said",
            messageLabel.text,
            footnote,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.text = nil
        footnoteLabel.text = nil
        footnoteLabel.isHidden = true
        bubble.backgroundColor = nil
        accessibilityLabel = nil
        // Alignment pins are left as-is: `configure` always sets exactly one.
    }
}
