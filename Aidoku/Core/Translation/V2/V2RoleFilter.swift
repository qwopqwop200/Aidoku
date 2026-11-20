import CoreGraphics
import Foundation

/// Pre-LLM role split. Dialogue recall must stay 1.0, so a block is marked
/// `.sfx` only on unambiguous layout evidence; everything else stays
/// `.dialogue` and the LLM classifies it (including background text).
///
/// Rule (fit on train GT text_role, 0 dialogue/narration lost on train and
/// dev): at least half of the block lies inside a confident RF sound-effect
/// region, less than half inside any confident balloon, and less than 30%
/// inside any RF text region.
enum V2RoleFilter {
    static let sfxScore: Float = 0.8
    static let sfxCoverage: CGFloat = 0.5
    static let balloonScore: Float = 0.5
    static let balloonCoverage: CGFloat = 0.5
    static let textScore: Float = 0.25
    static let textCoverage: CGFloat = 0.3

    /// Fragment rule (fit on train with replayed V2 blocks against GT merged text regions,
    /// checked on dev and the train folds): outside any detected balloon, a block of at most
    /// `fragmentCharacters` non-space characters read with mean confidence below
    /// `fragmentConfidence` is noise or art (rejects 336 non-text blocks on train for 4 lost
    /// one-character fragments of 2333 text blocks; dev 176 of 777 for 3 of 749). It stays
    /// as source pixels: no provider request, no erase, no paint.
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
