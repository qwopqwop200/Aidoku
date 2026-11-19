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
    var width: Int { image.width }
    var height: Int { image.height }
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
    /// Optional binary mask covering `bounds` (row-major, width = Int(bounds.width)).
    var mask: [UInt8]?
}

enum V2Role: String, Sendable, Codable {
    case dialogue, sfx, background
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
    var role: V2Role = .dialogue
    var translation: String?
    var style: V2Style?
}

/// Output of the layout stage for one block.
struct V2PlacedText: Sendable, Codable, Equatable {
    var blockID: Int
    var frame: CGRect
    var fontPixels: CGFloat
    var vertical: Bool
    var lines: [String]
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
    var removalMask: [UInt8]?
    var timings: V2Timings
    var failure: String?
}
