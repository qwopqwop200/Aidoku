// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation
import CoreGraphics
import UIKit

/// Immutable, versioned native layout. Coordinates are points in the supplied viewport;
/// source geometry arrays remain normalized to the original image, like OCR descriptors.
struct NativeTranslationLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let imageSize: CGSize
    let sourceRect: CGRect
    let viewport: CGSize
    let items: [NativeTranslationLayoutItem]
    let readableRecoveryRemaining: Int?
    let sourceObjectFit: String?

    private enum CodingKeys: String, CodingKey { case version, imageSize, sourceRect, viewport, items, readableRecoveryRemaining, sourceObjectFit }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        imageSize = try values.decode(CGSize.self, forKey: .imageSize)
        sourceRect = try values.decode(CGRect.self, forKey: .sourceRect)
        viewport = try values.decode(CGSize.self, forKey: .viewport)
        items = try values.decode([NativeTranslationLayoutItem].self, forKey: .items)
        readableRecoveryRemaining = try values.decodeIfPresent(Int.self, forKey: .readableRecoveryRemaining)
        sourceObjectFit = try values.decodeIfPresent(String.self, forKey: .sourceObjectFit)
        guard version == Self.currentVersion,
              sourceObjectFit == nil || ["fill", "contain", "cover"].contains(sourceObjectFit!),
              NativeTranslationLayoutPlanner.validGeometry(imageSize: imageSize, sourceRect: sourceRect, viewport: viewport)
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid native layout version or geometry")) }
    }

    init(imageSize: CGSize, sourceRect: CGRect, viewport: CGSize, items: [NativeTranslationLayoutItem],
         readableRecoveryRemaining: Int? = nil, sourceObjectFit: String? = nil) {
        version = Self.currentVersion
        self.imageSize = imageSize
        self.sourceRect = sourceRect
        self.viewport = viewport
        self.items = items
        self.readableRecoveryRemaining = readableRecoveryRemaining
        self.sourceObjectFit = sourceObjectFit
    }
}

struct NativeTranslationBalloonInterior: Codable, Equatable, Sendable {
    let rect: [CGFloat]
    let center: [CGFloat]
    let spans: [Double]
    let contourVerified: Bool

    var normalizedRect: CGRect {
        guard rect.count == 4 else { return .zero }
        return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
    }
}

struct NativeTranslationBalloonUnit: Codable, Equatable, Sendable {
    let members: [String]
    let order: Int
    let interior: NativeTranslationBalloonInterior
}

struct NativeTranslationLayoutAlternative: Codable, Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let paddingTop: CGFloat
    let paddingRight: CGFloat
    let paddingBottom: CGFloat
    let paddingLeft: CGFloat
    let inspectionHeight: CGFloat?
    let balancedColumn: Bool?
    let allowsAutomaticFontRecovery: Bool?

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var contentInsets: UIEdgeInsets {
        UIEdgeInsets(top: paddingTop, left: paddingLeft, bottom: paddingBottom, right: paddingRight)
    }
}

struct NativeTranslationSmallTextReference: Codable, Equatable, Sendable {
    let fontSize: CGFloat
    let additionalLines: Int
    let allowsEmergencyWordBreak: Bool
    let fallbackFontSize: CGFloat
    let fallbackPadding: [CGFloat]
    let exclusionRects: [[CGFloat]]
    let padding: [CGFloat]
    let paragraphRecovery: Bool?
}

/// A card's complete Swift planner output. Kept source lettering has no text card;
/// decoding defaults only those absent fields, while retaining its protected geometry.
struct NativeTranslationLayoutItem: Codable, Equatable, Sendable {
    let id: String
    let text: String
    var typesettingText: String?
    var typesettingQuoteMode: Int?
    var typesettingWidthScale: CGFloat?
    var typesettingForeground: [Double]?
    var typesettingOutlineRGB: [Double]?
    var typesettingOutlineWidth: CGFloat?
    var typesettingStrictLineBreak: Bool?
    var typesettingBlockDisplay: Bool?
    var typesettingPreservedBlockWrapper: Bool?
    var typesettingDisplayGrowth: String?
    var typesettingPreformattedRows: Bool?
    var inlineKoreanRepairResolved: Bool?
    var unitPlannedCard: [CGFloat]?
    var captionFixedBoxReflowDisabled: Bool?
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var paddingTop: CGFloat { didSet { cssPaddingTop = paddingTop } }
    var paddingRight: CGFloat
    var paddingBottom: CGFloat { didSet { cssPaddingBottom = paddingBottom } }
    var paddingLeft: CGFloat
    // Runtime CSS declarations accompany the used box. Explicit assignments
    // replace them, even when the new value equals the previous used value.
    // Prepared-layout persistence stores the unrefined input, before this
    // physical LayoutUnit conversion; these fields are not part of that format.
    private(set) var cssPaddingTop: CGFloat = 0
    private(set) var cssPaddingBottom: CGFloat = 0

    mutating func preservePaddingDeclarations(from item: NativeTranslationLayoutItem) {
        cssPaddingTop = item.cssPaddingTop
        cssPaddingBottom = item.cssPaddingBottom
    }
    var rotation: CGFloat
    let vertical: Bool
    let clipsText: Bool
    let keptLettering: Bool
    let sourceTextOnly: Bool
    let sourceVertical: Bool
    let sourceSingleColumn: Bool
    let fontScript: String
    let wrappingScript: String
    let lightSurface: Bool
    let sourceColorEligible: Bool
    let sourcePanelRestorationEligible: Bool
    let sourceCleanupLexical: Bool
    let sourceCleanup: Bool
    let sourceRubyEligible: Bool
    let recoveredLine: Bool
    var allowsAutomaticFontRecovery: Bool
    let uprightQuadText: Bool
    let sourceBounds: [CGFloat]
    let sourcePolygon: [[CGFloat]]
    let auxiliaryInkRects: [[CGFloat]]
    let auxiliaryInkPolygons: [[[CGFloat]]]
    let unitMemberRects: [[CGFloat]]
    let sourceFrame: [CGFloat]
    let sourceFontSize: CGFloat?
    let sourceLettering: String?
    let sourceQuad: [CGFloat]?
    let rotationPlannedFontSize: CGFloat?
    let nearUprightRotation: CGFloat?
    let uprightAlternative: NativeTranslationLayoutAlternative?
    let columnLayout: NativeTranslationLayoutAlternative?
    var smallTextReference: NativeTranslationSmallTextReference?
    let balloonInterior: NativeTranslationBalloonInterior?
    let balloonUnit: NativeTranslationBalloonUnit?
    var balancedColumn: Bool
    var sourceErasureRGB: [CGFloat]?
    var drawsUprightQuadText: Bool
    var smallTextReferenceResolved: Bool

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var contentInsets: UIEdgeInsets {
        UIEdgeInsets(top: paddingTop, left: paddingLeft, bottom: paddingBottom, right: paddingRight)
    }
    var contentRect: CGRect { rect.inset(by: contentInsets) }
    var usesBalancedColumn: Bool { balancedColumn }

