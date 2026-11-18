#!/usr/bin/env python3
"""Private host contract check. Real cohort search/Core Text, minimal Card carrier.

Never certifies a group, renders a production page, or touches the shared cache.
Only the unrelated Card audit extension is omitted from temporary typography.
"""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"


def section(source, first, last):
    start = source.index(first)
    return source[start:source.index(last, start)]


cohort = (OVERLAY / "NativeTranslationRenderer+CohortTextBoxes.swift").read_text()
typography = (OVERLAY / "NativeTranslationTypography.swift").read_text()
typography = typography.replace(section(typography,
    "/// Scalar-only actual Card observer.", "extension NativeTranslationTypography {"), "")
commit = (OVERLAY / "NativeTranslationRenderer+CohortTextCommit.swift").read_text()
textboxes = (OVERLAY / "NativeTranslationRenderer+TextBoxes.swift").read_text()
helpers = section(commit, "    static func cohortBackingIsUpright(", "    /// One shared")
helpers += section(textboxes, "    static func uprightTranslatedSourceColumn(", "    static func sourceCaptionTopGroups(")
sources = ["NativeParentheticalNameWrap", "NativeTextPaintGeometry", "NativeCollapsedRowIntrinsicWidth",
    "NativePreLineTextFlow", "NativeNormalTextFlow", "NativeNormalBreakOpportunities", "NativeRawTextBalance",
    "NativeKeepAllBreakOpportunities", "NativeKeepAllAutoLines", "NativeKeepAllTextBalance",
    "NativeCTFontStrokePainter", "NativeCTFontHorizontalFillPainter", "NativeCTFontVerticalPainter",
    "NativeVerticalGlyphOrigins", "NativePreformattedTabs", "NativeVerticalLetterSpacing",
    "NativeVisibleControlGlyphs", "NativeTypographyFontCache", "NativeTranslationFontFitSearch",
    "NativeSmallFontReadabilityPolicy"]

