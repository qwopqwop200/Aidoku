import Foundation

/// Knobs fitted to the current models' outputs, to re-fit when a model changes (port-eval/retune/retune.py).
/// The app runs these defaults; only the Mac host overrides them before its first page (AIDOKU_PIPELINE_TUNING).
struct PipelineTuning: Equatable, Sendable {
    /// S1 RF-DETR per-class score floors (model class order: text, SFX, frame); balloon is `balloonFloor`.
    var layoutTextFloor: Float = 0.25
    var layoutSFXFloor: Float = 0.20
    var layoutFrameFloor: Float = 0.50
    /// Least balloon score S1 keeps and S2b/S4/S4b use (fit against GT balloon masks; 0.35-0.45 is a plateau).
    var balloonFloor: Float = 0.40
    /// S2 PP-OCR DB binarization, box score and unclip (`NativeCoreMLDBPostprocessConfiguration.manga`).
    var detectionThreshold: Double = 0.85
    var detectionBoxThreshold: Double = 0.25
    var detectionUnclipRatio: Double = 1.4
    /// S2 detector canvas: the page's long side is scaled down to at most this (stride 32).
    var detectionMaximumSide = 1_120
    /// S2b minimum cross-axis overlap of two fragments, in thinner-fragment thicknesses.
    var assemblyMinimumOverlap: CGFloat = 0.6
    /// S2b maximum along-axis gap between two fragments, in thinner-fragment thicknesses.
    var assemblyMaximumGap: CGFloat = 1.5
    /// S3 acceptance: a recognized line below this mean CTC confidence is dropped (legacy manga gate).
    var recognitionMinimumConfidence = 0.30
    /// S3 crop: a text line (long >= 1.5 x short) is padded short / this on each side.
    var recognitionLinePadDivisor: CGFloat = 20
    /// S3 line keep gate: its fitted threshold times this (0 keeps every line, as for retraining the gate).
    var lineKeepScale = 1.0
    /// S3 recognition: mean confidence under which a short block outside balloons is a fragment.
    var fragmentConfidence: Float = 0.6
    /// S4 roles on RF-DETR scores: SFX / balloon region score cuts before coverage counts, and the
    /// speech rescue cuts on score x coverage (balloon at least, SFX below).
    var roleSFXScore: Float = 0.8
    var roleBalloonScore: Float = 0.5
    var roleRescueBalloon: CGFloat = 0.5
    var roleRescueSFX: CGFloat = 0.1
    /// S4b interior growth reach per side, in source line thicknesses.
    var interiorHorizontalReach: CGFloat = 8
    var interiorVerticalReach: CGFloat = 3
    /// S4b: RF frame score a panel needs to bound the growth.
    var interiorFrameScore: Float = 0.7
    /// S6 glyph probability cut and output dilation (px).
    var maskThreshold: Float = 0.15
    var maskDilation = 2
    /// S6 line ends: boxes searched this many thicknesses past each end, and the margin added to the
    /// line-end regressor's prediction.
    var lineEndExtension = 0.5
    var lineEndMargin = 0.35
    /// S8 font size: global log level on the geometric estimate (`PipelineFontCorrection`).
    var fontLevel = 0.02845
    /// S9 (fitted on the typesetting score, tools/typeset_score.py). Fit box: inset of the balloon interior, as a
    /// share of its short side.
    var layoutBalloonInset: CGFloat = 0.02
    /// S9 fit cap in a balloon, relative to the source lettering size.
    var layoutBalloonCap: CGFloat = 1.05
    /// S9: smallest whole-word size, relative to the split-word size, preferred over splitting a word.
    var layoutWholeWordRatio: CGFloat = 0.8
    /// S9: a tall paragraph in a balloon keeps its lines within this many source widths.
    var layoutTallWidth: CGFloat = 1.7
    /// S9 cohorts: 1 = every family takes the page's smallest family step, 0 = each family keeps its own.
    var layoutPageScale = 0.0
    /// S9 cohorts: share of a family's members that must reach the family step; the tightest rest keep their own fit.
    var layoutFamilyShare = 0.7
    /// S9: a fit that cuts a word is replaced by a whole-word fit along the balloon's row spans at no less than
    /// this share of its size (0 = off).
    var layoutSpanWhole: CGFloat = 0.9

    /// The set every stage reads. Written only by the host before any page runs.
    nonisolated(unsafe) static var current = PipelineTuning()

    /// Field names as `retune.py` and AIDOKU_PIPELINE_TUNING spell them.
    static let keys = PipelineTuning().values.keys.sorted()

