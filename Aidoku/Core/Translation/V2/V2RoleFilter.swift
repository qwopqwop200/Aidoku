import CoreGraphics
import Foundation

/// Pre-LLM role split that never loses dialogue: `.sfx` only when at least half of the block
/// is inside a confident RF SFX region, under half inside any balloon and under 30% inside
/// any RF text region (fit on train GT); everything else is left for the LLM.
enum V2RoleFilter {
    static let sfxScore: Float = 0.8
    static let sfxCoverage: CGFloat = 0.5
    static let balloonScore: Float = 0.5
    static let balloonCoverage: CGFloat = 0.5
    static let textScore: Float = 0.25
    static let textCoverage: CGFloat = 0.3

    /// Fragment rule (fit on train, checked on dev): outside any balloon, a block of at most
    /// `fragmentCharacters` non-space characters with mean confidence below `fragmentConfidence`
    /// is noise or art and keeps its source pixels (no request, erase or paint).
    static let fragmentConfidence: Float = 0.6
    static let fragmentCharacters = 4

    static func classify(_ blocks: [V2Block], layout: [V2LayoutRegion]) -> [V2Block] {
        blocks.map { block in
            var result = block
            result.role = isFragment(block) ? .background : role(of: block.bounds, layout: layout)
            return result
        }
    }

    static func isFragment(_ block: V2Block) -> Bool {
        guard block.balloon == nil, !block.lines.isEmpty,
              block.sourceText.filter({ !$0.isWhitespace }).count <= fragmentCharacters else { return false }
        let confidence = block.lines.reduce(Float(0)) { $0 + $1.confidence } / Float(block.lines.count)
        return confidence < fragmentConfidence
    }

    static func role(of bounds: CGRect, layout: [V2LayoutRegion]) -> V2Role {
        func coverage(_ kind: V2LayoutKind, _ score: Float) -> CGFloat {
            layout.lazy.filter { $0.kind == kind && $0.score >= score }
                .map { covered(bounds, by: $0.bounds) }.max() ?? 0
        }
        return coverage(.sfx, sfxScore) >= sfxCoverage
            && coverage(.balloon, balloonScore) < balloonCoverage
            && coverage(.text, textScore) < textCoverage ? .sfx : .dialogue
    }

    /// Fraction of `box` inside `region`.
    static func covered(_ box: CGRect, by region: CGRect) -> CGFloat {
        guard !box.isNull, box.width > 0, box.height > 0 else { return 0 }
        let overlap = box.intersection(region)
        return overlap.isNull ? 0 : overlap.width * overlap.height / (box.width * box.height)
    }
}
