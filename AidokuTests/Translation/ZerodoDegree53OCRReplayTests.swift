import Testing
import UIKit
@testable import Aidoku

/// Opt-in replay of the 53 original pages selected from the user's device cache.
/// The fixture lives in the simulator Documents directory and is never checked in.
@Suite(.serialized)
@MainActor
struct ZerodoDegree53OCRReplayTests {
    @Test
    func repaintGeometryFromStoredRegions() throws {
        let directory = URL.documentsDirectory.appendingPathComponent("ZerodoDegree53Replay")
        let names = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: directory.appendingPathComponent("run.json")))
        #expect(names.count == 53)
        for name in names {
            let image = try #require(UIImage(contentsOfFile:
                directory.appendingPathComponent(name + ".png").path))
            let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
                from: Data(contentsOf: directory.appendingPathComponent(name + ".regions.json"))).map(\.region)
            let geometryOnly = regions.map { original -> ReaderTranslationRegion in
                var region = original
                region.translation = String(repeating: "가", count: max(2, min(24, original.source.count / 2)))
                return region
            }
            let size = image.size
            let viewport = CGSize(width: 430, height: 574)
            let frameHeight = 430 * size.height / size.width
            let frame = CGRect(x: 0, y: (viewport.height - frameHeight) / 2,
                width: 430, height: frameHeight)
            let items = BrowserPageImageOverlayRenderer.layoutPayload(
                items: ReaderTranslationRegion.layoutItems(geometryOnly, imageSize: size),
                imageSize: size, sourceRect: frame,
                settings: ReaderTranslationSettings.defaultOverlay,
                targetLanguage: "ko", viewport: viewport)
            let payload: [String: Any] = [
                "items": items, "imageSize": [size.width, size.height],
                "viewport": [viewport.width, viewport.height], "scale": 3,
                "displayRect": [frame.minX, frame.minY, frame.width, frame.height],
                "translationMode": "korean-dummy-geometry-probe",
                "appearance": ["inpaintingEnabled": true,
                    "preserveSourceBackgroundColor": true,
                    "preserveSourceTextColor": true, "opacity": 1,
                    "minimumReadableFontSize": 5]
            ]
            try JSONSerialization.data(withJSONObject: payload)
                .write(to: directory.appendingPathComponent(name + ".geometry.payload.json"))
            #expect(items.contains { ($0["keptLettering"] as? Bool) != true },
                "No painted caption on page \(name)")
        }
    }

    @Test
    func originalPages() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("ZerodoDegree53Replay")
        let names = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: directory.appendingPathComponent("run.json")))
        #expect(names.count == 53)
        var summary: [[String: Any]] = []
        for name in names {
            let started = Date()
            do {
                let image = try #require(UIImage(contentsOfFile:
                    directory.appendingPathComponent(name + ".png").path))
                let cgImage = try #require(image.cgImage)
                let regions = try await ReaderOCRService.shared.recognize(image: cgImage,
                    configuration: .init(detectorMaximumSide: 2000,
                        confidenceThreshold: 0.35,
                        detectorPixelThreshold: 0.3,
                        detectorConfidenceThreshold: 0.3))
                try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
                    .write(to: directory.appendingPathComponent(name + ".regions.json"))

                // Deliberately distinct Korean text activates the painted-caption path.
                // This is a geometry probe, not a translation.
                let geometryOnly = regions.map { original -> ReaderTranslationRegion in
                    var region = original
                    region.translation = String(repeating: "가", count: max(2, min(24, original.source.count / 2)))
                    return region
                }
                let size = image.size
                let viewport = CGSize(width: 430, height: 574)
                let frameHeight = 430 * size.height / size.width
                let frame = CGRect(x: 0, y: (viewport.height - frameHeight) / 2,
                    width: 430, height: frameHeight)
                let items = BrowserPageImageOverlayRenderer.layoutPayload(
                    items: ReaderTranslationRegion.layoutItems(geometryOnly, imageSize: size),
                    imageSize: size, sourceRect: frame,
                    settings: ReaderTranslationSettings.defaultOverlay,
                    targetLanguage: "ko", viewport: viewport)
                let payload: [String: Any] = [
                    "items": items, "imageSize": [size.width, size.height],
                    "viewport": [viewport.width, viewport.height], "scale": 3,
                    "displayRect": [frame.minX, frame.minY, frame.width, frame.height],
                    "translationMode": "korean-dummy-geometry-probe",
                    "appearance": ["inpaintingEnabled": true,
                        "preserveSourceBackgroundColor": true,
                        "preserveSourceTextColor": true, "opacity": 1,
                        "minimumReadableFontSize": 5]
                ]
                try JSONSerialization.data(withJSONObject: payload)
                    .write(to: directory.appendingPathComponent(name + ".geometry.payload.json"))
                summary.append(["page": name, "regions": regions.count,
                    "items": items.count, "seconds": Date().timeIntervalSince(started)])
                #expect(!regions.isEmpty, "No text on page \(name)")
            } catch {
                summary.append(["page": name, "error": String(describing: error),
                    "seconds": Date().timeIntervalSince(started)])
            }
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("summary.json"))
            await ReaderOCRService.shared.purge()
        }
        #expect(summary.count == 53)
        #expect(summary.allSatisfy { $0["error"] == nil })
    }
}
