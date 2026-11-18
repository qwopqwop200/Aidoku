import Foundation
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Final glyph shaping and painting. Coordinates outside this type are top-left,
/// including `inkBounds`; Core Text's bottom-left coordinates never escape it.
/// The caller owns panel transforms, so a rotated label uses the same shaped
/// glyphs and fitting decision as its unrotated version.
enum NativeTranslationTypography {
    // The app bundles this renamed OFL face; the native host registers the
    // same WOFF2 from its resource directory before rendering. Registration
    // belongs to the Core Text process, not necessarily Bundle.main.
    private static let bundledSerifRegistered: Bool = {
        func isRegistered() -> Bool {
            let font = CTFontCreateWithName("AidokuSerifKR-Bold" as CFString, 12, nil)
            return CTFontCopyPostScriptName(font) as String == "AidokuSerifKR-Bold"
        }
        if isRegistered() { return true }
        guard let url = Bundle.main.url(forResource: "AidokuSerifKR-Bold", withExtension: "woff2") else { return false }
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { return true }
        // Another consumer may have registered the process-wide face already.
        return isRegistered()
    }()

    static var availabilityKey: String {
        "native-typography-v2:serif-\(bundledSerifRegistered ? "available" : "unavailable")"
    }

    static var isBundledSerifAvailable: Bool { bundledSerifRegistered }

    enum HorizontalAlignment { case center, left, right }
    enum HorizontalWrapping { case normal, keepAll, keepAllWithEmergency }
    enum HorizontalWhitespace { case preWrap, normal, preLine }

    enum OutlinePaintOrder: String { case strokeThenFill, fillThenStroke }

    struct Style {
        var fontName: String?
        var fontScript: String
        /// Translated Korean may retain a few Japanese characters. Keep the
        /// source hint for source-only labels, but choose Korean metrics when
        /// Hangul dominates a translated label's Japanese hint.
        var prefersDominantKoreanScript: Bool
        var fontSize: CGFloat
        var bold: Bool
        var vertical: Bool
        var foreground: CGColor
        var outline: CGColor?
        var outlineWidth: CGFloat
        var outlinePaintOrder: OutlinePaintOrder
        var tracking: CGFloat
        /// Initial CSS letter spacing is relative to font size. A later
        /// explicit pixel assignment keeps its value through font-only trials.
        var trackingScalesWithFont: Bool = true
        var lineHeight: CGFloat
        var optimizesKoreanWrapping: Bool
        var koreanQuoteMode: Int
        var alignsToTop: Bool
        var horizontalScale: CGFloat
        var balancesHorizontalLines: Bool
        var keepsWholeWords: Bool
        var horizontalWrapping: HorizontalWrapping
        var horizontalWhitespace: HorizontalWhitespace
        fileprivate var explicitLineFlow: Bool = false
        fileprivate var wholeWordFallbackResolved: Bool = false
        fileprivate var usesKeepAllInlineItemWidths: Bool = false
        fileprivate var keepAllParagraphEndRows: [Bool]? = nil
        var usesBlockWordLayout: Bool
        var usesPreformattedBlockRows: Bool
        var preservesBlockRows: Bool { usesBlockWordLayout || usesPreformattedBlockRows }
        var blockWordLayoutUsesTopPadding: Bool
        var horizontalAlignment: HorizontalAlignment
        var blockRowHorizontalAlignment: HorizontalAlignment?
        var outlineGlow: CGFloat
        var strictLineBreak: Bool
        var balancesExplicitParagraphs: Bool
        fileprivate var intrinsicText: String? = nil
        fileprivate var intrinsicMinimumContentWidth: CGFloat? = nil
        fileprivate var paintsVisibleFormFeeds: Bool = false

        init(
            fontName: String? = nil,
            fontScript: String = "",
            prefersDominantKoreanScript: Bool = false,
            fontSize: CGFloat,
            bold: Bool = true,
            vertical: Bool = false,
            foreground: CGColor = CGColor(gray: 0, alpha: 1),
            outline: CGColor? = nil,
            outlineWidth: CGFloat = 0,
            outlinePaintOrder: OutlinePaintOrder = .strokeThenFill,
            tracking: CGFloat? = nil,
            lineHeight: CGFloat? = nil,
            optimizesKoreanWrapping: Bool = true,
            koreanQuoteMode: Int = 0,
            alignsToTop: Bool = false,
            horizontalScale: CGFloat = 1,
            balancesHorizontalLines: Bool = false,
            keepsWholeWords: Bool = false,
            horizontalWrapping: HorizontalWrapping = .normal,
            horizontalWhitespace: HorizontalWhitespace = .preWrap,
            usesBlockWordLayout: Bool = false,
            usesPreformattedBlockRows: Bool = false,
            blockWordLayoutUsesTopPadding: Bool = false,
            horizontalAlignment: HorizontalAlignment = .center,
            blockRowHorizontalAlignment: HorizontalAlignment? = nil,
            outlineGlow: CGFloat = 0,
            strictLineBreak: Bool = false,
            balancesExplicitParagraphs: Bool = false
        ) {
            self.fontName = fontName
            self.fontScript = fontScript
            self.prefersDominantKoreanScript = prefersDominantKoreanScript
            self.fontSize = fontSize
            self.bold = bold
            self.vertical = vertical
            self.foreground = foreground
            self.outline = outline
            self.outlineWidth = outlineWidth
            self.outlinePaintOrder = outlinePaintOrder
            self.tracking = tracking ?? fontSize * -0.012
            self.lineHeight = lineHeight ?? fontSize * (vertical ? 1 : 1.2)
            self.optimizesKoreanWrapping = optimizesKoreanWrapping
            self.koreanQuoteMode = koreanQuoteMode
            self.alignsToTop = alignsToTop
            self.horizontalScale = horizontalScale
            self.balancesHorizontalLines = balancesHorizontalLines
            self.keepsWholeWords = keepsWholeWords
            self.horizontalWrapping = horizontalWrapping
            self.horizontalWhitespace = horizontalWhitespace
            self.usesBlockWordLayout = usesBlockWordLayout
            self.usesPreformattedBlockRows = usesPreformattedBlockRows
            self.blockWordLayoutUsesTopPadding = blockWordLayoutUsesTopPadding
            self.horizontalAlignment = horizontalAlignment
            self.blockRowHorizontalAlignment = blockRowHorizontalAlignment
            self.outlineGlow = outlineGlow
            self.strictLineBreak = strictLineBreak
            self.balancesExplicitParagraphs = balancesExplicitParagraphs
        }
    }

    struct Layout {
        /// Complete occupied text extent, including ink overhang and outline.
        /// This is never the size of only the visible/clipped text fragment.
        let size: CGSize
        let inkBounds: CGRect
        let visibleUTF16Range: NSRange
        let lineCount: Int
        let fits: Bool
        let glyphBounds: [CGRect]
        let rangeBounds: [CGRect]
        let lineRanges: [NSRange]
        let shapedText: String
        fileprivate let frame: CTFrame?
        fileprivate let frameSize: CGSize
        fileprivate let offset: CGPoint
        fileprivate let attributed: NSAttributedString?
        fileprivate let frameAttributes: CFDictionary?
        fileprivate var paintScaleX: CGFloat = 1
        fileprivate var lineOffsets: [CGPoint] = []
        /// Exact widths used by the committed horizontal alignment producer.
        /// Raw CT advance is not equivalent for trailing whitespace or inline items.
        fileprivate var committedRowAlignmentWidths: [CGFloat]? = nil
        fileprivate var verticalPaintOffsets: [CGPoint] = []
        fileprivate var blockRowIntrinsicWidths: [CGFloat?] = []
        fileprivate var outlineGlow: CGFloat = 0
        fileprivate var outlineGlowColor: CGColor?
        /// Original UTF16 ownership for each shaped display code unit. A
        /// generated soft break owns a zero-length source boundary.
        var sourceUTF16Ownership: [NSRange]? = nil
        fileprivate(set) var sourceOwnershipNormalization: SourceOwnershipNormalization = .exact
        /// Explicit producer provenance. Missing after an uninstrumented transform
        /// is unknown, not proof that manual wrapping did not occur.
        var fromManualWrap: Bool? = nil

        fileprivate static var empty: Self {
            Self(
                size: .zero, inkBounds: .zero,
                visibleUTF16Range: NSRange(location: 0, length: 0),
                lineCount: 0, fits: true, glyphBounds: [], rangeBounds: [], lineRanges: [],
                shapedText: "", frame: nil, frameSize: .zero, offset: .zero, attributed: nil, frameAttributes: nil
            )
        }
    }

