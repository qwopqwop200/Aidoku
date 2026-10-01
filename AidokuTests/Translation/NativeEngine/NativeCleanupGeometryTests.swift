import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCleanupGeometryTests {
    @Test func normalizedPixelsDoNotReuseTheOriginalImageAspectRatio() throws {
        let originalFrame = CGRect(x: 0, y: 212.30263157894737, width: 390, height: 275.39473684210526)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 3192, height: 2254), sourceRect: originalFrame,
            viewport: CGSize(width: 390, height: 700), items: [])
        let geometry = try #require(NativeTranslationRenderer.normalizedCleanupGeometry(layout: layout,
            naturalSize: CGSize(width: 2380, height: 1680), objectFit: "contain"))
        #expect(abs(geometry.frame.minY - 212.35294117647058) < 1e-10)
        #expect(abs(geometry.frame.height - 275.29411764705884) < 1e-10)
        #expect(geometry.frame.width == 390 && geometry.clip == CGRect(x: 0, y: 0, width: 390, height: 700))
        #expect(layout.sourceRect == originalFrame && layout.imageSize == CGSize(width: 3192, height: 2254))
    }

    @Test func storedFitSurvivesReplayEvenWhenOriginalSourceExactlyFilledTheViewport() throws {
        let viewport = CGSize(width: 390, height: 390)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 3192, height: 3192),
            sourceRect: CGRect(origin: .zero, size: viewport), viewport: viewport, items: [], sourceObjectFit: "contain")
        let decoded = try JSONDecoder().decode(NativeTranslationLayout.self, from: JSONEncoder().encode(layout))
        let natural = CGSize(width: 2380, height: 2379)
        let replay = try #require(NativeTranslationRenderer.normalizedCleanupGeometry(layout: decoded, naturalSize: natural))
        let fill = try #require(NativeTranslationRenderer.normalizedCleanupGeometry(layout: decoded, naturalSize: natural, objectFit: "fill"))
        #expect(replay.frame.minY > 0 && replay.frame.height < viewport.height)
        #expect(fill.frame == CGRect(origin: .zero, size: viewport))
        #expect(decoded == layout)
    }

    @Test func sourceElementCSSBoundsAndUnsupportedFitRemainExplicit() throws {
        let viewport = CGSize(width: 390.1234, height: 700.5678)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 640, height: 880),
            sourceRect: CGRect(origin: .zero, size: viewport), viewport: viewport, items: [])
        let fill = try #require(NativeTranslationRenderer.normalizedCleanupGeometry(layout: layout,
            naturalSize: CGSize(width: 640, height: 880), objectFit: "fill"))
        #expect(fill.frame == CGRect(x: 0, y: 0, width: 390.109375, height: 700.5625))
        #expect(NativeTranslationRenderer.normalizedCleanupGeometry(layout: layout, naturalSize: .zero, objectFit: "contain") == nil)
        #expect(NativeTranslationRenderer.normalizedCleanupGeometry(layout: layout,
            naturalSize: CGSize(width: 640, height: 880), objectFit: "unsupported") == nil)
    }
}
