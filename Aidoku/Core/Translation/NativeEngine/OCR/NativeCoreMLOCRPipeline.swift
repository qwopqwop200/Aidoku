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

    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        recognitionScopes: [CGRect]?,
        probabilityObserver: NativeMainEnsembleOCRProbability.Observer?,
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

    // Existing mocks/fallbacks need not implement probability transport.
    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        recognitionScopes: [CGRect]?,
        probabilityObserver: NativeMainEnsembleOCRProbability.Observer?,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult {
        _ = probabilityObserver
        return try await detect(frame: frame, requestID: requestID, configuration: configuration,
            recognitionScopes: recognitionScopes, cancellationCheck: cancellationCheck)
    }

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
    var recoverySequenceWidthLimit: Int { get }
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
    var recoverySequenceWidthLimit: Int { 0 }
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
    let detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]?

    var acceptedSource: NativeOCRSourceMetadata = .init()

    /// A calibrated output still belongs to the line geometry on which the
    /// recognizer and the paragraph adjacency thresholds operated.
    var preCalibrationPolygon: [CGPoint]?
    var isLegacyComplement = false

    init(
        polygon: [CGPoint],
        text: String,
        score: Double,
        orientation: BrowserOCRSourceOrientation,
        orientationIsEstimated: Bool = false,
        sourceTileBounds: CGRect? = nil,
        erasurePolygons: [[CGPoint]] = [],
        detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]? = nil,
        acceptedSource: NativeOCRSourceMetadata = .init()
    ) {
        self.polygon = polygon
        self.text = text
        self.score = score
        self.orientation = orientation
        self.orientationIsEstimated = orientationIsEstimated
        self.sourceTileBounds = sourceTileBounds
        self.erasurePolygons = erasurePolygons
        self.detectorSeedEvidence = detectorSeedEvidence
        self.acceptedSource = acceptedSource
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
    /// Actual observed stage arrays for the live ensemble bridge; nil means unavailable.
    var ensembleStageSnapshot: NativeOCREnsembleStageSnapshot? = nil
    /// Individual localization output, before content filtering and paragraph
    /// grouping. Explicit alternatives keep immutable source provenance; their
    /// count is separate from selected text lines and merged paragraphs.
    var individualGeometry: [NativeOCRIndividualGeometryHypotheses.Individual] = []
    /// Admission is separate from model computation; records are checked after actual G.emit.
    var individualGeometryAdmission: NativeOCRLearnedBoundaryAdmission.Proof? = nil
    var individualGeometryRepresentatives: NativeOCRGeometryRepresentativeSelection.Report? = nil
    var individualGeometrySignalAdmission: NativeOCRGeometrySignalAdmission.Report? = nil
    var individualGeometryWitnessAdmission: NativeOCRGeometryWitnessAdmission.Report? = nil
    var individualGeometryPortfolioAdmission: NativeOCRGeometryPortfolioAdmission.Report? = nil
    var individualGeometryRFSemanticAdmission: NativeOCRRFSemanticAdmission.Report? = nil
    var individualGeometryPhysicalPaintAdmission: NativeOCRPhysicalPaintAdmission.Report? = nil
    var individualGeometryPhysicalBoundaryModesAdmission: NativeOCRPhysicalPaintAdmission.Report? = nil
    var individualGeometrySharedLineAdmission: NativeOCRPhysicalPaintAdmission.Report? = nil
    var rawCanonicalReceipt: NativeOCRRawCanonicalRuntime.Receipt? = nil
    var legacyComplementReceipt: NativeOCRRawCanonicalRuntime.Receipt? = nil
    var legacyComplementFailure: String? = nil
    var legacyComplementGeometry: [NativeOCRIndividualGeometryHypotheses.Individual] = []
}

@available(iOS 18.0, *)
enum NativeOCRScopeGeometry {
    /// Clockwise quad with its upper cross-edge first. Sorting into left/right
    /// halves turns a clockwise-leaning vertical crop upside down. Select an
    /// actual edge instead, independent of the detector's starting vertex.
    static func canonicalQuad(_ points: [CGPoint], vertical: Bool? = nil) -> [CGPoint]? {
        if NativeOCRDirectionGeometry.enabled("quad") {
            return NativeOCRDirectionGeometry.readingQuad(points, vertical: vertical)
        }
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
        if NativeOCRDirectionGeometry.enabled("latin") {
            guard var target = NativeOCRDirectionGeometry.directedQuad(points, longAlong: false),
                  let size = NativeOCRDirectionGeometry.edgeSize(target), size.width >= size.height * 1.1,
                  let original = canonicalQuad(points) else { return nil }
            let dx = target[1].x+target[2].x-target[0].x-target[3].x
            let dy = target[1].y+target[2].y-target[0].y-target[3].y
            // Detector vertex zero is untyped. Equivalent 180-degree cyclic
            // starts must not turn alternating words into opposite baselines.
            if dx < -0.000001 || (abs(dx) <= 0.000001 && dy < 0) {
                target = [target[2],target[3],target[0],target[1]]
            }
            return target == original ? nil : target
        }
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
        if admits(candidate) && shortPunctuatedSibling(candidate) && shortPunctuatedSibling(anchor) { return true }
        return admitsLatin(candidate) && latinAnchors(anchor) && isHorizontal(anchorPolygon)
    }

    /// A brief exclamation followed by another brief, punctuated column can be
    /// one utterance even when neither column reaches the four-character caption
    /// anchor gate. Require text on *both* sides of the spatial link; punctuation
    /// alone and isolated sound effects never establish an anchor.
    static func shortPunctuatedSibling(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let kanaOrHan = scalars.filter { 0x3040...0x30FF ~= $0.value || 0x3400...0x9FFF ~= $0.value }.count
        return (2...6).contains(kanaOrHan) && text.count <= 16 &&
            (text.contains("…") || text.contains("...")) &&
            !containsLatinLetter(text) && !isNotice(text) &&
            !scalars.contains(where: { CharacterSet.decimalDigits.contains($0) })
    }

    static func isLatinStackRow(_ text: String) -> Bool {
        admitsLatin(text) && !admits(text)
    }

    /// A confidently read single Latin letter ("I", "A") has a square or tall box, so its orientation is
    /// estimated vertical. Beside or between horizontal Latin rows it is the first word of a row or a row
    /// of its own: it keeps a fixed horizontal orientation so the merger can join it.
    static func orientingSingleLatinLetter(_ line: NativeCoreMLOCRLine, rows: [[CGPoint]]) -> NativeCoreMLOCRLine {
        let letters = line.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if NativeOCRDirectionGeometry.enabled("single") {
            guard letters.count == 1, isLatinStackRow(line.text),
                  let anchor = rows.first(where: { isAdjacent(line.polygon, to: $0) || isSameRow(line.polygon, as: $0) }),
                  let q = NativeOCRDirectionGeometry.cycle(anchor),
                  let own = NativeOCRDirectionGeometry.cycle(line.polygon),
                  let size = NativeOCRDirectionGeometry.edgeSize(q) else { return line }
            let dx = q[1].x-q[0].x, dy = q[1].y-q[0].y
            let start = (0..<4).max { a,b in
                func alignment(_ i: Int) -> CGFloat {
                    let x = own[(i+1)%4].x-own[i].x, y = own[(i+1)%4].y-own[i].y
                    return (x*dx+y*dy)/max(0.000001,hypot(x,y))
                }
                return alignment(a)<alignment(b)
            }!
            let polygon = (0..<4).map { own[(start+$0)%4] }
            return NativeCoreMLOCRLine(polygon: polygon, text: line.text, score: line.score,
                orientation: size.height >= size.width*1.25 ? .vertical : .horizontal,
                orientationIsEstimated: false, sourceTileBounds: line.sourceTileBounds, erasurePolygons: line.erasurePolygons,
                detectorSeedEvidence: line.detectorSeedEvidence, acceptedSource: line.acceptedSource)
        }
        guard letters.count == 1, isLatinStackRow(line.text), !rows.isEmpty,
              rows.contains(where: { isAdjacent(line.polygon, to: $0) || isSameRow(line.polygon, as: $0) })
        else { return line }
        return NativeCoreMLOCRLine(polygon: line.polygon, text: line.text, score: line.score, orientation: .horizontal,
                                   orientationIsEstimated: false, sourceTileBounds: line.sourceTileBounds, erasurePolygons: line.erasurePolygons,
                                   detectorSeedEvidence: line.detectorSeedEvidence, acceptedSource: line.acceptedSource)
    }

    /// `candidate` sits on the row of the horizontal `anchor`: shared height band, similar glyph size,
    /// at most one line thickness apart along the row.
    static func isSameRow(_ candidate: [CGPoint], as anchor: [CGPoint]) -> Bool {
        if NativeOCRDirectionGeometry.enabled("single") {
            guard let basis = NativeOCRDirectionGeometry.Frame(anchor, longAlong: false) else { return false }
            let a = basis.bounds(anchor), c = basis.bounds(candidate)
            guard a.height > 0, c.height > 0, max(a.height,c.height) <= min(a.height,c.height)*1.6 else { return false }
            let shared = min(a.maxY,c.maxY)-max(a.minY,c.minY)
            let gap = max(a.minX,c.minX)-min(a.maxX,c.maxX)
            return shared >= min(a.height,c.height)*0.6 && gap <= a.height
        }
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
            result[target].acceptedSource = region.acceptedSource
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
        case .manga:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Manga-DetShapes",
                recognizerResourceName: "PP-OCRv6-Manga-RecWidths",
                dictionaryResourceName: "ppocrv6_manga_rec_character_dict",
                expectedDictionaryCharacterCount: 19_054,
                postprocessConfiguration: .manga
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
    private let premergeCandidateModel: NativeOCRPremergeCandidateModel?
    private let premergeCandidateSelection: NativeOCRPremergeCandidateSelection?
    private let premergeAutoPolicy: NativeOCRPremergeAutoPolicy?
    private let premergeCombinationPolicy: NativeOCRPremergeCombinationPolicy?
    private let rawCanonicalModels: NativeOCRRawGeometryModelBundle.Provider?
    private let postprocessConfiguration:
        NativeCoreMLDBPostprocessConfiguration
    private let generation = NativeCoreMLOCRGeneration()

    init(
        detector: any NativeCoreMLDetecting = NativeCoreMLDetector(),
        recognizer: any NativeCoreMLRecognizing = NativeCoreMLRecognizer(),
        postprocessConfiguration:
            NativeCoreMLDBPostprocessConfiguration = .manga,
        premergeCandidateModel: NativeOCRPremergeCandidateModel? = nil,
        premergeCandidateSelection: NativeOCRPremergeCandidateSelection? = nil,
        premergeAutoPolicy: NativeOCRPremergeAutoPolicy? = nil,
        policyBundle: Bundle = .main,
        rawCanonicalModels: Result<NativeOCRRawGeometryModelBundle.Loaded, Error>? = nil,
        rawCanonicalModelProvider: NativeOCRRawGeometryModelBundle.Provider? = nil,
        frameConverter: @escaping FrameConverter = { image in
            await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image)
        }
    ) {
        self.detector = detector
        self.recognizer = recognizer
        self.postprocessConfiguration = postprocessConfiguration
        self.frameConverter = frameConverter
        self.rawCanonicalModels = rawCanonicalModelProvider ?? rawCanonicalModels.map {
            NativeOCRRawGeometryModelBundle.Provider(supplied: $0)
        }
        let bundled = NativeOCRPremergePolicyBundle.load(bundle: policyBundle)
        #if os(macOS)
        // Explicit host overrides remain available for reproducible research;
        // the app and ordinary host execution use the same admitted bundle.
        let modelPath = ProcessInfo.processInfo.environment["AIDOKU_OCR_PREMERGE_MODEL"]
        self.premergeCandidateModel = premergeCandidateModel ?? modelPath.map {
            NativeOCRPremergeCandidateModel(contentsOf: URL(fileURLWithPath: $0))
        } ?? bundled?.content
        self.premergeCandidateSelection = premergeCandidateSelection ?? modelPath.map {
            let directory = URL(fileURLWithPath: $0).deletingLastPathComponent()
            return NativeOCRPremergeCandidateSelection(
                qualityURL: directory.appendingPathComponent("quality-model.json"),
                policyURL: directory.appendingPathComponent("duplicate-policy-minimal-pixel.json"))
        } ?? bundled?.selection
        self.premergeAutoPolicy = premergeAutoPolicy ?? modelPath.map {
            NativeOCRPremergeAutoPolicy(contentsOf: URL(fileURLWithPath: $0).deletingLastPathComponent()
                .appendingPathComponent("auto-policy.json"))
        } ?? bundled?.automatic
        self.premergeCombinationPolicy = modelPath.map {
            NativeOCRPremergeCombinationPolicy(contentsOf: URL(fileURLWithPath: $0).deletingLastPathComponent()
                .appendingPathComponent("combination-policy.json"))
        }
        #else
        self.premergeCandidateModel = premergeCandidateModel ?? bundled?.content
        self.premergeCandidateSelection = premergeCandidateSelection ?? bundled?.selection
        self.premergeAutoPolicy = premergeAutoPolicy ?? bundled?.automatic
        self.premergeCombinationPolicy = nil
        #endif
    }

