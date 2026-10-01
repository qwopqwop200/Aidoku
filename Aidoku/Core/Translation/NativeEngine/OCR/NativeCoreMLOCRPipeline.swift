// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLSharedLoadAccess<Value: Sendable>: Sendable {
    let value: Value
    /// True only for the caller that created the shared load task. A recognizer
    /// joining preparation reports zero model-load time in OCR diagnostics.
    let initiatedLoad: Bool
}

/// An explicit preparation lifetime. Frame cancellation intentionally leaves
/// this revision alone so a newer frame can reuse an in-flight specialization;
/// OCR OFF and resource purge invalidate it before any store is cleared.
@available(iOS 18.0, *)
final class NativeCoreMLPreparationRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func token() -> UInt64 {
        lock.withLock { value }
    }

    func invalidate() {
        lock.withLock { value &+= 1 }
    }

    func requireCurrent(_ token: UInt64) throws {
        try Task.checkCancellation()
        let isCurrent = lock.withLock { value == token }
        guard isCurrent else { throw CancellationError() }
    }
}

/// Coalesces one Core ML function specialization per key. Frame cancellation
/// does not cancel this reusable work; only the explicit resource-purge
/// boundary cancels pending tasks and advances the revision.
@available(iOS 18.0, *)
actor NativeCoreMLSharedLoadCoordinator<
    Key: Hashable & Sendable,
    Value: Sendable
> {
    private struct Pending: Sendable {
        let revision: UInt64
        let token: UInt64
        let task: Task<Value, Error>
    }

    private var revision: UInt64 = 0
    private var nextToken: UInt64 = 0
    private var pending: [Key: Pending] = [:]

    func load(
        for key: Key,
        using loader: @escaping @Sendable () async throws -> Value
    ) async throws -> NativeCoreMLSharedLoadAccess<Value> {
        let issuedRevision = revision
        let entry: Pending
        let initiatedLoad: Bool
        if let existing = pending[key],
           existing.revision == issuedRevision {
            entry = existing
            initiatedLoad = false
        } else {
            nextToken &+= 1
            let task = Task { try await loader() }
            entry = Pending(
                revision: issuedRevision,
                token: nextToken,
                task: task
            )
            pending[key] = entry
            initiatedLoad = true
        }

        let value: Value
        do {
            value = try await entry.task.value
        } catch {
            if pending[key]?.token == entry.token {
                pending[key] = nil
            }
            throw error
        }
        guard revision == issuedRevision else {
            throw CancellationError()
        }
        if pending[key]?.token == entry.token {
            pending[key] = nil
        }
        return NativeCoreMLSharedLoadAccess(
            value: value,
            initiatedLoad: initiatedLoad
        )
    }

    func purge() {
        revision &+= 1
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll(keepingCapacity: false)
    }
}

@available(iOS 18.0, *)
protocol NativeCoreMLDetecting: Sendable {
    func prepare(
        sourceWidth: Int,
        sourceHeight: Int
    ) async throws

    /// Loads the model without a shape-specific warm-up prediction.
    func warmUpModel() async throws

    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult

    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        recognitionScopes: [CGRect]?,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult

    func cancelCurrent()
    func cancelPreparation()
    func purgeResources() async
}

@available(iOS 18.0, *)
extension NativeCoreMLDetector: NativeCoreMLDetecting {}

@available(iOS 18.0, *)
extension NativeCoreMLDetecting {
    func prepare(
        sourceWidth: Int,
        sourceHeight: Int
    ) async throws {}
    func warmUpModel() async throws {}
    func cancelPreparation() {}

    /// Non-native test and fallback detectors retain full postprocessing. The
    /// production Core ML detector overrides this requirement to materialize
    /// and decode a safe dirty-scope output window.
    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        recognitionScopes: [CGRect]?,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult {
        _ = recognitionScopes
        return try await detect(
            frame: frame,
            requestID: requestID,
            configuration: configuration,
            cancellationCheck: cancellationCheck
        )
    }
}

@available(iOS 18.0, *)
protocol NativeCoreMLRecognizing: Sendable {
    func prepare() async throws
    func prepareIdlePreservingDemandCapacity() async throws

