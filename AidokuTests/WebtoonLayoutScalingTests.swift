import Testing
import UIKit
@testable import Aidoku

@MainActor struct WebtoonLayoutScalingTests {
    @Test func viewportLookupMatchesFullScanAndMeasuresScaling() throws {
        let data = LayoutPages()
        let layout = MeasuredWebtoonLayout()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), collectionViewLayout: layout)
        collection.dataSource = data
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        var rows: [[String: Any]] = []
        for count in [100, 1000, 10000] {
            data.count = count
            collection.reloadData()
            for scale: CGFloat in [1, 2] {
                layout.setScale(scale); layout.invalidateLayout(); layout.prepare()
                let all = Dictionary(uniqueKeysWithValues: (0..<count).map { index in
                    let path = IndexPath(item: index, section: 0)
                    return (path, layout.layoutAttributesForItem(at: path)!)
                })
                let rectangles = (0..<100).map { i in
                    CGRect(x: 0, y: CGFloat(i) / 100 * layout.collectionViewContentSize.height, width: 390, height: 844)
                } + [.zero, .null, CGRect(x: 4000, y: 50, width: 2, height: 2)]
                for rect in rectangles {
                    let expected = all.values.filter { rect.intersects($0.frame) }.sorted { $0.indexPath < $1.indexPath }
                    let actual = (layout.layoutAttributesForElements(in: rect) ?? []).sorted { $0.indexPath < $1.indexPath }
                    #expect(actual.map(\.indexPath) == expected.map(\.indexPath))
                    #expect(actual.map(\.frame) == expected.map(\.frame))
                    #expect(actual.map(\.transform) == expected.map(\.transform))
                }
                for iteration in 0..<5 {
                    var oldCount = 0; var newCount = 0
                    let start = CACurrentMediaTime()
                    for rect in rectangles { for (_, value) in all where rect.intersects(value.frame) { oldCount += 1 } }
                    let middle = CACurrentMediaTime()
                    for rect in rectangles { newCount += layout.layoutAttributesForElements(in: rect)?.count ?? 0 }
                    let end = CACurrentMediaTime()
                    #expect(oldCount == newCount)
                    rows.append(["pages": count, "scale": scale, "iteration": iteration,
                        "fullScanMS": (middle-start)*1000, "viewportLookupMS": (end-middle)*1000, "queries": rectangles.count, "exact": true])
                }
            }
        }
        let output = URL.documentsDirectory.appendingPathComponent("WebtoonLayoutScaling.json")
        try JSONSerialization.data(withJSONObject: ["rows": rows, "scope": "Actual simulator UICollectionView layout with deterministic variable-height cells; original full-scan algorithm replay in same process. Internal lookup cost, not end-to-end gesture latency."], options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
}
@MainActor private final class LayoutPages: NSObject, UICollectionViewDataSource {
    var count = 0
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
    }
}
@MainActor private final class MeasuredWebtoonLayout: VerticalContentOffsetPreservingLayout {
    override func getHeight(for indexPath: IndexPath) -> CGFloat { CGFloat(40 + indexPath.item % 11 * 31) }
}