    static func layout(text: String, in available: CGSize, style: Style) -> Layout {
        guard !text.isEmpty else { return .empty }
        guard available.width.isFinite, available.height.isFinite,
              available.width > 0, available.height > 0,
              style.fontSize.isFinite, style.fontSize > 0,
              style.lineHeight.isFinite, style.lineHeight > 0,
              style.tracking.isFinite, style.outlineWidth.isFinite,
              style.outlineWidth >= 0, style.horizontalScale.isFinite,
              style.horizontalScale >= 0.5, style.horizontalScale <= 1
        else {
            return Layout(
                size: .zero, inkBounds: .zero,
                visibleUTF16Range: NSRange(location: 0, length: 0),
                lineCount: 0, fits: false, glyphBounds: [], rangeBounds: [], lineRanges: [],
                shapedText: text, frame: nil, frameSize: .zero, offset: .zero, attributed: nil, frameAttributes: nil
            )
        }

        let collapsedKeepAll = style.horizontalWrapping != .normal &&
            (style.horizontalWhitespace == .preLine || style.horizontalWhitespace == .normal &&
                (style.horizontalWrapping == .keepAllWithEmergency || text.unicodeScalars.contains { [9,10,12,13].contains($0.value) }))
        if !style.vertical && !style.preservesBlockRows && !style.keepsWholeWords && collapsedKeepAll,
           let flow = layoutCollapsedKeepAllFlow(text: text, in: available, style: style) { return flow }

        if !style.vertical && !style.preservesBlockRows && !style.strictLineBreak && !style.keepsWholeWords &&
            style.horizontalWhitespace == .normal && style.horizontalWrapping == .keepAll {
            let supported = !text.unicodeScalars.contains { [9,10,12,13].contains($0.value) }
            let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if supported, let shaped = layoutKeepAllFlow(text: collapsed, in: available, style: style, overflowAnywhere: false) {
                let ownership = collapsedOwnership(source: text, collapsed: collapsed, layout: shaped)
                return Layout(size: shaped.size, inkBounds: shaped.inkBounds,
                    visibleUTF16Range: NSRange(location: 0, length: text.utf16.count), lineCount: shaped.lineCount,
                    fits: shaped.fits, glyphBounds: shaped.glyphBounds, rangeBounds: shaped.rangeBounds,
                    lineRanges: shaped.lineRanges, shapedText: shaped.shapedText, frame: shaped.frame,
                    frameSize: shaped.frameSize, offset: shaped.offset, attributed: shaped.attributed,
                    frameAttributes: shaped.frameAttributes, paintScaleX: shaped.paintScaleX,
                    lineOffsets: shaped.lineOffsets, committedRowAlignmentWidths: shaped.committedRowAlignmentWidths,
                    outlineGlow: shaped.outlineGlow, outlineGlowColor: shaped.outlineGlowColor,
                    sourceUTF16Ownership: ownership, sourceOwnershipNormalization: .certifiedASCIISpaceCollapse)
            }
            if !style.wholeWordFallbackResolved {
                return layoutKeepingWholeWords(text: text, in: available, style: style)
            }
        }
        if !style.vertical && !style.preservesBlockRows && !style.strictLineBreak && !style.keepsWholeWords &&
            style.horizontalWhitespace == .normal && style.horizontalWrapping == .normal,
           let flow = layoutNormalFlow(text: text, in: available, style: style) { return flow }
        if !style.vertical && !style.preservesBlockRows && !style.strictLineBreak && !style.keepsWholeWords && style.horizontalWhitespace == .preWrap && style.horizontalWrapping == .keepAll,
           let flow = layoutKeepAllFlow(text: text, in: available, style: style, overflowAnywhere: false) { return flow }
        if !style.vertical && !style.preservesBlockRows && !style.strictLineBreak && !style.keepsWholeWords && style.horizontalWhitespace == .preWrap && style.horizontalWrapping == .keepAllWithEmergency,
           let flow = layoutKeepAllFlow(text: text, in: available, style: style, overflowAnywhere: true) { return flow }
        if style.keepsWholeWords && !style.vertical && !style.preservesBlockRows && !style.strictLineBreak { return layoutKeepingWholeWords(text: text, in: available, style: style) }

        let scaleX = style.vertical ? 1 : style.horizontalScale
        let available = CGSize(width: available.width / scaleX, height: available.height)
        let wordAware = !style.preservesBlockRows && style.optimizesKoreanWrapping && !style.vertical
            ? koreanLines(text: text, available: available, style: style)?.joined(separator: "\n") : nil
        let balanced = !style.preservesBlockRows && wordAware == nil && style.balancesHorizontalLines && !style.vertical
            ? balancedHorizontalLines(text: text, available: available, style: style)?.joined(separator: "\n") : nil
        let preferred = !style.preservesBlockRows && wordAware == nil && style.balancesHorizontalLines && !style.vertical && !style.strictLineBreak
            ? preferredWholeWordLines(text: text, width: available.width, style: style) : nil
        let shapedText = style.usesPreformattedBlockRows ? text : style.usesBlockWordLayout ? blockWordText(text) : wordAware ?? balanced ?? preferred?.joined(separator: "\n") ?? text
        // These producers preserve input scalars and may insert LF only.
        // Verify that contract instead of searching repeated text or guessing
        // ownership after wrapping. Other normalization paths remain unknown.
        let insertedOwnership: [NSRange]? = !style.vertical && !style.usesPreformattedBlockRows &&
            !style.usesBlockWordLayout && (wordAware != nil || balanced != nil || preferred != nil)
            ? insertedLFOwnership(source: text, displayed: shapedText) : nil
        let attributed = attributedString(text: shapedText, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let extent = max(style.fontSize, style.lineHeight) * CGFloat(text.utf16.count + 2) * 2
        let frameSize: CGSize
        let suggested: CGSize
        if style.vertical {
            // Height controls column wrapping; width must allow *all* columns.
            // Using the panel width here would silently discard the overflow.
            let minimumInline = text.map { character -> CGFloat in
                guard !character.isWhitespace else { return 0 }
                let line = CTLineCreateWithAttributedString(attributedString(text: String(character), style: style))
                return max(0, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            }.max() ?? 0
            let usedInline = max(available.height, CGFloat((Float(minimumInline) * 64).rounded(.up)) / 64)
            frameSize = CGSize(width: max(available.width, extent), height: usedInline)
            suggested = .zero
        } else {
            suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: 0), nil,
                CGSize(width: available.width, height: max(available.height, extent)), nil
            )
            frameSize = CGSize(width: available.width, height: max(1, ceil(suggested.height) + 1))
        }
        let path = CGPath(rect: CGRect(origin: .zero, size: frameSize), transform: nil)
        let frameAttributes: CFDictionary? = style.vertical
            ? [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
            : nil
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, frameAttributes)
        let lines = CTFrameGetLines(frame)
        let count = CFArrayGetCount(lines)
        let range = CTFrameGetVisibleStringRange(frame)
        let blockIntrinsic = collapsedBlockRowIntrinsicWidths(text: text, style: style)
        let horizontalPaint = horizontalPaintMovements(frame: frame, frameSize: frameSize,
            originalText: style.intrinsicText ?? text, shapedText: shapedText, style: style,
            scaleX: scaleX, blockIntrinsic: blockIntrinsic)
        let movements = horizontalPaint.movements
        let bounds = inkBounds(frame: frame, frameSize: frameSize, vertical: style.vertical)
        let outlineInset = style.outline == nil ? 0 : style.outlineWidth / 2
        let ink = bounds.isEmpty ? bounds : bounds.insetBy(dx: -outlineInset, dy: -outlineInset)
        let occupied = style.vertical
            ? ink.size
            : CGSize(width: max(suggested.width, ink.width), height: max(suggested.height, ink.height))
        let offset: CGPoint
        if style.vertical {
            // The flex cross-axis is the right-to-left column stack. The
            // balanced-column rule anchors this stack to the right edge;
            // inline centering remains independent of that cross alignment.
            var origins = [CGPoint](repeating: .zero, count: count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            let pitch = floor(max(style.fontSize, style.lineHeight)), crossWidth = CGFloat(count) * pitch
            let crossLeft = style.alignsToTop ? available.width - crossWidth
                : ((available.width - crossWidth) * 32).rounded(.towardZero) / 64
            let baselineX = crossLeft + CGFloat(max(0, count - 1)) * pitch + pitch / 2
            let maximum = text.components(separatedBy: .newlines).map {
                CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedString(text: $0, style: style)), nil, nil, nil))
            }.max() ?? 0
            let minimum = text.filter { !$0.isWhitespace }.map {
                CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedString(text: String($0), style: style)), nil, nil, nil))
            }.max() ?? 0
            let inline = NativeTextPaintGeometry.anonymousFlexBox(contentWidth: available.height,
                maximumContentWidth: maximum, minimumContentWidth: minimum)
            offset = CGPoint(x: baselineX - (origins.first?.x ?? 0),
                y: (inline?.origin ?? 0) + ((inline?.width ?? frameSize.height) - frameSize.height) / 2)
        } else {
            // Paragraph alignment centers each horizontal line independently.
            // CSS flex centering applies to the line box stack, not the ink.
            offset = CGPoint(x: 0, y: (style.alignsToTop || style.preservesBlockRows && style.blockWordLayoutUsesTopPadding) ? 0 : ((available.height - CGFloat(count) * floor(max(style.fontSize, style.lineHeight))) * 32).rounded(.towardZero) / 64)
        }
        let verticalMovements = style.vertical ? verticalPaintMovements(frame: frame, frameSize: frameSize,
            offset: offset, available: available, attributed: attributed, text: shapedText, style: style) : []
        let painted = ink.offsetBy(dx: offset.x, dy: offset.y)
        let complete = range.location == 0 && range.length >= attributed.length
        let fits = complete && occupied.width <= available.width + 0.5 &&
            occupied.height <= available.height + 0.5 &&
            CGRect(origin: .zero, size: available).insetBy(dx: -0.5, dy: -0.5).contains(painted)
        let glyphs = glyphBounds(frame: frame, frameSize: frameSize, vertical: style.vertical,
            movements: style.vertical ? verticalMovements : movements, scaleX: scaleX).map {
            $0.insetBy(dx: -outlineInset, dy: -outlineInset).offsetBy(dx: offset.x, dy: offset.y)
        }
        let lineRanges = (0..<count).map { index -> NSRange in
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            let range = CTLineGetStringRange(line)
            return NSRange(location: max(0, range.location), length: max(0, range.length))
        }
        func scaled(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scaleX, y: rect.minY, width: rect.width * scaleX, height: rect.height)
        }
        let paintedInk = glyphs.reduce(CGRect.null) { $0.union($1) }
        // Painting can shift physical ink away from the original Core Text
        // bounds. Native containment follows the actual painted positions;
        // horizontal occupied-size and complete-frame predicates stay exact.
        let horizontalRowsMoved = !style.vertical && movements.contains { abs($0.y) > 0.000001 }
        let rowGap = horizontalRowsMoved && !fits
            ? minimumHorizontalPaintedRowGap(frame:frame,glyphBounds:glyphs,lineRanges:lineRanges) : nil
        // Newly admitted horizontal fits must also keep adjacent stroke rows
        // apart. Old unmoved and upright vertical fit semantics stay exact.
        let newHorizontalAdmissionClear = !horizontalRowsMoved || fits ||
            rowGap.map { $0 >= max(CGFloat(0.25),style.fontSize*0.04) } == true
        let resolvedOccupied = verticalMovements.isEmpty || paintedInk.isNull ? occupied : paintedInk.size
        let resolvedFits = verticalMovements.isEmpty && !horizontalRowsMoved || paintedInk.isNull ? fits
            : complete && resolvedOccupied.width <= available.width + 0.5 &&
                resolvedOccupied.height <= available.height + 0.5 &&
                CGRect(origin: .zero, size: available).insetBy(dx: -0.5, dy: -0.5).contains(paintedInk) &&
                newHorizontalAdmissionClear
        return Layout(
            size: CGSize(width: resolvedOccupied.width * scaleX, height: resolvedOccupied.height), inkBounds: scaled(paintedInk.isNull ? painted : paintedInk),
            visibleUTF16Range: complete
                ? NSRange(location: 0, length: text.utf16.count)
                : NSRange(location: max(0, range.location), length: min(text.utf16.count, max(0, range.length))),
            lineCount: count, fits: resolvedFits, glyphBounds: glyphs.map(scaled),
            rangeBounds: rangeBounds(frame: frame, frameSize: frameSize, offset: offset, scaleX: scaleX,
                text: shapedText, originalText: style.intrinsicText ?? text, style: style, movements: movements, blockIntrinsic: blockIntrinsic, reuse: horizontalPaint.geometry),
            lineRanges: lineRanges,
            shapedText: shapedText, frame: frame, frameSize: frameSize, offset: offset,
            attributed: attributed, frameAttributes: frameAttributes, paintScaleX: scaleX, lineOffsets: movements,
            committedRowAlignmentWidths: horizontalPaint.widths,
            verticalPaintOffsets: verticalMovements, blockRowIntrinsicWidths: blockIntrinsic,
            outlineGlow: max(0, style.outlineGlow), outlineGlowColor: style.outline,
            sourceUTF16Ownership: insertedOwnership
        )
    }

    /// Compose only verified collapsed-input provenance; never search text.
    private static func collapsedOwnership(source: String, collapsed: String, layout: Layout) -> [NSRange]? {
        guard let outer = SourceUTF16Transport.ownership(text: source,
            ranges: [NSRange(location: 0, length: source.utf16.count)], mode: .collapseSpaces),
            outer.displayed.utf16.elementsEqual(collapsed.utf16),
            let inner = layout.sourceUTF16Ownership,
            inner.count == layout.shapedText.utf16.count,
            let context = SourceUTF16Transport.prepareLift(through: outer, sourceUTF16Length: source.utf16.count)
        else { return nil }
        var result: [NSRange] = []
        result.reserveCapacity(inner.count)
        var cursor = 0
        for range in inner {
            guard range.location >= cursor, let lifted = context.lift(range) else { return nil }
            result.append(lifted)
            cursor = range.location + range.length
        }
        return result
    }

    private enum SourceUTF16Transport {
        enum OwnershipMode { case collapseSpaces, trimSpaces, preserve }
        struct Ownership {
            let displayed: String
            let units: [NSRange]
        }
        static func scalarBoundary(_ offset: Int, in input: [UInt16]) -> Bool {
            guard offset >= 0, offset <= input.count else { return false }
            return offset == 0 || offset == input.count ||
                !((0xD800...0xDBFF).contains(input[offset - 1]) &&
                  (0xDC00...0xDFFF).contains(input[offset]))
        }
        static func ownership(text: String, ranges: [NSRange], mode: OwnershipMode,
                              paragraphEnds: [Bool]? = nil) -> Ownership? {
            // Bounds before materializing the UTF16 array or coverage bitmap.
            let source = text as NSString
            guard source.length <= 8192, ranges.count <= 512,
                  paragraphEnds == nil || paragraphEnds?.count == ranges.count else { return nil }
            let input = Array(text.utf16)
            // Both target producers decline authored CR/CRLF; the separate
            // pre-line CR-drop producer must supply its own provenance.
            guard !input.contains(13) else { return nil }
            let allowsSpaces: Bool
            switch mode {
            case .collapseSpaces, .trimSpaces: allowsSpaces = true
            case .preserve: allowsSpaces = false
            }
            var rows: [String] = [], maps: [[NSRange]] = []
            var previousEnd = 0
            for range in ranges {
                guard range.location >= previousEnd, range.location <= input.count,
                      range.length >= 0, range.length <= input.count - range.location,
                      scalarBoundary(range.location, in: input),
                      scalarBoundary(range.location + range.length, in: input) else { return nil }
                previousEnd = range.location + range.length
                let part = source.substring(with: range)
                var owned: [NSRange] = []
                let row: String
                switch mode {
                case .collapseSpaces:
                    // Same Character-based split as the existing normal producer.
                    let tokens = part.split(separator: " ", omittingEmptySubsequences: true)
                    var tokenEnd: Int?
                    for token in tokens {
                        let start = range.location + part.utf16.distance(
                            from: part.utf16.startIndex, to: token.startIndex)
                        let end = range.location + part.utf16.distance(
                            from: part.utf16.startIndex, to: token.endIndex)
                        if let tokenEnd {
                            guard start > tokenEnd,
                                  input[tokenEnd..<start].allSatisfy({ $0 == 32 }) else { return nil }
                            owned.append(NSRange(location: tokenEnd, length: start - tokenEnd))
                        }
                        owned.append(contentsOf: (start..<end).map { NSRange(location: $0, length: 1) })
                        tokenEnd = end
                    }
                    row = tokens.joined(separator: " ")
                case .trimSpaces, .preserve:
                    var start = range.location, end = previousEnd
                    if case .trimSpaces = mode {
                        while start < end && input[start] == 32 { start += 1 }
                        while end > start && input[end - 1] == 32 { end -= 1 }
                    }
                    guard scalarBoundary(start, in: input), scalarBoundary(end, in: input) else { return nil }
                    row = source.substring(with: NSRange(location: start, length: end - start))
                    owned = (start..<end).map { NSRange(location: $0, length: 1) }
                }
                guard owned.count == row.utf16.count else { return nil }
                rows.append(row); maps.append(owned)
            }
            var ledger: [NSRange] = []
            for index in rows.indices {
                if index > 0 {
                    let left = maps[index - 1].last.map { $0.location + $0.length }
                        ?? ranges[index - 1].location
                    let right = maps[index].first?.location ?? ranges[index].location
                    guard right >= left else { return nil }
                    let gap = input[left..<right]
                    let feeds = (left..<right).filter { input[$0] == 10 }
                    let ownedBreak: NSRange
                    if !feeds.isEmpty {
                        guard paragraphEnds?[index - 1] == true, feeds.count == 1,
                              gap.allSatisfy({ $0 == 10 || allowsSpaces && $0 == 32 }) else { return nil }
                        ownedBreak = NSRange(location: feeds[0], length: 1)
                    } else if !gap.isEmpty {
                        guard allowsSpaces, gap.allSatisfy({ $0 == 32 }) else { return nil }
                        ownedBreak = NSRange(location: right, length: 0)
                    } else {
                        ownedBreak = NSRange(location: right, length: 0)
                    }
                    ledger.append(ownedBreak)
                }
                ledger.append(contentsOf: maps[index])
            }
            let displayed = rows.joined(separator: "\n")
            guard ledger.count == displayed.utf16.count,
                  ledger.count <= 8192 + 511 else { return nil }
            var covered = [Bool](repeating: false, count: input.count)
            var cursor = 0
            for range in ledger {
                guard range.location >= cursor, range.location <= input.count,
                      range.length >= 0, range.length <= input.count - range.location else { return nil }
                for unit in range.location..<(range.location + range.length) {
                    guard !covered[unit] else { return nil }
                    covered[unit] = true
                }
                cursor = range.location + range.length
            }
            let omitted = input.indices.filter { !covered[$0] }
            // Whole-source contract: only known trimmed ASCII spaces and exactly
            // one terminal paragraph LF may be omitted. Never omit letters/CR/TAB.
            let terminalLF: Int? = {
                guard paragraphEnds?.last == true, let last = ranges.last else { return nil }
                let end = last.location + last.length
                let tail = input[end...]
                let feeds = (end..<input.count).filter { input[$0] == 10 }
                guard feeds.count == 1,
                      tail.allSatisfy({ $0 == 10 || allowsSpaces && $0 == 32 }) else { return nil }
                return feeds[0]
            }()
            guard omitted.allSatisfy({ allowsSpaces && input[$0] == 32 || $0 == terminalLF }) else { return nil }
            return Ownership(displayed: displayed, units: ledger)
        }
        // A unit ledger may own one half of a surrogate pair. This pure-integer
        // operation never substrings it; text row ranges are checked above.
        struct LiftContext {
            fileprivate let units: [NSRange]
            fileprivate let gapPrefix: [Int]
            func lift(_ range: NSRange) -> NSRange? {
                guard range.location >= 0, range.location <= units.count,
                      range.length >= 0, range.length <= units.count - range.location else { return nil }
                if range.length == 0 {
                    let boundary = range.location < units.count ? units[range.location].location
                        : units.last.map { $0.location + $0.length } ?? 0
                    return NSRange(location: boundary, length: 0)
                }
                let last = range.location + range.length - 1
                guard gapPrefix[last] == gapPrefix[range.location] else { return nil }
                let first = units[range.location], final = units[last]
                return NSRange(location: first.location, length: final.location + final.length - first.location)
            }
        }
        static func prepareLift(through outer: Ownership,
                                sourceUTF16Length: Int) -> LiftContext? {
            guard sourceUTF16Length >= 0, sourceUTF16Length <= 8192,
                  outer.units.count <= 8192 + 511,
                  outer.units.count == outer.displayed.utf16.count else { return nil }
            var cursor = 0, gaps = 0
            var prefix: [Int] = []
            prefix.reserveCapacity(outer.units.count)
            for (index, value) in outer.units.enumerated() {
                guard value.location >= cursor, value.location <= sourceUTF16Length,
                      value.length >= 0, value.length <= sourceUTF16Length - value.location else { return nil }
                if index > 0 && value.location > cursor { gaps += 1 }
                prefix.append(gaps)
                cursor = value.location + value.length
            }
            return LiftContext(units: outer.units, gapPrefix: prefix)
        }
    }

    /// Exact insertion-only transport, not a source-image/OCR correspondence.
    /// A generated LF owns no input units. Authored newlines are intentionally
    /// declined here because their provenance belongs to the row producer.
    static func insertedLFOwnership(source: String, displayed: String) -> [NSRange]? {
        guard source.utf16.count <= 131_072, displayed.utf16.count <= 262_144,
              !source.contains(where: \.isNewline) else { return nil }
        let input = Array(source.unicodeScalars)
        var cursor = 0, sourceOffset = 0
        var result: [NSRange] = []
        result.reserveCapacity(displayed.utf16.count)
        for scalar in displayed.unicodeScalars {
            if cursor < input.count, scalar.value == input[cursor].value {
                let width = scalar.utf16.count
                for unit in 0..<width {
                    result.append(NSRange(location: sourceOffset + unit, length: 1))
                }
                sourceOffset += width
                cursor += 1
            } else if scalar.value == 10 {
                result.append(NSRange(location: sourceOffset, length: 0))
            } else {
                return nil
            }
        }
        guard cursor == input.count, sourceOffset == source.utf16.count,
              result.count == displayed.utf16.count else { return nil }
        return result
    }

    /// Keep physical Core Text row ownership and already stroked/moved ink
    /// together. Empty or ambiguous rows cannot prove a new fit admission.
    private static func horizontalPaintedRows(frame: CTFrame,
        glyphBounds: [CGRect], lineRanges: [NSRange]) -> [CGRect]? {
        guard !glyphBounds.isEmpty, glyphBounds.count <= 256 else { return nil }
        let lines = CTFrameGetLines(frame), count = CFArrayGetCount(lines)
        guard count > 0, count <= 256, count == lineRanges.count else { return nil }
        var cursor = 0, inspected = 0, previousEnd = 0
        var rows: [CGRect] = []
        for lineIndex in 0..<count {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines,lineIndex),to:CTLine.self)
            let range = CTLineGetStringRange(line), expected = lineRanges[lineIndex]
            guard range.location == expected.location, range.length == expected.length,
                  range.location == previousEnd, range.length > 0 else { return nil }
            previousEnd = range.location+range.length
            let runs = CTLineGetGlyphRuns(line)
            var row = CGRect.null
            for runIndex in 0..<CFArrayGetCount(runs) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs,runIndex),to:CTRun.self)
                for glyphIndex in 0..<CTRunGetGlyphCount(run) {
                    inspected += 1
                    guard inspected <= 16_384 else { return nil }
                    guard !CTRunGetImageBounds(run,nil,CFRange(location:glyphIndex,length:1)).isEmpty else { continue }
                    guard cursor < glyphBounds.count else { return nil }
                    let glyph = glyphBounds[cursor]
                    guard glyph.minX.isFinite, glyph.minY.isFinite, glyph.width.isFinite,
                          glyph.height.isFinite, !glyph.isNull, !glyph.isEmpty else { return nil }
                    row = row.union(glyph); cursor += 1
                }
            }
            guard !row.isNull else { return nil }
            rows.append(row)
        }
        guard cursor == glyphBounds.count else { return nil }
        return rows
    }

    /// Stroked, positioned Core Text rows; nil is unavailable, never a safe gap.
    static func minimumPaintedRowGap(layout: Layout) -> CGFloat? {
        guard let frame = layout.frame,
              let rows = horizontalPaintedRows(frame: frame, glyphBounds: layout.glyphBounds,
                lineRanges: layout.lineRanges), rows.count > 1 else { return nil }
        return zip(rows, rows.dropFirst()).map { $0.1.minY - $0.0.maxY }.min()
    }

    private static func minimumHorizontalPaintedRowGap(frame: CTFrame,
        glyphBounds: [CGRect], lineRanges: [NSRange]) -> CGFloat? {
        guard let rows = horizontalPaintedRows(frame:frame,glyphBounds:glyphBounds,lineRanges:lineRanges) else { return nil }
        return zip(rows,rows.dropFirst()).map { $1.minY-$0.maxY }.min() ?? CGFloat.greatestFiniteMagnitude
    }

    /// CSS nowrap span text collapses ASCII segment whitespace and removes
    /// collapsed spaces at each line edge. NBSP and other Unicode separators
    /// remain text; raw pre-wrap captions never pass through this operation.
    static func blockWordText(_ text: String) -> String {
        text.components(separatedBy: "\n").map { row in
            var result = "", pendingSpace = false
            for scalar in row.unicodeScalars {
                if [9, 10, 12, 13, 32].contains(scalar.value) {
                    if !result.isEmpty { pendingSpace = true }
                } else {
                    if pendingSpace { result.append(" "); pendingSpace = false }
                    result.unicodeScalars.append(scalar)
                }
            }
            return result
        }.joined(separator: "\n")
    }

    /// Preserve the raw collapsed span's intrinsic arithmetic without changing
    /// its displayed text or glyph advances. Unsupported shaping retains the
    /// existing CTLine measurement for that row.
    private static func collapsedBlockRowIntrinsicWidths(text: String, style: Style) -> [CGFloat?] {
        guard !style.vertical, style.usesBlockWordLayout, !style.usesPreformattedBlockRows,
              text.utf16.count <= 2048 else { return [] }
        let natural = naturalHorizontalGlyphAdvances(style: style)
        return text.components(separatedBy: "\n").map { row -> CGFloat? in
            // Visible controls and Unicode spacing/format items have separate
            // glyph and inline-item contracts. Preserve their existing path.
            guard !row.unicodeScalars.contains(where: {
                ($0.properties.generalCategory == .control && ![9, 13].contains($0.value)) ||
                $0.properties.generalCategory == .format ||
                (CharacterSet.whitespacesAndNewlines.contains($0) && ![9, 13, 32].contains($0.value))
            }) else { return nil }
            return NativeCollapsedRowIntrinsicWidth.width(text: row, letterSpacing: Float(style.tracking), measureNaturalGlyphAdvances: natural)
        }
    }

    /// Natural advances retain default font kerning. Scalar ownership and
    /// run guards decline clusters, bidi, color glyphs, and font transforms.
    private static func naturalHorizontalGlyphAdvances(style: Style, requiresPrimaryFont: Bool = false) -> (String) -> [Float]? {
        var naturalStyle = style
        naturalStyle.tracking = 0
        var cache: [String: [Float]] = [:], declined = Set<String>()
        return { fragment in
            if let found = cache[fragment] { return found }
            if declined.contains(fragment) { return nil }
            let naturalText = NSMutableAttributedString(attributedString: attributedString(text: fragment, style: naturalStyle))
            naturalText.removeAttribute(NSAttributedString.Key(kCTKernAttributeName as String), range: NSRange(location: 0, length: naturalText.length))
            let line = CTLineCreateWithAttributedString(naturalText)
            var offsets: [Int] = [], cursor = 0
            for scalar in fragment.unicodeScalars { offsets.append(cursor); cursor += scalar.utf16.count }
            let primary = requiresPrimaryFont ? font(text: fragment, style: naturalStyle) : nil
            var values: [Float] = [], indices: [Int] = []
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                guard !CTRunGetStatus(run).contains(.rightToLeft), CTRunGetTextMatrix(run) == .identity,
                      count > 0, count <= offsets.count - values.count else { declined.insert(fragment); return nil }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let object = attributes[kCTFontAttributeName], CFGetTypeID(object as CFTypeRef) == CTFontGetTypeID(),
                      CTFontGetMatrix(object as! CTFont) == .identity,
                      !CTFontGetSymbolicTraits(object as! CTFont).contains(.traitColorGlyphs) else { declined.insert(fragment); return nil }
                if let primary {
                    let face = object as! CTFont
                    guard CTFontCopyPostScriptName(face) == CTFontCopyPostScriptName(primary),
                          CTFontGetSize(face) == CTFontGetSize(primary) else { declined.insert(fragment); return nil }
                }
                var advances = [CGSize](repeating: .zero, count: count)
                var stringIndices = [CFIndex](repeating: 0, count: count)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)
                guard advances.allSatisfy({ $0.width.isFinite && $0.width >= 0 && Float($0.width).isFinite && $0.height == 0 }) else {
                    declined.insert(fragment); return nil
                }
                values.append(contentsOf: advances.map { Float($0.width) })
                indices.append(contentsOf: stringIndices)
            }
            guard indices == offsets else { declined.insert(fragment); return nil }
            if requiresPrimaryFont && style.tracking == 0 {
                // Core Text's explicit kern-zero paint disables pair kerning.
                // Do not align that paint with a differently kerned measure.
                let painted = CTLineCreateWithAttributedString(attributedString(text: fragment, style: style))
                var paintedAdvances: [Float] = []
                for run in CTLineGetGlyphRuns(painted) as! [CTRun] {
                    var advances = [CGSize](repeating: .zero, count: CTRunGetGlyphCount(run))
                    CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                    paintedAdvances.append(contentsOf: advances.map { Float($0.width) })
                }
                guard paintedAdvances == values else { declined.insert(fragment); return nil }
            }
            cache[fragment] = values
            return values
        }
    }

    /// Keep-all inline items are measured word by word before line alignment.
    /// A synthetic soft break hangs its one trailing ASCII space; authored
    /// breaks and a final trailing space retain their established path.
    private static func keepAllInlineItemWidths(frame: CTFrame, text: String, style: Style) -> [CGFloat?] {
        guard style.usesKeepAllInlineItemWidths, !style.vertical,
              !style.preservesBlockRows, !style.strictLineBreak,
              !style.keepsWholeWords, style.horizontalScale == 1,
              style.horizontalAlignment == .center else { return [] }
        let source = text as NSString, lines = CTFrameGetLines(frame) as! [CTLine]
        let natural = naturalHorizontalGlyphAdvances(style: style, requiresPrimaryFont: true)
        return lines.enumerated().map { index, line in
            let range = CTLineGetStringRange(line)
            guard range.location >= 0, range.length >= 0,
                  range.location <= source.length, range.length <= source.length - range.location else { return nil }
            var row = source.substring(with: NSRange(location: range.location, length: range.length))
            if row.last == "\n" { row.removeLast() }
            guard !row.hasPrefix(" "), !row.contains("  "),
                  !(index == lines.count - 1 && row.hasSuffix(" ")),
                  !row.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ||
                      (CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 32)
                  }) else { return nil }
            return NativeCollapsedRowIntrinsicWidth.width(text: row,
                letterSpacing: Float(style.tracking), measureNaturalGlyphAdvances: natural)
        }
    }

    private static func blockRowBox(contentWidth: CGFloat, advance: CGFloat, style: Style) -> NativeTextPaintGeometry.FlexBox? {
        let alignment: CGFloat = style.blockRowHorizontalAlignment == .left ? 0
            : style.blockRowHorizontalAlignment == .right ? 1 : 0.5
        guard style.usesPreformattedBlockRows else {
            return NativeTextPaintGeometry.anonymousFlexBox(contentWidth: contentWidth,
                maximumContentWidth: advance, justification: alignment)
        }
        guard contentWidth.isFinite, advance.isFinite, contentWidth > 0, advance >= 0 else { return nil }
        let available = CGFloat((Float(contentWidth) * 64).rounded(.towardZero)) / 64
        let width = CGFloat((Float(advance) * 64).rounded(.up)) / 64
        let origin = (max(0, available - width) * alignment * 64).rounded(.towardZero) / 64
        return NativeTextPaintGeometry.FlexBox(origin: origin, width: width)
    }

    private static func minimumHorizontalContentWidth(text: String, style: Style) -> CGFloat {
        if let intrinsic = style.intrinsicMinimumContentWidth { return intrinsic }
        return text.filter { !$0.isWhitespace }.map {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                attributedString(text: String($0), style: style)), nil, nil, nil))
        }.max() ?? 0
    }

    /// Whole DOM selectNodeContents geometry is distinct from scalar ranges.
    /// Preserved span children contribute their block boxes as well as text;
    /// Packing additionally selects a full-width wrapper around those spans.
    static func wholeRangeBounds(layout: Layout, style: Style, available: CGSize,
                                 preservesBlockWrapper: Bool = false) -> CGRect? {
        let lines = captionLineMetrics(layout: layout)
        guard !lines.isEmpty else { return nil }
        var result = lines.reduce(CGRect.null) { $0.union($1.rect) }
        guard !style.vertical, style.preservesBlockRows else { return result.isNull ? nil : result }
        let scale = layout.paintScaleX, contentWidth = available.width / scale
        let pitch = floor(max(style.fontSize, style.lineHeight))
        let stackTop = layout.offset.y
        for (index, line) in lines.enumerated() {
            let intrinsic = index < layout.blockRowIntrinsicWidths.count ? layout.blockRowIntrinsicWidths[index] : nil
            guard let flex = blockRowBox(contentWidth: contentWidth, advance: intrinsic ?? line.rect.width / scale, style: style) else { continue }
            result = result.union(CGRect(x: flex.origin * scale, y: stackTop + CGFloat(index) * pitch,
                width: flex.width * scale, height: pitch))
        }
        if preservesBlockWrapper {
            result = result.union(CGRect(x: 0, y: stackTop,
                width: floor(contentWidth * 64) / 64 * scale, height: CGFloat(lines.count) * pitch))
        }
        return result.isNull ? nil : result
    }

    /// Intrinsic widest token using the supplied face and canvas-style width.
    /// The unit-search caller supplies its separate 700 sans-serif probe face.
    static func widestWord(text: String, style: Style) -> CGFloat {
        text.split(whereSeparator: \.isWhitespace).map { measuredWidth(text: String($0), style: style) }.max() ?? 0
    }

    struct WordFlow {
        let wordSplits: Int
        let strandedSyllable: Bool
        let displayedLines: Int
    }

    /// Actual committed rows mapped back to the source UTF-16 string. Collapsed
    /// spaces and explicit layout breaks never invent a split between words.
    static func wordFlow(layout: Layout, originalText: String) -> WordFlow {
        var source: [(scalar: Unicode.Scalar, start: Int, end: Int)] = [], offset = 0
        for scalar in originalText.unicodeScalars {
            let next = offset + scalar.utf16.count
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { source.append((scalar, offset, next)) }
            offset = next
        }
        let text = layout.shapedText as NSString
        var position = 0, previous: (end: Int, row: Int)?, splits = 0, counts: [Int] = []
        for (row, range) in layout.lineRanges.enumerated() where range.location >= 0 && NSMaxRange(range) <= text.length {
            var count = 0
            for scalar in text.substring(with: range).unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                guard position < source.count, source[position].scalar == scalar else {
                    return WordFlow(wordSplits: max(1, splits), strandedSyllable: true, displayedLines: layout.lineCount)
                }
                let value = source[position]
                if let previous, previous.row != row && previous.end == value.start { splits += 1 }
                previous = (value.end, row); position += 1; count += scalar.utf16.count
            }
            if count > 0 { counts.append(count) }
        }
        let characters = counts.reduce(0, +)
        return WordFlow(wordSplits: splits,
            strandedSyllable: counts.count > 1 && characters >= 4 && counts.contains(where: { $0 < 2 }),
            displayedLines: counts.count)
    }

    struct CanvasTextMetrics {
        let fontAscent: CGFloat
        let fontDescent: CGFloat
        let actualAscent: CGFloat
        let actualDescent: CGFloat
        let actualLeft: CGFloat
        let actualRight: CGFloat
        let advance: CGFloat
    }

    /// Canvas font measurement has no CSS tracking, outline, or writing-mode
    /// transform. ASCII control whitespace is normalized to ordinary spaces.
    static func canvasTextMetrics(text: String, style: Style) -> CanvasTextMetrics? {
        guard style.fontSize.isFinite, style.fontSize > 0 else { return nil }
        let normalized = text.unicodeScalars.map { scalar -> String in
            [9, 10, 12, 13].contains(scalar.value) ? " " : String(scalar)
        }.joined()
        // Retain the actual selected CTFont: private UI font PostScript
        // names cannot reliably be recreated with CTFontCreateWithName.
        let face = font(text: normalized.isEmpty ? "M" : normalized, style: style)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): face]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: normalized, attributes: attributes))
        // Canvas FontMetrics caches lroundf(primary ascent/descent); DOM
        // scalar ranges separately retain their measured advance rectangles.
        let bounds = (ascent: max(0, CGFloat(Float(CTFontGetAscent(face))).rounded(.toNearestOrAwayFromZero)),
                      descent: max(0, CGFloat(Float(CTFontGetDescent(face))).rounded(.toNearestOrAwayFromZero)))
        let image = CTLineGetImageBounds(line, nil)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let hasInk = !image.isNull && !image.isEmpty && [image.minX,image.maxX,image.minY,image.maxY].allSatisfy(\.isFinite)
        return CanvasTextMetrics(fontAscent: bounds.ascent, fontDescent: bounds.descent,
            actualAscent: hasInk ? floor(max(0, image.maxY) * 64) / 64 : 0,
            actualDescent: hasInk ? floor(max(0, -image.minY) * 64) / 64 : 0,
            actualLeft: hasInk ? CGFloat(Float(max(0, -image.minX))) : 0,
            actualRight: CGFloat(Float(hasInk ? max(advance, image.maxX) : advance)), advance: advance)
    }

    /// Frozen slanted glyphRects: individual scalar DOM ranges anchored to
    /// the font baseline, refined using that scalar's canvas glyph ink. Guard
    /// is applied before the final width transform, never to shaped run glyphs.
    static func slantedGlyphRects(layout: Layout, style: Style, guardPixels: CGFloat) -> [CGRect] {
        guard guardPixels.isFinite, guardPixels >= 0 else { return [] }
        let scalars = layout.shapedText.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard scalars.count == layout.rangeBounds.count else { return [] }
        if style.vertical { return layout.rangeBounds }
        let scale = layout.paintScaleX
        return zip(scalars, layout.rangeBounds).map { scalar, range in
            guard let metrics = canvasTextMetrics(text: String(scalar), style: style),
                  metrics.actualLeft + metrics.actualRight > 0 else { return range }
            let baseline = range.minY + (range.height - metrics.fontAscent - metrics.fontDescent) / 2 + metrics.fontAscent
            let left = (range.minX / scale - metrics.actualLeft - guardPixels) * scale
            let right = (range.minX / scale + metrics.actualRight + guardPixels) * scale
            return CGRect(x: left, y: baseline - metrics.actualAscent - guardPixels,
                          width: right - left, height: metrics.actualAscent + metrics.actualDescent + guardPixels * 2)
        }
    }

    static func slantedWordBroken(layout: Layout, originalText: String) -> Bool {
        let flow = wordFlow(layout: layout, originalText: originalText)
        let count = layout.shapedText.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        return flow.wordSplits > 0 || flow.displayedLines >= 3 && count >= 8 &&
            CGFloat(count) / CGFloat(flow.displayedLines) < 2.5
    }

    /// A fresh block text node with collapsed ASCII whitespace. Hard LF is
    /// preserved only by pre-line; the original note and ownership are retained.
    private static func layoutCollapsedKeepAllFlow(text: String, in available: CGSize,
                                                   style: Style) -> Layout? {
        let preserveBreaks = style.horizontalWhitespace == .preLine
        let normalized = NativePreLineTextFlow.normalize(text, preservesLineBreaks: preserveBreaks)
        var paintedStyle = style
        paintedStyle.horizontalWhitespace = .preWrap
        paintedStyle.horizontalWrapping = .normal
        paintedStyle.keepsWholeWords = false
        paintedStyle.optimizesKoreanWrapping = false
        paintedStyle.balancesHorizontalLines = false
        paintedStyle.explicitLineFlow = true
        paintedStyle.paintsVisibleFormFeeds = true
        paintedStyle.intrinsicText = normalized.text
        let width = available.width / style.horizontalScale
        guard let rows = NativePreLineTextFlow.rows(text, width: width,
            overflowAnywhere: style.horizontalWrapping == .keepAllWithEmergency,
            preservesLineBreaks: preserveBreaks, balances: style.balancesHorizontalLines,
            measure: { value in
                CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                    attributedString(text: value, style: paintedStyle)), nil, nil, nil))
            }) else { return nil }
        var displayed = rows.map(\.text).joined(separator: "\n")
        var ownership: [NSRange] = []
        let source = Array(text.utf16)
        var sourceCursor = 0
        func appendBreak(before limit: Int) {
            let end = max(sourceCursor, min(source.count, limit))
            if preserveBreaks, let index = (sourceCursor..<end).first(where: { source[$0] == 10 }) {
                ownership.append(NSRange(location: index, length: 1))
                sourceCursor = index + 1
            } else {
                ownership.append(NSRange(location: sourceCursor, length: 0))
            }
        }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let next = rows[index...].compactMap { $0.sourceUTF16.first?.location }.first ?? source.count
                appendBreak(before: next)
            }
            ownership.append(contentsOf: row.sourceUTF16)
            if let last = row.sourceUTF16.last { sourceCursor = NSMaxRange(last) }
        }
        // CoreText does not create an additional line after the last LF. Add
        // a terminator only when a source-owned empty paragraph must be drawn.
        if rows.last?.text.isEmpty == true {
            displayed.append("\n")
            appendBreak(before: source.count)
        }
        let shaped = layout(text: displayed, in: available, style: paintedStyle)
        return Layout(size: shaped.size, inkBounds: shaped.inkBounds,
            visibleUTF16Range: NSRange(location: 0, length: text.utf16.count), lineCount: shaped.lineCount,
            fits: shaped.fits, glyphBounds: shaped.glyphBounds, rangeBounds: shaped.rangeBounds,
            lineRanges: shaped.lineRanges, shapedText: shaped.shapedText, frame: shaped.frame,
            frameSize: shaped.frameSize, offset: shaped.offset, attributed: shaped.attributed,
            frameAttributes: shaped.frameAttributes, paintScaleX: shaped.paintScaleX,
            lineOffsets: shaped.lineOffsets, committedRowAlignmentWidths: shaped.committedRowAlignmentWidths,
            outlineGlow: shaped.outlineGlow,
            outlineGlowColor: shaped.outlineGlowColor, sourceUTF16Ownership: ownership,
            sourceOwnershipNormalization: style.horizontalWhitespace == .normal ? .certifiedASCIISpaceCollapse : .exact)
    }

    /// The normal/collapsed mode is explicit producer provenance. Initial
    /// pre-wrap captions and fixed span rows never enter this adapter.
    private static func layoutNormalFlow(text: String, in available: CGSize, style: Style) -> Layout? {
        let source = text as NSString, width = available.width / style.horizontalScale
        var paintedStyle = style
        paintedStyle.horizontalWhitespace = .preWrap
        paintedStyle.horizontalWrapping = .normal
        paintedStyle.keepsWholeWords = false
        paintedStyle.optimizesKoreanWrapping = false
        paintedStyle.balancesHorizontalLines = false
        paintedStyle.explicitLineFlow = true
        paintedStyle.intrinsicText = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        func measure(_ range: NSRange) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                attributedString(text: source.substring(with: range), style: paintedStyle)), nil, nil, nil))
        }
        guard let flow = NativeNormalTextFlow.layout(text: text, maximumWidth: width,
            balances: style.balancesHorizontalLines, width: measure, emergencyBreak: { range, room in
                var end = range.location, chosen = 0
                while end < NSMaxRange(range) {
                    end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: end))
                    if measure(NSRange(location: range.location, length: end - range.location)) > room { break }
                    chosen = end - range.location
                }
                return chosen
            }) else { return nil }
        let shaped = layout(text: flow.displayRows.joined(separator: "\n"), in: available, style: paintedStyle)
        let carried = SourceUTF16Transport.ownership(text: text, ranges: flow.sourceRanges, mode: .collapseSpaces)
        let ownership = carried.flatMap {
            $0.displayed.utf16.elementsEqual(shaped.shapedText.utf16) ? $0.units : nil
        }
        return Layout(size: shaped.size, inkBounds: shaped.inkBounds,
            visibleUTF16Range: NSRange(location: 0, length: text.utf16.count), lineCount: shaped.lineCount,
            fits: shaped.fits, glyphBounds: shaped.glyphBounds, rangeBounds: shaped.rangeBounds,
            lineRanges: shaped.lineRanges, shapedText: shaped.shapedText, frame: shaped.frame,
            frameSize: shaped.frameSize, offset: shaped.offset, attributed: shaped.attributed,
            frameAttributes: shaped.frameAttributes, paintScaleX: shaped.paintScaleX,
            lineOffsets: shaped.lineOffsets, committedRowAlignmentWidths: shaped.committedRowAlignmentWidths,
            outlineGlow: shaped.outlineGlow, outlineGlowColor: shaped.outlineGlowColor,
            sourceUTF16Ownership: ownership, sourceOwnershipNormalization: .certifiedASCIISpaceCollapse)
    }

    private static func layoutKeepAllFlow(text: String, in available: CGSize, style: Style,
                                         overflowAnywhere: Bool) -> Layout? {
        // Preserved LF ends a paragraph; it does not turn keep-all into
        // Core Text's ordinary character wrapping within either paragraph.
        // Other authored controls retain their existing shaping path.
        guard !text.contains(where: { $0.isNewline && $0 != "\n" }) else { return nil }
        var width = available.width / style.horizontalScale
        let source = text as NSString
        guard source.length <= 8192 else { return nil }
        let analysis = NativeKeepAllBreakOpportunities.analyze(text: text)
        guard analysis.paragraphs.count <= 512 else { return nil }
        var paintedStyle = style
        paintedStyle.intrinsicText = text
        paintedStyle.horizontalWrapping = .normal
        paintedStyle.horizontalWhitespace = .preWrap
        paintedStyle.keepsWholeWords = false
        paintedStyle.optimizesKoreanWrapping = false
        paintedStyle.balancesHorizontalLines = false
        paintedStyle.explicitLineFlow = true
        // Only this adapter proves that newlines are synthetic soft breaks.
        // Normal/strict columns and authored whitespace are independent modes.
        paintedStyle.usesKeepAllInlineItemWidths = style.horizontalWhitespace == .preWrap &&
            !text.hasPrefix(" ") && !text.hasSuffix(" ") && !text.contains("  ") &&
            text.utf16.count <= 2048 && !text.unicodeScalars.contains {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ||
                (CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 32)
            }

        // Intrinsic sizing, greedy flow and balance revisit the same ranges.
        // Cache only this immutable shaping context, with bounded call lifetime.
        var measuredWidths: [NSRange: CGFloat] = [:]
        func measure(_ range: NSRange) -> CGFloat {
            if let cached = measuredWidths[range] { return cached }
            let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                attributedString(text: source.substring(with: range), style: paintedStyle)), nil, nil, nil))
            if measuredWidths.count < 512 { measuredWidths[range] = width }
            return width
        }
        if !overflowAnywhere {
            let minimum = analysis.items
                .filter { $0.kind == .text }.map { measure($0.range) }.max() ?? 0
            let intrinsic = CGFloat((Float(minimum) * 64).rounded(.up)) / 64
            width = max(width, intrinsic)
            paintedStyle.intrinsicMinimumContentWidth = intrinsic
        }
        var ranges: [NSRange] = [], paragraphEnds: [Bool] = []
        for paragraph in analysis.paragraphs {
            let paragraphRange = paragraph.range
            if paragraphRange.length == 0 {
                ranges.append(paragraphRange); paragraphEnds.append(true)
                continue
            }
            let paragraphText = source.substring(with: paragraphRange)
            func originalRange(_ range: NSRange) -> NSRange {
                NSRange(location: paragraphRange.location + range.location, length: range.length)
            }
            guard let auto = NativeKeepAllAutoLines.greedy(text: paragraphText, maximumWidth: width,
                overflowAnywhere: overflowAnywhere, width: { measure(originalRange($0)) }, emergencyBreak: { range, room in
                    let original = originalRange(range)
                    var end = original.location, chosen = 0
                    while end < NSMaxRange(original) {
                        end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: end))
                        if measure(NSRange(location: original.location, length: end - original.location)) > room { break }
                        chosen = end - original.location
                    }
                    return chosen
                }) else { return nil }
            let balances = style.balancesHorizontalLines &&
                (analysis.paragraphs.count == 1 || style.balancesExplicitParagraphs)
            let balanced = balances ? NativeKeepAllTextBalance.solve(text: paragraphText,
                originalAutoRanges: auto, maximumWidth: width, itemWidth: { Float(measure(originalRange($0))) }) : nil
            let paragraphRows = (balanced?.flowRanges ?? auto).map(originalRange)
            ranges.append(contentsOf: paragraphRows)
            paragraphEnds.append(contentsOf: paragraphRows.map { NSMaxRange($0) == NSMaxRange(paragraphRange) })
            guard ranges.count <= 512 else { return nil }
        }
        // Core Text ranges below refer to text with newly inserted soft LF.
        // Keep authored paragraph ends in their original coordinate space.
        paintedStyle.keepAllParagraphEndRows = paragraphEnds
        let carried = SourceUTF16Transport.ownership(text: text, ranges: ranges,
            mode: style.horizontalWhitespace == .normal ? .trimSpaces : .preserve,
            paragraphEnds: paragraphEnds)
        let rows = ranges.map { range -> String in
            let row = source.substring(with: range)
            return style.horizontalWhitespace == .normal
                ? row.trimmingCharacters(in: CharacterSet(charactersIn: " ")) : row
        }
        let shaped = layout(text: rows.joined(separator: "\n"), in: available, style: paintedStyle)
        return Layout(size: shaped.size, inkBounds: shaped.inkBounds,
            visibleUTF16Range: NSRange(location: 0, length: text.utf16.count), lineCount: shaped.lineCount,
            fits: shaped.fits, glyphBounds: shaped.glyphBounds, rangeBounds: shaped.rangeBounds,
            lineRanges: shaped.lineRanges, shapedText: shaped.shapedText, frame: shaped.frame,
            frameSize: shaped.frameSize, offset: shaped.offset, attributed: shaped.attributed,
            frameAttributes: shaped.frameAttributes, paintScaleX: shaped.paintScaleX,
            lineOffsets: shaped.lineOffsets, committedRowAlignmentWidths: shaped.committedRowAlignmentWidths,
            outlineGlow: shaped.outlineGlow, outlineGlowColor: shaped.outlineGlowColor,
            sourceUTF16Ownership: carried.flatMap {
                $0.displayed.utf16.elementsEqual(shaped.shapedText.utf16) ? $0.units : nil
            }, sourceOwnershipNormalization: style.horizontalWhitespace == .normal ? .certifiedASCIISpaceCollapse : .exact)
    }

    /// CSS white-space:normal / word-break:keep-all / overflow-wrap:normal.
    /// Long words remain intact and report overflow instead of being split by
    /// Core Text's emergency character wrapping. Only actual word gaps wrap.
    private static func layoutKeepingWholeWords(text: String, in available: CGSize, style: Style) -> Layout {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return .empty }
        var paintedStyle = style
        paintedStyle.intrinsicText = text
        // A rejected keep-all adapter (for example soft hyphens or its input
        // budget) must not recursively select this same fallback again.
        paintedStyle.wholeWordFallbackResolved = true
        paintedStyle.keepsWholeWords = false
        paintedStyle.optimizesKoreanWrapping = false
        paintedStyle.balancesHorizontalLines = false
        let physicalWidth = available.width / style.horizontalScale
        func width(_ text: String) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedString(text: text, style: paintedStyle)), nil, nil, nil))
        }
        let longest = words.map(width).max() ?? 0
        let frameWidth = max(physicalWidth, longest + 0.0001)
        var rows: [String] = [], row = ""
        for word in words {
            let proposed = row.isEmpty ? word : row + " " + word
            if !row.isEmpty && width(proposed) > physicalWidth + 0.0001 { rows.append(row); row = word }
            else { row = proposed }
        }
        if !row.isEmpty { rows.append(row) }
        var balancingStyle = paintedStyle
        balancingStyle.keepsWholeWords = true
        if style.balancesHorizontalLines, longest <= physicalWidth + 0.0001,
           let balanced = balancedHorizontalLines(text: words.joined(separator: " "),
               available: CGSize(width: physicalWidth, height: available.height), style: balancingStyle) {
            rows = balanced
        }
        let shaped = layout(text: rows.joined(separator: "\n"),
            in: CGSize(width: frameWidth * style.horizontalScale, height: available.height), style: paintedStyle)
        let dx = (physicalWidth - frameWidth) / 2
        let worldDx = dx * style.horizontalScale
        return Layout(size: shaped.size, inkBounds: shaped.inkBounds.offsetBy(dx: worldDx, dy: 0),
            visibleUTF16Range: NSRange(location: 0, length: text.utf16.count), lineCount: shaped.lineCount,
            fits: shaped.fits && longest * style.horizontalScale <= available.width + 0.5,
            glyphBounds: shaped.glyphBounds.map { $0.offsetBy(dx: worldDx, dy: 0) },
            rangeBounds: shaped.rangeBounds.map { $0.offsetBy(dx: worldDx, dy: 0) }, lineRanges: shaped.lineRanges,
            shapedText: shaped.shapedText, frame: shaped.frame, frameSize: shaped.frameSize,
            offset: CGPoint(x: shaped.offset.x + dx, y: shaped.offset.y), attributed: shaped.attributed,
            frameAttributes: shaped.frameAttributes, paintScaleX: shaped.paintScaleX, lineOffsets: shaped.lineOffsets,
            committedRowAlignmentWidths: shaped.committedRowAlignmentWidths,
            outlineGlow: shaped.outlineGlow, outlineGlowColor: shaped.outlineGlowColor)
    }

    /// Move the committed lines without reflowing or changing their face.
    /// Offsets use physical top-left points, after any horizontal scale.
    static func applyingLineOffsets(layout: Layout, offsets: [CGPoint]) -> Layout {
        guard layout.frameAttributes == nil, !offsets.isEmpty, offsets.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let frame = layout.frame else { return layout }
        var result = layout
        let applied = (0..<layout.lineCount).map { index -> CGPoint in
            let old = index < layout.lineOffsets.count ? layout.lineOffsets[index] : .zero
            let delta = index < offsets.count ? offsets[index] : .zero
            return CGPoint(x: old.x + delta.x, y: old.y + delta.y)
        }
        let metrics = captionLineMetrics(layout: layout)
        func shifted(_ rect: CGRect) -> CGRect {
            let index = metrics.indices.min { abs(metrics[$0].rect.midY - rect.midY) < abs(metrics[$1].rect.midY - rect.midY) }
            guard let index, index < offsets.count else { return rect }
            return rect.offsetBy(dx: offsets[index].x, dy: offsets[index].y)
        }
        let rawLines = CTFrameGetLines(frame)
        var glyphLines: [Int] = []
        for lineIndex in 0..<CFArrayGetCount(rawLines) {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(rawLines, lineIndex), to: CTLine.self)
            let runs = CTLineGetGlyphRuns(line)
            for runIndex in 0..<CFArrayGetCount(runs) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
                for glyph in 0..<CTRunGetGlyphCount(run) where !CTRunGetImageBounds(run, nil, CFRange(location: glyph, length: 1)).isEmpty {
                    glyphLines.append(lineIndex)
                }
            }
        }
        let newGlyphs = layout.glyphBounds.enumerated().map { index, rect -> CGRect in
            guard index < glyphLines.count, glyphLines[index] < offsets.count else { return rect }
            let delta = offsets[glyphLines[index]]
            return rect.offsetBy(dx: delta.x, dy: delta.y)
        }
        let newRanges = layout.rangeBounds.map(shifted)
        let newInk = newGlyphs.reduce(CGRect.null) { $0.union($1) }
        result = Layout(size: CGSize(width: max(layout.size.width, newInk.width), height: max(layout.size.height, newInk.height)),
            inkBounds: newInk.isNull ? layout.inkBounds : newInk, visibleUTF16Range: layout.visibleUTF16Range,
            lineCount: layout.lineCount, fits: layout.fits, glyphBounds: newGlyphs, rangeBounds: newRanges,
            lineRanges: layout.lineRanges, shapedText: layout.shapedText, frame: frame, frameSize: layout.frameSize,
            offset: layout.offset, attributed: layout.attributed, frameAttributes: layout.frameAttributes,
            paintScaleX: layout.paintScaleX, lineOffsets: applied,
            committedRowAlignmentWidths: layout.committedRowAlignmentWidths, blockRowIntrinsicWidths: layout.blockRowIntrinsicWidths,
            outlineGlow: layout.outlineGlow, outlineGlowColor: layout.outlineGlowColor,
            sourceUTF16Ownership: layout.sourceUTF16Ownership,
            sourceOwnershipNormalization: layout.sourceOwnershipNormalization)
        return result
    }

    static func draw(
        layout: Layout, in context: CGContext, at origin: CGPoint = .zero,
        additionalFillStrokeWidth: CGFloat = 0,
        outlinePaintOrder: OutlinePaintOrder = .strokeThenFill,
        pixelSnapScale: CGFloat? = nil
    ) {
        guard var frame = layout.frame else { return }
        if drawPreparedHorizontal(layout: layout, in: context, at: origin,
            additionalFillStrokeWidth: additionalFillStrokeWidth,
            outlinePaintOrder: outlinePaintOrder, pixelSnapScale: pixelSnapScale) { return }
        var paintedAttributes = layout.attributed
        if additionalFillStrokeWidth.isFinite, additionalFillStrokeWidth > 0, let attributed = layout.attributed {
            let stroked = NSMutableAttributedString(attributedString: attributed)
            let range = NSRange(location: 0, length: attributed.length)
            attributed.enumerateAttributes(in: range) { attributes, range, _ in
                let font = attributes[NSAttributedString.Key(kCTFontAttributeName as String)] as! CTFont
                let fill = attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] ?? CGColor(gray: 0, alpha: 1)
                stroked.addAttributes([
                    NSAttributedString.Key(kCTStrokeColorAttributeName as String): fill,
                    NSAttributedString.Key(kCTStrokeWidthAttributeName as String):
                        -additionalFillStrokeWidth * 100 / CTFontGetSize(font),
                ], range: range)
            }
            paintedAttributes = stroked
            frame = CTFramesetterCreateFrame(
                CTFramesetterCreateWithAttributedString(stroked), CFRange(location: 0, length: 0),
                CTFrameGetPath(frame), layout.frameAttributes
            )
        }
        var frames = [frame]
        if let painted = paintedAttributes {
            let full = NSRange(location: 0, length: painted.length)
            var hasStroke = false
            painted.enumerateAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), in: full) { value, _, _ in
                if let width = value as? NSNumber, width.doubleValue != 0 { hasStroke = true }
            }
            if hasStroke {
                // Preserve the CSS producer's order: normal paints fill then
                // stroke, while explicit stroke fill leaves the full interior.
                // Both passes reuse identical shaping and glyph coordinates.
                let stroke = NSMutableAttributedString(attributedString: painted)
                let fill = NSMutableAttributedString(attributedString: painted)
                painted.enumerateAttributes(in: full) { attributes, range, _ in
                    let key = NSAttributedString.Key(kCTStrokeWidthAttributeName as String)
                    if let width = attributes[key] as? NSNumber, width.doubleValue != 0 {
                        stroke.addAttribute(key, value: abs(width.doubleValue), range: range)
                    } else {
                        stroke.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                            value: CGColor(gray: 0, alpha: 0), range: range)
                    }
                }
                fill.removeAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), range: full)
                fill.removeAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), range: full)
                let passes = outlinePaintOrder == .strokeThenFill ? [stroke, fill] : [fill, stroke]
                frames = passes.map {
                    CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString($0), CFRange(location: 0, length: 0),
                        CTFrameGetPath(frame), layout.frameAttributes)
                }
            }
        }
        context.saveGState()
        context.textMatrix = .identity
        let glow = layout.outlineGlow.isFinite && layout.outlineGlow > 0 && layout.outlineGlowColor != nil
        if glow {
            context.setShadow(offset: .zero, blur: layout.outlineGlow, color: layout.outlineGlowColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        for (paintPass, frame) in frames.enumerated() {
            if layout.frameAttributes == nil {
                let lines = CTFrameGetLines(frame), count = CFArrayGetCount(lines)
                var origins = [CGPoint](repeating: .zero, count: count)
                CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                for index in 0..<count {
                    let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
                    let movement = index < layout.lineOffsets.count ? layout.lineOffsets[index] : .zero
                    let base = origin.y + layout.offset.y + layout.frameSize.height - origins[index].y + movement.y
                    let x = origin.x + (layout.offset.x + origins[index].x) * layout.paintScaleX + movement.x
                    let anchor = NativeTextPaintGeometry.paintOrigin(CGPoint(x: x, y: base), deviceScale: pixelSnapScale) ?? CGPoint(x: x, y: base)
                    if frames.count == 2, paintPass == (outlinePaintOrder == .strokeThenFill ? 0 : 1),
                       NativeCTFontStrokePainter.draw(line: line, context: context, anchor: anchor,
                                                      horizontalScale: layout.paintScaleX) { continue }
                    if let prepared = NativeCTFontHorizontalFillPainter.prepare(line: line, horizontalScale: layout.paintScaleX),
                       NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: anchor) { continue }
                    // A FloatPoint is translated as the absolute line anchor.
                    // Compensating textPosition under a fractional parent
                    // translation serializes a different matrix in PDF output.
                    context.saveGState()
                    context.translateBy(x: anchor.x, y: anchor.y)
                    context.scaleBy(x: layout.paintScaleX, y: -1)
                    context.textPosition = .zero
                    CTLineDraw(line, context)
                    context.restoreGState()
                }
            } else {
                let lines = CTFrameGetLines(frame) as! [CTLine]
                var origins = [CGPoint](repeating: .zero, count: lines.count)
                CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                let prepared = layout.verticalPaintOffsets.count == lines.count && frames.count == 1
                    ? lines.compactMap { NativeCTFontVerticalPainter.prepare(line: $0) } : []
                let anchors = origins.enumerated().map { index, point -> CGPoint in
                    let movement = index < layout.verticalPaintOffsets.count ? layout.verticalPaintOffsets[index] : .zero
                    return CGPoint(x: origin.x + layout.offset.x + point.x + movement.x,
                        y: origin.y + layout.offset.y + layout.frameSize.height - point.y + movement.y)
                }
                if !prepared.isEmpty, prepared.count == lines.count,
                   anchors.allSatisfy({ Float($0.x).isFinite && Float($0.y).isFinite }) {
                    for (line, anchor) in zip(prepared, anchors) {
                        NativeCTFontVerticalPainter.draw(prepared: line, context: context, anchor: anchor)
                    }
                } else {
                    context.saveGState()
                    context.translateBy(x: origin.x, y: origin.y)
                    context.scaleBy(x: layout.paintScaleX, y: 1)
                    context.translateBy(x: layout.offset.x, y: layout.offset.y + layout.frameSize.height)
                    context.scaleBy(x: 1, y: -1)
                    CTFrameDraw(frame, context)
                    context.restoreGState()
                }
            }
        }
        if glow { context.endTransparencyLayer() }
        context.restoreGState()
    }

    /// Outline color/width and paint order do not change glyph shaping. Reuse the
    /// measured frame for supported horizontal runs instead of constructing two
    /// more frames (three for additional fill stroke) on every paint. All lines
    /// are preflighted before painting so unsupported fonts retain the fallback.
    @discardableResult
    static func drawPreparedHorizontal(
        layout: Layout, in context: CGContext, at origin: CGPoint = .zero,
        additionalFillStrokeWidth: CGFloat = 0,
        outlinePaintOrder: OutlinePaintOrder = .strokeThenFill,
        pixelSnapScale: CGFloat? = nil
    ) -> Bool {
        guard layout.frameAttributes == nil, layout.paintScaleX == 1,
              let frame = layout.frame, let attributed = layout.attributed else { return false }
        var hasStroke = additionalFillStrokeWidth.isFinite && additionalFillStrokeWidth > 0
        if !hasStroke {
            attributed.enumerateAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String),
                in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                if let width = value as? NSNumber, width.doubleValue != 0 { hasStroke = true }
            }
        }
        guard hasStroke else { return false }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var prepared: [(fill: NativeCTFontHorizontalFillPainter.PreparedLine,
                        stroke: NativeCTFontStrokePainter.PreparedLine, anchor: CGPoint)] = []
        prepared.reserveCapacity(lines.count)
        var glyphCount = 0
        for (index, line) in lines.enumerated() {
            let count = CTLineGetGlyphCount(line)
            guard count >= 0, count <= 65_536 - glyphCount else { return false }
            glyphCount += count
            let movement = index < layout.lineOffsets.count ? layout.lineOffsets[index] : .zero
            let base = origin.y + layout.offset.y + layout.frameSize.height - origins[index].y + movement.y
            let x = origin.x + (layout.offset.x + origins[index].x) * layout.paintScaleX + movement.x
            let point = CGPoint(x: x, y: base)
            let anchor = NativeTextPaintGeometry.paintOrigin(point, deviceScale: pixelSnapScale) ?? point
            guard Float(anchor.x).isFinite, Float(anchor.y).isFinite,
                  let fill = NativeCTFontHorizontalFillPainter.prepare(line: line, ignoringStroke: true),
                  let stroke = NativeCTFontStrokePainter.prepare(line: line, includesFill: true,
                    additionalFillStrokeWidth: additionalFillStrokeWidth) else { return false }
            prepared.append((fill, stroke, anchor))
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        let glow = layout.outlineGlow.isFinite && layout.outlineGlow > 0 && layout.outlineGlowColor != nil
        if glow {
            context.setShadow(offset: .zero, blur: layout.outlineGlow, color: layout.outlineGlowColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        for strokePass in outlinePaintOrder == .strokeThenFill ? [true, false] : [false, true] {
            for line in prepared {
                if strokePass {
                    NativeCTFontStrokePainter.draw(prepared: line.stroke, context: context, anchor: line.anchor)
                } else {
                    NativeCTFontHorizontalFillPainter.draw(prepared: line.fill, context: context, anchor: line.anchor)
                }
            }
        }
        if glow { context.endTransparencyLayer() }
        return true
    }

    /// The pinned iOS WebKit metrics and fixed line cell govern glyph paint.
    /// DOM selection boxes keep their existing independent geometry.
    private static func verticalPaintMovements(frame: CTFrame, frameSize: CGSize, offset: CGPoint,
        available: CGSize, attributed: NSAttributedString, text: String, style: Style) -> [CGPoint] {
        #if os(iOS)
        guard style.vertical, style.horizontalAlignment == .center,
              style.outline == nil || style.outlineWidth == 0, attributed.length > 0,
              let object = attributed.attribute(NSAttributedString.Key(kCTFontAttributeName as String), at: 0, effectiveRange: nil),
              CFGetTypeID(object as CFTypeRef) == CTFontGetTypeID() else { return [] }
        let primary = object as! CTFont
        // OpenType MATH uses a separate source metric override.
        guard CTFontCopyTable(primary, 0x4D415448, []) == nil,
              let metrics = NativeVerticalGlyphOrigins.iosMetrics(ascent: CTFontGetAscent(primary),
                descent: CTFontGetDescent(primary), leading: CTFontGetLeading(primary),
                familyName: CTFontCopyFamilyName(primary) as String) else { return [] }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty, lines.count <= 65_536,
              lines.allSatisfy({ NativeCTFontVerticalPainter.supports(line: $0) }) else { return [] }
        let source = text as NSString
        // Preserved trailing spaces need the separate hanging-space contract.
        for line in lines {
            let range = CTLineGetStringRange(line)
            var end = min(source.length, range.location + range.length)
            while end > range.location && [10, 13].contains(source.character(at: end - 1)) { end -= 1 }
            if end > range.location && [9, 32].contains(source.character(at: end - 1)) { return [] }
        }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let maximum = text.components(separatedBy: .newlines).map {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedString(text: $0, style: style)), nil, nil, nil))
        }.max() ?? 0
        let minimum = text.filter { !$0.isWhitespace }.map {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedString(text: String($0), style: style)), nil, nil, nil))
        }.max() ?? 0
        guard let inline = NativeTextPaintGeometry.anonymousFlexBox(contentWidth: available.height,
            maximumContentWidth: maximum, minimumContentWidth: minimum) else { return [] }
        let pitch = Float(floor(max(style.fontSize, style.lineHeight)))
        var result: [CGPoint] = []
        for (line, origin) in zip(lines, origins) {
            let nativeX = Float(origin.x + offset.x)
            let nativeY = Float(frameSize.height - origin.y + offset.y)
            guard let cross = NativeVerticalGlyphOrigins.ideographicCellBaseline(cellRight: nativeX + pitch / 2,
                    pitch: pitch, metrics: metrics.primary) else { return [] }
            let range = CTLineGetStringRange(line)
            var end = min(source.length, range.location + range.length)
            let originalEnd = end
            while end > range.location && [10, 13].contains(source.character(at: end - 1)) { end -= 1 }
            let advance = end == originalEnd ? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                : end > range.location ? CTLineGetOffsetForStringIndex(line, end, nil) : 0
            guard let inlineShift = NativeVerticalGlyphOrigins.centeredInlineShift(flexOrigin: Float(inline.origin),
                lineLogicalWidth: Float(inline.width), cssContentRight: Float(advance), hangingTrailingWidth: 0,
                conditionalHanging: false, nativeLineOrigin: nativeY) else { return [] }
            result.append(CGPoint(x: CGFloat(cross - nativeX), y: CGFloat(inlineShift)))
        }
        return result
        #else
        return []
        #endif
    }

    /// CSS fixed line-height already includes natural font leading. Core Text
    /// otherwise adds that leading after its min/max line-height clamp.
    private static func fixedPitchParagraph(_ paragraph: NSParagraphStyle, pitch: CGFloat) -> CTParagraphStyle {
        var pitch = pitch, spacing: CGFloat = 0
        var stops=paragraph.tabStops.map { CTTextTabCreate(.left,$0.location,nil) } as CFArray
        var interval=paragraph.defaultTabInterval
        var alignment: CTTextAlignment
        switch paragraph.alignment {
        case .left: alignment = .left
        case .right: alignment = .right
        case .center: alignment = .center
        case .justified: alignment = .justified
        case .natural: alignment = .natural
        @unknown default: alignment = .natural
        }
        var lineBreak = CTLineBreakMode(rawValue: UInt8(paragraph.lineBreakMode.rawValue)) ?? .byWordWrapping
        return withUnsafePointer(to: &stops) { tabs in
            withUnsafePointer(to: &interval) { tabInterval in
        return withUnsafePointer(to: &pitch) { height in
            withUnsafePointer(to: &spacing) { gap in
                withUnsafePointer(to: &alignment) { align in
                    withUnsafePointer(to: &lineBreak) { mode in
                        let settings = [
                            CTParagraphStyleSetting(spec: .tabStops,valueSize:MemoryLayout<CFArray>.size,value:tabs),
                            CTParagraphStyleSetting(spec:.defaultTabInterval,valueSize:MemoryLayout<CGFloat>.size,value:tabInterval),
                            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: align),
                            CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: mode),
                            CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: height),
                            CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: height),
                            CTParagraphStyleSetting(spec: .maximumLineSpacing, valueSize: MemoryLayout<CGFloat>.size, value: gap)
                        ]
                        return CTParagraphStyleCreate(settings, settings.count)
                    }
                }
            }
        }
            }
        }
    }

    static func attributedString(text: String, style: Style) -> NSAttributedString {
        let selectedFont = font(text: text, style: style)
        let paragraph = NSMutableParagraphStyle()
        switch style.horizontalAlignment {
        case .center: paragraph.alignment = .center
        case .left: paragraph.alignment = .left
        case .right: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = style.vertical ? (style.fontScript == "japanese" ? .byWordWrapping : .byCharWrapping) : style.preservesBlockRows || style.explicitLineFlow ? .byClipping : .byWordWrapping
        // The strict candidate removes Korean keep-all preference and uses
        // Unicode standard breaking; callers retain the frozen profile veto.
        // Core Text exposes no complete CSS line-break:strict equivalent.
        paragraph.lineBreakStrategy = style.strictLineBreak ? [.standard] : [.standard, .hangulWordPriority]
        // WebKit's committed line baselines use the integral line pitch, while
        // growth policy and CSS line-height calculations retain the float.
        let paintedPitch = floor(max(style.fontSize, style.lineHeight))
        paragraph.minimumLineHeight = paintedPitch
        paragraph.maximumLineHeight = paintedPitch
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): selectedFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.foreground,
            .paragraphStyle: paragraph,
            .kern: style.tracking,
        ]
        if style.vertical {
            attributes[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true
        }
        if style.vertical || CTFontGetLeading(selectedFont) > 0 {
            attributes.removeValue(forKey: .paragraphStyle)
            attributes[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = fixedPitchParagraph(paragraph, pitch: paintedPitch)
        }
        if let outline = style.outline, style.outlineWidth > 0 {
            // Core Text uses a percentage of point size. Keep combined stroke
            // attributes for measurement; draw splits stroke and fill passes.
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = outline
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -style.outlineWidth * 100 / CTFontGetSize(selectedFont)
        }
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        // CSS letter-spacing remains after the terminal glyph in the painted
        // line box. Canvas/DP candidate widths separately use only code-point
        // gaps; removing terminal kern here changes centring and final pixels.
        if style.usesPreformattedBlockRows && !style.vertical && text.contains("\t") {
            var characters:[UniChar] = [32,48],glyphs=[CGGlyph](repeating:0,count:2),advances=[CGSize](repeating:.zero,count:2)
            CTFontGetGlyphsForCharacters(selectedFont,&characters,&glyphs,2)
            CTFontGetAdvancesForGlyphs(selectedFont,.horizontal,&glyphs,&advances,2)
            if let plan=NativePreformattedTabs.plan(text:text,spaceAdvance:advances[0].width,zeroAdvance:advances[1].width,
                letterSpacing:style.tracking,measure:{ fragment in
                    CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string:fragment,attributes:attributes)),nil,nil,nil))
                }) {
                for row in plan.rows where !row.stops.isEmpty {
                    let tabs=paragraph.mutableCopy() as! NSMutableParagraphStyle
                    tabs.tabStops=row.stops.map { NSTextTab(textAlignment:.left,location:$0,options:[:]) }
                    tabs.defaultTabInterval=0
                    result.removeAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String),range:row.range)
                    if CTFontGetLeading(selectedFont)>0 {
                        result.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String),value:fixedPitchParagraph(tabs,pitch:paintedPitch),range:row.range)
                    } else {result.addAttribute(.paragraphStyle,value:tabs,range:row.range)}
                }
            }
        }
        if style.vertical { NativeVerticalLetterSpacing.apply(to: result) }
        if !style.vertical && (style.horizontalWhitespace == .preLine || style.paintsVisibleFormFeeds) {
            NativeVisibleControlGlyphs.apply(to: result)
        }
        return result
    }

    /// CSS keep-all first establishes greedy line count. Emergency Core Text
    /// flow remains available when an individual word exceeds the whole column.
    private static func preferredWholeWordLines(text: String, width: CGFloat, style: Style) -> [String]? {
        guard !text.contains(where: \.isNewline), text.utf16.count <= 180, width > 0 else { return nil }
        let scalars = Array(text.unicodeScalars)
        var boundaries = [0], offset = 0
        for index in scalars.indices {
            offset += scalars[index].utf16.count
            if CharacterSet.whitespacesAndNewlines.contains(scalars[index]),
               index + 1 == scalars.count || !CharacterSet.whitespacesAndNewlines.contains(scalars[index + 1]) {
                boundaries.append(offset)
            }
        }
        let source = text as NSString
        if boundaries.last != source.length { boundaries.append(source.length) }
        func advance(_ text: String) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedString(text: text, style: style)), nil, nil, nil))
        }
        var rows: [String] = [], row = ""
        for index in 1..<boundaries.count {
            let part = source.substring(with: NSRange(location: boundaries[index - 1], length: boundaries[index] - boundaries[index - 1]))
            let word = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard advance(word) <= width + 0.0001 else { return nil }
            let proposed = row + part
            if !row.isEmpty && advance(proposed.trimmingCharacters(in: .whitespacesAndNewlines)) > width + 0.0001 {
                rows.append(row); row = part
            } else { row = proposed }
        }
        if !row.isEmpty { rows.append(row) }
        return rows.isEmpty ? nil : rows
    }

    /// CSS text-wrap:balance narrows the wrap measure without changing the
    /// number of lines. Measuring the actual Core Text frame (rather than
    /// dividing a string's advance) retains Hangul word priority and fallback
    /// glyph shaping; the final card keeps its original physical width.
    static func balancedHorizontalLines(text: String, available: CGSize, style: Style) -> [String]? {
        if style.balancesExplicitParagraphs && !style.vertical && text.contains(where: \.isNewline) {
            var paragraphStyle = style
            paragraphStyle.balancesExplicitParagraphs = false
            return text.components(separatedBy: .newlines).flatMap { paragraph in
                balancedHorizontalLines(text: paragraph, available: available, style: paragraphStyle)
                    ?? preferredWholeWordLines(text: paragraph, width: available.width, style: paragraphStyle)
                    ?? [paragraph]
            }
        }
        guard !style.vertical, !text.contains(where: \.isNewline), text.utf16.count <= 180,
              available.width > 0, style.fontSize > 0 else { return nil }
        let attributed = attributedString(text: text, style: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let height = max(1, max(style.fontSize, style.lineHeight) * CGFloat(text.utf16.count + 2) * 2)
        func ranges(_ width: CGFloat) -> [NSRange] {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
            let raw = CTFrameGetLines(frame)
            return (0..<CFArrayGetCount(raw)).map { index in
                let line = unsafeBitCast(CFArrayGetValueAtIndex(raw, index), to: CTLine.self)
                let range = CTLineGetStringRange(line)
                return NSRange(location: max(0, range.location), length: max(0, range.length))
            }
        }
        let ordinary = ranges(available.width)
        let preferred = style.strictLineBreak ? nil : preferredWholeWordLines(text: text, width: available.width, style: style)
        let rows = preferred?.count ?? ordinary.count
        guard rows >= 2, rows <= 6, NSMaxRange(ordinary.last!) == attributed.length else { return nil }
        if text.contains(where: \.isWhitespace) {
            let source = text as NSString
            var boundaries = [0], offset = 0
            let scalars = Array(text.unicodeScalars)
            for index in scalars.indices {
                offset += scalars[index].utf16.count
                if CharacterSet.whitespacesAndNewlines.contains(scalars[index]),
                   index + 1 == scalars.count || !CharacterSet.whitespacesAndNewlines.contains(scalars[index + 1]) {
                    boundaries.append(offset)
                }
            }
            if boundaries.last != source.length { boundaries.append(source.length) }
            let count = boundaries.count - 1
            if count >= rows {
                var widths = [[CGFloat]](repeating: [CGFloat](repeating: .infinity, count: count + 1), count: count + 1)
                for start in 0..<count {
                    for end in (start + 1)...count {
                        let part = source.substring(with: NSRange(location: boundaries[start], length: boundaries[end] - boundaries[start]))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        widths[start][end] = measuredWidth(text: part, style: style)
                    }
                }
                var costs = [[CGFloat]](repeating: [CGFloat](repeating: .infinity, count: count + 1), count: rows + 1)
                var next = [[Int]](repeating: [Int](repeating: -1, count: count + 1), count: rows + 1)
                costs[0][count] = 0
                for start in stride(from: count - 1, through: 0, by: -1) {
                    for end in (start + 1)...count where widths[start][end] <= available.width + 0.1 {
                        for row in 1...rows {
                            let score = max(widths[start][end], costs[row - 1][end])
                            let tolerance: CGFloat = style.keepsWholeWords ? 0.0001 : 0
                            if score < costs[row][start] - tolerance ||
                                (style.keepsWholeWords && abs(score - costs[row][start]) <= tolerance && end > next[row][start]) {
                                costs[row][start] = score; next[row][start] = end
                            }
                        }
                    }
                }
                if next[rows][0] >= 0 {
                    var result: [String] = [], start = 0, remaining = rows
                    while start < count, remaining > 0 {
                        let end = next[remaining][start]
                        guard end > start else { return nil }
                        result.append(source.substring(with: NSRange(location: boundaries[start], length: boundaries[end] - boundaries[start])))
                        start = end; remaining -= 1
                    }
                    if start == count { return result }
                }
            }
        }
        var low: CGFloat = 1, high = available.width, best = ordinary
        for _ in 0..<24 {
            let width = (low + high) / 2, measured = ranges(width)
            if measured.count <= rows, let last = measured.last, NSMaxRange(last) == attributed.length {
                high = width; best = measured
            } else { low = width }
        }
        let source = text as NSString
        return best.map { source.substring(with: $0) }
    }

    /// Anonymous flex sizing is distinct from the inline text alignment.
    /// Each line uses a primary-face CSS baseline; fallback
    /// runs affect the painted glyph, never the DOM selection line metrics.
    private static func horizontalPaintMovements(frame: CTFrame, frameSize: CGSize, originalText: String,
        shapedText: String, style: Style, scaleX: CGFloat, blockIntrinsic: [CGFloat?] = [])
        -> (movements: [CGPoint], widths: [CGFloat]?, geometry: ScopedHorizontalPaintGeometry?) {
        guard !style.vertical else { return ([], nil, nil) }
        let lines = CTFrameGetLines(frame), count = CFArrayGetCount(lines)
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let maximum = originalText.components(separatedBy: .newlines).map {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedString(text: $0, style: style)), nil, nil, nil))
        }.max() ?? 0
        let alignment: CGFloat = style.horizontalAlignment == .left ? 0 : style.horizontalAlignment == .right ? 1 : 0.5
        let minimumContent = style.preservesBlockRows ? 0 : minimumHorizontalContentWidth(text: originalText, style: style)
        let flex = NativeTextPaintGeometry.anonymousFlexBox(contentWidth: frameSize.width,
            maximumContentWidth: maximum, minimumContentWidth: minimumContent, justification: alignment)
        let itemWidths = keepAllInlineItemWidths(frame: frame, text: shapedText, style: style)
        let primary = font(text: originalText, style: style)
        let ascent = ceil(CTFontGetAscent(primary)), descent = ceil(CTFontGetDescent(primary))
        let pitch = floor(max(style.fontSize, style.lineHeight))
        var rawAdvances: [CGFloat] = [], rawRanges: [CFRange] = []
        var widths: [CGFloat] = []
        let movements = (0..<count).map { index in
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            let rawWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let range = CTLineGetStringRange(line)
            rawAdvances.append(rawWidth); rawRanges.append(range)
            let source = originalText as NSString
            let end = min(source.length, range.location + range.length)
            let forcedOrFinal: Bool
            if let paragraphEnds = style.keepAllParagraphEndRows, index < paragraphEnds.count {
                forcedOrFinal = paragraphEnds[index]
            } else {
                forcedOrFinal = end == source.length || end > 0 && end <= source.length &&
                    (source.character(at: end - 1) == 10 || source.character(at: end - 1) == 13)
            }
            let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            let establishedWidth = style.preservesBlockRows ? max(0, rawWidth)
                : originalText.contains(where: \.isNewline) && forcedOrFinal
                    ? max(0, min(flex?.width ?? frameSize.width, rawWidth)) : max(0, rawWidth - trailing)
            let width = (index < itemWidths.count ? itemWidths[index] : nil) ?? establishedWidth
            widths.append(width * scaleX)
            let lineFlex = style.preservesBlockRows
                ? blockRowBox(contentWidth: frameSize.width, advance: (index < blockIntrinsic.count ? blockIntrinsic[index] : nil) ?? width, style: style)
                : flex
            let usesInlineUnits = index < itemWidths.count && itemWidths[index] != nil
            let desiredX = (usesInlineUnits ? lineFlex?.inlineCenteredLineOrigin(lineWidth: width)
                : lineFlex?.lineOrigin(lineWidth: width, alignment: alignment)) ?? origins[index].x
            let baseline = floor((pitch - ascent - descent) / 2) + ascent + CGFloat(index) * pitch
            let dy = baseline - (frameSize.height - origins[index].y)
            return CGPoint(x: (desiredX - origins[index].x) * scaleX, y: dy)
        }
        let geometry = !Task.isCancelled
            ? ScopedHorizontalPaintGeometry(frame: frame, size: frameSize, scaleX: scaleX, source: originalText,
                text: shapedText, style: style, origins: origins, advances: rawAdvances, ranges: rawRanges,
                naturalWidth: maximum, minimumContent: minimumContent, ascent: ascent, descent: descent) : nil
        return (movements, widths.allSatisfy { $0.isFinite && $0 >= 0 } ? widths : nil, geometry)
    }

    /// The line-break control character has a Core Text advance but no CSS
    /// vertical inline extent. Preserve spaces and terminal letter spacing.
    static func verticalLineAdvances(layout: Layout) -> [CGFloat] {
        guard let frame = layout.frame else { return [] }
        let text = layout.shapedText as NSString, lines = CTFrameGetLines(frame)
        return (0..<CFArrayGetCount(lines)).map { index in
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            let range = CTLineGetStringRange(line)
            let originalEnd = min(text.length, range.location + range.length)
            var end = originalEnd
            while end > range.location && (text.character(at: end - 1) == 10 || text.character(at: end - 1) == 13) { end -= 1 }
            guard end < originalEnd else { return max(0, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) }
            guard end > range.location else { return 0 }
            let tracking = (layout.attributed?.attribute(NSAttributedString.Key(kCTKernAttributeName as String),
                at: end - 1, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
            // The inner cursor edge bisects the letter spacing before the
            // newline. CSS includes the complete terminal glyph spacing.
            return max(0, CTLineGetOffsetForStringIndex(line, end, nil) + CGFloat(tracking) / 2)
        }
    }

    private static func roundedFontBounds(line: CTLine, stringOffset: Int? = nil) -> (ascent: CGFloat, descent: CGFloat) {
        let runs = CTLineGetGlyphRuns(line)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        for index in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, index), to: CTRun.self)
            let range = CTRunGetStringRange(run)
            if let stringOffset, !(range.location <= stringOffset && stringOffset < range.location + range.length) { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] else { continue }
            let face = font as! CTFont
            ascent = max(ascent, ceil(CTFontGetAscent(face)))
            descent = max(descent, ceil(CTFontGetDescent(face)))
        }
        return (ascent, descent)
    }

    /// DOM Range geometry used by the frozen measureLineProfile. The browser
    /// probes full advance rectangles of every visible Unicode scalar; the
    /// smaller glyph image bounds are retained separately for actual painting.
    private static func advanceBounds(frame: CTFrame, frameSize: CGSize, offset: CGPoint, scaleX: CGFloat,
                                    text: String, vertical: Bool) -> [CGRect] {
        let lines = CTFrameGetLines(frame), count = CFArrayGetCount(lines)
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var scalars: [(start: Int, end: Int, space: Bool)] = [], position = 0
        for scalar in text.unicodeScalars {
            let next = position + scalar.utf16.count
            scalars.append((position, next, CharacterSet.whitespacesAndNewlines.contains(scalar))); position = next
        }
        var boxes: [CGRect] = []
        for index in 0..<count {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            let range = CTLineGetStringRange(line), origin = origins[index]
            for scalar in scalars where !scalar.space && scalar.start >= range.location && scalar.end <= range.location + range.length {
                let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let rawStart = CTLineGetOffsetForStringIndex(line, scalar.start, nil)
                let rawEnd = CTLineGetOffsetForStringIndex(line, scalar.end, nil)
                let start = vertical ? max(0, min(advance, rawStart)) : rawStart
                let end = vertical ? max(0, min(advance, rawEnd)) : rawEnd
                let font = roundedFontBounds(line: line, stringOffset: scalar.start)
                let local: CGRect
                if vertical {
                    local = CGRect(x: origin.x - font.descent + offset.x,
                        y: frameSize.height - origin.y + min(start, end) + offset.y,
                        width: font.ascent + font.descent, height: abs(end - start))
                } else {
                    local = CGRect(x: (origin.x + min(start, end) + offset.x) * scaleX,
                        y: frameSize.height - origin.y - font.ascent + offset.y,
                        width: abs(end - start) * scaleX, height: font.ascent + font.descent)
                }
                if local.width > 0, local.height > 0 { boxes.append(local) }
            }
        }
        return boxes
    }

    /// DOM single-scalar ranges enclose integral cursor advances relative to
    /// the anonymous flex text box, then clip the terminal edge to that box.
    /// This policy geometry deliberately stays separate from glyph-path ink.
    private static func rangeBounds(frame: CTFrame, frameSize: CGSize, offset: CGPoint, scaleX: CGFloat,
                                    text: String, originalText: String, style: Style, movements: [CGPoint] = [], blockIntrinsic: [CGFloat?] = [], reuse: ScopedHorizontalPaintGeometry? = nil) -> [CGRect] {
        let lines = CTFrameGetLines(frame), count = CFArrayGetCount(lines)
        let saved = reuse.flatMap { $0.matches(frame: frame, size: frameSize, scaleX: scaleX,
            source: originalText, text: text, style: style, count: count) ? $0 : nil }
        var origins = saved?.origins ?? [CGPoint](repeating: .zero, count: count)
        if saved == nil { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
        var scalars: [(start: Int, end: Int, space: Bool)] = [], position = 0
        for scalar in text.unicodeScalars {
            let next = position + scalar.utf16.count
            scalars.append((position, next, CharacterSet.whitespacesAndNewlines.contains(scalar))); position = next
        }
        let naturalWidth = saved?.naturalWidth ?? originalText.components(separatedBy: .newlines).map {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedString(text: $0, style: style)), nil, nil, nil))
        }.max() ?? 0
        let alignment: CGFloat = style.horizontalAlignment == .left ? 0 : style.horizontalAlignment == .right ? 1 : 0.5
        let flex = NativeTextPaintGeometry.anonymousFlexBox(contentWidth: frameSize.width, maximumContentWidth: naturalWidth, minimumContentWidth: saved?.minimumContent ?? (style.preservesBlockRows ? 0 : minimumHorizontalContentWidth(text: originalText, style: style)), justification: alignment)
        let anonymousInlineX = flex?.origin ?? 0
        let primaryBounds: (ascent: CGFloat, descent: CGFloat)
        if let saved { primaryBounds = (saved.ascent, saved.descent) }
        else { let primary = font(text: originalText, style: style); primaryBounds = (ceil(CTFontGetAscent(primary)), ceil(CTFontGetDescent(primary))) }
        let minimumInline: CGFloat
        if style.vertical {
            minimumInline = originalText.filter { !$0.isWhitespace }.map {
                CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedString(text: String($0), style: style)), nil, nil, nil))
            }.max() ?? 0
        } else {
            minimumInline = 0 // Unused: verticalInline is nil in this exact branch.
        }
        let verticalInline = style.vertical ? NativeTextPaintGeometry.anonymousFlexBox(contentWidth: frameSize.height,
            maximumContentWidth: naturalWidth, minimumContentWidth: minimumInline) : nil
        let inlineY = offset.y + (frameSize.height - (verticalInline?.width ?? frameSize.height)) / 2
        var boxes: [CGRect] = []
        for index in 0..<count {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            let range = saved?.ranges[index] ?? CTLineGetStringRange(line)
            var origin = origins[index]
            if index < movements.count { origin.x += movements[index].x / scaleX; origin.y -= movements[index].y }
            let advance = saved?.advances[index] ?? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let inlineX = style.preservesBlockRows
                ? (blockRowBox(contentWidth: frameSize.width, advance: (index < blockIntrinsic.count ? blockIntrinsic[index] : nil) ?? advance, style: style)?.origin ?? 0)
                : anonymousInlineX
            let verticalTop = frameSize.height - origin.y + offset.y
            let paintedScalars = scalars.filter { !$0.space && $0.start >= range.location && $0.end <= range.location + range.length }
            let right = floor((origin.x + offset.x + advance) * 64) / 64
            for scalar in scalars where !scalar.space && scalar.start >= range.location && scalar.end <= range.location + range.length {
                // CT cursor offsets bisect letter spacing; DOM cursor advances
                // follow glyph positions. Restore the half-kern at inner edges.
                let rawStart = CTLineGetOffsetForStringIndex(line, scalar.start, nil)
                    + (!style.vertical && scalar.start > range.location ? style.tracking / 2 : 0)
                let rawEnd = CTLineGetOffsetForStringIndex(line, scalar.end, nil)
                    + (!style.vertical && scalar.end < range.location + range.length ? style.tracking / 2 : 0)
                let start = floor(max(0, min(advance, min(rawStart, rawEnd))) * 64) / 64
                let end = floor(max(0, min(advance, max(rawStart, rawEnd))) * 64) / 64
                let primaryHeight = primaryBounds.ascent + primaryBounds.descent
                let font = style.vertical
                    ? (ascent: ceil(primaryHeight / 2), descent: floor(primaryHeight / 2)) : primaryBounds
                let local: CGRect
                if style.vertical {
                    let singleStart = max(0, min(advance, min(rawStart, rawEnd)))
                    let singleEnd = max(0, min(advance, max(rawStart, rawEnd)))
                    let top = paintedScalars.count == 1 ? verticalTop + singleStart
                        : inlineY + floor(verticalTop + start - inlineY)
                    let bottom = paintedScalars.count == 1 ? verticalTop + singleEnd
                        : min(inlineY + ceil(verticalTop + end - inlineY), floor((verticalTop + advance) * 64) / 64)
                    local = CGRect(x: origin.x - font.descent + offset.x, y: top,
                        width: font.ascent + font.descent, height: bottom - top)
                } else {
                    let left = inlineX + floor(origin.x + start + offset.x - inlineX)
                    let endX = min(inlineX + ceil(origin.x + end + offset.x - inlineX), right)
                    local = CGRect(x: left * scaleX, y: frameSize.height - origin.y - font.ascent + offset.y,
                        width: (endX - left) * scaleX, height: font.ascent + font.descent)
                }
                if local.width > 0, local.height > 0 { boxes.append(local) }
            }
        }
        return boxes
    }

    /// Quality measurements from the committed horizontal rows, not glyph-box
    /// clustering. Read-only: the same offsets and absolute anchors are used by draw().
    /// Source word cuts remain unknown when display text has no verified ownership ledger.
    static func horizontalRowMetrics(layout: Layout, originalText: String, origin: CGPoint = .zero,
                                     pixelSnapScale: CGFloat? = nil) -> [[String: Any]]? {
        guard layout.frameAttributes == nil, origin.x.isFinite, origin.y.isFinite else { return nil }
        guard let frame = layout.frame else { return layout.shapedText.isEmpty ? [] : nil }
        let lines = CTFrameGetLines(frame), count = CFArrayGetCount(lines)
        guard count == layout.lineRanges.count else { return nil }
        let shaped = layout.shapedText as NSString
        let source = originalText as NSString
        let ledger = layout.sourceUTF16Ownership
        let verified = sourceOwnershipCoverage(layout, originalText: originalText) != nil
        let directOwnership = ledger == nil && verified
        let ledgerValid = ledger != nil && verified
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        func isWord(_ character: Character) -> Bool {
            character.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
        }
        func cutsWord(at boundary: Int) -> Bool? {
            guard boundary > 0, boundary < source.length else { return false }
            let utf16Index = originalText.utf16.index(originalText.utf16.startIndex, offsetBy: boundary)
            guard let index = String.Index(utf16Index, within: originalText),
                  index > originalText.startIndex, index < originalText.endIndex else { return nil }
            // A boundary inside a composed character is not a word-boundary observation.
            guard originalText.indices.contains(index) else { return nil }
            return isWord(originalText[originalText.index(before: index)]) && isWord(originalText[index])
        }
        var rows: [[String: Any]] = []
        for index in 0..<count {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            let raw = CTLineGetStringRange(line)
            guard raw.location >= 0, raw.length >= 0, raw.location <= shaped.length,
                  raw.length <= shaped.length - raw.location else { return nil }
            let range = NSRange(location: raw.location, length: raw.length)
            let text = shaped.substring(with: range)
            let graphemes = text.filter { !$0.isWhitespace }
            let letters = graphemes.filter(isWord)
            let movement = index < layout.lineOffsets.count ? layout.lineOffsets[index] : .zero
            let anchor = CGPoint(x: origin.x + (layout.offset.x + origins[index].x) * layout.paintScaleX + movement.x,
                y: origin.y + layout.offset.y + layout.frameSize.height - origins[index].y + movement.y)
            guard anchor.x.isFinite, anchor.y.isFinite else { return nil }
            let painted = NativeTextPaintGeometry.paintOrigin(anchor, deviceScale: pixelSnapScale) ?? anchor
            var sourceRange: NSRange?
            if ledgerValid, let ledger {
                let owned = ledger[range.location..<NSMaxRange(range)].filter { $0.length > 0 }
                if let first = owned.first,
                   zip(owned, owned.dropFirst()).allSatisfy({
                       $0.1.location >= $0.0.location && NSMaxRange($0.0) >= $0.1.location
                   }) {
                    let end = owned.reduce(first.location) { max($0, NSMaxRange($1)) }
                    sourceRange = NSRange(location: first.location, length: end - first.location)
                }
            } else if directOwnership { sourceRange = range }
            let cut = sourceRange.flatMap { cutsWord(at: NSMaxRange($0)) }
            let singleHangul = letters.count == 1 && letters.first?.unicodeScalars.contains(where: isHangulScript) == true
            rows.append([
                "index": index, "shapedUTF16Range": [range.location, range.length],
                "sourceUTF16Range": sourceRange.map { [$0.location, $0.length] } as Any? ?? NSNull(),
                "graphemeCount": graphemes.count,
                "scalarCount": text.unicodeScalars.filter { !$0.properties.isWhitespace }.count,
                "letterGraphemeCount": letters.count, "singleHangulLetterRow": singleHangul,
                "endsInsideSourceTokenProxy": cut as Any? ?? NSNull(),
                "pixelSnappingApplied": NativeTextPaintGeometry.paintOrigin(anchor, deviceScale: pixelSnapScale) != nil,
                "unsnappedBaseline": [Double(anchor.x), Double(anchor.y)],
                "paintedBaseline": [Double(painted.x), Double(painted.y)]
            ])
        }
        for index in rows.indices {
            guard index + 1 < rows.count else {
                rows[index]["tokenCutAfterRowProxy"] = false
                continue
            }
            guard let current = rows[index]["sourceUTF16Range"] as? [Int],
                  let next = rows[index + 1]["sourceUTF16Range"] as? [Int],
                  current[0] + current[1] == next[0],
                  let cut = rows[index]["endsInsideSourceTokenProxy"] as? Bool else {
                rows[index]["tokenCutAfterRowProxy"] = NSNull()
                continue
            }
            rows[index]["tokenCutAfterRowProxy"] = cut
        }
        return rows
    }

    /// Alignment anchors of the committed CT-frame painter, not original-source
    /// alignment truth. Preserve unknown for non-frame, transformed or bidi runs.
    /// The caller supplies its frozen current alignment model separately.
    static func committedRowAlignmentAnchors(layout: Layout, alignment: HorizontalAlignment,
        origin: CGPoint = .zero, pixelSnapScale: CGFloat? = nil) -> [CGFloat]? {
        guard layout.frameAttributes == nil, layout.paintScaleX == 1,
              origin.x.isFinite, origin.y.isFinite, let frame = layout.frame,
              let alignmentWidths = layout.committedRowAlignmentWidths else { return nil }
        let lines = CTFrameGetLines(frame)
        let count = CFArrayGetCount(lines)
        guard count == layout.lineRanges.count, count == alignmentWidths.count else { return nil }
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let fraction: CGFloat = alignment == .left ? 0 : alignment == .right ? 1 : 0.5
        var result: [CGFloat] = []
        for index in 0..<count {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            let actual = CTLineGetStringRange(line)
            guard actual.location == layout.lineRanges[index].location,
                  actual.length == layout.lineRanges[index].length else { return nil }
            let runs = CTLineGetGlyphRuns(line)
            for r in 0..<CFArrayGetCount(runs) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, r), to: CTRun.self)
                guard !CTRunGetStatus(run).contains(.rightToLeft), CTRunGetTextMatrix(run) == .identity else { return nil }
            }
            let width = alignmentWidths[index]
            let shift = index < layout.lineOffsets.count ? layout.lineOffsets[index] : .zero
            let point = CGPoint(x: origin.x + layout.offset.x + origins[index].x + shift.x,
                y: origin.y + layout.offset.y + layout.frameSize.height - origins[index].y + shift.y)
            let painted = NativeTextPaintGeometry.paintOrigin(point, deviceScale: pixelSnapScale) ?? point
            let x = painted.x + width * fraction
            guard width.isFinite, width >= 0, x.isFinite else { return nil }
            result.append(x)
        }
        return result
    }

    /// Opt-in diagnostics from the committed Core Text frame. Origins and run
    /// positions retain Core Text's lower-left coordinates; layoutOffset and
    /// lineOffset describe the separate top-left placement used by painting.
    /// This reads the frame without reshaping text or changing graphics state.
    static func diagnosticRuns(layout: Layout) -> [[String: Any]] {
        guard let frame = layout.frame,
              layout.frameSize.width.isFinite, layout.frameSize.height.isFinite,
              layout.offset.x.isFinite, layout.offset.y.isFinite,
              layout.paintScaleX.isFinite else { return [] }
        let text = layout.shapedText as NSString
        func checkedRange(_ range: CFRange) -> [Int]? {
            guard range.location >= 0, range.length >= 0,
                  range.location <= text.length,
                  range.length <= text.length - range.location else { return nil }
            return [range.location, range.length]
        }
        func point(_ value: CGPoint) -> [Double]? {
            guard value.x.isFinite, value.y.isFinite else { return nil }
            return [Double(value.x), Double(value.y)]
        }
        // A vertical CTRun can contain a font with symmetric vertical metrics.
        // Retain the selected pre-frame face separately from those run metrics.
        var primaryFont: [String: Any]?
        if let attributed = layout.attributed, attributed.length > 0,
           let value = attributed.attribute(NSAttributedString.Key(kCTFontAttributeName as String), at: 0, effectiveRange: nil) {
            let object = value as AnyObject
            if CFGetTypeID(object) == CTFontGetTypeID() {
                let font = unsafeDowncast(object, to: CTFont.self)
                let metrics = [CTFontGetSize(font), CTFontGetAscent(font), CTFontGetDescent(font), CTFontGetLeading(font)]
                if metrics.allSatisfy(\.isFinite) {
                    primaryFont = [
                        "fontName": CTFontCopyPostScriptName(font) as String,
                        "fontSize": Double(metrics[0]), "fontAscent": Double(metrics[1]),
                        "fontDescent": Double(metrics[2]), "fontLeading": Double(metrics[3]),
                        "rangeAscent": Double(ceil(metrics[1])), "rangeDescent": Double(ceil(metrics[2])),
                        "unitsPerEm": Int(CTFontGetUnitsPerEm(font)),
                    ]
                }
            }
        }
        let lines = CTFrameGetLines(frame), count = CFArrayGetCount(lines)
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var result: [[String: Any]] = []
        for lineIndex in 0..<count {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, lineIndex), to: CTLine.self)
            guard let range = checkedRange(CTLineGetStringRange(line)),
                  let origin = point(origins[lineIndex]),
                  let movement = point(lineIndex < layout.lineOffsets.count ? layout.lineOffsets[lineIndex] : .zero)
            else { continue }
            let rawRuns = CTLineGetGlyphRuns(line)
            var runs: [[String: Any]] = []
            for runIndex in 0..<CFArrayGetCount(rawRuns) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(rawRuns, runIndex), to: CTRun.self)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let runRange = checkedRange(CTRunGetStringRange(run)),
                      let fontValue = attributes[kCTFontAttributeName] else { continue }
                let fontObject = fontValue as AnyObject
                guard CFGetTypeID(fontObject) == CTFontGetTypeID() else { continue }
                let font = unsafeDowncast(fontObject, to: CTFont.self)
                let fontSize = CTFontGetSize(font), matrix = CTRunGetTextMatrix(run)
                let fontMetrics = [CTFontGetAscent(font), CTFontGetDescent(font), CTFontGetLeading(font)]
                let matrixValues = [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty]
                guard fontSize.isFinite, fontMetrics.allSatisfy(\.isFinite), matrixValues.allSatisfy(\.isFinite) else { continue }
                let glyphCount = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
                var positions = [CGPoint](repeating: .zero, count: glyphCount)
                var advances = [CGSize](repeating: .zero, count: glyphCount)
                var verticalTranslations = [CGSize](repeating: .zero, count: glyphCount)
                var indices = [CFIndex](repeating: 0, count: glyphCount)
                let allGlyphs = CFRange(location: 0, length: 0)
                CTRunGetGlyphs(run, allGlyphs, &glyphs)
                CTRunGetPositions(run, allGlyphs, &positions)
                CTRunGetAdvances(run, allGlyphs, &advances)
                CTRunGetStringIndices(run, allGlyphs, &indices)
                CTFontGetVerticalTranslationsForGlyphs(font, &glyphs, &verticalTranslations, glyphCount)
                guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                      advances.allSatisfy({ $0.width.isFinite && $0.height.isFinite }),
                      verticalTranslations.allSatisfy({ $0.width.isFinite && $0.height.isFinite }) else { continue }
                runs.append([
                    "index": runIndex, "range": runRange,
                    "text": text.substring(with: NSRange(location: runRange[0], length: runRange[1])),
                    "fontName": CTFontCopyPostScriptName(font) as String,
                    "fontSize": Double(fontSize),
                    "fontAscent": Double(fontMetrics[0]),
                    "fontDescent": Double(fontMetrics[1]),
                    "fontLeading": Double(fontMetrics[2]),
                    "unitsPerEm": Int(CTFontGetUnitsPerEm(font)),
                    "glyphs": glyphs.map(Int.init),
                    "positions": positions.map { [Double($0.x), Double($0.y)] },
                    "advances": advances.map { [Double($0.width), Double($0.height)] },
                    "verticalTranslations": verticalTranslations.map { [Double($0.width), Double($0.height)] },
                    "stringIndices": indices,
                    "textMatrix": matrixValues.map(Double.init),
                ])
            }
            var row: [String: Any] = [
                "index": lineIndex, "range": range,
                "text": text.substring(with: NSRange(location: range[0], length: range[1])),
                "origin": origin,
                "frameSize": [Double(layout.frameSize.width), Double(layout.frameSize.height)],
                "layoutOffset": [Double(layout.offset.x), Double(layout.offset.y)],
                "lineOffset": movement, "paintScaleX": Double(layout.paintScaleX),
                "runs": runs,
            ]
            if let primaryFont { row["primaryFont"] = primaryFont }
            if lineIndex < layout.blockRowIntrinsicWidths.count, let intrinsic = layout.blockRowIntrinsicWidths[lineIndex], intrinsic.isFinite {
                row["blockRowIntrinsicWidth"] = Double(intrinsic)
            }
            if lineIndex < layout.verticalPaintOffsets.count,
               let paintOffset = point(layout.verticalPaintOffsets[lineIndex]) {
                row["verticalPaintOffset"] = paintOffset
            }
            result.append(row)
        }
        return result
    }

    /// CSS layout overflow follows line advances, independently of glyph ink,
    /// outlines, and DOM selection rectangles.
    static func lineAdvances(layout: Layout) -> [CGFloat] {
        guard let frame = layout.frame else { return [] }
        let lines = CTFrameGetLines(frame)
        return (0..<CFArrayGetCount(lines)).map { index in
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            return max(0, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
    }

    struct CaptionLineMetrics {
        let rect: CGRect
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Line advance rectangles and actual ink metrics, from the committed frame.
    /// The line rect is stroke-free and lives in the same top-left space as glyphBounds.
    static func captionLineMetrics(layout: Layout) -> [CaptionLineMetrics] {
        guard let frame = layout.frame else { return [] }
        let lines = CTFrameGetLines(frame), count = CFArrayGetCount(lines)
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let primary: CTFont? = layout.attributed.flatMap { attributed in
            guard attributed.length > 0, let value = attributed.attribute(NSAttributedString.Key(kCTFontAttributeName as String), at: 0, effectiveRange: nil) else { return nil }
            return (value as! CTFont)
        }
        return (0..<count).map { index in
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let ink = CTLineGetImageBounds(line, nil)
            let origin = origins[index]
            let primaryHeight = primary.map { ceil(CTFontGetAscent($0)) + ceil(CTFontGetDescent($0)) }
            let font: (ascent: CGFloat, descent: CGFloat)
            if let primaryHeight, layout.frameAttributes != nil {
                font = (ascent: ceil(primaryHeight / 2), descent: floor(primaryHeight / 2))
            } else if let primary {
                font = (ascent: ceil(CTFontGetAscent(primary)), descent: ceil(CTFontGetDescent(primary)))
            } else { font = roundedFontBounds(line: line) }
            let rect = layout.frameAttributes != nil
                ? CGRect(x: origin.x - font.descent + layout.offset.x, y: layout.frameSize.height - origin.y + layout.offset.y,
                         width: font.ascent + font.descent, height: max(0, width))
                : CGRect(x: (origin.x + layout.offset.x) * layout.paintScaleX,
                         y: layout.frameSize.height - origin.y - font.ascent + layout.offset.y,
                         width: max(0, width) * layout.paintScaleX, height: font.ascent + font.descent)
            let movement = index < layout.lineOffsets.count ? layout.lineOffsets[index] : .zero
            return CaptionLineMetrics(rect: rect.offsetBy(dx: movement.x, dy: movement.y),
                ascent: max(0, ink.maxY), descent: max(0, -ink.minY))
        }
    }

    /// Native counterpart of aidokuKoreanLines: minimize raggedness while
    /// protecting eojeols, single-syllable fragments, paired punctuation, and
    /// dependent nouns. Measurement uses the exact final glyph font/tracking.
    /// Explicit source line breaks and long captions keep normal Core Text flow.
    static func koreanLines(text: String, available: CGSize, style: Style,
                            maxLines: Int? = nil, measuresScalars: Bool = false,
                            width: ((String) -> CGFloat)? = nil) -> [String]? {
        guard text.utf16.count <= 180, !text.contains(where: \.isNewline),
              text.unicodeScalars.contains(where: isHangulScript),
              available.width.isFinite, available.width > 0,
              available.height.isFinite, available.height > 0,
              style.fontSize.isFinite, style.fontSize > 0,
              style.lineHeight.isFinite, style.lineHeight > 0,
              style.tracking.isFinite
        else { return nil }
        let characters = text.unicodeScalars.map { Character(String($0)) }
        let count = characters.count
        guard count > 0 else { return nil }
        let protectedCuts = NativeParentheticalNameWrap.protectedUTF16Cuts(text)
        var sourceOffsets: [Int] = []
        if !protectedCuts.isEmpty {
            sourceOffsets.reserveCapacity(count + 1)
            sourceOffsets.append(0)
            for character in characters { sourceOffsets.append(sourceOffsets.last! + String(character).utf16.count) }
        }
        let pitch = max(style.fontSize, style.lineHeight)
        let limit = min(count, max(1, maxLines ?? Int(max(1, min(CGFloat(count), floor(available.height / pitch))))))
        if let maxLines, maxLines < 1 { return nil }
        let spaces = characters.map(\.isWhitespace)
        let hangul = characters.map { character in
            character.unicodeScalars.count == 1 &&
                character.unicodeScalars.first.map(isHangulScript) == true
        }
        let opening = Set(style.koreanQuoteMode > 0 ? "（([「『【《〈“‘" : "（([「『【《〈")
        let closing = Set(style.koreanQuoteMode > 0 ? "、。，．,.！？!?…‥）)]」』】》〉:;”’" : "、。，．,.！？!?…‥）)]」』】》〉:;")
        var opens = characters.map { opening.contains($0) }
        var closes = characters.map { closing.contains($0) }
        for index in 0..<count where style.koreanQuoteMode > 0 && (characters[index] == "\"" || characters[index] == "'") {
            let afterInk = index > 0 && !spaces[index - 1] && !opening.contains(characters[index - 1])
            opens[index] = !afterInk
            closes[index] = afterInk
        }
        var koreanBefore = Array(repeating: 0, count: count + 1)
        var letterBefore = Array(repeating: 0, count: count + 1)
        var nextSpace = Array(repeating: count, count: count + 1)
        var previousSpace = Array(repeating: -1, count: count)
        var previousInk = Array(repeating: -1, count: count)
        for index in 0..<count {
            koreanBefore[index + 1] = koreanBefore[index] + (hangul[index] ? 1 : 0)
            let isLetter = characters[index].unicodeScalars.contains {
                $0.properties.isAlphabetic || $0.properties.numericType != nil
            }
            letterBefore[index + 1] = letterBefore[index] + (isLetter ? 1 : 0)
            previousSpace[index] = spaces[index] ? index : (index > 0 ? previousSpace[index - 1] : -1)
            previousInk[index] = spaces[index] ? (index > 0 ? previousInk[index - 1] : -1) : index
        }
        for index in stride(from: count - 1, through: 0, by: -1) {
            nextSpace[index] = spaces[index] ? index : nextSpace[index + 1]
        }
        let dependentNouns: Set<String> = [
            "것", "거", "게", "걸", "건", "수", "줄", "때", "데", "뿐", "듯", "적", "척", "만큼", "대로", "중", "채", "김", "바", "법", "리",
        ]
        var dependent = Array(repeating: false, count: count)
        if count > 1 && style.koreanQuoteMode == 2 {
            for index in 1..<count where !spaces[index] && spaces[index - 1] && previousInk[index - 1] >= 0 {
                let prior = characters[previousInk[index - 1]].unicodeScalars
                guard prior.count == 1, let scalar = prior.first, (0xAC00...0xD7A3).contains(scalar.value) else { continue }
                let final = (scalar.value - 0xAC00) % 28
                guard final == 4 || final == 8 else { continue }
                var end = nextSpace[index]
                while end > index && characters[end - 1].unicodeScalars.allSatisfy({
                    CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
                }) { end -= 1 }
                dependent[index] = dependentNouns.contains(String(characters[index..<end]))
            }
        }
        let measuredFont = font(text: text, style: style)
        let measurementAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): measuredFont,
        ]
        var scalarAdvances = [CGFloat](repeating: 0, count: count + 1)
        if measuresScalars {
            for index in 0..<count {
                let scalarLine = CTLineCreateWithAttributedString(NSAttributedString(
                    string: String(characters[index]), attributes: measurementAttributes))
                scalarAdvances[index + 1] = scalarAdvances[index] + CGFloat(CTLineGetTypographicBounds(scalarLine, nil, nil, nil))
            }
        }
        var costs = Array(repeating: Array(repeating: CGFloat.infinity, count: count + 1), count: limit + 1)
        var next = Array(repeating: Array(repeating: -1, count: count + 1), count: limit + 1)
        costs[0][count] = 0
        for start in stride(from: count - 1, through: 0, by: -1) {
            var first = start
            while first < count && spaces[first] { first += 1 }
            guard first < count else { continue }
            for end in (start + 1)...count {
                if !protectedCuts.isEmpty,
                   protectedCuts.contains(sourceOffsets[start]) || protectedCuts.contains(sourceOffsets[end]) { continue }
                if end < count && spaces[end] { continue }
                let last = previousInk[end - 1]
                guard last >= first else { continue }
                let lineText = String(characters[first...last])
                let used = width?(lineText) ?? ((measuresScalars ? scalarAdvances[last + 1] - scalarAdvances[first]
                    : CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                        NSAttributedString(string: lineText, attributes: measurementAttributes)), nil, nil, nil))) +
                    CGFloat(max(0, lineText.unicodeScalars.count - 1)) * style.tracking)
                guard used.isFinite, used >= 0 else { return nil }
                if used > available.width + 0.1 { break }
                if (closes[first] && (start > 0 || letterBefore[last + 1] == letterBefore[first])) || opens[last] { continue }
                let split = end < count && !spaces[end - 1] && !spaces[end]
                let firstWord = koreanBefore[min(nextSpace[first], last + 1)] - koreanBefore[first]
                let lastWord = koreanBefore[last + 1] - koreanBefore[max(previousSpace[last] + 1, first)]
                let fragment = (firstWord == 1 && start > 0 && hangul[start - 1] && hangul[first]) ||
                    (lastWord == 1 && split && hangul[last] && hangul[end])
                let raggedness = 1 - used / available.width
                let cost: CGFloat = 12 + (split ? 36 : 0) + (fragment ? 90 : 0) +
                    (start > 0 && dependent[first] ? 24 : 0) + raggedness * raggedness * (end == count ? 5 : 16)
                for lines in 1...min(limit, count - end + 1) {
                    let total = cost + costs[lines - 1][end]
                    if total < costs[lines][start] {
                        costs[lines][start] = total
                        next[lines][start] = end
                    }
                }
            }
        }
        let remaining = (1...limit).min { costs[$0][0] < costs[$1][0] } ?? 1
        guard next[remaining][0] >= 0 else { return nil }
        var result: [String] = []
        var index = 0
        var lines = remaining
        while index < count && lines > 0 {
            let end = next[lines][index]
            guard end > index else { return nil }
            // Keep every original character. Only controlled line separators
            // are inserted for shaping; caller-facing ranges use original UTF16.
            result.append(String(characters[index..<end]))
            index = end
            lines -= 1
        }
        return index == count ? result : nil
    }

    /// Canvas-compatible advance: untracked shaping plus tracking at code-point gaps.
    static func measuredWidth(text: String, style: Style) -> CGFloat {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font(text: text, style: style)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) +
            CGFloat(max(0, text.unicodeScalars.count - 1)) * style.tracking
    }

    private static func isHangulScript(_ scalar: Unicode.Scalar) -> Bool {
        (0x1100...0x11FF).contains(scalar.value) ||
            (0x302E...0x302F).contains(scalar.value) ||
            (0x3131...0x318E).contains(scalar.value) ||
            (0x3200...0x321E).contains(scalar.value) ||
            (0x3260...0x327E).contains(scalar.value) ||
            (0xA960...0xA97C).contains(scalar.value) ||
            (0xAC00...0xD7A3).contains(scalar.value) ||
            (0xD7B0...0xD7C6).contains(scalar.value) ||
            (0xD7CB...0xD7FB).contains(scalar.value) ||
            (0xFFA0...0xFFBE).contains(scalar.value) ||
            (0xFFC2...0xFFC7).contains(scalar.value) ||
            (0xFFCA...0xFFCF).contains(scalar.value) ||
            (0xFFD2...0xFFD7).contains(scalar.value) ||
            (0xFFDA...0xFFDC).contains(scalar.value)
    }

    /// Effective automatic script used for shaping and typography cohorts.
    /// Explicit font names are independent of this script and retain priority.
    static func resolvedFontScript(text: String, style: Style) -> String {
        var inferred = style.fontScript.isEmpty ? script(for: text) : style.fontScript
        if style.prefersDominantKoreanScript, inferred == "japanese" {
            var hangulCount = 0, kanaCount = 0
            // Counting needs no materialized scalar arrays or retained cache.
            for scalar in text.unicodeScalars {
                if isHangulScript(scalar) { hangulCount += 1 }
                else if (0x3040...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value) ||
                    (0xFF66...0xFF9D).contains(scalar.value) { kanaCount += 1 }
            }
            if hangulCount > kanaCount { inferred = "korean" }
        }
        return inferred
    }

    private static func font(text: String, style: Style) -> CTFont {
        if style.fontName == "AidokuSerifKR-Bold" { _ = bundledSerifRegistered }
        // Arbitrary named fonts can be registered after a render. Do not cache
        // their temporarily missing-face fallback across registration changes.
        guard style.fontName == nil || (style.fontName == "AidokuSerifKR-Bold" && bundledSerifRegistered) else {
            return uncachedFont(text: text, style: style)
        }
        let key = NativeTypographyFontCache.Key(name: style.fontName,
            script: resolvedFontScript(text: text, style: style), size: Double(style.fontSize).bitPattern,
            bold: style.bold, vertical: style.vertical)
        return NativeTypographyFontCache.get(key) { uncachedFont(text: text, style: style) }
    }

    private static func uncachedFont(text: String, style: Style) -> CTFont {
        if style.fontName == "AidokuSerifKR-Bold" { _ = bundledSerifRegistered }
        let inferredScript = resolvedFontScript(text: text, style: style)
        let named: String?
        if let requested = style.fontName {
            named = requested
        } else {
            switch inferredScript {
            case "korean":
                named = style.bold ? (style.vertical ? "AppleSDGothicNeo-ExtraBold" : "AppleSDGothicNeo-Bold") : "AppleSDGothicNeo-Regular"
            case "japanese":
                named = style.bold ? (style.vertical ? "HiraginoSans-W8" : "HiraginoSans-W7") : "HiraginoSans-W3"
            case "han":
                named = style.bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
            default:
                named = nil
            }
        }
        if let named {
            let adjustedSize = named == "AidokuSerifKR-Bold" ? style.fontSize * 0.91 : style.fontSize
            // FontDescription computedSize and the CoreText creation boundary are Float32.
            // The separate serif size-adjust multiplication order is not yet proved.
            let creationSize = named == "AidokuSerifKR-Bold" ? adjustedSize : CGFloat(Float(adjustedSize))
            let font = CTFontCreateWithName(named as CFString, creationSize, nil)
            if CTFontCopyPostScriptName(font) as String == named { return font }
        }
        if style.fontName != nil {
            var fallbackStyle = style
            fallbackStyle.fontName = nil
            return font(text: text, style: fallbackStyle)
        }
        // Match -apple-system's separate 700/800 faces, including vertical
        // Latin captions. Symbolic bold alone cannot express CSS weight 800.
        let usage = style.bold ? (style.vertical ? "CTFontHeavyUsage" : "CTFontBoldUsage") : "CTFontRegularUsage"
        let descriptor = CTFontDescriptorCreateWithAttributes(["NSCTFontUIUsageAttribute": usage] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, CGFloat(Float(style.fontSize)), nil)
    }

    private static func script(for text: String) -> String {
        let values = text.unicodeScalars.map(\.value)
        // Use the same script coverage as Korean shaping/wrapping. Isolated
        // compatibility jamo (for example consonant reactions) otherwise
        // select a Latin primary face and receive an unweighted cascade font.
        if text.unicodeScalars.contains(where: isHangulScript) { return "korean" }
        if values.contains(where: { (0x3040...0x30FF).contains($0) }) { return "japanese" }
        if values.contains(where: { (0x3400...0x9FFF).contains($0) }) { return "han" }
        return "word"
    }

    private static func inkBounds(frame: CTFrame, frameSize: CGSize, vertical: Bool) -> CGRect {
        let lines = CTFrameGetLines(frame)
        let count = CFArrayGetCount(lines)
        guard count > 0 else { return .zero }
        var origins = Array(repeating: CGPoint.zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var union = CGRect.null
        for index in 0..<count {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            let local = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds, .excludeTypographicLeading])
            guard !local.isEmpty else { continue }
            let origin = origins[index]
            let bounds = vertical
                ? CGRect(x: origin.x + local.minY, y: origin.y - local.maxX, width: local.height, height: local.width)
                : local.offsetBy(dx: origin.x, dy: origin.y)
            union = union.union(CGRect(x: bounds.minX, y: frameSize.height - bounds.maxY, width: bounds.width, height: bounds.height))
        }
        return union.isNull ? .zero : union
    }

    private static func glyphBounds(frame: CTFrame, frameSize: CGSize, vertical: Bool, movements: [CGPoint] = [], scaleX: CGFloat = 1) -> [CGRect] {
        let lines = CTFrameGetLines(frame)
        let count = CFArrayGetCount(lines)
        guard count > 0 else { return [] }
        var origins = Array(repeating: CGPoint.zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var result: [CGRect] = []
        for index in 0..<count {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
            let runs = CTLineGetGlyphRuns(line)
            var origin = origins[index]
            if index < movements.count { origin.x += movements[index].x / scaleX; origin.y -= movements[index].y }
            for runIndex in 0..<CFArrayGetCount(runs) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
                for glyphIndex in 0..<CTRunGetGlyphCount(run) {
                    let local = CTRunGetImageBounds(run, nil, CFRange(location: glyphIndex, length: 1))
                    guard !local.isEmpty else { continue }
                    let bounds = vertical
                        ? CGRect(x: origin.x + local.minY, y: origin.y - local.maxX, width: local.height, height: local.width)
                        : local.offsetBy(dx: origin.x, dy: origin.y)
                    result.append(CGRect(
                        x: bounds.minX, y: frameSize.height - bounds.maxY,
                        width: bounds.width, height: bounds.height
                    ))
                }
            }
        }
        return result
    }
}
// Committed native row frontiers retain the original input and baseline.
// Safety and source-style authority remain the renderer caller's responsibility.
extension NativeTranslationTypography {
    private struct ParagraphRowKey: Hashable {
        let start: Int
        let rows: Int
    }