    func recognize(
        frame: NativeOCRRGBAFrame,
        regions: [NativeCoreMLRecognitionRegion],
        requestID: String,
        confidenceThreshold: Double,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLRecognitionResult

    func cancelCurrent()
    func cancelPreparation()
    func purgeResources() async
}

@available(iOS 18.0, *)
extension NativeCoreMLRecognizer: NativeCoreMLRecognizing {}

@available(iOS 18.0, *)
extension NativeCoreMLRecognizing {
    func prepare() async throws {}
    func prepareIdlePreservingDemandCapacity() async throws {}
    func cancelPreparation() {}
}

@available(iOS 18.0, *)
private final class NativeCoreMLOCRGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        value &+= 1
        let issued = value
        lock.unlock()
        return issued
    }

    func cancelCurrent() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    func cancel(ifCurrent generation: UInt64) {
        lock.lock()
        if value == generation {
            value &+= 1
        }
        lock.unlock()
    }

    func requireCurrent(_ issued: UInt64) throws {
        try Task.checkCancellation()
        lock.lock()
        let isCurrent = value == issued
        lock.unlock()
        guard isCurrent else { throw CancellationError() }
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLOCRLine: Equatable, Sendable {
    let polygon: [CGPoint]
    let text: String
    let score: Double
    let orientation: BrowserOCRSourceOrientation
    /// Aspect-ratio estimates may be revised using neighbouring glyphs. An
    /// explicit writing-direction hint must survive fragment grouping.
    let orientationIsEstimated: Bool
    /// Page-space tile bounds, supplied by tiled readers after offsetting the
    /// polygon. The merger uses interior edges to identify truncated retries.
    let sourceTileBounds: CGRect?
    let erasurePolygons: [[CGPoint]]

    init(
        polygon: [CGPoint],
        text: String,
        score: Double,
        orientation: BrowserOCRSourceOrientation,
        orientationIsEstimated: Bool = false,
        sourceTileBounds: CGRect? = nil,
        erasurePolygons: [[CGPoint]] = []
    ) {
        self.polygon = polygon
        self.text = text
        self.score = score
        self.orientation = orientation
        self.orientationIsEstimated = orientationIsEstimated
        self.sourceTileBounds = sourceTileBounds
        self.erasurePolygons = erasurePolygons
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLOCRPipelineDiagnostics: Equatable, Sendable {
    let backend: String
    let frameConversionMilliseconds: Double
    let detectionProvider: String
    let recognitionProvider: String
    let detectionComputeUnits: String
    let recognitionComputeUnits: String
    let detectionModel: String
    let recognitionModel: String
    let detection: NativeCoreMLDetectionDiagnostics
    let recognition: NativeCoreMLRecognitionDiagnostics?
}

@available(iOS 18.0, *)
struct NativeCoreMLOCRResult: Equatable, Sendable {
    let requestID: String
    let width: Int
    let height: Int
    let lines: [NativeCoreMLOCRLine]
    let frameConversionMilliseconds: Double
    let detectionMilliseconds: Double
    let recognitionMilliseconds: Double
    let totalMilliseconds: Double
    let detectedBoxes: Int
    let selectedBoxes: Int
    let diagnostics: NativeCoreMLOCRPipelineDiagnostics
    /// Rejected CJK reads lying next to an accepted line (weak detector boxes or reads below the
    /// confidence threshold). Not part of `lines`: the caller admits them only with image evidence
    /// that they share the accepted line's surface (`NativeOCRAdjacentLineRecovery`).
    var recoveryCandidates: [NativeCoreMLOCRLine] = []
    /// Lines read in a gap between two accepted lines where the detector found no box
    /// (`NativeOCRGapLineRecovery`). Not part of `lines`; admitted by the caller like recovery candidates.
    var gapLines: [NativeCoreMLOCRGapLine] = []
    /// Kana/Han reads of strong detector boxes just below the confidence threshold with no accepted line
    /// beside them (`NativeOCRIsolatedLineRecovery`). Not part of `lines`; the caller adds them as new captions.
    var isolatedLines: [NativeCoreMLOCRLine] = []
    /// Rows of a split lettering stack (`NativeOCRStackedRowSplit`). Not part of `lines`; the caller adds each
    /// stack as a recovered caption of its own.
    var splitLines: [NativeCoreMLOCRLine] = []
    /// Time spent on the stacked-row split (pixel proposals and their extra recognizer batch).
    var stackedRowSplitMilliseconds: Double = 0
    /// Time of the lettering-unit pass (`NativeOCRLetteringUnitRecovery`) and the lines it completed.
    var unitMilliseconds: Double = 0
    var unitLineCount = 0
}

@available(iOS 18.0, *)
enum NativeOCRScopeGeometry {
    /// Clockwise quad with its upper cross-edge first. Sorting into left/right
    /// halves turns a clockwise-leaning vertical crop upside down. Select an
    /// actual edge instead, independent of the detector's starting vertex.
    static func canonicalQuad(_ points: [CGPoint], vertical: Bool? = nil) -> [CGPoint]? {
        guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let center = CGPoint(x: points.reduce(0) { $0 + $1.x } / 4,
                             y: points.reduce(0) { $0 + $1.y } / 4)
        let ordered = points.sorted { atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x) }
        let lengths = (0..<4).map { hypot(ordered[($0 + 1) % 4].x - ordered[$0].x, ordered[($0 + 1) % 4].y - ordered[$0].y) }
        guard let shortest = lengths.min(), let longest = lengths.max(), shortest > 0 else { return nil }
        let candidates = (0..<4).filter { i in
            let dx = ordered[(i + 1) % 4].x - ordered[i].x
            guard dx > 0 else { return false }
            guard let vertical, longest > shortest * 1.25 else { return true }
            return vertical ? lengths[i] < (shortest + longest) / 2 : lengths[i] > (shortest + longest) / 2
        }
        guard let start = candidates.min(by: { a, b in
            abs(ordered[(a + 1) % 4].y - ordered[a].y) / lengths[a]
                < abs(ordered[(b + 1) % 4].y - ordered[b].y) / lengths[b]
        }) else { return nil }
        return (0..<4).map { ordered[(start + $0) % 4] }
    }

    static func isLatinWord(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.count >= 2 && letters.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
    }

    static func alternateHorizontalQuad(_ points: [CGPoint]) -> [CGPoint]? {
        guard let canonical = canonicalQuad(points) else { return nil }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        let left = Array(sorted.prefix(2)).sorted { $0.y < $1.y }
        let right = Array(sorted.suffix(2)).sorted { $0.y < $1.y }
        let alternate = [left[0], right[0], right[1], left[1]]
        let width = hypot(alternate[1].x - alternate[0].x, alternate[1].y - alternate[0].y)
        let height = hypot(alternate[3].x - alternate[0].x, alternate[3].y - alternate[0].y)
        let a = atan2(alternate[1].y - alternate[0].y, alternate[1].x - alternate[0].x)
        let b = atan2(canonical[1].y - canonical[0].y, canonical[1].x - canonical[0].x)
        guard width >= height * 1.1, abs(a) >= .pi / 60, abs(a) <= 80 * .pi / 180,
              abs(a - b) > .pi / 3 else { return nil }
        return alternate
    }

    static func bounds(for polygon: [CGPoint]) -> CGRect? {
        guard let minimumX = polygon.map(\.x).min(),
              let maximumX = polygon.map(\.x).max(),
              let minimumY = polygon.map(\.y).min(),
              let maximumY = polygon.map(\.y).max(),
              minimumX.isFinite,
              maximumX.isFinite,
              minimumY.isFinite,
              maximumY.isFinite,
              maximumX > minimumX,
              maximumY > minimumY
        else {
            return nil
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        ).standardized
    }

    static func intersectionArea(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.standardized.intersection(right.standardized)
        guard !intersection.isNull,
              !intersection.isEmpty,
              intersection.width.isFinite,
              intersection.height.isFinite
        else {
            return 0
        }
        let area = intersection.width * intersection.height
        return area.isFinite && area > 0 ? area : 0
    }
}

/// Recovers a line or column the gate rejected when it continues a confidently read caption.
/// Handwritten captions are often read confidently except for one neighbouring line (a faint
/// brush column, a pencil line whose box scores just under the detector threshold); the reader
/// then sees untranslated source next to the translation. Only CJK reads next to an accepted
/// line of the same orientation and glyph size, aligned with it and within one line pitch, are
/// admitted, so artwork, isolated SFX, large display lettering and ruby keep the old behaviour.
@available(iOS 18.0, *)
enum NativeOCRAdjacentLineRecovery {
    /// Detector components scoring at least this (below the box threshold) may be recovered.
    static let boxThreshold = 0.5
    /// Reads down to the confidence threshold minus this margin may be recovered.
    static let confidenceMargin = 0.2

    struct Axis {
        let direction: CGPoint
        let along: ClosedRange<CGFloat>
        let across: ClosedRange<CGFloat>
        let thickness: CGFloat
        let length: CGFloat
    }

    /// At least two kana/Han characters making up 60% of the alphanumerics. The prolonged sound
    /// mark and middle dot are not counted: alone they are the typical reads of strokes.
    static func admits(_ text: String) -> Bool {
        let (cjk, alphanumeric) = counts(text)
        // Latin letters inside a low-confidence Japanese read are recognition noise (screentone, garbled
        // small print); watermark notices are never recovered.
        return cjk >= 2 && Double(cjk) >= 0.6 * Double(alphanumeric) && !containsLatinLetter(text) && !isNotice(text)
    }

    /// Anti-reupload notices ("無断転載禁止", "AI学習禁止", "自作発言") printed over the art.
    static func isNotice(_ text: String) -> Bool {
        ["無断", "転載", "転写", "禁止", "学習", "自作発言", "複製"].contains { text.contains($0) }
    }

    /// Comic lettering (English scanlations, Latin captions) stacks short centred rows: "I" / "SO" /
    /// "NOT" above or below a confidently read row. The recognizer often scores such a row just under
    /// the gate (or the detector scores its box as weak) and the reader keeps it as source residue.
    /// A horizontal all-capitals Latin anchor row (comic lettering) of at least three letters and no CJK
    /// completes such a stack. Mixed-case rows (brand names, labels, dialogue boxes) never recover
    /// neighbours: their small print below is artwork, not a dropped row.
    static func latinAnchors(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.count >= 3 && letters.allSatisfy(isBasicLatin)
            && !letters.contains { 0x61...0x7A ~= $0.value } && !isNotice(text)
    }

    /// A short Latin row of such a stack: 1-12 basic Latin letters (one or two words), no CJK or
    /// digits, and no more punctuation than letters beyond an ellipsis ("I...", "SO,", "NOT").
    static func admitsLatin(_ text: String) -> Bool {
        let visible = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let letters = visible.filter { CharacterSet.letters.contains($0) }
        return (1...12).contains(letters.count) && letters.allSatisfy(isBasicLatin)
            && !visible.contains { CharacterSet.decimalDigits.contains($0) }
            && visible.count - letters.count <= max(3, letters.count)
            && text.split(whereSeparator: \.isWhitespace).count <= 2
    }

    /// A recovered Latin row takes its anchor's horizontal baseline.
    static func isHorizontal(_ polygon: [CGPoint]) -> Bool {
        guard let axis = axis(polygon), axis.length >= axis.thickness * 1.3 else { return false }
        return abs(axis.direction.x) > abs(axis.direction.y) * 2
    }

    /// Pairs a candidate read with an anchor of the same script: CJK completes CJK captions, a short
    /// Latin row completes a horizontal Latin stack.
    static func completes(_ candidate: String, polygon: [CGPoint], anchor: String, anchorPolygon: [CGPoint]) -> Bool {
        guard isAdjacent(polygon, to: anchorPolygon) else { return false }
        if admits(candidate) && anchors(anchor) { return true }
        return admitsLatin(candidate) && latinAnchors(anchor) && isHorizontal(anchorPolygon)
    }

    static func isLatinStackRow(_ text: String) -> Bool {
        admitsLatin(text) && !admits(text)
    }

    /// A confidently read single Latin letter ("I", "A") has a square or tall box, so its orientation is
    /// estimated vertical. Beside or between horizontal Latin rows it is the first word of a row or a row
    /// of its own: it keeps a fixed horizontal orientation so the merger can join it.
    static func orientingSingleLatinLetter(_ line: NativeCoreMLOCRLine, rows: [[CGPoint]]) -> NativeCoreMLOCRLine {
        let letters = line.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count == 1, isLatinStackRow(line.text), !rows.isEmpty,
              rows.contains(where: { isAdjacent(line.polygon, to: $0) || isSameRow(line.polygon, as: $0) })
        else { return line }
        return NativeCoreMLOCRLine(polygon: line.polygon, text: line.text, score: line.score, orientation: .horizontal,
                                   orientationIsEstimated: false, sourceTileBounds: line.sourceTileBounds, erasurePolygons: line.erasurePolygons)
    }

    /// `candidate` sits on the row of the horizontal `anchor`: shared height band, similar glyph size,
    /// at most one line thickness apart along the row.
    static func isSameRow(_ candidate: [CGPoint], as anchor: [CGPoint]) -> Bool {
        guard let a = NativeOCRScopeGeometry.bounds(for: anchor), let c = NativeOCRScopeGeometry.bounds(for: candidate),
              a.height > 0, c.height > 0, max(a.height, c.height) <= min(a.height, c.height) * 1.6 else { return false }
        let shared = min(a.maxY, c.maxY) - max(a.minY, c.minY)
        let gap = max(a.minX, c.minX) - min(a.maxX, c.maxX)
        return shared >= min(a.height, c.height) * 0.6 && gap <= a.height
    }

    private static func isBasicLatin(_ scalar: Unicode.Scalar) -> Bool {
        0x41...0x5A ~= scalar.value || 0x61...0x7A ~= scalar.value
    }

    private static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { 0x41...0x5A ~= $0.value || 0x61...0x7A ~= $0.value || 0xFF21...0xFF3A ~= $0.value
            || 0xFF41...0xFF5A ~= $0.value }
    }

    /// An anchor must itself be a Japanese/Chinese caption line of at least four characters: a Latin
    /// sign or label, or a short or repeated sound effect ("シャカ", "もしゃもしゃ"), is not a caption
    /// that neighbouring lettering continues.
    static func anchors(_ text: String) -> Bool {
        let (cjk, alphanumeric) = counts(text)
        guard cjk >= 4, Double(cjk) >= 0.5 * Double(alphanumeric), !isNotice(text) else { return false }
        // A short kana-only read that repeats a full-size syllable ("もしゃもい", "ドキドキ") is a sound effect.
        let small = Set("ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ".unicodeScalars)
        let kana = text.unicodeScalars.filter { 0x3040...0x30FA ~= $0.value && !small.contains($0) }
        let hasHan = text.unicodeScalars.contains { 0x3400...0x9FFF ~= $0.value }
        return hasHan || cjk > 6 || Set(kana).count == kana.count
    }

    private static func counts(_ text: String) -> (cjk: Int, alphanumeric: Int) {
        var cjk = 0, alphanumeric = 0
        for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            alphanumeric += 1
            switch scalar.value {
            case 0x30FB, 0x30FC: break
            case 0x3005...0x3007, 0x3040...0x30FF, 0x3400...0x9FFF, 0xFF66...0xFF9D: cjk += 1
            default: break
            }
        }
        return (cjk, alphanumeric)
    }

    /// Long axis of a quad (pointing down or right) with the quad's extent along and across it.
    static func axis(_ polygon: [CGPoint], direction: CGPoint? = nil) -> Axis? {
        guard polygon.count == 4, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let edges = (0..<4).map { CGPoint(x: polygon[($0 + 1) % 4].x - polygon[$0].x, y: polygon[($0 + 1) % 4].y - polygon[$0].y) }
        let first = (hypot(edges[0].x, edges[0].y) + hypot(edges[2].x, edges[2].y)) / 2
        let second = (hypot(edges[1].x, edges[1].y) + hypot(edges[3].x, edges[3].y)) / 2
        guard min(first, second) > 0 else { return nil }
        var unit: CGPoint
        if let direction {
            unit = direction
        } else {
            let edge = first >= second ? edges[0] : edges[1]
            let norm = hypot(edge.x, edge.y)
            unit = CGPoint(x: edge.x / norm, y: edge.y / norm)
            if abs(unit.y) > abs(unit.x) ? unit.y < 0 : unit.x < 0 { unit = CGPoint(x: -unit.x, y: -unit.y) }
        }
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let along = polygon.map { $0.x * unit.x + $0.y * unit.y }
        let across = polygon.map { $0.x * normal.x + $0.y * normal.y }
        guard let aLow = along.min(), let aHigh = along.max(), let cLow = across.min(), let cHigh = across.max() else { return nil }
        return Axis(direction: unit, along: aLow...aHigh, across: cLow...cHigh,
                    thickness: min(first, second), length: max(first, second))
    }

    /// `candidate` continues `anchor` as a sibling line: same orientation, similar glyph size, at
    /// least half of the shorter line side by side with the other, centres 0.6-2 line thicknesses apart.
    static func isAdjacent(_ candidate: [CGPoint], to anchor: [CGPoint]) -> Bool {
        // A one-glyph anchor has no reliable reading direction.
        guard let base = axis(anchor), base.length >= base.thickness * 1.3,
              let own = axis(candidate), let projected = axis(candidate, direction: base.direction) else { return false }
        // A short candidate (one or two glyphs) takes the anchor's orientation.
        let parallel = abs(own.direction.x * base.direction.x + own.direction.y * base.direction.y) >= 0.7
        guard own.length < own.thickness * 1.3 || parallel else { return false }
        let across = projected.across.upperBound - projected.across.lowerBound
        let ratio = across / base.thickness
        guard ratio >= 1 / 1.6, ratio <= 1.6 else { return false }
        let overlap = min(base.along.upperBound, projected.along.upperBound) - max(base.along.lowerBound, projected.along.lowerBound)
        let shorter = min(base.along.upperBound - base.along.lowerBound, projected.along.upperBound - projected.along.lowerBound)
        guard overlap >= shorter * 0.5 else { return false }
        let pitch = (base.thickness + across) / 2
        let distance = abs((base.across.lowerBound + base.across.upperBound) / 2
            - (projected.across.lowerBound + projected.across.upperBound) / 2)
        return distance >= pitch * 0.6 && distance <= pitch * 2
    }

    /// Candidates adjacent to an accepted line with no image evidence (a balloon outline or panel
    /// rule, another enclosed surface) separating the two. Candidates never anchor each other.
    /// Recovery completes captions that were otherwise read confidently; when many lines of a page
    /// would need it (dense low-quality handwriting, where reads are unreliable and the extra lines
    /// crowd the layout), nothing is recovered.
    static func admitted(
        _ candidates: [NativeCoreMLOCRLine], anchors: [NativeCoreMLOCRLine],
        separates: (CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool
    ) -> [NativeCoreMLOCRLine] {
        guard !candidates.isEmpty, !anchors.isEmpty else { return [] }
        let admitted = candidates.filter { candidate in
            guard admits(candidate.text) || admitsLatin(candidate.text),
                  let bounds = NativeOCRScopeGeometry.bounds(for: candidate.polygon) else { return false }
            return anchors.contains { anchor in
                guard completes(candidate.text, polygon: candidate.polygon, anchor: anchor.text, anchorPolygon: anchor.polygon),
                      let anchorBounds = NativeOCRScopeGeometry.bounds(for: anchor.polygon),
                      let direction = axis(anchor.polygon)?.direction else { return false }
                return !separates(anchorBounds, bounds, abs(direction.y) > abs(direction.x) ? .vertical : .horizontal)
            }
        }
        return admitted.count <= max(2, anchors.count / 4) ? admitted : []
    }

    /// Recovery may only complete one caption. A region of the recovered grouping replaces base region R
    /// when it holds a recovered line, every confident line inside it belongs to R, all of R's lines are
    /// inside it, and within half a line pitch of another caption it neither comes closer than R did nor touches it.
    /// Otherwise the base grouping stays: a recovered line never joins, splits or crowds captions.
    /// A gap line (`bridges`) may in addition join the captions that own its two flanks: the regrouped region must
    /// then hold both flank captions, and only whole captions (at most four), plus recovered lines.
    static func extending(
        _ base: [ReaderTranslationRegion], with grouped: [ReaderTranslationRegion],
        baseLines: [NativeCoreMLOCRLine], recovered: [NativeCoreMLOCRLine], bridges: [NativeCoreMLOCRGapLine] = [],
        imageBounds: CGRect, inkContrast: ((CGRect, CGRect) -> Bool)? = nil
    ) -> [ReaderTranslationRegion] {
        guard !recovered.isEmpty, imageBounds.width > 0, imageBounds.height > 0 else { return base }
        func center(_ line: NativeCoreMLOCRLine) -> CGPoint? {
            NativeOCRScopeGeometry.bounds(for: line.polygon).map {
                CGPoint(x: $0.midX / imageBounds.width, y: $0.midY / imageBounds.height)
            }
        }
        func owner(_ point: CGPoint?, in regions: [ReaderTranslationRegion]) -> Int? {
            guard let point else { return nil }
            return regions.indices.filter { index in
                let region = regions[index]
                return region.polygon.count >= 3 ? contains(region.polygon, point) : region.rect.contains(point)
            }.min { regions[$0].rect.width * regions[$0].rect.height < regions[$1].rect.width * regions[$1].rect.height }
        }
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * imageBounds.width, y: rect.minY * imageBounds.height,
                   width: rect.width * imageBounds.width, height: rect.height * imageBounds.height)
        }
        func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX), max(a.minY, b.minY) - min(a.maxY, b.maxY))
        }
        let baseCenters = baseLines.map(center)
        let baseOwners = baseCenters.map { owner($0, in: base) }
        let groupedOwners = baseCenters.map { owner($0, in: grouped) }
        // Base captions a gap line may join: the owners of its two flanks.
        let bridging: [(line: NativeCoreMLOCRLine, owners: Set<Int>)] = bridges.map { bridge in
            (bridge.line, Set(bridge.flanks.compactMap { flank in
                if let exact = baseLines.firstIndex(where: { $0.polygon == flank }) { return baseOwners[exact] }
                // Unit completion can replace a flank polygon. Accept only one
                // unambiguous containing read; neighboring captions cannot claim it.
                guard let rect = NativeOCRScopeGeometry.bounds(for: flank), rect.width > 0, rect.height > 0 else { return nil }
                let matches = baseLines.indices.filter { index in
                    guard let candidate = NativeOCRScopeGeometry.bounds(for: baseLines[index].polygon) else { return false }
                    let overlap = candidate.intersection(rect)
                    return !overlap.isNull && overlap.width * overlap.height >= rect.width * rect.height * 0.9
                }
                return matches.count == 1 ? baseOwners[matches[0]] : nil
            }))
        }
        var result = base
        var removed = Set<Int>(), changed = Set<Int>()
        for (index, region) in grouped.enumerated() {
            let mine = recovered.filter { owner(center($0), in: grouped) == index }
            guard !mine.isEmpty else { continue }
            let inside = baseLines.indices.filter { groupedOwners[$0] == index }
            let owners = Set(inside.map { baseOwners[$0] })
            let allowed = bridging.filter { bridge in mine.contains { $0 == bridge.line } && bridge.owners.count == 2 }
                .reduce(into: Set<Int>()) { $0.formUnion($1.owners) }
            let targets = owners.compactMap { $0 }.sorted()
            // Joining captions needs a bridge whose flanks are both inside; the merger may then also join further
            // captions of the same balloon (all of their lines inside), at most four in all.
            guard !owners.contains(nil), !targets.isEmpty,
                  targets.count == 1 || (!allowed.isEmpty && allowed.isSubset(of: Set(targets)) && targets.count <= 4),
                  targets.allSatisfy({ target in
                      !removed.contains(target) && !changed.contains(target)
                          && baseLines.indices.allSatisfy({ baseOwners[$0] != target || groupedOwners[$0] == index })
                  })
            else { continue }
            let target = targets[0]
            let pitch = mine.compactMap { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
                .map { min($0.width, $0.height) }.max() ?? 0
            let edgeCompletion = bridges.contains { $0.edge && mine.contains($0.line) }
            let grown = pixels(region.rect)
            let old = targets.dropFirst().reduce(pixels(base[target].rect)) { $0.union(pixels(base[$1].rect)) }
            let crowds = base.indices.contains { other in
                // A bridge's other flank is the caption it completes: coming close to it is expected.
                guard !targets.contains(other), !allowed.contains(other) else { return false }
                // A pixel/recognition-certified outer column can approach a sign
                // seen through its balloon. Reject new overlap, not empty proximity.
                if edgeCompletion {
                    let obstacle = pixels(base[other].rect)
                    return NativeOCRScopeGeometry.intersectionArea(grown, obstacle)
                        > NativeOCRScopeGeometry.intersectionArea(old, obstacle) + 1
                }
                let before = gap(old, pixels(base[other].rect)), after = gap(grown, pixels(base[other].rect))
                // Closer than half a pitch to another caption, either newly or touching it: a crowded
                // cluster, where a larger caption collides with (or its plate covers) the neighbour.
                // A bridged caption only has to keep its existing distances (it fills a gap inside its balloon).
                guard after < pitch * 0.5 && (after < before || (after == 0 && allowed.isEmpty)) else { return false }
                // A confirmed internal column may extend across a differently
                // coloured horizontal sign visible through a translucent balloon.
                // Only pixel evidence can distinguish that background from a peer.
                if !allowed.isEmpty, region.sourceOrientation == .vertical,
                   base[other].sourceOrientation == .horizontal,
                   mine.allSatisfy({ line in
                       guard let box = NativeOCRScopeGeometry.bounds(for: line.polygon) else { return false }
                       return inkContrast?(box, pixels(base[other].rect)) == true
                   }) { return false }
                return true
            }
            guard !crowds else { continue }
            result[target] = ReaderTranslationRegion(
                id: base[target].id, rect: region.rect, source: region.source, translation: region.translation,
                polygon: region.polygon, confidence: region.confidence, sourceImageAspectRatio: region.sourceImageAspectRatio,
                translationOrder: region.translationOrder, translationOrderVersion: region.translationOrderVersion,
                sourceOrientation: region.sourceOrientation, sourceSingleVerticalColumn: region.sourceSingleVerticalColumn,
                translationReuseIdentity: region.translationReuseIdentity, auxiliaryInkRects: region.auxiliaryInkRects,
                auxiliaryInkPolygons: region.auxiliaryInkPolygons
            )
            changed.insert(target)
            removed.formUnion(targets.dropFirst())
        }
        return result.indices.filter { !removed.contains($0) }.map { result[$0] }
    }

    private static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y),
               point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }
}

/// The unread half of a display or effect lettering unit. The page pass often reads one glyph or one
/// word of a hand-lettered unit ("だ" of "だら…", "に" of "にぎ", "ジ" of "ジー…") and leaves the rest,
/// which it split into weak blobs, without a line. The overlay then erases the read half and leaves the
/// other half as source residue. An accepted short kana/Han line whose reading axis continues into
/// unexplained ink components of its own colour and stroke width, on clean paper, is read again together
/// with those components as one line; the read replaces the line only when it is confident and extends
/// the accepted text.
@available(iOS 18.0, *)
enum NativeOCRLetteringUnitRecovery {
    struct Line {
        let polygon: [CGPoint]
        let text: String
    }

    struct Neighbour: Equatable {
        /// Index of the anchor in the `lines` passed to `neighbours`.
        let anchor: Int
        let anchorBounds: CGRect
        /// Union of the unexplained components that continue the anchor.
        let ink: CGRect
        let vertical: Bool
        var unit: CGRect { anchorBounds.union(ink) }
        let side: Side
    }

    /// Anchors: at most this many kana/Han glyphs (display and effect lettering pieces).
    static let maximumAnchorGlyphs = 6
    /// At most this many anchors are examined, and at most this many units are read, per page.
    static let maximumAnchors = 24
    static let maximumUnits = 6
    /// Glyph size floor (source pixels): smaller lines are body text.
    static let minimumGlyph: CGFloat = 14
    /// The components may extend a line by this many glyphs along its axis.
    static let reach: CGFloat = 2.2
    /// Components chain when their gap is at most this many glyphs.
    static let chainGap: CGFloat = 0.6
    /// Shares of the anchor's and of each component's surrounding ring that must be the anchor's paper.
    static let anchorPaper: CGFloat = 0.35
    static let componentPaper: CGFloat = 0.5
    /// A unit is completed only on clean paper, where the overlay erases it cleanly: the rings reach these
    /// stricter floors and the unit's box holds no other ink or artwork (at most `foreignShare` of it).
    /// On artwork the larger box would take a plate over the art (and neighbouring units merge into one
    /// plate), so the unread half is left as it was.
    static let anchorCleanPaper: CGFloat = 0.7
    static let componentCleanPaper: CGFloat = 0.85
    static let foreignShare: CGFloat = 0.03
    /// Confidence floor of a unit read.
    static let unitConfidence = 0.8

    private static let marks = Set("!?！？…‥ー〜～~・♡♥♪")

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool { 0x3005...0x3007 ~= scalar.value || 0x3400...0x9FFF ~= scalar.value }