    /// Every field by name (for logs and run summaries).
    var values: [String: Double] {
        [
            "layoutTextFloor": Double(layoutTextFloor),
            "layoutSFXFloor": Double(layoutSFXFloor),
            "layoutFrameFloor": Double(layoutFrameFloor),
            "balloonFloor": Double(balloonFloor),
            "detectionThreshold": detectionThreshold,
            "detectionBoxThreshold": detectionBoxThreshold,
            "detectionUnclipRatio": detectionUnclipRatio,
            "detectionMaximumSide": Double(detectionMaximumSide),
            "assemblyMinimumOverlap": Double(assemblyMinimumOverlap),
            "assemblyMaximumGap": Double(assemblyMaximumGap),
            "recognitionMinimumConfidence": recognitionMinimumConfidence,
            "recognitionLinePadDivisor": Double(recognitionLinePadDivisor),
            "lineKeepScale": lineKeepScale,
            "fragmentConfidence": Double(fragmentConfidence),
            "roleSFXScore": Double(roleSFXScore),
            "roleBalloonScore": Double(roleBalloonScore),
            "roleRescueBalloon": Double(roleRescueBalloon),
            "roleRescueSFX": Double(roleRescueSFX),
            "interiorHorizontalReach": Double(interiorHorizontalReach),
            "interiorVerticalReach": Double(interiorVerticalReach),
            "interiorFrameScore": Double(interiorFrameScore),
            "maskThreshold": Double(maskThreshold),
            "maskDilation": Double(maskDilation),
            "lineEndExtension": lineEndExtension,
            "lineEndMargin": lineEndMargin,
            "fontLevel": fontLevel,
            "layoutBalloonInset": Double(layoutBalloonInset),
            "layoutBalloonCap": Double(layoutBalloonCap),
            "layoutWholeWordRatio": Double(layoutWholeWordRatio),
            "layoutTallWidth": Double(layoutTallWidth),
            "layoutPageScale": layoutPageScale,
            "layoutFamilyShare": layoutFamilyShare,
            "layoutSpanWhole": Double(layoutSpanWhole),
        ]
    }

    /// Sets the field `key` to `value`; false for an unknown key.
    mutating func set(_ key: String, _ value: Double) -> Bool {
        switch key {
        case "layoutTextFloor": layoutTextFloor = Float(value)
        case "layoutSFXFloor": layoutSFXFloor = Float(value)
        case "layoutFrameFloor": layoutFrameFloor = Float(value)
        case "balloonFloor": balloonFloor = Float(value)
        case "detectionThreshold": detectionThreshold = value
        case "detectionBoxThreshold": detectionBoxThreshold = value
        case "detectionUnclipRatio": detectionUnclipRatio = value
        case "detectionMaximumSide": detectionMaximumSide = Int(value.rounded())
        case "assemblyMinimumOverlap": assemblyMinimumOverlap = CGFloat(value)
        case "assemblyMaximumGap": assemblyMaximumGap = CGFloat(value)
        case "recognitionMinimumConfidence": recognitionMinimumConfidence = value
        case "recognitionLinePadDivisor": recognitionLinePadDivisor = CGFloat(value)
        case "lineKeepScale": lineKeepScale = value
        case "fragmentConfidence": fragmentConfidence = Float(value)
        case "roleSFXScore": roleSFXScore = Float(value)
        case "roleBalloonScore": roleBalloonScore = Float(value)
        case "roleRescueBalloon": roleRescueBalloon = CGFloat(value)
        case "roleRescueSFX": roleRescueSFX = CGFloat(value)
        case "interiorHorizontalReach": interiorHorizontalReach = CGFloat(value)
        case "interiorVerticalReach": interiorVerticalReach = CGFloat(value)
        case "interiorFrameScore": interiorFrameScore = Float(value)
        case "maskThreshold": maskThreshold = Float(value)
        case "maskDilation": maskDilation = Int(value.rounded())
        case "lineEndExtension": lineEndExtension = value
        case "lineEndMargin": lineEndMargin = value
        case "fontLevel": fontLevel = value
        case "layoutBalloonInset": layoutBalloonInset = CGFloat(value)
        case "layoutBalloonCap": layoutBalloonCap = CGFloat(value)
        case "layoutWholeWordRatio": layoutWholeWordRatio = CGFloat(value)
        case "layoutTallWidth": layoutTallWidth = CGFloat(value)
        case "layoutPageScale": layoutPageScale = value
        case "layoutFamilyShare": layoutFamilyShare = value
        case "layoutSpanWhole": layoutSpanWhole = CGFloat(value)
        default: return false
        }
        return true
    }
}
