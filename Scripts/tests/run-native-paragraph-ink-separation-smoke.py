#!/usr/bin/env python3
"""Run unchanged paragraph-separation and surface production sources on macOS.

Card/shaping, color functions, native admission and the unused balloon-interior
input type are minimal shims. Callback tests verify decision wiring, NOT alpha
measurement or source-color accuracy; those require actual renderer fixtures.
Surface.contains itself is production code. This checks geometry, not raster output
or the renderer's end-to-end stage wiring. All compiler caches are temporary.
"""

from pathlib import Path
import os
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"

HARNESS = r'''
import Foundation
import CoreGraphics

// Keep actionable assertion messages even in an optimized standalone executable.
func precondition(_ condition: @autoclosure () -> Bool,
                  _ message: @autoclosure () -> String = "assertion failed",
                  line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL at harness line \(line): \(message())\n".utf8))
        exit(1)
    }
}

// Only needed to typecheck the unused containment.known entry point.
struct NativeTranslationBalloonInterior {
    var contourVerified: Bool
    var rect: [Double]
    var spans: [Double]
    var normalizedRect: CGRect
}

enum NativeSourceBootstrapBirth {
    struct Admission {
        var accepted: Bool
        var reason: String
    }
}

enum NativeTranslationRenderer {
    struct Item: Equatable {
        var id: String
        var contentRect: CGRect
        var rect: CGRect
        var text = "번역 문단"
        var rotation: CGFloat = 0
    }
    struct Typography: Equatable {
        var glyphBounds: [CGRect]
        var fontName = "FixtureSerif"
        var fontSize: CGFloat = 17
    }
    struct Style: Equatable {
        enum PaintOrder { case strokeThenFill }
        var outlineGlow: CGFloat = 0
        var fontSize: CGFloat = 17
        var fill = [0.1, 0.2, 0.3, 1]
        var stroke = [0.9, 0.8, 0.7, 1]
        var foreground: CGColor? { CGColor(gray: fill[0], alpha: fill[3]) }
        var outline: CGColor? { nil }
        var outlineWidth: CGFloat = 0
        var outlinePaintOrder = PaintOrder.strokeThenFill
    }
    struct Card {
        var item: Item
        var typography: Typography
        var style = Style()
        var textShift = CGPoint(x: 3, y: -2)
        var textOrigin: CGPoint {
            CGPoint(x: item.contentRect.minX + textShift.x, y: item.contentRect.minY + textShift.y)
        }
        var sourcePlateOwnerRect: CGRect?
        var sourcePlateRect: CGRect { sourcePlateOwnerRect ?? item.rect }
        var effectiveTextRotation: CGFloat = 0
        var unitTextParts: [CGRect] = []
        var textPaintDomain: CGRect?
        var sourcePanels: [CGRect]
        var drawsPanel = true
        var background = CGColor(gray: 0.9, alpha: 1) // Opaque, unchanged rectangular panel.
        var straightenedPanelRect: CGRect?
        var sourceBackgroundKind = "solid-text-box"
        var usesFallbackVeil = false
        var finalFontSize: CGFloat = 17
        var harmonyRecord: [String: Any] = ["existing": "preserve-me"]
    }
    static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
            && [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
    }
    static func rgb(_ color: CGColor?) -> [Double]? {
        guard let c = color?.components, c.count >= 2 else { return nil }
        return c.count == 2 ? Array(repeating: Double(c[0]), count: 3) : c.prefix(3).map(Double.init)
    }
    // Minimal color shims: geometry/callback controls do not certify this policy.
    static func textBoxFillContrast(_ fill: [Double], panel: [Double]) -> Double {
        func y(_ values: [Double]) -> Double {
            zip(values, [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
                let v = pair.0
                return sum + (v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) * pair.1
            }
        }
        let a = y(fill), b = y(panel)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    static func textBoxOutlineSupportsForeground(_ fill: [Double], panel: [Double], outline: [Double]?,
                                                visibleOutlinePixels: Double, opaqueStrokeThenFill: Bool) -> Bool {
        false // These fixtures deliberately have no outline.
    }
}

typealias Card = NativeTranslationRenderer.Card
typealias Surface = NativeTextBoxContainment.Surface
func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}
func card(_ id: String, ink: CGRect, plate: CGRect) -> Card {
    // A nonzero local glyph origin AND initial shift catch incorrect origin math.
    Card(item: .init(id: id, contentRect: box(ink.minX - 5, ink.minY + 1, 30, 30), rect: plate),
         typography: .init(glyphBounds: [box(2, 1, ink.width, ink.height)]), sourcePanels: [plate])
}
func ink(_ card: Card) -> [CGRect] {
    card.typography.glyphBounds.map {
        $0.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)
            .insetBy(dx: -card.style.outlineGlow, dy: -card.style.outlineGlow)
    }
}
func bounds(_ card: Card) -> CGRect { ink(card).reduce(CGRect.null) { $0.union($1) } }
func area(_ rect: CGRect) -> CGFloat {
    NativeTranslationRenderer.valid(rect) ? rect.width * rect.height : 0
}
func hit(_ a: Card, _ b: Card) -> CGFloat {
    ink(a).reduce(0) { sum, a in sum + ink(b).reduce(0) { $0 + area(a.intersection($1)) } }
}
func clearance(_ a: CGRect, _ b: CGRect) -> CGFloat {
    max(b.minX - a.maxX, a.minX - b.maxX, b.minY - a.maxY, a.minY - b.maxY)
}
func surface(_ rect: CGRect, left: CGFloat, right: CGFloat) -> Surface {
    Surface(rect: rect, spans: Array(repeating: (left, right), count: 20), color: nil)
}
var checked = 0
func run(_ name: String, _ before: [Card], scale: CGFloat = 1,
         surfaces: [String: Surface] = [:], kept: [CGRect] = []) throws -> [Card] {
    var after = before
    try NativeTranslationRenderer.separateParagraphInk(cards: &after, surfaces: surfaces,
                                                        keptOwners: kept, outputScale: scale)
    precondition(before.count == after.count, name)
    let gap = 1 / max(0.001, scale)
    for i in before.indices {
        let old = before[i], new = after[i]
        precondition(old.item == new.item && old.typography == new.typography && old.style == new.style,
                     "\(name): text, glyphs, font or colors changed")
        precondition(old.sourcePlateRect == new.sourcePlateRect && old.sourcePlateOwnerRect == new.sourcePlateOwnerRect
            && old.sourcePanels == new.sourcePanels && old.background == new.background
            && old.drawsPanel == new.drawsPanel && old.finalFontSize == new.finalFontSize,
                     "\(name): opaque panel or font fields changed")
        precondition(old.effectiveTextRotation == new.effectiveTextRotation
            && old.unitTextParts == new.unitTextParts && old.textPaintDomain == new.textPaintDomain, name)
        var metadata = new.harmonyRecord
        metadata.removeValue(forKey: "paragraphInkSeparationShift")
        precondition(NSDictionary(dictionary: metadata).isEqual(to: old.harmonyRecord),
                     "\(name): existing metadata changed")
        if old.textShift != new.textShift {
            let delta = CGPoint(x: new.textShift.x - old.textShift.x, y: new.textShift.y - old.textShift.y)
            let recorded = new.harmonyRecord["paragraphInkSeparationShift"] as? [Double]
            precondition(recorded == [Double(delta.x), Double(delta.y)], "\(name): shift metadata")
            precondition(new.sourcePlateRect.contains(bounds(new).insetBy(dx: -gap, dy: -gap)),
                         "\(name): output-pixel panel clearance")
            precondition(surfaces[new.item.id]?.contains(bounds(new)) ?? true, "\(name): surface escape")
        } else {
            precondition(new.harmonyRecord["paragraphInkSeparationShift"] == nil, "\(name): false repair metadata")
        }
        for owner in kept {
            precondition(area(bounds(new).intersection(owner)) <= area(bounds(old).intersection(owner)) + 1e-9,
                         "\(name): increased kept-owner contact")
        }
        for j in before.indices where j > i {
            precondition(hit(new, after[j]) <= hit(old, before[j]) + 1e-9,
                         "\(name): increased/new peer overlap")
        }
    }
    checked += 1
    print("PASS: \(name)")
    return after
}
func pair(scale: CGFloat = 1, glow: CGFloat = 0) -> [Card] {
    let gap = 1 / max(0.001, scale)
    var a = card("a", ink: box(80, 80, 10, 10), plate: box(0, 0, 400, 400))
    var b = card("b", ink: box(80, 80, 12, 12),
                 plate: box(80, 80, 12, 12).insetBy(dx: -gap - glow, dy: -gap - glow))
    a.style.outlineGlow = glow; b.style.outlineGlow = glow
    return [a, b]
}

// Exact glyph contact, outlines, existing shifts, and small/high output scales.
for scale: CGFloat in [0.05, 0.25, 1, 2, 4] {
    for glow: CGFloat in [0, 0.75] {
        let before = pair(scale: scale, glow: glow)
        precondition(hit(before[0], before[1]) > 0)
        let after = try run("exact overlap scale=\(scale) outline=\(glow)", before, scale: scale)
        precondition(hit(after[0], after[1]) == 0, "exact overlap unresolved")
        precondition(clearance(bounds(after[0]), bounds(after[1])) * scale >= 1 - 1e-9,
                     "less than one actual output pixel between painted glyphs")
        precondition(after[0].textShift != before[0].textShift && after[1].textShift == before[1].textShift)
    }
}

// Block the shorter rightward move with a previously disjoint third peer.
var three = pair()
three.append(card("third", ink: box(93, 80, 16, 16), plate: box(92, 79, 18, 18)))
precondition(hit(three[0], three[2]) == 0 && hit(three[1], three[2]) == 0)
let threeAfter = try run("third peer cannot acquire new overlap", three)
precondition(hit(threeAfter[0], threeAfter[1]) == 0)
precondition(threeAfter[0].textShift.x < three[0].textShift.x, "blocked right shift was accepted")

let owners = [box(93, 80, 12, 12), box(82, 82, 2, 2)]
let keptAfter = try run("new and existing kept-owner contacts", pair(), kept: owners)
precondition(hit(keptAfter[0], keptAfter[1]) == 0)
precondition(keptAfter[0].textShift.x < 3, "new kept-owner contact accepted")

var tight = pair()
tight[0].sourcePlateOwnerRect = box(79, 79, 12, 12)
let tightAfter = try run("infeasible panels leave geometry unchanged", tight)
precondition(zip(tight, tightAfter).allSatisfy { $0.textShift == $1.textShift })
precondition(hit(tightAfter[0], tightAfter[1]) == hit(tight[0], tight[1]))

// Glyphs fit at the right panel edge, but the required extra output pixel does not.
var edge = pair()
edge[0].sourcePlateOwnerRect = box(80, 79, 23, 12)
let edgeAfter = try run("panel edge rejects missing output-pixel margin", edge)
precondition(edgeAfter[0].textShift == edge[0].textShift)
edge[0].sourcePlateOwnerRect = box(80, 79, 24, 12)
let edgeControl = try run("one extra panel pixel admits move", edge)
precondition(hit(edgeControl[0], edgeControl[1]) == 0)

// Broad bbox with narrower row spans catches bbox-only containment substitutes.
let narrow = surface(box(0, 79, 400, 14), left: 80, right: 92)
precondition(narrow.contains(bounds(pair()[0])))
let surfaceAfter = try run("surface row boundary rejects all candidates", pair(), surfaces: ["a": narrow])
precondition(zip(pair(), surfaceAfter).allSatisfy { $0.textShift == $1.textShift })
let openLeft = surface(box(0, 79, 400, 14), left: 0, right: 92)
let surfaceControl = try run("surface admits safe leftward move", pair(), surfaces: ["a": openLeft])
precondition(hit(surfaceControl[0], surfaceControl[1]) == 0)

// An unsupported card abstains both as a movement target and as a peer.
for kind in ["rotation", "unit", "independent-domain"] {
    for index in 0...1 {
        var rows = pair()
        switch kind {
        case "rotation": rows[index].effectiveTextRotation = 0.1
        case "unit": rows[index].unitTextParts = [box(80, 80, 10, 10)]
        default: rows[index].textPaintDomain = box(0, 0, 400, 400)
        }
        let after = try run("unsupported \(kind) at index \(index) abstains", rows)
        precondition(zip(rows, after).allSatisfy { $0.textShift == $1.textShift })
    }
}

// Multiple local glyphs retain their shaped spacing after one translation.
var fragments = pair()
fragments[0].typography.glyphBounds = [box(2, 1, 4, 10), box(8, 1, 4, 10)]
let fragmentsAfter = try run("multi-glyph shaped layout preserved", fragments)
precondition(hit(fragmentsAfter[0], fragmentsAfter[1]) < hit(fragments[0], fragments[1]),
             "multi-glyph contact must decrease; one admitted shift need not eliminate every contact")
var disjoint = pair()
disjoint[0].textShift.x -= 30
let disjointAfter = try run("already separated text stays unchanged", disjoint)
precondition(zip(disjoint, disjointAfter).allSatisfy { $0.textShift == $1.textShift })

// Real native alpha is separately fixture-tested; these adversarial callbacks
// establish that rejection/unknown cannot silently authorize a geometry move.
for decision in ["accept", "reject", "unknown"] {
    let before = pair()
    var after = before
    var calls = 0
    try NativeTranslationRenderer.separateParagraphInk(cards: &after, surfaces: [:], keptOwners: [], outputScale: 1,
        admitShift: { candidate, peers in
            calls += 1
            precondition(candidate.textShift != before[0].textShift, "callback saw unmoved candidate")
            precondition(peers.count == 1 && peers[0].item.id == "b", "callback lost peers")
            if decision == "unknown" { return nil }
            return .init(accepted: decision == "accept", reason: "fixture-" + decision)
        })
    precondition(calls > 0, "admission callback not invoked")
    precondition((after[0].textShift != before[0].textShift) == (decision == "accept"), "admission decision ignored")
    let audit = after[0].harmonyRecord["paragraphInkSeparationAudit"] as? [String: Any]
    precondition(audit?["unknownIsPermission"] as? Bool == false, "unknown mislabeled as permission")
    checked += 1
    print("PASS: native callback wiring " + decision)
}
print("PASS: \(checked) native paragraph ink separation cases; actual production Surface.contains")
'''


def main() -> None:
    sources = [
        OVERLAY / "NativeTextBoxContainment.swift",
        OVERLAY / "NativeTranslationRenderer+ParagraphInkSeparation.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="aidoku-paragraph-ink-smoke-") as directory:
        temporary = Path(directory)
        harness = temporary / "main.swift"
        harness.write_text(HARNESS)
        cache = temporary / "module-cache"
        cache.mkdir()
        environment = os.environ.copy()
        environment.update({
            "CLANG_MODULE_CACHE_PATH": str(cache),
            "SWIFT_MODULECACHE_PATH": str(cache),
        })
        executable = temporary / "probe"
        started = time.perf_counter()
        subprocess.run([
            "xcrun", "swiftc", "-O", "-module-cache-path", str(cache),
            *map(str, sources), str(harness), "-o", str(executable),
        ], check=True, cwd=temporary, env=environment)
        compiled = time.perf_counter()
        subprocess.run([str(executable)], check=True, cwd=temporary, env=environment)
        finished = time.perf_counter()
        print(f"Host-only compile: {compiled - started:.2f}s; test process: {finished - compiled:.2f}s")


if __name__ == "__main__":
    main()
