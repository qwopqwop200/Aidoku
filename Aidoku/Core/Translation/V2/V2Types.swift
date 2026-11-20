import CoreGraphics
import Foundation

// Shared value types for the speed-first V2 image translation pipeline.
// Every V2 stage consumes and produces these plain values; stages never reach
// into the legacy NativeEngine orchestration, singletons or task-locals.
// See Docs/translation-v2.md for the stage contracts and quality/speed gates.

/// One input page in original-image pixel coordinates (top-left origin).
struct V2Page: Sendable {
    let id: String
    let image: CGImage
    /// The book's reading direction; S4 orders blocks and panels by it.
    var readingDirection: V2ReadingDirection = .rightToLeft
    var width: Int { image.width }
    var height: Int { image.height }
}

/// Block/panel reading order for S4. Manga reads right-to-left, comics and
/// LTR books left-to-right, and vertical strips (webtoon) top-to-bottom.
enum V2ReadingDirection: String, Sendable, Codable, CaseIterable {
    case rightToLeft, leftToRight, topToBottom
}

/// A detected and (after S3) recognized text line.
struct V2Line: Sendable, Codable, Equatable {
    var polygon: [CGPoint]
    var bounds: CGRect
    var vertical: Bool
    var detectionScore: Float
    var text: String = ""
    var confidence: Float = 0
}

enum V2LayoutKind: String, Sendable, Codable {
    case text, sfx, balloon, frame, other
}

/// A layout region from the RF-DETR detector, in page pixels.
struct V2LayoutRegion: Sendable, Codable, Equatable {
    var kind: V2LayoutKind
    var bounds: CGRect
    var score: Float
}

enum V2Role: String, Sendable, Codable {
    /// `narration`: a caption or story text (provider roles narration/story_text); painted
    /// like dialogue except that horizontal lines start at the frame's left edge.
    case dialogue, sfx, background, narration
}

struct V2RGB: Sendable, Codable, Equatable {
    var r: UInt8, g: UInt8, b: UInt8
}

/// Source lettering style used to paint the translation.
struct V2Style: Sendable, Codable, Equatable {
    var fontPixels: CGFloat
    var bold: Bool
    var textColor: V2RGB
    var strokeColor: V2RGB?
    var strokeWidth: CGFloat
}

/// A paragraph/balloon unit: the translation request and paint unit.
struct V2Block: Sendable, Codable, Equatable {
    var id: Int
    var lines: [V2Line]
    var bounds: CGRect
    var polygon: [CGPoint]
    var vertical: Bool
    var readingOrder: Int
    var sourceText: String
    /// Enclosing balloon interior, when one was detected.
    var balloon: CGRect?
    /// Clean half-width per raster row around the source centre (S4b), so S9 can widen
    /// the middle lines of a rounded balloon beyond its inscribed rectangle.
    var rows: V2RowSpans?
    /// The confident RF panel frame holding the block (S4b), which no box may cross.
    var panel: CGRect?
    var role: V2Role = .dialogue
    var translation: String?
    var style: V2Style?
}

/// Symmetric clean spans about `centre` (page x) for rows `top + i * step` (page px).
struct V2RowSpans: Sendable, Codable, Equatable {
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
struct V2PlacedText: Sendable, Codable, Equatable {
    var blockID: Int
    var frame: CGRect
    var fontPixels: CGFloat
    var vertical: Bool
    var lines: [String]
    /// Source tilt in radians (clockwise, about the frame centre); nil when upright.
    /// `frame` is the unrotated text rectangle.
    var angle: CGFloat?
    /// Horizontal scale of every line about the frame centre (0.9 condense); nil when 1.
    var condense: CGFloat?

    /// Painted area: the frame rotated by `angle`.
    var bounds: CGRect { V2Rotation.bounds(frame, angle: angle ?? 0) }
}

/// Per-stage wall-clock milliseconds for one page.
struct V2Timings: Sendable, Codable, Equatable {
    var stages: [String: Double] = [:]
    mutating func record<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { stages[stage, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
        return try body()
    }
    mutating func record<T>(_ stage: String, _ body: () async throws -> T) async rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { stages[stage, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
        return try await body()
    }
}

/// The complete result for one page.
struct V2PageResult: Sendable {
    var pageID: String
    var blocks: [V2Block]
    var placed: [V2PlacedText]
    var output: CGImage?
    var timings: V2Timings
    var failure: String?
}