    /// Native attributedString measurements, no alternate font/scale solver.
    /// False completeness is a resource outcome, never physical infeasibility.
    static func committedParagraphFrontier(
        text: String, width: CGFloat, style: Style,
        utf16Work: inout Int, geometryWork: inout Int,
        referenceLayout: Layout? = nil
    ) -> (programs: [CommittedParagraphProgram], complete: Bool) {
        guard !style.vertical, !style.preservesBlockRows, !text.isEmpty,
              !style.keepsWholeWords, !style.strictLineBreak,
              style.fontSize.isFinite, style.fontSize > 0,
              style.outlineWidth.isFinite, style.outlineWidth >= 0,
              width.isFinite, width > 0, style.horizontalScale.isFinite,
              style.horizontalScale >= 0.5, style.horizontalScale <= 1 else { return ([], false) }
        let source = text as NSString
        guard source.length > 0, source.length <= utf16Work else { return ([], false) }
        utf16Work -= source.length
        var scalarAt: [Int: Unicode.Scalar] = [:], scalarOffset = 0
        for scalar in text.unicodeScalars {
            scalarAt[scalarOffset] = scalar
            scalarOffset += scalar.utf16.count
        }
        var boundaries = [0], hardEnds: Set<Int> = [], offset = 0
        for character in text {
            let length = String(character).utf16.count
            let next = offset.addingReportingOverflow(length)
            guard !next.overflow else { return ([], false) }
            offset = next.partialValue; boundaries.append(offset)
            if character.isNewline { hardEnds.insert(offset) }
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributedString(text: text, style: style))
        struct Row {
            let range: NSRange
            let fill: CGFloat
            let cuts: Int
            let singleton: Int
        }
        struct Node {
            let score: [CGFloat]
            let ranges: [NSRange]
            let short: Int
            let ragged: CGFloat
        }
        var cache: [NSRange: Row] = [:], exhausted = false
        func measured(_ range: NSRange) -> Row? {
            if let old = cache[range] { return old }
            guard range.length <= utf16Work else { exhausted = true; return nil }
            utf16Work -= range.length
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
            let actual = CTLineGetStringRange(line)
            guard actual.location == range.location, actual.length == range.length else { return nil }
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let ink = CTLineGetImageBounds(line, nil)
            let value = source.substring(with: range)
            let plain = Array(value.unicodeScalars.filter { !$0.properties.isWhitespace })
            let hasInk = !plain.isEmpty && !ink.isNull && !ink.isInfinite
            let supportedWidth = hasInk
                ? max(advance, ink.maxX) - min(0, ink.minX) + style.outlineWidth : advance
            let fill = supportedWidth * style.horizontalScale / width
            guard fill.isFinite else { return nil }
            let end = range.location + range.length
            func token(_ scalar: Unicode.Scalar?) -> Bool {
                scalar.map { CharacterSet.alphanumerics.contains($0) } ?? false
            }
            let before = value.unicodeScalars.last
            let after = scalarAt[end]
            let cuts = token(before) && token(after) ? 1 : 0
            let letters = value.filter { character in
                !character.isWhitespace && character.unicodeScalars.contains {
                    $0.properties.isAlphabetic || $0.properties.numericType != nil
                }
            }
            let singleton = letters.count == 1 && letters.first?.unicodeScalars.contains(where: isHangulScript) == true ? 1 : 0
            let row = Row(range: range, fill: fill, cuts: cuts, singleton: singleton)
            cache[range] = row
            return row
        }
        func preferred(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
            for (x, y) in zip(a, b) where x != y { return x < y }
            return false
        }
        var output: [CommittedParagraphProgram] = []
        for mode in ["balance-inspired", "pretty-inspired"] {
            var allRanges: [NSRange] = [], cuts = 0, singles = 0, short = 0
            var ragged: CGFloat = 0, segmentStart = 0
            for segmentEnd in boundaries.dropFirst() where hardEnds.contains(segmentEnd) || segmentEnd == source.length {
                var cursor = segmentStart, targetRows = 0
                while cursor < segmentEnd {
                    guard geometryWork > 0 else { return ([], false) }
                    geometryWork -= 1
                    let count = CTTypesetterSuggestLineBreak(typesetter, cursor, Double(width / style.horizontalScale))
                    guard count > 0, count <= source.length - cursor else { return ([], false) }
                    let end = min(segmentEnd, cursor + count)
                    guard boundaries.contains(end) else { return ([], false) }
                    cursor = end; targetRows += 1
                }
                if let referenceLayout {
                    guard let observed = horizontalRowMetrics(layout: referenceLayout, originalText: text),
                          referenceLayout.visibleUTF16Range.length == source.length else { return ([], false) }
                    let owned = observed.compactMap { $0["sourceUTF16Range"] as? [Int] }
                    guard owned.count == observed.count else { return ([], false) }
                    let rowsInSegment = owned.filter { $0[0] >= segmentStart && $0[0] < segmentEnd }
                    guard !rowsInSegment.isEmpty,
                          rowsInSegment.allSatisfy({ $0[0] + $0[1] <= segmentEnd }) else { return ([], false) }
                    targetRows = rowsInSegment.count
                }
                let positions = boundaries.filter { $0 >= segmentStart && $0 <= segmentEnd }
                var table: [ParagraphRowKey: Node] = [
                    .init(start: segmentEnd, rows: 0): .init(score: [0, 0, 0, 0], ranges: [], short: 0, ragged: 0)
                ]
                // Bottom-up: no input-length-dependent recursion/stack depth.
                for remaining in 1...targetRows {
                    for start in positions.dropLast().reversed() {
                        for end in positions where end > start {
                            guard geometryWork > 0 else { return ([], false) }
                            geometryWork -= 1
                            guard let tail = table[.init(start: end, rows: remaining - 1)] else { continue }
                            guard let row = measured(NSRange(location: start, length: end - start)) else {
                                if exhausted { return ([], false) }
                                continue
                            }
                            guard row.fill <= 1 + 1e-9 else { continue }
                            let last = end == segmentEnd
                            let lastPenalty = last && targetRows > 1 ? pow(max(0, 0.35 - row.fill), 2) : 0
                            let empty = pow(1 - row.fill, 2)
                            let score = [CGFloat(row.cuts) + tail.score[0], CGFloat(row.singleton) + tail.score[1],
                                (mode == "balance-inspired" ? empty : lastPenalty) + tail.score[2],
                                (mode == "balance-inspired" ? lastPenalty : last ? 0 : empty) + tail.score[3]]
                            let node = Node(score: score, ranges: [row.range] + tail.ranges,
                                short: (last && targetRows > 1 && row.fill < 0.35 ? 1 : 0) + tail.short,
                                ragged: (last ? 0 : empty) + tail.ragged)
                            let key = ParagraphRowKey(start: start, rows: remaining)
                            if table[key] == nil || preferred(score, table[key]!.score) { table[key] = node }
                        }
                    }
                }
                guard let best = table[.init(start: segmentStart, rows: targetRows)] else { break }
                allRanges += best.ranges; cuts += Int(best.score[0]); singles += Int(best.score[1])
                short += best.short; ragged += best.ragged; segmentStart = segmentEnd
            }
            if segmentStart == source.length {
                output.append(.init(originalRanges: allRanges, mode: mode, emergencyCuts: cuts,
                    singletonRows: singles, shortLastLines: short, normalizedRaggedness: ragged, completeFrontier: true))
            }
        }
        return (output, true)
    }

