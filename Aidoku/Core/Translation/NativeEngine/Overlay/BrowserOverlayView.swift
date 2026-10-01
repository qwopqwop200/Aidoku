// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreText
import UIKit

struct BrowserStatusAnnouncementState: Equatable, Sendable {
    private(set) var persistentSemanticIDs: Set<String> = []
    private(set) var lastTransientSemanticID: String?

    mutating func shouldAnnounce(
        _ semanticID: String,
        persistsAcrossHides: Bool = true
    ) -> Bool {
        if persistsAcrossHides {
            return persistentSemanticIDs.insert(semanticID).inserted
        }
        guard lastTransientSemanticID != semanticID else { return false }
        lastTransientSemanticID = semanticID
        return true
    }

    mutating func statusHidden() {
        lastTransientSemanticID = nil
    }

    mutating func reset() {
        persistentSemanticIDs.removeAll(keepingCapacity: true)
        lastTransientSemanticID = nil
    }
}

struct BrowserPageImageOverlayDiagnostic: Equatable, Sendable {
    enum Operation: String, Equatable, Sendable {
        case render
        case clear
    }

    enum Failure: String, Equatable, Sendable {
        case webViewUnavailable
        case javaScriptEvaluationFailed
        case malformedJavaScriptResult
        case nativeRenderingFailed
    }

    enum Outcome: Equatable, Sendable {
        case committed
        case cleared
        case stale
        case failed(Failure)
    }

    let operation: Operation
    let revision: UInt64
    let outcome: Outcome
    let renderedItemCount: Int
    var isCacheable = true
}

struct BrowserOverlayItem: Equatable, Sendable {
    /// Stable identity assigned by the temporal OCR tracker. Rendering must
    /// preserve this identity instead of treating every OCR/translation
    /// publication as a brand-new card.
    let stableRegionID: UInt64?
    let rect: CGRect
    let sourcePolygon: [CGPoint]
    let auxiliaryInkRects: [CGRect]
    let auxiliaryInkPolygons: [[CGPoint]]
    let sourceText: String
    let translatedText: String?
    let confidence: Double
    let sourceOrientation: BrowserOCRSourceOrientation
    let sourceSingleVerticalColumn: Bool?
    let translationReuseIdentity: NativeTranslationReuseIdentity?
    /// Source lettering that stays visible (see `ReaderTranslationRegion.keepsOriginalLettering`).
    /// Layout reserves its box and the overlay protects it; it is never typeset or erased.
    let keepsSourceLettering: Bool
    /// Normalized clean paper of the balloon holding only this caption (see `ReaderTranslationBalloonInterior`).
    let balloonInterior: ReaderTranslationBalloonInterior?
    /// Member OCR boxes of a joined balloon unit (image px; `rect` is their union): erasure and plate bounds.
    let unitMemberRects: [CGRect]
    /// Recovered below the OCR confidence gate (see `ReaderTranslationRegion.isRecoveredLine`).
    let recoveredLine: Bool

    init(
        stableRegionID: UInt64? = nil,
        rect: CGRect,
        sourceText: String,
        translatedText: String?,
        confidence: Double,
        sourceOrientation: BrowserOCRSourceOrientation = .unknown,
        sourceSingleVerticalColumn: Bool? = nil,
        translationReuseIdentity: NativeTranslationReuseIdentity? = nil,
        sourcePolygon: [CGPoint] = [],
        auxiliaryInkRects: [CGRect] = [],
        auxiliaryInkPolygons: [[CGPoint]] = [],
        balloonInterior: ReaderTranslationBalloonInterior? = nil,
        unitMemberRects: [CGRect] = [],
        keepsSourceLettering: Bool = false,
        recoveredLine: Bool = false
    ) {
        self.keepsSourceLettering = keepsSourceLettering
        self.recoveredLine = recoveredLine
        self.stableRegionID = stableRegionID
        self.balloonInterior = balloonInterior
        self.unitMemberRects = unitMemberRects
        self.rect = rect
        self.sourcePolygon = sourcePolygon
        self.auxiliaryInkRects = auxiliaryInkRects
        self.auxiliaryInkPolygons = auxiliaryInkPolygons
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.confidence = confidence
        self.sourceOrientation = sourceOrientation
        self.sourceSingleVerticalColumn = sourceSingleVerticalColumn
        self.translationReuseIdentity = translationReuseIdentity
    }
}

/// Stable layout order is separate from the language-aware translation order.
/// An approximate comparator can form cycles (A~B, B~C, A<C); anchor rows
/// before sorting their members so publication order cannot jitter placement.
struct BrowserOverlayItemOrdering {
    static func ordered(_ items: [BrowserOverlayItem]) -> [BrowserOverlayItem] {
        var counts: [UInt64: Int] = [:]
        for item in items { if let id = item.stableRegionID { counts[id, default: 0] += 1 } }
        let valid = items.filter { item in
            let r = item.rect
            return !r.isNull && !r.isEmpty &&
                [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite) &&
                (item.stableRegionID.map { counts[$0] == 1 } ?? true)
        }
        func tie(_ a: BrowserOverlayItem, _ b: BrowserOverlayItem) -> Bool {
            if a.rect.width != b.rect.width { return a.rect.width < b.rect.width }
            if a.rect.height != b.rect.height { return a.rect.height < b.rect.height }
            if a.stableRegionID != b.stableRegionID { return (a.stableRegionID ?? .max) < (b.stableRegionID ?? .max) }
            if a.sourceText != b.sourceText { return a.sourceText < b.sourceText }
            return (a.translatedText ?? "") < (b.translatedText ?? "")
        }
        let byY = valid.sorted {
            if $0.rect.minY != $1.rect.minY { return $0.rect.minY < $1.rect.minY }
            if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
            return tie($0, $1)
        }
        var result: [BrowserOverlayItem] = []
        var start = 0
        while start < byY.count {
            var end = start + 1
            while end < byY.count && byY[end].rect.minY <= byY[start].rect.minY + 2 { end += 1 }
            result.append(contentsOf: byY[start..<end].sorted {
                if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
                if $0.rect.minY != $1.rect.minY { return $0.rect.minY < $1.rect.minY }
                return tie($0, $1)
            })
            start = end
        }
        // Different tracker IDs may still describe the exact same painted
        // source. Collapse only exact geometry/text/orientation duplicates;
        // repeated dialogue elsewhere and competing translations remain distinct.
        struct PaintIdentity: Hashable {
            let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat
            let source: String; let translation: String?; let orientation: String
            let singleColumn: Bool?
        }
        var seen = Set<PaintIdentity>()
        return result.filter { item in
            seen.insert(PaintIdentity(x: item.rect.minX, y: item.rect.minY,
                width: item.rect.width, height: item.rect.height,
                source: item.sourceText, translation: item.translatedText,
                orientation: item.sourceOrientation.rawValue,
                singleColumn: item.sourceSingleVerticalColumn)).inserted
        }
    }
}

struct BrowserOverlayVisibility {
    static func visibleItems(
        _ items: [BrowserOverlayItem]
    ) -> [BrowserOverlayItem] {
        return items.compactMap { item in
            let sourceIsEmpty = item.sourceText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            let translationIsEmpty = item.translatedText?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ?? true
            guard !sourceIsEmpty || !translationIsEmpty else { return nil }
            let visibleItem: BrowserOverlayItem
            if translationIsEmpty, item.translatedText != nil {
                // Treat a blank provider response as untranslated so it can
                // never create an empty replacement surface.
                visibleItem = BrowserOverlayItem(
                    stableRegionID: item.stableRegionID,
                    rect: item.rect,
                    sourceText: item.sourceText,
                    translatedText: nil,
                    confidence: item.confidence,
                    sourceOrientation: item.sourceOrientation,
                    sourceSingleVerticalColumn:
                        item.sourceSingleVerticalColumn,
                    translationReuseIdentity: item.translationReuseIdentity,
                    sourcePolygon: item.sourcePolygon, auxiliaryInkRects: item.auxiliaryInkRects, auxiliaryInkPolygons: item.auxiliaryInkPolygons,
                    balloonInterior: item.balloonInterior, unitMemberRects: item.unitMemberRects,
                    keepsSourceLettering: item.keepsSourceLettering, recoveredLine: item.recoveredLine
                )
            } else {
                visibleItem = item
            }
            return visibleItem
        }
    }
}

/// Matches the established image-overlay display boundary: line grouping is
/// owned by OCR, and presentation removes only an exact repeated string in the
/// same region.
struct BrowserImageSourceOverlayConsolidator {
    static func consolidate(
        _ input: [BrowserOverlayItem]
    ) -> [BrowserOverlayItem] {
        // Preserve the c1b89c7 display-boundary contract: OCR owns text-line
        // grouping, while the presentation boundary removes only an exact
        // repeated string occupying the same region. Geometry-only joining
        // changes the recognized sentence and made upgraded capture output
        // differ from the established renderer result.
        var unique: [BrowserOverlayItem] = []
        for item in input.sorted(by: readingOrder) {
            let normalized = normalizedText(item.sourceText)
            let duplicate = unique.contains { existing in
                normalizedText(existing.sourceText) == normalized &&
                    overlapRatio(existing.rect, item.rect) >= 0.70
            }
            if !duplicate { unique.append(item) }
        }
        return unique
    }

    private static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func overlapRatio(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return 0 }
        let smallerArea = min(
            left.width * left.height,
            right.width * right.height
        )
        guard smallerArea > 0 else { return 0 }
        return intersection.width * intersection.height / smallerArea
    }

    private static func readingOrder(
        _ left: BrowserOverlayItem,
        _ right: BrowserOverlayItem
    ) -> Bool {
        if abs(left.rect.minY - right.rect.minY) > 2 {
            return left.rect.minY < right.rect.minY
        }
        return left.rect.minX < right.rect.minX
    }
}

struct BrowserSidePanelHistoryEntry: Equatable {
    let id: String
    let item: BrowserOverlayItem
}

struct BrowserOverlayLayoutCacheStatistics: Equatable {
    let hits: Int
    let misses: Int
}

struct BrowserOverlayRenderStatistics: Equatable {
    let semanticNoOp: Bool
    let usedFullLayoutFallback: Bool
    let cardUpdates: Int
    let cardFrameChanges: Int
    let intrinsicLayoutHits: Int
    let intrinsicLayoutMisses: Int
    let textMeasurementHits: Int
    let textMeasurementMisses: Int

    static let empty = Self(
        semanticNoOp: false,
        usedFullLayoutFallback: false,
        cardUpdates: 0,
        cardFrameChanges: 0,
        intrinsicLayoutHits: 0,
        intrinsicLayoutMisses: 0,
        textMeasurementHits: 0,
        textMeasurementMisses: 0
    )
}

struct BrowserOverlayTextMeasurementCacheStatistics: Equatable {
    let hits: Int
    let misses: Int
}

/// Bounded, view-owned memoization for the Core Text work shared by the
/// planner and the painted label. Exact CGFloat keys keep cached measurements
/// semantically identical to uncached UIKit measurements.
final class BrowserOverlayTextMeasurementCache {
    private struct SizeKey: Hashable {
        let variant: BrowserOverlayDisplayVariant
        let width: CGFloat
        let fontSize: CGFloat
    }

    private struct UnbrokenWidthKey: Hashable {
        let variant: BrowserOverlayDisplayVariant
        let fontSize: CGFloat
    }

    private struct MeasurementStringKey: Hashable {
        let variant: BrowserOverlayDisplayVariant
        let fontSize: CGFloat
        let primaryBreakMode: Int
        let secondaryBreakMode: Int
    }

    /// Two bounded generations: filling the current one retires the older
    /// generation only, so recently used measurements survive eviction.
    /// Values are pure functions of their keys; eviction never changes output.
    private struct TwoGenerationCache<Key: Hashable, Value> {
        let generationCapacity: Int
        private var current: [Key: Value] = [:]
        private var previous: [Key: Value] = [:]

        init(generationCapacity: Int) { self.generationCapacity = generationCapacity }

        var count: Int { current.count + previous.count }

        mutating func value(for key: Key) -> Value? {
            if let value = current[key] { return value }
            guard let value = previous.removeValue(forKey: key) else { return nil }
            insert(value, for: key)
            return value
        }

        mutating func insert(_ value: Value, for key: Key) {
            if current.count >= generationCapacity {
                previous = current
                current = Dictionary(minimumCapacity: generationCapacity)
            }
            current[key] = value
        }

        mutating func removeAll() {
            current.removeAll(keepingCapacity: true)
            previous.removeAll()
        }
    }

    private let reusesMeasurementStrings: Bool
    private var measurementStrings = TwoGenerationCache<MeasurementStringKey, NSAttributedString>(generationCapacity: 512)
    private(set) var measurementStringHits = 0

    init(reusesMeasurementStrings: Bool = true) {
        self.reusesMeasurementStrings = reusesMeasurementStrings
    }

    // Width affects measurement attributes only through the wrapping mode.
    // Reuse immutable attributes across widths without reusing measured bounds.
    func measurementString(for variant: BrowserOverlayDisplayVariant, width: CGFloat,
                           fontSize: CGFloat, calculate: () -> NSAttributedString) -> NSAttributedString {
        guard reusesMeasurementStrings else { return calculate() }
        let secondaryMode: Int
        if case .originalAndTranslation = variant.content {
            secondaryMode = variant.lineBreakMode(availableWidth: width, fontSize: max(7, fontSize * 0.64),
                                                  measurementCache: self).rawValue
        } else {
            secondaryMode = -1
        }
        let key = MeasurementStringKey(variant: variant, fontSize: fontSize,
            primaryBreakMode: variant.lineBreakMode(availableWidth: width, fontSize: fontSize,
                                                   measurementCache: self).rawValue,
            secondaryBreakMode: secondaryMode)
        if let cached = measurementStrings.value(for: key) {
            measurementStringHits += 1
            return cached
        }
        let value = NSAttributedString(attributedString: calculate())
        measurementStrings.insert(value, for: key)
        return value
    }

    // Measurements are cheap to rebuild compared with carrying an unbounded
    // session history containing translated text: at most 16K entries live.
    private var sizes = TwoGenerationCache<SizeKey, CGSize>(generationCapacity: 6_144)
    private var unbrokenWidths = TwoGenerationCache<UnbrokenWidthKey, CGFloat>(generationCapacity: 2_048)
    var entryCount: Int { sizes.count + unbrokenWidths.count }
    private(set) var passHits = 0
    private(set) var passMisses = 0

    var passStatistics: BrowserOverlayTextMeasurementCacheStatistics {
        BrowserOverlayTextMeasurementCacheStatistics(
            hits: passHits,
            misses: passMisses
        )
    }

    func beginPass() {
        passHits = 0
        passMisses = 0
    }

    func measuredSize(
        for variant: BrowserOverlayDisplayVariant,
        width: CGFloat,
        fontSize: CGFloat,
        calculate: () -> CGSize
    ) -> CGSize {
        let key = SizeKey(
            variant: variant,
            width: width,
            fontSize: fontSize
        )
        if let cached = sizes.value(for: key) {
            passHits += 1
            return cached
        }
        let measured = calculate()
        sizes.insert(measured, for: key)
        passMisses += 1
        return measured
    }

    func minimumUnbrokenWidth(
        for variant: BrowserOverlayDisplayVariant,
        fontSize: CGFloat,
        calculate: () -> CGFloat
    ) -> CGFloat {
        let key = UnbrokenWidthKey(
            variant: variant,
            fontSize: fontSize
        )
        if let cached = unbrokenWidths.value(for: key) {
            passHits += 1
            return cached
        }
        let measured = calculate()
        unbrokenWidths.insert(measured, for: key)
        passMisses += 1
        return measured
    }

    func removeAll() {
        sizes.removeAll()
        unbrokenWidths.removeAll()
        measurementStrings.removeAll()
        measurementStringHits = 0
        beginPass()
    }
}

struct BrowserOverlayPositionedCollisionDependency: Equatable {
    let key: String
    let rect: CGRect
}

struct BrowserOverlayPositionedLayoutCacheInput: Equatable {
    let source: CGRect
    let intrinsicLayout: BrowserOverlayCardLayout
    let viewport: CGSize
    let occupiedDependencies: [BrowserOverlayPositionedCollisionDependency]
    let reservedSources: [CGRect]
}

struct BrowserOverlayPositionedLayoutCache {
    private struct Record {
        let input: BrowserOverlayPositionedLayoutCacheInput
        let layout: BrowserOverlayCardLayout
    }

    private var records: [String: Record] = [:]
    private(set) var passHits = 0
    private(set) var passMisses = 0

    mutating func beginPass() {
        passHits = 0
        passMisses = 0
    }

    mutating func layout(
        for key: String,
        input: BrowserOverlayPositionedLayoutCacheInput,
        invalidated: Bool,
        calculate: () -> BrowserOverlayCardLayout
    ) -> BrowserOverlayCardLayout {
        if !invalidated,
           let record = records[key],
           record.input == input
        {
            passHits += 1
            return record.layout
        }
        let layout = calculate()
        records[key] = Record(input: input, layout: layout)
        passMisses += 1
        return layout
    }

    mutating func finishPass(retaining keys: Set<String>) {
        records = records.filter { keys.contains($0.key) }
    }

    mutating func removeAll() {
        records.removeAll(keepingCapacity: true)
        beginPass()
    }
}

struct BrowserOverlayPositionedIntrinsicLayoutCacheInput: Equatable {
    let source: CGRect
    let displayedVariant: BrowserOverlayDisplayVariant
    let settings: IPhoneOverlaySettings
    let viewport: CGSize
    let sourceVertical: Bool
    let singleVerticalColumn: Bool
}

struct BrowserOverlayPositionedIntrinsicLayoutCache {
    private struct Record {
        let input: BrowserOverlayPositionedIntrinsicLayoutCacheInput
        let layout: BrowserOverlayCardLayout
    }

    private var records: [String: Record] = [:]
    private(set) var passHits = 0
    private(set) var passMisses = 0

    mutating func beginPass() {
        passHits = 0
        passMisses = 0
    }

    mutating func layout(
        for key: String,
        input: BrowserOverlayPositionedIntrinsicLayoutCacheInput,
        invalidated: Bool,
        calculate: () -> BrowserOverlayCardLayout
    ) -> BrowserOverlayCardLayout {
        if !invalidated,
           let record = records[key],
           record.input == input
        {
            passHits += 1
            return record.layout
        }
        let layout = calculate()
        records[key] = Record(input: input, layout: layout)
        passMisses += 1
        return layout
    }

    mutating func finishPass(retaining keys: Set<String>) {
        records = records.filter { keys.contains($0.key) }
    }

    mutating func removeAll() {
        records.removeAll(keepingCapacity: true)
        beginPass()
    }
}

enum BrowserOCRInvalidationScope: Equatable {
    case display
    case session

    var clearsSidePanelSessionHistory: Bool {
        self == .session
    }
}

struct BrowserOverlayTextFlow {
    enum WrappingScript: String {
        case cjk
        case korean
        case rightToLeft
        case word
    }

    enum FontScript: String {
        case japanese
        case han
        case korean
        case rightToLeft
        case word
    }

    static func usesVerticalLayout(
        rect: CGRect,
        texts: [String]
    ) -> Bool {
        guard let source = texts.first else { return false }
        return usesVerticalSourceLayout(rect: rect, text: source)
    }

    static func usesVerticalSourceLayout(
        rect: CGRect,
        text: String,
        sourceOrientation: BrowserOCRSourceOrientation = .unknown
    ) -> Bool {
        switch sourceOrientation {
        case .vertical:
            if textPrefersVerticalWriting(text) { return true }
            // A detected vertical reaction may contain one kana plus ellipsis
            // dots misread as o/0. Its short transcription must not turn the
            // source-mask axis horizontal.
            let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
            return rect.height >= rect.width * 1.2 &&
                letters.contains { (0x3040...0x30FF).contains($0.value) } &&
                letters.allSatisfy { (0x3040...0x30FF).contains($0.value) || [48, 79, 111].contains($0.value) }
        case .horizontal:
            return false
        case .unknown:
            break
        }
        guard rect.width > 0, rect.height > 0 else { return false }
        var verticalCJKCount = 0
        var otherAlphabeticCount = 0
        var visibleCharacters = 0
        for scalar in text.unicodeScalars {
            guard scalar.properties.isAlphabetic ||
                    scalar.properties.numericType != nil
            else {
                continue
            }
            visibleCharacters += 1
            if isVerticalCJK(scalar.value) {
                verticalCJKCount += 1
            } else if scalar.properties.isAlphabetic {
                otherAlphabeticCount += 1
            }
        }
        guard visibleCharacters >= 2,
              Double(verticalCJKCount) / Double(visibleCharacters) >= 0.6
        else {
            return false
        }
        let aspectRatio = rect.height / rect.width
        let minimumAspectRatio = max(
            1.8,
            min(6, CGFloat(visibleCharacters) * 0.55)
        )
        let glyphHeightRatio =
            rect.height / CGFloat(visibleCharacters) / rect.width
        return aspectRatio >= minimumAspectRatio &&
            glyphHeightRatio >= 0.35 &&
            glyphHeightRatio <= 2.4 &&
            verticalCJKCount >= otherAlphabeticCount
    }

    static func translatedTextUsesVerticalLayout(
        sourceIsVertical: Bool,
        targetLanguage: String,
        text: String
    ) -> Bool {
        guard sourceIsVertical else { return false }
        let language = targetLanguage
            .lowercased()
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        guard ["ja", "zh", "yue"].contains(language),
              !isRightToLeft(text)
        else {
            return false
        }
        return text.unicodeScalars.contains { isCJK($0.value) }
    }

    /// Source geometry describes how OCR read the original language; it must
    /// not force the translated language into the same writing direction.
    /// Korean and other horizontal target languages remain horizontal even
    /// when PP-OCR reports one explicit Japanese vertical column. Before a
    /// translation arrives, retaining the source direction avoids a visible
    /// source-card reflow.
    static func displayedTextUsesVerticalLayout(
        item: BrowserOverlayItem,
        sourceIsVertical: Bool,
        targetLanguage: String
    ) -> Bool {
        guard let translatedText = item.translatedText else {
            return sourceIsVertical
        }
        return translatedTextUsesVerticalLayout(
            sourceIsVertical: sourceIsVertical,
            targetLanguage: targetLanguage,
            text: translatedText
        )
    }

