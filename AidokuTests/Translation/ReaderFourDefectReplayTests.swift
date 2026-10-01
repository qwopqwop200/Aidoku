import Testing
import UIKit
@testable import Aidoku

/// Explicit local replay: originals remain outside the repository and provider calls are not required.
@Suite(.serialized)
@MainActor
struct ReaderFourDefectReplayTests {
    @Test
    func capturedOriginals() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("FourDefectReplay/translations.json").path), "Required local replay fixture is missing")
        let directory = URL.documentsDirectory.appendingPathComponent("FourDefectReplay")
        for name in ["overflow", "missing"] {
            let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent(name + ".png").path)?.cgImage)
            let audit = FourDefectRecognitionAudit()
            let profile = NativeCoreMLOCRModelProfile.profile(for: .medium)
            let pipeline = NativeCoreMLOCRPipeline(
                detector: NativeCoreMLDetector(modelResourceName: profile.detectorResourceName, maximumSide: 2000),
                recognizer: NativeCoreMLRecognizer(modelResourceName: profile.recognizerResourceName,
                    dictionaryResourceName: profile.dictionaryResourceName,
                    expectedDictionaryCharacterCount: profile.expectedDictionaryCharacterCount,
                    maximumRecognitionWidth: 1600, auditObserver: { audit.record($0) }),
                postprocessConfiguration: profile.postprocessConfiguration)
            let raw = try await pipeline.recognize(image: image, requestID: name, confidenceThreshold: 0.35,
                detectorConfiguration: .init(threshold: 0.3, boxThreshold: 0.3, unclipRatio: 1.5,
                                             maximumCandidates: 3000, recoveryBoxThreshold: 0.2))
            func rows(_ lines: [NativeCoreMLOCRLine]) -> [[String: Any]] {
                lines.map { ["text": $0.text, "score": $0.score, "polygon": $0.polygon.map { [$0.x, $0.y] },
                             "orientation": $0.orientation.rawValue] }
            }
            try JSONSerialization.data(withJSONObject: ["lines": rows(raw.lines), "gaps": rows(raw.gapLines.map(\.line)),
                                                        "recovered": rows(raw.recoveryCandidates)], options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent(name + ".raw.json"))
            try audit.data().write(to: directory.appendingPathComponent(name + ".recognizer.json"))
            if let frame = await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image) {
                let proposals = frame.bytes.withUnsafeBufferPointer { bytes in
                    let luminance: (Int, Int) -> Int = { x, y in
                        let i = y * frame.bytesPerRow + x * 4
                        return (Int(bytes[i]) * 299 + Int(bytes[i+1]) * 587 + Int(bytes[i+2]) * 114) / 1000
                    }
                    let lines = raw.lines.map { NativeOCRGapLineRecovery.Line(polygon: $0.polygon, text: $0.text) }
                    return NativeOCRGapLineRecovery.proposals(width: frame.width, height: frame.height,
                        luminance: luminance, lines: lines, blockers: []) + NativeOCRGapLineRecovery.edgeProposals(
                            width: frame.width, height: frame.height, luminance: luminance, lines: lines, blockers: [])
                }
                try JSONSerialization.data(withJSONObject: proposals.map { ["polygon": $0.polygon.map { [$0.x, $0.y] },
                    "edge": $0.edge] as [String: Any] }, options: [.prettyPrinted])
                    .write(to: directory.appendingPathComponent(name + ".proposals.json"))
            }
            await pipeline.purgeResources()
            let regions = try await ReaderOCRService.shared.recognize(image: image, configuration: .init(
                detectorMaximumSide: 2000, recognizerMaximumWidth: 1280, confidenceThreshold: 0.35, detectorPixelThreshold: 0.3, detectorConfidenceThreshold: 0.3))
            try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
                .write(to: directory.appendingPathComponent(name + ".regions.json"))
            #expect(!regions.isEmpty)
            if name == "overflow" {
                let caption = try #require(regions.first { $0.source.contains("パンツ") })
                #expect(!caption.source.contains("啡"))
                #expect(caption.rect.minX > 0.81)
            } else {
                let caption = try #require(regions.first { $0.source.contains("興味あるん") })
                #expect(caption.source.contains("レンタルペット"))
                #expect(caption.source.contains("だよなぁ"))
                #expect(!regions.contains { $0.source == "お払" })
                #expect(regions.contains { $0.source.contains("払ってないのにおっぱい") })
            }
            try await render(regions, image: image, name: name, directory: directory)
            await ReaderOCRService.shared.purge()
        }
    }
    private func render(_ regions: [ReaderTranslationRegion], image: CGImage, name: String, directory: URL) async throws {
        let translations = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("translations.json"))) as? [String: String])
        var settings = ReaderTranslationSettings()
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        settings.overlay.inpaintingEnabled = true
        settings.overlay.preserveSourceBackgroundColor = true
        settings.overlay.preserveSourceTextColor = true
        settings.overlay.opacity = 1
        let translated = regions.map { value in
            var region = value
            let key = name == "overflow" && value.source.contains("パンツ") ? "overflow"
                : value.source.contains("興味あるん") ? "missing"
                : value.source.contains("払ってないのに") ? "red" : ""
            region.translation = translations[key] ?? value.source
            return region
        }
        let output = directory.appendingPathComponent("native-replay")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let uiImage = UIImage(cgImage: image)
        let prepared = try ReaderTranslationBackgroundImage.prepare(uiImage)
        let preparedPNG = try #require(prepared.pngData())
        try preparedPNG.write(to: output.appendingPathComponent(name + ".prepared.png"))
        let size = CGSize(width: image.width, height: image.height), viewport = CGSize(width: 430, height: 574)
        let rendered = try await NativeTranslationRenderer.render(image: uiImage, imageSize: size,
            items: ReaderTranslationRegion.layoutItems(translated, imageSize: size), settings: settings.overlay,
            targetLanguage: settings.targetLanguage, viewport: viewport, scale: 3, aspectFit: true,
            dark: false, collectDiagnostics: true)
        #expect(rendered.renderedItemCount > 0)
        let auditData = try #require(rendered.diagnosticData)
        try auditData.write(to: output.appendingPathComponent(name + ".audit.json"))
        try rendered.layoutData.write(to: output.appendingPathComponent(name + ".native-layout.json"))
        let auditObject = try JSONSerialization.jsonObject(with: auditData)
        let audit = try #require(auditObject as? [String: Any])
        let cards = try #require(audit["cards"] as? [[String: Any]])
        let failures = try #require(audit["finalPatchCaptureFailures"] as? [String])
        #expect(failures.isEmpty)
        let repairs = try #require(audit["finalPatches"] as? [[String: Any]])
        for (index, region) in translated.enumerated() where region.translation != region.source {
            let id = String(index)
            let card = try #require(cards.first { $0["id"] as? String == id })
            let panels = try #require(card["panels"] as? [[String: Any]])
            #expect(panels.isEmpty, "Translated source lettering must not retain a readability panel")
            // Initial proposals may defer to the verified final forced repair.
            // Inspect the committed source patch, including its actual PNG pixels.
            let matching = repairs.filter {
                $0["id"] as? String == id && $0["independentArtworkCover"] as? Bool == false
            }
            try #require(matching.count == 1, "The translated source must have one committed primary repair")
            let repair = matching[0]
            #expect(repair["sourceErasureVerified"] as? Bool == true)
            // Source erasure is an independent certificate: preserving foreign
            // lettering can revoke the broad glyph proof while keeping owned ink erased.
            #expect(repair["erasureComplete"] as? Bool == true)
            let erased = try repairedPixelCount(repair,
                output: output.appendingPathComponent(name + ".final-patch-" + id + ".png"))
            let minimum = name == "overflow" ? 35000 : region.source.contains("興味") ? 40000 : 75000
            #expect(erased >= minimum, "Include the original white outlines, not just coloured cores")
        }
        // Persist the same complete-page native export used by the reader cache.
        let snapshot = try await ReaderTranslationImageExporter.renderCacheSnapshot(
            image: uiImage, imageSize: size, regions: translated, settings: settings,
            viewport: viewport, scale: 3, aspectFit: true, host: nil, dark: false, preparedLayout: nil)
        let png = try #require(snapshot.pngData())
        try png.write(to: output.appendingPathComponent(name + ".render.png"))
    }

    private func repairedPixelCount(_ repair: [String: Any], output: URL) throws -> Int {
        let source = try #require(repair["png"] as? String)
        let encoded = try #require(source.split(separator: ",", maxSplits: 1).last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        let patch = try #require(UIImage(data: data)?.cgImage)
        let width = try #require(repair["width"] as? Int)
        let height = try #require(repair["height"] as? Int)
        #expect(patch.width == width && patch.height == height)
        try data.write(to: output)
        var pixels = Data(count: patch.width * patch.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: patch.width, height: patch.height,
                bitsPerComponent: 8, bytesPerRow: patch.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setBlendMode(.copy)
            context.draw(patch, in: CGRect(x: 0, y: 0, width: patch.width, height: patch.height))
        }
        // The production restoration's paintedCount also counts rgba alpha > 0.
        // Decode its actual PNG instead of trusting a reported count or layout-safe mask.
        return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 0 ? 1 : 0) }
    }

}

private final class FourDefectRecognitionAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    func record(_ event: NativeCoreMLRecognitionAuditEvent) {
        guard case let .decoded(_, region, text, confidence, threshold, cacheHit) = event else { return }
        lock.lock(); defer { lock.unlock() }
        rows.append(["index": region.sourceIndex, "text": text, "confidence": confidence, "threshold": threshold,
                     "cached": cacheHit, "polygon": region.polygon.map { [$0.x, $0.y] }])
    }
    func data() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
    }
}