    struct CommittedParagraphProgram {
        let originalRanges: [NSRange]
        let mode: String
        let emergencyCuts: Int
        let singletonRows: Int
        let shortLastLines: Int
        let normalizedRaggedness: CGFloat
        let completeFrontier: Bool
    }

    /// Exact original UTF ledger, including spaces, astral code units and hard
    /// breaks. Soft LF is source-empty. Input/card identities never change.
    static func layoutCommittedParagraph(
        text: String, in available: CGSize, style: Style,
        program: CommittedParagraphProgram
    ) -> Layout? {
        guard !style.vertical, !style.preservesBlockRows,
              !style.keepsWholeWords, !style.strictLineBreak,
              style.horizontalWhitespace == .preWrap,
              !text.isEmpty, !program.originalRanges.isEmpty,
              available.width.isFinite, available.height.isFinite,
              available.width > 0, available.height > 0 else { return nil }
        let source = text as NSString, units = Array(text.utf16)
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text {
            let (next, overflow) = offset.addingReportingOverflow(String(character).utf16.count)
            guard !overflow else { return nil }
            offset = next; boundaries.insert(offset)
        }
        guard offset == source.length else { return nil }

        var displayed = "", ownership: [NSRange] = [], expectedRows: [NSRange] = []
        var cursor = 0, displayCursor = 0
        for (index, range) in program.originalRanges.enumerated() {
            guard range.location == cursor, range.length > 0,
                  range.location >= 0, range.location <= source.length,
                  range.length <= source.length - range.location,
                  boundaries.contains(range.location),
                  boundaries.contains(range.location + range.length) else { return nil }
            let end = range.location + range.length
            // A row cannot cross an authored hard break. CRLF remains atomic.
            for position in range.location..<end {
                switch units[position] {
                case 13:
                    let terminator = position + 1 < units.count && units[position + 1] == 10
                        ? position + 2 : position + 1
                    guard terminator == end else { return nil }
                case 10, 11, 12, 0x85, 0x2028, 0x2029:
                    guard position + 1 == end else { return nil }
                default: break
                }
            }
            displayed += source.substring(with: range)
            ownership += (range.location..<end).map { NSRange(location: $0, length: 1) }
            var count = range.length
            let last = units[end - 1]
            let hard = [10, 11, 12, 13, 0x85, 0x2028, 0x2029].contains(last)
            if index + 1 < program.originalRanges.count && !hard {
                displayed += "\n"
                ownership.append(NSRange(location: end, length: 0))
                count += 1
            }
            expectedRows.append(NSRange(location: displayCursor, length: count))
            displayCursor += count; cursor = end
        }
        guard cursor == source.length, ownership.count == displayed.utf16.count else { return nil }
        // Only internal row-flow machinery changes. Face, foreground, stroke,
        // relative outline width, font/pitch/tracking/scale remain caller-owned.
        var paint = style
        paint.horizontalWrapping = .normal
        paint.optimizesKoreanWrapping = false
        paint.balancesHorizontalLines = false
        paint.explicitLineFlow = true
        paint.intrinsicText = text
        let shaped = layout(text: displayed, in: available, style: paint)
        guard shaped.fits, shaped.shapedText.utf16.elementsEqual(displayed.utf16),
              shaped.visibleUTF16Range.location == 0,
              shaped.visibleUTF16Range.length == displayed.utf16.count,
              shaped.lineRanges == expectedRows else { return nil }
        // In particular, never overwrite visibleUTF to original length before
        // proving the entire committed display program really survived native fit.
        return Layout(size: shaped.size, inkBounds: shaped.inkBounds,
            visibleUTF16Range: NSRange(location: 0, length: source.length),
            lineCount: shaped.lineCount, fits: shaped.fits,
            glyphBounds: shaped.glyphBounds, rangeBounds: shaped.rangeBounds,
            lineRanges: shaped.lineRanges, shapedText: shaped.shapedText,
            frame: shaped.frame, frameSize: shaped.frameSize, offset: shaped.offset,
            attributed: shaped.attributed, frameAttributes: shaped.frameAttributes,
            paintScaleX: shaped.paintScaleX, lineOffsets: shaped.lineOffsets,
            committedRowAlignmentWidths: shaped.committedRowAlignmentWidths,
            verticalPaintOffsets: shaped.verticalPaintOffsets,
            blockRowIntrinsicWidths: shaped.blockRowIntrinsicWidths,
            outlineGlow: shaped.outlineGlow, outlineGlowColor: shaped.outlineGlowColor,
            sourceUTF16Ownership: ownership, fromManualWrap: true)
    }
}


