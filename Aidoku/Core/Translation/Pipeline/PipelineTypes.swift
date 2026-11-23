import CoreGraphics
import Foundation

// Plain values shared by the pipeline stages.

/// One input page in original-image pixel coordinates (top-left origin).
struct PipelinePage: Sendable {
    let id: String
    let image: CGImage
    /// The book's reading direction; S4 orders blocks and panels by it.
    var readingDirection: PipelineReadingDirection = .rightToLeft
    var width: Int { image.width }
    var height: Int { image.height }
}

/// Block/panel reading order for S4 (manga, comics, webtoon strips).
enum PipelineReadingDirection: String, Sendable, Codable, CaseIterable {
    case rightToLeft, leftToRight, topToBottom
}

/// A detected and (after S3) recognized text line.
struct PipelineLine: Sendable, Codable, Equatable {
    var polygon: [CGPoint]
    var bounds: CGRect
    var vertical: Bool
    var detectionScore: Float
    var text: String = ""
    var confidence: Float = 0
}

enum PipelineLayoutKind: String, Sendable, Codable {
    case text, sfx, balloon, frame, other
}

/// A layout region from the RF-DETR detector, in page pixels.
struct PipelineLayoutRegion: Sendable, Codable, Equatable {
    var kind: PipelineLayoutKind
    var bounds: CGRect
    var score: Float

    /// Least balloon score S1 keeps and S2b/S4/S4b use (fit on train folds against GT balloon masks:
    /// recall 0.90 -> 0.93 at IoU 0.5, GT text-in-balloon disagreements 70 -> 37; 0.35-0.45 is an
    /// end-to-end plateau).
    static let balloonFloor: Float = 0.40
}

enum PipelineRole: String, Sendable, Codable {
    /// `narration`: captions/story text, painted like dialogue but left-aligned when horizontal.
    case dialogue, sfx, background, narration
}

struct PipelineRGB: Sendable, Codable, Equatable {
    var r: UInt8, g: UInt8, b: UInt8
}

/// Source lettering style used to paint the translation.
struct PipelineStyle: Sendable, Codable, Equatable {
    var fontPixels: CGFloat
    var bold: Bool
    var textColor: PipelineRGB
    var strokeColor: PipelineRGB?
    var strokeWidth: CGFloat
}

/// A paragraph/balloon unit: the translation request and paint unit.
struct PipelineBlock: Sendable, Codable, Equatable {
    var id: Int
    var lines: [PipelineLine]
    var bounds: CGRect
    var polygon: [CGPoint]
    var vertical: Bool
    var readingOrder: Int
    var sourceText: String
    /// Enclosing balloon interior, when one was detected.
    var balloon: CGRect?
    /// Clean half-width per raster row around the source centre (S4b), so S9 can widen
    /// the middle lines of a rounded balloon beyond its inscribed rectangle.
    var rows: PipelineRowSpans?
    /// The confident RF panel frame holding the block (S4b), which no box may cross.
    var panel: CGRect?
    var role: PipelineRole = .dialogue
    var translation: String?
    var style: PipelineStyle?
}

/// Symmetric clean spans about `centre` (page x) for rows `top + i * step` (page px).
struct PipelineRowSpans: Sendable, Codable, Equatable {
    var top: CGFloat
    var step: CGFloat
    var centre: CGFloat
    var halfWidths: [CGFloat]

    var bottom: CGFloat { top + CGFloat(halfWidths.count) * step }

    /// The narrowest half-width over the rows that [y0, y1) touches; 0 outside the spans.
    func halfWidth(_ y0: CGFloat, _ y1: CGFloat) -> CGFloat {
        guard step > 0, y0 >= top - 0.01, y1 <= bottom + 0.01, y1 > y0 else { return 0 }
        let first = max(0, Int(((y0 - top) / step).rounded(.down)))
        let last = min(halfWidths.count - 1, Int(((y1 - top) / step).rounded(.up)) - 1)
        guard first <= last else { return 0 }
        return halfWidths[first...last].min() ?? 0
    }
}

/// Output of the layout stage for one block.
struct PipelinePlacedText: Sendable, Codable, Equatable {
    var blockID: Int
    var frame: CGRect
    var fontPixels: CGFloat
    var vertical: Bool
    var lines: [String]
    /// Source tilt in radians (clockwise, about the frame centre) of the unrotated `frame`; nil when upright.
    var angle: CGFloat?
    /// Horizontal scale of every line about the frame centre (0.9 condense); nil when 1.
    var condense: CGFloat?
    /// Line alignment chosen by the size cohort's majority (true = left); nil = by role.
    var leading: Bool?

    /// Painted area: the frame rotated by `angle`.
    var bounds: CGRect { PipelineRotation.bounds(frame, angle: angle ?? 0) }
}

/// Per-stage wall-clock milliseconds for one page.
struct PipelineTimings: Sendable, Codable, Equatable {
    var stages: [String: Double] = [:]
    mutating func record<T>(_ stage: String, _ body: () async throws -> T) async rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { stages[stage, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
        return try await body()
    }
}

/// The complete result for one page.
struct PipelinePageResult: Sendable {
    var pageID: String
    var blocks: [PipelineBlock]
    var placed: [PipelinePlacedText]
    var output: CGImage?
    var timings: PipelineTimings
    var failure: String?
}
