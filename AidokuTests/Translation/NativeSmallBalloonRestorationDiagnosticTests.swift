import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Temporary mandatory trace of the production restore path. The existing real
/// replay retains its complete-erasure, no-panel and centering assertions.
private final class NativeSmallBalloonRestorationFixtureBundle: NSObject {}

@Suite(.serialized)
@MainActor
struct NativeSmallBalloonRestorationDiagnosticTests {
    @Test func capturedLayoutRecordsActualRestorationDecisionsWithoutOCR() throws {
        let bundle = Bundle(for: NativeSmallBalloonRestorationFixtureBundle.self)
        let inputURL = try #require(bundle.url(forResource: "SmallBalloonRestorationOriginal", withExtension: "bin"))
        let payloadURL = try #require(bundle.url(forResource: "SmallBalloonRestorationPayload", withExtension: "json"))
        let input = try Data(contentsOf: inputURL)
        let payloadData = try Data(contentsOf: payloadURL)
        try #require(SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined() == "d43013aeb4d946343b72fb7232e54d154c7d3aa7b032367cdeb60a6cf429acad")
        try #require(SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined() == "360398b12a33064f6c9ca13538da7faee5fc1d608d0558df8fbdfe3615415891")
        let cg = try #require(UIImage(data: input)?.cgImage)
        let payload = try #require(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        let frame = try #require(payload["displayRect"] as? [Double])
        let viewport = try #require(payload["viewport"] as? [Double])
        let size = try #require(payload["imageSize"] as? [Double])
        try #require(frame.count == 4 && viewport.count == 2 && size.count == 2)
        let itemData = try JSONSerialization.data(withJSONObject: try #require(payload["items"]))
        let items = try JSONDecoder().decode([NativeTranslationLayoutItem].self, from: itemData)
        try #require(items.count == 4 && items.contains { $0.id == "2" && $0.rotation != 0 })
        let layout = NativeTranslationLayout(imageSize: CGSize(width: size[0], height: size[1]),
            sourceRect: CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]),
            viewport: CGSize(width: viewport[0], height: viewport[1]), items: items, sourceObjectFit: "contain")
        #expect(layout.imageSize == CGSize(width: cg.width, height: cg.height))
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.inpaintingEnabled = true
        settings.preserveSourceBackgroundColor = true
        settings.preserveSourceTextColor = true
        settings.opacity = 1
        // Execute the actual production pipeline once. No OCR service, network,
        // alternate source crops or test-side repair implementation is involved.
        let rendered = try NativeTranslationRenderer.renderSynchronously(layout: layout, image: UIImage(cgImage: cg),
            settings: settings, scale: CGFloat(try #require(payload["scale"] as? Double)), collectDiagnostics: true)
        let diagnostic = try #require(rendered.diagnosticData)
        let output = URL.documentsDirectory.appendingPathComponent("SmallBalloonRestorationProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try diagnostic.write(to: output.appendingPathComponent("audit.json"))
        try #require(rendered.image.pngData()).write(to: output.appendingPathComponent("render.png"))
        let report = try #require(JSONSerialization.jsonObject(with: diagnostic) as? [String: Any])
        let attempts = try #require(report["restorationAttempts"] as? [[String: Any]])
        let slanted = try #require(attempts.first { $0["id"] as? String == "2" && $0["phase"] as? String == "slanted-preparation" })
        try #require(slanted["reasons"] as? [String])
        try #require(slanted["rasterAvailable"] as? Bool)
        let cards = try #require(report["cards"] as? [[String: Any]])
        let card = try #require(cards.first { $0["id"] as? String == "2" })
        let restored: Bool = try #require(card["restored"] as? Bool)
        let erased: Bool = try #require(card["erasureComplete"] as? Bool)
        try #require(Self.hasTerminalEvidence(restored: restored, erasureComplete: erased, attempts: attempts))
        try captureExactCropGates(image: cg, layout: layout, settings: settings, report: report, directory: output)
        #expect(rendered.renderedItemCount == 4)
        #expect(try Data(contentsOf: inputURL) == input)
        #expect(try Data(contentsOf: payloadURL) == payloadData)
    }
    private static func hasTerminalEvidence(restored: Bool, erasureComplete: Bool, attempts: [[String: Any]]) -> Bool {
        let page = attempts.first { $0["id"] as? String == "2" && $0["phase"] as? String == "slanted-page-admission" }
        if restored { return erasureComplete && page?["admitted"] as? Bool == true && page?["quadProof"] as? Bool == true }
        return !erasureComplete && page?["admitted"] as? Bool == false && attempts.contains {
            $0["id"] as? String == "2" && $0["phase"] as? String == "deferred-forced" && $0["status"] as? String == "rejected"
        }
    }

    @Test func terminalEvidenceCannotDisappearOrContradictTheFinalCard() {
        let success: [[String: Any]] = [["id": "2", "phase": "slanted-page-admission", "admitted": true, "quadProof": true]]
        let rejected: [[String: Any]] = [["id": "2", "phase": "slanted-page-admission", "admitted": false, "quadProof": false],
                                         ["id": "2", "phase": "deferred-forced", "status": "rejected"]]
        #expect(Self.hasTerminalEvidence(restored: true, erasureComplete: true, attempts: success))
        #expect(Self.hasTerminalEvidence(restored: false, erasureComplete: false, attempts: rejected))
        #expect(!Self.hasTerminalEvidence(restored: false, erasureComplete: false, attempts: []))
        #expect(!Self.hasTerminalEvidence(restored: true, erasureComplete: true, attempts: []))
        #expect(!Self.hasTerminalEvidence(restored: false, erasureComplete: false, attempts: success))
        #expect(!Self.hasTerminalEvidence(restored: true, erasureComplete: false, attempts: success))
        #expect(!Self.hasTerminalEvidence(restored: true, erasureComplete: true, attempts: rejected))
        #expect(!Self.hasTerminalEvidence(restored: false, erasureComplete: false, attempts: Array(rejected.prefix(1))))
    }

    /// Re-enter only the two captured crop geometries with the final card sample.
    /// The renderer does not record its initial palette at this seam, so matching
    /// geometry does not certify identical initial color evidence.
    private func captureExactCropGates(image: CGImage, layout: NativeTranslationLayout, settings: IPhoneOverlaySettings,
                                      report: [String: Any], directory: URL) throws {
        let items = layout.items
        let attempts = try #require(report["restorationAttempts"] as? [[String: Any]])
        let cards = try #require(report["cards"] as? [[String: Any]])
        let reader = NativeSourcePixelReader(image: image)
        defer { reader.release() }
        let cropper = NativeSpatialSourceCrop(image: image, reader: reader, eligibleCount: items.count)
        var records: [[String: Any]] = []
        func bounds(_ value: CGRect) -> [Double] { [value.minX, value.minY, value.width, value.height].map(Double.init) }
        func pixels(_ value: NativeRestorationPixels, name: String) throws {
            try Data(value.rgba).write(to: directory.appendingPathComponent(name + ".rgba"))
            let cgImage = try #require(value.image())
            let png = try #require(UIImage(cgImage: cgImage).pngData())
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            if let safe = value.layoutSafe { try Data(safe).write(to: directory.appendingPathComponent(name + ".safe")) }
        }
        func summary(_ value: NativeRestorationPixels?) -> [String: Any] {
            guard let value else { return ["exists": false] }
            return ["exists": true, "painted": value.paintedCount, "method": value.method ?? "",
                    "sourceErasureVerified": value.sourceErasureVerified.map { $0 as Any } ?? NSNull(),
                    "erasureComplete": value.erasureComplete, "glyphsVerified": value.glyphsVerified,
                    "polygonGlyphsVerified": value.polygonGlyphsVerified,
                    "preservedCore": value.preservedCore, "preservedPixels": value.preservedPixels,
                    "remainingInk": value.sourceRemainingInk.map { $0 as Any } ?? NSNull(),
                    "framePixels": value.sourceFramePixels.map { $0 as Any } ?? NSNull(),
                    "surface": value.surfaceQuality.map { $0 as Any } ?? NSNull()]
        }
        for id in ["1", "2"] {
            let item = try #require(items.first { $0.id == id })
            let attempt = try #require(attempts.first { $0["id"] as? String == id && $0["phase"] as? String == "source-crop" })
            let card = try #require(cards.first { $0["id"] as? String == id })
            let sample = try #require(card["sourceSample"] as? [String: Any])
            let palette = NativeRestorationPixels.palette(sample)
            let excluded = items.filter { $0.id != id }.flatMap { other in
                ([other.sourceBounds] + other.auxiliaryInkRects).compactMap(cropper.pixelRect)
            }
            let detached = try #require(attempt["detached"] as? Bool)
            let descriptor = try #require(cropper.prepare(item: item, palette: palette, excluded: excluded,
                detached: detached, sample: sample,
                frame: CGRect(x: item.sourceFrame[0], y: item.sourceFrame[1], width: item.sourceFrame[2], height: item.sourceFrame[3])))
            let recordedCrop = try #require(attempt["crop"] as? [Double])
            try #require(recordedCrop.count == 4)
            try #require(zip(bounds(descriptor.crop), recordedCrop).allSatisfy { abs($0 - $1) < 1e-9 })
            let recordedWidth = try #require(attempt["width"] as? Int), recordedHeight = try #require(attempt["height"] as? Int)
            try #require(descriptor.pixels.width == recordedWidth && descriptor.pixels.height == recordedHeight)
            let original = descriptor.pixels.rgba
            try pixels(descriptor.pixels, name: id + "-original-crop")
            var options = NativeObservedRestoreOptions()
            options.chromaticBalloon = item.balloonInterior?.contourVerified == true
            options.sampleScale = Double(min(descriptor.sx, descriptor.sy))
            options.leadingRule = descriptor.leadingRule; options.rowEndMarks = descriptor.marks
            options.auxiliary = descriptor.auxiliary; options.excluded = descriptor.excluded
            options.inferredRubyExclusions = descriptor.excluded; options.vertical = item.sourceVertical
            let localPolygon = item.sourcePolygon.map { point in
                CGPoint(x: (point[0] * CGFloat(image.width) - descriptor.crop.minX) * descriptor.sx,
                        y: (point[1] * CGFloat(image.height) - descriptor.crop.minY) * descriptor.sy)
            }
            if !detached {
                options.glyphOwnership = NativeObservedGlyphOwnership.make(width: descriptor.pixels.width,
                    height: descriptor.pixels.height, box: descriptor.box, polygon: localPolygon, auxiliary: descriptor.auxiliary)
            }
            let candidate = NativeRestorationPixels.exactObservedRestore(descriptor.pixels, box: descriptor.box, palette: palette, options: options)
            var record: [String: Any] = ["id": id, "crop": bounds(descriptor.crop), "box": bounds(descriptor.box),
                "width": descriptor.pixels.width, "height": descriptor.pixels.height, "scale": [descriptor.sx, descriptor.sy],
                "auxiliary": descriptor.auxiliary.map(bounds), "excluded": descriptor.excluded.map(bounds),
                "sourceSample": sample, "sampleProvenance": "final card sourceSample; initial source-crop palette equality not recorded",
                "observed": summary(candidate)]
            if let candidate { try pixels(candidate, name: id + "-observed-candidate") }
            let flat = NativeRestorationPixels.flatInpaintingPalette(descriptor.pixels, box: descriptor.box)
            record["flatPalette"] = flat.map { ["foreground": $0.foreground.channels, "background": $0.background.channels] as Any } ?? NSNull()
            var states: [[String: Any]] = []
            for (name, colors) in [("sample", palette), ("flat", flat)] {
                var stateOptions = options
                if name == "flat" { stateOptions.compactMask = true; stateOptions.flatPalette = true }
                guard let colors, let state = NativeObservedRestoreState(descriptor.pixels, box: descriptor.box,
                    palette: colors, options: stateOptions) else { states.append(["name": name, "initialized": false]); continue }
                let established = state.establishMask()
                states.append(["name": name, "initialized": true, "established": established,
                    "unresolved": state.unresolved, "frameInterior": state.frameInterior, "core": state.coreCount,
                    "shortGlyph": state.shortGlyphCandidate, "sourceErasureVerified": state.sourceErasureVerified,
                    "auxiliary": state.auxiliary.map(bounds)])
                for (kind, bytes) in [("raw", state.raw), ("protected", state.protectedInk), ("frame", state.frameInk), ("mask", state.mask)] {
                    try Data(bytes).write(to: directory.appendingPathComponent(id + "-" + name + "-" + kind + ".mask"))
                }
            }
            record["states"] = states
            if detached, let candidate {
                var gate: [String: Any] = [:]
                let result = NativeSlantedProof.pageErasureInQuad(original: descriptor.pixels, result: candidate,
                    sx: Double(descriptor.sx), sy: Double(descriptor.sy), ox: Double(descriptor.crop.minX), oy: Double(descriptor.crop.minY),
                    quad: [Double(item.rect.minX - item.sourceFrame[0]) * Double(image.width) / Double(item.sourceFrame[2]),
                           Double(item.rect.minY - item.sourceFrame[1]) * Double(image.height) / Double(item.sourceFrame[3]),
                           Double(item.rect.width) * Double(image.width) / Double(item.sourceFrame[2]),
                           Double(item.rect.height) * Double(image.height) / Double(item.sourceFrame[3])],
                    angle: Double(item.rotation), auxiliary: item.auxiliaryInkRects.compactMap(cropper.pixelRect).map(NativeSlantedGeometry.array),
                    palette: palette, audit: { gate = $0 })
                record["quadGate"] = gate; record["quadAccepted"] = result != nil
                if let gated = result {
                    try pixels(gated.result, name: id + "-page-gated")
                    let appearance = NativeTranslationRestoration.Appearance(
                        foreground: palette?.verifiedForeground?.cgColor, background: palette?.verifiedBackground?.cgColor,
                        restored: false, stroke: palette?.stroke?.cgColor, sourceSample: sample)
                    let context = NativeTranslationRenderer.SlantedContext(layout: layout, source: image, settings: settings)
                    let admitted = context.admitPage(item: item, appearance: appearance, prepared: descriptor, pixels: gated.result)
                    let entry = try #require(context.entries[id]), trial = try #require(context.results[id])
                    let surface = try #require(trial.surface)
                    let production = try #require(attempts.first { $0["id"] as? String == id && $0["phase"] as? String == "slanted-page-admission" })
                    #expect(production["admitted"] as? Bool == admitted)
                    var probes: [[String: Any]] = []
                    // Bounded diagnostic queries only: they do not replace the
                    // actual trial, commit a layout or change any safety gate.
                    for fraction in [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.45] {
                        var candidate = entry.initial
                        let inset = Double(entry.quad.width) * (1 - fraction) / 2
                        candidate.padding[1] += inset; candidate.padding[3] += inset; candidate.fraction = fraction
                        guard let shaped = context.shape(item: item, appearance: appearance, candidate: candidate, guardPixels: 1) else {
                            probes.append(["fraction": fraction, "shape": false]); continue
                        }
                        var audit = NativeSlantedInkSafety.Audit(survey: true)
                        let fits = context.fits(item: item, entry: entry, surface: surface, candidate: candidate,
                            glyphs: shaped.0.glyphs, color: trial.foreground, audit: &audit)
                        probes.append(["fraction": fraction, "shape": true, "contentFits": shaped.0.contentFits,
                            "lines": shaped.0.lineCount, "glyphs": shaped.0.glyphs, "padding": candidate.padding,
                            "font": candidate.font, "pitch": candidate.pitch, "inkFits": fits,
                            "samples": audit.samples, "unsafe": audit.unsafeCount, "unsafeDim": audit.unsafeDim,
                            "dim": audit.dim, "minimumContrast": audit.minimumContrast.isFinite ? audit.minimumContrast as Any : NSNull(),
                            "range": audit.range.map { $0 as Any } ?? NSNull()])
                    }
                    record["pageAdmission"] = ["accepted": admitted, "metadata": trial.metadata, "measurements": trial.measurements,
                        "foreground": trial.foreground, "candidateRect": bounds(trial.candidate.rect),
                        "angle": trial.candidate.angle, "probes": probes,
                        "provenance": "final-card palette replay; same original item/crop/source, acceptance must match production; initial palette identity not recorded"]
                }
                try #require(!gate.isEmpty)
                if let result { try pixels(result.result, name: id + "-quad-candidate") }
            }
            #expect(descriptor.pixels.rgba == original)
            records.append(record)
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("exact-crop-gates.json"))
    }

}
