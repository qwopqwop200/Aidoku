//
//  VerticalContentOffsetPreservingLayout.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 3/1/23.
//  Thanks to Mantton (https://github.com/Mantton) for this.
//

import UIKit
import AsyncDisplayKit

class VerticalContentOffsetPreservingLayout: UICollectionViewFlowLayout {

    private(set) var isChangingCellsAbove: Bool = false
    var onOffsetPreserved: ((CGPoint) -> Void)?

    func preserveOffsetAcrossChangeAbove() {
        isChangingCellsAbove = true
    }

    var spacing: CGFloat {
        get { minimumLineSpacing }
        set { minimumLineSpacing = newValue }
    }

    private var scale: CGFloat = 1

    private var contentSize = CGSize.zero
    override var collectionViewContentSize: CGSize {
        contentSize
    }

    private var verticalAttributes: [UICollectionViewLayoutAttributes] = []

    private var sectionRanges: [Range<Int>] = []
    // Accumulated cell heights exclude line spacing, matching the page slider.
    private var cumulativeHeights: [CGFloat] = [0]
    // Node identities, so anchors follow their page when sections change above it.
    private var itemIdentifiers: [IndexPath: AnyHashable] = [:]
    private var indexPathsByIdentifier: [AnyHashable: IndexPath] = [:]

    private struct ViewportAnchor {
        let indexPath: IndexPath
        // the anchored node, so the anchor follows its page if sections change above it
        let identifier: AnyHashable?
        let position: CGPoint
    }

    private var preservedViewportAnchor: ViewportAnchor?

    func preserveVisiblePosition() {
        guard let collectionView else { return }

        let bounds = collectionView.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard
            let attributes = layoutAttributesForElements(in: bounds)?
                .filter({ $0.representedElementCategory == .cell && $0.frame.width > 0 && $0.frame.height > 0 })
                .min(by: {
                    let first = max($0.frame.minY - center.y, center.y - $0.frame.maxY, 0)
                    let second = max($1.frame.minY - center.y, center.y - $1.frame.maxY, 0)
                    return first < second
                })
        else {
            preservedViewportAnchor = nil
            return
        }

        preservedViewportAnchor = ViewportAnchor(
            indexPath: attributes.indexPath,
            identifier: itemIdentifiers[attributes.indexPath],
            position: CGPoint(
                x: (center.x - attributes.frame.minX) / attributes.frame.width,
                y: (center.y - attributes.frame.minY) / attributes.frame.height
            )
        )
    }

    func clearPreservedPosition() {
        preservedViewportAnchor = nil
    }

    override init() {
        super.init()
        scrollDirection = .vertical
        minimumInteritemSpacing = 0
        minimumLineSpacing = 0
        sectionInset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        guard let collectionView else { return }

        // Anchor the top visible cell using the previous layout
        // (frames are stacked in increasing Y order)
        let anchor = isChangingCellsAbove ? verticalAttributes
            .first { $0.frame.maxY > collectionView.contentOffset.y } : nil
        let anchorIdentifier = anchor.flatMap { itemIdentifiers[$0.indexPath] }
        let oldAnchorY = anchor?.frame.minY
        isChangingCellsAbove = false

        // calculate collection view size
        sectionRanges.removeAll(keepingCapacity: true)
        verticalAttributes.removeAll(keepingCapacity: true)
        cumulativeHeights.removeAll(keepingCapacity: true)
        cumulativeHeights.append(0)
        itemIdentifiers.removeAll(keepingCapacity: true)
        indexPathsByIdentifier.removeAll(keepingCapacity: true)

        var origin: CGFloat = 0
        var cumulativeHeight: CGFloat = 0
        let width = collectionView.bounds.size.width
        let transform = CGAffineTransform(scaleX: scale, y: scale)

        for section in 0..<collectionView.numberOfSections {
            let firstIndex = verticalAttributes.count
            for itemIndex in 0..<collectionView.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: itemIndex, section: section)
                let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)