    private static func isKanaOrHan(_ scalar: Unicode.Scalar) -> Bool {
        0x3041...0x30FA ~= scalar.value || 0x30FD...0x30FF ~= scalar.value || isHan(scalar)
    }

    /// Kana/Han glyphs of a lettering piece, or nil when the text has anything but kana, Han and marks.
    static func glyphCount(_ text: String) -> Int? {
        var count = 0
        for character in text where !character.isWhitespace {
            if marks.contains(character) { continue }
            guard character.unicodeScalars.allSatisfy(isKanaOrHan) else { return nil }
            count += 1
        }
        return count
    }

    /// A short kana/Han lettering piece. Han glyphs (labels, list items, signs at body size) qualify only on
    /// display lettering, at least `displayThickness` times the page's median line thickness.
    static func isAnchor(_ text: String, glyph: CGFloat, medianGlyph: CGFloat) -> Bool {
        guard let count = glyphCount(text), (1...maximumAnchorGlyphs).contains(count),
              !NativeOCRAdjacentLineRecovery.isNotice(text) else { return false }
        let hasHan = text.unicodeScalars.contains { 0x3400...0x9FFF ~= $0.value }
        return !hasHan || glyph >= medianGlyph * displayThickness
    }

    static let displayThickness: CGFloat = 1.5

    /// A unit read that completes `anchor`: kana/Han and marks only, the anchor's glyphs in order, and at
    /// least one more glyph or mark ("だら…", "ジー…"), never a different word.
    /// Where the neighbour lies along the anchor's reading axis.
    enum Side: Equatable { case after, before }

    static func completes(_ read: String, anchor: String, side: Side) -> Bool {
        let unit = read.filter { !$0.isWhitespace }, base = anchor.filter { !$0.isWhitespace }
        guard let glyphs = glyphCount(unit), glyphs >= 1, let own = glyphCount(base), unit.count > base.count,
              glyphs <= own + 4, !NativeOCRAdjacentLineRecovery.isNotice(unit),
              // The added text lies on the neighbour's side.
              side == .after ? unit.hasPrefix(base) : unit.hasSuffix(base) else { return false }
        var remaining = Substring(unit)
        var added = Array(unit)
        for character in base {
            guard let found = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: found)...]
            if let index = added.firstIndex(of: character) { added.remove(at: index) }
        }
        // A straight stroke read as the Han "one" is a rule or a frame line. A kana anchor (effect
        // lettering) continues in kana and marks.
        guard !added.contains("一") else { return false }
        if !base.unicodeScalars.contains(where: isHan), added.contains(where: { $0.unicodeScalars.contains(where: isHan) }) {
            return false
        }
        // A long mark follows kana or another long mark, never Han ("次の日ー" is a rule under a label).
        let letters = Array(unit)
        for (index, character) in letters.enumerated() where longMarks.contains(character) && added.contains(character) {
            guard index > 0, longMarks.contains(letters[index - 1])
                || letters[index - 1].unicodeScalars.allSatisfy({ 0x3041...0x30FA ~= $0.value || 0x30FD...0x30FF ~= $0.value })
            else { return false }
        }
        return true
    }

    private static let longMarks = Set("ー〜～")

    /// Reads `(r, g, b)` at a pixel.
    typealias Pixel = (Int, Int) -> (Int, Int, Int)

    private struct Colour {
        var r: Int, g: Int, b: Int
        func distance(_ other: (Int, Int, Int)) -> Int {
            let dr = r - other.0, dg = g - other.1, db = b - other.2
            return Int(Double(dr * dr + dg * dg + db * db).squareRoot())
        }
        static func median(_ samples: [(Int, Int, Int)]) -> Colour {
            func mid(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
            return Colour(r: mid(samples.map(\.0)), g: mid(samples.map(\.1)), b: mid(samples.map(\.2)))
        }
    }

    private struct Component {
        let bounds: CGRect
        let area: CGFloat
    }

    /// `lines`: the page's confidently read lines (anchors are chosen among them). `occupied`: every accepted
    /// or recovered line; ink inside them (plus 2 px) is explained.
    static func neighbours(width: Int, height: Int, pixel: Pixel, lines: [Line], occupied: [CGRect]) -> [Neighbour] {
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        let explained = occupied.map { $0.insetBy(dx: -2, dy: -2) }
        let thicknesses = lines.compactMap { NativeOCRAdjacentLineRecovery.axis($0.polygon)?.thickness }.sorted()
        let medianGlyph = thicknesses.isEmpty ? 0 : thicknesses[thicknesses.count / 2]
        var result: [Neighbour] = []
        var examined = 0
        for (index, line) in lines.enumerated() {
            guard examined < maximumAnchors, result.count < maximumUnits else { break }
            guard let bounds = NativeOCRScopeGeometry.bounds(for: line.polygon)?.intersection(page), !bounds.isNull,
                  let count = glyphCount(line.text) else { continue }
            let glyph = NativeOCRAdjacentLineRecovery.axis(line.polygon)?.thickness ?? min(bounds.width, bounds.height)
            guard glyph >= minimumGlyph, bounds.width >= 4, bounds.height >= 4,
                  isAnchor(line.text, glyph: glyph, medianGlyph: medianGlyph) else { continue }
            examined += 1
            // The recognizer turns crops at least 1.5 times taller than wide; a one-glyph line has no axis.
            let axes: [Bool] = count == 1 ? [true, false] : [bounds.height >= bounds.width * 1.25]
            if let found = neighbour(index: index, bounds: bounds, glyph: glyph, axes: axes, page: page, pixel: pixel,
                                     explained: explained, others: occupied) {
                result.append(found)
            }
        }
        return result
    }

    private static func neighbour(index: Int, bounds: CGRect, glyph: CGFloat, axes: [Bool], page: CGRect, pixel: Pixel,
                                  explained: [CGRect], others: [CGRect]) -> Neighbour? {
        // Sample grid: about 24 samples per glyph.
        let step = max(1, Int(glyph / 24))
        let pad = max(CGFloat(2), glyph * 0.12)
        // Paper: the ring just outside the line box. Ink: box pixels far from the paper.
        let ringBox = bounds.insetBy(dx: -pad, dy: -pad).intersection(page)
        var ring: [(Int, Int, Int)] = [], inner: [(Int, Int, Int)] = []
        forEachSample(in: ringBox, step: step) { x, y in
            let value = pixel(x, y)
            if bounds.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { inner.append(value) } else { ring.append(value) }
        }
        guard ring.count >= 8, !inner.isEmpty else { return nil }
        let paper = Colour.median(ring)
        let inkSamples = inner.filter { paper.distance($0) > 80 }
        guard inkSamples.count >= 8 else { return nil }
        let ink = Colour.median(inkSamples)
        let contrast = CGFloat(ink.distance((paper.r, paper.g, paper.b)))
        // The ring must be paper: lettering on art or texture is left alone.
        let clean = ring.filter { CGFloat(paper.distance($0)) < contrast * 0.35 }.count
        guard contrast >= 90, CGFloat(clean) >= CGFloat(ring.count) * anchorPaper else { return nil }
        let anchorOnPaper = CGFloat(clean) >= CGFloat(ring.count) * anchorCleanPaper
        let isInk: ((Int, Int, Int)) -> Bool = {
            CGFloat(ink.distance($0)) < contrast * 0.45 && CGFloat(paper.distance($0)) > contrast * 0.55
        }
        guard let stroke = strokeWidth(in: bounds, step: step, pixel: pixel, isInk: isInk) else { return nil }

        struct Part { let component: Component; let clean: Bool; var bounds: CGRect { component.bounds } }
        var best: (added: CGFloat, parts: [Part], vertical: Bool)?
        for vertical in axes {
            let window = (vertical
                ? bounds.insetBy(dx: -0.3 * glyph, dy: -reach * glyph)
                : bounds.insetBy(dx: -reach * glyph, dy: -0.3 * glyph)).intersection(page).integral
            let components = self.components(in: window, step: step, pixel: pixel, isInk: isInk, explained: explained)
                .filter { component in
                    let extent = max(component.bounds.width, component.bounds.height)
                    guard component.area >= max(8, 0.01 * glyph * glyph), extent <= 1.4 * glyph,
                          // A component reaching the window edge is a longer drawing.
                          component.bounds.minX > window.minX, component.bounds.minY > window.minY,
                          component.bounds.maxX < window.maxX, component.bounds.maxY < window.maxY,
                          // In line with the anchor.
                          overlap(component.bounds, bounds, vertical: vertical) >= 0.5 else { return false }
                    return true
                }
            // Chain outward from the anchor; each component's ring and stroke are tested once.
            var verdicts: [Int: Bool] = [:], dirty = Set<Int>()
            func admitted(_ k: Int) -> Bool {
                if let known = verdicts[k] { return known }
                let component = components[k]
                let share = paperShare(component.bounds, glyph: glyph, step: step, page: page, pixel: pixel, paper: paper,
                                       contrast: contrast, explained: explained,
                                       siblings: components.map(\.bounds).filter { $0 != component.bounds } + [bounds])
                let value = share >= componentPaper
                    && strokeMatches(component, stroke: stroke, glyph: glyph, step: step, pixel: pixel, isInk: isInk)
                if value && share < componentCleanPaper { dirty.insert(k) }
                verdicts[k] = value
                return value
            }
            var unit = bounds, used: [Int] = [], added: CGFloat = 0, grew = true
            while grew {
                grew = false
                for k in components.indices where !used.contains(k) {
                    guard gap(unit, components[k].bounds) <= chainGap * glyph, admitted(k) else { continue }
                    used.append(k)
                    unit = unit.union(components[k].bounds)
                    added += components[k].area
                    grew = true
                }
            }
            if added > (best?.added ?? 0) {
                best = (added, used.map { Part(component: components[$0], clean: !dirty.contains($0)) }, vertical)
            }
        }
        guard let best else { return nil }
        // The neighbour continues the anchor on one side: the side holding most of the ink is kept.
        let tolerance = glyph * 0.15
        let isAfter: (Part) -> Bool = {
            best.vertical ? $0.bounds.maxY > bounds.maxY + tolerance : $0.bounds.maxX > bounds.maxX + tolerance
        }
        let isBefore: (Part) -> Bool = {
            best.vertical ? $0.bounds.minY < bounds.minY - tolerance : $0.bounds.minX < bounds.minX - tolerance
        }
        let after = best.parts.filter(isAfter), before = best.parts.filter(isBefore)
        func area(_ parts: [Part]) -> CGFloat { parts.reduce(0) { $0 + $1.component.area } }
        var parts = best.parts, side = Side.after
        if !after.isEmpty && !before.isEmpty {
            let keepAfter = area(after) >= area(before)
            parts = parts.filter { keepAfter ? !isBefore($0) : !isAfter($0) }
            side = keepAfter ? .after : .before
        } else if !before.isEmpty {
            side = .before
        } else if after.isEmpty {
            return nil
        }
        guard area(parts) >= 0.06 * glyph * glyph else { return nil }
        let inkBounds = parts.reduce(CGRect.null) { $0.union($1.bounds) }
        // The unit must not run into another line.
        let unit = bounds.union(inkBounds)
        guard !others.contains(where: { other in
            other != bounds && NativeOCRScopeGeometry.intersectionArea(other, unit) > 0.1 * other.width * other.height
                && !other.contains(bounds)
        }) else { return nil }
        // Clean paper only: clean rings, and no ink in the unit's box beyond the anchor and the parts.
        guard anchorOnPaper, parts.allSatisfy(\.clean) else { return nil }
        var total = 0, foreign = 0
        let lettering = [bounds] + parts.map(\.bounds)
        forEachSample(in: unit.intersection(page), step: step) { x, y in
            let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            guard !lettering.contains(where: { $0.contains(point) }), !explained.contains(where: { $0.contains(point) }) else { return }
            total += 1
            let value = pixel(x, y)
            if isInk(value) || CGFloat(paper.distance(value)) >= contrast * 0.5 { foreign += 1 }
        }
        guard CGFloat(foreign) <= CGFloat(total) * foreignShare else { return nil }
        return Neighbour(anchor: index, anchorBounds: bounds, ink: inkBounds, vertical: best.vertical, side: side)
    }

    private static func forEachSample(in rect: CGRect, step: Int, _ body: (Int, Int) -> Void) {
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return }
        var y = Int(rect.minY)
        while y < Int(rect.maxY) {
            var x = Int(rect.minX)
            while x < Int(rect.maxX) {
                body(x, y)
                x += step
            }
            y += step
        }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect, vertical: Bool) -> CGFloat {
        let shared = vertical ? min(a.maxX, b.maxX) - max(a.minX, b.minX) : min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let own = vertical ? a.width : a.height
        return own > 0 ? max(0, shared) / own : 0
    }

    private static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX), max(a.minY, b.minY) - min(a.maxY, b.maxY))
    }

    /// Mean stroke width (source pixels) of the ink in `rect`: twice the ink area over its boundary length.
    private static func strokeWidth(in rect: CGRect, step: Int, pixel: Pixel, isInk: ((Int, Int, Int)) -> Bool) -> CGFloat? {
        let columns = Int(rect.width) / step + 1, rows = Int(rect.height) / step + 1
        guard columns >= 2, rows >= 2 else { return nil }
        var mask = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = Int(rect.minX) + column * step, y = Int(rect.minY) + row * step
                guard x < Int(rect.maxX), y < Int(rect.maxY) else { continue }
                mask[row * columns + column] = isInk(pixel(x, y))
            }
        }
        return strokeWidth(mask: mask, columns: columns, rows: rows).map { $0 * CGFloat(step) }
    }

    private static func strokeWidth(mask: [Bool], columns: Int, rows: Int) -> CGFloat? {
        var area = 0, boundary = 0
        for row in 0..<rows {
            for column in 0..<columns where mask[row * columns + column] {
                area += 1
                let edge = row == 0 || column == 0 || row == rows - 1 || column == columns - 1
                    || !mask[(row - 1) * columns + column] || !mask[(row + 1) * columns + column]
                    || !mask[row * columns + column - 1] || !mask[row * columns + column + 1]
                if edge { boundary += 1 }
            }
        }
        return area >= 4 && boundary > 0 ? 2 * CGFloat(area) / CGFloat(boundary) : nil
    }

    private static func strokeMatches(_ component: Component, stroke: CGFloat, glyph: CGFloat, step: Int, pixel: Pixel,
                                      isInk: ((Int, Int, Int)) -> Bool) -> Bool {
        // Dots and short dashes ("…", "っ") are too small to measure.
        guard component.area > 0.05 * glyph * glyph else { return true }
        guard let own = strokeWidth(in: component.bounds, step: step, pixel: pixel, isInk: isInk) else { return false }
        return own >= stroke * 0.45 && own <= stroke * 2.2
    }

    /// Share of a ring 0.12 glyph around the component (outside the anchor and explained lines) in the
    /// anchor's paper colour. Balloon outlines, frames and hatching lower it.
    /// `siblings`: the anchor (the last entry, grown by the ring width) and the other glyph-sized candidates,
    /// which are the rest of the unit's strokes rather than its surroundings.
    private static func paperShare(_ rect: CGRect, glyph: CGFloat, step: Int, page: CGRect, pixel: Pixel, paper: Colour,
                                   contrast: CGFloat, explained: [CGRect], siblings: [CGRect]) -> CGFloat {
        let pad = max(CGFloat(2), glyph * 0.12)
        let outer = rect.insetBy(dx: -pad, dy: -pad).intersection(page)
        let excluded = siblings.enumerated().map { $0.offset == siblings.count - 1 ? $0.element.insetBy(dx: -pad, dy: -pad) : $0.element }
            .filter { $0.intersects(outer) } + explained.filter { $0.intersects(outer) }
        var total = 0, clean = 0
        forEachSample(in: outer, step: step) { x, y in
            let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            guard !rect.contains(point), !excluded.contains(where: { $0.contains(point) }) else { return }
            total += 1
            if CGFloat(paper.distance(pixel(x, y))) < contrast * 0.35 { clean += 1 }
        }
        return total >= 4 ? CGFloat(clean) / CGFloat(total) : 0
    }

    /// 8-connected components of lettering-coloured ink in `window` outside explained lines (sampled grid).
    private static func components(in window: CGRect, step: Int, pixel: Pixel, isInk: ((Int, Int, Int)) -> Bool,
                                   explained: [CGRect]) -> [Component] {
        let columns = Int(window.width) / step, rows = Int(window.height) / step
        guard columns >= 3, rows >= 3, columns * rows <= 250_000 else { return [] }
        let local = explained.filter { $0.intersects(window) }
        var mask = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = Int(window.minX) + column * step, y = Int(window.minY) + row * step
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                mask[row * columns + column] = !local.contains(where: { $0.contains(point) }) && isInk(pixel(x, y))
            }
        }
        var seen = [Bool](repeating: false, count: columns * rows)
        var result: [Component] = []
        var stack: [Int] = []
        for start in mask.indices where mask[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var minX = columns, minY = rows, maxX = 0, maxY = 0, count = 0
            while let current = stack.popLast() {
                let row = current / columns, column = current % columns
                count += 1
                minX = min(minX, column); maxX = max(maxX, column); minY = min(minY, row); maxY = max(maxY, row)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let r = row + dy, c = column + dx
                        guard r >= 0, c >= 0, r < rows, c < columns else { continue }
                        let next = r * columns + c
                        if mask[next] && !seen[next] { seen[next] = true; stack.append(next) }
                    }
                }
            }
            let s = CGFloat(step)
            result.append(Component(
                bounds: CGRect(x: window.minX + CGFloat(minX) * s, y: window.minY + CGFloat(minY) * s,
                               width: CGFloat(maxX - minX + 1) * s, height: CGFloat(maxY - minY + 1) * s),
                area: CGFloat(count) * s * s
            ))
        }
        return result
    }
}

