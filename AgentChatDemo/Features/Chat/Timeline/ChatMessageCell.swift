import UIKit

/// Pure-UIKit self-sizing chat bubble. No `UIHostingConfiguration` — this cell
/// is the thing being reused thousands of times, so it stays cheap.
final class ChatMessageCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatMessageCell"

    private let bubble = UIView()
    private let messageLabel = UILabel()
    private let footnoteLabel = UILabel()
    private let stack = UIStackView()

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

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

        leadingConstraint = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailingConstraint = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        leadingConstraint.priority = .required
        trailingConstraint.priority = .required

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
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

        // Exactly one alignment constraint is ever active; setting the pair every
        // time is a no-op when unchanged and avoids an ambiguous-layout window.
        leadingConstraint.isActive = !isUser
        trailingConstraint.isActive = isUser

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
        // Alignment constraints are left as-is: `configure` always sets both.
    }
}
