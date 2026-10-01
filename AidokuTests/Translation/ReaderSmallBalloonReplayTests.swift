import Testing
import UIKit
@testable import Aidoku

/// Explicit real-image regression for the two narrow neighbouring speech balloons.
@Suite(.serialized)
@MainActor
struct ReaderSmallBalloonReplayTests {
    @Test
    func originalPage() async throws {
        try await replay(URL.documentsDirectory.appendingPathComponent("SmallBalloonReplay"))
    }

    private func replay(_ directory: URL) async throws {
        let cgImage = try #require(UIImage(contentsOfFile: directory.appendingPathComponent("original.image").path)?.cgImage)
        var regions = try await ReaderOCRService.shared.recognize(image: cgImage, configuration: .init(
            detectorMaximumSide: 2000, confidenceThreshold: 0.35, detectorPixelThreshold: 0.3, detectorConfidenceThreshold: 0.3))
        for index in regions.indices {
            let x = regions[index].rect.midX
            regions[index].translation = x > 0.93 ? "치..." : x > 0.85 ? "음(승인가)" : x > 0.5 ? "퐁냐!" : "자○지냐냥?"
        }
        try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
            .write(to: directory.appendingPathComponent("regions.json"))
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let layoutViewport = CGSize(width: 430, height: 932)
        let height = 430 * size.height / size.width
        let frame = CGRect(x: 0, y: (layoutViewport.height - height) / 2, width: 430, height: height)
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.inpaintingEnabled = true
        settings.preserveSourceBackgroundColor = true
        settings.preserveSourceTextColor = true
        settings.opacity = 1
        let rendered = try await NativeTranslationRenderer.render(image: UIImage(cgImage: cgImage), imageSize: size,
            items: ReaderTranslationRegion.layoutItems(regions, imageSize: size), settings: settings,
            targetLanguage: "ko", viewport: layoutViewport, scale: 3, aspectFit: true, collectDiagnostics: true)
        let diagnostic = try #require(rendered.diagnosticData)
        try diagnostic.write(to: directory.appendingPathComponent("native-audit.json"))
        try #require(rendered.image.pngData()).write(to: directory.appendingPathComponent("native-render.png"))
        let report = try #require(JSONSerialization.jsonObject(with: diagnostic) as? [String: Any])
        let cards = try #require(report["cards"] as? [[String: Any]])
        #expect(rendered.renderedItemCount > 0)
        let one = try #require(cards.first { $0["id"] as? String == "1" })
        let two = try #require(cards.first { $0["id"] as? String == "2" })
        #expect(one["sourceBackgroundKind"] as? String == "inpainted")
        // This source remains rotated and is admitted by the strict page-ink
        // path, whose committed provenance is distinct from upright inpainting.
        #expect(two["sourceBackgroundKind"] as? String == "slanted-glyph-restored")
        let rotation = try #require(two["rotation"] as? Double)
        #expect(abs(rotation) > 0)
        let attempts = try #require(report["restorationAttempts"] as? [[String: Any]])
        let admission = try #require(attempts.first { $0["id"] as? String == "2" && $0["phase"] as? String == "slanted-page-admission" })
        #expect(admission["admitted"] as? Bool == true && admission["quadProof"] as? Bool == true)
        #expect(two["restored"] as? Bool == true)
        #expect(two["erasureComplete"] as? Bool == true)
        for card in cards {
            #expect(card["drawsPanel"] as? Bool == false)
            #expect((card["panels"] as? [Any])?.isEmpty == true,
                    "Both narrow balloons must erase without readability or rotated source panels")
            #expect(card["sourceTopAnchored"] as? Bool == false,
                    "Dialogue in these balloons must not be anchored at the source top")
        }
        let punctuation = try rangeRects(one)
        try #require(!punctuation.isEmpty)
        let punctuationBottom = try #require(punctuation.map(\.minY).max())
        let punctuationTop = try #require(punctuation.map(\.minY).min())
        #expect(punctuationBottom - punctuationTop <= 1,
                "Narrow punctuation must remain on one horizontal row")
        for index in [0, 3] {
            try #require(regions.indices.contains(index))
            let card = try #require(cards.first { $0["id"] as? String == String(index) })
            let rects = try rangeRects(card)
            try #require(!rects.isEmpty)
            let top = try #require(rects.map(\.minY).min())
            let bottom = try #require(rects.map(\.maxY).max())
            let center = (top + bottom) / 2
            #expect(abs(center - (frame.minY + regions[index].rect.midY * frame.height)) <= 8,
                    "Translated dialogue must remain centered on its source balloon")
        }
        await ReaderOCRService.shared.purge()
    }

    private func rangeRects(_ card: [String: Any]) throws -> [CGRect] {
        let values = try #require(card["pageRangeBounds"] as? [[Double]])
        return try values.map { value in
            try #require(value.count == 4)
            return CGRect(x: value[0], y: value[1], width: value[2], height: value[3])
        }.filter { $0.width > 0 && $0.height > 0 }
    }
}
