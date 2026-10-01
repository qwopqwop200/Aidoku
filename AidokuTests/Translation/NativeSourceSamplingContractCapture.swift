import CoreGraphics
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Actual browser observation, independent of the deterministic Node area filter.
@Suite(.serialized) @MainActor
struct NativeSourceSamplingContractCapture {
    private static let webFixture = RegressionWebFixture()

    @Test func expandedEnvironmentUsesActualIOSSourceSampling() async throws {
        typealias F = NativeSourceRestorationMatrixFixtures
        let fixture = try F.load("source-inpainting-expanded-environments", 8, count: 13)
        let page = try fixture.pixels(), bounds = F.bounds(fixture)
        let source = try #require(page.image())
        let png = try #require(UIImage(cgImage: source).pngData())
        let decoded = try #require(UIImage(data: png)?.cgImage)
        let native = try #require(NativeSourceColorSamplingStage(image: decoded, enabled: true).sample(bounds: bounds))
        let original = try #require(NativeSourceColorSamplingStage(image: source, enabled: true).sample(bounds: bounds))
        let browser = Self.webFixture.acquire()
        defer { Self.webFixture.release(browser) }
        try await RegressionWebFixture.load("<!doctype html><html><body></body></html>", in: browser)
        let value = try await browser.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const image=new Image();image.src='data:image/png;base64,'+png;await image.decode();
        const sample=aidokuSourceColorSampler(image,true).sample(bounds);
        return JSON.stringify({sample,display:aidokuSourceDisplayInk(sample),userAgent:navigator.userAgent});
        """, arguments: ["png": png.base64EncodedString(), "bounds": bounds], in: nil, contentWorld: .page)
        let json = try #require(value as? String)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let result = try #require(object as? [String: Any])
        let web = try #require(result["sample"] as? [String: Any])
        let nativeDisplay = try #require(NativeObservedSourcePalette.sourceDisplayInk(sample: native))
        let originalDisplay = try #require(NativeObservedSourcePalette.sourceDisplayInk(sample: original))
        let webDisplay = try #require(result["display"] as? [Double])
        let directory = URL.documentsDirectory.appendingPathComponent("NativeRenderParity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let capture: [String: Any] = ["fixture": fixture.id, "pixelSHA256": F.hash(Data(page.rgba)),
            "scope": "Same immutable source pixels; real iOS Canvas sampling versus production native sampling. Node area-averaged harness is not the platform oracle.",
            "native": native, "nativeOriginalImage": original, "web": web,
            "nativeDisplay": nativeDisplay, "originalDisplay": originalDisplay, "webDisplay": webDisplay,
            "annotatedExpected": fixture.values["expectedColor"] ?? NSNull(),
            "userAgent": result["userAgent"] ?? NSNull()]
        try JSONSerialization.data(withJSONObject: capture, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("expanded-environment-source-contract.json"))
        try png.write(to: directory.appendingPathComponent("expanded-environment-source.png"))
        #expect(originalDisplay == nativeDisplay, "PNG transport preserves the source display observation")
        #expect(nativeDisplay == webDisplay, "Native source display color matches actual iOS Canvas")
    }
}
