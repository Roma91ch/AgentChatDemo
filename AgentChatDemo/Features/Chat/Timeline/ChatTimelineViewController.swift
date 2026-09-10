import UIKit

/// Single-section transcript. File-scoped so its `Hashable` conformance is
/// `nonisolated` — the diffable data source requires a `Sendable` section
/// identifier.
private enum ChatTimelineSection: Hashable, Sendable {
    case main
}

/// UIKit owner of the high-volume transcript. It renders whatever
/// `ConversationStore` hands it and owns **no** business state — just enough
/// bookkeeping to diff snapshots and manage scrolling.
final class ChatTimelineViewController: UIViewController {

    // MARK: Callbacks (set by the SwiftUI bridge)

    /// Fires when the user scrolls near the oldest loaded message.
    var onReachedTop: (() -> Void)?
    /// Fires when "is the user near the bottom" flips. `true` == near bottom.
    var onBottomStateChanged: ((Bool) -> Void)?

    // MARK: Tuning

    /// Distance from the bottom (pt) still considered "pinned".
    private let nearBottomThreshold: CGFloat = 120
    /// Distance from the top (pt) that triggers a history page load.
    private let topLoadTriggerDistance: CGFloat = 320

    // MARK: Collection view

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: ChatTimelineLayout.make())
        view.backgroundColor = .systemBackground
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.delegate = self
        return view
    }()

    private lazy var dataSource = makeDataSource()

    // MARK: Renderer bookkeeping (not business state)

    private var orderedIDs: [UUID] = []
    private var messagesByID: [UUID: ChatMessage] = [:]

    /// Latest messages handed in before the view had a usable size. Applied on
    /// first `viewIsAppearing`, when scroll math is finally meaningful.
    private var pendingMessages: [ChatMessage]?
    private var hasAppeared = false
    private var lastReportedNearBottom = true
    private var isInTopTriggerZone = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Geometry-dependent work belongs here, not in `viewDidLoad`: this is the
    /// first point where the collection view has its real size, so the initial
    /// scroll-to-bottom actually lands.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !hasAppeared else { return }
        hasAppeared = true
        if let pendingMessages {
            self.pendingMessages = nil
            render(messages: pendingMessages)
        }
    }

    // MARK: Data source

    private func makeDataSource() -> UICollectionViewDiffableDataSource<ChatTimelineSection, UUID> {
        let registration = UICollectionView.CellRegistration<ChatMessageCell, UUID> { [weak self] cell, _, id in
            guard let message = self?.messagesByID[id] else { return }
            cell.configure(with: message)
        }
        return UICollectionViewDiffableDataSource<ChatTimelineSection, UUID>(
            collectionView: collectionView
        ) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    // MARK: Rendering

    /// Reconcile the collection view with `messages`: work out what actually
    /// changed (bottom insert, top prepend, in-place content edit) and pick the
    /// cheapest update plus the right scrolling response for each.
    func render(messages: [ChatMessage]) {
        guard hasAppeared else {
            pendingMessages = messages
            return
        }

        let previousIDs = orderedIDs
        let previousByID = messagesByID
        let newIDs = messages.map(\.id)

        orderedIDs = newIDs
        messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        let changedIDs = newIDs.filter { id in
            guard let old = previousByID[id], let new = messagesByID[id] else { return false }
            return old != new
        }

        let mode = Self.diffMode(previous: previousIDs, next: newIDs)
        if mode == .unchanged, changedIDs.isEmpty { return }

        var snapshot = NSDiffableDataSourceSnapshot<ChatTimelineSection, UUID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newIDs, toSection: .main)
        if !changedIDs.isEmpty {
            // Same identifiers, new content -> reconfigure only those cells.
            snapshot.reconfigureItems(changedIDs)
        }

        apply(snapshot, mode: mode)
    }

    private enum DiffMode: Equatable {
        case initialLoad
        case appendedAtBottom
        case prependedAtTop
        case unchanged        // same identifiers, maybe reconfigured content
        case mixed            // prepend + append/change in one pass
    }

    private static func diffMode(previous: [UUID], next: [UUID]) -> DiffMode {
        if previous.isEmpty { return next.isEmpty ? .unchanged : .initialLoad }
        if previous == next { return .unchanged }
        if next.count >= previous.count, Array(next.suffix(previous.count)) == previous {
            return .prependedAtTop
        }
        if next.count >= previous.count, Array(next.prefix(previous.count)) == previous {
            return .appendedAtBottom
        }
        return .mixed
    }

    private func apply(_ snapshot: NSDiffableDataSourceSnapshot<ChatTimelineSection, UUID>, mode: DiffMode) {
        switch mode {
        case .initialLoad:
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                scrollToBottom(animated: false)
                notifyBottomStateIfChanged(force: true)
            }

        case .prependedAtTop:
            // CASE 3: keep the user where they are.
            applyPreservingScrollPosition(snapshot)

        case .mixed where !isNearBottom:
            // History arrived while the user is reading it — don't yank down.
            applyPreservingScrollPosition(snapshot)

        case .appendedAtBottom, .unchanged, .mixed:
            let wasNearBottom = isNearBottom
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                if wasNearBottom {
                    // CASE 1: near the bottom while streaming -> stay pinned.
                    scrollToBottom(animated: mode == .appendedAtBottom)
                }
                // CASE 2: scrolled up -> leave the offset alone; just report it.
                notifyBottomStateIfChanged()
            }
        }
    }

    /// Prepend without a visible jump: anchor on the first visible item and
    /// restore its on-screen position after the apply. (Self-sizing cells make
    /// a perfect restore impossible; this keeps the shift sub-pixel in practice.)
    private func applyPreservingScrollPosition(_ snapshot: NSDiffableDataSourceSnapshot<ChatTimelineSection, UUID>) {
        collectionView.layoutIfNeeded()

        let anchorID = firstVisibleID()
        let anchorDistanceFromTop: CGFloat? = anchorID.flatMap { id in
            guard let indexPath = dataSource.indexPath(for: id),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath)
            else { return nil }
            return attributes.frame.minY - collectionView.contentOffset.y
        }

        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            collectionView.layoutIfNeeded()

            if let anchorID,
               let anchorDistanceFromTop,
               let indexPath = dataSource.indexPath(for: anchorID),
               let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
                var offset = collectionView.contentOffset
                offset.y = max(
                    attributes.frame.minY - anchorDistanceFromTop,
                    -collectionView.adjustedContentInset.top
                )
                collectionView.setContentOffset(offset, animated: false)
            }
            notifyBottomStateIfChanged()
        }
    }

    // MARK: Scrolling

    func scrollToBottom(animated: Bool) {
        collectionView.layoutIfNeeded()
        let target = max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
        lastReportedNearBottom = true
    }

    private var distanceFromTop: CGFloat {
        collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    private var isNearBottom: Bool {
        let bounds = collectionView.bounds.height
        guard bounds > 0 else { return true }
        let visibleHeight = bounds
            - collectionView.adjustedContentInset.top
            - collectionView.adjustedContentInset.bottom
        guard collectionView.contentSize.height > visibleHeight else { return true }
        let maxOffsetY = collectionView.contentSize.height
            - bounds
            + collectionView.adjustedContentInset.bottom
        return collectionView.contentOffset.y >= maxOffsetY - nearBottomThreshold
    }

    private func firstVisibleID() -> UUID? {
        collectionView.indexPathsForVisibleItems
            .min()
            .flatMap { dataSource.itemIdentifier(for: $0) }
    }

    private func notifyBottomStateIfChanged(force: Bool = false) {
        let near = isNearBottom
        guard force || near != lastReportedNearBottom else { return }
        lastReportedNearBottom = near
        onBottomStateChanged?(near)
    }
}

// MARK: - UIScrollViewDelegate

extension ChatTimelineViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasAppeared else { return }
        notifyBottomStateIfChanged()

        if distanceFromTop < topLoadTriggerDistance {
            if !isInTopTriggerZone {
                isInTopTriggerZone = true
                onReachedTop?()
            }
        } else {
            isInTopTriggerZone = false
        }
    }
}
