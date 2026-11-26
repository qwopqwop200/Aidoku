import CoreGraphics
import Foundation

/// Pre-LLM role split that never loses dialogue: `.sfx` only when at least half of the block
/// is inside a confident RF SFX region, under half inside any balloon and under 30% inside
/// any RF text region (fit on train GT); everything else is left for the LLM.
enum PipelineRoleFilter {
    static var sfxScore: Float { PipelineTuning.current.roleSFXScore }
    static let sfxCoverage: CGFloat = 0.5
    static var balloonScore: Float { PipelineTuning.current.roleBalloonScore }
    static let balloonCoverage: CGFloat = 0.5
    /// The S1 text floor (a region S1 keeps counts).
    static var textScore: Float { PipelineTuning.current.layoutTextFloor }
    static let textCoverage: CGFloat = 0.3

    /// Fragment rule (fit on train, checked on dev): outside any balloon, a block of at most
    /// `fragmentCharacters` non-space characters with mean confidence below `fragmentConfidence`
    /// is noise or art and keeps its source pixels (no request, erase or paint).
    static var fragmentConfidence: Float { PipelineTuning.current.fragmentConfidence }
    static let fragmentCharacters = 4
    /// Text-content fragments (fit on train folds, lossless under page, size and chunk folds), also
    /// outside balloons and at most `fragmentCharacters` long: Latin-only text below
    /// `latinFragmentConfidence`, and kana-only text (at least `kanaFragmentShare` kana, no kanji or
    /// punctuation) with RF text and balloon evidence (score x coverage) below `kanaFragmentEvidence`.
    static let latinFragmentConfidence: Float = 0.9
    static let kanaFragmentShare = 0.8
    static let kanaFragmentEvidence: CGFloat = 0.3

    /// Paint precision rule (CV-fit on train folds against GT text regions): SFX keeps its source
    /// pixels unless quoted or at least `sfxSpeechLetters` letters long (speech the LLM over-flags),
    /// and so does text without kana/kanji of 1...`latinLetters` letters (page numbers, art labels) unless
    /// the LLM called it dialogue or narration.
    static let sfxSpeechLetters = 16
    static let latinLetters = 8

    static func keepsSource(_ block: PipelineBlock) -> Bool {
        let text = block.sourceText
        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        if block.role == .sfx, letters < sfxSpeechLetters, !text.contains(where: "「」『』".contains) { return true }
        // Short Latin text the LLM calls speech is painted; digits alone (page numbers) stay source.
        if block.role == .dialogue || block.role == .narration, text.contains(where: \.isLetter) { return false }
        return (1...latinLetters).contains(letters) && !text.unicodeScalars.contains {
            PipelineReplyText.isKana($0) || (0x3400...0x9FFF).contains($0.value)
        }
    }

    /// Speech rescue (fit on train folds against GT text regions): short text the LLM called SFX is
    /// still speech when RF-DETR sees it inside a balloon (score x coverage >= `rescueBalloon`) and
    /// not inside an SFX region (score x coverage < `rescueSFX`).
    static var rescueBalloon: CGFloat { PipelineTuning.current.roleRescueBalloon }
    static var rescueSFX: CGFloat { PipelineTuning.current.roleRescueSFX }

    /// Lettering rescue (fit on train folds, held under size and chunk folds): short SFX or background
    /// text inside its S4 balloon is speech when RF text regions (score >= `letteringTextScore`) cover at
    /// least `letteringText` of it, RF SFX evidence stays under `letteringSFX` and every line is upright
    /// (less than `letteringTilt` degrees off the axes; drawn SFX is tilted).
    static let letteringText: CGFloat = 0.5
    static let letteringTextScore: Float = 0.3
    static let letteringSFX: CGFloat = 0.3
    static let letteringTilt: CGFloat = 0.5

