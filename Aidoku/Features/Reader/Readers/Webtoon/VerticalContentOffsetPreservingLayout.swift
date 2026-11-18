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

    var isInsertingCellsAbove: Bool = false {
        didSet {
            if isInsertingCellsAbove {
                contentSizeBeforeInsertingAbove = collectionViewContentSize
            }
        }
    }

    var spacing: CGFloat {
        get { minimumLineSpacing }
        set { minimumLineSpacing = newValue }
    }

    private var contentSizeBeforeInsertingAbove: CGSize?
    private var scale: CGFloat = 1

    private var contentSize = CGSize.zero
    override var collectionViewContentSize: CGSize {
        contentSize
    }

    private var verticalAttributes: [UICollectionViewLayoutAttributes] = []

    private var sectionRanges: [Range<Int>] = []
    // Accumulated cell heights exclude line spacing, matching the page slider.
    private var cumulativeHeights: [CGFloat] = [0]

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

        // calculate collection view size
        sectionRanges.removeAll(keepingCapacity: true)
        verticalAttributes.removeAll(keepingCapacity: true)
        cumulativeHeights.removeAll(keepingCapacity: true)
        cumulativeHeights.append(0)

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
                cumulativeHeight += attributes.frame.height
                cumulativeHeights.append(cumulativeHeight)
                origin += size.height + minimumLineSpacing
            }
            sectionRanges.append(firstIndex..<verticalAttributes.count)
        }

        // scale for zoom
        let size = CGSize(width: width, height: origin)
        contentSize = size.applying(transform)

        // preserve offset when inserting cells above
        if isInsertingCellsAbove {
            if let oldContentSize = contentSizeBeforeInsertingAbove {
                UIView.performWithoutAnimation {
                    let newContentSize = collectionViewContentSize
                    let contentOffsetX = collectionView.contentOffset.x + (newContentSize.width - oldContentSize.width)
                    let contentOffsetY = collectionView.contentOffset.y + (newContentSize.height - oldContentSize.height)
                    let newOffset = CGPoint(x: contentOffsetX, y: contentOffsetY)
                    collectionView.contentOffset = newOffset
                }
            }
            contentSizeBeforeInsertingAbove = nil
            isInsertingCellsAbove = false
        }
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
        // Frames are stacked in increasing Y order (including the zoom transform).
        // Find the first possible intersection, then visit only the viewport.
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