program = r'''
import Foundation
import CoreGraphics
import CoreText
enum BrowserOverlayLayoutPlanner { static let minimumRenderedFontSize: CGFloat = 5 }
struct NativeTranslationLayoutItem {
    var id: String
    var text = "같은 크기의 글자와 문장"
    var typesettingText: String? = nil
    var x: CGFloat = 0, y: CGFloat = 20, width: CGFloat = 100, height: CGFloat = 120
    var rect: CGRect { .init(x: x, y: y, width: width, height: height) }
    var contentRect: CGRect {
        .init(x: x + paddingLeft, y: y + paddingTop,
            width: width - paddingLeft - paddingRight, height: height - paddingTop - paddingBottom)
    }
    var sourceBounds: [CGFloat] = [0, 0.2, 1, 0.6]
    var sourceFrame: [CGFloat] = [0, 0, 100, 100]
    var sourceFontSize: CGFloat? = 8
    var fontSize: CGFloat = 8
    var rotation: CGFloat = 0
    var vertical = false, sourceVertical = true, sourceTextOnly = false, keptLettering = false
    var balloonInterior: Int? = nil, balloonUnit: Int? = nil
    var paddingTop: CGFloat = 4, paddingLeft: CGFloat = 4, paddingRight: CGFloat = 4, paddingBottom: CGFloat = 4
}
enum NativeTranslationRenderer {
    struct Card {
        var item: NativeTranslationLayoutItem
        var style: NativeTranslationTypography.Style
        var typography: NativeTranslationTypography.Layout
        var textOrigin: CGPoint
        var effectiveTextRotation: CGFloat = 0
        var straightenedPanelRect: CGRect? = nil
        var unitTextParts: [String] = []
        var heavyStrokeWidth: CGFloat = 0
        var harmonyRecord: [String: Any] = [:]
    }
    struct TextPaintDomain { let rect: CGRect; let polygon: [CGPoint] }
''' + helpers + r'''
}
typealias R = NativeTranslationRenderer
typealias T = NativeTranslationTypography
var checks = 0
func check(_ v: Bool, _ message: String) {
    checks += 1
    if !v { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
}
let family = "owned-core-fill-repeated-glyph-body-cross-span-v2"
func record(_ span: Double, method: String? = nil, vertical: Bool = true) -> [String: Any] {
    ["supported": true, "method": method ?? family, "logicalCrossSpan": span,
     "logicalUnits": "logical-page-units", "sourceVertical": vertical, "confidence": 0.9]
}
func member(_ id: String, _ span: Double, font: CGFloat = 8, forecast: CGFloat = 8,
            method: String? = nil, vertical: Bool = true) -> R.CohortScaleMember {
    .init(id: id, forecast: forecast, translatedFont: font, sourceVertical: vertical,
        record: record(span, method: method, vertical: vertical))
}
let floorMap: [String: CGFloat] = ["a": 5, "b": 5]
let equal = R.cohortScaleProfile([member("a", 40, font: 6), member("b", 40)])!
check(equal.observedComparable && equal.anchorID == "b" && equal.anchorTranslatedFont == 8, "explicit actual translated anchor")
check(equal.weights == ["a": 1, "b": 1], "body spans are dimensionless, not 40pt fonts")
let equalFrontier = R.cohortScaleFontFrontier(equal, floors: floorMap)!
check(equalFrontier[0] == ["a": 8, "b": 8], "no ink/em absolute assumption")
check(equalFrontier.count == 3, "bounded font frontier")
for factor: Double in [0.001, 0.2, 1, 3, 1000] {
    let p = R.cohortScaleProfile([member("a", 40 * factor, font: 6), member("b", 40 * factor)])!
    check(p.weights == equal.weights, "uniform sample/page scale cannot change hierarchy")
    check(R.cohortScaleFontFrontier(p, floors: floorMap)! == equalFrontier, "frontier scale invariant")
}
let emphasis = R.cohortScaleProfile([member("a", 40), member("b", 80, font: 16)])!
check(emphasis.weights["b"]! / emphasis.weights["a"]! == 2, "intentional 2x remains 2x")
check(R.cohortScaleFontFrontier(emphasis, floors: floorMap)![0] == ["a": 8, "b": 16], "not blanket font average")
let singleUnknown = R.CohortScaleMember(id: "b", forecast: 16, translatedFont: 16, sourceVertical: true, record: nil)
let missing = R.cohortScaleProfile([member("a", 40), singleUnknown])!
check(!missing.observedComparable && missing.weights.count == 2, "missing retains entire group")
check(missing.weights["b"]! / missing.weights["a"]! == 2, "whole-group legacy fallback")
check(missing.observations["a"]!.logicalCrossSpan == 40, "supported observation is not falsified by group fallback")
let mixed = R.cohortScaleProfile([member("a", 40), member("b", 88, method: "owned-colour-cross-ink-v1")])!
check(mixed.unknownReason == "mixed-measurement-families" && mixed.weights.count == 2, "v1/v2 never mixed")
let old = R.cohortScaleProfile([member("a", 40, method: "v1"), member("b", 88, method: "v1")])!
check(old.unknownReason == "uncalibrated-measurement-family", "same v1 does not authorize false body inference")
let direction = R.cohortScaleProfile([member("a", 40), member("b", 40, vertical: false)])!
check(direction.unknownReason == "mixed-source-directions", "original direction not translated horizontal flag")
for bad: Double in [0, -1, .nan, .infinity] {
    let p = R.cohortScaleProfile([member("a", 40), member("b", bad)])!
    check(!p.observedComparable && p.weights.count == 2, "invalid measurement group unknown, never drop")
}
check(R.cohortScaleProfile([member("a", 40), member("a", 40)]) == nil, "duplicate identity rejected")
check(R.cohortScaleProfile([member("a", 40)]) == nil, "no singleton fake group")
check(R.cohortScaleFontFrontier(equal, floors: ["a": 5]) == nil, "partial floor set rejected")
check(R.cohortLegacyFontProxy(forecast: 8, requested: 12)!.value == 8, "adapter uses immutable forecast")
check(R.cohortLegacyFontProxy(forecast: nil, requested: 12)!.value == 12, "explicit requested fallback")
check(R.cohortLegacyFontProxy(forecast: .nan, requested: .nan) == nil, "no zero/error substitution")
let firstFrame = R.cohortImmutableSourceFrame([0, 0.2, 1, 0.6], mapping: [0, 0, 100, 100])!
let staggerFrame = R.cohortImmutableSourceFrame([0, 0.25, 1, 0.6], mapping: [102, 0, 100, 100])!
check(staggerFrame.minY - firstFrame.minY == 5, "intentional source stagger preserved")
let spatial = R.cohortSpatialRelationConfidence(firstFrame, unitA: 8, staggerFrame, unitB: 8)!
check(spatial > 0.55, "frozen spatial relation")
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, .process, nil)
check(T.isBundledSerifAvailable, "real bundled font")
func card(_ id: String, x: CGFloat, font: CGFloat, span: Double) -> R.Card {
    var item = NativeTranslationLayoutItem(id: id)
    item.x = x; item.sourceFrame[0] = x; item.fontSize = font
    let s = T.Style(fontName: "AidokuSerifKR-Bold", fontScript: "korean", fontSize: font,
        outline: CGColor(gray: 1, alpha: 1), outlineWidth: 0.25,
        lineHeight: font * 1.7, horizontalWrapping: .keepAllWithEmergency)
    let layout = T.layout(text: item.text, in: item.contentRect.size, style: s)
    return .init(item: item, style: s, typography: layout, textOrigin: item.contentRect.origin,
        harmonyRecord: ["observedSourceLetteringScale": record(span)])
}
var cards = [card("a", x: 0, font: 6, span: 40), card("b", x: 102, font: 8, span: 40)]
func domain(_ c: R.Card) -> R.CohortTextDomain {
    R.cohortTextDomain(card: c, certifiedTextSpace: .init(rect: c.item.rect, polygon: []),
        frames: [c.item.rect], protectedRects: [], minimumFontSize: 5)!
}
let domains = Dictionary(uniqueKeysWithValues: cards.map { ($0.item.id, domain($0)) })
check(domains["a"]!.sourceFontProxy == 8 && domains["b"]!.sourceFontProxy == 8, "actual adapter never selects body span as em")
check(cards[0].harmonyRecord["observedSourceLetteringScale"] != nil, "observation preserved")
var anchored = cards[0]; anchored.harmonyRecord["sourceTopObservedInkAnchor"] = 30.0
check(domain(anchored).sourceFrame.minY == 20, "domain source frame stays immutable")
check(domain(anchored).observedTypographyAnchor?.top == 30, "supported top recorded separately")
check(domain(anchored).typographyFrame.minY == 20, "unproposed observed anchor cannot affect geometry")
check(R.cohortImmutableSourceFrame(anchored.item.sourceBounds, mapping: anchored.item.sourceFrame)!.minY == 20,
    "observed top cannot redefine relation frame")
for method in [family, "owned-colour-cross-ink-v1"] {
    for top: Double in [20, 25, 30, 40] {
        for factor: Double in [0.1, 1, 100] {
            var a = cards[0], b = cards[1]
            a.harmonyRecord["observedSourceLetteringScale"] = record(40 * factor, method: method)
            b.harmonyRecord["observedSourceLetteringScale"] = record(40 * factor, method: method)
            a.harmonyRecord["sourceTopObservedInkAnchor"] = top
            b.harmonyRecord["sourceTopObservedInkAnchor"] = top + 5
            b.item.sourceBounds[1] = 0.25
            let da = domain(a), db = domain(b)
            check(da.sourceFrame == firstFrame && db.sourceFrame == staggerFrame, "family/top/scale cannot alter domain frame")
            check(R.cohortSpatialRelationConfidence(da.sourceFrame, unitA: da.spatialUnit,
                db.sourceFrame, unitB: db.spatialUnit) == spatial, "family/top/scale cannot alter spatial relation")
            check(a.item.sourceFontSize == 8 && b.item.sourceFontSize == 8, "forecast remains immutable")
        }
    }
}
let placements = cards.enumerated().map {
    R.cohortPlacement(index: $0.offset, card: $0.element, domain: domains[$0.element.item.id]!,
        frame: $0.element.item.rect, origin: $0.element.textOrigin, style: $0.element.style,
        layout: $0.element.typography, baseline: true)!
}
check(placements.allSatisfy { $0.completenessDebt == 0 && $0.baselineObserved }, "native complete baseline witness")
let edges = [R.CohortTextRelation(firstID: "a", secondID: "b", confidence: spatial)]
let unknownObjective = R.cohortObjective(placements, domains: domains, relations: edges,
    observedRelations: edges, hierarchyWeights: nil, explicitHierarchy: true)
check(unknownObjective[3] == nil, "unknown group observed hierarchy is nil, not zero")
let knownObjective = R.cohortObjective(placements, domains: domains, relations: edges,
    observedRelations: edges, hierarchyWeights: equal.weights, explicitHierarchy: true)
check(abs(knownObjective[3]! - abs(log(6.0 / 8))) < 1e-8, "dimensionless measured hierarchy objective")
for enable in [false, true] {
    var budget = R.CohortTextBudget(), probes: [R.CohortTextProposal] = []
    let commits = try R.improveCohortTextBoxes(cards: cards, domains: domains, budget: &budget,
        useObservedFamilyRatios: enable, certifyGroup: { proposal in probes.append(proposal); return false })
    check(commits.isEmpty, "no fake full-group certificate")
    check(budget.reasonCounts["groups"] == 1, "real group search reached")
    check(budget.shapedCandidates > 0, "actual native font frontier shaped")
    check(budget.reasonCounts["observedFamilyComparableGroups"] == 1, "real Card group parsing")
    check(!probes.isEmpty, "actual shaped proposals reached rejecting external certificate")
    for p in probes {
        check(p.scaleProfile?.observedComparable == true && p.observedRatiosUsed == enable, "proposed provenance")
        check(p.placements.count == 2, "never certify subset")
        check(p.placements.allSatisfy { $0.completenessDebt == 0 && $0.layout.fits }, "candidate raw shaping remains gated")
    }
    print("SEARCH observed=\(enable) capturedProposals=\(probes.count) shaped=\(budget.shapedCandidates) reasons=\(budget.reasonCounts)")
}
// Entire-group top activation and fallback are independent of the spatial graph.
for mixedFamily in [false, true] {
    var topCards = cards
    topCards[0].harmonyRecord["sourceTopObservedInkAnchor"] = 30.0
    topCards[1].harmonyRecord["sourceTopObservedInkAnchor"] = 35.0
    if mixedFamily { topCards[1].harmonyRecord["observedSourceLetteringScale"] = record(88, method: "v1") }
    let ds = Dictionary(uniqueKeysWithValues: topCards.map { ($0.item.id, domain($0)) })
    var budget = R.CohortTextBudget()
    let committed = try R.improveCohortTextBoxes(cards: topCards, domains: ds, budget: &budget,
        useObservedFamilyRatios: true, certifyGroup: { p in
            check(!mixedFamily && p.observedRatiosUsed, "second pass admits only complete observed family")
            check(p.proposedTypographyAnchors.count == 2, "anchor activates for complete observed family")
            return false
        })
    check(committed.isEmpty, "anchor proposals do not forge commit")
    check(budget.reasonCounts["groups"] == 1 && budget.reasonCounts["relationsAccepted"] == 1,
        "changed tops/family preserve actual frozen group")
    check(budget.reasonCounts[mixedFamily ? "observedFamilySecondPassWithheld" : "comparableObservedTypographyAnchorsUsed"] == 1,
        "whole-group second-pass decision explicit")
}
check(cards.map { $0.item.sourceFontSize! } == [8, 8], "immutable source forecasts")
var independentlyAllocated = 0
for width: CGFloat in [12, 18, 24, 48, 80] {
    var carrier = cards[0]
    carrier.item.text = "글자의 외곽선과 안전한 배치"
    var paint = carrier.style
    paint.fontSize = 8; paint.lineHeight = 18
    paint.outline = CGColor(gray: 1, alpha: 1); paint.outlineWidth = 4
    let measured = T.layout(text: carrier.item.text, in: CGSize(width: width, height: 200), style: paint)
    if !measured.fits && T.committedParagraphRawComplete(measured, original: carrier.item.text) {
        let allocation = CGRect(x: -20, y: -20, width: 260, height: 300)
        let placed = R.cohortPlacement(index: 0, card: carrier, domain: domains["a"]!,
            frame: allocation, origin: .zero, style: paint, layout: measured)
        if let placed {
            check(placed.completenessDebt == 0 && !placed.layout.fits,
                "raw completeness and allocated ink do not fabricate advance fits")
            independentlyAllocated += 1
            let clipped = T.layout(text: carrier.item.text, in: CGSize(width: width, height: 2), style: paint)
            check(R.cohortPlacement(index: 0, card: carrier, domain: domains["a"]!,
                frame: allocation, origin: .zero, style: paint, layout: clipped) == nil,
                "large allocation cannot restore actually missing CT rows")
            check(R.cohortPlacement(index: 0, card: carrier, domain: domains["a"]!,
                frame: CGRect(x: 0, y: 0, width: 1, height: 1), origin: .zero, style: paint, layout: measured) == nil,
                "raw completeness does not waive actual ink capacity")
        }
    }
}
check(independentlyAllocated > 0, "real Core Text advance-fail/raw-complete fixture reached")
print("PASS \(checks) family-contract checks; full production cohort search compiled, private Core Text shaping; zero certified groups")
'''

with tempfile.TemporaryDirectory(prefix="aidoku-cohort-family-") as directory:
    private = Path(directory)
    (private / "main.swift").write_text(program)
    (private / "Typography.swift").write_text(typography)
    started = time.monotonic()
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(private / "modules"),
        str(private / "main.swift"), str(private / "Typography.swift"),
        str(OVERLAY / "NativeTranslationRenderer+CohortTextBoxes.swift"),
        *[str(OVERLAY / (s + ".swift")) for s in sources], "-o", str(private / "probe")], check=True)
    print(f"private compile seconds={time.monotonic() - started:.3f}", flush=True)
    started = time.monotonic()
    subprocess.run([str(private / "probe"), str(ROOT / "Aidoku/Resources/Translation/AidokuSerifKR-Bold.woff2")], check=True)
    print(f"test body seconds={time.monotonic() - started:.3f}")