    static func rescuingSpeech(_ blocks: [PipelineBlock], layout: [PipelineLayoutRegion]) -> [PipelineBlock] {
        func evidence(_ kind: PipelineLayoutKind, _ bounds: CGRect) -> CGFloat {
            layout.lazy.filter { $0.kind == kind }.map { CGFloat($0.score) * covered(bounds, by: $0.bounds) }.max() ?? 0
        }
        func lettering(_ block: PipelineBlock) -> Bool {
            guard block.balloon != nil, (block.role == .sfx && keepsSource(block)) || block.role == .background else { return false }
            let text = layout.lazy.filter { $0.kind == .text && $0.score >= letteringTextScore }
                .map { covered(block.bounds, by: $0.bounds) }.max() ?? 0
            return text >= letteringText && evidence(.sfx, block.bounds) < letteringSFX
                && block.lines.allSatisfy { tilt($0.polygon) < letteringTilt }
        }
        return blocks.map { block in
            guard block.translation != nil else { return block }
            let speech = block.role == .sfx && keepsSource(block)
                && evidence(.balloon, block.bounds) >= rescueBalloon && evidence(.sfx, block.bounds) < rescueSFX
            guard speech || lettering(block) else { return block }
            var block = block
            block.role = .dialogue
            return block
        }
    }

    /// Degrees the first polygon edge lies off the nearest axis (0 for fewer than four points).
    static func tilt(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 4 else { return 0 }
        let degrees = abs(atan2(polygon[1].y - polygon[0].y, polygon[1].x - polygon[0].x)) * 180 / .pi
        let off = degrees.truncatingRemainder(dividingBy: 90)
        return min(off, 90 - off)
    }

    static func classify(_ blocks: [PipelineBlock], layout: [PipelineLayoutRegion]) -> [PipelineBlock] {
        blocks.map { block in
            var result = block
            result.role = isFragment(block, layout: layout) ? .background : role(of: block.bounds, layout: layout)
            return result
        }
    }

    static func isFragment(_ block: PipelineBlock, layout: [PipelineLayoutRegion] = []) -> Bool {
        guard block.balloon == nil, !block.lines.isEmpty,
              block.sourceText.filter({ !$0.isWhitespace }).count <= fragmentCharacters else { return false }
        let confidence = block.lines.reduce(Float(0)) { $0 + $1.confidence } / Float(block.lines.count)
        return confidence < fragmentConfidence || isTextFragment(block, confidence: confidence, layout: layout)
    }

    /// The two text-content fragment rules (scalars, as fit; the caller checked balloon and length).
    static func isTextFragment(_ block: PipelineBlock, confidence: Float, layout: [PipelineLayoutRegion]) -> Bool {
        let scalars = block.sourceText.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty, scalars.count <= fragmentCharacters else { return false }
        func isKana(_ v: UInt32) -> Bool { (0x3040...0x30FF).contains(v) || (0xFF66...0xFF9D).contains(v) }
        func isHan(_ v: UInt32) -> Bool {
            (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x20000...0x323AF).contains(v)
        }
        func isLatin(_ v: UInt32) -> Bool { (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || (0xC0...0x24F).contains(v) }
        let values = scalars.map(\.value)
        if values.contains(where: { isKana($0) || isHan($0) }) {
            let punctuation = Set("!?！？…‥。、・「」『』～~―ー".unicodeScalars.map(\.value))
            guard !values.contains(where: { isHan($0) || punctuation.contains($0) }) else { return false }
            let kana = values.filter { (0x3040...0x30FF).contains($0) || (0xFF66...0xFF9D).contains($0) }.count
            guard Double(kana) >= kanaFragmentShare * Double(values.count) else { return false }
            let evidence = layout.lazy.filter { $0.kind == .text || $0.kind == .balloon }
                .map { CGFloat($0.score) * covered(block.bounds, by: $0.bounds) }.max() ?? 0
            return evidence < kanaFragmentEvidence
        }
        let letters = scalars.filter(\.properties.isAlphabetic)
        return !letters.isEmpty && letters.allSatisfy { isLatin($0.value) } && confidence < latinFragmentConfidence
    }

    static func role(of bounds: CGRect, layout: [PipelineLayoutRegion]) -> PipelineRole {
        func coverage(_ kind: PipelineLayoutKind, _ score: Float) -> CGFloat {
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