/// A line read in the gap between two confidently read lines of one caption, with those two lines.
@available(iOS 18.0, *)
struct NativeCoreMLOCRGapLine: Equatable, Sendable {
    let line: NativeCoreMLOCRLine
    let flanks: [[CGPoint]]
    var edge = false
}

/// Recovers a column (or line) that the detector missed between two confidently read columns of one caption.
/// Tightly set balloon columns can fuse in the detector's probability map; the middle column then has no box
/// (or only a weak box spanning its neighbours), the caption is translated in pieces and the middle stays
/// Japanese. The recovery looks for an ink column of the flanks' own style in the gap: a run of the same ink
/// on the same paper, as dense as the flanks and separated from both by gutters. The proposed box is read
/// by the recognizer and kept only when the read is confident, Japanese/Chinese, as long as the ink
/// suggests and not a repeat of a flank. Only upright (axis-aligned) lines are considered.
@available(iOS 18.0, *)
enum NativeOCRGapLineRecovery {
    struct Line {
        let polygon: [CGPoint]
        let text: String
    }

    struct Proposal: Equatable {
        let polygon: [CGPoint]
        let vertical: Bool
        let flanks: [[CGPoint]]
        let flankTexts: [String]
        var edge = false
    }

    static let maximumProposals = 8

    private struct Oriented {
        let vertical: Bool
        let across: ClosedRange<CGFloat>
        let along: ClosedRange<CGFloat>
        var thickness: CGFloat { across.upperBound - across.lowerBound }
        var center: CGFloat { (across.lowerBound + across.upperBound) / 2 }
    }

    private struct InkStyle {
        let threshold: Int
        let dark: Bool
        let paper: Double
        let ink: Double
        let midtones: Double
        func isInk(_ value: Int) -> Bool { dark ? value < threshold : value >= threshold }
        var separation: Double { abs(paper - ink) }
        func isMidtone(_ value: Int) -> Bool {
            abs(Double(value) - paper) > separation * 0.25 && abs(Double(value) - ink) > separation * 0.25
        }
    }

    /// A flank is a Japanese/Chinese line of at least two characters (no notice).
    static func flanks(_ text: String) -> Bool {
        let (cjk, alphanumeric) = cjkCounts(text)
        return cjk >= 2 && Double(cjk) >= 0.5 * Double(alphanumeric) && !NativeOCRAdjacentLineRecovery.isNotice(text)
    }

    /// A caption line: at least four Japanese/Chinese characters, not a repeated sound effect ("ドキドキ").
    static func isCaption(_ text: String) -> Bool {
        let (cjk, alphanumeric) = cjkCounts(text)
        guard cjk >= 4, Double(cjk) >= 0.5 * Double(alphanumeric), !NativeOCRAdjacentLineRecovery.isNotice(text) else { return false }
        let letters = Array(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        let kanaOnly = letters.allSatisfy { 0x3040...0x30FF ~= $0.value }
        return !kanaOnly || !(1...3).contains { period in
            letters.count >= period * 2 && letters.indices.allSatisfy { letters[$0] == letters[$0 % period] }
        }
    }

    static func cjkCounts(_ text: String) -> (cjk: Int, alphanumeric: Int) {
        var cjk = 0, alphanumeric = 0
        for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            alphanumeric += 1
            switch scalar.value {
            case 0x30FB, 0x30FC: break
            case 0x3005...0x3007, 0x3040...0x30FF, 0x3400...0x9FFF, 0xFF66...0xFF9D: cjk += 1
            default: break
            }
        }
        return (cjk, alphanumeric)
    }

    private static func oriented(_ polygon: [CGPoint]) -> Oriented? {
        guard let axis = NativeOCRAdjacentLineRecovery.axis(polygon), axis.length >= axis.thickness * 1.3,
              let rect = NativeOCRScopeGeometry.bounds(for: polygon) else { return nil }
        let vertical = abs(axis.direction.y) > abs(axis.direction.x)
        // Rows and columns of pixels are sampled, so the line must be upright (within about six degrees).
        guard (vertical ? abs(axis.direction.x) : abs(axis.direction.y)) <= 0.1 else { return nil }
        return vertical
            ? Oriented(vertical: true, across: rect.minX...rect.maxX, along: rect.minY...rect.maxY)
            : Oriented(vertical: false, across: rect.minY...rect.maxY, along: rect.minX...rect.maxX)
    }