extension NativeTranslationTypography {
    static func committedParagraphCandidates(text: String, in size: CGSize, style: Style,
        reference: Layout, utf16Work: inout Int, geometryWork: inout Int)
        -> (baseline: Layout, layouts: [Layout], complete: Bool) {
        let inputWork = text.utf16.count
        guard inputWork <= utf16Work, reference.lineCount >= 0,
              reference.lineCount <= geometryWork else { return (reference, [], false) }
        utf16Work -= inputWork; geometryWork -= reference.lineCount
        guard committedParagraphRawComplete(reference, original: text) else { return (reference, [], false) }
        guard reference.visibleUTF16Range == NSRange(location: 0, length: text.utf16.count),
              let before = horizontalRowMetrics(layout: reference, originalText: text),
              before.allSatisfy({ $0["tokenCutAfterRowProxy"] is Bool }) else { return (reference, [], false) }
        let beforeCuts = before.filter { $0["tokenCutAfterRowProxy"] as? Bool == true }.count
        let beforeSingles = before.filter { $0["singleHangulLetterRow"] as? Bool == true }.count
        let frontier = committedParagraphFrontier(text: text, width: size.width, style: style,
            utf16Work: &utf16Work, geometryWork: &geometryWork, referenceLayout: reference)
        guard frontier.complete else { return (reference, [], false) }
        var result: [Layout] = []
        for program in frontier.programs {
            let reservation = text.utf16.count.addingReportingOverflow(program.originalRanges.count)
            guard !reservation.overflow, reservation.partialValue <= utf16Work,
                  geometryWork > 0 else { return (reference, [], false) }
            utf16Work -= reservation.partialValue; geometryWork -= 1
            guard let candidate = layoutCommittedParagraph(text: text, in: size, style: style, program: program),
                  committedParagraphRawComplete(candidate, original: text),
                  let rows = horizontalRowMetrics(layout: candidate, originalText: text),
                  rows.allSatisfy({ $0["tokenCutAfterRowProxy"] is Bool }),
                  rows.filter({ $0["tokenCutAfterRowProxy"] as? Bool == true }).count <= beforeCuts,
                  rows.filter({ $0["singleHangulLetterRow"] as? Bool == true }).count <= beforeSingles else { continue }
            let shapedGuardUnits = reference.shapedText.utf16.count.addingReportingOverflow(candidate.shapedText.utf16.count)
            let guardUnits = shapedGuardUnits.partialValue.addingReportingOverflow(text.utf16.count)
            let guardUTF = guardUnits.partialValue.multipliedReportingOverflow(by: 2)
            let guardRows = reference.lineCount.addingReportingOverflow(candidate.lineCount)
            guard !shapedGuardUnits.overflow, !guardUnits.overflow, !guardUTF.overflow, !guardRows.overflow,
                  guardUTF.partialValue <= utf16Work, guardRows.partialValue <= geometryWork else {
                return (reference, [], false)
            }
            utf16Work -= guardUTF.partialValue; geometryWork -= guardRows.partialValue
            guard NativeParagraphReadabilityGuard.permits(candidate: candidate, baseline: reference,
                original: text, width: size.width, style: style) == true else { continue }
            result.append(candidate)
        }
        return (reference, result, true)
    }