    static func isSingleLogicalLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !text.contains(where: \.isNewline)
    }

    static func wrappingScript(for text: String) -> WrappingScript {
        if isRightToLeft(text) {
            return .rightToLeft
        }
        var verticalCJKCount = 0
        var hangulCount = 0
        var otherAlphabeticCount = 0
        for scalar in text.unicodeScalars {
            if isHangul(scalar.value) {
                hangulCount += 1
            } else if isVerticalCJK(scalar.value) {
                verticalCJKCount += 1
            } else if scalar.properties.isAlphabetic {
                otherAlphabeticCount += 1
            }
        }
        if hangulCount > 0,
           hangulCount >= verticalCJKCount,
           hangulCount >= otherAlphabeticCount
        {
            return .korean
        }
        if verticalCJKCount > 0,
           verticalCJKCount >= otherAlphabeticCount
        {
            return .cjk
        }
        return .word
    }

    static func fontScript(for text: String) -> FontScript {
        if text.unicodeScalars.contains(where: {
            switch $0.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                return true
            default:
                return false
            }
        }) {
            return .japanese
        }
        switch wrappingScript(for: text) {
        case .cjk:
            return .han
        case .korean:
            return .korean
        case .rightToLeft:
            return .rightToLeft
        case .word:
            return .word
        }
    }

    static func isRightToLeft(_ text: String) -> Bool {
        var rightToLeftCount = 0
        var otherAlphabeticCount = 0
        for scalar in text.unicodeScalars {
            if isRightToLeft(scalar.value) {
                rightToLeftCount += 1
            } else if scalar.properties.isAlphabetic {
                otherAlphabeticCount += 1
            }
        }
        return rightToLeftCount > 0 &&
            rightToLeftCount >= otherAlphabeticCount
    }

    static func verticalized(_ text: String) -> String {
        // Match the desktop vertical planner: spaces and model-inserted line
        // separators are not glyph cells. Counting Korean word spaces as rows
        // made otherwise identical text fit at a visibly smaller point size.
        text.filter { !$0.isWhitespace && !$0.isNewline }
            .map(String.init)
            .joined(separator: "\n")
    }

    static func isCJKForLayout(_ value: UInt32) -> Bool {
        isCJK(value)
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF,
             0x2E80...0x2FDF,
             0x3040...0x30FF,
             0x3130...0x318F,
             0x31F0...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xAC00...0xD7AF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func textPrefersVerticalWriting(_ text: String) -> Bool {
        var verticalCJKCount = 0
        var otherVisibleCount = 0
        for scalar in text.unicodeScalars {
            guard scalar.properties.isAlphabetic ||
                    scalar.properties.numericType != nil
            else {
                continue
            }
            if isVerticalCJK(scalar.value) {
                verticalCJKCount += 1
            } else {
                otherVisibleCount += 1
            }
        }
        let visibleCount = verticalCJKCount + otherVisibleCount
        return verticalCJKCount >= 2 &&
            verticalCJKCount >= otherVisibleCount &&
            Double(verticalCJKCount) / Double(max(1, visibleCount)) >= 0.6
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF,
             0x3130...0x318F,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private static func isVerticalCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x2E80...0x2FDF,
             0x3040...0x30FF,
             0x31A0...0x31BF,
             0x31F0...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func isRightToLeft(_ value: UInt32) -> Bool {
        switch value {
        case 0x0590...0x08FF,
             0xFB1D...0xFDFF,
             0xFE70...0xFEFF,
             0x1EE00...0x1EEFF:
            return true
        default:
            return false
        }
    }
}

/// In-memory-only history for one native-browser OCR session.
///
/// Stable segment IDs update their existing row so a translated result can
/// replace the source-only row from the same frame. Importantly, the whole
/// item is replaced: a new source-only item never inherits a translation just
/// because its text is unchanged.
struct BrowserSidePanelSessionHistory {
    static let defaultMaximumItems = 100

    let maximumItems: Int
    private(set) var entries: [BrowserSidePanelHistoryEntry] = []

    init(maximumItems: Int = Self.defaultMaximumItems) {
        self.maximumItems = max(0, maximumItems)
    }

    var items: [BrowserOverlayItem] {
        entries.map(\.item)
    }

    mutating func remember(
        _ newEntries: [BrowserSidePanelHistoryEntry]
    ) {
        guard maximumItems > 0 else {
            removeAll()
            return
        }
        for entry in newEntries {
            if let index = entries.firstIndex(where: {
                $0.id == entry.id
            }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
        if entries.count > maximumItems {
            entries.removeFirst(entries.count - maximumItems)
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}

@MainActor
final class BrowserOverlayView: UIView {
    private struct PositionedCardPresentationInput: Equatable {
        let sourceText: String
        let translatedText: String?
        let confidence: Double
        let content: BrowserOverlayCardContent
        let settings: IPhoneOverlaySettings
        let maximumFontSize: CGFloat
        let contentInsets: UIEdgeInsets
        let locale: IPhoneUILocale
    }

    private struct PositionedCardRecord {
        let card: OverlayCardView
        let item: BrowserOverlayItem
        let presentation: PositionedCardPresentationInput
    }

    private struct PositionedSegment {
        let key: String
        let item: BrowserOverlayItem
        let sourceRect: CGRect
        let sourceVertical: Bool
        let content: BrowserOverlayCardContent
    }

    private struct PositionedGeometrySignature: Equatable {
        let key: String
        let stableRegionID: UInt64
        let sourceRect: CGRect
        let sourceText: String
        let sourceOrientation: BrowserOCRSourceOrientation
        let sourceSingleVerticalColumn: Bool?
    }

    private struct PositionedLayoutContext: Equatable {
        let imageSize: CGSize
        let sourceRect: CGRect
        let settings: IPhoneOverlaySettings
        let targetLanguage: String
        let viewport: CGSize
        let locale: IPhoneUILocale
    }

    private struct PositionedRenderRequest: Equatable {
        let items: [BrowserOverlayItem]
        let context: PositionedLayoutContext
    }

    private let statusContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let statusLabel = UILabel()
    private var statusAnnouncementState = BrowserStatusAnnouncementState()
    private let itemsContainer = UIView()
    private var itemHitViews: [UIView] = []
    private var positionedCards: [String: PositionedCardRecord] = [:]
    private var viewportTransformCardFrames: [String: CGRect]?
    private var viewportTransformCardTransforms:
        [String: CGAffineTransform]?
    private var positionedLayoutCache = BrowserOverlayPositionedLayoutCache()
    private var positionedIntrinsicLayoutCache =
        BrowserOverlayPositionedIntrinsicLayoutCache()
    private let textMeasurementCache =
        BrowserOverlayTextMeasurementCache()
    private var lastPositionedRenderRequest: PositionedRenderRequest?
    private var lastPositionedGeometry: [PositionedGeometrySignature]?
    private var lastPositionedLayoutContext: PositionedLayoutContext?
    private var renderedMode: IPhoneOverlayMode?
    private var subtitleView: OverlaySubtitleView?
    private var sidePanelView: OverlaySidePanelView?
    private var isRenderingPositionedCards = false
    private var localizer = IPhoneLocalizer(locale: .korean)
    private(set) var lastLayoutCacheStatistics =
        BrowserOverlayLayoutCacheStatistics(hits: 0, misses: 0)
    private(set) var lastRenderStatistics =
        BrowserOverlayRenderStatistics.empty

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear
        accessibilityIdentifier = "aidoku.reader.overlay"

        itemsContainer.backgroundColor = .clear
        itemsContainer.accessibilityIdentifier =
            "aidoku.reader.overlay.items"
        addSubview(itemsContainer)
        addSubview(statusContainer)

        statusContainer.clipsToBounds = true
        statusContainer.layer.cornerRadius = 15
        statusContainer.accessibilityIdentifier =
            "aidoku.reader.overlay.status.container"
        statusLabel.textColor = .white
        statusLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12, weight: .semibold)
        )
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier =
            "aidoku.reader.overlay.status"
        // Updates are announced explicitly below so repeated semantic states
        // do not interrupt VoiceOver.
        statusLabel.accessibilityTraits = [.staticText]
        statusContainer.contentView.addSubview(statusLabel)

        itemsContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            itemsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            itemsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            itemsContainer.topAnchor.constraint(equalTo: topAnchor),
            itemsContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusContainer.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            statusLabel.leadingAnchor.constraint(equalTo: statusContainer.contentView.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: statusContainer.contentView.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: statusContainer.contentView.topAnchor, constant: 7),
            statusLabel.bottomAnchor.constraint(equalTo: statusContainer.contentView.bottomAnchor, constant: -7)
        ])
        hideStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        itemHitViews.contains { view in
            !view.isHidden &&
                view.alpha > 0.01 &&
                view.frame.insetBy(dx: -6, dy: -6).contains(point)
        }
    }

    func showStatus(
        _ text: String,
        isError: Bool = false,
        announcementID: String? = nil
    ) {
        statusLabel.text = text
        statusLabel.textColor = isError ? UIColor(red: 1, green: 0.78, blue: 0.80, alpha: 1) : .white
        statusContainer.isHidden = false
        // Visible counters can change on every OCR pass even though their
        // meaning has not changed. Let callers provide a stable semantic ID so
        // VoiceOver does not repeatedly interrupt itself with run numbers.
        let semanticID = announcementID ?? text
        if UIAccessibility.isVoiceOverRunning,
           statusAnnouncementState.shouldAnnounce(
               semanticID,
               persistsAcrossHides: announcementID != nil
           )
        {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    func hideStatus() {
        statusLabel.text = nil
        statusContainer.isHidden = true
        statusAnnouncementState.statusHidden()
    }

    func resetStatusAnnouncements() {
        statusAnnouncementState.reset()
    }

    func setLocale(_ locale: IPhoneUILocale) {
        guard localizer.locale != locale else { return }
        localizer = IPhoneLocalizer(locale: locale)
        resetStatusAnnouncements()
    }

    func clearItems() {
        itemsContainer.subviews.forEach { $0.removeFromSuperview() }
        itemHitViews.removeAll(keepingCapacity: true)
        positionedCards.removeAll(keepingCapacity: true)
        viewportTransformCardFrames = nil
        viewportTransformCardTransforms = nil
        positionedLayoutCache.removeAll()
        positionedIntrinsicLayoutCache.removeAll()
        textMeasurementCache.removeAll()
        lastPositionedRenderRequest = nil
        lastPositionedGeometry = nil
        lastPositionedLayoutContext = nil
        subtitleView = nil
        sidePanelView = nil
        renderedMode = nil
        isRenderingPositionedCards = false
        lastLayoutCacheStatistics = BrowserOverlayLayoutCacheStatistics(
            hits: 0,
            misses: 0
        )
        lastRenderStatistics = .empty
    }

    func render(
        _ items: [BrowserOverlayItem],
        imageSize: CGSize,
        sourceRect: CGRect,
        settings: IPhoneOverlaySettings,
        targetLanguage: String = "ko",
        invalidatingStableRegionIDs: Set<UInt64> = []
    ) {
        guard imageSize.width > 0, imageSize.height > 0 else {
            clearItems()
            return
        }
        if renderedMode != settings.mode {
            clearItems()
            renderedMode = settings.mode
        }
        switch settings.mode {
        case .translateOnly, .originalAndTranslation:
            if !isRenderingPositionedCards {
                isRenderingPositionedCards = true
            }
            renderPositionedItems(
                items,
                imageSize: imageSize,
                sourceRect: sourceRect,
                settings: settings,
                targetLanguage: targetLanguage,
                invalidatingStableRegionIDs: invalidatingStableRegionIDs
            )
        case .subtitle:
            renderSubtitle(items, settings: settings)
        case .sidePanel:
            renderSidePanel(items, settings: settings)
        }
    }

    /// Moves and scales the already-settled cards with WebKit during a
    /// viewport interaction. This path performs no OCR, translation, text
    /// fitting, line breaking, or collision planning.
    func beginViewportTransform() {
        guard viewportTransformCardFrames == nil else { return }
        viewportTransformCardFrames = positionedCards.mapValues { $0.card.frame }
        viewportTransformCardTransforms = positionedCards.mapValues {
            $0.card.transform
        }
    }

    func applyViewportTransform(
        scale: CGFloat,
        translation: CGPoint
    ) {
        guard scale.isFinite, scale > 0 else { return }
        beginViewportTransform()
        for (key, record) in positionedCards {
            guard let base = viewportTransformCardFrames?[key],
                  let baseTransform = viewportTransformCardTransforms?[key]
            else { continue }
            record.card.transform = baseTransform.scaledBy(
                x: scale,
                y: scale
            )
            record.card.center = CGPoint(
                x: base.midX * scale + translation.x,
                y: base.midY * scale + translation.y
            )
        }
    }

    private func renderPositionedItems(
        _ items: [BrowserOverlayItem],
        imageSize: CGSize,
        sourceRect: CGRect,
        settings: IPhoneOverlaySettings,
        targetLanguage: String,
        invalidatingStableRegionIDs: Set<UInt64>
    ) {
        let layoutContext = PositionedLayoutContext(
            imageSize: imageSize,
            sourceRect: sourceRect,
            settings: settings,
            targetLanguage: targetLanguage,
            viewport: bounds.size,
            locale: localizer.locale
        )
        let renderRequest = PositionedRenderRequest(
            items: items,
            context: layoutContext
        )
        if invalidatingStableRegionIDs.isEmpty,
           viewportTransformCardFrames == nil,
           lastPositionedRenderRequest == renderRequest
        {
            lastLayoutCacheStatistics = BrowserOverlayLayoutCacheStatistics(
                hits: positionedCards.count,
                misses: 0
            )
            lastRenderStatistics = BrowserOverlayRenderStatistics(
                semanticNoOp: true,
                usedFullLayoutFallback: false,
                cardUpdates: 0,
                cardFrameChanges: 0,
                intrinsicLayoutHits: 0,
                intrinsicLayoutMisses: 0,
                textMeasurementHits: 0,
                textMeasurementMisses: 0
            )
            return
        }
        positionedIntrinsicLayoutCache.beginPass()
        textMeasurementCache.beginPass()

        let scaleX = sourceRect.width / imageSize.width
        let scaleY = sourceRect.height / imageSize.height
        let stableRegionIDCounts = items.reduce(
            into: [UInt64: Int](),
            { counts, item in
                guard let stableRegionID = item.stableRegionID else { return }
                counts[stableRegionID, default: 0] += 1
            }
        )
        // A repeated temporal identity is ambiguous. Match the desktop planner:
        // exclude every occurrence instead of choosing one arbitrarily. This
        // also guarantees that no card can be created without an owning map
        // entry and survive later cleanup as an orphaned subview.
        let unambiguousItems = items.filter { item in
            guard let stableRegionID = item.stableRegionID else { return true }
            return stableRegionIDCounts[stableRegionID] == 1
        }
        let sorted = BrowserOverlayItemOrdering.ordered(unambiguousItems)
        var segments: [PositionedSegment] = sorted.enumerated().map {
            index, item in
            let sourceVertical =
                BrowserOverlayTextFlow.usesVerticalSourceLayout(
                    rect: item.rect,
                    text: item.sourceText,
                    sourceOrientation: item.sourceOrientation
                )
            let translatedVertical =
                BrowserOverlayTextFlow.displayedTextUsesVerticalLayout(
                    item: item,
                    sourceIsVertical: sourceVertical,
                    targetLanguage: targetLanguage
                )
            let content = BrowserOverlayCardContent.make(
                item: item,
                mode: settings.mode,
                sourceVertical: sourceVertical,
                translatedVertical: translatedVertical
            )
            let mappedSource = CGRect(
                x: sourceRect.minX + item.rect.minX * scaleX,
                y: sourceRect.minY + item.rect.minY * scaleY,
                width: max(1, item.rect.width * scaleX),
                height: max(1, item.rect.height * scaleY)
            )
            let key = item.stableRegionID.map {
                "region:\($0)"
            } ?? "transient:\(index):\(item.sourceText)"
            return PositionedSegment(
                key: key,
                item: item,
                sourceRect: mappedSource,
                sourceVertical: sourceVertical,
                content: content
            )
        }
        let geometry: [PositionedGeometrySignature]? = {
            guard unambiguousItems.count == items.count,
                  !segments.contains(where: { BrowserOverlayRotation.mapped(item: $0.item, imageSize: imageSize,
                      sourceRect: sourceRect, settings: settings) != nil }),
                  segments.allSatisfy({ $0.item.stableRegionID != nil })
            else {
                return nil
            }
            return segments.compactMap { segment in
                guard let stableRegionID = segment.item.stableRegionID else {
                    return nil
                }
                return PositionedGeometrySignature(
                    key: segment.key,
                    stableRegionID: stableRegionID,
                    sourceRect: segment.sourceRect,
                    sourceText: segment.item.sourceText,
                    sourceOrientation: segment.item.sourceOrientation,
                    sourceSingleVerticalColumn:
                        segment.item.sourceSingleVerticalColumn
                )
            }
        }()
        if invalidatingStableRegionIDs.isEmpty,
           let previousGeometry = lastPositionedGeometry,
           let geometry,
           let baseViewportTransformCardFrames = viewportTransformCardFrames,
           let baseViewportTransformCardTransforms =
            viewportTransformCardTransforms,
           previousGeometry.count >= geometry.count,
           !geometry.isEmpty,
           lastPositionedLayoutContext?.settings == settings,
           lastPositionedLayoutContext?.targetLanguage == targetLanguage,
           lastPositionedLayoutContext?.locale == localizer.locale
        {
            let previousByKey = Dictionary(
                uniqueKeysWithValues: previousGeometry.map { ($0.key, $0) }
            )
            let first = geometry[0]
            if let oldFirst = previousByKey[first.key],
               oldFirst.sourceRect.width > 0,
               oldFirst.sourceRect.height > 0
            {
                let scaleX = first.sourceRect.width /
                    oldFirst.sourceRect.width
                let scaleY = first.sourceRect.height /
                    oldFirst.sourceRect.height
                let scale = (scaleX + scaleY) / 2
                let translation = CGPoint(
                    x: first.sourceRect.minX -
                        oldFirst.sourceRect.minX * scale,
                    y: first.sourceRect.minY -
                        oldFirst.sourceRect.minY * scale
                )
                let tolerance: CGFloat = 1.25
                let isUniform = scale.isFinite && scale > 0 &&
                    abs(scaleX - scaleY) <= 0.01 &&
                    geometry.allSatisfy { current in
                        guard let old = previousByKey[current.key] else {
                            return false
                        }
                        let projected = CGRect(
                            x: old.sourceRect.minX * scale + translation.x,
                            y: old.sourceRect.minY * scale + translation.y,
                            width: old.sourceRect.width * scale,
                            height: old.sourceRect.height * scale
                        )
                        return abs(projected.minX - current.sourceRect.minX) <= tolerance &&
                            abs(projected.minY - current.sourceRect.minY) <= tolerance &&
                            abs(projected.width - current.sourceRect.width) <= tolerance &&
                            abs(projected.height - current.sourceRect.height) <= tolerance
                    }
                if isUniform {
                    let segmentsByKey = Dictionary(
                        uniqueKeysWithValues: segments.map { ($0.key, $0) }
                    )
                    let currentGeometryByKey = Dictionary(
                        uniqueKeysWithValues: geometry.map { ($0.key, $0) }
                    )
                    var nextCards: [String: PositionedCardRecord] = [:]
                    var nextHitViews: [UIView] = []
                    var isSemanticallyStable = true
                    for segment in segments {
                        guard let existing = positionedCards[segment.key],
                              existing.presentation.sourceText ==
                                segment.item.sourceText,
                              existing.presentation.translatedText ==
                                segment.item.translatedText,
                              existing.presentation.confidence ==
                                segment.item.confidence,
                              existing.presentation.content == segment.content
                        else {
                            isSemanticallyStable = false
                            break
                        }
                    }
                    for oldGeometry in previousGeometry {
                        guard isSemanticallyStable,
                              let existing = positionedCards[oldGeometry.key],
                              let base = baseViewportTransformCardFrames[
                                oldGeometry.key
                              ],
                              let baseTransform =
                                baseViewportTransformCardTransforms[
                                    oldGeometry.key
                                ]
                        else {
                            isSemanticallyStable = false
                            break
                        }
                        let currentSegment = segmentsByKey[oldGeometry.key]
                        let item = currentSegment?.item ?? existing.item
                        existing.card.transform = baseTransform.scaledBy(
                            x: scale,
                            y: scale
                        )
                        existing.card.center = CGPoint(
                            x: base.midX * scale + translation.x,
                            y: base.midY * scale + translation.y
                        )
                        nextCards[oldGeometry.key] = PositionedCardRecord(
                            card: existing.card,
                            item: item,
                            presentation: existing.presentation
                        )
                        nextHitViews.append(existing.card)
                    }
                    if isSemanticallyStable,
                       nextCards.count == previousGeometry.count
                    {
                        let projectedGeometry = previousGeometry.map { old in
                            if let current = currentGeometryByKey[old.key] {
                                return current
                            }
                            return PositionedGeometrySignature(
                                key: old.key,
                                stableRegionID: old.stableRegionID,
                                sourceRect: CGRect(
                                    x: old.sourceRect.minX * scale +
                                        translation.x,
                                    y: old.sourceRect.minY * scale +
                                        translation.y,
                                    width: old.sourceRect.width * scale,
                                    height: old.sourceRect.height * scale
                                ),
                                sourceText: old.sourceText,
                                sourceOrientation: old.sourceOrientation,
                                sourceSingleVerticalColumn:
                                    old.sourceSingleVerticalColumn
                            )
                        }
                        positionedCards = nextCards
                        itemHitViews = nextHitViews
                        viewportTransformCardFrames = nil
                        viewportTransformCardTransforms = nil
                        positionedLayoutCache.removeAll()
                        positionedIntrinsicLayoutCache.removeAll()
                        lastPositionedRenderRequest = renderRequest
                        lastPositionedGeometry = projectedGeometry
                        lastPositionedLayoutContext = layoutContext
                        lastLayoutCacheStatistics =
                            BrowserOverlayLayoutCacheStatistics(
                                hits: nextCards.count,
                                misses: 0
                            )
                        lastRenderStatistics = BrowserOverlayRenderStatistics(
                            semanticNoOp: false,
                            usedFullLayoutFallback: false,
                            cardUpdates: 0,
                            cardFrameChanges: nextCards.count,
                            intrinsicLayoutHits: nextCards.count,
                            intrinsicLayoutMisses: 0,
                            textMeasurementHits: 0,
                            textMeasurementMisses: 0
                        )
                        return
                    }
                }
            }
        }
        if let baseFrames = viewportTransformCardFrames {
            for (key, record) in positionedCards {
                record.card.transform = .identity
                if let base = baseFrames[key] { record.card.frame = base }
            }
            viewportTransformCardFrames = nil
            viewportTransformCardTransforms = nil
        }
        let hasPreviousLayout = lastPositionedLayoutContext != nil
        let canUseIncrementalLayout = geometry != nil &&
            lastPositionedGeometry == geometry &&
            lastPositionedLayoutContext == layoutContext
        if !canUseIncrementalLayout {
            // Geometry, ordering, style, mode-adjacent context, or transient
            // identity is ambiguous. Retain expensive text measurements, but
            // conservatively recompute every collision placement.
            positionedLayoutCache.removeAll()
        }
        // PP-OCR has already performed the canonical fragment merge and
        // pre-translation deduplication. The renderer is deliberately
        // one-region-in/one-card-out; merging translated strings here changes
        // sentence meaning and was the source of repeated price/line output.
        let sourceRects = segments.map { $0.sourceRect }
        var occupied: [BrowserOverlayPositionedCollisionDependency] = []
        var plannedLayouts = Array<BrowserOverlayCardLayout?>(
            repeating: nil,
            count: segments.count
        )
        var nextCards: [String: PositionedCardRecord] = [:]
        var nextHitViews: [UIView] = []
        var retainedLayoutKeys = Set<String>()
        var cardUpdates = 0
        var cardFrameChanges = 0
        positionedLayoutCache.beginPass()

        var intrinsicLayouts = segments.map { segment in
            let explicitlyInvalidated =
                segment.item.stableRegionID.map {
                    invalidatingStableRegionIDs.contains($0)
                } ?? false
            let intrinsicInput =
                BrowserOverlayPositionedIntrinsicLayoutCacheInput(
                    source: segment.sourceRect,
                    displayedVariant: segment.content.displayed,
                    settings: settings,
                    viewport: bounds.size,
                    sourceVertical: segment.sourceVertical,
                    singleVerticalColumn:
                        segment.content.singleVerticalColumn
                )
            retainedLayoutKeys.insert(segment.key)
            return positionedIntrinsicLayoutCache.layout(
                for: segment.key,
                input: intrinsicInput,
                invalidated: explicitlyInvalidated
            ) {
                BrowserOverlayLayoutPlanner.plan(
                    source: segment.sourceRect,
                    variants: [segment.content.displayed],
                    settings: settings,
                    viewport: bounds.size,
                    occupied: [],
                    sourceVertical: segment.sourceVertical,
                    singleVerticalColumn:
                        segment.content.singleVerticalColumn,
                    reservedSources: [],
                    measurementCache: textMeasurementCache
                )
            }
        }
        var verticalContents: [Int: BrowserOverlayCardContent] = [:]
        var verticalLayouts: [Int: BrowserOverlayCardLayout] = [:]
        for index in segments.indices {
            let segment = segments[index]
            guard let verticalContent =
                BrowserOverlayCardContent.adaptiveVerticalCandidate(
                    item: segment.item,
                    current: segment.content,
                    mode: settings.mode,
                    textPlacement: settings.textPlacement,
                    sourceVertical: segment.sourceVertical,
                    sourceRect: segment.sourceRect
                )
            else { continue }
            verticalContents[index] = verticalContent
            verticalLayouts[index] = BrowserOverlayLayoutPlanner.plan(
                source: segment.sourceRect,
                variants: [verticalContent.displayed],
                settings: settings,
                viewport: bounds.size,
                occupied: [],
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn: verticalContent.singleVerticalColumn,
                reservedSources: [],
                measurementCache: textMeasurementCache
            )
        }
        let verticalIndices =
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: intrinsicLayouts,
                verticalLayouts: verticalLayouts,
                eligibleIndices:
                    BrowserOverlayLayoutPlanner
                        .severelyDisplacedTranslationIndices(
                            intrinsicLayouts: intrinsicLayouts,
                            sources: sourceRects,
                            variants: segments.map { $0.content.displayed },
                            settings: settings,
                            viewport: bounds.size,
                            sourceVerticals: segments.map(\.sourceVertical),
                            singleVerticalColumns: segments.map {
                                $0.content.singleVerticalColumn
                            },
                            placementBounds: sourceRect,
                            allowsDetachedPlacements: segments.map {
                                $0.content.hasTranslation &&
                                    settings.mode == .translateOnly
                            }
                        )
            )
        for index in verticalIndices {
            guard let content = verticalContents[index],
                  let layout = verticalLayouts[index]
            else { continue }
            let segment = segments[index]
            segments[index] = PositionedSegment(
                key: segment.key,
                item: segment.item,
                sourceRect: segment.sourceRect,
                sourceVertical: segment.sourceVertical,
                content: content
            )
            intrinsicLayouts[index] = layout
        }
        let planningOrder = BrowserOverlayLayoutPlanner.packingOrder(
            intrinsicLayouts
        )

        for index in planningOrder {
            let segment = segments[index]
            let item = segment.item
            let mappedSource = segment.sourceRect
            // Desktop sizes the card for the text that is actually painted,
            // not for both the hidden source and the visible translation at
            // once. Reserving the envelope for a much longer hidden source
            // unnecessarily shrank short translations on iPhone.
            let visiblePlanningVariants = [
                segment.content.displayed,
            ]
            let reservedSources = sourceRects.enumerated().compactMap {
                otherIndex, rect in
                otherIndex == index ? nil : rect
            }
            let explicitlyInvalidated =
                segment.item.stableRegionID.map {
                    invalidatingStableRegionIDs.contains($0)
                } ?? false
            let intrinsicLayout = intrinsicLayouts[index]
            let occupiedDependencies =
                BrowserOverlayLayoutPlanner.collisionDependencies(
                    intrinsicLayout: intrinsicLayout,
                    source: mappedSource,
                    variants: visiblePlanningVariants,
                    settings: settings,
                    viewport: bounds.size,
                    occupied: occupied,
                    sourceVertical: segment.sourceVertical,
                    singleVerticalColumn:
                        segment.content.singleVerticalColumn
                )
            let cacheInput = BrowserOverlayPositionedLayoutCacheInput(
                source: mappedSource,
                intrinsicLayout: intrinsicLayout,
                viewport: bounds.size,
                occupiedDependencies: occupiedDependencies,
                reservedSources: reservedSources
            )
            let layout = positionedLayoutCache.layout(
                for: segment.key,
                input: cacheInput,
                invalidated: explicitlyInvalidated
            ) {
                BrowserOverlayLayoutPlanner.resolvePositionedLayout(
                    intrinsicLayout,
                    source: mappedSource,
                    variants: visiblePlanningVariants,
                    settings: settings,
                    viewport: bounds.size,
                    occupied: occupied.map(\.rect),
                    sourceVertical: segment.sourceVertical,
                    singleVerticalColumn:
                        segment.content.singleVerticalColumn,
                    reservedSources: reservedSources
                )
            }
            let mapped = layout.rect
            guard !mapped.isNull, mapped.width > 0, mapped.height > 0 else { continue }
            plannedLayouts[index] = layout
            occupied.append(BrowserOverlayPositionedCollisionDependency(
                key: segment.key,
                rect: mapped
            ))

            let presentation = PositionedCardPresentationInput(
                sourceText: item.sourceText,
                translatedText: item.translatedText,
                confidence: item.confidence,
                content: segment.content,
                settings: settings,
                maximumFontSize: layout.maximumFontSize,
                contentInsets: layout.contentInsets,
                locale: localizer.locale
            )

            let existing = positionedCards[segment.key]
            let card: OverlayCardView
            if let existing {
                card = existing.card
                if existing.presentation != presentation || existing.item.sourcePolygon != item.sourcePolygon ||
                    existing.card.transform != .identity {
                    card.update(
                        item: item,
                        content: segment.content,
                        settings: settings,
                        maximumFontSize: layout.maximumFontSize,
                        contentInsets: layout.contentInsets,
                        localizer: localizer,
                        measurementCache: textMeasurementCache
                    )
                    cardUpdates += 1
                }
            } else {
                card = OverlayCardView(
                    item: item,
                    content: segment.content,
                    settings: settings,
                    maximumFontSize: layout.maximumFontSize,
                    contentInsets: layout.contentInsets,
                    localizer: localizer,
                    measurementCache: textMeasurementCache
                )
                cardUpdates += 1
            }
            card.transform = .identity
            card.layer.mask = nil
            if card.frame != mapped {
                card.frame = mapped
                cardFrameChanges += 1
            }
            if card.superview == nil {
                itemsContainer.addSubview(card)
            } else {
                itemsContainer.bringSubviewToFront(card)
            }
            nextHitViews.append(card)
            nextCards[segment.key] = PositionedCardRecord(
                card: card,
                item: item,
                presentation: presentation
            )
        }
        let concreteLayouts = plannedLayouts.compactMap { $0 }
        if concreteLayouts.count == plannedLayouts.count {
            let relaxed = BrowserOverlayLayoutPlanner.restoringSourceCoverage(
                BrowserOverlayLayoutPlanner.relaxingCardPositions(
                concreteLayouts,
                sources: sourceRects,
                sourceVerticals: segments.map(\.sourceVertical),
                viewport: bounds.size,
                placementBounds: sourceRect,
                preferredRects: intrinsicLayouts.map(\.rect),
                allowsDetachedPlacements: segments.map {
                    $0.content.hasTranslation &&
                        settings.mode == .translateOnly
                }
                ),
                sources: sourceRects,
                bounds: sourceRect,
                enabled: settings.mode == .translateOnly && settings.textPlacement == .replace
            )
            for index in relaxed.indices {
                guard let record = nextCards[segments[index].key] else {
                    continue
                }
                let relaxedFrame = relaxed[index].rect
                if record.card.frame != relaxedFrame {
                    record.card.frame = relaxedFrame
                    cardFrameChanges += 1
                }
            }
        }
        for (key, record) in positionedCards where nextCards[key] == nil {
            record.card.removeFromSuperview()
        }
        // Match the reader DOM path. The ordinary placement pass still reserves
        // the source footprint for neighbors; rotation stays inside that quad.
        for segment in segments {
            guard let record = nextCards[segment.key],
                  let rotation = BrowserOverlayRotation.mapped(item: segment.item, imageSize: imageSize,
                      sourceRect: sourceRect, settings: settings),
                  let layout = BrowserOverlayRotation.layout(geometry: rotation, variant: segment.content.displayed,
                      maximumFontSize: BrowserOverlayRotation.maximumFontSize(geometry: rotation, sourceText: segment.item.sourceText,
                                                                              planned: record.presentation.maximumFontSize),
                      plannedFontSize: record.presentation.maximumFontSize,
                      obstacles: segments.compactMap { $0.key == segment.key ? nil : $0.sourceRect },
                      measurementCache: textMeasurementCache) else { continue }
            record.card.update(item: segment.item, content: segment.content, settings: settings,
                maximumFontSize: layout.maximumFontSize, contentInsets: layout.contentInsets,
                localizer: localizer, measurementCache: textMeasurementCache)
            record.card.bounds = CGRect(origin: .zero, size: layout.rect.size)
            record.card.center = CGPoint(x: layout.rect.midX, y: layout.rect.midY)
            // A column tilted only by detector noise is set upright in the same
            // box; its plate is clipped to the quad grown by the plate margin.
            let upright = BrowserOverlayRotation.setsUprightInQuad(rotation, sourceVertical: segment.sourceVertical,
                                                                   translatedVertical: segment.content.displayed.vertical)
            let angle = upright ? 0 : rotation.radians
            record.card.transform = CGAffineTransform(rotationAngle: angle)
            let mask = CAShapeLayer()
            mask.frame = record.card.bounds
            let path = CGMutablePath()
            var corners = [CGPoint(x: sourceRect.minX, y: sourceRect.minY), CGPoint(x: sourceRect.maxX, y: sourceRect.minY),
                           CGPoint(x: sourceRect.maxX, y: sourceRect.maxY), CGPoint(x: sourceRect.minX, y: sourceRect.maxY)]
            if upright { corners = BrowserOverlayRotation.clipped(corners, toQuad: rotation) }
            let c = cos(angle), s = sin(angle)
            let local = corners.map { point -> CGPoint in
                let x = point.x - layout.rect.midX, y = point.y - layout.rect.midY
                return CGPoint(x: x * c + y * s + layout.rect.width / 2,
                               y: -x * s + y * c + layout.rect.height / 2)
            }
            path.addLines(between: local); path.closeSubpath()
            mask.path = path; record.card.layer.mask = mask
        }
        positionedCards = nextCards
        itemHitViews = nextHitViews
        positionedLayoutCache.finishPass(retaining: retainedLayoutKeys)
        positionedIntrinsicLayoutCache.finishPass(
            retaining: retainedLayoutKeys
        )
        lastLayoutCacheStatistics = BrowserOverlayLayoutCacheStatistics(
            hits: positionedLayoutCache.passHits,
            misses: positionedLayoutCache.passMisses
        )
        let measurementStatistics = textMeasurementCache.passStatistics
        lastRenderStatistics = BrowserOverlayRenderStatistics(
            semanticNoOp: false,
            usedFullLayoutFallback:
                hasPreviousLayout && !canUseIncrementalLayout,
            cardUpdates: cardUpdates,
            cardFrameChanges: cardFrameChanges,
            intrinsicLayoutHits:
                positionedIntrinsicLayoutCache.passHits,
            intrinsicLayoutMisses:
                positionedIntrinsicLayoutCache.passMisses,
            textMeasurementHits: measurementStatistics.hits,
            textMeasurementMisses: measurementStatistics.misses
        )
        lastPositionedRenderRequest = renderRequest
        lastPositionedGeometry = geometry
        lastPositionedLayoutContext = layoutContext
    }

    private func renderSubtitle(
        _ items: [BrowserOverlayItem],
        settings: IPhoneOverlaySettings
    ) {
        let text = items.compactMap { item -> String? in
            let value = item.translatedText ?? item.sourceText
            return value.isEmpty ? nil : value
        }.joined(separator: "  ")
        guard !text.isEmpty else {
            subtitleView?.removeFromSuperview()
            subtitleView = nil
            itemHitViews.removeAll(keepingCapacity: true)
            return
        }

        let sourceText = items.map(\.sourceText).joined(separator: "  ")
        let subtitle: OverlaySubtitleView
        if let existing = subtitleView {
            subtitle = existing
            subtitle.update(
                text: text,
                sourceText: sourceText,
                settings: settings,
                localizer: localizer
            )
        } else {
            subtitle = OverlaySubtitleView(
                text: text,
                sourceText: sourceText,
                settings: settings,
                localizer: localizer
            )
            subtitleView = subtitle
            itemsContainer.addSubview(subtitle)
        }
        let height = CGFloat(settings.subtitleMaxLines == 1 ? 54 : 86)
        let inset: CGFloat = 12
        let y = settings.subtitlePosition == .top
            ? safeAreaInsets.top + 44
            : bounds.height - safeAreaInsets.bottom - height - 12
        subtitle.frame = CGRect(
            x: inset,
            y: max(inset, y),
            width: max(1, bounds.width - inset * 2),
            height: height
        ).intersection(bounds)
        itemHitViews = [subtitle]
    }

    private func renderSidePanel(
        _ items: [BrowserOverlayItem],
        settings: IPhoneOverlaySettings
    ) {
        guard !items.isEmpty else {
            sidePanelView?.removeFromSuperview()
            sidePanelView = nil
            itemHitViews.removeAll(keepingCapacity: true)
            return
        }
        let width = min(max(190, bounds.width * 0.52), bounds.width - 16)
        let panel: OverlaySidePanelView
        if let existing = sidePanelView {
            panel = existing
            panel.update(
                items: items,
                settings: settings,
                localizer: localizer
            )
        } else {
            panel = OverlaySidePanelView(
                items: items,
                settings: settings,
                localizer: localizer
            )
            sidePanelView = panel
            itemsContainer.addSubview(panel)
        }
        panel.frame = CGRect(
            x: bounds.width - width - 8,
            y: safeAreaInsets.top + 44,
            width: width,
            height: max(80, bounds.height - safeAreaInsets.top -
                safeAreaInsets.bottom - 100)
        ).intersection(bounds)
        itemHitViews = [panel]
    }

}

struct BrowserOverlayPresentationSegment: Equatable {
    let sourceRect: CGRect
    let sourceText: String
    let translatedText: String?
    let confidence: Double
    let sourceVertical: Bool
    let translatedVertical: Bool
    let displayVertical: Bool
}

struct BrowserOverlayPresentationGroup: Equatable {
    let segments: [BrowserOverlayPresentationSegment]

    var sourceRects: [CGRect] {
        segments.map(\.sourceRect)
    }

    var sourceBounds: CGRect {
        sourceRects.dropFirst().reduce(sourceRects.first ?? .null) {
            $0.union($1)
        }
    }

    var sourceVertical: Bool {
        segments.count == 1 && segments[0].sourceVertical
    }

    var translatedVertical: Bool {
        segments.count == 1 && segments[0].translatedVertical
    }

    var displayVertical: Bool {
        segments.count == 1 && segments[0].displayVertical
    }

    var overlayItem: BrowserOverlayItem {
        let translations = segments.compactMap(\.translatedText)
        let translation = translations.count == segments.count
            ? Self.joinWrappedLines(translations)
            : nil
        return BrowserOverlayItem(
            rect: sourceBounds,
            sourceText: segments.map(\.sourceText).joined(separator: "\n"),
            translatedText: translation,
            confidence: segments.reduce(0) { $0 + $1.confidence } /
                Double(max(1, segments.count)),
            sourceOrientation: sourceVertical ? .vertical : .horizontal
        )
    }

    private static func joinWrappedLines(_ lines: [String]) -> String {
        lines.reduce(into: "") { result, line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if result.isEmpty {
                result = value
            } else if result.last == "-" {
                result.removeLast()
                result += value
            } else if value.first?.isPunctuation == true {
                result += value
            } else {
                result += " " + value
            }
        }
    }
}

struct BrowserOverlayPresentationGrouper {
    static func groups(
        _ segments: [BrowserOverlayPresentationSegment]
    ) -> [BrowserOverlayPresentationGroup] {
        let sorted = BrowserOverlayPresentationDeduplicator
            .deduplicate(segments)
            .sorted {
            if abs($0.sourceRect.minY - $1.sourceRect.minY) > 2 {
                return $0.sourceRect.minY < $1.sourceRect.minY
            }
            return $0.sourceRect.minX < $1.sourceRect.minX
        }
        var result: [[BrowserOverlayPresentationSegment]] = []
        for segment in sorted {
            let candidates = result.indices.filter {
                canAppend(segment, to: result[$0])
            }
            if let index = candidates.min(by: {
                groupingDistance(segment, from: result[$0]) <
                    groupingDistance(segment, from: result[$1])
            }) {
                result[index].append(segment)
            } else {
                result.append([segment])
            }
        }
        return result.map(BrowserOverlayPresentationGroup.init)
    }

    private static func canAppend(
        _ segment: BrowserOverlayPresentationSegment,
        to group: [BrowserOverlayPresentationSegment]
    ) -> Bool {
        guard let previous = group.max(by: {
            $0.sourceRect.maxY < $1.sourceRect.maxY
        }),
              !segment.sourceVertical,
              !previous.sourceVertical,
              (segment.translatedText != nil) ==
                (previous.translatedText != nil)
        else {
            return false
        }
        let current = segment.sourceRect
        let last = previous.sourceRect
        let verticalOverlap = min(current.maxY, last.maxY) -
            max(current.minY, last.minY)
        if verticalOverlap >= min(current.height, last.height) * 0.45 {
            let gap = max(
                0,
                max(current.minX, last.minX) -
                    min(current.maxX, last.maxX)
            )
            return gap <= max(12, min(current.height, last.height))
        }

        let verticalGap = current.minY - last.maxY
        guard verticalGap >= -min(current.height, last.height) * 0.2,
              verticalGap <= max(10, min(current.height, last.height) * 0.7)
        else {
            return false
        }
        let widthRatio = min(current.width, last.width) /
            max(1, max(current.width, last.width))
        let leadingTolerance = max(
            10,
            min(current.width, last.width) * 0.18
        )
        guard widthRatio >= 0.55,
              abs(current.minX - last.minX) <= leadingTolerance
        else {
            return false
        }
        let bounds = group.dropFirst().reduce(
            group.first?.sourceRect ?? .null
        ) { $0.union($1.sourceRect) }
        let combined = bounds.union(current)
        let widest = max(
            current.width,
            group.map { $0.sourceRect.width }.max() ?? 0
        )
        return combined.width <= widest * 1.35
    }

    private static func groupingDistance(
        _ segment: BrowserOverlayPresentationSegment,
        from group: [BrowserOverlayPresentationSegment]
    ) -> CGFloat {
        guard let last = group.max(by: {
            $0.sourceRect.maxY < $1.sourceRect.maxY
        }) else {
            return .greatestFiniteMagnitude
        }
        let dx = segment.sourceRect.minX - last.sourceRect.minX
        let dy = segment.sourceRect.minY - last.sourceRect.maxY
        return dx * dx + dy * dy
    }
}

struct BrowserOverlayPresentationDeduplicator {
    static func deduplicate(
        _ segments: [BrowserOverlayPresentationSegment]
    ) -> [BrowserOverlayPresentationSegment] {
        var result: [BrowserOverlayPresentationSegment] = []
        for segment in segments {
            guard let index = result.firstIndex(where: {
                isDuplicate(segment, of: $0)
            }) else {
                result.append(segment)
                continue
            }
            if prefers(segment, over: result[index]) {
                result[index] = segment
            }
        }
        return result
    }

    private static func isDuplicate(
        _ left: BrowserOverlayPresentationSegment,
        of right: BrowserOverlayPresentationSegment
    ) -> Bool {
        let intersection = left.sourceRect.intersection(right.sourceRect)
        guard !intersection.isNull else { return false }
        let smallerArea = min(
            left.sourceRect.width * left.sourceRect.height,
            right.sourceRect.width * right.sourceRect.height
        )
        guard smallerArea > 0,
              intersection.width * intersection.height / smallerArea >= 0.78,
              related(left.sourceText, right.sourceText),
              relatedTranslations(left.translatedText, right.translatedText)
        else {
            return false
        }
        return true
    }

    private static func relatedTranslations(
        _ left: String?,
        _ right: String?
    ) -> Bool {
        switch (left, right) {
        case (.none, .none):
            return true
        case let (.some(left), .some(right)):
            return related(left, right)
        default:
            return false
        }
    }

    private static func related(_ left: String, _ right: String) -> Bool {
        let left = normalized(left)
        let right = normalized(right)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let shorter = left.count < right.count ? left : right
        let longer = left.count < right.count ? right : left
        return shorter.count >= 3 && longer.contains(shorter)
    }

    private static func prefers(
        _ left: BrowserOverlayPresentationSegment,
        over right: BrowserOverlayPresentationSegment
    ) -> Bool {
        let leftLength = normalized(left.sourceText).count +
            normalized(left.translatedText ?? "").count
        let rightLength = normalized(right.sourceText).count +
            normalized(right.translatedText ?? "").count
        if leftLength != rightLength {
            return leftLength > rightLength
        }
        if abs(left.confidence - right.confidence) > 0.0001 {
            return left.confidence > right.confidence
        }
        let leftArea = left.sourceRect.width * left.sourceRect.height
        let rightArea = right.sourceRect.width * right.sourceRect.height
        return leftArea < rightArea
    }

    private static func normalized(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars where
            scalar.properties.isAlphabetic ||
            scalar.properties.numericType != nil
        {
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

/// Fonts for overlay measurement at arbitrary fractional sizes.
/// UIKit keeps every `systemFont(ofSize:weight:)` / `UIFont(name:size:)` instance, with its
/// TextKit and Core Text caches (~100 KB per size), for the life of the process, and font
/// fitting visits dozens of new sizes per page. The same fonts created through Core Text
/// (identical descriptor, metrics and layout) are released with their last reference; a small
/// two-generation cache keeps the sizes of the current fit warm.
enum BrowserOverlayFont {
    private static let usages: [CGFloat: String] = [
        UIFont.Weight.regular.rawValue: "CTFontRegularUsage",
        UIFont.Weight.medium.rawValue: "CTFontMediumUsage",
        UIFont.Weight.semibold.rawValue: "CTFontDemiUsage",
        UIFont.Weight.bold.rawValue: "CTFontBoldUsage",
        UIFont.Weight.heavy.rawValue: "CTFontHeavyUsage",
        UIFont.Weight.black.rawValue: "CTFontBlackUsage"
    ]
    nonisolated(unsafe) private static let descriptors: [CGFloat: CTFontDescriptor] = usages.mapValues {
        CTFontDescriptorCreateWithAttributes(["NSCTFontUIUsageAttribute": $0] as CFDictionary)
    }
    private struct Key: Hashable {
        let name: String?
        let weight: CGFloat
        let size: CGFloat
    }
    private static let lock = NSLock()
    private static let generationCapacity = 64
    nonisolated(unsafe) private static var current: [Key: UIFont] = [:]
    nonisolated(unsafe) private static var previous: [Key: UIFont] = [:]

    private static func cached(_ key: Key, create: () -> UIFont?) -> UIFont? {
        lock.lock()
        if let font = current[key] { lock.unlock(); return font }
        if let font = previous[key] {
            store(font, key)
            lock.unlock()
            return font
        }
        lock.unlock()
        guard let font = create() else { return nil }
        lock.lock()
        store(font, key)
        lock.unlock()
        return font
    }

    private static func store(_ font: UIFont, _ key: Key) {
        if current.count >= generationCapacity {
            previous = current
            current = Dictionary(minimumCapacity: generationCapacity)
        }
        current[key] = font
    }

    /// Same font as `UIFont.systemFont(ofSize:weight:)`.
    static func system(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        guard let descriptor = descriptors[weight.rawValue], size.isFinite, size > 0 else {
            return .systemFont(ofSize: size, weight: weight)
        }
        return cached(Key(name: nil, weight: weight.rawValue, size: size)) {
            CTFontCreateWithFontDescriptor(descriptor, size, nil) as UIFont
        } ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Same font as `UIFont(name:size:)`, including nil for a missing face.
    static func named(_ name: String, size: CGFloat) -> UIFont? {
        guard size.isFinite, size > 0 else { return UIFont(name: name, size: size) }
        return cached(Key(name: name, weight: 0, size: size)) {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            // Core Text substitutes a fallback face for unknown names; UIKit returns nil.
            return CTFontCopyPostScriptName(font) as String == name ? font as UIFont : nil
        }
    }
}

enum BrowserOverlayDOMTypography {
    /// c1's Korean CSS stack starts with Apple SD Gothic Neo and paints a
    /// horizontal translated card at weight 700. Use the same face for the
    /// final native glyph pass without feeding its metrics back into layout.
    static func font(
        for text: String,
        pointSize: CGFloat,
        weight: UIFont.Weight
    ) -> UIFont {
        guard BrowserOverlayTextFlow.fontScript(for: text) == .korean else {
            return BrowserOverlayFont.system(ofSize: pointSize, weight: weight)
        }
        let postScriptName: String
        if weight.rawValue >= UIFont.Weight.heavy.rawValue {
            postScriptName = "AppleSDGothicNeo-ExtraBold"
        } else if weight.rawValue >= UIFont.Weight.bold.rawValue {
            postScriptName = "AppleSDGothicNeo-Bold"
        } else if weight.rawValue >= UIFont.Weight.semibold.rawValue {
            postScriptName = "AppleSDGothicNeo-SemiBold"
        } else if weight.rawValue >= UIFont.Weight.medium.rawValue {
            postScriptName = "AppleSDGothicNeo-Medium"
        } else {
            postScriptName = "AppleSDGothicNeo-Regular"
        }
        return BrowserOverlayFont.named(postScriptName, size: pointSize) ??
            BrowserOverlayFont.system(ofSize: pointSize, weight: weight)
    }
}

struct BrowserOverlayDisplayVariant: Equatable, Hashable {
    enum Content: Equatable, Hashable {
        case plain(String)
        case originalAndTranslation(
            source: String,
            translation: String,
            separator: String
        )
    }

    let content: Content
    let vertical: Bool

    static func plain(_ text: String, vertical: Bool) -> Self {
        Self(content: .plain(text), vertical: vertical)
    }

    var displayText: String {
        switch content {
        case let .plain(text):
            text
        case let .originalAndTranslation(source, translation, separator):
            source + separator + translation
        }
    }

    func attributedString(
        fontSize: CGFloat,
        foregroundColor: UIColor? = nil,
        secondaryForegroundColor: UIColor? = nil,
        textShadow: NSShadow? = nil,
        availableWidth: CGFloat? = nil,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil,
        usesDOMFontFamily: Bool = false
    ) -> NSAttributedString {
        func attributes(
            scriptText: String,
            pointSize: CGFloat,
            weight: UIFont.Weight,
            color: UIColor?,
            includesTextShadow: Bool
        ) -> [NSAttributedString.Key: Any] {
            let planningFont = BrowserOverlayFont.system(
                ofSize: pointSize,
                weight: weight
            )
            let font = usesDOMFontFamily
                ? BrowserOverlayDOMTypography.font(
                    for: scriptText,
                    pointSize: pointSize,
                    weight: weight
                )
                : planningFont
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = lineBreakMode(
                availableWidth: availableWidth,
                fontSize: pointSize,
                measurementCache: measurementCache
            )
            paragraph.lineBreakStrategy = [.standard, .hangulWordPriority]
            paragraph.alignment = .center
            // Horizontal cards must reserve UIKit's real font line height.
            // A point-size multiplier can be shorter than the current SF font
            // metrics, so the planner approves a card that UILabel later clips.
            // Explicit vertical columns intentionally keep one glyph per point-
            // size cell; their compact column spacing is a separate contract.
            // c1 plans geometry with the system font, then paints Korean with
            // Apple SD Gothic Neo while retaining the planned CSS line-height
            // ratio. Keeping those responsibilities separate preserves every
            // existing card frame while matching the DOM painter's glyphs.
            let lineHeight = vertical ? pointSize : planningFont.lineHeight
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            var result: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph,
                .kern: pointSize * -0.012,
            ]
            if let color {
                result[.foregroundColor] = color
            }
            if includesTextShadow, let textShadow {
                result[.shadow] = textShadow
            }
            return result
        }

        switch content {
        case let .plain(text):
            return NSAttributedString(
                string: text,
                attributes: attributes(
                    scriptText: text,
                    pointSize: fontSize,
                    weight: vertical ? .heavy : .bold,
                    color: foregroundColor,
                    includesTextShadow: true
                )
            )
        case let .originalAndTranslation(source, translation, separator):
            let result = NSMutableAttributedString()
            let sourceFontSize = max(7, fontSize * 0.64)
            result.append(NSAttributedString(
                string: source,
                attributes: attributes(
                    scriptText: source,
                    pointSize: sourceFontSize,
                    weight: .medium,
                    color: secondaryForegroundColor ?? foregroundColor,
                    includesTextShadow: false
                )
            ))
            result.append(NSAttributedString(
                string: separator,
                attributes: attributes(
                    scriptText: source,
                    pointSize: sourceFontSize,
                    weight: .medium,
                    color: secondaryForegroundColor ?? foregroundColor,
                    includesTextShadow: false
                )
            ))
            result.append(NSAttributedString(
                string: translation,
                attributes: attributes(
                    scriptText: translation,
                    pointSize: fontSize,
                    weight: .bold,
                    color: foregroundColor,
                    includesTextShadow: true
                )
            ))
            return result
        }
    }

    func measuredSize(
        width: CGFloat,
        fontSize: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> CGSize {
        guard width > 0, fontSize > 0 else { return .zero }
        let calculate = { () -> CGSize in
            let makeString = {
                attributedString(fontSize: fontSize, availableWidth: width, measurementCache: measurementCache)
            }
            let string = measurementCache?.measurementString(for: self, width: width, fontSize: fontSize,
                                                              calculate: makeString) ?? makeString()
            let measured = string.boundingRect(
                with: CGSize(
                    width: width,
                    height: .greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            return CGSize(
                width: ceil(measured.width),
                height: ceil(measured.height)
            )
        }
        guard let measurementCache else { return calculate() }
        return measurementCache.measuredSize(
            for: self,
            width: width,
            fontSize: fontSize,
            calculate: calculate
        )
    }

    func fits(
        available: CGSize,
        fontSize: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> Bool {
        guard available.width > 0, available.height > 0 else {
            return false
        }
        // The planner's vertical compatibility string has one explicit line per
        // glyph. Measuring thousands of forced lines at unbounded height makes
        // UIKit repeatedly shape the remaining string. Mandatory line advances
        // alone can prove non-fit without changing fonts, geometry or the text.
        // Ignore the first/last line extents, so this remains a lower bound.
        if case let .plain(text) = content {
            let minimumAdvance = vertical ? fontSize : BrowserOverlayFont.system(ofSize: fontSize, weight: .bold).lineHeight
            if minimumAdvance > 0 {
                var forcedAdvance: CGFloat = 0
                for scalar in text.unicodeScalars where scalar.value == 10 {
                    forcedAdvance += minimumAdvance
                    if forcedAdvance > available.height + 0.5 { return false }
                }
            }
        }
        let measured = measuredSize(
            width: available.width,
            fontSize: fontSize,
            measurementCache: measurementCache
        )
        return measured.width <= available.width + 0.5 &&
            measured.height <= available.height + 0.5
    }

    func minimumUnbrokenWidth(
        fontSize: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> CGFloat {
        let calculate = { () -> CGFloat in
            switch content {
            case let .plain(text):
                return Self.minimumUnbrokenWidth(
                    text,
                    fontSize: fontSize,
                    weight: vertical ? .heavy : .bold
                )
            case let .originalAndTranslation(source, translation, _):
                return max(
                    Self.minimumUnbrokenWidth(
                        source,
                        fontSize: max(7, fontSize * 0.64),
                        weight: .medium
                    ),
                    Self.minimumUnbrokenWidth(
                        translation,
                        fontSize: fontSize,
                        weight: .bold
                    )
                )
            }
        }
        guard let measurementCache else { return calculate() }
        return measurementCache.minimumUnbrokenWidth(
            for: self,
            fontSize: fontSize,
            calculate: calculate
        )
    }

    /// A whole Korean utterance must not stay microscopic merely because
    /// shrinking it made one long token fit on a single line. The final DOM
    /// guard still owns glyph containment, obstacles and punctuation.
    func allowsEmergencyKoreanWordBreak(at referenceFont: CGFloat) -> Bool {
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !vertical && referenceFont < 8 && text.count >= 10 && text.count <= 180 &&
            !text.contains(where: \.isWhitespace) &&
            BrowserOverlayTextFlow.wrappingScript(for: text) == .korean
    }

    func lineBreakMode(
        availableWidth: CGFloat?,
        fontSize: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> NSLineBreakMode {
        guard let availableWidth, availableWidth > 0,
              minimumUnbrokenWidth(
                  fontSize: fontSize,
                  measurementCache: measurementCache
              ) > availableWidth + 0.5
        else {
            return .byWordWrapping
        }
        return .byCharWrapping
    }

    private static func minimumUnbrokenWidth(
        _ text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight
    ) -> CGFloat {
        text.split(whereSeparator: { character in
            character.isWhitespace || character.isNewline
        }).reduce(CGFloat.zero) { widest, token in
            let value = String(token)
            let containsBreakableCJK = value.unicodeScalars.contains {
                BrowserOverlayTextFlow.isCJKForLayout($0.value) &&
                    !($0.value >= 0xAC00 && $0.value <= 0xD7AF)
            }
            guard !containsBreakableCJK else {
                return max(widest, fontSize)
            }
            let width = ceil((value as NSString).size(withAttributes: [
                .font: BrowserOverlayFont.system(ofSize: fontSize, weight: weight),
            ]).width)
            return max(widest, width)
        }
    }
}

struct BrowserOverlayVerticalTextLayoutSnapshot: Equatable {
    let visibleUTF16Range: NSRange
    let utf16Length: Int
    let lineOrigins: [CGPoint]
    let paintedInkBounds: CGRect
    let availableBounds: CGRect
    let usesVerticalForms: Bool
    let progressesRightToLeft: Bool

    var fits: Bool {
        visibleUTF16Range.location == 0 &&
            NSMaxRange(visibleUTF16Range) >= utf16Length &&
            availableBounds.insetBy(dx: -0.5, dy: -0.5)
                .contains(paintedInkBounds)
    }
}

/// Core Text owns the final native vertical painter. The existing display
/// variant remains the layout planner's compatibility contract, but the text
/// handed to this renderer is the unmodified OCR/translation string rather
/// than a string with a synthetic newline inserted after every character.
enum BrowserOverlayVerticalTextRenderer {
    static let verticalFormsAttributeKey = NSAttributedString.Key(
        kCTVerticalFormsAttributeName as String
    )

    static func attributedString(
        text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        foregroundColor: UIColor? = nil,
        textShadow: NSShadow? = nil
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.minimumLineHeight = fontSize
        paragraph.maximumLineHeight = fontSize
        var attributes: [NSAttributedString.Key: Any] = [
            .font: BrowserOverlayFont.system(ofSize: fontSize, weight: weight),
            .paragraphStyle: paragraph,
            .kern: fontSize * -0.012,
            verticalFormsAttributeKey: true,
        ]
        if let foregroundColor {
            attributes[.foregroundColor] = foregroundColor
        }
        if let textShadow {
            attributes[.shadow] = textShadow
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func snapshot(
        text: String,
        bounds: CGSize,
        fontSize: CGFloat,
        weight: UIFont.Weight = .heavy
    ) -> BrowserOverlayVerticalTextLayoutSnapshot {
        guard !text.isEmpty, bounds.width > 0, bounds.height > 0,
              fontSize > 0
        else {
            return BrowserOverlayVerticalTextLayoutSnapshot(
                visibleUTF16Range: NSRange(location: 0, length: 0),
                utf16Length: text.utf16.count,
                lineOrigins: [],
                paintedInkBounds: .zero,
                availableBounds: CGRect(origin: .zero, size: bounds),
                usesVerticalForms: true,
                progressesRightToLeft: true
            )
        }
        let frame = makeFrame(
            attributedString: attributedString(
                text: text,
                fontSize: fontSize,
                weight: weight
            ),
            bounds: bounds
        )
        let visibleRange = CTFrameGetVisibleStringRange(frame)
        let lines = CTFrameGetLines(frame)
        let lineCount = CFArrayGetCount(lines)
        var origins = Array(
            repeating: CGPoint.zero,
            count: lineCount
        )
        if lineCount > 0 {
            CTFrameGetLineOrigins(
                frame,
                CFRange(location: 0, length: 0),
                &origins
            )
        }
        let inkBounds = verticalInkBounds(in: frame)
        let horizontalOffset = centeredHorizontalOffset(
            inkBounds: inkBounds,
            boundsWidth: bounds.width
        )
        let paintedInkBounds = inkBounds.offsetBy(
            dx: horizontalOffset,
            dy: 0
        )
        return BrowserOverlayVerticalTextLayoutSnapshot(
            visibleUTF16Range: NSRange(
                location: max(0, visibleRange.location),
                length: max(0, visibleRange.length)
            ),
            utf16Length: text.utf16.count,
            lineOrigins: origins,
            paintedInkBounds: paintedInkBounds,
            availableBounds: CGRect(origin: .zero, size: bounds),
            usesVerticalForms: true,
            progressesRightToLeft: true
        )
    }

    static func fits(
        text: String,
        available: CGSize,
        fontSize: CGFloat,
        weight: UIFont.Weight
    ) -> Bool {
        snapshot(
            text: text,
            bounds: available,
            fontSize: fontSize,
            weight: weight
        ).fits
    }

    static func draw(
        text: String,
        in rect: CGRect,
        context: CGContext,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        foregroundColor: UIColor?,
        textShadow: NSShadow?
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let attributed = attributedString(
            text: text,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: foregroundColor,
            textShadow: textShadow
        )
        let frame = makeFrame(
            attributedString: attributed,
            bounds: rect.size
        )
        let inkBounds = verticalInkBounds(in: frame)
        let horizontalOffset = centeredHorizontalOffset(
            inkBounds: inkBounds,
            boundsWidth: rect.width
        )

        context.saveGState()
        // The card keeps masksToBounds disabled so its c1 drop shadow can
        // remain visible. Clip only this text pass to the label's content
        // rectangle, preventing a Core Text column or glyph overhang from
        // escaping the card while leaving the outer shadow untouched.
        context.clip(to: rect)
        context.translateBy(
            x: rect.minX + horizontalOffset,
            y: rect.maxY
        )
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func makeFrame(
        attributedString: NSAttributedString,
        bounds: CGSize
    ) -> CTFrame {
        let framesetter = CTFramesetterCreateWithAttributedString(
            attributedString
        )
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: bounds))
        let attributes: [CFString: Any] = [
            kCTFrameProgressionAttributeName:
                CTFrameProgression.rightToLeft.rawValue,
        ]
        return CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            attributes as CFDictionary
        )
    }

    private static func origins(in frame: CTFrame) -> [CGPoint] {
        let lineCount = CFArrayGetCount(CTFrameGetLines(frame))
        guard lineCount > 0 else { return [] }
        var origins = Array(repeating: CGPoint.zero, count: lineCount)
        CTFrameGetLineOrigins(
            frame,
            CFRange(location: 0, length: 0),
            &origins
        )
        return origins
    }

    /// CTLine glyph bounds use the line's horizontal coordinates even when
    /// the frame progresses vertically. For a vertical line, local X maps to
    /// frame Y (in reverse) and local Y maps to frame X. Using just the line
    /// origins plus `fontSize` shifted the left-most column baseline to zero,
    /// leaving its negative glyph-side bearing outside narrow cards.
    private static func verticalInkBounds(in frame: CTFrame) -> CGRect {
        let lines = CTFrameGetLines(frame)
        let lineCount = CFArrayGetCount(lines)
        guard lineCount > 0 else { return .zero }
        let lineOrigins = origins(in: frame)
        var union = CGRect.null
        for index in 0..<lineCount {
            let line = unsafeBitCast(
                CFArrayGetValueAtIndex(lines, index),
                to: CTLine.self
            )
            let local = CTLineGetBoundsWithOptions(
                line,
                [.useGlyphPathBounds, .excludeTypographicLeading]
            )
            guard !local.isNull,
                  local.width > 0,
                  local.height > 0
            else { continue }
            let origin = lineOrigins[index]
            let vertical = CGRect(
                x: origin.x + local.minY,
                y: origin.y - local.maxX,
                width: local.height,
                height: local.width
            )
            union = union.union(vertical)
        }
        return union.isNull ? .zero : union
    }

    private static func centeredHorizontalOffset(
        inkBounds: CGRect,
        boundsWidth: CGFloat
    ) -> CGFloat {
        guard !inkBounds.isNull, inkBounds.width > 0 else { return 0 }
        let targetMinimumX = max(0, (boundsWidth - inkBounds.width) / 2)
        return targetMinimumX - inkBounds.minX
    }
}

enum BrowserOverlayVerticalTextPainter {
    static func text(
        for item: BrowserOverlayItem,
        content: BrowserOverlayCardContent,
        mode: IPhoneOverlayMode
    ) -> String? {
        guard content.displayed.vertical else { return nil }
        guard let translatedText = item.translatedText else {
            return item.sourceText
        }
        switch mode {
        case .translateOnly:
            return translatedText
        case .originalAndTranslation:
            // Preserve the established dual-language payload contract. c1's
            // DOM renderer receives the already composed display variant for
            // this mode, including its explicit source/translation separator.
            return content.displayed.displayText
        case .subtitle, .sidePanel:
            return nil
        }
    }
}

struct BrowserOverlayCardContent: Equatable {
    let source: BrowserOverlayDisplayVariant
    let translated: BrowserOverlayDisplayVariant
    let hasTranslation: Bool
    let singleVerticalColumn: Bool

    static func make(
        item: BrowserOverlayItem,
        mode: IPhoneOverlayMode,
        sourceVertical: Bool,
        translatedVertical: Bool
    ) -> Self {
        let sourceDisplay = sourceVertical
            ? BrowserOverlayTextFlow.verticalized(item.sourceText)
            : item.sourceText
        let source = BrowserOverlayDisplayVariant.plain(
            sourceDisplay,
            vertical: sourceVertical
        )
        guard let translation = item.translatedText else {
            return Self(
                source: source,
                translated: source,
                hasTranslation: false,
                singleVerticalColumn:
                    (item.sourceSingleVerticalColumn ??
                        (item.sourceOrientation == .vertical)) &&
                    sourceVertical &&
                    BrowserOverlayTextFlow.isSingleLogicalLine(
                        item.sourceText
                    )
            )
        }

        let translatedDisplay = translatedVertical
            ? BrowserOverlayTextFlow.verticalized(translation)
            : translation
        let translated: BrowserOverlayDisplayVariant
        if mode == .originalAndTranslation {
            let dualSource = translatedVertical
                ? BrowserOverlayTextFlow.verticalized(item.sourceText)
                : item.sourceText
            translated = BrowserOverlayDisplayVariant(
                content: .originalAndTranslation(
                    source: dualSource,
                    translation: translatedDisplay,
                    separator: translatedVertical ? "\n\n" : "\n"
                ),
                vertical: translatedVertical
            )
        } else {
            translated = .plain(
                translatedDisplay,
                vertical: translatedVertical
            )
        }
        return Self(
            source: source,
            translated: translated,
            hasTranslation: true,
            singleVerticalColumn:
                (item.sourceSingleVerticalColumn ??
                    (item.sourceOrientation == .vertical)) &&
                sourceVertical && translatedVertical &&
                BrowserOverlayTextFlow.isSingleLogicalLine(item.sourceText)
        )
    }

    /// Korean normally reads horizontally, but a dense row of narrow manga
    /// columns can require much more displacement than the source geometry.
    /// Offer a vertical alternative only for translated replacement cards;
    /// the global direction selector below still keeps horizontal text unless
    /// this alternative removes an intrinsic card collision.
    static func adaptiveVerticalCandidate(
        item: BrowserOverlayItem,
        current: Self,
        mode: IPhoneOverlayMode,
        textPlacement: IPhoneOverlayTextPlacement,
        sourceVertical: Bool,
        sourceRect: CGRect
    ) -> Self? {
        guard mode == .translateOnly,
              textPlacement == .replace,
              sourceVertical,
              current.hasTranslation,
              !current.displayed.vertical,
              sourceRect.height >= sourceRect.width * 1.8,
              let translatedText = item.translatedText,
              BrowserOverlayTextFlow.wrappingScript(for: translatedText) ==
                .korean
        else { return nil }
        return make(
            item: item,
            mode: mode,
            sourceVertical: sourceVertical,
            translatedVertical: true
        )
    }

    var displayed: BrowserOverlayDisplayVariant {
        hasTranslation ? translated : source
    }

}

struct BrowserOverlayFontReference: Equatable {
    let fontSize: CGFloat
    let insets: UIEdgeInsets
    var additionalLines: Int = 1
    var exclusionRects: [CGRect] = []
    var fallbackFontSize: CGFloat? = nil
    var fallbackInsets: UIEdgeInsets? = nil
    var allowsEmergencyWordBreak: Bool = false
}

struct BrowserOverlayCardLayout: Equatable {
    let rect: CGRect
    let maximumFontSize: CGFloat
    let contentInsets: UIEdgeInsets
    var smallTextReference: BrowserOverlayFontReference? = nil
}

struct BrowserOverlayCardTextInsets {
    static let regular = UIEdgeInsets(
        top: 4,
        left: 6,
        bottom: 4,
        right: 6
    )
    static let singleVerticalColumn = UIEdgeInsets(
        top: 0.5,
        left: 0.5,
        bottom: 0.5,
        right: 0.5
    )
}

struct BrowserOverlayLayoutPlanner {
    private struct JointPackingState {
        var placements: [Int: CGRect]
        var overlapPairs: Int
        var overlapArea: CGFloat
        var maximumSquaredDisplacement: CGFloat
        var totalSquaredDisplacement: CGFloat
        var totalHorizontalDisplacement: CGFloat
        var totalVerticalDisplacement: CGFloat
    }

    /// Match the desktop auto-fit floor. The previous 11-point mobile-only
    /// floor expanded compact cards beyond their OCR bbox and hid nearby text.
    static let minimumAutoFontSize: CGFloat = 7
    /// Dense manga translations may contract this far, but never below it.
    /// This is intentionally lower than the regular auto-fit floor so compact
    /// horizontal Hangul stays near its OCR source instead of covering panels.
    static let minimumReadableHorizontalFontSize: CGFloat = 5
    static let minimumRenderedFontSize: CGFloat = 5
    /// Captions on a page from which it is treated as a dense sheet.
    static let denseSheetCaptionCount = 12
    static let maximumAutoFontSize: CGFloat = 32
    private static let minimumConstrainedMangaFontSize: CGFloat = 5
    private static let minimumSingleVerticalColumnFontSize: CGFloat = 1

    /// Pick vertical Korean only where it prevents the intrinsic cards from
    /// colliding. This happens before positional packing, so changing writing
    /// direction can remove the reason a card would otherwise be thrown far
    /// from its OCR bbox. A no-collision horizontal layout is never changed.
    static func adaptiveVerticalTranslationIndices(
        horizontalLayouts: [BrowserOverlayCardLayout],
        verticalLayouts: [Int: BrowserOverlayCardLayout],
        eligibleIndices: Set<Int>? = nil
    ) -> Set<Int> {
        guard horizontalLayouts.count > 1,
              !verticalLayouts.isEmpty
        else { return [] }

        struct Score {
            let pairs: Int
            let area: CGFloat
        }
        func score(_ rects: [CGRect]) -> Score {
            let geometry = rects.map(BrowserOverlayCollisionGeometry.init)
            let areas = rects.map { $0.width * $0.height }
            var pairs = 0
            var area: CGFloat = 0
            for left in rects.indices {
                for right in (left + 1)..<rects.count {
                    let overlap = geometry[left].overlapArea(with: geometry[right], minimumExtent: 0.25)
                    let smallerArea = min(areas[left], areas[right])
                    guard overlap > 0,
                          smallerArea > 0,
                          overlap >=
                            smallerArea * 0.5
                    else { continue }
                    pairs += 1
                    area += overlap
                }
            }
            return Score(pairs: pairs, area: area)
        }
        func isBetter(_ candidate: Score, than current: Score) -> Bool {
            if candidate.pairs != current.pairs {
                return candidate.pairs < current.pairs
            }
            return candidate.area + 0.25 < current.area
        }

        var rects = horizontalLayouts.map(\.rect)
        var selected = Set<Int>()
        let candidateIndices = verticalLayouts.keys.sorted()
        var currentScore = score(rects)
        guard currentScore.pairs > 0 else { return [] }

        // Coordinate descent is deterministic and intentionally conservative:
        // every accepted direction change must immediately improve the full
        // page's collision score. Re-evaluation lets several adjacent columns
        // verticalize together without forcing unrelated translations to do so.
        while true {
            var bestIndex: Int?
            var bestScore = currentScore
            for index in candidateIndices
            where !selected.contains(index) {
                guard rects.indices.contains(index),
                      let alternative = verticalLayouts[index]?.rect,
                      eligibleIndices?.contains(index) ?? true
                else { continue }
                var trial = rects
                trial[index] = alternative
                let trialScore = score(trial)
                if isBetter(trialScore, than: bestScore) {
                    bestIndex = index
                    bestScore = trialScore
                }
            }
            guard let bestIndex,
                  let alternative = verticalLayouts[bestIndex]?.rect
            else { break }
            rects[bestIndex] = alternative
            selected.insert(bestIndex)
            currentScore = bestScore
        }
        return selected
    }

    /// Run the complete horizontal packing pass first and expose only cards
    /// whose centers actually leave their source-anchored intrinsic position
    /// by at least 24 points. Minor overlap and short local shifts therefore
    /// keep the target language horizontal.
    static func severelyDisplacedTranslationIndices(
        intrinsicLayouts: [BrowserOverlayCardLayout],
        sources: [CGRect],
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        sourceVerticals: [Bool],
        singleVerticalColumns: [Bool],
        placementBounds: CGRect,
        allowsDetachedPlacements: [Bool],
        returnableCards: [Bool]? = nil,
        protectedRects: [CGRect] = [],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> Set<Int> {
        let count = intrinsicLayouts.count
        guard count > 1,
              sources.count == count,
              variants.count == count,
              sourceVerticals.count == count,
              singleVerticalColumns.count == count
        else { return [] }

        var occupied: [CGRect] = []
        var planned = Array<BrowserOverlayCardLayout?>(
            repeating: nil,
            count: count
        )
        for index in packingOrder(intrinsicLayouts) {
            let reservedSources = sources.indices.compactMap {
                $0 == index ? nil : sources[$0]
            }
            let layout = resolvePositionedLayout(
                intrinsicLayouts[index],
                source: sources[index],
                variants: [variants[index]],
                settings: settings,
                viewport: viewport,
                occupied: occupied,
                sourceVertical: sourceVerticals[index],
                singleVerticalColumn: singleVerticalColumns[index],
                reservedSources: reservedSources,
                measurementCache: measurementCache
            )
            guard !layout.rect.isNull,
                  layout.rect.width > 0,
                  layout.rect.height > 0
            else { continue }
            planned[index] = layout
            occupied.append(layout.rect)
        }
        let concrete = planned.compactMap { $0 }
        guard concrete.count == count else { return [] }
        let final = relaxingCardPositions(
            concrete,
            sources: sources,
            sourceVerticals: sourceVerticals,
            viewport: viewport,
            placementBounds: placementBounds,
            preferredRects: intrinsicLayouts.map(\.rect),
            allowsDetachedPlacements: allowsDetachedPlacements,
            returnableCards: returnableCards,
            protectedRects: protectedRects
        )
        // Vertical target text is a last resort, not a normal dense-row
        // packing tool. Require an escape larger than roughly one quarter of
        // an iPhone-width page before even offering that writing direction.
        let minimumDistance: CGFloat = 120
        return Set(final.indices.filter { index in
            guard allowsDetachedPlacements.indices.contains(index),
                  allowsDetachedPlacements[index]
            else { return false }
            let dx = final[index].rect.midX - intrinsicLayouts[index].rect.midX
            let dy = final[index].rect.midY - intrinsicLayouts[index].rect.midY
            return hypot(dx, dy) >= minimumDistance
        })
    }

    /// Greedy placement is order-sensitive. Give the cards that need the
    /// largest envelope first choice, then fit smaller cards around them.
    /// Returning indices keeps payload and accessibility order independent
    /// from the packing order.
    static func packingOrder(
        _ intrinsicLayouts: [BrowserOverlayCardLayout]
    ) -> [Int] {
        intrinsicLayouts.indices.sorted { left, right in
            let leftRect = intrinsicLayouts[left].rect
            let rightRect = intrinsicLayouts[right].rect
            let leftArea = leftRect.width * leftRect.height
            let rightArea = rightRect.width * rightRect.height
            if abs(leftArea - rightArea) > 0.25 {
                return leftArea > rightArea
            }
            let leftLongestSide = max(leftRect.width, leftRect.height)
            let rightLongestSide = max(rightRect.width, rightRect.height)
            if abs(leftLongestSide - rightLongestSide) > 0.25 {
                return leftLongestSide > rightLongestSide
            }
            return left < right
        }
    }

    /// Greedy placement can leave an earlier card in a position that blocks a
    /// later neighbor. Revisit every card against the complete placed set and
    /// accept only moves that reduce positive-area overlap. Sizes, fonts,
    /// viewport bounds, and full source coverage are preserved whenever the
    /// OCR boxes permit it. Translation-only callers can opt into a detached
    /// fallback, but it must not leave a blank replacement surface behind.
    static func relaxingCardPositions(
        _ layouts: [BrowserOverlayCardLayout],
        sources: [CGRect],
        sourceVerticals: [Bool]? = nil,
        viewport: CGSize,
        placementBounds: CGRect? = nil,
        preferredRects: [CGRect]? = nil,
        allowsDetachedPlacements: [Bool] = [],
        returnableCards: [Bool]? = nil,
        protectedRects: [CGRect] = []
    ) -> [BrowserOverlayCardLayout] {
        guard layouts.count > 1, layouts.count == sources.count else {
            return layouts
        }
        // Cards drawn from their own rotated quad keep the packed rect: it only
        // bounds their planned size and is never shown at that position.
        let returnable = zip(allowsDetachedPlacements, returnableCards ?? allowsDetachedPlacements).map { $0 && $1 }

        let viewportRect = CGRect(origin: .zero, size: viewport)
        let requestedPlacementBounds = placementBounds ?? viewportRect
        let effectivePlacementBounds = requestedPlacementBounds
            .standardized
            .intersection(viewportRect)
        guard !effectivePlacementBounds.isNull,
              effectivePlacementBounds.width > 0,
              effectivePlacementBounds.height > 0
        else { return layouts }
        let effectivePreferredRects: [CGRect]
        if let preferredRects, preferredRects.count == layouts.count {
            effectivePreferredRects = preferredRects
        } else {
            effectivePreferredRects = layouts.map(\.rect)
        }

        let jointlyPacked = jointlyPackingOverlappingClusters(
            layouts,
            sources: sources,
            sourceVerticals: sourceVerticals,
            viewport: viewport,
            placementBounds: effectivePlacementBounds,
            preferredRects: effectivePreferredRects,
            allowsDetachedPlacements: allowsDetachedPlacements
        )
        if !hasAnyCardOverlap(jointlyPacked) {
            return returningDisplacedCards(jointlyPacked, sources: sources, preferredRects: effectivePreferredRects,
                                           placementBounds: effectivePlacementBounds, movable: returnable,
                                           protectedRects: protectedRects)
        }

        func overlapMetrics(
            _ candidates: [BrowserOverlayCardLayout]
        ) -> (pairs: Int, area: CGFloat, displacement: CGFloat) {
            var pairs = 0
            var area: CGFloat = 0
            for left in candidates.indices {
                for right in candidates.indices where right > left {
                    let intersection = candidates[left].rect.intersection(
                        candidates[right].rect
                    )
                    guard !intersection.isNull,
                          intersection.width > 0.25,
                          intersection.height > 0.25
                    else { continue }
                    pairs += 1
                    area += intersection.width * intersection.height
                }
            }
            let displacement = candidates.indices.reduce(CGFloat.zero) {
                total, index in
                let dx = candidates[index].rect.midX - layouts[index].rect.midX
                let dy = candidates[index].rect.midY - layouts[index].rect.midY
                return total + dx * dx + dy * dy
            }
            return (pairs, area, displacement)
        }

        func reducesOverlap(
            _ candidate: (
                pairs: Int,
                area: CGFloat,
                displacement: CGFloat
            ),
            over current: (
                pairs: Int,
                area: CGFloat,
                displacement: CGFloat
            )
        ) -> Bool {
            if candidate.pairs != current.pairs {
                return candidate.pairs < current.pairs
            }
            if abs(candidate.area - current.area) > 0.25 {
                return candidate.area < current.area
            }
            return false
        }

        func isBetterCandidate(
            _ candidate: (
                pairs: Int,
                area: CGFloat,
                displacement: CGFloat
            ),
            than current: (
                pairs: Int,
                area: CGFloat,
                displacement: CGFloat
            )
        ) -> Bool {
            if reducesOverlap(candidate, over: current) {
                return true
            }
            guard candidate.pairs == current.pairs,
                  abs(candidate.area - current.area) <= 0.25
            else { return false }
            return candidate.displacement + 0.25 < current.displacement
        }

        var current = layouts
        for _ in 0..<(layouts.count * 4) {
            if Task.isCancelled { return current }
            let currentMetrics = overlapMetrics(current)
            guard currentMetrics.pairs > 0 else { break }
            var best = current
            var bestMetrics = currentMetrics
            for index in current.indices {
                let otherRects = current.indices.compactMap {
                    $0 == index ? nil : current[$0].rect
                }
                let reservedSources = sources.indices.compactMap {
                    $0 == index ? nil : sources[$0]
                }
                let resolved = resolveCollision(
                    layouts[index].rect,
                    source: clippedSource(sources[index], viewport: viewport),
                    occupied: otherRects,
                    reservedSources: reservedSources,
                    viewport: viewport
                )
                var trial = current
                trial[index] = BrowserOverlayCardLayout(
                    rect: resolved,
                    maximumFontSize: current[index].maximumFontSize,
                    contentInsets: current[index].contentInsets
                )
                let trialMetrics = overlapMetrics(trial)
                if isBetterCandidate(trialMetrics, than: bestMetrics) {
                    best = trial
                    bestMetrics = trialMetrics
                }

                let allowsDetached =
                    allowsDetachedPlacements.indices.contains(index) &&
                    allowsDetachedPlacements[index]
                guard allowsDetached,
                      let detached = resolveDetachedCollision(
                          layouts[index].rect,
                          source: clippedSource(
                              sources[index],
                              viewport: viewport
                          ),
                          occupied: otherRects,
                          placementBounds: effectivePlacementBounds
                      )
                else { continue }
                var detachedTrial = current
                detachedTrial[index] = BrowserOverlayCardLayout(
                    rect: detached,
                    maximumFontSize: current[index].maximumFontSize,
                    contentInsets: current[index].contentInsets
                )
                let detachedMetrics = overlapMetrics(detachedTrial)
                if isBetterCandidate(detachedMetrics, than: bestMetrics) {
                    best = detachedTrial
                    bestMetrics = detachedMetrics
                }
            }
            guard reducesOverlap(bestMetrics, over: currentMetrics) else {
                break
            }
            current = best
        }
        return returningDisplacedCards(current, sources: sources, preferredRects: effectivePreferredRects,
                                       placementBounds: effectivePlacementBounds, movable: returnable,
                                       protectedRects: protectedRects)
    }

    /// Packing is order-sensitive: one card fewer or more elsewhere can make it
    /// throw an unrelated card far from its source instead of nudging the few
    /// cards in its way. A card far from its source-anchored position returns
    /// there (or next to it) when every card in the way can make room with a
    /// short move that stays in its own source neighbourhood and the page's
    /// total squared displacement drops. Overlap confined to the intersection
    /// of the two cards' own OCR boxes is unavoidable and is not a collision:
    /// a card never leaves its source because another OCR box contains part of
    /// it. Sizes, fonts and insets are unchanged; no other overlap is created.
    static func returningDisplacedCards(
        _ layouts: [BrowserOverlayCardLayout],
        sources: [CGRect],
        preferredRects: [CGRect],
        placementBounds: CGRect,
        movable: [Bool],
        protectedRects: [CGRect] = []
    ) -> [BrowserOverlayCardLayout] {
        let count = layouts.count
        guard count > 1, sources.count == count, preferredRects.count == count, movable.count == count,
              movable.contains(true), placementBounds.width > 0, placementBounds.height > 0
        else { return layouts }
        func clamped(_ rect: CGRect) -> CGRect {
            let x = rect.width > placementBounds.width ? rect.minX
                : min(max(placementBounds.minX, rect.minX), placementBounds.maxX - rect.width)
            let y = rect.height > placementBounds.height ? rect.minY
                : min(max(placementBounds.minY, rect.minY), placementBounds.maxY - rect.height)
            return CGRect(x: x, y: y, width: rect.width, height: rect.height)
        }
        var rects = layouts.map(\.rect)
        let homes = rects.indices.map { index in
            clamped(CGRect(x: preferredRects[index].midX - rects[index].width / 2,
                           y: preferredRects[index].midY - rects[index].height / 2,
                           width: rects[index].width, height: rects[index].height))
        }
        func cost(_ rect: CGRect, _ index: Int) -> CGFloat {
            let dx = rect.midX - homes[index].midX, dy = rect.midY - homes[index].midY
            return dx * dx + dy * dy
        }
        // A collision is positive-area overlap outside the region both OCR
        // boxes claim (where both cards must cover their source anyway), or
        // one that buries most of either card (a fragment inside a larger box).
        func collides(_ rect: CGRect, _ index: Int, with other: Int, at otherRect: CGRect,
                      coveringSource: Bool = false) -> Bool {
            // A returning card's plate also covers its own source box when it lies on it.
            let footprint = coveringSource && rect.intersects(sources[index]) ? rect.union(sources[index]) : rect
            let overlap = footprint.intersection(otherRect)
            guard !overlap.isNull, overlap.width > 0.25, overlap.height > 0.25 else { return false }
            let shared = sources[index].intersection(sources[other])
            let smaller = min(footprint.width * footprint.height, otherRect.width * otherRect.height)
            return shared.isNull || !shared.insetBy(dx: -0.5, dy: -0.5).contains(overlap) ||
                overlap.width * overlap.height > smaller * 0.5
        }
        // A card may move only inside its source's neighbourhood.
        let cells = sources.indices.map { index in
            sourceCell(at: index, sources: sources, bounds: placementBounds,
                       reach: CGSize(width: max(12, sources[index].width * 0.5), height: max(12, sources[index].height * 0.5)))
        }
        func inCell(_ rect: CGRect, _ index: Int) -> Bool {
            let cell = cells[index]
            return rect.intersects(sources[index].insetBy(dx: -2, dy: -2)) ||
                cell.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: rect.midX, y: rect.midY))
        }
        // Kept source lettering is never covered by a moved card.
        func coversKept(_ rect: CGRect) -> Bool {
            protectedRects.contains { kept in
                let overlap = rect.intersection(kept)
                return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
            }
        }
        let spacing: CGFloat = 1
        func pushes(_ rect: CGRect, clearing wall: CGRect) -> [CGRect] {
            [
                CGRect(x: wall.minX - spacing - rect.width, y: rect.minY, width: rect.width, height: rect.height),
                CGRect(x: wall.maxX + spacing, y: rect.minY, width: rect.width, height: rect.height),
                CGRect(x: rect.minX, y: wall.minY - spacing - rect.height, width: rect.width, height: rect.height),
                CGRect(x: rect.minX, y: wall.maxY + spacing, width: rect.width, height: rect.height),
            ].map(clamped)
        }
        // Distance from a card's centre to its own source box.
        func sourceDistance(_ rect: CGRect, _ index: Int) -> CGFloat {
            let source = sources[index]
            return hypot(max(source.minX - rect.midX, 0, rect.midX - source.maxX),
                         max(source.minY - rect.midY, 0, rect.midY - source.maxY))
        }
        // Far: moved off its source-anchored place and detached from its source
        // (a wide card shifted along its own source box is not far).
        func isFar(_ index: Int) -> Bool {
            let size = rects[index].size
            let limit = max(12, min(size.width, size.height) * 0.5)
            return cost(rects[index], index) > limit * limit &&
                sourceDistance(rects[index], index) > max(8, min(size.width, size.height) * 0.5)
        }
        // The planner's final fit grows only a card clear of other cards and
        // source boxes; a short return must not cost a card that growth.
        func isFree(_ rect: CGRect, _ index: Int, _ moves: [Int: CGRect]) -> Bool {
            !rects.indices.contains { other in
                guard other != index else { return false }
                return [moves[other] ?? rects[other], sources[other]].contains { obstacle in
                    let overlap = rect.intersection(obstacle)
                    return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
                }
            }
        }
        // Page geometry the overlay inherits: source lettering left outside
        // every card, and a card's area over other captions' source boxes
        // (outside its own). A return may trade only a small share of these
        // for the lettering it covers again.
        func uncovered(_ index: Int, _ cards: [Int: CGRect]) -> CGFloat {
            let source = sources[index]
            guard source.width > 0, source.height > 0 else { return 0 }
            let steps = 12
            var open = 0
            for row in 0..<steps {
                for column in 0..<steps {
                    let point = CGPoint(x: source.minX + (CGFloat(column) + 0.5) * source.width / CGFloat(steps),
                                        y: source.minY + (CGFloat(row) + 0.5) * source.height / CGFloat(steps))
                    if !rects.indices.contains(where: { (cards[$0] ?? rects[$0]).contains(point) }) { open += 1 }
                }
            }
            return source.width * source.height * CGFloat(open) / CGFloat(steps * steps)
        }
        func otherLettering(_ rect: CGRect, _ index: Int) -> CGFloat {
            sources.indices.reduce(CGFloat.zero) { total, other in
                guard other != index else { return total }
                let overlap = rect.intersection(sources[other])
                guard !overlap.isNull else { return total }
                let shared = overlap.intersection(sources[index])
                return total + overlap.width * overlap.height - (shared.isNull ? 0 : shared.width * shared.height)
            }
        }
        // Card area outside every source box: where a plate would cover art.
        func artArea(_ rect: CGRect) -> CGFloat {
            guard rect.width > 0, rect.height > 0 else { return 0 }
            let steps = 12
            var open = 0
            for row in 0..<steps {
                for column in 0..<steps {
                    let point = CGPoint(x: rect.minX + (CGFloat(column) + 0.5) * rect.width / CGFloat(steps),
                                        y: rect.minY + (CGFloat(row) + 0.5) * rect.height / CGFloat(steps))
                    if !sources.contains(where: { $0.contains(point) }) { open += 1 }
                }
            }
            return rect.width * rect.height * CGFloat(open) / CGFloat(steps * steps)
        }
        // A return never lays the returning card over more art than before, and
        // the lettering it covers again plus the art it frees must outweigh four
        // times what the cards making room give up (their own lettering left
        // open, new art under them, other captions' lettering under the card).
        func tradesWell(_ index: Int, _ moves: [Int: CGRect]) -> Bool {
            let position = moves[index] ?? rects[index]
            let artBefore = artArea(rects[index]), artAfter = artArea(position)
            guard artAfter <= artBefore + 0.5 else { return false }
            let gain = uncovered(index, [:]) - uncovered(index, moves) + artBefore - artAfter
            var loss = max(0, otherLettering(position, index) - otherLettering(rects[index], index))
            for (other, rect) in moves where other != index {
                loss += max(0, uncovered(other, moves) - uncovered(other, [:]))
                loss += max(0, artArea(rect) - artArea(rects[other]))
            }
            return loss * 4 <= gain + 0.5
        }
        for _ in 0..<2 {
            if Task.isCancelled { return layouts }
            let far = rects.indices.filter { movable[$0] && isFar($0) }
                .sorted { cost(rects[$0], $0) > cost(rects[$1], $1) }
            guard !far.isEmpty else { break }
            var changed = false
            for index in far where isFar(index) {
                let before = cost(rects[index], index)
                // Home first, then home shifted just clear of one card in the way.
                var positions = [homes[index]]
                for other in rects.indices where other != index &&
                    collides(homes[index], index, with: other, at: rects[other], coveringSource: true) {
                    positions += pushes(homes[index], clearing: rects[other])
                }
                var best: (total: CGFloat, moves: [Int: CGRect])?
                for position in positions {
                    let own = cost(position, index)
                    guard own * 4 <= before, inCell(position, index) || own < 1, !coversKept(position) else { continue }
                    var moves: [Int: CGRect] = [index: position]
                    var total = own
                    var feasible = true
                    let blockers = rects.indices.filter {
                        $0 != index && collides(position, index, with: $0, at: rects[$0], coveringSource: true)
                    }
                    for other in blockers {
                        guard movable[other] else { feasible = false; break }
                        let current = rects[other], original = layouts[other].rect
                        let limit = max(12, min(24, min(current.width, current.height) * 0.6))
                        // A card making room stays near its own source (never becomes far),
                        // measured from where the pass found it so moves never accumulate.
                        let near = max(sourceDistance(original, other), 8, min(current.width, current.height) * 0.5)
                        var chosen: (rect: CGRect, extra: CGFloat)?
                        let wall = position.intersects(sources[index]) ? position.union(sources[index]) : position
                        for candidate in pushes(current, clearing: wall) {
                            guard hypot(candidate.midX - original.midX, candidate.midY - original.midY) <= limit + 0.01,
                                  sourceDistance(candidate, other) <= near + 0.01, !coversKept(candidate),
                                  inCell(candidate, other) || cost(candidate, other) <= cost(current, other) else { continue }
                            // Clear of every card at its current or already decided place.
                            let clear = rects.indices.allSatisfy { third in
                                guard third != other else { return true }
                                return !collides(candidate, other, with: third, at: moves[third] ?? rects[third])
                            }
                            guard clear, !isFree(current, other, [:]) || isFree(candidate, other, moves) else { continue }
                            let extra = cost(candidate, other) - cost(current, other)
                            if extra < (chosen?.extra ?? .infinity) { chosen = (candidate, extra) }
                        }
                        guard let chosen else { feasible = false; break }
                        moves[other] = chosen.rect
                        total += chosen.extra
                    }
                    guard feasible else { continue }
                    // The returning card must also be clear of every moved card.
                    let clear = moves.allSatisfy { other, rect in
                        other == index || !collides(position, index, with: other, at: rect, coveringSource: true)
                    }
                    guard clear, total * 2 <= before else { continue }
                    let size = rects[index].size
                    guard !isFree(rects[index], index, [:]) || isFree(position, index, moves) ||
                        sourceDistance(rects[index], index) > max(24, min(size.width, size.height)) else { continue }
                    guard tradesWell(index, moves) else { continue }
                    if total < (best?.total ?? .infinity) - 0.01 { best = (total, moves) }
                }
                guard let best else { continue }
                for (other, rect) in best.moves { rects[other] = rect }
                changed = true
            }
            if !changed { break }
        }
        return rects.indices.map { index in
            rects[index] == layouts[index].rect ? layouts[index] : BrowserOverlayCardLayout(
                rect: rects[index], maximumFontSize: layouts[index].maximumFontSize,
                contentInsets: layouts[index].contentInsets)
        }
    }

    /// Recover exposed original lettering only when the extra surface stays local
    /// and cannot cover another OCR region or translation. Detached cards are
    /// deliberately excluded: joining those to their source would paint artwork.
    static func restoringSourceCoverage(
        _ layouts: [BrowserOverlayCardLayout],
        sources: [CGRect],
        bounds: CGRect,
        enabled: Bool
    ) -> [BrowserOverlayCardLayout] {
        guard enabled, layouts.count == sources.count else { return layouts }
        var result = layouts
        for index in result.indices {
            let layout = result[index]
            let source = sources[index].intersection(bounds)
            let intersection = layout.rect.intersection(source)
            guard !source.isNull, source.width > 0, source.height > 0,
                  !intersection.isNull,
                  intersection.width * intersection.height >= source.width * source.height * 0.5,
                  !layout.rect.contains(source)
            else { continue }
            let candidate = layout.rect.union(source)
            guard bounds.contains(candidate),
                  candidate.width * candidate.height <= layout.rect.width * layout.rect.height * 1.75
            else { continue }
            let obstructsNeighbor = result.indices.contains { other in
                guard other != index else { return false }
                return [result[other].rect, sources[other]].contains { obstacle in
                    let overlap = candidate.intersection(obstacle)
                    return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
                }
            }
            guard !obstructsNeighbor else { continue }
            result[index] = BrowserOverlayCardLayout(
                rect: candidate, maximumFontSize: layout.maximumFontSize,
                contentInsets: layout.contentInsets
            )
        }
        return result
    }

    /// The neighbourhood a source box owns on a dense page: the box grown
    /// toward each side up to half the gap to the nearest source box beside,
    /// above or below it, and by at most `reach` where nothing is near.
    static func sourceCell(
        at index: Int,
        sources: [CGRect],
        bounds: CGRect,
        reach: CGSize
    ) -> CGRect {
        let own = sources[index]
        var left = max(bounds.minX, own.minX - reach.width), right = min(bounds.maxX, own.maxX + reach.width)
        var top = max(bounds.minY, own.minY - reach.height), bottom = min(bounds.maxY, own.maxY + reach.height)
        for (other, rect) in sources.enumerated() where other != index {
            let xOverlap = min(own.maxX, rect.maxX) - max(own.minX, rect.minX)
            let yOverlap = min(own.maxY, rect.maxY) - max(own.minY, rect.minY)
            if xOverlap > 0 && yOverlap > 0 { continue }
            if yOverlap > 0 {
                if rect.maxX <= own.minX + 0.5 { left = max(left, (rect.maxX + own.minX) / 2) }
                if rect.minX >= own.maxX - 0.5 { right = min(right, (rect.minX + own.maxX) / 2) }
            } else if xOverlap > 0 {
                if rect.maxY <= own.minY + 0.5 { top = max(top, (rect.maxY + own.minY) / 2) }
                if rect.minY >= own.maxY - 0.5 { bottom = min(bottom, (rect.minY + own.maxY) / 2) }
            }
        }
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    /// Share of a card lying outside its own source box (grown by a small
    /// allowance for padding and glyph side bearings).
    static func sourceSpill(_ rect: CGRect, source: CGRect, fontSize: CGFloat) -> CGFloat {
        let area = rect.width * rect.height
        guard area > 0 else { return 0 }
        let allowance = max(4, fontSize * 0.35)
        let inside = rect.intersection(source.insetBy(dx: -allowance, dy: -allowance))
        let kept = inside.isNull ? 0 : inside.width * inside.height
        return max(0, area - kept) / area
    }

    /// Dense sheets (profiles, tables, timetables, notes): a card that the
    /// readable floor or collision packing pushed far beyond its source box is
    /// re-laid inside that box's cell when its text fits there at the same size
    /// (or at most 10% smaller while staying at or above the small-text size):
    /// wider or taller, words unbroken, centred on the source and clamped into
    /// the cell. The planner's final small-print fit must show the text at
    /// least as large as before. A card that does not fit keeps its layout;
    /// nothing is dropped and no text becomes smaller than the readable floor.
    static func confiningToSourceCells(
        _ layouts: [BrowserOverlayCardLayout?],
        sources: [CGRect],
        variants: [BrowserOverlayDisplayVariant],
        sourceVerticals: [Bool],
        sourceSizes: [CGFloat?],
        eligible: [Bool],
        bounds: CGRect,
        settings: IPhoneOverlaySettings,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> [BrowserOverlayCardLayout?] {
        guard layouts.count == sources.count, variants.count == sources.count,
              eligible.count == sources.count, sourceVerticals.count == sources.count, sourceSizes.count == sources.count,
              sources.count >= 2, !bounds.isNull, bounds.width > 0, bounds.height > 0
        else { return layouts }
        var result = layouts
        func overlapArea(_ rect: CGRect, excluding index: Int) -> CGFloat {
            result.indices.reduce(CGFloat.zero) { total, other in
                guard other != index, let obstacle = result[other]?.rect else { return total }
                let overlap = rect.intersection(obstacle)
                return overlap.isNull ? total : total + overlap.width * overlap.height
            }
        }
        func outsideShare(_ rect: CGRect, _ cell: CGRect) -> CGFloat {
            let area = rect.width * rect.height
            guard area > 0 else { return 0 }
            let inside = rect.intersection(cell)
            return max(0, area - (inside.isNull ? 0 : inside.width * inside.height)) / area
        }
        // A second pass lets a card return once a neighbour has left its cell.
        for _ in 0..<2 {
            for index in result.indices where eligible[index] {
                guard let layout = result[index], !variants[index].vertical else { continue }
                let source = sources[index].intersection(bounds)
                let font = layout.maximumFontSize
                guard !source.isNull, source.width > 0, source.height > 0, font > 0 else { continue }
                let cell = sourceCell(at: index, sources: sources, bounds: bounds,
                    reach: CGSize(width: max(3 * font, source.width * 0.75), height: max(3 * font, source.height * 0.75)))
                let outside = outsideShare(layout.rect, cell)
                guard cell.width > 0, cell.height > 0, outside > 0.05 else { continue }
                let spill = sourceSpill(layout.rect, source: source, fontSize: font)
                // Far: most of the card, or its centre, lies outside the cell.
                let far = outside > 0.3 || !cell.contains(CGPoint(x: layout.rect.midX, y: layout.rect.midY))
                guard far || spill > 0.2 else { continue }
                let variant = variants[index]
                // A horizontal translation of a vertical source keeps the planner's
                // six-cell minimum width (no stacks of one or two syllables).
                let units: CGFloat = sourceVerticals[index] ? 6 : 1
                let smallest = font >= 9.5 ? max(8.5, font * 0.9) : font
                var fonts: [CGFloat] = [font]
                var next = floor((font - 0.25) * 4) / 4
                while next + 0.001 >= smallest { fonts.append(next); next -= 0.25 }
                // Thin lines of small print may use the compact padding of the
                // final small-text refinement.
                let old = layout.contentInsets
                func reduced(_ value: CGFloat) -> CGFloat { min(value, max(2, value * 0.65)) }
                let compact = UIEdgeInsets(top: reduced(old.top), left: reduced(old.left),
                                           bottom: reduced(old.bottom), right: reduced(old.right))
                let overlapBefore = overlapArea(layout.rect, excluding: index)
                // The type the card finally shows (the planner's last fit grows
                // small print into its card): a confined card never reads smaller.
                let others = result.indices.compactMap { $0 == index ? nil : result[$0]?.rect }
                let reserved = sources.indices.compactMap { $0 == index ? nil : sources[$0] }
                func shown(_ card: BrowserOverlayCardLayout) -> CGFloat {
                    fittingFinalHorizontalFont(card, variants: [variant], settings: settings, occupied: others,
                        reservedSources: reserved, measurementCache: measurementCache).maximumFontSize
                }
                let shownBefore = shown(layout)
                var accepted: BrowserOverlayCardLayout?
                search: for size in fonts {
                    for insets in [old, compact] {
                        let horizontalInsets = insets.left + insets.right, verticalInsets = insets.top + insets.bottom
                        let token = variant.minimumUnbrokenWidth(fontSize: size, measurementCache: measurementCache)
                        let minimumWidth = max(token, units * size) + horizontalInsets
                        guard minimumWidth <= cell.width + 0.5 else { continue }
                        let span = max(0, cell.width - minimumWidth)
                        var best: (rect: CGRect, spill: CGFloat)?
                        for step in 0...16 {
                            let width = min(cell.width, minimumWidth + span * CGFloat(step) / 16)
                            let height = variant.measuredSize(width: max(1, width - horizontalInsets), fontSize: size,
                                measurementCache: measurementCache).height + verticalInsets
                            guard height <= cell.height + 0.5 else { continue }
                            let card = CGSize(width: max(width, min(source.width, cell.width)),
                                              height: min(cell.height, max(height, min(source.height, cell.height))))
                            guard variantsFit([variant], size: card, fontSize: size, minimumHorizontalUnits: units,
                                              contentInsets: insets, measurementCache: measurementCache) else { continue }
                            let rect = CGRect(
                                x: min(max(cell.minX, source.midX - card.width / 2), cell.maxX - card.width),
                                y: min(max(cell.minY, source.midY - card.height / 2), cell.maxY - card.height),
                                width: card.width, height: card.height)
                            let rectSpill = sourceSpill(rect, source: source, fontSize: size)
                            if rectSpill < (best?.spill ?? .infinity) - 0.001 { best = (rect, rectSpill) }
                        }
                        guard let best else { continue }
                        guard far || best.spill <= spill - 0.1 else { continue }
                        guard overlapArea(best.rect, excluding: index) <= overlapBefore + 0.5 else { continue }
                        let card = BrowserOverlayCardLayout(rect: best.rect, maximumFontSize: size, contentInsets: insets)
                        guard shown(card) + 0.25 >= shownBefore else { continue }
                        // Readable captions (or lettering the overlay grows back toward a
                        // readable source size) keep their room.
                        guard max(shownBefore, sourceSizes[index] ?? 0) < 8.5 || best.rect.width * best.rect.height >=
                            layout.rect.width * layout.rect.height - 0.5 else { continue }
                        accepted = card
                        break search
                    }
                }
                if let accepted { result[index] = accepted }
            }
        }
        return result
    }

    /// Solve every connected overlap cluster as one bounded assignment. The
    /// previous coordinate-descent fallback could only move one card at a
    /// time, so it anchored the rest and threw a single translation far away.
    /// Keeping several partial assignments lets neighboring cards share the
    /// displacement and selects the zero-overlap result with the least total
    /// squared movement from the original layout.
    private static func jointlyPackingOverlappingClusters(
        _ layouts: [BrowserOverlayCardLayout],
        sources: [CGRect],
        sourceVerticals: [Bool]?,
        viewport: CGSize,
        placementBounds: CGRect,
        preferredRects: [CGRect],
        allowsDetachedPlacements: [Bool]
    ) -> [BrowserOverlayCardLayout] {
        var result = layouts
        let clusters = overlapClusters(preferredRects)
        for cluster in clusters where cluster.count > 1 {
            if Task.isCancelled { return result }
            // Irregular real pages form several medium clusters; each used to
            // keep 192 states even when the whole page contained 29+ cards.
            // Bound those combinations as well as the single dense-cluster case.
            let beamWidth = cluster.count > 24 ? 4 : (cluster.count > 12 ? 16 : (cluster.count > 4 ? 32 : 192))
            let candidateLimit = cluster.count > 24 ? 24 : (cluster.count > 12 ? 48 : (cluster.count > 4 ? 96 : 160))
            guard cluster.contains(where: { index in
                allowsDetachedPlacements.indices.contains(index) &&
                    allowsDetachedPlacements[index]
            }) else { continue }
            let external = result.indices.compactMap { index in
                cluster.contains(index) ? nil : result[index].rect
            }
            let externalGeometry = external.map(BrowserOverlayCollisionGeometry.init)
            let preferredClusterRects = cluster.map { preferredRects[$0] }
            let clusterBounds = preferredClusterRects.dropFirst().reduce(
                preferredClusterRects[0]
            ) { $0.union($1) }
            let horizontalChain =
                clusterBounds.width >= clusterBounds.height * 1.35
            let verticalChain =
                clusterBounds.height >= clusterBounds.width * 1.35
            let order = cluster.sorted { left, right in
                if horizontalChain,
                   abs(preferredRects[left].midX -
                       preferredRects[right].midX) > 0.25 {
                    return preferredRects[left].midX <
                        preferredRects[right].midX
                }
                if verticalChain,
                   abs(preferredRects[left].midY -
                       preferredRects[right].midY) > 0.25 {
                    return preferredRects[left].midY <
                        preferredRects[right].midY
                }
                let leftArea = layouts[left].rect.width *
                    layouts[left].rect.height
                let rightArea = layouts[right].rect.width *
                    layouts[right].rect.height
                if abs(leftArea - rightArea) > 0.25 {
                    return leftArea > rightArea
                }
                return left < right
            }
            var beam = [JointPackingState(
                placements: [:],
                overlapPairs: 0,
                overlapArea: 0,
                maximumSquaredDisplacement: 0,
                totalSquaredDisplacement: 0,
                totalHorizontalDisplacement: 0,
                totalVerticalDisplacement: 0
            )]
            for index in order {
                if Task.isCancelled { return result }
                let comparisonKeys = ((beam.first.map { Array($0.placements.keys) } ?? []) + [index]).sorted()
                let canDetach =
                    allowsDetachedPlacements.indices.contains(index) &&
                    allowsDetachedPlacements[index]
                let baseCandidates = jointPackingCandidates(
                    for: index,
                    cluster: cluster,
                    layouts: layouts,
                    preferredRects: preferredRects,
                    source: clippedSource(
                        sources[index],
                        viewport: viewport
                    ),
                    placementBounds: placementBounds,
                    canDetach: canDetach
                )
                var next: [JointPackingState] = []
                next.reserveCapacity(
                    min(30_720, beam.count * baseCandidates.count)
                )
                for state in beam {
                    let placed = Array(state.placements.values)
                    let candidates = orderedUniquePackingCandidates(
                        baseCandidates + dynamicPackingCandidates(
                            for: index,
                            layouts: layouts,
                            preferredRects: preferredRects,
                            placementBounds: placementBounds,
                            placed: placed
                        ),
                        preferredRect: preferredRects[index],
                        limit: candidateLimit
                    )
                    let intersections = placed.map(BrowserOverlayCollisionGeometry.init) + externalGeometry
                    for candidate in candidates {
                        var addedPairs = 0
                        var addedArea: CGFloat = 0
                        let geometry = BrowserOverlayCollisionGeometry(candidate)
                        for obstacle in intersections {
                            let area = geometry.overlapArea(with: obstacle, minimumExtent: 0.25)
                            guard area > 0 else { continue }
                            addedPairs += 1
                            addedArea += area
                        }
                        let dx = candidate.midX - preferredRects[index].midX
                        let dy = candidate.midY - preferredRects[index].midY
                        var placements = state.placements
                        placements[index] = candidate
                        next.append(JointPackingState(
                            placements: placements,
                            overlapPairs: state.overlapPairs + addedPairs,
                            overlapArea: state.overlapArea + addedArea,
                            maximumSquaredDisplacement: max(
                                state.maximumSquaredDisplacement,
                                dx * dx + dy * dy
                            ),
                            totalSquaredDisplacement:
                                state.totalSquaredDisplacement + dx * dx + dy * dy,
                            totalHorizontalDisplacement:
                                state.totalHorizontalDisplacement + dx,
                            totalVerticalDisplacement:
                                state.totalVerticalDisplacement + dy
                        ))
                    }
                }
                next.sort { jointPackingStateIsBetter($0, $1, placementKeys: comparisonKeys) }
                if next.count > beamWidth {
                    next.removeLast(next.count - beamWidth)
                }
                beam = next
                if beam.isEmpty { break }
            }
            guard let best = beam.min(by: { jointPackingStateIsBetter($0, $1) }),
                  best.placements.count == cluster.count
            else { continue }
            let currentOverlap = overlapScore(
                cluster.map { result[$0].rect },
                external: external
            )
            var currentState = JointPackingState(
                placements: [:],
                overlapPairs: currentOverlap.pairs,
                overlapArea: currentOverlap.area,
                maximumSquaredDisplacement: 0,
                totalSquaredDisplacement: 0,
                totalHorizontalDisplacement: 0,
                totalVerticalDisplacement: 0
            )
            for index in cluster {
                let rect = result[index].rect
                let dx = rect.midX - preferredRects[index].midX
                let dy = rect.midY - preferredRects[index].midY
                currentState.placements[index] = rect
                currentState.maximumSquaredDisplacement = max(
                    currentState.maximumSquaredDisplacement,
                    dx * dx + dy * dy
                )
                currentState.totalSquaredDisplacement += dx * dx + dy * dy
                currentState.totalHorizontalDisplacement += dx
                currentState.totalVerticalDisplacement += dy
            }
            if jointPackingStateIsBetter(best, currentState) {
                for index in cluster {
                    guard let rect = best.placements[index] else { continue }
                    result[index] = BrowserOverlayCardLayout(
                        rect: rect,
                        maximumFontSize: result[index].maximumFontSize,
                        contentInsets: result[index].contentInsets
                    )
                }
            }
            // Even a non-overlapping greedy result can have crossed the source
            // order by ejecting one card beyond its neighbor. Always run the
            // source-row pass; it restores the original X order and lets the
            // neighboring cards share the horizontal displacement.
            guard let sourceBand = horizontallyPackedSourceBand(
                cluster: cluster,
                sources: sources,
                sourceVerticals: sourceVerticals,
                layouts: result,
                preferredRects: preferredRects,
                placementBounds: placementBounds,
                external: external
            ) else { continue }
            // A caption stack can share a cluster with nearby credit columns.
            // The row-order fallback must not replace a collision-free, small
            // vertical nudge with a much longer sideways move. Keep its legacy
            // reading-order repair for vertical manga columns.
            if let sourceVerticals, sourceVerticals.count == sources.count,
               cluster.allSatisfy({ !sourceVerticals[$0] }),
               !BrowserOverlayCollisionGeometry.hasOverlap(in: cluster.map { result[$0].rect }, external: external) {
                func movement(_ rect: CGRect, at index: Int) -> CGFloat {
                    let dx = rect.midX - preferredRects[index].midX
                    let dy = rect.midY - preferredRects[index].midY
                    return dx * dx + dy * dy
                }
                let currentMovement = cluster.reduce(CGFloat.zero) { $0 + movement(result[$1].rect, at: $1) }
                let rowMovement = sourceBand.reduce(CGFloat.zero) { $0 + movement($1.value, at: $1.key) }
                if rowMovement > currentMovement + 0.25 { continue }
            }
            for (index, rect) in sourceBand {
                result[index] = BrowserOverlayCardLayout(
                    rect: rect,
                    maximumFontSize: result[index].maximumFontSize,
                    contentInsets: result[index].contentInsets
                )
            }
        }
        return result
    }

    /// Dense manga dialogue often forms one visual row of tall vertical source
    /// columns. Once collision contraction makes their widths fit, keep every
    /// card on its source y and solve only x. Do not classify the row by its
    /// union aspect ratio: a short run of two or three tall columns is naturally
    /// taller than it is wide, but still needs to move together horizontally.
    private static func horizontallyPackedSourceBand(
        cluster: [Int],
        sources: [CGRect],
        sourceVerticals: [Bool]?,
        layouts: [BrowserOverlayCardLayout],
        preferredRects: [CGRect],
        placementBounds: CGRect,
        external: [CGRect]
    ) -> [Int: CGRect]? {
        let order = cluster.sorted {
            preferredRects[$0].midX < preferredRects[$1].midX
        }
        let spacing: CGFloat = 0.5
        func overlapsVertically(_ left: CGRect, _ right: CGRect) -> Bool {
            min(left.maxY, right.maxY) - max(left.minY, right.minY) > 0.25
        }

        // Only a source cluster classified as horizontal in one source column
        // can be a stack of caption lines. Unknown or mixed writing directions
        // retain the existing column-packing behavior.
        var horizontalCaptionColumn = sourceVerticals.map { orientations in
            orientations.count == sources.count && order.allSatisfy {
                !orientations[$0]
            }
        } ?? false
        if horizontalCaptionColumn {
            for (position, index) in order.enumerated() {
                for previous in order[..<position] {
                    let narrowerWidth = min(sources[index].width, sources[previous].width)
                    let overlapWidth = min(sources[index].maxX, sources[previous].maxX) -
                        max(sources[index].minX, sources[previous].minX)
                    if narrowerWidth <= 0 || overlapWidth < narrowerWidth * 0.75 {
                        horizontalCaptionColumn = false
                        break
                    }
                }
                if !horizontalCaptionColumn { break }
            }
        }
        if horizontalCaptionColumn {
            // Minimum height or insets can make distinct original lines touch.
            // Do not turn their padded envelopes into side-by-side columns.
            for (position, index) in order.enumerated() {
                let proposed = CGRect(
                    x: preferredRects[index].minX,
                    y: preferredRects[index].minY,
                    width: layouts[index].rect.width,
                    height: layouts[index].rect.height
                )
                for previous in order[..<position] {
                    let previousProposed = CGRect(
                        x: preferredRects[previous].minX,
                        y: preferredRects[previous].minY,
                        width: layouts[previous].rect.width,
                        height: layouts[previous].rect.height
                    )
                    if overlapsVertically(proposed, previousProposed),
                       !overlapsVertically(sources[index], sources[previous]) {
                        return nil
                    }
                }
            }
        }

        var row: [Int: CGRect] = [:]
        for (position, index) in order.enumerated() {
            let size = layouts[index].rect.size
            var x = preferredRects[index].midX - size.width / 2
            let y = preferredRects[index].minY
            let proposed = CGRect(x: x, y: y, width: size.width, height: size.height)
            for previous in order[..<position] {
                guard let previousRect = row[previous],
                      overlapsVertically(proposed, previousRect)
                else { continue }
                x = max(x, previousRect.maxX + spacing)
            }
            let rect = CGRect(
                x: x,
                y: y,
                width: size.width,
                height: size.height
            )
            row[index] = rect
        }
        guard let first = order.first,
              let firstRect = row[first]
        else { return nil }
        let rowRects = order.compactMap { row[$0] }
        let rowBounds = rowRects.dropFirst().reduce(firstRect) {
            $0.union($1)
        }
        let preferredRowRects = order.map { preferredRects[$0] }
        let preferredBounds = preferredRowRects.dropFirst().reduce(
            preferredRowRects[0]
        ) { $0.union($1) }
        let requestedDX = preferredBounds.midX - rowBounds.midX
        let dx = min(
            placementBounds.maxX - rowBounds.maxX,
            max(placementBounds.minX - rowBounds.minX, requestedDX)
        )
        if abs(dx) > 0.001 {
            for index in order {
                row[index] = row[index]?.offsetBy(dx: dx, dy: 0)
            }
        }
        // After correcting whole-row bias, use any remaining gutter to pull
        // each card toward its own source. Running this last avoids undoing
        // the local attachment with a second global recenter.
        for _ in 0..<2 {
            for (position, index) in order.enumerated() {
                guard let current = row[index] else { continue }
                var lowerX = placementBounds.minX
                for previous in order[..<position] {
                    guard let previousRect = row[previous],
                          overlapsVertically(current, previousRect)
                    else { continue }
                    lowerX = max(lowerX, previousRect.maxX + spacing)
                }
                var upperX = placementBounds.maxX - current.width
                for next in order[(position + 1)...] {
                    guard let nextRect = row[next],
                          overlapsVertically(current, nextRect)
                    else { continue }
                    upperX = min(
                        upperX,
                        nextRect.minX - spacing - current.width
                    )
                }
                guard lowerX <= upperX else { continue }
                let preferredX = preferredRects[index].midX -
                    current.width / 2
                row[index] = CGRect(
                    x: min(upperX, max(lowerX, preferredX)),
                    y: current.minY,
                    width: current.width,
                    height: current.height
                )
            }
        }
        let rects = order.compactMap { row[$0] }
        guard rects.count == order.count,
              // A row wider than the image cannot be recentered into it.
              // Reject that fallback instead of hiding the leading translation
              // beyond the viewport merely to achieve zero pairwise overlap.
              rects.allSatisfy({ placementBounds.contains($0) }),
              !BrowserOverlayCollisionGeometry.hasOverlap(in: rects, external: external)
        else { return nil }
        return row
    }

    private static func jointPackingStateIsBetter(
        _ left: JointPackingState,
        _ right: JointPackingState,
        placementKeys: [Int]? = nil
    ) -> Bool {
        if left.overlapPairs != right.overlapPairs {
            return left.overlapPairs < right.overlapPairs
        }
        if abs(left.overlapArea - right.overlapArea) > 0.25 {
            return left.overlapArea < right.overlapArea
        }
        // Minimize the movement paid by the whole cluster first. Squared
        // distance already makes a single far outlier expensive, while still
        // allowing a short chain shift into a neighbor's vacated bbox.
        if abs(
            left.totalSquaredDisplacement -
                right.totalSquaredDisplacement
        ) > 0.25 {
            return left.totalSquaredDisplacement <
                right.totalSquaredDisplacement
        }
        if abs(
            left.maximumSquaredDisplacement -
                right.maximumSquaredDisplacement
        ) > 0.25 {
            return left.maximumSquaredDisplacement <
                right.maximumSquaredDisplacement
        }
        let leftCount = CGFloat(max(1, left.placements.count))
        let rightCount = CGFloat(max(1, right.placements.count))
        let leftCentroidDrift =
            pow(left.totalHorizontalDisplacement / leftCount, 2) +
            pow(left.totalVerticalDisplacement / leftCount, 2)
        let rightCentroidDrift =
            pow(right.totalHorizontalDisplacement / rightCount, 2) +
            pow(right.totalVerticalDisplacement / rightCount, 2)
        if abs(leftCentroidDrift - rightCentroidDrift) > 0.25 {
            return leftCentroidDrift < rightCentroidDrift
        }
        let keys = placementKeys ?? Set(left.placements.keys)
            .union(right.placements.keys)
            .sorted()
        for key in keys {
            guard let leftRect = left.placements[key],
                  let rightRect = right.placements[key]
            else { continue }
            if abs(leftRect.minX - rightRect.minX) > 0.25 {
                return leftRect.minX < rightRect.minX
            }
            if abs(leftRect.minY - rightRect.minY) > 0.25 {
                return leftRect.minY < rightRect.minY
            }
        }
        return false
    }

    private static func overlapScore(
        _ rects: [CGRect],
        external: [CGRect] = []
    ) -> (pairs: Int, area: CGFloat) {
        let geometry = rects.map(BrowserOverlayCollisionGeometry.init)
        let obstacles = external.map(BrowserOverlayCollisionGeometry.init)
        var pairs = 0
        var area: CGFloat = 0
        for left in geometry.indices {
            for right in (left + 1)..<geometry.count {
                let overlap = geometry[left].overlapArea(with: geometry[right], minimumExtent: 0.25)
                guard overlap > 0 else { continue }
                pairs += 1
                area += overlap
            }
            for obstacle in obstacles {
                let overlap = geometry[left].overlapArea(with: obstacle, minimumExtent: 0.25)
                guard overlap > 0 else { continue }
                pairs += 1
                area += overlap
            }
        }
        return (pairs, area)
    }

    private static func hasAnyCardOverlap(
        _ layouts: [BrowserOverlayCardLayout]
    ) -> Bool {
        BrowserOverlayCollisionGeometry.hasOverlap(in: layouts.map(\.rect))
    }

    private static func overlapClusters(_ rects: [CGRect]) -> [[Int]] {
        // Cards separated by only a narrow gutter still constrain one
        // another's useful movement. Include those neighbors so a crowded row
        // can shift together instead of treating them as fixed obstacles and
        // ejecting only the final overlapping card.
        let interactionPadding: CGFloat = 24
        var remaining = Set(rects.indices)
        var clusters: [[Int]] = []
        while let seed = remaining.first {
            remaining.remove(seed)
            var cluster = [seed]
            var cursor = 0
            while cursor < cluster.count {
                let current = cluster[cursor]
                cursor += 1
                let neighbors = remaining.filter { index in
                    rects[current]
                        .insetBy(
                            dx: -interactionPadding,
                            dy: -interactionPadding
                        )
                        .intersects(rects[index])
                }
                for neighbor in neighbors {
                    remaining.remove(neighbor)
                    cluster.append(neighbor)
                }
            }
            clusters.append(cluster.sorted())
        }
        return clusters
    }

    private static func jointPackingCandidates(
        for index: Int,
        cluster: [Int],
        layouts: [BrowserOverlayCardLayout],
        preferredRects: [CGRect],
        source: CGRect,
        placementBounds: CGRect,
        canDetach: Bool
    ) -> [CGRect] {
        let layoutRect = layouts[index].rect
        let original = CGRect(
            x: preferredRects[index].midX - layoutRect.width / 2,
            y: preferredRects[index].midY - layoutRect.height / 2,
            width: layoutRect.width,
            height: layoutRect.height
        )
        guard canDetach else { return [original] }
        let spacing: CGFloat = 2
        guard placementBounds.width >= original.width,
              placementBounds.height >= original.height
        else { return [original] }
        let minimumX = placementBounds.minX
        let minimumY = placementBounds.minY
        let maximumX = placementBounds.maxX - original.width
        let maximumY = placementBounds.maxY - original.height
        let clusterRects = cluster.map { clusterIndex in
            let rect = layouts[clusterIndex].rect
            let preferred = preferredRects[clusterIndex]
            return CGRect(
                x: preferred.midX - rect.width / 2,
                y: preferred.midY - rect.height / 2,
                width: rect.width,
                height: rect.height
            )
        }
        var xSeeds: [CGFloat] = [
            original.minX,
            source.minX,
            source.midX - original.width / 2,
            source.maxX - original.width,
            minimumX,
            maximumX,
        ]
        var ySeeds: [CGFloat] = [
            original.minY,
            source.minY,
            source.midY - original.height / 2,
            source.maxY - original.height,
            minimumY,
            maximumY,
        ]
        for rect in clusterRects {
            // A jointly moved neighbor vacates its old bbox. Make that exact
            // slot available instead of offering only positions outside its
            // edges, which prevents short chain shifts through the cluster.
            xSeeds.append(rect.minX)
            xSeeds.append(rect.midX - original.width / 2)
            xSeeds.append(rect.maxX - original.width)
            xSeeds.append(rect.minX - original.width - spacing)
            xSeeds.append(rect.maxX + spacing)
            ySeeds.append(rect.minY)
            ySeeds.append(rect.midY - original.height / 2)
            ySeeds.append(rect.maxY - original.height)
            ySeeds.append(rect.minY - original.height - spacing)
            ySeeds.append(rect.maxY + spacing)
        }
        // A cluster of four equal cards needs three successive neighbor slots,
        // not merely the edge of one original card. Add a bounded lattice in
        // both axes so the beam can distribute the entire group around its
        // source centroid instead of ejecting the last card by one full height.
        for step in 1...cluster.count {
            let horizontalOffset = CGFloat(step) *
                (original.width + spacing)
            let verticalOffset = CGFloat(step) *
                (original.height + spacing)
            xSeeds.append(original.minX - horizontalOffset)
            xSeeds.append(original.minX + horizontalOffset)
            ySeeds.append(original.minY - verticalOffset)
            ySeeds.append(original.minY + verticalOffset)
        }
        // Also expose complete row/column slots from both placement edges.
        // Without these, an adjacent non-overlapping card can become a fixed
        // wall and the last card is offered only a distant perpendicular slot.
        for step in 0..<cluster.count {
            let horizontalOffset = CGFloat(step) *
                (original.width + spacing)
            let verticalOffset = CGFloat(step) *
                (original.height + spacing)
            xSeeds.append(minimumX + horizontalOffset)
            xSeeds.append(maximumX - horizontalOffset)
            ySeeds.append(minimumY + verticalOffset)
            ySeeds.append(maximumY - verticalOffset)
        }
        let xValues = uniqueValues(xSeeds).map {
            min(max(minimumX, $0), maximumX)
        }
        let yValues = uniqueValues(ySeeds).map {
            min(max(minimumY, $0), maximumY)
        }
        var candidates = xValues.flatMap { x in
            yValues.map { y in
                CGRect(
                    x: x,
                    y: y,
                    width: original.width,
                    height: original.height
                )
            }
        }
        candidates = orderedPackingCandidates(candidates, preferredRect: original)
        let alignedY = min(max(minimumY, original.minY), maximumY)
        let alignedX = min(max(minimumX, original.minX), maximumX)
        var alignedCandidates = xValues.map { x in
            CGRect(
                x: x,
                y: alignedY,
                width: original.width,
                height: original.height
            )
        }
        alignedCandidates.append(contentsOf: yValues.map { y in
            CGRect(
                x: alignedX,
                y: y,
                width: original.width,
                height: original.height
            )
        })
        alignedCandidates.sort { left, right in
            let leftDistance = hypot(
                left.midX - original.midX,
                left.midY - original.midY
            )
            let rightDistance = hypot(
                right.midX - original.midX,
                right.midY - original.midY
            )
            return leftDistance < rightDistance
        }
        return uniquePackingCandidatesInOrder(alignedCandidates + candidates, limit: 128)
    }

    /// Candidate slots created by earlier beam assignments cannot be known
    /// from the original geometry. Offer the exact four sides of every card
    /// already moved in this partial state so later cards can perform a short
    /// chain shift through the newly vacated/adjacent space.
    private static func dynamicPackingCandidates(
        for index: Int,
        layouts: [BrowserOverlayCardLayout],
        preferredRects: [CGRect],
        placementBounds: CGRect,
        placed: [CGRect]
    ) -> [CGRect] {
        let size = layouts[index].rect.size
        let preferred = preferredRects[index]
        let original = CGRect(
            x: preferred.midX - size.width / 2,
            y: preferred.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let minimumX = placementBounds.minX
        let minimumY = placementBounds.minY
        let maximumX = placementBounds.maxX - size.width
        let maximumY = placementBounds.maxY - size.height
        guard maximumX >= minimumX, maximumY >= minimumY else { return [] }
        let spacing: CGFloat = 2
        var result: [CGRect] = []
        for neighbor in placed {
            let horizontalX = [
                neighbor.minX - size.width - spacing,
                neighbor.maxX + spacing,
            ]
            let horizontalY = [
                original.minY,
                neighbor.minY,
                neighbor.midY - size.height / 2,
                neighbor.maxY - size.height,
            ]
            for x in horizontalX {
                for y in horizontalY {
                    result.append(CGRect(
                        x: min(max(minimumX, x), maximumX),
                        y: min(max(minimumY, y), maximumY),
                        width: size.width,
                        height: size.height
                    ))
                }
            }
            let verticalY = [
                neighbor.minY - size.height - spacing,
                neighbor.maxY + spacing,
            ]
            let verticalX = [
                original.minX,
                neighbor.minX,
                neighbor.midX - size.width / 2,
                neighbor.maxX - size.width,
            ]
            for y in verticalY {
                for x in verticalX {
                    result.append(CGRect(
                        x: min(max(minimumX, x), maximumX),
                        y: min(max(minimumY, y), maximumY),
                        width: size.width,
                        height: size.height
                    ))
                }
            }
        }
        return result
    }

    /// Compute geometry once per candidate, retaining the exact existing
    /// comparator and stable input order during the much larger sort.
    static func orderedPackingCandidates(_ candidates: [CGRect], preferredRect: CGRect) -> [CGRect] {
        let center = CGPoint(x: preferredRect.midX, y: preferredRect.midY)
        return candidates.map { rect in
            let dx = rect.midX - center.x
            let dy = rect.midY - center.y
            return (rect: rect, distance: dx * dx + dy * dy, x: rect.minX, y: rect.minY)
        }.sorted { left, right in
            if abs(left.distance - right.distance) > 0.25 { return left.distance < right.distance }
            if abs(left.x - right.x) > 0.25 { return left.x < right.x }
            return left.y < right.y
        }.map(\.rect)
    }

    private static func orderedUniquePackingCandidates(
        _ candidates: [CGRect],
        preferredRect: CGRect,
        limit: Int
    ) -> [CGRect] {
        let ordered = orderedPackingCandidates(candidates, preferredRect: preferredRect)
        return uniquePackingCandidatesInOrder(ordered, limit: limit)
    }

    private struct PackingCell: Hashable {
        let x: CGFloat
        let y: CGFloat
    }

    /// Preserve the original first-wins 0.25-point rule without comparing each
    /// candidate against every accepted CGRect in every beam state.
    static func uniquePackingCandidatesInOrder(_ ordered: [CGRect], limit: Int) -> [CGRect] {
        var cells: [PackingCell: [CGPoint]] = [:]
        var unique: [CGRect] = []
        for candidate in ordered {
            let point = CGPoint(x: candidate.minX, y: candidate.minY)
            let cell = PackingCell(x: floor(point.x * 4), y: floor(point.y * 4))
            // Clamped candidates most often repeat their own cell. Probe it
            // first, preserving the same any-neighbour proximity predicate.
            var duplicate = cells[cell]?.contains(where: {
                abs($0.x - point.x) < 0.25 && abs($0.y - point.y) < 0.25
            }) == true
            for dx: CGFloat in [-1, 0, 1] where !duplicate {
                for dy: CGFloat in [-1, 0, 1] where dx != 0 || dy != 0 {
                    if cells[PackingCell(x: cell.x + dx, y: cell.y + dy)]?.contains(where: {
                        abs($0.x - point.x) < 0.25 && abs($0.y - point.y) < 0.25
                    }) == true {
                        duplicate = true
                        break
                    }
                }
                if duplicate { break }
            }
            guard !duplicate else { continue }
            unique.append(candidate)
            cells[cell, default: []].append(point)
            if unique.count == limit { break }
        }
        return unique
    }

    /// Source-containing placement has no solution when OCR boxes themselves
    /// overlap. Translated cards may use a nearby empty slot without creating
    /// a second, text-free card over the original location.
    private static func resolveDetachedCollision(
        _ candidate: CGRect,
        source: CGRect,
        occupied: [CGRect],
        placementBounds: CGRect
    ) -> CGRect? {
        guard placementBounds.width >= candidate.width,
              placementBounds.height >= candidate.height
        else { return nil }
        // Once a translated card has to detach, other OCR source boxes are no
        // longer useful obstacles: every one owns its own translated card.
        // Treating those narrow source columns as blocked space caused the
        // whole cluster to jump toward the viewport edges despite nearby gaps.
        let obstacles = occupied
        let spacing: CGFloat = 2
        let minimumX = placementBounds.minX
        let minimumY = placementBounds.minY
        let maximumX = placementBounds.maxX - candidate.width
        let maximumY = placementBounds.maxY - candidate.height
        let xValues = exactUniqueValues(uniqueValues([
            candidate.minX,
            source.minX,
            source.midX - candidate.width / 2,
            source.maxX - candidate.width,
            minimumX,
            maximumX,
        ] + obstacles.flatMap { other in
            [
                other.minX - candidate.width - spacing,
                other.maxX + spacing,
            ]
        }).map { min(max(minimumX, $0), maximumX) })
        let yValues = exactUniqueValues(uniqueValues([
            candidate.minY,
            source.minY,
            source.midY - candidate.height / 2,
            source.maxY - candidate.height,
            minimumY,
            maximumY,
        ] + obstacles.flatMap { other in
            [
                other.minY - candidate.height - spacing,
                other.maxY + spacing,
            ]
        }).map { min(max(minimumY, $0), maximumY) })
        return xValues.flatMap { x in
            yValues.map { y in
                CGRect(
                    x: x,
                    y: y,
                    width: candidate.width,
                    height: candidate.height
                )
            }
        }.filter { rect in
            return !hasVisualCollision(
                rect,
                occupied: occupied,
                reservedSources: []
            )
        }.min { left, right in
            let leftDX = left.midX - candidate.midX
            let leftDY = left.midY - candidate.midY
            let rightDX = right.midX - candidate.midX
            let rightDY = right.midY - candidate.midY
            return leftDX * leftDX + leftDY * leftDY <
                rightDX * rightDX + rightDY * rightDY
        }
    }

    static func plan(
        source: CGRect,
        text: String,
        vertical: Bool,
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [CGRect],
        sourceVertical: Bool? = nil,
        singleVerticalColumn: Bool = false,
        reservedSources: [CGRect] = [],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> BrowserOverlayCardLayout {
        plan(
            source: source,
            variants: [.plain(text, vertical: vertical)],
            settings: settings,
            viewport: viewport,
            occupied: occupied,
            sourceVertical: sourceVertical,
            singleVerticalColumn: singleVerticalColumn,
            reservedSources: reservedSources,
            measurementCache: measurementCache
        )
    }

    static func plan(
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [CGRect],
        sourceVertical: Bool? = nil,
        singleVerticalColumn: Bool = false,
        reservedSources: [CGRect] = [],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> BrowserOverlayCardLayout {
        guard viewport.width > 0, viewport.height > 0 else {
            return BrowserOverlayCardLayout(
                rect: .null,
                maximumFontSize: minimumAutoFontSize,
                contentInsets: BrowserOverlayCardTextInsets.regular
            )
        }
        let clippedSource = source.standardized.intersection(
            CGRect(origin: .zero, size: viewport)
        )
        guard !clippedSource.isNull,
              clippedSource.width > 0,
              clippedSource.height > 0
        else {
            return BrowserOverlayCardLayout(
                rect: .null,
                maximumFontSize: minimumAutoFontSize,
                contentInsets: BrowserOverlayCardTextInsets.regular
            )
        }
        let safeVariants = variants.isEmpty
            ? [.plain("", vertical: false)]
            : variants
        let isExactVerticalReplacement =
            settings.textPlacement == .replace &&
            sourceVertical == true &&
            safeVariants.allSatisfy(\.vertical)
        if isExactVerticalReplacement
        {
            let contentInsets = singleVerticalColumn
                ? BrowserOverlayCardTextInsets.singleVerticalColumn
                : BrowserOverlayCardTextInsets.regular
            let fittedAtNormalScale = singleVerticalColumn
                ? fittedSingleVerticalColumnFontSize(
                    variants: safeVariants,
                    size: clippedSource.size,
                    maximum: maximumAutoFontSize,
                    measurementCache: measurementCache
                )
                : fittedSourceFontSize(
                    variants: safeVariants,
                    size: clippedSource.size,
                    minimumHorizontalUnits: 1,
                    minimum: minimumSingleVerticalColumnFontSize,
                    maximum: maximumAutoFontSize,
                    contentInsets: contentInsets,
                    measurementCache: measurementCache
                )
            let fittedInSource = fittedAtNormalScale
            let readableFloor = minimumReadableFontSize(
                variants: safeVariants,
                settings: settings
            )
            guard fittedInSource + 0.001 >= readableFloor,
                  variantsFit(
                      safeVariants,
                      size: clippedSource.size,
                      fontSize: fittedInSource,
                      minimumHorizontalUnits: 1,
                      contentInsets: contentInsets,
                      measurementCache: measurementCache
                  )
            else {
                // A valid OCR source must never disappear merely because its
                // text cannot fully fit the source bbox. Exact vertical
                // replacement remains attached to that bbox and paints at the
                // five-point emergency floor; clipping is preferable to
                // dropping the OCR/translation card altogether.
                return BrowserOverlayCardLayout(
                    rect: clippedSource,
                    maximumFontSize: bestEffortFontSize(
                        settings: settings,
                        fittedFontSize: fittedInSource
                    ),
                    contentInsets: contentInsets
                )
            }
            // Replacement cards must stay on the vertical OCR bbox even when
            // first-frame merging has not yet settled the single-column bit.
            // Growing a long vertical string down the page covers unrelated
            // content; fitting inside the source is the stable fallback.
            return BrowserOverlayCardLayout(
                rect: clippedSource,
                maximumFontSize: fittedInSource,
                contentInsets: contentInsets
            )
        }
        let containsHorizontal = safeVariants.contains { !$0.vertical }
        let contentInsets = plannedContentInsets(
            source: clippedSource,
            settings: settings,
            vertical: !containsHorizontal
        )
        let isHorizontalTranslationOfVerticalSource =
            (sourceVertical ?? false) && containsHorizontal
        // Six Hangul cells remain usable at the 5pt emergency floor while
        // avoiding the old eight-cell card that routinely crossed manga gutters.
        let minimumHorizontalUnits: CGFloat = isHorizontalTranslationOfVerticalSource ? 6 : 1
        // Legacy expanded presentation remains readable when decoding older data.
        let usesLegacyExpandedPresentation = settings.textPlacement == .expanded
        let minimumExpandedSize = usesLegacyExpandedPresentation
            ? (safeVariants.allSatisfy(\.vertical)
                ? CGSize(width: 64, height: 112)
                : CGSize(width: 112, height: 36))
            : .zero
        let maximumEnvelopeWidth: CGFloat = {
            guard !usesLegacyExpandedPresentation,
                  isHorizontalTranslationOfVerticalSource
            else {
                return viewport.width
            }
            let horizontalInsets = contentInsets.left + contentInsets.right
            let readableFloor =
                minimumHorizontalUnits * minimumReadableFontSize(
                    variants: safeVariants,
                    settings: settings
                ) +
                horizontalInsets
            let proportionalCap = min(
                clippedSource.width * 2.25,
                max(
                    clippedSource.width * 1.75,
                    clippedSource.height * 0.45
                )
            )
            return min(
                viewport.width,
                max(clippedSource.width, readableFloor, proportionalCap)
            )
        }()

        let maximumFontSize: CGFloat
        let fittedBase = usesLegacyExpandedPresentation
            ? maximumAutoFontSize
            : fittedSourceFontSize(
                variants: safeVariants,
                size: clippedSource.size,
                minimumHorizontalUnits: minimumHorizontalUnits,
                maximum: maximumAutoFontSize,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            )
        let scaledMinimum = minimumReadableFontSize(
            variants: safeVariants,
            settings: settings
        )
        let desired = min(64, max(scaledMinimum, fittedBase))
        maximumFontSize = fittedEnvelopeFontSize(
            variants: safeVariants,
            source: clippedSource,
            minimumSize: minimumExpandedSize,
            minimumHorizontalUnits: minimumHorizontalUnits,
            viewport: viewport,
            maximumWidth: maximumEnvelopeWidth,
            minimum: scaledMinimum,
            maximum: desired,
            contentInsets: contentInsets,
            measurementCache: measurementCache
        )

        let requested: CGSize
        if !usesLegacyExpandedPresentation,
           variantsFit(
               safeVariants,
               size: clippedSource.size,
               fontSize: maximumFontSize,
               minimumHorizontalUnits: minimumHorizontalUnits,
               contentInsets: contentInsets,
               measurementCache: measurementCache
           )
        {
            requested = clippedSource.size
        } else {
            guard let readableSize = readableEnvelopeSize(
                variants: safeVariants,
                source: clippedSource,
                minimumSize: minimumExpandedSize,
                minimumHorizontalUnits: minimumHorizontalUnits,
                fontSize: maximumFontSize,
                viewport: viewport,
                maximumWidth: maximumEnvelopeWidth,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            ) else {
                return bestEffortAttachedLayout(
                    source: clippedSource,
                    variants: safeVariants,
                    settings: settings,
                    viewport: viewport,
                    occupied: occupied,
                    reservedSources: reservedSources,
                    contentInsets: contentInsets,
                    maximumWidth: maximumEnvelopeWidth,
                    measurementCache: measurementCache
                )
            }
            requested = readableSize
        }
        let anchored = anchoredRect(
            source: clippedSource,
            requested: requested,
            viewport: viewport
        )
        return resolveCollisionAwareLayout(
            BrowserOverlayCardLayout(
                rect: anchored,
                maximumFontSize: maximumFontSize,
                contentInsets: contentInsets
            ),
            source: clippedSource,
            variants: safeVariants,
            settings: settings,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport,
            measurementCache: measurementCache
        )
    }

    /// Returns only preceding cards that could overlap any legal collision
    /// placement for this card. The rectangle is a conservative superset of
    /// the exact candidate grid, so excluding a card cannot alter scoring;
    /// including an extra nearby card merely causes a safe cache miss.
    static func collisionDependencies(
        intrinsicLayout: BrowserOverlayCardLayout,
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [BrowserOverlayPositionedCollisionDependency],
        sourceVertical: Bool?,
        singleVerticalColumn: Bool
    ) -> [BrowserOverlayPositionedCollisionDependency] {
        guard requiresCollisionResolution(
            variants: variants,
            settings: settings,
            sourceVertical: sourceVertical,
            singleVerticalColumn: singleVerticalColumn
        ) else {
            return []
        }
        let influence = collisionInfluenceBounds(
            intrinsicLayout: intrinsicLayout,
            source: source,
            viewport: viewport
        )
        return occupied.filter { dependency in
            let intersection = influence.intersection(dependency.rect)
            return !intersection.isNull &&
                intersection.width > 0.25 &&
                intersection.height > 0.25
        }
    }

    /// Applies only the inexpensive collision phase to a cached intrinsic
    /// layout. Exact source-bounds and one-column vertical replacements retain
    /// the planner's original early-return semantics.
    static func resolvePositionedLayout(
        _ intrinsicLayout: BrowserOverlayCardLayout,
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [CGRect],
        sourceVertical: Bool?,
        singleVerticalColumn: Bool,
        reservedSources: [CGRect],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> BrowserOverlayCardLayout {
        guard requiresCollisionResolution(
            variants: variants,
            settings: settings,
            sourceVertical: sourceVertical,
            singleVerticalColumn: singleVerticalColumn
        ) else {
            return intrinsicLayout
        }
        return resolveCollisionAwareLayout(
            intrinsicLayout,
            source: clippedSource(source, viewport: viewport),
            variants: variants,
            settings: settings,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport,
            measurementCache: measurementCache
        )
    }

    /// Recover readable text only after every card position and source-coverage
    /// adjustment is final. The original layout is retained if growth cannot fit.
    static func fittingFinalHorizontalFont(
        _ layout: BrowserOverlayCardLayout,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        occupied: [CGRect],
        reservedSources: [CGRect],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> BrowserOverlayCardLayout {
        guard settings.textPlacement == .replace,
              !variants.isEmpty,
              variants.allSatisfy({ if case .plain = $0.content { return true }; return false })
        else { return layout }
        guard !(occupied + reservedSources).contains(where: { $0.contains(layout.rect) }) else { return layout }
        let hasCollision = hasVisualCollision(layout.rect, occupied: occupied, reservedSources: reservedSources)
        let vertical = variants.allSatisfy(\.vertical)
        let strictFont = vertical || hasCollision ? layout.maximumFontSize :
            (readableFontSize(variants: variants, rect: layout.rect,
                ceiling: max(layout.maximumFontSize, maximumAutoFontSize), settings: settings,
                contentInsets: layout.contentInsets, measurementCache: measurementCache,
                preservingLineLayoutAt: layout.maximumFontSize) ?? layout.maximumFontSize)
        var best = BrowserOverlayCardLayout(rect: layout.rect,
            maximumFontSize: max(layout.maximumFontSize, strictFont), contentInsets: layout.contentInsets)
        // Korean captions just above the emergency size can still be difficult
        // to read. Offer the same guarded, fixed-card refinement below 9 pt;
        // WebKit must still preserve word boundaries and avoid nearby sources.
        let refinementFloor: CGFloat = !vertical && variants.allSatisfy {
            BrowserOverlayTextFlow.wrappingScript(for: $0.displayText) == .korean
        } ? 9 : 8
        guard best.maximumFontSize < refinementFloor else { return best }
        let referenceFont = best.maximumFontSize
        let old = layout.contentInsets
        func reduced(_ value: CGFloat) -> CGFloat { min(value, max(2, value * 0.65)) }
        let compact = UIEdgeInsets(top: reduced(old.top), left: reduced(old.left),
                                   bottom: reduced(old.bottom), right: reduced(old.right))
        // Preserve the previous v10 proposal as an independently verified fallback.
        var fallback = best
        if !vertical && !hasCollision {
            for insets in [old, compact] {
                if fallback.maximumFontSize >= 8 { break }
                if let font = readableFontSize(variants: variants, rect: layout.rect,
                    ceiling: 8, settings: settings, contentInsets: insets,
                    measurementCache: measurementCache, preservingLineLayoutAt: referenceFont,
                    additionalLineAllowance: 1), font >= fallback.maximumFontSize + 0.5 {
                    fallback = .init(rect: layout.rect, maximumFontSize: font, contentInsets: insets)
                }
            }
        }
        let extraLines = min(32, max(1, Int((vertical ? layout.rect.width : layout.rect.height) / 10)))
        if vertical {
            // UIKit measures horizontal attributed strings; WebKit measures the
            // actual vertical columns and shrinks this ceiling inside the same card.
            best = .init(rect: layout.rect, maximumFontSize: 12, contentInsets: old)
        } else {
            for insets in [old, compact] {
                if best.maximumFontSize >= refinementFloor { break }
                if let font = readableFontSize(variants: variants, rect: layout.rect,
                    ceiling: 12, settings: settings, contentInsets: insets,
                    measurementCache: measurementCache, preservingLineLayoutAt: referenceFont,
                    additionalLineAllowance: extraLines), font >= best.maximumFontSize + 0.5 {
                    best = .init(rect: layout.rect, maximumFontSize: font, contentInsets: insets)
                }
            }
        }
        if fallback.maximumFontSize > best.maximumFontSize { best = fallback }
        if best.maximumFontSize > referenceFont {
            best.smallTextReference = BrowserOverlayFontReference(fontSize: referenceFont, insets: old,
                additionalLines: extraLines, exclusionRects: hasCollision ? occupied + reservedSources : [],
                fallbackFontSize: fallback.maximumFontSize, fallbackInsets: fallback.contentInsets,
                allowsEmergencyWordBreak: variants.allSatisfy { $0.allowsEmergencyKoreanWordBreak(at: referenceFont) })
        }
        return best
    }

    /// Position-only collision handling cannot solve dense manga layouts when
    /// several expanded translations all have to cover nearby source boxes.
    /// Keep the largest readable envelope that has no positive-area overlap;
    /// if necessary, contract toward the source bbox and auto-fit the text.
    private static func resolveCollisionAwareLayout(
        _ intrinsicLayout: BrowserOverlayCardLayout,
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        occupied: [CGRect],
        reservedSources: [CGRect],
        viewport: CGSize,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> BrowserOverlayCardLayout {
        guard !intrinsicLayout.rect.isNull,
              intrinsicLayout.rect.width > 0,
              intrinsicLayout.rect.height > 0
        else {
            return intrinsicLayout
        }
        let resolved = resolveCollision(
            intrinsicLayout.rect,
            source: source,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport
        )
        guard hasVisualCollision(
            resolved,
            occupied: occupied,
            reservedSources: reservedSources
        ) else {
            // The source-derived ceiling can remain at the emergency floor
            // after horizontal text has gained a collision-free envelope.
            // Recover the normal floor only inside that existing envelope;
            // never enlarge a card for this.
            let restoresNormalFloor = settings.textPlacement == .replace
                && !variants.isEmpty && variants.allSatisfy { !$0.vertical }
            let fittedCeiling = restoresNormalFloor
                ? max(intrinsicLayout.maximumFontSize, minimumAutoFontSize)
                : intrinsicLayout.maximumFontSize
            guard let readableFontSize = readableFontSize(
                variants: variants,
                rect: resolved,
                ceiling: fittedCeiling,
                settings: settings,
                contentInsets: intrinsicLayout.contentInsets,
                measurementCache: measurementCache
            ) else {
                return bestEffortAttachedLayout(
                    source: source,
                    variants: variants,
                    settings: settings,
                    viewport: viewport,
                    occupied: occupied,
                    reservedSources: reservedSources,
                    contentInsets: intrinsicLayout.contentInsets,
                    maximumWidth: intrinsicLayout.rect.width,
                    measurementCache: measurementCache
                )
            }
            return BrowserOverlayCardLayout(
                rect: resolved,
                maximumFontSize: readableFontSize,
                contentInsets: intrinsicLayout.contentInsets
            )
        }

        let safeVariants = variants.isEmpty
            ? [.plain("", vertical: false)]
            : variants
        let expandedSize = intrinsicLayout.rect.size
        var lastCollidingScale: CGFloat = 1

        // Coarse-to-fine search avoids an expensive two-dimensional packing
        // pass on every frame while still finding a near-maximal envelope.
        for step in 1...24 {
            let scale = 1 - CGFloat(step) / 24
            let candidate = collisionCandidate(
                source: source,
                expandedSize: expandedSize,
                scale: scale,
                occupied: occupied,
                reservedSources: reservedSources,
                viewport: viewport
            )
            guard !hasVisualCollision(
                candidate,
                occupied: occupied,
                reservedSources: reservedSources
            ) else {
                lastCollidingScale = scale
                continue
            }

            guard readableFontSize(
                variants: safeVariants,
                rect: candidate,
                ceiling: intrinsicLayout.maximumFontSize,
                settings: settings,
                contentInsets: intrinsicLayout.contentInsets,
                measurementCache: measurementCache
            ) != nil else {
                // Every later candidate is smaller, so it cannot restore the
                // minimum readable font size once this one no longer fits.
                break
            }

            var acceptedScale = scale
            var acceptedRect = candidate
            var rejectedScale = lastCollidingScale
            for _ in 0..<8 {
                let probeScale = (acceptedScale + rejectedScale) / 2
                let probe = collisionCandidate(
                    source: source,
                    expandedSize: expandedSize,
                    scale: probeScale,
                    occupied: occupied,
                    reservedSources: reservedSources,
                    viewport: viewport
                )
                if hasVisualCollision(
                    probe,
                    occupied: occupied,
                    reservedSources: reservedSources
                ) {
                    rejectedScale = probeScale
                } else {
                    acceptedScale = probeScale
                    acceptedRect = probe
                }
            }

            guard let maximumFontSize = readableFontSize(
                variants: safeVariants,
                rect: acceptedRect,
                ceiling: intrinsicLayout.maximumFontSize,
                settings: settings,
                contentInsets: intrinsicLayout.contentInsets,
                measurementCache: measurementCache
            ) else {
                break
            }
            return BrowserOverlayCardLayout(
                rect: acceptedRect,
                maximumFontSize: maximumFontSize,
                contentInsets: intrinsicLayout.contentInsets
            )
        }

        // A perfect packing is not always possible when OCR source boxes are
        // themselves dense or overlapping. Preserve one source-attached card
        // per OCR result: find the smallest envelope that can paint at 5pt and
        // select its least-overlapping legal placement. This deliberately
        // accepts unavoidable overlap instead of silently dropping the card.
        return bestEffortAttachedLayout(
            source: source,
            variants: safeVariants,
            settings: settings,
            viewport: viewport,
            occupied: occupied,
            reservedSources: reservedSources,
            contentInsets: intrinsicLayout.contentInsets,
            maximumWidth: intrinsicLayout.rect.width,
            measurementCache: measurementCache
        )
    }

    private static func bestEffortAttachedLayout(
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [CGRect],
        reservedSources: [CGRect],
        contentInsets: UIEdgeInsets,
        maximumWidth: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> BrowserOverlayCardLayout {
        let safeVariants = variants.isEmpty
            ? [.plain("", vertical: false)]
            : variants
        let fontSize = bestEffortFontSize(settings: settings)
        let readableSize = readableEnvelopeSize(
            variants: safeVariants,
            source: source,
            minimumSize: .zero,
            minimumHorizontalUnits: 1,
            fontSize: fontSize,
            viewport: viewport,
            maximumWidth: max(source.width, maximumWidth),
            contentInsets: contentInsets,
            measurementCache: measurementCache
        )
        // An arbitrarily long provider response may not fit even the available
        // viewport at 5pt. The source-sized card is still a visible, attached,
        // bounded result; renderer clipping/overflow policy can then degrade
        // locally without turning the whole OCR item into `.null`.
        let requested = readableSize ?? source.size
        let anchored = anchoredRect(
            source: source,
            requested: requested,
            viewport: viewport
        )
        let placed = resolveCollision(
            anchored,
            source: source,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport
        )
        return BrowserOverlayCardLayout(
            rect: placed,
            maximumFontSize: fontSize,
            contentInsets: contentInsets
        )
    }

    private static func bestEffortFontSize(
        settings: IPhoneOverlaySettings,
        fittedFontSize: CGFloat? = nil
    ) -> CGFloat {
        return max(
            minimumRenderedFontSize,
            fittedFontSize ?? minimumRenderedFontSize
        )
    }

    private static func readableFontSize(
        variants: [BrowserOverlayDisplayVariant],
        rect: CGRect,
        ceiling: CGFloat,
        settings: IPhoneOverlaySettings,
        contentInsets: UIEdgeInsets,
        measurementCache: BrowserOverlayTextMeasurementCache?,
        preservingLineLayoutAt referenceFont: CGFloat? = nil,
        additionalLineAllowance: Int = 0
    ) -> CGFloat? {
        let floor = minimumReadableFontSize(
            variants: variants,
            settings: settings
        )
        guard ceiling + 0.001 >= floor else { return nil }
        let usableWidth = max(1, rect.width - contentInsets.left - contentInsets.right)
        // Enlarging into unused height must not turn a horizontal utterance into
        // a narrow stack or introduce emergency breaks inside previously fitting words.
        let lineBudgets: [(count: Int, protectsWords: Bool)]? = referenceFont.map { reference in
            variants.map { variant in
                let height = variant.measuredSize(width: usableWidth, fontSize: reference,
                    measurementCache: measurementCache).height
                let lineHeight = BrowserOverlayFont.system(ofSize: reference, weight: .bold).lineHeight
                return (max(1, Int(ceil(max(0, height - 1) / lineHeight))),
                    !variant.allowsEmergencyKoreanWordBreak(at: reference) &&
                    variant.minimumUnbrokenWidth(fontSize: reference,
                        measurementCache: measurementCache) <= usableWidth + 0.5)
            }
        }
        let preservesLineLayout: ((CGFloat) -> Bool)? = lineBudgets.map { budgets in
            { candidate in
                // The prior accepted size remains admissible despite metric rounding.
                if let referenceFont, candidate <= referenceFont { return true }
                let lineHeight = BrowserOverlayFont.system(ofSize: candidate, weight: .bold).lineHeight
                return zip(variants, budgets).allSatisfy { variant, budget in
                    let height = variant.measuredSize(width: usableWidth, fontSize: candidate,
                        measurementCache: measurementCache).height
                    return height <= CGFloat(budget.count + max(0, additionalLineAllowance)) * lineHeight + 1 &&
                        (!budget.protectsWords || variant.minimumUnbrokenWidth(fontSize: candidate,
                            measurementCache: measurementCache) <= usableWidth + 0.5)
                }
            }
        }
        let fitted: CGFloat
        fitted = min(
            ceiling,
            fittedSourceFontSize(
                variants: variants,
                size: rect.size,
                minimumHorizontalUnits: 1,
                minimum: max(floor, referenceFont ?? floor),
                maximum: ceiling,
                contentInsets: contentInsets,
                measurementCache: measurementCache,
                additionalFit: preservesLineLayout
            )
        )
        guard fitted + 0.001 >= floor,
              variantsFit(
                  variants,
                  size: rect.size,
                  fontSize: fitted,
                  minimumHorizontalUnits: 1,
                  contentInsets: contentInsets,
                  measurementCache: measurementCache
              )
        else {
            return nil
        }
        return fitted
    }

    private static func minimumReadableFontSize(
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings
    ) -> CGFloat {
        return variants.contains(where: { !$0.vertical })
            ? minimumReadableHorizontalFontSize
            : minimumAutoFontSize
    }

    private static func collisionCandidate(
        source: CGRect,
        expandedSize: CGSize,
        scale: CGFloat,
        occupied: [CGRect],
        reservedSources: [CGRect],
        viewport: CGSize
    ) -> CGRect {
        let clampedScale = min(1, max(0, scale))
        let requested = CGSize(
            width: source.width +
                max(0, expandedSize.width - source.width) * clampedScale,
            height: source.height +
                max(0, expandedSize.height - source.height) * clampedScale
        )
        return resolveCollision(
            anchoredRect(
                source: source,
                requested: requested,
                viewport: viewport
            ),
            source: source,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport
        )
    }

    private static func collisionInfluenceBounds(
        intrinsicLayout: BrowserOverlayCardLayout,
        source: CGRect,
        viewport: CGSize
    ) -> CGRect {
        let maximumWidth = max(source.width, intrinsicLayout.rect.width)
        let maximumHeight = max(source.height, intrinsicLayout.rect.height)
        let legalPlacementBounds = CGRect(
            x: source.minX - maximumWidth,
            y: source.minY - maximumHeight,
            width: source.width + maximumWidth * 2,
            height: source.height + maximumHeight * 2
        )
        return legalPlacementBounds
            .union(intrinsicLayout.rect)
            .intersection(CGRect(origin: .zero, size: viewport))
    }

    private static func hasVisualCollision(
        _ rect: CGRect,
        occupied: [CGRect],
        reservedSources: [CGRect]
    ) -> Bool {
        (occupied + reservedSources).contains { other in
            let intersection = rect.intersection(other)
            return !intersection.isNull &&
                intersection.width > 0.25 &&
                intersection.height > 0.25
        }
    }

    private static func requiresCollisionResolution(
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        sourceVertical: Bool?,
        singleVerticalColumn: Bool
    ) -> Bool {
        let safeVariants = variants.isEmpty
            ? [.plain("", vertical: false)]
            : variants
        if settings.textPlacement == .replace,
           sourceVertical == true,
           safeVariants.allSatisfy(\.vertical)
        {
            return false
        }
        return true
    }

    private static func clippedSource(
        _ source: CGRect,
        viewport: CGSize
    ) -> CGRect {
        source.standardized.intersection(
            CGRect(origin: .zero, size: viewport)
        )
    }

    private static func fittedSourceFontSize(
        variants: [BrowserOverlayDisplayVariant],
        size: CGSize,
        minimumHorizontalUnits: CGFloat,
        minimum: CGFloat = minimumAutoFontSize,
        maximum: CGFloat,
        contentInsets: UIEdgeInsets,
        measurementCache: BrowserOverlayTextMeasurementCache?,
        additionalFit: ((CGFloat) -> Bool)? = nil
    ) -> CGFloat {
        guard variantsFit(
            variants,
            size: size,
            fontSize: minimum,
            minimumHorizontalUnits: minimumHorizontalUnits,
            contentInsets: contentInsets,
            measurementCache: measurementCache
        ) else {
            return minimum
        }
        var lower = minimum
        var upper = max(minimum, maximum)
        for _ in 0..<10 {
            let candidate = (lower + upper) / 2
            if variantsFit(
                variants,
                size: size,
                fontSize: candidate,
                minimumHorizontalUnits: minimumHorizontalUnits,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            ) && (additionalFit?(candidate) ?? true) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return floor(lower * 4) / 4
    }

    private static func fittedSingleVerticalColumnFontSize(
        variants: [BrowserOverlayDisplayVariant],
        size: CGSize,
        maximum: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> CGFloat {
        let upperBound = max(
            minimumSingleVerticalColumnFontSize,
            maximum
        )
        func fits(_ fontSize: CGFloat) -> Bool {
            variantsFit(
                variants,
                size: size,
                fontSize: fontSize,
                minimumHorizontalUnits: 1,
                contentInsets:
                    BrowserOverlayCardTextInsets.singleVerticalColumn,
                measurementCache: measurementCache
            )
        }
        guard !fits(upperBound) else { return upperBound }
        guard fits(minimumSingleVerticalColumnFontSize) else {
            return minimumSingleVerticalColumnFontSize
        }
        var lower = minimumSingleVerticalColumnFontSize
        var upper = upperBound
        for _ in 0..<10 {
            let candidate = (lower + upper) / 2
            if fits(candidate) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return floor(lower * 4) / 4
    }

    private static func fittedEnvelopeFontSize(
        variants: [BrowserOverlayDisplayVariant],
        source: CGRect,
        minimumSize: CGSize,
        minimumHorizontalUnits: CGFloat,
        viewport: CGSize,
        maximumWidth: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        contentInsets: UIEdgeInsets,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> CGFloat {
        func fits(_ fontSize: CGFloat) -> Bool {
            guard let size = readableEnvelopeSize(
                variants: variants,
                source: source,
                minimumSize: minimumSize,
                minimumHorizontalUnits: minimumHorizontalUnits,
                fontSize: fontSize,
                viewport: viewport,
                maximumWidth: maximumWidth,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            ) else {
                return false
            }
            return variantsFit(
                variants,
                size: size,
                fontSize: fontSize,
                minimumHorizontalUnits: minimumHorizontalUnits,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            )
        }

        let policyFloor = maximumWidth + 0.5 < viewport.width
            ? minimumConstrainedMangaFontSize
            : minimumSingleVerticalColumnFontSize
        let lowerBound = max(policyFloor, minimum)
        let upperBound = max(lowerBound, maximum)
        guard !fits(upperBound) else { return upperBound }
        guard fits(lowerBound) else { return lowerBound }
        var lower = lowerBound
        var upper = upperBound
        for _ in 0..<10 {
            let candidate = (lower + upper) / 2
            if fits(candidate) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return floor(lower * 4) / 4
    }

    private static func readableEnvelopeSize(
        variants: [BrowserOverlayDisplayVariant],
        source: CGRect,
        minimumSize: CGSize,
        minimumHorizontalUnits: CGFloat,
        fontSize: CGFloat,
        viewport: CGSize,
        maximumWidth: CGFloat,
        contentInsets: UIEdgeInsets,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> CGSize? {
        let horizontalInsets = contentInsets.left + contentInsets.right
        let verticalInsets = contentInsets.top + contentInsets.bottom
        let tokenWidth = variants.reduce(CGFloat.zero) {
            max(
                $0,
                $1.minimumUnbrokenWidth(
                    fontSize: fontSize,
                    measurementCache: measurementCache
                )
            )
        }
        let boundedMaximumWidth = min(
            viewport.width,
            max(source.width, maximumWidth)
        )
        let minimumWidth = min(
            boundedMaximumWidth,
            max(
                source.width,
                minimumSize.width,
                minimumHorizontalUnits * fontSize + horizontalInsets,
                tokenWidth + horizontalInsets
            )
        )
        let widthSpan = max(0, boundedMaximumWidth - minimumWidth)
        var candidateWidths = (0...24).map { step in
            minimumWidth + widthSpan * CGFloat(step) / 24
        }
        candidateWidths.append(contentsOf: [
            source.width,
            minimumSize.width,
            boundedMaximumWidth * 0.72,
            boundedMaximumWidth,
        ])
        candidateWidths = uniqueValues(candidateWidths)
            .map { min(boundedMaximumWidth, max(minimumWidth, $0)) }

        var candidates: [CGSize] = []
        for width in candidateWidths {
            let usableWidth = max(1, width - horizontalInsets)
            let measuredHeight = variants.reduce(CGFloat.zero) {
                max(
                    $0,
                    $1.measuredSize(
                        width: usableWidth,
                        fontSize: fontSize,
                        measurementCache: measurementCache
                    ).height
                )
            }
            let size = CGSize(
                width: max(source.width, minimumSize.width, width),
                height: min(
                    viewport.height,
                    max(
                        source.height,
                        minimumSize.height,
                        measuredHeight + verticalInsets
                    )
                )
            )
            if size.width <= boundedMaximumWidth,
               variantsFit(
                   variants,
                   size: size,
                   fontSize: fontSize,
                   minimumHorizontalUnits: minimumHorizontalUnits,
                   contentInsets: contentInsets,
                   measurementCache: measurementCache
               )
            {
                candidates.append(size)
            }
        }

        return candidates.min { left, right in
            let leftExpansion = max(
                left.width / source.width,
                left.height / source.height
            )
            let rightExpansion = max(
                right.width / source.width,
                right.height / source.height
            )
            if abs(leftExpansion - rightExpansion) > 0.001 {
                return leftExpansion < rightExpansion
            }
            return left.width * left.height < right.width * right.height
        }
    }

    private static func variantsFit(
        _ variants: [BrowserOverlayDisplayVariant],
        size: CGSize,
        fontSize: CGFloat,
        minimumHorizontalUnits: CGFloat,
        contentInsets: UIEdgeInsets = BrowserOverlayCardTextInsets.regular,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> Bool {
        let usable = CGSize(
            width: max(
                1,
                size.width - contentInsets.left - contentInsets.right
            ),
            height: max(
                1,
                size.height - contentInsets.top - contentInsets.bottom
            )
        )
        if variants.contains(where: { !$0.vertical }),
           usable.width + 0.5 < minimumHorizontalUnits * fontSize
        {
            return false
        }
        return variants.allSatisfy {
            $0.fits(
                available: usable,
                fontSize: fontSize,
                measurementCache: measurementCache
            )
        }
    }

    /// Mirrors desktop replacement padding and its conservative border/font
    /// metric reserves. Small OCR boxes no longer lose a fixed 12x8 points of
    /// content area before auto-fit even starts.
    private static func plannedContentInsets(
        source: CGRect,
        settings: IPhoneOverlaySettings,
        vertical: Bool
    ) -> UIEdgeInsets {
        let minorAxis = max(1, min(source.width, source.height))
        let padding: CGFloat
        if settings.textPlacement == .replace {
            padding = min(4, max(1, minorAxis * 0.055))
        } else {
            padding = min(10, max(4, minorAxis * 0.06))
        }
        let roundedPadding = (padding * 100).rounded() / 100
        let borderReservePerEdge: CGFloat = settings.reservesSurfaceBorder ? 2 : 0
        let verticalOverhangPerHorizontalEdge: CGFloat = vertical ? 2 : 0
        return UIEdgeInsets(
            top: roundedPadding + borderReservePerEdge,
            left: roundedPadding + borderReservePerEdge +
                verticalOverhangPerHorizontalEdge,
            bottom: roundedPadding + borderReservePerEdge,
            right: roundedPadding + borderReservePerEdge +
                verticalOverhangPerHorizontalEdge
        )
    }

    /// Uses the same UIKit font and wrapping policy as the painted label.
    /// Keeping this measurement authoritative prevents the planner from
    /// approving an 11pt layout that UILabel later clips.
    static func measuredHorizontalTextSize(
        _ text: String,
        width: CGFloat,
        fontSize: CGFloat,
        weight: UIFont.Weight = .semibold
    ) -> CGSize {
        guard width > 0, fontSize > 0 else { return .zero }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = [.standard, .hangulWordPriority]
        let measured = (text as NSString).boundingRect(
            with: CGSize(
                width: width,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: BrowserOverlayFont.system(ofSize: fontSize, weight: weight),
                .paragraphStyle: paragraph,
            ],
            context: nil
        )
        return CGSize(
            width: ceil(measured.width),
            height: ceil(measured.height)
        )
    }

    static func horizontalTextFits(
        _ text: String,
        available: CGSize,
        fontSize: CGFloat,
        weight: UIFont.Weight = .semibold
    ) -> Bool {
        let measured = measuredHorizontalTextSize(
            text,
            width: available.width,
            fontSize: fontSize,
            weight: weight
        )
        return measured.width <= available.width + 0.5 &&
            measured.height <= available.height + 0.5
    }

    private static func anchoredRect(
        source: CGRect,
        requested: CGSize,
        viewport: CGSize
    ) -> CGRect {
        let width = min(viewport.width, max(source.width, requested.width))
        let height = min(viewport.height, max(source.height, requested.height))
        return CGRect(
            x: min(
                max(0, source.midX - width / 2),
                max(0, viewport.width - width)
            ),
            y: min(
                max(0, source.midY - height / 2),
                max(0, viewport.height - height)
            ),
            width: width,
            height: height
        )
    }

    private static func resolveCollision(
        _ candidate: CGRect,
        source: CGRect,
        occupied: [CGRect],
        reservedSources: [CGRect],
        viewport: CGSize
    ) -> CGRect {
        guard !occupied.isEmpty || !reservedSources.isEmpty else {
            return candidate
        }
        let minimumX = max(0, source.maxX - candidate.width)
        let maximumX = min(
            source.minX,
            max(0, viewport.width - candidate.width)
        )
        let minimumY = max(0, source.maxY - candidate.height)
        let maximumY = min(
            source.minY,
            max(0, viewport.height - candidate.height)
        )
        let obstacles = occupied + reservedSources
        let xValues = exactUniqueValues(uniqueValues([
            candidate.minX, minimumX, maximumX,
            source.minX, source.maxX - candidate.width,
        ] + obstacles.flatMap { other in
            [other.minX - candidate.width, other.maxX]
        }).map { min(max(minimumX, $0), maximumX) })
        let yValues = exactUniqueValues(uniqueValues([
            candidate.minY, minimumY, maximumY,
            source.minY, source.maxY - candidate.height,
        ] + obstacles.flatMap { other in
            [other.minY - candidate.height, other.maxY]
        }).map { min(max(minimumY, $0), maximumY) })
        // Clamping can collapse almost every seed onto the same boundary.
        // Score each distinct location once, retaining first-candidate tie order.
        // Padding is invariant across all candidates and belongs outside the loop.
        let paddedCards = occupied.map { BrowserOverlayCollisionGeometry($0.insetBy(dx: -2, dy: -2)) }
        let reservedGeometry = reservedSources.map(BrowserOverlayCollisionGeometry.init)
        var best = candidate
        var bestScore: CGFloat?
        for x in xValues {
            if Task.isCancelled { return best }
            for y in yValues {
                let rect = CGRect(x: x, y: y, width: candidate.width, height: candidate.height)
                let value = score(rect, anchor: candidate, occupied: paddedCards, reservedSources: reservedGeometry)
                if bestScore.map({ value < $0 }) ?? true {
                    best = rect
                    bestScore = value
                }
            }
        }
        return best
    }

    private static func score(
        _ rect: CGRect,
        anchor: CGRect,
        occupied: [BrowserOverlayCollisionGeometry],
        reservedSources: [BrowserOverlayCollisionGeometry]
    ) -> CGFloat {
        let geometry = BrowserOverlayCollisionGeometry(rect)
        let sourceOverlap = reservedSources.reduce(CGFloat.zero) {
            total, other in
            total + geometry.overlapArea(with: other)
        }
        let cardOverlap = occupied.reduce(CGFloat.zero) { total, other in
            total + geometry.overlapArea(with: other)
        }
        let dx = rect.minX - anchor.minX
        let dy = rect.minY - anchor.minY
        return sourceOverlap * 1_000_000 +
            cardOverlap * 1_000 + dx * dx + dy * dy
    }

    /// Exact deduplication AFTER the original tolerance-based seed selection
    /// and clamping preserves the original candidate grid and tie order.
    private static func exactUniqueValues(_ values: [CGFloat]) -> [CGFloat] {
        var seen = Set<CGFloat>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueValues(_ values: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        for value in values where value.isFinite {
            if !result.contains(where: { abs($0 - value) < 0.25 }) {
                result.append(value)
            }
        }
        return result
    }
}

private struct OverlayPalette {
    let isLightSurface: Bool
    let foreground: UIColor
    let secondary: UIColor
    let background: UIColor
    let border: UIColor

    func applyDropShadow(to layer: CALayer, compact: Bool) {
        layer.shadowColor = UIColor.black.cgColor
        if isLightSurface {
            layer.shadowOpacity = compact ? 0.26 : 0.32
            layer.shadowRadius = compact ? 3.5 : 9
            layer.shadowOffset = CGSize(width: 0, height: compact ? 2 : 5)
        } else {
            layer.shadowOpacity = compact ? 0.38 : 0.58
            layer.shadowRadius = compact ? 4 : 13
            layer.shadowOffset = CGSize(width: 0, height: compact ? 2 : 7)
        }
    }

    func makeTextShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = isLightSurface
            ? UIColor.white.withAlphaComponent(0.75)
            : UIColor.black.withAlphaComponent(0.95)
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        shadow.shadowBlurRadius = isLightSurface ? 0 : 2
        return shadow
    }

    func applyTextShadow(to layer: CALayer) {
        layer.shadowColor = isLightSurface
            ? UIColor.white.cgColor
            : UIColor.black.cgColor
        layer.shadowOpacity = isLightSurface ? 0.75 : 0.95
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = isLightSurface ? 0 : 2
    }

    static func make(
        mode: IPhoneOverlayColorMode,
        opacity: Double
    ) -> Self {
        let useLightSurface = mode == .white
        let baseAlpha = min(max(opacity, 0), 1)
        if !useLightSurface {
            // CSS parity: rgba(7,9,13,opacity) with a second
            // rgba(7,9,13,.64) background-image composited above it.
            let effectiveAlpha = 0.64 + (baseAlpha * (1 - 0.64))
            return Self(
                isLightSurface: false,
                foreground: .white,
                secondary: UIColor.white.withAlphaComponent(0.72),
                background: UIColor(
                    red: 7 / 255,
                    green: 9 / 255,
                    blue: 13 / 255,
                    alpha: effectiveAlpha
                ),
                border: UIColor.white.withAlphaComponent(0.40)
            )
        }
        // CSS parity: rgba(255,254,249,opacity) under rgba(255,255,255,.42).
        // Collapse the two layers into one UIColor while preserving the
        // resulting alpha and premultiplied RGB values.
        let imageAlpha = 0.42
        let effectiveAlpha = imageAlpha + (baseAlpha * (1 - imageAlpha))
        let baseContribution = baseAlpha * (1 - imageAlpha)
        let compositeChannel: (CGFloat) -> CGFloat = { baseChannel in
            guard effectiveAlpha > 0 else { return 0 }
            return CGFloat(
                (imageAlpha + (Double(baseChannel) * baseContribution)) /
                    effectiveAlpha
            )
        }
        return Self(
            isLightSurface: true,
            foreground: UIColor(red: 17 / 255, green: 18 / 255, blue: 23 / 255, alpha: 1),
            secondary: UIColor(red: 17 / 255, green: 18 / 255, blue: 23 / 255, alpha: 0.66),
            background: UIColor(
                red: compositeChannel(1),
                green: compositeChannel(254 / 255),
                blue: compositeChannel(249 / 255),
                alpha: effectiveAlpha
            ),
            border: UIColor(red: 17 / 255, green: 18 / 255, blue: 23 / 255, alpha: 0.72)
        )
    }
}

private final class OverlayCardView: UIView, UIContextMenuInteractionDelegate {
    /// UIKit does not expose the exact CSS `blur(2px) saturate(...)` controls
    /// used by c1. A material view is the public native approximation: it
    /// obscures sharp source-image glyphs before the configured translucent
    /// palette tint is composited above them.
    private let backdropView = UIVisualEffectView()
    private let surfaceTintView = UIView()
    private let label = OverlayFittingInsetLabel()
    private var backdropConstraints: [NSLayoutConstraint] = []
    private var sourceText: String
    private var translatedText: String?
    private var content: BrowserOverlayCardContent
    private var localizer: IPhoneLocalizer

    init(
        item: BrowserOverlayItem,
        content: BrowserOverlayCardContent,
        settings: IPhoneOverlaySettings,
        maximumFontSize: CGFloat,
        contentInsets: UIEdgeInsets,
        localizer: IPhoneLocalizer,
        measurementCache: BrowserOverlayTextMeasurementCache
    ) {
        sourceText = item.sourceText
        translatedText = item.translatedText
        self.content = content
        self.localizer = localizer
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityIdentifier =
            "aidoku.reader.overlay.item"

        backdropView.isUserInteractionEnabled = false
        backdropView.isAccessibilityElement = false
        backdropView.accessibilityElementsHidden = true
        backdropView.accessibilityIdentifier =
            "aidoku.reader.overlay.item.backdrop"
        backdropView.clipsToBounds = true
        surfaceTintView.isUserInteractionEnabled = false
        surfaceTintView.isAccessibilityElement = false
        surfaceTintView.accessibilityIdentifier =
            "aidoku.reader.overlay.item.surface"
        backdropView.contentView.addSubview(surfaceTintView)

        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.lineBreakStrategy = [.standard, .hangulWordPriority]
        label.accessibilityIdentifier =
            "aidoku.reader.overlay.item.text"
        addSubview(label)

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        surfaceTintView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        backdropConstraints = [
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate([
            surfaceTintView.leadingAnchor.constraint(
                equalTo: backdropView.contentView.leadingAnchor
            ),
            surfaceTintView.trailingAnchor.constraint(
                equalTo: backdropView.contentView.trailingAnchor
            ),
            surfaceTintView.topAnchor.constraint(
                equalTo: backdropView.contentView.topAnchor
            ),
            surfaceTintView.bottomAnchor.constraint(
                equalTo: backdropView.contentView.bottomAnchor
            ),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        addInteraction(UIContextMenuInteraction(delegate: self))
        apply(
            item: item,
            content: content,
            settings: settings,
            maximumFontSize: maximumFontSize,
            contentInsets: contentInsets,
            localizer: localizer,
            measurementCache: measurementCache
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        item: BrowserOverlayItem,
        content: BrowserOverlayCardContent,
        settings: IPhoneOverlaySettings,
        maximumFontSize: CGFloat,
        contentInsets: UIEdgeInsets,
        localizer: IPhoneLocalizer,
        measurementCache: BrowserOverlayTextMeasurementCache
    ) {
        apply(
            item: item,
            content: content,
            settings: settings,
            maximumFontSize: maximumFontSize,
            contentInsets: contentInsets,
            localizer: localizer,
            measurementCache: measurementCache
        )
    }

    private func apply(
        item: BrowserOverlayItem,
        content: BrowserOverlayCardContent,
        settings: IPhoneOverlaySettings,
        maximumFontSize: CGFloat,
        contentInsets: UIEdgeInsets,
        localizer: IPhoneLocalizer,
        measurementCache: BrowserOverlayTextMeasurementCache
    ) {
        sourceText = item.sourceText
        translatedText = item.translatedText
        self.content = content
        self.localizer = localizer

        let palette = OverlayPalette.make(
            mode: settings.colorMode,
            opacity: settings.opacity
        )
        let isReplacement = settings.textPlacement == .replace
        let isFinalTranslationReplacement =
            content.hasTranslation &&
            settings.mode == .translateOnly &&
            isReplacement
        if isReplacement {
            // Keep the c1 opacity contract. The material blur removes sharp
            // source-image detail; the configured palette alpha remains the
            // tint alpha instead of being silently promoted to opaque.
            installBackdropIfNeeded()
            backgroundColor = .clear
            backdropView.effect = UIBlurEffect(
                style: palette.isLightSurface
                    ? .systemThinMaterialLight
                    : .systemThinMaterialDark
            )
            surfaceTintView.backgroundColor = palette.background
        } else {
            // Expanded/subtitle-adjacent cards retain their established plain
            // surface and do not pay for a backdrop effect they never used.
            backgroundColor = palette.background
            backdropView.effect = nil
            surfaceTintView.backgroundColor = .clear
            removeBackdropIfNeeded()
        }
        let compact = settings.textPlacement == .replace
        let overlayBaseFontSize: CGFloat = 14
        layer.cornerRadius = compact
            ? 6
            : overlayBaseFontSize * (content.source.vertical ? 1.45 : 1.05)
        backdropView.layer.cornerRadius = layer.cornerRadius
        layer.borderWidth = !compact && content.source.vertical ? 2 : 1
        layer.borderColor = palette.border.cgColor
        palette.applyDropShadow(to: layer, compact: compact)
        layer.masksToBounds = false
        // Explicit one-line vertical OCR stays in one column; the planner may
        // grow its painted card around the source to preserve the mobile
        // readability floor. Clip only as a final font-metric safety net.
        clipsToBounds = false
        label.clipsToBounds = !content.hasTranslation ||
            content.displayed.vertical ||
            content.singleVerticalColumn ||
            settings.textPlacement != .replace

        label.setContentInsets(contentInsets)
        label.configure(
            displayVariant: displayedVariant,
            verticalRawText: BrowserOverlayVerticalTextPainter.text(
                for: item,
                content: content,
                mode: settings.mode
            ),
            foregroundColor: palette.foreground,
            secondaryForegroundColor: isFinalTranslationReplacement
                ? nil
                : palette.secondary,
            textShadow: palette.makeTextShadow(),
            maximumPointSize: maximumFontSize,
            // c1 chooses 800/700 from the displayed writing flow, not from
            // the source OCR orientation. A Korean translation of Japanese
            // vertical text is horizontal and therefore uses weight 700.
            weight: content.displayed.vertical ? .heavy : .bold,
            minimumScaleFactor: 0.42,
            minimumPointSize:
                BrowserOverlayLayoutPlanner.minimumAutoFontSize,
            measurementCache: measurementCache
        )
        accessibilityHint = localizer.string(.overlayCopyHint)
        updateTextFlow()
        updateAccessibility()
        setNeedsLayout()
        label.setNeedsLayout()
    }

    private func installBackdropIfNeeded() {
        guard backdropView.superview !== self else { return }
        insertSubview(backdropView, belowSubview: label)
        NSLayoutConstraint.activate(backdropConstraints)
    }

    private func removeBackdropIfNeeded() {
        guard backdropView.superview === self else { return }
        NSLayoutConstraint.deactivate(backdropConstraints)
        backdropView.removeFromSuperview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else {
            layer.shadowPath = nil
            return
        }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    private func updateTextFlow() {
        let rawText = translatedText ?? sourceText
        let rightToLeft = BrowserOverlayTextFlow.isRightToLeft(rawText)
        // Desktop translation cards center both horizontal and vertical text;
        // direction still controls glyph order and accessibility semantics.
        label.textAlignment = .center
        label.semanticContentAttribute =
            rightToLeft ? .forceRightToLeft : .unspecified
    }

    private var displayedVariant: BrowserOverlayDisplayVariant {
        content.displayed
    }

    private func updateAccessibility() {
        accessibilityLabel = localizer.format(
            .overlayTranslationFormat,
            translatedText ?? sourceText
        )
        accessibilityValue = nil
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [sourceText, translatedText, localizer] _ in
            var actions = [
                UIAction(
                    title: localizer.string(.overlayCopySource),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = sourceText
                },
            ]
            if let translatedText {
                actions.append(
                    UIAction(
                        title: localizer.string(.overlayCopyTranslation),
                        image: UIImage(systemName: "character.book.closed")
                    ) { _ in
                        UIPasteboard.general.string = translatedText
                    }
                )
            }
            return UIMenu(title: sourceText, children: actions)
        }
    }
}

private final class OverlaySubtitleView: UIView, UIContextMenuInteractionDelegate {
    private let label = OverlayFittingLabel()
    private var sourceText: String
    private var translatedText: String
    private var localizer: IPhoneLocalizer

    init(
        text: String,
        sourceText: String,
        settings: IPhoneOverlaySettings,
        localizer: IPhoneLocalizer
    ) {
        self.sourceText = sourceText
        translatedText = text
        self.localizer = localizer
        super.init(frame: .zero)
        let palette = OverlayPalette.make(
            mode: settings.colorMode,
            opacity: settings.opacity
        )
        backgroundColor = palette.background
        layer.cornerRadius = 0.72 * 14
        layer.borderWidth = 1
        layer.borderColor = palette.border.cgColor
        palette.applyDropShadow(to: layer, compact: false)
        layer.masksToBounds = false
        isAccessibilityElement = true
        accessibilityIdentifier =
            "aidoku.reader.overlay.item"
        label.text = text
        label.textColor = palette.foreground
        palette.applyTextShadow(to: label.layer)
        label.configure(
            maximumPointSize: 18,
            weight: .semibold,
            minimumScaleFactor: 0.55
        )
        label.textAlignment = BrowserOverlayTextFlow.isRightToLeft(text)
            ? .right
            : .center
        label.semanticContentAttribute =
            BrowserOverlayTextFlow.isRightToLeft(text)
                ? .forceRightToLeft
                : .unspecified
        label.numberOfLines = settings.subtitleMaxLines
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        accessibilityLabel = text
        accessibilityHint = localizer.string(.overlayCopyHint)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func update(
        text: String,
        sourceText: String,
        settings: IPhoneOverlaySettings,
        localizer: IPhoneLocalizer
    ) {
        self.sourceText = sourceText
        translatedText = text
        self.localizer = localizer
        let palette = OverlayPalette.make(
            mode: settings.colorMode,
            opacity: settings.opacity
        )
        backgroundColor = palette.background
        layer.cornerRadius = 0.72 * 14
        layer.borderWidth = 1
        layer.borderColor = palette.border.cgColor
        palette.applyDropShadow(to: layer, compact: false)
        label.text = text
        label.textColor = palette.foreground
        palette.applyTextShadow(to: label.layer)
        label.configure(
            maximumPointSize: 18,
            weight: .semibold,
            minimumScaleFactor: 0.55
        )
        label.textAlignment = BrowserOverlayTextFlow.isRightToLeft(text)
            ? .right
            : .center
        label.semanticContentAttribute =
            BrowserOverlayTextFlow.isRightToLeft(text)
                ? .forceRightToLeft
                : .unspecified
        label.numberOfLines = settings.subtitleMaxLines
        accessibilityLabel = text
        accessibilityHint = localizer.string(.overlayCopyHint)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else {
            layer.shadowPath = nil
            return
        }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [sourceText, translatedText, localizer] _ in
            var actions = [
                UIAction(
                    title: localizer.string(.overlayCopySource),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = sourceText
                },
            ]
            if translatedText != sourceText {
                actions.append(
                    UIAction(
                        title:
                            localizer.string(.overlayCopyTranslation),
                        image: UIImage(
                            systemName: "character.book.closed"
                        )
                    ) { _ in
                        UIPasteboard.general.string = translatedText
                    }
                )
            }
            return UIMenu(children: actions)
        }
    }
}

private final class OverlaySidePanelView: UIView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var rowsByKey: [String: OverlayRevealLabel] = [:]

    init(
        items: [BrowserOverlayItem],
        settings: IPhoneOverlaySettings,
        localizer: IPhoneLocalizer
    ) {
        super.init(frame: .zero)
        accessibilityIdentifier =
            "aidoku.reader.overlay.side-panel"
        layer.cornerRadius = 15
        layer.borderWidth = 1
        layer.masksToBounds = false
        scroll.clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        update(items: items, settings: settings, localizer: localizer)
    }

    func update(
        items: [BrowserOverlayItem],
        settings: IPhoneOverlaySettings,
        localizer: IPhoneLocalizer
    ) {
        let palette = OverlayPalette.make(
            mode: settings.colorMode,
            opacity: settings.opacity
        )
        backgroundColor = palette.background
        layer.borderColor = palette.border.cgColor
        palette.applyDropShadow(to: layer, compact: false)

        let stableRegionIDCounts = items.reduce(into: [UInt64: Int]()) {
            counts, item in
            if let stableRegionID = item.stableRegionID {
                counts[stableRegionID, default: 0] += 1
            }
        }
        var nextRows: [String: OverlayRevealLabel] = [:]
        for (index, item) in items.enumerated() {
            let output = item.translatedText ?? item.sourceText
            let key: String
            if let stableRegionID = item.stableRegionID,
               stableRegionIDCounts[stableRegionID] == 1
            {
                key = "region:\(stableRegionID)"
            } else {
                key = "transient:\(index):\(item.sourceText)"
            }
            let label = rowsByKey[key] ?? OverlayRevealLabel(
                prefix: "",
                sourceText: "",
                translatedText: nil,
                localizer: localizer
            )
            label.update(
                prefix: "\(index + 1). ",
                sourceText: item.sourceText,
                translatedText: item.translatedText,
                localizer: localizer
            )
            label.text = "\(index + 1). \(output)"
            label.font = .systemFont(
                ofSize: 14,
                weight: .medium
            )
            label.numberOfLines = 0
            label.textColor = palette.foreground
            label.accessibilityLabel = output
            label.accessibilityIdentifier =
                "aidoku.reader.overlay.item"
            if stack.arrangedSubviews.indices.contains(index),
               stack.arrangedSubviews[index] === label
            {
                // Already in the correct stable position.
            } else {
                if stack.arrangedSubviews.contains(where: { $0 === label }) {
                    stack.removeArrangedSubview(label)
                    label.removeFromSuperview()
                }
                stack.insertArrangedSubview(
                    label,
                    at: min(index, stack.arrangedSubviews.count)
                )
            }
            nextRows[key] = label
        }
        for (key, label) in rowsByKey where nextRows[key] == nil {
            stack.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        rowsByKey = nextRows
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else {
            layer.shadowPath = nil
            return
        }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class OverlayRevealLabel: UILabel,
    UIContextMenuInteractionDelegate
{
    private var prefix: String
    private var sourceText: String
    private var translatedText: String?
    private var localizer: IPhoneLocalizer

    init(
        prefix: String,
        sourceText: String,
        translatedText: String?,
        localizer: IPhoneLocalizer
    ) {
        self.prefix = prefix
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.localizer = localizer
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        accessibilityHint = localizer.string(.overlayCopyHint)
        addInteraction(UIContextMenuInteraction(delegate: self))
        updateAccessibility()
    }

    func update(
        prefix: String,
        sourceText: String,
        translatedText: String?,
        localizer: IPhoneLocalizer
    ) {
        self.prefix = prefix
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.localizer = localizer
        accessibilityHint = localizer.string(.overlayCopyHint)
        updateAccessibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAccessibility() {
        accessibilityLabel = translatedText ?? sourceText
        accessibilityValue = nil
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [sourceText, translatedText, localizer] _ in
            var actions = [
                UIAction(
                    title: localizer.string(.overlayCopySource),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = sourceText
                },
            ]
            if let translatedText, translatedText != sourceText {
                actions.append(
                    UIAction(
                        title:
                            localizer.string(.overlayCopyTranslation),
                        image: UIImage(
                            systemName: "character.book.closed"
                        )
                    ) { _ in
                        UIPasteboard.general.string = translatedText
                    }
                )
            }
            return UIMenu(children: actions)
        }
    }
}

private class OverlayFittingLabel: UILabel {
    private struct FontFitInput: Equatable {
        let text: String
        let displayVariant: BrowserOverlayDisplayVariant?
        let verticalRawText: String?
        let availableSize: CGSize
        let minimumPointSize: CGFloat
        let maximumPointSize: CGFloat
        let weightRawValue: CGFloat
    }

    private var maximumPointSize: CGFloat = 17
    private var minimumFittingScale: CGFloat = 0.5
    private var weight: UIFont.Weight = .regular
    private var explicitMinimumPointSize: CGFloat?
    private var displayVariant: BrowserOverlayDisplayVariant?
    private var verticalRawText: String?
    private var displayForegroundColor: UIColor?
    private var displaySecondaryForegroundColor: UIColor?
    private var displayTextShadow: NSShadow?
    private var measurementCache: BrowserOverlayTextMeasurementCache?
    private var cachedFontFitInput: FontFitInput?
    private var cachedFittedPointSize: CGFloat?
    private var appliedDisplayVariant: BrowserOverlayDisplayVariant?
    private var appliedDisplayForegroundColor: UIColor?
    private var appliedDisplaySecondaryForegroundColor: UIColor?
    private var appliedDisplayTextShadow: NSShadow?
    private var appliedDisplayPointSize: CGFloat?
    private var appliedDisplayWidth: CGFloat?
    private var appliedDisplayLineBreakMode: NSLineBreakMode?
    private var appliedVerticalRawText: String?
    private let renderedMeasurementLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakStrategy = [.standard, .hangulWordPriority]
        label.textAlignment = .center
        return label
    }()

    fileprivate var usesVerticalCoreTextPainter: Bool {
        verticalRawText != nil
    }

    func configure(
        displayVariant: BrowserOverlayDisplayVariant? = nil,
        verticalRawText: String? = nil,
        foregroundColor: UIColor? = nil,
        secondaryForegroundColor: UIColor? = nil,
        textShadow: NSShadow? = nil,
        maximumPointSize: CGFloat,
        weight: UIFont.Weight,
        minimumScaleFactor: CGFloat,
        minimumPointSize: CGFloat? = nil,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) {
        self.maximumPointSize = maximumPointSize
        self.weight = weight
        minimumFittingScale = minimumScaleFactor
        explicitMinimumPointSize = minimumPointSize
        self.displayVariant = displayVariant
        self.verticalRawText = verticalRawText
        displayForegroundColor = foregroundColor
        displaySecondaryForegroundColor = secondaryForegroundColor
        displayTextShadow = textShadow
        self.measurementCache = measurementCache
        if verticalRawText != nil {
            lineBreakMode = .byCharWrapping
        } else if displayVariant == nil {
            lineBreakMode = .byWordWrapping
        }
        lineBreakStrategy = [.standard, .hangulWordPriority]
        applyFont(pointSize: maximumPointSize)
        setNeedsLayout()
    }

    func measurementBounds() -> CGRect {
        bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layoutText = verticalRawText ?? text,
              !layoutText.isEmpty
        else {
            return
        }
        let available = measurementBounds()
        guard available.width > 0, available.height > 0 else { return }

        let minimumPointSize: CGFloat
        if verticalRawText != nil {
            // Match c1's public render contract: the DOM fitter never shrank
            // below `minimumRenderedFontSize`. Preserve that readability floor
            // and let the explicit Core Text clip be the bounded fallback when
            // an adversarially long source still cannot fit.
            minimumPointSize = min(
                maximumPointSize,
                BrowserOverlayLayoutPlanner.minimumRenderedFontSize
            )
        } else {
            minimumPointSize = min(
                maximumPointSize,
                explicitMinimumPointSize ?? max(
                    8,
                    maximumPointSize * minimumFittingScale
                )
            )
        }
        let fitInput = FontFitInput(
            text: layoutText,
            displayVariant: displayVariant,
            verticalRawText: verticalRawText,
            availableSize: available.size,
            minimumPointSize: minimumPointSize,
            maximumPointSize: maximumPointSize,
            weightRawValue: weight.rawValue
        )
        if cachedFontFitInput == fitInput,
           let cachedFittedPointSize
        {
            applyFont(pointSize: cachedFittedPointSize)
            return
        }
        let fittedPointSize: CGFloat
        if textFits(
            layoutText,
            pointSize: maximumPointSize,
            available: available
        ) {
            // The DOM keeps the payload font verbatim when it already fits.
            fittedPointSize = maximumPointSize
        } else if !textFits(
            layoutText,
            pointSize: minimumPointSize,
            available: available
        ) {
            fittedPointSize = minimumPointSize
        } else {
            var low = minimumPointSize
            var high = maximumPointSize
            for _ in 0..<9 {
                let candidate = (low + high) / 2
                if textFits(
                    layoutText,
                    pointSize: candidate,
                    available: available
                ) {
                    low = candidate
                } else {
                    high = candidate
                }
            }
            // c1 floors the paint-time CSS fit to quarter-point increments.
            fittedPointSize = floor(low * 4) / 4
        }
        cachedFontFitInput = fitInput
        cachedFittedPointSize = fittedPointSize
        applyFont(pointSize: fittedPointSize)
    }

    private func textFits(
        _ text: String,
        pointSize: CGFloat,
        available: CGRect
    ) -> Bool {
        if verticalRawText != nil {
            return BrowserOverlayVerticalTextRenderer.fits(
                text: text,
                available: available.size,
                fontSize: pointSize,
                weight: weight
            )
        }
        if let displayVariant {
            let rendered = displayVariant.attributedString(
                fontSize: pointSize,
                availableWidth: available.width,
                measurementCache: measurementCache,
                usesDOMFontFamily: true
            )
            renderedMeasurementLabel.attributedText = rendered
            renderedMeasurementLabel.lineBreakMode =
                displayVariant.lineBreakMode(
                    availableWidth: available.width,
                    fontSize: pointSize,
                    measurementCache: measurementCache
                )
            let measured = renderedMeasurementLabel.textRect(
                forBounds: CGRect(origin: .zero, size: available.size),
                limitedToNumberOfLines: 0
            )
            return ceil(measured.width) <= available.width + 0.5 &&
                ceil(measured.height) <= available.height + 0.5
        }
        return BrowserOverlayLayoutPlanner.horizontalTextFits(
            text,
            available: available.size,
            fontSize: pointSize,
            weight: weight
        )
    }

    private func applyFont(pointSize: CGFloat) {
        if let verticalRawText {
            applyVerticalFont(
                text: verticalRawText,
                pointSize: pointSize
            )
            return
        }
        if appliedVerticalRawText != nil {
            appliedDisplayVariant = nil
        }
        appliedVerticalRawText = nil
        guard let displayVariant else {
            appliedDisplayVariant = nil
            appliedDisplayForegroundColor = nil
            appliedDisplaySecondaryForegroundColor = nil
            appliedDisplayTextShadow = nil
            appliedDisplayPointSize = nil
            appliedDisplayWidth = nil
            appliedDisplayLineBreakMode = nil
            if abs(font.pointSize - pointSize) > 0.01 {
                font = BrowserOverlayFont.system(ofSize: pointSize, weight: weight)
            }
            return
        }

        // Attributed variants carry a font on every run. Writing UILabel.font
        // as well makes UIKit invalidate its baseline constraints and then
        // restore the first run's font while laying out the attributed text.
        // The next layout writes UILabel.font again, creating an unbounded
        // layout loop (and visible flicker) for dual source/translation cards.
        // Cache the semantic render state and never mutate UILabel from inside
        // layout when the rendered value is already current.
        let availableWidth = measurementBounds().width
        let nextLineBreakMode = displayVariant.lineBreakMode(
            availableWidth: availableWidth,
            fontSize: pointSize,
            measurementCache: measurementCache
        )
        let sameForeground = colorsEqual(
            appliedDisplayForegroundColor,
            displayForegroundColor
        )
        let sameSecondaryForeground = colorsEqual(
            appliedDisplaySecondaryForegroundColor,
            displaySecondaryForegroundColor
        )
        let sameTextShadow = textShadowsEqual(
            appliedDisplayTextShadow,
            displayTextShadow
        )
        let isAlreadyApplied =
            appliedDisplayVariant == displayVariant &&
            sameForeground &&
            sameSecondaryForeground &&
            sameTextShadow &&
            appliedDisplayPointSize.map {
                abs($0 - pointSize) <= 0.01
            } == true &&
            appliedDisplayWidth.map {
                abs($0 - availableWidth) <= 0.01
            } == true &&
            appliedDisplayLineBreakMode == nextLineBreakMode
        guard !isAlreadyApplied else { return }

        // Store first so even a synchronous UIKit invalidation cannot apply
        // the same state recursively.
        appliedDisplayVariant = displayVariant
        appliedDisplayForegroundColor = displayForegroundColor
        appliedDisplaySecondaryForegroundColor =
            displaySecondaryForegroundColor
        appliedDisplayTextShadow = displayTextShadow
        appliedDisplayPointSize = pointSize
        appliedDisplayWidth = availableWidth
        appliedDisplayLineBreakMode = nextLineBreakMode
        if lineBreakMode != nextLineBreakMode {
            lineBreakMode = nextLineBreakMode
        }
        attributedText = displayVariant.attributedString(
            fontSize: pointSize,
            foregroundColor: displayForegroundColor,
            secondaryForegroundColor: displaySecondaryForegroundColor,
            textShadow: displayTextShadow,
            availableWidth: availableWidth,
            measurementCache: measurementCache,
            usesDOMFontFamily: true
        )
    }

    override func drawText(in rect: CGRect) {
        guard let verticalRawText,
              let context = UIGraphicsGetCurrentContext()
        else {
            super.drawText(in: rect)
            return
        }
        BrowserOverlayVerticalTextRenderer.draw(
            text: verticalRawText,
            in: rect,
            context: context,
            fontSize: appliedDisplayPointSize ?? maximumPointSize,
            weight: weight,
            foregroundColor: displayForegroundColor,
            textShadow: displayTextShadow
        )
    }

    private func applyVerticalFont(
        text: String,
        pointSize: CGFloat
    ) {
        let availableWidth = measurementBounds().width
        let sameForeground = colorsEqual(
            appliedDisplayForegroundColor,
            displayForegroundColor
        )
        let sameTextShadow = textShadowsEqual(
            appliedDisplayTextShadow,
            displayTextShadow
        )
        let isAlreadyApplied =
            appliedVerticalRawText == text &&
            sameForeground &&
            sameTextShadow &&
            appliedDisplayPointSize.map {
                abs($0 - pointSize) <= 0.01
            } == true &&
            appliedDisplayWidth.map {
                abs($0 - availableWidth) <= 0.01
            } == true
        guard !isAlreadyApplied else { return }

        appliedVerticalRawText = text
        appliedDisplayVariant = displayVariant
        appliedDisplayForegroundColor = displayForegroundColor
        appliedDisplaySecondaryForegroundColor = nil
        appliedDisplayTextShadow = displayTextShadow
        appliedDisplayPointSize = pointSize
        appliedDisplayWidth = availableWidth
        appliedDisplayLineBreakMode = .byCharWrapping
        if lineBreakMode != .byCharWrapping {
            lineBreakMode = .byCharWrapping
        }
        attributedText = BrowserOverlayVerticalTextRenderer.attributedString(
            text: text,
            fontSize: pointSize,
            weight: weight,
            foregroundColor: displayForegroundColor,
            textShadow: displayTextShadow
        )
        setNeedsDisplay()
    }

    private func colorsEqual(_ left: UIColor?, _ right: UIColor?) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.isEqual(right)
        default:
            return false
        }
    }

    private func textShadowsEqual(
        _ left: NSShadow?,
        _ right: NSShadow?
    ) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return true
        case let (left?, right?):
            guard left.shadowOffset == right.shadowOffset,
                  abs(left.shadowBlurRadius - right.shadowBlurRadius) <= 0.01
            else {
                return false
            }
            return colorsEqual(
                left.shadowColor as? UIColor,
                right.shadowColor as? UIColor
            )
        default:
            return false
        }
    }
}

private final class OverlayFittingInsetLabel: OverlayFittingLabel {
    private var contentInsets = BrowserOverlayCardTextInsets.regular

    func setContentInsets(_ next: UIEdgeInsets) {
        guard contentInsets != next else { return }
        contentInsets = next
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: effectiveContentInsets))
    }

    override func measurementBounds() -> CGRect {
        bounds.inset(by: effectiveContentInsets)
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        let insets = effectiveContentInsets
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }

    private var effectiveContentInsets: UIEdgeInsets { contentInsets }
}