    /// Otsu threshold, polarity and paper/ink levels of a line's own box (sampled, at most ~20k pixels).
    private static func style(of line: Oriented, width: Int, height: Int, luminance: (Int, Int) -> Int) -> InkStyle? {
        let rect = line.vertical
            ? CGRect(x: line.across.lowerBound, y: line.along.lowerBound, width: line.thickness,
                     height: line.along.upperBound - line.along.lowerBound)
            : CGRect(x: line.along.lowerBound, y: line.across.lowerBound, width: line.along.upperBound - line.along.lowerBound,
                     height: line.thickness)
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY.rounded(.up)))
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { return nil }
        let step = max(1, Int((Double((x1 - x0) * (y1 - y0)) / 20_000).squareRoot()))
        var histogram = [Double](repeating: 0, count: 64)
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                histogram[min(63, max(0, luminance(x, y)) / 4)] += 1
                x += step
            }
            y += step
        }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        let sum = histogram.indices.reduce(0) { $0 + Double($1 * 4 + 2) * histogram[$1] }
        var best: Double = -1, threshold = 128, weight: Double = 0, partial: Double = 0
        for index in 0..<63 {
            weight += histogram[index]
            partial += Double(index * 4 + 2) * histogram[index]
            guard weight > 0, weight < total else { continue }
            let low = partial / weight, high = (sum - partial) / (total - weight)
            let between = weight * (total - weight) * (low - high) * (low - high)
            if between > best {
                best = between
                threshold = (index + 1) * 4
            }
        }
        let darkCount = histogram[0..<(threshold / 4)].reduce(0, +)
        let dark = darkCount < total * 0.5
        func median(_ range: Range<Int>) -> Double? {
            let count = histogram[range].reduce(0, +)
            guard count > 0 else { return nil }
            var seen = 0.0
            for index in range {
                seen += histogram[index]
                if seen >= count / 2 { return Double(index * 4 + 2) }
            }
            return nil
        }
        let lowRange = 0..<(threshold / 4), highRange = (threshold / 4)..<64
        guard let low = median(lowRange), let high = median(highRange) else { return nil }
        var style = InkStyle(threshold: threshold, dark: dark, paper: dark ? high : low, ink: dark ? low : high, midtones: 0)
        var midtones = 0.0
        for index in 0..<64 where style.isMidtone(index * 4 + 2) { midtones += histogram[index] }
        style = InkStyle(threshold: threshold, dark: dark, paper: style.paper, ink: style.ink, midtones: midtones / total)
        return style
    }

    /// Candidate boxes for missed lines between pairs of `lines` (confident reads). `blockers` are detector boxes
    /// that were read (or are being recovered otherwise): a gap holding one is not a missed line.
    static func proposals(
        width: Int, height: Int, luminance: (Int, Int) -> Int, lines: [Line], blockers: [[CGPoint]]
    ) -> [Proposal] {
        let oriented = lines.map { self.oriented($0.polygon) }
        let blocking = blockers.compactMap { NativeOCRScopeGeometry.bounds(for: $0) }
        var styles: [Int: InkStyle?] = [:]
        func style(_ index: Int) -> InkStyle? {
            if let cached = styles[index] { return cached }
            let value = oriented[index].flatMap { self.style(of: $0, width: width, height: height, luminance: luminance) }
            styles[index] = .some(value)
            return value
        }
        let lineRects = lines.map { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
        let occupied = blocking + lineRects.compactMap { $0 }
        var result: [Proposal] = []
        // Body text only: display lettering (thicker than 8 % of the page's short side) is left to the detector.
        let bodyLimit = CGFloat(min(width, height)) * 0.08
        for first in lines.indices {
            guard let a = oriented[first], a.thickness <= bodyLimit else { continue }
            // Only the nearest sibling in reading order can flank a gap (any line between would block it).
            var nearest: (index: Int, distance: CGFloat)?
            for second in lines.indices where second != first {
                guard let b = oriented[second], b.vertical == a.vertical,
                      // Each pair once, in reading order: right to left for columns, top down for lines.
                      a.vertical ? b.center < a.center : b.center > a.center
                else { continue }
                let ratio = a.thickness / b.thickness
                let thickness = (a.thickness + b.thickness) / 2
                let distance = abs(a.center - b.center)
                guard ratio >= 1 / 1.35, ratio <= 1.35, distance >= thickness * 1.2, distance <= thickness * 3.6,
                      distance < nearest?.distance ?? .infinity else { continue }
                let low = max(a.along.lowerBound, b.along.lowerBound), high = min(a.along.upperBound, b.along.upperBound)
                let shorter = min(a.along.upperBound - a.along.lowerBound, b.along.upperBound - b.along.lowerBound)
                guard high - low >= shorter * 0.5 else { continue }
                nearest = (second, distance)
            }
            guard let second = nearest?.index, let b = oriented[second], let distance = nearest?.distance,
                  isCaption(lines[first].text) || isCaption(lines[second].text) else { continue }
            let low = max(a.along.lowerBound, b.along.lowerBound), high = min(a.along.upperBound, b.along.upperBound)
            let near = min(a.center, b.center), far = max(a.center, b.center)
            let spanLow = min(a.along.lowerBound, b.along.lowerBound), spanHigh = max(a.along.upperBound, b.along.upperBound)
            let blocked = occupied.contains { rect in
                let center = a.vertical ? rect.midX : rect.midY
                let along = a.vertical ? rect.minY...rect.maxY : rect.minX...rect.maxX
                return center > near + distance * 0.2 && center < far - distance * 0.2
                    && min(along.upperBound, spanHigh) > max(along.lowerBound, spanLow)
            }
            guard !blocked, let ink = style(first), ink.separation >= 48,
                  let proposal = gapProposal(a: a, b: b, ink: ink, low: low, high: high, span: spanLow...spanHigh,
                                             width: width, height: height, luminance: luminance)
            else { continue }
            let box = proposal
            guard !result.contains(where: { NativeOCRScopeGeometry.intersectionArea(
                NativeOCRScopeGeometry.bounds(for: $0.polygon) ?? .null, box) > 0.5 * box.width * box.height })
            else { continue }
            // The box must not cover the core (middle half across) of a line that was already read or detected.
            let covers = occupied.contains { rect in
                let core = a.vertical ? rect.insetBy(dx: rect.width / 4, dy: 0) : rect.insetBy(dx: 0, dy: rect.height / 4)
                return NativeOCRScopeGeometry.intersectionArea(core, box) >= 0.25 * core.width * core.height
            }
            guard !covers else { continue }
            result.append(Proposal(
                polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                          CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
                vertical: a.vertical, flanks: [lines[first].polygon, lines[second].polygon],
                flankTexts: [lines[first].text, lines[second].text]
            ))
            if result.count >= maximumProposals { return result }
        }
        return result
    }

    /// Extend a measured pair of upright dialogue columns by one pitch. Two real
    /// siblings establish size/spacing; a missing outer column has no second flank
    /// on its far side, so the interior-gap scanner cannot find it. Inspect at most
    /// eight 64k-pixel crops, then require a confident, non-duplicate CJK read.
    static func edgeProposals(
        width: Int, height: Int, luminance: (Int, Int) -> Int, lines: [Line], blockers: [[CGPoint]]
    ) -> [Proposal] {
        guard lines.count <= 256 else { return [] }
        let bounds = lines.map { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
        let occupied = blockers.compactMap(NativeOCRScopeGeometry.bounds(for:)) + bounds.compactMap { $0 }
        var result: [Proposal] = [], budget = 262_144, styleChecks = 0
        for first in lines.indices {
            guard isCaption(lines[first].text), let a = oriented(lines[first].polygon), a.vertical,
                  let ar = bounds[first], a.thickness <= CGFloat(min(width, height)) * 0.05 else { continue }
            for second in lines.indices where second != first {
                guard isCaption(lines[second].text), let b = oriented(lines[second].polygon), b.vertical,
                      let br = bounds[second], b.center > a.center else { continue }
                let thin = min(a.thickness, b.thickness), pitch = b.center - a.center
                guard thin >= 6, max(a.thickness, b.thickness) <= thin * 1.3,
                      pitch >= thin * 0.85, pitch <= thin * 1.4,
                      abs(ar.minY - br.minY) <= thin * 0.25,
                      min(ar.height, br.height) >= thin * 3,
                      max(ar.height, br.height) <= min(ar.height, br.height) * 1.4 else { continue }
                guard styleChecks < 32 else { return result }
                styleChecks += 1
                guard let ink = style(of: b, width: width, height: height, luminance: luminance),
                      ink.dark, ink.separation >= 100 else { continue }
                for center in [b.center + pitch, a.center - pitch] {
                    var box = CGRect(x: center - thin * 0.5, y: min(ar.minY, br.minY) - thin * 0.15,
                                     width: thin, height: max(ar.height, br.height) + thin * 1.1)
                        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
                    var tailIndex: Int?
                    // A detected one-glyph tail is kept and merged after recovery.
                    // Stop at its top instead of rejecting the missing body beside it.
                    for index in lines.indices {
                        guard let tail = bounds[index], lines[index].text.count <= 2,
                              tail.height <= thin * 1.2, abs(tail.midX - center) <= thin * 0.35,
                              tail.minY > box.minY + thin * 3, tail.minY < box.maxY else { continue }
                        box.size.height = tail.minY - box.minY
                        tailIndex = index
                    }
                    guard !box.isEmpty, !occupied.contains(where: {
                        NativeOCRScopeGeometry.intersectionArea($0, box) > min($0.width * $0.height, box.width * box.height) * 0.15
                    }), !result.contains(where: {
                        guard let r = NativeOCRScopeGeometry.bounds(for: $0.polygon) else { return true }
                        return NativeOCRScopeGeometry.intersectionArea(r, box) > box.width * box.height * 0.3
                    }) else { continue }
                    let x0 = Int(box.minX.rounded(.up)), x1 = Int(box.maxX)
                    let y0 = Int(box.minY.rounded(.up)), y1 = Int(box.maxY)
                    let count = (x1 - x0) * (y1 - y0)
                    guard count > 0, count <= 65_536, count <= budget else { continue }
                    budget -= count
                    var dark = 0, paper = 0, sum = 0, bands = Set<Int>()
                    for y in y0..<y1 { for x in x0..<x1 {
                        let value = luminance(x, y)
                        if ink.isInk(value) { dark += 1; bands.insert(Int(CGFloat(y - y0) / thin)) }
                        else { paper += 1; sum += value }
                    } }
                    guard dark > count / 25, dark < count / 2, bands.count >= 4, paper > 0,
                          abs(Double(sum) / Double(paper) - ink.paper) < 32 else { continue }
                    result.append(Proposal(polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                        CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
                        vertical: true, flanks: [lines[center > b.center ? second : first].polygon,
                            lines[tailIndex ?? (center > b.center ? first : second)].polygon],
                        flankTexts: [lines[first].text, lines[second].text], edge: true))
                    if result.count >= 8 { return result }
                }
            }
        }
        return result
    }

    // swiftlint:disable:next function_parameter_count
    private static func gapProposal(
        a: Oriented, b: Oriented, ink: InkStyle, low: CGFloat, high: CGFloat, span: ClosedRange<CGFloat>,
        width: Int, height: Int, luminance: (Int, Int) -> Int
    ) -> CGRect? {
        let vertical = a.vertical
        let acrossLimit = vertical ? width : height, alongLimit = vertical ? height : width
        func value(_ across: Int, _ along: Int) -> Int { vertical ? luminance(across, along) : luminance(along, across) }
        let thickness = (a.thickness + b.thickness) / 2
        let near = min(a.center, b.center), far = max(a.center, b.center)
        let start = max(0, Int(near - thickness / 2)), end = min(acrossLimit, Int((far + thickness / 2).rounded(.up)))
        let alongStart = max(0, Int(low)), alongEnd = min(alongLimit, Int(high.rounded(.up)))
        guard end - start >= 4, alongEnd - alongStart >= 4 else { return nil }
        let step = max(1, (alongEnd - alongStart) / 160)
        var raw = [Double](repeating: 0, count: end - start)
        var samples = 0
        var along = alongStart
        while along < alongEnd {
            for across in start..<end where ink.isInk(value(across, along)) { raw[across - start] += 1 }
            samples += 1
            along += step
        }
        guard samples > 0 else { return nil }
        let window = max(1, Int(thickness * 0.12))
        var profile = [Double](repeating: 0, count: raw.count)
        for index in raw.indices {
            let lower = max(0, index - window / 2), upper = min(raw.count, lower + window)
            profile[index] = raw[lower..<upper].reduce(0, +) / Double((upper - lower) * samples)
        }
        func mean(_ center: CGFloat, _ span: CGFloat) -> Double {
            let lower = max(0, Int(center - span / 2) - start), upper = min(profile.count, Int(center + span / 2) - start)
            guard upper > lower else { return 0 }
            return profile[lower..<upper].reduce(0, +) / Double(upper - lower)
        }
        let first = mean(a.center, thickness / 2), second = mean(b.center, thickness / 2)
        let reference = min(first, second)
        guard reference > 0.02 else { return nil }
        let innerStart = max(0, Int(near + thickness * 0.45) - start), innerEnd = min(profile.count, Int(far - thickness * 0.45) - start)
        guard CGFloat(innerEnd - innerStart) >= thickness * 0.3 else { return nil }
        var runs: [Range<Int>] = []
        var index = innerStart
        while index < innerEnd {
            guard profile[index] >= reference * 0.45 else {
                index += 1
                continue
            }
            var stop = index
            while stop < innerEnd, profile[stop] >= reference * 0.45 { stop += 1 }
            if let last = runs.last, CGFloat(index - last.upperBound) < thickness * 0.12 {
                runs[runs.count - 1] = last.lowerBound..<stop
            } else {
                runs.append(index..<stop)
            }
            index = stop
        }
        for run in runs where CGFloat(run.count) >= thickness * 0.35 {
            let center = CGFloat(start + (run.lowerBound + run.upperBound) / 2)
            let stripWidth = min(CGFloat(run.count), thickness / 2)
            let density = mean(center, stripWidth)
            guard density >= reference * 0.5, density <= max(first, second) * 2.5 else { continue }
            // Gutters: the profile dips between each flank and the run.
            let nearValley = profile[max(0, Int(near) - start)..<max(max(0, Int(near) - start), run.lowerBound)].min() ?? 0
            let farValley = profile[min(run.upperBound, profile.count)..<max(min(run.upperBound, profile.count),
                                                                              min(profile.count, Int(far) - start))].min() ?? 0
            guard max(nearValley, farValley) <= density * 0.8 else { continue }
            // Same paper and no tone or art: the strip's non-ink pixels match the flank's paper.
            let stripStart = max(0, Int(center - stripWidth / 2)), stripEnd = min(acrossLimit, Int(center + stripWidth / 2) + 1)
            // The missing column can be one glyph longer than either neighbour.
            // Include its complete final glyph instead of recognizing a clipped
            // crop and leaving that glyph's lower strokes outside the erase mask.
            let scanStart = max(0, Int(span.lowerBound - thickness / 2))
            let scanEnd = min(alongLimit, Int(span.upperBound + thickness * (vertical ? 1.5 : 0.5)))
            guard stripEnd > stripStart, scanEnd > scanStart else { continue }
            var paper = [Int](repeating: 0, count: 64)
            var midtones = 0, counted = 0
            var rows = [Bool](repeating: false, count: scanEnd - scanStart)
            let rowStep = max(1, (scanEnd - scanStart) / 400)
            var position = scanStart
            while position < scanEnd {
                var inked = 0
                for across in stripStart..<stripEnd {
                    let pixel = value(across, position)
                    if ink.isInk(pixel) {
                        inked += 1
                    } else if position >= alongStart, position < alongEnd {
                        paper[min(63, max(0, pixel) / 4)] += 1
                    }
                    if position >= alongStart, position < alongEnd {
                        counted += 1
                        if ink.isMidtone(pixel) { midtones += 1 }
                    }
                }
                let ratio = Double(inked) / Double(stripEnd - stripStart)
                for offset in 0..<rowStep where position + offset < scanEnd { rows[position + offset - scanStart] = ratio >= 0.1 }
                position += rowStep
            }
            let paperCount = paper.reduce(0, +)
            guard counted > 0, paperCount > 0 else { continue }
            var seen = 0, paperLevel = 0.0
            for bin in paper.indices {
                seen += paper[bin]
                if seen * 2 >= paperCount {
                    paperLevel = Double(bin * 4 + 2)
                    break
                }
            }
            guard abs(paperLevel - ink.paper) <= ink.separation * 0.25,
                  Double(midtones) / Double(counted) <= max(0.35, ink.midtones * 3) else { continue }
            // Along extent: the inked stretch of the strip that overlaps the flanks' common span.
            var best: Range<Int>?
            var bestOverlap = 0
            var segmentStart: Int?
            var lastInk = -1
            let allowedGap = Int(thickness)
            for row in 0...rows.count {
                let inked = row < rows.count && rows[row]
                if inked {
                    if let begin = segmentStart, row - lastInk > allowedGap {
                        let segment = begin..<(lastInk + 1)
                        let overlap = min(segment.upperBound + scanStart, alongEnd) - max(segment.lowerBound + scanStart, alongStart)
                        if overlap > bestOverlap { best = segment; bestOverlap = overlap }
                        segmentStart = row
                    } else if segmentStart == nil {
                        segmentStart = row
                    }
                    lastInk = row
                } else if row == rows.count, let begin = segmentStart {
                    let segment = begin..<(lastInk + 1)
                    let overlap = min(segment.upperBound + scanStart, alongEnd) - max(segment.lowerBound + scanStart, alongStart)
                    if overlap > bestOverlap { best = segment; bestOverlap = overlap }
                }
            }
            guard let segment = best, CGFloat(segment.count) >= thickness else { continue }
            let boxThickness = min(a.thickness, b.thickness)
            let pad = thickness * 0.15
            let lower = max(0, CGFloat(segment.lowerBound + scanStart) - pad)
            let upper = min(CGFloat(alongLimit), CGFloat(segment.upperBound + scanStart) + pad)
            let acrossLow = max(0, center - boxThickness / 2), acrossHigh = min(CGFloat(acrossLimit), center + boxThickness / 2)
            return vertical
                ? CGRect(x: acrossLow, y: lower, width: acrossHigh - acrossLow, height: upper - lower)
                : CGRect(x: lower, y: acrossLow, width: upper - lower, height: acrossHigh - acrossLow)
        }
        return nil
    }

    /// A read of a proposal is kept when it is confident Japanese/Chinese text as long as its box suggests and not
    /// a re-read of a flank (a box that caught a neighbouring column).
    static func accepts(_ text: String, proposal: Proposal) -> Bool {
        guard NativeOCRAdjacentLineRecovery.admits(text), let box = NativeOCRScopeGeometry.bounds(for: proposal.polygon) else {
            return false
        }
        let length = proposal.vertical ? box.height : box.width, thickness = proposal.vertical ? box.width : box.height
        let glyphs = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        guard thickness > 0, Double(glyphs) >= max(2, Double(length / thickness) * 0.4) else { return false }
        let own = Array(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return !proposal.flankTexts.contains { flank in
            let other = Set(flank.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            return !own.isEmpty && Double(own.filter { other.contains($0) }.count) >= Double(own.count) * 0.6
        }
    }

    /// Recovered lines (`NativeOCRAdjacentLineRecovery`) that sit between two accepted sibling lines, one on each side:
    /// like a gap line, such a line completes the reading order of both.
    static func bridges(_ recovered: [NativeCoreMLOCRLine], lines: [NativeCoreMLOCRLine]) -> [NativeCoreMLOCRGapLine] {
        recovered.compactMap { line in
            let siblings = lines.filter { NativeOCRAdjacentLineRecovery.isAdjacent(line.polygon, to: $0.polygon) }
            guard let first = siblings.first, let axis = NativeOCRAdjacentLineRecovery.axis(first.polygon),
                  let own = NativeOCRAdjacentLineRecovery.axis(line.polygon, direction: axis.direction) else { return nil }
            let center = (own.across.lowerBound + own.across.upperBound) / 2
            var sides: [Bool: (distance: CGFloat, polygon: [CGPoint])] = [:]
            for sibling in siblings {
                guard let other = NativeOCRAdjacentLineRecovery.axis(sibling.polygon, direction: axis.direction) else { continue }
                let offset = (other.across.lowerBound + other.across.upperBound) / 2 - center
                if abs(offset) < (sides[offset > 0]?.distance ?? .infinity) { sides[offset > 0] = (abs(offset), sibling.polygon) }
            }
            guard let before = sides[false], let after = sides[true],
                  // Like a gap line's flanks: two lines of one lettering size, not a display or sound-effect box
                  // twice as thick beside the caption (diverse-4496).
                  let first = NativeOCRAdjacentLineRecovery.axis(before.polygon, direction: axis.direction),
                  let second = NativeOCRAdjacentLineRecovery.axis(after.polygon, direction: axis.direction) else { return nil }
            let thickness = [first, second].map { $0.across.upperBound - $0.across.lowerBound }
            guard let thin = thickness.min(), thin > 0, (thickness.max() ?? 0) <= thin * 1.35 else { return nil }
            return NativeCoreMLOCRGapLine(line: line, flanks: [after.polygon, before.polygon])
        }
    }

    /// Gap lines with no balloon outline, panel rule or other enclosed surface between them and either flank.
    static func admitted(
        _ gaps: [NativeCoreMLOCRGapLine], separates: (CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool
    ) -> [NativeCoreMLOCRGapLine] {
        gaps.filter { gap in
            guard let bounds = NativeOCRScopeGeometry.bounds(for: gap.line.polygon), gap.flanks.count == 2 else { return false }
            return gap.flanks.allSatisfy { flank in
                guard let rect = NativeOCRScopeGeometry.bounds(for: flank) else { return false }
                return !separates(rect, bounds, gap.line.orientation == .vertical ? .vertical : .horizontal)
            }
        }
    }
}

/// Splits a strong detector box that holds a stack of short lettered rows ("IT'S / ME.", "I'LL / SEE / YOU!") into
/// its rows. Tightly leaded comic lettering in a small balloon fuses into one box in the probability map; the
/// recognizer then reads the whole stack as one tall crop and fails, and the balloon stays in the source language.
/// The rows are found in the box's own pixels (ink bands separated by clean gutters) and read again; only a stack
/// whose every row reads as a short Latin row, at least half of them confidently, replaces the failed read.
@available(iOS 18.0, *)
enum NativeOCRStackedRowSplit {
    struct Proposal: Equatable {
        let sourceIndex: Int
        let rows: [[CGPoint]]
    }

    static let maximumProposals = 6
    static let maximumExamined = 24

    /// A short Latin row: 1-16 basic Latin letters in at most three words, no digits or CJK.
    static func admitsRow(_ text: String) -> Bool {
        let visible = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let letters = visible.filter { CharacterSet.letters.contains($0) }
        return (1...16).contains(letters.count)
            && letters.allSatisfy { 0x41...0x5A ~= $0.value || 0x61...0x7A ~= $0.value }
            && !visible.contains { CharacterSet.decimalDigits.contains($0) }
            && visible.count - letters.count <= max(3, letters.count)
            && text.split(whereSeparator: \.isWhitespace).count <= 3
    }

    /// Every row reads as a short Latin row, at least half of them at the confidence threshold, with three letters in all.
    static func accepts(_ reads: [NativeCoreMLRecognizedRegion?], threshold: Double) -> Bool {
        let found = reads.compactMap { $0 }
        guard found.count == reads.count, found.allSatisfy({ admitsRow($0.text) }) else { return false }
        let letters = found.reduce(0) { $0 + $1.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count }
        return letters >= 3 && found.filter { $0.confidence >= threshold }.count * 2 >= found.count
    }

    static func proposals(
        width: Int, height: Int, luminance: (Int, Int) -> Int, boxes: [(sourceIndex: Int, polygon: [CGPoint])]
    ) -> [Proposal] {
        var result: [Proposal] = []
        for box in boxes.prefix(maximumExamined) {
            guard result.count < maximumProposals, let bounds = NativeOCRScopeGeometry.bounds(for: box.polygon) else { continue }
            let x0 = max(0, Int(bounds.minX.rounded(.down))), x1 = min(width, Int(bounds.maxX.rounded(.up)))
            let y0 = max(0, Int(bounds.minY.rounded(.down))), y1 = min(height, Int(bounds.maxY.rounded(.up)))
            guard x1 - x0 >= 12, y1 - y0 >= 12, (x1 - x0) * (y1 - y0) <= width * height / 20,
                  let rows = rows(x0: x0, y0: y0, x1: x1, y1: y1, luminance: luminance) else { continue }
            result.append(Proposal(sourceIndex: box.sourceIndex, rows: rows))
        }
        return result
    }

    private static func rows(x0: Int, y0: Int, x1: Int, y1: Int, luminance: (Int, Int) -> Int) -> [[CGPoint]]? {
        let w = x1 - x0, h = y1 - y0
        var histogram = [Int](repeating: 0, count: 256)
        var values = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let value = UInt8(clamping: luminance(x0 + x, y0 + y))
                values[y * w + x] = value
                histogram[Int(value)] += 1
            }
        }
        // Otsu threshold; ink and paper must differ clearly.
        let total = Double(w * h)
        var sum: Double = 0
        for level in 0..<256 { sum += Double(level * histogram[level]) }
        var below: Double = 0, belowSum: Double = 0, best: Double = -1, threshold = 0
        for level in 0..<256 {
            below += Double(histogram[level]); belowSum += Double(level * histogram[level])
            guard below > 0, below < total else { continue }
            let low = belowSum / below, high = (sum - belowSum) / (total - below)
            let score = below * (total - below) * (high - low) * (high - low)
            if score > best { best = score; threshold = level }
        }
        let lowCount = histogram[0...threshold].reduce(0, +), highCount = w * h - lowCount
        guard lowCount > 0, highCount > 0 else { return nil }
        let lowMean = Double(histogram[0...threshold].enumerated().reduce(0) { $0 + $1.offset * $1.element }) / Double(lowCount)
        let highMean = (sum - lowMean * Double(lowCount)) / Double(highCount)
        guard highMean - lowMean >= 60 else { return nil }
        // Paper is the level most of the box border shows.
        var lightBorder = 0, border = 0
        for x in 0..<w {
            for y in [0, h - 1] { border += 1; if Int(values[y * w + x]) > threshold { lightBorder += 1 } }
        }
        for y in 1..<(h - 1) {
            for x in [0, w - 1] { border += 1; if Int(values[y * w + x]) > threshold { lightBorder += 1 } }
        }
        let darkInk = lightBorder * 2 >= border
        func isInk(_ value: UInt8) -> Bool { darkInk ? Int(value) <= threshold : Int(value) > threshold }
        var profile = [Double](repeating: 0, count: h)
        for y in 0..<h {
            var count = 0
            for x in 0..<w where isInk(values[y * w + x]) { count += 1 }
            profile[y] = Double(count) / Double(w)
        }
        guard let peak = profile.max(), peak > 0 else { return nil }
        var bands: [Range<Int>] = []
        var start: Int?
        for y in 0...h {
            let inked = y < h && profile[y] > peak * 0.06
            if inked, start == nil { start = y }
            if !inked, let first = start { if y - first >= 2 { bands.append(first..<y) }; start = nil }
        }
        // Thin slivers at the ends (a balloon outline or a neighbour's edge inside the box) are not rows.
        func median(_ values: [Int]) -> Double {
            let sorted = values.sorted()
            return sorted.count.isMultiple(of: 2)
                ? Double(sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : Double(sorted[sorted.count / 2])
        }
        while bands.count >= 3 {
            let middle = median(bands.map(\.count))
            if Double(bands[0].count) < middle * 0.45 { bands.removeFirst() }
            else if Double(bands[bands.count - 1].count) < middle * 0.45 { bands.removeLast() }
            else { break }
        }
        guard (2...5).contains(bands.count) else { return nil }
        let thickness = median(bands.map(\.count))
        guard bands.allSatisfy({ Double($0.count) >= thickness * 0.45 && Double($0.count) <= thickness * 2.2 }),
              zip(bands, bands.dropFirst()).allSatisfy({ Double($1.lowerBound - $0.upperBound) >= max(1, thickness * 0.08) })
        else { return nil }
        var quads: [[CGPoint]] = []
        var densities: [Double] = []
        for band in bands {
            var left = w, right = -1, ink = 0
            for y in band {
                for x in 0..<w where isInk(values[y * w + x]) { left = min(left, x); right = max(right, x); ink += 1 }
            }
            // A row is lettering along the reading direction, not one glyph of a vertical column.
            guard right >= left, Double(right - left + 1) >= Double(band.count) * 1.5 else { return nil }
            densities.append(Double(ink) / Double((right - left + 1) * band.count))
            let pad = max(1, Int((Double(band.count) * 0.15).rounded()))
            let qx0 = CGFloat(max(0, x0 + left - pad)), qx1 = CGFloat(min(x1, x0 + right + 1 + pad))
            let qy0 = CGFloat(max(0, y0 + band.lowerBound - pad)), qy1 = CGFloat(min(y1, y0 + band.upperBound + pad))
            quads.append([CGPoint(x: qx0, y: qy0), CGPoint(x: qx1, y: qy0), CGPoint(x: qx1, y: qy1), CGPoint(x: qx0, y: qy1)])
        }
        guard let low = densities.min(), let high = densities.max(), high <= low * 3 else { return nil }
        return quads
    }
}

/// Recovers whole utterances whose only read fell just under the confidence gate: a short handwritten or
/// stylised balloon line ("こら～!", "うう…", "まで!?") is read correctly at 0.6-0.75 far more often than a caption
/// line, and no accepted line beside it can anchor the adjacent-line recovery, so the balloon stays untranslated.
/// Only reads of strong detector boxes qualify, already decoded by the primary pass (no extra model work), and
/// only Japanese/Chinese text: at least two kana/Han, no Latin letters or digits, no notices, and on a page whose
/// accepted text uses kana, kana of its own (a Han-only read there is a sign, a book spine or a misread).
@available(iOS 18.0, *)
enum NativeOCRIsolatedLineRecovery {
    /// Reads down to the confidence threshold minus this margin qualify.
    static let confidenceMargin = 0.15
    /// More candidates than this on one page (dense low-quality handwriting) recovers nothing.
    static let maximumPerPage = 6

    static func admits(_ text: String, pageUsesKana: Bool) -> Bool {
        guard NativeOCRAdjacentLineRecovery.admits(text),
              !text.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return false }
        let kana = text.unicodeScalars.contains { 0x3041...0x30FA ~= $0.value && $0.value != 0x30FB }
        if pageUsesKana, !kana { return false }
        // One Han character repeated ("国国") is a texture or pattern read.
        let han = Set(text.unicodeScalars.filter { 0x3400...0x9FFF ~= $0.value })
        return kana || han.count >= 2
    }

    static func usesKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { 0x3041...0x30FA ~= $0.value && $0.value != 0x30FB && $0.value != 0x30FC }
    }

    /// Candidates of `reads` (rejected reads) that no accepted, recovered or other stronger candidate line overlaps.
    static func candidates(
        _ reads: [NativeCoreMLRecognizedRegion], threshold: Double, accepted: [NativeCoreMLRecognizedRegion],
        occupied: [[CGPoint]]
    ) -> [NativeCoreMLRecognizedRegion] {
        let pageUsesKana = accepted.contains { usesKana($0.text) }
        let blockers = (accepted.map(\.polygon) + occupied).compactMap(NativeOCRScopeGeometry.bounds(for:))
        func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
            NativeOCRScopeGeometry.intersectionArea(a, b) >= min(a.width * a.height, b.width * b.height) * 0.3
        }
        var chosen: [(read: NativeCoreMLRecognizedRegion, bounds: CGRect)] = []
        for read in reads.sorted(by: { $0.confidence > $1.confidence }) {
            guard read.confidence >= threshold - confidenceMargin, read.confidence < threshold,
                  admits(read.text, pageUsesKana: pageUsesKana),
                  let bounds = NativeOCRScopeGeometry.bounds(for: read.polygon),
                  !blockers.contains(where: { overlaps($0, bounds) }),
                  !chosen.contains(where: { overlaps($0.bounds, bounds) }) else { continue }
            chosen.append((read, bounds))
            // Selection only grows: once the page exceeds the cap, later reads cannot make it eligible.
            guard chosen.count <= maximumPerPage else { return [] }
        }
        return chosen.map(\.read).sorted { $0.sourceIndex < $1.sourceIndex }
    }

    /// Captions grouped from isolated lines alone that overlap no existing caption (by 20 % of either box);
    /// their ids follow the existing ones.
    static func captions(_ grouped: [ReaderTranslationRegion], beside existing: [ReaderTranslationRegion]) -> [ReaderTranslationRegion] {
        let used = Set(existing.map(\.id))
        var next = existing.count
        func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
        return grouped.compactMap { region in
            guard !existing.contains(where: { other in
                NativeOCRScopeGeometry.intersectionArea(region.rect, other.rect) >= min(area(region.rect), area(other.rect)) * 0.2
            }) else { return nil }
            while used.contains("region-\(next)") { next += 1 }
            defer { next += 1 }
            var caption = ReaderTranslationRegion(
                id: "region-\(next)", rect: region.rect, source: region.source, translation: region.translation,
                polygon: region.polygon, confidence: region.confidence, sourceImageAspectRatio: region.sourceImageAspectRatio,
                translationOrder: region.translationOrder, translationOrderVersion: region.translationOrderVersion,
                sourceOrientation: region.sourceOrientation, sourceSingleVerticalColumn: region.sourceSingleVerticalColumn,
                translationReuseIdentity: region.translationReuseIdentity, auxiliaryInkRects: region.auxiliaryInkRects,
                auxiliaryInkPolygons: region.auxiliaryInkPolygons
            )
            caption.isRecoveredLine = true
            return caption
        }
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLOCRModelProfile: Equatable, Sendable {
    let tier: IPhoneOCRModelTier
    let detectorResourceName: String
    let recognizerResourceName: String
    let dictionaryResourceName: String
    let expectedDictionaryCharacterCount: Int
    let postprocessConfiguration: NativeCoreMLDBPostprocessConfiguration

    static func profile(for tier: IPhoneOCRModelTier) -> Self {
        switch tier {
        case .medium:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Medium-DetShapes",
                recognizerResourceName: "PP-OCRv6-Medium-RecWidths",
                dictionaryResourceName:
                    "ppocrv6_medium_rec_character_dict",
                expectedDictionaryCharacterCount: 18_709,
                postprocessConfiguration: .production.withRecoveryBoxThreshold(NativeOCRAdjacentLineRecovery.boxThreshold)
            )
        case .small:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Small-DetShapes",
                recognizerResourceName: "PP-OCRv6-Small-RecWidths",
                dictionaryResourceName:
                    "ppocrv6_small_rec_character_dict",
                expectedDictionaryCharacterCount: 18_709,
                postprocessConfiguration: .production.withRecoveryBoxThreshold(NativeOCRAdjacentLineRecovery.boxThreshold)
            )
        case .tiny:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Tiny-DetShapes",
                recognizerResourceName: "PP-OCRv6-Tiny-RecWidths",
                dictionaryResourceName:
                    "ppocrv6_tiny_rec_character_dict",
                expectedDictionaryCharacterCount: 6_905,
                postprocessConfiguration: .tiny
            )
        }
    }
}

