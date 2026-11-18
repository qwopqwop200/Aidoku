import CoreGraphics
import Foundation

@main struct SourceRevisionSmoke {
    static func main() throws {
        var assertions = 0
        for folder in CommandLine.arguments.dropFirst() {
            let root = URL(fileURLWithPath: folder)
            let revision = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("source-revision.json"))) as! [String: Any]
            let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("001-render-payload.json"))) as! [String: Any]
            let value = payload["value"] as! [String: Any], layout = value["nativeLayout"] as! [String: Any]
            let items = layout["items"] as! [[String: Any]]
            let valid = try NativeMainSourceRevision.validate(revision, displayItems: items,
                imageSize: CGSize(width: 1, height: 1), localize: { $0 })
            precondition(valid.removalItems.count == (revision["originalRemovalItems"] as! [Any]).count)
            assertions += 1
            func rejects(_ r: [String: Any], _ d: [[String: Any]]) {
                do {
                    _ = try NativeMainSourceRevision.validate(r, displayItems: d,
                        imageSize: CGSize(width: 1, height: 1), localize: { $0 })
                    preconditionFailure("Invalid source revision accepted")
                } catch { assertions += 1 }
            }
            let transactions = revision["transactions"] as! [[String: Any]]
            let fresh = transactions[0]["newItem"] as! [String: Any], id = fresh["id"] as! String
            var bad = items
            let index = bad.firstIndex { $0["id"] as? String == id }!
            bad[index]["text"] = "stale target"
            rejects(revision, bad)
            bad = items; bad.remove(at: index); rejects(revision, bad)
            var broken = revision, changed = transactions
            changed[0]["primaryAfter"] = [-1]; broken["transactions"] = changed
            rejects(broken, items)
            changed = transactions; changed[0]["acceptedPrimaryUnionVerified"] = false
            broken = revision; broken["transactions"] = changed; rejects(broken, items)
            let originals = transactions[0]["oldItems"] as! [[String: Any]]
            bad = items + [originals.first { $0["id"] as? String != id }!]
            rejects(revision, bad)
            bad = items
            if let other = bad.firstIndex(where: { $0["id"] as? String != id }) {
                bad[other]["text"] = "unrelated target changed"; rejects(revision, bad)
            }
        }
        print("Source revision checks passed: \(assertions)")
    }
}