    static func committedParagraphRawComplete(_ l: Layout, original: String) -> Bool {
        guard let frame = l.frame else {
            return original.isEmpty && sourceOwnershipCoverage(l, originalText: original, normalization: .exact)?.whole == true
        }
        let displayed = l.shapedText.utf16.count
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.location == 0, visible.length == displayed else { return false }
        let lines = CTFrameGetLines(frame)
        var cursor = 0
        for i in 0..<CFArrayGetCount(lines) {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, i), to: CTLine.self)
            let r = CTLineGetStringRange(line)
            guard r.location == cursor, r.length >= 0, r.length <= displayed - cursor else { return false }
            cursor += r.length
            let runs = CTLineGetGlyphRuns(line)
            for j in 0..<CFArrayGetCount(runs) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, j), to: CTRun.self)
                let count = CTRunGetGlyphCount(run)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                guard indices.allSatisfy({ $0 >= r.location && $0 < r.location + r.length }) else { return false }
            }
        }
        guard cursor == displayed else { return false }
        return sourceOwnershipCoverage(l, originalText: original, normalization: .exact)?.whole == true
    }
}
// Single value/cursor proof used by diagnostics and completeness gates.
extension NativeTranslationTypography {
    enum SourceOwnershipNormalization { case exact, certifiedASCIISpaceCollapse }
    struct SourceOwnershipCoverage { let whole: Bool }