    /// Legacy descriptor view for algorithms being ported from the browser renderer.
    /// Native rendering never evaluates this descriptor as JavaScript.
    var payload: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func sourceRect(in imageSize: CGSize) -> CGRect {
        guard sourceBounds.count == 4 else { return .zero }
        return CGRect(x: sourceBounds[0] * imageSize.width, y: sourceBounds[1] * imageSize.height,
                      width: sourceBounds[2] * imageSize.width, height: sourceBounds[3] * imageSize.height)
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, typesettingText, typesettingQuoteMode, typesettingWidthScale, typesettingForeground, typesettingOutlineRGB, typesettingOutlineWidth, typesettingStrictLineBreak, inlineKoreanRepairResolved, x, y
        case width, height, fontSize, lineHeight, unitPlannedCard, captionFixedBoxReflowDisabled, typesettingBlockDisplay, typesettingPreservedBlockWrapper, typesettingPreformattedRows, typesettingDisplayGrowth
        case paddingTop, paddingRight, paddingBottom, paddingLeft
        case rotation, vertical, clipsText, keptLettering
        case sourceTextOnly, sourceVertical, sourceSingleColumn, fontScript
        case wrappingScript, lightSurface, sourceColorEligible, sourcePanelRestorationEligible
        case sourceCleanupLexical, sourceCleanup, sourceRubyEligible, recoveredLine
        case allowsAutomaticFontRecovery, uprightQuadText, sourceBounds, sourcePolygon
        case auxiliaryInkRects, auxiliaryInkPolygons, unitMemberRects, sourceFrame
        case sourceFontSize, sourceLettering, sourceQuad, rotationPlannedFontSize
        case nearUprightRotation, uprightAlternative, columnLayout, smallTextReference
        case balloonInterior, balloonUnit, balancedColumn, sourceErasureRGB, drawsUprightQuadText, smallTextReferenceResolved
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        typesettingText = try values.decodeIfPresent(String.self, forKey: .typesettingText)
        typesettingQuoteMode = try values.decodeIfPresent(Int.self, forKey: .typesettingQuoteMode)
        typesettingBlockDisplay = try values.decodeIfPresent(Bool.self, forKey: .typesettingBlockDisplay)
        typesettingPreservedBlockWrapper = try values.decodeIfPresent(Bool.self, forKey: .typesettingPreservedBlockWrapper)
        typesettingDisplayGrowth = try values.decodeIfPresent(String.self, forKey: .typesettingDisplayGrowth)
        typesettingPreformattedRows = try values.decodeIfPresent(Bool.self, forKey: .typesettingPreformattedRows)
        typesettingWidthScale = try values.decodeIfPresent(CGFloat.self, forKey: .typesettingWidthScale)
        typesettingForeground = try values.decodeIfPresent([Double].self, forKey: .typesettingForeground)
        typesettingOutlineRGB = try values.decodeIfPresent([Double].self, forKey: .typesettingOutlineRGB)
        typesettingOutlineWidth = try values.decodeIfPresent(CGFloat.self, forKey: .typesettingOutlineWidth)
        typesettingStrictLineBreak = try values.decodeIfPresent(Bool.self, forKey: .typesettingStrictLineBreak)
        inlineKoreanRepairResolved = try values.decodeIfPresent(Bool.self, forKey: .inlineKoreanRepairResolved)
        unitPlannedCard = try values.decodeIfPresent([CGFloat].self, forKey: .unitPlannedCard)
        captionFixedBoxReflowDisabled = try values.decodeIfPresent(Bool.self, forKey: .captionFixedBoxReflowDisabled)
        x = try values.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        y = try values.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        width = try values.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0
        height = try values.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0
        fontSize = try values.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 0
        lineHeight = try values.decodeIfPresent(CGFloat.self, forKey: .lineHeight) ?? 0
        paddingTop = try values.decodeIfPresent(CGFloat.self, forKey: .paddingTop) ?? 0
        paddingRight = try values.decodeIfPresent(CGFloat.self, forKey: .paddingRight) ?? 0
        paddingBottom = try values.decodeIfPresent(CGFloat.self, forKey: .paddingBottom) ?? 0
        paddingLeft = try values.decodeIfPresent(CGFloat.self, forKey: .paddingLeft) ?? 0
        rotation = try values.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        vertical = try values.decodeIfPresent(Bool.self, forKey: .vertical) ?? false
        clipsText = try values.decodeIfPresent(Bool.self, forKey: .clipsText) ?? true
        keptLettering = try values.decodeIfPresent(Bool.self, forKey: .keptLettering) ?? false
        sourceTextOnly = try values.decodeIfPresent(Bool.self, forKey: .sourceTextOnly) ?? true
        sourceVertical = try values.decodeIfPresent(Bool.self, forKey: .sourceVertical) ?? false
        sourceSingleColumn = try values.decodeIfPresent(Bool.self, forKey: .sourceSingleColumn) ?? false
        fontScript = try values.decodeIfPresent(String.self, forKey: .fontScript) ?? "latin"
        wrappingScript = try values.decodeIfPresent(String.self, forKey: .wrappingScript) ?? "latin"
        lightSurface = try values.decodeIfPresent(Bool.self, forKey: .lightSurface) ?? true
        sourceColorEligible = try values.decodeIfPresent(Bool.self, forKey: .sourceColorEligible) ?? false
        sourcePanelRestorationEligible = try values.decodeIfPresent(Bool.self, forKey: .sourcePanelRestorationEligible) ?? false
        sourceCleanupLexical = try values.decodeIfPresent(Bool.self, forKey: .sourceCleanupLexical) ?? false
        sourceCleanup = try values.decodeIfPresent(Bool.self, forKey: .sourceCleanup) ?? false
        sourceRubyEligible = try values.decodeIfPresent(Bool.self, forKey: .sourceRubyEligible) ?? false
        recoveredLine = try values.decodeIfPresent(Bool.self, forKey: .recoveredLine) ?? false
        allowsAutomaticFontRecovery = try values.decodeIfPresent(Bool.self, forKey: .allowsAutomaticFontRecovery) ?? false
        uprightQuadText = try values.decodeIfPresent(Bool.self, forKey: .uprightQuadText) ?? false
        sourceBounds = try values.decode([CGFloat].self, forKey: .sourceBounds)
        sourcePolygon = try values.decodeIfPresent([[CGFloat]].self, forKey: .sourcePolygon) ?? []
        auxiliaryInkRects = try values.decodeIfPresent([[CGFloat]].self, forKey: .auxiliaryInkRects) ?? []
        auxiliaryInkPolygons = try values.decodeIfPresent([[[CGFloat]]].self, forKey: .auxiliaryInkPolygons) ?? []
        unitMemberRects = try values.decodeIfPresent([[CGFloat]].self, forKey: .unitMemberRects) ?? []
        sourceFrame = try values.decode([CGFloat].self, forKey: .sourceFrame)
        sourceFontSize = try values.decodeIfPresent(CGFloat.self, forKey: .sourceFontSize)
        sourceLettering = try values.decodeIfPresent(String.self, forKey: .sourceLettering)
        sourceQuad = try values.decodeIfPresent([CGFloat].self, forKey: .sourceQuad)
        rotationPlannedFontSize = try values.decodeIfPresent(CGFloat.self, forKey: .rotationPlannedFontSize)
        nearUprightRotation = try values.decodeIfPresent(CGFloat.self, forKey: .nearUprightRotation)
        uprightAlternative = try values.decodeIfPresent(NativeTranslationLayoutAlternative.self, forKey: .uprightAlternative)
        columnLayout = try values.decodeIfPresent(NativeTranslationLayoutAlternative.self, forKey: .columnLayout)
        smallTextReference = try values.decodeIfPresent(NativeTranslationSmallTextReference.self, forKey: .smallTextReference)
        balloonInterior = try values.decodeIfPresent(NativeTranslationBalloonInterior.self, forKey: .balloonInterior)
        balloonUnit = try values.decodeIfPresent(NativeTranslationBalloonUnit.self, forKey: .balloonUnit)
        balancedColumn = try values.decodeIfPresent(Bool.self, forKey: .balancedColumn) ?? false
        sourceErasureRGB = try values.decodeIfPresent([CGFloat].self, forKey: .sourceErasureRGB)
        drawsUprightQuadText = try values.decodeIfPresent(Bool.self, forKey: .drawsUprightQuadText) ?? false
        smallTextReferenceResolved = try values.decodeIfPresent(Bool.self, forKey: .smallTextReferenceResolved) ?? false
        cssPaddingTop = paddingTop
        cssPaddingBottom = paddingBottom
        guard !id.isEmpty, sourceBounds.count == 4, sourceFrame.count == 4,
              sourceBounds.allSatisfy(\.isFinite), sourceFrame.allSatisfy(\.isFinite),
              sourceBounds[2] > 0, sourceBounds[3] > 0, sourceFrame[2] > 0, sourceFrame[3] > 0,
              keptLettering || (width > 0 && height > 0 && fontSize > 0 && lineHeight > 0 &&
                [x, y, width, height, fontSize, lineHeight, rotation].allSatisfy(\.isFinite))
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid native card geometry")) }
    }
}

/// Actor confinement keeps exact text measurements reusable without passing UIKit objects
/// between tasks. The browser compatibility payload and native image renderer share one planner.
private actor NativeTranslationLayoutWorker {
    static let shared = NativeTranslationLayoutWorker()
    private let measurementCache = BrowserOverlayTextMeasurementCache()

    func data(items: [BrowserOverlayItem], imageSize: CGSize, sourceRect: CGRect,
              settings: IPhoneOverlaySettings, targetLanguage: String, viewport: CGSize) throws -> Data {
        try Task.checkCancellation()
        return try autoreleasepool {
            let layout = try NativeTranslationLayoutPlanner.plan(
                items: items, imageSize: imageSize, sourceRect: sourceRect, settings: settings,
                targetLanguage: targetLanguage, viewport: viewport, measurementCache: measurementCache)
            try Task.checkCancellation()
            return try JSONEncoder().encode(layout)
        }
    }
}

/// The production Swift geometry planner: no DOM, JavaScript evaluation, or WebKit startup.
/// Image-dependent restoration and final native text fitting consume this immutable plan.
enum NativeTranslationLayoutPlanner {
    enum Failure: Error { case invalidGeometry }

    static func validGeometry(imageSize: CGSize, sourceRect: CGRect, viewport: CGSize) -> Bool {
        imageSize.width > 0 && imageSize.height > 0 && sourceRect.width > 0 && sourceRect.height > 0 &&
            viewport.width > 0 && viewport.height > 0 &&
            [imageSize.width, imageSize.height, sourceRect.minX, sourceRect.minY, sourceRect.width,
             sourceRect.height, viewport.width, viewport.height].allSatisfy(\.isFinite)
    }

    static func prepareLayoutData(items: [BrowserOverlayItem], imageSize: CGSize, sourceRect: CGRect,
                                  settings: IPhoneOverlaySettings, targetLanguage: String, viewport: CGSize) async throws -> Data {
        try await NativeTranslationLayoutWorker.shared.data(items: items, imageSize: imageSize, sourceRect: sourceRect,
                                                           settings: settings, targetLanguage: targetLanguage, viewport: viewport)
    }

    static func plan(items: [BrowserOverlayItem], imageSize: CGSize, sourceRect: CGRect,
                     settings: IPhoneOverlaySettings, targetLanguage: String, viewport: CGSize,
                     measurementCache: BrowserOverlayTextMeasurementCache? = BrowserOverlayTextMeasurementCache()) throws -> NativeTranslationLayout {
        try Task.checkCancellation()
        guard validGeometry(imageSize: imageSize, sourceRect: sourceRect, viewport: viewport) else { throw Failure.invalidGeometry }
        let cards = payload(items: items, imageSize: imageSize, sourceRect: sourceRect, settings: settings,
                            targetLanguage: targetLanguage, viewport: viewport, measurementCache: measurementCache)
        try Task.checkCancellation()
        // Convert the compatibility descriptor once at the worker boundary. Both renderers
        // consume exactly the same planned geometry; the stored native format is typed/versioned.
        let data = try JSONSerialization.data(withJSONObject: cards)
        let decoded = try JSONDecoder().decode([NativeTranslationLayoutItem].self, from: data)
        return NativeTranslationLayout(imageSize: imageSize, sourceRect: sourceRect, viewport: viewport, items: decoded)
    }