    // Reader settings and CLI options enforce the reader resolution limits.
    // Explicit dimensions remain available for model and historical replay tests.
    convenience init(
        modelTier: IPhoneOCRModelTier,
        detectorMaximumSide: Int? = nil,
        recognizerMaximumWidth: Int? = nil,
        existingDetector: NativeCoreMLDetector? = nil,
        premergeCandidateModel: NativeOCRPremergeCandidateModel? = nil,
        premergeCandidateSelection: NativeOCRPremergeCandidateSelection? = nil,
        premergeAutoPolicy: NativeOCRPremergeAutoPolicy? = nil,
        bundle: Bundle = .main
    ) {
        let profile = NativeCoreMLOCRModelProfile.profile(for: modelTier)
        self.init(
            detector: existingDetector ?? NativeCoreMLDetector(
                bundle: bundle,
                modelResourceName: profile.detectorResourceName,
                maximumSide: detectorMaximumSide ?? IPhoneOCRSettings.defaultDetectorMaximumSide(for: modelTier)
            ),
            recognizer: NativeCoreMLRecognizer(
                bundle: bundle,
                modelResourceName: profile.recognizerResourceName,
                dictionaryResourceName: profile.dictionaryResourceName,
                expectedDictionaryCharacterCount:
                    profile.expectedDictionaryCharacterCount,
                maximumRecognitionWidth: recognizerMaximumWidth ?? IPhoneOCRSettings.maximumRecognizerWidth(for: modelTier)
            ),
            postprocessConfiguration: profile.postprocessConfiguration,
            premergeCandidateModel: premergeCandidateModel,
            premergeCandidateSelection: premergeCandidateSelection,
            premergeAutoPolicy: premergeAutoPolicy,
            policyBundle: bundle,
            rawCanonicalModelProvider: modelTier == .manga ? NativeOCRRawGeometryModelBundle.Provider(bundle: bundle) : nil
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

    /// The same frame converter and resident detector produce both the lookup identity
    /// and the optional miss prediction. Neither is retained by the pipeline.
    func prepareSourceProbabilityRequest(image:CGImage,
        configuration:NativeCoreMLDBPostprocessConfiguration) async throws -> NativeCoreMLDetector.ProbabilityRequest {
        guard let concrete=detector as? NativeCoreMLDetector else {
            throw NativeMainEnsemblePreparedDB.Failure.observerUnavailable
        }
        guard let frame=await frameConverter(image) else {throw NativeCoreMLDetectorError.imageConversionFailed}
        try Task.checkCancellation()
        let request = try await concrete.prepareProbabilityRequest(frame: frame, configuration: configuration)
        return .init(expectation: request.expectation) { [self] observer, cancellationCheck in
            let issued = generation.begin()
            let check: @Sendable () throws -> Void = { [generation] in
                try cancellationCheck()
                try generation.requireCurrent(issued)
            }
            try await withTaskCancellationHandler {
                try check()
                try await request.observe(observer, check)
                try check()
            } onCancel: { [weak self] in self?.cancelCurrent() }
        }
    }

    func recognize(
        image: CGImage,
        requestID: String,
        confidenceThreshold: Double,
        detectorConfiguration: NativeCoreMLDBPostprocessConfiguration? = nil,
        recognitionScope: CGRect? = nil,
        probabilityObserver: NativeMainEnsembleOCRProbability.Observer? = nil,
        rfLayout: NativeRFDETRLayoutResult? = nil
    ) async throws -> NativeCoreMLOCRResult {
        try await recognize(
            image: image,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            detectorConfiguration: detectorConfiguration,
            recognitionScopes: recognitionScope.map { [$0] },
            probabilityObserver: probabilityObserver,
            rfLayout: rfLayout
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
        recognitionScopes: [CGRect]?,
        probabilityObserver: NativeMainEnsembleOCRProbability.Observer? = nil,
        rfLayout: NativeRFDETRLayoutResult? = nil
    ) async throws -> NativeCoreMLOCRResult {
        try await performRecognition(
            providedFrame: nil,
            image: image,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            detectorConfiguration: detectorConfiguration,
            recognitionScopes: recognitionScopes,
            probabilityObserver: probabilityObserver,
            rfLayout: rfLayout
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
        probabilityObserver: NativeMainEnsembleOCRProbability.Observer? = nil,
        stageHandler: (@Sendable (NativeCoreMLOCRStage) -> Void)? = nil,
        rfLayout: NativeRFDETRLayoutResult? = nil
    ) async throws -> NativeCoreMLOCRResult {
        let mainMangaPolicy=postprocessConfiguration == .manga && recognitionScopes == nil
        return try await NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(mainMangaPolicy) {
            try await NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(mainMangaPolicy) {
                try await performRecognitionWithEndpointPolicy(providedFrame: providedFrame,
                    image: image, requestID: requestID, confidenceThreshold: confidenceThreshold,
                    detectorConfiguration: detectorConfiguration, recognitionScopes: recognitionScopes,
                    probabilityObserver: probabilityObserver, stageHandler: stageHandler, rfLayout: rfLayout)
            }
        }
    }

    private func performRecognitionWithEndpointPolicy(
        providedFrame: NativeOCRRGBAFrame?,
        image: CGImage?,
        requestID: String,
        confidenceThreshold: Double,
        detectorConfiguration: NativeCoreMLDBPostprocessConfiguration?,
        recognitionScopes: [CGRect]?,
        probabilityObserver: NativeMainEnsembleOCRProbability.Observer? = nil,
        stageHandler: (@Sendable (NativeCoreMLOCRStage) -> Void)? = nil,
        rfLayout: NativeRFDETRLayoutResult? = nil
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
            // Admit the actual source-bound RF contract BEFORE any DET/REC
            // submission. A valid-looking identity string or same-sized foreign
            // grid is not evidence for this source's learned source165 ABI.
            var preparedRawCanonicalFrame: NativeOCRRGBAFrame?
            if recognitionScopes == nil, rawCanonicalModels != nil, let layout = rfLayout {
                guard layout.sourceWidth == frame.width, layout.sourceHeight == frame.height,
                      let grid = layout.semanticGrid, grid.isValid, grid.hasValidWeightedMeanProbabilities,
                      grid.width == frame.width, grid.height == frame.height,
                      grid.modelWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                      grid.imageIdentity == layout.imageIdentity, let support = layout.sourceSupportGrid,
                      NativeOCRSourceSupportFeatures155.PreparedRF(width: frame.width, height: frame.height,
                        native17Fields: support.native17Fields) != nil, let image else {
                    throw NativeOCRRawCanonicalRuntime.Failure.missingEvidence
                }
                // SAME canonical RF decoder and hash domain, never a new hash
                // of encoded bytes or the detector's DeviceRGB input tensor.
                let source = try NativeRFOCRSourceReuse.active?.source(for: image, consume: true)
                    ?? NativeRFOCRPackedSource(image)
                guard source.width == frame.width, source.height == frame.height,
                      source.identity == layout.imageIdentity else {
                    throw NativeOCRRawCanonicalRuntime.Failure.missingEvidence
                }
                try cancellationCheck()
                // End RF ownership before constructing the frame so the packed array can expand in place.
                let rgba = try (consume source).rgbaBytes()
                guard let canonical = NativeOCRRGBAFrame(width: frame.width, height: frame.height, bytes: rgba) else {
                    throw NativeCoreMLDetectorError.imageConversionFailed
                }
                preparedRawCanonicalFrame = canonical
            }
            try cancellationCheck()
            stageHandler?(.detecting)
            let primaryMap = NativeOCRRFPrimaryEnsemble.MapCapture()
            let mapObserver: NativeMainEnsembleOCRProbability.Observer? =
                recognitionScopes == nil && (rfLayout != nil || NativeOCRBBoxConfidenceAdmission.enabled)
                    ? primaryMap.observer(forwarding: probabilityObserver) : probabilityObserver
            var detection = try await detector.detect(
                frame: frame,
                requestID: requestID,
                configuration: detectorConfiguration ?? postprocessConfiguration,
                // The detector model still receives the complete frame. Its
                // CPU output materialization and recognition admission may be
                // limited to dirty scopes for a partial refresh.
                recognitionScopes: standardizedScopes,
                probabilityObserver: mapObserver,
                cancellationCheck: cancellationCheck
            )
            try cancellationCheck()
            guard detection.requestID == requestID else {
                throw CancellationError()
            }
            let primaryProbability = primaryMap.take()
            let sourceDetectionBoxes = detection.boxes
            if recognitionScopes == nil, let rawCanonicalModels, let layout = rfLayout {
                guard let probability = primaryProbability else { throw NativeOCRRawCanonicalRuntime.Failure.missingEvidence }
                guard let canonicalFrame = preparedRawCanonicalFrame else {
                    throw NativeOCRRawCanonicalRuntime.Failure.missingEvidence
                }
                // Capture once: required resources and runtime dispatch use the
                // same request mode even when this pipeline handles other modes.
                let sourceAnchorMode = NativeOCRRawCanonicalRuntime.sourceAnchorMode
                let required: NativeOCRRawGeometryModelBundle.RequiredHeads
                switch sourceAnchorMode {
                case .disabled: required = .full
                case .fixedPreRecognition: required = .preRecognitionOnly
                case .noPreRecognition, .noPreRecognitionTerminalRecovery: required = .none
                }
                let models = try rawCanonicalModels.acquire(required, cancellationCheck: cancellationCheck)
                let raw = try await NativeOCRRawCanonicalRuntime.recognize(frame:canonicalFrame,requestID:requestID,
                    originals:sourceDetectionBoxes,probability:probability,layout:layout,models:models,
                    sourceAnchorMode:sourceAnchorMode,
                    recognizer:recognizer,recognitionThreshold:confidenceThreshold,
                    cancellationCheck:cancellationCheck,stageHandler:stageHandler)
                try cancellationCheck()
                var outputLines = raw.lines
                var recognitionDiagnostics = raw.recognition.diagnostics
                var selectedBoxes = raw.receipt.preRecognitionAdmitted
                var complement: NativeOCRRawCanonicalRuntime.Output?
                var complementFailure: String?
                if NativeOCRRawCanonicalRuntime.usesLegacyComplement {
                    do {
                        let legacyModels = try rawCanonicalModels.acquire(.full, cancellationCheck: cancellationCheck)
                        let legacy = try await NativeOCRRawCanonicalRuntime.$simpleDeduplication.withValue(nil) {
                            try await NativeOCRRawCanonicalRuntime.recognize(frame: canonicalFrame, requestID: requestID,
                                originals: sourceDetectionBoxes, probability: probability, layout: layout, models: legacyModels,
                                sourceAnchorMode: .disabled, recognizer: recognizer, recognitionThreshold: confidenceThreshold,
                                cancellationCheck: cancellationCheck, stageHandler: stageHandler)
                        }
                        try cancellationCheck()
                        outputLines = try NativeOCRRawCanonicalRuntime.joinedLines(current: raw.lines, legacy: legacy.lines,
                                                                                   width: frame.width, height: frame.height)
                        recognitionDiagnostics = recognitionDiagnostics.addingRecovery(legacy.recognition.diagnostics,
                            acceptedCount: recognitionDiagnostics.acceptedRegions + legacy.recognition.diagnostics.acceptedRegions,
                            includingRecoveryRequests: true)
                        selectedBoxes += legacy.receipt.preRecognitionAdmitted
                        complement = legacy
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try cancellationCheck()
                        complementFailure = String(describing: error)
                    }
                }
                return .init(requestID:requestID,width:frame.width,height:frame.height,lines:outputLines,
                    frameConversionMilliseconds:frameConversionMilliseconds,
                    detectionMilliseconds:detection.diagnostics.totalMilliseconds,
                    recognitionMilliseconds:recognitionDiagnostics.totalMilliseconds,
                    totalMilliseconds:Self.nowMilliseconds()-started,detectedBoxes:sourceDetectionBoxes.count,
                    selectedBoxes:selectedBoxes,
                    diagnostics:.init(backend:"coreml",frameConversionMilliseconds:frameConversionMilliseconds,
                        detectionProvider:detection.diagnostics.executionProvider,
                        recognitionProvider:raw.recognition.diagnostics.executionProvider,
                        detectionComputeUnits:detection.diagnostics.computeUnits,
                        recognitionComputeUnits:raw.recognition.diagnostics.computeUnits,
                        detectionModel:detection.diagnostics.modelName,recognitionModel:raw.recognition.diagnostics.modelName,
                        detection:detection.diagnostics,recognition:recognitionDiagnostics),
                    individualGeometry:raw.geometry,rawCanonicalReceipt:raw.receipt,
                    legacyComplementReceipt:complement?.receipt,legacyComplementFailure:complementFailure,
                    legacyComplementGeometry:complement?.geometry ?? [])
            }
            // Later RF/lane refinement may enlarge geometry. Keep the actual
            // detector ingress separate from those proposals so a subsequent
            // source-preserving trim does not certify its own earlier growth.
            let detectorSourcePolygons=Dictionary(uniqueKeysWithValues:detection.boxes.enumerated().map {
                ($0.offset,$0.element.polygon)
            })
            var independentLaneResult: NativeOCRIndependentLanes.Result?
            if postprocessConfiguration == .manga, recognitionScopes == nil {
                let lanes = try NativeOCRIndependentLanes.refine(
                    boxes: detection.boxes, layout: rfLayout, probability: primaryProbability,
                    width: frame.width, height: frame.height, cancellationCheck: cancellationCheck
                )
                independentLaneResult = lanes
            }
            if let lanes = independentLaneResult, lanes.boxes != detection.boxes {
                detection = .init(requestID: detection.requestID, width: detection.width,
                    height: detection.height, boxes: lanes.boxes, diagnostics: detection.diagnostics)
            }
            // Existing RF affiliations, recognition and paragraph/line grouping
            // remain unchanged; only their input detection candidates are refined.
            var rfPrimary = recognitionScopes == nil ? NativeOCRRFPrimaryEnsemble.plan(
                boxes: detection.boxes, layout: rfLayout, width: frame.width, height: frame.height,
                probability: primaryProbability, pixelThreshold: (detectorConfiguration ?? postprocessConfiguration).threshold
            ) : NativeOCRRFPrimaryEnsemble.Plan(boxes: detection.boxes, supported: [],
                stronglySupported: [], groups: [], refinedCrops: [])
            if postprocessConfiguration == .manga,recognitionScopes == nil {
                let sourceGroupExisting=rfPrimary.boxes.map(\.polygon)
                rfPrimary=NativeOCRRFPrimaryEnsemble.includingSourceAlignedColumns(rfPrimary,layout:rfLayout,frame:frame,
                    independentColumns:{
                        (try? NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:sourceDetectionBoxes,
                            existing:sourceGroupExisting,layout:rfLayout,frame:frame,
                            probability:primaryProbability))?.map(\.polygon) ?? []
                    })
            }
            if rfPrimary.boxes != detection.boxes {
                detection = .init(requestID: detection.requestID, width: detection.width,
                    height: detection.height, boxes: rfPrimary.boxes, diagnostics: detection.diagnostics)
            }

            let endpointFontPeers=NativeOCRRFPrimaryEnsemble.refinesEndpointInk ?
                NativeOCRRFPrimaryEnsemble.endpointFontPeerPolygons(detection.boxes) : [:]
            var endpointInkStyles: [NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]? = NativeOCRRFPrimaryEnsemble.refinesEndpointInk ? detection.boxes.map {
                NativeOCRRFPrimaryEnsemble.endpointInkStyle(box:$0,frame:frame,candidatePeerPolygons:endpointFontPeers)
            } : nil
            var endpointBases: [Int: [CGPoint]] = [:]
            var endpointMeasuredTrims=Set<Int>()
            var endpointPixelProofs: [Int: [CGPoint]] = [:]
            var endpointPixelInkProofs: [Int: [CGPoint]] = [:]
            var endpointTerminalProofs: [Int: [CGPoint]] = [:]
            var endpointPointTerminalProofs:[Int:[CGPoint]]=[:]
            var endpointContinuationPeers: [Int: Set<Int>] = [:]
            let proposedRegions = detection.boxes.enumerated().compactMap {
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
                guard let endpoint = NativeOCRRFPrimaryEnsemble.recognitionCrop(index: index,
                    boxes: detection.boxes, layout: rfLayout, frame: frame,
                    probability: primaryProbability,
                    pixelThreshold: (detectorConfiguration ?? postprocessConfiguration).threshold,
                    mode: NativeOCRRFPrimaryEnsemble.endpointCompletionMode,
                    inkStyles:endpointInkStyles,groups:rfPrimary.groups) else { return nil }
                if let base = endpoint.baseline { endpointBases[index] = base }
                if endpoint.measuredTrim { endpointMeasuredTrims.insert(index) }
                if let proof = endpoint.pixelProof { endpointPixelProofs[index] = proof }
                if let proof = endpoint.pixelInkProof { endpointPixelInkProofs[index] = proof }
                if let proof = endpoint.terminalProof { endpointTerminalProofs[index] = proof }
                if let proof=endpoint.pointTerminalProof { endpointPointTerminalProofs[index]=proof }
                if !endpoint.continuationPeers.isEmpty { endpointContinuationPeers[index] = endpoint.continuationPeers }
                let endpointPolygon = endpoint.polygon
                let geometryChanged = endpointPolygon != box.polygon
                return NativeCoreMLRecognitionRegion(
                    sourceIndex: index,
                    polygon: endpointPolygon,
                    samplingPolygon: !geometryChanged ? (NativeOCRRFPrimaryEnsemble.completeSupportSampling(
                        box: box, boxes: detection.boxes, layout: rfLayout, frame: frame) ?? box.recognitionPolygon) : nil,
                    isThinFinePrintRecovery: box.isThinFinePrintRecovery,
                    finePrintRetryPolygons: box.finePrintRetryPolygons,
                    recognitionColumnEvidence: box.recognitionColumnEvidence
                )
            }

            let reconciledPolygons = NativeOCRRFPrimaryEnsemble.reconcilingEndpointGrowth(
                proposedRegions.map(\.polygon), bases: proposedRegions.map {
                    endpointBases[$0.sourceIndex] ?? detection.boxes[$0.sourceIndex].polygon
                }, pixelProofs: proposedRegions.map { endpointPixelProofs[$0.sourceIndex] },
                inkStyles: proposedRegions.map { region in endpointInkStyles?[region.sourceIndex] ?? nil },
                pixelInkProofs: proposedRegions.map { endpointPixelInkProofs[$0.sourceIndex] },
                pointTerminalProofs:proposedRegions.map { endpointPointTerminalProofs[$0.sourceIndex] })
            var regions = zip(proposedRegions,reconciledPolygons).map { region, polygon in
                NativeCoreMLRecognitionRegion(sourceIndex: region.sourceIndex, polygon: polygon,
                    samplingPolygon: polygon == region.polygon ? region.samplingPolygon : nil,
                    isThinFinePrintRecovery: region.isThinFinePrintRecovery,
                    finePrintRetryPolygons: region.finePrintRetryPolygons,
                    recognitionColumnEvidence: region.recognitionColumnEvidence)
            }

            let sourceGroupPolygons=try NativeOCRRFPrimaryEnsemble.reconcilingSourceGroupAxes(
                regions.map(\.polygon),indices:regions.map(\.sourceIndex),groups:rfPrimary.groups,
                boxes:sourceDetectionBoxes,layout:rfLayout,frame:frame,probability:primaryProbability,
                cancellationCheck:cancellationCheck)
            regions=zip(regions,sourceGroupPolygons).map { region,polygon in
                NativeCoreMLRecognitionRegion(sourceIndex:region.sourceIndex,polygon:polygon,
                    samplingPolygon:polygon==region.polygon ? region.samplingPolygon:nil,
                    isThinFinePrintRecovery:region.isThinFinePrintRecovery,
                    finePrintRetryPolygons:region.finePrintRetryPolygons,
                    recognitionColumnEvidence:region.recognitionColumnEvidence)
            }

            if postprocessConfiguration == .manga, recognitionScopes == nil {
                let columns = try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes: sourceDetectionBoxes,
                    existing: regions.map(\.polygon), layout: rfLayout, frame: frame,
                    probability: primaryProbability, cancellationCheck: cancellationCheck)
                let first = detection.boxes.count
                if !columns.isEmpty {
                    detection = .init(requestID: detection.requestID, width: detection.width,
                        height: detection.height, boxes: detection.boxes + columns, diagnostics: detection.diagnostics)
                    endpointInkStyles?.append(contentsOf: columns.map { _ in nil })
                    regions.append(contentsOf: columns.enumerated().map { i, box in
                        NativeCoreMLRecognitionRegion(sourceIndex: first + i, polygon: box.polygon, useProvidedOrder: true)
                    })
                }
            }

            let rejectsPrimaryInput: (NativeCoreMLRecognitionRegion)->Bool = { region in
                if NativeOCRRFPrimaryEnsemble.primaryRoleRejection(region.polygon,layout:rfLayout,
                    width:frame.width,height:frame.height) != nil {return true}
                let evidence=detection.boxes.indices.contains(region.sourceIndex) ?
                    detection.boxes[region.sourceIndex].detectorSeedEvidence:nil
                let inkProof=endpointPixelInkProofs[region.sourceIndex] != nil ||
                    endpointTerminalProofs[region.sourceIndex] != nil || endpointPointTerminalProofs[region.sourceIndex] != nil
                return NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(region.polygon,evidence:evidence,
                    layout:rfLayout,width:frame.width,height:frame.height,hasSourceInkProof:inkProof) != nil
            }
            if NativeOCRRFPrimaryEnsemble.mainMangaEndpointPolicy {
                regions.removeAll(where:rejectsPrimaryInput)
            }

            var residualRetention = NativeOCRResidualRetention.State()
            var sourceCalibrationObservations: [(index: Int, polygon: [CGPoint])] = []
            var residualCoverageEvidence: [Int: [NativeOCRDetectorSeedEvidence]] = [:]
            var residualParentPolygons: [Int: [CGPoint]] = [:]
            func preservesResidualFootprint(_ index: Int, _ polygon: [CGPoint]) -> Bool {
                guard let selected = residualParentPolygons[index] else { return true }
                // A same-footprint sampling retry is allowed; a legacy geometric
                // fallback cannot undo the selected net ownership transaction.
                return selected.allSatisfy { NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 0.75) } &&
                    polygon.allSatisfy { NativeOCRSourceComponentMeasurements.contains(selected, $0, tolerance: 0.75) }
            }
            if NativeOCRRFPrimaryEnsemble.mainMangaEndpointPolicy {
                let calibrationInputs=regions.map { region in
                    NativeOCRCommonBoundaryCalibration.Input(index:region.sourceIndex,polygon:region.polygon,
                        baseline:endpointBases[region.sourceIndex],terminal:endpointTerminalProofs[region.sourceIndex],
                        pointTerminal:endpointPointTerminalProofs[region.sourceIndex],
                        hasInk:endpointPixelInkProofs[region.sourceIndex] != nil || endpointTerminalProofs[region.sourceIndex] != nil ||
                            endpointPointTerminalProofs[region.sourceIndex] != nil,
                        independent:region.sourceIndex>=rfPrimary.boxes.count)
                }
                let calibrated=NativeOCRCommonBoundaryCalibration.calibrate(calibrationInputs,originals:sourceDetectionBoxes,
                    prepared:rfPrimary.boxes,groups:Dictionary(uniqueKeysWithValues:rfPrimary.groups.map {($0.index,$0.members)}))
                let componentScopes=(rfLayout?.primitives ?? []).compactMap { p -> NativeOCRSourceComponentMeasurements.Scope? in
                    guard p.semanticClass == .text,p.confidence>=0.5 else {return nil}
                    return .init(rect:p.sourceBounds,confidence:Double(p.confidence))
                }
                let componentAdjusted=NativeOCRSourceComponentBounds.refine(calibrated,indices:regions.map(\.sourceIndex),
                    hasInk:calibrationInputs.map(\.hasInk),baselines:calibrationInputs.map(\.baseline),
                    terminalProofs:calibrationInputs.map(\.terminal),pointProofs:calibrationInputs.map(\.pointTerminal),
                    originals:sourceDetectionBoxes,prepared:rfPrimary.boxes,
                    groups:Dictionary(uniqueKeysWithValues:rfPrimary.groups.map {($0.index,$0.members)}),
                    scopes:componentScopes,frameProvider:{frame},
                    accepts:{index,polygon in !rejectsPrimaryInput(.init(sourceIndex:index,polygon:polygon))})
                var sourceCalibrationAudit = NativeOCRSourceLocalJoint369Capture.ExportConfiguration()
                if ProcessInfo.processInfo.environment["AIDOKU_OCR_SOURCE_UTILITY435_ALL8"] == "1" {
                    sourceCalibrationAudit.enabled = true
                    sourceCalibrationAudit.families = ["source-utility435-all8-select"]
                }
                let residualAdjusted=NativeOCRResidualCandidateBank.evaluate(componentAdjusted,indices:regions.map(\.sourceIndex),
                    hasInk:calibrationInputs.map(\.hasInk),baselines:calibrationInputs.map(\.baseline),
                    terminalProofs:calibrationInputs.map(\.terminal),pointProofs:calibrationInputs.map(\.pointTerminal),
                    originals:sourceDetectionBoxes,prepared:rfPrimary.boxes,
                    groups:Dictionary(uniqueKeysWithValues:rfPrimary.groups.map {($0.index,$0.members)}),
                    layout:rfLayout,scopes:componentScopes,frameProvider:{frame},
                    liveCandidateAudit369: sourceCalibrationAudit,
                    accepts:{index,polygon in !rejectsPrimaryInput(.init(sourceIndex:index,polygon:polygon))})
                if sourceCalibrationAudit.enabled,
                   residualAdjusted.polygons.count == regions.count,
                   componentAdjusted.count == regions.count {
                    sourceCalibrationObservations = regions.indices.compactMap { offset in
                        let region = regions[offset], polygon = residualAdjusted.polygons[offset]
                        guard !residualAdjusted.consumed.contains(region.sourceIndex),
                              polygon != componentAdjusted[offset] else { return nil }
                        return (region.sourceIndex, polygon)
                    }
                }
                let residualGroups = Dictionary(uniqueKeysWithValues: rfPrimary.groups.map { ($0.index, $0.members) })
                residualRetention = .init(consumed: residualAdjusted.consumed, associations: residualAdjusted.associations,
                                          groups: residualGroups)
                if !residualRetention.coverage.isEmpty {
                    for (region, polygon) in zip(regions, residualAdjusted.polygons) where
                        residualRetention.coverage[region.sourceIndex] != nil {
                        residualParentPolygons[region.sourceIndex] = polygon
                    }
                    let evidenceContext = NativeOCRSourceComponentMeasurements.Context(originals: sourceDetectionBoxes,
                        prepared: rfPrimary.boxes, groups: residualGroups, scopes: componentScopes, frameProvider: { frame })
                    let ingress = Dictionary(uniqueKeysWithValues: regions.map { ($0.sourceIndex, $0.polygon) })
                    for (parent, coverage) in residualRetention.coverage {
                        var evidence: [NativeOCRDetectorSeedEvidence] = []
                        for index in coverage.sorted() {
                            let represented = rfPrimary.groups.first(where: { $0.index == index })?.evidence ??
                                (sourceDetectionBoxes.indices.contains(index)
                                    ? sourceDetectionBoxes[index].detectorSeedEvidence.map { [$0] } : nil)
                            var observed = represented ?? []
                            if observed.isEmpty, let polygon = ingress[index],
                               let metadata = evidenceContext.metadata(index: index, polygon: polygon) {
                                observed = evidenceContext.associatedEvidence(metadata)
                                if observed.isEmpty, index >= rfPrimary.boxes.count {
                                    observed = NativeOCRResidualIndependentColumns.sourceEvidence(index: index, polygon: polygon,
                                        originals: sourceDetectionBoxes, prepared: rfPrimary.boxes, groups: residualGroups)
                                }
                            }
                            for owner in observed where !evidence.contains(where: { $0.ownerID == owner.ownerID }) {
                                evidence.append(owner)
                            }
                        }
                        if !evidence.isEmpty { residualCoverageEvidence[parent] = evidence }
                    }
                }
                regions=zip(regions,residualAdjusted.polygons).filter { !residualRetention.suppressed.contains($0.0.sourceIndex) }.map { region,polygon in
                    NativeCoreMLRecognitionRegion(sourceIndex:region.sourceIndex,polygon:polygon,
                        samplingPolygon:polygon==region.polygon ? region.samplingPolygon:nil,
                        isThinFinePrintRecovery:region.isThinFinePrintRecovery,finePrintRetryPolygons:region.finePrintRetryPolygons,
                        recognitionColumnEvidence:region.recognitionColumnEvidence)
                }
            }

            var recognition: NativeCoreMLRecognitionResult?
            let rejectedColumnEvidence: [Int: NativeOCRDetectorSeedEvidence] = [:]
            let recoveredHorizontal = Set<Int>()
            var rejectedReads: [NativeCoreMLRecognizedRegion] = []
            var shortFragmentErasurePolygons: [Int: [[CGPoint]]] = [:]
            let threshold = min(max(confidenceThreshold, 0), 1)
            let detectorThresholds = detectorConfiguration ?? postprocessConfiguration
            // Weak boxes (recovery band below the box threshold) never enter the primary pass, so
            // the confident reads and their batches are exactly those of the plain detector output.
            let recovers = detectorThresholds.recoveryBoxThreshold != nil
            let mangaSiblingRecovery = postprocessConfiguration == .manga
            let strongRegions = regions.filter { region in
                !recovers || (detection.boxes.indices.contains(region.sourceIndex)
                    && detection.boxes[region.sourceIndex].score >= detectorThresholds.boxThreshold)
            }
            // First-batch alternatives. All crops are derived from
            // detector/RF geometry or original pixels, never from page IDs or labels.
            var firstPassRegions = strongRegions
            var expandedFirstCrops: [(parent: Int, index: Int)] = []
            var columnFirstCrops: [(parent: Int, indices: [Int])] = []
            var quotedFirstCrops: [(proposal: NativeOCRQuotedDotRecovery.Proposal, indices: [Int])] = []
            var endpointFirstControls: [(parent: Int, index: Int, polygon: [CGPoint])] = []
            var endpointFirstAlternatives: [Int: (index: Int, polygon: [CGPoint])] = [:]
            var endpointTrimConfirmations:[Int:Int]=[:]
            var contextGroupingOverrides:[Int:[CGPoint]]=[:]
            var contextGroupingOrientations:[Int:BrowserOCRSourceOrientation]=[:]
            var normalTrimConfirmations:[Int:(signature:String,confidence:Double)]=[:]
            var confirmedFragmentJoins:[Int:(word:String,fragment:String,budget:Int,read:NativeCoreMLRecognizedRegion)]=[:]
            var confirmedSourceFamilyReads:[Int:NativeCoreMLRecognizedRegion]=[:]
            var contextAcceptedPolygons:[Int:[CGPoint]]=[:]
            var contextDuplicatePeers:[Int:Set<Int>]=[:]
            if recognitionScopes == nil {
                var nextIndex = detection.boxes.count
                for region in strongRegions where firstPassRegions.count < strongRegions.count + 32 {
                    guard !residualRetention.blockedRecovery.contains(region.sourceIndex) else { continue }
                    if let box = detection.boxes.indices.contains(region.sourceIndex) ? detection.boxes[region.sourceIndex] : nil,
                       let bounds = NativeOCRDirectionGeometry.enabled("large")
                        ? NativeOCRDirectionGeometry.Frame(box.polygon)?.rect
                        : NativeOCRScopeGeometry.bounds(for: box.polygon),
                       box.score >= 0.5, bounds.width >= 150, bounds.height >= 300,
                       bounds.height >= bounds.width * 1.3, bounds.height <= bounds.width * 2.5,
                       box.polygon.count == 4 {
                        let columnWidth = max(48, bounds.height * 0.3)
                        let columnCount = min(4, max(2, Int((bounds.width / columnWidth).rounded())))
                        if firstPassRegions.count + columnCount <= strongRegions.count + 32 {
                            let p: [CGPoint]
                            if NativeOCRDirectionGeometry.enabled("large") {
                                guard let basis = NativeOCRDirectionGeometry.Frame(box.polygon) else { continue }
                                p = basis.quad
                            } else { p = box.polygon }
                            func interpolate(_ a: CGPoint, _ b: CGPoint, _ fraction: CGFloat) -> CGPoint {
                                CGPoint(x: a.x + (b.x - a.x) * fraction,
                                        y: a.y + (b.y - a.y) * fraction)
                            }
                            let indices = (0..<columnCount).map { nextIndex + $0 }
                            nextIndex += columnCount
                            for column in 0..<columnCount {
                                let left = CGFloat(column) / CGFloat(columnCount)
                                let right = CGFloat(column + 1) / CGFloat(columnCount)
                                let polygon = [interpolate(p[0], p[1], left), interpolate(p[0], p[1], right),
                                               interpolate(p[3], p[2], right), interpolate(p[3], p[2], left)]
                                firstPassRegions.append(NativeCoreMLRecognitionRegion(sourceIndex: indices[column],
                                    polygon: polygon, useProvidedOrder: NativeOCRDirectionGeometry.enabled("large")))
                            }
                            columnFirstCrops.append((region.sourceIndex, indices))
                        }
                    }
                    if residualParentPolygons[region.sourceIndex] == nil,
                       let proposal = NativeOCRQuotedDotRecovery.pixelProposal(frame: frame, region: region),
                       firstPassRegions.count + 2 <= strongRegions.count + 32 {
                        let indices = [nextIndex, nextIndex + 1]
                        nextIndex += 2
                        for (crop, index) in zip(proposal.crops, indices) {
                            firstPassRegions.append(NativeCoreMLRecognitionRegion(sourceIndex: index,
                                polygon: crop.polygon, useProvidedOrder: crop.useProvidedOrder))
                        }
                        quotedFirstCrops.append((proposal, indices))
                    } else if rfPrimary.supported.contains(region.sourceIndex),
                              region.samplingPolygon == nil,
                              let polygon = NativeOCRRFPrimaryEnsemble.expandedRecognitionPolygon(region.polygon) {
                        guard let expanded = NativeOCRScopeGeometry.bounds(for: polygon),
                              expanded.minX >= 0, expanded.minY >= 0,
                              expanded.maxX <= CGFloat(frame.width), expanded.maxY <= CGFloat(frame.height) else { continue }
                        firstPassRegions.append(NativeCoreMLRecognitionRegion(sourceIndex: nextIndex,
                            polygon: polygon))
                        expandedFirstCrops.append((region.sourceIndex, nextIndex))
                        nextIndex += 1
                    }
                }
                // Append controls after the established alternatives, so they
                // cannot consume or renumber the existing 32-crop recovery
                // budget. Unchanged crops require no additional recognition.
                for region in strongRegions {
                    guard !residualRetention.blockedRecovery.contains(region.sourceIndex),
                          residualParentPolygons[region.sourceIndex] == nil else { continue }
                    guard let base = endpointBases[region.sourceIndex], base.count == region.polygon.count,
                          zip(base,region.polygon).contains(where: { old,new in hypot(old.x-new.x,old.y-new.y) > 1 }) else { continue }
                    let box = detection.boxes[region.sourceIndex]
                    let sampling = base == box.polygon ?
                        (NativeOCRRFPrimaryEnsemble.completeSupportSampling(box: box, boxes: detection.boxes,
                            layout: rfLayout, frame: frame) ?? box.recognitionPolygon) : nil
                    firstPassRegions.append(NativeCoreMLRecognitionRegion(sourceIndex: nextIndex,
                        polygon: base, samplingPolygon: sampling,
                        isThinFinePrintRecovery: region.isThinFinePrintRecovery,
                        finePrintRetryPolygons: region.finePrintRetryPolygons,
                        recognitionColumnEvidence: region.recognitionColumnEvidence))
                    endpointFirstControls.append((region.sourceIndex,nextIndex,base))
                    nextIndex += 1
                    if endpointMeasuredTrims.contains(region.sourceIndex),
                       let local=NativeOCRRFPrimaryEnsemble.EndpointFrame(region.polygon) {
                        let sampling=NativeOCRDirectionGeometry.corners(local.rect.insetBy(
                            dx:-local.rect.width*0.08,dy:-local.rect.width*0.08)).map(local.restore)
                        if sampling.allSatisfy({ $0.x >= 0 && $0.x <= CGFloat(frame.width) && $0.y >= 0 && $0.y <= CGFloat(frame.height) }) {
                            firstPassRegions.append(.init(sourceIndex:nextIndex,polygon:region.polygon,samplingPolygon:sampling))
                            endpointTrimConfirmations[region.sourceIndex]=nextIndex
                            nextIndex += 1
                        }
                    }
                    if let measured=NativeOCRRFPrimaryEnsemble.measuredEndpointAlternative(
                        candidate:region.polygon,baseline:base,terminalProof:endpointTerminalProofs[region.sourceIndex]) {
                        firstPassRegions.append(.init(sourceIndex:nextIndex,polygon:measured,
                            isThinFinePrintRecovery:region.isThinFinePrintRecovery,
                            finePrintRetryPolygons:region.finePrintRetryPolygons,
                            recognitionColumnEvidence:region.recognitionColumnEvidence))
                        endpointFirstAlternatives[region.sourceIndex]=(nextIndex,measured)
                        nextIndex += 1
                    }
                }
            }
            if NativeOCRRFPrimaryEnsemble.mainMangaEndpointPolicy {
                firstPassRegions.removeAll(where:rejectsPrimaryInput)
            }
            NativeCausalRawDecodeDiagnostics.current?.bindDetectors(requestID: requestID,
                rows: detection.boxes.enumerated().map { index, box in
                    .init(sourceIndex: index, ownerID: nil, polygon: box.polygon)
                })
            if strongRegions.isEmpty {
                recognition = nil
            } else {
                try cancellationCheck()
                stageHandler?(.recognizing(regionCount: strongRegions.count))
                let decoded = try await recognizer.recognize(
                    frame: frame,
                    regions: firstPassRegions,
                    requestID: requestID,
                    confidenceThreshold: mangaSiblingRecovery ?
                        min(NativeOCRRFPrimaryEnsemble.firstPassDecodeFloor, threshold) :
                        (rfPrimary.supported.isEmpty ?
                            (recovers ? max(0, threshold - NativeOCRAdjacentLineRecovery.confidenceMargin) : threshold) :
                            min(rfPrimary.stronglySupported.isEmpty ?
                                NativeOCRRFPrimaryEnsemble.supportedRecognitionThreshold :
                                NativeOCRRFPrimaryEnsemble.stronglySupportedRecognitionThreshold, threshold)),
                    cancellationCheck: cancellationCheck
                )
                try cancellationCheck()
                guard decoded.requestID == requestID else {
                    throw CancellationError()
                }
                var firstReads = decoded.regions.filter {
                    $0.sourceIndex < detection.boxes.count && !residualRetention.suppressed.contains($0.sourceIndex)
                }
                var confirmedEndpointTerminalParents=Set<Int>()
                var confirmedRetainedTerminalParents=Set<Int>()
                var confirmedGlyphContourParents=Set<Int>()
                var confirmedSymbolicTerminals:[Int:(read:NativeCoreMLRecognizedRegion,head:Bool,tail:Bool,ink:[[CGPoint]])]=[:]
                var consumedFragmentJoinSources=Set<Int>()
                func preserveEndpointControls(in reads: inout [NativeCoreMLRecognizedRegion], preserveAdmission: Bool = false) {
                    for control in endpointFirstControls {
                        guard let baseline = decoded.regions.first(where: { $0.sourceIndex == control.index }) else {
                            if preserveAdmission { reads.removeAll { $0.sourceIndex == control.parent } }
                            continue
                        }
                        if baseline.confidence < threshold || baseline.text.isEmpty {
                            // Endpoint geometry does not create a new primary
                            // source. Keep the original decode for its existing
                            // filters; explicit recovery remains a later route.
                            if preserveAdmission {
                                reads.removeAll { $0.sourceIndex == control.parent }
                                if !baseline.text.isEmpty {
                                    reads.append(.init(sourceIndex:control.parent,polygon:control.polygon,
                                        text:baseline.text,confidence:baseline.confidence,
                                        tokenObservations:baseline.tokenObservations))
                                }
                            }
                            continue
                        }
                        let candidate = reads.first { $0.sourceIndex == control.parent }
                        let currentReads=reads
                        func acceptedEndpoint(_ candidate:NativeCoreMLRecognizedRegion)->Bool {
                            let peerOverlap=currentReads.compactMap { peer -> (text:String,acquired:Bool)? in
                                guard peer.sourceIndex != control.parent,peer.confidence >= threshold,
                                      endpointContinuationPeers[control.parent]?.contains(peer.sourceIndex) != true,
                                      detection.boxes.indices.contains(peer.sourceIndex) else { return nil }
                                let original=endpointBases[peer.sourceIndex] ?? detection.boxes[peer.sourceIndex].polygon
                                guard NativeOCRRFPrimaryEnsemble.overlapsEndpointReadAfterGrowth(candidate.polygon,
                                    baseline:control.polygon,peer:original,
                                    ink:endpointInkStyles?[control.parent],peerInk:endpointInkStyles?[peer.sourceIndex]) else { return nil }
                                let before=NativeOCRDirectionGeometry.intersectionArea(control.polygon,original)
                                let after=NativeOCRDirectionGeometry.intersectionArea(candidate.polygon,original)
                                var acquired=after > before+1e-6
                                if acquired,let proof=confirmedSymbolicTerminals[control.parent],!proof.ink.isEmpty,
                                   NativeOCRContextualColumnRecovery.retainsConfirmedSymbolicTerminal(
                                    candidate:candidate,baseline:baseline.text,confirmed:proof.read,head:proof.head,tail:proof.tail),
                                   let evidence=detection.boxes[peer.sourceIndex].detectorSeedEvidence,evidence.isValid {
                                    acquired=NativeOCRContextualColumnRecovery.samplesObservedGlyph(proof.ink,
                                        peerPolygon:original,evidence:evidence,excludingPolygon:control.polygon)
                                }
                                return (peer.text,acquired)
                            }
                            let normalProof=normalTrimConfirmations[control.parent].map {
                                $0.signature==NativeOCRRFPrimaryEnsemble.measuredTrimSignature(candidate.text) &&
                                    candidate.confidence >= $0.confidence
                            } == true
                            // Only the exact physically measured and twice
                            // decoded crop can retain a weak-token correction.
                            if let proof=confirmedSourceFamilyReads[control.parent],
                               candidate.polygon==proof.polygon,candidate.text==proof.text,
                               candidate.confidence >= proof.confidence {
                                // An overlapping word's enclosing quad may
                                // cover blank space above its actual letters.
                                // Preserve the paired physical certificate
                                // unless the new band acquires owned glyphs.
                                let borrows=currentReads.contains { peer in
                                    guard peer.sourceIndex != control.parent,peer.confidence >= threshold,
                                          endpointContinuationPeers[control.parent]?.contains(peer.sourceIndex) != true,
                                          detection.boxes.indices.contains(peer.sourceIndex) else { return false }
                                    let original=endpointBases[peer.sourceIndex] ?? detection.boxes[peer.sourceIndex].polygon
                                    let before=NativeOCRDirectionGeometry.intersectionArea(control.polygon,original)
                                    let after=NativeOCRDirectionGeometry.intersectionArea(candidate.polygon,original)
                                    guard after > before+1e-6 else { return false }
                                    guard let evidence=detection.boxes[peer.sourceIndex].detectorSeedEvidence,
                                          evidence.isValid else { return true }
                                    return NativeOCRContextualColumnRecovery.samplesObservedGlyph([candidate.polygon],
                                        peerPolygon:original,evidence:evidence,excludingPolygon:control.polygon)
                                }
                                if !borrows { return true }
                            }
                            if let proof=confirmedSymbolicTerminals[control.parent],
                               !peerOverlap.contains(where: \.acquired),
                               NativeOCRContextualColumnRecovery.retainsConfirmedSymbolicTerminal(
                                candidate:candidate,baseline:baseline.text,confirmed:proof.read,
                                head:proof.head,tail:proof.tail) { return true }
                            if let proof=confirmedFragmentJoins[control.parent],candidate.polygon==proof.read.polygon,
                               candidate.confidence >= proof.read.confidence,
                               NativeOCRRFPrimaryEnsemble.measuredTrimSignature(candidate.text) ==
                                NativeOCRRFPrimaryEnsemble.measuredTrimSignature(proof.read.text),
                               NativeOCRContextualColumnRecovery.preservesFragmentJoin(candidate:candidate.text,
                                word:proof.word,fragment:proof.fragment,budget:proof.budget),
                               !peerOverlap.contains(where:{$0.acquired}) { return true }
                            return NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate: candidate.text,
                                confidence: candidate.confidence, baseline: baseline.text, threshold: threshold,
                                retainsOriginalSpan:NativeOCRRFPrimaryEnsemble.retainsOriginalReadingSpan(
                                    candidate:candidate.polygon,baseline:control.polygon),
                                retainsDetectorSpan:detection.boxes.indices.contains(control.parent) &&
                                    NativeOCRRFPrimaryEnsemble.retainsOriginalReadingSpan(
                                        candidate:candidate.polygon,baseline:detection.boxes[control.parent].polygon),
                                confirmedMeasuredTrim:normalProof || (endpointMeasuredTrims.contains(control.parent) &&
                                    candidate.confidence >= baseline.confidence &&
                                    endpointTrimConfirmations[control.parent].flatMap { id in
                                        decoded.regions.first { $0.sourceIndex == id }
                                    }.map { other in
                                        other.confidence >= threshold &&
                                        NativeOCRRFPrimaryEnsemble.measuredTrimContent(other.text)==NativeOCRRFPrimaryEnsemble.measuredTrimContent(candidate.text)
                                    } == true),
                                confirmedTerminalCompletion:confirmedEndpointTerminalParents.contains(control.parent),
                                unprovenLongGrowth:NativeOCRRFPrimaryEnsemble.hasUnprovenLongEndpointGrowth(
                                    candidate:candidate.polygon,baseline:control.polygon,
                                    terminalProof:endpointTerminalProofs[control.parent]),
                                overlappingPeerTexts:peerOverlap.map(\.text),
                                newlyAcquiredPeerTexts:peerOverlap.filter(\.acquired).map(\.text))
                        }
                        if let candidate,acceptedEndpoint(candidate) { continue }
                        if let proof=confirmedFragmentJoins[control.parent],acceptedEndpoint(proof.read) {
                            reads.removeAll { $0.sourceIndex==control.parent };reads.append(proof.read)
                            continue
                        }
                        if let alternative=endpointFirstAlternatives[control.parent],
                           let measured=decoded.regions.first(where:{ $0.sourceIndex == alternative.index }),
                           acceptedEndpoint(measured) {
                            reads.removeAll { $0.sourceIndex == control.parent }
                            reads.append(.init(sourceIndex:control.parent,polygon:alternative.polygon,
                                text:measured.text,confidence:measured.confidence,tokenObservations:measured.tokenObservations))
                            continue
                        }
                        reads.removeAll { $0.sourceIndex == control.parent }
                        reads.append(.init(sourceIndex: control.parent, polygon: control.polygon,
                            text: baseline.text, confidence: baseline.confidence,
                            tokenObservations: baseline.tokenObservations))
                    }
                }
                preserveEndpointControls(in: &firstReads,preserveAdmission:true)
                var acceptedContext=residualRetention.blockedRecovery
                var contextObservedPeers=Dictionary(uniqueKeysWithValues:firstReads.filter {
                    $0.confidence >= threshold
                }.map { ($0.sourceIndex,$0) })
                var confirmedPointSources=Set<Int>()
                func admitContext(_ entry:(proposal:NativeOCRContextualColumnRecovery.Proposal,indices:[Int]),
                                  from candidates:[NativeCoreMLRecognizedRegion]) {
                    guard !residualRetention.blockedRecovery.contains(entry.proposal.parent),
                          preservesResidualFootprint(entry.proposal.parent, entry.proposal.polygon) else { return }
                    let reads=entry.indices.compactMap { index in candidates.first { $0.sourceIndex == index } }
                    guard reads.count==2,
                          NativeOCRRFPrimaryEnsemble.measuredTrimContent(reads[0].text)==NativeOCRRFPrimaryEnsemble.measuredTrimContent(reads[1].text),
                          !reads[0].text.isEmpty,
                          reads.allSatisfy({ $0.confidence.isFinite && $0.confidence >= threshold && !$0.tokenObservations.isEmpty &&
                              $0.tokenObservations.allSatisfy { $0.confidence.isFinite && (0...1).contains($0.confidence) } }),
                          (entry.proposal.symbolicTerminalOnly || reads[0].text.unicodeScalars.contains(where:{ CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })) else { return }
                    let parent=entry.proposal.parent,prior=firstReads.first { $0.sourceIndex == parent }
                    if entry.proposal.sourceFamilyTrim || entry.proposal.observedWeakTerminal {
                        guard let prior,reads.allSatisfy({NativeOCRContextualColumnRecovery.preservesConfidentDotSlots(
                            candidate:$0.text,baseline:prior,threshold:threshold)}) else { return }
                    }
                    let familyWordPreserved=(entry.proposal.sourceFamilyTrim || entry.proposal.observedWeakTerminal) && prior.map { baseline in
                        reads.allSatisfy { NativeOCRContextualColumnRecovery.preservesSourceFamilyWord(
                            candidate:$0,baseline:baseline,threshold:threshold) }
                    } == true
                    let symbolicPreserved=entry.proposal.symbolicTerminalOnly && prior.map {
                        NativeOCRContextualColumnRecovery.preservesSymbolicTerminal(
                            candidate:reads[0].text,baseline:$0.text,
                            head:entry.proposal.sourceHeadCompletion,tail:entry.proposal.sourceTailCompletion)
                    } == true
                    if entry.proposal.measuredSourceAxis,!entry.proposal.measuredNormalOnly { return }
                    // Later one-ended alternatives are fallbacks for a failed
                    // nominal trim, never permission to undo a certified trim.
                    if entry.proposal.measuredTrimOnly,acceptedContext.contains(parent) { return }
                    if entry.proposal.measuredNormalOnly {
                        guard !acceptedContext.contains(parent),let prior,prior.confidence >= threshold,
                              prior.text.filter({$0.isLetter || $0.isNumber}).count >= 2,
                              reads.allSatisfy({ $0.confidence >= max(0.8,prior.confidence) &&
                                NativeOCRContextualColumnRecovery.preservesNormalWord(candidate:$0.text,baseline:prior.text,
                                    head:entry.proposal.sourceHeadCompletion,tail:entry.proposal.sourceTailCompletion)
                              }) else { return }
                    }
                    if entry.proposal.measuredGlyphContourOnly {
                        guard let prior,prior.confidence >= threshold,entry.proposal.sourceTerminalProof != nil,
                              reads.allSatisfy({$0.confidence >= (entry.proposal.retainedGlyphWordConfirmation ? threshold:max(0.8,threshold))}) else {return}
                        if entry.proposal.retainedGlyphWordConfirmation {
                            guard entry.proposal.samplings.last==prior.polygon,reads.allSatisfy({
                                NativeOCRRFPrimaryEnsemble.measuredTrimContent($0.text) ==
                                    NativeOCRRFPrimaryEnsemble.measuredTrimContent(prior.text)
                            }) else {return}
                        }
                    }
                    if entry.proposal.pointTailOnly {
                        guard !firstReads.contains(where: { entry.proposal.pointSources.contains($0.sourceIndex) && $0.confidence >= threshold }),
                              let prior,prior.confidence >= threshold else { return }
                        guard reads.allSatisfy({NativeOCRRFPrimaryEnsemble.preservesTerminalWord(
                            candidate:$0.text,baseline:prior.text,allowSingleGlyph:true)}) else { return }
                    }
                    if entry.proposal.measuredTerminalOnly {
                        guard !acceptedContext.contains(parent),let prior,prior.confidence >= threshold,
                              entry.proposal.sourceTerminalProof != nil,
                              (entry.proposal.symbolicTerminalOnly || prior.text.filter({$0.isLetter || $0.isNumber}).count >= 2),
                              reads.allSatisfy({ $0.confidence >= (entry.proposal.symbolicTerminalOnly ? threshold:max(0.8,threshold)) &&
                                NativeOCRRFPrimaryEnsemble.measuredTrimSignature($0.text) ==
                                    NativeOCRRFPrimaryEnsemble.measuredTrimSignature(reads[0].text) &&
                                (entry.proposal.symbolicTerminalOnly ?
                                    NativeOCRContextualColumnRecovery.preservesSymbolicTerminal(candidate:$0.text,baseline:prior.text,
                                        head:entry.proposal.sourceHeadCompletion,tail:entry.proposal.sourceTailCompletion):
                                    (NativeOCRContextualColumnRecovery.preservesNormalWord(candidate:$0.text,baseline:prior.text,
                                        head:entry.proposal.sourceHeadCompletion,tail:entry.proposal.sourceTailCompletion) || familyWordPreserved))
                              }) else { return }
                        for group in rfPrimary.groups where group.members.contains(parent) {
                            guard let existing=firstReads.first(where:{$0.sourceIndex==group.index}),
                                  existing.confidence >= threshold else { continue }
                            guard reads.allSatisfy({ NativeOCRContextualColumnRecovery.retainedTerminalGroup(
                                prior:existing,candidate:$0,threshold:threshold) != nil }) else { return }
                        }
                    }
                    if entry.proposal.measuredTrimOnly {
                        let priorFloor=entry.proposal.sourceFamilyTrim ? threshold:max(0.8,threshold)
                        guard let prior,prior.confidence >= priorFloor,reads.allSatisfy({
                            $0.confidence >= max(0.8,threshold) && (familyWordPreserved ||
                                NativeOCRRFPrimaryEnsemble.measuredTrimSignature($0.text) ==
                                    NativeOCRRFPrimaryEnsemble.measuredTrimSignature(prior.text))
                        }) else { return }
                    }
                    for peer in firstReads where peer.sourceIndex != parent && acceptedContext.contains(peer.sourceIndex) &&
                        peer.confidence >= threshold && peer.text.filter({$0.isLetter || $0.isNumber}).count >= 2 {
                        guard detection.boxes.indices.contains(peer.sourceIndex),
                              let evidence=detection.boxes[peer.sourceIndex].detectorSeedEvidence else { continue }
                        let shared=detection.boxes[parent].detectorSeedEvidence.map {
                            NativeOCRContextualColumnRecovery.sharedContinuationSeeds(evidence:$0,
                                source:detection.boxes[parent].polygon,reference:entry.proposal.polygon)
                        } ?? []
                        let oldSpan=NativeOCRContextualColumnRecovery.unchangedObservedWordSpan(
                            before:contextObservedPeers[peer.sourceIndex],after:peer,threshold:threshold)
                        if NativeOCRContextualColumnRecovery.samplesObservedGlyph([entry.proposal.polygon],
                            peerPolygon:peer.polygon,evidence:evidence,excludingSeeds:shared,excludingPolygon:oldSpan) { return }
                    }
                    let complements=firstReads.filter { entry.proposal.complements.contains($0.sourceIndex) }
                    let combined=reads[0].text+complements.sorted(by:{ $0.sourceIndex < $1.sourceIndex }).map(\.text).joined()
                    let peerOverlap=firstReads.compactMap { peer -> (text:String,acquired:Bool)? in
                        guard peer.sourceIndex != parent,!entry.proposal.complements.contains(peer.sourceIndex),
                              !(entry.proposal.pointTailOnly && rfPrimary.groups.contains(where:{
                                $0.index==peer.sourceIndex && $0.members.contains(parent)
                              })),
                              peer.confidence >= threshold,detection.boxes.indices.contains(peer.sourceIndex),
                              NativeOCRRFPrimaryEnsemble.overlapsEndpointReadAfterGrowth(entry.proposal.polygon,
                                baseline:prior?.polygon ?? detection.boxes[parent].polygon,peer:peer.polygon,
                                ink:endpointInkStyles?[parent],peerInk:endpointInkStyles?[peer.sourceIndex]) else { return nil }
                        let old=prior?.polygon ?? detection.boxes[parent].polygon
                        let before=NativeOCRDirectionGeometry.intersectionArea(old,peer.polygon)
                        let after=NativeOCRDirectionGeometry.intersectionArea(entry.proposal.polygon,peer.polygon)
                        var acquired=after > before+1e-6
                        if acquired,entry.proposal.symbolicTerminalOnly,!entry.proposal.sourceTerminalInk.isEmpty,
                           let evidence=detection.boxes[peer.sourceIndex].detectorSeedEvidence,evidence.isValid {
                            // A wider enclosing rectangle can overlap an old
                            // neighbouring crop without acquiring its glyph.
                            // Symbol-only cap recovery must be judged against
                            // the measured new print, not empty bbox corners.
                            acquired=NativeOCRContextualColumnRecovery.samplesObservedGlyph(
                                entry.proposal.sourceTerminalInk,peerPolygon:peer.polygon,evidence:evidence,excludingPolygon:old)
                        }
                        return (peer.text,acquired)
                    }
                    let trusted=prior.flatMap { $0.confidence >= threshold ? $0.text:nil }
                    if !peerOverlap.isEmpty {
                        guard NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:combined,
                        confidence:reads[0].confidence,baseline:trusted ?? "",threshold:threshold,retainsOriginalSpan:true,
                        confirmedMeasuredTrim:entry.proposal.measuredNormalOnly,
                        confirmedTerminalCompletion:entry.proposal.pointTailOnly || entry.proposal.measuredTerminalOnly,
                        overlappingPeerTexts:trusted == nil ? []:peerOverlap.map(\.text),
                        newlyAcquiredPeerTexts:peerOverlap.filter(\.acquired).map(\.text)) ||
                            ((symbolicPreserved || familyWordPreserved) && !peerOverlap.contains(where: \.acquired)) else { return }
                    }
                    if let prior,prior.confidence >= threshold,
                       let previous=NativeOCRRFPrimaryEnsemble.EndpointFrame(prior.polygon),
                       let next=NativeOCRRFPrimaryEnsemble.EndpointFrame(entry.proposal.polygon) {
                        let dot=min(CGFloat(1),abs(previous.along.x*next.along.x+previous.along.y*next.along.y))
                        let angle=acos(dot)
                        let grid=primaryProbability.map { max(CGFloat(frame.width)/CGFloat($0.width),CGFloat(frame.height)/CGFloat($0.height)) } ?? 1
                        let uncertainty=max(CGFloat.pi/180,atan2(2*grid,min(previous.rect.width,previous.rect.height)))
                        let same=NativeOCRRFPrimaryEnsemble.measuredTrimContent(prior.text)==NativeOCRRFPrimaryEnsemble.measuredTrimContent(reads[0].text)
                        if same,!entry.proposal.measuredSourceAxis,prior.text.filter({$0.isLetter || $0.isNumber}).count >= 2,
                           angle > 1e-6,angle <= uncertainty*2 { return }
                        let oldCore=NativeOCRRFPrimaryEnsemble.measuredTrimContent(prior.text)
                        let newCore=NativeOCRRFPrimaryEnsemble.measuredTrimContent(reads[0].text)
                        if !familyWordPreserved,prior.text.filter({$0.isLetter || $0.isNumber}).count >= 2,newCore != oldCore,
                           !newCore.hasSuffix(oldCore),!newCore.hasPrefix(oldCore) { return }
                        if angle <= uncertainty*2,let proof=endpointTerminalProofs[parent] {
                            let observed=next.bounds(proof),original=next.bounds(detection.boxes[parent].polygon),epsilon=max(2,grid)
                            if observed.minY < original.minY-1,next.rect.minY > observed.minY+epsilon { return }
                            if observed.maxY > original.maxY+1,next.rect.maxY < observed.maxY-epsilon { return }
                        }
                    }
                    if (prior?.confidence ?? 0) < threshold {
                        let before=prior.map { NativeOCRRFPrimaryEnsemble.measuredTrimContent($0.text) } ?? ""
                        let after=NativeOCRRFPrimaryEnsemble.measuredTrimContent(reads[0].text)
                        guard entry.proposal.independentGeometry ||
                            (after != before && reads[0].text.filter({$0.isLetter || $0.isNumber}).count >= 2) else { return }
                        let scopes=rfLayout?.primitives ?? []
                        guard scopes.contains(where:{ $0.semanticClass == .text && $0.confidence >= 0.25 &&
                            NativeOCRDirectionAdapters.coverage(entry.proposal.polygon,by:$0) >= 0.5 }),
                              !scopes.contains(where:{ $0.semanticClass == .soundEffect && $0.confidence >= 0.25 &&
                            NativeOCRDirectionAdapters.coverage(entry.proposal.polygon,by:$0) >= 0.3 }) else { return }
                    }
                    if let prior,prior.confidence >= threshold {
                        let preserved=NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:combined,confidence:reads[0].confidence,
                            baseline:prior.text,threshold:threshold,retainsOriginalSpan:true,
                            confirmedMeasuredTrim:entry.proposal.measuredNormalOnly,
                            confirmedTerminalCompletion:entry.proposal.pointTailOnly || entry.proposal.measuredTerminalOnly)
                        let oldLetters=prior.text.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
                        let area=NativeOCRDirectionGeometry.area(prior.polygon)
                        let correctedSingle=oldLetters.count==1 && reads.allSatisfy({$0.confidence >= prior.confidence}) && area > 0 &&
                            NativeOCRDirectionGeometry.intersectionArea(prior.polygon,entry.proposal.polygon) >= area*0.9
                        guard preserved || correctedSingle || symbolicPreserved || familyWordPreserved else { return }
                        // A new sampling axis does not establish a new relation
                        // to adjacent, independently retained words. Preserve
                        // the pre-recognition layout core for this source.
                        if entry.proposal.complements.isEmpty {
                            contextGroupingOverrides[parent]=endpointBases[parent] ?? prior.polygon
                            // One glyph has no independently measured text
                            // baseline. Borrowing a neighbour's sampling axis
                            // cannot establish a new paragraph flow for it.
                            let nextLetters=reads[0].text.unicodeScalars.filter {
                                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                            }
                            let independentSFX=rfLayout?.primitives.contains {
                                $0.semanticClass == .soundEffect && $0.confidence >= 0.25 &&
                                    NativeOCRDirectionAdapters.coverage(prior.polygon,by:$0) >= 0.5
                            } == true
                            if oldLetters.count==1,nextLetters.count==1,independentSFX {
                                contextGroupingOrientations[parent]=Self.orientation(for:prior.polygon)
                            }
                        }
                    } else { contextGroupingOverrides[parent]=entry.proposal.polygon }
                    acceptedContext.insert(parent)
                    if entry.proposal.measuredGlyphContourOnly {confirmedGlyphContourParents.insert(parent)}
                    if entry.proposal.measuredTerminalOnly || entry.proposal.measuredGlyphContourOnly {
                        confirmedRetainedTerminalParents.insert(parent)
                    }
                    contextAcceptedPolygons[parent]=entry.proposal.polygon
                    if entry.proposal.measuredNormalOnly || entry.proposal.measuredTerminalOnly ||
                        entry.proposal.measuredGlyphContourOnly || familyWordPreserved {
                        normalTrimConfirmations[parent]=(NativeOCRRFPrimaryEnsemble.measuredTrimSignature(reads[0].text),
                            reads.map(\.confidence).min()!)
                        if let proof=entry.proposal.sourceTerminalProof {
                            endpointTerminalProofs[parent]=NativeOCRRFPrimaryEnsemble.combiningEndpointGrowth(
                                base:proof,supplement:endpointTerminalProofs[parent],minimumChange:0)
                            confirmedEndpointTerminalParents.insert(parent)
                        }
                    }
                    if entry.proposal.pointTailOnly {
                        confirmedPointSources.formUnion(entry.proposal.pointSources)
                        contextDuplicatePeers[parent,default:[]].formUnion(entry.proposal.pointSources)
                        confirmedEndpointTerminalParents.insert(parent)
                        // A confirmed member recovery and its existing group
                        // are reads of identical owners, not independent words.
                        for group in rfPrimary.groups where group.members.contains(parent) {
                            endpointContinuationPeers[parent,default:[]].insert(group.index)
                        }
                        // Carry the measured point proof through the later
                        // endpoint-control pass. Unchanged word letters are
                        // not evidence of empty padding after two actual reads
                        // have confirmed a source-rooted punctuation tail.
                        endpointTerminalProofs[parent]=endpointTerminalProofs[parent].map {
                            NativeOCRRFPrimaryEnsemble.combiningEndpointGrowth(base:$0,
                                supplement:entry.proposal.polygon,minimumChange:0)
                        } ?? entry.proposal.polygon
                        endpointPointTerminalProofs[parent]=entry.proposal.polygon
                    }
                    var observedBoundaryAliases=Set<Int>()
                    let newLetters=reads[0].text.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
                    if newLetters.count >= 2,!entry.proposal.measuredTerminalOnly,
                       let parentEvidence=detection.boxes[parent].detectorSeedEvidence {
                        for child in firstReads where child.sourceIndex != parent && detection.boxes.indices.contains(child.sourceIndex) {
                            let letters=child.text.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
                            guard letters.count==1,reads.allSatisfy({$0.confidence >= child.confidence}),
                                  let evidence=detection.boxes[child.sourceIndex].detectorSeedEvidence,
                                  !NativeOCRRFPrimaryEnsemble.distinctEndpointInk(endpointInkStyles?[parent],endpointInkStyles?[child.sourceIndex]) else { continue }
                            let shared=NativeOCRRFPrimaryEnsemble.retainsSharedGlyph(child:evidence,parent:parentEvidence,
                                childPolygon:child.polygon,container:entry.proposal.polygon)
                            let boundary=prior.map { original in
                                original.confidence >= threshold && reads.allSatisfy {
                                    NativeOCRRFPrimaryEnsemble.retainsObservedBoundaryGlyph(child:evidence,fragment:child.text,
                                        baselineText:original.text,candidateText:$0.text,
                                        baseline:original.polygon,container:entry.proposal.polygon)
                                }
                            } == true
                            guard shared || boundary else { continue }
                            // Shared detector cells describe the letter, not
                            // an independently retained punctuation tail. Do
                            // not transfer that read while its observed cap
                            // remains outside the new parent's actual crop.
                            let hasMark=child.text.unicodeScalars.contains {
                                !CharacterSet.letters.contains($0) && !CharacterSet.decimalDigits.contains($0) &&
                                    !CharacterSet.whitespacesAndNewlines.contains($0)
                            }
                            // A measured but unaccepted expansion is not this
                            // singleton's retained punctuation. In particular,
                            // it may observe points already owned by the word
                            // above. The complete boundary-glyph certificate
                            // preserves the accepted footprint; still protect
                            // every admitted terminal and literal source mark.
                            let protectTerminal = !boundary || hasMark ||
                                confirmedEndpointTerminalParents.contains(child.sourceIndex)
                            if protectTerminal,let terminal=endpointTerminalProofs[child.sourceIndex] ?? (hasMark ? child.polygon:nil) {
                                let grid=primaryProbability.map {
                                    max(CGFloat(frame.width)/CGFloat($0.width),CGFloat(frame.height)/CGFloat($0.height))
                                } ?? 1
                                guard NativeOCRContextualColumnRecovery.retainsObservedSource(terminal,
                                    candidate:entry.proposal.polygon,uncertainty:max(2,grid)) else { continue }
                            }
                            contextDuplicatePeers[parent,default:[]].insert(child.sourceIndex)
                            if boundary { observedBoundaryAliases.insert(child.sourceIndex) }
                        }
                    }
                    if !observedBoundaryAliases.isEmpty,let prior {
                        // The old whole-word crop already observed this glyph.
                        // Its singleton detector cannot replace that word's
                        // grouping axis or reduce its relation span.
                        contextGroupingOverrides[parent]=prior.polygon
                    } else if let aliases=contextDuplicatePeers[parent],aliases.count==1,
                       let child=firstReads.first(where:{aliases.contains($0.sourceIndex)}) {
                        contextGroupingOverrides[parent]=endpointBases[child.sourceIndex] ?? child.polygon
                    }
                    firstReads.removeAll { $0.sourceIndex == parent || contextDuplicatePeers[parent]?.contains($0.sourceIndex)==true }
                    // This fallback confirms the existing actual read's word,
                    // rather than inventing new punctuation from a wider crop.
                    // Keep that independently decoded source transcript intact.
                    let sourceRead=entry.proposal.retainedGlyphWordConfirmation ? reads[1]:reads[0]
                    let accepted=NativeCoreMLRecognizedRegion(sourceIndex:parent,polygon:entry.proposal.polygon,text:sourceRead.text,
                        confidence:reads.map(\.confidence).min()!,tokenObservations:sourceRead.tokenObservations)
                    firstReads.append(accepted)
                    if familyWordPreserved { confirmedSourceFamilyReads[parent]=accepted }
                    if entry.proposal.symbolicTerminalOnly {
                        confirmedSymbolicTerminals[parent]=(accepted,entry.proposal.sourceHeadCompletion,entry.proposal.sourceTailCompletion,entry.proposal.sourceTerminalInk)
                    }
                }
                if mangaSiblingRecovery,recognitionScopes == nil {
                    // A detector that supplied no retained read has no consumed
                    // glyph to veto a neighbouring, freshly recognized crop.
                    // Kept reads still supply exact private-ink barriers.
                    let kept=firstReads.filter { $0.confidence >= threshold }
                    let active=Set(kept.map(\.sourceIndex))
                    let resolved=Set(kept.filter { $0.text.filter({$0.isLetter || $0.isNumber}).count >= 2 }.map(\.sourceIndex))
                    let shortPointWords=Set(kept.filter { $0.text.filter({$0.isLetter || $0.isNumber}).count == 1 }.map(\.sourceIndex))
                    let symbolicTrains=Set(kept.filter {
                        NativeOCRContextualColumnRecovery.isSymbolicPointTrain($0.text)
                    }.map(\.sourceIndex))
                    let peerPolygons=Dictionary(uniqueKeysWithValues:kept.map { ($0.sourceIndex,$0.polygon) })
                    contextObservedPeers=Dictionary(uniqueKeysWithValues:kept.map { ($0.sourceIndex,$0) })
                    var proposals=NativeOCRContextualColumnRecovery.proposals(boxes:detection.boxes,layout:rfLayout,
                        probability:primaryProbability,frame:frame,inkStyles:endpointInkStyles,
                        activePeers:active,peerPolygons:peerPolygons,excludingParents:acceptedContext,
                        retainedSingleGlyphs:Set(kept.filter {
                            $0.confidence >= threshold && $0.text.filter { $0.isLetter || $0.isNumber }.count==1
                        }.map(\.sourceIndex)))
                    proposals += NativeOCRContextualColumnRecovery.retainedPointTails(boxes:detection.boxes,
                        frame:frame,inkStyles:endpointInkStyles,retained:resolved.union(shortPointWords),peerPolygons:peerPolygons,
                        excluding:acceptedContext.union(proposals.map(\.parent)),layout:rfLayout,groups:rfPrimary.groups,
                        terminalCapParents:shortPointWords)
                    let confidentWords=Set(kept.filter {
                        $0.confidence >= max(0.8,threshold) && $0.text.filter({$0.isLetter || $0.isNumber}).count >= 2
                    }.map(\.sourceIndex))
                    let restoredTrims=Set(kept.compactMap { read -> Int? in
                        guard endpointMeasuredTrims.contains(read.sourceIndex),
                              let crop=firstPassRegions.first(where:{$0.sourceIndex==read.sourceIndex}),
                              !NativeOCRRFPrimaryEnsemble.retainsOriginalReadingSpan(candidate:crop.polygon,
                                  baseline:read.polygon) else { return nil }
                        return read.sourceIndex
                    })
                    proposals += NativeOCRContextualColumnRecovery.retainedWordTrims(boxes:detection.boxes,
                        frame:frame,layout:rfLayout,inkStyles:endpointInkStyles,retained:confidentWords,
                        peerPolygons:peerPolygons,excluding:acceptedContext.union(proposals.map(\.parent)),fallbackParents:restoredTrims)
                    proposals += NativeOCRContextualColumnRecovery.retainedNormalTrims(boxes:detection.boxes,
                        frame:frame,probability:primaryProbability,inkStyles:endpointInkStyles,retained:resolved,peerPolygons:peerPolygons,
                        excluding:acceptedContext.union(proposals.map(\.parent)))
                    var representedTerminalSpans:[Int:[[CGPoint]]]=[:]
                    for group in rfPrimary.groups {
                        guard let read=decoded.regions.first(where:{$0.sourceIndex==group.index}),
                              read.confidence >= threshold else { continue }
                        for member in group.members { representedTerminalSpans[member,default:[]].append(read.polygon) }
                    }
                    proposals += NativeOCRContextualColumnRecovery.retainedTerminals(boxes:detection.boxes,
                        frame:frame,probability:primaryProbability,inkStyles:endpointInkStyles,retained:resolved.union(symbolicTrains),
                        peerPolygons:peerPolygons,excluding:acceptedContext.union(proposals.map(\.parent)),
                        representedSpans:representedTerminalSpans,
                        exclamationParents:Set(kept.filter { NativeOCRContextualColumnRecovery.hasTerminalExclamation($0.text) }.map(\.sourceIndex)),
                        pointTrainParents:resolved.union(symbolicTrains),symbolicParents:symbolicTrains)
                    proposals += NativeOCRContextualColumnRecovery.retainedGlyphTerminals(boxes:detection.boxes,
                        frame:frame,inkStyles:endpointInkStyles,
                        retained:Set(kept.filter { $0.text.filter { $0.isLetter || $0.isNumber }.count >= 2 }.map(\.sourceIndex)),
                        peerPolygons:peerPolygons,excluding:acceptedContext.union(proposals.map(\.parent)))
                    proposals += NativeOCRContextualColumnRecovery.retainedCurvedStrokeTerminals(boxes:detection.boxes,
                        reads:kept,frame:frame,inkStyles:endpointInkStyles,
                        excluding:acceptedContext.union(proposals.map(\.parent)),threshold:threshold)
                    proposals += NativeOCRContextualColumnRecovery.retainedObservedWeakTerminals(boxes:detection.boxes,
                        reads:kept,frame:frame,layout:rfLayout,inkStyles:endpointInkStyles,
                        excluding:acceptedContext,threshold:threshold)
                    // Existing measured-corner/glyph recoveries keep priority.
                    // A failed trim nomination must never suppress their crops.
                    proposals += NativeOCRContextualColumnRecovery.retainedExpansionTrims(boxes:detection.boxes,
                        frame:frame,layout:rfLayout,inkStyles:endpointInkStyles,retained:confidentWords,
                        peerPolygons:peerPolygons,excluding:acceptedContext,terminalProofs:endpointTerminalProofs,
                        probability:primaryProbability)
                    proposals += NativeOCRContextualColumnRecovery.retainedSourceFamilyTrims(boxes:detection.boxes,
                        frame:frame,inkStyles:endpointInkStyles,retained:resolved,
                        peerPolygons:peerPolygons,excluding:acceptedContext,terminalProofs:endpointTerminalProofs,
                        immutableSourcePolygons:detectorSourcePolygons,probability:primaryProbability,
                        exclamationParents:Set(kept.filter {
                            NativeOCRContextualColumnRecovery.hasTerminalExclamation($0.text)
                        }.map(\.sourceIndex)))
                    var contextRegions:[NativeCoreMLRecognitionRegion]=[]
                    var contextLateCrops:[(proposal:NativeOCRContextualColumnRecovery.Proposal,indices:[Int])]=[]
                    var next=(firstPassRegions.map(\.sourceIndex).max() ?? -1)+1
                    for proposal in proposals where !residualRetention.blockedRecovery.contains(proposal.parent) &&
                        preservesResidualFootprint(proposal.parent, proposal.polygon) {
                        let indices=[next,next+1];next+=2
                        for (sampling,index) in zip(proposal.samplings,indices) {
                            contextRegions.append(.init(sourceIndex:index,polygon:proposal.polygon,samplingPolygon:sampling))
                        }
                        contextLateCrops.append((proposal,indices))
                    }
                    if !contextRegions.isEmpty {
                        let contextDecoded=try await recognizer.recognize(frame:frame,regions:contextRegions,requestID:requestID,
                            confidenceThreshold:threshold,cancellationCheck:cancellationCheck)
                        guard contextDecoded.requestID == requestID else { throw CancellationError() }
                        let ordered=contextLateCrops.sorted { a,b in
                            let rankA=a.proposal.immutableExpansionTrim ? 2:(a.proposal.sourceFamilyTrim ? 1:0)
                            let rankB=b.proposal.immutableExpansionTrim ? 2:(b.proposal.sourceFamilyTrim ? 1:0)
                            if rankA != rankB { return rankA < rankB }
                            let knownA=resolved.contains(a.proposal.parent),knownB=resolved.contains(b.proposal.parent)
                            if knownA != knownB { return knownA }
                            if a.proposal.parent != b.proposal.parent { return a.proposal.parent < b.proposal.parent }
                            // Same-source alternatives keep their nomination
                            // priority: established sampling before its fallback.
                            return (a.indices.first ?? 0) < (b.indices.first ?? 0)
                        }
                        for entry in ordered { admitContext(entry,from:contextDecoded.regions) }
                        firstPassRegions += contextRegions
                    }
                    let recovered=acceptedContext.subtracting(active)
                    let wordJoins=NativeOCRContextualColumnRecovery.recoveredColumnJoins(boxes:detection.boxes,
                        reads:firstReads,recovered:recovered,layout:rfLayout,inkStyles:endpointInkStyles,
                        threshold:threshold,width:frame.width,height:frame.height)
                    let reservedSources=Set(wordJoins.flatMap {[$0.parent,$0.recovered]})
                    let fragmentJoins=NativeOCRContextualColumnRecovery.retainedFragmentJoins(boxes:detection.boxes,
                        reads:firstReads,layout:rfLayout,frame:frame,inkStyles:endpointInkStyles,threshold:threshold)
                        .filter { !reservedSources.contains($0.parent) && !reservedSources.contains($0.recovered) &&
                            $0.additionalSources.isDisjoint(with:reservedSources) }
                    let joins=(wordJoins+fragmentJoins).filter { join in
                        residualRetention.blockedRecovery.union(residualRetention.coverage.keys).isDisjoint(with:
                            Set([join.parent, join.recovered]).union(join.additionalSources))
                    }
                    if !joins.isEmpty {
                        let start=(firstPassRegions.map(\.sourceIndex).max() ?? -1)+1
                        let regions=joins.enumerated().flatMap { offset,join in
                            join.samplings.enumerated().map { sample,polygon in
                                NativeCoreMLRecognitionRegion(sourceIndex:start+offset*2+sample,polygon:polygon)
                            }
                        }
                        let decodedJoins=try await recognizer.recognize(frame:frame,regions:regions,requestID:requestID,
                            confidenceThreshold:threshold,cancellationCheck:cancellationCheck)
                        guard decodedJoins.requestID == requestID else { throw CancellationError() }
                        for (offset,join) in joins.enumerated() {
                            let indices=Set([start+offset*2,start+offset*2+1])
                            let readings=decodedJoins.regions.filter { indices.contains($0.sourceIndex) }
                            let members=firstReads.filter { $0.sourceIndex==join.parent || $0.sourceIndex==join.recovered }
                            guard members.count==2,readings.count==2,
                                  let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(join.polygon) else { continue }
                            let expected=members.sorted { basis.bounds($0.polygon).minY < basis.bounds($1.polygon).minY }
                                .map(\.text).joined()
                            if join.maximumInsertedGlyphs > 0 {
                                guard let word=members.first(where:{$0.sourceIndex==join.parent}),
                                      let fragment=members.first(where:{$0.sourceIndex==join.recovered}),
                                      readings.allSatisfy({ read in
                                        read.confidence >= max(0.8,members.map(\.confidence).max()!) &&
                                        !read.tokenObservations.isEmpty &&
                                        NativeOCRRFPrimaryEnsemble.measuredTrimSignature(read.text) ==
                                            NativeOCRRFPrimaryEnsemble.measuredTrimSignature(readings[0].text) &&
                                        NativeOCRContextualColumnRecovery.preservesFragmentJoin(candidate:read.text,
                                            word:word.text,fragment:fragment.text,budget:join.maximumInsertedGlyphs)
                                      }) else { continue }
                                let joined=Set([join.parent,join.recovered]).union(join.additionalSources)
                                guard !rfPrimary.groups.contains(where:{ group in
                                    group.members.contains(join.parent) && !Set(group.members).isSubset(of:joined) &&
                                        firstReads.contains(where:{$0.sourceIndex==group.index && $0.confidence >= threshold})
                                }) else { continue }
                                let read=NativeCoreMLRecognizedRegion(sourceIndex:join.parent,polygon:join.polygon,
                                    text:readings[0].text,confidence:readings.map(\.confidence).min()!,
                                    tokenObservations:readings[0].tokenObservations)
                                confirmedFragmentJoins[join.parent]=(word.text,fragment.text,join.maximumInsertedGlyphs,read)
                                consumedFragmentJoinSources.formUnion(join.additionalSources.union([join.recovered]))
                                endpointTerminalProofs[join.parent]=join.polygon
                                confirmedEndpointTerminalParents.insert(join.parent)
                                for group in rfPrimary.groups where group.members.contains(join.parent) &&
                                    residualParentPolygons[group.index] == nil && Set(group.members).isSubset(of:joined) {
                                    guard let prior=firstReads.first(where:{$0.sourceIndex==group.index}) else { continue }
                                    firstReads.removeAll { $0.sourceIndex==group.index }
                                    firstReads.append(.init(sourceIndex:group.index,polygon:read.polygon,text:read.text,
                                        confidence:read.confidence,tokenObservations:read.tokenObservations))
                                    contextDuplicatePeers[group.index,default:[]].formUnion(joined)
                                    contextGroupingOverrides[group.index]=contextGroupingOverrides[group.index] ?? prior.polygon
                                    contextAcceptedPolygons[group.index]=read.polygon
                                }
                            } else {
                                guard readings.allSatisfy({ read in
                                    read.confidence >= threshold && !read.tokenObservations.isEmpty &&
                                    NativeOCRRFPrimaryEnsemble.measuredTrimContent(read.text)==NativeOCRRFPrimaryEnsemble.measuredTrimContent(expected) &&
                                    members.allSatisfy { NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:read.text,
                                        confidence:read.confidence,baseline:$0.text,threshold:threshold,retainsOriginalSpan:true) }
                                }) else { continue }
                            }
                            contextDuplicatePeers[join.parent,default:[]].insert(join.recovered)
                            contextDuplicatePeers[join.parent,default:[]].formUnion(join.additionalSources)
                            contextAcceptedPolygons[join.parent]=join.polygon
                            contextGroupingOverrides[join.parent]=join.polygon
                            acceptedContext.insert(join.parent)
                            firstReads.removeAll { $0.sourceIndex==join.parent || $0.sourceIndex==join.recovered }
                            firstReads.append(.init(sourceIndex:join.parent,polygon:join.polygon,text:readings[0].text,
                                confidence:readings.map(\.confidence).min()!,tokenObservations:readings[0].tokenObservations))
                        }
                        firstPassRegions += regions
                    }
                }
                if mangaSiblingRecovery,NativeOCRDirectionGeometry.enabled("pixelLocal") {
                    var retryRegions:[NativeCoreMLRecognitionRegion]=[]
                    var retryParents:[Int:[Int]]=[:]
                    for region in strongRegions where retryParents.count < 8 && !confirmedPointSources.contains(region.sourceIndex) &&
                        !consumedFragmentJoinSources.contains(region.sourceIndex) &&
                        !residualRetention.blockedRecovery.contains(region.sourceIndex) {
                        guard !firstReads.contains(where:{ $0.sourceIndex == region.sourceIndex && $0.confidence >= threshold }) else { continue }
                        let polygons=NativeOCRRFPrimaryEnsemble.smallCoreContextPolygons(index:region.sourceIndex,
                            boxes:detection.boxes,width:frame.width,height:frame.height)
                        guard polygons.count >= 2 else { continue }
                        let indices=polygons.indices.map { firstPassRegions.map(\.sourceIndex).max()!+1+retryRegions.count+$0 }
                        retryParents[region.sourceIndex]=indices
                        retryRegions += zip(polygons,indices).map { polygon,index in
                            NativeCoreMLRecognitionRegion(sourceIndex:index,polygon:polygon)
                        }
                    }
                    if !retryRegions.isEmpty {
                        let retries=try await recognizer.recognize(frame:frame,regions:retryRegions,requestID:requestID,
                            confidenceThreshold:threshold,cancellationCheck:cancellationCheck)
                        guard retries.requestID == requestID else { throw CancellationError() }
                        for (parent,indices) in retryParents {
                            let reads=retries.regions.filter { indices.contains($0.sourceIndex) && $0.confidence >= threshold }
                            let groups=Dictionary(grouping:reads,by:\.text)
                            guard let agreeing=groups.values.filter({ $0.count >= 2 && !$0[0].text.isEmpty }).max(by:{ $0.count < $1.count }),
                                  groups.values.filter({ $0.count >= 2 }).count == 1,
                                  let best=agreeing.max(by:{ $0.confidence < $1.confidence }),
                                  let original=strongRegions.first(where:{ $0.sourceIndex == parent }) else { continue }
                            firstReads.removeAll { $0.sourceIndex == parent }
                            firstReads.append(.init(sourceIndex:parent,polygon:original.polygon,text:best.text,
                                confidence:agreeing.map(\.confidence).min()!,tokenObservations:best.tokenObservations))
                        }
                    }
                }
                var splitColumnParents = Set<Int>()
                for candidate in columnFirstCrops where !firstReads.contains(where: { $0.sourceIndex == candidate.parent }) {
                    let children = candidate.indices.compactMap { index in
                        decoded.regions.first { $0.sourceIndex == index }
                    }
                    guard children.count == candidate.indices.count,
                          children.allSatisfy({ $0.confidence >= 0.65 && $0.text.count >= 2 }),
                          let original = strongRegions.first(where: { $0.sourceIndex == candidate.parent }) else { continue }
                    let text = children.reversed().map(\.text).joined()
                    firstReads.append(NativeCoreMLRecognizedRegion(sourceIndex: candidate.parent,
                        polygon: original.polygon, text: text,
                        confidence: children.map(\.confidence).min() ?? 0,
                        tokenObservations: children.flatMap(\.tokenObservations)))
                    splitColumnParents.insert(candidate.parent)
                }
                for crop in expandedFirstCrops {
                    guard let alternative = decoded.regions.first(where: { $0.sourceIndex == crop.index }),
                          alternative.confidence >= 0.8,
                          alternative.text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2,
                          let original = strongRegions.first(where: { $0.sourceIndex == crop.parent }),
                          !firstReads.contains(where: { $0.sourceIndex == crop.parent }) else { continue }
                    firstReads.removeAll { $0.sourceIndex == crop.parent }
                    firstReads.append(NativeCoreMLRecognizedRegion(sourceIndex: crop.parent,
                        polygon: original.polygon, text: alternative.text,
                        confidence: alternative.confidence, tokenObservations: alternative.tokenObservations))
                }
                for candidate in quotedFirstCrops {
                    let reads = zip(candidate.proposal.crops, candidate.indices).compactMap { crop, index -> NativeCoreMLRecognizedRegion? in
                        guard let read = decoded.regions.first(where: { $0.sourceIndex == index }) else { return nil }
                        return NativeCoreMLRecognizedRegion(sourceIndex: candidate.proposal.original.sourceIndex,
                            polygon: crop.polygon, text: read.text, confidence: read.confidence,
                            tokenObservations: read.tokenObservations)
                    }
                    guard let replacement = NativeOCRQuotedDotRecovery.accepted(proposal: candidate.proposal, reads: reads) else { continue }
                    firstReads.removeAll { $0.sourceIndex == replacement.sourceIndex }
                    firstReads.append(replacement)
                }
                if mangaSiblingRecovery,recognitionScopes == nil {
                    // Use the final admitted word footprint, including any
                    // earlier point/cap recovery. Completing its first glyph
                    // must not undo an already retained tail or its owners.
                    let contours=NativeOCRContextualColumnRecovery.retainedEndpointGlyphContours(
                        boxes:detection.boxes,reads:firstReads,groups:rfPrimary.groups,frame:frame,threshold:threshold)
                        .filter { !residualRetention.blockedRecovery.contains($0.parent) &&
                            preservesResidualFootprint($0.parent, $0.polygon) }
                    let start=(firstPassRegions.map(\.sourceIndex).max() ?? -1)+1
                    let regions=contours.enumerated().flatMap { offset,proposal in
                        proposal.samplings.enumerated().map { n,crop in
                            NativeCoreMLRecognitionRegion(sourceIndex:start+offset*2+n,polygon:proposal.polygon,samplingPolygon:crop)
                        }
                    }
                    if !regions.isEmpty {
                        let measured=try await recognizer.recognize(frame:frame,regions:regions,requestID:requestID,
                            confidenceThreshold:threshold,cancellationCheck:cancellationCheck)
                        guard measured.requestID==requestID else {throw CancellationError()}
                        for (offset,proposal) in contours.enumerated() where !confirmedGlyphContourParents.contains(proposal.parent) {
                            admitContext((proposal,[start+offset*2,start+offset*2+1]),from:measured.regions)
                        }
                        firstPassRegions+=regions
                    }
                }
                // A later quotation/context alternative cannot silently undo
                // the same accepted-source preservation check.
                preserveEndpointControls(in: &firstReads)
                // A paired terminal read can contain the same complete word
                // as an existing RF/DB group. Commit it under that group's
                // identity so its point/fragment owners cannot disappear when
                // the later duplicate-member reconciliation removes members.
                for group in rfPrimary.groups where !residualRetention.blockedRecovery.contains(group.index) &&
                    residualParentPolygons[group.index] == nil && !confirmedRetainedTerminalParents.isDisjoint(with:group.members) {
                    guard let prior=firstReads.first(where:{$0.sourceIndex==group.index}) else { continue }
                    let members=firstReads.filter { confirmedRetainedTerminalParents.contains($0.sourceIndex) &&
                        group.members.contains($0.sourceIndex) && !group.pointFragments.contains($0.sourceIndex) }
                    guard members.count==1,let member=members.first,
                          let replacement=NativeOCRContextualColumnRecovery.retainedTerminalGroup(
                            prior:prior,candidate:member,threshold:threshold) else { continue }
                    firstReads.removeAll { $0.sourceIndex==group.index }
                    firstReads.append(replacement)
                    contextGroupingOverrides[group.index]=contextGroupingOverrides[group.index] ?? prior.polygon
                    contextAcceptedPolygons[group.index]=replacement.polygon
                    endpointTerminalProofs[group.index]=replacement.polygon
                    confirmedEndpointTerminalParents.insert(group.index)
                }
                // A full-column CTC read can truncate one of its already
                // recognized member words. Keep the existing group ownership
                // while reconciling its newly confirmed terminal from ordered,
                // non-overlapping actual member reads. No text is synthesized.
                for group in rfPrimary.groups where !residualRetention.blockedRecovery.contains(group.index) &&
                    residualParentPolygons[group.index] == nil && group.pointFragments.isEmpty && !confirmedEndpointTerminalParents.isDisjoint(with:group.members) {
                    guard let prior=firstReads.first(where:{$0.sourceIndex==group.index}),prior.confidence >= 0.65 else { continue }
                    let members=group.members.compactMap { i in firstReads.first { $0.sourceIndex==i } }
                    guard members.count==group.members.count,members.allSatisfy({
                        $0.confidence >= 0.65 && $0.text.filter({$0.isLetter || $0.isNumber}).count >= 2 && !$0.tokenObservations.isEmpty
                    }),let measured=NativeOCRRFPrimaryEnsemble.observedTerminalGroup(base:prior.polygon,
                        members:members.map(\.polygon),grid:primaryProbability.map {
                            max(CGFloat(frame.width)/CGFloat($0.width),CGFloat(frame.height)/CGFloat($0.height))
                        } ?? 1) else { continue }
                    let ordered=measured.order.map { members[$0] },text=ordered.map(\.text).joined()
                    let confidence=ordered.map(\.confidence).min()!
                    guard NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:text,confidence:confidence,
                        baseline:prior.text,threshold:threshold,retainsOriginalSpan:true,confirmedTerminalCompletion:true) else { continue }
                    firstReads.removeAll { $0.sourceIndex==group.index }
                    firstReads.append(.init(sourceIndex:group.index,polygon:measured.polygon,text:text,confidence:confidence,
                        tokenObservations:ordered.flatMap(\.tokenObservations)))
                    contextAcceptedPolygons[group.index]=measured.polygon
                }
                // A broad DB box can contain multiple columns while further
                // continuations are independent DB boxes. Follow adjacent
                // columns leftward while one RF text scope supports the chain.
                for parent in splitColumnParents.sorted() where !residualRetention.blockedRecovery.contains(parent) &&
                    residualParentPolygons[parent] == nil {
                    guard let head = firstReads.first(where: { $0.sourceIndex == parent }),
                          let worldHeadBounds = NativeOCRScopeGeometry.bounds(for: head.polygon) else { continue }
                    // Explicit local column basis, not the arbitrary detector corner zero.
                    let localFrame = NativeOCRDirectionGeometry.enabled("splitJoin")
                        ? NativeOCRDirectionGeometry.readingQuad(head.polygon,vertical:true).flatMap {
                            NativeOCRDirectionGeometry.Frame($0)
                        } : nil
                    if NativeOCRDirectionGeometry.enabled("splitJoin"), localFrame == nil { continue }
                    let headBounds = localFrame?.bounds(head.polygon) ?? worldHeadBounds
                    func localBounds(_ polygon:[CGPoint]) -> CGRect? {
                        localFrame?.bounds(polygon) ?? NativeOCRScopeGeometry.bounds(for:polygon)
                    }
                    func coverage(_ box: CGRect, by scope: CGRect) -> CGFloat {
                        let overlap = box.intersection(scope)
                        return overlap.isNull ? 0 : overlap.width * overlap.height / (box.width * box.height)
                    }
                    let scopes = rfLayout?.primitives.filter { primitive in
                        primitive.semanticClass == .text && primitive.confidence >= 0.8 &&
                            (localFrame == nil ? coverage(headBounds, by: primitive.sourceBounds)
                                : NativeOCRDirectionAdapters.coverage(head.polygon,by:primitive)) >= 0.45
                    } ?? []
                    guard !scopes.isEmpty else { continue }
                    var joined = [head]
                    var union = headBounds
                    var leftmost = headBounds
                    while true {
                        let adjacent = firstReads.compactMap { read -> (NativeCoreMLRecognizedRegion, CGRect)? in
                            guard read.sourceIndex != parent,
                                  !residualRetention.blockedRecovery.contains(read.sourceIndex),
                                  residualParentPolygons[read.sourceIndex] == nil,
                                  !joined.contains(where: { $0.sourceIndex == read.sourceIndex }),
                                  detection.boxes.indices.contains(read.sourceIndex),
                                  read.confidence >= 0.65, read.text.count >= 2,
                                  localFrame.map({ NativeOCRDirectionGeometry.compatible(read.polygon,with:$0) }) != false,
                                  let bounds = localBounds(read.polygon),
                                  bounds.width <= headBounds.width * 0.45,
                                  bounds.height >= headBounds.height * 0.5,
                                  bounds.height <= headBounds.height * 1.1,
                                  bounds.midX < leftmost.minX,
                                  bounds.midX >= leftmost.minX - max(leftmost.width, bounds.width) * 1.5,
                                  bounds.intersection(union).height >= bounds.height * 0.6,
                                  scopes.contains(where: { (localFrame == nil ? coverage(bounds,by:$0.sourceBounds)
                                      : NativeOCRDirectionAdapters.coverage(read.polygon,by:$0)) >= 0.5 })
                            else { return nil }
                            return (read, bounds)
                        }
                        guard adjacent.count == 1, let (next, bounds) = adjacent.first else { break }
                        joined.append(next)
                        union = union.union(bounds)
                        leftmost = bounds
                    }
                    guard joined.count > 1 else { continue }
                    let localPolygon = [CGPoint(x: union.minX, y: union.minY), CGPoint(x: union.maxX, y: union.minY),
                                   CGPoint(x: union.maxX, y: union.maxY), CGPoint(x: union.minX, y: union.maxY)]
                    let polygon = localFrame.map { localPolygon.map($0.restore) } ?? localPolygon
                    let joinedIDs = Set(joined.map(\.sourceIndex))
                    firstReads.removeAll { joinedIDs.contains($0.sourceIndex) }
                    firstReads.append(NativeCoreMLRecognizedRegion(sourceIndex: parent, polygon: polygon,
                        text: joined.map(\.text).joined(), confidence: joined.map(\.confidence).min() ?? 0,
                        tokenObservations: joined.flatMap(\.tokenObservations)))
                    shortFragmentErasurePolygons[parent] = joined.flatMap {
                        detection.boxes[$0.sourceIndex].erasurePolygons
                    }
                }
                firstReads.removeAll {
                    consumedFragmentJoinSources.contains($0.sourceIndex) || residualRetention.suppressed.contains($0.sourceIndex)
                }
                let firstDecoded = NativeCoreMLRecognitionResult(requestID: requestID, regions: firstReads,
                    diagnostics: decoded.diagnostics.withAcceptedRegions(firstReads.count))
                // Reads below the confidence threshold are kept aside as recovery candidates only.
                let mergedIDs = Set(rfPrimary.groups.map(\.index))
                func dbScore(_ read: NativeCoreMLRecognizedRegion) -> Double? {
                    guard mangaSiblingRecovery, read.sourceIndex < detection.boxes.count else { return nil }
                    return detection.boxes[read.sourceIndex].score
                }
                rejectedReads = firstDecoded.regions.filter { !NativeOCRRFPrimaryEnsemble.admits($0,
                    threshold: threshold, supported: rfPrimary.supported,
                    stronglySupported: rfPrimary.stronglySupported, merged: mergedIDs,
                    dbScore: dbScore($0)) }
                let value = rejectedReads.isEmpty ? firstDecoded : NativeCoreMLRecognitionResult(
                    requestID: requestID, regions: firstDecoded.regions.filter { NativeOCRRFPrimaryEnsemble.admits($0,
                        threshold: threshold, supported: rfPrimary.supported,
                        stronglySupported: rfPrimary.stronglySupported, merged: mergedIDs,
                        dbScore: dbScore($0)) },
                    diagnostics: firstDecoded.diagnostics.withAcceptedRegions(firstDecoded.regions.count - rejectedReads.count)
                )
                recognition = value
            }
            let splitLines: [NativeCoreMLOCRLine] = []
            // Reuse low-confidence decodes from the FIRST batch for adjacent
            // punctuation continuations; this performs no additional inference.
            let anchorReads = recognition?.regions.filter {
                NativeOCRAdjacentLineRecovery.anchors($0.text)
                    || mangaSiblingRecovery && NativeOCRAdjacentLineRecovery.shortPunctuatedSibling($0.text)
                    || NativeOCRAdjacentLineRecovery.latinAnchors($0.text)
                        && NativeOCRAdjacentLineRecovery.isHorizontal($0.polygon)
            } ?? []
            let recoveryCandidates: [NativeCoreMLOCRLine] = (recovers || mangaSiblingRecovery) ? rejectedReads
                .filter { read in
                    guard !residualRetention.suppressed.contains(read.sourceIndex) else { return false }
                    guard recovers || NativeOCRAdjacentLineRecovery.shortPunctuatedSibling(read.text) else { return false }
                    return anchorReads.contains {
                        NativeOCRAdjacentLineRecovery.completes(read.text, polygon: read.polygon,
                            anchor: $0.text, anchorPolygon: $0.polygon)
                    }
                }
                .sorted { $0.sourceIndex < $1.sourceIndex }
                .map { read in
                    let latin = NativeOCRAdjacentLineRecovery.isLatinStackRow(read.text)
                    let quad = latin ? NativeOCRScopeGeometry.alternateHorizontalQuad(read.polygon) : nil
                    return NativeCoreMLOCRLine(
                        polygon: quad ?? NativeOCRScopeGeometry.canonicalQuad(read.polygon) ?? read.polygon,
                        text: read.text, score: read.confidence,
                        orientation: latin ? .horizontal : Self.orientation(for: read.polygon),
                        orientationIsEstimated: !latin,
                        erasurePolygons: detection.boxes.indices.contains(read.sourceIndex)
                            ? detection.boxes[read.sourceIndex].erasurePolygons : [],
                        detectorSeedEvidence: detection.boxes.indices.contains(read.sourceIndex)
                            ? detection.boxes[read.sourceIndex].detectorSeedEvidence.map { [$0] } : nil)
                } : []
            let isolatedLines: [NativeCoreMLOCRLine] = []
            let gapLines: [NativeCoreMLOCRGapLine] = []
            let splitMilliseconds = 0.0
            // Reconcile after all source recoveries: an earlier pass can re-add
            // a fragment that the merged first-pass column already covers.
            if let current = recognition, !rfPrimary.groups.isEmpty || !rfPrimary.refinedCrops.isEmpty {
                var removed = residualRetention.suppressed
                for group in rfPrimary.groups where !residualRetention.blockedRecovery.contains(group.index) &&
                    residualParentPolygons[group.index] == nil {
                    guard let merged = current.regions.first(where: { $0.sourceIndex == group.index }),
                          merged.confidence >= 0.65 else {
                        if !group.pointFragments.isEmpty { removed.insert(group.index) }
                        continue
                    }
                    if NativeOCRContextualColumnRecovery.borrowsRetainedGlyph(members:group.members,
                        boxes:detection.boxes,reads:current.regions,threshold:threshold,
                        retainedAliases:contextDuplicatePeers) {
                        removed.insert(group.index)
                        continue
                    }
                    let observed = current.regions.filter { group.members.contains($0.sourceIndex) }
                    if !group.pointFragments.isEmpty {
                        let words=observed.filter { !group.pointFragments.contains($0.sourceIndex) }
                        guard !words.isEmpty,words.allSatisfy({ word in
                            NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:merged.text,
                                confidence:merged.confidence,baseline:word.text,threshold:threshold,retainsOriginalSpan:true)
                        }) else { removed.insert(group.index);continue }
                    }
                    if !group.pointFragments.isEmpty,observed.contains(where:{ read in
                        group.pointFragments.contains(read.sourceIndex) &&
                            !NativeOCRRFPrimaryEnsemble.preservesAlignedFragment(candidate:merged.text,fragment:read.text,
                                confidence:merged.confidence,threshold:threshold)
                    }) {
                        removed.insert(group.index)
                        continue
                    }
                    if !group.pointFragments.isEmpty,observed.contains(where:{ read in
                        let area=NativeOCRDirectionGeometry.area(read.polygon)
                        return area > 0 && NativeOCRDirectionGeometry.intersectionArea(read.polygon,merged.polygon) < area*0.9
                    }) { removed.insert(group.index);continue }
                    let required = max(group.pointFragments.isEmpty ? 2:1, observed.reduce(0) { count, read in
                        count + read.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                    })
                    guard merged.text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= required else {
                        if !group.pointFragments.isEmpty { removed.insert(group.index) }
                        continue
                    }
                    removed.formUnion(group.members)
                }
                for crop in rfPrimary.refinedCrops where !residualRetention.blockedRecovery.contains(crop.index) &&
                    !residualRetention.blockedRecovery.contains(crop.parent) && residualParentPolygons[crop.parent] == nil {
                    guard let refined = current.regions.first(where: { $0.sourceIndex == crop.index }),
                          refined.confidence >= NativeOCRRFPrimaryEnsemble.supportedRecognitionThreshold,
                          refined.text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2,
                          let parent = current.regions.first(where: { $0.sourceIndex == crop.parent }),
                          refined.confidence > parent.confidence + 0.05 else { continue }
                    removed.insert(crop.parent)
                }
                if !removed.isEmpty {
                    let selected = current.regions.filter { !removed.contains($0.sourceIndex) }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.withAcceptedRegions(selected.count))
                    rejectedReads.removeAll { removed.contains($0.sourceIndex) }
                }
            }

            if let current = recognition, !residualRetention.suppressed.isEmpty {
                let selected = current.regions.filter { !residualRetention.suppressed.contains($0.sourceIndex) }
                recognition = .init(requestID: requestID, regions: selected,
                    diagnostics: current.diagnostics.withAcceptedRegions(selected.count))
                rejectedReads.removeAll { residualRetention.suppressed.contains($0.sourceIndex) }
            }

            func recognizedEvidence(for region: NativeCoreMLRecognizedRegion) -> [NativeOCRDetectorSeedEvidence]? {
                var seedEvidence=rfPrimary.groups.first(where: { $0.index == region.sourceIndex })?.evidence ??
                    rejectedColumnEvidence[region.sourceIndex].map { [$0] } ??
                    (shortFragmentErasurePolygons[region.sourceIndex] == nil && detection.boxes.indices.contains(region.sourceIndex)
                        ? detection.boxes[region.sourceIndex].detectorSeedEvidence.map { [$0] } : nil)
                for peer in (endpointContinuationPeers[region.sourceIndex] ?? []).union(contextDuplicatePeers[region.sourceIndex] ?? []).sorted() where detection.boxes.indices.contains(peer) {
                    let box=detection.boxes[peer]
                    guard let evidence=box.detectorSeedEvidence,
                          (contextDuplicatePeers[region.sourceIndex]?.contains(peer)==true ||
                           NativeOCRDirectionGeometry.intersectionArea(region.polygon,box.polygon) >= NativeOCRDirectionGeometry.area(box.polygon)*0.8),
                          seedEvidence?.contains(where:{ $0.ownerID==evidence.ownerID }) != true else { continue }
                    seedEvidence=(seedEvidence ?? [])+[evidence]
                }
                for owner in residualCoverageEvidence[region.sourceIndex] ?? [] where
                    seedEvidence?.contains(where: { $0.ownerID == owner.ownerID }) != true {
                    seedEvidence = (seedEvidence ?? []) + [owner]
                }
                return seedEvidence
            }
            var absorbedPointEvidence: [Int: [NativeOCRDetectorSeedEvidence]] = [:]
            if NativeOCRRFPrimaryEnsemble.refinesEndpointInk, let current = recognition, let ink = endpointInkStyles {
                let evidence = Dictionary(uniqueKeysWithValues: current.regions.compactMap { region in
                    recognizedEvidence(for: region).map { (region.sourceIndex,$0) }
                })
                let owners = NativeOCRRFPrimaryEnsemble.containedPointOwners(reads: current.regions,
                    evidence: evidence, proofs: endpointTerminalProofs, ink: ink, recognitionThreshold: threshold)
                var removed = Set<Int>()
                for (child,parent) in owners.sorted(by: { $0.key < $1.key }) where residualParentPolygons[child] == nil {
                    guard let union = NativeOCRDetectorSeedEvidence.preservingUnion([
                        absorbedPointEvidence[parent] ?? evidence[parent], evidence[child]]) else { continue }
                    absorbedPointEvidence[parent] = union
                    removed.insert(child)
                }
                if !removed.isEmpty {
                    let selected = current.regions.filter { !removed.contains($0.sourceIndex) }
                    recognition = NativeCoreMLRecognitionResult(requestID: requestID, regions: selected,
                        diagnostics: current.diagnostics.withAcceptedRegions(selected.count))
                    rejectedReads.removeAll { removed.contains($0.sourceIndex) }
                }
            }

            if NativeOCRRFPrimaryEnsemble.refinesEndpointInk,let current=recognition {
                let evidence=Dictionary(uniqueKeysWithValues:current.regions.compactMap { region in
                    (absorbedPointEvidence[region.sourceIndex] ?? recognizedEvidence(for:region)).map { (region.sourceIndex,$0) }
                })
                let aliases=NativeOCRRFPrimaryEnsemble.containedSharedSourceOwners(reads:current.regions,
                    evidence:evidence,boxes:detection.boxes,recognitionThreshold:threshold)
                for (child,parent) in aliases.sorted(by:{$0.key < $1.key}) {
                    guard let source=detection.boxes[child].detectorSeedEvidence,
                          let union=NativeOCRDetectorSeedEvidence.preservingUnion([
                            absorbedPointEvidence[parent] ?? evidence[parent],[source]]) else { continue }
                    absorbedPointEvidence[parent]=union
                }
            }

            // Unread halves of lettering units (see `NativeOCRLetteringUnitRecovery`): full frames only.
            let units = LetteringUnitOutcome()

            if let current = recognition {
                let fitted = NativeOCRBlankGrowthCorrection.changes(polygons: current.regions.map(\.polygon),
                    originals: sourceDetectionBoxes, frame: frame)
                if !fitted.isEmpty {
                    let replacements = Dictionary(uniqueKeysWithValues: fitted.map { ($0.index, $0.polygon) })
                    let corrected = current.regions.enumerated().map { index, region in
                        guard let polygon = replacements[index] else { return region }
                        return NativeCoreMLRecognizedRegion(sourceIndex: region.sourceIndex, polygon: polygon,
                            text: region.text, confidence: region.confidence, tokenObservations: region.tokenObservations)
                    }
                    recognition = .init(requestID: current.requestID, regions: corrected,
                        diagnostics: current.diagnostics)
                }
            }

            typealias GeometryOutput = NativeOCRIndividualGeometryHypotheses
            func geometryPoints(_ polygon: [CGPoint]) -> [GeometryOutput.Point] {
                polygon.map { .init(x: Double($0.x), y: Double($0.y)) }
            }
            let originalOwnerIndices = Dictionary(grouping: sourceDetectionBoxes.indices.compactMap { index in
                sourceDetectionBoxes[index].detectorSeedEvidence.map { ($0.ownerID, index) }
            }, by: { $0.0 })
            let correctedGeometry = (recognition?.regions ?? []).map { region -> GeometryOutput.Record in
                // Equality of actual detector owner IDs establishes ancestry.
                // A nearby box or a sampling rectangle never supplies it.
                let evidence = absorbedPointEvidence[region.sourceIndex] ?? recognizedEvidence(for: region)
                let verified = NativeOCRDetectorSeedEvidence.preservingUnion([evidence]) ?? []
                var members = Set<Int>()
                var complete = !verified.isEmpty
                for seed in verified {
                    guard seed.sourceWidth == frame.width, seed.sourceHeight == frame.height,
                          let indices = originalOwnerIndices[seed.ownerID], indices.count == 1 else {
                        complete = false
                        break
                    }
                    members.insert(indices[0].1)
                }
                // Partial owner sets must not masquerade as complete ancestry.
                if !complete { members.removeAll() }
                return .init(requestID: requestID, sourceIndex: region.sourceIndex,
                    sourceParent: region.sourceIndex, sourceMembers: members,
                    alternativeID: "corrected/\(region.sourceIndex)", origin: .corrected,
                    originalDetectorIndex: nil, polygon: geometryPoints(region.polygon))
            }
            let sourcePaintEnabled = NativeOCRSourcePaintGeometry.enabled
            let sourceFirstGeneration = sourcePaintEnabled && NativeOCRSourcePaintGeometry.sourceFirstGeneration
            let originalGeometry = sourceDetectionBoxes.enumerated().map { index, box in
                GeometryOutput.Record(requestID: requestID, sourceIndex: index, sourceParent: index,
                    sourceMembers: Set([index]), alternativeID: "original/\(index)", origin: .sourceOriginal,
                    originalDetectorIndex: index, polygon: geometryPoints(box.polygon))
            }
            let layoutGeometry: [GeometryOutput.Record] = sourceFirstGeneration ? [] :
                (recognition?.regions ?? []).enumerated().compactMap { index, region -> GeometryOutput.Record? in
                var prior = contextGroupingOverrides[region.sourceIndex] ?? endpointBases[region.sourceIndex]
                if let group = rfPrimary.groups.first(where: { $0.index == region.sourceIndex && !$0.pointFragments.isEmpty }),
                   let word = group.members.first, detection.boxes.indices.contains(word) {
                    prior = endpointBases[word] ?? detection.boxes[word].polygon
                }
                guard let polygon = prior else { return nil }
                let identity = correctedGeometry[index]
                return .init(requestID: requestID, sourceIndex: region.sourceIndex,
                    sourceParent: identity.sourceParent, sourceMembers: identity.sourceMembers,
                    alternativeID: "layout/\(region.sourceIndex)", origin: .sourceLayout,
                    originalDetectorIndex: nil,
                    polygon: geometryPoints(NativeOCRScopeGeometry.canonicalQuad(polygon) ?? polygon))
            }
            let geometryMode = GeometryOutput.mode()
            let closedContourEnabled = !sourceFirstGeneration && geometryMode == .sourceOriginalLayoutRefinedAndCorrectedV3 &&
                ProcessInfo.processInfo.environment["AIDOKU_OCR_CLOSED_CONTOUR_GEOMETRY"] == "1"
            let closedContourPolicyName = closedContourEnabled ?
                (ProcessInfo.processInfo.environment["AIDOKU_OCR_CLOSED_CONTOUR_POLICY"] ?? "strictOnly") : "strictOnly"
            guard let closedContourPolicy = NativeOCRSourceClosedContourGeometry.AdmissionPolicy(rawValue: closedContourPolicyName) else {
                throw NSError(domain: "NativeOCRClosedContourGeometry", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported closed contour admission policy"])
            }
            var canonicalGeometryFrame = frame
            let learnedBoundary376Enabled = !sourceFirstGeneration &&
                ProcessInfo.processInfo.environment[NativeOCRLearnedBoundaryGeometry376.environmentKey]?.isEmpty == false
            let sourceRailEnabled = NativeOCRSourceOwnedRailGeometry.enabled
            if closedContourEnabled || learnedBoundary376Enabled || sourceRailEnabled || sourcePaintEnabled || ProcessInfo.processInfo.environment[NativeOCRLearnedBoundaryGeometryV2.environmentKey]?.isEmpty == false {
                guard let image, let decoded = NativeOCRV2SourcePixelDecoder.decode(image),
                      let converted = NativeOCRRGBAFrame(width: decoded.width, height: decoded.height,
                          bytesPerRow: decoded.bytesPerRow, bytes: decoded.bytes) else {
                    throw NativeCoreMLDetectorError.imageConversionFailed
                }
                canonicalGeometryFrame = converted
            }
            let closedContourGeometry = try NativeOCRSourceClosedContourGeometry.measure(requestID: requestID,
                frame: canonicalGeometryFrame, originals: sourceDetectionBoxes, enabled: closedContourEnabled,
                policy: closedContourPolicy,
                cancellationCheck: cancellationCheck)
            let geometryRefinements: [GeometryOutput.Refinement]
            if sourceFirstGeneration {
                geometryRefinements = NativeOCRSourceFragmentGeometry.refinements(requestID: requestID,
                    originals: sourceDetectionBoxes, width: frame.width, height: frame.height)
            } else if geometryMode == .sourceOriginalLayoutRefinedAndCorrectedV3 {
                let strokeRFBounds: [NativeOCRSourceStrokeGeometry.SourceRFBound] =
                    (rfLayout?.primitives ?? []).compactMap { primitive in
                        let kind: NativeOCRSourceStrokeGeometry.RFKind
                        switch primitive.semanticClass {
                        case .text: kind = .text
                        case .soundEffect: kind = .soundEffect
                        default: return nil
                        }
                        return .init(kind: kind, bounds: primitive.sourceBounds,
                                     confidence: Double(primitive.confidence))
                    }
                let stroke = try NativeOCRSourceStrokeGeometry.produce(requestID: requestID,
                    originals: sourceDetectionBoxes, frame: frame, sourceRFBounds: strokeRFBounds,
                    enabled: ProcessInfo.processInfo.environment["AIDOKU_OCR_SOURCE_STROKE_GEOMETRY"] == "1",
                    applicability: .trainFrozenV3Pruning, cancellationCheck: cancellationCheck)
                geometryRefinements = NativeOCROwnedAxisGeometry.refinements(requestID: requestID,
                    originals: sourceDetectionBoxes, width: frame.width, height: frame.height)
                    + NativeOCRSourceFragmentGeometry.refinements(requestID: requestID,
                        originals: sourceDetectionBoxes, width: frame.width, height: frame.height)
                    + stroke.refinements + closedContourGeometry.refinements
            } else {
                geometryRefinements = []
            }
            let registeredGeometry = correctedGeometry + originalGeometry + layoutGeometry + geometryRefinements.map(\.record)
            let reservedCalibrationIndices = registeredGeometry.flatMap { [$0.sourceIndex, $0.sourceParent] } +
                sourceCalibrationObservations.map(\.index) + Array(detection.boxes.indices) +
                Array(rfPrimary.boxes.indices) + regions.map(\.sourceIndex) + firstPassRegions.map(\.sourceIndex) +
                strongRegions.map(\.sourceIndex) + rejectedReads.map(\.sourceIndex)
            var nextCalibrationIndex = reservedCalibrationIndices.max() ?? -1
            var stageSources = Set<Int>()
            let sourceCalibrationGeometry = sourceCalibrationObservations.compactMap { observation -> GeometryOutput.Record? in
                guard stageSources.insert(observation.index).inserted else { return nil }
                let next = nextCalibrationIndex.addingReportingOverflow(1)
                guard !next.overflow else { return nil }
                nextCalibrationIndex = next.partialValue
                // This is an actual earlier computed localization. Its raw-cell
                // ancestry is not reconstructed from an index or nearby quad.
                return .init(requestID: requestID, sourceIndex: nextCalibrationIndex,
                    sourceParent: observation.index, sourceMembers: [],
                    alternativeID: "source-utility435-pre-recognition/\(observation.index)", origin: .corrected,
                    originalDetectorIndex: nil, polygon: geometryPoints(observation.polygon))
            }
            let geometryEmissionPlan = GeometryOutput.producerEmissionPlan()
            let baselineIndividualGeometryOutput = GeometryOutput.emit(requestID: requestID,
                corrected: sourceFirstGeneration ? [] : correctedGeometry + sourceCalibrationGeometry,
                originals: sourceFirstGeneration ? [] : originalGeometry, layout: layoutGeometry,
                refinements: sourceFirstGeneration ? [] : geometryRefinements, mode: geometryMode, emissionPlan: geometryEmissionPlan)
            let learnedBoundary = try NativeOCRLearnedBoundaryGeometry.corrections(requestID: requestID,
                input: sourceFirstGeneration ? [] : baselineIndividualGeometryOutput.individuals, frame: frame, baselines: endpointBases,
                reservedSourceIndices: reservedCalibrationIndices + sourceCalibrationGeometry.map(\.sourceIndex))
            let sourceContext = rfLayout.map { layout in
                NativeOCRLearnedBoundaryGeometryV2.SourceContext(
                    detector: sourceDetectionBoxes.map { box in
                        .init(polygon: box.polygon.map { [Double($0.x), Double($0.y)] }, score: Double(box.score))
                    }, primitives: layout.primitives.map { primitive in
                        let bounds = primitive.sourceBounds
                        return .init(canonicalClass: primitive.semanticClass.canonicalClassID,
                            confidence: Double(primitive.confidence),
                            polygon: [[Double(bounds.minX), Double(bounds.minY)],
                                      [Double(bounds.maxX), Double(bounds.minY)],
                                      [Double(bounds.maxX), Double(bounds.maxY)],
                                      [Double(bounds.minX), Double(bounds.maxY)]])
                    }, detectorCaptureAvailable: true, rfCaptureAvailable: true)
            }
            let learnedBoundaryV2 = try NativeOCRLearnedBoundaryGeometryV2.corrections(requestID: requestID,
                input: sourceFirstGeneration ? [] : baselineIndividualGeometryOutput.individuals, frame: canonicalGeometryFrame, baselines: endpointBases,
                reservedSourceIndices: reservedCalibrationIndices + sourceCalibrationGeometry.map(\.sourceIndex)
                    + learnedBoundary.records.map(\.sourceIndex), sourceContext: sourceContext)
            var sourceFrameIdentity376 = ""
            if learnedBoundary376Enabled {
                let fingerprint = NativeOCRFrameDigestBuilder.fingerprint(of: canonicalGeometryFrame)
                sourceFrameIdentity376 = "\(fingerprint.width)x\(fingerprint.height):\(fingerprint.primary):\(fingerprint.verifier)"
            }
            let learnedBoundary376 = try NativeOCRLearnedBoundaryGeometry376.corrections(requestID: requestID,
                input: sourceFirstGeneration ? [] : baselineIndividualGeometryOutput.individuals, frame: canonicalGeometryFrame, baselines: endpointBases,
                reservedSourceIndices: reservedCalibrationIndices + sourceCalibrationGeometry.map(\.sourceIndex)
                    + (learnedBoundary.records + learnedBoundaryV2.records).map(\.sourceIndex), sourceContext: sourceContext,
                originals: sourceDetectionBoxes.map {
                    .init(polygon: $0.polygon.map { [Double($0.x), Double($0.y)] }, detectorSeedEvidence: $0.detectorSeedEvidence)
                }, actualPrecomputedRefinements: geometryRefinements,
                frameBinding: .init(operationID: requestID, sourceFrameIdentity: sourceFrameIdentity376,
                    producerRequestID: requestID, width: frame.width, height: frame.height))
            let sourceRail = try NativeOCRSourceOwnedRailGeometry.produce(requestID: requestID,
                frame: canonicalGeometryFrame,
                originals: sourceDetectionBoxes.map { .init(polygon: $0.polygon.map { [Double($0.x), Double($0.y)] }, detectorSeedEvidence: $0.detectorSeedEvidence) },
                reservedSourceIndices: reservedCalibrationIndices + sourceCalibrationGeometry.map(\.sourceIndex),
                reservedRecords: baselineIndividualGeometryOutput.individuals.flatMap(\.provenance) + geometryRefinements.map(\.record)
                    + learnedBoundary.records + learnedBoundaryV2.records + learnedBoundary376.records,
                enabledOverride: sourceFirstGeneration ? false : nil)
            let learnedBoundaryAdmission = NativeOCRLearnedBoundaryAdmission.select(requestID: requestID,
                baseline: baselineIndividualGeometryOutput.individuals, v3: learnedBoundaryV2,
                learned376: learnedBoundary376, mode: try NativeOCRLearnedBoundaryAdmission.mode())
            let learnedBoundaryRecords = learnedBoundary.records + learnedBoundaryAdmission.v3Records + learnedBoundaryAdmission.records376 + sourceRail.records
            // Independent paint appends only after admission and physical rail emission.
            let sourcePaint: NativeOCRSourcePaintGeometry.Production?
            if sourcePaintEnabled {
                // One canonical calibrator per source stage; alternative model
                // outputs and refinements never expand the pixel work list.
                let paintOriginals = NativeOCRSourcePaintGeometry.canonicalSeeds(originalGeometry,
                    records: learnedBoundary.records,
                    decisions: learnedBoundary.decisions.map { ($0.inputIndividual.provenance, $0.outputAlternativeID) })
                let paintCorrections = NativeOCRSourcePaintGeometry.canonicalSeeds(correctedGeometry,
                    records: learnedBoundaryAdmission.v3Records,
                    decisions: learnedBoundaryV2.decisions.map { ($0.inputIndividual.provenance, $0.outputAlternativeID) })
                let paintLayout = NativeOCRSourcePaintGeometry.canonicalSeeds(layoutGeometry,
                    records: learnedBoundaryAdmission.records376,
                    decisions: learnedBoundary376.decisions.map { ($0.inputIndividual.provenance, $0.outputAlternativeID) })
                sourcePaint = try NativeOCRSourcePaintGeometry.produce(requestID: requestID,
                    frame: canonicalGeometryFrame,
                    originals: sourceDetectionBoxes.map { .init(polygon: $0.polygon.map { [Double($0.x), Double($0.y)] }, detectorSeedEvidence: $0.detectorSeedEvidence) },
                    currentCorrections: paintCorrections, rf: sourceContext?.primitives ?? [],
                    reservedRecords: correctedGeometry + sourceCalibrationGeometry + originalGeometry + layoutGeometry
                        + geometryRefinements.map(\.record) + learnedBoundary.records + learnedBoundaryV2.records
                        + learnedBoundary376.records + sourceRail.records,
                    sourceGroups: geometryRefinements.filter { $0.head == .fragment }.map(\.record),
                    originalSeeds: paintOriginals, layoutScopes: paintLayout)
            } else { sourcePaint = nil }
            let sourcePaintRecords = sourcePaint?.records ?? []
            // Canonical pixel queries no longer consume an emitted candidate
            // inventory. Materialize the final union once, after paint is known.
            let finalLayoutProposals = GeometryOutput.finalLayoutProposals(layoutGeometry)
            typealias LearnedEmission = NativeOCRConditionalLearnedEmission
            func emissionQuad(_ quad: [GeometryOutput.Point]) -> LearnedEmission.Quad { quad.map { .init(x: $0.x, y: $0.y) } }
            let emissionDecisions = learnedBoundary.decisions.map { LearnedEmission.Decision(head: .legacy,
                outputAlternativeID: $0.outputAlternativeID, inputQuad: emissionQuad($0.inputQuad), chosenQuad: emissionQuad($0.chosenQuad)) }
                + learnedBoundaryV2.decisions.map { LearnedEmission.Decision(head: .v2,
                    outputAlternativeID: $0.outputAlternativeID, inputQuad: emissionQuad($0.inputQuad), chosenQuad: emissionQuad($0.chosenQuad)) }
                + learnedBoundary376.decisions.map { LearnedEmission.Decision(head: .head376,
                    outputAlternativeID: $0.outputAlternativeID, inputQuad: emissionQuad($0.inputQuad), chosenQuad: emissionQuad($0.chosenQuad)) }
            let emittedLearnedRecords = LearnedEmission.emittedRecords(learnedBoundaryRecords,
                observed: correctedGeometry + sourceCalibrationGeometry + originalGeometry + finalLayoutProposals
                    + sourcePaintRecords + sourceRail.records + geometryRefinements.filter { geometryEmissionPlan.emits($0) }.map(\.record),
                decisions: emissionDecisions, detectors: sourceDetectionBoxes.map { box in
                    .init(polygon: box.polygon.map { .init(x: Double($0.x), y: Double($0.y)) }, confidence: Double(box.score))
                })
            let sourceRecovery = NativeOCRSourcePaintGeometry.sourceFirstRecovery(
                originals: originalGeometry, current: correctedGeometry + sourcePaintRecords)
            let unscoredIndividualGeometryOutput = sourceFirstGeneration
                ? GeometryOutput.emit(requestID: requestID, corrected: correctedGeometry + sourcePaintRecords,
                    originals: sourceRecovery, layout: [], refinements: [], mode: geometryMode, emissionPlan: geometryEmissionPlan)
                : emittedLearnedRecords.isEmpty && sourcePaintRecords.isEmpty
                && finalLayoutProposals == layoutGeometry
                ? baselineIndividualGeometryOutput :
                GeometryOutput.emit(requestID: requestID,
                    corrected: correctedGeometry + sourceCalibrationGeometry + emittedLearnedRecords + sourcePaintRecords,
                    originals: originalGeometry, layout: finalLayoutProposals, refinements: geometryRefinements, mode: geometryMode, emissionPlan: geometryEmissionPlan)
            let bboxConfidenceAdmission = try NativeOCRBBoxConfidenceAdmission.apply(unscoredIndividualGeometryOutput,
                probability: primaryProbability, sourceWidth: frame.width, sourceHeight: frame.height,
                cancellationCheck: cancellationCheck)
            typealias Representatives = NativeOCRGeometryRepresentativeSelection
            let representativeContext = Representatives.Context(
                detectors: sourceDetectionBoxes.map { box in
                    .init(polygon: box.polygon.map { .init(x: Double($0.x), y: Double($0.y)) },
                          confidence: Double(box.score))
                }, recognition: (recognition?.regions ?? []).map { region in
                    .init(polygon: region.polygon.map { .init(x: Double($0.x), y: Double($0.y)) },
                          confidence: region.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : region.confidence)
                }, layout: (rfLayout?.primitives ?? []).map { primitive in
                    let b = primitive.sourceBounds
                    return .init(polygon: [.init(x: Double(b.minX), y: Double(b.minY)),
                        .init(x: Double(b.maxX), y: Double(b.minY)), .init(x: Double(b.maxX), y: Double(b.maxY)),
                        .init(x: Double(b.minX), y: Double(b.maxY))], confidence: Double(primitive.confidence),
                        semanticClass: primitive.semanticClass.canonicalClassID)
                })
            // Election precedes legacy NMS: area-ranked suppression must not
            // discard the better boundary before the quality selector sees it.
            let geometrySignalAdmission: NativeOCRGeometrySignalAdmission.Result?
            let geometryWitnessAdmission: NativeOCRGeometryWitnessAdmission.Result?
            if ProcessInfo.processInfo.environment[NativeOCRGeometryWitnessAdmission.environmentKey] == "1" {
                geometryWitnessAdmission = try NativeOCRGeometryWitnessAdmission.apply(bboxConfidenceAdmission.output,
                    cancellationCheck: cancellationCheck)
            } else { geometryWitnessAdmission = nil }
            let signalInput = geometryWitnessAdmission?.output ?? bboxConfidenceAdmission.output
            if ProcessInfo.processInfo.environment[NativeOCRGeometrySignalAdmission.environmentKey] == "1" {
                typealias Signals = NativeOCRGeometrySignalAdmission
                func signalEvidence(_ evidence: [Representatives.Evidence]) -> [Signals.Evidence] {
                    evidence.map { .init(polygon: $0.polygon, confidence: $0.confidence, semanticClass: $0.semanticClass) }
                }
                geometrySignalAdmission = try Signals.apply(signalInput,
                    context: .init(detectors: signalEvidence(representativeContext.detectors),
                        recognition: signalEvidence(representativeContext.recognition),
                        layout: signalEvidence(representativeContext.layout)), cancellationCheck: cancellationCheck)
            } else { geometrySignalAdmission = nil }
            let portfolioInput = geometrySignalAdmission?.output ?? signalInput
            let geometryPortfolioAdmission = try NativeOCRGeometryPortfolioAdmission.configured(portfolioInput,
                referenceInventory: bboxConfidenceAdmission.output, context: representativeContext)
            let representativeInput = geometryPortfolioAdmission?.output ?? portfolioInput
            let geometryRepresentatives = try Representatives.configured(representativeInput, context: representativeContext,
                referenceInventory: bboxConfidenceAdmission.output)
            let geometryDeduplication = try NativeOCRGeometryDeduplication.configured(representativeInput,
                environment: geometryRepresentatives == nil ? ProcessInfo.processInfo.environment : [:])
            let electedGeometry = geometryRepresentatives?.output ?? geometryDeduplication.output
            let geometryRFSemanticAdmission = try NativeOCRRFSemanticAdmission.configured(electedGeometry,
                grid: rfLayout?.semanticGrid, recognition: representativeContext.recognition.map {
                    .init(polygon:$0.polygon,confidence:$0.confidence)
                }, qualityScores: geometryRepresentatives.map { result in
                    result.report.keptIndices.map { result.report.scores[$0] }
                }, referenceInventory: bboxConfidenceAdmission.output, cancellationCheck:cancellationCheck)
            let rfAdmittedGeometry = geometryRFSemanticAdmission?.output ?? electedGeometry
            let geometryPhysicalPaintAdmission: NativeOCRPhysicalPaintAdmission.Result?
            if ProcessInfo.processInfo.environment[NativeOCRPhysicalPaintAdmission.environmentKey] == "1" {
                let electedScores = geometryRepresentatives.map { result in
                    result.report.keptIndices.map { result.report.scores[$0] }
                }
                let physicalScores: [Double?]? = electedScores.map { scores in
                    (geometryRFSemanticAdmission?.report.keptIndices ?? Array(electedGeometry.individuals.indices)).map {
                        scores.indices.contains($0) ? scores[$0] : nil
                    }
                }
                geometryPhysicalPaintAdmission = try NativeOCRPhysicalPaintAdmission.apply(rfAdmittedGeometry,
                    referenceInventory: bboxConfidenceAdmission.output,
                    originals: sourceDetectionBoxes.map {
                        .init(polygon: $0.polygon.map { [Double($0.x), Double($0.y)] }, detectorSeedEvidence: $0.detectorSeedEvidence)
                    }, paint: sourcePaint?.report, primitives: sourceContext?.primitives ?? [],
                    grid: rfLayout?.semanticGrid, context: representativeContext,
                    frozenQualityScores: physicalScores, cancellationCheck: cancellationCheck)
            } else { geometryPhysicalPaintAdmission = nil }
            let physicalAdmittedGeometry = geometryPhysicalPaintAdmission?.output ?? rfAdmittedGeometry
            let geometryPhysicalBoundaryModesAdmission: NativeOCRPhysicalPaintAdmission.Result?
            if ProcessInfo.processInfo.environment["AIDOKU_OCR_PHYSICAL_BOUNDARY_MODES_ADMISSION"] == "1",
               let physicalAdmission = geometryPhysicalPaintAdmission {
                let electedScores = geometryRepresentatives.map { result in
                    result.report.keptIndices.map { result.report.scores[$0] }
                }
                let boundaryScores: [Double?]? = electedScores.map { scores in
                    let rfIndices = geometryRFSemanticAdmission?.report.keptIndices ?? Array(electedGeometry.individuals.indices)
                    return physicalAdmission.report.keptIndices.map { index in
                        let sourceIndex = rfIndices[index]
                        return scores.indices.contains(sourceIndex) ? scores[sourceIndex] : nil
                    }
                }
                geometryPhysicalBoundaryModesAdmission = try NativeOCRPhysicalPaintAdmission.apply(physicalAdmittedGeometry,
                    referenceInventory: bboxConfidenceAdmission.output,
                    originals: sourceDetectionBoxes.map {
                        .init(polygon: $0.polygon.map { [Double($0.x), Double($0.y)] }, detectorSeedEvidence: $0.detectorSeedEvidence)
                    }, paint: sourcePaint?.report, primitives: sourceContext?.primitives ?? [],
                    grid: rfLayout?.semanticGrid, context: representativeContext,
                    frozenQualityScores: boundaryScores, boundaryModes: true, cancellationCheck: cancellationCheck)
            } else { geometryPhysicalBoundaryModesAdmission = nil }
            let sharedLineInput = geometryPhysicalBoundaryModesAdmission?.output ?? physicalAdmittedGeometry
            let geometrySharedLineAdmission: NativeOCRPhysicalPaintAdmission.Result?
            if let path = ProcessInfo.processInfo.environment[NativeOCRSharedLineElection.environmentKey], !path.isEmpty,
               let physicalAdmission = geometryPhysicalPaintAdmission {
                let policy = try JSONDecoder().decode(NativeOCRSharedLineElection.Policy.self,
                    from: Data(contentsOf: URL(fileURLWithPath: path)))
                let sharedScores = geometryRepresentatives.map { result -> [Double?] in
                    let scores = result.report.keptIndices.map { result.report.scores[$0] }
                    let rfIndices = geometryRFSemanticAdmission?.report.keptIndices ?? Array(electedGeometry.individuals.indices)
                    let physicalIndices = physicalAdmission.report.keptIndices
                    let boundaryIndices = geometryPhysicalBoundaryModesAdmission?.report.keptIndices
                        ?? Array(physicalAdmittedGeometry.individuals.indices)
                    return boundaryIndices.map { local in
                        let index = rfIndices[physicalIndices[local]]
                        return scores.indices.contains(index) ? scores[index] : nil
                    }
                }
                geometrySharedLineAdmission = try NativeOCRPhysicalPaintAdmission.apply(sharedLineInput,
                    referenceInventory: bboxConfidenceAdmission.output,
                    originals: sourceDetectionBoxes.map {
                        .init(polygon: $0.polygon.map { [Double($0.x), Double($0.y)] }, detectorSeedEvidence: $0.detectorSeedEvidence)
                    }, paint: sourcePaint?.report, primitives: sourceContext?.primitives ?? [],
                    grid: rfLayout?.semanticGrid, context: representativeContext, frozenQualityScores: sharedScores,
                    sharedLinePolicy: policy, cancellationCheck: cancellationCheck)
            } else { geometrySharedLineAdmission = nil }
            let individualGeometryOutput = geometrySharedLineAdmission?.output ?? sharedLineInput
            let geometryDeduplicationProof = geometryDeduplication.report
            let bboxConfidenceProof = bboxConfidenceAdmission.report
            let sourcePaintProof = sourcePaint?.finalized(actualOutput: individualGeometryOutput.individuals)
            let learnedBoundaryAdmissionProof = learnedBoundaryAdmission.finalized(actualOutput: individualGeometryOutput.individuals)
            let sourceRailProof = sourceRail.report.enabled
                ? sourceRail.finalized(actualOutput: individualGeometryOutput.individuals) : nil

            var admittedDetectorSignals: [Int: [Double]] = [:]

            // Detector evidence belongs to the accepted observation, independently
            // of whether an optional content policy was loaded successfully. The
            // final-owner and post-LLM guards must not lose DET corroboration when
            // premerge admission abstains. The fallback uses original detector
            // observations, never RF-generated crops as their own corroboration.
            let hasAdmittedPremergeEvidence = rfLayout != nil && premergeCandidateModel?.isAvailable == true
                && premergeCandidateModel?.isAdmittedSignalFilter == true
            if postprocessConfiguration == .manga, !hasAdmittedPremergeEvidence, let current = recognition {
                typealias Features = NativeOCRPremergeCandidateFeatures
                let detectors = sourceDetectionBoxes.map { box in
                    Features.DetectorBox(polygon: box.polygon.map {
                        .init(x: Double($0.x), y: Double($0.y))
                    }, score: Double(box.score))
                }
                for region in current.regions {
                    let polygon = region.polygon.map { Features.Point(x: Double($0.x), y: Double($0.y)) }
                    let baseline = endpointBases[region.sourceIndex]?.map {
                        Features.Point(x: Double($0.x), y: Double($0.y))
                    }
                    admittedDetectorSignals[region.sourceIndex] =
                        NativePostLLMContentReclassifier.detectorSignals(polygon: polygon, baseline: baseline,
                            originalDetectors: detectors, recognitionConfidence: region.confidence)
                }
            }

            // Content admission runs on completed, freshly recognized individual polygons,
            // before OCR lines enter paragraph grouping or any translation provider.
            if postprocessConfiguration == .manga, let model = premergeCandidateModel,
               model.isAvailable, model.isAdmittedSignalFilter, let current = recognition, let layout = rfLayout {
                typealias Features = NativeOCRPremergeCandidateFeatures
                func points(_ polygon: [CGPoint]) -> [Features.Point] {
                    polygon.map { .init(x: Double($0.x), y: Double($0.y)) }
                }
                let prepared = rfPrimary.boxes.map {
                    Features.DetectorBox(polygon: points($0.polygon), score: Double($0.score))
                }
                let primitives = layout.primitives.map {
                    Features.RFPrimitive(x: Double($0.sourceBounds.minX), y: Double($0.sourceBounds.minY),
                        width: Double($0.sourceBounds.width), height: Double($0.sourceBounds.height),
                        confidence: Double($0.confidence), semanticClass: $0.semanticClass.rawValue,
                        mask: $0.mask.flatMap { Features.RFMask(sourceWidth: $0.sourceWidth,
                            sourceHeight: $0.sourceHeight, side: NativeRFDETRLayoutResource.maskSide, logits: $0.logits) }, queryID: $0.queryID)
                }
                let boxFeatureRows = current.regions.map { region in
                    let polygon = points(region.polygon)
                    return Features.extract(polygon: polygon,
                        baseline: endpointBases[region.sourceIndex].map(points), detectorBoxes: prepared,
                        rfPrimitives: primitives,
                        recognition: .init(polygon: polygon, text: region.text, confidence: region.confidence),
                        signalsOnly: true)
                }
                let featureRows = current.regions.map { region in
                    let polygon = points(region.polygon)
                    return Features.extract(polygon: polygon,
                        baseline: endpointBases[region.sourceIndex].map(points), detectorBoxes: prepared,
                        rfPrimitives: primitives,
                        recognition: .init(polygon: polygon, text: region.text, confidence: region.confidence),
                        signalsOnly: true, useRFMaskOverlap: true)
                }
                // Preserve the admitted policy's calibrated evidence when that
                // policy is available; the original-DET path above is fallback.
                for (region, features) in zip(current.regions, boxFeatureRows) {
                    admittedDetectorSignals[region.sourceIndex] =
                        NativePostLLMContentReclassifier.detectorSignals(from: features)
                }
                // Missing/invalid evidence stays admitted and cannot suppress a verified peer.
                let decisions = zip(boxFeatureRows, featureRows).map { model.evaluate(boxFeatures: $0.0, maskFeatures: $0.1) }
                let selector = premergeCandidateSelection.flatMap { $0.usesOnlyFixedConfidenceAndIoU ? $0 : nil }
                var keep = selector?.select(
                    polygons: current.regions.map { points($0.polygon) }, features: featureRows,
                    content: decisions,
                    detectorProvenance: NativeOCRPremergeCandidateSelection.detectorProvenance(
                        references: current.regions.map { endpointBases[$0.sourceIndex].map(points) ?? points($0.polygon) },
                        detectorBoxes: prepared)).keep ?? decisions.map(\.keep)
                if premergeAutoPolicy?.isAvailable == true || premergeCombinationPolicy?.isAvailable == true {
                    let queries = layout.classEvidence.map { q in
                        NativeOCRPremergeSpatialEvidence.Query(x: Double(q.sourceBounds.minX), y: Double(q.sourceBounds.minY),
                            width: Double(q.sourceBounds.width), height: Double(q.sourceBounds.height),
                            probabilities: q.probabilities.map(Double.init), queryID: q.queryID)
                    }
                    let spatial = NativeOCRPremergeSpatialEvidence(width: layout.sourceWidth, height: layout.sourceHeight,
                        primitives: primitives, queries: queries)
                    let relations = NativeOCRPremergeQueryRelations(primitives: primitives, queries: queries)
                    var ownerGroups: [String: Int] = [:]
                    let observations = sourceDetectionBoxes.enumerated().map { index, box in
                        let owner = box.detectorSeedEvidence?.ownerID ?? "original-observation:\(index)"
                        if ownerGroups[owner] == nil { ownerGroups[owner] = ownerGroups.count }
                        return NativeOCRPremergeDetectorAgreement.Observation(polygon: points(box.polygon),
                            score: Double(box.score), sourceGroups: [ownerGroups[owner]!])
                    }
                    let detectorContext = NativeOCRPremergeDetectorAgreement.Context(observations: observations)
                    for (index, region) in current.regions.enumerated() where keep[index] {
                        let polygon = points(region.polygon)
                        guard let spatialRow = spatial?.extract(polygon: polygon),
                              let stats = detectorContext?.extract(polygon: polygon,
                                reference: endpointBases[region.sourceIndex].map(points)) else { continue }
                        var detectorRow = stats.featureVector
                        for i in 0..<3 { detectorRow[i] = min(detectorRow[i], 4) / 4 }
                        let supplemental = spatialRow + detectorRow
                        if premergeAutoPolicy?.rejects(features: featureRows[index], supplemental: supplemental) == true { keep[index] = false }
                        if keep[index], let joint = relations?.extract(polygon: polygon),
                           premergeCombinationPolicy?.rejects(features: featureRows[index], supplemental: supplemental + joint) == true {
                            keep[index] = false
                        }
                    }
                }
                let retained = current.regions.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
                recognition = NativeCoreMLRecognitionResult(requestID: current.requestID, regions: retained,
                    diagnostics: current.diagnostics.withAcceptedRegions(retained.count))
            }

            let latinRows = (recognition?.regions ?? []).filter {
                NativeOCRAdjacentLineRecovery.latinAnchors($0.text) &&
                    (NativeOCRDirectionGeometry.enabled("single") || NativeOCRAdjacentLineRecovery.isHorizontal($0.polygon))
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
                    let latinBasis = NativeOCRDirectionGeometry.enabled("latin") && NativeOCRScopeGeometry.isLatinWord(region.text)
                        ? (latinQuad ?? NativeOCRDirectionGeometry.directedQuad(region.polygon,longAlong:false)) : latinQuad
                    let latinLayout: BrowserOCRSourceOrientation? = latinBasis.map { q in
                        let dx = q[1].x+q[2].x-q[0].x-q[3].x
                        let dy = q[1].y+q[2].y-q[0].y-q[3].y
                        // The full baseline angle stays in q. This coarse
                        // layout hint must follow that baseline, not Latin
                        // script identity or the crop's cyclic vertex zero.
                        return abs(dx) >= abs(dy) ? .horizontal : .vertical
                    }
                    // A point continuation changes the sampled source span,
                    // not the word's independent paragraph-affinity baseline.
                    var groupingBase=contextGroupingOverrides[region.sourceIndex] ?? endpointBases[region.sourceIndex]
                    if let group=rfPrimary.groups.first(where:{ $0.index == region.sourceIndex && !$0.pointFragments.isEmpty }),
                       let word=group.members.first,detection.boxes.indices.contains(word) {
                        groupingBase=endpointBases[word] ?? detection.boxes[word].polygon
                    }
                    let seedEvidence = absorbedPointEvidence[region.sourceIndex] ?? recognizedEvidence(for: region)
                    return NativeCoreMLOCRLine(
                        polygon: recoveredHorizontal.contains(region.sourceIndex) ? region.polygon : (latinQuad ?? NativeOCRScopeGeometry.canonicalQuad(region.polygon) ?? region.polygon),
                        text: region.text,
                        score: region.confidence,
                        // Reordering a Latin crop's vertices does not establish
                        // a new paragraph flow. Rotated labels retain the
                        // original layout orientation instead of becoming rows
                        // of one screen-horizontal paragraph.
                        orientation: recoveredHorizontal.contains(region.sourceIndex) ? .horizontal : (latinLayout ?? contextGroupingOrientations[region.sourceIndex] ?? Self.orientation(
                            for: region.polygon
                        )),
                        orientationIsEstimated: true,
                        erasurePolygons: shortFragmentErasurePolygons[region.sourceIndex] ??
                            (detection.boxes.indices.contains(region.sourceIndex)
                                ? detection.boxes[region.sourceIndex].erasurePolygons : []),
                        detectorSeedEvidence: seedEvidence,
                        acceptedSource:.init(layoutPolygon:groupingBase.map { base in
                            NativeOCRScopeGeometry.isLatinWord(region.text)
                                ? (NativeOCRScopeGeometry.alternateHorizontalQuad(base) ?? base)
                                : (NativeOCRScopeGeometry.canonicalQuad(base) ?? base)
                        }, detectorSignals: admittedDetectorSignals[region.sourceIndex])
                    )
                }
                .map { NativeOCRAdjacentLineRecovery.orientingSingleLatinLetter($0, rows: latinRows) }
            let recognitionMilliseconds =
                recognition?.diagnostics.totalMilliseconds ?? 0
            try cancellationCheck()
            // Compact actual observations only. The recognizer floor means
            // accepted + rejected cannot reconstruct a raw decoded stage.
            // A budget/validation failure leaves the optional snapshot unavailable
            // without discarding successful OCR; Reader records that absence.
            let ensembleStageSnapshot = try? NativeOCREnsembleStageSnapshot.capture(
                width: detection.width, height: detection.height,
                detectionBoxes: detection.boxes,
                recognizedRegions: recognition?.regions,
                rejectedReads: recognition == nil ? nil : rejectedReads
            )
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
                unitLineCount: units.lines.count,
                ensembleStageSnapshot: ensembleStageSnapshot,
                individualGeometry: individualGeometryOutput.individuals,
                individualGeometryAdmission: learnedBoundaryAdmissionProof,
                individualGeometryRepresentatives: geometryRepresentatives?.report,
                individualGeometrySignalAdmission: geometrySignalAdmission?.report,
                individualGeometryWitnessAdmission: geometryWitnessAdmission?.report,
                individualGeometryPortfolioAdmission: geometryPortfolioAdmission?.report,
                individualGeometryRFSemanticAdmission: geometryRFSemanticAdmission?.report,
                individualGeometryPhysicalPaintAdmission: geometryPhysicalPaintAdmission?.report,
                individualGeometryPhysicalBoundaryModesAdmission: geometryPhysicalBoundaryModesAdmission?.report,
                individualGeometrySharedLineAdmission: geometrySharedLineAdmission?.report
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

    static func orientation(
        for polygon: [CGPoint]
    ) -> BrowserOCRSourceOrientation {
        if NativeOCRDirectionGeometry.enabled("orientation"), let size = NativeOCRDirectionGeometry.edgeSize(polygon) {
            return size.height >= size.width*1.25 ? .vertical : .horizontal
        }
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


/// Residual ownership must survive every later recognition fallback. Kept separate
/// from the immutable RF plan so source inventory/probability evidence is unchanged.
@available(iOS 18.0, *)
enum NativeOCRResidualRetention {
    struct State {
        let suppressed: Set<Int>
        let coverage: [Int: Set<Int>]
        let leafCoverage: [Int: Set<Int>]
        // Live parents remain eligible for recognition retries. Only the
        // consumed source identities are permanently blocked from recovery.
        var blockedRecovery: Set<Int> { suppressed }

        init(consumed: Set<Int> = [], associations: [[String: Any]] = [], groups: [Int: [Int]] = [:]) {
            var edges = groups.mapValues(Set.init)
            var roots = Set<Int>()
            for association in associations {
                guard let parent = association["parent"] as? Int, parent >= 0,
                      let members = association["members"] as? [Int], members.contains(parent) else { continue }
                let children = Set(members.filter { $0 >= 0 && $0 != parent })
                guard !children.isEmpty, children.isSubset(of: consumed) else { continue }
                edges[parent, default: []].formUnion(children)
                roots.insert(parent)
            }
            func closure(_ seeds: Set<Int>) -> Set<Int> {
                var result = seeds, pending = Array(seeds)
                while let index = pending.popLast() {
                    for child in edges[index] ?? [] where result.insert(child).inserted { pending.append(child) }
                }
                return result
            }
            // A consumed grouped child must not resurrect through one of its
            // original members. Cyclic/malformed metadata cannot hide a live root.
            let liveRoots = roots.subtracting(consumed)
            suppressed = closure(consumed).subtracting(liveRoots)
            var represented: [Int: Set<Int>] = [:], leaves: [Int: Set<Int>] = [:]
            for parent in liveRoots {
                let all = closure([parent])
                represented[parent] = all
                leaves[parent] = Set(all.filter { index in
                    groups[index] == nil || groups[index]?.contains(index) == true
                })
            }
            coverage = represented
            leafCoverage = leaves
        }

        /// Effective replay metadata, alongside separately retained original RF
        /// inventories. Coverage uses source members rather than only group IDs.
        func preparedGroups(_ original: [[String: Any]]) -> [[String: Any]] {
            var result = original.filter { row in
                guard let index = row["index"] as? Int else { return true }
                return !suppressed.contains(index)
            }
            for parent in coverage.keys.sorted() {
                let position = result.firstIndex { $0["index"] as? Int == parent }
                var row = position.map { result[$0] } ?? ["index": parent, "pointFragments": [Int](), "sourcePixelLane": false]
                row["members"] = (leafCoverage[parent] ?? []).sorted()
                row["residualCoverage"] = coverage[parent]!.sorted()
                row["residualConsumed"] = coverage[parent]!.intersection(suppressed).sorted()
                if let position { result[position] = row } else { result.append(row) }
            }
            return result
        }
    }
}
