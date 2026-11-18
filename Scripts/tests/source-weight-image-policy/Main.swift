import Foundation

@main
struct PolicyParityMain {
    typealias P = NativeSourceWeightImagePolicy
    typealias Row = [String: Any]
    static func decode(_ value: Any) -> Any {
        if let row = value as? Row {
            if row.count == 1, let bits = row["__double__"] as? String {
                return Double(bitPattern: UInt64(bits, radix: 16)!)
            }
            if row.count == 1, let scalar = row["__float__"] as? String {
                return scalar == "nan" ? Double.nan : scalar == "inf" ? Double.infinity : -Double.infinity
            }
            return row.mapValues(decode)
        }
        if let values = value as? [Any] { return values.map(decode) }
        return value
    }
    static func encode(_ value: Any) -> Any {
        if let row = value as? Row { return row.mapValues(encode) }
        if let values = value as? [Any] { return values.map(encode) }
        if let n = value as? NSNumber, !n.doubleValue.isFinite {
            return ["__float__": n.doubleValue.isNaN ? "nan" : n.doubleValue > 0 ? "inf" : "-inf"]
        }
        if let n = value as? NSNumber, ["d", "f"].contains(String(cString: n.objCType)) {
            return ["__double__": String(format: "%016llx", n.doubleValue.bitPattern)]
        }
        return value
    }
    static func run(_ r: Row) throws -> Any {
        let op = r["op"] as! String, policy = r["policy"] as? Row ?? [:]
        let observation = r["observation"] as? Row ?? [:], prior = r["prior"] as? Row ?? [:]
        switch op {
        case "directional":
            let observations = r["observations"] as! [Row], predictions = r["predictions"] as! [Row]
            return ["classifications": try P.classifyDirectionalPage(observations: observations, predictions: predictions, policy: policy),
                    "predictions": try P.applyDirectionalPage(observations: observations, predictions: predictions, policy: policy)]
        case "referenceWord": return try P.referenceWordPasses(r["word"] as! Row, policy: policy)
        case "reference": return try P.applyReference(observation: observation, prediction: prior, policy: policy)
        case "softWord": return try P.softWordPasses(r["word"] as! Row, policy: policy)
        case "softProposes": return try P.softProposes(observation: observation, confidence: (r["confidence"] as! NSNumber).doubleValue, policy: policy)
        case "soft": return try P.applySoft(observation: observation, prior: prior, policy: policy)
        case "orderedProposes": return try P.orderedProposes(observation: observation, confidence: (r["confidence"] as! NSNumber).doubleValue, policy: policy)
        case "ordered": return try P.applyOrdered(observation: observation, prior: prior, policy: policy)
        case "agreement": return try P.regularGlyphAgreement(observation: observation, counts: r["counts"] as! [Int], policy: policy)
        case "outline": return try P.outlineWitness(style: r["style"] as! Row, policy: policy)
        case "counts": return try P.expectedGlyphCounts(members: r["members"] as! [Row])
        default: throw P.Failure.invalid("Unknown test operation")
        }
    }
    static func main() throws {
        let args = CommandLine.arguments
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let records = decode(input) as! [Row]
        let results: [Any] = records.map { record in
            do { return encode(try run(record)) }
            catch { return ["error": String(describing: error)] }
        }
        let output = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        try output.write(to: URL(fileURLWithPath: args[2]))
    }
}