    /// Resolve source-sensitive early columns, upright alternatives and reference fitting.
    /// The renderer commits coordinated balloon units after final caption packing and alignment.
    static func refining(layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
                         settings: IPhoneOverlaySettings, sourceImage: CGImage? = nil,
                         lockedIDs: Set<String> = []) throws -> NativeTranslationLayout {
        try Task.checkCancellation()
        var cards = layout.items
        if let sourceImage, let surfaces = try inspectedColumnSurfaces(cards: cards, frame: layout.sourceRect, image: sourceImage) {
            for index in cards.indices {
                guard !lockedIDs.contains(cards[index].id), let column = cards[index].columnLayout, let color = surfaces[cards[index].id] else { continue }
                cards[index] = applying(column, to: cards[index])
                cards[index].balancedColumn = true
                cards[index].sourceErasureRGB = color
                cards[index].smallTextReference = nil
            }
        }
        var referenceBudget = NativeReferenceRecoveryBudget(references: cards.map { item in
            .init(length: item.text.utf16.count, fontSize: item.smallTextReference.map { Double($0.fontSize) },
                  paddingIsValid: item.smallTextReference.map { $0.padding.count == 4 && $0.padding.allSatisfy(\.isFinite) } ?? false)
        }, readableRemaining: layout.readableRecoveryRemaining)
        var paragraphSession = NativeParagraphReferenceRecovery.Session()
        var koreanWrapCharacterBudget = 2048
        for index in cards.indices where !cards[index].keptLettering && !cards[index].text.isEmpty && !lockedIDs.contains(cards[index].id) {
            try Task.checkCancellation()
            let item = cards[index]
            let appearance = restoration.appearances[item.id]
            if settings.mode == .translateOnly && settings.textPlacement == .replace,
               settings.usesSourceInpainting, settings.preserveSourceBackgroundColor,
               settings.renderedBackgroundOpacity == 1, item.sourceColorEligible,
               item.rotation != 0, !item.vertical, appearance?.finalForcedErasure != true, appearance?.provisional != true,
               let alternative = item.uprightAlternative,
               let upright = uprightFromSlant(item, alternative: alternative, cards: cards,
                    layout: layout, restoration: restoration, settings: settings) {
                cards[index] = upright
            }
            if cards[index].smallTextReference == nil, cards[index].rotation == 0 {
                cards[index] = proposingParagraphReference(cards[index], cards: cards,
                    appearance: appearance, session: &paragraphSession, budget: referenceBudget)
            }
            if cards[index].smallTextReference == nil {
                cards[index] = fitted(cards[index], appearance: appearance)
            } else if cards[index].smallTextReferenceResolved != true {
                let reference = cards[index].smallTextReference!
                let canProfile = referenceBudget.admit(.init(length: cards[index].text.utf16.count,
                    fontSize: Double(reference.fontSize), paddingIsValid: reference.padding.count == 4 && reference.padding.allSatisfy(\.isFinite)))
                cards[index] = recovering(cards[index], appearance: appearance, canProfile: canProfile)
            }
            cards[index] = repairingInline(cards[index],appearance: appearance,characterBudget: &koreanWrapCharacterBudget)
        }
        return NativeTranslationLayout(imageSize: layout.imageSize, sourceRect: layout.sourceRect,
                                       viewport: layout.viewport, items: cards,
                                       readableRecoveryRemaining: referenceBudget.readableRemaining,
                                       sourceObjectFit: layout.sourceObjectFit)
    }

    private static func style(_ item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance?)
        -> NativeTranslationTypography.Style {
        NativeTranslationTypography.Style(fontName: item.fontScript == "korean" ? appearance?.fontName : nil, fontScript: item.fontScript, fontSize: item.fontSize, vertical: item.vertical,
            foreground: appearance?.foreground ?? CGColor(gray: item.lightSurface ? 0 : 1, alpha: 1),
            outline: nil, outlineWidth: 0,
            tracking: -item.fontSize * 0.012, lineHeight: max(item.fontSize, item.lineHeight),
            optimizesKoreanWrapping: false, alignsToTop: item.balancedColumn,
            balancesHorizontalLines: !item.vertical && item.wrappingScript == "korean" &&
                item.text.utf16.count <= 180 && !item.text.contains(where: \.isNewline),
            horizontalWrapping: item.wrappingScript == "korean" && item.typesettingStrictLineBreak != true
                ? .keepAllWithEmergency : .normal,
            strictLineBreak: item.typesettingStrictLineBreak ?? false)
    }

    /// The original upright-from-slant candidate loop. The native page-axis
    /// repair raster retains the same per-pixel cleanliness and quantized
    /// luminance certificates, so a balloon contour is not an admission rule.
    private static func uprightFromSlant(_ item: NativeTranslationLayoutItem,
        alternative: NativeTranslationLayoutAlternative, cards: [NativeTranslationLayoutItem],
        layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
        settings: IPhoneOverlaySettings) -> NativeTranslationLayoutItem? {
        let frame = layout.sourceRect, r = alternative.rect
        guard [r.minX, r.minY, r.width, r.height, alternative.fontSize, alternative.lineHeight,
               alternative.paddingTop, alternative.paddingRight, alternative.paddingBottom, alternative.paddingLeft].allSatisfy(\.isFinite),
              r.minX >= frame.minX - 0.5, r.minY >= frame.minY - 0.5,
              r.maxX <= frame.maxX + 0.5, r.maxY <= frame.maxY + 0.5,
              let patch = restoration.patches.first(where: { $0.itemID == item.id && !$0.finalForcedErasure &&
                $0.layoutSafe?.count == $0.image.width * $0.image.height && $0.surfaceLuminance?.count == $0.image.width * $0.image.height })
        else { return nil }
        let appearance = restoration.appearances[item.id]
        let minimum = max(BrowserOverlayLayoutPlanner.minimumRenderedFontSize,
            min(alternative.fontSize, max(8.5, item.fontSize * 0.85)))
        let ratio = max(1, alternative.lineHeight / max(1, alternative.fontSize))
        let observed = appearance?.sourceSample ?? [:]
        let baseInk = appearance?.foreground.flatMap { colour -> [Double]? in
            guard let values = colour.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components,
                  values.count >= 3 else { return nil }; return values.prefix(3).map { Double($0) * 255 }
        } ?? (item.lightSurface ? [17, 18, 23] : [255, 255, 255])
        let palette = NativeTranslationSourceStylePostPolish.captionPalette(sample: observed, ink: baseInk,
            preserveText: settings.preserveSourceTextColor, displayInk: observed["displayForeground"] as? [Double])
        let inks = [palette.foreground, [17, 18, 23], [0, 0, 0], [255, 255, 255]]
        let foreign = cards.filter { $0.id != item.id }.map { $0.rect.insetBy(dx: -8, dy: -8) }
        var size = max(alternative.fontSize, item.fontSize), probes = 0
        while size >= minimum - 1e-6 && probes < 384 {
            for fraction: CGFloat in [1, 0.8, 0.65] {
                probes += 1
                var candidate = applying(alternative, to: item)
                let inset = (alternative.width - alternative.paddingLeft - alternative.paddingRight) * (1 - fraction) / 2
                candidate.paddingLeft += inset; candidate.paddingRight += inset
                candidate.fontSize = size; candidate.lineHeight = size * ratio
                candidate.rotation = 0; candidate.smallTextReference = nil
                let shaped = NativeTranslationTypography.layout(text: item.text, in: candidate.contentRect.size, style: style(candidate, appearance: appearance))
                guard shaped.fits, !shaped.glyphBounds.isEmpty else { continue }
                let lineProfile = profile(text: item.text, shaped: shaped)
                if !lineProfile.breaks.isEmpty || lineProfile.lineCount >= 3 && shaped.glyphBounds.count >= 8 &&
                    Double(shaped.glyphBounds.count) / Double(lineProfile.lineCount) < 2.5 { continue }
                let glyphs = shaped.glyphBounds.map { $0.offsetBy(dx: candidate.contentRect.minX, dy: candidate.contentRect.minY).insetBy(dx: -1, dy: -1) }
                let occupied = glyphs.reduce(CGRect.null) { $0.union($1) }
                var shifts: [CGPoint] = [.zero]
                for d: CGFloat in [2, 4, 6, 9] {
                    for shift in [CGPoint(x: -d, y: 0), CGPoint(x: d, y: 0), CGPoint(x: 0, y: -d), CGPoint(x: 0, y: d)] {
                        if r.contains(occupied.offsetBy(dx: shift.x, dy: shift.y)) { shifts.append(shift) }
                    }
                }
                for shift in shifts {
                    let moved = glyphs.map { $0.offsetBy(dx: shift.x, dy: shift.y) }
                    if moved.contains(where: { glyph in foreign.contains { $0.intersects(glyph) } }) { continue }
                    for ink in inks where surfaceInkFits(patch, glyphs: moved, foreground: ink) {
                        candidate.x += shift.x; candidate.y += shift.y
                        candidate.typesettingForeground = ink
                        return candidate
                    }
                }
            }
            size = floor((size - 0.5) * 4 + 0.5) / 4
        }
        return nil
    }

    private static func surfaceInkFits(_ patch: NativeTranslationRestoration.Patch,
                                      glyphs: [CGRect], foreground: [Double]) -> Bool {
        guard let safe = patch.layoutSafe, let luminance = patch.surfaceLuminance,
              foreground.count == 3, patch.rect.width > 0, patch.rect.height > 0 else { return false }
        let w = patch.image.width, h = patch.image.height
        let sx = CGFloat(w) / patch.rect.width, sy = CGFloat(h) / patch.rect.height
        let linear = foreground.map { v -> Double in let x = v / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let fg = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        var samples = 0
        for glyph in glyphs {
            let l = Int(floor((glyph.minX - patch.rect.minX) * sx)) - 1, t = Int(floor((glyph.minY - patch.rect.minY) * sy)) - 1
            let right = Int(ceil((glyph.maxX - patch.rect.minX) * sx)) + 1, bottom = Int(ceil((glyph.maxY - patch.rect.minY) * sy)) + 1
            if l < 0 || t < 0 || right > w || bottom > h { return false }
            for y in t..<bottom { for x in l..<right {
                samples += 1; if samples > 262_144 { return false }
                let i = y * w + x; if safe[i] == 0 { return false }
                let value = Double(luminance[i]) / 255
                let bg = value >= fg ? max(fg, value - 1 / 510) : min(fg, value + 1 / 510)
                if (max(bg, fg) + 0.05) / (min(bg, fg) + 0.05) < 4.5 { return false }
            } }
        }
        return samples > 0
    }

    private static func fitted(_ item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance?)
        -> NativeTranslationLayoutItem {
        var result = item
        var attributes = style(item, appearance: appearance)
        let minimum = BrowserOverlayLayoutPlanner.minimumRenderedFontSize
        guard item.fontSize >= minimum, item.contentRect.width > 0, item.contentRect.height > 0 else { return item }
        let ratio = attributes.lineHeight / item.fontSize
        func fits(_ size: CGFloat) -> Bool {
            attributes.fontSize = size
            attributes.lineHeight = size * ratio
            attributes.tracking = -size * 0.012
            var proposal = item
            proposal.fontSize = size; proposal.lineHeight = size * ratio
            let shaped = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: attributes)
            return NativeTypographyPostPolish.contentFits(item: proposal, typography: shaped)
        }
        guard !fits(item.fontSize), fits(minimum) else { return item }
        var low = minimum, high = item.fontSize
        for _ in 0..<9 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        result.fontSize = floor(low * 4) / 4
        result.lineHeight = result.fontSize * ratio
        return result
    }