/// Runs both PP-OCRv6 model stages through native Core ML. The
/// detector's source-space quads are passed directly to the recognizer, so no
/// PNG/base64/WebKit copy exists on the primary iPhone path.
@available(iOS 18.0, *)
enum NativeCoreMLOCRStage: Equatable, Sendable {
    case detecting
    case recognizing(regionCount: Int)
}

@available(iOS 18.0, *)
enum NativeCoreMLModelPreparationStage: Equatable, Sendable {
    case detectorReady
    case recognizerReady
}

@available(iOS 18.0, *)
final class NativeCoreMLOCRPipeline: @unchecked Sendable {
    typealias FrameConverter = @Sendable (CGImage) async
        -> NativeOCRRGBAFrame?

    private let detector: any NativeCoreMLDetecting
    private let recognizer: any NativeCoreMLRecognizing
    private let frameConverter: FrameConverter
    private let postprocessConfiguration:
        NativeCoreMLDBPostprocessConfiguration
    private let generation = NativeCoreMLOCRGeneration()

    init(
        detector: any NativeCoreMLDetecting = NativeCoreMLDetector(),
        recognizer: any NativeCoreMLRecognizing = NativeCoreMLRecognizer(),
        postprocessConfiguration:
            NativeCoreMLDBPostprocessConfiguration = .production,
        frameConverter: @escaping FrameConverter = { image in
            await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image)
        }
    ) {
        self.detector = detector
        self.recognizer = recognizer
        self.postprocessConfiguration = postprocessConfiguration
        self.frameConverter = frameConverter
    }

    // Reader settings and CLI options enforce the reader resolution limits.
    // Explicit dimensions remain available for model and historical replay tests.
    convenience init(
        modelTier: IPhoneOCRModelTier,
        detectorMaximumSide: Int =
            IPhoneOCRSettings.defaultDetectorMaximumSide,
        recognizerMaximumWidth: Int =
            IPhoneOCRSettings.defaultRecognizerMaximumWidth,
        bundle: Bundle = .main
    ) {
        let profile = NativeCoreMLOCRModelProfile.profile(for: modelTier)
        self.init(
            detector: NativeCoreMLDetector(
                bundle: bundle,
                modelResourceName: profile.detectorResourceName,
                maximumSide: detectorMaximumSide
            ),
            recognizer: NativeCoreMLRecognizer(
                bundle: bundle,
                modelResourceName: profile.recognizerResourceName,
                dictionaryResourceName: profile.dictionaryResourceName,
                expectedDictionaryCharacterCount:
                    profile.expectedDictionaryCharacterCount,
                maximumRecognitionWidth: recognizerMaximumWidth
            ),
            postprocessConfiguration: profile.postprocessConfiguration
        )
    }

    /// Moves the bounded Core ML model specialization cost off the first OCR
    /// frame. Preparation has an explicit lifetime separate from OCR frame
    /// generations: `cancelCurrent()` only invalidates obsolete frame work,
    /// while production owners cancel and await speculative preparation before
    /// admitting inference. Completed resident models remain reusable. Each
    /// underlying model store coalesces same-function loads, and
    /// `purgeResources()` is the explicit boundary that clears them.
    ///
    /// Initializes the two bundled OCR model packages sequentially. The
    /// recognizer prepares its bounded common-width working set; later unusual
    /// crop widths can still demand-load their exact function.
    func prepare(
        sourceWidth: Int,
        sourceHeight: Int,
        stageHandler: (@Sendable (NativeCoreMLModelPreparationStage) async -> Void)? = nil
    ) async throws {
        try await detector.prepare(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        await stageHandler?(.detectorReady)
        try await recognizer.prepare()
        await stageHandler?(.recognizerReady)
    }

    /// Reader-open warm-up: loads the detector model and prepares the
    /// recognizer concurrently, before the first page image is known. Unlike
    /// `prepare(sourceWidth:sourceHeight:)` the detector runs no speculative
    /// prediction, because its dynamic input shape depends on the page. Both
    /// stores coalesce with concurrent OCR loads, so this only moves loads
    /// that the first OCR frame would perform anyway. Idempotent: resident
    /// models return immediately. Cancel with task cancellation or
    /// `cancelPreparation()`/`purgeResources()`.
    func warmUp() async throws {
        async let detectorReady: Void = detector.warmUpModel()
        async let recognizerReady: Void = recognizer.prepare()
        _ = try await (detectorReady, recognizerReady)
    }

    /// Best-effort post-result specialization. The production recognizer
    /// refuses to evict actual-demand functions and retains spare capacity for
    /// the next unseen width; low-memory configurations may intentionally do
    /// no work.
    func prepareRecognizerIdlePreservingDemandCapacity() async throws {
        try await recognizer.prepareIdlePreservingDemandCapacity()
    }

    func cancelCurrent() {
        // Invalidate the whole detector -> recognizer transaction first. This
        // makes cancellation sticky even when it lands immediately before the
        // recognizer creates its own stage-local generation.
        generation.cancelCurrent()
        detector.cancelCurrent()
        recognizer.cancelCurrent()
    }

    /// Stops preparation that has not yet crossed a model-store admission
    /// point. Already resident functions remain available to later OCR.
    func cancelPreparation() {
        detector.cancelPreparation()
        recognizer.cancelPreparation()
    }

    func purgeResources() async {
        cancelPreparation()
        cancelCurrent()
        async let detectorPurge: Void = detector.purgeResources()
        async let recognizerPurge: Void = recognizer.purgeResources()
        _ = await (detectorPurge, recognizerPurge)
    }

    func recognize(
        image: CGImage,
        requestID: String,
        confidenceThreshold: Double,
        detectorConfiguration: NativeCoreMLDBPostprocessConfiguration? = nil,
        recognitionScope: CGRect? = nil
    ) async throws -> NativeCoreMLOCRResult {
        try await recognize(
            image: image,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            detectorConfiguration: detectorConfiguration,
            recognitionScopes: recognitionScope.map { [$0] }
        )
    }

    func recognize(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        confidenceThreshold: Double,
        detectorConfiguration: NativeCoreMLDBPostprocessConfiguration? = nil,
        recognitionScope: CGRect? = nil
    ) async throws -> NativeCoreMLOCRResult {
        try await recognize(
            frame: frame,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            detectorConfiguration: detectorConfiguration,
            recognitionScopes: recognitionScope.map { [$0] }
        )
    }

    /// Runs the exact full-frame detector once, then admits recognition only
    /// for boxes whose bounds intersect one of the dirty content scopes. This
    /// matches display invalidation so a changed tail of a long line cannot
    /// remove the old line without re-recognizing its replacement.
    /// The single-scope overload above preserves the containing-app API.
    func recognize(
        image: CGImage,
        requestID: String,
        confidenceThreshold: Double,
        detectorConfiguration: NativeCoreMLDBPostprocessConfiguration? = nil,
        recognitionScopes: [CGRect]?
    ) async throws -> NativeCoreMLOCRResult {
        try await performRecognition(
            providedFrame: nil,
            image: image,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            detectorConfiguration: detectorConfiguration,
            recognitionScopes: recognitionScopes
        )
    }

    /// Entry point for callers that already own canonical RGBA pixels. It is
    /// also the parity seam used by tests; no converter is invoked here.
    func recognize(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        confidenceThreshold: Double,
        detectorConfiguration: NativeCoreMLDBPostprocessConfiguration? = nil,
        recognitionScopes: [CGRect]?,
        stageHandler: (@Sendable (NativeCoreMLOCRStage) -> Void)? = nil
    ) async throws -> NativeCoreMLOCRResult {
        try await performRecognition(
            providedFrame: frame,
            image: nil,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            detectorConfiguration: detectorConfiguration,
            recognitionScopes: recognitionScopes,
            stageHandler: stageHandler
        )
    }

    private func performRecognition(
        providedFrame: NativeOCRRGBAFrame?,
        image: CGImage?,
        requestID: String,
        confidenceThreshold: Double,
        detectorConfiguration: NativeCoreMLDBPostprocessConfiguration?,
        recognitionScopes: [CGRect]?,
        stageHandler: (@Sendable (NativeCoreMLOCRStage) -> Void)? = nil
    ) async throws -> NativeCoreMLOCRResult {
        let issuedGeneration = generation.begin()
        let started = Self.nowMilliseconds()
        let cancellationCheck: @Sendable () throws -> Void = {
            [generation] in
            try generation.requireCurrent(issuedGeneration)
        }
        return try await withTaskCancellationHandler {
            try cancellationCheck()
            let frame: NativeOCRRGBAFrame
            let frameConversionMilliseconds: Double
            if let providedFrame {
                frame = providedFrame
                frameConversionMilliseconds = 0
            } else if let image {
                let conversionStarted = Self.nowMilliseconds()
                guard let converted = await frameConverter(image) else {
                    throw NativeCoreMLDetectorError.imageConversionFailed
                }
                frame = converted
                frameConversionMilliseconds = max(
                    0,
                    Self.nowMilliseconds() - conversionStarted
                )
            } else {
                throw NativeCoreMLDetectorError.imageConversionFailed
            }
            try cancellationCheck()
            let frameBounds = CGRect(
                x: 0,
                y: 0,
                width: frame.width,
                height: frame.height
            )
            let standardizedScopes = recognitionScopes?.compactMap {
                scope -> CGRect? in
                guard scope.origin.x.isFinite, scope.origin.y.isFinite,
                      scope.size.width.isFinite,
                      scope.size.height.isFinite
                else {
                    return nil
                }
                let clipped = scope.standardized.intersection(frameBounds)
                return clipped.isNull || clipped.isEmpty ? nil : clipped
            }
            stageHandler?(.detecting)
            let detection = try await detector.detect(
                frame: frame,
                requestID: requestID,
                configuration: detectorConfiguration ?? postprocessConfiguration,
                // The detector model still receives the complete frame. Its
                // CPU output materialization and recognition admission may be
                // limited to dirty scopes for a partial refresh.
                recognitionScopes: standardizedScopes,
                cancellationCheck: cancellationCheck
            )
            try cancellationCheck()
            guard detection.requestID == requestID else {
                throw CancellationError()
            }

            let regions = detection.boxes.enumerated().compactMap {
                index, box -> NativeCoreMLRecognitionRegion? in
                guard box.polygon.count == 4,
                      recognitionScopes == nil || standardizedScopes?.contains(where: { scope in
                          guard let bounds = NativeOCRScopeGeometry.bounds(
                              for: box.polygon
                          ) else {
                              return false
                          }
                          return NativeOCRScopeGeometry.intersectionArea(
                              bounds,
                              scope
                          ) > 0
                      }) == true
                else {
                    return nil
                }
                return NativeCoreMLRecognitionRegion(
                    sourceIndex: index,
                    polygon: box.polygon
                )
            }

            var recognition: NativeCoreMLRecognitionResult?
            var recoveredHorizontal = Set<Int>()
            var rejectedReads: [NativeCoreMLRecognizedRegion] = []
            let threshold = min(max(confidenceThreshold, 0), 1)
            let detectorThresholds = detectorConfiguration ?? postprocessConfiguration
            // Weak boxes (recovery band below the box threshold) never enter the primary pass, so
            // the confident reads and their batches are exactly those of the plain detector output.
            let recovers = detectorThresholds.recoveryBoxThreshold != nil
            let strongRegions = regions.filter { region in
                !recovers || (detection.boxes.indices.contains(region.sourceIndex)
                    && detection.boxes[region.sourceIndex].score >= detectorThresholds.boxThreshold)
            }
            if strongRegions.isEmpty {
                recognition = nil
            } else {
                try cancellationCheck()
                stageHandler?(.recognizing(regionCount: strongRegions.count))
                let decoded = try await recognizer.recognize(
                    frame: frame,
                    regions: strongRegions,
                    requestID: requestID,
                    confidenceThreshold: recovers ? max(0, threshold - NativeOCRAdjacentLineRecovery.confidenceMargin) : threshold,
                    cancellationCheck: cancellationCheck
                )
                try cancellationCheck()
                guard decoded.requestID == requestID else {
                    throw CancellationError()
                }
                // Reads below the confidence threshold are kept aside as recovery candidates only.
                rejectedReads = decoded.regions.filter { $0.confidence < threshold }
                let value = rejectedReads.isEmpty ? decoded : NativeCoreMLRecognitionResult(
                    requestID: requestID, regions: decoded.regions.filter { $0.confidence >= threshold },
                    diagnostics: decoded.diagnostics.withAcceptedRegions(decoded.regions.count - rejectedReads.count)
                )
                recognition = value
                // A steep Latin baseline and a tilted Japanese vertical column
                // can share the same quad. Retry only rejected ambiguous crops,
                // once, with the other reading direction (at most 32 regions).
                // Ambiguous Latin words also compare both crops: a reversed
                // BEVERLY can otherwise decode confidently as only "VRL".
                let accepted = Dictionary(uniqueKeysWithValues: value.regions.map { ($0.sourceIndex, $0) })
                let alternate = strongRegions.filter { region in
                    accepted[region.sourceIndex].map { NativeOCRScopeGeometry.isLatinWord($0.text) } ?? true
                }.compactMap { region -> NativeCoreMLRecognitionRegion? in
                    guard let quad = NativeOCRScopeGeometry.alternateHorizontalQuad(region.polygon) else { return nil }
                    return NativeCoreMLRecognitionRegion(sourceIndex: region.sourceIndex, polygon: quad, useProvidedOrder: true)
                }
                if !alternate.isEmpty {
                    let recovery = try await recognizer.recognize(frame: frame, regions: Array(alternate.prefix(32)),
                        requestID: requestID, confidenceThreshold: max(0.85, confidenceThreshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    let additional = recovery.regions.filter { candidate in
                        guard candidate.text.count >= 2, candidate.text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
                        guard let previous = accepted[candidate.sourceIndex] else { return true }
                        return candidate.confidence > previous.confidence + 0.01 ||
                            candidate.confidence >= previous.confidence - 0.02 && candidate.text.count >= previous.text.count
                    }
                    recoveredHorizontal = Set(additional.map(\.sourceIndex))
                    let selected = value.regions.filter { !recoveredHorizontal.contains($0.sourceIndex) } + additional
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: value.diagnostics.addingRecovery(recovery.diagnostics, acceptedCount: selected.count))
                }
            }

            if recovers, let current = recognition {
                let acceptedIDs = Set(current.regions.map(\.sourceIndex))
                let failed = strongRegions.filter { !acceptedIDs.contains($0.sourceIndex) }
                let reactions = try NativeOCRShortReactionRecovery.recover(frame: frame, failed: failed, accepted: current.regions)
                try cancellationCheck()
                if !reactions.isEmpty {
                    let selected = current.regions + reactions
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.withAcceptedRegions(selected.count))
                }
            }

            if recovers, let current = recognition {
                let (nextSourceIndex, idOverflow) = (current.regions.map(\.sourceIndex).max() ?? 0).addingReportingOverflow(1)
                let nextID = max(detection.boxes.count, nextSourceIndex)
                let proposals = idOverflow ? [] : NativeOCRFusedColumnRecovery.proposals(current.regions, frame: frame, startingID: nextID)
                try cancellationCheck()
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.9, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    var recoveredFused = Set<Int>()
                    for proposal in proposals {
                        if let owner = proposal.fusedOwner, !recoveredFused.contains(owner) { continue }
                        guard let replacements = NativeOCRFusedColumnRecovery.replacements(proposal, reads: reread.regions) else { continue }
                        selected.removeAll { $0.sourceIndex == proposal.original.sourceIndex }
                        selected += replacements
                        recoveredFused.insert(proposal.original.sourceIndex)
                        recoveredHorizontal.remove(proposal.original.sourceIndex)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            if recovers, let current = recognition {
                let (nextSourceIndex, idOverflow) = (current.regions.map(\.sourceIndex).max() ?? 0).addingReportingOverflow(1)
                let nextID = max(detection.boxes.count, nextSourceIndex)
                let proposals = idOverflow ? [] : NativeOCRFusedColumnRecovery.anchoredProposals(current.regions, frame: frame, startingID: nextID)
                try cancellationCheck()
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.9, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    for proposal in proposals {
                        guard let replacement = NativeOCRFusedColumnRecovery.anchoredReplacement(proposal, reads: reread.regions) else { continue }
                        selected.removeAll { $0.sourceIndex == proposal.original.sourceIndex }
                        selected.append(replacement)
                        recoveredHorizontal.remove(proposal.original.sourceIndex)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            if recovers, let current = recognition {
                let proposals = NativeOCRShortFragmentRecovery.proposals(current.regions, width: frame.width, height: frame.height)
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.9, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    for proposal in proposals {
                        guard let replacement = NativeOCRShortFragmentRecovery.replacement(proposal, reads: reread.regions) else { continue }
                        selected.removeAll { proposal.replaced.contains($0.sourceIndex) }
                        selected.append(replacement)
                        recoveredHorizontal.subtract(proposal.replaced)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            if recovers, let current = recognition {
                let (nextSourceIndex, idOverflow) = (current.regions.map(\.sourceIndex).max() ?? 0).addingReportingOverflow(1)
                let nextID = max(detection.boxes.count, nextSourceIndex)
                let proposals = idOverflow ? [] : NativeOCRShortContextRecovery.proposals(current.regions, frame: frame, startingID: nextID)
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.65, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    for proposal in proposals {
                        guard let replacement = NativeOCRShortContextRecovery.replacement(proposal, reads: reread.regions, frame: frame) else { continue }
                        selected.removeAll { $0.sourceIndex == proposal.original.sourceIndex }
                        selected.append(replacement)
                        recoveredHorizontal.remove(proposal.original.sourceIndex)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            // A horizontal detector box may contain the heads of distinct vertical
            // columns. Only replace it after every full-column re-read preserves
            // its established suffix and confirms the corresponding head glyph.
            if let current = recognition {
                let proposals = NativeOCRCrossColumnRecovery.proposals(current.regions)
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.75, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    for proposal in proposals {
                        guard let replacements = NativeOCRCrossColumnRecovery.replacements(proposal, reads: reread.regions) else { continue }
                        let replaced = Set(replacements.map(\.sourceIndex)).union([proposal.row.sourceIndex])
                        selected.removeAll { replaced.contains($0.sourceIndex) }
                        selected += replacements
                        recoveredHorizontal.subtract(replaced)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            if let current = recognition {
                let grid = NativeOCRGridColumnRecovery.proposals(current.regions, width: frame.width, height: frame.height,
                                                                  startingID: detection.boxes.count)
                let extraBase = max(detection.boxes.count, max(current.regions.map(\.sourceIndex).max() ?? 0,
                                    grid.flatMap(\.regions).map(\.sourceIndex).max() ?? 0) + 1)
                let proposals = grid.enumerated().map { index, proposal in
                    NativeOCRGridColumnRecovery.pixelRefined(proposal, reads: current.regions,
                                                             frame: frame, addedID: extraBase + index) ?? proposal
                }
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.8, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    for proposal in proposals {
                        guard let replacements = NativeOCRGridColumnRecovery.replacements(proposal, reads: reread.regions) else { continue }
                        selected.removeAll { proposal.replaced.contains($0.sourceIndex) }
                        selected += replacements
                        recoveredHorizontal.subtract(proposal.replaced)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            if let current = recognition {
                let nextID = max(detection.boxes.count, (current.regions.map(\.sourceIndex).max() ?? 0) + 1)
                let proposals = NativeOCRGridColumnRecovery.shortVerticalProposals(current.regions,
                    frame: frame, startingID: nextID)
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.8, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    for proposal in proposals {
                        guard let replacements = NativeOCRGridColumnRecovery.replacements(proposal, reads: reread.regions),
                              replacements.contains(where: { candidate in
                                  proposal.replaced.contains(candidate.sourceIndex) &&
                                  candidate.text.count > (current.regions.first {
                                      $0.sourceIndex == candidate.sourceIndex
                                  }?.text.count ?? 0)
                              }) else { continue }
                        selected.removeAll { proposal.replaced.contains($0.sourceIndex) }
                        selected += replacements
                        recoveredHorizontal.subtract(proposal.replaced)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            if let current = recognition {
                let nextID = max(detection.boxes.count, (current.regions.map(\.sourceIndex).max() ?? 0) + 1)
                let proposals = NativeOCRGridColumnRecovery.singleRowProposals(current.regions,
                    frame: frame, startingID: nextID)
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.8, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    for proposal in proposals {
                        guard let replacements = NativeOCRGridColumnRecovery.replacements(proposal, reads: reread.regions),
                              replacements.filter({ $0.text.count >= 3 }).count >= proposal.regions.count - 1,
                              replacements.filter({ $0.confidence >= 0.9 }).count >= proposal.regions.count - 1,
                              replacements.reduce(0, { $0 + $1.text.count }) >= proposal.regions.count * 2 else { continue }
                        selected.removeAll { proposal.replaced.contains($0.sourceIndex) }
                        selected += replacements
                        recoveredHorizontal.subtract(proposal.replaced)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            if let current = recognition {
                let nextID = max(detection.boxes.count, (current.regions.map(\.sourceIndex).max() ?? 0) + 1)
                let proposals = NativeOCRGridColumnRecovery.tailRowProposals(current.regions,
                    frame: frame, startingID: nextID)
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.8, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    for proposal in proposals {
                        guard let replacements = NativeOCRGridColumnRecovery.replacements(proposal, reads: reread.regions),
                              replacements.count == proposal.regions.count,
                              replacements.allSatisfy({ $0.confidence >= 0.9 && $0.text.count >= 5 }) else { continue }
                        selected.removeAll { proposal.replaced.contains($0.sourceIndex) }
                        selected += replacements
                        recoveredHorizontal.subtract(proposal.replaced)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            if recovers, let current = recognition {
                let proposals = NativeOCRStackedAsideRecovery.proposals(current.regions)
                if !proposals.isEmpty {
                    let reread = try await recognizer.recognize(frame: frame, regions: proposals.flatMap(\.regions),
                        requestID: requestID, confidenceThreshold: max(0.85, threshold), cancellationCheck: cancellationCheck)
                    try cancellationCheck()
                    guard reread.requestID == requestID else { throw CancellationError() }
                    var selected = current.regions
                    for proposal in proposals {
                        guard let replacements = NativeOCRStackedAsideRecovery.replacements(proposal, reads: reread.regions) else { continue }
                        let ids = Set(proposal.originals.map(\.sourceIndex))
                        selected.removeAll { ids.contains($0.sourceIndex) }
                        selected += replacements
                        recoveredHorizontal.subtract(ids)
                    }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.addingRecovery(reread.diagnostics, acceptedCount: selected.count))
                }
            }

            // Stacked-row split: a strong box with no accepted read that holds a stack of short Latin rows.
            var splitLines: [NativeCoreMLOCRLine] = []
            let splitStarted = Self.nowMilliseconds()
            if recovers {
                // Comic lettering only: the page has a confidently read capital Latin row. A failed box that
                // overlaps an accepted line is a duplicate detection of it.
                let acceptedReads = recognition?.regions ?? []
                let accepted = Set(acceptedReads.map(\.sourceIndex))
                let acceptedBounds = acceptedReads.compactMap { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
                let lettering = acceptedReads.contains { NativeOCRAdjacentLineRecovery.latinAnchors($0.text) }
                let failed = !lettering ? [] : strongRegions.filter { region in
                    guard !accepted.contains(region.sourceIndex),
                          let bounds = NativeOCRScopeGeometry.bounds(for: region.polygon) else { return false }
                    return !acceptedBounds.contains {
                        NativeOCRScopeGeometry.intersectionArea($0, bounds) >= min($0.width * $0.height, bounds.width * bounds.height) * 0.3
                    }
                }
                let proposals: [NativeOCRStackedRowSplit.Proposal] = failed.isEmpty ? [] : frame.bytes.withUnsafeBufferPointer { bytes in
                    let bytesPerRow = frame.bytesPerRow
                    return NativeOCRStackedRowSplit.proposals(
                        width: frame.width, height: frame.height,
                        luminance: { x, y in
                            let offset = y * bytesPerRow + x * 4
                            return (Int(bytes[offset]) * 299 + Int(bytes[offset + 1]) * 587 + Int(bytes[offset + 2]) * 114) / 1000
                        },
                        boxes: failed.map { ($0.sourceIndex, $0.polygon) }
                    )
                }
                if !proposals.isEmpty {
                    try cancellationCheck()
                    let base = detection.boxes.count + 64
                    var crops: [NativeCoreMLRecognitionRegion] = []
                    for proposal in proposals {
                        for row in proposal.rows {
                            crops.append(NativeCoreMLRecognitionRegion(sourceIndex: base + crops.count, polygon: row, useProvidedOrder: true))
                        }
                    }
                    let reads = try await recognizer.recognize(
                        frame: frame, regions: crops, requestID: requestID,
                        confidenceThreshold: max(0, threshold - NativeOCRAdjacentLineRecovery.confidenceMargin),
                        cancellationCheck: cancellationCheck
                    )
                    try cancellationCheck()
                    let byIndex = Dictionary(reads.regions.map { ($0.sourceIndex, $0) }, uniquingKeysWith: { first, _ in first })
                    var offset = base
                    var replaced = Set<Int>()
                    for proposal in proposals {
                        let rowReads = proposal.rows.indices.map { byIndex[offset + $0] }
                        offset += proposal.rows.count
                        guard NativeOCRStackedRowSplit.accepts(rowReads, threshold: threshold),
                              !proposal.rows.contains(where: { row in
                                  splitLines.contains { NativeOCRScopeGeometry.intersectionArea(
                                      NativeOCRScopeGeometry.bounds(for: $0.polygon) ?? .null,
                                      NativeOCRScopeGeometry.bounds(for: row) ?? .null) > 0 }
                              }) else { continue }
                        replaced.insert(proposal.sourceIndex)
                        splitLines += zip(proposal.rows, rowReads.compactMap { $0 }).map { row, read in
                            NativeCoreMLOCRLine(polygon: row, text: read.text, score: read.confidence, orientation: .horizontal)
                        }
                    }
                    rejectedReads.removeAll { replaced.contains($0.sourceIndex) }
                }
            }

            let splitMilliseconds = Self.nowMilliseconds() - splitStarted

            // Adjacent-line recovery: rejected CJK reads (and weak boxes, read now) that sit next to an
            // accepted line as a sibling line of the same caption; short Latin rows of a horizontal
            // Latin lettering stack likewise.
            var recoveryCandidates: [NativeCoreMLOCRLine] = []
            let anchorReads = recognition?.regions.filter({
                !recoveredHorizontal.contains($0.sourceIndex) && (NativeOCRAdjacentLineRecovery.anchors($0.text)
                    || NativeOCRAdjacentLineRecovery.latinAnchors($0.text)
                        && NativeOCRAdjacentLineRecovery.isHorizontal($0.polygon))
            }) ?? []
            if recovers, !anchorReads.isEmpty {
                let anchors = anchorReads.map(\.polygon)
                let strongIndices = Set(strongRegions.map(\.sourceIndex))
                let weak = regions.filter { region in
                    !strongIndices.contains(region.sourceIndex)
                        && anchors.contains { NativeOCRAdjacentLineRecovery.isAdjacent(region.polygon, to: $0) }
                }
                var reads = rejectedReads.filter { !recoveredHorizontal.contains($0.sourceIndex) }
                if !weak.isEmpty {
                    try cancellationCheck()
                    let weakReads = try await recognizer.recognize(
                        frame: frame, regions: Array(weak.prefix(32)), requestID: requestID,
                        confidenceThreshold: max(0, threshold - NativeOCRAdjacentLineRecovery.confidenceMargin),
                        cancellationCheck: cancellationCheck
                    )
                    try cancellationCheck()
                    reads += weakReads.regions
                }
                recoveryCandidates = reads
                    .filter { read in
                        anchorReads.contains {
                            NativeOCRAdjacentLineRecovery.completes(read.text, polygon: read.polygon,
                                                                    anchor: $0.text, anchorPolygon: $0.polygon)
                        }
                    }
                    .sorted { $0.sourceIndex < $1.sourceIndex }
                    .map { read in
                        // A short Latin stack row (a lone "I") has no reliable box shape: it takes the
                        // horizontal baseline of the row it completes.
                        let latin = NativeOCRAdjacentLineRecovery.isLatinStackRow(read.text)
                        let quad = latin ? NativeOCRScopeGeometry.alternateHorizontalQuad(read.polygon) : nil
                        return NativeCoreMLOCRLine(
                            polygon: quad ?? NativeOCRScopeGeometry.canonicalQuad(read.polygon) ?? read.polygon,
                            text: read.text, score: read.confidence,
                            orientation: latin ? .horizontal : Self.orientation(for: read.polygon), orientationIsEstimated: !latin,
                            erasurePolygons: detection.boxes.indices.contains(read.sourceIndex)
                                ? detection.boxes[read.sourceIndex].erasurePolygons : []
                        )
                    }
            }

            // Isolated-line recovery: rejected reads of a whole utterance with no accepted line beside it.
            var isolatedLines: [NativeCoreMLOCRLine] = []
            if recovers, !rejectedReads.isEmpty {
                let reads = rejectedReads.filter { !recoveredHorizontal.contains($0.sourceIndex) }
                isolatedLines = NativeOCRIsolatedLineRecovery.candidates(
                    reads, threshold: threshold, accepted: recognition?.regions ?? [],
                    occupied: recoveryCandidates.map(\.polygon) + splitLines.map(\.polygon)
                ).map { read in
                    NativeCoreMLOCRLine(
                        polygon: NativeOCRScopeGeometry.canonicalQuad(read.polygon) ?? read.polygon, text: read.text,
                        score: read.confidence, orientation: Self.orientation(for: read.polygon), orientationIsEstimated: true,
                        erasurePolygons: detection.boxes.indices.contains(read.sourceIndex)
                            ? detection.boxes[read.sourceIndex].erasurePolygons : []
                    )
                }
            }

            // Gap-line recovery: an ink column of the flanks' style between two accepted lines with no box.
            var gapLines: [NativeCoreMLOCRGapLine] = []
            if recovers, let confident = recognition?.regions.filter({
                !recoveredHorizontal.contains($0.sourceIndex) && NativeOCRGapLineRecovery.flanks($0.text)
            }), confident.count >= 2 {
                // A rejected detector envelope may contain several successfully read
                // columns. It is not an occupied line and must not hide their missing
                // sibling from the gap scanner. Keep ordinary rejected boxes blocking.
                let acceptedIDs = Set((recognition?.regions ?? []).map(\.sourceIndex))
                let gapBlockers = strongRegions.filter { region in
                    guard !acceptedIDs.contains(region.sourceIndex),
                          let box = NativeOCRScopeGeometry.bounds(for: region.polygon) else { return true }
                    let enclosed = confident.filter { read in
                        guard let line = NativeOCRScopeGeometry.bounds(for: read.polygon) else { return false }
                        return NativeOCRScopeGeometry.intersectionArea(box, line) >= line.width * line.height * 0.9
                    }
                    return enclosed.count < 2
                }.map(\.polygon) + recoveryCandidates.map(\.polygon)
                let proposals = frame.bytes.withUnsafeBufferPointer { bytes in
                    let bytesPerRow = frame.bytesPerRow
                    let baseProposals = NativeOCRGapLineRecovery.proposals(
                        width: frame.width, height: frame.height,
                        luminance: { x, y in
                            let offset = y * bytesPerRow + x * 4
                            return (Int(bytes[offset]) * 299 + Int(bytes[offset + 1]) * 587 + Int(bytes[offset + 2]) * 114) / 1000
                        },
                        lines: confident.map { .init(polygon: $0.polygon, text: $0.text) },
                        blockers: gapBlockers
                    )
                    // No outer-column result can be admitted once the shared cap is full.
                    guard baseProposals.count < NativeOCRGapLineRecovery.maximumProposals else { return baseProposals }
                    let edges = NativeOCRGapLineRecovery.edgeProposals(
                        width: frame.width, height: frame.height,
                        luminance: { x, y in
                            let offset = y * bytesPerRow + x * 4
                            return (Int(bytes[offset]) * 299 + Int(bytes[offset + 1]) * 587 + Int(bytes[offset + 2]) * 114) / 1000
                        }, lines: (recognition?.regions ?? []).map { .init(polygon: $0.polygon, text: $0.text) },
                        blockers: gapBlockers + baseProposals.map(\.polygon))
                    return baseProposals + edges.prefix(max(0, NativeOCRGapLineRecovery.maximumProposals - baseProposals.count))
                }
                if !proposals.isEmpty {
                    try cancellationCheck()
                    let base = detection.boxes.count
                    let reads = try await recognizer.recognize(
                        frame: frame,
                        regions: proposals.enumerated().map {
                            NativeCoreMLRecognitionRegion(sourceIndex: base + $0.offset, polygon: $0.element.polygon)
                        },
                        requestID: requestID, confidenceThreshold: max(0, threshold - NativeOCRAdjacentLineRecovery.confidenceMargin),
                        cancellationCheck: cancellationCheck
                    )
                    try cancellationCheck()
                    gapLines = reads.regions.sorted { $0.sourceIndex < $1.sourceIndex }.compactMap { read in
                        let index = read.sourceIndex - base
                        guard proposals.indices.contains(index),
                              read.confidence >= (proposals[index].edge ? max(0.75, threshold) : threshold),
                              !proposals[index].edge || NativeOCRGapLineRecovery.isCaption(read.text),
                              NativeOCRGapLineRecovery.accepts(read.text, proposal: proposals[index]) else { return nil }
                        let polygon = proposals[index].polygon
                        return NativeCoreMLOCRGapLine(
                            line: NativeCoreMLOCRLine(
                                polygon: polygon, text: read.text, score: read.confidence,
                                orientation: proposals[index].vertical ? .vertical : .horizontal, orientationIsEstimated: true
                            ),
                            flanks: proposals[index].flanks, edge: proposals[index].edge
                        )
                    }
                }
            }

            // Unread halves of lettering units (see `NativeOCRLetteringUnitRecovery`): full frames only.
            let units = try await letteringUnits(
                frame: frame, requestID: requestID,
                enabled: recovers && recognitionScopes == nil,
                confident: (recognition?.regions ?? []).filter { !recoveredHorizontal.contains($0.sourceIndex) },
                occupied: ((recognition?.regions ?? []).map(\.polygon) + recoveryCandidates.map(\.polygon)
                    + gapLines.map(\.line.polygon) + isolatedLines.map(\.polygon) + splitLines.map(\.polygon))
                    .compactMap(NativeOCRScopeGeometry.bounds(for:)),
                threshold: threshold, cancellationCheck: cancellationCheck
            )

            let latinRows = (recognition?.regions ?? []).filter {
                NativeOCRAdjacentLineRecovery.latinAnchors($0.text) && NativeOCRAdjacentLineRecovery.isHorizontal($0.polygon)
            }.map(\.polygon)
            let lines = (recognition?.regions ?? [])
                .sorted { $0.sourceIndex < $1.sourceIndex }
                .map { region in
                    if let completed = units.lines[region.sourceIndex] {
                        return NativeCoreMLOCRLine(polygon: completed.polygon, text: completed.text, score: completed.score,
                            orientation: completed.orientation, orientationIsEstimated: completed.orientationIsEstimated,
                            sourceTileBounds: completed.sourceTileBounds,
                            erasurePolygons: completed.erasurePolygons + (detection.boxes.indices.contains(region.sourceIndex)
                                ? detection.boxes[region.sourceIndex].erasurePolygons : []))
                    }
                    // Latin word classification already uses horizontal layout.
                    // Its polygon must use the same baseline, even if the model
                    // recognized it in a quarter-turned primary crop (SALE).
                    let latinQuad = NativeOCRScopeGeometry.isLatinWord(region.text)
                        ? NativeOCRScopeGeometry.alternateHorizontalQuad(region.polygon) : nil
                    return NativeCoreMLOCRLine(
                        polygon: recoveredHorizontal.contains(region.sourceIndex) ? region.polygon : (latinQuad ?? NativeOCRScopeGeometry.canonicalQuad(region.polygon) ?? region.polygon),
                        text: region.text,
                        score: region.confidence,
                        orientation: recoveredHorizontal.contains(region.sourceIndex) || latinQuad != nil ? .horizontal : Self.orientation(
                            for: region.polygon
                        ),
                        orientationIsEstimated: true,
                        erasurePolygons: detection.boxes.indices.contains(region.sourceIndex)
                            ? detection.boxes[region.sourceIndex].erasurePolygons : []
                    )
                }
                .map { NativeOCRAdjacentLineRecovery.orientingSingleLatinLetter($0, rows: latinRows) }
            let recognitionMilliseconds =
                recognition?.diagnostics.totalMilliseconds ?? 0
            try cancellationCheck()
            return NativeCoreMLOCRResult(
                requestID: requestID,
                width: detection.width,
                height: detection.height,
                lines: lines,
                frameConversionMilliseconds: frameConversionMilliseconds,
                detectionMilliseconds:
                    detection.diagnostics.totalMilliseconds,
                recognitionMilliseconds: recognitionMilliseconds,
                totalMilliseconds: Self.nowMilliseconds() - started,
                detectedBoxes: detection.boxes.count,
                selectedBoxes: strongRegions.count,
                diagnostics: NativeCoreMLOCRPipelineDiagnostics(
                    backend: "coreml",
                    frameConversionMilliseconds:
                        frameConversionMilliseconds,
                    detectionProvider:
                        detection.diagnostics.executionProvider,
                    recognitionProvider:
                        recognition?.diagnostics.executionProvider
                            ?? "not-run",
                    detectionComputeUnits:
                        detection.diagnostics.computeUnits,
                    recognitionComputeUnits:
                        recognition?.diagnostics.computeUnits
                            ?? "not-run",
                    detectionModel: detection.diagnostics.modelName,
                    recognitionModel:
                        recognition?.diagnostics.modelName
                            ?? NativeCoreMLRecognizer.modelResourceName,
                    detection: detection.diagnostics,
                    recognition: recognition?.diagnostics
                ),
                recoveryCandidates: recoveryCandidates,
                gapLines: gapLines,
                isolatedLines: isolatedLines,
                splitLines: splitLines,
                stackedRowSplitMilliseconds: splitMilliseconds,
                unitMilliseconds: units.milliseconds,
                unitLineCount: units.lines.count
            )
        } onCancel: { [generation] in
            // A late handler from superseded request A must never invalidate
            // request B. The active detector/recognizer have their own
            // token-scoped handlers; explicit owner cancellation still uses
            // `cancelCurrent()` above to invalidate all stages immediately.
            generation.cancel(ifCurrent: issuedGeneration)
        }
    }

    private struct LetteringUnitOutcome {
        /// Completed lines by the source index of the accepted line they replace.
        var lines: [Int: NativeCoreMLOCRLine] = [:]
        var milliseconds = 0.0
    }

    private func letteringUnits(
        frame: NativeOCRRGBAFrame, requestID: String, enabled: Bool, confident: [NativeCoreMLRecognizedRegion],
        occupied: [CGRect], threshold: Double, cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> LetteringUnitOutcome {
        var outcome = LetteringUnitOutcome()
        guard enabled, !confident.isEmpty else { return outcome }
        let started = Self.nowMilliseconds()
        let anchors = confident.sorted { $0.sourceIndex < $1.sourceIndex }
        let neighbours = frame.bytes.withUnsafeBufferPointer { bytes in
            let bytesPerRow = frame.bytesPerRow
            return NativeOCRLetteringUnitRecovery.neighbours(
                width: frame.width, height: frame.height,
                pixel: { x, y in
                    let offset = y * bytesPerRow + x * 4
                    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
                },
                lines: anchors.map { .init(polygon: $0.polygon, text: $0.text) }, occupied: occupied
            )
        }
        guard !neighbours.isEmpty else {
            outcome.milliseconds = Self.nowMilliseconds() - started
            return outcome
        }
        try cancellationCheck()
        func quad(_ rect: CGRect) -> [CGPoint] {
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
        // One batch: each unit, the anchor read again together with its neighbour.
        let regions = neighbours.enumerated().map { index, neighbour in
            NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: quad(neighbour.unit))
        }
        let reads = try await recognizer.recognize(
            frame: frame, regions: regions, requestID: requestID, confidenceThreshold: threshold,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        let byIndex = Dictionary(reads.regions.map { ($0.sourceIndex, $0) }, uniquingKeysWith: { first, _ in first })

        for (index, neighbour) in neighbours.enumerated() {
            let anchor = anchors[neighbour.anchor]
            guard let read = byIndex[index], read.confidence >= max(threshold, NativeOCRLetteringUnitRecovery.unitConfidence),
                  NativeOCRLetteringUnitRecovery.completes(read.text, anchor: anchor.text, side: neighbour.side) else { continue }
            let text = read.text.filter { !$0.isWhitespace }
            let vertical = neighbour.vertical && (NativeOCRLetteringUnitRecovery.glyphCount(anchor.text) ?? 0) == 1
                || Self.orientation(for: anchor.polygon) == .vertical
            outcome.lines[anchor.sourceIndex] = NativeCoreMLOCRLine(
                polygon: quad(neighbour.unit), text: text, score: read.confidence,
                orientation: vertical ? .vertical : .horizontal, orientationIsEstimated: true
            )
        }
        outcome.milliseconds = Self.nowMilliseconds() - started
        return outcome
    }

    private static func orientation(
        for polygon: [CGPoint]
    ) -> BrowserOCRSourceOrientation {
        guard let bounds = bounds(for: polygon) else {
            return .unknown
        }
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return .unknown }
        return height >= width * 1.25 ? .vertical : .horizontal
    }

    private static func bounds(for polygon: [CGPoint]) -> CGRect? {
        NativeOCRScopeGeometry.bounds(for: polygon)
    }

    private static func nowMilliseconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }
}
