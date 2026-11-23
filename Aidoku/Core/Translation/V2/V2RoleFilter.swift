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

    /// Paint precision rule (CV-fit on train folds against GT text regions): SFX keeps its source
    /// pixels unless quoted or at least `sfxSpeechLetters` letters long (speech the LLM over-flags),
    /// and so does text without kana/kanji of 1...`latinLetters` letters (page numbers, art labels).
    static let sfxSpeechLetters = 16
    static let latinLetters = 8

    static func keepsSource(_ block: V2Block) -> Bool {
        let text = block.sourceText
        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        if block.role == .sfx, letters < sfxSpeechLetters, !text.contains(where: "「」『』".contains) { return true }
        return (1...latinLetters).contains(letters) && !text.unicodeScalars.contains {
            V2ReplyText.isKana($0) || (0x3400...0x9FFF).contains($0.value)
        }
    }

    /// Speech rescue (fit on train folds against GT text regions): short text the LLM called SFX is
    /// still speech when RF-DETR sees it inside a balloon (score x coverage >= `rescueBalloon`) and
    /// not inside an SFX region (score x coverage < `rescueSFX`). Train folds: 15 of 21 such speech
    /// blocks painted, 1 of 441 SFX wrongly painted; held-out dev+test 3 rescued, 1 wrong.
    static let rescueBalloon: CGFloat = 0.5
    static let rescueSFX: CGFloat = 0.1

    static func rescuingSpeech(_ blocks: [V2Block], layout: [V2LayoutRegion]) -> [V2Block] {
        func evidence(_ kind: V2LayoutKind, _ bounds: CGRect) -> CGFloat {
            layout.lazy.filter { $0.kind == kind }.map { CGFloat($0.score) * covered(bounds, by: $0.bounds) }.max() ?? 0
        }
        return blocks.map { block in
            guard block.role == .sfx, block.translation != nil, keepsSource(block),
                  evidence(.balloon, block.bounds) >= rescueBalloon, evidence(.sfx, block.bounds) < rescueSFX else { return block }
            var block = block
            block.role = .dialogue
            return block
        }
    }

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