    private struct LineProfile {
        let lineCount: Int
        let breaks: Set<Int>
        let badStarts: Set<Int>
        let badEnds: Set<Int>
        let isolated: Set<Int>
        let hangulIsolated: Int
    }

    /// Measure break identities against original UTF16 positions, even when the native Korean
    /// wrapper inserts controlled line separators for Core Text shaping.
    private static func profile(text: String, shaped: NativeTranslationTypography.Layout) -> LineProfile {
        let original = Array(text)
        var originalOffsets: [Int] = [], cursor = 0
        for character in original { originalOffsets.append(cursor); cursor += String(character).utf16.count }
        struct Entry { let shaped: Int; let original: Int; let character: Character; let index: Int }
        var entries: [Entry] = [], originalIndex = 0, shapedOffset = 0
        for character in shaped.shapedText {
            defer { shapedOffset += String(character).utf16.count }
            if character == "\n", originalIndex < original.count, original[originalIndex] != "\n" { continue }
            guard originalIndex < original.count else { continue }
            entries.append(Entry(shaped: shapedOffset, original: originalOffsets[originalIndex], character: character, index: originalIndex))
            originalIndex += 1
        }
        let forbiddenStarts = Set("、。，．,.！？!?…‥）)]」』】》〉:;")
        let forbiddenEnds = Set("（([「『【《〈")
        var breaks: Set<Int> = [], starts: Set<Int> = [], ends: Set<Int> = [], isolated: Set<Int> = [], count = 0, hangulIsolated = 0
        for range in shaped.lineRanges {
            let visible = entries.filter { $0.shaped >= range.location && $0.shaped < NSMaxRange(range) && !$0.character.isWhitespace }
            guard let first = visible.first, let last = visible.last else { continue }
            count += 1
            if first.index > 0, !original[first.index - 1].isWhitespace { breaks.insert(first.original) }
            if forbiddenStarts.contains(first.character) { starts.insert(first.original) }
            if forbiddenEnds.contains(last.character) { ends.insert(last.original) }
            if first.original == last.original { isolated.insert(first.original) }
            let row = String(original[first.index...last.index]).precomposedStringWithCanonicalMapping
                .unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }
            let visibleRow = String(String.UnicodeScalarView(row))
            if visibleRow.range(of: "^[\\p{Script=Hangul}]$", options: .regularExpression) != nil { hangulIsolated += 1 }
        }
        return LineProfile(lineCount: count, breaks: breaks, badStarts: starts, badEnds: ends,
                           isolated: isolated, hangulIsolated: hangulIsolated)
    }

    private static func proposingParagraphReference(_ item: NativeTranslationLayoutItem,
        cards: [NativeTranslationLayoutItem], appearance: NativeTranslationRestoration.Appearance?,
        session: inout NativeParagraphReferenceRecovery.Session, budget: NativeReferenceRecoveryBudget) -> NativeTranslationLayoutItem {
        let ratio = max(1, item.lineHeight / max(1, item.fontSize))
        let input = NativeParagraphReferenceRecovery.Entry(text: item.text, font: Double(item.fontSize), lineHeightRatio: Double(ratio),
            usableWidth: Double(item.contentRect.width), usableHeight: Double(item.contentRect.height),
            automaticRecovery: item.allowsAutomaticFontRecovery, hasReference: item.smallTextReference != nil,
            vertical: item.vertical, sourceVertical: item.sourceVertical, script: item.wrappingScript)
        let proposal = NativeParagraphReferenceRecovery.propose(input, session: &session,
            refinementRemaining: budget.refinementRemaining, readableRemaining: budget.readableRemaining,
            fitFont: { Double(fitted(item, appearance: appearance).fontSize) }, measureLines: { font in
                var measured = item
                measured.fontSize = CGFloat(font); measured.lineHeight = CGFloat(font) * ratio
                let shaped = NativeTranslationTypography.layout(text: measured.text, in: measured.contentRect.size, style: style(measured, appearance: appearance))
                let result = profile(text: measured.text, shaped: shaped)
                return result.lineCount > 0 ? result.lineCount : nil
            })
        guard let proposal else { return item }
        let exclusions = cards.filter { $0.id != item.id }.flatMap { other -> [[CGFloat]] in
            var boxes = [[other.x, other.y, other.width, other.height]]
            let b = other.sourceBounds, f = other.sourceFrame
            if b.count == 4, f.count == 4, b.allSatisfy(\.isFinite), f.allSatisfy(\.isFinite) {
                boxes.append([f[0] + b[0] * f[2], f[1] + b[1] * f[3], b[2] * f[2], b[3] * f[3]])
            }
            return boxes.filter { $0.allSatisfy(\.isFinite) && $0[2] > 0 && $0[3] > 0 }
        }
        var result = item
        result.smallTextReference = .init(fontSize: CGFloat(proposal.font), additionalLines: proposal.additionalLines,
            allowsEmergencyWordBreak: false, fallbackFontSize: CGFloat(proposal.font), fallbackPadding: [],
            exclusionRects: exclusions, padding: [item.paddingTop, item.paddingRight, item.paddingBottom, item.paddingLeft], paragraphRecovery: true)
        result.fontSize = 12; result.lineHeight = 12 * ratio
        return result
    }

    /// Port of smallTextReference baseline/candidate validation. Exclusions veto glyph growth;
    /// they are not holes in the text frame and never make text flow around another caption.
    private static func recovering(_ item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance?, canProfile: Bool)
        -> NativeTranslationLayoutItem {
        guard let reference = item.smallTextReference, reference.padding.count == 4 else { return item }
        func padded(_ padding: [CGFloat], font: CGFloat) -> NativeTranslationLayoutItem {
            var result = item
            result.paddingTop = padding[0]; result.paddingRight = padding[1]
            result.paddingBottom = padding[2]; result.paddingLeft = padding[3]
            let effective = max(BrowserOverlayLayoutPlanner.minimumRenderedFontSize, font)
            result.fontSize = effective; result.lineHeight = effective * max(1, item.lineHeight / item.fontSize)
            return fitted(result, appearance: appearance)
        }
        var baseline = padded(reference.padding, font: reference.fontSize)
        if !canProfile { baseline.smallTextReferenceResolved = true; return baseline }
        let baselineShape = NativeTranslationTypography.layout(text: baseline.text, in: baseline.contentRect.size, style: style(baseline, appearance: appearance))
        let baselineProfile = profile(text: baseline.text, shaped: baselineShape)
        guard baselineProfile.lineCount > 0 else { return baseline }
        let allowance = max(1, min(32, reference.additionalLines))
        let protectsWords = !item.vertical &&
            !(reference.fontSize < 8 && reference.allowsEmergencyWordBreak && item.wrappingScript == "korean") &&
            ["korean", "word"].contains(item.wrappingScript)
        let exclusions = reference.exclusionRects.compactMap { values -> CGRect? in
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        func acceptable(_ candidate: NativeTranslationLayoutItem, extraLines: Int, contained: Bool = true) -> Bool {
            let shaped = NativeTranslationTypography.layout(text: candidate.text, in: candidate.contentRect.size,
                                                           style: style(candidate, appearance: appearance))
            guard NativeTypographyPostPolish.contentFits(item: candidate, typography: shaped),
                  candidate.fontSize >= baseline.fontSize + 0.5 else { return false }
            let candidateProfile = profile(text: candidate.text, shaped: shaped)
            guard candidateProfile.lineCount > 0, candidateProfile.lineCount <= baselineProfile.lineCount + extraLines,
                  candidateProfile.badStarts.isSubset(of: baselineProfile.badStarts),
                  candidateProfile.badEnds.isSubset(of: baselineProfile.badEnds),
                  reference.paragraphRecovery != true || (candidateProfile.isolated.isSubset(of: baselineProfile.isolated) &&
                    candidateProfile.hangulIsolated <= baselineProfile.hangulIsolated),
                  !protectsWords || candidateProfile.breaks.isSubset(of: baselineProfile.breaks) else { return false }
            for glyph in shaped.glyphBounds {
                let ink = glyph.offsetBy(dx: candidate.contentRect.minX, dy: candidate.contentRect.minY)
                if contained && !candidate.rect.insetBy(dx: -0.5, dy: -0.5).contains(ink) { return false }
                if exclusions.contains(where: {
                    let intersection = ink.intersection($0)
                    return !intersection.isNull && intersection.width > 0.5 && intersection.height > 0.5
                }) { return false }
            }
            return true
        }
        var candidate = fitted(item, appearance: appearance)
        var chosen: NativeTranslationLayoutItem? = acceptable(candidate, extraLines: allowance) ? candidate : nil
        if chosen == nil && allowance > 1 {
            let upper = min(item.fontSize, candidate.fontSize)
            for step in 1...8 {
                let size = floor((upper - CGFloat(step) * 0.5) * 4) / 4
                guard size >= max(8, baseline.fontSize + 0.5) else { break }
                candidate = item
                candidate.fontSize = size; candidate.lineHeight = size * max(1, item.lineHeight / item.fontSize)
                candidate = fitted(candidate, appearance: appearance)
                if acceptable(candidate, extraLines: allowance) { chosen = candidate; break }
            }
        }
        if chosen == nil && reference.paragraphRecovery != true && !item.vertical && !exclusions.isEmpty && allowance > 1 {
            for shift: CGFloat in [-6, 6, -12, 12] where abs(shift) <= item.height * 0.2 {
                candidate = item
                if shift < 0 { candidate.paddingBottom += abs(shift) * 2 } else { candidate.paddingTop += abs(shift) * 2 }
                candidate = fitted(candidate, appearance: appearance)
                if acceptable(candidate, extraLines: allowance) { chosen = candidate; break }
            }
        }
        if reference.fallbackPadding.count == 4,
           chosen == nil || (chosen?.fontSize ?? 0) < reference.fallbackFontSize {
            let fallback = padded(reference.fallbackPadding, font: reference.fallbackFontSize)
            if acceptable(fallback, extraLines: 1, contained: false), fallback.fontSize >= (chosen?.fontSize ?? 0) { chosen = fallback }
        }
        var result = chosen ?? baseline
        result.smallTextReferenceResolved = true
        return result
    }

    private static func repairingInline(_ item: NativeTranslationLayoutItem,
        appearance: NativeTranslationRestoration.Appearance?, characterBudget: inout Int) -> NativeTranslationLayoutItem {
        guard item.inlineKoreanRepairResolved != true else { return item }
        let exclusions = (item.smallTextReference?.exclusionRects ?? []).compactMap { a -> CGRect? in
            guard a.count == 4, a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 else { return nil }
            return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
        var input = NativeKoreanInlineRepair.Entry(text: item.text, card: item.rect, exclusions: exclusions,
            font: Double(item.fontSize), padding: [item.paddingTop,item.paddingRight,item.paddingBottom,item.paddingLeft].map { Double($0) })
        input.vertical = item.vertical; input.wrappingScript = item.wrappingScript
        let ratio = item.lineHeight / max(1,item.fontSize)
        let repaired = NativeKoreanInlineRepair.repair(input, characterBudget: &characterBudget,
            minimumFont: Double(BrowserOverlayLayoutPlanner.minimumRenderedFontSize), widestWord: { text,font in
                var attributes = style(item,appearance: appearance)
                attributes.fontSize = CGFloat(font); attributes.tracking = 0
                return Double(NativeTranslationTypography.widestWord(text: text,style: attributes))
            }, measure: { proposal in
                var candidate = item
                candidate.fontSize = CGFloat(proposal.font); candidate.lineHeight = candidate.fontSize * ratio
                candidate.paddingTop = CGFloat(proposal.padding[0]); candidate.paddingRight = CGFloat(proposal.padding[1])
                candidate.paddingBottom = CGFloat(proposal.padding[2]); candidate.paddingLeft = CGFloat(proposal.padding[3])
                var attributes = style(candidate,appearance: appearance)
                attributes.strictLineBreak = proposal.strictPunctuation
                // The frozen punctuation trial switches both word-break and line-break.
                attributes.horizontalWrapping = proposal.strictPunctuation ? .normal : attributes.horizontalWrapping
                let shaped = NativeTranslationTypography.layout(text: candidate.text,in: candidate.contentRect.size,style: attributes)
                let p = profile(text: candidate.text,shaped: shaped)
                let result = NativeKoreanInlineRepair.Profile(lines: p.lineCount,breaks: p.breaks.sorted(),
                    badStarts: p.badStarts.sorted(),badEnds: p.badEnds.sorted(),ink: shaped.rangeBounds.map {
                        $0.offsetBy(dx: candidate.contentRect.minX,dy: candidate.contentRect.minY)
                    })
                return .init(profile: p.lineCount > 0 ? result:nil,fits: shaped.fits)
            })
        var result = item
        result.inlineKoreanRepairResolved = true
        guard repaired.wrapAccepted || repaired.punctuationAccepted else { return result }
        result.fontSize = CGFloat(repaired.candidate.font); result.lineHeight = result.fontSize * ratio
        result.paddingTop = CGFloat(repaired.candidate.padding[0]); result.paddingRight = CGFloat(repaired.candidate.padding[1])
        result.paddingBottom = CGFloat(repaired.candidate.padding[2]); result.paddingLeft = CGFloat(repaired.candidate.padding[3])
        if repaired.punctuationAccepted { result.typesettingStrictLineBreak = true }
        return result
    }

    private static func applying(_ alternative: NativeTranslationLayoutAlternative, to item: NativeTranslationLayoutItem)
        -> NativeTranslationLayoutItem {
        var result = item
        result.x = alternative.x; result.y = alternative.y
        result.width = alternative.width; result.height = alternative.height
        result.fontSize = alternative.fontSize; result.lineHeight = alternative.lineHeight
        result.paddingTop = alternative.paddingTop; result.paddingRight = alternative.paddingRight
        result.paddingBottom = alternative.paddingBottom; result.paddingLeft = alternative.paddingLeft
        if let recovery = alternative.allowsAutomaticFontRecovery { result.allowsAutomaticFontRecovery = recovery }
        return result
    }

    private static func holds(_ rect: CGRect, paper: NativeTranslationBalloonInterior, frame: CGRect) -> Bool {
        guard paper.rect.count == 4, paper.spans.count >= 2, paper.spans.count.isMultiple(of: 2) else { return false }
        let normalized = paper.normalizedRect
        let bounds = CGRect(x: frame.minX + normalized.minX * frame.width, y: frame.minY + normalized.minY * frame.height,
                            width: normalized.width * frame.width, height: normalized.height * frame.height)
        guard bounds.height > 0, bounds.contains(rect) else { return false }
        let bands = paper.spans.count / 2, step = bounds.height / CGFloat(bands)
        let first = max(0, Int(floor((rect.minY - bounds.minY) / step)))
        let last = min(bands - 1, Int(ceil((rect.maxY - bounds.minY) / step)) - 1)
        guard first <= last else { return false }
        for band in first...last {
            let left = paper.spans[band * 2], right = paper.spans[band * 2 + 1]
            guard left >= 0, right > left, frame.minX + CGFloat(left) * frame.width <= rect.minX,
                  frame.minX + CGFloat(right) * frame.width >= rect.maxX else { return false }
        }
        return true
    }

    private static func clears(_ rect: CGRect, excluding ids: Set<String>, cards: [NativeTranslationLayoutItem], frame: CGRect) -> Bool {
        for item in cards where !ids.contains(item.id) {
            if !item.keptLettering && rect.intersects(item.rect) { return false }
            for bounds in [item.sourceBounds] + item.auxiliaryInkRects where bounds.count == 4 {
                let source = CGRect(x: frame.minX + bounds[0] * frame.width, y: frame.minY + bounds[1] * frame.height,
                                    width: bounds[2] * frame.width, height: bounds[3] * frame.height)
                if rect.intersects(source) { return false }
            }
        }
        return true
    }

    /// Port of the shared browser column inspection. Inspect exposed pixels once for all
    /// proposed columns, independently of palette/inpainting settings, at the same 4096 budget.
    private static func inspectedColumnSurfaces(cards: [NativeTranslationLayoutItem], frame: CGRect,
                                                 image: CGImage) throws -> [String: [CGFloat]]? {
        let columns = cards.filter { $0.columnLayout != nil }
        guard !columns.isEmpty, frame.width > 0, frame.height > 0 else { return nil }
        let proposals = columns.compactMap(\.columnLayout)
        let left = proposals.map(\.x).min() ?? 0, top = proposals.map(\.y).min() ?? 0
        let right = proposals.map { $0.x + $0.width }.max() ?? 0
        let bottom = proposals.map { $0.y + ($0.inspectionHeight ?? $0.height) }.max() ?? 0
        let width = right - left, height = bottom - top
        guard width > 0, height > 0 else { return nil }
        let w = max(1, min(512, Int(floor(sqrt(4096 * width / height)))))
        let h = max(1, min(512, 4096 / w))
        let sourceMargin = min(2, max(1, width / CGFloat(w) * 0.5))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            let scaleX = CGFloat(w) * frame.width / width / CGFloat(image.width)
            let scaleY = CGFloat(h) * frame.height / height / CGFloat(image.height)
            let sourceX = (left - frame.minX) / frame.width * CGFloat(image.width)
            let sourceY = (top - frame.minY) / frame.height * CGFloat(image.height)
            context.draw(image, in: CGRect(x: -sourceX * scaleX, y: -sourceY * scaleY,
                                           width: CGFloat(image.width) * scaleX, height: CGFloat(image.height) * scaleY))
            return true
        }
        guard decoded else { return nil }
        let sources = cards.flatMap { [$0.sourceBounds] + $0.auxiliaryInkRects }.compactMap { bounds -> CGRect? in
            guard bounds.count == 4, bounds.allSatisfy(\.isFinite) else { return nil }
            return CGRect(x: frame.minX + bounds[0] * frame.width, y: frame.minY + bounds[1] * frame.height,
                          width: bounds[2] * frame.width, height: bounds[3] * frame.height).insetBy(dx: -sourceMargin, dy: -sourceMargin)
        }
        struct Sample {
            let colors: [Double]
            let alpha: UInt8
            let gridIndex: Int
            let features: [Double]
        }
        var surfaces: [String: [CGFloat]] = [:]
        for item in columns {
            try Task.checkCancellation()
            guard let proposal = item.columnLayout else { return nil }
            let inspected = CGRect(x: proposal.x, y: proposal.y, width: proposal.width,
                                   height: proposal.inspectionHeight ?? proposal.height)
            var samples: [Sample] = []
            for yy in 0..<h {
                for xx in 0..<w {
                    let point = CGPoint(x: left + (CGFloat(xx) + 0.5) * width / CGFloat(w),
                                        y: top + (CGFloat(yy) + 0.5) * height / CGFloat(h))
                    guard inspected.contains(point), !sources.contains(where: { $0.contains(point) }) else { continue }
                    let index = yy * w + xx, offset = index * 4
                    let normalizedX = Double(xx) / Double(w), normalizedY = Double(yy) / Double(h)
                    samples.append(Sample(colors: [Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2])],
                        alpha: pixels[offset + 3], gridIndex: index, features: [1, normalizedX, normalizedY, normalizedY * normalizedY]))
                }
            }
            guard samples.count >= 4 else { return nil }
            let background = (0..<3).map { channel in samples.map { $0.colors[channel] }.sorted()[samples.count / 2] }
            let obstructed = samples.filter { sample in
                sample.alpha < 250 || (zip(sample.colors, background).map { abs($0.0 - $0.1) }.max() ?? 0) > 24
            }.count
            let limit = max(1, Double(samples.count) * 0.015)
            if Double(obstructed) > limit {
                var matrix = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
                var rhs = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
                for sample in samples {
                    for j in 0..<4 {
                        for k in 0..<4 { matrix[j][k] += sample.features[j] * sample.features[k] }
                        for channel in 0..<3 { rhs[channel][j] += sample.features[j] * sample.colors[channel] }
                    }
                }
                let planes = rhs.map { solve(matrix: matrix, values: $0) }
                let outliers = planes.contains(where: { $0 == nil }) ? samples.count : samples.filter { sample in
                    sample.alpha < 250 || ((0..<3).map { channel in
                        abs(sample.colors[channel] - zip(planes[channel]!, sample.features).reduce(0) { $0 + $1.0 * $1.1 })
                    }.max() ?? 0) > 14
                }.count
                if Double(outliers) > limit {
                    let grid = Dictionary(uniqueKeysWithValues: samples.map { ($0.gridIndex, $0) })
                    var links = 0, edges = 0
                    for (index, sample) in grid {
                        for neighbor in [index % w < w - 1 ? index + 1 : -1, index + w] {
                            guard let next = grid[neighbor] else { continue }
                            links += 1
                            if sample.alpha < 250 || next.alpha < 250 ||
                                (zip(sample.colors, next.colors).map { abs($0.0 - $0.1) }.max() ?? 0) > 24 { edges += 1 }
                        }
                    }
                    guard Double(links) >= Double(samples.count) * 0.5, edges <= 1 else { return nil }
                }
            }
            surfaces[item.id] = background.map { CGFloat($0) }
        }
        return surfaces
    }

    private static func solve(matrix: [[Double]], values: [Double]) -> [Double]? {
        var augmented = matrix.enumerated().map { index, row in row + [values[index]] }
        for k in 0..<4 {
            let pivot = (k..<4).max { abs(augmented[$0][k]) < abs(augmented[$1][k]) } ?? k
            augmented.swapAt(k, pivot)
            guard abs(augmented[k][k]) >= 1e-8 else { return nil }
            let divisor = augmented[k][k]
            for column in k...4 { augmented[k][column] /= divisor }
            for row in 0..<4 where row != k {
                let factor = augmented[row][k]
                for column in k...4 { augmented[row][column] -= factor * augmented[k][column] }
            }
        }
        return augmented.map { $0[4] }
    }

    static func payload(
        items: [BrowserOverlayItem],
        imageSize: CGSize,
        sourceRect: CGRect,
        settings: IPhoneOverlaySettings,
        targetLanguage: String,
        viewport: CGSize,
        measurementCache: BrowserOverlayTextMeasurementCache? = BrowserOverlayTextMeasurementCache()
    ) -> [[String: Any]] {
        guard imageSize.width > 0, imageSize.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              sourceRect.width > 0, sourceRect.height > 0,
              [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height].allSatisfy(\.isFinite),
              viewport.width > 0, viewport.height > 0, viewport.width.isFinite, viewport.height.isFinite
        else { return [] }

        let scaleX = sourceRect.width / imageSize.width
        let scaleY = sourceRect.height / imageSize.height
        // Kept source lettering is never typeset: its box is reserved like
        // another caption's source, and the overlay receives it as a
        // protected-lettering descriptor (appended after the captions).
        let validItems = items.filter {
            !$0.rect.isNull && $0.rect.width > 0 && $0.rect.height > 0 &&
                [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height].allSatisfy(\.isFinite)
        }
        let keptLettering = validItems.filter(\.keepsSourceLettering)
        let keptSources = keptLettering.map {
            CGRect(x: sourceRect.minX + $0.rect.minX * scaleX, y: sourceRect.minY + $0.rect.minY * scaleY,
                   width: max(1, $0.rect.width * scaleX), height: max(1, $0.rect.height * scaleY))
        }
        let sanitized = validItems.filter { !$0.keepsSourceLettering }.map { item -> BrowserOverlayItem in
            guard let translated = item.translatedText else { return item }
            let clean = ReaderTranslationLanguageFilter.removingForeignScriptTail(
                translated, target: targetLanguage
            )
            guard clean != translated else { return item }
            return BrowserOverlayItem(
                stableRegionID: item.stableRegionID,
                rect: item.rect,
                sourceText: item.sourceText,
                translatedText: clean,
                confidence: item.confidence,
                sourceOrientation: item.sourceOrientation,
                sourceSingleVerticalColumn: item.sourceSingleVerticalColumn,
                translationReuseIdentity: item.translationReuseIdentity,
                sourcePolygon: item.sourcePolygon,
                auxiliaryInkRects: item.auxiliaryInkRects,
                auxiliaryInkPolygons: item.auxiliaryInkPolygons,
                balloonInterior: item.balloonInterior,
                unitMemberRects: item.unitMemberRects,
                keepsSourceLettering: item.keepsSourceLettering,
                recoveredLine: item.recoveredLine
            )
        }
        let sorted = BrowserOverlayItemOrdering.ordered(sanitized)
        var segments = sorted.map { item -> (
            item: BrowserOverlayItem,
            source: CGRect,
            sourceVertical: Bool,
            content: BrowserOverlayCardContent
        ) in
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
            return (
                item,
                CGRect(
                    x: sourceRect.minX + item.rect.minX * scaleX,
                    y: sourceRect.minY + item.rect.minY * scaleY,
                    width: max(1, item.rect.width * scaleX),
                    height: max(1, item.rect.height * scaleY)
                ),
                sourceVertical,
                content
            )
        }
        let sourceRects = segments.map(\.source)
        let sourceRotations = segments.map {
            BrowserOverlayRotation.mapped(item: $0.item, imageSize: imageSize, sourceRect: sourceRect, settings: settings)
        }
        let nearUprightQuads = segments.map {
            BrowserOverlayRotation.nearUpright(item: $0.item, imageSize: imageSize, sourceRect: sourceRect, settings: settings)
        }
        var intrinsicLayouts = segments.map { segment in
            BrowserOverlayLayoutPlanner.plan(
                source: segment.source,
                variants: [segment.content.displayed],
                settings: settings,
                viewport: viewport,
                occupied: [],
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn:
                    segment.content.singleVerticalColumn,
                reservedSources: [],
                measurementCache: measurementCache
            )
        }
        var verticalContents: [Int: BrowserOverlayCardContent] = [:]
        var verticalLayouts: [Int: BrowserOverlayCardLayout] = [:]
        for index in segments.indices {
            if Task.isCancelled { return [] }
            let segment = segments[index]
            guard let verticalContent =
                BrowserOverlayCardContent.adaptiveVerticalCandidate(
                    item: segment.item,
                    current: segment.content,
                    mode: settings.mode,
                    textPlacement: settings.textPlacement,
                    sourceVertical: segment.sourceVertical,
                    sourceRect: segment.source
                )
            else { continue }
            verticalContents[index] = verticalContent
            verticalLayouts[index] = BrowserOverlayLayoutPlanner.plan(
                source: segment.source,
                variants: [verticalContent.displayed],
                settings: settings,
                viewport: viewport,
                occupied: [],
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn: verticalContent.singleVerticalColumn,
                reservedSources: [],
                measurementCache: measurementCache
            )
        }
        let verticalIndices =
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: intrinsicLayouts,
                verticalLayouts: verticalLayouts,
                eligibleIndices: verticalLayouts.isEmpty ? [] :
                    BrowserOverlayLayoutPlanner
                        .severelyDisplacedTranslationIndices(
                            intrinsicLayouts: intrinsicLayouts,
                            sources: sourceRects,
                            variants: segments.map { $0.content.displayed },
                            settings: settings,
                            viewport: viewport,
                            sourceVerticals: segments.map(\.sourceVertical),
                            singleVerticalColumns: segments.map {
                                $0.content.singleVerticalColumn
                            },
                            placementBounds: sourceRect,
                            allowsDetachedPlacements: segments.map {
                                $0.content.hasTranslation &&
                                    settings.mode == .translateOnly
                            },
                            returnableCards: sourceRotations.map { $0 == nil },
                            protectedRects: keptSources,
                            measurementCache: measurementCache
                        )
            )
        for index in verticalIndices {
            guard let content = verticalContents[index],
                  let layout = verticalLayouts[index]
            else { continue }
            let segment = segments[index]
            segments[index] = (
                segment.item,
                segment.source,
                segment.sourceVertical,
                content
            )
            intrinsicLayouts[index] = layout
        }
        let planningOrder = BrowserOverlayLayoutPlanner.packingOrder(
            intrinsicLayouts
        )
        var occupied: [CGRect] = []
        var plannedLayouts = Array<BrowserOverlayCardLayout?>(
            repeating: nil,
            count: segments.count
        )
        for index in planningOrder {
            if Task.isCancelled { return [] }
            let segment = segments[index]
            let reservedSources = sourceRects.enumerated().compactMap {
                otherIndex, rect in otherIndex == index ? nil : rect
            } + keptSources
            let layout = BrowserOverlayLayoutPlanner.resolvePositionedLayout(
                intrinsicLayouts[index],
                source: segment.source,
                variants: [segment.content.displayed],
                settings: settings,
                viewport: viewport,
                occupied: occupied,
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn:
                    segment.content.singleVerticalColumn,
                reservedSources: reservedSources,
                measurementCache: measurementCache
            )
            guard !layout.rect.isNull,
                  layout.rect.width > 0, layout.rect.height > 0
            else { continue }
            plannedLayouts[index] = layout
            occupied.append(layout.rect)
        }
        let concreteLayouts = plannedLayouts.compactMap { $0 }
        if concreteLayouts.count == plannedLayouts.count {
            let relaxed = BrowserOverlayLayoutPlanner.restoringSourceCoverage(
                BrowserOverlayLayoutPlanner.relaxingCardPositions(
                concreteLayouts,
                sources: sourceRects,
                sourceVerticals: segments.map(\.sourceVertical),
                viewport: viewport,
                placementBounds: sourceRect,
                preferredRects: intrinsicLayouts.map(\.rect),
                allowsDetachedPlacements: segments.map {
                    $0.content.hasTranslation &&
                        settings.mode == .translateOnly
                },
                returnableCards: sourceRotations.map { $0 == nil },
                protectedRects: keptSources
                ),
                sources: sourceRects,
                bounds: sourceRect,
                enabled: settings.mode == .translateOnly && settings.textPlacement == .replace
            )
            for index in relaxed.indices {
                plannedLayouts[index] = relaxed[index]
            }
        }

        // Dense sheets: cards stay in the neighbourhood of their own source box.
        let cellEligible = segments.indices.map {
            segments[$0].content.hasTranslation && sourceRotations[$0] == nil && !segments[$0].content.displayed.vertical
        }
        if settings.mode == .translateOnly && settings.textPlacement == .replace &&
            cellEligible.filter({ $0 }).count >= BrowserOverlayLayoutPlanner.denseSheetCaptionCount {
            plannedLayouts = BrowserOverlayLayoutPlanner.confiningToSourceCells(
                plannedLayouts, sources: sourceRects, variants: segments.map { $0.content.displayed },
                sourceVerticals: segments.map(\.sourceVertical),
                sourceSizes: segments.map { BrowserOverlayTypography.sourceSize(text: $0.item.sourceText, rect: $0.source) },
                eligible: cellEligible,
                bounds: sourceRect, settings: settings, measurementCache: measurementCache)
        }

        // Captions sharing one balloon (native shared interior) may be set as one unit: stacked in
        // source reading order at one size inside the balloon paper. The planner proposes the unit
        // (order, paper, a stack that fits); every card keeps its own layout and erasure, and the
        // overlay commits the unit only once each member's erasure is verified and the stack keeps
        // the members' final size (`balloonUnit`).
        var unitMembership: [Int: (unit: BrowserOverlayBalloonUnit, order: Int)] = [:]
        if settings.mode == .translateOnly && settings.textPlacement == .replace,
           segments.contains(where: { $0.item.balloonInterior?.members != nil }) {
            let unitEligible = segments.indices.map { index -> Bool in
                let content = segments[index].content
                guard content.hasTranslation, sourceRotations[index] == nil, nearUprightQuads[index] == nil,
                      !content.displayed.vertical, case .plain = content.displayed.content else { return false }
                return true
            }
            let units = BrowserOverlayLayoutPlanner.balloonUnits(
                items: segments.map(\.item), sources: sourceRects, sourceVerticals: segments.map(\.sourceVertical),
                variants: segments.map { $0.content.displayed }, eligible: unitEligible, planned: plannedLayouts,
                frame: sourceRect, measurementCache: measurementCache)
            for unit in units {
                for (order, member) in unit.members.enumerated() { unitMembership[member] = (unit, order) }
            }
        }

        var columns = settings.mode == .translateOnly && settings.textPlacement == .replace
            ? BrowserOverlayColumnLayout.plan(sources: sourceRects, variants: segments.map { $0.content.displayed },
                eligible: segments.indices.map { segments[$0].sourceVertical && segments[$0].content.hasTranslation && sourceRotations[$0] == nil },
                bounds: sourceRect, measurementCache: measurementCache,
                sourceSizes: segments.map { BrowserOverlayTypography.sourceSize(text: $0.item.sourceText, rect: $0.source) }) : [:]
        // A rejected neighbor returns to its original footprint. Recheck that
        // footprint before accepting any remaining coordinated column.
        while !columns.isEmpty {
            let rejected = columns.keys.filter { index in
                guard let frame = columns[index]?.rect else { return false }
                return plannedLayouts.indices.contains { other in
                    guard other != index, let obstacle = columns[other]?.rect ?? plannedLayouts[other]?.rect else { return false }
                    let overlap = frame.intersection(obstacle)
                    return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
                } || keptSources.contains { kept in
                    let overlap = frame.intersection(kept)
                    return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
                }
            }
            if rejected.isEmpty { break }
            for index in rejected { columns.removeValue(forKey: index) }
        }
        // Sound-effect / logo evidence from the source text (the overlay's keep-source + gloss path).
        let hiraganaSources = items.filter { ReaderTranslationNonContentText.containsHiragana($0.sourceText) }.count
        let creditSources = items.filter { ReaderTranslationNonContentText.containsTitleCredits($0.sourceText) }.count
        var result: [[String: Any]] = []
        for (index, segment) in segments.enumerated() {
            if Task.isCancelled { return [] }
            guard let resolvedLayout = plannedLayouts[index] else { continue }
            // All placement and source-coverage adjustments are finished. Growing
            // fonts earlier feeds back into packing and can shrink other captions.
            let ordinaryLayout = segment.content.hasTranslation
                ? BrowserOverlayLayoutPlanner.fittingFinalHorizontalFont(
                    resolvedLayout, variants: [segment.content.displayed], settings: settings,
                    occupied: plannedLayouts.enumerated().compactMap { $0.offset == index ? nil : $0.element?.rect },
                    reservedSources: sourceRects.enumerated().compactMap { $0.offset == index ? nil : $0.element } + keptSources,
                    measurementCache: measurementCache
                ) : resolvedLayout
            func quadLayout(display: Bool) -> BrowserOverlayCardLayout? {
                sourceRotations[index].flatMap {
                    BrowserOverlayRotation.layout(geometry: $0, variant: segment.content.displayed,
                        maximumFontSize: BrowserOverlayRotation.maximumFontSize(geometry: $0, sourceText: segment.item.sourceText,
                                                                                planned: ordinaryLayout.maximumFontSize,
                                                                                display: display),
                        plannedFontSize: ordinaryLayout.maximumFontSize,
                        obstacles: sourceRects.enumerated().compactMap { $0.offset == index ? nil : $0.element } + keptSources,
                        displayMargins: display, measurementCache: measurementCache)
                }
            }
            let bodyRotatedLayout = quadLayout(display: false)
            // A quad tilted only by detector noise is set upright. When its
            // rotated layout would fit, it stays outside the page's size
            // cohorts, like a rotated caption.
            let nearUprightRotation = nearUprightQuads[index].flatMap { geometry -> CGFloat? in
                BrowserOverlayRotation.layout(geometry: geometry, variant: segment.content.displayed,
                    maximumFontSize: BrowserOverlayRotation.maximumFontSize(geometry: geometry, sourceText: segment.item.sourceText,
                                                                            planned: ordinaryLayout.maximumFontSize),
                    plannedFontSize: ordinaryLayout.maximumFontSize,
                    obstacles: sourceRects.enumerated().compactMap { $0.offset == index ? nil : $0.element },
                    measurementCache: measurementCache) == nil ? nil : geometry.radians
            }
            // Rotated and slanted display lettering (titles, shouts, sound
            // effects) stopped only by the body ceiling is sized from its source
            // glyph inside the same quad. The body-ceiling layout still decides
            // the upright alternative below.
            var rotatedLayout = bodyRotatedLayout
            if let body = bodyRotatedLayout, let geometry = sourceRotations[index], !segment.content.displayed.vertical {
                let text = segment.item.sourceText, planned = ordinaryLayout.maximumFontSize
                let ceiling = BrowserOverlayRotation.maximumFontSize(geometry: geometry, sourceText: text, planned: planned)
                let display = BrowserOverlayRotation.maximumFontSize(geometry: geometry, sourceText: text, planned: planned,
                                                                     display: true)
                if display > ceiling + 0.25, body.maximumFontSize >= ceiling - 0.5,
                   let grown = quadLayout(display: true), grown.maximumFontSize > body.maximumFontSize {
                    rotatedLayout = grown
                }
            }
            // Horizontal Korean in a narrow slanted column breaks every word.
            // Offer the planner's upright card; the overlay uses it only when the
            // slanted source erasure leaves clean surface under every glyph,
            // otherwise the rotated layout below stays in place.
            let uprightAlternative = bodyRotatedLayout.flatMap { rotated in
                BrowserOverlayRotation.prefersUprightLayout(rotated: rotated, radians: sourceRotations[index]?.radians ?? 0,
                    upright: ordinaryLayout, variant: segment.content.displayed, sourceVertical: segment.sourceVertical,
                    measurementCache: measurementCache) ? ordinaryLayout : nil
            }
            // The size the quad held under the planner's ceiling. Artwork-safe
            // slanted fitting keeps its floor there, so growth never costs a
            // restoration that fit before.
            let plannedRotatedFont = rotatedLayout == nil ? nil : sourceRotations[index].flatMap {
                BrowserOverlayRotation.layout(geometry: $0, variant: segment.content.displayed,
                    maximumFontSize: ordinaryLayout.maximumFontSize, measurementCache: measurementCache)?.maximumFontSize
            }
            // A vertical column tilted only by detector noise: the quad's layout
            // (glyph-based size, erasure, plate) with upright text; the overlay
            // clips any plate to the quad and keeps the rotated caption when
            // source ink leaves the upright box.
            let uprightQuadText = rotatedLayout != nil && sourceRotations[index].map {
                BrowserOverlayRotation.setsUprightInQuad($0, sourceVertical: segment.sourceVertical,
                                                         translatedVertical: segment.content.displayed.vertical)
            } == true
            let layout = rotatedLayout ?? ordinaryLayout
            let renderedText: String
            if segment.content.hasTranslation,
               settings.mode == .translateOnly
            {
                renderedText =
                    segment.item.translatedText ?? segment.item.sourceText
            } else if !segment.content.hasTranslation {
                renderedText = segment.item.sourceText
            } else {
                renderedText = segment.content.displayed.displayText
            }
            var payload: [String: Any] = [
                "id": String(segment.item.stableRegionID ?? UInt64(index)),
                "rotation": rotatedLayout == nil ? 0 : (sourceRotations[index]?.radians ?? 0),
                "rotationPlannedFontSize": plannedRotatedFont as Any? ?? NSNull(),
                "nearUprightRotation": nearUprightRotation as Any? ?? NSNull(),
                "uprightQuadText": uprightQuadText,
                "uprightAlternative": uprightAlternative.map { upright -> [String: Any] in
                    ["x": upright.rect.minX, "y": upright.rect.minY, "width": upright.rect.width, "height": upright.rect.height,
                     "fontSize": upright.maximumFontSize,
                     "lineHeight": BrowserOverlayFont.system(ofSize: upright.maximumFontSize, weight: .bold).lineHeight,
                     "paddingTop": upright.contentInsets.top, "paddingRight": upright.contentInsets.right,
                     "paddingBottom": upright.contentInsets.bottom, "paddingLeft": upright.contentInsets.left]
                } as Any? ?? NSNull(),
                "sourceTextOnly": !segment.content.hasTranslation,
                "sourceFontSize": BrowserOverlayTypography.sourceSize(text: segment.item.sourceText, rect: segment.source) as Any? ?? NSNull(),
                "sourceColorEligible": settings.mode == .translateOnly &&
                    settings.textPlacement == .replace,
                "sourcePanelRestorationEligible": settings.mode == .translateOnly &&
                    settings.textPlacement == .replace,
                "sourceCleanupLexical": BrowserSourceInkCleanup.hasColoredCleanupText(segment.item.sourceText),
                "sourceLettering": ReaderTranslationNonContentText.letteringRole(
                    segment.item.sourceText,
                    pageHasHiragana: hiraganaSources - (ReaderTranslationNonContentText.containsHiragana(segment.item.sourceText) ? 1 : 0) > 0,
                    pageHasCredits: creditSources - (ReaderTranslationNonContentText.containsTitleCredits(segment.item.sourceText) ? 1 : 0) > 0
                )?.rawValue as Any? ?? NSNull(),
                "columnLayout": columns[index].map { column -> [String: Any] in
                    let height = segment.content.displayed.measuredSize(
                        width: column.rect.width - column.contentInsets.left - column.contentInsets.right,
                        fontSize: column.maximumFontSize, measurementCache: measurementCache).height
                    return ["x": column.rect.minX, "y": column.rect.minY,
                     "width": column.rect.width, "height": column.rect.height,
                     "inspectionHeight": min(column.rect.height, ceil(height) + 8),
                     "fontSize": column.maximumFontSize,
                     "lineHeight": BrowserOverlayFont.system(ofSize: column.maximumFontSize, weight: .bold).lineHeight,
                     "paddingTop": column.contentInsets.top, "paddingLeft": column.contentInsets.left,
                     "paddingBottom": column.contentInsets.bottom, "paddingRight": column.contentInsets.right,
                     "smallTextReference": NSNull(), "balancedColumn": true,
                     "allowsAutomaticFontRecovery": false]
                } as Any? ?? NSNull(),
                "allowsAutomaticFontRecovery": rotatedLayout == nil && settings.mode == .translateOnly &&
                    settings.textPlacement == .replace,
                "sourceCleanup": settings.mode == .translateOnly &&
                    settings.textPlacement == .replace &&
                    settings.colorMode == .white,
                "sourceBounds": [segment.item.rect.minX / imageSize.width, segment.item.rect.minY / imageSize.height,
                                 segment.item.rect.width / imageSize.width, segment.item.rect.height / imageSize.height],
                "sourcePolygon": segment.item.sourcePolygon.map { [$0.x / imageSize.width, $0.y / imageSize.height] },
                "auxiliaryInkRects": segment.item.auxiliaryInkRects.map {
                    [$0.minX / imageSize.width, $0.minY / imageSize.height, $0.width / imageSize.width, $0.height / imageSize.height]
                },
                "auxiliaryInkPolygons": segment.item.auxiliaryInkPolygons.map { $0.map { [$0.x / imageSize.width, $0.y / imageSize.height] } },
                "balloonInterior": segment.item.balloonInterior.flatMap { $0.members == nil ? $0.payload : nil } as Any? ?? NSNull(),
                "balloonUnit": unitMembership[index].map { membership -> [String: Any] in
                    ["members": membership.unit.members.map { String(segments[$0].item.stableRegionID ?? UInt64($0)) },
                     "order": membership.order,
                     "interior": segments[index].item.balloonInterior?.payload ?? [:]]
                } as Any? ?? NSNull(),
                "unitMemberRects": segment.item.unitMemberRects.map {
                    [$0.minX / imageSize.width, $0.minY / imageSize.height, $0.width / imageSize.width, $0.height / imageSize.height]
                },
                "sourceSingleColumn": segment.item.sourceSingleVerticalColumn == true,
                "recoveredLine": segment.item.recoveredLine,
                "sourceRubyEligible": segment.item.sourceText.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) },
                "sourceFrame": [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height],
                "sourceVertical": segment.sourceVertical,
                "x": layout.rect.minX,
                "y": layout.rect.minY,
                "width": layout.rect.width,
                "height": layout.rect.height,
                "text": renderedText,
                "vertical": segment.content.displayed.vertical,
                "wrappingScript":
                    BrowserOverlayTextFlow.wrappingScript(
                        for: renderedText
                    ).rawValue,
                "fontScript":
                    BrowserOverlayTextFlow.fontScript(
                        for: renderedText
                    ).rawValue,
                "fontSize": layout.maximumFontSize,
                "smallTextReference": layout.smallTextReference.map { reference -> [String: Any] in
                    ["fontSize": reference.fontSize, "additionalLines": reference.additionalLines,
                     "allowsEmergencyWordBreak": reference.allowsEmergencyWordBreak,
                     "fallbackFontSize": reference.fallbackFontSize ?? reference.fontSize,
                     "fallbackPadding": [reference.fallbackInsets?.top ?? reference.insets.top,
                                         reference.fallbackInsets?.right ?? reference.insets.right,
                                         reference.fallbackInsets?.bottom ?? reference.insets.bottom,
                                         reference.fallbackInsets?.left ?? reference.insets.left],
                     "exclusionRects": reference.exclusionRects.map { [$0.minX, $0.minY, $0.width, $0.height] },
                     "padding": [reference.insets.top, reference.insets.right, reference.insets.bottom, reference.insets.left]]
                } as Any? ?? NSNull(),
                "lineHeight": segment.content.displayed.vertical
                    ? layout.maximumFontSize
                    : BrowserOverlayFont.system(
                        ofSize: layout.maximumFontSize,
                        weight: .bold
                    ).lineHeight,
                "paddingTop": layout.contentInsets.top,
                "paddingLeft": layout.contentInsets.left,
                "paddingBottom": layout.contentInsets.bottom,
                "paddingRight": layout.contentInsets.right,
                "lightSurface":
                    settings.colorMode == .white,
                "clipsText": !segment.content.hasTranslation ||
                    segment.content.displayed.vertical ||
                    segment.content.singleVerticalColumn ||
                    settings.textPlacement != .replace,
            ]
            // Keep-source glosses follow the lettering's own tilt: the detector quad of a lettering role, or
            // the baseline of italic lettering, as [centre x, centre y (fractions of the page), width, height
            // (fractions of its width), radians].
            if payload["sourceLettering"] is String, sourceRect.width > 0, sourceRect.height > 0,
               let quad = sourceRotations[index] ?? nearUprightQuads[index] ??
                BrowserOverlayRotation.baselineAxis(item: segment.item, imageSize: imageSize, sourceRect: sourceRect) {
                payload["sourceQuad"] = [(quad.panelRect.midX - sourceRect.minX) / sourceRect.width,
                                         (quad.panelRect.midY - sourceRect.minY) / sourceRect.height,
                                         quad.panelRect.width / sourceRect.width, quad.panelRect.height / sourceRect.width, quad.radians]
            }
            result.append(payload)
        }
        for (offset, (item, source)) in zip(keptLettering, keptSources).enumerated() {
            let text = item.translatedText ?? item.sourceText
            let sourceVertical = BrowserOverlayTextFlow.usesVerticalSourceLayout(
                rect: item.rect, text: item.sourceText, sourceOrientation: item.sourceOrientation)
            result.append([
                "keptLettering": true,
                "id": "kept-" + String(item.stableRegionID ?? UInt64(offset)),
                "sourceBounds": [item.rect.minX / imageSize.width, item.rect.minY / imageSize.height,
                                 item.rect.width / imageSize.width, item.rect.height / imageSize.height],
                "sourcePolygon": item.sourcePolygon.map { [$0.x / imageSize.width, $0.y / imageSize.height] },
                "sourceFrame": [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height],
                "sourceFontSize": BrowserOverlayTypography.sourceSize(text: item.sourceText, rect: source) as Any? ?? NSNull(),
                "fontScript": BrowserOverlayTextFlow.fontScript(for: text).rawValue,
                "vertical": BrowserOverlayTextFlow.displayedTextUsesVerticalLayout(
                    item: item, sourceIsVertical: sourceVertical, targetLanguage: targetLanguage),
                "sourceVertical": sourceVertical,
            ])
        }
        return result
    }

}