    static func sourceOwnershipCoverage(_ layout: Layout, originalText: String,
        normalization: SourceOwnershipNormalization? = nil) -> SourceOwnershipCoverage? {
        let source = Array(originalText.utf16), display = Array(layout.shapedText.utf16)
        guard let ledger = layout.sourceUTF16Ownership else {
            return display.elementsEqual(source) ? .init(whole: true) : nil
        }
        guard ledger.count == display.count else { return nil }
        let policy = normalization ?? layout.sourceOwnershipNormalization
        var cursor = 0, whole = true
        for (unit, owner) in zip(display, ledger) {
            guard owner.location >= cursor, owner.location <= source.count,
                  owner.length >= 0, owner.length <= source.count - owner.location else { return nil }
            if owner.length == 0 {
                guard unit == 10 else { return nil }
                if owner.location != cursor {
                    guard policy == .certifiedASCIISpaceCollapse,
                          source[cursor..<owner.location].allSatisfy({ $0 == 32 }) else { return nil }
                    whole = false // Provenance verifies the omission, not full-source coverage.
                }
            } else if owner.length == 1 {
                guard unit == source[owner.location] else { return nil }
                if owner.location != cursor { whole = false }
            } else {
                guard policy == .certifiedASCIISpaceCollapse, unit == 32,
                      source[owner.location..<owner.location + owner.length].allSatisfy({ $0 == 32 }) else { return nil }
                if owner.location != cursor { whole = false }
            }
            cursor = owner.location + owner.length
        }
        return .init(whole: whole && cursor == source.count)
    }
}