                let size = CGSize(width: width, height: getHeight(for: indexPath))
                attributes.frame = CGRect(origin: CGPoint(x: 0, y: origin), size: size)
                if scale != 1 {
                    attributes.transform = transform
                    attributes.center = CGPoint(x: width / 2, y: origin + size.height / 2).applying(transform)
                }
                verticalAttributes.append(attributes)
                if let identifier = itemIdentifier(for: indexPath) {
                    itemIdentifiers[indexPath] = identifier
                    indexPathsByIdentifier[identifier] = indexPath
                }
                cumulativeHeight += attributes.frame.height
                cumulativeHeights.append(cumulativeHeight)
                origin += size.height + minimumLineSpacing
            }
            sectionRanges.append(firstIndex..<verticalAttributes.count)
        }

        // scale for zoom
        let size = CGSize(width: width, height: origin)
        contentSize = size.applying(transform)

        // Only movement of the anchor counts, not resizing of cells
        if
            let anchorIdentifier, let oldAnchorY,
            let newIndexPath = indexPathsByIdentifier[anchorIdentifier],
            let newAnchorY = layoutAttributesForItem(at: newIndexPath)?.frame.minY
        {
            UIView.performWithoutAnimation {
                let offset = CGPoint(
                    x: collectionView.contentOffset.x,
                    y: collectionView.contentOffset.y + newAnchorY - oldAnchorY
                )
                collectionView.contentOffset = offset
                onOffsetPreserved?(offset)
            }
        }
    }

    func itemIdentifier(for indexPath: IndexPath) -> AnyHashable? {
        guard
            let collectionView = collectionView as? ASCollectionView,
            let node = collectionView.collectionNode?.nodeForItem(at: indexPath)
        else { return nil }
        return ObjectIdentifier(node)
    }

    func getHeight(for indexPath: IndexPath) -> CGFloat {
        guard
            let collectionView = collectionView as? ASCollectionView,
            let collectionNode = collectionView.collectionNode,
            let node = collectionNode.nodeForItem(at: indexPath) as? HeightQueryable
        else {
            return 0
        }
        return node.getHeight(for: collectionView.bounds.size)
    }

    func getHeightFor(section: Int, range: Range<Int>? = nil) -> CGFloat {
        guard sectionRanges.indices.contains(section) else { return 0 }
        let sectionRange = sectionRanges[section]
        let items = 0..<sectionRange.count
        let range = range?.clamped(to: items) ?? items
        let start = sectionRange.lowerBound + range.lowerBound
        let end = sectionRange.lowerBound + range.upperBound
        return (cumulativeHeights[end] - cumulativeHeights[start]) * scale
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard sectionRanges.indices.contains(indexPath.section) else { return nil }
        let section = sectionRanges[indexPath.section]
        guard (0..<section.count).contains(indexPath.item) else { return nil }
        return verticalAttributes[section.lowerBound + indexPath.item]
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // Frames are sorted by Y: binary-search the first intersection, then visit only the viewport.
        var low = 0
        var high = verticalAttributes.count
        while low < high {
            let mid = low + (high - low) / 2
            if verticalAttributes[mid].frame.maxY < rect.minY { low = mid + 1 }
            else { high = mid }
        }
        var attributes: [UICollectionViewLayoutAttributes] = []
        for index in low..<verticalAttributes.count {
            let item = verticalAttributes[index]
            if item.frame.minY > rect.maxY { break }
            if rect.intersects(item.frame) { attributes.append(item) }
        }
        return attributes
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        preservedContentOffset() ?? proposedContentOffset
    }

    /// The content offset that puts the preserved anchor back at the center of the current bounds.
    func preservedContentOffset() -> CGPoint? {
        guard let collectionView, let anchor = preservedViewportAnchor else { return nil }

        let indexPath = if let identifier = anchor.identifier {
            indexPathsByIdentifier[identifier]
        } else {
            anchor.indexPath
        }
        guard let indexPath, let attributes = layoutAttributesForItem(at: indexPath) else { return nil }

        let frame = attributes.frame
        let size = collectionView.bounds.size
        let inset = collectionView.adjustedContentInset
        let minimum = CGPoint(x: -inset.left, y: -inset.top)
        let maximum = CGPoint(
            x: max(minimum.x, collectionViewContentSize.width - size.width + inset.right),
            y: max(minimum.y, collectionViewContentSize.height - size.height + inset.bottom)
        )

        return CGPoint(
            x: min(max(frame.minX + frame.width * anchor.position.x - size.width / 2, minimum.x), maximum.x),
            y: min(max(frame.minY + frame.height * anchor.position.y - size.height / 2, minimum.y), maximum.y)
        )
    }
}

// MARK: - Zoom Support
extension VerticalContentOffsetPreservingLayout: @MainActor ZoomableLayoutProtocol {
    func getScale() -> CGFloat {
        scale
    }

    func setScale(_ scale: CGFloat) {
        self.scale = scale
    }
}
