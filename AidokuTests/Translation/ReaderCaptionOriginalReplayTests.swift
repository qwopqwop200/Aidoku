import Testing
import UIKit
@testable import Aidoku

/// Original image and recorded translations are immutable local replay inputs.
@Suite(.serialized)
@MainActor
struct ReaderCaptionOriginalReplayTests {
    @Test func originalThroughOCRRecordedTranslationAndNativeRendering() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("CaptionOriginalReplay")
        let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent("original.png").path))
        let cgImage = try #require(image.cgImage)
        let settings = try RecordedTranslationReplay.settings(in: directory)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("recorded-payload.json"))) as? [String: Any])
        let recorded = try #require(saved["items"] as? [[String: Any]])
        let configuration = try RecordedTranslationReplay.ocrConfiguration(in: directory)
        let raw = try await ReaderOCRService.shared.recognize(image: cgImage, configuration: configuration)
        try JSONEncoder().encode(raw.map(ReaderTranslationStoredRegion.init))
            .write(to: directory.appendingPathComponent("original.actual.regions.json"))
        try #require(recorded.count == 7)
        // These are seven independently captured boxes, not seven raw OCR reads.
        // The screenshot also contains status text, toolbar controls and a footer.
        var recordsByRawID: [String: [String: Any]] = [:]
        var rawIDByRecordedID: [String: String] = [:]
        for item in recorded {
            let recordedID = try #require(item["id"] as? String)
            let bounds = try #require(item["sourceBounds"] as? [Double])
            try #require(bounds.count == 4)
            let matches = raw.filter { region in
                let coordinates = [region.rect.minX, region.rect.minY, region.rect.width, region.rect.height].map(Double.init)
                return zip(coordinates, bounds).allSatisfy { abs($0 - $1) < 0.000001 }
            }
            try #require(matches.count == 1, "Every captured box must retain an independently recognized geometry")
            let match = matches[0]
            try #require(recordsByRawID[match.id] == nil)
            recordsByRawID[match.id] = item
            rawIDByRecordedID[recordedID] = match.id
        }
        // Image inspection identifies kept-0 as the document toolbar's bulleted-list
        // icon. It has no Japanese lettering or translation. The old capture's
        // false positive must not force that icon into the production language filter.
        let icon = try #require(recorded.first { $0["id"] as? String == "kept-0" })
        #expect(icon["keptLettering"] as? Bool == true)
        #expect(icon["text"] == nil)
        let iconBounds = try #require(icon["sourceBounds"] as? [Double])
        let annotatedIconBounds = [0.19224806201550387, 0.0740343347639485, 0.06821705426356589, 0.02503576537911302]
        #expect(iconBounds.count == annotatedIconBounds.count)
        #expect(zip(iconBounds, annotatedIconBounds).allSatisfy { abs($0 - $1) <= 1e-12 })
        let iconRawID = try #require(rawIDByRecordedID["kept-0"])
        // ReaderTranslationService applies this production stage before returning
        // translated regions; the deterministic provider replay uses the same policy.
        let recognized = ReaderTranslationLanguageFilter.apply(raw, settings: settings)
        try JSONEncoder().encode(recognized.map(ReaderTranslationStoredRegion.init))
            .write(to: directory.appendingPathComponent("original.actual.filtered-regions.json"))
        #expect(!recognized.contains { $0.id == iconRawID })
        let expectedIDs = Set(rawIDByRecordedID.filter { $0.key != "kept-0" }.map(\.value))
        try #require(recognized.count == 6)
        #expect(Set(recognized.map(\.id)) == expectedIDs)
        let translated = try recognized.map { region in
            let item = try #require(recordsByRawID[region.id])
            var value = region
            value.translation = item["text"] as? String ?? region.source
            return value
        }
        #expect(translated.filter { $0.translation != $0.source }.count == 4)
        #expect(translated.contains { $0.translation?.contains("고마") == true })
        let viewport = CGSize(width: 430, height: 932)
        let rendered = try await NativeTranslationRenderer.render(image: image, imageSize: image.size,
            items: ReaderTranslationRegion.layoutItems(translated, imageSize: image.size), settings: settings.overlay,
            targetLanguage: settings.targetLanguage, viewport: viewport, scale: 3, aspectFit: true,
            collectDiagnostics: true)
        let diagnostic = try #require(rendered.diagnosticData)
        let report = try #require(JSONSerialization.jsonObject(with: diagnostic) as? [String: Any])
        let cards = try #require(report["cards"] as? [[String: Any]])
        let caption = try #require(cards.first { ($0["text"] as? String)?.contains("고마") == true })
        #expect(caption["drawsPanel"] as? Bool == false, "Short restored captions must not retain a rectangular panel")
        #expect((caption["panels"] as? [Any])?.isEmpty == true)
        #expect(caption["restored"] as? Bool == true)
        #expect(caption["sourceBackgroundKind"] as? String == "inpainted")
        // The source quad separates the upper-right hat contour from lettering.
        // Body proof can be valid while the surrounding rectangle still has art.
        let initial = try #require((report["initialPatches"] as? [[String: Any]])?.first {
            $0["id"] as? String == caption["id"] as? String
        })
        #expect(initial["sourceGlyphsVerified"] as? Bool == true)
        #expect(initial["sourceErasureVerified"] as? Bool == false)
        #expect(initial["sourceRemainingInk"] as? Int == 4)
        #expect(rendered.renderedItemCount > 0)
        try diagnostic.write(to: directory.appendingPathComponent("original.native-audit.json"))
        try #require(rendered.image.pngData()).write(to: directory.appendingPathComponent("original.native-render.png"))
        let sourceOnly = try await NativeTranslationRenderer.render(image: image, imageSize: image.size,
            items: [], settings: settings.overlay, targetLanguage: settings.targetLanguage,
            viewport: viewport, scale: 3, aspectFit: true)
        let actualPixels = try #require(rendered.image.cgImage)
        let originalPixels = try #require(sourceOnly.image.cgImage)
        try #require(actualPixels.width == originalPixels.width && actualPixels.height == originalPixels.height)
        let iconPixels = CGRect(x: iconBounds[0] * Double(actualPixels.width), y: iconBounds[1] * Double(actualPixels.height),
            width: iconBounds[2] * Double(actualPixels.width), height: iconBounds[3] * Double(actualPixels.height)).integral
        let actualIcon = try #require(actualPixels.cropping(to: iconPixels))
        let originalIcon = try #require(originalPixels.cropping(to: iconPixels))
        let actualIconBytes = try pixelBytes(actualIcon)
        let originalIconBytes = try pixelBytes(originalIcon)
        #expect(actualIconBytes == originalIconBytes, "Translation must preserve every toolbar icon pixel")
        // Independently inspected original-source hat-contour points, including
        // the four bbox-only uncertain pixels and nineteen contour pixels inside
        // the tilted quad. A body-glyph certificate cannot authorize painting art.
        let sourceHash = NativeSourceRestorationMatrixFixtures.hash(try Data(contentsOf: directory.appendingPathComponent("original.png")))
        #expect(sourceHash == "bc7e2e2da80ea343daaa64192d5c6e7466aaab879658b08c01631d79780e3eee")
        let hatContour = [
            [66, 1146], [60, 1151], [61, 1151], [62, 1151],
            [57, 1147], [55, 1148], [56, 1148], [57, 1148],
            [54, 1149], [55, 1149], [56, 1149], [57, 1149],
            [53, 1150], [54, 1150], [55, 1150], [56, 1150], [57, 1150],
            [52, 1151], [53, 1151], [52, 1152], [52, 1153], [52, 1154], [52, 1155]
        ]
        try #require(actualPixels.width == 1290 && actualPixels.height == 2796)
        let committed = try #require((report["finalPatches"] as? [[String: Any]])?.first {
            $0["id"] as? String == caption["id"] as? String
        })
        let encodedPatch = try #require((committed["png"] as? String)?.split(separator: ",").last)
        let patchData = try #require(Data(base64Encoded: String(encodedPatch)))
        let patchImage = try #require(UIImage(data: patchData)?.cgImage)
        let values = try #require(committed["frame"] as? [Double])
        try #require(values.count == 4)
        let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        let deviceScale = CGFloat(actualPixels.width) / viewport.width
        let sourceFrame = CGRect(x: frame.minX * deviceScale, y: frame.minY * deviceScale,
            width: frame.width * deviceScale, height: frame.height * deviceScale)
        let liveFrame = try #require(NativeSourceCanvasImageFrame.liveFrame(domRect: frame))
        let livePixels = CGRect(x: liveFrame.minX * deviceScale, y: liveFrame.minY * deviceScale,
            width: liveFrame.width * deviceScale, height: liveFrame.height * deviceScale)
        func alpha(_ x: Int, _ y: Int) throws -> UInt8 {
            guard x >= 0, y >= 0, x < patchImage.width, y < patchImage.height else { return 0 }
            let pixel = try #require(patchImage.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)))
            return try pixelBytes(pixel)[3]
        }
        var pointAudit: [[String: Any]] = []
        for point in hatContour {
            let center = CGPoint(x: CGFloat(point[0]) + 0.5, y: CGFloat(point[1]) + 0.5)
            let sourceX = (center.x - sourceFrame.minX) * CGFloat(patchImage.width) / sourceFrame.width - 0.5
            let sourceY = (center.y - sourceFrame.minY) * CGFloat(patchImage.height) / sourceFrame.height - 0.5
            try #require(abs(sourceX - sourceX.rounded()) < 0.000001 && abs(sourceY - sourceY.rounded()) < 0.000001)
            let rawAlpha = try alpha(Int(sourceX.rounded()), Int(sourceY.rounded()))
            #expect(rawAlpha == 0, "The committed restoration mask cannot paint the source hat at \(point)")
            // The live canvas rounds CSS edges before output scaling. A source
            // edge can then receive a neighboring restored texel through linear
            // filtering, although its own raw source mask remains transparent.
            // Exact final preservation applies beyond that sampling footprint;
            // never replace ownership with a measured color-error tolerance.
            let sampleX = (center.x - livePixels.minX) * CGFloat(patchImage.width) / livePixels.width - 0.5
            let sampleY = (center.y - livePixels.minY) * CGFloat(patchImage.height) / livePixels.height - 0.5
            let left = Int(floor(sampleX)), top = Int(floor(sampleY))
            let dx = sampleX - floor(sampleX), dy = sampleY - floor(sampleY)
            let footprint = [(left, top, (1 - dx) * (1 - dy)), (left + 1, top, dx * (1 - dy)),
                (left, top + 1, (1 - dx) * dy), (left + 1, top + 1, dx * dy)]
            var receivesPaintedNeighbor = false
            for (x, y, weight) in footprint where weight > 0.000000001 {
                if try alpha(x, y) != 0 { receivesPaintedNeighbor = true }
            }
            let rect = CGRect(x: CGFloat(point[0]), y: CGFloat(point[1]), width: 1, height: 1)
            let actual = try #require(actualPixels.cropping(to: rect)), original = try #require(originalPixels.cropping(to: rect))
            let actualBytes = try pixelBytes(actual), originalBytes = try pixelBytes(original)
            if !receivesPaintedNeighbor {
                #expect(actualBytes == originalBytes, "Preserve protected hat interior beyond transformed paint support at \(point)")
            }
            pointAudit.append(["point": point, "rawAlpha": Int(rawAlpha), "receivesPaintedNeighbor": receivesPaintedNeighbor,
                "sourceRGBA": Array(originalBytes), "finalRGBA": Array(actualBytes),
                "deltaRGBA": zip(actualBytes, originalBytes).map { Int($0) - Int($1) }])
        }
        try JSONSerialization.data(withJSONObject: pointAudit, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("original.protected-hat-audit.json"))
        await ReaderOCRService.shared.purge()
    }

    private func pixelBytes(_ image: CGImage) throws -> Data {
        var bytes = Data(count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