/// Additive candidate guard only. A model/heuristic observation, never a GT label.
/// Requires a verified original UTF ledger and exact native row-shaping parity.
enum NativeParagraphReadabilityGuard {
    typealias T = NativeTranslationTypography
    struct Metrics {
        let cuts: Int
        let singletons: Int
        let punctuationOnlyRows: Int
        let lonelyQuoteRows: Int
        let openingAtSoftEnd: Int
        let closingAtSoftStart: Int
        let shortLastRows: Int
        let attachedTerminalSplits: Int
        let punctuationClusterSplits: Int
        let meanNonfinalEmptySquared: Double
        let fills: [Double]
        let actualSoftNonfinalRows: Int
        let actualNonfinalEmptySquaredSum: Double
        func noWorse(than old: Metrics) -> Bool {
            cuts <= old.cuts && singletons <= old.singletons &&
                punctuationOnlyRows <= old.punctuationOnlyRows && lonelyQuoteRows <= old.lonelyQuoteRows &&
                openingAtSoftEnd <= old.openingAtSoftEnd && closingAtSoftStart <= old.closingAtSoftStart &&
                shortLastRows <= old.shortLastRows &&
                attachedTerminalSplits <= old.attachedTerminalSplits &&
                punctuationClusterSplits <= old.punctuationClusterSplits &&
                meanNonfinalEmptySquared <= old.meanNonfinalEmptySquared + 1e-9
        }
    }
    static func opening(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.properties.generalCategory == .openPunctuation ||
            $0.properties.generalCategory == .initialPunctuation }
    }
    static func closing(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.properties.generalCategory == .closePunctuation ||
            $0.properties.generalCategory == .finalPunctuation }
    }
    static func quote(_ c: Character) -> Bool {
        "「」『』“”‘’\"'".contains(c)
    }
    static func observed(layout: T.Layout, original: String, width: CGFloat, style: T.Style, auditWork: ReadabilityAuditBudget? = nil) -> Metrics? {
        if let auditWork, !auditWork.nativeReserved, !auditWork.reserveNative(layout, original: original) { return nil }
        let auditStarted = auditWork?.clock()
        defer { if let auditWork, let auditStarted { auditWork.elapsed("sharedObservedTotal", auditStarted) } }
        guard !style.vertical, width.isFinite, width > 0,
              T.committedParagraphRawComplete(layout, original: original),
              let rows = T.horizontalRowMetrics(layout: layout, originalText: original),
              rows.count == layout.lineCount,
              rows.allSatisfy({ $0["tokenCutAfterRowProxy"] is Bool }) else { return nil }
        let advances = T.lineAdvances(layout: layout)
        let native = auditWork == nil ? T.diagnosticRuns(layout: layout) : []
        guard advances.count == rows.count, auditWork != nil || native.count == rows.count else { return nil }
        let shaped = layout.shapedText as NSString
        let units = Array(original.utf16)
        // Direct source Character boundaries, not translated-string heuristics.
        // This measured whitelist is intentionally not a full UAX #14 claim.
        let terminal = ".,!?…。，！？：；:;"
        var starts: [Int: Character] = [:], ends: [Int: Character] = [:], offset = 0
        for character in original {
            starts[offset] = character
            offset += String(character).utf16.count
            ends[offset] = character
        }
        let typesetter = CTTypesetterCreateWithAttributedString(T.attributedString(text: layout.shapedText, style: style))
        var punct = 0, lonely = 0, openEnd = 0, closeStart = 0, short = 0
        var ragged = 0.0, nonfinal = 0, fills: [Double] = []
        var attached = 0, cluster = 0
        var previousWasSoft = false
        for (index, row) in rows.enumerated() {
            let range = layout.lineRanges[index]
            if let auditWork, !auditWork.takeLine() { return nil }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
            let actualRange = CTLineGetStringRange(line)
            if let auditWork {
                guard actualRange.location == range.location, actualRange.length == range.length,
                      abs(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - advances[index]) <= 1e-9 else { return nil }
                let parityStarted = auditWork.clock()
                auditWork.add("reconstructedLines", 1)
                let runs = CTLineGetGlyphRuns(line)
                let count = CFArrayGetCount(runs)
                guard auditWork.takeRuns(count, factor: 8) else { return nil }
                auditWork.add("reconstructedRuns", count)
                for i in 0..<count {
                    let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, i), to: CTRun.self)
                    let glyphCount = CTRunGetGlyphCount(run)
                    guard auditWork.takeGlyphs(glyphCount) else { return nil }
                    auditWork.add("reconstructedGlyphs", glyphCount)
                }
                guard auditWork.parity(layout, index: index, reconstructed: line) else { return nil }
                auditWork.elapsed("reconstructedNativeParity", parityStarted)
            } else {
                guard actualRange.location == range.location, actualRange.length == range.length,
                      let observedRuns = native[index]["runs"] as? [[String: Any]],
                      abs(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - advances[index]) <= 1e-9 else { return nil }
                let runs = CTLineGetGlyphRuns(line)
                guard observedRuns.count == CFArrayGetCount(runs) else { return nil }
                for j in 0..<CFArrayGetCount(runs) {
                    let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, j), to: CTRun.self)
                    let count = CTRunGetGlyphCount(run)
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    var widths = [CGSize](repeating: .zero, count: count)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                    CTRunGetAdvances(run, CFRange(location: 0, length: 0), &widths)
                    let attrs = CTRunGetAttributes(run) as NSDictionary
                    guard let value = attrs[kCTFontAttributeName],
                          CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { return nil }
                    let font = value as! CTFont, observed = observedRuns[j]
                    guard observed["glyphs"] as? [Int] == glyphs.map(Int.init),
                          observed["positions"] as? [[Double]] == positions.map({ [Double($0.x), Double($0.y)] }),
                          observed["advances"] as? [[Double]] == widths.map({ [Double($0.width), Double($0.height)] }),
                          observed["fontName"] as? String == CTFontCopyPostScriptName(font) as String,
                          observed["fontSize"] as? Double == Double(CTFontGetSize(font)) else { return nil }
                }
            }
            guard let sourceRange = row["sourceUTF16Range"] as? [Int], sourceRange.count == 2,
                  sourceRange[0] >= 0, sourceRange[1] >= 0, sourceRange[0] <= units.count,
                  sourceRange[1] <= units.count - sourceRange[0] else { return nil }
            let end = sourceRange[0] + sourceRange[1]
            let characters = shaped.substring(with: range).filter { !$0.isWhitespace }
            let hard = end > 0 && [10, 11, 12, 13, 0x85, 0x2028, 0x2029].contains(units[end - 1])
            let final = end == units.count || hard
            if !final {
                guard let left = ends[end], let right = starts[end] else { return nil }
                if !left.isWhitespace && !right.isWhitespace && !left.isNewline && !right.isNewline {
                    if terminal.contains(right), left.unicodeScalars.contains(where: {
                        CharacterSet.alphanumerics.contains($0)
                    }) { attached += 1 }
                    if terminal.contains(left) && terminal.contains(right) { cluster += 1 }
                }
            }
            let punctuationOnly = !characters.isEmpty && characters.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0)
            }
            if punctuationOnly { punct += 1 }
            if characters.count == 1, let c = characters.first, quote(c) { lonely += 1 }
            if !final, let last = characters.last, opening(last) { openEnd += 1 }
            if previousWasSoft, let first = characters.first, closing(first) { closeStart += 1 }
            previousWasSoft = !final
            let advance = advances[index], ink = CTLineGetImageBounds(line, nil)
            let supported = characters.isEmpty || ink.isNull || ink.isInfinite
                ? advance : max(advance, ink.maxX) - min(0, ink.minX) + style.outlineWidth
            let fill = Double(supported * style.horizontalScale / width)
            guard fill.isFinite, fill >= 0 else { return nil }
            fills.append(fill)
            if final {
                if !characters.isEmpty && fill < 0.35 { short += 1 }
            } else { ragged += pow(max(0, 1 - fill), 2); nonfinal += 1 }
        }
        return Metrics(cuts: rows.filter { $0["tokenCutAfterRowProxy"] as? Bool == true }.count,
            singletons: rows.filter { $0["singleHangulLetterRow"] as? Bool == true }.count,
            punctuationOnlyRows: punct, lonelyQuoteRows: lonely, openingAtSoftEnd: openEnd,
            closingAtSoftStart: closeStart, shortLastRows: short,
            attachedTerminalSplits: attached, punctuationClusterSplits: cluster,
            meanNonfinalEmptySquared: nonfinal > 0 ? ragged / Double(nonfinal) : 0, fills: fills,
            actualSoftNonfinalRows: nonfinal, actualNonfinalEmptySquaredSum: ragged)
    }
    static func permits(candidate: T.Layout, baseline: T.Layout, original: String,
                        width: CGFloat, style: T.Style) -> Bool? {
        guard let old = observed(layout: baseline, original: original, width: width, style: style),
              let new = observed(layout: candidate, original: original, width: width, style: style)
        else { return nil } // unknown is not success
        return new.noWorse(than: old)
    }
}

/// Audit-only work ledger. Nil work preserves the existing collector path.
final class ReadabilityAuditBudget {
    var utf16 = 1_048_576, rows = 16_384, runs = 32_768, glyphs = 1_048_576
    var lineCreations = 4_096, outputBytes = 1_048_576
    var reason = "unknown-native-parity"

    // Per-observation counters/timing; page admission quotas are never reset.
    var nativeReserved = false
    var counts: [String: Int] = [:]
    var milliseconds: [String: Double] = [:]
    func beginObservation() {
        reason = "unknown-native-parity"; nativeReserved = false
        counts.removeAll(keepingCapacity: true); milliseconds.removeAll(keepingCapacity: true)
    }
    func clock() -> Double { ProcessInfo.processInfo.systemUptime }
    func elapsed(_ name: String, _ start: Double) {
        milliseconds[name, default: 0] += (clock() - start) * 1000
    }
    func add(_ name: String, _ n: Int) { counts[name, default: 0] += n }
    /// Exact legacy parity fields, directly from the real CTFrame, no diagnostic dictionaries.
    func parity(_ layout: NativeTranslationTypography.Layout, index: Int, reconstructed: CTLine) -> Bool {
        guard let frame = layout.frame else { reason = "unknown-no-frame"; return false }
        let lines = CTFrameGetLines(frame)
        guard index >= 0, index < CFArrayGetCount(lines) else { reason = "unknown-line-index"; return false }
        let actual = unsafeBitCast(CFArrayGetValueAtIndex(lines, index), to: CTLine.self)
        let aa = CTLineGetGlyphRuns(actual), bb = CTLineGetGlyphRuns(reconstructed)
        guard CFArrayGetCount(aa) == CFArrayGetCount(bb) else { reason = "unknown-run-parity"; return false }
        for j in 0..<CFArrayGetCount(aa) {
            let a = unsafeBitCast(CFArrayGetValueAtIndex(aa, j), to: CTRun.self)
            let b = unsafeBitCast(CFArrayGetValueAtIndex(bb, j), to: CTRun.self)
            let n = CTRunGetGlyphCount(a)
            guard n == CTRunGetGlyphCount(b) else { reason = "unknown-glyph-count-parity"; return false }
            guard takeGlyphs(n, factor: 9) else { return false }
            let aAttrs = CTRunGetAttributes(a) as NSDictionary, bAttrs = CTRunGetAttributes(b) as NSDictionary
            guard let av = aAttrs[kCTFontAttributeName], let bv = bAttrs[kCTFontAttributeName],
                CFGetTypeID(av as CFTypeRef) == CTFontGetTypeID(),
                CFGetTypeID(bv as CFTypeRef) == CTFontGetTypeID() else { reason = "unknown-run-font"; return false }
            let af = av as! CTFont, bf = bv as! CTFont
            let range = CTRunGetStringRange(a), length = layout.shapedText.utf16.count
            guard range.location >= 0, range.length >= 0, range.location <= length,
                range.length <= length - range.location else { reason = "unknown-native-run-range"; return false }
            let matrix = CTRunGetTextMatrix(a)
            guard [CTFontGetSize(af), CTFontGetAscent(af), CTFontGetDescent(af), CTFontGetLeading(af),
                matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].allSatisfy(\.isFinite)
                else { reason = "unknown-native-run-nonfinite"; return false }
            guard CTFontCopyPostScriptName(af) as String == CTFontCopyPostScriptName(bf) as String,
                CTFontGetSize(af) == CTFontGetSize(bf) else { reason = "unknown-font-parity"; return false }
            var ag = [CGGlyph](repeating: 0, count: n), bg = ag
            var ap = [CGPoint](repeating: .zero, count: n), bp = ap
            var ad = [CGSize](repeating: .zero, count: n), bd = ad
            let all = CFRange(location: 0, length: 0)
            CTRunGetGlyphs(a, all, &ag); CTRunGetGlyphs(b, all, &bg)
            CTRunGetPositions(a, all, &ap); CTRunGetPositions(b, all, &bp)
            CTRunGetAdvances(a, all, &ad); CTRunGetAdvances(b, all, &bd)
            var vertical = [CGSize](repeating: .zero, count: n)
            CTFontGetVerticalTranslationsForGlyphs(af, &ag, &vertical, n)
            add("parityArraySlots", n * 7)
            guard vertical.allSatisfy({ $0.width.isFinite && $0.height.isFinite })
                else { reason = "unknown-native-vertical-translation-nonfinite"; return false }
            guard ag == bg, ap == bp, ad == bd else { reason = "unknown-glyph-position-advance-parity"; return false }
        }
        return true
    }
    var exhaustionReason: String? = nil
    func take(_ remaining: inout Int, _ n: Int, _ factor: Int, _ label: String) -> Bool {
        let v = n.multipliedReportingOverflow(by: factor)
        guard n >= 0, factor >= 0, !v.overflow, v.partialValue <= remaining else {
            reason = "budget-" + label; exhaustionReason = reason; return false
        }
        remaining -= v.partialValue; return true
    }
    func takeUTF(_ n: Int, factor: Int = 1) -> Bool { take(&utf16, n, factor, "utf16") }
    func takeRows(_ n: Int, factor: Int = 1) -> Bool { take(&rows, n, factor, "rows") }
    func takeRuns(_ n: Int, factor: Int = 1) -> Bool { take(&runs, n, factor, "runs") }
    func takeGlyphs(_ n: Int, factor: Int = 1) -> Bool { take(&glyphs, n, factor, "glyphs") }
    func takeLine() -> Bool { take(&lineCreations, 1, 1, "line-creations") }
    func reserveOutput(id: String, stage: String) -> Bool {
        guard take(&outputBytes, 4_096, 1, "output") else { return false }
        for _ in id.utf8 { guard take(&outputBytes, 1, 6, "output") else { return false } }
        for _ in stage.utf8 { guard take(&outputBytes, 1, 6, "output") else { return false } }
        return true // fixed scalar schema below; no row-fill or retained Card arrays
    }
    func reserveNative(_ layout: NativeTranslationTypography.Layout, original: String) -> Bool {
        var source = 0, shaped = 0
        for _ in original.utf16 { guard takeUTF(1) else { return false }; source += 1 }
        for _ in layout.shapedText.utf16 { guard takeUTF(1) else { return false }; shaped += 1 }
        if let ledger = layout.sourceUTF16Ownership, ledger.count != shaped {
            reason = "unknown-malformed-ledger"; return false
        }
        guard let frame = layout.frame else { reason = "unknown-no-frame"; return false }
        guard [layout.frameSize.width, layout.frameSize.height, layout.offset.x, layout.offset.y,
            layout.paintScaleX].allSatisfy(\.isFinite)
            else { reason = "unknown-native-layout-nonfinite"; return false }
        let lines = CTFrameGetLines(frame), count = CFArrayGetCount(lines)
        guard count == layout.lineRanges.count, takeRows(count, factor: 32) else { return false }
        add("actualFrameRows", count); add("sourceUTF16", source); add("shapedUTF16", shaped)
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        guard origins.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
            layout.lineOffsets.prefix(count).allSatisfy({ $0.x.isFinite && $0.y.isFinite })
            else { reason = "unknown-native-origin-nonfinite"; return false }
        let total = source.addingReportingOverflow(shaped)
        let factor = count.multipliedReportingOverflow(by: 32)
        guard !total.overflow, !factor.overflow,
              takeUTF(total.partialValue, factor: max(32, factor.partialValue)) else { return false }
        for i in 0..<count {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(lines, i), to: CTLine.self)
            let runs = CTLineGetGlyphRuns(line), count = CFArrayGetCount(runs)
            guard takeRuns(count, factor: 32) else { return false }
            add("actualFrameRuns", count)
            for j in 0..<count {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, j), to: CTRun.self)
                let glyphCount = CTRunGetGlyphCount(run)
                guard takeGlyphs(glyphCount, factor: 32) else { return false }
                add("actualFrameGlyphs", glyphCount)
                add("nonIdentityRunMatrix", CTRunGetTextMatrix(run).isIdentity ? 0 : 1)
                add("runStatusNonZero", CTRunGetStatus(run).rawValue == 0 ? 0 : 1)
            }
        }
        nativeReserved = true
        return true
    }
}


/// Scalar-only actual Card observer. Horizontal logical-row axes, not transformed page ink/GT.
extension NativeParagraphReadabilityGuard {
    static func auditObservation(_ card: NativeTranslationRenderer.Card, stage: String,
                                 work: ReadabilityAuditBudget) -> [String: Any]? {
        work.beginObservation()
        let started = work.clock()
        guard work.reserveOutput(id: card.item.id, stage: stage) else { return nil }
        var record: [String: Any] = ["cardID": card.item.id, "stage": stage,
            "authority": "actual-native-currentstyle-not-original-GT", "originalGT": NSNull(),
            "metrics": NSNull(), "status": "unknown",
            "measurementDefinition": "legacy-horizontal-logical-row-nativeguard-width-normalized",
            "styleRoot": ["itemVertical": card.item.vertical, "styleVertical": card.style.vertical,
                "rotated": card.effectiveTextRotation != 0, "unitParts": !card.unitTextParts.isEmpty,
                "heavyStroke": card.heavyStrokeWidth != 0, "glow": card.style.outlineGlow != 0]]
        let prechargeStarted = work.clock()
        let original = card.item.typesettingText ?? card.item.text
        let native = work.reserveNative(card.typography, original: original)
        work.elapsed("nativePrecharge", prechargeStarted)
        defer { work.nativeReserved = false }
        func finish(_ reason: String? = nil) -> [String: Any] {
            if let reason { record["reason"] = reason }
            work.elapsed("total", started)
            record["nativeWorkCounts"] = work.counts
            record["observerMilliseconds"] = work.milliseconds
            return record
        }
        guard native else { return finish(work.reason) }
        guard card.effectiveTextRotation.isFinite, card.heavyStrokeWidth.isFinite,
            card.style.outlineGlow.isFinite else { return finish("unknown-nonfinite-style") }
        if card.item.vertical || card.style.vertical {
            record["status"] = "unsupported"; return finish("unsupported-vertical-horizontal-definition")
        }
        if !card.unitTextParts.isEmpty {
            record["status"] = "unsupported"; return finish("unsupported-unit-parts-painter-relayout")
        }
        guard let m = observed(layout: card.typography, original: original,
            width: card.item.contentRect.width, style: card.style, auditWork: work) else { return finish(work.reason) }
        record["status"] = "observed"
        record["actualRowCount"] = m.fills.count
        record["actualSoftNonfinalRows"] = m.actualSoftNonfinalRows
        record["actualNonfinalEmptySquaredSum"] = m.actualNonfinalEmptySquaredSum
        record["metrics"] = ["cuts": m.cuts, "singletons": m.singletons,
            "punctuationOnlyRows": m.punctuationOnlyRows, "lonelyQuoteRows": m.lonelyQuoteRows,
            "openingAtSoftEnd": m.openingAtSoftEnd, "closingAtSoftStart": m.closingAtSoftStart,
            "shortLastRows": m.shortLastRows, "attachedTerminalSplits": m.attachedTerminalSplits,
            "punctuationClusterSplits": m.punctuationClusterSplits,
            "meanNonfinalEmptySquared": m.meanNonfinalEmptySquared]
        return finish()
    }
}

extension NativeTranslationTypography {
    private struct ScopedHorizontalPaintGeometry {
        let frame: CTFrame, size: CGSize, scaleX: CGFloat, source: String, text: String, style: Style
        let origins: [CGPoint], advances: [CGFloat], ranges: [CFRange]
        let naturalWidth: CGFloat, minimumContent: CGFloat, ascent: CGFloat, descent: CGFloat
        static func sameNumber(_ a: CGFloat,_ b: CGFloat) -> Bool { Double(a).bitPattern == Double(b).bitPattern }
        static func sameUTF(_ a: String?, _ b: String?) -> Bool {
            switch (a,b) { case (nil,nil): return true; case let (a?,b?): return a.utf16.elementsEqual(b.utf16); default: return false }
        }
        static func sameStyle(_ a: Style,_ b: Style) -> Bool {
            return sameUTF(a.fontName, b.fontName) &&
                a.fontScript.utf16.elementsEqual(b.fontScript.utf16) &&
                a.prefersDominantKoreanScript == b.prefersDominantKoreanScript &&
                Double(a.fontSize).bitPattern == Double(b.fontSize).bitPattern &&
                a.bold == b.bold &&
                a.vertical == b.vertical &&
                ObjectIdentifier(a.foreground) == ObjectIdentifier(b.foreground) &&
                a.outline.map(ObjectIdentifier.init) == b.outline.map(ObjectIdentifier.init) &&
                Double(a.outlineWidth).bitPattern == Double(b.outlineWidth).bitPattern &&
                a.outlinePaintOrder == b.outlinePaintOrder &&
                Double(a.tracking).bitPattern == Double(b.tracking).bitPattern &&
                a.trackingScalesWithFont == b.trackingScalesWithFont &&
                Double(a.lineHeight).bitPattern == Double(b.lineHeight).bitPattern &&
                a.optimizesKoreanWrapping == b.optimizesKoreanWrapping &&
                a.koreanQuoteMode == b.koreanQuoteMode &&
                a.alignsToTop == b.alignsToTop &&
                Double(a.horizontalScale).bitPattern == Double(b.horizontalScale).bitPattern &&
                a.balancesHorizontalLines == b.balancesHorizontalLines &&
                a.keepsWholeWords == b.keepsWholeWords &&
                a.horizontalWrapping == b.horizontalWrapping &&
                a.horizontalWhitespace == b.horizontalWhitespace &&
                a.explicitLineFlow == b.explicitLineFlow &&
                a.wholeWordFallbackResolved == b.wholeWordFallbackResolved &&
                a.usesKeepAllInlineItemWidths == b.usesKeepAllInlineItemWidths &&
                a.keepAllParagraphEndRows == b.keepAllParagraphEndRows &&
                a.usesBlockWordLayout == b.usesBlockWordLayout &&
                a.usesPreformattedBlockRows == b.usesPreformattedBlockRows &&
                a.preservesBlockRows == b.preservesBlockRows &&
                a.blockWordLayoutUsesTopPadding == b.blockWordLayoutUsesTopPadding &&
                a.horizontalAlignment == b.horizontalAlignment &&
                a.blockRowHorizontalAlignment == b.blockRowHorizontalAlignment &&
                Double(a.outlineGlow).bitPattern == Double(b.outlineGlow).bitPattern &&
                a.strictLineBreak == b.strictLineBreak &&
                a.balancesExplicitParagraphs == b.balancesExplicitParagraphs &&
                sameUTF(a.intrinsicText, b.intrinsicText) &&
                a.intrinsicMinimumContentWidth.map { Double($0).bitPattern } == b.intrinsicMinimumContentWidth.map { Double($0).bitPattern } &&
                a.paintsVisibleFormFeeds == b.paintsVisibleFormFeeds
        }
        func matches(frame: CTFrame,size: CGSize,scaleX: CGFloat,source: String,text: String,style: Style,count: Int) -> Bool {
            !Task.isCancelled && self.frame === frame &&
            Self.sameNumber(self.size.width,size.width) && Self.sameNumber(self.size.height,size.height) &&
            Self.sameNumber(self.scaleX,scaleX) &&
            !style.vertical && size.width.isFinite && size.height.isFinite && scaleX.isFinite &&
            self.source.utf16.elementsEqual(source.utf16) && self.text.utf16.elementsEqual(text.utf16) &&
            Self.sameStyle(self.style,style) && origins.count == count && advances.count == count && ranges.count == count
        }
    }
}
