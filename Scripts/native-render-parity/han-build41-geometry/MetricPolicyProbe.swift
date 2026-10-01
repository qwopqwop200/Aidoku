import Foundation

@main enum MetricPolicyProbe {
    static func main() throws {
        let rows = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
        let result = rows.map { row -> [String: Any] in
            let metrics = NativeVerticalGlyphOrigins.iosMetrics(ascent: row["ascent"] as! Double,
                descent: row["descent"] as! Double, leading: row["leading"] as! Double,
                familyName: row["family"] as! String)!
            let baseline = NativeVerticalGlyphOrigins.ideographicCellBaseline(cellRight: Float(row["right"] as! Double),
                pitch: Float(row["pitch"] as! Double), metrics: metrics.primary)!
            return ["ascent": Double(metrics.primary.ascent), "descent": Double(metrics.primary.descent),
                    "leading": Double(metrics.leading), "spacing": Double(metrics.lineSpacing),
                    "baseline": Double(baseline)]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
