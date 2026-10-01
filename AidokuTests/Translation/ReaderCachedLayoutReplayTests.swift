import CoreGraphics
import Testing
import UIKit
@testable import Aidoku

/// Replay captured source/layout fixtures through the production native renderer without provider calls.
@Suite(.serialized)
@MainActor
struct ReaderCachedLayoutReplayTests {
    private static var directory: URL { URL.documentsDirectory.appendingPathComponent("CachedLayoutReplay") }

    @Test
    func capturedLayoutUsesNativeBackgroundPreparation() async throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OverlayIncidentReplay")
        if let data = try? Data(contentsOf: caches.appendingPathComponent("pages.json")) {
            let names = try JSONDecoder().decode([String].self, from: data)
            try #require(!names.isEmpty)
            for name in names { try await replay(caches.appendingPathComponent(name)) }
        } else { try await replay(Self.directory) }
    }

    private func replay(_ directory: URL) async throws {
        let output = directory.appendingPathComponent("native-replay", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var payloadURL = directory.appendingPathComponent("payload.json")
        let regionURL = directory.appendingPathComponent("regions.json")
        let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent("original.image").path))
        let cg = try #require(image.cgImage)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("refresh-ocr").path) {
            let recognized = try await ReaderOCRService.shared.recognize(image: cg, configuration: .init(
                detectorMaximumSide: 2000, recognizerMaximumWidth: 1280, confidenceThreshold: 0.35,
                detectorPixelThreshold: 0.3, detectorConfidenceThreshold: 0.3))
            try JSONEncoder().encode(recognized.map(ReaderTranslationStoredRegion.init))
                .write(to: output.appendingPathComponent("recognized.json"))
            #expect(!recognized.isEmpty)
        }
        // Captured geometry and expectations are immutable. A regions-only replay
        // generates a separate candidate, never replacing a captured payload.
        if !FileManager.default.fileExists(atPath: payloadURL.path),
           FileManager.default.fileExists(atPath: regionURL.path) {
            let stored = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: Data(contentsOf: regionURL))
            let size = CGSize(width: cg.width, height: cg.height)
            let viewport = CGSize(width: 430, height: 932)
            let height = 430 * size.height / size.width
            let frame = CGRect(x: 0, y: (viewport.height - height) / 2, width: 430, height: height)
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.inpaintingEnabled = true
            settings.preserveSourceBackgroundColor = true
            settings.preserveSourceTextColor = true
            settings.opacity = 1
            let layout = try NativeTranslationLayoutPlanner.plan(
                items: ReaderTranslationRegion.layoutItems(stored.map(\.region), imageSize: size),
                imageSize: size, sourceRect: frame, settings: settings, targetLanguage: "ko", viewport: viewport)
            let items = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout.items))
            let payload: [String: Any] = ["items": items, "viewport": [430, 932], "scale": 3,
                "imageSize": [cg.width, cg.height], "displayRect": [frame.minX, frame.minY, frame.width, frame.height],
                "appearance": ["inpaintingEnabled": true, "preserveSourceBackgroundColor": true,
                               "preserveSourceTextColor": true, "opacity": 1]]
            payloadURL = output.appendingPathComponent("generated-payload.json")
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: payloadURL)
        }
        try #require(FileManager.default.fileExists(atPath: payloadURL.path),
                     "Install payload.json and original.image in Documents/CachedLayoutReplay before this replay")
        let payloadData = try Data(contentsOf: payloadURL)
        let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
        let payload = try #require(payloadObject as? [String: Any])
        let expectationURL = directory.appendingPathComponent("expectations.json")
        let expectations: [String: Any]
        if FileManager.default.fileExists(atPath: expectationURL.path) {
            let expectationData = try Data(contentsOf: expectationURL)
            let expectationObject = try JSONSerialization.jsonObject(with: expectationData)
            expectations = try #require(expectationObject as? [String: Any])
        } else {
            expectations = payload
        }
        let viewportValues = try #require(payload["viewport"] as? [Double])
        let frame = try #require(payload["displayRect"] as? [Double])
        let size = try #require(payload["imageSize"] as? [Double])
        try #require(viewportValues.count == 2 && frame.count == 4 && size.count == 2)
        let viewport = CGSize(width: viewportValues[0], height: viewportValues[1])
        let imageSize = CGSize(width: size[0], height: size[1])
        #expect(imageSize == CGSize(width: cg.width, height: cg.height))
        let rawItems = try #require(payload["items"])
        let itemData = try JSONSerialization.data(withJSONObject: rawItems)
        let items = try JSONDecoder().decode([NativeTranslationLayoutItem].self, from: itemData)
        try #require(!items.isEmpty)
        let layout = NativeTranslationLayout(imageSize: imageSize,
            sourceRect: CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]),
            viewport: viewport, items: items, sourceObjectFit: "contain")
        let appearance = try #require(payload["appearance"] as? [String: Any])
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.inpaintingEnabled = appearance["inpaintingEnabled"] as? Bool ?? false
        settings.preserveSourceBackgroundColor = appearance["preserveSourceBackgroundColor"] as? Bool ?? false
        settings.preserveSourceTextColor = appearance["preserveSourceTextColor"] as? Bool ?? false
        settings.opacity = appearance["opacity"] as? Double ?? 1
        let prepared = try ReaderTranslationBackgroundImage.prepare(image)
        let encodedSource = try ReaderTranslationBackgroundImage.dataURL(for: image)
        let encoded = try #require(encodedSource)
        let encodedPNG = try #require(encoded.split(separator: ",", maxSplits: 1).last)
        let png = try #require(Data(base64Encoded: String(encodedPNG)))
        let decoded = try #require(UIImage(data: png)?.cgImage)
        let preparedCG = try #require(prepared.cgImage)
        #expect(decoded.width == preparedCG.width && decoded.height == preparedCG.height)
        let decodedPixels = try canonicalRGBA(decoded)
        let preparedPixels = try canonicalRGBA(preparedCG)
        let preservesPreparedPixels = decodedPixels == preparedPixels
        #expect(preservesPreparedPixels, "PNG representation must preserve prepared source pixels")
        try #require(prepared.pngData()).write(to: output.appendingPathComponent("prepared.png"))
        // This serialized suite invokes the synchronous production pipeline to
        // retain the exact captured frame, including non-default page geometry.
        let result = try NativeTranslationRenderer.renderSynchronously(layout: layout, image: prepared, settings: settings,
            scale: CGFloat(payload["scale"] as? Double ?? 1), collectDiagnostics: true)
        #expect(result.renderedItemCount > 0)
        let retainedLayout = try JSONDecoder().decode(NativeTranslationLayout.self, from: result.layoutData)
        #expect(retainedLayout == layout)
        try result.layoutData.write(to: output.appendingPathComponent("native-layout.json"))
        let auditData = try #require(result.diagnosticData)
        try auditData.write(to: output.appendingPathComponent("audit.json"))
        try #require(result.image.pngData()).write(to: output.appendingPathComponent("render.png"))
        let auditObject = try JSONSerialization.jsonObject(with: auditData)
        let audit = try #require(auditObject as? [String: Any])
        let cards = try #require(audit["cards"] as? [[String: Any]])
        for rule in expectations["styleRules"] as? [[String: Any]] ?? [] {
            let ids = try #require(rule["ids"] as? [String])
            for id in ids {
                let card = try #require(cards.first { $0["id"] as? String == id })
                let fill = try #require(card["foreground"] as? [Double])
                let stroke = try #require(card["outline"] as? [Double])
                let width = try #require(card["outlineWidth"] as? Double)
                #expect(within(fill, minimum: rule["minimumFill"] as? [Double], maximum: rule["maximumFill"] as? [Double]),
                        "Captured \(directory.lastPathComponent)/\(id) native fill must satisfy original bounds")
                if rule["minimumStroke"] != nil || rule["maximumStroke"] != nil {
                    #expect(within(stroke, minimum: rule["minimumStroke"] as? [Double], maximum: rule["maximumStroke"] as? [Double]))
                }
                if let minimum = rule["minimumStrokeWidth"] as? Double { #expect(width >= minimum) }
                if let maximum = rule["maximumStrokeWidth"] as? Double { #expect(width <= maximum) }
                if let font = rule["fontSize"] as? Double {
                    let actualFont = try #require(card["fontSize"] as? Double)
                    #expect(abs(actualFont - font) < 0.01)
                }
                if let pitch = rule["lineHeight"] as? Double {
                    let actualPitch = try #require(card["lineHeight"] as? Double)
                    #expect(abs(actualPitch - pitch) < 0.02)
                }
            }
        }
        for id in expectations["expectedInpaintedIDs"] as? [String] ?? [] {
            let card = try #require(cards.first { $0["id"] as? String == id })
            #expect(card["sourceBackgroundKind"] as? String == "inpainted")
            let panels = try #require(card["panels"] as? [[String: Any]])
            #expect(panels.isEmpty,
                    "Captured region \(id) must retain inpainting without a flat panel")
        }
        for id in expectations["expectedTopAlignedIDs"] as? [String] ?? [] {
            let item = try #require(items.first { $0.id == id })
            let card = try #require(cards.first { $0["id"] as? String == id })
            let ranges = try #require(card["pageRangeBounds"] as? [[Double]])
            let top = try #require(ranges.filter { $0.count == 4 && $0[2] > 0 && $0[3] > 0 }.map { $0[1] }.min())
            let sourceTop = Double(item.sourceFrame[1] + item.sourceBounds[1] * item.sourceFrame[3])
            #expect(abs(top - sourceTop) <= 0.5, "Final glyphs must begin at the source top")
        }
        if let minimumErased = payload["minimumErasedPixels"] as? [String: Int] {
            let captureFailures = try #require(audit["initialPatchCaptureFailures"] as? [String])
            #expect(captureFailures.isEmpty)
            let repairs = try #require(audit["initialPatches"] as? [[String: Any]])
            for (id, minimum) in minimumErased {
                let repair = try #require(repairs.first { $0["id"] as? String == id })
                #expect(repair["sourceErasureVerified"] as? Bool == true)
                let source = try #require(repair["png"] as? String)
                let encodedPatch = try #require(source.split(separator: ",", maxSplits: 1).last)
                let data = try #require(Data(base64Encoded: String(encodedPatch)))
                let image = try #require(UIImage(data: data)?.cgImage)
                let rgba = try canonicalRGBA(image)
                let erased = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.count
                #expect(erased >= minimum, "The captured source outline must be removed too")
            }
        }
    }

    private func within(_ values: [Double], minimum: [Double]?, maximum: [Double]?) -> Bool {
        values.count == 3 && (minimum == nil || minimum?.count == 3) && (maximum == nil || maximum?.count == 3) &&
            values.indices.allSatisfy { values[$0].isFinite && (minimum == nil || values[$0] >= minimum![$0]) &&
                (maximum == nil || values[$0] <= maximum![$0]) }
    }

    private func canonicalRGBA(_ image: CGImage) throws -> Data {
        var bytes = Data(count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
