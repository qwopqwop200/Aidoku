import CoreGraphics
import Foundation

@main struct ReaderTranslationQuotedStackSmoke {
    typealias Fragment = ReaderTranslationQuotedStack.Fragment
    static func main() throws {
        let fragments = [
            Fragment(text: "「はい", rect: CGRect(x: 100, y: 10, width: 20, height: 40), vertical: true, translated: false),
            Fragment(text: "ん", rect: CGRect(x: 106, y: 65, width: 8, height: 14), vertical: false, translated: false),
            Fragment(text: "…", rect: CGRect(x: 107, y: 85, width: 6, height: 10), vertical: false, translated: false),
            Fragment(text: "っ」", rect: CGRect(x: 101, y: 105, width: 18, height: 25), vertical: true, translated: false)
        ]
        var checks = 0
        func check(_ condition: Bool) { precondition(condition); checks += 1 }
        func groups(_ input: [Fragment], blocked: Bool = false) -> [[Int]] {
            ReaderTranslationQuotedStack.groups(input, separates: { _, _ in blocked })
        }
        for scale in [0.5, 1.0, 2.0] {
            let values = fragments.map { Fragment(text: $0.text,
                rect: CGRect(x: $0.rect.minX * scale, y: $0.rect.minY * scale,
                    width: $0.rect.width * scale, height: $0.rect.height * scale), vertical: $0.vertical, translated: false) }
            check(groups(values) == [[0,1,2,3]])
            let reverse = Array(values.reversed())
            check(groups(reverse).map { $0.map { reverse[$0].text }.joined() } == [fragments.map(\.text).joined()])
        }
        check(groups(fragments, blocked: true).isEmpty)
        check(groups(Array(fragments.dropLast())).isEmpty)
        check(groups(fragments.map { Fragment(text: $0.text, rect: $0.rect, vertical: $0.vertical, translated: true) }).isEmpty)
        let obstruction = Fragment(text: "other", rect: CGRect(x: 105, y: 55, width: 9, height: 7), vertical: false, translated: false)
        check(groups(fragments + [obstruction]).isEmpty)
        let adjacent = Fragment(text: "another", rect: CGRect(x: 140, y: 30, width: 20, height: 60), vertical: true, translated: false)
        check(groups(fragments + [adjacent]) == [[0,1,2,3]])
        check(!ReaderTranslationQuotedStack.isBoundedQuote("「first」「second」"))
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let width = root["width"] as! Double, height = root["height"] as! Double
            let regions = root["regions"] as! [[String: Any]]
            let values = regions.map { row -> Fragment in
                let rect = row["rect"] as! [String: Double]
                return Fragment(text: row["source"] as! String,
                    rect: CGRect(x: rect["x"]! * width, y: rect["y"]! * height,
                        width: rect["width"]! * width, height: rect["height"]! * height),
                    vertical: row["sourceOrientation"] as? String == "vertical", translated: false)
            }
            let joined = groups(values)
            check(joined.count == 1 && joined[0].count == values.count)
            print("Cached source pre-translation regrouping:", joined.map { $0.map { values[$0].text }.joined() })
        }
        print("PASS: \(checks) quoted-stack controls; scale/order, boundaries, missing endpoints, copied-result exclusion and foreign-owner protection")
    }
}
