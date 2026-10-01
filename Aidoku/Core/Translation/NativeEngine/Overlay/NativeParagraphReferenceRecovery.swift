import Foundation

/// Initial roomy-paragraph proposal, before small-reference admission spends
/// the shared readable allowance. Its separate probe allowance is 512 UTF16 units.
enum NativeParagraphReferenceRecovery {
    struct Entry {
        var text: String
        var font: Double
        var lineHeightRatio: Double
        var usableWidth: Double
        var usableHeight: Double
        var automaticRecovery: Bool
        var hasReference: Bool
        var vertical: Bool
        var sourceVertical: Bool
        var script: String
    }
    struct Proposal { var font: Double; var additionalLines: Int }
    struct Session { var probeRemaining = 512 }

    static func propose(_ entry: Entry, session: inout Session, refinementRemaining: Int, readableRemaining: Int,
                        fitFont: () -> Double, measureLines: (Double) -> Int?) -> Proposal? {
        let length = entry.text.utf16.count
        let words = entry.text.unicodeScalars.split(whereSeparator: { scalar in
            switch scalar.value {
            case 9...13, 32, 160, 5760, 8192...8202, 8232, 8233, 8239, 8287, 12288, 65279: true
            default: false
            }
        }).count
        guard entry.automaticRecovery, !entry.hasReference, !entry.vertical, entry.script == "korean",
              entry.font >= 9, entry.font < 12, length <= session.probeRemaining,
              (length >= 40 && length <= 180 && words >= 8 && entry.usableWidth >= entry.font * 12) ||
                (entry.sourceVertical && entry.font <= 11.5 && length >= 5 && length <= 32 && words >= 2),
              !entry.text.contains("\r"), !entry.text.contains("\n"),
              length <= refinementRemaining, length <= readableRemaining else { return nil }
        session.probeRemaining -= length
        let font = fitFont()
        guard font >= 9, let lines = measureLines(font), lines >= 2 else { return nil }
        let used = Double(lines) * font * entry.lineHeightRatio
        guard used <= entry.usableHeight * 0.5,
              entry.usableHeight - used >= 24 * entry.lineHeightRatio else { return nil }
        return .init(font: font,
                     additionalLines: min(length <= 32 ? 2 : 3, Int(floor((entry.usableHeight - used) / (12 * entry.lineHeightRatio)))))
    }
}
