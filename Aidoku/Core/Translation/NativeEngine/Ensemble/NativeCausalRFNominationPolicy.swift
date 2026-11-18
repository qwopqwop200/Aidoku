import CoreGraphics
import Foundation

/// Recognition scheduling only. Never changes primary packets or read acceptance.
struct NativeCausalRFNominationPolicy: Equatable, Sendable {
    let supportFloor: Double
    let ownerCountExponent: Double
    let admitsEstimatedSingleGlyph: Bool
    let cropBudget: Int
    static let legacy = Self(supportFloor: 0.55, ownerCountExponent: 0,
        admitsEstimatedSingleGlyph: false, cropBudget: 8)
    var maximumPlans: Int { cropBudget == 32 ? 4 : 2 }
    var cacheVersion: String {
        "rf-nomination-v146:floor=\(supportFloor):p=\(ownerCountExponent):axis=\(admitsEstimatedSingleGlyph):crops=\(cropBudget)"
    }

    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let floor = Double(environment["AIDOKU_OCR_RF_PARAGRAPH_SUPPORT_FLOOR"] ?? "")
        let exponent = Double(environment["AIDOKU_OCR_RF_PARAGRAPH_OWNER_EXPONENT"] ?? "")
        return Self(supportFloor: floor.flatMap { [0.30, 0.40, 0.55].contains($0) ? $0 : nil } ?? 0.55,
            ownerCountExponent: exponent.flatMap { [0, 0.5, 1].contains($0) ? $0 : nil } ?? 0,
            admitsEstimatedSingleGlyph: environment["AIDOKU_OCR_RF_PARAGRAPH_ESTIMATED_GLYPH_AXIS"] == "1",
            cropBudget: environment["AIDOKU_OCR_RF_PARAGRAPH_CROP_BUDGET"] == "32" ? 32 : 8)
    }

    struct AxisPacket {
        let text: String
        let vertical: Bool
        let horizontal: Bool
        let estimated: Bool
        let polygon: [CGPoint]
    }

    /// A genuine vertical companion in this SAME owner supplies the axis;
    /// neither the horizontal packet nor its original metadata is rewritten.
    func permitsVerticalOwner(_ packets: [AxisPacket]) -> Bool {
        guard !packets.isEmpty else { return false }
        if packets.allSatisfy(\.vertical) { return true }
        guard admitsEstimatedSingleGlyph else { return false }
        let uncertain = packets.filter { !$0.vertical }
        guard uncertain.count == 1, let glyph = uncertain.first,
              glyph.horizontal, glyph.estimated, glyph.text.count == 1,
              let g = Self.bounds(glyph.polygon), g.width / g.height >= 0.5,
              g.width / g.height <= 2 else { return false }
        return packets.contains { companion in
            guard companion.vertical, let c = Self.bounds(companion.polygon) else { return false }
            let gap = max(0, max(c.minY - g.maxY, g.minY - c.maxY))
            return min(c.maxX, g.maxX) > max(c.minX, g.minX) &&
                abs(c.midX - g.midX) <= min(c.width, g.width) * 0.5 &&
                gap <= max(c.width, g.width) * 3
        }
    }

    func ranked(_ supports: [NativeCausalRFParagraphRecognition.Support],
                owners: [NativeCausalRFParagraphRecognition.Owner]) -> [NativeCausalRFParagraphRecognition.Support] {
        // Preserve the exact legacy confidence ordering unless opted in.
        guard ownerCountExponent != 0 else { return supports.sorted { $0.confidence > $1.confidence } }
        func score(_ support: NativeCausalRFParagraphRecognition.Support) -> Double {
            let count = owners.filter { $0.bounds.intersects(support.bounds) }.count
            guard support.confidence.isFinite, count >= 2 else { return -.infinity }
            return support.confidence / pow(Double(count), ownerCountExponent)
        }
        return supports.sorted {
            let a = score($0), b = score($1)
            if a != b { return a > b }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.queryID < $1.queryID
        }
    }

    private static func bounds(_ polygon: [CGPoint]) -> CGRect? {
        guard polygon.count >= 3, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        let result = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return result.width > 0 && result.height > 0 ? result : nil
    }
}
