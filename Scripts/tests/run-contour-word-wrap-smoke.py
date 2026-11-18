#!/usr/bin/env python3
"""Parent-run real-CoreText contour tests. Synthetic masks only, no corpus/RGB.

Compiles exact production sources in a private incremental host cache. Never
builds the shared renderer/iOS, alters source lists, or emits image artifacts.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble"
SOURCES = ["NativeLineBreakPolicy", "NativeNecessaryCJKBreaks", "NativeTextSpacing",
           "NativeRenderWrapQuality", "NativeWholeWordWrap", "NativeWholeWordWrap+Proposals", "NativeTextExpansionPolicy",
           "NativeTextPlacementGuide", "NativeSourceClusterAlignment", "NativeSourceCohortPacking", "NativeContourWordWrap"]

PROGRAM = r'''
import Foundation
import CoreText
import CoreGraphics

enum Smoke {
    static var checks = 0
    static func require(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    static let font = CTFontCreateWithName("Menlo-Regular" as CFString, 20, nil)
    static let color = CGColor(srgbRed: 0.15, green: 0.28, blue: 0.43, alpha: 1)
    static let page = CGRect(x: 0, y: 0, width: 400, height: 240)
    static let anchor = CGRect(x: 180, y: 110, width: 40, height: 20)
    static let text = "aa bbbb cccc dd"
    static let old = [NSRange(location: 0, length: 5), NSRange(location: 5, length: 10)]
    static let pitch: CGFloat = 36
    static let halo: CGFloat = 1
    static func measure(_ value: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            .init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): color]))
        return NativeRenderWrapQuality.joinedLineWidth(line)
    }
    static var width: CGFloat { measure("bbbb cccc") + 0.5 }
    static func seed(_ value: String = text) throws -> NativeWholeWordWrap.Result {
        try NativeWholeWordWrap.layoutInternal(text: value, font: font, size: 20,
            width: width, captionBoundaryRules:false, color: color, necessaryCJK: true, preferWholeWords: true)
    }
    static func metrics(_ wrapped: NativeWholeWordWrap.Result) -> (CGFloat, CGFloat) {
        (max(CTFontGetAscent(font), wrapped.rows.map(\.upperExtent).max() ?? 0),
         max(CTFontGetDescent(font), wrapped.rows.map(\.lowerExtent).max() ?? 0))
    }
    static func policy(_ rows: [[Double]], page: CGRect = page) -> NativeTextExpansionPolicy {
        NativeTextExpansionPolicy(allowedRectNormalized: [0, 0, 1, 1], candidates: [[0, 0, 1, 1]],
            maskCoverage: [1], backgroundRisk: [0], sourceFontPixels: 20, kind: "inside-balloon-mask",
            maskRectNormalized: [0, 0, 1, 1],
            maskSpansNormalized: rows.flatMap { row in [row.first ?? 0, row.last ?? 0] },
            maskIntervalRowsNormalized: rows)
    }
    static func contour() throws -> NativeTextExpansionPolicy {
        let (upper, lower) = metrics(try seed())
        let middleTop = anchor.midY - (upper + lower) / 2 - halo - 2
        let middleBottom = anchor.midY + (upper + lower) / 2 + halo + 2
        let narrow = measure("aa") + 0.5 + 2 * (halo + 2)
        let broad = width + 2 * (halo + 2) + 1
        return policy((0..<Int(page.height)).map { y in
            // Pixel bands intersecting the complete middle styled row are wide.
            let w = CGFloat(y + 1) > middleTop && CGFloat(y) < middleBottom ? broad : narrow
            return [Double((anchor.midX - w / 2) / page.width), Double((anchor.midX + w / 2) / page.width)]
        })
    }
    static func proposal(_ p: NativeTextExpansionPolicy, value: String = text,
                         ranges: [NSRange] = old, contentWidth: CGFloat = width,
                         factory: ((NSAttributedString) -> CTLine)? = nil) throws -> NativeContourWordWrap.Proposal? {
        try NativeContourWordWrap.layout(text: value, font: font, size: 20, width: contentWidth,
            pitch: pitch, outwardExtent: halo, policy: p, page: page, anchor: anchor,
            originalRanges: ranges, color: color, lineFactory: factory)
    }
    static func centredInk(_ wrapped: NativeWholeWordWrap.Result, step: CGFloat = pitch) -> [CGRect] {
        let upper = wrapped.rows.map(\.upperExtent).max()!
        let local = wrapped.rows.enumerated().map { i, row -> CGRect in
            let ink = CTLineGetImageBounds(row.line, nil).union(row.inkBounds)
            return CGRect(x: row.centeredBaselineX(width: width) + ink.minX,
                y: upper + CGFloat(i) * step - ink.maxY, width: ink.width, height: ink.height)
        }
        let block = local.reduce(CGRect.null) { $0.union($1) }
        return local.map { $0.offsetBy(dx: anchor.midX - block.midX, dy: anchor.midY - block.midY) }
    }
    static func bandsFit(_ wrapped: NativeWholeWordWrap.Result, _ p: NativeTextExpansionPolicy) -> Bool {
        centredInk(wrapped).allSatisfy { p.allows($0.insetBy(dx: -halo - 2, dy: -halo - 2), page: page) }
    }
    static func ownership(_ wrapped: NativeWholeWordWrap.Result) {
        require(wrapped.text == text && wrapped.attributedText.string == text, "canonical text unchanged")
        require(wrapped.completeOwnership && wrapped.unresolvedGlyphRanges.isEmpty, "all glyphs owned/resolved")
        require(wrapped.appliedTracking == 0 && wrapped.requestedFontSize == 20, "same size / zero tracking")
        require(wrapped.requestedFontName == CTFontCopyPostScriptName(font) as String, "same face")
        let ns = text as NSString
        var cursor = 0
        var recovered = ""
        let boundaries = Set([0] + wrapped.graphemeRanges.map(NSMaxRange))
        let legal = NativeLineBreakPolicy.legalOffsets(text: text)
        for row in wrapped.rows {
            require(row.ownedRange.location == cursor && boundaries.contains(NSMaxRange(row.ownedRange)), "contiguous grapheme ownership")
            cursor = NSMaxRange(row.ownedRange)
            require(cursor == ns.length || legal.contains(cursor), "protected legal boundary")
            recovered += ns.substring(with: row.ownedRange)
            for run in CTLineGetGlyphRuns(row.line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let actualFont = attrs[kCTFontAttributeName] as! CTFont
                let actualColor = attrs[kCTForegroundColorAttributeName] as! CGColor
                require(CTFontGetSize(actualFont) == 20 && actualColor == color, "actual line font/color preserved")
            }
        }
        require(cursor == ns.length && recovered == text, "exact UTF16 partition")
    }
    // Draw the returned actual CTLines without exporting/viewing an image.
    // Every nonzero fill alpha and its synthetic 1px halo must fit the mask.
    static func alphaFits(_ wrapped: NativeWholeWordWrap.Result, _ p: NativeTextExpansionPolicy) {
        let w = Int(page.width), h = Int(page.height)
        var bytes = [UInt8](repeating: 0, count: w * h)
        let (upper, lower) = metrics(wrapped)
        let local = wrapped.rows.enumerated().map { i, row -> CGRect in
            let ink = CTLineGetImageBounds(row.line, nil).union(row.inkBounds)
            return CGRect(x: row.centeredBaselineX(width: width) + ink.minX,
                y: upper + CGFloat(i) * pitch - ink.maxY, width: ink.width, height: ink.height)
        }
        let block = local.reduce(CGRect.null) { $0.union($1) }
        let dx = anchor.midX - block.midX, dy = anchor.midY - block.midY
        var pixels = 0
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            context.setFillColor(gray: 1, alpha: 1)
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for (i, row) in wrapped.rows.enumerated() {
                context.textPosition = CGPoint(x: dx + row.centeredBaselineX(width: width),
                    y: dy + upper + CGFloat(i) * pitch)
                CTLineDraw(row.line, context)
            }
        }
        // Grayscale intensity is nonzero support here (opaque coloured fill on
        // initially zero buffer), with no threshold dropping faint samples.
        for y in 0..<h {
            for x in 0..<w where bytes[y * w + x] > 0 {
                pixels += 1
                require(p.allows(CGRect(x: x - 1, y: y - 1, width: 3, height: 3), page: page), "actual fill+halo stays in contour")
            }
        }
        require(pixels > 0, "real CoreText raster nonempty")
    }
    static func run() async throws {
        let p = try contour()
        require(p.valid, "valid synthetic contour")
        let ordinary = try seed()
        require(!bandsFit(ordinary, p), "uniform-width production partition fails contour")
        guard let result = try proposal(p) else { fatalError("contour proposal missing") }
        ownership(result.wrapped)
        require(result.wrapped.rows.count == 3, "narrow/wide/narrow three-row partition")
        require(NativeRenderWrapQuality.wordCutOffsets(text, ranges: result.wrapped.rows.map(\.ownedRange)).isEmpty,
            "strict inherited-cut improvement to zero")
        require(bandsFit(result.wrapped, p), "all row-specific styled bands fit")
        require(result.diagnostics["physicalContainmentCertified"] as? Bool == false, "no physical claim")
        require((result.diagnostics["shapingCallsIncludingProductionSeed"] as? Int ?? Int.max) <= 4096, "total shaping budget")
        require((result.diagnostics["transitions"] as? Int ?? Int.max) <= 262144, "DP work budget")
        alphaFits(result.wrapped, p)

        // Replay's retained pitch is not a fresh natural baselineStep. A safe
        // non-quantized pitch below that natural step must survive unchanged.
        let (u, l) = metrics(try seed())
        let retained = u + l + 2 * halo + 1 + 0.005
        require(NativeTextSpacing.baselineStep(fontSize: 20, bodyHeight: u + l, leading: 0,
            outwardExtent: halo, minimumLineHeight: retained) > retained + 0.01, "fixture exposes old pitch veto")
        let full = policy([[Double]](repeating: [0.1, 0.9], count: 240))
        let retainedResult = try NativeContourWordWrap.layout(text: text, font: font, size: 20, width: width,
            pitch: retained, outwardExtent: halo, policy: full, page: page, anchor: anchor,
            originalRanges: old, color: color)
        require(retainedResult != nil, "safe exact retained pitch accepted without requantization")
        require(retainedResult!.wrapped.rows.allSatisfy { $0.ascent == u && $0.descent == l }, "full font metrics unchanged")
        require(retainedResult!.diagnostics["pitchPixels"] as? Double == Double(retained), "exact retained pitch receipt")
        require(try NativeContourWordWrap.layout(text: text, font: font, size: 20, width: width,
            pitch: u + l + 2 * halo + 1 - 0.02, outwardExtent: halo, policy: full, page: page, anchor: anchor,
            originalRanges: old, color: color) == nil, "existing retained-pitch safety floor still enforced")

        // A vertically tight room fits actual ink, not a transparent font slab.
        // Initial seed profile fits; exact partition must be independently checked.
        let seedInks = ordinary.rows.map { CTLineGetImageBounds($0.line, nil).union($0.inkBounds) }
        let inkHeight = seedInks.map(\.maxY).max()! - seedInks.map(\.minY).min()!
        let tightHeight = inkHeight + pitch + 2 * (halo + 2) + 0.5
        let tight = NativeTextExpansionPolicy(allowedRectNormalized: [0, 0, 1, 1], candidates: [[0, 0, 1, 1]],
            maskCoverage: [1], backgroundRisk: [0], sourceFontPixels: 20, kind: "inside-balloon-mask",
            maskRectNormalized: [0, Double((anchor.midY - tightHeight / 2) / page.height), 1, Double(tightHeight / page.height)],
            maskSpansNormalized: [0.1, 0.9, 0.1, 0.9])
        require(u + l + pitch + 2 * (halo + 2) > tightHeight, "font slab fails tight room")
        guard let inkResult = try proposal(tight) else { fatalError("actual ink-centred tight-room rescue missing") }
        require(inkResult.wrapped.rows.count == 2 && bandsFit(inkResult.wrapped, tight), "exact centred ink fits tight room")
        require(inkResult.diagnostics["exactPartitionInkBandsValidated"] as? Bool == true, "complete partition independently validated")
        require((inkResult.diagnostics["profilePasses"] as? Int ?? Int.max) <= 3 * 7, "bounded replan budget shared")
        alphaFits(inkResult.wrapped, tight)

        let divided = policy([[Double]](repeating: [0.1, 0.48, 0.52, 0.9], count: 240))
        require(divided.valid, "disjoint interval fixture valid")
        require(try proposal(divided) == nil, "centre hole cannot be bridged by lobe union")
        let blocked = policy([[Double]](repeating: [], count: 240))
        require(try proposal(blocked) == nil, "empty centre mask abstains")
        for hard in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}", "\u{00AD}"] {
            var calls = 0
            let hardText = "aabb" + hard + "cccc"
            let hardRanges = [NSRange(location: 0, length: 2), NSRange(location: 2, length: hardText.utf16.count - 2)]
            let candidate = try proposal(p, value: hardText, ranges: hardRanges) { value in
                calls += 1; return CTLineCreateWithAttributedString(value)
            }
            require(candidate == nil && calls == 0, "hardbreak/soft hyphen abstains before shaping")
        }
        for invalid in [[NSRange(location: 0, length: Int.max)],
                        [NSRange(location: NSNotFound, length: 1)],
                        [NSRange(location: 0, length: 5), NSRange(location: 6, length: 9)]] {
            require(try proposal(p, ranges: invalid) == nil, "malformed ownership rejected")
        }
        require(try proposal(p, contentWidth: .nan) == nil, "nonfinite geometry rejected")
        require(try proposal(p, ranges: [NSRange(location: 0, length: text.utf16.count)]) == nil, "no cuts means no proposal")
        let longWord = "가나다라마바사 아"
        let fragmented = [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2),
                          NSRange(location: 4, length: 2), NSRange(location: 6, length: 3)]
        let flat = policy([[Double]](repeating: [0.1, 0.9], count: 240))
        guard let partial = try proposal(flat, value: longWord, ranges: fragmented, contentWidth: measure("가나다라") + 0.5)
        else { fatalError("necessary-CJK partial repair missing") }
        let cutsAfter = NativeRenderWrapQuality.wordCutOffsets(longWord, ranges: partial.wrapped.rows.map(\.ownedRange)).count
        require(cutsAfter > 0 && cutsAfter < 3, "unavoidably overwide word permits partial strict improvement")
        require(partial.wrapped.rows.reduce("") { $0 + (longWord as NSString).substring(with: $1.ownedRange) } == longWord,
            "necessary-CJK keeps exact original text")
        var budgetCalls = 0
        let huge = String(repeating: "가", count: 97)
        require(try proposal(p, value: huge, ranges: [NSRange(location: 0, length: 48), NSRange(location: 48, length: 49)]) { value in
            budgetCalls += 1; return CTLineCreateWithAttributedString(value)
        } == nil && budgetCalls == 0, "grapheme budget abstains before work")
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try proposal(p); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancellationPropagated = await cancelled.value
        require(cancellationPropagated, "task cancellation propagates")

        // Repeat uses independent caches and must be deterministic; the input
        // attributed carrier and ordinary wrapper were never mutated.
        let repeated = try proposal(p)!
        require(repeated.wrapped.rows.map(\.ownedRange) == result.wrapped.rows.map(\.ownedRange), "deterministic scalar DP")
        require(try seed().rows.map(\.ownedRange) == ordinary.rows.map(\.ownedRange), "legacy wrapper unchanged")
        print("PASS \(checks) contour checks; actual CoreText, exact UTF16/font/color, mask holes, budgets, cancellation")
    }
}

@main struct Main {
    static func main() async throws { try await Smoke.run() }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path(os.environ.get("TMPDIR", "/tmp")) / "aidoku-contour-word-wrap-smoke")
    args = parser.parse_args()
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    fixture = cache / "ContourSmoke.swift"
    if not fixture.exists() or fixture.read_text() != PROGRAM:
        fixture.write_text(PROGRAM)
    binary = cache / "contour-smoke"
    sources = [ENGINE / (name + ".swift") for name in SOURCES]
    inputs = sources + [fixture]
    mapping = {str(p): {"object": str(cache / (p.stem + ".o")),
                        "swift-dependencies": str(cache / (p.stem + ".swiftdeps"))} for p in inputs}
    mapping[""] = {"swift-dependencies": str(cache / "master.swiftdeps")}
    output_map = cache / "output-map.json"
    value = json.dumps(mapping, sort_keys=True)
    if not output_map.exists() or output_map.read_text() != value:
        output_map.write_text(value)
    started = time.perf_counter()
    subprocess.run(["xcrun", "swiftc", "-O", "-incremental", "-enable-batch-mode", "-j2",
                    "-module-name", "ContourWordSmoke", "-output-file-map", str(output_map),
                    "-parse-as-library", "-module-cache-path", str(cache / "modules"),
                    *map(str, inputs), "-o", str(binary)], check=True)
    compiled = time.perf_counter()
    subprocess.run([str(binary)], check=True)
    finished = time.perf_counter()
    print(json.dumps({"buildSeconds": compiled - started, "testSeconds": finished - compiled,
                      "binary": str(binary), "fixture": str(fixture),
                      "sourceSHA256": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}, indent=2))


if __name__ == "__main__":
    main()
