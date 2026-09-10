import UIKit

/// Layout factory for the transcript.
///
/// A single-section compositional list with self-sizing (`.estimated`) item
/// heights. Full-width items — the bubble alignment (left/right) is done inside
/// the cell, not by the layout — so a role change never invalidates layout
/// geometry, only the cell's own Auto Layout.
@MainActor
enum ChatTimelineLayout {
    static func make() -> UICollectionViewLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.interSectionSpacing = 0

        return UICollectionViewCompositionalLayout(
            sectionProvider: { _, _ in
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(56)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let group = NSCollectionLayoutGroup.vertical(
                    layoutSize: itemSize,
                    subitems: [item]
                )
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 10
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: 12, leading: 16, bottom: 12, trailing: 16
                )
                return section
            },
            configuration: configuration
        )
    }
}
