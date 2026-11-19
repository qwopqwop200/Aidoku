import Testing
import UIKit
@testable import Aidoku

@MainActor struct WebtoonLayoutScalingTests {
    @Test func chapterRangesFollowZoomSpacingAndReloadedCells() throws {
        let data = LayoutPages()
        let layout = MeasuredWebtoonLayout()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), collectionViewLayout: layout)
        collection.dataSource = data
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        layout.spacing = 15

        for chapterCounts in [[2, 0, 4], [0, 3]] {
            data.counts = chapterCounts
            collection.reloadData()
            for scale: CGFloat in [1, 1.75] {
                layout.setScale(scale)
                layout.prepare()
                var origin: CGFloat = 0
                for (section, count) in chapterCounts.enumerated() {
                    var heights: [CGFloat] = []
                    for item in 0..<count {
                        let path = IndexPath(item: item, section: section)
                        let attributes = try #require(layout.layoutAttributesForItem(at: path))
                        #expect(attributes.indexPath == path)
                        let height = layout.getHeight(for: path)
                        #expect(attributes.center == CGPoint(x: 195 * scale, y: (origin + height / 2) * scale))
                        #expect(attributes.transform == CGAffineTransform(scaleX: scale, y: scale))
                        heights.append(attributes.frame.height)
                        origin += height + 15
                    }
                    #expect(layout.layoutAttributesForItem(at: IndexPath(item: count, section: section)) == nil)
                    #expect(layout.getHeightFor(section: section) == heights.reduce(0, +) * scale)
                    // The existing slider sums frame heights without the inter-page spacing.
                    #expect(layout.getHeightFor(section: section, range: 1..<6) == heights.dropFirst().reduce(0, +) * scale)
                    #expect(layout.getHeightFor(section: section, range: 1..<1) == 0)
                }
                #expect(layout.collectionViewContentSize == CGSize(width: 390 * scale, height: origin * scale))
                #expect(layout.getHeightFor(section: chapterCounts.count) == 0)
            }
        }
    }
}
@MainActor private final class LayoutPages: NSObject, UICollectionViewDataSource {
    var counts = [0]
    func numberOfSections(in collectionView: UICollectionView) -> Int { counts.count }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { counts[section] }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
    }
}
@MainActor private final class MeasuredWebtoonLayout: VerticalContentOffsetPreservingLayout {
    override func getHeight(for indexPath: IndexPath) -> CGFloat { CGFloat(40 + indexPath.item % 11 * 31) }
}
